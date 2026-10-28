---
name: h15-vpu-setup
description: Put a formal Hailo VPU release (e.g. vpu-stability-v1.13.0) on the Hailo-15 board wired to a test shuttle (run on the shuttle, or remotely from a laptop over ssh) and make drone_follow_h15 --native-pipeline run on it - stage the release for TFTP, flash it from the u-boot console, build and install the runtime bundle (numpy, pyzmq, mavsdk, pyhailort, native binary), install the app, smoke-test with --dry-run. Use when the user says "set up drone follow on vpu-stability-vX.Y.Z", "flash <release> on the shuttle's board and run robot follow", or "does drone follow work on the new VPU release".
---

# Drone-follow on a formal VPU release (H15L / H15H)

Arguments: **release** (folder under `ystor:/mnt/ystor/bkc/`, e.g. `vpu-stability-v1.13.0`),
**shuttle** (`hailo@<ip>`, or `local` when Claude runs on the shuttle), optionally **board**
(`hailo15l-sbc`, `hailo15-sbc`, `hailo15-sbc-rev3-1`; detected if omitted) and **logs**
(`yes` by default: keep every step's output and the board/shuttle logs, see "Run logs" below; `no` to skip).

The **shuttle** is the host wired to the board: board link `10.0.0.2 <-> 10.0.0.1`, `tftpd-hpa`,
the board's FTDI console. Steps 1-3 (board key, detect, stage, flash) must run **on the shuttle**;
steps 4-6 (bundle, app, smoke test) run wherever this repo is checked out and reach the board over ssh.

**Local mode** (Claude Code on the shuttle, in a checkout of this repo): run everything in place,
starting every shell with `source scripts/h15_boot/shuttle.env`.

**Remote mode** (Claude on a laptop, verified 2026-10-19 with had-1067-tns): the laptop needs ssh to
the shuttle (`ssh-copy-id hailo@<shuttle>`). Then:
```bash
S=hailo@<shuttle-ip>; R=.cache/h15_vpu_setup          # scripts cache on the shuttle, refreshed every run
ssh $S "mkdir -p $R/scripts/h15_boot" && (cd scripts/h15_boot && rsync -a common.sh shuttle.env \
    vpu_stage.sh vpu_console.py vpu_board_key.sh vpu_detect.sh $S:$R/scripts/h15_boot/)
on_shuttle() { ssh -o BatchMode=yes $S "cd $R && source scripts/h15_boot/shuttle.env && $*"; }
```
and add a board alias to the laptop's `~/.ssh/config` (steps 4-6 use it as `TARGET`):
```
Host h15-<shuttle-short-name>
    HostName 10.0.0.1
    User root
    ProxyJump hailo@<shuttle-ip>
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
```
In remote mode, pass the laptop key to the board in step 1 (`EXTRA_PUBKEYS="$(cat ~/.ssh/id_ed25519.pub)"`)
and start the flash detached (step 3), or the ssh call stays open for the whole flash.

Why a formal release needs more than flashing: it has no phys-ai packagegroup, so numpy, pyzmq,
mavsdk + mavsdk_server, grpcio, protobuf and pyhailort are missing, and its HailoRT / media library
differ from what `df_native_pipeline` was built against. `build_bundle.sh` builds all of that from the
release's own SDK into one tarball, and `install_bundle.sh` unpacks it on the board (new paths only).

## What needs a person

| When | What | Why |
|---|---|---|
| Once per shuttle | Board powered, console cable on, boot switches on eMMC (H15L) / SD (H15H) | Physical |
| Once per shuttle | Allow `scripts/h15_boot/vpu_console.py` in Claude Code permissions (see Setup) | The auto-mode classifier blocks serial-console driving unless allowed |
| If the serial port is busy | Close their picocom (`Ctrl+A Ctrl+X`) | The scripts never kill another terminal |
| Board doesn't boot and isn't reachable | Power-cycle when `vpu_console.py --reset manual` asks | No software reset path |
| End | Look at the web UI through a tunnel | Only a person can judge the boxes |

Everything else is done by Claude: sudo on the shuttle is passwordless on the test shuttles, and
`sshpass` gets past the fresh image's `root`/`root` login. If `sudo -n true` fails on a shuttle, give
the user the printed TFTP commands instead.

## Setup check (step 0)

**First: is the shuttle a CI node?** Many shuttles are Jenkins agents that flash their board themselves.
```bash
pgrep -fa '[r]emoting.jar|[a]gent.jar'; readlink /srv/tftp; ls -lt /local/workspace 2>/dev/null | head -5
```
If a Jenkins agent runs or `/srv/tftp` points into a CI workspace (e.g. `/local/workspace/mercury_one_stage/image_files`),
**stop and ask the user to mark the node offline in Jenkins** (or confirm the shuttle is theirs). Otherwise a
CI job can reflash the board mid-run, or our TFTP change breaks the next CI job. Note the original `/srv/tftp`
target: it is restored at the end (step 7).

Then run and stop at the first failure:
```bash
sudo -n true && echo sudo-ok
id -nG | grep -qw dialout && echo dialout-ok
command -v sshpass picocom && python3 -c 'import pexpect'
ssh -n -o BatchMode=yes "$YSTOR" true && echo ystor-ok     # -n: don't eat the rest of a piped script
ip -br addr | grep 10.0.0.2; ping -c1 -W2 10.0.0.1
ls -l "$H15_TTY"; fuser "$H15_TTY"          # shuttle.env picks the board's FTDI by id; fuser prints nothing if free
```
Where steps 4-6 run (the shuttle in local mode, the laptop in remote mode) also check:
```bash
command -v ninja unzip cmake rsync && python3 -c 'import venv'
curl -sI https://pypi.org/simple/ | head -1; curl -sI https://github.com | head -1
command -v npm || echo "no npm: install node (below) for the UI build"
```
- No npm: `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash && . ~/.nvm/nvm.sh && nvm install 22`
  (user-level, no sudo; Vite needs Node >= 20).
- Console permission: ask the user to add to `.claude/settings.local.json` in this checkout:
  `{"permissions": {"allow": ["Bash(scripts/h15_boot/vpu_console.py:*)"]}}`

## Run logs (logs=yes, the default)

Logs are kept **on the host the skill runs on**: the shuttle in local mode, the laptop in remote mode.
At the start of the run, before step 1, create the run directory there:
```bash
RUN=${H15_RUNS:-$HOME/h15_vpu_runs}/<release>_<machine-or-unknown>_<shuttle-short-name>_$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUN"
```
Save each step's output while running it, numbered by step: `set -o pipefail; <command> 2>&1 | tee "$RUN/<step>_<name>.log"`
(**`pipefail` is required**: without it the pipeline returns tee's exit code and a failed step looks successful)
(e.g. `1_detect.log`, `2_stage.log`, `3_flash.log`, `4_bundle.log`, `5_install.log`, `6_smoke.log`). In remote
mode `on_shuttle ... | tee` saves shuttle-side output on the laptop the same way. At the end (step 7) and after
every `vpu_live.sh stop`, collect the rest from the board and shuttle (board `/tmp` is lost on reboot/reflash):
```bash
scripts/h15_boot/vpu_collect_logs.sh --run-dir "$RUN" --target "$TARGET"                      # local mode
scripts/h15_boot/vpu_collect_logs.sh --run-dir "$RUN" --target h15-<short> --shuttle hailo@<ip>   # remote mode
```
It saves `board/` (app logs `df_live.log` / `df_smoke.log`, `hailo_analytics.log`, `medialib.log`, `dmesg.txt`,
`build-info`, `os-release`, `bundle-manifest.txt`, `check_board.txt`) and `shuttle/` (`h15_flash.out`,
`h15_console.log`, the full serial console). Re-running it refreshes the same directory. Board timestamps
read 2018 (no RTC): use them as relative times. App log lines appear twice (two handlers); harmless.
With `logs=no`, skip the `tee`s, the run directory and the collect step.

## 1. Detect the board

```bash
scripts/h15_boot/vpu_board_key.sh       # creates ~/.ssh/h15_board_ed25519 and installs it (sshpass root/root); no-op if it works
scripts/h15_boot/vpu_detect.sh
# remote mode: on_shuttle "EXTRA_PUBKEYS='$(cat ~/.ssh/id_ed25519.pub)' scripts/h15_boot/vpu_board_key.sh && scripts/h15_boot/vpu_detect.sh"
```
- `BOARD_STATE=linux`: use `MACHINE` as the board (if the user also gave one and they differ, stop and ask).
  If `RELEASE` already equals the requested release, **skip to step 4**.
- `no-ssh` / `down`: `scripts/h15_boot/vpu_console.py detect --reset manual` → `BOARD=` is the machine.

## 2. Stage the release for TFTP

```bash
scripts/h15_boot/vpu_stage.sh --release <release> --machine <machine>
```
Copies the 13 Board Init files from ystor to `$H15_IMAGES/<release>/<machine>/` (md5-checked,
re-runs skip good files), points `/srv/tftp` there and restarts `tftpd-hpa`. Note the printed `revert:`
line for the report. Missing files → the release wasn't built for that machine: stop and tell the user.

## 3. Flash

```bash
scripts/h15_boot/vpu_console.py flash --machine <machine>          # run in the background
# remote mode, detached (stdin from /dev/null, or ssh stays attached until the flash ends):
on_shuttle "(nohup python3 scripts/h15_boot/vpu_console.py flash --machine <machine> > ~/h15_flash.out 2>&1 < /dev/null &)"
on_shuttle "cat ~/h15_flash.out"; on_shuttle "pgrep -f '[v]pu_console.py flash'"   # progress / still running? ([v] stops pgrep matching its own ssh command)
```
Duration depends on the shuttle's board link: **5 min on had-1067** (the `.swu` at ~6 MB/s), **~45 min on
had-1060** (~300 KB/s).
Resets the board (ssh `reboot`), stops autoboot, checks u-boot's `board` matches, runs the boot menu's
**eMMC Board Init** (H15L) / **SD Card Board Init** (H15H) command, and follows it: TFTP fitImage +
swupdate image → swupdate pulls `hailo-update-image-<machine>.swu` over TFTP → modes
`init-partitions-single`, `init-scu-bl`, `copy-a` (copy-a can be silent for minutes) → reboot → `login:`.
Exit 0 = flashed. Exit 2 = port busy (ask the user to close their terminal). Exit 1/3 = read the tail of
`~/h15_console.log` and report it. The board answers ping but refuses ssh while swupdate runs; that's normal.

After it returns 0: `scripts/h15_boot/vpu_board_key.sh` again (the flash wiped the keys; pass `EXTRA_PUBKEYS`
again in remote mode), then
`scripts/h15_boot/vpu_detect.sh` must show the requested `RELEASE`.

Never use `run update_partitions_mmc1` / `update_rootfs` for these releases: u-boot loads the whole
~2 GB rootfs into RAM and fails with `TFTP error: trying to overwrite reserved memory`.

## 4. Build the runtime bundle

```bash
B=$H15_WORK/<release>/<machine>/drone-follow-bundle-<release>-<machine>.tar.gz
[ -f "$B" ] || scripts/h15_boot/build_bundle.sh --release <release> --machine <machine>
```
First run per release/machine fetches and installs the SDK (~3 GB, several minutes), builds pyhailort
from the public `hailort` tag matching the SDK's libhailort, builds `df_native_pipeline` from `HEAD`,
and downloads cp3X aarch64 wheels. Rebuild (delete the tarball) when the app's native code changes.
If the build fails, the log path is printed; the usual cause is a new release with a HailoRT version
that has no public `hailort` tag yet. pyhailort has two build routes, picked automatically: hailort >= 5.4
(`pyproject.toml`, scikit-build-core, e.g. v1.13.0) and hailort <= 5.3 (legacy `setup.py`, e.g. v1.12.1; needs
the host venv's Python to equal the board's, 3.10). Tested: v1.13.0 (HailoRT 5.4.0) and v1.12.1 (5.3.0).
Time: SDK fetch + install ~10-20 min on first use per release/machine, then ~3 min per bundle.

## 5. Install bundle + app

```bash
scripts/h15_boot/install_bundle.sh "$B" "$TARGET" --reboot     # preflight, unpack, setup_hailo_sensor.sh, verify
# --reboot returns only after the board went down AND came back (don't add your own ssh wait:
# ssh answers for a few seconds after `reboot`, so a plain loop runs the next step on the old system)
scripts/h15_boot/build_ui.sh                                   # needs npm
scripts/h15_boot/install_app.sh "$TARGET"
scripts/h15_boot/check_board.sh "$TARGET"                      # every FAIL must be fixed; FC/service WARNs are fine
```
`install_bundle.sh` preflight refuses a board whose libhailort differs from the bundle's SDK (wrong
release on the board), so nothing is half-installed. Don't run `install.sh` or `install_pyzmq.sh` /
`install_native.sh` on a formal image: the bundle already provides those, from the right SDK.
Don't install the boot service unless the user asks: it holds the camera and would block step 6.

## 6. Smoke test

```bash
scripts/h15_boot/vpu_smoke.sh "$TARGET" 45
```
Runs `--native-pipeline --dry-run` for 45 s, checks the web UI answers on `:5001`, stops the app with one
SIGINT and reports dry-run commands (non-zero yaw = a person was followed). It never SIGKILLs the app:
that wedges the ISP until a reboot.

### Live view for the user

Start the app in the background on the board (it stops itself after the given minutes):
```bash
scripts/h15_boot/vpu_live.sh start "$TARGET" 60      # waits until the web server is up
scripts/h15_boot/vpu_live.sh status "$TARGET"        # running? last dry-run commands
scripts/h15_boot/vpu_live.sh stop "$TARGET"          # one SIGINT to the app (= Ctrl+C), waits for exit
```
The board's UI is on `10.0.0.1:5001`, reachable only from the shuttle, so the viewer tunnels through it:

| Viewer | What to run | Then open |
|---|---|---|
| Laptop where Claude runs (remote mode; WSL included) | Claude starts it in the background: `ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L 15002:10.0.0.1:5001 hailo@<shuttle-ip>`; check with `curl -s -o /dev/null -w '%{http_code}' http://localhost:15002/` → 200 | `http://localhost:15002` in the Windows/desktop browser (WSL2 forwards localhost) |
| Any other PC (MobaXterm local terminal, PowerShell, Linux shell) | `ssh -N -L 15002:10.0.0.1:5001 hailo@<shuttle-ip>` (needs the shuttle password or key) | `http://localhost:15002` |

Port taken (`bind: Address already in use`): use another local port, e.g. `-L 15003:...` and `:15003`.
After an app update press Ctrl+F5 (cached UI). Close the tunnel when done (Ctrl+C, or kill the background ssh).
Stop the app with `vpu_live.sh stop` before running `vpu_smoke.sh` or flashing again.

## 7. Collect logs, restore the shuttle, report

If logs=yes: `vpu_collect_logs.sh` (see "Run logs"). If the user is still watching the live view, collect
now and again after `vpu_live.sh stop`.

Run the `revert:` command `vpu_stage.sh` printed (puts `/srv/tftp` back, e.g. to the CI's image folder, and
restarts tftpd). If the user took a CI node offline, remind them to bring it back online when they're done
with the board; the next CI job reflashes it with its own image.

Report: release + board (`vpu_detect.sh`), sensor config, bundle manifest (`/usr/share/drone-follow/bundle-manifest.txt`),
`check_board.sh` result, smoke result, TFTP restored or not, where the run logs are (host + path), and anything
skipped or failed.

## Facts behind the steps

- Release name on a board: `VERSION` in `/etc/os-release`; exact build: `IMAGE_NAME` in `/etc/build-info`.
- Release layout on ystor: `/mnt/ystor/bkc/<release>/hailo-yocto-validation/build/tmp/deploy/{images/<machine>,sdk}`.
  The images folder holds several builds (~19 GB); only the canonical symlinks are used. ystor's login
  shell is tcsh, so the scripts send commands through `bash -s`.
- Board Init (`boot_swupdate_sdio1_only_a` / `..._sdio0_only_a`) re-partitions the boot device: everything on
  the board is lost. The u-boot env's `serverip` must be the shuttle (`10.0.0.2`).
- The swupdate image's `/sbin/init.initscripts-hailo-swupdate` runs BusyBox `tftp` without `-b` (512-byte blocks,
  one round trip each), so the `.swu` download speed depends on the link's latency: ~6 MB/s on had-1067, ~300 KB/s
  on had-1060. The server can't raise the block size; an image fix can (`tftp -b 65464`).
