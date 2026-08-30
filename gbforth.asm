INCLUDE "hardware.inc"
INCLUDE "ibmpc1.inc"

SECTION "PPU stat handler", ROM0[$0048]
  jp StatInterrupt
SECTION "VBlank handler", ROM0[$0040]
  jp VBlankInterrupt

SECTION "Print buffer", WRAM0[$C000]
def PRINT_QUEUE_SIZE equ 32
def PRINT_QUEUE_MASK equ 31
PrintQueue: ds PRINT_QUEUE_SIZE
PrintQueueLength: db
PrintQueueHead: db
PrintQueueTail: db

SECTION "Globals", WRAM0
CurChar: db
FrameCounter: db
KeyTimer: db
CurButtons: db
NewButtons: db
CursorX: db
CursorY: db
CursorPtr: dw       ; cursor pointer in video ram
CurPage: db         ; current page number
PageBasePtr: dw     ; base address of current page in save ram
PagePtr: dw         ; where editor stores chars in save ram
Editing: db
SavedPagePtr: dw    ; editor position before running program
LastWordScanPtr: dw  ; start of last word text

; A ram trampoline to jump via an indirect pointer.
Indirect: ds 3
EXPORT Indirect

State: dw           ; 0 if interpreting, $ffff if compiling
EXPORT State
Base: dw            ; current base for printing and scanning numbers
                    ; 2 bytes because BASE requires it be a cell
EXPORT Base
Here: dw            ; Here points to the next free byte of user memory
EXPORT Here
ScanPtr: dw         ; The next character of the program input to scan
EXPORT ScanPtr
Latest: dw          ; Points to the most recent dictionary entry
EXPORT Latest
Temp: dw            ; Temporary for sorting out stack messes
EXPORT Temp
Key: db             ; Input key from virtual keyboard
EXPORT Key
WordFlags: db       ; Header of the current dictionary entry
EXPORT WordFlags
PicPtr: dw          ; Index for pictured numeric output
EXPORT PicPtr
PicLen: db
EXPORT PicLen
EvalEndPtr: dw      ; If nonzero, the end of the current eval
EXPORT EvalEndPtr
EvalEndChar: db     ; Saved character at end of current eval
EXPORT EvalEndChar
EvalScanPtr: dw     ; Saved scan position before eval
EXPORT EvalScanPtr

; Note: wordlen must immediately precede FormatBuf so that it can be treated as
; a length-prefixed byte string.
WordLen:   db       ; Length of the most recent scanned word
EXPORT WordLen
; Last character is a sentinel
def FORMAT_BUF_LEN      equ 32
EXPORT FORMAT_BUF_LEN
def END_SENTINEL        equ $ff
EXPORT END_SENTINEL
FormatBuf: ds FORMAT_BUF_LEN + 1
EXPORT FormatBuf

; Space reserved for parameter stack
def STACK_SENTINEL equ $bad5
EXPORT STACK_SENTINEL
def PARAMETER_STACK_SIZE equ 256
ParameterStack: ds PARAMETER_STACK_SIZE
EXPORT ParameterStack

SECTION "User", WRAMX[$D000]
User: ds 4*1024     ; Reserved for user programs.
EndOfUser: ds 0
EXPORT EndOfUser

SECTION "Save RAM", SRAM[$A000], BANK[0]
def PAGE_SIZE equ TILEMAP_AREA
def NUM_PAGES equ 8
def SAVE_SIZE equ PAGE_SIZE * NUM_PAGES
SaveData: ds  SAVE_SIZE
EXPORT SaveData
EXPORT SAVE_SIZE

; Editor control codes
export CR
def CR equ 13
def UP equ 24
def DN equ 25
def RT equ 26
def LT equ 27
def PGUP equ 30
def PGDN equ 31
export SC
def SC equ 32

def EDITOR_PALETTE   equ %11100100
def KEYBOARD_PALETTE equ %10010011

; Keyboard geometry
def KEYBOARD_TOP   equ SCREEN_HEIGHT_PX - 8 * 4
def PICKER_START_Y equ 16 + KEYBOARD_TOP
def PICKER_END_Y   equ PICKER_START_Y + 4 * 8
def PICKER_START_X equ 7
def PICKER_END_X   equ PICKER_START_X + 8 * SCREEN_WIDTH

; Key repeat params
def KEY_REPEAT_RESET equ $10  ; frames before first repeat
def KEY_REPEAT_RATE  equ $4   ; frames between repeats

; Use up to 31 columns and scroll when we hit the last column, so that we don't
; wrap around and show the first character offscreen to the right.
def MAX_COLUMN    equ TILEMAP_WIDTH
def SCROLL_COLUMN equ SCREEN_WIDTH - 1
def SCROLL_ROW    equ SCREEN_HEIGHT - 5

SECTION "Top of stack", WRAMX[$DFFF], BANK[1]
TopOfStack: ds 0
EXPORT TopOfStack

SECTION "OAM Shadow", WRAM0[$CF00]
OamShadow: ds OAM_SIZE
def PickerY equ OamShadow + 0
def PickerX equ OamShadow + 1

SECTION "Digit table", ROM0, ALIGN[16]
Digits: db "0123456789ABCDEF"
EXPORT Digits

