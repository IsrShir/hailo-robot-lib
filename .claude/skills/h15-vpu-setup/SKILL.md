---
name: h15-vpu-setup
description: Put an H15 image (a formal Hailo VPU release such as vpu-stability-v1.13.0, or a phys-ai dev build / image folder) on the Hailo-15 board wired to a test shuttle (run on the shuttle, or remotely from a laptop over ssh) and make drone_follow_h15 --native-pipeline run on it - stage the image for TFTP, flash it from the u-boot console, build and install the runtime bundle (only what the image lacks - numpy, pyzmq, mavsdk, pyhailort, native binary), install the app, smoke-test with --dry-run. Use when the user says "set up drone follow on vpu-stability-vX.Y.Z", "flash <release> on the shuttle's board and run robot follow", "does drone follow work on the new VPU release", "set up a new H15 for drone follow", "flash the H15 / reproduce the board", or "why doesn't drone follow run on this H15".
---

# Drone-follow on an H15 image (formal VPU release or phys-ai dev build; H15L / H15H)

Background, timings, FC / SITL notes and troubleshooting: `scripts/h15_boot/VPU_SETUP_NOTES.md`.

**Arguments**
- **image**: a **release** under `ystor:/mnt/ystor/bkc/` (e.g. `vpu-stability-v1.13.0`), or an **image folder**
  `[user@host:]path` with the Board Init files (phys-ai dev build, board backup), plus where its SDK installer is.
- **shuttle**: `hailo@<ip>` (remote mode), or `local` when Claude runs on the shuttle.
- **board** (optional): `hailo15l-sbc`, `hailo15-sbc`, `hailo15-sbc-rev3-1`; detected if omitted.
- **logs** (optional, default `yes`): keep each step's output and the board/shuttle logs.

**Where things run.** Steps 1-3 (board key, detect, stage, flash) run **on the shuttle** (it has the board
link `10.0.0.2 <-> 10.0.0.1`, `tftpd-hpa` and the console). Steps 4-6 run where this repo is checked out.
- Local mode: run everything in place; start each shell with `source scripts/h15_boot/shuttle.env`.
- Remote mode (laptop): `scripts/h15_boot/vpu_remote.sh setup hailo@<ip>` once per run. It copies the shuttle
  scripts and adds the board alias `h15-<last octet>`, the `TARGET` of steps 4-6. Then run shuttle steps with
  `vpu_remote.sh run hailo@<ip> <command>` (long ones: `start <name> <command>` + `wait <name>`).
  Never source `shuttle.env` on the laptop (it points work dirs at shuttle paths).

**What needs a person:** power, cables and boot switches (eMMC on H15L, SD on H15H); allowing
`scripts/h15_boot/vpu_console.py` in Claude Code permissions (the auto-mode classifier blocks console driving);
closing their picocom if the console is busy (never kill it); a power-cycle if the board is dead; marking a CI
node offline; judging the web UI. Everything else is Claude's: sudo is passwordless on the test shuttles, and
`sshpass` handles the fresh image's `root`/`root`. If `sudo -n true` fails, give the user the printed TFTP commands.

## 0. Setup check

**Is the shuttle a CI node?** On the shuttle: `pgrep -fa '[r]emoting.jar|[a]gent.jar'; readlink /srv/tftp`.
A Jenkins agent, or `/srv/tftp` in a CI workspace → **stop and ask the user to mark the node offline** (or
confirm the shuttle is theirs). Note the `/srv/tftp` target; step 7 restores it.

Then on the shuttle, stop at the first failure:
```bash
sudo -n true && id -nG | grep -qw dialout && command -v sshpass picocom && python3 -c 'import pexpect' && echo ok
ssh -n -o BatchMode=yes "$YSTOR" true && echo ystor-ok        # only for a release
ip -br addr | grep 10.0.0.2; ping -c1 -W2 10.0.0.1
ls -l "$H15_TTY"; fuser "$H15_TTY"                            # empty = console free
```
Where steps 4-6 run: `command -v ninja unzip cmake rsync npm && python3 -c 'import venv'`, plus access to
pypi.org and github.com. No npm: install Node >= 20 user-level with nvm.

**Run logs** (logs=yes): create `RUN=$HOME/h15_vpu_runs/<image>_<machine>_<shuttle>_$(date +%Y%m%d-%H%M%S)` where
steps 4-6 run, and save every step with `set -o pipefail; <command> 2>&1 | tee "$RUN/<n>_<step>.log"`.
`pipefail` is required, or a failed step looks successful.

## 1. Detect the board (on the shuttle)

