# Gameboy Forth

Gameboy Forth lets you use an onscreen keyboard to enter little forth programs
and run them on your Gameboy. This will be a boring symbol based forth, although
it might be fun to build a colorForth for Gameboy Color some day.

Programs are divided into pages of 32x20 characters or 640 bytes, one VRAM
tilemap page. To save source code, we target an
[MBC1](https://gbdev.io/pandocs/MBC1.html) cartridge with 8K of battery-backed
save RAM, allowing for 12 full pages.

Programs are compiled into WRAM. The DMG has 8K of WRAM which should hopefully
be ample, but if not the GBC has a whopping 32K.