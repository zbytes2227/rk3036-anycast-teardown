# RK3036 AnyCast Dongle — Firmware Dump & Reverse Engineering

Reverse engineering notes, full firmware backup, and analysis of a cheap
**AnyCast-branded HDMI wireless display dongle** built on the Rockchip RK3036
SoC. Goal: understand the stock firmware, get root access, back up the
complete flash chip, and explore turning the device into something more
custom — ideally a network-controlled HDMI display — without bricking it.

> ⚠️ **Status: research/backup phase complete. No firmware has been modified
> or reflashed yet.** Everything below "Confirmed Findings" is what's been
> actually tested and verified. The "Proposed Next Steps" section contains
> ideas that are **untested hypotheses**, not completed work — flagged
> explicitly so nobody mistakes a plan for a result.

---

<img width="1280" height="591" alt="image" src="https://github.com/user-attachments/assets/cdb06d0c-b013-497d-a9c3-06ab9426d474" />


## Hardware

| Component | Chip | Notes |
|---|---|---|
| SoC | Rockchip RK3036G | Dual-core ARM Cortex-A7 |
| WiFi | SV6051P (TAB1839) | `ssv6xxx` driver in Linux |
| RAM | Samsung K4T1G1... | DDR |
| Regulator | AAAS1117 3.3 | 3.3V LDO |
| Flash | Unconfirmed part number | 16MB total (see partition table below) |
| PCB marking | `FMD 7573S VER 3.3` | |

A tactile button on the PCB doubles as a Maskrom-recovery trigger (see below).

