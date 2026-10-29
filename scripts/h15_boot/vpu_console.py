#!/usr/bin/env python3
"""Drive a Hailo-15 board's u-boot console from the shuttle (picocom + pexpect).

Subcommands:
  detect   reset the board, stop at the u-boot prompt, print its `board` (machine)
           and network env, then boot normally. Use only when Linux doesn't come up.
  flash    reset the board, stop at the u-boot prompt and run the boot menu's
           "Board Init" entry for the machine. Then follow the flash to `login:`.
           The board TFTPs fitImage + the swupdate image from the shuttle, boots
           it, pulls hailo-update-image-<machine>.swu and writes eMMC/SD. Stage
           the release and point TFTP at it first (vpu_stage.sh).

The board is reset over ssh (`--reset ssh`, default; needs vpu_detect.sh's key)
or by a person (`--reset manual`: power-cycle or press reset when asked).

Never takes the serial port from another program: if picocom/minicom/screen
holds it, this exits with code 2 and names the process.

Exit codes: 0 ok, 1 failed, 2 serial port busy, 3 timeout.
Everything the console prints is appended to --log.

Usage (on the shuttle):
  source scripts/h15_boot/shuttle.env
  scripts/h15_boot/vpu_console.py flash --machine hailo15l-sbc
  scripts/h15_boot/vpu_console.py detect --reset manual
"""

import argparse
import os
import re
import shlex
import subprocess
import sys
import time

try:
    import pexpect
except ImportError:
    sys.exit("pexpect not installed (pip3 install --user pexpect)")

# Boot menu entry that re-initialises the boot device from TFTP, per machine
# (same choice as flash_board.py: H15L SBC boots from eMMC, H15H SBC from SD).
INIT_LABEL = {
    "hailo15l-sbc": "eMMC Board Init",
    "hailo15-sbc": "SD Card Board Init",
    "hailo15-sbc-rev3-1": "SD Card Board Init",
}

PROMPT = r"\n(?:hailo\w*#|=>) ?"
AUTOBOOT = r"U-Boot Boot Menu|Hit any key to stop autoboot"
FATAL = (r"TFTP error[^\r\n]*|Retry count exceeded[^\r\n]*|SWUPDATE failed[^\r\n]*"
         r"|tftp: (?:timeout|server error|can't)[^\r\n]*"
         r"|Kernel panic[^\r\n]*|ERROR: All boot options failed")


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def port_users(tty):
    """PIDs + names of processes holding the serial port."""
    out = subprocess.run(["fuser", tty], capture_output=True, text=True).stdout.split()
    users = []
    for pid in out:
        pid = pid.strip().rstrip("ecfFrm")
        if pid.isdigit():
            try:
                with open(f"/proc/{pid}/comm") as f:
                    users.append(f"{pid} ({f.read().strip()})")
            except OSError:
                users.append(pid)
    return users


class Console:
    def __init__(self, tty, logfile):
        self.child = pexpect.spawn(
            f"picocom -q --noreset -b 115200 {shlex.quote(tty)}",
            encoding="utf-8", codec_errors="ignore", timeout=30)
        self.child.logfile_read = open(logfile, "a")
        time.sleep(1)

    def close(self):
        try:
            self.child.send("\x01\x18")  # picocom: C-a C-x
            self.child.expect(pexpect.EOF, timeout=5)
        except Exception:
            self.child.terminate(force=True)

    def stop_autoboot(self, timeout):
        """Wait for u-boot's menu/countdown, then Ctrl+C until the prompt."""
        self.child.expect(AUTOBOOT, timeout=timeout)
        for _ in range(30):
            self.child.send("\x03")
            try:
                self.child.expect(PROMPT, timeout=0.5)
                break
            except pexpect.TIMEOUT:
                continue
        else:
            raise RuntimeError("u-boot menu seen, but no prompt after Ctrl+C")
        self.cmd("")  # confirm we're at a quiet prompt

    def cmd(self, line, timeout=15):
        self.child.sendline(line)
        self.child.expect(PROMPT, timeout=timeout)
        return self.child.before.replace("\r", "")

    def env(self, *names):
        out = self.cmd("printenv " + " ".join(names))
        return dict(re.findall(r"^([\w.]+)=(.*)$", out, re.M))


def reset_board(how, target, ssh_opts):
    if how == "ssh":
        log(f"Rebooting {target} over ssh...")
        subprocess.run(["ssh", *shlex.split(ssh_opts), target, "reboot"],
                       capture_output=True, timeout=30)
    else:
        log("Power-cycle the board or press its reset button now.")


