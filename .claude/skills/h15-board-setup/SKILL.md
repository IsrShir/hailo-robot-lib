---
name: h15-board-setup
description: Bring up a Hailo-15 (H15L/H15H SBC) board to run drone_follow_h15 — image requirements, flashing over u-boot TFTP, sensor setup, install scripts, board check, first run, SITL. Use when the user says "set up a new H15 for drone follow", "flash the H15", "the H15 board died / reproduce the board", or "why doesn't drone follow run on this H15".
---

# H15 board bring-up for drone-follow

Goal: a board that passes `scripts/h15_boot/check_board.sh` and shows boxes in the web UI
(`http://<board>:5001/`) with `python3 -m robot_follow.drone_follow_h15 --native-pipeline --dry-run`.

Work in this order and stop at the first failure. Prefer giving the user commands for anything
that touches the board's console or flash; let them run it unless they ask you to.

## 0. Pre-checks (host)

```bash
ping -c1 10.0.0.1                              # board link (host side is usually 10.0.0.2)
ssh -o ProxyCommand=none root@10.0.0.1 true    # password: root
```
- If plain `ssh` fails with `kex_exchange_identification` / `sss_ssh_knownhostsproxy`, the host proxies ssh
  through SSSD: use `-o ProxyCommand=none`, and `SSH_OPTS="-o ProxyCommand=none"` for the h15_boot scripts.
- Several boards share 10.0.0.1, so host keys clash: add `-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no`.
- If the board is already flashed, skip to step 3 and run `check_board.sh`. It tells you what's missing.

## 1. Image

Required: **`core-image-hailo-dev`** built with the **phys-ai** kas config. A normal image lacks mavsdk.
- `hailo-yocto-validation` branch `develop`, kas `kas/CI/hailo15l-sbc-vpu-phys-ai.yml`
  (H15 rev3.1: `hailo15-sbc-rev3-1-vpu-phys-ai.yml`; or Kconfig `PHYS_AI_SUPPORT`).
- `meta-hailo-bsp` branch `kirkstone-develop`: layer `meta-hailo-phys-ai`. Its
  `core-image-hailo-dev.bbappend` adds `packagegroup-hailo-phys-ai`
  (mavsdk-server, python3-mavsdk, pymavlink, pyserial, pyhailort).
- Known image gaps that `install.sh` covers: no pyzmq (install_pyzmq.sh), mavsdk_server is in `/usr/bin`
  instead of `mavsdk/bin` (the app falls back to PATH). Also known: python3-protobuf is 3.x while python3-mavsdk
  expects `runtime_version`; `drone_follow_h15.py` stubs it at startup.

Ask the user for the image folder if one exists. It needs `fitImage`, `core-image-hailo-dev-<machine>.ext4`,
`u-boot-tfa.itb`, `swupdate-image-<machine>.ext4.gz`, `u-boot-spl.bin`, `u-boot-initial-env`, SCU bins
and the certificate. Check `/srv/tftp`: it is often a symlink to the last flashed image folder.

## 2. Flash (eMMC over TFTP from u-boot)

Host: `tftpd-hpa` serving `/srv/tftp` → `sudo ln -sfn <image_folder> /srv/tftp`, host IP on the board link `10.0.0.2/24`.

