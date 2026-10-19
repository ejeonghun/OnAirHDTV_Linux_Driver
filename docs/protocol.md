# OnAir GT USB HDTV (USB 11ba:1101): USB protocol spec for the ATSC/TS path

Source analysed: `OnAirGt64.sys` from the OnAir GT Windows driver package (DriverVer 3.2.0.3, internal name `hdtvgt.sys`,
PDB `f:\wdk\6000\src\onairdrv\gtdriver\...\OnAirGt.pdb`, SHA-256 `dba54678cd7251fc7c291a77799851ae8fa7a3a4ccf8926b7442d3ec23005134`)
and the FX2 firmware embedded in it (extracted, disassembled as 8051).
The x64 driver was disassembled with capstone using `.pdata` function bounds.
Addresses `0x1xxxx`/`0x2xxxx` are driver VAs (image base 0x10000, file offset = VA - 0x10000).
Addresses `fw:0xNNNN` are 8051 code/xdata addresses in the firmware image (loaded at 0x0000).

Tags: **CONFIRMED** = seen directly in driver or firmware code. **INFERRED** = deduced, not proven.

Summary: the board is a Conexant/DViCO-"Bluebird"-style FX2 design. It uses the same EP1 bulk command protocol as Linux
`drivers/media/usb/dvb-usb/cxusb.c` (cmd 0x08/0x09 I2C, 0x0e GPIO, 0xde/0xdc power, 0x36/0x37 streaming, 0x50/0x51
analog/digital). It is very close to the DViCO FusionHDTV5 USB Gold (LGDT3303 at 0x0e + LG TDVS-H06xF at 0x61), but there
are three differences:
1. A cold device needs this FX2 firmware uploaded, and then it re-enumerates.
2. TS streaming uses command **0x38**, not 0x36. 0x36 is the analog video path.
3. Windows reads TS from **isochronous** EP 0x82 in alternate setting 6.

---

## 1. FX2 firmware

### 1.1 Embedded image: CONFIRMED
- Location: driver VA `0x26360` (file offset **0x16360**), length **0x1C00 = 7168** bytes. It sits in `.data` and starts with
  `02 14 51` (`LJMP 0x1451`). Firmware code contains `90 E6 xx` (`MOV DPTR,#0xE6xx`, FX2 register access).