def go_to_prompt(args):
    users = port_users(args.tty)
    if users:
        log(f"Serial port {args.tty} is in use by: {', '.join(users)}. "
            "Close that terminal (picocom: Ctrl+A Ctrl+X) and run again.")
        sys.exit(2)
    con = Console(args.tty, args.log)
    reset_board(args.reset, args.target, args.ssh_opts)
    con.stop_autoboot(timeout=args.reset_timeout)
    log("At the u-boot prompt")
    return con


def cmd_detect(args):
    con = go_to_prompt(args)
    try:
        env = con.env("board", "serverip", "ipaddr", "core_image_name")
        for k in ("board", "serverip", "ipaddr", "core_image_name"):
            print(f"{k.upper()}={env.get(k, '')}")
        con.child.sendline("boot")  # continue the normal boot
        return 0
    finally:
        con.close()


def follow_update(con, total_timeout, idle_timeout):
    """Follow Board Init: TFTP -> swupdate modes -> reboot -> login."""
    start = time.time()
    successes, last_pct, phase = 0, -10, "download"
    patterns = [FATAL, r"(\d{1,3})%\s*\|", r"Running: swupdate with mode (\S+)",
                r"SWUPDATE successful ![^\r\n]*", r"login:", r"\[ERROR\][^\r\n]*", pexpect.TIMEOUT]
    while time.time() - start < total_timeout:
        i = con.child.expect(patterns, timeout=idle_timeout)
        m = con.child.match
        if i == 0:
            log(f"FAILED: {m.group(0).strip()}")
            return 1
        if i == 1:
            pct = int(m.group(1))
            if pct >= last_pct + 10 or (pct == 100 and last_pct != 100):
                last_pct = pct
                log(f"{phase}: {pct}%")
        elif i == 2:
            phase = m.group(1)
            log(f"swupdate mode {phase} (can be quiet for 5-10 min)")
        elif i == 3:
            successes += 1
            log(f"SWUPDATE successful ({successes})")
        elif i == 4:
            if successes:
                log("login: prompt, flash complete")
                return 0
            log("login: prompt but no swupdate ran; the board booted its old image")
            return 1
        elif i == 5:
            log(f"swupdate: {m.group(0).strip()}")
        else:
            log(f"no console output for {idle_timeout // 60} min")
            return 3
    log(f"flash did not finish in {total_timeout // 60} min")
    return 3


def cmd_flash(args):
    label = args.init_label or INIT_LABEL.get(args.machine)
    if not label:
        sys.exit(f"unknown machine {args.machine}; pass --init-label")
    con = go_to_prompt(args)
    try:
        env = con.env("board", "serverip", "ipaddr")
        if env.get("board") != args.machine:
            log(f"u-boot says board={env.get('board')!r}, expected {args.machine!r}. Not flashing.")
            con.child.sendline("boot")
            return 1
        log(f"serverip={env.get('serverip')} ipaddr={env.get('ipaddr')}")
        menu = re.findall(r"^bootmenu_\d+=([^=\r\n]+)=(.*)$", con.cmd("printenv"), re.M)
        init = dict(menu).get(label)
        if not init:
            log(f"no boot menu entry {label!r}; entries: {[m[0] for m in menu]}")
            con.child.sendline("boot")
            return 1
        log(f"Running {label!r}: {init}")
        con.child.sendline(init)
        return follow_update(con, args.timeout * 60, args.idle_timeout * 60)
    finally:
        con.close()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["detect", "flash"])
    p.add_argument("--machine", help="hailo15l-sbc | hailo15-sbc | hailo15-sbc-rev3-1 (flash)")
    p.add_argument("--init-label", help="boot menu entry to run instead of the machine default")
    p.add_argument("--tty", default=os.environ.get("H15_TTY", "/dev/ttyUSB3"))
    p.add_argument("--reset", choices=["ssh", "manual"], default="ssh")
    p.add_argument("--target", default=os.environ.get("TARGET", "root@10.0.0.1"))
    p.add_argument("--ssh-opts", default=os.environ.get("SSH_OPTS", "-o ProxyCommand=none"))
    p.add_argument("--reset-timeout", type=int, default=300, help="s to wait for u-boot after the reset")
    p.add_argument("--timeout", type=int, default=120, help="min for the whole flash")
    p.add_argument("--idle-timeout", type=int, default=20, help="min without console output")
    p.add_argument("--log", default=os.path.expanduser("~/h15_console.log"))
    args = p.parse_args()
    if args.command == "flash" and not args.machine:
        p.error("flash needs --machine")
    try:
        sys.exit({"detect": cmd_detect, "flash": cmd_flash}[args.command](args))
    except (pexpect.TIMEOUT, RuntimeError) as e:
        log(f"FAILED: {e if isinstance(e, RuntimeError) else 'timed out waiting for the console'}")
        sys.exit(3)


if __name__ == "__main__":
    main()
