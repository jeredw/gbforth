INCLUDE "hardware.inc"
INCLUDE "ibmpc1.inc"

SECTION "Globals", WRAM0
CurChar: db
FrameCounter: db
CurButtons: db
NewButtons: db
CursorPtr: dw

SECTION "Header", ROM0[$100]
  jp Boot
  ds $150 - @, 0  ; Reserve space for the header

Boot:
  nop
  di
  ; Set up stack at top of WRAM. We will use the hardware stack as the parameter
  ; stack, but will also use it for subroutines during startup.
  ld sp, $DFFF
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
  cp 144
  jr c, .wait_for_vblank
  ; Disable LCD
  ld a, 0
  ld [rLCDC], a

  ; Copy tiles for font into VRAM at $8000
  ld de, Font
  ld hl, $8000
  ld bc, Font.End - Font
  call CopyMemory

  ; Clear tilemap 
  ld hl, TILEMAP0
  ld bc, TILEMAP1 - TILEMAP0
  ld d, 32
  call FillMemory

  ; Print message
  ld de, Message
  ld hl, TILEMAP0
  ld bc, Message.End - Message
  call CopyMemory

  ; Turn on LCD and enable BG with tiles starting from $8000
  ld a, LCDC_ON | LCDC_BG_ON | LCDC_BLOCK01 | LCDC_BG_9800
  ld [rLCDC], a

  ; Initialize bg palette
  ld a, %11100100
  ld [rBGP], a

Main:
  ld a, [rLY]   ; Wait for end of current vblank
  cp 144
  jr nc, Main
.wait_for_vblank:
  ld a, [rLY]   ; Wait for start of next vblank
  cp 144
  jr c, .wait_for_vblank
  ; Now we are at the start of vblank

  call UpdateButtons
  ld a, [NewButtons]
  and a, PAD_RIGHT
  jp nz, .cursor_right
  ld a, [NewButtons]
  and a, PAD_LEFT
  jp nz, .cursor_left
  ld a, [NewButtons]
  and a, PAD_UP
  jr nz, .next_char
  ld a, [NewButtons]
  and a, PAD_DOWN
  jr nz, .prev_char
  jr .draw_cursor
.next_char:
  ld a, [CurChar]
  inc a
  ld [CurChar], a
  jp .draw_cursor
.prev_char:
  ld a, [CurChar]
  dec a
  ld [CurChar], a
  jp .draw_cursor
.cursor_right:
  ld de, 1
  call MoveCursor
  jp .draw_cursor
.cursor_left:
  ld de, -1
  call MoveCursor
  ;jp .draw_cursor
.draw_cursor
  ld b, 219 ; Show cursor on 1/4 of frames
  ld a, [FrameCounter]
  and a, 16
  jr z, .put
  ld a, [CurChar] ; Show char on frames 10-19
  ld b, a
.put
  call PutChar
  ld a, [FrameCounter]
  inc a
  ld [FrameCounter], a
  jr Main

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
  swap a                  ; A7-4 = unpressed directions; A3-0 = 1
  xor a, b                ; A = pressed buttons + directions
  ld b, a                 ; B = pressed buttons + directions

  ; And release the controller
  ld a, JOYP_GET_NONE
  ldh [rJOYP], a

  ; Combine with previous CurButtons to make NewButtons
  ld a, [CurButtons]
  xor a, b                ; A = keys that changed state
  and a, b                ; A = keys that changed to pressed
  ld [NewButtons], a
  ld a, b
  ld [CurButtons], a
  ret

.read_one_nibble
  ldh [rJOYP], a          ; switch the key matrix
  call .delay10           ; burn 10 cycles calling a known ret
  ldh a, [rJOYP]          ; ignore value while waiting for the key matrix to settle
  ldh a, [rJOYP]         
  ldh a, [rJOYP]          ; this read counts
  or a, $F0               ; A7-4 = 1; A3-0 = unpressed keys
.delay10
  ret

Message:
  db "gbforth 1.0"
.End

SECTION "Tile data", ROM0
Font:
  chr_IBMPC1 1, 8 ; Load entire character set
.End