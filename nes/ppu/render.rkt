#lang racket/base

;; PPU Background Rendering
;;
;; Renders the NES background layer to a framebuffer.
;; This is an initial implementation without scrolling - renders the first
;; nametable (at $2000) as a static 256x240 image.
;;
;; Background structure:
;; - 32x30 tiles (8x8 pixels each) = 256x240 visible area
;; - Pattern table provides 2-bit per pixel tile graphics
;; - Attribute table provides palette selection per 16x16 pixel area
;; - Palette RAM provides final color lookup
;;
;; Reference: https://www.nesdev.org/wiki/PPU_nametables
;;            https://www.nesdev.org/wiki/PPU_pattern_tables
;;            https://www.nesdev.org/wiki/PPU_attribute_tables

(provide
 ;; Main rendering function
 render-background!

 ;; Tile rendering helpers (for debugging/testing)
 decode-tile-row
 get-attribute-palette
 get-tile-pixel)

(require "ppu.rkt"
         "bus.rkt"
         "palette.rkt"
         "timing.rkt"
         "../../lib/bits.rkt")

;; ============================================================================
;; Constants
;; ============================================================================

(define TILES-PER-ROW 32)       ; 32 tiles across
(define TILES-PER-COL 30)       ; 30 tiles down
(define TILE-SIZE 8)            ; 8x8 pixels per tile
(define BYTES-PER-PIXEL 4)      ; RGBA

