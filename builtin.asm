SECTION "Forth Builtins", ROMX[$4000], BANK[1]

def TRUE  equ $ffff
def FALSE equ $0

; Immediate words get executed during compilation instead of being compiled,
; acting as macros.
def FLAG_IMMEDIATE equ $80
; Hidden words cannot be looked up. This is used to prevent a word from
; referencing itself unintentionally during compilation.
def FLAG_HIDDEN    equ $40
EXPORT FLAG_HIDDEN

; Macro defcode creates a new dictionary entry in rom.
def last_entry = 0
EXPORT last_entry
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
; | -2  | -1  | -1 <-- base (sentinel)
; +-----------+
; The stack grows up. We want to pop low-order bytes first for arithmetic, so
; elements are stored in big endian byte order.
;
; Initially the stack is empty, so hl points before the first entry,
; and bc is undefined.

; Macro DROP pops the top of the stack, setting bc to second.
; This sequence is reused in several stack primitives.
; If there's just one element on the stack, this will leave hl
; pointed before the beginning of the stack and bc (top) will be
; set to a sentinel value.
MACRO DROP
  ld a, [hld]
  ld c, a
  ld a, [hld]
  ld b, a
ENDM

; Macro DUP pushes the current top onto the stack.
; This sequence is reused in several stack primitives.
; If the stack is empty, this puts whatever junk is in bc into
; the first real stack slot.
MACRO DUP
  inc hl
  ld a, b
  ld [hli], a
  ld [hl], c
ENDM

; Macro PUSH16 is a convenience to load a new top of stack.
MACRO PUSH16
  DUP
  ld bc, \1
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
  ; Push second as new top.
  DUP
  ld b, d
  ld c, e
  NEXT

; Copies top below second ( x1 x2 -- x2 x1 x2 )
  DEFCODE "TUCK", _TUCK, 0
  call _SWAP
  call _OVER
  NEXT

; Drops the second item ( x1 x2 -- x2 )
  DEFCODE "NIP", _NIP, 0
  call _SWAP
  call _DROP
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

; Rotates u+1 items on the stack ( xu xu-1 ... x0 u -- xu-1 ... x0 xu )
  DEFCODE "ROLL", ROLL, 0
  ld a, b
  or a, c
  jr z, .out        ; if u=0 then roll does nothing
  ; assume if u>0 that there are at least 1 + u+1 entries on the stack
  ; and so everything we need to roll is at [hl]. top (in bc) doesn't
  ; need to roll, so this just amounts to swapping adjacent words in ram
  push hl           ; save stack pointer
  ld d, b           ; stash count in de
  ld e, c
  sla c             ; move hl back 2*u entries
  rl b
  ld a, l
  add a, c
  ld l, a
  ld a, h
  adc a, b
  ld h, a
  ; now hl points to the left member of the first pair to swap
  ; swap each entry with its right neighbor
.roll
  inc hl            ; move to low byte of right
  inc hl
  ld a, [hld]       ; store right in temp
  ld [Temp], a
  ld a, [hld]
  ld [Temp+1], a
  ld a, [hld]       ; store left in bc
  ld c, a
  ld a, [hl]
  ld b, a
  ld a, [Temp+1]    ; replace left with right
  ld [hli], a
  ld a, [Temp]
  ld [hli], a
  ld a, b           ; replace right with old left
  ld [hli], a
  ld a, c     
  ld [hl], a
  dec de            ; dec count of pairs to swap
  ld a, d
  or a, e
  jr nz, .roll      ; continue swapping while count is nonzero
  pop hl            ; restore stack pointer
.out
  DROP              ; drop count and move xu to top
  NEXT

; Indexes into the stack and copies something ( xu...x1 x0 u -- xu...x1 x0 xu )
  DEFCODE "PICK", PICK, 0
  ld a, b
  or a, c
  jp z, _DUP        ; if index is 0 then dup
  dec bc            ; otherwise compute 2*(index-1)
  sla c
  rl b
  push hl           ; save stack pointer
  ld a, l           ; subtract 2*(index-1) from hl
  sub a, c
  ld l, a
  ld a, h
  sbc a, b
  ld h, a
  DROP              ; read bc and clobber index
  pop hl
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

; Fetches 2 elements ( a-addr -- x1 x2 ).
  DEFCODE "2@", _2FETCH, 0
  call _DUP
  call _CELL_PLUS
  call _FETCH       ; fetch most significant word
  call _SWAP
  call _FETCH       ; fetch least significant word
  NEXT

; Stores 2 elements ( x1 x2 a-addr -- ).
  DEFCODE "2!", _2STORE, 0
  call _SWAP
  call _OVER        ; ( -- x1 a-addr x2 a-addr )
  call _STORE       ; store least-significant word
  call _CELL_PLUS
  call _STORE       ; store most sigificant word
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

; Returns ones complement of a number. ( n1 -- n2 )
  DEFCODE "INVERT", _INVERT, 0
  ld a, c
  cpl
  ld c, a
  ld a, b
  cpl
  ld b, a
  NEXT

; Negates a number. ( n -- u )
  DEFCODE "NEGATE", _NEGATE, 0
  call _INVERT
  inc bc
  NEXT

; Returns the absolute value of of a number. ( n1 -- n2 )
  DEFCODE "ABS", _ABS, 0
  bit 7, b
  jr z, .out
  call _NEGATE
.out
  NEXT

; Shifts x1 left by u bits ( x1 u -- x2 )
  DEFCODE "LSHIFT", _LSHIFT, 0
  ld d, c           ; save shift amount in d
  DROP
  ld a, d           ; shift amount to a
.shift
  or a, a
  jr z, .out        ; if shift amount is 0, done
  sla c
  rl b
  dec a             ; dec shift amount
  jr .shift
.out
  NEXT

; Shifts x1 right by u bits ( x1 u -- x2 )
  DEFCODE "RSHIFT", _RSHIFT, 0
  ld d, c           ; save shift amount in d
  DROP
  ld a, d           ; shift amount to a
.shift
  or a, a
  jr z, .out        ; if shift amount is 0, done
  srl b
  rr c
  dec a             ; dec shift amount
  jr .shift
.out
  NEXT

; Shift right arithmetic by one bit. ( x1 -- x2 )
  DEFCODE "2/", _2SLASH, 0
  sra b
  rr c
  NEXT

; Shift left logical by one bit. ( x1 -- x2 )
  DEFCODE "2*", _2STAR, 0
  sla c
  rl c
  NEXT

; Max of two signed numbers ( n1 n2 -- n3 )
  DEFCODE "MAX", _MAX, 0
  ld a, [hld]       ; load de = n1^$8000
  ld e, a
  ld a, [hld]
  xor $80
  ld d, a
  ld a, b           ; load bc = n2^$8000
  xor $80
  cp a, d           ; compare high bytes
  jr c, .n1_gt_n2   ; if d > b, then n1 > n2
  jr nz, .n1_le_n2
  ld a, c           ; high bytes are equal
  cp a, e           ; compare low bytes
  jr c, .n1_gt_n2   ; if e > c, then n1 > n2
.n1_le_n2
  ld a, b           ; bc = n2 is already the max
  xor $80           ; flip sign back
  ld b, a
  NEXT
.n1_gt_n2
  ld c, e           ; set bc from de (low byte)
  ld a, d           ; invert and set high byte
  xor $80           ; flip sign back
  ld b, a
  NEXT

; Min of two signed numbers ( n1 n2 -- n3 )
  DEFCODE "MIN", _MIN, 0
  ld a, [hld]       ; load de = n1^$8000
  ld e, a
  ld a, [hld]
  xor $80
  ld d, a
  ld a, b           ; load bc = n2^$8000
  xor $80
  cp a, d           ; compare high bytes
  jr c, .n1_gt_n2   ; if d > b, then n1 > n2
  jr nz, .n1_le_n2
  ld a, c           ; high bytes are equal
  cp a, e           ; compare low bytes
  jr c, .n1_gt_n2   ; if e > c, then n1 > n2
.n1_le_n2
  ld c, e           ; set bc from de (low byte)
  ld a, d           ; invert and set high byte
  xor $80           ; flip sign back
  ld b, a
  NEXT
.n1_gt_n2
  ld a, b           ; bc = n2 is already the min
  xor $80           ; flip sign back
  ld b, a
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

; Subtracts top of stack from second, i.e. n1 - n2 ( n1 n2 -- difference )
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

; Multiplies elements on stack ( n1 | u1 n2 | u2 -- n3 | u3 )
  DEFCODE "*", _STAR, 0
  ld a, [hld]       ; pop de
  ld e, a
  ld a, [hld]
  ld d, a
  push hl           ; save stack pointer 
  call Mul16By16    ; set bc = de * bc
  pop hl            ; restore stack pointer
  NEXT

; Divides elements on stack n1 / n2 ( n1 n2 -- n3 )
  DEFCODE "/", _SLASH, 0
  ld a, [hld]       ; pop de
  ld e, a
  ld a, [hld]
  ld d, a
  push hl           ; save stack pointer 
  call UnsignedDiv16By16 ; set bc = n1 / n2
  pop hl            ; restore stack pointer
  NEXT