SECTION "OAM copy routine", ROM0
; DMA transfer (ROM copy, must be called in HRAM instead).
RomOamCopy:
  ld a, HIGH(OamShadow)
  ldh [rDMA], a     ; start DMA transfer (starts right after instruction)
  ld a, 40          ; delay for a total of 4×40 = 160 M-cycles
.wait:
  dec a             ; 1 M-cycle
  jr nz, .wait      ; 3 M-cycles
  ret
.End

SECTION "HRAM", HRAM
OamCopy: ds RomOamCopy.End - RomOamCopy

SECTION "Header", ROM0[$100]
  jp Boot
  ds $150 - @, 0  ; Reserve space for the header

Boot:
  nop
  di
  ld sp, TopOfStack
  xor a
  ld [rNR52], a     ; Turn off audio right away.
  call DisableLCD

  ; Clear all of WRAM for sanity.
  ld hl, $c000
  ld bc, $2000 - 4  ; Don't clobber return address on stack.
  ld d, 0
  call FillMemory
  ; Init globals in WRAM.
  ld a, 1
  ld [CursorY], a
  ld a, 1
  ld [Editing], a
  ld a, LOW($9820)
  ld [CursorPtr], a
  ld a, HIGH($9820)
  ld [CursorPtr+1], a
  ld a, LOW(SaveData)
  ld [PageBasePtr], a
  ld a, HIGH(SaveData)
  ld [PageBasePtr+1], a
  ld a, LOW(SaveData+$20)
  ld [PagePtr], a
  ld a, HIGH(SaveData+$20)
  ld [PagePtr+1], a
  call ResetProgramState
  ld a, $c3         ; c3 is JP, set up trampoline for indirect jumps
  ld [Indirect], a

  ; Copy tiles for font into VRAM at $8000
  ld de, Font
  ld hl, $8000
  ld bc, Font.End - Font
  call CopyMemory

  ; See if data is in save ram
  ld a, RAMG_SRAM_ENABLE
  ld [rRAMG], a
  ld hl, Header
  ld bc, SaveData
  ld d, Header.End - Header
.test_header
  ld a, [bc]        ; get byte of save data
  cp a, [hl]        ; cp with header
  jr nz, .clear_save_ram ; if mismatch, reset save
  inc bc            ; next save data byte
  inc hl            ; next header byte
  dec d             ; count chars
  jr nz, .test_header ; check if done comparing
  jr .load_page0    ; match, load save page 0
.clear_save_ram
  ; Fill save ram with spaces
  ld hl, SaveData
  ld bc, SAVE_SIZE
  ld d, SC
  call FillMemory
  ; Set last byte of save ram to an invisible end sentinel to prevent scanning
  ; past the end of input.
  ld hl, SaveData + SAVE_SIZE - 1
  ld a, END_SENTINEL
  ld [hl], a
  ; Copy header into save ram so we keep it next time
  ld de, Header
  ld hl, SaveData
  ld bc, Header.End - Header
  call CopyMemory
.load_page0
  xor a
  call LoadPageWithLCDDisabled

  ; Init character at cursor pos
  ld hl, $9820
  ld a, [hl]
  ld [CurChar], a

  ; Clear tilemap for window
  ld hl, TILEMAP1
  ld bc, TILEMAP_AREA
  ld d, SC
  call FillMemory

  ; Install OAM DMA routine in HRAM
  ld de, RomOamCopy
  ld hl, OamCopy
  ld bc, RomOamCopy.End - RomOamCopy
  call CopyMemory

  ; Init OAM
  ld hl, OamShadow
  ld bc, OAM_SIZE
  ld d, 0
  call FillMemory
  ; Init cursor sprite
  ld hl, OamShadow
  ld [hl], PICKER_START_Y ; y
  inc hl
  ld [hl], PICKER_START_X ; x
  inc hl
  ld [hl], 0        ; tile $95 (_)
  inc hl
  ld [hl], $80      ; behind bg

  ; Copy on screen keyboard to window tilemap
  ld de, OnScreenKeyboard
  ld hl, TILEMAP1
  ld bc, OnScreenKeyboard.End - OnScreenKeyboard
  call CopyMemory

  ; Position keyboard window
  ld a, KEYBOARD_TOP
  ld [rWY], a
  ld a, 7
  ld [rWX], a
  ; Raster interrupt to switch palettes for keyboard window
  ld a, KEYBOARD_TOP - 1
  ld [rLYC], a
  ld a, STAT_LYC | STAT_MODE_1
  ld [rSTAT], a

  ; Turn on LCD and enable BG with tiles starting from $8000
  call EnableLCD

  ; Initialize bg palette
  ld a, EDITOR_PALETTE
  ld [rBGP], a
  ld [rOBP0], a

  ; Enable interrupts
  ld a, IE_STAT | IE_VBLANK
  ld [rIE], a
  ei

Editor:
  ; The editor updates during vblank and otherwise does nothing.
  ld a, 1
  ld [Editing], a
  halt
  nop
  ld a, [NewButtons]; DULRSEBA
  and a, $8         ; if start is pressed, enter interpreter
  jr z, Editor
  ; Wait for START to be released so we do not immediately return.
.wait_for_release
  halt
  nop
  ld a, [NewButtons]; DULRSEBA
  and a, $8         ; if start is released, enter interpreter
  jr nz, .wait_for_release

  ; fall through to interpreter