;; Nametable addresses
(define NAMETABLE-BASE #x2000)
(define ATTRIBUTE-OFFSET #x03C0)  ; Attribute table starts at $23C0 for nametable 0

;; ============================================================================
;; Pattern Table Decoding
;; ============================================================================

;; Decode one row of a tile from pattern table
;; Returns a vector of 8 2-bit pixel values (0-3)
;; tile-index: 0-255 tile number
;; row: 0-7 row within tile
;; pattern-base: $0000 or $1000
;; ppu-read: function to read from PPU bus
(define (decode-tile-row tile-index row pattern-base ppu-read)
  ;; Each tile is 16 bytes: 8 bytes for low plane, 8 bytes for high plane
  ;; Planes are interleaved: low byte, then high byte 8 bytes later
  (define tile-addr (+ pattern-base (* tile-index 16)))
  (define low-byte (ppu-read (+ tile-addr row)))
  (define high-byte (ppu-read (+ tile-addr row 8)))

  ;; Decode 8 pixels from the two planes
  (define pixels (make-vector 8 0))
  (for ([x (in-range 8)])
    (define bit-pos (- 7 x))  ; MSB is leftmost pixel
    (define low-bit (if (bit? low-byte bit-pos) 1 0))
    (define high-bit (if (bit? high-byte bit-pos) 1 0))
    (vector-set! pixels x (bitwise-ior low-bit (arithmetic-shift high-bit 1))))

  pixels)

;; ============================================================================
;; Attribute Table Decoding
;; ============================================================================

;; Get the palette index (0-3) for a tile at (tile-x, tile-y)
;; Attribute table divides screen into 16x16 pixel (2x2 tile) regions
;; Each byte controls 4 such regions (32x32 pixels / 4x4 tiles)
(define (get-attribute-palette tile-x tile-y nametable-base ppu-read)
  ;; Which 32x32 pixel block are we in?
  (define block-x (quotient tile-x 4))
  (define block-y (quotient tile-y 4))

  ;; Attribute table address
  (define attr-addr (+ nametable-base ATTRIBUTE-OFFSET
                       (+ (* block-y 8) block-x)))
  (define attr-byte (ppu-read attr-addr))

  ;; Which quadrant within the 32x32 block?
  ;; 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right
  (define quad-x (quotient (remainder tile-x 4) 2))
  (define quad-y (quotient (remainder tile-y 4) 2))
  (define shift (* (+ quad-x (* quad-y 2)) 2))

  (bitwise-and (arithmetic-shift attr-byte (- shift)) #x03))

;; ============================================================================
;; Pixel Lookup
;; ============================================================================

;; Get the color index from palette RAM for a specific pixel
;; palette-index: 0-3 (from attribute table)
;; pixel-value: 0-3 (from pattern table)
;; ppu-read: function to read from PPU bus
(define (get-tile-pixel palette-index pixel-value ppu-read)
  ;; Pixel value 0 is always transparent/background color
  (if (= pixel-value 0)
      (ppu-read #x3F00)  ; Universal background color
      (ppu-read (+ #x3F00 (* palette-index 4) pixel-value))))

;; ============================================================================
;; Background Rendering
;; ============================================================================

;; Render the background to a framebuffer
;; p: PPU state
;; pbus: PPU bus for memory access
;; framebuffer: bytes object (256*240*4 bytes, RGBA format)
;;
;; This renders the current nametable without scrolling.
(define (render-background! p pbus framebuffer)
  (define ppu-read (λ (addr) (ppu-bus-read pbus addr)))

  ;; Get pattern table address from PPUCTRL
  (define bg-pattern-base
    (if (ppu-ctrl-flag? p CTRL-BG-PATTERN) #x1000 #x0000))

  ;; Use nametable 0 ($2000) for now
  (define nametable-base NAMETABLE-BASE)

  ;; Render each tile
  (for* ([tile-y (in-range TILES-PER-COL)]
         [tile-x (in-range TILES-PER-ROW)])

    ;; Get tile index from nametable
    (define nt-addr (+ nametable-base (* tile-y TILES-PER-ROW) tile-x))
    (define tile-index (ppu-read nt-addr))

    ;; Get palette for this tile
    (define palette-index (get-attribute-palette tile-x tile-y nametable-base ppu-read))

    ;; Render each row of the tile
    (for ([row (in-range TILE-SIZE)])
      (define pixels (decode-tile-row tile-index row bg-pattern-base ppu-read))

      ;; Write each pixel to framebuffer
      (for ([col (in-range TILE-SIZE)])
        (define pixel-value (vector-ref pixels col))
        (define color-index (get-tile-pixel palette-index pixel-value ppu-read))

        ;; Look up actual RGB color
        (define-values (r g b) (nes-palette-ref color-index))

        ;; Calculate framebuffer position
        (define screen-x (+ (* tile-x TILE-SIZE) col))
        (define screen-y (+ (* tile-y TILE-SIZE) row))
        (define fb-offset (* (+ (* screen-y VISIBLE-WIDTH) screen-x) BYTES-PER-PIXEL))

        ;; Write RGBA
        (bytes-set! framebuffer fb-offset r)
        (bytes-set! framebuffer (+ fb-offset 1) g)
        (bytes-set! framebuffer (+ fb-offset 2) b)
        (bytes-set! framebuffer (+ fb-offset 3) 255)))))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "decode-tile-row basic"
    ;; Create a mock ppu-read that returns test pattern
    ;; Tile at index 0: low byte = #b10101010, high byte = #b11001100
    (define (mock-read addr)
      (cond
        [(= addr 0) #b10101010]   ; Row 0, low plane
        [(= addr 8) #b11001100]   ; Row 0, high plane
        [else 0]))

    (define pixels (decode-tile-row 0 0 0 mock-read))

    ;; Expected: combine bits for each pixel (high << 1 | low)
    ;; Bit 7: high=1, low=1 -> 3
    ;; Bit 6: high=1, low=0 -> 2
    ;; Bit 5: high=0, low=1 -> 1
    ;; Bit 4: high=0, low=0 -> 0
    ;; Bit 3: high=1, low=1 -> 3
    ;; Bit 2: high=1, low=0 -> 2
    ;; Bit 1: high=0, low=1 -> 1
    ;; Bit 0: high=0, low=0 -> 0
    (check-equal? (vector-ref pixels 0) 3)
    (check-equal? (vector-ref pixels 1) 2)
    (check-equal? (vector-ref pixels 2) 1)
    (check-equal? (vector-ref pixels 3) 0)
    (check-equal? (vector-ref pixels 4) 3)
    (check-equal? (vector-ref pixels 5) 2)
    (check-equal? (vector-ref pixels 6) 1)
    (check-equal? (vector-ref pixels 7) 0))

  (test-case "attribute table quadrants"
    ;; Attribute byte with different values in each quadrant
    ;; Bits 0-1: top-left = 0
    ;; Bits 2-3: top-right = 1
    ;; Bits 4-5: bottom-left = 2
    ;; Bits 6-7: bottom-right = 3
    (define attr-byte #b11100100)  ; 3, 2, 1, 0

    (define (mock-read addr)
      (if (= addr (+ #x2000 ATTRIBUTE-OFFSET))
          attr-byte
          0))

    ;; Top-left quadrant (tiles 0-1, 0-1)
    (check-equal? (get-attribute-palette 0 0 #x2000 mock-read) 0)
    (check-equal? (get-attribute-palette 1 0 #x2000 mock-read) 0)
    (check-equal? (get-attribute-palette 0 1 #x2000 mock-read) 0)
    (check-equal? (get-attribute-palette 1 1 #x2000 mock-read) 0)

    ;; Top-right quadrant (tiles 2-3, 0-1)
    (check-equal? (get-attribute-palette 2 0 #x2000 mock-read) 1)
    (check-equal? (get-attribute-palette 3 0 #x2000 mock-read) 1)

    ;; Bottom-left quadrant (tiles 0-1, 2-3)
    (check-equal? (get-attribute-palette 0 2 #x2000 mock-read) 2)
    (check-equal? (get-attribute-palette 1 3 #x2000 mock-read) 2)

    ;; Bottom-right quadrant (tiles 2-3, 2-3)
    (check-equal? (get-attribute-palette 2 2 #x2000 mock-read) 3)
    (check-equal? (get-attribute-palette 3 3 #x2000 mock-read) 3)))
