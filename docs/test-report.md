# Hardware test report

Real-hardware results for `dvb-usb-onairgt`. Raw output is shortened to excerpts. Background is in
[hardware.md](hardware.md) and [driver-internals.md](driver-internals.md).

## Test setup
| item | value |
|---|---|
| device | OnAir GT USB HDTV, USB `11ba:1101`, product string "USB HDTV-GT(1.1)" |
| host | Ubuntu 26.04 VM (VMware), kernel 7.0.0-38-generic, xHCI, USB 2.0 high speed |
| USB | VMware USB passthrough from a Windows host |
| signal | Korean cable TV, 8VSB on the US cable (STD) channel plan |
| tools | dvb-tools (`dvbv5-scan`, `dvbv5-zap`), ffprobe; a Python checker for TS sync bytes, TEI and per-PID continuity counters |
| date | 2026-10-18 |

The driver was tested in two builds:
- the first standalone build (0.1), which produced all the results below except the last re-check;
- the repository's DKMS package (0.2), re-checked at the end ([DKMS 0.2 re-check](#dkms-02-re-check)).

Commands and names below are those of 0.2: `./install.sh`, `scripts/`, `driver/`, DKMS module
`dvb-usb-onairgt`. From 0.3 they are `tools/install.sh`, `tools/`, the repository root and DKMS module
`onairgt`; the kernel module is still `dvb-usb-onairgt`.

## Probe and attach
dmesg with `dvb_usb_v2` debug output enabled. The command bytes are the FX2 protocol from
[protocol.md](protocol.md).
```
usb 3-2: dvb_usb_v2: found a 'OnAir GT USB HDTV' in warm state
usb 3-2: dvb_usb_v2_generic_io: >>> de 00                 power on
usb 3-2: dvb_usb_v2_generic_io: >>> 0b                    USB speed check
usb 3-2: dvb_usb_v2_generic_io: <<< 80                    high speed
usb 3-2: dvb_usb_v2_generic_io: >>> 51                    digital mode
usb 3-2: dvb_usb_v2_generic_io: <<< 01
usb 3-2: dvb_usb_v2_generic_io: >>> 09 01 01 0e 02        I2C read, demod reg 0x02
usb 3-2: dvb_usb_v2_generic_io: <<< 08 f7
lgdt330x 0-000e: Demod loaded for LGDT3303 chip
usb 3-2: DVB: registering adapter 0 frontend 0 (LG Electronics LGDT3303 VSB/QAM Frontend)...
tuner-simple 0-0061: type set to 64 (LG TDVS-H06xF)
usb 3-2: dvb_usb_v2: 'OnAir GT USB HDTV' successfully initialized and connected
```
The driver creates `/dev/dvb/adapter0/{frontend0,demux0,dvr0,net0}`.

The first build timed out on the `51` reply (`2nd usb_bulk_msg() failed=-110`). The cause is that the
firmware does not reset its data toggles on SET_INTERFACE. The fix is `CLEAR_FEATURE(ENDPOINT_HALT)` on
EP 0x01 and 0x81 after selecting the alt setting. The cause was reproduced and the fix confirmed from
userspace before it went into the driver (see [hardware.md](hardware.md)).

## Lock list
`dvbv5-zap` was run on each center frequency of the US terrestrial ATSC table. Tuning is plain
`tuner-simple` (center + 44 MHz IF), with no frequency offset.

| frequency (MHz) | status | C/N (dB) |
|---|---|---|
| 57.03 | Lock (0x1f) | 30.9 |
| 183.03 | Lock | 23.4 |
| 189.03 | Lock | 21.4 |
| 195.03 | Lock | 28.3 |
| 201.03 | Lock | 28.1 |
| 207.03 | Lock | 21.4 |
| 213.03 | Lock | 24.9 |
| 63-177, 473-803 (other 61 channels) | no lock | - |

57.03 MHz carries only null packets (PID 0x1fff). The cable band from 219 MHz up is not in the terrestrial
table; it was scanned with the cable plan below.

## dvbv5-scan
`dvbv5-scan -C KR` over the US cable STD plan (center frequencies, `DELIVERY_SYSTEM = ATSC`,
`MODULATION = VSB/8`):

- **70 services on 27 frequencies** between 183 and 423 MHz. Examples: KBS1 (231 MHz), KBS2 (225), MBC
  (237), EBS1/EBS2 (219), KTV (213), 국회TV (195), tvN (303), 연합뉴스TV (303), YTN2 (261), 아리랑TV (339).
- On 10 more frequencies (189, 201, 267, 279, 297, 315, 327, 345, 363 and 369 MHz) the demod locked and the
  channel table was read, but `dvbv5-scan` timed out waiting for the program tables ("not found on PMT").
  The tables are on air: a raw 10 s recording of 189 MHz carries every program's table 5 times a second,
  with 0 continuity errors. With `dvbv5-scan -T 4` (4× table timeouts), 189 MHz gave all 3 services, and so
  did 201 MHz.
