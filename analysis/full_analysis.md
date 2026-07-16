# RK3036 AnyCast Dongle — Full Firmware Analysis Report
> Generated: 2026-07-15 | Device: `LOLLIPOP-XXXXXX` @ `DEVICE_IP`

---

## ⚠️ Critical Finding: SHA256SUMS.txt Was Corrupted

> [!CAUTION]
> The `SHA256SUMS.txt` in `adb_dumps/` stored the **same hash for all 5 partitions** — this is impossible and indicates the script ran before the files were populated. A corrected `SHA256SUMS_CORRECT.txt` has been generated.

### ✅ Correct Partition SHA256 Hashes
| Partition | File | Size | SHA256 |
|-----------|------|------|--------|
| mtd0 loader | `loader.bin` | 256 KB | `85fa181fdb7fd94b48752fdc071d1fa874d76a9...` |
| mtd1 kernel | `kernel.bin` | 4.0 MB | `229cf2bf5346d676c2f955d602a256041449971...` |
| mtd2 data | `data.bin` | 768 KB | `6db7eca108878bb3aa027eee5f6fa5107601a231...` |
| mtd3 system | `system.bin` | 11.0 MB | `0c92e4d0ec36ee341fbd6437d261eb69aaebeea5...` |
| mtd4 misc | `misc.bin` | 128 KB | `db9c349e95f5d9db57e550969985f4478de1d3ee...` |

Both `adb_dumps/` and `analysis/` copies of `kernel.bin` match (SHA256 identical) ✓

---

## 1. Hardware Summary
| Item | Value |
|------|-------|
| SoC | Rockchip RK3036 — dual-core ARM Cortex-A7 |
| Serial | `REDACTED_SERIAL` |
| WiFi | SSV6051P (ssv6xxx driver) |
| Flash | 16 MB SPI NOR (MX25L12845E) |
| RAM | Samsung K4T1G1 DDR |
| Display | HDMI output, 1280×720 @ 60fps |

---

## 2. Flash Partition Map (from `/proc/mtd`)
| MTD | Name | Size | Erase block | Filesystem | Status |
|-----|------|------|-------------|------------|--------|
| mtd0 | loader | 256 KB | 4 KB | raw binary | Rockchip SPL |
| mtd1 | kernel | 4 MB | 4 KB | Rockchip KERNEL fmt | Contains zImage + DTB |
| mtd2 | data | 768 KB | 4 KB | jffs2 (rw) | ~480 KB free |
| mtd3 | system | ~11.1 MB | 4 KB | squashfs (ro, XZ) | 100% FULL |
| mtd4 | misc | 128 KB | 4 KB | raw | Bootloader scratch |

**Total: 16 MB — no hidden space exists.**

---

## 3. Software Stack
| Layer | Details |
|-------|---------|
| Kernel | Linux 3.10.0 — built Thu Oct 11 01:08:48 HKT 2018 by `NoMoneyNoTalk` using Linaro GCC 5.4 |
| OS | Android 5.1.1 (Lollipop), API 22, `ro.build.type=eng` |
| Init | Android init (bionic), SELinux **permissive**, `ro.secure=0`, `ro.debuggable=1` |
| Web | `boa` v0.94 on port 80, `DocumentRoot /data/boa/www`, `ScriptAlias /cgi-bin/ -> /system/bin/` |
| ADB | TCP on port 5555, always-root (`ro.adb.secure=0`) |

---

## 4. Kernel Binary Structure (SOLVED ✅)

> [!IMPORTANT]
> Previous analysis was stuck on ramdisk extraction. This is now **fully solved**.

The `kernel.bin` structure:
```
0x000000  "KERNEL\x00\x00" — Rockchip NAND partition header
0x000800  ARM zImage decompressor stub (ARM instructions)
0x001FC1  LZOP stream — compressed Linux kernel (vmlinux), LZO1X-999 level 9
          → 25 blocks × 256 KB = 6.1 MB decompressed
          → Kernel compiled with CONFIG_INITRAMFS_SOURCE (initramfs built-in!)
0x36E061  End of LZOP stream (4-byte aligned padding)
0x36E098  DTB (Flattened Device Tree, d00dfeed magic) — hardware description
0x400000  End of partition
```