- The same image is also in the 32-bit `OnAirGt.sys` (installed under `USBHDTV-GT\Drivers\`) at file offset 0x11e90 (identical bytes).
- Extracted raw image: not in this repository. `tools/extract-firmware.sh` produces it as `dvb-usb-onairgt-01.fw`.
  Load address 0x0000, SHA-256 `4a574e11e8d8460ce06e2512e9ae4b9303b2829649046e234212fc2734dcd143`. The last real byte
  is at 0x1B4E; the rest is 0xAA padding. The Windows driver uploads it in 14 chunks of 0x200 bytes (section 1.2).
- The firmware is proprietary. A Linux package should extract it from the user's driver copy (offset 0x16360, length 0x1C00)
  rather than redistribute it.

### 1.2 Upload procedure: CONFIRMED (`0x11cc0` → `0x11f1c`, then `0x11e0e`)
- The decision to upload is made in `0x11cc0`. It uploads only if the active configuration descriptor has **bMaxPower == 0x32** (100 mA).
  This is the FX2 boot/C0-EEPROM descriptor. The firmware's own configuration has bMaxPower 0xFA (500 mA), so a warm device is
  never re-uploaded.
- 14 chunks, each a control transfer:
  `bmRequestType=0x40 (vendor, device, OUT), bRequest=0xA0, wValue=addr, wIndex=0, wLength=0x200`.
  `addr` = 0x0000, 0x0200, …, 0x1A00. The data is image[addr:addr+0x200]. Chunk size is 512 bytes.
- Then `bRequest=0xA0, wValue=0xE600 (CPUCS), wIndex=0, wLength=1, data={0x00}`, which releases the 8051 from reset. The driver
  zero-fills the buffer in `0x1c7dc`.
- The Windows driver does **not** write CPUCS=0x01 before the upload. It relies on the cold FX2 already being held in reset.
  A Linux driver can use the standard `cypress_load_firmware()` (CPUCS=1, data, CPUCS=0) safely.
- After a 50 µs stall the driver immediately sends command 0xDE (power on, section 2). On a cold device this races the
  re-enumeration and is harmless.
- These are the only two vendor control-request sites in the driver (`0x11f89` and `0x11e39`). All other device traffic goes over
  EP1 bulk/interrupt.

### 1.3 Re-enumeration: CONFIRMED (fw main `0x0ec8`-`0x0f09`, `fw:0x169c`)
- Firmware main checks `USBCS.RENUM`. If it is clear, it sets `USBCS |= DISCON|RENUM` (0x0a), waits about 1.5 s, then clears
  DISCON. The device **disconnects and re-enumerates** with the firmware descriptors.
- Warm device descriptor (fw:0x0d00): VID **0x11ba** / PID **0x1101**, bcdDevice **0x0800**, bcdUSB 2.00, EP0 size 64, one
  configuration, 500 mA.
- **Hardware correction:** the inference that rev 0x1205 is a cold, EEPROM-provided ID was wrong. The tested
  unit has a **C2 firmware EEPROM at I2C 0x51**, boots straight into its own firmware build (`LJMP 0x14b8`, not
  this image's `LJMP 0x1451`), and reports bcdDevice **0x1205** / 500 mA / alt 0-6 right after power-up. See
  [hardware.md](hardware.md).
- Linux matches 11ba:1101 in both states. It treats the device as cold only if config bMaxPower == 0x32 (the Windows
  rule); bcdDevice is not a usable test. The upload path exists for C0/blank-EEPROM boards and is **not
  hardware-verified**.

### 1.4 Warm descriptors: CONFIRMED (fw:0x0d1c)
Interface 0 (class ff/01/01) has 7 alternate settings, each with 3 endpoints:

| alt | EP 0x81 | EP 0x01 | EP 0x82 | firmware EP2CFG / EP2ISOINPKTS / AUTOINLEN |
|---|---|---|---|---|
| 0 | bulk IN 512 | bulk OUT 512 | **bulk IN 512** | 0xE0 / – / 0x0200 |
| 1 | intr IN 32 | bulk OUT 512 | iso IN 1010×3 | 0xD8 / 3 / 0x03F2 (analog video) |
| 2 | intr IN 32 | bulk OUT 512 | iso IN 726×3 | 0xD8 / 2 / 0x02D6 |
| 3 | intr IN 32 | bulk OUT 512 | iso IN 686×3 | 0xD8 / 2 / 0x02AE |
| 4 | intr IN 32 | bulk OUT 512 | iso IN 970×1 | 0xD8 / 1 / 0x03CA |
| 5 | intr IN 32 | bulk OUT 512 | iso IN 684×1 | 0xD8 / 1 / 0x02AC |
| 6 | intr IN 32 | bulk OUT 512 | **iso IN 940×1 (5×188), bInterval 1** | 0xD8 / 1 / 0x03AC (**TS**) |

`SET_INTERFACE` in the firmware (`fw:0x11cb`) programs EP2CFG, EP2ISOINPKTS and the auto-IN length per alt. Command 0x38 uses
these values.

---

## 2. USB transport and command set

### 2.1 Command pipe: CONFIRMED (`0x12034`, firmware `fw:0x0080` dispatcher)
- A command is one **bulk OUT on EP 0x01**: `[cmd, args…]`. If the command has a reply, the driver then reads
  **EP 0x81** for `rlen` bytes. This is the same as `cxusb_ctrl_msg()`.
  - In alt 0, EP 0x81 is bulk. In alt 1-6 it is **interrupt** with a 32-byte maximum packet. Linux `usb_bulk_msg()` handles
    both endpoint types.
  - The driver serialises commands with a mutex. URB timeout is 5 s (`0x1c6ff`).
  - Firmware limits: EP1 buffers are 64 bytes (out at XDATA 0xE780, in at 0xE7C0). A command is at most 64 bytes including the
    cmd byte. The reply is at most 64 bytes, or 32 in alt≥1.
- Pipe mapping in the driver (`0x11cc0`): out pipe index 1 = EP 0x01, in pipe index 0 = EP 0x81, stream pipe index 2 = EP 0x82.

### 2.2 Command table
The firmware dispatch is a Keil CCASE table at fw:0x009b. For each command, "driver use" says whether the Windows driver sends it.

| cmd | OUT payload (after cmd byte) | IN reply | meaning | driver use |
|---|---|---|---|---|
| **0x08** | `addr7, len, data[len]` | 1 byte status | **I2C write** (`0x121c0`) | CONFIRMED |
| **0x09** | `wlen, rlen, addr7, wdata[wlen]` | `1+rlen`: `[status, rdata…]` | **I2C write-then-read with repeated start**. With wlen=0 it is a plain read (`0x12130`: `09 00 len addr`); combined form at `0x12248`. | CONFIRMED |
| 0x0B | – | 1 byte = `USBCS & 0x80` | High-speed check. The driver **fails start** with STATUS_DEVICE_NOT_READY if the reply is 0, so USB 2.0 HS is required (`0x10ff7`). | CONFIRMED |
| 0x0C | `addr7, count, len, data[count*len]` | 1 | Repeated I2C write of `count` chunks of `len` bytes | firmware only |
| 0x0D | `bit` | 1 | Read port-D GPIO bit | firmware only |
| **0x0E** | `bit, value` | 1 (=0x01) | **GPIO write**: sets `IOD.bit` and `OED.bit` (`fw:0x1886`). Only reached through a user-mode property (`0x1622c`). The driver never toggles GPIO itself. | CONFIRMED |
| 0x0F | 19 bytes of IR timing (EP1OUTBC must be 0x14) | 1 | IR receiver config. Driver sends `0f 04 84 d0 bb 80 16 f8 2e e0 6a 40 05 64 0f a0 0f a0 3e 80` (`0x16068`). | CONFIRMED |
| 0x10 | – | 5: `[?, addr, ~addr, cmd, ~cmd]` | IR (NEC) key poll (`0x1612c`) | CONFIRMED |
| 0x36 | `0x03, 0x00` | none | Start **analog video** streaming (IFCONFIG=0x03, alt 1) | CONFIRMED |
| 0x37 | – | none | **Stop streaming**: EP2 FIFO off, IFCONFIG=0 | CONFIRMED |
| **0x38** | `0x03, 0x00` | none | **Start TS streaming**: IFCONFIG=0xCB, EP2 FIFO reset, AUTOIN | CONFIRMED |
| 0x46 | – | 64 | Debug dump of FX2 registers | firmware only |
| **0x50** | – | 1 (=0x01) | **Analog mode** GPIO sequence | CONFIRMED |
| **0x51** | – | 1 (=0x01) | **Digital mode** GPIO sequence | CONFIRMED |
| **0xDC** | `0x00` | none | **Power off** | CONFIRMED |
| **0xDE** | `0x00` | none | **Power on** | CONFIRMED |
| 0xE8 / 0xE9 | – | none | Start / stop EP8 FIFO stream | firmware only |
| 0xEB | – | 1 | Returns the EEPROM I2C address (0x50 in the Windows image; the tested unit's EEPROM firmware returns **0x51**) | firmware only |

- I2C status byte: CONFIRMED values 6, 7 and 8 from `fw:0x19f6`. 8 = OK; Linux cxusb also treats `buf != 0x8` as an error
  (Linux `drivers/media/usb/dvb-usb/cxusb.c`). **INFERRED**: 7 = NACK, 6 = bus error (Cypress EZ-USB library naming). The Windows driver ignores the status and only checks the USB transfer result.
- In cmd 0x08 the address is 7-bit. The driver keeps 8-bit addresses internally and does `addr >> 1`.

### 2.3 TS streaming: CONFIRMED (`0x15ab4` start, `0x15c64` stop, `0x1a324`/`0x1a6b0` reader, `0x1d60c` iso URB)

**Start, digital stream (stream type 2):**
1. `SET_INTERFACE(0, alt 6)` (`0x11e88` → `0x1d3c8`). The driver then resets the command pipes.
2. Send `38 03 00` (3 bytes OUT, no reply). The second argument is 0, so firmware leaves EP2ISOINPKTS at the alt-6 value.
   Firmware sets IFCONFIG=0xCB (internal 48 MHz IFCLK, async, GPIF master), resets the EP2 FIFO, sets AUTOINLEN=0x03AC and
   FIFOPINPOLAR=0x27.
3. Enable demod output: LGDT3303 reg 0x00 bit 7 cleared (section 5.4).

**Data path:**
- 8 isochronous URBs are kept in flight on **EP 0x82**. Each URB has 32 iso packets (buffer = 32 × wMaxPacketSize = 32 × 940 =
  30080 bytes). Flags are `START_ISO_TRANSFER_ASAP | SHORT_TRANSFER_OK | IN`.
- On completion, each iso packet with non-zero `Length` is passed in order as `(buf+Offset, Length)` to the TS sink
  (`0x1a6de` loop → `0x15e60`).
- The sink copies the bytes straight into KS frames. There is **no 0x47 sync search, no header stripping and no 188-byte
  realignment**. A 188-byte holding buffer (`0x15a35`) is allocated but only zeroed. In Linux, feed each iso frame's actual bytes
  to `dvb_dmx_swfilter()`.
- Bandwidth: 940 B × 8000/s ≈ 60 Mbit/s capacity versus 19.39 Mbit/s for ATSC, so many iso packets are short or empty.

**Stop:**
1. Set LGDT3303 reg 0x00 bit 7.
2. Send `37` (1 byte, no reply).

The alternate setting is not changed back on stop.

**Bulk alternative: INFERRED, untested.** Alt 0 exposes EP 0x82 as bulk 512 with the same FIFO. `38 03 00` in alt 0 should
stream TS over bulk, which is how cxusb/DViCO devices work. Windows does not do this.

---

## 3. Endpoints (summary)
- EP 0x01 bulk OUT: commands.
- EP 0x81 IN: replies. Bulk in alt 0, interrupt 32 B in alt 1-6.
- **EP 0x82 IN: MPEG-TS.** Isochronous 940 B/µframe in **alt 6** (Windows); bulk 512 in alt 0.
- `dwTP_PACKET_SIZE` (0xBC) is read from the registry for the KS frame format only (`0x1b77e`).
- The INF keys `dwTS_GEN_CNTRL`, `dwIsTSStream`, `BlackbirdType`, `DemodType`, `TunerModel`, `TunerType`, `TunerI2CAddress` and
  `Tuner2IFAddress` are **not read by this driver**. Their names do not occur in the binary. They are leftovers from the Conexant
  reference INF, and the driver hardcodes all I2C addresses.

---

## 4. I2C bus map: CONFIRMED (address literals passed to the I2C object; the I2C layer shifts right by 1)

| device | 8-bit | 7-bit | evidence |
|---|---|---|---|
| LGDT3303 demod | 0x1C | **0x0e** | `0x12774` (write), `0x127ac` (read) |
| LG TDVS-H062F tuner PLL | 0xC2 | **0x61** | `0x12360`, `0x12514` |
| CX25843 (analog A/V) | 0x88 | **0x44** | `0x13460`/`0x134a8`, 16-bit big-endian register address |
| EEPROM | 0xA0 | 0x50 | firmware RAM 0x63 = 0x50; EEPROM write-poll in cmd 0x08 handler |
| (unknown) | 0xC0 | 0x60 | listed in the firmware gate table only |

- **No IF-demod (0x86/0x43) traffic exists in this driver.** There is no I2C access with address 0x86 (bounded search over all
  I2C call sites). `Tuner2IFAddress` is unused.
- **I2C gate is handled in firmware and is transparent to the host.** CONFIRMED: `fw:0x1a31` compares `addr<<1` against the
  RAM table {0x1C, 0xC2, 0xC0} (initialised at fw:0x1965). On a match it sets **PD2=1** before the transfer. After every I2C
  command it clears PD2 (`fw:0x1af4`). **INFERRED**: PD2 drives a bus switch or gate to the tuner/demod module. The host does not
  need to do anything; Linux needs no `i2c_gate_ctrl`.
- The tuner is reached directly over the FX2 I2C bus, not through the LGDT3303.

---

## 5. ATSC tuning path

### 5.1 Objects
The demod and tuner are one C++ object. Its vtable is at `0x245e0` and the constructor is at `0x1086f`. Fields:

| field | meaning | default |
|---|---|---|
| `+0x10` | mode: 1 = analog, 0x10 = digital | – |
| `+0x1c` | modulation: 0 = QAM64, 1 = QAM256, 3 = VSB | 3 |
| `+0x20` | AtscAgcValue | from registry; INF value 0x50; -1 if absent |
| `+0x24` | NtscAgcValue | from registry; INF value 0x30 |
| `+0x2c` | extra bits for reg 0x00 (0x80 = output disabled) | 0 |

The BDA tuner object (vtable `0x24af0`) calls these through demod vtable slots:

| slot | function | purpose |
|---|---|---|
| +0x20 | `0x12360` | setFrequency |
| +0x70 | `0x12674` | setModulation |
| +0x80 | `0x12594` | lock wait |
| +0x88 | `0x12ebc` | packet-error count |
| +0x90 | `0x13030` | SNR to quality |
| +0xb0 | `0x127ec` | output enable |

The BDA frequency is `freq_kHz × 1000` (multiplier 1000, `0x170ae`). It is range-checked against ≤ 803000 kHz (`0x170e0`).

### 5.2 Mode switch to digital: CONFIRMED (`0x115cc`, device vtable +0x40, mode 2)
1. Send cmd `51`, read 1 byte. It must be non-zero, otherwise abort.
2. Call `demod.setMode(0x10)`. No register writes in this path.
3. Call `demod.setModulation(3 = 8VSB)`, which runs the full VSB init in 5.3.

Switching to analog (mode 1):
1. Set reg 0x00 bit 7 (output off).
2. Write reg 0x02 = 0x00 (hold reset).
3. Wait 5 ms.
4. Set reg 0x00 bit 7 again.
5. Send cmd `50` and read 1 byte.

### 5.3 LGDT3303 register writes for 8VSB: CONFIRMED (`0x12d58`)
Single-register writes `[reg, val]` to 0x0e. They are issued only when the modulation changes or on the first tune.
```
00 = 0x03 | outbits     ; top control: VSB. outbits = 0x80 while output disabled, else 0. 0x40 (serial) is NEVER set → PARALLEL TS
0d = 0x40               ; VSB carrier NCO
0e = 0x87
0f = 0x8e
10 = 0x01
47 = 0x88               ; Linux lgdt3303_8vsb_44_data uses 0x8b. cxusb.c's FusionHDTV5-USB-Gold resume fixup writes 0x88 (Linux `cxusb.c`, `cxusb_aver_power_ctrl`)
4c = 0x14               ; same as Linux lgdt3303_init_data {0x4c,0x14}
02 = 0x00 ; sleep 5 ms ; 02 = 0x01 ; sleep 55 ms     ; soft reset (0x12868)
87 = (read(87) & 0xF5) | 0x05                         ; MPEG/DEMUX control read-modify-write (0x12e20)
```
After this the driver reads reg 0x00 & 3 and expects 3.

**Linux equivalent:**
- `lgdt330x_config { .demod_chip = LGDT3303, .serial_mpeg = 0x00 (parallel), .clock_polarity_flip = ? }`.
- Register 0x87 in Windows is a read-modify-write: clear bits 1 and 3, set bits 0 and 2. Bit 5 is controlled separately by
  `0x126e0` and stays cleared by default.
- Linux flip=1 writes 0x87=0xF3 and flip=2 writes 0x87=0xDA. Neither is provably equal without the chip's reset value. **Open
  question**: read 0x87 on hardware after reset, or add a `set_ts_params` hook that applies `(v&0xF5)|0x05`. Try flip=0 first;
  that is what DViCO FusionHDTV5 USB Gold uses.
- Order difference: Windows writes reg 0x00 first, then the table. Windows does not write reg 0x04.

QAM is not needed for ATSC, but for reference:
- QAM64: `00=00|outbits, 0d=00, 51=63, 47=66, 48=66, 4d=1a, 4c=14, 49=08, 4a=9b`, then reset.
- QAM256: the same, with `00=01|outbits`.

### 5.4 Output enable and disable: CONFIRMED (`0x127ec`)
`reg00 = read(0x00)`, then clear bit 7 to enable or set bit 7 to disable. The current state is stored in `+0x2c` so later
reg-0x00 writes keep it.
- Enabled at TS start and in BDA run.
- Disabled at TS stop and on switch to analog.
- **INFERRED**: bit 7 is power-down or output tri-state.

### 5.5 Tuner PLL (LG TDVS-H062F at 0x61): CONFIRMED (`0x12360`)
Input `f` is in Hz: the BDA frequency × 1000.
```
div  = (f + 45_750_000) / 62_500          ; 16-bit, step 62.5 kHz
CB   = 0xCE
BB   = 0x01 if f <= 165 MHz ; 0x02 if f < 450 MHz ; else 0x04
I2C write 0x61: [div>>8, div&0xff, 0xCE, BB]
```
Digital sequence (mode 0x10), in order:
1. If not yet initialised, run 5.3.
2. Demod reg 0x02 = 0x00.
3. Sleep 5 ms.
4. Write the tuner 4 bytes.
5. If AtscAgcValue is set, write the tuner AB byte: `[0x9E, AtscAgcValue]`. With the INF value this is `[0x9E, 0x50]`.
6. Demod reg 0x02 = 0x01.
7. Sleep 55 ms.
8. Store a timestamp for the lock timeout.

Analog uses the same PLL write followed by `[0x9E, NtscAgcValue(0x30)]`. It then polls the tuner status byte (I2C read
0x61) for bit 0x40 (lock), every 20 ms for up to 250 ms.

Notes for Linux:
- The band edges (165/450 MHz) and BB values match `tuner-simple` `TUNER_LG_TDVS_H06XF`.
- Windows uses control byte **0xCE**, where Linux uses 0x8E. Bit 6 differs (charge-pump current). Windows also writes an
  **auxiliary byte 0x9E,0x50**, which Linux digital mode does not.
- IF offset: Windows adds **45.75 MHz** (the picture-carrier IF), but the demod NCO values are Linux's "44 MHz" set. **INFERRED**:
  Windows apps pass `center − 1.75 MHz`, so the PLL lands at a 44 MHz IF center, which equals Linux tuner-simple digital
  `(f_center + 44 MHz)/62.5 kHz`. This could not be proven statically. **Verify on hardware** whether lock needs +44 MHz with
  the center frequency (expected) or +45.75 MHz.

### 5.6 Status, lock, SNR and UCB: CONFIRMED (`0x128ec`, `0x12f20`, `0x12ebc`)
- Lock wait timeout: VSB 200 ms, QAM64 300 ms, QAM256 600 ms, measured from the tune timestamp. Poll every 20 ms.
- VSB carrier lock: reg **0x1C bit 7**. VSB sync/FEC lock: reg **0x38 bit 1**.
- QAM: reg 0x36 & 7, reg 0x1C & 7, reg 0x05 & 0x20, reg 0x8A & 0x0F.
- SNR/MSE:
  - VSB: `(reg 0x71 << 8) | reg 0x72`. Reg 0x6E is read but its bits are discarded.
  - QAM: `(reg 0x1A << 8) | reg 0x1B`.
  - These are the same registers as Linux `lgdt3303_read_snr`.
  - Converted to a quality figure through a 2047-entry table at `0x21ec0` (`0x13030`). BDA "signal strength" is
    `(18 − idx) × 1000` (`0x17104`).
- Packet errors: `(reg 0x8B << 8) | reg 0x8C`, same as Linux UCBLOCKS.

---

## 6. Init and power sequence

### 6.1 Host side: CONFIRMED (`0x10400` start, `0x11cc0`, `0x11354`)
1. Read the registry: AtscAgcValue, NtscAgcValue, VideoStandard and others.
2. SELECT_CONFIGURATION.
3. Upload firmware if cold (section 1).
4. Send `DE 00` (power on, no reply).
5. Send `0B` and read 1 byte. It must be non-zero (high speed).
6. Create the I2C object and the demod/tuner object. Neither touches the bus at construction.
7. Initialise the CX25843 and load its audio firmware. This is analog-only (6.3).
8. When the BDA (digital) filter is used: send `51` and run the VSB init (5.2-5.3).
9. Tune (5.5).
10. Stream (2.3).
11. Power down or stop: send `DC 00`. Resume repeats steps 3 and 4.

### 6.2 Firmware GPIO actions: CONFIRMED sequences; pin meanings INFERRED
Port D: `gpio(n,v)` sets `IOD.n=v` and `OED.n=1`. Delays are from `fw:0x1728` (ms). Firmware boot (`fw:0x0eba`) sets IOD=0x87,
OED=0x87.

- **0xDE power on** (`fw:0x1646`):
  1. IOD=0x83, OED=0xBF.
  2. Wait 10 ms.
  3. IOA=0x08.
  4. Wait 10 ms.
  5. PD6=0, PD3=0, PD0=0, PD4=0.
  6. Wait 10 ms.
  7. PD4=1, PD5=1, PD2=1.
  8. Run the *analog-mode* sequence below.
  9. FIFOPINPOLAR=0x27.

  The device powers up in analog mode.
- **0x51 digital** (`fw:0x17a8`):
  1. PD0=1.
  2. Wait 10 ms.
  3. PD7=0, PD1=1, PD3=1, PA0=1.
  4. Wait 50 ms.
  5. PD7=1, PD5=0.

  **INFERRED**: PD7 is the LGDT3303 RESET_N (50 ms low pulse), PA0/PD3/PD1 select the digital path or enable demod power,
  and PD5 is an analog-side enable.
- **0x50 analog** (`fw:0x18b7`):
  1. PA0=0, PD3=0, PD0=0, PD5=1, PD7=0 (demod held in reset), PD1=0.
  2. Wait 100 ms.
- **0xDC power off** (`fw:0x198c`), only if powered:
  1. FIFOPINPOLAR=0x20.
  2. Stop EP2 and EP8.
  3. PD0=1, PD1=0, PD2=0.
  4. IOA=0.

A Linux driver only has to send `DE 00` and then `51`. The firmware performs every reset and mode GPIO step. The driver needs no
raw GPIO writes for ATSC.

### 6.3 CX25843 (0x44): analog only
- Chip revision = reg 0x100 & 0xF. The driver loads `GTaudC.rom` if rev ≥ 4, otherwise `GTaudB.rom` (`0x13f04`).
- Download protocol: reg 0x803=0x0b, address regs 0x800/0x801, data, then 0x803=0x13. This matches Linux
  `cx25840-firmware.c` start/end_fw_load.
- **Confirmed**: `gtaudb.rom` and `gtaudc.rom` are CX2584x audio microcontroller firmware. Both start with an 8051 `LJMP`
  (`02 2d b6…`, `02 27 bb…`).
- No CX25843 access is part of the digital path. **INFERRED**: Linux ATSC support can ignore the CX25843 entirely.

---

## 7. Minimal Linux recipe
```
probe:  if cold (bMaxPower == 0x32):
            upload onairgt_fx2.bin via 0xA0 (CPUCS=1, 512-byte chunks @0x0000.., CPUCS=0); wait for re-enumeration
        usb_set_interface(0, 6); CLEAR_FEATURE(HALT) on EP 0x01 and 0x81   (firmware keeps stale data toggles)
        cmd(0xDE,{0x00}); cmd(0x0B) → expect 0x80
frontend_attach: cmd(0x51) → expect 0x01
        lgdt330x_attach({.demod_chip=LGDT3303, .serial_mpeg=0, .clock_polarity_flip=0}, 0x0e)
        on 8VSB setup (set_ts_params): reg 0x47 = 0x88; reg 0x87 = (v & 0xf5) | 0x05   (REQUIRED, see hardware.md)
        tuner: tuner-simple TUNER_LG_TDVS_H06XF @0x61 (CB 0xCE, AB 0x50 at init; center + 44 MHz, no offset)
i2c_xfer: write → [0x08, addr, len, data…] rx 1; read/write-read → [0x09, wlen, rlen, addr, wdata…] rx 1+rlen (skip status)
streaming_ctrl(on):  cmd(0x38,{0x03,0x00})   (lgdt330x keeps reg00 bit 7 clear)
streaming_ctrl(off): cmd(0x37)
stream: ISOC EP 0x82, 940-byte frames, ≥32 frames/URB, ~8 URBs; dvb_dmx_swfilter() on each frame's actual_length
        (or try alt 0 + BULK EP 0x82 512, like cxusb)
```
Command transport is the same as cxusb: write to EP 0x01, read from EP 0x81, with `generic_bulk_ctrl_endpoint = 0x01` and
`generic_bulk_ctrl_endpoint_response = 0x81`.

## 8. Open questions
Hardware answers (details in [hardware.md](hardware.md)):
- Q1/Q2: reg 0x87 resets to 0xfb. The Windows tweak (0x87 → 0xf5, 0x47 → 0x88) is required; without it the TS is
  garbage. No `clock_polarity_flip` value reproduces it.
- Q3: Linux center + 44 MHz locks; no offset is needed.
- Q4: bulk TS on alt 0 works as well as iso on alt 6.
- Q6: rev 0x1205 is the warm firmware of a C2 EEPROM at 0x51; the tested unit never runs cold.

Original questions:
1. LGDT3303 reg 0x87 reset value. This decides which Linux `clock_polarity_flip` matches the Windows RMW `(v&0xF5)|5`.
2. Reg 0x47: Windows writes 0x88. Upstream `lgdt3303_8vsb_44_data` writes 0x8b (Linux `drivers/media/dvb-frontends/lgdt330x.c`). The cxusb
   FusionHDTV5 USB Gold resume table writes 0x88 (Linux `cxusb.c`, `cxusb_aver_power_ctrl`). A Linux driver probably needs an extra
   `47=0x88` write after set_frontend; test both. Related: OnAir Creator (11ba:1003, pvrusb2) uses `clock_polarity_flip=1`
   (0x87=0xF3), which is not identical to the Windows RMW `(v&0xF5)|0x05`.
3. Tuner IF offset: Windows uses +45.75 MHz. Determine whether Windows apps pass center−1.75 MHz (5.5); verify by lock test.
4. Whether bulk TS on alt 0 works. Windows only uses iso on alt 6.
5. Exact GPIO pin roles (PD7, PA0, PD1, PD3, PD5, PD2) are inferred from sequences only.
6. Cold bcdDevice (0x1205) and the EEPROM type were not observed in code. They should be checked with `lsusb -v` on a cold device.
