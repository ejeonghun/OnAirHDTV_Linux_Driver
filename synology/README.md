# OnAir GT on Synology DSM / Xpenology

> **EXPERIMENTAL. NOT TESTED ON REAL DSM HARDWARE.**
> The bundles build reproducibly, and each module's vermagic and symbol
> dependencies are checked against the real DSM kernel build tree. Nobody has
> loaded them on a running DSM system yet. Loading a kernel module that does
> not fit the running kernel can crash the NAS. Try it only on a box you can
> recover, and report results in an issue.

DSM ships without the Linux DVB stack. To use the OnAir GT (USB `11ba:1101`,
ATSC 8VSB) on DSM 7.2, you have to add these modules to the DSM kernel:

| module | from | role |
|---|---|---|
| `rc-core` | DSM's own copy if `modprobe rc-core` finds one, otherwise `fallback/rc-core.ko` (built from DSM's unchanged RC config) | remote-control core, needed by `dvb_usb_v2` |
| `dvb-core` | bundle | DVB API, `/dev/dvb/adapterN/*` |
| `dvb_usb_v2` | bundle | DVB USB framework |
| `lgdt330x` | bundle | LGDT3303 demodulator |
| `tuner-types`, `tuner-simple` | bundle | LG TDVS-H06xF tuner |
| `dvb-usb-onairgt` | bundle | this driver |

The bundled modules are built from Synology's GPL kernel source with
Synology's toolchain. They use the exact `.config` from Synology's toolkit
("dev" tarball) for that platform. At most, `drivers/media` options are added.

## Which bundle do I need?

On the NAS, run:

```sh
uname -r                                          # e.g. 5.10.55+ or 4.4.302+
grep '^unique=' /etc.defaults/synoinfo.conf       # e.g. unique="synology_r1000_923+"
```

The word after `synology_` is the platform. The loader (RR, Arc, arpl...)
also shows it.

| DSM 7.2 platform | models (common Xpenology choices) | kernel | status |
|---|---|---|---|
| `epyc7002` | SA6400 | 5.10.55+ | built and verified offline |
| `r1000` | DS923+, DS723+, DS1522+, RS422+ | 4.4.302+ | built and verified offline |
| `geminilakenk` | DS225+, DS425+ | 5.10.55+ | built and verified offline |
| `r1000nk` | DS725+ | 5.10.55+ | CI build only |
| `v1000nk` | DS925+, DS1825+ | 5.10.55+ | CI build only |
| `geminilake` | DS920+, DS720+, DS420+, DS220+, DVA1622 | 4.4.302+ | CI build only |
| `apollolake` | DS918+, DS718+, DS418play | 4.4.302+ | CI build only |
| `v1000` | DS1621+, DS1821+, DS2422+, RS1221+ | 4.4.302+ | CI build only |
| `broadwellnk` | DS3622xs+, DS1621xs+, RS4021xs+ | 4.4.302+ | CI build only |
| `denverton` | DVA3221, DVA3219 | 4.4.302+ | CI build only |

The model list is a guide only. The platform word from `synoinfo.conf` decides
which bundle you need.

DS923+ is `r1000` and runs **Linux 4.4.302** on DSM 7.2. It is not a 5.10
platform. The 5.10.55 platforms of DSM 7.2 are `epyc7002` and the `*nk`
platforms.

The bundle has to match both the kernel release and the platform. All 4.4
platforms report the same `4.4.302+`, but their kernel configurations differ.
The installer and the loader compare `uname -r` and the platform in
`synoinfo.conf` with the bundle's `BUILDINFO`, and refuse to run when either
differs (`--force` / `FORCE=1` overrides this).

Bundles are attached to the GitHub Releases as
`onairgt-dsm-<platform>-7.2-<kernel>.tgz`. CI builds them as artifacts too.

## Install

