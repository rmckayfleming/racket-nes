#lang racket/base

;; PPU Bus
;;
;; Handles the PPU's internal memory bus, which is separate from the CPU bus.
;; The PPU has a 16KB address space with the following layout:
;;
;; $0000-$1FFF: Pattern tables (CHR ROM/RAM, via mapper)
;; $2000-$2FFF: Nametables (with mirroring)
;; $3000-$3EFF: Nametable mirrors
;; $3F00-$3FFF: Palette RAM (32 bytes, with internal mirrors)
;;
;; Reference: https://www.nesdev.org/wiki/PPU_memory_map

(provide
 ;; PPU bus creation and access
 make-ppu-bus
 ppu-bus-read
 ppu-bus-write

 ;; For testing
 ppu-bus-vram
 ppu-bus-palette)

(require "../mappers/mapper.rkt"
         "../../lib/bits.rkt")

;; ============================================================================
;; PPU Bus Structure
;; ============================================================================

;; The PPU bus contains:
;; - vram: 2KB internal VRAM for nametables
;; - palette: 32 bytes of palette RAM
;; - mapper: Reference to mapper for CHR access and mirroring info
(struct ppu-bus
  (vram            ; 2KB internal VRAM
   palette         ; 32 bytes palette RAM
   mapper-box)     ; Box containing mapper (for dynamic updates)
  #:transparent)

;; ============================================================================
;; PPU Bus Creation
;; ============================================================================

(define (make-ppu-bus [m #f])
  (ppu-bus (make-bytes #x800 0)   ; 2KB VRAM
           (make-bytes 32 0)      ; 32 bytes palette
           (box m)))              ; Mapper (can be set later)

;; ============================================================================
;; Nametable Mirroring
;; ============================================================================

;; Convert a nametable address ($2000-$2FFF) to internal VRAM offset
;; based on the current mirroring mode.
;;
;; Nametable layout (conceptual):
;;   +-------+-------+
;;   | $2000 | $2400 |
;;   +-------+-------+
;;   | $2800 | $2C00 |
;;   +-------+-------+
;;
;; With 2KB VRAM, we have 2 physical nametables mapped to 4 logical ones.
(define (mirror-nametable-addr addr mode)
  ;; Get offset within nametable region (0-$FFF)
  (define offset (bitwise-and addr #x0FFF))
  ;; Which logical nametable (0-3)?
  (define table (quotient offset #x400))
  ;; Offset within that nametable (0-$3FF)
  (define table-offset (remainder offset #x400))

  ;; Map to physical nametable based on mirroring
  (define physical-table
    (case mode
      [(horizontal)
       ;; Vertical arrangement: 0,0,1,1
       ;; Top two nametables = VRAM[0], bottom two = VRAM[1]
       (if (< table 2) 0 1)]
      [(vertical)
       ;; Horizontal arrangement: 0,1,0,1
       ;; Left nametables = VRAM[0], right nametables = VRAM[1]
       (bitwise-and table 1)]
      [(single-0)
       ;; All point to first nametable
       0]
      [(single-1)
       ;; All point to second nametable
       1]
      [(four-screen)
       ;; Four separate nametables (requires extra VRAM on cart)
       ;; For now, just use logical table mod 2
       (bitwise-and table 1)]
      [else
       ;; Default to vertical mirroring
       (bitwise-and table 1)]))

  ;; Return offset into 2KB VRAM
  (+ (* physical-table #x400) table-offset))

;; ============================================================================
;; Palette Addressing
;; ============================================================================

;; Palette RAM is 32 bytes but has some quirks:
;; - $3F00-$3F0F: Background palettes
;; - $3F10-$3F1F: Sprite palettes
;; - $3F10, $3F14, $3F18, $3F1C mirror $3F00, $3F04, $3F08, $3F0C
;;   (sprite palette entry 0 mirrors background palette entry 0)
(define (palette-index addr)
  (define idx (bitwise-and addr #x1F))
  ;; Mirror $3F10/$3F14/$3F18/$3F1C to $3F00/$3F04/$3F08/$3F0C
  (if (and (>= idx #x10)
           (zero? (bitwise-and idx #x03)))
      (- idx #x10)
      idx))

;; ============================================================================
;; Bus Read/Write
;; ============================================================================

(define (ppu-bus-read bus addr)
  (define addr14 (bitwise-and addr #x3FFF))  ; 14-bit address space
  (define m (unbox (ppu-bus-mapper-box bus)))

  (cond
    ;; $0000-$1FFF: Pattern tables (CHR ROM/RAM via mapper)
    [(< addr14 #x2000)
     (if m
         ((mapper-ppu-read m) addr14)
         0)]

    ;; $2000-$3EFF: Nametables (with mirroring)
    [(< addr14 #x3F00)
     (define mirroring (if m ((mapper-get-mirroring m)) 'vertical))
     (define vram-offset (mirror-nametable-addr addr14 mirroring))
     (bytes-ref (ppu-bus-vram bus) vram-offset)]

    ;; $3F00-$3FFF: Palette RAM
    [else
     (define idx (palette-index addr14))
     (bytes-ref (ppu-bus-palette bus) idx)]))

(define (ppu-bus-write bus addr val)
  (define addr14 (bitwise-and addr #x3FFF))
  (define m (unbox (ppu-bus-mapper-box bus)))
  (define val8 (u8 val))

  (cond
    ;; $0000-$1FFF: Pattern tables (CHR RAM only)
    [(< addr14 #x2000)
     (when m
       ((mapper-ppu-write m) addr14 val8))]

    ;; $2000-$3EFF: Nametables
    [(< addr14 #x3F00)
     (define mirroring (if m ((mapper-get-mirroring m)) 'vertical))
     (define vram-offset (mirror-nametable-addr addr14 mirroring))
     (bytes-set! (ppu-bus-vram bus) vram-offset val8)]

    ;; $3F00-$3FFF: Palette RAM
    [else
     (define idx (palette-index addr14))
     (bytes-set! (ppu-bus-palette bus) idx val8)]))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "palette mirroring"
    (define bus (make-ppu-bus))

    ;; Write to background palette
    (ppu-bus-write bus #x3F00 #x0F)  ; Universal background
    (ppu-bus-write bus #x3F01 #x15)  ; Palette 0, color 1

    (check-equal? (ppu-bus-read bus #x3F00) #x0F)
    (check-equal? (ppu-bus-read bus #x3F01) #x15)

    ;; $3F10 should mirror $3F00
    (check-equal? (ppu-bus-read bus #x3F10) #x0F)

    ;; Writing to $3F10 should affect $3F00
    (ppu-bus-write bus #x3F10 #x30)
    (check-equal? (ppu-bus-read bus #x3F00) #x30)
    (check-equal? (ppu-bus-read bus #x3F10) #x30))

  (test-case "palette address wrapping"
    (define bus (make-ppu-bus))

    ;; $3F20 should wrap to $3F00
    (ppu-bus-write bus #x3F00 #xAB)
    (check-equal? (ppu-bus-read bus #x3F20) #xAB)

    ;; $3FFF should wrap to $3F1F
    (ppu-bus-write bus #x3F1F #xCD)
    (check-equal? (ppu-bus-read bus #x3FFF) #xCD))

  (test-case "nametable vertical mirroring"
    (define bus (make-ppu-bus))
    ;; No mapper = default vertical mirroring

    ;; Vertical mirroring: $2000 = $2800, $2400 = $2C00
    (ppu-bus-write bus #x2000 #x42)
    (check-equal? (ppu-bus-read bus #x2000) #x42)
    (check-equal? (ppu-bus-read bus #x2800) #x42)  ; Should mirror

    (ppu-bus-write bus #x2400 #x55)
    (check-equal? (ppu-bus-read bus #x2400) #x55)
    (check-equal? (ppu-bus-read bus #x2C00) #x55)) ; Should mirror

  (test-case "nametable address wrapping"
    (define bus (make-ppu-bus))

    ;; $3000-$3EFF mirrors $2000-$2EFF
    (ppu-bus-write bus #x2000 #x99)
    (check-equal? (ppu-bus-read bus #x3000) #x99))

  (test-case "pattern table requires mapper"
    (define bus (make-ppu-bus))

    ;; Without mapper, reads return 0
    (check-equal? (ppu-bus-read bus #x0000) 0)
    (check-equal? (ppu-bus-read bus #x1FFF) 0)))
