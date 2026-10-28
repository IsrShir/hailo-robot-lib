---
name: h15-vpu-setup
description: Put an H15 image (a formal Hailo VPU release such as vpu-stability-v1.13.0, or a phys-ai dev build / image folder) on the Hailo-15 board wired to a test shuttle (run on the shuttle, or remotely from a laptop over ssh) and make drone_follow_h15 --native-pipeline run on it - stage the image for TFTP, flash it from the u-boot console, build and install the runtime bundle (only what the image lacks - numpy, pyzmq, mavsdk, pyhailort, native binary), install the app, smoke-test with --dry-run. Use when the user says "set up drone follow on vpu-stability-vX.Y.Z", "flash <release> on the shuttle's board and run robot follow", "does drone follow work on the new VPU release", "set up a new H15 for drone follow", "flash the H15 / reproduce the board", or "why doesn't drone follow run on this H15".
---

# Drone-follow on an H15 image (formal VPU release or phys-ai dev build; H15L / H15H)

Arguments: **image**, one of
- a **release**: folder under `ystor:/mnt/ystor/bkc/`, e.g. `vpu-stability-v1.13.0` (formal VPU release), or
- an **image folder** `[user@host:]path` holding the Board Init files, e.g. a phys-ai dev build or a board backup
  (`hailo@10.41.75.21:/local/users/h15l_reference_backup/image_files`), plus where its SDK installer is
  (step 4; formal releases have theirs on ystor);

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
Never source `shuttle.env` on the laptop: it points `H15_WORK` / `H15_IMAGES` at shuttle paths (`/local/...`)
and `build_bundle.sh` fails with `mkdir: cannot create directory '/local'`. On the laptop the bundle goes
to `~/h15_bundle_work` (step 4's default).

Why an image needs more than flashing: `df_native_pipeline` must be built against the image's own media
library, and no image has pyzmq. A formal release also lacks the phys-ai packagegroup (numpy, mavsdk +
mavsdk_server, grpcio, protobuf, pyhailort); a phys-ai dev build has those. `build_bundle.sh` builds all of
it from the image's SDK into one tarball; `install_bundle.sh` installs on the board **only the packages the
image lacks** (so a phys-ai image keeps its own mavsdk, numpy, pyhailort) plus the native binary.

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
It saves `board/` (`drone-follow.log`: the service's log with the `[CMD]` FC lines, in RAM, so lost on reboot;
app logs `df_live.log` / `df_smoke.log`, `hailo_analytics.log`, `medialib.log`, `dmesg.txt`,
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
  If the board already runs the requested image, **skip to step 4**: for a release, `RELEASE` equals it; for an
  image folder, `IMAGE_NAME` matches the folder's `core-image-hailo-dev-<machine>.uid` / build (dev builds set
  `RELEASE=develop`, so compare the image, not the name).
- `no-ssh` / `down`: `scripts/h15_boot/vpu_console.py detect --reset manual` → `BOARD=` is the machine.

## 2. Stage the image for TFTP

```bash
scripts/h15_boot/vpu_stage.sh --release <release> --machine <machine>
scripts/h15_boot/vpu_stage.sh --image-dir [user@host:]<folder> --machine <machine> [--name <label>]   # image folder
```
Copies the 13 Board Init files from ystor (or the folder; read access is enough) to
`$H15_IMAGES/<release-or-label>/<machine>/` (md5-checked against the source, re-runs skip good files),
points `/srv/tftp` there and restarts `tftpd-hpa`. Note the printed `revert:` line for the report. Missing
files → the image wasn't built for that machine: stop and tell the user. The source must be reachable from
the shuttle; if it isn't, copy the folder to the shuttle first and pass the local path.

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
`FAILED: Kernel panic - not syncing: Version mismatch!` (with `arm-scmi: Firmware version mismatch:
linux(kernel)=0x..., fw=0x...` in the console log) = the board's SCU firmware is newer than the release:
see 3a. Nothing was written yet, and the board resets itself ~10 s after the panic and boots its old
image again: no power-cycle needed.

### 3a. SCU firmware newer than the release (CI shuttles)

Board Init can't change the SCU firmware before its own kernel boots, and that kernel refuses a newer
one. CI nodes leave the board on a recent develop build, so any formal release hits this there
(seen 2026-10-28 on had-1321: board `fw=0x330001`, v1.13.0 kernel wants `0x320001`). The fix is what every
CI job on the shuttle does anyway: burn the SCU firmware, SCU bootloader and u-boot over UART recovery,
then run Board Init. Use CI's own script, fed with the files staged in step 2 (CI's `image_files` stays
untouched); the next CI job burns its own firmware again.

