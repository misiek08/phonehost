obj-m += pm6150_chg.o

# Out-of-tree build. Cross-compiling from a workstation (see README.md) is the
# default path so the phone stays idle:
#
#   make KDIR=/path/to/linux-6.14.7 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
#
KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
