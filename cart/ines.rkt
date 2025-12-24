#lang racket/base

;; iNES / NES 2.0 ROM Parser
;;
;; Parses NES ROM files in iNES and NES 2.0 formats.
;;
;; iNES format (16-byte header):
;;   Bytes 0-3: "NES\x1A" magic
;;   Byte 4: PRG ROM size in 16KB units
;;   Byte 5: CHR ROM size in 8KB units (0 = CHR RAM)
;;   Byte 6: Flags 6 (mapper low, mirroring, battery, trainer)
;;   Byte 7: Flags 7 (mapper high, vs/playchoice, NES 2.0 indicator)
;;   Byte 8: Flags 8 (PRG RAM size in iNES, submapper in NES 2.0)
;;   Byte 9: Flags 9 (TV system in iNES, ROM sizes high in NES 2.0)
;;   Byte 10: Flags 10 (unofficial, PRG RAM in NES 2.0)
;;   Bytes 11-15: Padding (should be zero)
;;
;; Reference: https://www.nesdev.org/wiki/INES
;;            https://www.nesdev.org/wiki/NES_2.0

(provide
 ;; Main parsing
 load-rom
 parse-rom

 ;; ROM accessors
 rom?
 rom-prg-rom
 rom-chr-rom
 rom-chr-ram?
 rom-mapper
 rom-mirroring
 rom-battery?
 rom-four-screen?
 rom-prg-ram-size
 rom-trainer

 ;; Mirroring types
 (struct-out mirroring))

(require racket/file
         "../lib/bits.rkt")

;; ============================================================================
;; Data Structures
;; ============================================================================

