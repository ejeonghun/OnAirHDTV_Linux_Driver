# dvb-usb-onairgt
#
#   make                 build for KVER (default: running kernel)
#   make install         install into /lib/modules/KVER/updates and run depmod
#   make uninstall       remove that copy and run depmod
#   make dkms-install    copy the source to /usr/src, dkms add/build/install
#   make dkms-remove     remove every DKMS build and the /usr/src copy
#   make dkms-src DEST=  copy only the files DKMS needs to DEST (packaging, CI)
#   make clean           remove build output (keeps the header cache)
#   make distclean       also remove the downloaded kernel headers
#
# Kernel-private headers are resolved by kheaders.sh (see there) and cached in
# KHEADERS_CACHE. The kbuild part lives in Kbuild, so this file also works when
# DKMS passes KERNELRELEASE on the command line.

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
KHEADERS_CACHE ?= $(CURDIR)/kheaders
MODULE := dvb-usb-onairgt
PKG := $(shell sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' $(CURDIR)/dkms.conf)
VERSION := $(shell sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' $(CURDIR)/dkms.conf)
SRC_FILES := onairgt.c Kbuild Makefile kheaders.sh dkms.conf fallback-kheaders LICENSE
KHEADERS = KVER=$(KVER) sh $(CURDIR)/kheaders.sh $(KDIR) $(KHEADERS_CACHE)

all: modules

modules:
	@test -d $(KDIR)/ || { echo "no kernel build dir $(KDIR); install the kernel headers for $(KVER)" >&2; exit 1; }
	inc=$$($(KHEADERS)) && \
	$(MAKE) -C $(KDIR) M=$(CURDIR) ONAIRGT_INCLUDES="$$inc" modules

install: modules
	$(MAKE) -C $(KDIR) M=$(CURDIR) INSTALL_MOD_DIR=updates modules_install
	depmod -a $(KVER)

uninstall:
	rm -f /lib/modules/$(KVER)/updates/$(MODULE).ko*
	depmod -a $(KVER)

dkms-src:
	@test -n "$(DEST)" || { echo "usage: make dkms-src DEST=<dir>" >&2; exit 1; }
	mkdir -p $(DEST)
	cp -R $(SRC_FILES) $(DEST)/

dkms-install:
	-dkms remove $(PKG)/$(VERSION) --all >/dev/null 2>&1
	rm -rf /usr/src/$(PKG)-$(VERSION)
	$(MAKE) dkms-src DEST=/usr/src/$(PKG)-$(VERSION)
	dkms add $(PKG)/$(VERSION)
	dkms build $(PKG)/$(VERSION) -k $(KVER)
	dkms install $(PKG)/$(VERSION) -k $(KVER)

dkms-remove:
	-dkms remove $(PKG)/$(VERSION) --all
	rm -rf /usr/src/$(PKG)-$(VERSION)

clean:
	@if [ -d $(KDIR)/ ]; then $(MAKE) -C $(KDIR) M=$(CURDIR) clean; fi
	rm -f *.o *.ko *.mod *.mod.c .*.cmd Module.symvers modules.order

distclean: clean
	rm -rf kheaders

.PHONY: all modules install uninstall dkms-src dkms-install dkms-remove clean distclean
