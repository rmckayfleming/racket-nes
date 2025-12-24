#lang racket/base

;; NROM Mapper (Mapper 0)
;;
;; The simplest NES mapper with no bank switching:
;; - PRG ROM: 16KB or 32KB at $8000-$FFFF
;;   - 16KB ROMs are mirrored at $8000 and $C000
;;   - 32KB ROMs fill the entire space
;; - PRG RAM: Optional 8KB at $6000-$7FFF (Family BASIC, etc.)
;; - CHR: 8KB ROM or RAM at PPU $0000-$1FFF
;;
;; Games: Super Mario Bros., Donkey Kong, Balloon Fight, etc.
;;
;; Reference: https://www.nesdev.org/wiki/NROM

(provide
 make-nrom-mapper)

(require "mapper.rkt"
         "../../cart/ines.rkt"
         "../../lib/bits.rkt")

;; ============================================================================
;; NROM Mapper Implementation
;; ============================================================================

(define (make-nrom-mapper rom)
  (define prg-rom (rom-prg-rom rom))
  (define chr-data (rom-chr-rom rom))
  (define prg-size (bytes-length prg-rom))
  (define chr-size (bytes-length chr-data))

  ;; Determine if we have CHR RAM (no CHR ROM in file)
  (define chr-is-ram? (zero? chr-size))

  ;; CHR RAM/ROM (8KB)
  (define chr
    (if chr-is-ram?
        (make-bytes #x2000 0)  ; 8KB CHR RAM
        chr-data))             ; CHR ROM from file

  ;; PRG RAM (8KB, optional but always allocate for simplicity)
  (define prg-ram (make-bytes #x2000 0))

  ;; Get mirroring mode from ROM header
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
      ;; $6000-$7FFF: PRG RAM
      [(and (>= addr #x6000) (<= addr #x7FFF))
       (bytes-ref prg-ram (- addr #x6000))]

      ;; $8000-$FFFF: PRG ROM
      [(>= addr #x8000)
       ;; For 16KB ROMs, mirror: addr & 0x3FFF
       ;; For 32KB ROMs, use full range: addr & 0x7FFF
       (define mask (if (= prg-size #x4000) #x3FFF #x7FFF))
       (bytes-ref prg-rom (bitwise-and (- addr #x8000) mask))]

      ;; $4020-$5FFF: Expansion ROM (not used by NROM)
      [else #x00]))

  ;; --- CPU Write ($4020-$FFFF) ---
  (define (cpu-write addr val)
    (cond
      ;; $6000-$7FFF: PRG RAM
      [(and (>= addr #x6000) (<= addr #x7FFF))
       (bytes-set! prg-ram (- addr #x6000) val)]

      ;; PRG ROM writes are ignored (no bank switching)
      [else (void)]))

  ;; --- PPU Read ($0000-$1FFF) ---
  (define (ppu-read addr)
    (bytes-ref chr (bitwise-and addr #x1FFF)))

  ;; --- PPU Write ($0000-$1FFF) ---
  (define (ppu-write addr val)
    ;; Only CHR RAM is writable
    (when chr-is-ram?
      (bytes-set! chr (bitwise-and addr #x1FFF) val)))

  ;; --- Mirroring ---
  (define (get-mirroring)
    mirror-mode)

  ;; --- Serialization (for save states) ---
  (define (serialize)
    ;; Save PRG RAM and CHR RAM (if applicable)
    (bytes-append
     prg-ram
     (if chr-is-ram? chr #"")))

  (define (deserialize! data)
    ;; Restore PRG RAM
    (bytes-copy! prg-ram 0 data 0 #x2000)
    ;; Restore CHR RAM if applicable
    (when chr-is-ram?
      (bytes-copy! chr 0 data #x2000 #x4000)))

  ;; Create and return the mapper
  (make-mapper
   #:number 0
   #:name "NROM"
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
           racket/file
           "../../lib/bits.rkt")

  ;; Create a fake iNES ROM file for testing
  (define (make-test-rom-bytes #:prg-size [prg-size #x4000]
                               #:chr-size [chr-size #x2000]
                               #:mirroring [mirror 'vertical])
    ;; iNES header (16 bytes)
    (define header (make-bytes 16 0))
    (bytes-set! header 0 (char->integer #\N))
    (bytes-set! header 1 (char->integer #\E))
    (bytes-set! header 2 (char->integer #\S))
    (bytes-set! header 3 #x1A)
    (bytes-set! header 4 (quotient prg-size #x4000))  ; PRG ROM in 16KB units
    (bytes-set! header 5 (quotient chr-size #x2000))  ; CHR ROM in 8KB units
    ;; Flags 6: mirroring bit
    (bytes-set! header 6 (if (eq? mirror 'vertical) #x01 #x00))

    ;; Create PRG ROM with identifiable pattern (low byte of address)
    (define prg (make-bytes prg-size))
    (for ([i (in-range prg-size)])
      (bytes-set! prg i (u8 i)))

    ;; Create CHR ROM (inverted pattern)
    (define chr (if (> chr-size 0)
                    (let ([c (make-bytes chr-size)])
                      (for ([i (in-range chr-size)])
                        (bytes-set! c i (u8 (bitwise-xor i #xFF))))
                      c)
                    #""))

    ;; Combine into iNES file
    (bytes-append header prg chr))

  ;; Create a mapper from test ROM bytes
  (define (make-test-mapper #:prg-size [prg-size #x4000]
                            #:chr-size [chr-size #x2000]
                            #:mirroring [mirror 'vertical])
    (define rom-bytes (make-test-rom-bytes #:prg-size prg-size
                                           #:chr-size chr-size
                                           #:mirroring mirror))
    (define r (parse-rom rom-bytes))
    (make-nrom-mapper r))

  (test-case "16KB PRG ROM mirroring"
    (define m (make-test-mapper #:prg-size #x4000))

    ;; $8000 and $C000 should read the same (mirrored)
    (check-equal? ((mapper-cpu-read m) #x8000)
                  ((mapper-cpu-read m) #xC000))

    ;; Check pattern at various addresses
    (check-equal? ((mapper-cpu-read m) #x8000) #x00)
    (check-equal? ((mapper-cpu-read m) #x8001) #x01)
    (check-equal? ((mapper-cpu-read m) #x80FF) #xFF)

    ;; Mirror check
    (check-equal? ((mapper-cpu-read m) #xC000) #x00)
    (check-equal? ((mapper-cpu-read m) #xC001) #x01))

  (test-case "32KB PRG ROM no mirroring"
    (define m (make-test-mapper #:prg-size #x8000))

    ;; $8000 and $C000 should be different (no mirroring)
    (check-equal? ((mapper-cpu-read m) #x8000) #x00)
    (check-equal? ((mapper-cpu-read m) #xC000) #x00)  ; But pattern repeats

    ;; Check high addresses
    (check-equal? ((mapper-cpu-read m) #xBFFF) #xFF)  ; End of first 16KB
    (check-equal? ((mapper-cpu-read m) #xFFFF) #xFF)) ; End of second 16KB

  (test-case "PRG RAM read/write"
    (define m (make-test-mapper))

    ;; Write to PRG RAM
    ((mapper-cpu-write m) #x6000 #x42)
    (check-equal? ((mapper-cpu-read m) #x6000) #x42)

    ((mapper-cpu-write m) #x7FFF #xAB)
    (check-equal? ((mapper-cpu-read m) #x7FFF) #xAB))

  (test-case "CHR ROM read-only"
    (define m (make-test-mapper #:chr-size #x2000))

    ;; Read CHR ROM (pattern is i XOR $FF)
    (check-equal? ((mapper-ppu-read m) #x0000) #xFF)
    (check-equal? ((mapper-ppu-read m) #x0001) #xFE)

    ;; Writes should be ignored (CHR ROM)
    ((mapper-ppu-write m) #x0000 #x00)
    (check-equal? ((mapper-ppu-read m) #x0000) #xFF))  ; Unchanged

  (test-case "CHR RAM read/write"
    (define m (make-test-mapper #:chr-size 0))  ; No CHR ROM = CHR RAM

    ;; Initially zero
    (check-equal? ((mapper-ppu-read m) #x0000) #x00)

    ;; Write and read back
    ((mapper-ppu-write m) #x0000 #x42)
    (check-equal? ((mapper-ppu-read m) #x0000) #x42)

    ((mapper-ppu-write m) #x1FFF #xAB)
    (check-equal? ((mapper-ppu-read m) #x1FFF) #xAB))

  (test-case "mirroring modes"
    (define m-h (make-test-mapper #:mirroring 'horizontal))
    (define m-v (make-test-mapper #:mirroring 'vertical))

    (check-equal? ((mapper-get-mirroring m-h)) mirroring-horizontal)
    (check-equal? ((mapper-get-mirroring m-v)) mirroring-vertical))

  (test-case "serialization round-trip"
    (define m (make-test-mapper #:chr-size 0))  ; CHR RAM

    ;; Write some data
    ((mapper-cpu-write m) #x6000 #x12)
    ((mapper-cpu-write m) #x6001 #x34)
    ((mapper-ppu-write m) #x0000 #x56)
    ((mapper-ppu-write m) #x0001 #x78)

    ;; Serialize
    (define saved ((mapper-serialize m)))

    ;; Clear the data
    ((mapper-cpu-write m) #x6000 #x00)
    ((mapper-ppu-write m) #x0000 #x00)

    ;; Deserialize
    ((mapper-deserialize! m) saved)

    ;; Verify restored
    (check-equal? ((mapper-cpu-read m) #x6000) #x12)
    (check-equal? ((mapper-cpu-read m) #x6001) #x34)
    (check-equal? ((mapper-ppu-read m) #x0000) #x56)
    (check-equal? ((mapper-ppu-read m) #x0001) #x78)))
