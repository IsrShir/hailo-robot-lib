# h15-vpu-setup: reference notes

Background for `.claude/skills/h15-vpu-setup/SKILL.md`, which keeps only the steps.

## Why an image needs more than flashing

`df_native_pipeline` must be built against the image's own media library, and no image has pyzmq.
A formal VPU release also lacks the phys-ai packagegroup (numpy, mavsdk + mavsdk_server, grpcio,
protobuf, pyhailort); a phys-ai dev build has those. `build_bundle.sh` builds everything from the
image's SDK into one tarball (~41 MB); `install_bundle.sh` installs only the packages the image lacks
(decided per package with `importlib.util.find_spec` on the board), plus the native binary, and
records what it installed in `/usr/share/drone-follow/bundle-installed.txt`.

- pyhailort is built from the public `hailort` tag matching the SDK's libhailort. Two routes, picked
  automatically: hailort >= 5.4 (`pyproject.toml`, scikit-build-core) and <= 5.3 (legacy `setup.py`,
  needs the host Python to equal the board's, 3.10). Tested with v1.13.0 (5.4.0) and v1.12.1 (5.3.0).
- mavsdk is 2.8.4: the last 2.x on PyPI (2.12 is a Yocto build from git), protobuf-3 compatible, and it
  ships `mavsdk_server` 2.12.10. 3.x needs protobuf >= 5; 4.x drops mavsdk_server / gRPC (different API).
- Phys-ai dev images (`kas/CI/hailo15l-sbc-vpu-phys-ai.yml`, or `PHYS_AI_SUPPORT`) put `mavsdk_server`
  in `/usr/bin` (the app falls back to `PATH`). Their `python3-mavsdk` 2.12 imports
  `google.protobuf.runtime_version`, missing from their protobuf 3.20; `drone_follow_h15.py` stubs it.
  Their source revisions are in the image: `/etc/hailo-rev/` (kas yml, layer commits, srcrevs).
- Time: SDK fetch + install ~10-20 min on first use per image/machine, then ~3 min per bundle.

## Flashing

- Board Init (u-boot boot menu, `boot_swupdate_sdio1_only_a` on eMMC / `..._sdio0_only_a` on SD)
  re-partitions the boot device: everything on the board is lost. The u-boot env's `serverip` must be
  the shuttle (`10.0.0.2`). It TFTPs fitImage + the swupdate image, boots it, and swupdate pulls
  `hailo-update-image-<machine>.swu`, then runs `init-partitions-single`, `init-scu-bl`, `copy-a`.
- Never `run update_partitions_mmc1` / `update_rootfs`: u-boot loads the whole ~2 GB rootfs into RAM and
  fails with `TFTP error: trying to overwrite reserved memory`.
- The swupdate image runs BusyBox `tftp` without `-b` (512-byte blocks, one round trip each), so the
  `.swu` download speed depends on the board link: ~6 MB/s on had-1067 (flash ~5 min), ~300 KB/s on
  had-1060 (~45 min). The server can't raise the block size; an image fix can (`tftp -b 65464`).
- **SCU firmware newer than the image** (normal on CI shuttles, whose boards run recent develop builds):
  Board Init's kernel panics with `Kernel panic - not syncing: Version mismatch!`
  (`arm-scmi: Firmware version mismatch: linux(kernel)=0x..., fw=0x...`) before writing anything, and the
  board reboots its old image ~10 s later. Seen on had-1321 (board `fw=0x330001`, v1.13.0 wants
  `0x320001`). The fix is what every CI job does: burn SCU firmware, SCU bootloader and u-boot over UART
  recovery, then Board Init: `vpu_ci_board_init.sh` runs the shuttle's CI `setup_preparation.py
  EMMC_BOARD_INIT` with the board flags of the latest CI job and the staged image. ~10 min on had-1321
  (UART burn ~3.5 min, then Board Init; ends with `MBIST: all domains passed`). Check afterwards on the
  board: `dmesg | grep 'SCMI.*Firmware version'`.
- Console: the board's own FTDI is `/dev/serial/by-id/usb-FTDI_SBC_H15L_...` (or `SBC_H15H`); debug
  boards show a quad FTDI (`FTDI_Quad_RS232-HS`) whose port 3 (`ttyUSB3`) is the A53 console.
- ssh keeps the first value of each `-o` option, so overrides go before `$SSH_OPTS`.

## On the board

- Release name: `VERSION` in `/etc/os-release` (dev builds: `develop`); exact build: `IMAGE_NAME` /
  `IMAGE_UID` in `/etc/build-info`.
- `setup_hailo_sensor.sh` detects 15L/15H and the IMX sensor; the image default points
  `medialib_configs` at hailo15h/imx678. The media server reads it at boot, hence the reboot.
- `isp_media_server` always holds `/dev/video0`; the app runs alongside it. Anything else on it (an old
  app, the drone-follow service) blocks the camera.
- A hard kill of the app leaves the ISP stuck (`post event failed` in dmesg, black video): reboot.
- Memory (v1.13.0 H15L): 1.9 GB total, 1.28 GB CMA, 160-210 MB free outside CMA while the app runs.
  A board left with a few tens of MB can pass a 45 s run and still hang minutes later.
- Logs: the service writes `/var/log/drone-follow.log` (with the `[CMD]` FC lines) to RAM: lost on
  reboot. Board timestamps read 2018 (no RTC); app log lines appear twice (two handlers).
- Release layout on ystor (`hailo@192.168.12.21`, tcsh login shell, so scripts use `bash -s`):
  `/mnt/ystor/bkc/<release>/hailo-yocto-validation/build/tmp/deploy/{images/<machine>,sdk}`; the images
  folder holds several builds (~19 GB); only the canonical symlinks are used.

## Real flight controller, SITL

- **Real FC:** `--serial /dev/ttyACM0` (USB). PX4 and ArduPilot both work: the app waits for OFFBOARD,
  and MAVSDK reports ArduCopter **GUIDED as OFFBOARD** (offboard control drives GUIDED). Without
  `--takeoff-landing` the app never arms and never changes mode; `--auto-offboard` sets the mode itself
  (bench / SITL only). ArduCopter refuses GUIDED without a position estimate (indoors, no GPS).
- **Boot service:** args in `/etc/default/drone-follow`, then `/etc/init.d/drone-follow restart`.
- **PX4 SITL** (host with PX4 `main` + Gazebo Harmonic that reaches the board's link): add to
  `build/px4_sitl_default/etc/init.d-posix/airframes/4005_gz_x500_vision.post`:
  `mavlink start -x -u 14590 -o 14540 -t 10.0.0.1 -r 4000000`; run `HEADLESS=1 make px4_sitl gz_x500_vision`
  (stop with `shutdown` at `pxh>`, not Ctrl+C); on the board, no `--serial`:
  `python3 -m robot_follow.drone_follow_h15 --native-pipeline --takeoff-landing --auto-offboard`.
  `Preflight Fail: No connection to the GCS` until the app connects (`mavlink status` at `pxh>`).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `native pipeline exited immediately with code -9` | Binary must be named `df_native_pipeline`; camera busy: `/etc/init.d/drone-follow stop`, `fuser /dev/video0` (`isp_media_server` on it is normal) |
| `ModuleNotFoundError: zmq` | Bundle not installed (step 5) |
| `mavsdk_server not found` | No bundle on a formal image, or old app code without the `PATH` fallback |
| Waits forever for OFFBOARD | Nobody switched the mode (GCS: OFFBOARD on PX4, GUIDED on ArduPilot), or GUIDED refused for lack of position |
| `Version mismatch!` kernel panic during Board Init | SCU firmware newer than the image: `vpu_ci_board_init.sh` (step 3) |
| Board dates are 2018 | No RTC/NTP; expected |
| Ping works, ssh drops, EXT4 I/O errors on console | Failing SD/eMMC: re-flash or replace the card |
| No LEDs, PWR button does nothing | Hardware/power fault |

## Long-term: drone-ready formal images (no bundle, faster flash)

Image changes to propose for the release builds (meta-hailo-bsp / hailo-yocto-validation):
1. `packagegroup-hailo-phys-ai` (mavsdk-server, python3-mavsdk, grpcio, protobuf, pyhailort) in the formal
   `core-image-hailo-dev`, plus `python3-pyzmq` (branch `PAI-add-pyzmq-to-phys-ai`) and `python3-numpy`.
2. `tftp -b 65464` in `init.initscripts-hailo-swupdate` (Board Init download on slow links ~35 min → ~1-3 min).

With 1 in place, `install_bundle.sh` installs only the native binary; it still has to be built per image.
