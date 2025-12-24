#lang racket/base

;; PPU Background and Sprite Rendering
;;
;; Renders the NES background and sprite layers to a framebuffer.
;; This is an initial implementation without scrolling - renders the first
;; nametable (at $2000) as a static 256x240 image, plus all 64 sprites.
;;
;; Background structure:
;; - 32x30 tiles (8x8 pixels each) = 256x240 visible area
;; - Pattern table provides 2-bit per pixel tile graphics
;; - Attribute table provides palette selection per 16x16 pixel area
;; - Palette RAM provides final color lookup
;;
;; Sprite structure (OAM):
;; - 64 sprites, 4 bytes each = 256 bytes
;; - Byte 0: Y position (scanline minus 1)
;; - Byte 1: Tile index
;; - Byte 2: Attributes (palette, priority, flips)
;; - Byte 3: X position
;;
;; Reference: https://www.nesdev.org/wiki/PPU_nametables
;;            https://www.nesdev.org/wiki/PPU_pattern_tables
;;            https://www.nesdev.org/wiki/PPU_attribute_tables
;;            https://www.nesdev.org/wiki/PPU_OAM

(provide
 ;; Main rendering functions
 render-background!
 render-sprites!
 render-frame!           ; Combined background + sprites

 ;; Tile rendering helpers (for debugging/testing)
 decode-tile-row
 get-attribute-palette
 get-tile-pixel

 ;; Sprite helpers
 sprite-y
 sprite-tile
 sprite-attr
 sprite-x
 sprite-palette
 sprite-priority
 sprite-flip-h?
 sprite-flip-v?)

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

;; Sprite constants
(define NUM-SPRITES 64)
(define SPRITE-SIZE 4)           ; 4 bytes per sprite in OAM
(define MAX-SPRITES-PER-LINE 8)  ; Hardware limit

