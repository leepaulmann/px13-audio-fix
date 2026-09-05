obj-m := snd-soc-tas2783-sdw.o
snd-soc-tas2783-sdw-y := tas2783-sdw.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

# --- target-kernel API probes -------------------------------------------------
# sdca_parse_function() and sdw_slave_wait_for_init() differ between kernel
# trees that share a LINUX_VERSION_CODE (Arch 7.1.9-arch1-2 carries a different
# sdca_parse_function() signature than the CachyOS 7.1.x this driver was written
# against), so probe the headers of the kernel actually being built against
# instead of guessing from a version macro. In kbuild context $(srctree) is that
# tree; standalone it is unset and the value is unused.
KHDR := $(if $(srctree),$(srctree),$(KDIR))

ccflags-y += $(shell awk '/^int sdca_parse_function/,/;/' \
	$(KHDR)/include/sound/sdca_function.h 2>/dev/null \
	| grep -q sdca_function_desc && echo -DHAVE_SDCA_PARSE_FUNCTION_DESC)
ccflags-y += $(shell grep -q sdw_slave_wait_for_init \
	$(KHDR)/include/linux/soundwire/sdw.h 2>/dev/null \
	&& echo -DHAVE_SDW_SLAVE_WAIT_FOR_INIT)

ifneq ($(KERNELRELEASE),)
$(info px13 tas2783: kernel API probes ->$(if $(ccflags-y), $(ccflags-y), none))
endif

# Follow the toolchain the TARGET kernel was built with. CachyOS builds its
# kernels with clang, Arch stock and Fedora with gcc, and mixing the two fails
# on unknown compiler flags (-mpreferred-stack-boundary, -mrecord-mcount, ...).
# Override with LLVM=1 or LLVM= if the probe is ever wrong.
LLVM ?= $(shell grep -qs '^CONFIG_CC_IS_CLANG=y' $(KDIR)/.config && echo 1)
LLVMARG := $(if $(LLVM),LLVM=$(LLVM))

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVMARG) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVMARG) clean
