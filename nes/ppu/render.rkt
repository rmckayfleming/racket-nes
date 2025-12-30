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
 render-sprites!
 render-frame!           ; Combined background + sprites

 ;; Sprite 0 hit detection (for use during PPU tick)
 check-sprite0-hit?      ; Check if sprite 0 hit occurs at given scanline/cycle

 ;; Sprite overflow detection (for use during PPU tick)
 evaluate-sprites-for-scanline  ; Evaluate sprites for scanline, set overflow if >8

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
;; Sprite 0 Hit Detection (per-pixel during PPU tick)
;; ============================================================================

;; Check if sprite 0 hit occurs at the given scanline and x position
;; This is called during PPU tick to detect hit at the correct time
;;
;; Returns #t if sprite 0 and background both have opaque pixels at this position
;;
;; p: PPU state
;; pbus: PPU bus for memory access
;; scanline: current scanline (0-239 visible)
;; x: current X position (0-255 visible, we check 0-254 since x=255 never hits)
;;
;; OPTIMIZATION: Checks are ordered from cheapest to most expensive:
;; 1. Sprite 0 scanline bounds (most common early exit)
;; 2. Sprite 0 X bounds
;; 3. Rendering enabled flags
;; 4. Left-edge clipping
;; 5. Sprite pixel opacity (requires tile decode)
;; 6. Background pixel opacity (requires tile decode)
(define (check-sprite0-hit? p pbus scanline x)
  ;; FAST PATH: Check sprite 0 bounds first (cheapest check, most likely to fail)
  (define oam (ppu-oam p))
  (define sprite0-y (sprite-y oam 0))
  (define sprite0-x (sprite-x oam 0))
  (define sprite-height (if (ppu-ctrl-flag? p CTRL-SPRITE-SIZE) 16 8))
  ;; Actual Y on screen (OAM Y is scanline - 1)
  (define screen-y (+ sprite0-y 1))

  ;; Early exit if sprite 0 is not on this scanline
  (and (>= scanline screen-y)
       (< scanline (+ screen-y sprite-height))
       ;; Early exit if sprite 0 doesn't cover this X
       (>= x sprite0-x)
       (< x (+ sprite0-x 8))

       ;; Now check if rendering is enabled (less common to change)
       (ppu-mask-flag? p MASK-BG-ENABLE)
       (ppu-mask-flag? p MASK-SPRITE-ENABLE)

       ;; Check left-edge clipping (x < 8 and clipping enabled)
       (not (and (< x 8) (not (ppu-mask-flag? p MASK-BG-LEFT))))
       (not (and (< x 8) (not (ppu-mask-flag? p MASK-SPRITE-LEFT))))

       ;; SLOW PATH: We're in the sprite 0 region, now check actual pixels
       (let* ([sprite0-tile (sprite-tile oam 0)]
              [sprite0-attr (sprite-attr oam 0)]
              [ppu-read (λ (addr) (ppu-bus-read pbus addr))]
              ;; Get sprite pixel
              [sprite-row (- scanline screen-y)]
              [sprite-col (- x sprite0-x)]
              [flip-h (sprite-flip-h? sprite0-attr)]
              [flip-v (sprite-flip-v? sprite0-attr)]
              [actual-row (if flip-v (- (- sprite-height 1) sprite-row) sprite-row)]
              [actual-col (if flip-h (- 7 sprite-col) sprite-col)]

              ;; For 8x16, determine pattern base and tile
              [sprite-pattern-base
               (if (= sprite-height 16)
                   (if (bit? sprite0-tile 0) #x1000 #x0000)
                   (if (ppu-ctrl-flag? p CTRL-SPRITE-PATTERN) #x1000 #x0000))]
              [base-tile
               (if (= sprite-height 16)
                   (bitwise-and sprite0-tile #xFE)
                   sprite0-tile)]

              ;; For 8x16, which tile are we in?
              [tile-for-row
               (if (= sprite-height 16)
                   (if (< actual-row 8) base-tile (+ base-tile 1))
                   base-tile)]
              [row-in-tile
               (if (and (= sprite-height 16) (>= actual-row 8))
                   (- actual-row 8)
                   actual-row)]

              ;; Get sprite pixel value
              [sprite-pixels (decode-tile-row tile-for-row row-in-tile
                                              sprite-pattern-base ppu-read)]
              [sprite-pixel (vector-ref sprite-pixels actual-col)])

         ;; Check if sprite pixel is opaque
         (and (not (= sprite-pixel 0))

              ;; Now check background pixel
              ;; Get scroll position from v and x registers
              (let* ([v (ppu-v p)]
                     [fine-x (ppu-x p)]
                     [coarse-x-start (v-coarse-x v)]
                     [coarse-y-start (v-coarse-y v)]
                     [fine-y-start (v-fine-y v)]
                     [nt-select (v-nametable v)]
                     [scroll-x (+ (* coarse-x-start 8) fine-x)]
                     [scroll-y (+ (* coarse-y-start 8) fine-y-start)]

                     ;; Virtual position in nametable space
                     [virt-x (+ x scroll-x)]
                     [virt-y (+ scanline scroll-y)]

                     ;; Which nametable
                     [nt-h (if (>= virt-x 256) 1 0)]
                     [nt-v (if (>= virt-y 240) 1 0)]
                     [nt (bitwise-xor nt-select
                                      (bitwise-ior nt-h (arithmetic-shift nt-v 1)))]
                     [nametable-base (nametable-base-addr nt)]

                     ;; Position within nametable
                     [nt-x (remainder virt-x 256)]
                     [nt-y (remainder virt-y 240)]

                     ;; Tile coordinates
                     [tile-x (quotient nt-x 8)]
                     [tile-y (quotient nt-y 8)]
                     [fine-x-pixel (remainder nt-x 8)]
                     [fine-y-pixel (remainder nt-y 8)]

                     ;; Get tile index from nametable
                     [nt-addr (+ nametable-base (* tile-y TILES-PER-ROW) tile-x)]
                     [tile-index (ppu-read nt-addr)]

                     ;; Get background pattern
                     [bg-pattern-base
                      (if (ppu-ctrl-flag? p CTRL-BG-PATTERN) #x1000 #x0000)]
                     [bg-pixels (decode-tile-row tile-index fine-y-pixel
                                                 bg-pattern-base ppu-read)]
                     [bg-pixel (vector-ref bg-pixels fine-x-pixel)])

                ;; Hit if background pixel is also opaque
                (not (= bg-pixel 0)))))))

;; ============================================================================
;; Sprite Overflow Detection
;; ============================================================================

;; Evaluate sprites for the given scanline and set overflow flag if more than 8
;; sprites are found on this scanline.
;;
;; This implements the famous NES PPU sprite overflow bug. On real hardware:
;; 1. For sprites 0-7, PPU correctly checks if sprite Y falls on scanline
;; 2. After finding 8 sprites, the PPU has a bug where it increments both
;;    the sprite number (n) AND the byte offset within the sprite (m)
;; 3. This causes it to compare incorrect bytes (attributes, X position)
;;    against the scanline, leading to false positives and negatives
;;
;; Reference: https://www.nesdev.org/wiki/PPU_sprite_evaluation
;;
;; p: PPU state
;; scanline: current scanline (0-239)
;;
;; Sets ppu-sprite-overflow? if overflow detected
(define (evaluate-sprites-for-scanline p scanline)
  (define oam (ppu-oam p))
  (define sprite-height (if (ppu-ctrl-flag? p CTRL-SPRITE-SIZE) 16 8))
  (define sprites-found 0)

  ;; Phase 1: Find sprites 0-63, stop after finding 8
  ;; n = sprite number (0-63)
  (let loop-normal ([n 0])
    (when (and (< n NUM-SPRITES) (< sprites-found 8))
      (define sprite-y (bytes-ref oam (* n SPRITE-SIZE)))
      (define screen-y (+ sprite-y 1))  ; OAM Y is scanline - 1
      ;; Check if this sprite is on the current scanline
      (when (and (>= scanline screen-y)
                 (< scanline (+ screen-y sprite-height)))
        (set! sprites-found (+ sprites-found 1)))
      (loop-normal (+ n 1))))

  ;; Phase 2: Buggy overflow detection
  ;; After finding 8 sprites, the hardware bug kicks in:
  ;; - Instead of checking byte 0 (Y), it checks byte m where m increments
  ;; - m starts at 0 but increments on each check, wrapping around 0-3
  ;; This means it compares the wrong sprite bytes against the scanline
  (when (= sprites-found 8)
    ;; Continue scanning with the buggy behavior
    ;; Start from where we left off (next sprite after 8th)
    (let loop-buggy ([n (let scan ([i 0] [count 0])
                          (cond
                            [(>= i NUM-SPRITES) i]
                            [(let* ([sy (bytes-ref oam (* i SPRITE-SIZE))]
                                    [screen-y (+ sy 1)])
                               (and (>= scanline screen-y)
                                    (< scanline (+ screen-y sprite-height))))
                             (if (= count 7) (+ i 1) (scan (+ i 1) (+ count 1)))]
                            [else (scan (+ i 1) count)]))]
                     [m 0])  ; Byte offset within sprite (0-3)
      (when (< n NUM-SPRITES)
        ;; Read the WRONG byte from OAM due to the bug
        ;; Instead of always reading Y (byte 0), read byte m
        (define oam-addr (+ (* n SPRITE-SIZE) m))
        (define oam-value (bytes-ref oam oam-addr))

        ;; Compare this (possibly wrong) value as if it were a Y coordinate
        (define screen-y (+ oam-value 1))
        (cond
          ;; If "match", set overflow and stop
          [(and (>= scanline screen-y)
                (< scanline (+ screen-y sprite-height)))
           (set-ppu-sprite-overflow! p #t)]
          ;; If no match, increment m (the bug!) and continue
          [else
           ;; m cycles through 0,1,2,3,0,1,2,3...
           ;; n only increments when m wraps from 3 to 0
           (if (= m 3)
               (loop-buggy (+ n 1) 0)
               (loop-buggy n (+ m 1)))])))))

;; ============================================================================
;; Pattern Table Decoding
;; ============================================================================

;; Preallocated pixel buffer to avoid allocation in hot path
;; Used by decode-tile-row! for in-place decoding
(define shared-pixel-buffer (make-vector 8 0))

;; Decode one row of a tile from pattern table into provided buffer
;; pixels: vector of 8 elements to fill with 2-bit pixel values (0-3)
;; tile-index: 0-255 tile number
;; row: 0-7 row within tile
;; pattern-base: $0000 or $1000
;; ppu-read: function to read from PPU bus
(define (decode-tile-row! pixels tile-index row pattern-base ppu-read)
  ;; Each tile is 16 bytes: 8 bytes for low plane, 8 bytes for high plane
  ;; Planes are interleaved: low byte, then high byte 8 bytes later
  (define tile-addr (+ pattern-base (* tile-index 16)))
  (define low-byte (ppu-read (+ tile-addr row)))
  (define high-byte (ppu-read (+ tile-addr row 8)))

  ;; Decode 8 pixels from the two planes
  (for ([x (in-range 8)])
    (define bit-pos (- 7 x))  ; MSB is leftmost pixel
    (define low-bit (if (bit? low-byte bit-pos) 1 0))
    (define high-bit (if (bit? high-byte bit-pos) 1 0))
    (vector-set! pixels x (bitwise-ior low-bit (arithmetic-shift high-bit 1)))))

;; Decode one row of a tile from pattern table
;; Returns a vector of 8 2-bit pixel values (0-3)
;; NOTE: This allocates a fresh vector - prefer decode-tile-row! in hot paths
;; tile-index: 0-255 tile number
;; row: 0-7 row within tile
;; pattern-base: $0000 or $1000
;; ppu-read: function to read from PPU bus
(define (decode-tile-row tile-index row pattern-base ppu-read)
  (define pixels (make-vector 8 0))
  (decode-tile-row! pixels tile-index row pattern-base ppu-read)
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
;;            (used for sprite priority)
;;
;; Note: Sprite 0 hit is detected per-cycle in ppu-tick!, not here.
(define (render-sprites! p pbus framebuffer [bg-opaque #f])
  (define ppu-read (λ (addr) (ppu-bus-read pbus addr)))
  (define oam (ppu-oam p))

  ;; Get pattern table address from PPUCTRL (bit 3)
  (define sprite-pattern-base
    (if (ppu-ctrl-flag? p CTRL-SPRITE-PATTERN) #x1000 #x0000))

  ;; Check if 8x16 sprites are enabled (bit 5 of PPUCTRL)
  (define sprite-height
    (if (ppu-ctrl-flag? p CTRL-SPRITE-SIZE) 16 8))

  ;; Preallocate pixel buffer for tile decoding
  (define pixels (make-vector 8 0))

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

        (decode-tile-row! pixels tile-for-row row-in-tile
                          actual-pattern-base ppu-read)

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
                    (bytes-set! framebuffer (+ fb-offset 3) 255)))))))))))

;; ============================================================================
;; Combined Frame Rendering
;; ============================================================================

;; Render a complete frame (background + sprites)
;; p: PPU state
;; pbus: PPU bus for memory access
;; framebuffer: bytes object (256*240*4 bytes, RGBA format)
(define (render-frame! p pbus framebuffer)
  ;; Create a buffer to track background opacity for sprite priority
  (define bg-opaque (make-bytes (* VISIBLE-WIDTH VISIBLE-HEIGHT) 0))

  ;; Render background first, tracking opacity
  (render-background-with-opacity! p pbus framebuffer bg-opaque)

  ;; Render sprites on top
  (render-sprites! p pbus framebuffer bg-opaque))

;; ============================================================================
;; Scroll Register Decoding
;; ============================================================================

;; Extract scroll components from v register
;; v register format: yyy NN YYYYY XXXXX
;;   bits 0-4:   coarse X (tile column, 0-31)
;;   bits 5-9:   coarse Y (tile row, 0-29, wraps at 30)
;;   bits 10-11: nametable select (0-3)
;;   bits 12-14: fine Y (pixel row within tile, 0-7)
(define (v-coarse-x v) (bitwise-and v #x1F))
(define (v-coarse-y v) (bitwise-and (arithmetic-shift v -5) #x1F))
(define (v-nametable v) (bitwise-and (arithmetic-shift v -10) #x03))
(define (v-fine-y v) (bitwise-and (arithmetic-shift v -12) #x07))

;; Get nametable base address from nametable select bits
(define (nametable-base-addr nt-select)
  (+ #x2000 (* nt-select #x400)))

;; Internal: render background while tracking which pixels are opaque
;; Uses per-scanline scroll capture for proper mid-frame scroll changes
;; Optimized: decodes tiles once per 8-pixel span instead of per-pixel
(define (render-background-with-opacity! p pbus framebuffer bg-opaque)
  (define ppu-read (λ (addr) (ppu-bus-read pbus addr)))

  ;; Get pattern table address from PPUCTRL
  (define bg-pattern-base
    (if (ppu-ctrl-flag? p CTRL-BG-PATTERN) #x1000 #x0000))

  ;; Preallocate pixel buffer for tile decoding
  (define pixels (make-vector 8 0))

  ;; Render each scanline using its captured scroll state
  (for ([screen-y (in-range VISIBLE-HEIGHT)])
    ;; Get the scroll state that was captured at the start of this scanline
    (define v (ppu-scanline-scroll p screen-y))
    (define fine-x (ppu-scanline-fine-x p screen-y))
    (define coarse-x-start (v-coarse-x v))
    (define coarse-y-start (v-coarse-y v))
    (define fine-y-start (v-fine-y v))
    (define nt-select (v-nametable v))

    ;; Calculate scroll in pixels for this scanline
    (define scroll-x (+ (* coarse-x-start 8) fine-x))
    (define scroll-y (+ (* coarse-y-start 8) fine-y-start))

    ;; Virtual Y is constant for this scanline
    (define virt-y (+ screen-y scroll-y))
    (define nt-v (if (>= virt-y 240) 1 0))
    (define nt-y (remainder virt-y 240))
    (define tile-y (quotient nt-y 8))
    (define fine-y-pixel (remainder nt-y 8))

    ;; Framebuffer row base offset
    (define row-base (* screen-y VISIBLE-WIDTH))

    ;; Track last decoded tile to avoid re-decoding
    (define last-tile-key #f)  ; (cons nametable-base tile-x)
    (define last-palette-index 0)

    ;; Render each pixel in this scanline
    (for ([screen-x (in-range VISIBLE-WIDTH)])
      ;; Calculate which pixel in the virtual 512x480 nametable space
      (define virt-x (+ screen-x scroll-x))

      ;; Calculate which nametable (0-3) based on position
      (define nt-h (if (>= virt-x 256) 1 0))

      ;; XOR with base nametable select for proper mirroring behavior
      (define nt (bitwise-xor nt-select
                              (bitwise-ior nt-h (arithmetic-shift nt-v 1))))
      (define nametable-base (nametable-base-addr nt))

      ;; Position within nametable (0-255, 0-239)
      (define nt-x (remainder virt-x 256))

      ;; Tile coordinates
      (define tile-x (quotient nt-x 8))
      (define fine-x-pixel (remainder nt-x 8))

      ;; Check if we need to decode a new tile
      (define tile-key (+ (* nametable-base 64) tile-x))
      (unless (equal? last-tile-key tile-key)
        (set! last-tile-key tile-key)
        ;; Get tile index from nametable
        (define nt-addr (+ nametable-base (* tile-y TILES-PER-ROW) tile-x))
        (define tile-index (ppu-read nt-addr))
        ;; Decode tile row into preallocated buffer
        (decode-tile-row! pixels tile-index fine-y-pixel bg-pattern-base ppu-read)
        ;; Get palette for this tile (changes per 2x2 tile region)
        (set! last-palette-index (get-attribute-palette tile-x tile-y nametable-base ppu-read)))

      ;; Get pixel value from cached tile
      (define pixel-value (vector-ref pixels fine-x-pixel))
      (define color-index (get-tile-pixel last-palette-index pixel-value ppu-read))

      ;; Look up actual RGB color
      (define-values (r g b) (nes-palette-ref color-index))

      ;; Calculate framebuffer position
      (define fb-offset (* (+ row-base screen-x) BYTES-PER-PIXEL))
      (define opacity-offset (+ row-base screen-x))

      ;; Track opacity (pixel-value 0 = transparent)
      (bytes-set! bg-opaque opacity-offset (if (= pixel-value 0) 0 1))

      ;; Write RGBA
      (bytes-set! framebuffer fb-offset r)
      (bytes-set! framebuffer (+ fb-offset 1) g)
      (bytes-set! framebuffer (+ fb-offset 2) b)
      (bytes-set! framebuffer (+ fb-offset 3) 255))))

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
    (check-true (sprite-flip-v? #b11000000)))

  (test-case "sprite overflow: fewer than 8 sprites"
    (define p (make-ppu))
    ;; Set up 7 sprites on scanline 50
    (define oam (ppu-oam p))
    (for ([i (in-range 7)])
      (bytes-set! oam (+ (* i SPRITE-SIZE) 0) 49))  ; Y = 49 -> screen Y = 50
    ;; Put remaining sprites off-screen
    (for ([i (in-range 7 NUM-SPRITES)])
      (bytes-set! oam (+ (* i SPRITE-SIZE) 0) 240))

    ;; Enable rendering
    (set-ppu-mask! p #x18)  ; BG + sprites enabled

    ;; Evaluate for scanline 50
    (evaluate-sprites-for-scanline p 50)
    (check-false (ppu-sprite-overflow? p)))

  (test-case "sprite overflow: exactly 8 sprites"
    (define p (make-ppu))
    (define oam (ppu-oam p))
    ;; Set up exactly 8 sprites on scanline 50
    (for ([i (in-range 8)])
      (bytes-set! oam (+ (* i SPRITE-SIZE) 0) 49))
    ;; Put remaining sprites off-screen
    (for ([i (in-range 8 NUM-SPRITES)])
      (bytes-set! oam (+ (* i SPRITE-SIZE) 0) 240))

    (set-ppu-mask! p #x18)
    (evaluate-sprites-for-scanline p 50)
    ;; With exactly 8, no overflow (bug doesn't trigger on 9th sprite)
    (check-false (ppu-sprite-overflow? p)))

  (test-case "sprite overflow: 9+ sprites triggers overflow"
    (define p (make-ppu))
    (define oam (ppu-oam p))
    ;; Set up 9 sprites on scanline 50
    ;; The 9th sprite's Y will be checked correctly (m=0 at start of buggy phase)
    (for ([i (in-range 9)])
      (bytes-set! oam (+ (* i SPRITE-SIZE) 0) 49))
    ;; Put remaining sprites off-screen
    (for ([i (in-range 9 NUM-SPRITES)])
      (bytes-set! oam (+ (* i SPRITE-SIZE) 0) 240))

    (set-ppu-mask! p #x18)
    (evaluate-sprites-for-scanline p 50)
    ;; 9th sprite triggers overflow
    (check-true (ppu-sprite-overflow? p)))

  (test-case "sprite overflow bug: false negative due to m increment"
    ;; Test the hardware bug: after finding 8, m increments
    ;; If the 9th sprite's tile/attr/x bytes don't match, no overflow
    (define p (make-ppu))
    (define oam (ppu-oam p))
    ;; 8 sprites on scanline 50
    (for ([i (in-range 8)])
      (bytes-set! oam (+ (* i SPRITE-SIZE) 0) 49))
    ;; 9th sprite: Y = 49, but tile = 200 (checked with m=0)
    ;; Wait, m=0 still checks Y, so this should still trigger
    ;; Put 9th sprite at Y where it's NOT on scanline
    (bytes-set! oam (+ (* 8 SPRITE-SIZE) 0) 0)  ; Y = 0
    ;; But set its tile byte (byte 1) to look like it's on scanline 50
    ;; When m=1, it reads tile byte as Y
    (bytes-set! oam (+ (* 8 SPRITE-SIZE) 1) 49)
    ;; Put remaining sprites off-screen with no matching bytes
    (for ([i (in-range 9 NUM-SPRITES)])
      (bytes-set! oam (+ (* i SPRITE-SIZE) 0) 240)
      (bytes-set! oam (+ (* i SPRITE-SIZE) 1) 240)
      (bytes-set! oam (+ (* i SPRITE-SIZE) 2) 240)
      (bytes-set! oam (+ (* i SPRITE-SIZE) 3) 240))

    (set-ppu-mask! p #x18)
    (evaluate-sprites-for-scanline p 50)
    ;; The 9th sprite's Y (byte 0) is checked with m=0, doesn't match
    ;; m increments to 1, n stays at 8
    ;; Then sprite 8's tile byte (49) is checked, which DOES match scanline range
    ;; So this should trigger overflow!
    (check-true (ppu-sprite-overflow? p))))  ; False positive due to bug
