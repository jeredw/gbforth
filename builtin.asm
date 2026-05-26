SECTION "Forth Builtins", ROMX[$4000], BANK[1]

; Macro defcode creates a new dictionary entry in rom.
def prev_entry = 0
MACRO DEFCODE ; DEFCODE name, label
  def new_prev_entry = @
  dw  prev_entry      ; Pointer to previous entry
  def prev_entry = new_prev_entry
  db  STRLEN(\1)      ; Length of entry name
  db  \1              ; Entry name
\2:
ENDM

; Macro NEXT returns control to the interpreter to string words together.
; Because we are direct threading using call instructions, it is just ret.
MACRO NEXT
  ret
ENDM

; Exit pops back to the calling word.
  DEFCODE "EXIT", _EXIT
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
  DEFCODE "DROP", _DROP
  DROP
  NEXT

; Duplicates top of stack ( n -- n n )
  DEFCODE "DUP", _DUP
  DUP 
  NEXT

; Swaps first two elements on stack ( n1 n2 -- n2 n1 )
  DEFCODE "SWAP", _SWAP
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
  DEFCODE "OVER", _OVER
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
  DEFCODE "ROT", _ROT
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
  DEFCODE "-ROT", _M_ROT
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
  DEFCODE "2DROP", _2DROP
  dec hl
  dec hl
  DROP
  NEXT

; Dups 2 elements at top of stack ( n1 n2 -- n1 n2 n1 n2 ).
  DEFCODE "2DUP", _2DUP
  call _OVER
  call _OVER
  NEXT

; Swaps 2 elements at top of stack ( n1 n2 n3 n4 -- n3 n4 n1 n2 ).
  DEFCODE "2SWAP", _2SWAP
  ; : 2SWAP ROT >R ROT R> ; is taken from forth-standard.org
  call _ROT
  call _TO_R
  call _ROT
  call _R_FROM
  NEXT

; Duplicates top of stack if not zero.
  DEFCODE "?DUP", _QDUP
  ld a, b
  or a, c
  jr z, .to_next
  DUP
.to_next
  NEXT

; Increments top of stack ( n -- inc )
  DEFCODE "1+", _INC
  inc bc
  NEXT

; Decrements top of stack ( n -- dec )
  DEFCODE "1-", _DEC
  dec bc
  NEXT

; Adds elements on stack ( n1 n2 -- sum )
  DEFCODE "+", _PLUS
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
  DEFCODE "-", _MINUS
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
  DEFCODE ">R", _TO_R
  push bc
  DROP
  NEXT

; Pop return stack and push onto parameter stack.
  DEFCODE "R>", _R_FROM
  DUP
  pop bc
  NEXT

; Copy x from the return stack to the parameter stack.
  DEFCODE "R@", _R_FETCH
  DUP
  pop bc
  push bc
  NEXT

; Sample user word for testing.
  DEFCODE "DOUBLE", DOUBLE
  call _DUP
  call _PLUS
  NEXT

EXPORT DOUBLE

; The outer interpreter loop is called QUIT (no really).
  DEFCODE "QUIT", _QUIT
.interpreter
  ; TODO
  jr .interpreter

; The main program will call into _QUIT to start the interpreter.
EXPORT _QUIT