; Divides elements on stack n1 / n2 ( n1 n2 -- remainder quotient )
  DEFCODE "/MOD", _SLASH_MOD, 0
  ld a, [hld]       ; pop de
  ld e, a
  ld a, [hld]
  ld d, a
  push hl           ; save stack pointer 
  call UnsignedDiv16By16 ; set bc = n1 / n2, de = n1 % n2
  pop hl            ; restore stack pointer
  inc hl
  ld a, d           ; push remainder
  ld [hli], a
  ld [hl], e
  ; bc has the quotient on top of stack
  NEXT

; Multiplies elements on stack and returns 32-bit product ( u1 u2 -- ud )
  DEFCODE "UM*", _U_M_STAR, 0
  ld a, [hld]       ; pop de
  ld e, a
  ld a, [hld]
  ld d, a
  push hl           ; save stack pointer 
  call Mul16By16    ; set de:bc = de * bc
  pop hl            ; restore stack pointer
  DUP               ; push bc
  ld b, d           ; push de
  ld c, e
  NEXT

; TODO: */
; TODO: */MOD
; TODO: UM/MOD
; TODO: FM/MOD
; TODO: SM/REM
; TODO: M*

; Sign extend n into a 32-bit word ( n -- d )
  DEFCODE "S>D", _S_TO_D, 0
  DUP               ; first cell is just n
  bit 7, b
  jr z, .positive   ; if sign bit zero then push 0
  ld bc, -1         ; else -1
  NEXT
.positive
  ld bc, 0
  NEXT

; Equals zero ( x -- flag )
  DEFCODE "0=", _ZERO_EQUALS, 0
  ld a, b
  or a, c
  jr nz, .ne_zero   ; if some bit nonzero return false
  ld bc, TRUE       ; else return true
  NEXT
.ne_zero
  ld bc, FALSE
  NEXT

; Not equals zero ( x -- flag )
  DEFCODE "0<>", _ZERO_NOT_EQUALS, 0
  ld a, b
  or a, c
  jr z, .eq_zero    ; if all bits zero return false
  ld bc, TRUE       ; else return true
  NEXT
.eq_zero
  ld bc, FALSE
  NEXT

; Less than zero ( n -- flag )
  DEFCODE "0<", _ZERO_LESS, 0
  ; Returns true iff n < 0
  bit 7, b
  jr z, .positive   ; if sign bit zero return false
  ld bc, TRUE       ; else return true
  NEXT
.positive
  ld bc, FALSE
  NEXT

; Greater than zero ( n -- flag )
  DEFCODE "0>", _ZERO_GREATER, 0
  ; Returns true iff n > 0
  ld a, b
  or a, c
  jr z, .le_zero    ; if all bits zero return false
  bit 7, b
  jr nz, .le_zero   ; if sign bit one return false
  ld bc, TRUE       ; else return true
  NEXT
.le_zero
  ld bc, FALSE
  NEXT

; Equals ( x1 x2 -- flag )
  DEFCODE "=", _EQUALS, 0
  ld a, [hld]
  cp a, c           ; compare low byte of second with low byte of top
  jr nz, .ne_dec    ; if not equal, return false
  ld a, [hld]
  cp a, b
  jr nz, .ne        ; if not equal, return false
  ld bc, TRUE       ; else return true
  NEXT
.ne_dec
  dec hl
.ne
  ld bc, FALSE
  NEXT

; Not equals ( x1 x2 -- flag )
  DEFCODE "<>", _NOT_EQUALS, 0
  ld a, [hld]
  cp a, c           ; compare low byte of second with low byte of top
  jr nz, .ne_dec    ; if not equal, return true
  ld a, [hld]
  cp a, b
  jr nz, .ne        ; if not equal, return true
  ld bc, FALSE      ; else return false
  NEXT
.ne_dec
  dec hl
.ne
  ld bc, TRUE 
  NEXT

; Tests if n1 is greater than n2 ( n1 n2 -- flag )
  DEFCODE ">", _GREATER_THAN, 0
  ld a, [hld]       ; load de = n1^$8000
  ld e, a
  ld a, [hld]
  xor $80
  ld d, a
  ld a, b           ; load ac = n2^$8000
  xor $80
  cp a, d           ; compare high bytes
  jr c, .n1_gt_n2   ; if d > a, then n1 > n2
  jr nz, .n1_le_n2
  ld a, c           ; high bytes are equal
  cp a, e           ; compare low bytes
  jr c, .n1_gt_n2   ; if e > c, then n1 > n2
.n1_le_n2
  ld bc, FALSE      ; no, not >
  NEXT
.n1_gt_n2
  ld bc, TRUE       ; yes, >
  NEXT

; Tests if u1 is greater than u2 ( u1 u2 -- flag )
  DEFCODE "U>", _U_GREATER_THAN, 0
  ld a, [hld]       ; load de = n1
  ld e, a
  ld a, [hld]
  ld d, a
  ld a, b           ; bc is already n2
  cp a, d           ; compare high bytes
  jr c, .n1_gt_n2   ; if d > b, then n1 > n2
  jr nz, .n1_le_n2
  ld a, c           ; high bytes are equal
  cp a, e           ; compare low bytes
  jr c, .n1_gt_n2   ; if e > c, then n1 > n2
.n1_le_n2
  ld bc, FALSE      ; no, not >
  NEXT
.n1_gt_n2
  ld bc, TRUE       ; yes, >
  NEXT

; Tests if n1 is less than n2 ( n1 n2 -- flag )
  DEFCODE "<", _LESS_THAN, 0
  ld a, b           ; load bc = n2^$8000
  xor $80
  ld b, a
  ld a, [hld]       ; load de = n1^$8000
  ld e, a
  ld a, [hld]
  xor $80
  cp a, b           ; compare high bytes
  jr c, .n1_lt_n2   ; if b > d, then n2 > n1
  jr nz, .n1_ge_n2
  ld a, e           ; high bytes are equal
  cp a, c           ; compare low bytes
  jr c, .n1_lt_n2   ; if c > e, then n2 > n1
.n1_ge_n2
  ld bc, FALSE      ; no, not <
  NEXT
.n1_lt_n2
  ld bc, TRUE       ; yes, <
  NEXT

; Tests if u1 is less than u2 ( u1 u2 -- flag )
  DEFCODE "U<", _U_LESS_THAN, 0
  ; bc = u2 already
  ld a, [hld]       ; load de = u1
  ld e, a
  ld a, [hld]
  cp a, b           ; compare high bytes
  jr c, .n1_lt_n2   ; if b > d, then n2 > n1
  jr nz, .n1_ge_n2
  ld a, e           ; high bytes are equal
  cp a, c           ; compare low bytes
  jr c, .n1_lt_n2   ; if c > e, then n2 > n1
.n1_ge_n2
  ld bc, FALSE      ; no, not <
  NEXT
.n1_lt_n2
  ld bc, TRUE       ; yes, <
  NEXT

; Tests if a number is within a range ( test low high -- flag )
  DEFCODE "WITHIN", _WITHIN, 0
  ; Magic reference implementation from forth-standard.org
  ; : WITHIN ( test low high -- flag ) OVER - >R - R> U< ;
  call _OVER
  call _MINUS
  call _TO_R
  call _MINUS
  call _R_FROM
  call _U_LESS_THAN
  NEXT

; Logical ORs second with top ( x1 x2 -- x3 )
  DEFCODE "OR", _OR, 0
  ld a, [hld]
  or a, c
  ld c, a
  ld a, [hld]
  or a, b
  ld b, a
  NEXT

; Logical ANDs second with top ( x1 x2 -- x3 )
  DEFCODE "AND", _AND, 0
  ld a, [hld]
  and a, c
  ld c, a
  ld a, [hld]
  and a, b
  ld b, a
  NEXT

; Logical XOR second with top ( x1 x2 -- x3 )
  DEFCODE "XOR", _XOR, 0
  ld a, [hld]
  xor a, c
  ld c, a
  ld a, [hld]
  xor a, b
  ld b, a
  NEXT

; Pop parameter stack and push return stack.
  DEFCODE ">R", _TO_R, 0
  ; Push the value "under" the >R stack frame.
  pop de            ; save >R caller address
  push bc           ; push data
  DROP
  push de           ; push caller again + ret
  NEXT

; Pop return stack and push onto parameter stack.
  DEFCODE "R>", _R_FROM, 0
  pop de            ; save R> caller address
  DUP
  pop bc            ; pop data
  push de           ; push caller again + ret
  NEXT

; Copy x from the return stack to the parameter stack.
  DEFCODE "R@", _R_FETCH, 0
  pop de            ; save R@ caller address
  DUP               ; push data onto data stack
  pop bc
  push bc
  push de           ; push caller again + ret
  NEXT

; Transfer two items to return stack below return address.
MACRO PUSH2R
  pop de            ; save return address
  push bc           ; R:( -- start ) 
  DROP
  push bc           ; R:( -- start limit )
  DROP
  push de           ; restore return address
ENDM

; Transfer two items from return stack below return address.
MACRO POP2R
  pop de            ; save R> caller address
  DUP
  pop bc            ; pop data
  DUP
  pop bc            ; pop data
  push de           ; push caller again + ret
ENDM

; Pop parameter stack twice and push return stack.
; ( x1 x2 -- ) ( R: -- x1 x2 )
  DEFCODE "2>R", _2_TO_R, 0
  call _SWAP
  PUSH2R
  NEXT