- The scan was cut short at about 429 MHz by the unplug test below. TVHeadend later scanned the full plan
  (see the TVHeadend section).

## TS integrity
Full-TS recordings (`dvbv5-zap -P`), isochronous transfer (alt 6) unless noted.

| recording | bytes | packets | bad sync | TEI | CC errors | rate |
|---|---|---|---|---|---|---|
| 195 MHz, **60 s** | 145,540,200 | 774,150 | 0 | 0 | 0 | 2368 KB/s ≈ 19.4 Mbit/s |
| 183 MHz, 5 s | 12,217,180 | 64,985 | 0 | 0 | 0 | 2386 KB/s |
| 195 MHz, 5 s | 12,216,240 | 64,980 | 0 | 0 | 0 | 2385 KB/s |
| 195 MHz, 8 s, **bulk** (`xfer=1`) | 19,480,560 | 103,620 | 0 | 0 | 0 | 2377 KB/s |
| KTV service only (`-r`), 10 s | 7,657,804 | 40,733 | 0 | 0 | 0 | 747 KB/s |

19.39 Mbit/s is the ATSC 8VSB payload rate.

ffprobe on the 195 MHz multiplex:
```
Program 1
  Stream #0:0[0xded]: Video: mpeg2video (Main), yuv420p(tv, bt709, top first), 1920x1080 [SAR 1:1 DAR 16:9], 29.97 fps
  Stream #0:1[0x11d5](eng): Audio: ac3, 48000 Hz, stereo, fltp, 256 kb/s
Program 2
  Stream #0:4[0xe79]: Video: mpeg2video (Main), yuv420p(tv, bt709, top first), 1920x1080 [SAR 1:1 DAR 16:9], 29.97 fps
  Stream #0:5[0x1261]: Audio: ac3, 48000 Hz, stereo, fltp, 256 kb/s
Program 602
  Stream #0:2[0xd8c]: Video: mpeg2video (Main), yuv420p(tv, bt709, top first), 1920x1080 [SAR 1:1 DAR 16:9], 29.97 fps
  Stream #0:3[0x1174]: Audio: ac3, 48000 Hz, stereo, fltp, 256 kb/s
```
ffprobe on the KTV recording:
```
Duration: 00:00:10.42, bitrate: 5880 kb/s
Stream #0:0[0xe03]: Video: mpeg2video (Main), yuv420p(tv, top first), 1920x1080 [SAR 1:1 DAR 16:9], 5700 kb/s, 29.97 fps
Stream #0:1[0x11eb]: Audio: ac3, 48000 Hz, stereo, fltp, 192 kb/s
```
`ffmpeg` decoded the KTV recording to frames that matched the live broadcast, including the on-screen clock.

## Isochronous vs bulk
| mode | how | result |
|---|---|---|
| isochronous, alt 6 (default, as Windows) | 8 URBs × 32 × 940 B | clean; URBs complete with 9400-10340 B, i.e. 10-11 full packets out of 32 |
| bulk, alt 0 (`xfer=1`) | 8 × 16 KiB | clean (see table above) |

## LGDT3303 TS setup (`win_ts`)
The demod's MPEG output register 0x87 resets to **0xfb** on this board. The Windows driver changes it to
**0xf5** (`(v & 0xf5) | 0x05`) and writes reg 0x47 = 0x88. Results at 195 MHz:

| `win_ts` | reg 0x87 / 0x47 | 8 s recording |
|---|---|---|
| 1 (default) | 0xf5 / 0x88 | 0 TEI, 0 CC errors, 12 PIDs |
| 0 (stock lgdt330x setup) | 0xfb / 0x8b | **213 TEI, 101 CC errors, 378 distinct PIDs** (garbage) |

So the Windows setting is required on this board.

## Boot EEPROM
Read through the driver's I2C adapter with `i2c-dev`:
```
$ i2ctransfer -y 0 w2@0x51 0x00 0x00 r16
0xc2 0xba 0x11 0x01 0x11 0x00 0x00 0x41 0x00 0x03 0x00 0x00 0x02 0x14 0xb8 0x00
$ i2ctransfer -y 0 w1@0x50 0x00 r16
Error: Sending messages failed: Remote I/O error
```
- **0x51 holds a C2 firmware image:** C2 header, VID 0x11ba, PID 0x1101, first record `LJMP 0x14b8`.
  The image embedded in the Windows driver starts with `LJMP 0x1451`, so the board's firmware is a
  different build.
- **Nothing answers at 0x50.** FX2 command 0xEB also reports 0x51.

## Cold start and unplug
- A physical unplug/replug with no Windows host involved:
  - The device re-enumerated as bcdDevice 0x1205 / 500 mA with all seven alt settings.
  - dmesg showed `found a 'OnAir GT USB HDTV' in warm state`, then `successfully initialized and connected`.
  - No firmware was requested. The board loads its firmware from the EEPROM above, so the module needs no
    firmware file.
