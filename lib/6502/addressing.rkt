#lang racket/base

;; 6502 Addressing Modes
;;
;; Implements all official 6502 addressing modes. Each mode returns:
;; - The effective address (or value for immediate)
;; - Whether a page boundary was crossed (for cycle penalties)
;;
;; Reference: https://www.nesdev.org/wiki/CPU_addressing_modes

(provide
 ;; Address mode result
 addr-result
 addr-result-addr
 addr-result-crossed?

 ;; Addressing mode functions
 ;; Each takes the CPU and returns an addr-result
 addr-immediate
 addr-zero-page
 addr-zero-page-x
 addr-zero-page-y
 addr-absolute
 addr-absolute-x
 addr-absolute-y
 addr-indirect         ; For JMP only
 addr-indirect-x       ; Indexed indirect (X,ind)
 addr-indirect-y       ; Indirect indexed (ind),Y
 addr-relative)        ; For branches

(require "cpu.rkt"
         "../bits.rkt")

;; ============================================================================
;; Address Result
;; ============================================================================

;; Result of an addressing mode calculation
(struct addr-result (addr crossed?) #:transparent)

;; Check if two addresses are on different pages
(define (page-crossed? addr1 addr2)
  (not (= (hi addr1) (hi addr2))))

;; ============================================================================
;; Addressing Modes
;; ============================================================================

;; Immediate: operand is the byte following the opcode
;; Returns the value directly (not an address)
(define (addr-immediate c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 1)))
  (addr-result (cpu-read c pc) #f))

;; Zero Page: 8-bit address in zero page ($00xx)
(define (addr-zero-page c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 1)))
  (addr-result (cpu-read c pc) #f))

;; Zero Page,X: zero page address + X, wrapping within zero page
(define (addr-zero-page-x c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 1)))
  (define base (cpu-read c pc))
  (addr-result (u8 (+ base (cpu-x c))) #f))

;; Zero Page,Y: zero page address + Y, wrapping within zero page
(define (addr-zero-page-y c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 1)))
  (define base (cpu-read c pc))
  (addr-result (u8 (+ base (cpu-y c))) #f))

;; Absolute: 16-bit address
(define (addr-absolute c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 2)))
  (define lo (cpu-read c pc))
  (define hi (cpu-read c (u16 (+ pc 1))))
  (addr-result (merge16 lo hi) #f))

;; Absolute,X: 16-bit address + X
(define (addr-absolute-x c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 2)))
  (define lo (cpu-read c pc))
  (define hi (cpu-read c (u16 (+ pc 1))))
  (define base (merge16 lo hi))
  (define addr (u16 (+ base (cpu-x c))))
  (addr-result addr (page-crossed? base addr)))

;; Absolute,Y: 16-bit address + Y
(define (addr-absolute-y c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 2)))
  (define lo (cpu-read c pc))
  (define hi (cpu-read c (u16 (+ pc 1))))
  (define base (merge16 lo hi))
  (define addr (u16 (+ base (cpu-y c))))
  (addr-result addr (page-crossed? base addr)))