```bash
scripts/h15_boot/vpu_board_key.sh && scripts/h15_boot/vpu_detect.sh
```
`vpu_board_key.sh` installs the shuttle's board key (and, in remote mode, the laptop's) with sshpass.
- `BOARD_STATE=linux`: `MACHINE` is the board (if the user gave a different one, stop and ask). If it already
  runs the image (release: `RELEASE`; image folder: `IMAGE_NAME` vs the folder's `.uid`), skip to step 4.
- `no-ssh` / `down`: `scripts/h15_boot/vpu_console.py detect --reset manual` → `BOARD=`.

## 2. Stage the image (on the shuttle)

```bash
scripts/h15_boot/vpu_stage.sh --release <release> --machine <machine>
scripts/h15_boot/vpu_stage.sh --image-dir [user@host:]<folder> --machine <machine> [--name <label>]
```
Copies the 13 Board Init files (md5-checked) to `$H15_IMAGES/<name>/<machine>/` and points TFTP there. Keep
the printed `revert:` line. Missing files → wrong machine for this image: stop and tell the user.

## 3. Flash (on the shuttle, ~5-45 min depending on the shuttle)

```bash
scripts/h15_boot/vpu_console.py flash --machine <machine>
# remote: vpu_remote.sh start hailo@<ip> flash python3 scripts/h15_boot/vpu_console.py flash --machine <machine>
#         vpu_remote.sh wait hailo@<ip> flash           (vpu_remote.sh log ... flash for progress)
```
It reboots the board, stops at u-boot, checks `board`, runs the menu's Board Init and follows it to `login:`.
Exit 0 = flashed; 2 = console busy (ask the user); 1/3 = report the tail of `~/h15_console.log`.
`Kernel panic ... Version mismatch!` = the board's SCU firmware is newer than the image; nothing was written
and the board reboots its old image. Flash through the shuttle's CI tooling instead (needs a CI workspace):
```bash
scripts/h15_boot/vpu_ci_board_init.sh --image-dir $H15_IMAGES/<name>/<machine> --machine <machine>         # shows the command
scripts/h15_boot/vpu_ci_board_init.sh --image-dir $H15_IMAGES/<name>/<machine> --machine <machine> --run   # ~10 min
```
Show the user the command before `--run`. After a flash: `vpu_board_key.sh` again (keys are wiped), then
`vpu_detect.sh` must show the new image.

## 4. Build the runtime bundle (where the repo is)

```bash
B=${H15_WORK:-$HOME/h15_bundle_work}/<release-or-label>/<machine>/drone-follow-bundle-<release-or-label>-<machine>.tar.gz
[ -f "$B" ] || scripts/h15_boot/build_bundle.sh --release <release-or-label> --machine <machine> [--sdk-from [user@host:]<sdk.sh>]
```
A release's SDK comes from ystor; for an image folder pass `--sdk-from` (or `--sdk-dir`). It must be the SDK
the image was built with; if the user doesn't know where it is, ask. Rebuild (delete `$B`) when the app's
native code changes. On failure the log path is printed.

## 5. Install bundle + app

```bash
scripts/h15_boot/install_bundle.sh "$B" "$TARGET" --reboot     # preflight, only-missing packages, sensor, verify, reboot
SKIP_SERVICE=1 scripts/h15_boot/install.sh "$TARGET"           # UI build, app, check_board.sh
```
The preflight refuses a board whose libhailort (or kernel) differs from the bundle's. `install_bundle.sh`
prints `skip` / `install` per package (formal release: all install; phys-ai: pyzmq only), installs `cdc-acm.ko`
if the bundle carries one (v1.12.1's kernel has no USB serial driver for the FC), and returns after the board
is back up. `check_board.sh`: fix every FAIL; FC / service WARNs are fine. Install the boot service only if
the user asks: it holds the camera.

## 6. Smoke test and live view

```bash
scripts/h15_boot/vpu_run.sh smoke "$TARGET" 45
```
`--dry-run` for 45 s: web UI on `:5001`, dry-run commands (non-zero yaw = a person followed), RAM report,
stop with one SIGINT (never kill: it wedges the ISP). For the user to watch, run
`vpu_run.sh start "$TARGET" 60` (later `status` / `stop`). The UI is reachable through a tunnel via the shuttle,
`ssh -N -L 15002:10.0.0.1:5001 hailo@<shuttle-ip>`, then `http://localhost:15002`. In remote mode, start the
tunnel in the background yourself and check it returns 200. Stop the app before a smoke test or a flash.

## 7. Collect logs, restore, report

```bash
scripts/h15_boot/vpu_collect_logs.sh --run-dir "$RUN" --target "$TARGET" [--shuttle hailo@<ip>]   # logs=yes
```
Do it again after `vpu_run.sh stop`. Run `vpu_stage.sh`'s `revert:` line. If a CI node was taken offline,
remind the user to bring it back. Report: image + board (`vpu_detect.sh`), sensor, bundle manifest,
`check_board.sh`, smoke result incl. RAM, TFTP restored, where the logs are, anything skipped or failed.