- The cold upload path (bMaxPower 100 mA → vendor request 0xA0 upload) is for blank-EEPROM boards. It has
  **not run on hardware**.
- The unplug happened while `dvbv5-scan` held the frontend:
  - The adapter was torn down correctly once the scan let go.
  - For those ~7 s, each frontend poll logged `usb_bulk_msg() failed=-19` and an `lgdt330x … error
    (ret == -19)` line.
  - The 0.2 driver fixes this: commands fail silently with -ENODEV once the device is gone, and the frontend
    thread is stopped on disconnect. **The fix has not been re-tested with a physical unplug.**

## DKMS 0.2 re-check
The repository driver was installed with `make dkms-install`. It uses the kernel.org headers for v7.0.14,
which are byte-identical to the Ubuntu 7.0.0-38 source.
```
$ dkms status
dvb-usb-onairgt/0.2, 7.0.0-38-generic, x86_64: installed
$ modinfo -n dvb_usb_onairgt
/lib/modules/7.0.0-38-generic/updates/dkms/dvb-usb-onairgt.ko.zst
```
dmesg after `modprobe` shows the same warm attach sequence as above.

A 5 s zap on 213 MHz gave:
- `Lock (0x1f)`, C/N 29.8 dB;
- 12,216,240 bytes (2385 KB/s), 64,980 packets;
- 0 bad sync, 0 TEI, 0 CC errors;
- PAT with programs 1, 2 and 201.

## TVHeadend end-to-end (see installation-notes.md)

Test system: Ubuntu 26.04.1 (kernel 7.0.0-38-generic), VMware VM, the OnAir GT
passed through, Korean cable 8VSB feed, preset `kr-cable-8vsb` (133 muxes),
2026-10-18. Every run started from `sudo ./uninstall.sh --yes` (plus
`--purge-tvh --purge-data` between TVHeadend methods) and used `install.sh --yes`.

| path | command | result |
|---|---|---|
| driver only | `install.sh --yes --no-tvh --no-dkms` | built in a temp copy, `/lib/modules/7.0.0-38-generic/updates/dvb-usb-onairgt.ko`, loaded, `/dev/dvb/adapter0` |
| driver (DKMS) | `install.sh --yes --no-tvh` | `dvb-usb-onairgt/0.2 ... installed`. A re-run prints `already installed` and `already loaded (current build)` |
| Docker | `install.sh --yes --tvh docker` | **pass, the only path verified end to end** (install, scan, mapping, live stream), see below |
| source | `install.sh --yes --tvh source` | **partial**: 1st run failed (auth check bug, fixed). 2nd run scanned 226 services and created 109 channels, but they were left unlinked (no services) by the restart race. Fix in the scripts, not re-run on hardware. See below |
| repo (apt, cloudsmith) | `install.sh --yes --tvh repo` | **not run** (resolute repo verified to exist: tvheadend 4.3-2897) |

**Docker** (`lscr.io/linuxserver/tvheadend`, host network, `--device /dev/dvb`):
- driver: DKMS 0.2 built (kernel-private headers v7.0.14 fetched from kernel.org), loaded, adapter0;
- admin account created, the wide-open `*` admin entry from `-C` removed;
  anonymous `GET /api/channel/grid` → 401;
- network "Cable 8VSB (STD)", 133 muxes, ATSC-C frontend disabled, ATSC-T enabled;
- scan: 133/133 muxes, 42 with services, 224 services;
- mapping: 109 channels (KBS/MBC/JTBC/tvN/KTV etc.). The installer printed
  "channels: 0" because it read the async mapper's status too early. Fixed: it
  now polls `channel/grid`;
- stream: `/stream/channel/<KTV>?profile=pass` for 10 s → 7,497,816 bytes,
  39,882 packets, 0 bad sync, 0 TEI; ffprobe: MPEG-2 1920x1080 + AC-3.
- Bug found: the "verify admin login" step ran without credentials (unexported
  shell variables). Fixed.

**Source build** (`/usr/local/src/tvheadend`, unit `-c /var/lib/tvheadend`,
no `-C`):
- build + install OK, config dir `/var/lib/tvheadend` owned by `hts`, persistent;
- first run failed: fresh native install has no access entries, so the
  temporary-superuser bootstrap was used, and the credential check used
  `/login`, which answers 403 to the superuser-file account. Fixed: `/login` is
  only consulted when anonymous access is admin;
- second run: scan 133/133 muxes, 42 with services, 226 services; mapping
  109/109 channels; 10 s stream 7,497,816 bytes, 0 bad sync, 0 TEI, MPEG-2
  1080 + AC-3; anonymous API → 401; ExecStart without `-C`;
- **after the final restart** (which removes the temporary superuser) all 109
  channels had `services: []` and "{name-not-set}": tvheadend had not yet saved
  the service↔channel links. Fixed in the scripts: install.sh waits 20 s before
  that restart, and tvh-setup.py deletes service-less channels before mapping,
  so a re-run (`install.sh --tvh existing`) repairs it. This fix is **not yet
  re-tested** on hardware.
