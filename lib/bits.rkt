#lang racket/base

;; Bit Manipulation Utilities
;;
;; Low-level helpers for 8-bit and 16-bit unsigned integer operations,
;; commonly needed for emulating 8-bit processors.

(require racket/contract)

(provide
 ;; Type coercion / wrapping
 u8
 u16
 wrap8
 wrap16

 ;; Byte extraction / combination
 lo
 hi
 merge16

 ;; Bit operations
 bit?
 set-bit
 clear-bit
 update-bit
 mask
 extract

 ;; Signed conversion (for relative branches)
 u8->s8)

;; ============================================================================
;; Type Coercion / Wrapping
;; ============================================================================

;; Coerce to unsigned 8-bit (masks to 0-255)
(define (u8 n)
  (bitwise-and n #xFF))

;; Coerce to unsigned 16-bit (masks to 0-65535)
(define (u16 n)
  (bitwise-and n #xFFFF))

;; Wrap with overflow (same as u8/u16 but semantically for arithmetic)
(define wrap8 u8)
(define wrap16 u16)

;; ============================================================================
;; Byte Extraction / Combination
;; ============================================================================

;; Extract low byte of a 16-bit value
(define (lo n)
  (bitwise-and n #xFF))

;; Extract high byte of a 16-bit value
(define (hi n)
  (bitwise-and (arithmetic-shift n -8) #xFF))

;; Combine low and high bytes into a 16-bit value
(define (merge16 low high)
  (bitwise-ior low (arithmetic-shift high 8)))

;; ============================================================================
;; Bit Operations
;; ============================================================================

;; Test if bit n is set (0-indexed from LSB)
(define (bit? value n)
  (not (zero? (bitwise-and value (arithmetic-shift 1 n)))))

;; Set bit n to 1
(define (set-bit value n)
  (bitwise-ior value (arithmetic-shift 1 n)))

;; Clear bit n to 0
(define (clear-bit value n)
  (bitwise-and value (bitwise-not (arithmetic-shift 1 n))))

;; Update bit n to bool (set if #t, clear if #f)
(define (update-bit value n bool)
  (if bool
      (set-bit value n)
      (clear-bit value n)))

;; Create a mask of n bits (e.g., (mask 3) => #b111 = 7)
(define (mask n)
  (sub1 (arithmetic-shift 1 n)))

;; Extract bits from value: start is LSB position, count is number of bits
;; (extract #b11010110 2 4) => #b0101 (bits 2-5)
(define (extract value start count)
  (bitwise-and (arithmetic-shift value (- start)) (mask count)))

;; ============================================================================
;; Signed Conversion
;; ============================================================================

;; Convert unsigned 8-bit to signed (-128 to 127)
;; Used for relative branch offsets
(define (u8->s8 n)
  (if (>= n 128)
      (- n 256)
      n))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "u8 wrapping"
    (check-equal? (u8 0) 0)
    (check-equal? (u8 255) 255)
    (check-equal? (u8 256) 0)
    (check-equal? (u8 -1) 255)
    (check-equal? (u8 #x1FF) #xFF))

  (test-case "u16 wrapping"
    (check-equal? (u16 0) 0)
    (check-equal? (u16 #xFFFF) #xFFFF)
    (check-equal? (u16 #x10000) 0)
    (check-equal? (u16 -1) #xFFFF))

  (test-case "lo/hi extraction"
    (check-equal? (lo #x1234) #x34)
    (check-equal? (hi #x1234) #x12)
    (check-equal? (lo #xFF) #xFF)
    (check-equal? (hi #xFF) #x00))

  (test-case "merge16"
    (check-equal? (merge16 #x34 #x12) #x1234)
    (check-equal? (merge16 #x00 #x00) #x0000)
    (check-equal? (merge16 #xFF #xFF) #xFFFF))

  (test-case "bit? testing"
    (check-true (bit? #b00000001 0))
    (check-false (bit? #b00000001 1))
    (check-true (bit? #b10000000 7))
    (check-false (bit? #b01111111 7)))

  (test-case "set-bit"
    (check-equal? (set-bit #b00000000 0) #b00000001)
    (check-equal? (set-bit #b00000000 7) #b10000000)
    (check-equal? (set-bit #b11111111 4) #b11111111))

  (test-case "clear-bit"
    (check-equal? (clear-bit #b11111111 0) #b11111110)
    (check-equal? (clear-bit #b11111111 7) #b01111111)
    (check-equal? (clear-bit #b00000000 4) #b00000000))

  (test-case "update-bit"
    (check-equal? (update-bit #b00000000 3 #t) #b00001000)
    (check-equal? (update-bit #b11111111 3 #f) #b11110111))

  (test-case "mask"
    (check-equal? (mask 0) 0)
    (check-equal? (mask 1) 1)
    (check-equal? (mask 4) #b1111)
    (check-equal? (mask 8) #xFF))

  (test-case "extract"
    (check-equal? (extract #b11010110 0 4) #b0110)
    (check-equal? (extract #b11010110 2 4) #b0101)
    (check-equal? (extract #b11010110 4 4) #b1101))

  (test-case "u8->s8 signed conversion"
    (check-equal? (u8->s8 0) 0)
    (check-equal? (u8->s8 127) 127)
    (check-equal? (u8->s8 128) -128)
    (check-equal? (u8->s8 255) -1)
    (check-equal? (u8->s8 #xFE) -2)))
