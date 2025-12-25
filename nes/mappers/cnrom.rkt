#lang racket/base

;; CNROM Mapper (Mapper 3)
;;
;; A simple CHR switching mapper with no PRG banking:
;; - PRG ROM: 16KB or 32KB, no banking
;;   - 16KB: Mirrored at $8000-$BFFF and $C000-$FFFF
;;   - 32KB: Full range $8000-$FFFF
;; - CHR ROM: Up to 32KB, bank switched in 8KB chunks
;; - No PRG RAM
;;
;; Bank select: Write any value to $8000-$FFFF
;;   Bits 0-1 select the 8KB CHR bank at PPU $0000-$1FFF
;;
;; Games: Gradius, Solomon's Key, Arkanoid, Paperboy, etc.
;;
;; Reference: https://www.nesdev.org/wiki/CNROM

(provide
 make-cnrom-mapper)

(require "mapper.rkt"
         "../../cart/ines.rkt"
         "../../lib/bits.rkt")

;; ============================================================================
;; CNROM Mapper Implementation
;; ============================================================================

(define (make-cnrom-mapper rom)
  (define prg-rom (rom-prg-rom rom))
  (define chr-rom (rom-chr-rom rom))
  (define prg-size (bytes-length prg-rom))
  (define chr-size (bytes-length chr-rom))

  ;; Number of 8KB CHR banks (typically 2-4)
  (define num-chr-banks (quotient chr-size #x2000))
  (define chr-bank-mask (sub1 num-chr-banks))

  ;; PRG mask for mirroring (16KB = $3FFF, 32KB = $7FFF)
  (define prg-mask (sub1 prg-size))

  ;; CHR bank register
  (define chr-bank-box (box 0))

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
      ;; $8000-$FFFF: PRG ROM (mirrored if 16KB)
      [(>= addr #x8000)
       (bytes-ref prg-rom (bitwise-and (- addr #x8000) prg-mask))]

      ;; $4020-$7FFF: Not used by CNROM
      [else #x00]))

  ;; --- CPU Write ($4020-$FFFF) ---
  (define (cpu-write addr val)
    ;; Any write to $8000-$FFFF selects CHR bank
    (when (>= addr #x8000)
      (set-box! chr-bank-box (bitwise-and val chr-bank-mask))))

  ;; --- PPU Read ($0000-$1FFF) ---
  (define (ppu-read addr)
    (define bank (unbox chr-bank-box))
    (define offset (+ (* bank #x2000) (bitwise-and addr #x1FFF)))
    (bytes-ref chr-rom offset))

  ;; --- PPU Write ($0000-$1FFF) ---
  (define (ppu-write addr val)
    ;; CNROM has CHR ROM, not RAM - writes are ignored
    (void))

  ;; --- Mirroring ---
  (define (get-mirroring)
    mirror-mode)

  ;; --- Serialization (for save states) ---
  (define (serialize)
    (bytes (unbox chr-bank-box)))

  (define (deserialize! data)
    (set-box! chr-bank-box (bytes-ref data 0)))

  ;; Create and return the mapper
  (make-mapper
   #:number 3
   #:name "CNROM"
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

  ;; Create a fake iNES ROM for testing CNROM
  (define (make-test-rom-bytes #:prg-banks [prg-banks 2]
                               #:chr-banks [chr-banks 4]
                               #:mirroring [mirror 'vertical])
    ;; iNES header
    (define header (make-bytes 16 0))
    (bytes-set! header 0 (char->integer #\N))
    (bytes-set! header 1 (char->integer #\E))
    (bytes-set! header 2 (char->integer #\S))
    (bytes-set! header 3 #x1A)
    (bytes-set! header 4 prg-banks)  ; PRG ROM in 16KB units
    (bytes-set! header 5 chr-banks)  ; CHR ROM in 8KB units
    ;; Flags 6: mapper low nibble = 3, mirroring
    (bytes-set! header 6 (bitwise-ior #x30 (if (eq? mirror 'vertical) #x01 #x00)))
    (bytes-set! header 7 #x00)       ; Mapper high nibble = 0

    ;; Create PRG ROM with address pattern
    (define prg-size (* prg-banks #x4000))
    (define prg (make-bytes prg-size))
    (for ([i (in-range prg-size)])
      (bytes-set! prg i (u8 i)))

    ;; Create CHR ROM - each bank starts with its bank number
    (define chr-size (* chr-banks #x2000))
    (define chr (make-bytes chr-size))
    (for ([bank (in-range chr-banks)])
      (define offset (* bank #x2000))
      (for ([i (in-range #x2000)])
        (bytes-set! chr (+ offset i) (u8 bank))))

    (bytes-append header prg chr))

  (define (make-test-mapper #:prg-banks [prg-banks 2]
                            #:chr-banks [chr-banks 4])
    (define rom-bytes (make-test-rom-bytes #:prg-banks prg-banks
                                           #:chr-banks chr-banks))
    (define r (parse-rom rom-bytes))
    (make-cnrom-mapper r))

  (test-case "PRG ROM mirroring - 16KB"
    (define m (make-test-mapper #:prg-banks 1))

    ;; 16KB ROM should mirror
    (check-equal? ((mapper-cpu-read m) #x8000)
                  ((mapper-cpu-read m) #xC000)))

  (test-case "PRG ROM no mirroring - 32KB"
    (define m (make-test-mapper #:prg-banks 2))

    ;; 32KB ROM fills full range
    (check-equal? ((mapper-cpu-read m) #x8000) #x00)
    (check-equal? ((mapper-cpu-read m) #xC000) #x00))  ; Pattern repeats

  (test-case "initial CHR bank state"
    (define m (make-test-mapper #:chr-banks 4))

    ;; Bank 0 initially selected
    (check-equal? ((mapper-ppu-read m) #x0000) 0))

  (test-case "CHR bank switching"
    (define m (make-test-mapper #:chr-banks 4))

    ;; Switch to bank 2
    ((mapper-cpu-write m) #x8000 2)
    (check-equal? ((mapper-ppu-read m) #x0000) 2)

    ;; Switch to bank 3
    ((mapper-cpu-write m) #xFFFF 3)
    (check-equal? ((mapper-ppu-read m) #x0000) 3)

    ;; Switch to bank 1
    ((mapper-cpu-write m) #xA000 1)
    (check-equal? ((mapper-ppu-read m) #x0000) 1))

  (test-case "CHR bank masking"
    ;; With 4 banks, only bits 0-1 should matter
    (define m (make-test-mapper #:chr-banks 4))

    ;; Write value larger than bank count
    ((mapper-cpu-write m) #x8000 #xFF)
    ;; Should wrap to bank 3 (4 banks = mask 0x03)
    (check-equal? ((mapper-ppu-read m) #x0000) 3))

  (test-case "CHR ROM is read-only"
    (define m (make-test-mapper #:chr-banks 4))

    ;; Read initial value
    (check-equal? ((mapper-ppu-read m) #x0000) 0)

    ;; Try to write
    ((mapper-ppu-write m) #x0000 #xFF)

    ;; Should be unchanged (ROM is read-only)
    (check-equal? ((mapper-ppu-read m) #x0000) 0))

  (test-case "serialization round-trip"
    (define m (make-test-mapper #:chr-banks 4))

    ;; Set CHR bank
    ((mapper-cpu-write m) #x8000 2)
    (check-equal? ((mapper-ppu-read m) #x0000) 2)

    ;; Serialize
    (define saved ((mapper-serialize m)))

    ;; Change bank
    ((mapper-cpu-write m) #x8000 0)
    (check-equal? ((mapper-ppu-read m) #x0000) 0)

    ;; Deserialize
    ((mapper-deserialize! m) saved)

    ;; Verify restored
    (check-equal? ((mapper-ppu-read m) #x0000) 2)))