1. Enable SSH: Control Panel > Terminal & SNMP > Enable SSH service.
2. Copy the bundle to the NAS, for example into `/volume1/homes/<you>/`.
3. SSH in and become root:

   ```sh
   ssh you@nas
   sudo -i
   cd /volume1/homes/you
   tar xzf onairgt-dsm-epyc7002-7.2-5.10.55+.tgz
   cd onairgt-dsm-epyc7002-7.2-5.10.55+
   cat BUILDINFO VERIFY.txt
   ./install-dsm.sh
   ```

   The installer does the following:
   - copies the bundle to `/usr/local/onairgt` (`--prefix` changes this)
   - writes `/usr/local/etc/rc.d/onairgt-dvb.sh`
   - loads the modules once and prints the relevant `dmesg` lines

   **Optional: firmware.** Do this only if `dmesg` shows the device in cold
   state, or shows a request for `dvb-usb-onairgt-01.fw` failing. Most units
   have a programmed EEPROM and boot their own FX2 firmware; only
   blank-EEPROM units need the host to upload it. The firmware is not
   redistributable, so take it from your own Windows driver
   (`OnAirGt64.sys` or `OnAirGt.sys`), or use a raw 7168-byte
   `onairgt_fx2.bin` extracted earlier:

   ```sh
   ./install-dsm.sh --firmware ../OnAirGt64.sys
   ```

   The installer checks the image's SHA-256 before it installs anything. It
   writes the image to `/lib/firmware/dvb-usb-onairgt-01.fw` and keeps a copy
   in the prefix. The loader restores that copy if a DSM update removes it.

4. Load the modules at boot. DSM 7 does not reliably run `rc.d` scripts, so add
   a Task Scheduler task:
   Control Panel > Task Scheduler > Create > Triggered Task > User-defined
   script.
   - General: User `root`, Event `Boot-up`, Enabled
   - Task Settings > Run command: `/usr/local/onairgt/onairgt-dsm.sh start`

   The loader is idempotent, so it does no harm if both the `rc.d` hook and the
   task run it.

5. Plug in the stick. Check the result:

   ```sh
   /usr/local/onairgt/onairgt-dsm.sh status
   ls -l /dev/dvb/adapter0/
   ```

   The expected nodes are `demux0`, `dvr0`, `frontend0` and `net0`.

### What the loader does

`onairgt-dsm.sh start` does the following, in order:

1. It refuses to run when `uname -r` differs from the bundle. `FORCE=1`
   overrides this, at your own risk.
2. If you installed the optional firmware, it copies the firmware back to
   `/lib/firmware` whenever a DSM update has removed it.
3. It runs `modprobe` for the DSM modules listed in `modules.load` (`usbcore`
   and `rc-core`). If DSM has no `rc-core`, it loads `fallback/rc-core.ko`.
4. It runs `insmod` for the bundled modules, in `modules.load` order. Modules
   that are already loaded are skipped.
5. It installs a udev rule `SUBSYSTEM=="dvb", MODE="0666"` and waits up to 20 s
   for the adapter. A blank-EEPROM unit re-enumerates after the firmware
   upload before the adapter appears.
6. It creates any missing `/dev/dvb/adapterN/*` nodes from
   `/sys/class/dvb/*/uevent`, in case devtmpfs/udev did not. You can also run
   this step alone with `onairgt-dsm.sh nodes`, for example after replugging
   the stick.

`/usr/local/onairgt/onairgt.conf` holds two settings:
- `ONAIRGT_OPTS`: module options. For example, `xfer=1` selects bulk
  transfers instead of isochronous ones, and `clock_flip=1` changes the
  lgdt330x clock polarity.
- `DVB_MODE`: the permissions of the device nodes.

The default mode `0666` lets non-root services (TVHeadend's package user,
Docker) open the tuner. Any local user can do the same. Tighten the mode if
that matters to you.

DSM kernels are built with `CONFIG_MODULE_SIG=y`, but not `MODULE_SIG_FORCE`.
The modules are unsigned, so loading them logs `module verification failed
... tainting kernel` once. That message is expected.

## TVHeadend

### Option A: SynoCommunity package

1. Package Center > Settings > Package Sources > Add
   `https://packages.synocommunity.com/`.
2. Install **Tvheadend**. It runs as the package user `sc-tvheadend`, so the
   `/dev/dvb` nodes must be readable and writable by that user. The default
   `DVB_MODE=0666` covers this.
