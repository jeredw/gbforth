INCLUDE "hardware.inc"
INCLUDE "ibmpc1.inc"

SECTION "Header", ROM0[$100]
  jp Main
  ds $150 - @, 0  ; Reserve space for the header

Main:
  nop
  di
  ld sp, $cfff
  ei

  ; Turn off audio
  ld a, 0
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

.done
  halt 
  nop
  jr .done

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

Message:
  db "gbforth 1.0"
.End

SECTION "Tile data", ROM0
Font:
  chr_IBMPC1 1, 8 ; Load entire character set
.End