# Gameboy Forth

<img width="320" height="288" alt="image" src="https://github.com/user-attachments/assets/de209b9d-46e8-4988-ac25-1f2bad0b4b16" />

[Try it in your browser](https://jeredw.github.io/gbforth/)

Gameboy Forth lets you use an onscreen keyboard to enter little Forth programs
and run them on your Gameboy. It is a boring monochrome Forth, although
it might be fun to build a
[colorForth](https://en.wikipedia.org/wiki/ColorForth) for the Gameboy Color.

Programs are divided into pages of 32x32 characters or 1KB, since this fits
nicely on one VRAM tilemap page. To save programs, we target an
[MBC1](https://gbdev.io/pandocs/MBC1.html) cartridge with 8K of battery-backed
save RAM, allowing for 8 full code pages. On boot, if save RAM starts with
`( gbforth )`, we preserve it, otherwise it is reset.

Forth traditionally runs as a line buffered REPL which prints helpful
encouragement like `ok` as you type lines. To make editing on a small
screen simpler, Gameboy Forth buffers your whole program instead of just the
current line.

When you press START, the program is re-interpreted. If there is a syntax error,
Gameboy Forth will return to the editor with the cursor positioned near it.
Otherwise the editor cursor will not reappear until you press START again.

Note: `KEY` still uses the on screen keyboard to read input, and if it is run
in interpreter context it will block interpreting the rest of the program.

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

The definition of `NEXT` is just `ret`, so dispatch costs `call + ret` or 10
cycles.

Arithmetic is 16-bit. The parameter stack is stored with its first word in BC
and the rest of its values in a software stack indexed by HL. HL points to the
low-order byte of the second stack entry. So `DUP` is:

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

We could get more compact code by using the hardware stack for parameters.

```
  ; Example DUP implementation with hardware stack
  dw link     ; previous word in dictionary
  db 3        ; name length
  db "DUP"
  ; Assuming we still keep top of stack in bc
  push bc
  NEXT
```

But this makes managing the return stack painful since we'd need to use a
register like HL to track the current code location, instead of implicitly using
PC and SP. So we'd be short a register for tracking the current return stack.
Indirect threading would look something like:

```
; 14 cycles to jump to next address in threaded code for a word
macro NEXT
  ; Read next address from threaded code
  ld a, [hli]   ; +2
  ld e, a       ; +1
  ld a, [hli]   ; +2
  ld d, a       ; +1
  ; Jump to the next address.
  push de       ; +4
  ret           ; +4
endm

; Used by DOCOL to push code position on return stack
; Needs a slow indirect load through PCstack because we don't have enough
; registers to keep track of the return stack.
macro PUSHPC
  ; Stash current code location
  push hl        ; +4
  ; Indirect load return stack pointer from [PCstack] into hl
  ld hl, PCstack ; +3
  ld a, [hli]    ; +2
  ld h, [hl]     ; +2
  ld l, a        ; +1
  ; Push current code location onto the return stack
  pop de         ; +4
  ld a, e        ; +1
  ld [hli], a    ; +2
  ld a, d        ; +1
  ld [hli], a    ; +2
  ; Save return stack pointer
  ld a, l        ; +1
  ld [PCstack], a ; +4
  ld a, h        ; +1
  ld [PCstack+1], a ; +4
  ; Restore current code location
  ld h, d        ; +1
  ld l, e        ; +1
endm

macro EXIT
  ; ...
endm
```

We could fix HL as the return stack pointer and store the current PC in memory,
but this would make `NEXT` slow. There might be some cool hack we could do here
to support indirect threading, but really subroutine threading seems to make
most sense on this CPU.

### Literals

Many Forths store literals as inline data after a `LITERAL` word. This would
save one byte of program space but costs an extra 16 cycles to load. We'll
instead compile literals as

```
  call _DUP
  ld bc, XXXX
```

## Complaints about Forth

Forth is a weird mishmash of many generations of hacky metaprogramming stuff.
It is at best confusing and at worst incoherent.

A big part of the problem is just understanding what the core vocabulary of
the language is. Searching online turned up confused hobbyist forum posts,
strange textbooks from the 80s, and the truly cursed [ANS Forth
standard](https://forth-standard.org/). This standard had the impossible task of
making sense of the mess by writing down what everyone did for 50 years, and the
result is not good.

### Loops

There is no provision for local variables, _except_ for loop indices. `DO ...
LOOP`, the standard `for`-loop construct, basically hijacks the return stack to
bootleg dynamic scope for its state. To read the indices, you go spelunk on the
return stack.

Belatedly I have learned there is also `?DO ... LOOP`. The old non-? `DO` does
not check if its start and end limits are already equal before looping, and will
happily loop 65536 times if they are. Why would you want this behavior? Well,
the extra check does take 40 clock cycles of painful stack shuffling. Ugh.

```
: (?DO) 2DUP = -ROT >R >R ;
```

There are also backwards branching while loops. There's `BEGIN ... AGAIN`,
`BEGIN ... UNTIL`, and `BEGIN ... WHILE ... REPEAT`. You can use `LEAVE` to
break out of `DO ... LOOP` but you'd better not try it in a `BEGIN` loop.
Ditto `UNLOOP`, which I guess exists because `LEAVE` is too slow?

Also, to add insult to injury, there is `DO ... N +LOOP` which  _includes_ its
endpoint but only when counting down. PS `DO` loops can only work inside
compiled words, and probably just crash if you try to interpret them.

PPS: Also also, it is idiomatic to ignore the pretend block structure of control
flow words and use _non-nesting_ control flow in programs when it suits to
generate the desired branches, like this gem:

```forth
BEGIN ... WHILE ( branch out if not found )
          WHILE ( branch out if found )
          REPEAT ( loop branch )
ELSE ( not found )
THEN ( found )
```

`WHILE ... ELSE ... THEN`. Great.

### Strings

There are two string conventions, an older one where string addresses point to a
length byte prefixed to data, and a "newer" one where people pass around a data
pointer and length separately. The older convention is baked into several
standard system words so we're stuck with it.

### Weird Dictionary Antics

There is pretty much one program abstraction, the dictionary, and it's used for
everything, procedures, variables, constants, macros, objects, etc. It's pretty
much just a symbol table you can use to roll your own language however you want.
This is both good and bad.

`: name ... ;` builds a new dictionary entry named `name` and compiles some code
into it. So far, so good. `IMMEDIATE` turns an entry (which one? `LATEST`) into
a compile-time macro. Cool.

So what do we do with this?

- `CONSTANT` builds a new entry that pushes a literal.
- `VARIABLE` builds a new entry that pushes an address where you can store some
data.
- `VALUE` builds a new entry that pushes a literal you can modify with `TO`.
This is the "newer" version of `VARIABLE`.
- `DEFER` builds a new entry whose action can later be dynamically set to some
other entry's action using `IS` and queried with `ACTION-OF`.
- `CREATE` builds a new entry that by default pushes its address. `DOES>`
compiles code that the word should do, in addition to that.
- `MARKER` builds a new entry that checkpoints memory and unwinds it when you
invoke that word, kind of like an undo.

You can probably code up some object systems and abstractions with all that. But
you have to really dig for explanations about _why_ stuff is this way. It's all
just in the standard with no context and forum threads with people arguing about
ambiguities of how it works together.

### :NONAME

`:NONAME ... ;` just spits out some code, and pushes an address you can use to
call it. It does not put it in the dictionary. Except `;` has to work for both
`: name` and `:NONAME`, so we need to keep track of that, somehow. And it has to
work with `RECURSE`, the self-pointer for recurison.

This frees us from needing to name everything. This unbound lambda idea came
about much later than the dictionary for Forth, so it doesn't compose cleanly.
It might be nicer if everything were `:NONAME` and binding names into the
dictionary was a separate step.

### Variables?

There are only global variables, and there are two incompatible ways to define
them, the obsolete way with `VARIABLE` and the new way with `VALUE`. They live
in the same symbol table as everything else. So that's not great. It's fine for
toy programs, but it's not great.

### The stack?

Otherwise you get the stack. The stack sucks. It's just super confusing and bug
prone. It takes like three brain cells to support infix expressions and local
variables. Concatenative programming is kind of cool I guess, but only in
extremely small doses.

Look, we have this CPU with 7 registers and really anemic addressing, and we're
burning 4 registers to try to make a reasonably performant software stack. This
is not an efficient way to program this machine. I just want to spill into RAM.

### Printing things

For the love of all that is holy, what is a pictured numeric output. Hoo boy.

### Where's the code?

I've had a hard time finding interesting Forth programs to try. This makes a lot
of the stranger features here academic. It's not like I'm going to be able to
run program X, if only I add support for weird feature Y.

After reading a bunch of complainy forum threads, I imagine the standard
response here would be that I should be making my own Forth to suit my needs.
It's not supposed to be one size fits all. In terms of what would be useful for
writing actual Gameboy games - this language probably isn't it.

## What would be better

Named parameters and no implicit parameter stack? Lexical scope? It's
interesting that taking out the implicit stack kinda makes it not feel like
Forth anymore. Anyway, it is fun to play with.
