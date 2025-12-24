#lang racket/base

;; Open Bus Behavior
;;
;; On the NES, when reading from an unmapped address or a register that
;; doesn't drive all data lines, the result is often the "last value"
;; that was on the data bus. This module provides helpers to track and
;; use that value.
;;
;; Convention:
;; - CPU reads update the open bus value with whatever is read
;; - CPU writes update the open bus value with the written value
;; - PPU register reads may only drive some bits (documented per register)
;; - Unmapped reads return the open bus value
;;
;; Reference: https://www.nesdev.org/wiki/Open_bus_behavior

(provide
 make-openbus
 openbus?
 openbus-value
 openbus-update!
 openbus-read)

;; ============================================================================
;; Data Structure
;; ============================================================================

;; Simple mutable container for the last bus value
(struct openbus (value-box) #:transparent)

;; Create a new open bus tracker
;; Initial value is typically 0 but some systems may differ
(define (make-openbus [initial-value 0])
  (openbus (box initial-value)))

;; ============================================================================
;; Operations
;; ============================================================================

;; Get the current open bus value
(define (openbus-value ob)
  (unbox (openbus-value-box ob)))

;; Update the open bus value
(define (openbus-update! ob value)
  (set-box! (openbus-value-box ob) (bitwise-and value #xFF)))

;; Read the open bus value (convenience - same as openbus-value)
;; Use this when explicitly modeling an unmapped read
(define (openbus-read ob)
  (unbox (openbus-value-box ob)))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "initial value"
    (define ob (make-openbus))
    (check-equal? (openbus-value ob) 0))

  (test-case "custom initial value"
    (define ob (make-openbus #xFF))
    (check-equal? (openbus-value ob) #xFF))

  (test-case "update and read"
    (define ob (make-openbus))
    (openbus-update! ob #x42)
    (check-equal? (openbus-value ob) #x42)
    (check-equal? (openbus-read ob) #x42))

  (test-case "value is masked to 8 bits"
    (define ob (make-openbus))
    (openbus-update! ob #x1FF)
    (check-equal? (openbus-value ob) #xFF))

  (test-case "multiple updates"
    (define ob (make-openbus))
    (openbus-update! ob #xAA)
    (check-equal? (openbus-value ob) #xAA)
    (openbus-update! ob #x55)
    (check-equal? (openbus-value ob) #x55)))