Take the flags from the shuttle's latest CI job, so they match its board:
```bash
on_shuttle "cat \$(ls -td /local/workspace/*/results_dir/*/setup_preparation_logs | head -1)/setup_preparation_cmd.txt"
```
Keep its `--use-uart-recovery --platform-type ... --scu-fw-flavor ... --uboot-source ... --recovery-device ...
--emmc-boot-partition ... --emmc-bit-mode ...`; replace `--yocto-remote-path`, `--clean-image-files` and
`--builder-ip` with `--image-files-path`. On had-1321 (H15L) that gave, run detached:
```bash
on_shuttle "mkdir -p ~/h15_ci_prep && cd /local/workspace/mercury_one_stage && (nohup mercury_venv/bin/python3 \
  setup_preparation.py --results-dir \$HOME/h15_ci_prep EMMC_BOARD_INIT \
  --image-files-path \$H15_IMAGES/<release>/<machine> --yocto-machine-name <machine> --use-uart-recovery \
  --platform-type H15L_SBC_ON_BOARD --scu-fw-flavor hailo15l --uboot-source mmc2_boot --recovery-device sdio1 \
  --emmc-boot-partition 0 --emmc-bit-mode 4 > \$HOME/h15_ci_prep/run.out 2>&1 < /dev/null &)"
on_shuttle "tail -5 ~/h15_ci_prep/run.out"; on_shuttle "pgrep -f '[s]etup_preparation.py'"   # progress / still running?
```
~10 min on had-1321: UART burn ~3.5 min (`Programming ...` / `Storage program validatation passed` per file),
then Board Init (`Running Command run boot_swupdate_sdio1_only_a`, swupdate modes, `login:`); ends with
`MBIST: all domains passed`. It points `/srv/tftp` at the staged folder itself; step 7's revert still applies.
Save `run.out` as `3_flash.log` in the run directory. Then `vpu_board_key.sh` + `vpu_detect.sh` as below;
`dmesg | grep 'SCMI.*Firmware version'` on the board shows the SCU firmware it now runs. This needs the
CI workspace on the shuttle; on a shuttle without one, stop and tell the user.

After it returns 0: `scripts/h15_boot/vpu_board_key.sh` again (the flash wiped the keys; pass `EXTRA_PUBKEYS`
again in remote mode), then
`scripts/h15_boot/vpu_detect.sh` must show the requested `RELEASE`.

Never use `run update_partitions_mmc1` / `update_rootfs` for these releases: u-boot loads the whole
~2 GB rootfs into RAM and fails with `TFTP error: trying to overwrite reserved memory`.

## 4. Build the runtime bundle

