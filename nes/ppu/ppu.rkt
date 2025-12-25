#lang racket/base

;; PPU State
;;
;; Defines the PPU (Picture Processing Unit) state for the NES.
;; The PPU handles all video output and contains its own memory
;; and registers separate from the CPU.
;;
;; Internal state:
;; - v, t: 15-bit VRAM address registers (current/temporary)
;; - x: 3-bit fine X scroll
;; - w: Write toggle (first/second write latch)
;; - Registers: CTRL, MASK, STATUS
;; - OAM: 256 bytes of sprite memory
;; - Palette: 32 bytes of palette RAM
;; - VRAM read buffer (for buffered reads from $2007)
;;
;; Reference: https://www.nesdev.org/wiki/PPU_registers
;;            https://www.nesdev.org/wiki/PPU_scrolling

(provide
 ;; PPU creation
 make-ppu
 ppu?

 ;; Register accessors
 ppu-ctrl ppu-mask ppu-status
 set-ppu-ctrl! set-ppu-mask! set-ppu-status!

 ;; Scroll/address registers (internal)
 ppu-v ppu-t ppu-x ppu-w
 set-ppu-v! set-ppu-t! set-ppu-x! set-ppu-w!

 ;; Memory
 ppu-oam
 ppu-palette
 ppu-read-buffer set-ppu-read-buffer!

 ;; OAM address
 ppu-oam-addr set-ppu-oam-addr!

 ;; Position tracking
 ppu-scanline ppu-cycle ppu-frame
 set-ppu-scanline! set-ppu-cycle! set-ppu-frame!

 ;; Flags
 ppu-odd-frame? set-ppu-odd-frame!
 ppu-nmi-occurred? set-ppu-nmi-occurred!
 ppu-sprite0-hit? set-ppu-sprite0-hit!
 ppu-sprite-overflow? set-ppu-sprite-overflow!

 ;; NMI output
 ppu-nmi-output? set-ppu-nmi-output!

 ;; Per-scanline scroll capture (for rendering)
 ppu-scanline-scroll
 ppu-scanline-fine-x
 ppu-capture-scanline-scroll!

 ;; CTRL register bits
 CTRL-NAMETABLE-X
 CTRL-NAMETABLE-Y
 CTRL-INCREMENT
 CTRL-SPRITE-PATTERN
 CTRL-BG-PATTERN
 CTRL-SPRITE-SIZE
 CTRL-MASTER-SLAVE
 CTRL-NMI-ENABLE

 ;; MASK register bits
 MASK-GREYSCALE
 MASK-BG-LEFT
 MASK-SPRITE-LEFT
 MASK-BG-ENABLE
 MASK-SPRITE-ENABLE
 MASK-EMPHASIZE-RED
 MASK-EMPHASIZE-GREEN
 MASK-EMPHASIZE-BLUE

 ;; STATUS register bits
 STATUS-SPRITE-OVERFLOW
 STATUS-SPRITE0-HIT
 STATUS-VBLANK

 ;; Helpers
 ppu-ctrl-flag?
 ppu-mask-flag?
 ppu-rendering-enabled?
 ppu-vram-increment)

(require "timing.rkt"
         "../../lib/bits.rkt")

;; ============================================================================
;; Register Bit Definitions
;; ============================================================================

;; PPUCTRL ($2000) bits
(define CTRL-NAMETABLE-X    0)  ; Base nametable X (bit 0 of $2000-$2FFF)
(define CTRL-NAMETABLE-Y    1)  ; Base nametable Y (bit 1 of $2000-$2FFF)
(define CTRL-INCREMENT      2)  ; VRAM increment (0: +1, 1: +32)
(define CTRL-SPRITE-PATTERN 3)  ; Sprite pattern table (0: $0000, 1: $1000)
(define CTRL-BG-PATTERN     4)  ; Background pattern table
(define CTRL-SPRITE-SIZE    5)  ; Sprite size (0: 8x8, 1: 8x16)
(define CTRL-MASTER-SLAVE   6)  ; PPU master/slave (not used on NES)
(define CTRL-NMI-ENABLE     7)  ; Generate NMI on VBlank

;; PPUMASK ($2001) bits
(define MASK-GREYSCALE      0)  ; Greyscale mode
(define MASK-BG-LEFT        1)  ; Show background in leftmost 8 pixels
(define MASK-SPRITE-LEFT    2)  ; Show sprites in leftmost 8 pixels
(define MASK-BG-ENABLE      3)  ; Enable background rendering
(define MASK-SPRITE-ENABLE  4)  ; Enable sprite rendering
(define MASK-EMPHASIZE-RED  5)  ; Emphasize red (green on PAL)
(define MASK-EMPHASIZE-GREEN 6) ; Emphasize green (red on PAL)
(define MASK-EMPHASIZE-BLUE 7)  ; Emphasize blue