;; Indirect: 16-bit pointer to 16-bit address (JMP only)
;; Has the famous page-boundary bug: if pointer is $xxFF,
;; high byte is read from $xx00 instead of $xx00+$0100
(define (addr-indirect c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 2)))
  (define ptr-lo (cpu-read c pc))
  (define ptr-hi (cpu-read c (u16 (+ pc 1))))
  (define ptr (merge16 ptr-lo ptr-hi))
  ;; Bug: if low byte is $FF, wrap within page
  (define lo (cpu-read c ptr))
  (define hi-addr (if (= ptr-lo #xFF)
                      (merge16 #x00 ptr-hi)  ; Wrap to start of page
                      (u16 (+ ptr 1))))
  (define hi (cpu-read c hi-addr))
  (addr-result (merge16 lo hi) #f))

;; Indexed Indirect (X,ind): zero-page pointer + X -> 16-bit address
;; The pointer addition wraps within zero page
(define (addr-indirect-x c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 1)))
  (define base (cpu-read c pc))
  (define ptr (u8 (+ base (cpu-x c))))
  ;; Read 16-bit address from zero page (wrapping)
  (define lo (cpu-read c ptr))
  (define hi (cpu-read c (u8 (+ ptr 1))))
  (addr-result (merge16 lo hi) #f))

;; Indirect Indexed (ind),Y: zero-page pointer -> 16-bit address + Y
(define (addr-indirect-y c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 1)))
  (define ptr (cpu-read c pc))
  ;; Read 16-bit address from zero page (wrapping)
  (define lo (cpu-read c ptr))
  (define hi (cpu-read c (u8 (+ ptr 1))))
  (define base (merge16 lo hi))
  (define addr (u16 (+ base (cpu-y c))))
  (addr-result addr (page-crossed? base addr)))

;; Relative: signed 8-bit offset from PC (for branches)
;; Returns the target address, crossed? indicates page cross
(define (addr-relative c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 1)))
  (define offset (u8->s8 (cpu-read c pc)))
  (define new-pc (cpu-pc c))  ; PC after fetching offset
  (define target (u16 (+ new-pc offset)))
  (addr-result target (page-crossed? new-pc target)))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit
           "../bus.rkt")

  ;; Create a test CPU with RAM
  (define (make-test-cpu)
    (define ram (make-bytes #x10000 0))
    (define b (make-bus))
    (bus-add-handler! b
                      #:start #x0000
                      #:end #xFFFF
                      #:read (λ (addr) (bytes-ref ram addr))
                      #:write (λ (addr val) (bytes-set! ram addr val))
                      #:name 'ram)
    (values (make-cpu b) ram))

  (test-case "immediate"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x42)
    (set-cpu-pc! c #x0000)
    (define r (addr-immediate c))
    (check-equal? (addr-result-addr r) #x42)
    (check-equal? (cpu-pc c) #x0001))

  (test-case "zero-page"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x42)
    (set-cpu-pc! c #x0000)
    (define r (addr-zero-page c))
    (check-equal? (addr-result-addr r) #x42)
    (check-equal? (cpu-pc c) #x0001))

  (test-case "zero-page-x wraps"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xFF)
    (set-cpu-pc! c #x0000)
    (set-cpu-x! c #x10)
    (define r (addr-zero-page-x c))
    (check-equal? (addr-result-addr r) #x0F))  ; $FF + $10 = $0F (wrap)

  (test-case "absolute"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x34)
    (bytes-set! ram #x0001 #x12)
    (set-cpu-pc! c #x0000)
    (define r (addr-absolute c))
    (check-equal? (addr-result-addr r) #x1234)
    (check-equal? (cpu-pc c) #x0002))

  (test-case "absolute-x with page cross"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xFF)
    (bytes-set! ram #x0001 #x10)
    (set-cpu-pc! c #x0000)
    (set-cpu-x! c #x10)
    (define r (addr-absolute-x c))
    (check-equal? (addr-result-addr r) #x110F)
    (check-true (addr-result-crossed? r)))

  (test-case "absolute-x no page cross"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x00)
    (bytes-set! ram #x0001 #x10)
    (set-cpu-pc! c #x0000)
    (set-cpu-x! c #x10)
    (define r (addr-absolute-x c))
    (check-equal? (addr-result-addr r) #x1010)
    (check-false (addr-result-crossed? r)))

  (test-case "indirect JMP bug"
    (define-values (c ram) (make-test-cpu))
    ;; Set up JMP ($10FF) - pointer at $10FF
    (bytes-set! ram #x0000 #xFF)
    (bytes-set! ram #x0001 #x10)
    ;; Target address bytes
    (bytes-set! ram #x10FF #x34)  ; Low byte
    (bytes-set! ram #x1000 #x12)  ; High byte (bug: reads from $1000 not $1100)
    (set-cpu-pc! c #x0000)
    (define r (addr-indirect c))
    (check-equal? (addr-result-addr r) #x1234))

  (test-case "indirect-x"
    (define-values (c ram) (make-test-cpu))
    ;; Operand at $0000, X = $04, so pointer at $10
    (bytes-set! ram #x0000 #x0C)
    (bytes-set! ram #x0010 #x34)  ; Low byte
    (bytes-set! ram #x0011 #x12)  ; High byte
    (set-cpu-pc! c #x0000)
    (set-cpu-x! c #x04)
    (define r (addr-indirect-x c))
    (check-equal? (addr-result-addr r) #x1234))

  (test-case "indirect-y with page cross"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x10)  ; Pointer at $10
    (bytes-set! ram #x0010 #xFF)  ; Base address $10FF
    (bytes-set! ram #x0011 #x10)
    (set-cpu-pc! c #x0000)
    (set-cpu-y! c #x10)
    (define r (addr-indirect-y c))
    (check-equal? (addr-result-addr r) #x110F)
    (check-true (addr-result-crossed? r)))

  (test-case "relative forward"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x10)  ; +16
    (set-cpu-pc! c #x0000)
    (define r (addr-relative c))
    (check-equal? (addr-result-addr r) #x0011))  ; $0001 + $10

  (test-case "relative backward"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0100 #xFE)  ; -2
    (set-cpu-pc! c #x0100)
    (define r (addr-relative c))
    (check-equal? (addr-result-addr r) #x00FF)))  ; $0101 + (-2)
