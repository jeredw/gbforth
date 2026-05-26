# Gameboy Forth

Gameboy Forth lets you use an onscreen keyboard to enter little Forth programs
and run them on your Gameboy. This will be a boring symbolic Forth, although it
might be fun to build a colorForth for Gameboy Color some day.

Programs are divided into pages of 32x32 characters or 1KB, since this fits
nicely on one VRAM tilemap page. To save programs, we target an
[MBC1](https://gbdev.io/pandocs/MBC1.html) cartridge with 8K of battery-backed
save RAM, allowing for 8 full pages. On boot, if save RAM starts with
`(gbforth)`, we preserve it, otherwise it is reset.

Forth runs as a REPL that scans one input key at a time and prints output
immediately. This is not 100% true, since modern Forths are line buffered to
allow line editing at least. To make editing on a small screen simpler, Gameboy
Forth buffers your whole program instead of just the current line.

When you press START, the program is re-interpreted. If there is a syntax error,
Gameboy Forth will return to the editor with the cursor positioned near it.
Otherwise the editor cursor will not reappear until you press START again.
Note that `KEY` still uses the on screen keyboard to read input, and if it is
run in an immediate context it will block interpreting the rest of the program.

## VM details

Forth words are compiled into a linked list dictionary that starts with builtins
in ROM and continues with user entries in the Gameboy's 8K WRAM. Since indirect
loads are expensive on the Gameboy CPU and storage is abundant (ish), user words
are direct threaded with explicit `call` instructions.

```
  ; Layout of user word : DOUBLE DUP + ;
  dw link     ; previous word in dictionary
  db 6        ; name length
  db "DOUBLE"
  call _DUP
  call _PLUS
  NEXT
```

The definition of `NEXT` is just `ret`, so dispatch costs 6 + 4 = 10 cycles.
Indirect, implicit threaded Forths have a `DOCOL` interpreter that pushes the
return stack, and a separate `EXIT` to pop, but we don't need that.

Arithmetic is 16 bit. The parameter stack is stored with its first word in `bc`
and the rest of its values in a software stack indexed by `hl`. `hl` points to
the low-order byte of the second stack entry. So `DUP` is:

```
  ; Example DUP implementation
  dw link     ; previous word in dictionary
  db 3        ; name length
  db "DUP"
  inc hl
  ld a, b
  ld [hli], a
  ld [hl], c
  NEXT

  ; Example + implementation
  dw link
  db 1
  db "+"
  ld a, [hld]
  add a, c
  ld c, a
  ld a, [hld]
  adc a, b
  ld b, a
  NEXT
```

### Alternative: hardware stack for parameters?

We could maybe get slightly more compact builtin code by using the 16 bit
hardware stack for parameters, but this makes managing the return stack painful
since we'd want to thread through `jp hl` so `hl` isn't available for a stack
pointer. `NEXT -> op` could be faster, 7 cycles. But pushing and popping the
return stack is much slower (20+ cycles).

```
macro NEXT
  inc hl
  jp hl   ; (assuming code is jp XXXX)
endm

macro PUSHPC
  push hl        ; +4
  ld hl, PCstack ; +3
  ld a, [hli]    ; +2
  ld h, [hl]     ; +2
  ld l, a        ; +1
  pop de         ; +4
  ld a, e        ; +1
  ld [hli], a    ; +2
  ld [hl], d     ; +2
  ld h, d        ; +1
  ld l, e        ; +1
endm

macro EXIT
  ; ...
endm
```

We could fix `hl` as the return stack pointer and thread through `jp Ptr`, but
this would make `NEXT` slow. There might be some cool hack we could do here but
really just doing the simple thing seems to make most sense on this CPU.

### Literals

Many Forths store literals as inline data after a `LITERAL` word. This would
save one byte of program space but costs an extra 16 cycles to load. We'll
instead compile literals as

```
  call _DUP
  ld bc, XXXX
```