> [!NOTE]
> The binwalk-reported `0x298DEB` "XZ stream" was a **false positive** — the 6-byte XZ magic appeared inside the LZOP-compressed data. The actual ramdisk is NOT a separate XZ stream — it's a CPIO archive compiled directly into the kernel via `CONFIG_INITRAMFS_SOURCE`.

### Ramdisk Extraction Method Used
1. Used `ctypes` + `liblzo2.so.2` (`lzo1x_decompress`) to decompress the LZOP stream → `vmlinux.raw` (6.1 MB)
2. Scanned `vmlinux.raw` for CPIO `070701` magic → found initramfs at offset `0x52cfbc`
3. Extracted CPIO archive (`initramfs.cpio`, 753 KB) and unpacked to `initramfs-root/`

---

## 5. Initramfs Contents (init.rc EXTRACTED ✅)

**47 entries total.** Key files:

| File | Size | Purpose |
|------|------|---------|
| `init.rc` | 21,851 B | **Main Android init script** — full boot sequence |
| `init.rk30board.rc` | 5,929 B | RK30 board-specific init (service defs) |
| `init.rockchip.rc` | 9,427 B | **Rockchip service definitions** — lollipop, airserver, boa, etc. |
| `init.connectivity.rc` | 6,513 B | WiFi/dhcpcd service config |
| `init.rk30board.usb.rc` | 6,333 B | USB/ADB enable rules |
| `init.environ.rc` | 944 B | Environment variables |
| `default.prop` | 311 B | **Root defaults** — `ro.secure=0`, `ro.debuggable=1` |
| `fstab.rk30board.bootmode.unknown` | 2,615 B | **Partition mount table** — mounts mtdblock3→/system, mtdblock2→/data |
| `init` | 309,836 B | Android init binary (ARM ELF) |
| `sbin/adbd` | 236,084 B | ADB daemon |
| `file_contexts` | 16,813 B | SELinux contexts (permissive = not enforced) |

### Boot Sequence
```
early-init → ueventd + mkdir /mnt/ram0
init       → mount cgroups, mkdir /system /data, set kernel tunables
post-fs    → insmod vcodec_service.ko (VPU video codec!)
post-fs-data → copy boa.conf/mime.types to /data/boa/, mkdir /data/boa/www
boot       → class_start core (surfaceflinger, logd, servicemanager)
           → class_start main (netd, media, lollipop, ntpclient, dhcpcd...)
```

### Service Start Order (from `init.rockchip.rc`)
```
lollipop          /system/bin/lollipop         [class main, always running]
lollipop_softap   /system/bin/lollipop_softap  [disabled, oneshot]
airserver         /system/bin/none_stop_service /system/bin/airserver
rk_dlna_dmr       /system/bin/none_stop_service /system/bin/rk_dlna_dmr
MediaDaemon       /system/bin/none_stop_service /system/bin/MediaDaemon
boa               /system/bin/boa              [disabled, started by lollipop]
ntpclient         ntpclient -c 10000 ...2.android.pool.ntp.org [class main]
```

> [!NOTE]
> The `none_stop_service` wrapper binary is what makes airserver/rk_dlna_dmr restart on crash — it's a simple supervisor loop.

---

## 6. System Partition (`system.bin`) Analysis

**SquashFS 4.0, XZ compressed, ARM BCJ filter, 131072-byte blocks, 376 inodes**
**Created: Wed Oct 10 17:08:40 2018** | **Build hostname: `NoMoneyNoTalk`**

### Key Binaries in `/system/bin/` (86 files)
| Binary | Size | Notes |
|--------|------|-------|
| `airserver` | 1.9 MB | AirPlay receiver |
| `wpa_supplicant` | 933 KB | WiFi client |
| `hostapd` | 290 KB | SoftAP daemon |
| `toolbox` | 151 KB | Android toolbox (ls, cp, cat, etc.) |
| `sh` | 157 KB | mksh shell |
| `avtest` | 17.8 KB | **Video player test** (Stagefright/SurfaceComposer) |
| `boa` | 63.6 KB | HTTP server |
| `debug.cgi` | 5.4 KB | Enables ADB — key access vector |
| `lollipop` | 13.6 KB | Core Miracast orchestrator |
| `media_control.cgi` | 9.5 KB | Media control API |
| `settings.cgi` | 9.5 KB | Settings web API |
| `wifi.cgi` | 9.5 KB | WiFi network management |

