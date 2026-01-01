#lang racket/base

;; UxROM Mapper (Mapper 2)
;;
;; A simple PRG switching mapper with no CHR banking:
;; - PRG ROM: Two 16KB banks
;;   - $8000-$BFFF: Switchable bank (controlled by writes to $8000-$FFFF)
;;   - $C000-$FFFF: Fixed to last bank
;; - CHR: 8KB RAM (UxROM games always use CHR RAM)
;; - No PRG RAM
;;
;; Bank select: Write any value to $8000-$FFFF
;;   Bits 0-3 select the 16KB bank at $8000-$BFFF
;;
;; Games: Mega Man, Castlevania, Contra, Metal Gear, Duck Tales, etc.
;;
;; Reference: https://www.nesdev.org/wiki/UxROM

(provide
 make-uxrom-mapper)

(require "mapper.rkt"
         "../../cart/ines.rkt"
         "../../lib/bits.rkt")

;; ============================================================================
;; UxROM Mapper Implementation
;; ============================================================================

(define (make-uxrom-mapper rom)
  (define prg-rom (rom-prg-rom rom))
  (define prg-size (bytes-length prg-rom))

  ;; Number of 16KB PRG banks
  (define num-banks (quotient prg-size #x4000))
  (define bank-mask (sub1 num-banks))

  ;; Last bank is fixed at $C000-$FFFF
  (define last-bank-offset (* (sub1 num-banks) #x4000))

  ;; CHR RAM (8KB) - UxROM always uses CHR RAM
  (define chr-ram (make-bytes #x2000 0))

  ;; Bank register (selects 16KB bank at $8000-$BFFF)
  (define bank-box (box 0))

  ;; Get mirroring mode from ROM header (fixed, not mapper-controlled)
  (define mirror-mode
    (let ([m (rom-mirroring rom)])
      (if (rom-four-screen? rom)
          mirroring-four-screen
          (case (mirroring-type m)
            [(horizontal) mirroring-horizontal]
            [(vertical) mirroring-vertical]
            [else mirroring-vertical]))))

  ;; --- CPU Read ($4020-$FFFF) ---
  (define (cpu-read addr)
    (cond
      ;; $8000-$BFFF: Switchable PRG bank
      [(and (>= addr #x8000) (<= addr #xBFFF))
       (define bank (unbox bank-box))
       (define offset (+ (* bank #x4000) (- addr #x8000)))
       (bytes-ref prg-rom offset)]

      ;; $C000-$FFFF: Fixed to last bank
      [(>= addr #xC000)
       (define offset (+ last-bank-offset (- addr #xC000)))
       (bytes-ref prg-rom offset)]

      ;; $4020-$7FFF: Not used by UxROM - return open bus
      [else #f]))

  ;; --- CPU Write ($4020-$FFFF) ---
  (define (cpu-write addr val)
    ;; Any write to $8000-$FFFF sets the bank register
    (when (>= addr #x8000)
      ;; Mask to valid bank range (typically bits 0-3, but depends on ROM size)
      (set-box! bank-box (bitwise-and val bank-mask))))

  ;; --- PPU Read ($0000-$1FFF) ---
  (define (ppu-read addr)
    (bytes-ref chr-ram (bitwise-and addr #x1FFF)))

  ;; --- PPU Write ($0000-$1FFF) ---
  (define (ppu-write addr val)
    (bytes-set! chr-ram (bitwise-and addr #x1FFF) val))

  ;; --- Mirroring ---
  (define (get-mirroring)
    mirror-mode)

  ;; --- Serialization (for save states) ---
  (define (serialize)
    (bytes-append
     (bytes (unbox bank-box))
     chr-ram))

  (define (deserialize! data)
    (set-box! bank-box (bytes-ref data 0))
    (bytes-copy! chr-ram 0 data 1 (+ 1 #x2000)))

  ;; Create and return the mapper
  (make-mapper
   #:number 2
   #:name "UxROM"
   #:cpu-read cpu-read
   #:cpu-write cpu-write
   #:ppu-read ppu-read
   #:ppu-write ppu-write
   #:get-mirroring get-mirroring
   #:serialize serialize
   #:deserialize! deserialize!))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit
           "../../lib/bits.rkt")

  ;; Create a fake iNES ROM for testing UxROM
  ;; UxROM typically has 8 or 16 PRG banks (128KB or 256KB)
  (define (make-test-rom-bytes #:prg-banks [prg-banks 8]
                               #:mirroring [mirror 'vertical])
    ;; iNES header
    (define header (make-bytes 16 0))
    (bytes-set! header 0 (char->integer #\N))
    (bytes-set! header 1 (char->integer #\E))
    (bytes-set! header 2 (char->integer #\S))
    (bytes-set! header 3 #x1A)
    (bytes-set! header 4 prg-banks)  ; PRG ROM in 16KB units
    (bytes-set! header 5 0)          ; 0 CHR ROM = CHR RAM
    ;; Flags 6: mapper low nibble = 2, mirroring
    (bytes-set! header 6 (bitwise-ior #x20 (if (eq? mirror 'vertical) #x01 #x00)))
    (bytes-set! header 7 #x00)       ; Mapper high nibble = 0

    ;; Create PRG ROM - each bank has unique pattern
    ;; First byte of each bank = bank number
    (define prg-size (* prg-banks #x4000))
    (define prg (make-bytes prg-size))
    (for ([bank (in-range prg-banks)])
      (define offset (* bank #x4000))
      ;; Fill bank with its number
      (for ([i (in-range #x4000)])
        (bytes-set! prg (+ offset i) (u8 bank))))

    (bytes-append header prg))

  (define (make-test-mapper #:prg-banks [prg-banks 8])
    (define rom-bytes (make-test-rom-bytes #:prg-banks prg-banks))
    (define r (parse-rom rom-bytes))
    (make-uxrom-mapper r))

  (test-case "initial bank state"
    (define m (make-test-mapper #:prg-banks 8))

    ;; Bank 0 at $8000-$BFFF
    (check-equal? ((mapper-cpu-read m) #x8000) 0)

    ;; Last bank (7) at $C000-$FFFF
    (check-equal? ((mapper-cpu-read m) #xC000) 7))

  (test-case "bank switching"
    (define m (make-test-mapper #:prg-banks 8))

    ;; Switch to bank 3
    ((mapper-cpu-write m) #x8000 3)
    (check-equal? ((mapper-cpu-read m) #x8000) 3)

    ;; Last bank should still be fixed
    (check-equal? ((mapper-cpu-read m) #xC000) 7)

    ;; Switch to bank 5
    ((mapper-cpu-write m) #xFFFF 5)  ; Write anywhere in $8000-$FFFF
    (check-equal? ((mapper-cpu-read m) #x8000) 5))

  (test-case "bank masking"
    ;; With 8 banks, only bits 0-2 should matter
    (define m (make-test-mapper #:prg-banks 8))

    ;; Write value larger than bank count
    ((mapper-cpu-write m) #x8000 #xFF)
    ;; Should wrap to bank 7 (8 banks = mask 0x07)
    (check-equal? ((mapper-cpu-read m) #x8000) 7))

  (test-case "CHR RAM read/write"
    (define m (make-test-mapper))

    ;; Initially zero
    (check-equal? ((mapper-ppu-read m) #x0000) 0)

    ;; Write and read back
    ((mapper-ppu-write m) #x0000 #x42)
    (check-equal? ((mapper-ppu-read m) #x0000) #x42)

    ((mapper-ppu-write m) #x1FFF #xAB)
    (check-equal? ((mapper-ppu-read m) #x1FFF) #xAB))

  (test-case "serialization round-trip"
    (define m (make-test-mapper))

    ;; Set some state
    ((mapper-cpu-write m) #x8000 5)
    ((mapper-ppu-write m) #x0000 #x12)
    ((mapper-ppu-write m) #x1000 #x34)

    ;; Serialize
    (define saved ((mapper-serialize m)))

    ;; Change state
    ((mapper-cpu-write m) #x8000 0)
    ((mapper-ppu-write m) #x0000 #x00)

    ;; Verify changed
    (check-equal? ((mapper-cpu-read m) #x8000) 0)

    ;; Deserialize
    ((mapper-deserialize! m) saved)

    ;; Verify restored
    (check-equal? ((mapper-cpu-read m) #x8000) 5)
    (check-equal? ((mapper-ppu-read m) #x0000) #x12)
    (check-equal? ((mapper-ppu-read m) #x1000) #x34)))