Interpreter:
  ; Clear tilemap for output and reset cursor position
  di
  call DisableLCD
  ld hl, TILEMAP0
  ld bc, TILEMAP_AREA
  ld d, SC
  call FillMemory
  call EnableLCD
  ; Save current cursor position for after program runs
  ld a, [PagePtr]
  ld [SavedPagePtr], a
  ld a, [PagePtr+1]
  ld [SavedPagePtr+1], a
  xor a             ; clear cursor position for output
  ld [CursorY], a
  ld [CursorX], a
  ld [Key], a       ; reset any buffered input key
  ld a, LOW(TILEMAP0)
  ld [CursorPtr], a
  ld a, HIGH(TILEMAP0)
  ld [CursorPtr+1], a
  ld a, SC
  ld [CurChar], a
  ; Start from the beginning of the program.
  xor a
  ld [Editing], a
  ld a, LOW(SaveData)
  ld [ScanPtr], a
  ld [LastWordScanPtr], a
  ld a, HIGH(SaveData)
  ld [ScanPtr+1], a
  ld [LastWordScanPtr+1], a
  ei
  ; Reset the compiler state each time we run...
  call ResetProgramState
  ; _QUIT is the canonical name of the forth repl loop...
  call _QUIT

; Flag program done executing. Tell the user, unwind the stack and bail.
EXPORT Done
Done:
  call ResetEval
  ; TODO flag done somehow (cursor?)
  ; Pause so the user can see output.
  halt
  nop
  ld a, [NewButtons]; DULRSEBA
  and a, $8         ; if start is pressed, go ahead
  jr z, Done
.wait_for_release
  halt
  nop
  ld a, [NewButtons]; DULRSEBA
  and a, $8         ; if start is still pressed, wait
  jr nz, .wait_for_release
  ; Restore old cursor position prior to starting program
  ld a, [SavedPagePtr]
  ld [ScanPtr], a
  ld a, [SavedPagePtr+1]
  ld [ScanPtr+1], a
  call MoveCursorToScanPtr
  jp Editor

; Flag an error condition. Unwind the stack and bail.
EXPORT Error
Error:
  call ResetEval
  ld a, [LastWordScanPtr]
  ld [ScanPtr], a
  ld a, [LastWordScanPtr+1]
  ld [ScanPtr+1], a
  call MoveCursorToScanPtr
  ; TODO flag error somehow (cursor?)
  jp Editor

ResetProgramState:
  ld a, 10
  ld [Base], a
  ld a, END_SENTINEL
  ld [FormatBuf + FORMAT_BUF_LEN], a  ; one byte past end of usable buffer
  ld a, LOW(last_entry)
  ld [Latest], a
  ld a, HIGH(last_entry)
  ld [Latest+1], a
  ld a, LOW(User)
  ld [Here], a
  ld a, HIGH(User)
  ld [Here+1], a
  xor a
  ld [EvalEndPtr], a
  ld [EvalEndPtr+1], a
  ret

; Cleans up sentinel eof character after evaluate string and resets scan ptr.
; Called both between program runs for sanity, and when the interpreter hits
; the eof at the end of an eval.
;
; Returns with z set if there was no eval.
ResetEval:
EXPORT ResetEval
  ld a, [EvalEndPtr] ; get de = eval end char ptr
  ld e, a
  ld a, [EvalEndPtr+1]
  ld d, a
  or a, e
  ret z             ; if ptr is 0, no eval pending
  ld a, [EvalEndChar]
  ld [de], a        ; replace char overwritten by sentinel
  ; Reset scan ptr. This is for QUIT which needs to continue scanning.
  ; Done and Error will simply ignore ScanPtr here.
  ld a, [EvalScanPtr]
  ld [ScanPtr], a
  ld a, [EvalScanPtr+1]
  ld [ScanPtr+1], a
  ; Reset eval end ptr
  xor a
  ld [EvalEndPtr], a
  ld [EvalEndPtr+1], a
  inc a             ; clear z flag
  ret

MoveCursorToScanPtr:
  ; Turn off output so we can load the correct page into vram.
  di
  call DisableLCD
  ; Subtract ScanPtr from base address.
  ld a, [ScanPtr]
  sub a, LOW(SaveData)
  ld c, a
  ld a, [ScanPtr+1]
  sbc a, HIGH(SaveData)
  ld b, a
  push bc
  ; Divide by 1024 to get page
  srl a             ; high byte is in a, divide by 256 * 4
  srl a
  call LoadPageWithLCDDisabled ; load page #
  ; Get offset in page
  pop bc
  ld a, c           ; compute x = offset % 32
  and a, $1f
  ld [CursorX], a
  ld a, b           ; compute y = offset / 32
  and a, $3
  rl c              ; rotate 3 bits up into a
  rl a
  rl c
  rl a
  rl c
  rl a
  ld [CursorY], a
  ; Clear print queue so pending output doesn't clobber the program.
  xor a
  ld [PrintQueueLength], a
  ld [PrintQueueHead], a
  ld [PrintQueueTail], a
  ; Call editor routine to update screen state for the selected position.
  call DoMoveCursor
  ; Turn on output again
  call EnableLCD
  ei
  ret