### CGI API Endpoints (native ARM ELF binaries served as CGI scripts)
```
/cgi-bin/home.cgi           GET device status
/cgi-bin/settings.cgi       GET/SET overscan, freq, password, OTA host
/cgi-bin/debug.cgi          → enables ADB TCP on :5555 ("ADB enabled!")
/cgi-bin/media_control.cgi  play/pause/stop media
/cgi-bin/playUrl.cgi        DEAD — attempts /system/bin/mediaplayertest (MISSING)
/cgi-bin/scan.cgi           scan WiFi networks
/cgi-bin/connect.cgi        connect to WiFi AP
/cgi-bin/wifi.cgi           WiFi management hub
/cgi-bin/password.cgi       change SoftAP password
/cgi-bin/softap_freq.cgi    2.4G/5G band selection
/cgi-bin/ota_host.cgi       OTA server config
/cgi-bin/dialog.cgi         UI dialog control
/cgi-bin/inputUrl.cgi       input media URL
/cgi-bin/key.cgi            remote key control
```

### Key Libraries in `/system/lib/`
| Library | Size | Purpose |
|---------|------|---------|
| `libffmpeg.so` | 2.5 MB | **FFmpeg** — full media framework |
| `librkffplayer.so` | 665 KB | **Rockchip FFmpeg player** — UNEXPLORED |
| `libomxvpu_dec.so` | 62 KB | RK VPU hardware decoder interface |
| `librk_vpuapi.so` | 593 KB | VPU API |
| `libstagefright.so` | 350 KB | Stagefright media framework |
| `libsurfaceflinger.so` | 214 KB | Display compositor |
| `libskia.so` | 1.1 MB | 2D graphics (Skia) |
| `libcrypto.so` | 1.1 MB | OpenSSL crypto |
| `liblollipop_config.so` | 5.3 KB | Config reader for lollipop.conf |
| `lib_rkdlna_dmr_upnp_c.so` | 210 KB | DLNA/UPnP |

---

## 7. Key Config Files

### `/system/etc/lollipop.conf`
```ini
device_name_prefix=LOLLIPOP
device_name=
function_mode=DLNA
fb_scale=100
softap_password=12345678
softap_freq=2.4G
ota_host=dongleking.net/ota/alpha2asvbs
language=English
```

### `/system/etc/boa/boa.conf` Key Settings
```
Port 80
User 0 / Group 0       ← runs as root!
DocumentRoot /data/boa/www
ScriptAlias /cgi-bin/ /system/bin/
```

### `initramfs-root/default.prop`
```properties
ro.secure=0
ro.allow.mock.location=1
ro.debuggable=1
persist.sys.usb.config=adb
```
These are hardcoded into the **kernel initramfs** — cannot be changed without kernel recompile.

### Media Codecs (hardware-accelerated via RK VPU)
- **H.264/AVC** (up to 4K×2K) — `OMX.rk.video_decoder.avc`
- **VP8** — `OMX.rk.video_decoder.vp8`
- **VP9** (software, Google) — `OMX.google.vp9.decoder` (720p max)
- **H.263, MPEG-4, FLV, MJPEG** — all hardware-accelerated
- HEVC/H.265 — declared but commented out in codec XML

---

## 8. Security Profile

| Property | Value | Implication |
|----------|-------|-------------|
| `ro.secure` | `0` | ADB shell is always root |
| `ro.debuggable` | `1` | eng build, no security |
| `ro.build.type` | `eng` | Engineering/debug build |
| `ro.build.tags` | `test-keys` | Not production-signed |
| `ro.adb.secure` | `0` | No ADB auth required |
| SELinux | `permissive` | Denials logged but not enforced |
| `service.adb.tcp.port` | `5555` | ADB always on TCP |
| boa user | root (uid=0) | Web server runs as root |