3. Open `http://nas:9981`. Go to Configuration > DVB Inputs > TV adapters.
   The adapter shows as an ATSC-T frontend ("LG Electronics LGDT3303 VSB/QAM
   Frontend").
4. Create an ATSC-T network. You can use the scan tables in this repository
   (`tools/scan-tables/`), or set the muxes by hand.

The package has to start after the modules are loaded. If the adapter is
missing, restart the package from Package Center after boot. You can also
add `synopkg restart tvheadend` to the end of the boot-up task.

### Option B: Container Manager (Docker)

The Container Manager GUI cannot pass devices to a container, so use a
Project (docker compose):

```yaml
services:
  tvheadend:
    image: lscr.io/linuxserver/tvheadend:latest
    container_name: tvheadend
    environment:
      - PUID=1026        # id -u of a DSM user
      - PGID=100
      - TZ=Asia/Seoul
    volumes:
      - /volume1/docker/tvheadend/config:/config
      - /volume1/recordings:/recordings
    devices:
      - /dev/dvb:/dev/dvb
    ports:
      - 9981:9981
      - 9982:9982
    restart: unless-stopped
```

`/dev/dvb` must exist when the container starts. Start the project after the
boot-up task has run, or restart the container.

## Uninstall

```sh
sudo /usr/local/onairgt/uninstall-dsm.sh            # keeps /lib/firmware copy
sudo /usr/local/onairgt/uninstall-dsm.sh --purge-firmware
```

The uninstaller does not delete the Task Scheduler task. Delete it by hand.

## Troubleshooting

| symptom | check |
|---|---|
| `insmod: ERROR ... Invalid module format` | The bundle does not match the kernel. Compare `uname -r` with `BUILDINFO`, and `dmesg` for `version magic`. Use the bundle for your platform. |
| `Unknown symbol ...` in `dmesg` | A dependency is not loaded, or it was loaded in the wrong order. Run `onairgt-dsm.sh stop` and then `start`. Report the symbol name. |
| no `/dev/dvb` but `lsusb` shows `11ba:1101` | Run `onairgt-dsm.sh nodes`. If `dmesg` shows the device in cold state or a failed request for `dvb-usb-onairgt-01.fw`, the unit has a blank EEPROM: install the firmware with `install-dsm.sh --firmware ../OnAirGt64.sys` (optional otherwise; most units boot their own firmware). |
| TVHeadend shows no adapter | Check the node permissions (`ls -l /dev/dvb/adapter0`), then restart TVHeadend after the modules are loaded. |
| the stick stops working after a DSM update | DSM updates can replace the kernel. If `uname -r` changed, you need a new bundle. Rerun `install-dsm.sh` from it (add `--firmware ...` only if your unit needed the firmware before). |
| no lock / no picture | Try `ONAIRGT_OPTS="xfer=1"`, then `clock_flip=1`, in `onairgt.conf`, and run `onairgt-dsm.sh restart`. |

Collect `uname -a`, `cat BUILDINFO`, `onairgt-dsm.sh status` and
`dmesg | tail -100` for bug reports.

## Building the bundles

Building runs on any x86_64 Linux host with
`build-essential bison flex bc libelf-dev libssl-dev xz-utils curl kmod`. It
needs about 3 GB of disk space per platform, plus about 0.7 GB of downloads
per platform, which are cached in `synology/work/dl`.

```sh
synology/build-dsm.sh epyc7002 7.2        # -> synology/dist/onairgt-dsm-epyc7002-7.2-5.10.55+.tgz
synology/build-dsm.sh r1000 7.2
```

To build in a clean container:

```sh
docker run --rm -v "$PWD":/src -w /src ubuntu:24.04 sh -c \
  'apt-get update -q && apt-get install -y -q build-essential bison flex bc libelf-dev libssl-dev xz-utils curl kmod git &&
   synology/build-dsm.sh epyc7002 7.2'
```

`.github/workflows/dsm.yml` builds the platform matrix. On `v*` tags it
attaches the bundles to the release.

### How the build stays faithful to DSM

| input | source |
|---|---|
| toolchain | `ToolChain/toolchain/7.2-72806/.../<platform>-gcc1220_glibc236_x86_64-GPL.txz`: the same GCC 12.2.0 that `compile.h` reports for the DSM kernel |
| kernel `.config`, `Module.symvers`, `kernel.release` | `ToolChain/toolkit/7.2/<platform>/ds.<platform>-7.2.dev.txz`, from `usr/lib/modules/DSM-7.2/build` in the sysroot |
| kernel source | `ToolChain/Synology NAS GPL Source/7.2-72806/<platform>/linux-<ver>.x.txz` (5.10.55 platforms use the `epyc7002` tree, whose `synoconfigs` covers all of them) |

All three come from `https://global.synologydownload.com/download/ToolChain/`.
`synology/SHA256SUMS` pins the hashes of the downloads. Set
`STRICT_CHECKSUMS=1` to make the build fail on downloads that are not pinned.

The build does the following:
- Starts from the DSM `.config`. The 4.4.302 kernels (for example `r1000`)
  already have the whole DVB stack configured as modules, but DSM 7 does not
  ship those modules. For them the configuration is used unchanged. For the
  5.10.55 kernels, which have no media support, the build adds
  `MEDIA_SUPPORT=m`, digital TV only, `DVB_CORE`, `DVB_USB_V2`, `DVB_LGDT330X`
  and `MEDIA_TUNER_SIMPLE`, then runs `olddefconfig`.
- Aborts if any symbol outside `drivers/media` changed. The one exception is
  `SND_USB_AUDIO_USE_MEDIA_CONTROLLER`, which only affects `snd-usb-audio`, a
  module this build does not rebuild. Options that the GPL source has but the
  DSM kernel lacks are forced off. Options that a newer DSM kernel has but the
  source's Kconfig does not know (seen on `geminilakenk`: some `SYNO_SATA_*`
  and `SYNO_AHCI_*` options) are tolerated only if no header and no
  `drivers/media` file refers to them. The bundle includes the full diff as
  `config.delta`.