; Prints the signed number BC.
EXPORT PutSignedNumber
PutSignedNumber:
  bit 7, b
  jr z, PutUnsignedNumber ; if sign bit is 0, just print magnitude
  ld a, "-"
  call PutChar      ; print minus sign
  call Negate       ; negate the number
  ; fall through to PutUnsignedNumber
; Prints the unsigned number BC.
EXPORT PutUnsignedNumber
PutUnsignedNumber:
  ld hl, FormatBuf + FORMAT_BUF_LEN - 1
  ld a, [Base]
  ld d, a
.get_digits
  call UnsignedDiv16By8
  ld [hld], a
  ld a, b
  or a, c
  jr nz, .get_digits
  inc hl
.print_digits
  ld a, [hli]
  cp a, END_SENTINEL
  ret z
  push hl
  ld h, HIGH(Digits)
  ld l, a
  ld a, [hl]
  call PutChar
  pop hl
  jr .print_digits

; Scans the signed number pointed to by HL (with length A) into BC.
; May start with - to indicate a negative number, followed by a 
; special character selecting the base, otherwise we use [Base].
; Carry is clear if success, otherwise set if an error.
; Leaves HL at the character after the number.
EXPORT ScanSignedNumber
ScanSignedNumber:
  or a, a           ; test buffer length
  jr z, .error      ; if buffer is empty, not a number
  ld d, a           ; D = length remaining
  ; Check for minus sign
  xor a             ; clear A
  ld [Temp], a      ; set Temp=0 to assume result is positive
  ld a, [hl]
  cp a, "-"         ; found -?
  jr nz, .check_base
  ld [Temp], a      ; set Temp=- to flag result negative
  dec d             ; count minus sign consumed
  jr z, .error      ; if no remaining digits error
  inc hl            ; skip past minus sign
.check_base
  ; Check if selecting a different base.
  ld a, [hl]        ; peek first character
  cp a, "$"
  jr z, .hex        ; if $ scan hex number
  cp a, "%"
  jr z, .binary     ; if % scan binary number
  ld a, [Base]      ; else use default conversion base
  jr .set_base
.binary
  inc hl            ; consume base char
  dec d
  ld a, 2           ; base 2
  jr .set_base
.hex
  inc hl            ; consume base char
  dec d
  ld a, 16          ; base 16
.set_base
  ld e, a           ; E = base
  ld bc, 0          ; BC = result
.scan_digit
  ld a, [hl]        ; get next char of buffer
  sub a, "0"
  jr c, .error      ; < '0' is not a digit
  cp a, 10
  jr c, .digit      ; <= '9' is a digit
  and a, $3f        ; convert to uppercase
  sub a, "A"-"0"    ; get character relative to 'A'
  jr c, .error      ; < 'A' is not a digit
  cp a, "Z"+1       ;
  jr nc, .error     ; > 'Z' is not a digit
  add a, 10         ; letters are digits over 10
.digit
  cp a, e           ;
  jr nc, .error     ; > base is not a digit
  jr z, .error      ; = base is also not a digit
  inc hl            ; consume character
  dec d             ;
  ; Shift current number accumulator over by base.
  push af
  push hl
  ld a, e
  call UnsignedMul16By8 ; bc * base
  pop hl
  pop af
  ; Add in the next digit.
  add a, c          ; (bc * base) + a
  ld c, a
  ld a, 0           ; nb: preserve carry
  adc b
  ld b, a
  ld a, d           ; check whether any digits remain
  or a, a
  jr nz, .scan_digit
  ld a, [Temp]      ; get saved sign
  or a, a           ; test sign
  call nz, Negate   ; negate if there was a minus sign
  or a, a           ; clear carry to indicate success
  ret
.error
  scf               ; set carry to flag error
  ret

; Scans the next word from [HL] into FormatBuf delimited by character C.
;
; Skips leading delims, then reads up to FORMAT_BUF_LEN non-delim characters.
; If there are more than FORMAT_BUF_LEN characters in the word, skips any excess
; characters until the next delim.
;
; Leaves HL *after* the final delimiter.
EXPORT ScanWord
ScanWord:
  ld d, HIGH(FormatBuf)
  ld e, LOW(FormatBuf)
  ld b, 0
.skip_leading_delims
  ld a, [hl]
  cp a, c
  jr nz, .start     ; if not delim, done skipping
  inc hl            ; consume delim
  jr .skip_leading_delims
.start
  push af
  ld a, l           ; save start of word for error reporting
  ld [LastWordScanPtr], a
  ld a, h
  ld [LastWordScanPtr+1], a
  pop af
  jr .store_char
.in_word
  ld a, [hl]
  cp a, c
  jr z, .final_delim ; done scanning if we see a delim
.store_char
  cp a, END_SENTINEL
  jr z, .out        ; if char is an end sentinel, stop scanning
  ld [de], a        ; store next word char
  inc de
  inc hl            ; consume char
  inc b             ; count it
  ld a, b
  cp a, FORMAT_BUF_LEN
  jr nz, .in_word   ; if more capacity, keep scanning
  ; if we ran out of buffer space in the middle of a word,
  ; skip to the next delim
.skip_excess_chars
  ld a, [hl]
  cp a, c
  jr z, .final_delim ; if found delim, done now
  cp a, END_SENTINEL
  jr z, .out        ; if found end, done now
  inc hl            ; consume extra word char
  jr .skip_excess_chars
.final_delim
  inc hl            ; consume one trailing delim