; Pop return stack twice and push onto parameter stack.
; ( -- x1 x2 ) ( R: x1 x2 -- )
  DEFCODE "2R>", _2_R_FROM, 0
  POP2R
  call _SWAP
  NEXT

; Copy twice from the return stack to the parameter stack.
; ( -- x1 x2 ) ( R: x1 x2 -- x1 x2 )
  DEFCODE "2R@", _2_R_FETCH, 0
  POP2R             ; ( -- x2 ) ( R: x1 x2 -- x1 )
                    ; ( x1 -- x2 x1 ) ( R: x1 -- )
  call _2DUP        ; ( x2 x1 -- x2 x1 x2 x1 ) ( R: -- )
  PUSH2R            ; ( x2 -- x2 x1 x2 ) ( R: -- x1 )
                    ; ( -- x2 x1 ) ( R: -- x1 x2 )
  call _SWAP        ; ( -- x1 x2 ) ( R: -- x1 x2 )
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
  ; Replace top of stack (delimiter) with length-prefixed word pointer.
  ld bc, WordLen
  NEXT

; Scans until it finds delimiter char. Returns start address and length
; ( char "ccc<char>" -- c-addr u )
  DEFCODE "PARSE", _PARSE, 0
  ld d, 0           ; count length from 0
  ld e, c           ; save delimiter character in E
  push hl           ; save stack pointer
  ; HL = the next input buffer position
  ld a, [ScanPtr]
  ld l, a
  ld a, [ScanPtr+1]
  ld h, a
  ld b, h           ; clobber char with start position
  ld c, l
.scan_next_char
  ld a, [hl]        ; read character from input
  cp a, END_SENTINEL
  jp z, Error       ; if we hit eof in a string, error
  inc hl            ; always consume char (even if delimiter)
  cp a, e           ; is it the delimiter?
  jr z, .done       ; if delim, we are done scanning
  inc d             ; inc length
  jr .scan_next_char
.done
  ; Save scan position.
  ld a, l
  ld [ScanPtr], a
  ld a, h
  ld [ScanPtr+1], a
  pop hl            ; restore stack pointer
  DUP               ; push length
  ld b, 0           ; (saved in d)
  ld c, d
  NEXT

; Scans to find the next space delimited name in input.
; ( "<spaces>name<spaces>" -- c-addr u )
  DEFCODE "PARSE-NAME", _PARSE_NAME, 0
  DUP               ; push start pointer
  push hl           ; save stack pointer
  ; HL = the next input buffer position
  ld a, [ScanPtr]
  ld l, a
  ld a, [ScanPtr+1]
  ld h, a
.skip_spaces
  ld a, [hl]        ; read character from input
  cp a, END_SENTINEL
  jp z, Error       ; error if we hit eof in parse-name
  cp a, " "         ; is it a space
  jr nz, .start     ; if nonspace found start
  inc hl            ; consume space
  jr .skip_spaces
.start
  ld b, h           ; save start position
  ld c, l
  ld d, 1           ; init length to 1
  inc h             ; next char (we know this is a nonspace)
.find_space
  ld a, [hl]        ; read character from input
  cp a, END_SENTINEL
  jr z, .end
  cp a, " "         ; is it a space
  jr z, .end        ; if space found end
  inc hl            ; consume word char
  inc d             ; count length
  jr .find_space
.end
  ; Save scan position.
  ld a, l
  ld [ScanPtr], a
  ld a, h
  ld [ScanPtr+1], a
  pop hl            ; restore stack pointer
  DUP               ; push length
  ld b, 0
  ld c, d
  NEXT

; Scans a number loaded by WORD and pushes it. ( "digits" -- n )
; If there is no number in the buffer, errors.
  DEFCODE "NUMBER", _NUMBER, 0
  DUP               ; make space to push result
  push hl
  ; Point to length before digits
  ld a, LOW(WordLen)
  ld l, a
  ld a, HIGH(WordLen)
  ld h, a
  ld a, [hli]       ; set A = buffer length
  call ScanUnsignedNumber
  pop hl
  ld a, e
  or a, a           ; no chars consumed means not a number
  jp z, Error
  NEXT

; Parses a word and then returns its first character.
  DEFCODE "CHAR", _CHAR, 0
  PUSH16 " "
  call _WORD        ; scan the next space delimited word
  DUP               ; push the first character
  ld b, 0
  ld a, [WordLen+1]
  ld c, a
  NEXT

; Parses a word and generates code to return its first character.
; Only makes sense at compile time.
  DEFCODE "[CHAR]", _BRACKET_CHAR, FLAG_IMMEDIATE
  call _CHAR
  call _LITERAL
  NEXT

; Comments with '\'.
  DEFCODE "\\", _BACKSLASH, FLAG_IMMEDIATE
  ; This is a little unusual because we do not use newlines.
  ; Instead every line is 32 bytes long.
  ; We still scan ahead instead of just adding to ScanPtr so that we can
  ; detect the end sentinel and stop early.
  push hl
  ld a, [ScanPtr]   ; load scan pointer
  ld l, a
  ld a, [ScanPtr+1]
  ld h, a
.scan_to_next_line
  ld a, [hl]        ; check next character
  cp a, END_SENTINEL
  jr z, .done       ; if next char is eof, done
  inc hl            ; inc pointer
  ld a, l
  and a, $1f        ; test if at line boundary
  jr nz, .scan_to_next_line  ; not at line boundary, keep scanning
.done
  ld a, l
  ld [ScanPtr], a
  ld a, h
  ld [ScanPtr+1], a
  pop hl
  NEXT

; Comments with '(' and ')'.
  DEFCODE "(", _OPEN_PAREN, FLAG_IMMEDIATE
  PUSH16 ")"
  call _PARSE       ; scan forward til close paren
  DROP              ; discard start address and length
  DROP
  NEXT

; Scans a non-counted string and compiles code to push its address and length.
; Also works ok while interpreting since it's nice to be able to print...
; Assumes desired delimiter is on the stack.
  DEFCODE "S?", _S_DELIM, FLAG_IMMEDIATE
  call _PARSE       ; push string pointer and length
  ld a, [State]
  or a, a           ; test state
  jr z, .out        ; if interpreting, just leave stuff on the stack
  call _SWAP        ; swap them so we can push pointer first
  call _LITERAL     ; append code to push string pointer
  call _LITERAL     ; append code to push length
.out
  NEXT

; Scans a string delimited by "" and compiles code to push its address and length.
  DEFCODE "S\"", _S_QUOTE, FLAG_IMMEDIATE
  PUSH16 "\""
  call _S_DELIM     ; scan forward to " and find 
  NEXT

; Scans a string delimited by () and compiles code to print it.
  DEFCODE ".(", _DOT_PAREN, FLAG_IMMEDIATE
  PUSH16 ")"
  call _S_DELIM     ; scan forward to ) delimiter, and generate pushes
  ld a, [State]
  or a, a           ; test state
  jr nz, .compiling
  call _TYPE        ; if interpreting, print immediately
  NEXT
.compiling
  PUSH16 _TYPE      ; generate code to call TYPE
  call _COMPILE_COMMA
  NEXT

; Scans a string delimited by " and compiles code to print it.
  DEFCODE ".\"", _DOT_QUOTE, FLAG_IMMEDIATE
  call _S_QUOTE     ; generate code to push an address and length
  ld a, [State]
  or a, a           ; test state
  jr nz, .compiling
  call _TYPE        ; if interpreting, print immediately
  NEXT
.compiling
  PUSH16 _TYPE
  call _COMPILE_COMMA ; generate code to call TYPE
  NEXT

; Scans a counted string and compiles code to push its address.
; Since we don't want to corrupt source code, we copy counted strings and
; prepend a length byte. This is kind of annoying.
  DEFCODE "C\"", _C_QUOTE, FLAG_IMMEDIATE
  call _HERE        ; get output pointer
  push hl           ; save stack pointer
  ; Append a jp that will jump over the string data.
  ld a, $c3         ; jp instruction
  ld [bc], a        ; append instruction
  inc bc            ;
  push bc           ; save address of jp target
  inc bc            ; skip over target
  inc bc
  push bc           ; save address of length field
  inc bc            ; skip length field
  ; HL = the next input buffer position
  ld a, [ScanPtr]
  ld l, a
  ld a, [ScanPtr+1]
  ld h, a
  ld d, 0           ; d = length counts from 0
