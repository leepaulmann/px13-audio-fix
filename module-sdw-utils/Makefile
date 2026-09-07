# snd-soc-sdw-utils rebuilt from the running kernel's stable sources (fetched
# into ./src by fetch-sources.sh) plus the patches in ./patches.
obj-m := snd-soc-sdw-utils.o
-include $(src)/src/objects.mk
snd-soc-sdw-utils-y := $(addprefix src/,$(SDW_UTILS_OBJS))
ccflags-y += -I$(src)/src

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

# Follow the toolchain the TARGET kernel was built with (see module/Makefile).
LLVM ?= $(shell grep -qs '^CONFIG_CC_IS_CLANG=y' $(KDIR)/.config && echo 1)
LLVMARG := $(if $(LLVM),LLVM=$(LLVM))

all:
	@test -f src/objects.mk || { echo "run ./fetch-sources.sh first"; exit 1; }
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVMARG) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVMARG) clean