- `isp_media_server` always holds `/dev/video0` on these images; the app runs alongside it. Anything else on
  `/dev/video0` (an old app, the drone-follow service) blocks the camera.
- Console port: the board's own FTDI shows up as `/dev/serial/by-id/usb-FTDI_SBC_H15L_...` (or `SBC_H15H`);
  its `ttyUSB` number varies with other adapters on the shuttle.
- ssh keeps the first value of each `-o` option, so overrides go before `$SSH_OPTS`.
- `setup_hailo_sensor.sh` (in the image) detects 15L/15H and the IMX sensor; the image default points
  `medialib_configs` at hailo15h/imx678. The media server reads it at boot, hence `--reboot`.
- A hard kill of the app leaves the ISP stuck (`post event failed` in dmesg, black video): reboot to recover.
- The phys-ai dev image (`.claude/skills/h15-board-setup`) is the other route: everything is in the image, no bundle.

## Long-term: make formal images drone-ready (no bundle, faster flash)

Image changes to propose for the release builds (meta-hailo-bsp / hailo-yocto-validation):
1. `packagegroup-hailo-phys-ai` (mavsdk-server, python3-mavsdk, grpcio, protobuf, pyhailort) in the
   formal `core-image-hailo-dev`, plus `python3-pyzmq` (branch `PAI-add-pyzmq-to-phys-ai`) and
   `python3-numpy`, which the phys-ai image got only indirectly.
2. `tftp -b 65464` in `init.initscripts-hailo-swupdate` (Board Init download on high-latency links, e.g.
   ~35 min on had-1060, → ~1-3 min).
With 1 in place, steps 4-5 shrink to `install_app.sh`; `build_bundle.sh` is still needed for the native
binary unless it ships too.