;; Sprite attribute bits
(define SPRITE-ATTR-PALETTE   #b00000011)  ; Bits 0-1: palette (+ 4 for sprite palettes)
(define SPRITE-ATTR-PRIORITY  #b00100000)  ; Bit 5: 0=in front of BG, 1=behind BG
(define SPRITE-ATTR-FLIP-H    #b01000000)  ; Bit 6: flip horizontally
(define SPRITE-ATTR-FLIP-V    #b10000000)  ; Bit 7: flip vertically

;; ============================================================================
;; Sprite OAM Accessors
;; ============================================================================

;; Get sprite data from OAM
;; OAM is 256 bytes, 4 bytes per sprite
(define (sprite-y oam sprite-num)
  (bytes-ref oam (* sprite-num SPRITE-SIZE)))

(define (sprite-tile oam sprite-num)
  (bytes-ref oam (+ (* sprite-num SPRITE-SIZE) 1)))

(define (sprite-attr oam sprite-num)
  (bytes-ref oam (+ (* sprite-num SPRITE-SIZE) 2)))

(define (sprite-x oam sprite-num)
  (bytes-ref oam (+ (* sprite-num SPRITE-SIZE) 3)))

;; Extract attribute fields
(define (sprite-palette attr)
  (bitwise-and attr SPRITE-ATTR-PALETTE))

(define (sprite-priority attr)
  (if (= 0 (bitwise-and attr SPRITE-ATTR-PRIORITY)) 'front 'behind))

(define (sprite-flip-h? attr)
  (not (= 0 (bitwise-and attr SPRITE-ATTR-FLIP-H))))

(define (sprite-flip-v? attr)
  (not (= 0 (bitwise-and attr SPRITE-ATTR-FLIP-V))))

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
;; Sprite Rendering
;; ============================================================================

;; Get sprite pixel color index
;; Uses sprite palettes at $3F10-$3F1F (palette 4-7)
(define (get-sprite-pixel palette-index pixel-value ppu-read)
  ;; Pixel value 0 is transparent for sprites
  (if (= pixel-value 0)
      #f  ; Transparent
      (ppu-read (+ #x3F10 (* palette-index 4) pixel-value))))

;; Render all sprites to framebuffer
;; p: PPU state
;; pbus: PPU bus for memory access
;; framebuffer: bytes object (256*240*4 bytes, RGBA format)
;; bg-opaque: optional bytes object tracking which BG pixels are opaque
;;            (used for sprite priority and sprite 0 hit)
;;
;; Returns: #t if sprite 0 was hit this frame, #f otherwise
(define (render-sprites! p pbus framebuffer [bg-opaque #f])
  (define ppu-read (λ (addr) (ppu-bus-read pbus addr)))
  (define oam (ppu-oam p))

  ;; Get pattern table address from PPUCTRL (bit 3)
  (define sprite-pattern-base
    (if (ppu-ctrl-flag? p CTRL-SPRITE-PATTERN) #x1000 #x0000))

  ;; Check if 8x16 sprites are enabled (bit 5 of PPUCTRL)
  (define sprite-height
    (if (ppu-ctrl-flag? p CTRL-SPRITE-SIZE) 16 8))

  ;; Track sprite 0 hit
  (define sprite0-hit? #f)

  ;; Render sprites in reverse order (sprite 0 has highest priority)
  ;; This means we render 63->0 so sprite 0 ends up on top
  (for ([sprite-num (in-range (- NUM-SPRITES 1) -1 -1)])
    (define y-pos (sprite-y oam sprite-num))
    (define tile-idx (sprite-tile oam sprite-num))
    (define attr (sprite-attr oam sprite-num))
    (define x-pos (sprite-x oam sprite-num))

    ;; Skip sprites that are off-screen (Y >= 239 means hidden)
    (when (< y-pos 239)
      (define palette-idx (sprite-palette attr))
      (define priority (sprite-priority attr))
      (define flip-h (sprite-flip-h? attr))
      (define flip-v (sprite-flip-v? attr))

      ;; Actual Y position on screen (OAM Y is scanline - 1)
      (define screen-y (+ y-pos 1))

      ;; For 8x16 sprites, tile index bit 0 selects pattern table
      ;; and the actual tile is (tile-idx & 0xFE) for top, +1 for bottom
      (define actual-pattern-base
        (if (= sprite-height 16)
            (if (bit? tile-idx 0) #x1000 #x0000)
            sprite-pattern-base))
      (define base-tile
        (if (= sprite-height 16)
            (bitwise-and tile-idx #xFE)
            tile-idx))

      ;; Render each row of the sprite
      (for ([row (in-range sprite-height)])
        (define actual-row (if flip-v (- (- sprite-height 1) row) row))

        ;; For 8x16, determine which tile we're in
        (define-values (tile-for-row row-in-tile)
          (if (= sprite-height 16)
              (if (< actual-row 8)
                  (values base-tile actual-row)
                  (values (+ base-tile 1) (- actual-row 8)))
              (values base-tile actual-row)))

        (define pixels (decode-tile-row tile-for-row row-in-tile
                                        actual-pattern-base ppu-read))

        ;; Calculate screen Y for this row
        (define pixel-y (+ screen-y row))

        ;; Skip if off screen
        (when (and (>= pixel-y 0) (< pixel-y VISIBLE-HEIGHT))
          ;; Render each pixel
          (for ([col (in-range 8)])
            (define actual-col (if flip-h (- 7 col) col))
            (define pixel-value (vector-ref pixels actual-col))

            ;; Skip transparent pixels
            (unless (= pixel-value 0)
              (define pixel-x (+ x-pos col))

              ;; Skip if off screen
              (when (and (>= pixel-x 0) (< pixel-x VISIBLE-WIDTH))
                (define fb-offset (* (+ (* pixel-y VISIBLE-WIDTH) pixel-x)
                                     BYTES-PER-PIXEL))

                ;; Check background opacity for priority
                (define bg-is-opaque
                  (and bg-opaque
                       (= 1 (bytes-ref bg-opaque
                                       (+ (* pixel-y VISIBLE-WIDTH) pixel-x)))))

                ;; Sprite 0 hit detection:
                ;; - Sprite 0 opaque pixel overlaps BG opaque pixel
                ;; - Not at x=255
                ;; - Both BG and sprites enabled (we assume they are for now)
                (when (and (= sprite-num 0)
                           bg-is-opaque
                           (< pixel-x 255))
                  (set! sprite0-hit? #t))

                ;; Draw sprite pixel based on priority
                ;; 'front: sprite draws over BG
                ;; 'behind: sprite only draws where BG is transparent
                (define should-draw?
                  (or (eq? priority 'front)
                      (not bg-is-opaque)))

                (when should-draw?
                  (define color-index
                    (get-sprite-pixel palette-idx pixel-value ppu-read))
                  (when color-index
                    (define-values (r g b) (nes-palette-ref color-index))
                    (bytes-set! framebuffer fb-offset r)
                    (bytes-set! framebuffer (+ fb-offset 1) g)
                    (bytes-set! framebuffer (+ fb-offset 2) b)
                    (bytes-set! framebuffer (+ fb-offset 3) 255))))))))))

  sprite0-hit?)

;; ============================================================================
;; Combined Frame Rendering
;; ============================================================================

;; Render a complete frame (background + sprites)
;; p: PPU state
;; pbus: PPU bus for memory access
;; framebuffer: bytes object (256*240*4 bytes, RGBA format)
;;
;; Returns: #t if sprite 0 was hit this frame
(define (render-frame! p pbus framebuffer)
  ;; Create a buffer to track background opacity for sprite priority
  (define bg-opaque (make-bytes (* VISIBLE-WIDTH VISIBLE-HEIGHT) 0))

  ;; Render background first, tracking opacity
  (render-background-with-opacity! p pbus framebuffer bg-opaque)

  ;; Render sprites on top
  (render-sprites! p pbus framebuffer bg-opaque))

;; Internal: render background while tracking which pixels are opaque
(define (render-background-with-opacity! p pbus framebuffer bg-opaque)
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
        (define opacity-offset (+ (* screen-y VISIBLE-WIDTH) screen-x))

        ;; Track opacity (pixel-value 0 = transparent)
        (bytes-set! bg-opaque opacity-offset (if (= pixel-value 0) 0 1))

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
    (check-equal? (get-attribute-palette 3 3 #x2000 mock-read) 3))

  (test-case "sprite OAM accessors"
    (define oam (make-bytes 256 0))
    ;; Set up sprite 0 at (100, 50) with tile 42 and attributes
    (bytes-set! oam 0 49)   ; Y = 50-1 = 49
    (bytes-set! oam 1 42)   ; Tile = 42
    (bytes-set! oam 2 #b11100001)  ; Flip V, Flip H, Behind, Palette 1
    (bytes-set! oam 3 100)  ; X = 100

    (check-equal? (sprite-y oam 0) 49)
    (check-equal? (sprite-tile oam 0) 42)
    (check-equal? (sprite-attr oam 0) #b11100001)
    (check-equal? (sprite-x oam 0) 100))

  (test-case "sprite attribute parsing"
    ;; Test palette extraction
    (check-equal? (sprite-palette #b00000000) 0)
    (check-equal? (sprite-palette #b00000001) 1)
    (check-equal? (sprite-palette #b00000010) 2)
    (check-equal? (sprite-palette #b00000011) 3)
    (check-equal? (sprite-palette #b11111111) 3)  ; Only bottom 2 bits

    ;; Test priority
    (check-equal? (sprite-priority #b00000000) 'front)
    (check-equal? (sprite-priority #b00100000) 'behind)

    ;; Test flips
    (check-false (sprite-flip-h? #b00000000))
    (check-true (sprite-flip-h? #b01000000))
    (check-false (sprite-flip-v? #b00000000))
    (check-true (sprite-flip-v? #b10000000))
    ;; Both flips
    (check-true (sprite-flip-h? #b11000000))
    (check-true (sprite-flip-v? #b11000000))))
