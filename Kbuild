# kbuild reads this file instead of Makefile, so the Makefile stays a plain
# wrapper even when DKMS passes KERNELRELEASE on the command line.
obj-m := dvb-usb-onairgt.o
dvb-usb-onairgt-y := onairgt.o
ccflags-y += $(ONAIRGT_INCLUDES)
