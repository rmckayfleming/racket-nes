#lang racket/base

;; CPU Tests
;;
;; Unit tests for the 6502 CPU core and nestest harness.

(require rackunit
         rackunit/text-ui)

;; Forward declarations - uncomment as modules are implemented
;; (require "../lib/6502/cpu.rkt")
;; (require "../lib/6502/opcodes.rkt")
;; (require "../lib/6502/addressing.rkt")

(define cpu-tests
  (test-suite
   "CPU Tests"

   (test-suite
    "Placeholder"
    (test-case "CPU module loads"
      ;; Placeholder until CPU is implemented
      (check-true #t)))))

(module+ test
  (run-tests cpu-tests))

(module+ main
  (run-tests cpu-tests))