Bootloaders (only if the board's u-boot is old or has no `update_partitions_mmc1`): mercury_validation
`internals/tools/hailo15_platform_manager`. Copy `hailo15_platform_config_example.ini` to `hailo15_platform_config.ini`
and set platform (e.g. `H15L_SBC_DEBUG_BOARD`), `hailo15_version`, `yocto_machine_name` and `deploy=<image_folder>`.
Then run `board_update_uart` (or `board_update`) inside `mercury_venv`.

Linux. The user does this on the A53 console (debug board: FT4232H port 3, e.g. `picocom -b 115200 /dev/ttyUSB3`):
press a key to stop autoboot, then
```
printenv core_image_name board serverip ipaddr   # expect core-image-hailo-dev / <machine> / 10.0.0.2 / 10.0.0.1
setenv core_image_name core-image-hailo-dev      # only if different
run update_partitions_mmc1                       # u-boot, fitImage, swupdate image, rootfs -> eMMC (minutes)
run boot_mmc1
```
Nothing drone-specific is needed at flash time. Bootstrap switches must select eMMC boot.

## 3. Board setup + install (host repo)

```bash
ssh root@10.0.0.1 setup_hailo_sensor.sh                       # once; pick the board's sensor/lens/resolution
(cd robot_follow/native_pipeline && ./build.sh)               # needs the Hailo Yocto SDK at /opt/poky/<ver>
SSH_OPTS="-o ProxyCommand=none" scripts/h15_boot/install.sh root@10.0.0.1
```
`install.sh` = build UI, app, native binary, pyzmq, service (it keeps existing `/etc/default/drone-follow`),
then `check_board.sh`. Fix every FAIL before going on. WARNs about the FC or service args are fine for bench tests.

## 4. First run

```bash
ssh root@10.0.0.1
/etc/init.d/drone-follow stop          # the service holds the camera
cd /home/root && python3 -m robot_follow.drone_follow_h15 --native-pipeline --dry-run
```
Web UI: `http://10.0.0.1:5001/`. From another machine, tunnel: `ssh -N -L 15001:10.0.0.1:5001 <user>@<host>`.
Dry-run commands go to the console and to `~/fc_command_logs/` (if the branch has `--cmd-log`).

Real FC: `--serial /dev/ttyACM0` (USB). The app is written for **PX4** (waits for OFFBOARD). An **ArduPilot**
FC (`GUIDED` mode, no OFFBOARD) will wait forever. Check which firmware the FC runs before blaming the app.
Boot service args: `/etc/default/drone-follow`, then `/etc/init.d/drone-follow restart`. Log: `/var/log/drone-follow.log`
(cleared on reboot).

## 5. SITL instead of a real FC

Host with PX4 `main` + Gazebo Harmonic. Add a MAVLink stream to the board in
`build/px4_sitl_default/etc/init.d-posix/airframes/4005_gz_x500_vision.post`:
`mavlink start -x -u 14590 -o 14540 -t 10.0.0.1 -r 4000000`. Then:
```bash
HEADLESS=1 make px4_sitl gz_x500_vision                       # host; stop with `shutdown` at pxh>, not Ctrl+C
python3 -m robot_follow.drone_follow_h15 --native-pipeline --takeoff-landing --auto-offboard   # board, no --serial
```
`Preflight Fail: No connection to the GCS` until the board app connects; check `mavlink status` at `pxh>`.
Gazebo window over ssh X forwarding: `GZ_IP=127.0.0.1`, `GZ_SIM_RESOURCE_PATH=<PX4>/Tools/simulation/gz/models:<PX4>/Tools/simulation/gz/worlds`,
`LIBGL_ALWAYS_SOFTWARE=1 gz sim -g` (add `--render-engine ogre` if the window is black).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `native pipeline exited immediately with code -9` | Binary must be named `df_native_pipeline`; camera busy: `/etc/init.d/drone-follow stop`, `fuser /dev/video0` |
| `ModuleNotFoundError: zmq` | `scripts/h15_boot/install_pyzmq.sh` |
| `mavsdk_server not found` | Image not phys-ai, or old app code without the PATH fallback |
| Waits forever for OFFBOARD | No GCS switched mode (use `--auto-offboard` on the bench/SITL only), or the FC runs ArduPilot |
| Board dates are 2018 | No RTC/NTP; expected, don't trust board timestamps |
| Ping works, ssh drops, EXT4 I/O errors on console | Failing SD/eMMC: re-flash or replace the card |
| No LEDs, PWR button does nothing | Hardware/power fault; nothing to do in software |
