#lang racket/base

;; 6502 CPU Core
;;
;; Implements the MOS 6502 CPU (as used in the NES's Ricoh 2A03, which
;; lacks decimal mode). This is a reusable CPU core that can be connected
;; to any bus implementation.
;;
;; Reference: https://www.nesdev.org/wiki/CPU

(provide
 ;; CPU creation
 make-cpu
 cpu?

 ;; Register accessors
 cpu-a cpu-x cpu-y cpu-sp cpu-pc cpu-p
 set-cpu-a! set-cpu-x! set-cpu-y! set-cpu-sp! set-cpu-pc! set-cpu-p!

 ;; Flag accessors (bit positions in P register)
 flag-c flag-z flag-i flag-d flag-b flag-v flag-n
 cpu-flag? set-cpu-flag! clear-cpu-flag!

 ;; Cycle counter
 cpu-cycles
 cpu-add-cycles!

 ;; Interrupt state
 cpu-nmi-pending? cpu-irq-pending?
 set-cpu-nmi-pending! set-cpu-irq-pending!

 ;; Stack operations
 cpu-push8! cpu-pull8!
 cpu-push16! cpu-pull16!

 ;; Flag helpers
 cpu-update-nz!

 ;; Bus access (updates open bus)
 cpu-read cpu-write cpu-read16

 ;; Control
 cpu-reset!
 cpu-step!
 cpu-trigger-nmi!
 cpu-trigger-irq!

 ;; Opcode executor hook (set by opcodes.rkt)
 cpu-execute-opcode)

(require "../bits.rkt"
         "../bus.rkt")

;; ============================================================================
;; Flag Bit Positions
;; ============================================================================

(define flag-c 0)  ; Carry
(define flag-z 1)  ; Zero
(define flag-i 2)  ; Interrupt disable
(define flag-d 3)  ; Decimal mode (not used on NES)
(define flag-b 4)  ; Break (not a real flag, only in pushed P)
(define flag-v 6)  ; Overflow
(define flag-n 7)  ; Negative

;; Bit 5 is always set when P is pushed

;; ============================================================================
;; CPU State
;; ============================================================================