.scan_next_char
  ld a, [hl]        ; read character from input
  cp a, END_SENTINEL
  jp z, Error       ; if we hit eof in a string, error
  inc hl            ; always consume char (even if ")
  cp a, "\""        ; is it a close quote?
  jr z, .done       ; if quote, we are done scanning
  ld [bc], a        ; store the character
  inc bc            ; next output position
  inc d             ; inc length
  jr .scan_next_char
.done
  ; Save scan position.
  ld a, l
  ld [ScanPtr], a
  ld a, h
  ld [ScanPtr+1], a
  ; Save here.
  ld a, c
  ld [Here], a
  ld a, b
  ld [Here+1], a
  pop bc            ; point at length field
  ld a, d
  ld [bc], a        ; update length
  pop bc            ; point at jp target
  ld a, [Here]      ; set jp to jump over string
  ld [bc], a
  inc bc
  ld a, [Here+1]
  ld [bc], a
  inc bc            ; point bc at length field again
  pop hl            ; restore stack pointer
  ; Now the top of the stack points at the length field.
  call _LITERAL
  NEXT

; Finds a word in the dictionary and returns a pointer to it.
; ( c-addr -- c-addr 0 | xt 1 | xt -1 )
  DEFCODE "FIND", _FIND, 0
  push hl
  push bc
  ; BC has the word pointer to find.
  call LookupWord
  or a, a
  jr z, .not_found  ; 0 -> word is not found
  ld b, h           ; set top of stack to result pointer
  ld c, l
  pop de            ; discard c-addr
  pop hl            ; restore stack pointer
  and a, FLAG_IMMEDIATE
  jr nz, .immediate ; test if immediate flag set
  ; otherwise word is compiled
.compiled
  PUSH16 -1         ; -1 for compiled words
  jr .out
.immediate
  PUSH16 1          ; 1 for immediate words
  jr .out
.not_found
  pop bc            ; restore c-addr
  pop hl            ; restore stack pointer
  PUSH16 0          ; 0 for not found
.out
  NEXT

; Finds a space delimited word ( "<spaces>name" -- xt )
  DEFCODE "'", _TICK, 0
  PUSH16 " "
  call _WORD        ; scan the next word of input
  ld a, [bc]        ; get length of the word
  or a, a           ;
  jp z, Error       ; eof after ' is always an error
  call _FIND        ; try to look up the word
  ld a, c           ; get lookup result flags
  or a, a           ; 0 means not found
  jp z, Error       ; missing word after ' is an error
  DROP              ; drop flags from find leaving xt on stack
  NEXT

; Macro to find and push the address of the next word ( "<spaces>name" -- xt )
  DEFCODE "[']", _BRACKET_TICK, FLAG_IMMEDIATE
  call _TICK        ; look up the word
  call _LITERAL     ; compile code to push a literal
  NEXT

; Delays compilation of ( "<spaces>name" ).
; This is useful for deferring execution when defining macros.
  DEFCODE "POSTPONE", _POSTPONE, FLAG_IMMEDIATE
  call _TICK        ; lookup the word
  ld a, [WordFlags] ; get associated flags
  and a, FLAG_IMMEDIATE
  jr z, .compiled   ; if not immediate, compiled
  ; POSTPONE <immediate> just compiles a call instead of executing it now.
  ; Say we want to alias MAYBE to IF for some reason:
  ; : MAYBE POSTPONE IF ; IMMEDIATE
  ;   \ Since IF is immediate, MAYBE compiles to: call _IF
  ; : STUFF MAYBE TRUE THEN ;
  ;   \ When compiling STUFF, we run MAYBE which calls _IF.
  ;   \ Had we written IF instead of POSTPONE IF, we would have
  ;   \ called IF during the definition of MAYBE.
  call _COMPILE_COMMA ; compile a call to WORD
  NEXT
.compiled
  ; POSTPONE <compiled> appends code to compile a call to a word.
  ; For example say we want a macro to add a call to dup.
  ; : COMPILE-DUP POSTPONE DUP ; IMMEDIATE
  ;   \ COMPILE-DUP compiles to: [push _DUP] [COMPILE,]
  ; : MY-DUP COMPILE-DUP ;
  ;   \ When compiling MY-DUP, we run COMPILE-DUP which appends
  ;   \ a call to DUP. Had we written DUP instead of POSTPONE DUP,
  ;   \ we would have called DUP during the definition of MY-DUP.
  call _LITERAL     ; compile push xt
  PUSH16 _COMPILE_COMMA ; compile call to COMPILE,
  call _COMPILE_COMMA
  NEXT

; Compiles code to put a literal on the stack ( x -- )
  DEFCODE "LITERAL", _LITERAL, FLAG_IMMEDIATE
  ; Compile call DUP / ld bc, XXXX to implement the PUSH16 sequence.
  PUSH16 _DUP       ; call DUP
  call _COMPILE_COMMA
  ld d, $01         ; append "ld bc, XXXX"
  call AppendCode
  DROP
  NEXT

; >BODY finds the beginning of data for a dictionary entry ( xt -- addr )
  DEFCODE ">BODY", _TO_BODY, 0
  inc bc            ; skip previous entry pointer
  inc bc
  ld a, [bc]        ; read name length
  and a, $3f        ; mask length bytes
  add a, c          ; add length to pointer
  ld c, a
  ld a, b
  adc 0
  ld b, a
  NEXT

; Pushes a blank character. ( -- char )
  DEFCODE "BL", _BL, 0
  PUSH16 " "
  NEXT

; Returns the length and first character of a length-prefixed string. ( addr -- addr u )
  DEFCODE "COUNT", _COUNT, 0
  ld a, [bc]        ; read length
  ld d, a           ; save length to D
  inc bc            ; get string data address
  DUP               ; push length
  ld b, 0
  ld c, d
  NEXT

; Sets radix to decimal. ( -- )
  DEFCODE "DECIMAL", _DECIMAL, 0
  ld a, 10
  ld [Base], a
  NEXT

; Sets radix to hex. ( -- )
  DEFCODE "HEX", _HEX, 0
  ld a, 16
  ld [Base], a
  NEXT

; Reports depth of data stack. ( -- n )
  DEFCODE "DEPTH", _DEPTH, 0
  ; The stack pointer is at -1 when the stack is empty.
  ; So its current depth is hl - (ParameterStack-1).
  ld a, l
  sub LOW(ParameterStack-1)
  ld e, a
  ld a, h
  sbc HIGH(ParameterStack-1)
  ld d, a
  xor a, a          ; clear carry
  rr d              ; shift right to divide by 2 (bytes -> cells)
  rr e
  DUP               ; push depth
  ld b, d
  ld c, e
  NEXT

; Pushes a false value ( -- false )
  DEFCODE "FALSE", _FALSE, 0
  PUSH16 FALSE
  NEXT

; Pushes a true value ( -- true )
  DEFCODE "TRUE", _TRUE, 0
  PUSH16 TRUE
  NEXT

; Pushes the address of the current base for digit conversion. ( -- addr )
  DEFCODE "BASE", _BASE, 0
  PUSH16 Base
  NEXT

; Pushes address of compilation state. ( -- addr )
  DEFCODE "STATE", _STATE, 0
  PUSH16 State
  NEXT

; Gets address of input buffer and size ( -- c-addr u )
  DEFCODE "SOURCE", _SOURCE, 0
  ; The input buffer is the entire program text.
  PUSH16 SaveData
  PUSH16 SAVE_SIZE
  NEXT

; Pushes address of scan pointer in input buffer. ( -- addr )
  DEFCODE ">IN", _TO_IN, 0
  PUSH16 ScanPtr
  NEXT

; Pushes the current data location. ( -- addr )
  DEFCODE "HERE", _HERE, 0
  DUP
  ld a, [Here]
  ld c, a
  ld a, [Here+1]
  ld b, a
  NEXT

; Pushes the latest entry pointer. ( -- addr )
  DEFCODE "LATEST", _LATEST, 0
  DUP
  ld a, [Latest]
  ld c, a
  ld a, [Latest+1]
  ld b, a
  NEXT

; Reports unused space. ( -- u )
  DEFCODE "UNUSED", _UNUSED, 0
  call _HERE        ; push bc = here
  ; Compute EndOfUser - Here
  ld a, LOW(EndOfUser)
  sub a, c
  ld c, a
  ld a, HIGH(EndOfUser)
  sub a, b
  ld b, a
  NEXT

; Reserves data space. ( n -- )
  DEFCODE "ALLOT", _ALLOT, 0
  ld a, [Here]      ; add top of stack to Here pointer
  add a, c
  ld [Here], a
  ld a, [Here+1]
  adc a, b
  ld [Here+1], a
  DROP
  NEXT

; Aligns data space pointer. ( -- )
  DEFCODE "ALIGN", _ALIGN, 0 
  ld a, [Here]
  bit 0, a          ; check if Here pointer is cell-aligned
  jr z, .out        ; if so, ok
  PUSH16 1          ; otherwise allocate one byte to align it
  call _ALLOT
.out
  NEXT

; Gets next aligned address. ( addr -- a-addr )
  DEFCODE "ALIGNED", _ALIGNED, 0 
  bit 0, c          ; test if aligned
  jr z, .out        ; if aligned, do nothing
  inc bc            ; otherwise increment...
.out
  NEXT

; Erases memory. ( addr u -- )
  DEFCODE "ERASE", _ERASE, 0
  ld d, b           ; pop length in de
  ld e, c
  DROP
  ld a, d           ; check if length is zero
  or a, e
  jr z, .done       ; skip if zero length
  push hl           ; save stack pointer
  ld h, b           ; get dest addr in hl
  ld l, c
.clear
  xor a, a
  ld [hli], a       ; set current addr to 0
  dec de            ; dec length
  ld a, d           ; test if length is zero
  or a, e
  jr nz, .clear     ; continue while length is nonzero
.done
  pop hl            ; restore stack pointer
  DROP              ; pop address
  NEXT

; Fills memory with some value. ( addr u char -- )
  DEFCODE "FILL", _FILL, 0
  ld b, c           ; duplicate char in high byte of bc
  push bc           ; push char
  DROP
  ld d, b           ; pop length in de
  ld e, c
  DROP
  ld a, d           ; check if length is zero
  or a, e
  jr z, .done       ; skip if zero length
  pop af            ; set A=char (and clobber flags)
  push hl           ; save stack pointer
  ld h, b           ; get dest addr in hl
  ld l, c
  ld b, a           ; get fill character in b
.fill   
  ld a, b           ; fill character in a
  ld [hli], a       ; set current addr to a
  dec de            ; dec length
  ld a, d           ; test if length is zero
  or a, e
  jr nz, .fill      ; continue while length is nonzero
.done
  DROP              ; pop address
  NEXT

; Copies memory from low to high address. ( c-addr1 c-addr2 u -- )
  DEFCODE "CMOVE", _CMOVE, 0
  ld a, c           ; stash length
  ld [Temp], a
  ld a, b
  ld [Temp+1], a
  ld a, [hld]       ; pop destination in de
  ld d, a
  ld a, [hld]
  ld e, a
  DROP              ; pop source into bc
  push hl           ; save stack pointer
  ld h, b           ; source to hl
  ld l, c
  ld a, [Temp]      ; get length in bc again
  ld c, a
  ld a, [Temp+1]
  ld b, a
.copy   
  ld a, b           ; test if length is zero
  or a, c
  jr z, .done       ; if so, done
  ld a, [hli]       ; get next source byte
  ld [de], a        ; copy source to dest
  inc de
  dec bc
  jr .copy          ; continue copying
.done
  pop hl            ; restore stack pointer
  DROP              ; pop address
  NEXT

; Copies memory from high to low address. ( c-addr1 c-addr2 u -- )
  DEFCODE "CMOVE>", _CMOVE_UP, 0
  ld a, c           ; stash length
  ld [Temp], a
  ld a, b
  ld [Temp+1], a
  ld a, [hld]       ; de = destination + length
  add a, c          ; add low byte of length
  ld d, a
  ld a, [hld]
  adc a, b          ; add high byte of length
  ld e, a
  DROP              ; bc = source
  push hl           ; save stack pointer
  ld a, [Temp]      ; hl = source + length
  add a, c
  ld l, a
  ld a, [Temp+1]
  adc a, b
  ld h, a
  ld a, [Temp]      ; bc = length
  ld c, a
  ld a, [Temp]
  ld b, a
.copy   
  ld a, b           ; test if length is zero
  or a, c
  jr z, .done       ; if so, done
  ; dec before copying because ptr+length is one beyond the end.
  dec hl            ; dec source pointer
  dec de            ; dec dest pointer
  ld a, [hl]        ; get source byte
  ld [de], a        ; copy source to dest
  dec bc
  jr .copy          ; continue copying
.done
  pop hl            ; restore stack pointer
  DROP              ; pop source address
  NEXT

; Copies memory. ( addr1 addr2 u -- )
  DEFCODE "MOVE", _MOVE, 0
  ; XXX All these stack shenanigans probably cost more than the copy itself...
  call _M_ROT       ; ( addr1 addr2 u -- u addr1 addr2 )
  call _OVER
  call _OVER        ; ( -- u addr1 addr2 addr1 addr2 )
  call _U_LESS_THAN ; test if source < dest
  ld a, b
  or a, c
  DROP              ; pop test result
  call _ROT         ; ( u addr1 addr2 -- addr1 addr2 u )
  ; flags should still be ok, unaffected by DROP + ROT
  jr nz, .move_up   ;
  call _CMOVE       ; source >= dest so copy forwards
  NEXT
.move_up
  call _CMOVE_UP    ; copy backwards
  NEXT

; Creates a new empty named dictionary definition. ( "<spaces>name" -- )
  DEFCODE "(CREATE-EMPTY)", _CREATE_EMPTY, 0
  PUSH16 " "
  call _WORD        ; scan the next word of input
  ld a, [bc]        ; get length of the word
  ld d, a           ; save it in d
  or a, a           ; test if zero -> eof
  jp z, Error       ; eof after CREATE is always an error
  push hl           ; save stack pointer
  ld a, [Here+1]    ; get current here pointer
  ld h, a
  ld a, [Here]
  ld l, a
  bit 0, l          ; check if here is cell-aligned
  jr z, .aligned
  inc hl            ; if not aligned, align it
.aligned
  push hl           ; save start of entry pointer
  ld a, [Latest]    ; copy link to previous word
  ld [hli], a
  ld a, [Latest+1]
  ld [hli], a
  ld a, d           ; copy length of name
  ld [hli], a
.copy_name
  inc bc
  ld a, [bc]        ; load next char of name
  ld [hli], a       ; store next char of name
  dec d
  jr nz, .copy_name ; while more chars remain, keep copying
  ld a, l           ; update HERE
  ld [Here], a
  ld a, h
  ld [Here+1], a
  pop hl            ; set HL to start of entry
  ld a, l           ; update LATEST
  ld [Latest], a
  ld a, h
  ld [Latest+1], a
  pop hl            ; restore stack
  DROP
  NEXT

; Creates a new named dictionary definition with default behavior. ( "<spaces>name" -- )
; The default behavior of name is to push its first free address.
  DEFCODE "CREATE", _CREATE, 0
  call _CREATE_EMPTY
  ; Behavior for the newly created word is to push its data address,
  ; jp to optional DOES>, and return. Any data is stored after ret.
  ; By default YYYY is the following instruction, i.e. the jp just
  ; falls through to exit.
  ;   call _DUP     ; CD <_DUP> +3 bytes
  ;   ld bc, XXXX   ; 01 <XXXX> +3 bytes
  ;   jp YYYY       ; C3 <YYYY> +3 bytes
  ;   ret           ; C9        +1 byte
  ;   <padding>     ; (if needed for alignment)
  ;   <aligned data goes here at +10B/+11B>
  call _HERE        ; get current address
  ld a, c           ; offset to ret address
  add a, 9
  ld c, a
  ld a, b
  adc a, 0
  ld b, a
  DUP               ; push ret address
  inc bc            ; data goes after ret
  call _ALIGNED     ; align data address if necessary
  call _LITERAL     ; append code to push data address
  ; _LITERAL popped data address, so now bc is the ret address again
  ld d, $c3         ; jp opcode
  call AppendCode   ; append "jp <ret>"
  ld bc, $c9        ; clobber top of stack with ret opcode
  call _C_COMMA     ; append "ret" (and pop stack)
  NEXT

; How far into a CREATE word is the pointer we need to patch up for DOES>.
def DOES_OFFSET    equ $7

; DOES> appends common behavior to the most recent CREATE'd entry.
  DEFCODE "DOES>", _DOES, FLAG_IMMEDIATE
  ; Assume that we've just compiled code to call CREATE. Now we
  ; need to compile code to patch up the DOES pointer in the newly
  ; created entry. Note we want this to happen when CREATE executes,
  ; at runtime.
  PUSH16 _DOES_RUNTIME
  call _COMPILE_COMMA
  ; Return early from the current definition. The remainder of its code
  ; from HERE+1 onwards will be used as the behavior for DOES>.
  PUSH16 $c9        ; ret opcode
  call _C_COMMA     ; append ret
  NEXT

; Patches the DOES pointer in the LATEST entry. See CREATE and DOES>.
  DEFCODE "(DOES>)", _DOES_RUNTIME, 0
  call _HERE        ; HERE will be a ret in the current definition
  inc bc            ; the DOES code is just past the ret
  call _LATEST      ; we need to store this in the LATEST entry
  call _TO_BODY     ; skip past the header
  PUSH16 DOES_OFFSET
  call _PLUS        ; skip to the offset of the DOES pointer
  call _STORE       ; store HERE+1 into the DOES pointer
  NEXT

; DEFER defines a new entry that can be aliased to another one.
; We don't have dedicated fancy fields for this and just do it with a JP.
  DEFCODE "DEFER", _DEFER, 0
  call _CREATE_EMPTY
  ; Behavior for the newly created word is to jp to optional ACTION.
  ;   jp YYYY       ; C3 <YYYY> +3 bytes
  ;   ret           ; C9        +1 byte
  ; By default YYYY is the following instruction, i.e. the jp just
  ; falls through to exit.
  call _HERE        ; push here pointer
  inc bc            ; skip over jp itself to get to ret
  inc bc
  inc bc
  ld d, $c3         ; jp opcode
  call AppendCode   ; append "jp YYYY"
  ld bc, $c9        ; clobber top of stack with ret opcode
  call _C_COMMA     ; append "ret" (and pop)
  NEXT

; DEFER! sets the ACTION pointer of xt1 to be xt2 ( xt2 xt1 -- )
  DEFCODE "DEFER!", _DEFER_STORE, 0
  ld d, b           ; save address of word to modify
  ld e, c
  inc de            ; point at the jp target
  DROP              ; pop to get bc = xt2
  ld a, [bc]        ; copy xt2 to action address
  ld [de], a
  inc bc
  inc de
  ld a, [bc]
  ld [de], a
  DROP
  NEXT

; DEFER@ gets the ACTION pointer of xt1 ( xt1 -- xt2 )
  DEFCODE "DEFER@", _DEFER_FETCH, 0
  inc bc            ; point at the jp target
  ld a, [bc]        ; copy low byte of xt2 to e
  ld e, a
  inc bc
  ld a, [bc]        ; copy high byte of xt2 to b
  ld b, a
  ld c, d
  NEXT

; IS sets a name to execute xt. ( xt "<spaces>name" -- )
  DEFCODE "IS", _IS, FLAG_IMMEDIATE
  ld a, [State]
  or a, a           ; test state
  jr nz, .compiling
  call _TICK        ; look up the next word
  call _DEFER_STORE ; set jp target in defer definition
  NEXT
.compiling
  call _BRACKET_TICK ; compile code to push xt
  PUSH16 _DEFER_STORE ; compile DEFER!
  call _COMPILE_COMMA
  NEXT

; ACTION-OF returns the action of a deferred word. ( "<spaces>name" -- xt )
  DEFCODE "ACTION-OF", _ACTION_OF, FLAG_IMMEDIATE
  ld a, [State]
  or a, a           ; test state
  jr nz, .compiling
  call _TICK        ; look up the next word
  call _DEFER_FETCH ; get target in defer definition
  NEXT
.compiling
  call _BRACKET_TICK ; compile code to push xt
  PUSH16 _DEFER_FETCH ; compile DEFER@
  call _COMPILE_COMMA
  NEXT

; Creates a new entry that loads a literal value. ( x -- )
  DEFCODE "CONSTANT", _CONSTANT, 0
  call _CREATE_EMPTY ; create a new, empty dictionary entry
  call _LITERAL     ; compile code to push x
  PUSH16 $c9        ; push ret opcode
  call _C_COMMA     ; append "ret"
  NEXT

; Creates a new entry that pushes an address for some aligned data.
  DEFCODE "VARIABLE", _VARIABLE, 0
  call _CREATE_EMPTY ; create a new, empty dictionary entry
  call _HERE        ; push address
  PUSH16 7
  call _PLUS        ; skip over code
  call _ALIGNED     ; skip extra byte for alignment
  call _LITERAL     ; append code to push variable address (+6B)
  PUSH16 $c9
  call _C_COMMA     ; append "ret" (+1B)
  call _ALIGN
  PUSH16 2          ; reserve one cell for value
  call _ALLOT
  NEXT

; Creates a new entry that pushes an address for some aligned data.
  DEFCODE "2VARIABLE", _2VARIABLE, 0
  call _CREATE_EMPTY ; create a new, empty dictionary entry
  call _HERE        ; push address
  PUSH16 7
  call _PLUS        ; skip over code
  call _ALIGNED     ; skip extra byte for alignment
  call _LITERAL     ; append code to push variable address (+6B)
  PUSH16 $c9
  call _C_COMMA     ; append "ret" (+1B)
  call _ALIGN
  PUSH16 4          ; reserve two cells for value
  call _ALLOT
  NEXT

; Creates a new entry that loads a modifiable literal value. ( x "<spaces>name" -- )
  DEFCODE "VALUE", _VALUE, 0
  ; Values are just constants that we intrusively modify.
  call _CONSTANT
  NEXT

; How far into a VALUE word is the actual value for TO.
; It is after a literal field: call DUP / ld bc, XXXX
def VALUE_OFFSET   equ $5

; Modifies the value stored in a VALUE entry.
  DEFCODE "TO", _TO_, 0
  ld a, [State]
  or a, a           ; test state
  jr nz, .compiling
  call _TO_RUNTIME
  NEXT
.compiling
  PUSH16 _TO_RUNTIME
  call _COMPILE_COMMA
  NEXT

; Does the runtime part of a TO 
  DEFCODE "(TO)", _TO_RUNTIME, 0
  call _TICK        ; look up entry  
  call _TO_BODY     ; skip ahead to the body
  PUSH16 VALUE_OFFSET
  call _PLUS        ; skip into literal
  call _STORE       ; store x to literal
  NEXT

; Checkpoints dictionary and memory state. ( "<spaces>name" -- )
  DEFCODE "MARKER", _MARKER, 0
  call _LATEST      ; save latest dictionary pointer
  call _HERE        ; save current data space pointer
  call _CREATE_EMPTY  ; create an empty entry
  call _LITERAL     ; compile code to push HERE
  call _LITERAL     ; compile code to push LATEST
  PUSH16 _MARKER_RUNTIME  ; compile code to call MARKER_RUNTIME
  call _COMPILE_COMMA
  PUSH16 $c9
  call _C_COMMA     ; append "ret" (and pop)
  NEXT

; Rolls back dictionary and memory state. ( old-here old-latest -- )
  DEFCODE "(MARKER)", _MARKER_RUNTIME, 0
  ; Since dictionary entries point to earlier entries, we can just
  ; bump the latest entry pointer back to where it was before MARKER
  ; and don't have to fix up any other dictionary pointers.
  ld a, c
  ld [Latest], a
  ld a, b
  ld [Latest+1], a
  DROP              ; pop latest
  ld a, c
  ld [Here], a
  ld a, b
  ld [Here+1], a
  DROP              ; pop here
  NEXT

; Counts how many bytes are in n1 cells. ( n1 -- n2 )
  DEFCODE "CELLS", _CELLS, 0
  xor a             ; clear carry
  rl c              ; 1 cell = 2 bytes, so shift left
  rl b
  NEXT

; Increments address by one cell. ( addr1 -- addr2 )
  DEFCODE "CELL+", _CELL_PLUS, 0
  inc bc            ; 1 cell = 2 bytes.
  inc bc
  NEXT

; Counts how many chars are in n1 cells. ( n1 -- n2 )
  DEFCODE "CHARS", _CHARS, 0
  ; no-op because chars are 1:1
  NEXT

; Increments address by one char. ( addr1 -- addr2 )
  DEFCODE "CHAR+", _CHAR_PLUS, 0
  inc bc
  NEXT

; Stores the top of stack at HERE and increments HERE. ( x -- )
  DEFCODE ",", _COMMA, 0
  push hl           ; save stack pointer
  ld a, [Here]      ; load Here pointer into hl
  ld l, a
  ld a, [Here+1]
  ld h, a
  ld a, c
  ld [hli], a       ; store low byte at pointer
  ld a, b
  ld [hli], a       ; store high byte at pointer
  ld a, l
  ld [Here], a      ; update Here pointer
  ld a, h
  ld [Here+1], a
  pop hl            ; restore stack pointer
  DROP
  NEXT

; Appends code to execute the given word address at HERE. ( xt -- )
  DEFCODE "COMPILE,", _COMPILE_COMMA, 0
  ld d, $cd         ; $cd is a call instruction
  call AppendCode   ; append "CALL XXXX" with XXXX from top of stack
  DROP
  NEXT

; Executes the word address on the stack. ( xt -- )
  DEFCODE "EXECUTE", _EXECUTE, 0
  ld a, c           ; load the address into a prepared JP in ram
  ld [Indirect+1], a
  ld a, b
  ld [Indirect+2], a
  DROP              ; drop xt
  jp Indirect       ; execute and then return to caller

; Exits the current word ( -- )
  DEFCODE "EXIT", _EXIT, 0
  ; pop the return address for the call to EXIT, so that NEXT (ret) returns to
  ; the containing word's caller.
  pop de
  NEXT

; Prints a signed number. ( n -- )
  DEFCODE ".", _DOT, 0
  push hl
  push bc
  call PutSignedNumber
  ld a, " "
  call PutChar
  pop bc
  pop hl
  NEXT

; Prints an unsigned number. ( u -- )
  DEFCODE "U.", _U_DOT, 0
  push hl
  push bc
  call PutUnsignedNumber
  ld a, " "
  call PutChar
  pop bc
  pop hl
  NEXT

; Prints a character. ( x -- )
  DEFCODE "EMIT", _EMIT, 0
  push hl
  ld a, c
  call PutChar
  pop hl
  NEXT

; Prints a string given a separate length. ( address length -- )
  DEFCODE "TYPE", _TYPE, 0
  ld d, b           ; save length in de
  ld e, c
  DROP              ; get bc = address
  push hl
.print_next
  ld a, [bc]        ; get next character of string
  inc bc            ; advance string pointer
  call PutChar      ; print char
  dec de            ; count char as printed
  ld a, d           ; test if length is zero
  or a, e
  jr nz, .print_next ; while more chars keep printing
  pop hl
  DROP              ; pop address
  NEXT

; Stores a value x to addr. ( x addr -- )
  DEFCODE "!", _STORE, 0
  ld a, [hld]       ; get x low byte
  ld [bc], a        ; store it
  inc bc            ; next address
  ld a, [hld]       ; get x high byte
  ld [bc], a        ; store it
  DROP
  NEXT

; Fetches a value x from addr. ( addr -- x )
  DEFCODE "@", _FETCH, 0
  ld a, [bc]        ; fetch low-order byte
  ld d, a           ; stash it in d
  inc bc            ; index next byte
  ld a, [bc]        ; fetch high-order byte
  ld b, a           ; set new top of stack to data
  ld c, d           ;
  NEXT

; Adds a number to the cell at a-addr ( n a-addr -- )
  DEFCODE "+!", _PLUS_STORE, 0
  ld a, [bc]
  ld e, a           ; e = low byte from [addr]
  inc bc            ; inc addr
  ld a, [bc]
  ld d, a           ; d = high byte from [addr+1]
  ld a, [hld]       ; add n to de
  add a, e
  ld e, a
  ld a, [hld]
  adc a, d
  ld [bc], a        ; store high byte of sum at [addr+1]
  dec bc
  ld a, e
  ld [bc], a        ; store low byte of sum at [addr]
  DROP              ; drop n     
  NEXT

; Stores a character. ( char -- )
  DEFCODE "C,", _C_COMMA, 0
  push hl           ; save stack pointer
  ld a, [Here]      ; load Here pointer into hl
  ld l, a
  ld a, [Here+1]
  ld h, a
  ld a, c
  ld [hli], a       ; store low byte at pointer
  ld a, l
  ld [Here], a      ; update Here pointer
  ld a, h
  ld [Here+1], a
  pop hl            ; restore stack pointer
  DROP
  NEXT

; Stores a character to addr. ( char addr -- )
  DEFCODE "C!", _C_STORE, 0
  ld a, [hld]       ; get char low byte
  ld [bc], a        ; store it at addr
  dec hl            ; skip high byte
  DROP
  NEXT

; Fetches a character. ( addr -- char )
  DEFCODE "C@", _C_FETCH, 0
  ld a, [bc]        ; fetch character
  ld b, 0           ; set new top of stack to character
  ld c, a
  NEXT

; Enter interpretation state. ( -- )
  DEFCODE "[", _LEFT_BRACKET, 0
  ld a, 0
  ld [State], a
  ld [State+1], a
  NEXT

; Enter compilation state. ( -- )
  DEFCODE "]", _RIGHT_BRACKET, 0
  ld a, $ff
  ld [State], a
  ld [State+1], a
  NEXT

; Flags the most recently compiled word as immediate. ( -- )
  DEFCODE "IMMEDIATE", _IMMEDIATE, 0
  ld a, [Latest]    ; set de to latest entry pointer
  ld e, a
  ld a, [Latest+1]
  ld d, a
  inc de            ; skip previous entry pointer
  inc de
  ld a, [de]
  or a, FLAG_IMMEDIATE
  ld [de], a
  NEXT

; Toggles whether the current entry is hidden.
  DEFCODE "(TOGGLE-HIDDEN)", _TOGGLE_HIDDEN, 0
  ld a, [Latest]    ; set de to latest entry pointer
  ld e, a
  ld a, [Latest+1]
  ld d, a
  inc de            ; skip previous entry pointer
  inc de
  ld a, [de]
  xor a, FLAG_HIDDEN
  ld [de], a
  NEXT

; Defines a new word. ( "<spaces>name" -- )
  DEFCODE ":", _COLON, 0
  call _CREATE_EMPTY
  call _TOGGLE_HIDDEN ; hide the word while defining it
  call _RIGHT_BRACKET ; set state to compiling
  NEXT

; Defines a new word with no name and pushes its xt. ( -- xt )
  DEFCODE ":NONAME", _COLON_NO_NAME, 0
  ; :NONAME defines an actual dictionary entry with a zero length name,
  ; so that words like ; and RECURSE work normally.
  push hl           ; save stack pointer
  ld a, [Here+1]    ; get current here pointer
  ld h, a
  ld a, [Here]
  ld l, a
  bit 0, l          ; check if here is cell-aligned
  jr z, .aligned
  inc hl            ; if not aligned, align it
.aligned
  push hl           ; save start of entry pointer
  ld a, [Latest]    ; copy link to previous word
  ld [hli], a
  ld a, [Latest+1]
  ld [hli], a
  ld a, 0           ; set length byte to 0
  ld [hli], a
  ld a, l           ; update HERE
  ld [Here], a
  ld a, h
  ld [Here+1], a
  pop hl            ; set HL to start of entry
  ld a, l           ; update LATEST
  ld [Latest], a
  ld a, h
  ld [Latest+1], a
  pop hl            ; restore stack
  DROP
  call _TOGGLE_HIDDEN ; hide the word while defining it
  call _RIGHT_BRACKET ; set state to compiling
  ; We need some way to find this unnamed thing, so push its xt.
  call _LATEST
  NEXT

; Ends the current definition. ( -- )
  DEFCODE ";", _SEMICOLON, FLAG_IMMEDIATE
  PUSH16 $c9        ; ret opcode
  call _C_COMMA     ; append ret
  call _TOGGLE_HIDDEN ; unhide the word, it's ready
  call _LEFT_BRACKET  ; set state to interpreting
  NEXT

; Compiles a call to the word currently being compiled. ( -- )
  DEFCODE "RECURSE", _RECURSE, FLAG_IMMEDIATE
  call _LATEST      ; word currently being defined
  call _TO_BODY     ; skip past the header
  call _COMPILE_COMMA ; generate a call
  NEXT

; Appends a test and branch-if-zero sequence and pushes target address.
  DEFCODE "0BRANCH", _0BRANCH, FLAG_IMMEDIATE
  DUP               ; result
  push hl           ; save stack pointer
  ld a, [Here]      ; load Here pointer into hl
  ld l, a
  ld a, [Here+1]
  ld h, a
  ld a, $78         ; ld a, b
  ld [hli], a       ;
  ld a, $b1         ; or a, c
  ld [hli], a       ;
  ld a, $cd         ; call _DROP
  ld [hli], a       ;
  ld a, LOW(_DROP)  ;
  ld [hli], a       ;
  ld a, HIGH(_DROP) ;
  ld [hli], a       ;
  ld a, $ca         ; jp z, XXXX
  ld [hli], a       ;
  ld b, h           ; save target
  ld c, l
  inc hl            ; skip over target
  inc hl
  ld a, l
  ld [Here], a      ; update Here pointer
  ld a, h
  ld [Here+1], a
  pop hl            ; restore stack pointer
  NEXT

; Appends an unconditional branch and pushes target offset.
  DEFCODE "BRANCH", _BRANCH, FLAG_IMMEDIATE
  DUP               ; result
  push hl           ; save stack pointer
  ld a, [Here]      ; load Here pointer into hl
  ld l, a
  ld a, [Here+1]
  ld h, a
  ld a, $c3         ; jp XXXX
  ld [hli], a       ;
  ld b, h           ; save target
  ld c, l
  inc hl            ; skip over target
  inc hl
  ld a, l
  ld [Here], a      ; update Here pointer
  ld a, h
  ld [Here+1], a
  pop hl            ; restore stack pointer
  NEXT

; Appends code to branch if top of stack is false.
  DEFCODE "IF", _IF, FLAG_IMMEDIATE
  call _0BRANCH     ; append test and branch-if-zero
  NEXT

; Patches the branch target for an IF at top of stack.
  DEFCODE "THEN", _THEN, FLAG_IMMEDIATE
  ld a, [Here]      ; patch low byte of target
  ld [bc], a
  inc bc
  ld a, [Here+1]    ; patch high byte of target
  ld [bc], a
  DROP              ; pop target offset
  NEXT

; Patches the branch target for an IF with a false branch.
  DEFCODE "ELSE", _ELSE, FLAG_IMMEDIATE
  call _BRANCH      ; append a branch over the else body
  call _SWAP        ; get IF false target at top of stack
  call _THEN        ; patch up the IF false branch to go to else
  NEXT

; CASE compiles a sequence of IF statements.
  DEFCODE "CASE", _CASE, FLAG_IMMEDIATE
  ; Push a compile time stack sentinel so ENDCASE can detect when it is done
  ; patching branch targets.
  PUSH16 0
  NEXT

; OF tests whether a case matches and branches over it if not.
  DEFCODE "OF", _OF, FLAG_IMMEDIATE
  PUSH16 _OVER      ; test if case matches with OVER =
  call _COMPILE_COMMA
  PUSH16 _EQUALS
  call _COMPILE_COMMA
  call _0BRANCH     ; branch over this case if it does not match
  NEXT

; ENDOF fixes up the target for the last OF and adds a branch out.
  DEFCODE "ENDOF", _ENDOF, FLAG_IMMEDIATE
  call _ELSE
  NEXT

; Helper to patch targets left on the stack to point to here.
PatchTargets:
  ; Go back through the stack and patch all the branch targets left
  ; by ENDOF or LEAVE to point to DE, stopping when we hit a 0.
  ld a, b           ; test if we hit sentinel
  or a, c
  jr z, .done       ; if sentinel, nothing left to patch
  ld a, e
  ld [bc], a        ; patch low byte of target
  inc bc
  ld a, d
  ld [bc], a        ; patch high byte of target
  DROP              ; done with this target
  jr PatchTargets
.done
  DROP              ; drop sentinel
  NEXT

; ENDCASE patches all the out branches leftover from ENDOF.
  DEFCODE "ENDCASE", _ENDCASE, FLAG_IMMEDIATE
  ld a, [Here]      ; de = endcase offset
  ld e, a
  ld a, [Here+1]
  ld d, a
  PUSH16 _DROP      ; append code to DROP the CASE value
  call _COMPILE_COMMA
  jp PatchTargets   ; tail call patch ENDOF targets and pop sentinel

; BEGIN just pushes the current output position.
  DEFCODE "BEGIN", _BEGIN, FLAG_IMMEDIATE
  call _HERE
  NEXT

; AGAIN branches back to BEGIN.
  DEFCODE "AGAIN", _AGAIN, FLAG_IMMEDIATE
  call _BRANCH      ; stack will be ( ... -- begin-addr again-target )
  call _STORE       ; stores begin-addr to again-target
  NEXT

; UNTIL conditionally branches back to BEGIN.
  DEFCODE "UNTIL", _UNTIL, FLAG_IMMEDIATE
  call _0BRANCH     ; stack will be ( ... -- begin-addr until-target )
  call _STORE       ; stores begin-addr to until-target
  NEXT

; WHILE branches over the loop body if a condition is false.
  DEFCODE "WHILE", _WHILE, FLAG_IMMEDIATE
  call _0BRANCH     ; stack will be ( ... -- begin-addr while-target )
  NEXT

; REPEAT branches back to BEGIN, and patches the WHILE jump to jump over the loop.
  DEFCODE "REPEAT", _REPEAT, FLAG_IMMEDIATE
  call _SWAP        ; ( begin-addr while-target -- while-target begin-addr )
  call _BRANCH      ; ( ... -- while-target begin-addr repeat-target )
  call _STORE       ; stores begin-addr to repeat-target
  call _HERE        ; ( ... -- while-target HERE )
  call _SWAP
  call _STORE       ; stores HERE to while-target 
  NEXT

; Compiles the setup code for an indexed do ... loop.
  DEFCODE "DO", _DO, FLAG_IMMEDIATE
  PUSH16 _DO_RUNTIME  ; compile a call to the do setup
  call _COMPILE_COMMA
  PUSH16 0          ; dummy to match ?DO stack
  call _HERE        ; push target address for LOOP
  PUSH16 0          ; push sentinel to indicate end of LEAVE chain
  NEXT

; Compiles the setup code for an indexed ?do ... loop.
  DEFCODE "?DO", _QUESTION_DO, FLAG_IMMEDIATE
  PUSH16 _QUESTION_DO_RUNTIME ; compile call to ?do setup and check
  call _COMPILE_COMMA
  call _0BRANCH     ; jump out of loop if check fails
  call _HERE        ; push target address for LOOP
  PUSH16 0          ; push sentinel to indicate end of LEAVE chain
  NEXT

; Compiles the backwards branch for an indexed do ... loop.
  DEFCODE "LOOP", _LOOP, FLAG_IMMEDIATE
  PUSH16 1
  call _LITERAL     ; compile default loop increment
  call _PLUS_LOOP
  NEXT

; Compiles the backwards branch for an indexed do ... loop.
  DEFCODE "+LOOP", _PLUS_LOOP, FLAG_IMMEDIATE
  PUSH16 _LOOP_RUNTIME ; compile a call to the plus loop step
  call _COMPILE_COMMA
  ld a, [Here]      ; de = beyond loop
  add a, 3
  ld e, a
  ld a, [Here+1]
  adc a, 0
  ld d, a
  call PatchTargets ; patch any LEAVE targets and pop sentinel
  call _0BRANCH     ; ( ... -- ?do-addr do-addr loop-target )
  call _STORE       ; stores do-addr to loop-target
  ld a, b           ; test if ?do-addr is 0
  or a, c
  jr z, .out        ; skip if not a ?do loop
  ld a, e
  ld [bc], a        ; store beyond loop to ?do-addr branch 
  inc bc
  ld a, d
  ld [bc], a
.out
  DROP              ; drop ?do-addr
  NEXT

; Escapes a do-loop or ?do-loop.
  DEFCODE "LEAVE", _LEAVE, FLAG_IMMEDIATE
  PUSH16 _UNLOOP    ; discard loop stuff
  call _COMPILE_COMMA
  ; This branch target will be patched by LOOP.
  call _BRANCH      ; branch out of loop
  NEXT

; Runtime setup for DO. ( limit start -- )
  DEFCODE "(DO)", _DO_RUNTIME, 0
  PUSH2R            ; R:( -- limit start )
  NEXT

; Check whether ?DO loop bounds are sane. ( limit start -- flag )
  DEFCODE "(?DO)", _QUESTION_DO_RUNTIME, 0
  call _2DUP        ; ( -- limit start limit start )
  call _EQUALS      ; ( -- limit start flag )
  call _M_ROT       ; ( -- flag limit start )
  PUSH2R            ; R:( -- limit start ) ( -- flag )
  NEXT

; Runtime stepping for LOOP and +LOOP.
  DEFCODE "(LOOP)", _LOOP_RUNTIME, 0
  ; Expect that the stack contains an increment.
  ld d, b           ; pop the increment in de
  ld e, c
  DROP
  push hl
  push bc
  ; the return stack layout will look like
  ; <bc> <hl> <RET> <limit> <start>
  ; SP   +2   +4    +6      +8
  ld hl, sp+8       ; point at loop counter
  ld a, [hli]       ; fetch loop counter
  ld c, a
  ld a, [hl]
  ld b, a
  ld a, c           ; add increment to the counter
  add e
  ld c, a
  ld a, b
  adc d
  ld b, a
  ld a, b           ; store loop counter
  ld [hld], a
  ld a, c
  ld [hld], a
  ld a, [hld]       ; load de = loop limit
  ld d, a
  ld a, [hl]
  ld e, a
  ; check if the new loop counter is at its limit
  ld a, b
  cp a, d
  jr nz, .continue
  ld a, c
  cp a, e
  jr nz, .continue
  pop bc
  pop hl
  pop de            ; save return address
  pop af            ; discard loop counters
  pop af
  push de           ; put back return address
  PUSH16 TRUE       ; flag that we are done
  NEXT
.continue
  pop bc
  pop hl
  PUSH16 FALSE      ; flag that loop is not done
  NEXT

; Pushes the current loop counter. ( -- n )
  DEFCODE "I", _I, 0
  push hl
  push bc
  ; the return stack layout will look like
  ; <bc> <hl> <RET> <limit> <start>
  ; SP   +2   +4    +6      +8     
  ld hl, sp+8       ; point at loop counter
  ld a, [hli]       ; set de to loop counter
  ld e, a
  ld a, [hli]
  ld d, a
  pop bc
  pop hl
  DUP               ; push I
  ld b, d
  ld c, e
  NEXT

; Pushes the current _outer_ loop counter. ; ( -- n )
  DEFCODE "J", _J, 0
  push hl
  push bc
  ; the return stack layout will look like
  ; <bc> <hl> <RET> <limit> <start> <limit> <start>
  ; SP   +2   +4    +6      +8      +10     +12
  ld hl, sp+12      ; point at outer loop counter
  ld a, [hli]       ; set de to outer loop counter
  ld e, a
  ld a, [hli]
  ld d, a
  pop bc
  pop hl
  DUP               ; push J
  ld b, d
  ld c, e
  NEXT

; Removes the current loop counter and limit from the return stack.
  DEFCODE "UNLOOP", _UNLOOP, 0
  POP2R             ; pop return stack twice
  NEXT

; In standard forth ABORT drops back into the interpreter.
; This behavior is kind of what we want to happen though.

; Aborts the program with an error.
  DEFCODE "ABORT", _ABORT, 0
  jp Error

; Macro to print an error and then abort the program.
  DEFCODE "ABORT\"", _ABORT_QUOTE, FLAG_IMMEDIATE
  call _DOT_QUOTE
  jp Error

; The outer interpreter loop is called QUIT (no really).
  DEFCODE "QUIT", _QUIT, 0
  ld hl, ParameterStack-1
  ld bc, STACK_SENTINEL
  di
  ld sp, TopOfStack
  ei
  call _LEFT_BRACKET  ; set state to interpreting
.next_word
  PUSH16 " "
  call _WORD        ; scan the next word of input
  ld a, [bc]        ; get length of the word
  or a, a           ;
  jr z, .eof        ; length 0 means we hit eof
  call _FIND        ; try to look up the word
  ld a, c           ; get find result flags in a
  or a, a
  jr z, .number     ; 0 -> word not found, assume number instead
  cp a, 1
  jr z, .run_word   ; 1 -> immediate word, execute word now
  ; found a compiled word
  ld a, [State]
  or a, a           ; test state
  jr z, .run_word   ; if interpreting, execute word now
  ; else we are compiling and found a compiled word
  DROP              ; drop flags
  call _COMPILE_COMMA ; compile xt
  jr .next_word
.run_word
  DROP              ; drop flags
  call _EXECUTE     ; execute xt
  jr .next_word
.number
  dec hl            ; discard find flags
  dec hl
  DROP              ; discard missing word and reset top
  call _NUMBER      ; push the number
  ld a, [State]
  or a, a           ; test state
  call nz, _LITERAL ; if compiling, append code to push
  jr .next_word
.eof
  ld a, [State]
  or a, a           ; test state
  jp z, Done        ; eof when interpreting -> done
  jp Error          ; else eof when compiling -> error

; Strangely, _QUIT is how we enter the interpreter.
EXPORT _QUIT

; Appends opcode D with argument BC to [Here], and advances Here.
AppendCode:
  push hl
  ld a, [Here]    ; get output pointer
  ld l, a
  ld a, [Here+1]
  ld h, a
  ld a, d           ; get prefix from D
  ld [hl], a        ; output prefix (e.g. call instruction)
  inc hl
  ld [hl], c        ; output word from top of stack
  inc hl
  ld [hl], b
  inc hl
  ld a, l           ; advance and save output pointer
  ld [Here], a
  ld a, h
  ld [Here+1], a
  pop hl
  ret