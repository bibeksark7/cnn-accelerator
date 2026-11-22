# Firmware build (docs/decisions.md D-038, D-042).
#
#   make APP=<app> [OUT=<dir>]      build apps/<app>/ into <dir> (default ../sim_build/firmware/<app>)
#
# Outputs in OUT: <app>.elf, <app>.bin, <app>.hex (the $readmemh RAM image for soc_top's RAM_INIT),
# <app>.map, <app>.lst (disassembly), <app>.size, toolchain.txt (compiler version).
# Generated sources (weights, images) are written to OUT by the app's generator rule, never into
# the source tree.

.DEFAULT_GOAL := all

APP        ?= smoke
OUT        ?= ../sim_build/firmware/$(APP)
RAM_BYTES  ?= 65536
PREFIX     ?= riscv64-unknown-elf-
PYTHON     ?= python3

CC      := $(PREFIX)gcc
OBJCOPY := $(PREFIX)objcopy
OBJDUMP := $(PREFIX)objdump
SIZE    := $(PREFIX)size

ARCH    := -march=rv32im_zicsr -mabi=ilp32
CFLAGS  := $(ARCH) -O2 -g -std=c11 -ffreestanding -fno-tree-loop-distribute-patterns \
           -mstrict-align -mno-relax -ffunction-sections -fdata-sections \
           -Wall -Wextra -Werror -Icommon -I$(OUT)
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -static -mno-relax -T common/link.ld \
           -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-Map,$(OUT)/$(APP).map

COMMON_SRC := common/crt0.S common/accel.c common/libc.c
APP_SRC    := $(wildcard apps/$(APP)/*.c)
# Optional per-app generated sources and rules (apps/<app>/app.mk may add to GEN_SRC).
GEN_SRC    :=
-include apps/$(APP)/app.mk

ifeq ($(APP_SRC),)
$(error no sources in apps/$(APP))
endif

all: $(OUT)/$(APP).hex $(OUT)/$(APP).lst $(OUT)/$(APP).size $(OUT)/toolchain.txt

$(OUT):
	mkdir -p $@

$(OUT)/$(APP).elf: $(COMMON_SRC) $(APP_SRC) $(GEN_SRC) common/link.ld $(wildcard common/*.h) | $(OUT)
	$(CC) $(CFLAGS) $(LDFLAGS) $(COMMON_SRC) $(APP_SRC) $(GEN_SRC) -lgcc -o $@

$(OUT)/$(APP).bin: $(OUT)/$(APP).elf
	$(OBJCOPY) -O binary $< $@

$(OUT)/$(APP).hex: $(OUT)/$(APP).bin tools/bin2hex.py
	$(PYTHON) tools/bin2hex.py $< $@ $(RAM_BYTES)

$(OUT)/$(APP).lst: $(OUT)/$(APP).elf
	$(OBJDUMP) -d -S $< > $@

$(OUT)/$(APP).size: $(OUT)/$(APP).elf
	$(SIZE) -A $< > $@

$(OUT)/toolchain.txt: | $(OUT)
	$(CC) --version | head -n 1 > $@

clean:
	rm -rf $(OUT)

.PHONY: all clean