### Related prior work
- [`yuvadm/rockcast`](https://github.com/yuvadm/rockcast) — same SoC family,
  dumped flash via Bus Pirate + flashrom, documented OTA URL pattern and
  binwalk analysis of `update.img`.
- LabFruits blog, "AirPlay mirroring with cheap HDMI dongles" — same SoC,
  found UART pads, captured a full boot log at 115200 baud including a
  `fiq debugger` prompt.

---

## Confirmed Findings

### 1. Getting root access (no soldering required)

1. Device broadcasts its own WiFi AP: SSID pattern `LOLLIPOP-XXXXXX`.
   Default password: **`12345678`** (confirmed against official Rockchip
   RK2928/RK3036 wireless dongle manuals — this is a documented default,
   not a guess).
2. Connect to that AP, browse to `http://192.168.49.1` — a `boa`-served web
   config UI (`settings.cgi`, `home.cgi`, `media_control.cgi`, etc.) is
   exposed.
3. `http://192.168.49.1/cgi-bin/debug.cgi` silently enables **ADB over TCP**
   on port 5555.
4. Connect:
   ```bash
   adb connect 192.168.49.1:5555
   adb shell
   id   # uid=0(root) — instant root, no exploit needed
   ```
   This is an insecure "eng" build (`ro.secure=0`, `ro.debuggable=1`,
   SELinux permissive, test-keys) — effectively an unlocked dev unit.
5. The device is **dual-homed**: it's also joined to the home WiFi router
   (`wlan0`) in addition to running its own AP (`p2p0`). This means once
   it's on your LAN, `adb connect <lan-ip>:5555` works directly — no need
   to rejoin the soft-AP each session.

### 2. Software stack

- Kernel: Linux 3.10.0, ARMv7 (bionic libc, not glibc)
- Userspace: Android 5.1.1 (API 22), heavily stripped — **no `pm`, no
  `dumpsys`, no app framework/Zygote**. Only native C/C++ daemons run; APKs
  cannot be installed.
- Web server: `boa`, config at `/system/etc/boa/boa.conf`.
  `ScriptAlias /cgi-bin/ -> /system/bin/` — all `.cgi` "scripts" are
  actually native ARM ELF binaries.
- Native services: `airserver` (AirPlay), `rk_dlna_dmr` (DLNA), `lollipop` /
  `lollipop_softap` (core Miracast/casting + AP management), `mediaserver`,
  `surfaceflinger`, `netd`, `wpa_supplicant`, `hostapd`, `dnsmasq`.
- `playUrl.cgi` calls `/system/bin/mediaplayertest`, which **does not exist**
  on this firmware build — that path is a dead end as shipped.
- `avtest` is a real Stagefright/MediaCodec-based native player. Confirmed
  it successfully initializes the Rockchip hardware AVC decoder and
  correctly detects the display (1280x720 @ 60fps) — the hardware video
  pipeline is alive. It segfaults on a NULL `FILE*` when given a
  nonexistent path (unvalidated `fopen()`), which is **not proof the
  player itself is broken** — it was never tested against a real file.
- `libffmpeg.so` / `librkffplayer.so` also ship in `/system/lib` — an
  alternate playback path, unexplored.

### 3. Storage — hard limit, confirmed from `/proc/mtd`

```
mtd0: loader   256 KB
mtd1: kernel   4 MB
mtd2: data     768 KB   (~480KB free, persistent, jffs2)
mtd3: system   ~11.1 MB (100% full, squashfs, read-only)
mtd4: misc     128 KB   (bootloader scratch, not usable)
```
Total = 16MB, matching the flash chip size documented for the sibling
`rockcast` device. **There is no hidden/unallocated flash space anywhere on
this chip.** No custom file of meaningful size (video, image, binary) can
be stored permanently without either replacing the flash chip or streaming
content live instead of storing it.

### 4. Full firmware backup

Two independent recovery paths were confirmed:

- **ADB root shell dump** (primary method used): the on-device `toolbox` is
  extremely minimal — no `dd`, `grep`, `df`, `pm`, or `dumpsys`. `cat` on
  the raw block devices works fine:
  ```bash
  adb -s <ip>:5555 exec-out "cat /dev/block/mtdblock0" > loader.bin
  adb -s <ip>:5555 exec-out "cat /dev/block/mtdblock1" > kernel.bin
  adb -s <ip>:5555 exec-out "cat /dev/block/mtdblock2" > data.bin
  adb -s <ip>:5555 exec-out "cat /dev/block/mtdblock3" > system.bin
  adb -s <ip>:5555 exec-out "cat /dev/block/mtdblock4" > misc.bin
  ```
  (`/dev/mtd/mtdX` character devices don't exist on this build — only
  `/dev/block/mtdblockX`.)

  All 5 partitions dumped at exactly the expected sizes, hashed with
  SHA256, and archived. See [`/firmware`](./firmware).

- **Maskrom USB recovery mode** (safety net / independent verification):
  holding the PCB button while plugging in USB puts the SoC into Rockchip's
  boot-ROM recovery mode, confirmed via:
  ```
  lsusb
  # ID 2207:301a Fuzhou Rockchip Electronics Company RK3036 in Mask ROM mode
  ```
  `rkflashtool` was installed for this path; a raw full-chip dump via this
  route is a planned second, independent backup (not yet completed).

### 5. Firmware analysis

`system.bin` is a **SquashFS 4.0** image: little-endian, XZ compressed,
**ARM BCJ filter applied**, 131072-byte blocks, 376 inodes, built
2018-10-10. This is important for any future repack — matching flags are
required:
```bash
mksquashfs squashfs-root system_new.bin -comp xz -Xbcj arm -b 131072
```

Extracted cleanly with `unsquashfs -d squashfs-root system.bin` — 322
files, 35 directories, 19 symlinks, no errors. Notable contents:

- `/etc/lollipop.conf` — plain-text device config:
  ```
  device_name_prefix=LOLLIPOP
  function_mode=DLNA
  softap_password=12345678
  softap_freq=2.4G
  ota_host=dongleking.net/ota/alpha2asvbs
  language=English
  ```
  Lowest-risk, highest-value place for first customization experiments.
- `/etc/boa/boa.conf` — web server config.
- `/bin/*.cgi` — ~25 native ELF binaries serving the web UI.
- `/lib/*.so` — ~150 shared libs, full Stagefright/OMX/AudioFlinger/
  SurfaceFlinger stack plus `libffmpeg.so`.

`kernel.bin` (binwalk):
```
0x0800   zImage (ARM Linux kernel)
0x1E7C   LZO compressed data (likely small stub/decompressor)
0x1FC1   LZO compressed data
0x298DEB XZ compressed data   <- almost certainly the boot ramdisk (cpio),
                                  containing init.rc — not yet extracted
0x36E098 Flattened Device Tree
```
Extraction of the ramdisk (and therefore `init.rc` — the actual boot
sequence definition) is **incomplete**. `xz -d` fails on the sliced segment
due to trailing bytes past the real stream boundary (binwalk doesn't know
the exact end offset). Next attempt: `xz -dc --single-stream` or a
forgiving Python `lzma.LZMADecompressor()` read. This is the single
biggest missing piece of the analysis — `init.rc` would show the real boot
order and the cleanest hook point for any custom startup logic.

---

<img width="1216" height="1052" alt="Screenshot from 2026-07-15 20-46-11" src="https://github.com/user-attachments/assets/f81e82f4-a6fa-4ebc-80aa-4bc8ef85bad3" />


## Proposed Next Steps (⚠️ untested — plans, not results)

The following ideas have **not been verified working** in this repo's
research so far and should be treated as hypotheses to test, not
established facts:

- Bypassing the graphics stack by bind-mounting a custom JPEG over
  `/system/usr/share/jpg/dlna.jpg` (the background image drawn by
  `lollipop_softap`'s `libskia_ui.so`), then killing `lollipop_softap` to
  force the supervisor (`none_stop_service`) to restart it and redraw.
  **This specific technique was claimed successful in one AI-assisted
  session but was never actually executed or confirmed in the logged
  research here — treat as unverified until independently reproduced.**
- Replacing the `airserver` binary with a shell script that polls a home
  server for a dashboard image via a statically-linked `busybox wget`,
  writes it to `/data/dashboard.jpg`, and triggers a redraw.
- Using `avtest` or the FFmpeg-based player libs with an actual valid video
  file (never tested — all prior attempts used nonexistent paths).
- Editing `/etc/lollipop.conf` and repacking `system.bin` for basic
  rebranding / custom OTA host, then flashing via Maskrom mode.

**Full custom OS (Armbian/mainline Linux) was investigated and ruled out.**
RK3036 has no mainline kernel or Armbian support — current Rockchip work
targets RK3399/RK3568/RK3576/RK3588. Porting from scratch would be a
months-long SoC bring-up project, not realistic for this device's value.

---

## Repository Contents

```
/firmware
  loader.bin          - mtd0, 256KB
  kernel.bin           - mtd1, 4MB
  data.bin              - mtd2, 768KB
  system.bin            - mtd3, ~11MB (squashfs)
  misc.bin               - mtd4, 128KB
  SHA256SUMS.txt          - hashes for all of the above
/analysis
  squashfs-root/          - unpacked system.bin contents
  report.txt              - file/binwalk output notes
/images
  pcb-front.jpg, pcb-back.jpg, teardown photos, etc.
README.md                 - this file
```

<img width="1197" height="1052" alt="Screenshot from 2026-07-15 20-16-59" src="https://github.com/user-attachments/assets/d038f951-24a2-4c5d-a59f-924692557a42" />


## Reproducing / Reconnecting

```bash
# Preferred: over home LAN (device is dual-homed once joined once)
adb connect <device-lan-ip>:5555
adb shell

# Fallback: join the device's own AP first
# WiFi SSID: LOLLIPOP-XXXXXX   password: 12345678
adb connect 192.168.49.1:5555

# Re-enable ADB if disabled after reboot
curl http://<device-ip>/cgi-bin/debug.cgi

# Enter Maskrom recovery (safety net, e.g. for rkflashtool)
# hold the PCB button while plugging in USB, then:
lsusb   # look for "2207:301a ... RK3036 in Mask ROM mode"
```

<img width="1197" height="1052" alt="Screenshot from 2026-07-15 20-34-59" src="https://github.com/user-attachments/assets/7a2450c4-5d52-4c9b-b658-d50aba73421a" />


## Disclaimer

This is a personal hardware research project on a device the author owns.
Shared for educational/documentation purposes. No warranty — flashing
custom firmware to embedded devices carries real risk of bricking; the
Maskrom recovery path was confirmed working *for this specific unit* but
that's not a guarantee for others.