;; PPUSTATUS ($2002) bits
(define STATUS-SPRITE-OVERFLOW 5)  ; Sprite overflow
(define STATUS-SPRITE0-HIT     6)  ; Sprite 0 hit
(define STATUS-VBLANK          7)  ; VBlank flag

;; ============================================================================
;; PPU Structure
;; ============================================================================

(struct ppu
  (;; Registers (directly accessible)
   ctrl-box           ; PPUCTRL ($2000)
   mask-box           ; PPUMASK ($2001)
   status-box         ; PPUSTATUS ($2002) - only bits 5-7 meaningful

   ;; Internal registers
   v-box              ; Current VRAM address (15 bits)
   t-box              ; Temporary VRAM address (15 bits)
   x-box              ; Fine X scroll (3 bits)
   w-box              ; Write toggle (1 bit)

   ;; OAM
   oam                ; 256 bytes of sprite memory
   oam-addr-box       ; OAM address register

   ;; Palette RAM
   palette            ; 32 bytes of palette RAM

   ;; Read buffer for $2007
   read-buffer-box

   ;; Position tracking
   scanline-box
   cycle-box
   frame-box

   ;; Frame state
   odd-frame-box      ; Odd frame toggle (for skip cycle)

   ;; Status flags (stored separately for easy access)
   nmi-occurred-box   ; VBlank NMI occurred
   sprite0-hit-box    ; Sprite 0 hit this frame
   sprite-overflow-box ; Sprite overflow detected

   ;; NMI output line
   nmi-output-box     ; NMI should be generated

   ;; Per-scanline scroll capture for rendering
   ;; This captures the v register at the start of each visible scanline
   ;; so that the renderer can use the correct scroll position
   scanline-scroll-buffer   ; Vector of 240 v-register values
   scanline-fine-x-buffer)  ; Vector of 240 fine-x values
  #:transparent)

;; ============================================================================
;; PPU Creation
;; ============================================================================

(define (make-ppu)
  (ppu (box 0)                    ; ctrl
       (box 0)                    ; mask
       (box 0)                    ; status
       (box 0)                    ; v
       (box 0)                    ; t
       (box 0)                    ; x
       (box #f)                   ; w (first write)
       (make-bytes 256 0)         ; OAM
       (box 0)                    ; oam-addr
       (make-bytes 32 0)          ; palette
       (box 0)                    ; read buffer
       (box 0)                    ; scanline
       (box 0)                    ; cycle
       (box 0)                    ; frame
       (box #f)                   ; odd frame
       (box #f)                   ; nmi occurred
       (box #f)                   ; sprite 0 hit
       (box #f)                   ; sprite overflow
       (box #f)                   ; nmi output
       (make-vector 240 0)        ; scanline scroll buffer
       (make-vector 240 0)))      ; scanline fine-x buffer

;; ============================================================================
;; Register Accessors
;; ============================================================================

(define (ppu-ctrl p) (unbox (ppu-ctrl-box p)))
(define (ppu-mask p) (unbox (ppu-mask-box p)))
(define (ppu-status p) (unbox (ppu-status-box p)))

(define (set-ppu-ctrl! p v) (set-box! (ppu-ctrl-box p) (u8 v)))
(define (set-ppu-mask! p v) (set-box! (ppu-mask-box p) (u8 v)))
(define (set-ppu-status! p v) (set-box! (ppu-status-box p) (u8 v)))

;; Internal registers
(define (ppu-v p) (unbox (ppu-v-box p)))
(define (ppu-t p) (unbox (ppu-t-box p)))
(define (ppu-x p) (unbox (ppu-x-box p)))
(define (ppu-w p) (unbox (ppu-w-box p)))

(define (set-ppu-v! p v) (set-box! (ppu-v-box p) (bitwise-and v #x7FFF)))
(define (set-ppu-t! p v) (set-box! (ppu-t-box p) (bitwise-and v #x7FFF)))
(define (set-ppu-x! p v) (set-box! (ppu-x-box p) (bitwise-and v #x07)))
(define (set-ppu-w! p v) (set-box! (ppu-w-box p) v))

;; Read buffer
(define (ppu-read-buffer p) (unbox (ppu-read-buffer-box p)))
(define (set-ppu-read-buffer! p v) (set-box! (ppu-read-buffer-box p) (u8 v)))

;; OAM address
(define (ppu-oam-addr p) (unbox (ppu-oam-addr-box p)))
(define (set-ppu-oam-addr! p v) (set-box! (ppu-oam-addr-box p) (u8 v)))

;; Position
(define (ppu-scanline p) (unbox (ppu-scanline-box p)))
(define (ppu-cycle p) (unbox (ppu-cycle-box p)))
(define (ppu-frame p) (unbox (ppu-frame-box p)))

(define (set-ppu-scanline! p v) (set-box! (ppu-scanline-box p) v))
(define (set-ppu-cycle! p v) (set-box! (ppu-cycle-box p) v))
(define (set-ppu-frame! p v) (set-box! (ppu-frame-box p) v))

;; Frame state
(define (ppu-odd-frame? p) (unbox (ppu-odd-frame-box p)))
(define (set-ppu-odd-frame! p v) (set-box! (ppu-odd-frame-box p) v))

;; Status flags
(define (ppu-nmi-occurred? p) (unbox (ppu-nmi-occurred-box p)))
(define (set-ppu-nmi-occurred! p v) (set-box! (ppu-nmi-occurred-box p) v))

(define (ppu-sprite0-hit? p) (unbox (ppu-sprite0-hit-box p)))
(define (set-ppu-sprite0-hit! p v) (set-box! (ppu-sprite0-hit-box p) v))

(define (ppu-sprite-overflow? p) (unbox (ppu-sprite-overflow-box p)))
(define (set-ppu-sprite-overflow! p v) (set-box! (ppu-sprite-overflow-box p) v))

;; NMI output
(define (ppu-nmi-output? p) (unbox (ppu-nmi-output-box p)))
(define (set-ppu-nmi-output! p v) (set-box! (ppu-nmi-output-box p) v))

;; Per-scanline scroll capture
(define (ppu-scanline-scroll p scanline)
  (vector-ref (ppu-scanline-scroll-buffer p) scanline))

(define (ppu-scanline-fine-x p scanline)
  (vector-ref (ppu-scanline-fine-x-buffer p) scanline))

(define (ppu-capture-scanline-scroll! p scanline)
  (when (and (>= scanline 0) (< scanline 240))
    (vector-set! (ppu-scanline-scroll-buffer p) scanline (ppu-v p))
    (vector-set! (ppu-scanline-fine-x-buffer p) scanline (ppu-x p))))

;; ============================================================================
;; Helper Functions
;; ============================================================================

;; Check if a CTRL bit is set
(define (ppu-ctrl-flag? p flag)
  (bit? (ppu-ctrl p) flag))

;; Check if a MASK bit is set
(define (ppu-mask-flag? p flag)
  (bit? (ppu-mask p) flag))

;; Is rendering enabled? (either BG or sprites)
(define (ppu-rendering-enabled? p)
  (or (ppu-mask-flag? p MASK-BG-ENABLE)
      (ppu-mask-flag? p MASK-SPRITE-ENABLE)))

;; Get VRAM address increment (1 or 32)
(define (ppu-vram-increment p)
  (if (ppu-ctrl-flag? p CTRL-INCREMENT) 32 1))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "initial state"
    (define p (make-ppu))
    (check-equal? (ppu-ctrl p) 0)
    (check-equal? (ppu-mask p) 0)
    (check-equal? (ppu-status p) 0)
    (check-equal? (ppu-v p) 0)
    (check-equal? (ppu-t p) 0)
    (check-equal? (ppu-x p) 0)
    (check-false (ppu-w p))
    (check-equal? (ppu-scanline p) 0)
    (check-equal? (ppu-cycle p) 0))

  (test-case "register setters"
    (define p (make-ppu))
    (set-ppu-ctrl! p #x80)
    (check-equal? (ppu-ctrl p) #x80)
    (check-true (ppu-ctrl-flag? p CTRL-NMI-ENABLE))

    (set-ppu-mask! p #x18)
    (check-equal? (ppu-mask p) #x18)
    (check-true (ppu-rendering-enabled? p)))

  (test-case "internal registers wrap correctly"
    (define p (make-ppu))
    (set-ppu-v! p #xFFFF)
    (check-equal? (ppu-v p) #x7FFF)  ; 15-bit

    (set-ppu-x! p #xFF)
    (check-equal? (ppu-x p) #x07))   ; 3-bit

  (test-case "vram increment"
    (define p (make-ppu))
    (check-equal? (ppu-vram-increment p) 1)

    (set-ppu-ctrl! p #x04)  ; Set increment bit
    (check-equal? (ppu-vram-increment p) 32))

  (test-case "OAM and palette memory"
    (define p (make-ppu))
    (check-equal? (bytes-length (ppu-oam p)) 256)
    (check-equal? (bytes-length (ppu-palette p)) 32)))
