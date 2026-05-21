INCLUDE "hardware.inc"
INCLUDE "ibmpc1.inc"

SECTION "Globals", WRAM0
CurChar: db
FrameCounter: db
CurButtons: db
NewButtons: db
CursorPtr: dw

SECTION "Top of stack", WRAMX[$DFFF], BANK[1]
TopOfStack: ds 0

SECTION "OAM Shadow", WRAM0[$CF00]
OamShadow: ds OAM_SIZE
def PickerY equ OamShadow + 0
def PickerX equ OamShadow + 1

SECTION "OAM copy routine", ROM0
; DMA transfer (ROM copy, must be called in HRAM instead).
RomOamCopy:
    ld a, HIGH(OamShadow)
    ldh [rDMA], a   ; start DMA transfer (starts right after instruction)
    ld a, 40        ; delay for a total of 4×40 = 160 M-cycles
.wait:
    dec a           ; 1 M-cycle
    jr nz, .wait    ; 3 M-cycles
    ret
.End

SECTION "HRAM", HRAM
OamCopy: ds RomOamCopy.End - RomOamCopy

SECTION "Header", ROM0[$100]
  jp Boot
  ds $150 - @, 0  ; Reserve space for the header

def KEYBOARD_TOP equ SCREEN_HEIGHT_PX - 8 * 4 

Boot:
  nop
  di
  ; Set up stack at top of WRAM. We will use the hardware stack as the parameter
  ; stack, but will also use it for subroutines during startup.
  ld sp, TopOfStack
  ld a, 0
  ld [CurButtons], a
  ld [NewButtons], a
  ld [FrameCounter], a
  ld a, 32
  ld [CurChar], a
  ld a, LOW($9820)
  ld [CursorPtr], a
  ld a, HIGH($9820)
  ld [CursorPtr+1], a

  ; Turn off audio
  ld [rNR52], a

  ; Wait for vblank before turning off LCD
.wait_for_vblank:
  ld a, [rLY]
  cp SCREEN_HEIGHT_PX
  jr c, .wait_for_vblank
  ; Disable LCD
  ld a, 0
  ld [rLCDC], a

  ; Copy tiles for font into VRAM at $8000
  ld de, Font
  ld hl, $8000
  ld bc, Font.End - Font
  call CopyMemory

  ; Clear tilemaps for text entry and for window
  ld hl, TILEMAP0
  ld bc, 2 * (TILEMAP1 - TILEMAP0)
  ld d, 32
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
  ld [hl], 16 + KEYBOARD_TOP ; y
  inc hl
  ld [hl], 7        ; x
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

  ; Print startup message
  ld de, Message
  ld hl, TILEMAP0
  ld bc, Message.End - Message
  call CopyMemory

  ; Turn on LCD and enable BG with tiles starting from $8000
  ld a, (LCDC_ON\
         | LCDC_WIN_ON | LCDC_WIN_9C00\
         | LCDC_BG_ON | LCDC_BLOCK01 | LCDC_BG_9800\
         | LCDC_OBJ_ON | LCDC_OBJ_8)
  ld [rLCDC], a

  ; Initialize bg palette
  ld a, %11100100
  ld [rBGP], a
  ld [rOBP0], a

Main:
  ld a, [rLY]       ; Wait for end of current vblank
  cp SCREEN_HEIGHT_PX
  jr nc, Main
.wait_for_vblank:
  ld a, [rLY]       ; Wait for start of next vblank
  cp SCREEN_HEIGHT_PX
  jr c, .wait_for_vblank
  ; Now we are at the start of vblank
  ; Update sprites
  call OamCopy

  call UpdateButtons
  ld a, [NewButtons]    ; DULRSEBA
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
  jr .draw_cursor
.picker_down:
  ld a, [PickerY]
  add a, 8
  ld [PickerY], a
  jp .draw_cursor
.picker_up:
  ld a, [PickerY]
  sub a, 8
  ld [PickerY], a
  jp .draw_cursor
.picker_right:
  ld a, [PickerX]
  add a, 8
  ld [PickerX], a
  jp .draw_cursor
.picker_left:
  ld a, [PickerX]
  sub a, 8
  ld [PickerX], a
  jp .draw_cursor
.backspace
  ld a, 32
  ld [CurChar], a
  ld de, -1
  call MoveCursor
  jp .draw_cursor
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
  ld de, 1
  ld [CurChar], a
  call MoveCursor
.draw_cursor
  ld b, 219         ; Show cursor on 1/4 of frames
  ld a, [FrameCounter]
  and a, 16
  jr z, .put
  ld a, [CurChar]   ; Show char on frames 10-19
  ld b, a
.put
  call PutChar
  ld a, [FrameCounter]
  inc a
  ld [FrameCounter], a
  jp Main

; Puts B at current cursor position
PutChar:
  ld hl, CursorPtr
  ld a, [hli]
  ld h, [hl]
  ld l, a
  ld a, b
  ld [hl], a
  ret

; Adjust cursor position
MoveCursor:
  ld a, [CurChar]
  ld b, a
  call PutChar
  ld hl, CursorPtr
  ld a, [hli]
  ld h, [hl]
  ld l, a
  add hl, de
  ld a, l
  ld [CursorPtr], a
  ld a, h
  ld [CursorPtr+1], a
  ; Buffer character from new screen pos
  ld a, [hl]
  ld [CurChar], a
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
  ld b, a ; B7-4 = 1; B3-0 = unpressed buttons

  ; Poll the other half
  ld a, JOYP_GET_CTRL_PAD
  call .read_one_nibble
  swap a            ; A7-4 = unpressed directions; A3-0 = 1
  xor a, b          ; A = pressed buttons + directions
  ld b, a           ; B = pressed buttons + directions

  ; And release the controller
  ld a, JOYP_GET_NONE
  ldh [rJOYP], a

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

Message:
  db "gbforth 1.0"
.End

OnScreenKeyboard:
  ; Pad rows to 32 bytes to match VRAM tilemap width.
  ;   01234567890123456789012345678901
  db "1234567890 !\"#$%&'()            "
  db "QWERTYUIOP *+,-./:;<            "
  db "ASDFGHJKL  =>?@[\\]^_            "
  db "ZXCVBNM  \r  `\{|\}~                "
.End

SECTION "Tile data", ROM0
Font:
  chr_IBMPC1 1, 8 ; Load entire character set
.End