.out
  ld a, b
  ld [WordLen], a
  ret

; Looks up word at BC in the dictionary. Assumes it is prefixed with a length.
;
; Returns a pointer to the body of the dictionary entry in HL or 0 if not in
; dictionary. Returns length+flags in A and [WordFlags].
EXPORT LookupWord
LookupWord:
  ld a, [Latest]    ; point hl at head of the dictionary
  ld l, a
  ld a, [Latest+1]
  ld h, a
  jr .check_next_word
.no_match
  pop bc            ; pop input pointer
  pop hl            ; pop the next dictionary pointer
.check_next_word
  ld a, h           ; check if hl is nul now
  or a, l
  cp a, 0
  ret z             ; nul pointer -> last word of list, not found
  ld a, [hli]       ; get next pointer
  ld e, a
  ld a, [hli]
  ld d, a
  push de           ; push next dictionary pointer
  push bc           ; push input pointer (we will scan ahead)
  ld a, [hli]       ; get length+flags byte
  ld [WordFlags], a ; stash flags in case 
  and a, FLAG_HIDDEN | $1f ; mask length (+ skip hidden words)
  ld d, a           ; save length count in d
  ld a, [bc]        ; get length from input
  inc bc            ; consume char
  cp a, d           ; check if length matches
  jr nz, .no_match  ; if length doesn't match, does not match
.compare_word
  ld a, [bc]        ; next char of input
  cp a, [hl]        ; next char of dictionary
  jr nz, .no_match  ; if char differs, does not match
  inc bc            ; advance input
  inc hl            ; advance dictionary pointer
  dec d             ; count char
  jr nz, .compare_word ; continue comparing if more
  ; We found a match. hl now points at the body of the word,
  ; and [WordFlags] has the header flags.
  pop de            ; cleanup temporaries
  pop de            ;
  ld a, [WordFlags]
  ret

; Multiplies BC by the 8-bit value in A.
; Returns product in BC. Clobbers HL.
UnsignedMul16By8:
  ld hl, 0          ; accumulate 16-bit product in hl
.mul
  or a, a           ; test a
  jr z, .out        ; if multiplier is 0, we are done
  srl a             ; halve multiplier and get next bit in carry
  jr nc, .no_add    ; if even, don't accumulate
  add hl, bc
.no_add
  sla c             ; shift multiplicand left
  rl b
  jr .mul
.out
  ld b, h
  ld c, l
  ret

; Multiplies BC by DE and stores the 32-bit result in DE:BC.
; BC is the correct signed 16-bit product if there is no overflow.
Mul16By16:
EXPORT Mul16By16
  ld hl, 0
  ld a, 16          ; multiply 16 bits
  ; Accumulate partial products from most to least significant.
.loop:
  add hl, hl        ; shift partial product left
  rl e              ; carry into next result bit of de:hl
  rl d              ; shift out next most significant bit of multiplier
  jr nc, .no_mul    ; skip if next bit of multiplier is zero
  add hl, bc        ; else add multiplicand
  jr nc, .no_mul
  inc de            ; carry into high word
.no_mul
  dec a             ; next bit
  jr nz, .loop
  ld b, h
  ld c, l
  ret

; Multiplies BC by DE and stores the signed 32-bit result in DE:BC.
Mul16By16S:
EXPORT Mul16By16S
  bit 7, b
  jr nz, .bc_neg
  bit 7, d
  jr z, Mul16By16   ; BC+ DE+
  push bc           ; BC+ DE-
  call Mul16By16
  pop hl
  jr .sub           ; subtract extra BC
.bc_neg
  bit 7, d
  jr nz, .both_neg
  push de           ; BC- DE+
  call Mul16By16
  pop hl
  jr .sub           ; subtract extra DE
.both_neg
  push bc           ; BC- DE-
  push de
  call Mul16By16
  pop hl
  call .sub         ; subtract extra DE
  pop hl
  ; fall through to subtract extra BC
.sub
  ld a, e
  sub a, l
  ld e, a
  ld a, d
  sbc a, h
  ld d, a
  ret

; Divides BC:DE by the 8-bit value in [HL].
; Returns quotient in BC:DE, remainder in A.
UnsignedDiv32By8:
EXPORT UnsignedDiv32By8
  ld a, 32
  ld [Temp], a
  xor a
.div
  sla e
  rl d
  rl c
  rl b
  rl a
  cp a, [hl]
  jr c, .no_sub
  sbc [hl]
  inc e
.no_sub
  push hl
  ld hl, Temp
  dec [hl]
  pop hl
  jr nz, .div
  ret

; Divides BC by the 8-bit value in D.
; Returns quotient in BC, remainder in A.
UnsignedDiv16By8:
  ld e, 16
  xor a
.div
  sla c
  rl b
  rl a
  cp a, d
  jr c, .no_sub
  sbc d
  inc c
.no_sub
  dec e
  jr nz, .div
  ret

; Divides BC by the 16-bit value in DE.
; Returns quotient in BC, remainder in DE.
UnsignedDiv16By16:
EXPORT UnsignedDiv16By16
  ld hl, 0          ; initialize remainder to 0
; Entrypoint with preset remainder. Used for */, */MOD.
UnsignedDiv16By16R:
EXPORT UnsignedDiv16By16R
  ld a, 16          ; count 16 bits
  ld [Temp], a      ; store counter in temp