;; Mirroring modes
(struct mirroring (type) #:transparent)
(define mirroring-horizontal (mirroring 'horizontal))
(define mirroring-vertical (mirroring 'vertical))
(define mirroring-four-screen (mirroring 'four-screen))

;; Parsed ROM
(struct rom
  (prg-rom          ; bytes: PRG ROM data
   chr-rom          ; bytes: CHR ROM data (may be empty if CHR RAM)
   chr-ram?         ; boolean: true if using CHR RAM instead of ROM
   mapper           ; integer: mapper number
   mirroring        ; mirroring struct
   battery?         ; boolean: has battery-backed RAM
   four-screen?     ; boolean: uses four-screen VRAM
   prg-ram-size     ; integer: PRG RAM size in bytes
   trainer)         ; bytes or #f: 512-byte trainer if present
  #:transparent)

;; ============================================================================
;; Constants
;; ============================================================================

(define INES-MAGIC #"NES\x1a")
(define HEADER-SIZE 16)
(define TRAINER-SIZE 512)
(define PRG-BANK-SIZE (* 16 1024))  ; 16KB
(define CHR-BANK-SIZE (* 8 1024))   ; 8KB

;; ============================================================================
;; Parsing
;; ============================================================================

;; Load and parse a ROM from file path
(define (load-rom path)
  (define data (file->bytes path))
  (parse-rom data path))

;; Parse ROM from bytes
;; path is optional, used for error messages
(define (parse-rom data [path "<bytes>"])
  ;; Check minimum size
  (unless (>= (bytes-length data) HEADER-SIZE)
    (error 'parse-rom "file too small: ~a" path))

  ;; Check magic
  (define magic (subbytes data 0 4))
  (unless (equal? magic INES-MAGIC)
    (error 'parse-rom "invalid iNES magic: ~a" path))

  ;; Parse header
  (define prg-size-units (bytes-ref data 4))
  (define chr-size-units (bytes-ref data 5))
  (define flags6 (bytes-ref data 6))
  (define flags7 (bytes-ref data 7))
  (define flags8 (bytes-ref data 8))
  (define flags9 (bytes-ref data 9))
  (define flags10 (bytes-ref data 10))

  ;; Detect NES 2.0 format
  (define nes2? (= (bitwise-and flags7 #x0C) #x08))

  ;; Parse flags 6
  (define mirror-bit (bit? flags6 0))
  (define battery? (bit? flags6 1))
  (define trainer? (bit? flags6 2))
  (define four-screen? (bit? flags6 3))
  (define mapper-lo (arithmetic-shift flags6 -4))

  ;; Parse flags 7
  (define mapper-hi (bitwise-and flags7 #xF0))

  ;; Compute mapper number
  (define mapper (bitwise-ior mapper-lo mapper-hi))

  ;; Compute sizes
  (define prg-rom-size (* prg-size-units PRG-BANK-SIZE))
  (define chr-rom-size (* chr-size-units CHR-BANK-SIZE))
  (define chr-ram? (zero? chr-size-units))

  ;; PRG RAM size
  ;; In iNES 1.0, byte 8 is PRG RAM size in 8KB units (0 = 8KB for compat)
  ;; In NES 2.0, it's more complex but we'll handle basic case
  (define prg-ram-size
    (if nes2?
        ;; NES 2.0: byte 10 bits 0-3 encode size as 64 << value (0 = none)
        (let ([shift (bitwise-and flags10 #x0F)])
          (if (zero? shift) 0 (arithmetic-shift 64 shift)))
        ;; iNES 1.0: byte 8 in 8KB units, 0 means 8KB for compatibility
        (let ([units (bytes-ref data 8)])
          (if (zero? units) 8192 (* units 8192)))))

  ;; Mirroring
  (define mirroring-mode
    (cond
      [four-screen? mirroring-four-screen]
      [mirror-bit mirroring-vertical]
      [else mirroring-horizontal]))

  ;; Calculate data offsets
  (define trainer-offset HEADER-SIZE)
  (define prg-offset (+ HEADER-SIZE (if trainer? TRAINER-SIZE 0)))
  (define chr-offset (+ prg-offset prg-rom-size))

  ;; Validate file size
  (define expected-size (+ chr-offset chr-rom-size))
  (unless (>= (bytes-length data) expected-size)
    (error 'parse-rom
           "file size mismatch: expected ~a bytes, got ~a (~a)"
           expected-size (bytes-length data) path))

  ;; Extract data
  (define trainer
    (and trainer?
         (subbytes data trainer-offset (+ trainer-offset TRAINER-SIZE))))

  (define prg-rom (subbytes data prg-offset (+ prg-offset prg-rom-size)))
  (define chr-rom
    (if chr-ram?
        #""
        (subbytes data chr-offset (+ chr-offset chr-rom-size))))

  (rom prg-rom
       chr-rom
       chr-ram?
       mapper
       mirroring-mode
       battery?
       four-screen?
       prg-ram-size
       trainer))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  ;; Create a minimal valid iNES header
  (define (make-test-header #:prg-banks [prg-banks 1]
                            #:chr-banks [chr-banks 0]
                            #:flags6 [flags6 0]
                            #:flags7 [flags7 0])
    (bytes-append
     INES-MAGIC
     (bytes prg-banks chr-banks flags6 flags7 0 0 0 0 0 0 0 0)))

  ;; Create a full test ROM
  (define (make-test-rom #:prg-banks [prg-banks 1]
                         #:chr-banks [chr-banks 0]
                         #:flags6 [flags6 0]
                         #:flags7 [flags7 0])
    (bytes-append
     (make-test-header #:prg-banks prg-banks
                       #:chr-banks chr-banks
                       #:flags6 flags6
                       #:flags7 flags7)
     (make-bytes (* prg-banks PRG-BANK-SIZE) #xEA)  ; PRG filled with NOP
     (make-bytes (* chr-banks CHR-BANK-SIZE) #x00))) ; CHR filled with 0

  (test-case "parse minimal ROM (NROM-128 style)"
    (define data (make-test-rom #:prg-banks 1 #:chr-banks 1))
    (define r (parse-rom data))
    (check-equal? (bytes-length (rom-prg-rom r)) PRG-BANK-SIZE)
    (check-equal? (bytes-length (rom-chr-rom r)) CHR-BANK-SIZE)
    (check-false (rom-chr-ram? r))
    (check-equal? (rom-mapper r) 0)
    (check-equal? (rom-mirroring r) mirroring-horizontal)
    (check-false (rom-battery? r))
    (check-false (rom-four-screen? r)))

  (test-case "parse ROM with CHR RAM"
    (define data (make-test-rom #:prg-banks 2 #:chr-banks 0))
    (define r (parse-rom data))
    (check-true (rom-chr-ram? r))
    (check-equal? (bytes-length (rom-chr-rom r)) 0))

  (test-case "parse vertical mirroring"
    (define data (make-test-rom #:flags6 #b00000001))
    (define r (parse-rom data))
    (check-equal? (rom-mirroring r) mirroring-vertical))

  (test-case "parse battery flag"
    (define data (make-test-rom #:flags6 #b00000010))
    (define r (parse-rom data))
    (check-true (rom-battery? r)))

  (test-case "parse four-screen mirroring"
    (define data (make-test-rom #:flags6 #b00001000))
    (define r (parse-rom data))
    (check-true (rom-four-screen? r))
    (check-equal? (rom-mirroring r) mirroring-four-screen))

  (test-case "parse mapper number"
    ;; Mapper 1 (MMC1): low nibble in flags6 = 1, high nibble in flags7 = 0
    (define data1 (make-test-rom #:flags6 #b00010000))
    (check-equal? (rom-mapper (parse-rom data1)) 1)

    ;; Mapper 4 (MMC3): low nibble = 4
    (define data4 (make-test-rom #:flags6 #b01000000))
    (check-equal? (rom-mapper (parse-rom data4)) 4)

    ;; Mapper 66 (GxROM): low = 2, high = 64
    (define data66 (make-test-rom #:flags6 #b00100000 #:flags7 #b01000000))
    (check-equal? (rom-mapper (parse-rom data66)) 66))

  (test-case "reject invalid magic"
    (define bad-data (bytes-append #"BAD\x1a" (make-bytes 12 0)))
    (check-exn exn:fail? (λ () (parse-rom bad-data))))

  (test-case "reject truncated file"
    (define truncated (subbytes (make-test-rom) 0 20))
    (check-exn exn:fail? (λ () (parse-rom truncated)))))
