SECTION "Forth Builtins", ROMX[$4000], BANK[1]

def FLAG_IMMEDIATE equ $80

; Macro defcode creates a new dictionary entry in rom.
def last_entry = 0
MACRO DEFCODE ; DEFCODE name, label, flags
  def new_last_entry = @
  dw  last_entry      ; Pointer to previous entry
  def last_entry = new_last_entry
  db  \3 | STRLEN(\1) ; Length of entry name
  db  \1              ; Entry name
\2:
ENDM

; Macro NEXT returns control to the interpreter to string words together.
; Because we are direct threading using call instructions, it is just ret.
MACRO NEXT
  ret
ENDM

; Exit pops back to the calling word.
  DEFCODE "EXIT", _EXIT, 0
  NEXT

; Parameter stack layout (we'll just call this "the stack")
;
; bc is the top element of the stack.
; hl points to the low-order byte of the second element.
; +-----------+
; |    top    | bc
; +-----------+
; |   empty   | 5
; +-----+-----+
; |  2  |  3  | 3 <-- hl (second)
; +-----+-----+
; |  0  |  1  | 1
; +-----+-----+
; The stack grows up. We want to pop low-order bytes first for arithmetic, so
; elements are stored in big endian byte order.

; Macro DROP pops the top of the stack, setting bc to second.
; This sequence is reused in several stack primitives.
MACRO DROP
  ld a, [hld]
  ld c, a
  ld a, [hld]
  ld b, a
ENDM

; Macro DUP pushes the current top onto the stack.
; This sequence is reused in several stack primitives.
MACRO DUP
  inc hl
  ld a, b
  ld [hli], a
  ld [hl], c
ENDM

; Discards top of stack ( n -- )
  DEFCODE "DROP", _DROP, 0
  DROP
  NEXT

; Duplicates top of stack ( n -- n n )
  DEFCODE "DUP", _DUP, 0
  DUP 
  NEXT

; Swaps first two elements on stack ( n1 n2 -- n2 n1 )
  DEFCODE "SWAP", _SWAP, 0
  ; Save second in de temporarily.
  ld a, [hld]
  ld e, a
  ld d, [hl]
  ; Overwrite second with top.
  ld a, b
  ld [hli], a
  ld [hl], c
  ; Set top to saved second from de.
  ld b, d
  ld c, e
  NEXT

; Copies second stack element to top ( n1 n2 -- n1 n2 n1 )
  DEFCODE "OVER", _OVER, 0
  ; Save second in de.
  ld a, [hld]
  ld e, a
  ld a, [hli]
  ld d, a
  ; Push top as new second.
  DUP
  ; Set top from saved second.
  ld b, d
  ld c, e
  NEXT

; Rotates top three elements on stack ( n1 n2 n3 -- n2 n3 n1 )
  DEFCODE "ROT", _ROT, 0
  ; Swap top with second.
  call _SWAP        ; ( n1 n2 n3 -- n1 n3 n2 )
  ; Swap top with third.
  dec hl            ; 
  dec hl            ; point hl at third
  call _SWAP        ; ( n1 n3 n2 -- n2 n3 n1 )
  inc hl            ; point hl back at second
  inc hl
  NEXT

; Un-rotates top three elements on stack ( n1 n2 n3 -- n3 n1 n2 )
  DEFCODE "-ROT", _M_ROT, 0
  ; Swap top with third.
  dec hl            ; 
  dec hl            ; point hl at third
  call _SWAP        ; ( n1 n2 n3 -- n3 n2 n1 )
  inc hl            ; point hl back at second
  inc hl
  ; Swap top with second.
  call _SWAP        ; ( n3 n2 n1 -- n3 n1 n2 )
  NEXT

; Drops 2 elements from top of stack ( n1 n2 -- ).
  DEFCODE "2DROP", _2DROP, 0
  dec hl
  dec hl
  DROP
  NEXT

; Dups 2 elements at top of stack ( n1 n2 -- n1 n2 n1 n2 ).
  DEFCODE "2DUP", _2DUP, 0
  call _OVER
  call _OVER
  NEXT

; Swaps 2 elements at top of stack ( n1 n2 n3 n4 -- n3 n4 n1 n2 ).
  DEFCODE "2SWAP", _2SWAP, 0
  ; : 2SWAP ROT >R ROT R> ; is taken from forth-standard.org
  call _ROT
  call _TO_R
  call _ROT
  call _R_FROM
  NEXT

; Duplicates top of stack if not zero.
  DEFCODE "?DUP", _QDUP, 0
  ld a, b
  or a, c
  jr z, .to_next
  DUP
.to_next
  NEXT

; Increments top of stack ( n -- inc )
  DEFCODE "1+", _INC, 0
  inc bc
  NEXT

; Decrements top of stack ( n -- dec )
  DEFCODE "1-", _DEC, 0
  dec bc
  NEXT

; Adds elements on stack ( n1 n2 -- sum )
  DEFCODE "+", _PLUS, 0
  ; Add low byte of second to low byte of top.
  ld a, [hld]
  add a, c
  ld c, a
  ; Carry into high byte of second + high byte of top.
  ld a, [hld]
  adc a, b
  ld b, a
  NEXT

; Subtracts top of stack from second ( n1 n2 -- difference )
  DEFCODE "-", _MINUS, 0
  ; Subtract low byte of top from low byte of second.
  ld a, [hld]
  sub a, c
  ld c, a
  ; Carry into subtracting high byte of top from high byte of second.
  ld a, [hld]
  sbc a, b
  ld b, a
  NEXT

; Pop parameter stack and push return stack.
  DEFCODE ">R", _TO_R, 0
  push bc
  DROP
  NEXT

; Pop return stack and push onto parameter stack.
  DEFCODE "R>", _R_FROM, 0
  DUP
  pop bc
  NEXT

; Copy x from the return stack to the parameter stack.
  DEFCODE "R@", _R_FETCH, 0
  DUP
  pop bc
  push bc
  NEXT

; Scans a word delimited by the character at the top of the stack
; and returns a pointer to the length-delimited word.
; ( char "<chars>ccc<char>" -- c-addr )
  DEFCODE "WORD", _WORD, 0
  push hl
  ; HL = the next input buffer position
  ld a, [ScanPtr]
  ld l, a
  ld a, [ScanPtr+1]
  ld h, a
  ; C is the character from top of stack here.
  call ScanWord
  ld a, l
  ld [ScanPtr], a
  ld a, h
  ld [ScanPtr+1], a
  pop hl
  ; Replace top of stack with length-prefixed word.
  ld bc, WordLen
  NEXT

; Comments with '(' and ')'.
  DEFCODE "(", _OPEN_PAREN, FLAG_IMMEDIATE
  push bc
.skip_comment
  ld c, " "
  call _WORD        ; scan forward using space as delim
  ld a, [bc]        ; get length of word
  cp a, 0           ; length 0 means we hit eof
  jp z, Error       ; eof while scanning comment
  cp a, 1           ; ')' is length 1
  jr nz, .skip_comment ; if not length 1 continue skipping
  inc bc            ; point to word itself
  ld a, [bc]
  cp a, ")"         ; end of comment?
  jr nz, .skip_comment ; if not end comment, keep skipping
  pop bc
  NEXT

; The outer interpreter loop is called QUIT (no really).
  DEFCODE "QUIT", _QUIT, 0
.interpreter
  ; TODO
  jr .interpreter

; The main program will call into _QUIT to start the interpreter.
EXPORT _QUIT
EXPORT last_entry