- Sets `EXTRAVERSION` so that `make kernelrelease` equals the DSM
  `kernel.release` (`5.10.55+`). Otherwise it aborts.
- Builds the modules against the DSM `Module.symvers`. It aborts on any
  modpost "undefined" warning.
- Checks the vermagic of every `.ko` against the vermagic expected from the
  DSM `.config`, for example `5.10.55+ SMP mod_unload`.
- Checks that every undefined symbol of every `.ko` is exported by the DSM
  kernel, a DSM module, or another module in the bundle.
  `VERIFY.txt` lists, per module, the vermagic and where its symbols come from.
- Compiles `dvb-usb-onairgt` with the target tree's own `dvb_usb.h`,
  `lgdt330x.h` and `tuner-simple.h`, not `fallback-kheaders/`, so that
  its structure layouts match the `dvb_usb_v2.ko` it loads with.
- Loads `dvb-usb-onairgt` last. It reaches `lgdt330x` and `tuner-simple`
  through `dvb_attach()`, and `modprobe` cannot find them on DSM because they
  are not in `/lib/modules`.

As an external cross-check, the r1000 `dvb-core.ko` and `dvb_usb_v2.ko` were
compared with the ones that the Arc loader's module repository
(AuxXxilium/arc-modules, `r1000-7.2-4.4.302`) ships to Xpenology users. The
vermagic, file size, and the `.text`, `.data`, `.rodata` and
`.gnu.linkonce.this_module` sections are identical. Only a string section
differs by a few bytes. For epyc7002, the vermagic `5.10.55+ SMP mod_unload`
and the `struct module` size (0x3c0) match Arc's DSM 7.2 modules. No
`epyc7002` DVB module exists elsewhere to compare against.

## Prior art

- [belgio99/dsm7-dvb-drivers](https://github.com/belgio99/dsm7-dvb-drivers):
  DVB USB drivers on DSM 7 (geminilake, 4.4.302+), built with
  b-rad-NDi/Embedded-MediaDrivers and media_build. Modules are loaded with
  `insmod` from `/usr/local/lib/modules/<uname -r>` by a boot task.
- [SynoCommunity spksrc](https://github.com/SynoCommunity/spksrc), with
  `synokernel-usbserial` and `mk/spksrc.kernel`: the same GPL-source +
  synoconfig + toolchain approach for kernel modules. This build borrows its
  `EXTRAVERSION`/objtool handling.
- [AuxXxilium/arc-modules](https://github.com/AuxXxilium/arc-modules):
  the Arc loader's per-platform module sets. Its `r1000-7.2-4.4.302` set
  includes `dvb-core`, `dvb_usb_v2` and `rc-core`, which also shows that
  stock DSM 7.2 does not provide them. It was used only as a reference for
  the comparison above.
- [robertklep/dsm7-usb-serial-drivers](https://github.com/robertklep/dsm7-usb-serial-drivers):
  per-platform prebuilt modules, and the "Invalid module format" pitfall.
