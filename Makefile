gbforth: gbforth.asm hardware.inc ibmpc1.inc
	rgbasm -o gbforth.o gbforth.asm
	rgblink -o gbforth.gb gbforth.o
	rgbfix -v -p 0xFF gbforth.gb

clean: .PHONY
	rm *.o