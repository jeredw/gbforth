INCLUDE "hardware.inc"
INCLUDE "ibmpc1.inc"

SECTION "PPU stat handler", ROM0[$0048]
  jp StatInterrupt

SECTION "Globals", WRAM0
CurChar: db
FrameCounter: db
KeyTimer: db
CurButtons: db
NewButtons: db
CursorX: db
CursorY: db
CursorPtr: dw

; Control codes
def CR equ 13
def UP equ 24
def DN equ 25
def RT equ 26
def LT equ 27
def SC equ 32

; Keyboard geometry
def KEYBOARD_TOP   equ SCREEN_HEIGHT_PX - 8 * 4
def PICKER_START_Y equ 16 + KEYBOARD_TOP
def PICKER_END_Y   equ PICKER_START_Y + 4 * 8
def PICKER_START_X equ 7
def PICKER_END_X   equ PICKER_START_X + 8 * SCREEN_WIDTH

; Key repeat params
def KEY_REPEAT_RESET equ $10  ; frames before first repeat
def KEY_REPEAT_RATE  equ $4   ; frames between repeats

; Use up to 31 columns and scroll when we hit the last column, so that we don"t
; wrap around and show the first character offscreen to the right.
def MAX_COLUMN    equ TILEMAP_WIDTH - 1
def SCROLL_COLUMN equ SCREEN_WIDTH - 1
def SCROLL_ROW    equ SCREEN_HEIGHT - 5

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
  ld [CursorX], a
  ld [KeyTimer], a
  ld a, 1
  ld [CursorY], a
  ld a, SC
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

  ; Enable interrupts
  ld a, IE_STAT
  ld [rIE], a
  ei

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
  ld a, SC
  ld [CurChar], a
.left
  call CursorBack
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
  cp a, CR          ; newline
  jr z, .newline
  cp a, DN
  jr z, .down
  cp a, UP
  jr z, .up
  cp a, RT
  jr z, .right
  cp a, LT
  jr z, .left
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

CursorBack:
  ld a, [CursorX]
  cp a, 0
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
  cp a, 0
  jr z, UpDownStoreY
  dec a
  jr UpDownStoreY

NewLine:
  ld a, 0
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
  ld a, [CurChar]
  ld b, a
  call PutChar
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
  ld a, 0
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

; Raster interrupt to toggle keyboard bg
StatInterrupt:
  push af
  ld a, [rSTAT]
  and a, STAT_LYCF
  jr z, .reset_pal  ; if vblank, just reset palette
  ; else ly is one above keyboard, wait til end of visible line
  ld a, 9
.delay:
  dec a
  jr nz, .delay
  ; Reset object palette to inverse video to distinguish keyboard vb
  ld a, %10010011
  jr .set_pal
.reset_pal:
  ; Reset normal palette for text editor area
  ld a, %11100100
.set_pal:
  ld [rBGP], a
  pop af
  reti

Message:
  db "\\gbforth 1.0"
.End

OnScreenKeyboard:
  ; Pad rows to 32 bytes to match VRAM tilemap width.
  db "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", " ", "!", "\"", "#",  "$", "%",  "&", "'", "(", ")", "            "
  db "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", " ", "*",  "+", ",",  "-", ".",  "/", ":", ";", "<", "            "
  db "A", "S", "D", "F", "G", "H", "J", "K", "L",  24,  13, "=",  ">", "?",  "@", "[", "\\", "]", "^", "_", "            "
  db "Z", "X", "C", "V", "B", "N", "M",  27,  26,  25, " ", "`", "\{", "|", "\}", "~",  " ", " ", " ", " ", "            "
.End

SECTION "Tile data", ROM0
Font:
  chr_IBMPC1 1, 8 ; Load entire character set
.End