.div
  ; shift next bit of dividend into remainder
  sla c             ; shift bc left by one bit
  rl b
  rl l              ; shift carry into hl (remainder)
  rl h
  ; compare remainder with divisor
  ld a, l
  sub a, e          ; subtract least significant byte
  ld a, h
  sbc d             ; carry into most significant byte
  jr c, .no_sub     ; if carry, hl < de
  ; remainder is large enough to subtract
  ld a, l
  sub a, e
  ld l, a
  ld a, h
  sbc d
  ld h, a
  inc c             ; set lowest bit of quotient
.no_sub
  ld a, [Temp]      ; update loop counter
  dec a
  ld [Temp], a
  jr nz, .div
  ld d, h
  ld e, l
  ret

; Ones complement of bc
EXPORT Invert
Invert:
  ld a, c
  cpl
  ld c, a
  ld a, b
  cpl
  ld b, a
  ret

; Twos complement negate bc
EXPORT Negate
Negate:
  call Invert
  inc bc
  ret

; Prints the character from A.
EXPORT PutChar
PutChar:
  push af
.wait_for_room
  ld a, [PrintQueueLength]
  cp a, PRINT_QUEUE_SIZE    ; max length?
  jr nz, .has_room          ; if not, queue new char
  halt              ; wait for vblank to make room
  jr .wait_for_room
.has_room
  ld h, HIGH(PrintQueue)
  ld a, [PrintQueueTail]
  ld l, a                   ; hl = tail
  inc a                     ; advance tail
  and a, PRINT_QUEUE_MASK   ; wrap if needed
  ld [PrintQueueTail], a    ; save tail ptr
  pop af
  ld [hl], a                ; store character at tail ptr
  ; The queue length is also updated during vblank so we need to make sure to
  ; update it using a single instruction that does read+modify+write.
  ld hl, PrintQueueLength
  inc [hl]
  ret

; Turn off LCD so we can copy vram safely
DisableLCD:
  ld a, [rLCDC]
  and a, LCDC_ENABLE
  ret z
  ; Wait for vblank before disabling LCD
.wait_for_vblank
  ld a, [rLY]
  cp SCREEN_HEIGHT_PX
  jr c, .wait_for_vblank
  xor a
  ld [rLCDC], a     ; Turn off lcd.
  ret

; Re-enable LCD after disabling it temporarily
EnableLCD:
  ld a, (LCDC_ON\
         | LCDC_WIN_ON | LCDC_WIN_9C00\
         | LCDC_BG_ON | LCDC_BLOCK01 | LCDC_BG_9800\
         | LCDC_OBJ_ON | LCDC_OBJ_8)
  ld [rLCDC], a
  ret

; Load save data page A into vram
; Caller should make sure LCD is disabled first
LoadPageWithLCDDisabled:
  rlca              ; 256 * 4 * page number
  rlca
  or a, HIGH(SaveData) ; ram + page offset
  ld d, a           ; de = page offset
  ld [PageBasePtr+1], a
  ld e, LOW(SaveData)
  ld a, e
  ld [PageBasePtr], a
  ld hl, TILEMAP0
  ld bc, TILEMAP_AREA
  jp CopyMemory

; Text editor runs in vblank
VBlankInterrupt:
  push af
  push bc
  push de
  push hl

  ; Now we are at the start of vblank
  ; Update sprites
  call OamCopy

  ; If there is any output queued, prioritize printing it.
  ; We only print one character per vblank.
  ld a, [PrintQueueLength]
  or a, a           ; test if any queued characters
  jr nz, .pop_print_queue

  call UpdateButtons
  ld a, [NewButtons]; DULRSEBA
  rla               ; down
  jr c, .picker_down
  rla               ; up
  jr c, .picker_up
  rla               ; left
  jr c, .picker_left
  rla               ; right
  jr c, .picker_right
  rla               ; start
  rla               ; select
  rla               ; b
  jr c, .backspace
  rla               ; a
  jr c, .pick_char
  jp .draw_cursor
.picker_down:
  ld a, [PickerY]
  add a, 8
  cp a, PICKER_END_Y
  jr c, .picker_down_ok
  ld a, PICKER_START_Y
.picker_down_ok:
  ld [PickerY], a
  jp .draw_cursor
.picker_up:
  ld a, [PickerY]
  sub a, 8
  cp a, PICKER_START_Y
  jr nc, .picker_up_ok
  ld a, PICKER_END_Y - 8
.picker_up_ok
  ld [PickerY], a
  jp .draw_cursor
.picker_right:
  ld a, [PickerX]
  add a, 8
  cp a, PICKER_END_X
  jr c, .picker_right_ok
  ld a, PICKER_START_X
.picker_right_ok:
  ld [PickerX], a
  jp .draw_cursor
.picker_left:
  ld a, [PickerX]
  sub a, 8
  cp a, 255
  jr nz, .picker_left_ok
  ld a, PICKER_END_X - 8
.picker_left_ok:
  ld [PickerX], a
  jp .draw_cursor
.backspace
  ld a, [Editing]
  or a, a
  jr z, .draw_cursor        ; Disable backspace if not editing
  ld a, SC
  ld [CurChar], a
.left
  call CursorBack
  jp .draw_cursor
