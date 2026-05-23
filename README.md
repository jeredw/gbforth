# Gameboy Forth

Gameboy Forth lets you use an onscreen keyboard to enter little Forth programs
and run them on your Gameboy. This will be a boring symbolic Forth, although it
might be fun to build a colorForth for Gameboy Color some day.

Programs are divided into pages of 32x32 characters or 1KB, since this fits
nicely on one VRAM tilemap page. To save programs, we target an
[MBC1](https://gbdev.io/pandocs/MBC1.html) cartridge with 8K of battery-backed
save RAM, allowing for 8 full pages. On boot, if save RAM starts with
`(gbforth)`, we preserve it, otherwise it is reset.

Forths usually work interactively, executing an outer interpreter loop to scan
one input key at a time and printing output immediately. Gameboy Forth instead
buffers the whole program. When you press START, the WRAM dictionary is reset
and the program is re-interpreted. If there is a syntax error, Gameboy Forth
will return to the editor with the cursor positioned near it. Otherwise the
cursor will not reappear until you press START again.