;; The CPU struct holds all registers and state
;; Registers are stored in boxes for mutability
(struct cpu
  (a-box        ; Accumulator (8-bit)
   x-box        ; X index register (8-bit)
   y-box        ; Y index register (8-bit)
   sp-box       ; Stack pointer (8-bit, points into page $01)
   pc-box       ; Program counter (16-bit)
   p-box        ; Processor status flags (8-bit)
   cycles-box   ; Total cycles executed
   nmi-box      ; NMI pending flag
   irq-box      ; IRQ pending flag
   bus          ; Memory bus for read/write
   openbus-box) ; Last value on data bus (for open bus behavior)
  #:transparent)

;; Create a new CPU connected to a bus
(define (make-cpu bus)
  (cpu (box 0)       ; A
       (box 0)       ; X
       (box 0)       ; Y
       (box #xFD)    ; SP (initial value after reset)
       (box 0)       ; PC (set by reset vector)
       (box #x24)    ; P (I flag set, bit 5 set)
       (box 0)       ; cycles
       (box #f)      ; NMI pending
       (box #f)      ; IRQ pending
       bus
       (box 0)))     ; open bus

;; ============================================================================
;; Register Accessors
;; ============================================================================

(define (cpu-a c) (unbox (cpu-a-box c)))
(define (cpu-x c) (unbox (cpu-x-box c)))
(define (cpu-y c) (unbox (cpu-y-box c)))
(define (cpu-sp c) (unbox (cpu-sp-box c)))
(define (cpu-pc c) (unbox (cpu-pc-box c)))
(define (cpu-p c) (unbox (cpu-p-box c)))
(define (cpu-cycles c) (unbox (cpu-cycles-box c)))
(define (cpu-nmi-pending? c) (unbox (cpu-nmi-box c)))
(define (cpu-irq-pending? c) (unbox (cpu-irq-box c)))

(define (set-cpu-a! c v) (set-box! (cpu-a-box c) (u8 v)))
(define (set-cpu-x! c v) (set-box! (cpu-x-box c) (u8 v)))
(define (set-cpu-y! c v) (set-box! (cpu-y-box c) (u8 v)))
(define (set-cpu-sp! c v) (set-box! (cpu-sp-box c) (u8 v)))
(define (set-cpu-pc! c v) (set-box! (cpu-pc-box c) (u16 v)))
(define (set-cpu-p! c v) (set-box! (cpu-p-box c) (u8 v)))

(define (set-cpu-nmi-pending! c v) (set-box! (cpu-nmi-box c) v))
(define (set-cpu-irq-pending! c v) (set-box! (cpu-irq-box c) v))

(define (cpu-add-cycles! c n)
  (set-box! (cpu-cycles-box c) (+ (unbox (cpu-cycles-box c)) n)))

;; ============================================================================
;; Flag Operations
;; ============================================================================

(define (cpu-flag? c flag)
  (bit? (cpu-p c) flag))

(define (set-cpu-flag! c flag)
  (set-cpu-p! c (set-bit (cpu-p c) flag)))

(define (clear-cpu-flag! c flag)
  (set-cpu-p! c (clear-bit (cpu-p c) flag)))

;; Update N and Z flags based on a value
(define (cpu-update-nz! c value)
  (define v (u8 value))
  ;; Zero flag
  (if (zero? v)
      (set-cpu-flag! c flag-z)
      (clear-cpu-flag! c flag-z))
  ;; Negative flag (bit 7)
  (if (bit? v 7)
      (set-cpu-flag! c flag-n)
      (clear-cpu-flag! c flag-n)))

;; ============================================================================
;; Bus Access
;; ============================================================================

;; Read from bus (updates open bus value)
(define (cpu-read c addr)
  (define v (bus-read (cpu-bus c) addr))
  (set-box! (cpu-openbus-box c) v)
  v)

;; Write to bus (updates open bus value)
(define (cpu-write c addr val)
  (define v (u8 val))
  (set-box! (cpu-openbus-box c) v)
  (bus-write (cpu-bus c) addr v))

;; Read 16-bit value (little-endian)
(define (cpu-read16 c addr)
  (merge16 (cpu-read c addr)
           (cpu-read c (u16 (+ addr 1)))))

;; Read 16-bit with page wrap bug (for JMP indirect)
(define (cpu-read16-wrap c addr)
  (define lo-addr addr)
  (define hi-addr (merge16 (u8 (+ (lo addr) 1)) (hi addr)))
  (merge16 (cpu-read c lo-addr)
           (cpu-read c hi-addr)))

;; ============================================================================
;; Stack Operations
;; ============================================================================

(define (cpu-push8! c val)
  (cpu-write c (merge16 (cpu-sp c) #x01) val)
  (set-cpu-sp! c (wrap8 (- (cpu-sp c) 1))))

(define (cpu-pull8! c)
  (set-cpu-sp! c (wrap8 (+ (cpu-sp c) 1)))
  (cpu-read c (merge16 (cpu-sp c) #x01)))

(define (cpu-push16! c val)
  (cpu-push8! c (hi val))
  (cpu-push8! c (lo val)))

(define (cpu-pull16! c)
  (define lo (cpu-pull8! c))
  (define hi (cpu-pull8! c))
  (merge16 lo hi))

;; ============================================================================
;; Fetch Operations
;; ============================================================================

;; Fetch byte at PC and increment PC
(define (cpu-fetch! c)
  (define v (cpu-read c (cpu-pc c)))
  (set-cpu-pc! c (u16 (+ (cpu-pc c) 1)))
  v)

;; Fetch 16-bit at PC and increment PC by 2
(define (cpu-fetch16! c)
  (define lo (cpu-fetch! c))
  (define hi (cpu-fetch! c))
  (merge16 lo hi))

;; ============================================================================
;; Interrupts
;; ============================================================================

(define VECTOR-NMI   #xFFFA)
(define VECTOR-RESET #xFFFC)
(define VECTOR-IRQ   #xFFFE)

;; Trigger an NMI (will be handled on next step)
(define (cpu-trigger-nmi! c)
  (set-cpu-nmi-pending! c #t))

;; Trigger an IRQ (will be handled on next step if I flag clear)
(define (cpu-trigger-irq! c)
  (set-cpu-irq-pending! c #t))

;; Handle an interrupt
(define (cpu-interrupt! c vector set-b?)
  ;; Push PC and P (with B flag set according to type)
  (cpu-push16! c (cpu-pc c))
  (define p-to-push
    (if set-b?
        (set-bit (set-bit (cpu-p c) 5) flag-b)  ; B and bit 5 set
        (set-bit (clear-bit (cpu-p c) flag-b) 5)))  ; B clear, bit 5 set
  (cpu-push8! c p-to-push)
  ;; Set I flag
  (set-cpu-flag! c flag-i)
  ;; Jump to vector
  (set-cpu-pc! c (cpu-read16 c vector))
  ;; Interrupt takes 7 cycles
  (cpu-add-cycles! c 7))

;; ============================================================================
;; Reset
;; ============================================================================

(define (cpu-reset! c)
  ;; Reset registers to initial state
  (set-cpu-a! c 0)
  (set-cpu-x! c 0)
  (set-cpu-y! c 0)
  (set-cpu-sp! c #xFD)
  (set-cpu-p! c #x24)  ; I flag set, bit 5 set
  ;; Load PC from reset vector
  (set-cpu-pc! c (cpu-read16 c VECTOR-RESET))
  ;; Clear pending interrupts
  (set-cpu-nmi-pending! c #f)
  (set-cpu-irq-pending! c #f)
  ;; Reset takes ~7 cycles
  (cpu-add-cycles! c 7))

;; ============================================================================
;; Step (Execute One Instruction)
;; ============================================================================

;; This will be expanded in opcodes.rkt
;; For now, provide a stub that the opcode executor will call into
(define cpu-execute-opcode (make-parameter #f))

(define (cpu-step! c)
  ;; Check for NMI first (highest priority)
  (cond
    [(cpu-nmi-pending? c)
     (set-cpu-nmi-pending! c #f)
     (cpu-interrupt! c VECTOR-NMI #f)]

    ;; Check for IRQ (if I flag is clear)
    [(and (cpu-irq-pending? c) (not (cpu-flag? c flag-i)))
     (set-cpu-irq-pending! c #f)
     (cpu-interrupt! c VECTOR-IRQ #f)]

    ;; Normal instruction execution
    [else
     (define executor (cpu-execute-opcode))
     (unless executor
       (error 'cpu-step! "opcode executor not initialized - require opcodes.rkt"))
     (executor c)]))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

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

  (test-case "initial state"
    (define-values (c ram) (make-test-cpu))
    (check-equal? (cpu-a c) 0)
    (check-equal? (cpu-x c) 0)
    (check-equal? (cpu-y c) 0)
    (check-equal? (cpu-sp c) #xFD)
    (check-equal? (cpu-p c) #x24))

  (test-case "register setters wrap correctly"
    (define-values (c ram) (make-test-cpu))
    (set-cpu-a! c #x1FF)
    (check-equal? (cpu-a c) #xFF)
    (set-cpu-pc! c #x1FFFF)
    (check-equal? (cpu-pc c) #xFFFF))

  (test-case "flag operations"
    (define-values (c ram) (make-test-cpu))
    (set-cpu-p! c 0)
    (set-cpu-flag! c flag-c)
    (check-true (cpu-flag? c flag-c))
    (clear-cpu-flag! c flag-c)
    (check-false (cpu-flag? c flag-c)))

  (test-case "update-nz flags"
    (define-values (c ram) (make-test-cpu))
    (set-cpu-p! c 0)
    (cpu-update-nz! c 0)
    (check-true (cpu-flag? c flag-z))
    (check-false (cpu-flag? c flag-n))

    (cpu-update-nz! c #x80)
    (check-false (cpu-flag? c flag-z))
    (check-true (cpu-flag? c flag-n))

    (cpu-update-nz! c #x01)
    (check-false (cpu-flag? c flag-z))
    (check-false (cpu-flag? c flag-n)))

  (test-case "stack operations"
    (define-values (c ram) (make-test-cpu))
    (set-cpu-sp! c #xFF)
    (cpu-push8! c #x42)
    (check-equal? (cpu-sp c) #xFE)
    (check-equal? (bytes-ref ram #x01FF) #x42)

    (define pulled (cpu-pull8! c))
    (check-equal? pulled #x42)
    (check-equal? (cpu-sp c) #xFF))

  (test-case "stack 16-bit operations"
    (define-values (c ram) (make-test-cpu))
    (set-cpu-sp! c #xFF)
    (cpu-push16! c #x1234)
    (check-equal? (cpu-sp c) #xFD)

    (define pulled (cpu-pull16! c))
    (check-equal? pulled #x1234)
    (check-equal? (cpu-sp c) #xFF))

  (test-case "reset reads reset vector"
    (define-values (c ram) (make-test-cpu))
    ;; Set reset vector
    (bytes-set! ram #xFFFC #x00)
    (bytes-set! ram #xFFFD #xC0)
    (cpu-reset! c)
    (check-equal? (cpu-pc c) #xC000)))