.pop_print_queue:
  dec a                     ; dec print queue length
  ld [PrintQueueLength], a  ; update it
  ld h, HIGH(PrintQueue)    ;
  ld a, [PrintQueueHead]    ;
  ld l, a                   ; hl = head of queue
  inc a                     ; advance head pointer
  and a, PRINT_QUEUE_MASK   ; wrap around if needed
  ld [PrintQueueHead], a    ; store updated head
  ld a, [hl]                ; get queued character
  jr .print_char
.pick_char:
  ld a, [PickerY]
  sub a, 16 + KEYBOARD_TOP
  rla
  rla
  ld l, a           ; L = ((y - y0) / 8) * 32
  ld a, [PickerX]
  sub a, 7
  rrca
  rrca
  rrca
  or a, l           ; L = L | ((x - x0) / 8)
  ld l, a
  ld h, HIGH(TILEMAP1)
  ld a, [hl]        ; get char from tilemap
  push af
  ld a, [Editing]
  or a, a           ; test if we are editing
  jr z, .input_char ; if not editing, input char offscreen
  pop af
.print_char
  cp a, CR          ; newline
  jr z, .newline
  cp a, DN          ; arrow down
  jr z, .down
  cp a, UP          ; arrow up
  jr z, .up
  cp a, RT          ; arrow right
  jr z, .right
  cp a, LT          ; arrow left
  jr z, .left
  cp a, PGDN
  jp z, NextPage    ; next code page
  cp a, PGUP
  jp z, PrevPage    ; previous code page
  jr .advance
.newline:
  ld a, SC
  ld [CurChar], a
  call NewLine
  jr .draw_cursor
.down
  call CursorDown
  jr .draw_cursor
.up
  call CursorUp
  jr .draw_cursor
.advance
  ld [CurChar], a
.right
  call CursorAdvance
.draw_cursor
  ld a, [Editing]
  or a, a
  jr z, .no_blink   ; Hide cursor if not editing
  ld b, 219         ; Show cursor on 1/4 of frames
  ld a, [FrameCounter]
  and a, 16
  jr z, .put
.no_blink
  ld a, [CurChar]   ; Show char on frames 10-19
  ld b, a
.put
  call VBlankPutChar
  ld a, [FrameCounter]
  inc a
  ld [FrameCounter], a
  jr .out
.input_char
  pop af
  ld [Key], a
  ; Enable scrolling even when editing is disabled because the output
  ; area is so narrow.
  ; TODO: Ideally this wouldn't mess up the current print position.
  ; TODO: Maybe allow a way to disable this if programs want to intercept
  ; arrow keys.
  cp a, DN          ; arrow down
  jr z, .down
  cp a, UP          ; arrow up
  jr z, .up
  cp a, RT          ; arrow right
  jr z, .right
  cp a, LT          ; arrow left
  jp z, .left
.out
  pop hl
  pop de
  pop bc
  pop af
  reti

; Puts B at current cursor position
VBlankPutChar:
  ld hl, CursorPtr
  ld a, [hli]
  ld h, [hl]
  ld l, a
  ld a, b
  ld [hl], a
  ret

VBlankPutCharInSaveRam:
  ld hl, PagePtr
  ld a, [hli]
  ld h, [hl]
  ld l, a
  ld a, b
  ld [hl], a
  ret

PrevPage:
  ld a, [CurPage]
  or a, a
  jr z, .set_page
  dec a
.set_page
  ld [CurPage], a
  jr SetPageFromVBlank

NextPage:
  ld a, [CurPage]
  cp a, 7
  jr z, .set_page
  inc a
.set_page
  ld [CurPage], a
  jr SetPageFromVBlank

SetPageFromVBlank:
  push af           ; save page
  xor a
  ld [rLCDC], a     ; Turn off lcd.
  pop af            ; restore page
  call LoadPageWithLCDDisabled
  ; Reset cursor position inside new page
  xor a
  ld [CursorY], a
  ld [CursorX], a
  call DoMoveCursor
  call EnableLCD    ; reenable lcd
  ; End the vblank interrupt that triggered page change
  pop hl
  pop de
  pop bc
  pop af
  reti 

CursorBack:
  ld a, [CursorX]
  or a, a
  jr z, .no_back
  dec a
  ld [CursorX], a
.no_back
  jp MoveCursor

CursorAdvance:
  ld a, [CursorX]
  inc a
  cp a, MAX_COLUMN
  jr z, NewLine
  ld [CursorX], a
  jp MoveCursor

CursorUp:
  ld a, [CursorY]
  or a, a
  jr z, UpDownStoreY
  dec a
  jr UpDownStoreY

NewLine:
  xor a
  ld [CursorX], a
CursorDown:
  ld a, [CursorY]
  inc a
  cp a, TILEMAP_HEIGHT
  jr nz, UpDownStoreY
  ld a, TILEMAP_HEIGHT - 1
UpDownStoreY:
  ld [CursorY], a
  ;jp MoveCursor

; Adjust cursor position
MoveCursor:
  ; Replace character at old cursor position
  ld a, [CurChar]
  ld b, a
  call VBlankPutChar
  ld a, [Editing]
  or a, a           ; test if editing
  call nz, VBlankPutCharInSaveRam
