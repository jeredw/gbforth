gbforth: gbforth.asm builtin.asm hardware.inc ibmpc1.inc
	rgbasm -o gbforth.o gbforth.asm
	rgbasm -o builtin.o builtin.asm
	rgblink -o gbforth.gb gbforth.o builtin.o
	rgbfix -v -t "GBFORTH" -m 0x3 -r 0x2 -p 0xFF gbforth.gb

clean: .PHONY
	rm *.o