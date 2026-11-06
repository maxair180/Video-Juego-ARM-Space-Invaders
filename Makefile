# Makefile for Space Invaders Bare-Metal on Raspberry Pi Pico (RP2040)
# 100% ARM Assembly (ARMv6-M Cortex-M0+)

TOOLCHAIN ?= C:/Users/cachi/arm-toolchain/arm-gnu-toolchain-13.3.rel1-mingw-w64-i686-arm-none-eabi/bin/arm-none-eabi-
AS        := $(TOOLCHAIN)as
LD        := $(TOOLCHAIN)ld
OBJCOPY   := $(TOOLCHAIN)objcopy
OBJDUMP   := $(TOOLCHAIN)objdump
PYTHON    ?= python

ASFLAGS   := -mcpu=cortex-m0plus -mthumb
LDFLAGS   := -T memmap.ld

OBJS      := boot2.o crt0.o system.o timer.o inputs.o video.o font.o main.o

all: space_invaders.uf2

%.o: %.s
	$(AS) $(ASFLAGS) $< -o $@

space_invaders.elf: $(OBJS) memmap.ld
	$(LD) $(LDFLAGS) -o $@ $(OBJS)

space_invaders.bin: space_invaders.elf
	$(OBJCOPY) -O binary $< $@

space_invaders.uf2: space_invaders.bin uf2conv.py
	$(PYTHON) uf2conv.py $< $@

flash: space_invaders.uf2
	@if exist D:\ ( \
		echo Flashing to D:\... && \
		copy space_invaders.uf2 D:\ \
	) else ( \
		echo Drive D: not found. Put Pico in BOOTSEL mode. \
	)

clean:
	rm -f *.o *.elf *.bin *.uf2

.PHONY: all clean flash