> [!CAUTION]
> This is an **intentionally open engineering build**. Any device on your home network can get an instant root shell via ADB with zero authentication. Do not expose to untrusted networks.

---

## 9. Things That Work / Don't Work

### ✅ Works
- ADB root shell over WiFi (`adb connect DEVICE_IP:5555`)
- AirPlay receiver (`airserver`) — Miracast, DLNA
- Hardware H.264 decode (`avtest` initializes correctly, detects 1280×720@60fps)
- Boa web server with all CGI endpoints
- `lollipop` (Miracast core) + `lollipop_softap` (WiFi AP)
- Full graphics stack (SurfaceFlinger, EGL, OpenGL ES 1.1/2.0)

### ❌ Broken / Missing
- `mediaplayertest` — **does not exist**; `playUrl.cgi` is dead
- `zygote` — commented out → no APK/Java app support
- `healthd`, `bootanimation`, `installd` — all commented out

### ⚠️ Untested
- `avtest` with a **real video file** (prior tests used nonexistent paths → NULL crash)
- `librkffplayer.so` playback path
- OTA mechanism (`lollipop_online_ota`)

---

## 10. Storage Budget

| Location | Capacity | Free | Notes |
|----------|----------|------|-------|
| `/data` (jffs2, mtdblock2) | 768 KB | ~480 KB | Persistent, writable |
| `/data/boa/www` | within /data | ~480 KB shared | **Web root** — customizable! |
| `/system` (squashfs, mtdblock3) | 11 MB | **0** (full, RO) | Reflash required to change |
| `/mnt/ram0` (vfat RAM disk) | ~1 MB | varies | Volatile — lost on reboot |

**Practical storage ceiling for custom files: ~400 KB total in `/data`.**

---

## 11. Next Steps (Prioritized)

### 🟢 Easy / Zero Risk
- [ ] **URGENT: Copy backup tar.gz to external drive/cloud** — not confirmed done!
- [ ] Test `avtest` with a real H.264 file: `adb push tiny.mp4 /data/ && adb shell avtest /data/tiny.mp4`
- [ ] Extract `/data` partition (`data.bin`) to see current state of writable partition

### 🟡 Medium / No Firmware Change
- [ ] **Option A: Deploy custom HTML to `/data/boa/www`** — web root is ADB-writable, instantly served on port 80!
  ```bash
  adb push my_dashboard.html /data/boa/www/index.html
  # Browse to http://DEVICE_IP/ — instant!
  ```
- [ ] **Option B: Smart display** — cast existing Next.js dashboard via AirPlay/DLNA natively
- [ ] **Option C: Control panel** — Next.js app calling CGI APIs over LAN
- [ ] Explore `librkffplayer.so` as alternative playback path

### 🔴 Advanced / Firmware Modification
- [ ] **Custom lollipop.conf** — rename device, change OTA host — repack squashfs + reflash Maskrom
- [ ] **Tiny /data startup script** — push shell script to `/data`, trigger via `setprop`
- [ ] **Maskrom raw dump** via `rkflashtool` as independent second backup

---

## 12. Key Discovery: `/data/boa/www` is Writable Web Root

> [!TIP]
> The web root lives in the **writable /data JFFS2 partition**! Push custom HTML/CSS/JS via ADB — boa serves it immediately on port 80. ~400 KB available, enough for a compressed single-page app with inlined assets.

---

## 13. Files Created This Session

| File | Purpose |
|------|---------|
| `analysis/vmlinux.raw` | Decompressed Linux kernel via liblzo2 ctypes (6.1 MB) |
| `analysis/initramfs.cpio` | Extracted initramfs CPIO archive (753 KB, 47 entries) |
| `analysis/initramfs-root/` | Unpacked initramfs — **init.rc, init.rockchip.rc, default.prop, fstab, etc.** |
| `analysis/piggy_real.lzop` | Raw LZOP stream from kernel (for reference) |
| `adb_dumps/SHA256SUMS_CORRECT.txt` | **Correct** partition hashes (original SHA256SUMS.txt was corrupted) |