DoMoveCursor:
  ; Compute new cursor offset in de
  xor a             ; clear a and carry
  ld e, a           ; clear e
  ld a, [CursorY]
  ld d, a           ; de = 256 * y
  rr d
  rr e
  rr d
  rr e
  rr d
  rr e              ; de = 32 * y
  ld a, [CursorX]
  or a, e
  ld e, a           ; de = 32 * y + x
  ; Adjust cursor pointer within sram
  ld a, [PageBasePtr]
  ld l, a
  ld a, [PageBasePtr+1]
  ld h, a
  add hl, de
  ld a, l
  ld [PagePtr], a
  ld a, h
  ld [PagePtr+1], a
  ; Adjust cursor pointer within vram
  ld hl, TILEMAP0
  add hl, de
  ld a, l
  ld [CursorPtr], a
  ld a, h
  ld [CursorPtr+1], a
  ; Buffer character from new screen pos
  ld a, [hl]
  ld [CurChar], a
  ; Scroll viewport left and right if needed
  ld a, [CursorX]
  sub a, SCROLL_COLUMN
  jr nc, .scroll_x
  xor a
.scroll_x
  rla               ; note carry is clear
  rla
  rla               ; rSCX = 8 * x
  ld [rSCX], a
  ; Scroll viewport up and down if needed
  ld a, [CursorY]
  sub a, SCROLL_ROW
  jr nc, .scroll_y
  xor a
.scroll_y
  rla
  rla 
  rla               ; rSCY = 8 * y
  ld [rSCY], a
  ret

; Copy d to bc bytes at hl
FillMemory:
  ld a, d
  ld [hli], a
  dec bc
  ld a, b
  or a, c
  jr nz, FillMemory
  ret

; Copy bc bytes from de to hl
CopyMemory:
  ld a, [de]
  ld [hli], a
  inc de
  dec bc
  ld a, b
  or a, c
  jr nz, CopyMemory
  ret

; Update button state
UpdateButtons:
  ; Poll half the controller
  ld a, JOYP_GET_BUTTONS
  call .read_one_nibble
  ld b, a           ; B7-4 = 1; B3-0 = unpressed buttons

  ; Poll the other half
  ld a, JOYP_GET_CTRL_PAD
  call .read_one_nibble
  swap a            ; A7-4 = unpressed directions; A3-0 = 1
  xor a, b          ; A = pressed buttons + directions
  ld b, a           ; B = pressed buttons + directions

  ; And release the controller
  ld a, JOYP_GET_NONE
  ldh [rJOYP], a

  ; Key repeat
  ld a, [CurButtons]  ; any keys down?
  jr z, .clear_repeat ; if no keys down, no repeat
  ld a, [KeyTimer]    ; increment repeat timer
  dec a
  ld [KeyTimer], a
  jr nz, .new_buttons ; no repeat yet
  xor a
  ld [CurButtons], a  ; reset cur buttons so we repeat
  ld a, KEY_REPEAT_RATE
  ld [KeyTimer], a    ; reset key timer to repeat rate
  jr .new_buttons
.clear_repeat
  ld a, KEY_REPEAT_RESET
  ld [KeyTimer], a    ; reset key repeat timer
.new_buttons

  ; Combine with previous CurButtons to make NewButtons
  ld a, [CurButtons]
  xor a, b          ; A = keys that changed state
  and a, b          ; A = keys that changed to pressed
  ld [NewButtons], a
  ld a, b
  ld [CurButtons], a
  ret

.read_one_nibble
  ldh [rJOYP], a    ; switch the key matrix
  call .delay10     ; burn 10 cycles calling a known ret
  ldh a, [rJOYP]    ; ignore value while waiting for the key matrix to settle
  ldh a, [rJOYP]    
  ldh a, [rJOYP]    ; this read counts
  or a, $F0         ; A7-4 = 1; A3-0 = unpressed keys
.delay10
  ret

; Raster interrupt to toggle keyboard palette
; Turns on keyboard palette on LY=LYC, and resets it on vblank
StatInterrupt:
  push af
  ld a, [rSTAT]
  and a, STAT_LYCF
  jr z, .reset_pal  ; vblank occurred, keyboard done
  ; LY is one line above the keyboard, wait til end of visible line
  ld a, 9
.delay:
  dec a
  jr nz, .delay
  ; Reset object palette to inverse video to distinguish keyboard
  ld a, KEYBOARD_PALETTE
  jr .set_pal
.reset_pal:
  ; Reset normal palette for text editor area
  ld a, EDITOR_PALETTE
.set_pal:
  ld [rBGP], a
  pop af
  reti

Header:
  db "( gbforth )"
.End

OnScreenKeyboard:
  ; Pad rows to 32 bytes to match VRAM tilemap width.
  db "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", " ", "!", "\"", "#",  "$", "%",  "&", "'", "(", ")", "            "
  db "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", " ", "*",  "+", ",",  "-", ".",  "/", ":", ";", "<", "            "
  db "A", "S", "D", "F", "G", "H", "J", "K", "L",  24,  13, "=",  ">", "?",  "@", "[", "\\", "]", "^", "_", "            "
  db "Z", "X", "C", "V", "B", "N", "M",  27,  26,  25, " ", "`", "\{", "|", "\}", "~",  " ", " ",  31,  30, "            "
.End

SECTION "Tile data", ROM0
Font:
  chr_IBMPC1 1, 8 ; Load entire character set
.End
