**English** | [한국어](README.ko.md)

# OnAir GT USB HDTV Linux DVB Driver

[![Build](https://github.com/ejeonghun/OnAirHDTV_Linux_Driver/actions/workflows/build.yml/badge.svg)](https://github.com/ejeonghun/OnAirHDTV_Linux_Driver/actions/workflows/build.yml)

Out-of-tree Linux kernel driver for the **OnAir GT USB HDTV** ATSC tuner. It receives ATSC 8VSB (terrestrial and Korean/US cable) and exposes the tuner as a standard DVB device, `/dev/dvb/adapterN`.

## Supported Hardware

| Device | USB ID | USB Bridge | Demod | Tuner | Frontends |
|--------|--------|-----------|-------|-------|-----------|
| OnAir GT USB HDTV | `11ba:1101` | Cypress CY7C68013A (FX2) | LG LGDT3303 | LG TDVS-H062F (tuner-simple `TUNER_LG_TDVS_H06XF`) | 1 (ATSC 8VSB; QAM untested) |

The board also carries a Conexant CX25843 analog decoder. Analog TV is not supported. The device must be connected at USB 2.0 high speed; otherwise the driver logs `device is not running at USB high speed` and does not start.

## Modules

| Module | Description |
|--------|-------------|
| `dvb-usb-onairgt.ko` | FX2 USB bridge driver (dvb-usb-v2). Uses the in-kernel `dvb_usb_v2`, `lgdt330x` and `tuner-simple` modules. |

The build needs `dvb_usb.h`, `lgdt330x.h` and `tuner-simple.h` from the target kernel's `drivers/media`. Distribution header packages do not ship them, and their structures must match the running `dvb_usb_v2` exactly (three layout epochs: 4.4-4.16, 4.17-5.4, 5.5 and later). `kheaders.sh` downloads them from the kernel.org stable tree for the kernel's upstream version, checks the content, records SHA-256 sums and caches them. An internet connection is therefore needed for the first build for each new kernel version. Offline, the bundled Linux 7.0 copies (`fallback-kheaders/`) are used with a warning for kernels 5.5 and later; for older kernels the build stops. When `KDIR` is a full kernel source tree, its own headers are used. Details: [docs/driver-internals.md](docs/driver-internals.md#kernel-private-headers).

## Installation (package)

DKMS packages are attached to the [GitHub Releases](https://github.com/ejeonghun/OnAirHDTV_Linux_Driver/releases). They install the source to `/usr/src/onairgt-<version>/` and build the module for every kernel whose headers are installed. DKMS rebuilds it on kernel updates.

Install the headers for the running kernel first (`linux-headers-$(uname -r)` on Debian/Ubuntu, `kernel-devel-$(uname -r)` on Fedora). On Ubuntu, the in-kernel DVB modules are in `linux-modules-extra-$(uname -r)`.

### Debian / Ubuntu

```sh
sudo apt install ./onairgt-dkms_*.deb       # pulls in dkms
# or, with dkms already installed:
sudo dpkg -i onairgt-dkms_*.deb
```

To remove:

```sh
sudo apt remove onairgt-dkms        # purge also deletes the header cache in /var/cache/onairgt
```

### Fedora

```sh
sudo dnf install ./onairgt-dkms-*.noarch.rpm
```

To remove:

```sh
sudo dnf remove onairgt-dkms
```

Stock RHEL, Rocky and AlmaLinux kernels are built without the DVB subsystem, so the driver cannot load there. See [docs/installation-notes.md](docs/installation-notes.md#supported-distributions).

## Installation (DKMS, from source)

```sh
git clone https://github.com/ejeonghun/OnAirHDTV_Linux_Driver.git
cd OnAirHDTV_Linux_Driver
sudo dkms add .
sudo dkms build onairgt/0.3
sudo dkms install onairgt/0.3
```

`dkms add .` copies the whole checkout to `/usr/src/onairgt-0.3`. `sudo make dkms-install` does the same three steps but copies only the driver files.

To remove:

```sh
sudo dkms remove onairgt/0.3 --all
sudo rm -rf /usr/src/onairgt-0.3
```

DKMS builds keep the downloaded headers in `/var/cache/onairgt/kheaders`.

## Building (manual)

Requires `make`, `gcc`, `curl` or `wget`, and the headers of the target kernel.

```sh
make
sudo make install       # /lib/modules/$(uname -r)/updates, runs depmod
```

To remove:

```sh
sudo make uninstall
```

To build against a specific kernel:

```sh
make KVER=6.8.0-147-generic                    # KDIR defaults to /lib/modules/$KVER/build
make KVER=5.10.55 KDIR=/path/to/linux-5.10.55  # full source tree: uses its own headers
```

Downloaded headers are cached in `./kheaders`; `make distclean` removes them.

## Firmware

Not needed for units that boot their FX2 firmware from the on-board EEPROM. The tested unit does.

Units with a blank EEPROM enumerate "cold" and request `/lib/firmware/dvb-usb-onairgt-01.fw`. Extract it from your own copy of the Windows driver:

```sh
sudo tools/extract-firmware.sh /path/to/OnAirGt64.sys    # or OnAirGt.sys, or a raw 7168-byte image
```

The script checks the SHA-256 of the image before installing it. The cold-start path has not been tested on hardware. Vendor firmware is not distributed with this driver.

## Module Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `xfer` | `0` | TS transfer: `0` isochronous (alt setting 6, as the Windows driver), `1` bulk (alt setting 0). Both verified clean; try `1` on USB controllers or VMs with poor isochronous support. |
| `win_ts` | `1` | Windows LGDT3303 TS setup (reg 0x87, 0x47). Keep `1`: with `0` the TS is corrupt on the tested board. |
| `clock_flip` | `0` | lgdt330x `clock_polarity_flip` (0, 1 or 2). Debugging only. |
| `adapter_nr` | auto | DVB adapter number. |

Example, `/etc/modprobe.d/dvb-usb-onairgt.conf`:

```
options dvb-usb-onairgt xfer=1
```

## Usage

Scan tables in dvbv5 format are in `tools/scan-tables/`:

| File | Channels |
|------|----------|
| `kr-cable-8vsb-std` | Korean/US cable 8VSB, STD plan (hardware-tested) |
| `kr-cable-8vsb-hrc`, `kr-cable-8vsb-irc` | Cable 8VSB, HRC / IRC plans |
| `kr-atsc-terrestrial` | Korean over-the-air ATSC, UHF 14-51 |
| `us-atsc-terrestrial` | US over-the-air ATSC, VHF 2-13 and UHF 14-36 |

```sh
dvbv5-scan -T 4 -o channels.conf tools/scan-tables/kr-cable-8vsb-std
dvbv5-zap -c channels.conf -r -o ktv.ts -t 10 KTV
```

On the tested Korean cable feed, `dvbv5-scan` needs `-T 4`; with the default table timeouts it reports "not found on PMT". The tools are in `dvb-tools` (Debian/Ubuntu) or `v4l-utils` (Fedora).

### TVHeadend

`tools/install.sh` is a one-shot installer: it builds the driver with DKMS and can install TVHeadend (distro package, official apt repository, Docker or source build) and configure it (admin account, ATSC network, muxes from a preset, scan, channel mapping). Run `sudo tools/install.sh --help`. `tools/uninstall.sh` reverses it. Methods, presets and test results: [docs/installation-notes.md](docs/installation-notes.md).

## Tested

| Platform | Kernel | Status |
|----------|--------|--------|
| Ubuntu 26.04 (VMware VM, USB passthrough) | 7.0.0-38-generic | Hardware-tested: lock, scan, 60 s TS capture with 0 sync/TEI/CC errors, TVHeadend (Docker path end to end) |
| Ubuntu 18.04 (GA, HWE), 20.04, 22.04, 24.04 | 4.15, 5.4, 5.4, 5.15, 6.8 | Compile-tested |
| Debian 11, 12, 13 | 5.10, 6.1, 6.12 | Compile-tested |
| Fedora 44 | 7.2 | Compile-tested |
| Vanilla kernel.org | 4.4.302, 5.10.55 | Compile-tested (Synology DSM kernel versions) |
| DKMS packages | Ubuntu 24.04 (6.8), Fedora 44 (7.2) | Install-tested in containers: DKMS builds and installs the module |
| Synology / Xpenology DSM 7.2 | 4.4.302+, 5.10.55+ | Experimental, not loaded on real DSM hardware. See [synology/README.md](synology/README.md). |

Compile matrix: `sh ci/matrix.sh [target ...]` (docker), also run by [.github/workflows/build.yml](.github/workflows/build.yml). Hardware results: [docs/test-report.md](docs/test-report.md).

## Troubleshooting

- Collect a report with `sudo tools/onairgt-doctor.sh` (add `--freq 195` to test lock on one frequency) and attach it to an issue. It never prints passwords.
- No `/dev/dvb/adapterN`: check `lsusb -d 11ba:1101` and `sudo dmesg | grep -iE 'onair|dvb|lgdt|11ba'`. A request for `dvb-usb-onairgt-01.fw` means a cold unit (see [Firmware](#firmware)).
- `device is not running at USB high speed`: use a USB 2.0 (or newer) port, not a USB 1.1 hub.
- Secure Boot: the kernel only loads modules signed with an enrolled key. Check `mokutil --sb-state`, enroll the DKMS key with `sudo mokutil --import /var/lib/dkms/mok.pub` (Ubuntu: `/var/lib/shim-signed/mok/MOK.der`), reboot and choose **Enroll MOK**.
- DKMS build failed: see `/var/lib/dkms/onairgt/0.3/build/make.log`. A failed header download on a pre-5.5 kernel stops the build; rebuild with network access: `sudo dkms install onairgt/0.3 -k $(uname -r)`.
- VMware: attach the tuner with **VM > Removable Devices > USB HDTV-GT > Connect**. To attach it automatically, add `usb.autoConnect.device0 = "vid:0x11ba pid:0x1101"` to the `.vmx` while the VM is off. If isochronous streaming is unreliable in a VM, use `xfer=1`.
- TVHeadend channels listed but nothing plays (no services, `{name-not-set}`): re-run the mapping on the existing install with `sudo tools/install.sh --yes --tvh existing --preset kr-cable-8vsb` (use your preset).

## Documentation

| Document | Contents |
|----------|----------|
| [docs/hardware.md](docs/hardware.md) | Parts, EEPROM boot, USB interface, LGDT3303 TS setup, tuner, throughput |
| [docs/protocol.md](docs/protocol.md) | FX2 firmware and command set, TS streaming, I2C map, ATSC tuning, init sequence |
| [docs/usb-descriptors.txt](docs/usb-descriptors.txt) | USB descriptor dump |
| [docs/driver-internals.md](docs/driver-internals.md) | Driver structure, kernel compatibility, private headers, compile matrix |
| [docs/test-report.md](docs/test-report.md) | Hardware test results |
| [docs/installation-notes.md](docs/installation-notes.md) | `tools/` installer, TVHeadend setup, presets, distribution notes |
| [synology/README.md](synology/README.md) | Experimental Synology / Xpenology DSM 7.2 bundles |

## License

GPL-2.0-or-later. See [LICENSE](LICENSE).

This project is not affiliated with or endorsed by OnAirSolution. The USB protocol was reverse-engineered from the vendor's Windows driver for interoperability. Vendor firmware and driver files are not distributed.
