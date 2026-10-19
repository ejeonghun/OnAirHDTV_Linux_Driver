# OnAir GT USB HDTV: hardware notes

What was measured on a real unit (product string "USB HDTV-GT(1.1)", USB `11ba:1101`), connected to a
Linux 7.0 VM by USB passthrough. Protocol details are in [protocol.md](protocol.md); the full `lsusb -v`
dump is in [usb-descriptors.txt](usb-descriptors.txt).

## Parts
| part | I2C (7-bit) | role |
|---|---|---|
| Cypress CY7C68013A (FX2) | - | USB 2.0 bridge, runs the command firmware |
| LG LGDT3303 | 0x0e | 8VSB/QAM demodulator, parallel TS output |
| LG Innotek TDVS-H062F | 0x61 | tuner (Infineon TUA6034 PLL), 54-863 MHz |
| Conexant CX25843 | 0x44 | analog video/audio decoder; not used for ATSC |
| boot EEPROM | **0x51** | FX2 "C2" firmware image (see below) |

Nothing answers at I2C 0x50.

## Firmware: the board boots warm
The FX2 loads its firmware from the EEPROM at I2C 0x51 at power-up. 0x51 is the address the FX2 boot loader
uses for large (16-bit addressed) EEPROMs. Read through the driver's I2C adapter (`i2c-dev`):
```
$ i2ctransfer -y 0 w2@0x51 0x00 0x00 r16
0xc2 0xba 0x11 0x01 0x11 0x00 0x00 0x41 0x00 0x03 0x00 0x00 0x02 0x14 0xb8 0x00
```
- `c2`: C2 load format (the EEPROM holds firmware, not only IDs).
- `ba 11` / `01 11` / `00 00`: VID 0x11ba, PID 0x1101, DID 0x0000.
- `41`: configuration byte (bit 6: 400 kHz I2C).
- Then the first load record: length 0x0003 at 0x0000: `02 14 b8` (`LJMP 0x14b8`).

The firmware embedded in the Windows driver starts with `LJMP 0x1451` and its device descriptor says
bcdDevice 0x0800, so the EEPROM copy is a different build. The running device reports **bcdDevice 0x1205**,
MaxPower **500 mA**, and the full seven-alt-setting interface right after power-up.

Evidence: the user physically unplugged and replugged the device with no Windows host involved. It
re-enumerated as bcdDevice 0x1205 / 500 mA and the driver logged `found a 'OnAir GT USB HDTV' in warm state`.
No firmware was uploaded. FX2 command 0xEB (EEPROM address) returns 0x51.

Consequences for the driver:
- The module works without any firmware file.
- The cold path stays in the driver for boards with a blank or ID-only (C0) EEPROM. It applies the Windows
  rule (configuration bMaxPower == 0x32 → cold) and uploads `dvb-usb-onairgt-01.fw` with vendor request
  0xA0. **This path is not hardware-verified.**

## USB interface
Interface 0 has alt settings 0-6, each with three endpoints:
- **EP 0x01 OUT (bulk 512):** commands.
- **EP 0x81 IN:** replies. Bulk 512 in alt 0, interrupt 32 B in alt 1-6.
- **EP 0x82 IN:** TS. Bulk 512 in alt 0. Isochronous in alt 1-6; alt 6 is 940 B per microframe
  (5 TS packets), the one Windows uses for TS.

### Firmware quirk: data toggles
The firmware does not reset its endpoint data toggles on SET_INTERFACE; the host does. The next reply on
EP 0x81 is then dropped by the host as a duplicate, and the command times out (-ETIMEDOUT). This was reproduced
from userspace (pyusb).
`CLEAR_FEATURE(ENDPOINT_HALT)` on EP 0x01 and 0x81 resets both sides. The driver issues it right after
`usb_set_interface()`, before any command; the Windows driver resets its pipes at the same point.

## Demodulator TS output (LGDT3303 reg 0x87)
- Reset value on this board: `0x87 = 0xfb`.
- The Windows driver does `0x87 = (v & 0xf5) | 0x05` → `0xf5` and writes `0x47 = 0x88`.
- Linux `lgdt330x` `clock_polarity_flip` 0/1/2 would give 0xfb/0xf3/0xda.

Measured at 195 MHz:

| setting | result |
|---|---|
| Windows tweak (`win_ts=1`, driver default) | 0 TEI, 0 continuity errors |
| plain lgdt330x (`win_ts=0`, reg 0x87 stays 0xfb) | garbage: 213 TEI, 101 CC errors, 378 random PIDs in 8 s |

The tweak is required on this board. The two registers were not tested separately.

## Tuner
`tuner-simple` type `TUNER_LG_TDVS_H06XF` (64) uses:
- divider `(f_center + 44 MHz) / 62.5 kHz`
- CB 0xce
- band byte 0x01 up to 165 MHz, 0x02 up to 450 MHz, 0x04 above
- AB 0x50 at init

These band edges and bytes are the ones the Windows driver uses, and plain ATSC center frequencies lock
without any offset. So the cable midband (120-174 MHz) and superband (216-470 MHz) are covered.
The demod limits tuning to 54-858 MHz.

## Throughput
- Full TS: 2368-2386 KB/s (19.39 Mbit/s).
- 60 s full-TS recording: 774,150 packets, 0 sync/TEI/continuity errors.
- Isochronous (alt 6) and bulk (alt 0, `xfer=1`) both deliver a clean TS.

## Signal used for testing
Korean cable TV, 8VSB on the US cable (STD) channel plan.
- A partial dvbv5 scan (57-423 MHz) found 70+ services, e.g. KTV, 국회TV, tvN스포츠, KBS라이프, MBN+, EBS.
- `dvbv5-scan` needs `-T 4` on this feed. With the default table timeouts it reports
  "not found on PMT", although the PMTs are on air 5 times a second.