```bash
B=${H15_WORK:-$HOME/h15_bundle_work}/<release>/<machine>/drone-follow-bundle-<release>-<machine>.tar.gz
[ -f "$B" ] || scripts/h15_boot/build_bundle.sh --release <release> --machine <machine>
# image folder: <release> is just a label; give the image's SDK installer (or an installed SDK with --sdk-dir), e.g.
#   --sdk-from hailo@10.41.75.21:/local/users/sdk/poky-glibc-x86_64-core-image-hailo-dev-armv8a-hailo15l-sbc-toolchain-4.0.23.sh
```
The SDK must be the one the image was built with: `install_bundle.sh` refuses a board whose libhailort
differs from the SDK's. If the user doesn't know where an image's SDK is, ask; don't guess.
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
SKIP_SERVICE=1 scripts/h15_boot/install.sh "$TARGET"           # UI build (npm), app, check_board.sh
```
`install_bundle.sh` preflight refuses a board whose libhailort differs from the bundle's SDK (wrong
image on the board), so nothing is half-installed. It prints `skip` / `install` per package: on a formal
release everything installs; on a phys-ai image only pyzmq (and the native binary) should. It records what it
installed in `/usr/share/drone-follow/bundle-installed.txt`; a later bundle removes only those.
`check_board.sh`: every FAIL must be fixed; FC / service WARNs are fine.
Don't install the boot service (`install_service.sh`) unless the user asks: it starts at boot, holds the
camera and would block step 6.

## 6. Smoke test

```bash
scripts/h15_boot/vpu_smoke.sh "$TARGET" 45
```
Runs `--native-pipeline --dry-run` for 45 s, checks the web UI answers on `:5001`, stops the app with one
SIGINT and reports dry-run commands (non-zero yaw = a person was followed). It never SIGKILLs the app:
that wedges the ISP until a reboot. It also reports the board's RAM and the lowest free memory outside
CMA while the app ran (on v1.13.0 H15L: 1.9 GB total, 1.28 GB CMA, 160-210 MB free). Put it in the report; a board left
with only a few tens of MB can pass the 45 s run and still hang minutes later.

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
- Phys-ai dev images (`kas/CI/hailo15l-sbc-vpu-phys-ai.yml`, or `PHYS_AI_SUPPORT`) ship the drone packages but
  not pyzmq, and put `mavsdk_server` in `/usr/bin` (the app falls back to `PATH`). Their `python3-mavsdk` 2.12
  imports `google.protobuf.runtime_version`, which their protobuf 3.20 lacks; `drone_follow_h15.py` stubs it.
  Their source revisions are in the image itself: `/etc/hailo-rev/` (kas yml, layer commits, srcrevs).
- mavsdk in the bundle is 2.8.4: the last 2.x on PyPI (2.12 is a Yocto build from git), protobuf-3 compatible,
  and it ships `mavsdk_server` 2.12.10. 3.x needs protobuf >= 5; 4.x drops mavsdk_server/gRPC (different API).

## Real flight controller, SITL

- **Real FC:** `--serial /dev/ttyACM0` (USB). PX4 and ArduPilot both work: the app waits for OFFBOARD, and
  MAVSDK reports ArduCopter **GUIDED as OFFBOARD** (offboard control drives GUIDED). Without `--takeoff-landing`
  the app never arms and never changes mode; `--auto-offboard` sets the mode itself (bench / SITL only).
  ArduCopter refuses GUIDED without a position estimate (indoors, no GPS).
- **Boot service:** args in `/etc/default/drone-follow`, then `/etc/init.d/drone-follow restart`;
  log `/var/log/drone-follow.log` (RAM, cleared on reboot: copy it off after a flight).
- **PX4 SITL** (host with PX4 `main` + Gazebo Harmonic that reaches the board's link): add a MAVLink stream to the
  board in `build/px4_sitl_default/etc/init.d-posix/airframes/4005_gz_x500_vision.post`:
  `mavlink start -x -u 14590 -o 14540 -t 10.0.0.1 -r 4000000`, then `HEADLESS=1 make px4_sitl gz_x500_vision`
  (stop with `shutdown` at `pxh>`, not Ctrl+C) and on the board, no `--serial`:
  `python3 -m robot_follow.drone_follow_h15 --native-pipeline --takeoff-landing --auto-offboard`.
  `Preflight Fail: No connection to the GCS` until the app connects (`mavlink status` at `pxh>`).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `native pipeline exited immediately with code -9` | Binary must be named `df_native_pipeline`; camera busy: `/etc/init.d/drone-follow stop`, `fuser /dev/video0` (`isp_media_server` on it is normal) |
| `ModuleNotFoundError: zmq` | Bundle not installed: step 5 |
| `mavsdk_server not found` | No bundle on a formal image, or old app code without the `PATH` fallback |
| Waits forever for OFFBOARD | Nobody switched the mode (GCS: OFFBOARD on PX4, GUIDED on ArduPilot), or GUIDED refused for lack of position |
| Board dates are 2018 | No RTC/NTP; expected, don't trust board timestamps |
| Ping works, ssh drops, EXT4 I/O errors on console | Failing SD/eMMC: re-flash or replace the card |
| No LEDs, PWR button does nothing | Hardware/power fault; nothing to do in software |

## Long-term: make formal images drone-ready (no bundle, faster flash)

Image changes to propose for the release builds (meta-hailo-bsp / hailo-yocto-validation):
1. `packagegroup-hailo-phys-ai` (mavsdk-server, python3-mavsdk, grpcio, protobuf, pyhailort) in the
   formal `core-image-hailo-dev`, plus `python3-pyzmq` (branch `PAI-add-pyzmq-to-phys-ai`) and
   `python3-numpy`, which the phys-ai image got only indirectly.
2. `tftp -b 65464` in `init.initscripts-hailo-swupdate` (Board Init download on high-latency links, e.g.
   ~35 min on had-1060, → ~1-3 min).
With 1 in place, steps 4-5 shrink to `install_app.sh`; `build_bundle.sh` is still needed for the native
binary unless it ships too.
