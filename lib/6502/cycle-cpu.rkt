#lang racket/base

;; 6502 Cycle-Stepped CPU Core
;;
;; Provides cpu-tick! which advances the CPU by exactly one cycle.
;; This enables Mode B (cycle-interleaved) emulation where PPU/APU
;; can observe exact CPU state at each cycle boundary.
;;
;; The approach uses a simple state machine:
;; - Each instruction is broken into cycles
;; - On each tick, we advance the cycle counter and perform one operation
;; - When instruction completes, we start the next one
;;
;; Reference: https://www.nesdev.org/wiki/CPU_cycles

(provide
 ;; CPU creation and core interface (re-export from cpu.rkt)
 make-cpu
 cpu?
 cpu-a cpu-x cpu-y cpu-sp cpu-pc cpu-p
 set-cpu-a! set-cpu-x! set-cpu-y! set-cpu-sp! set-cpu-pc! set-cpu-p!
 flag-c flag-z flag-i flag-d flag-b flag-v flag-n
 cpu-flag? set-cpu-flag! clear-cpu-flag!
 cpu-cycles
 cpu-add-cycles!
 cpu-nmi-pending? cpu-irq-pending?
 set-cpu-nmi-pending! set-cpu-irq-pending!
 cpu-push8! cpu-pull8!
 cpu-push16! cpu-pull16!
 cpu-update-nz!
 cpu-read cpu-write cpu-read16
 cpu-reset!
 cpu-step!
 cpu-trigger-nmi!
 cpu-trigger-irq!

 ;; Cycle-stepped interface
 cpu-tick!
 cpu-instruction-cycle
 cpu-at-instruction-boundary?

 ;; Instruction state for debugging
 cpu-current-opcode
 cpu-instruction-state)

(require "cpu.rkt"
         "opcodes.rkt"
         "../bits.rkt")

;; ============================================================================
;; Cycle-Stepped Execution State
;; ============================================================================

;; We use thread cells to store per-CPU cycle state
;; This maps cpu struct -> instruction state
(define cpu-states (make-weak-hasheq))

;; Instruction state during multi-cycle execution
(struct instr-state
  (opcode           ; Current opcode being executed
   cycle            ; Current cycle within instruction (1-based)
   total-cycles     ; Total cycles this instruction will take
   addr-lo          ; Low byte of address
   addr-hi          ; High byte of address
   pointer          ; Pointer for indirect modes
   data             ; Intermediate data value
   effective-addr   ; Calculated effective address
   page-crossed?)   ; Whether page crossing occurred
  #:mutable
  #:transparent)

(define (make-instr-state)
  (instr-state 0 0 0 0 0 0 0 0 #f))

(define (get-instr-state c)
  (hash-ref! cpu-states c make-instr-state))

(define (reset-instr-state! state opcode total-cycles)
  (set-instr-state-opcode! state opcode)
  (set-instr-state-cycle! state 1)
  (set-instr-state-total-cycles! state total-cycles)
  (set-instr-state-addr-lo! state 0)
  (set-instr-state-addr-hi! state 0)
  (set-instr-state-pointer! state 0)
  (set-instr-state-data! state 0)
  (set-instr-state-effective-addr! state 0)
  (set-instr-state-page-crossed?! state #f))

;; ============================================================================
;; Public Accessors
;; ============================================================================

(define (cpu-instruction-cycle c)
  (instr-state-cycle (get-instr-state c)))

(define (cpu-at-instruction-boundary? c)
  (let ([state (get-instr-state c)])
    (= (instr-state-cycle state) 0)))

(define (cpu-current-opcode c)
  (instr-state-opcode (get-instr-state c)))

(define (cpu-instruction-state c)
  (get-instr-state c))

;; ============================================================================
;; Cycle Tables
;; ============================================================================

;; Base cycle counts by addressing mode/opcode type
;; These are the MINIMUM cycles; page crosses add 1 for reads
(define cycle-counts
  #(;; 0   1   2   3   4   5   6   7   8   9   A   B   C   D   E   F
    7   6   0   8   3   3   5   5   3   2   2   2   4   4   6   6  ; 0x
    2   5   0   8   4   4   6   6   2   4   2   7   4   4   7   7  ; 1x
    6   6   0   8   3   3   5   5   4   2   2   2   4   4   6   6  ; 2x
    2   5   0   8   4   4   6   6   2   4   2   7   4   4   7   7  ; 3x
    6   6   0   8   3   3   5   5   3   2   2   2   3   4   6   6  ; 4x
    2   5   0   8   4   4   6   6   2   4   2   7   4   4   7   7  ; 5x
    6   6   0   8   3   3   5   5   4   2   2   2   5   4   6   6  ; 6x
    2   5   0   8   4   4   6   6   2   4   2   7   4   4   7   7  ; 7x
    2   6   2   6   3   3   3   3   2   2   2   2   4   4   4   4  ; 8x
    2   6   0   6   4   4   4   4   2   5   2   5   5   5   5   5  ; 9x
    2   6   2   6   3   3   3   3   2   2   2   2   4   4   4   4  ; Ax
    2   5   0   5   4   4   4   4   2   4   2   4   4   4   4   4  ; Bx
    2   6   2   8   3   3   5   5   2   2   2   2   4   4   6   6  ; Cx
    2   5   0   8   4   4   6   6   2   4   2   7   4   4   7   7  ; Dx
    2   6   2   8   3   3   5   5   2   2   2   2   4   4   6   6  ; Ex
    2   5   0   8   4   4   6   6   2   4   2   7   4   4   7   7  ; Fx
    ))

;; Opcodes that add a cycle on page cross (read instructions with indexed addressing)
(define page-cross-opcodes
  (make-immutable-hasheq
   '((#xBD . #t) (#xB9 . #t) (#xB1 . #t)  ; LDA abs,X / abs,Y / (ind),Y
     (#xBE . #t) (#xBC . #t)              ; LDX abs,Y / LDY abs,X
     (#x7D . #t) (#x79 . #t) (#x71 . #t)  ; ADC
     (#xFD . #t) (#xF9 . #t) (#xF1 . #t)  ; SBC
     (#x3D . #t) (#x39 . #t) (#x31 . #t)  ; AND
     (#x1D . #t) (#x19 . #t) (#x11 . #t)  ; ORA
     (#x5D . #t) (#x59 . #t) (#x51 . #t)  ; EOR
     (#xDD . #t) (#xD9 . #t) (#xD1 . #t)  ; CMP
     (#x1C . #t) (#x3C . #t) (#x5C . #t) (#x7C . #t) (#xDC . #t) (#xFC . #t) ; *NOP abs,X
     (#xBF . #t) (#xB3 . #t)              ; *LAX abs,Y / (ind),Y
     (#xBB . #t)                          ; *LAS abs,Y
     )))

;; ============================================================================
;; Cycle-Stepped Tick
;; ============================================================================

;; Advance CPU by exactly one cycle
;; Returns #t if an instruction just completed
(define (cpu-tick! c)
  (define state (get-instr-state c))
  (define cycle (instr-state-cycle state))

  ;; If cycle is 0, this tick is the opcode fetch (cycle 1 of instruction)
  (if (= cycle 0)
      ;; Cycle 1: Fetch opcode
      (begin
        ;; Check for interrupts first
        (cond
          [(cpu-nmi-pending? c)
           (set-cpu-nmi-pending! c #f)
           ;; Set up for NMI sequence (7 cycles)
           (reset-instr-state! state #x00 7)
           (set-instr-state-data! state 'nmi)]

          [(and (cpu-irq-pending? c) (not (cpu-flag? c flag-i)))
           (set-cpu-irq-pending! c #f)
           (reset-instr-state! state #x00 7)
           (set-instr-state-data! state 'irq)]

          [else
           ;; Fetch opcode and start instruction
           (let* ([pc (cpu-pc c)]
                  [opcode (cpu-read c pc)])
             (set-cpu-pc! c (u16 (+ pc 1)))
             (reset-instr-state! state opcode (vector-ref cycle-counts opcode)))])
        ;; First cycle done
        (cpu-add-cycles! c 1)
        ;; Check if 1-cycle instruction (shouldn't exist, but handle it)
        (if (>= 1 (instr-state-total-cycles state))
            (begin (set-instr-state-cycle! state 0) #t)
            #f))

      ;; Cycles 2+: Execute instruction microcode
      (let ([opcode (instr-state-opcode state)])
        (cond
          ;; Handle interrupt sequence specially
          [(eq? (instr-state-data state) 'nmi)
           (execute-interrupt-cycle! c state cycle #xFFFA)]
          [(eq? (instr-state-data state) 'irq)
           (execute-interrupt-cycle! c state cycle #xFFFE)]
          [else
           ;; Normal instruction execution
           (execute-instruction-cycle! c state opcode cycle)])

        ;; Advance cycle counter
        (set-instr-state-cycle! state (+ cycle 1))
        (cpu-add-cycles! c 1)

        ;; Check if instruction is complete
        (if (>= (instr-state-cycle state) (instr-state-total-cycles state))
            (begin (set-instr-state-cycle! state 0) #t)
            #f))))

;; ============================================================================
;; Interrupt Cycle Execution
;; ============================================================================

(define (execute-interrupt-cycle! c state cycle vector)
  (case cycle
    [(1) ; Internal operation
     (void)]
    [(2) ; Push PC high
     (cpu-push8! c (hi (cpu-pc c)))]
    [(3) ; Push PC low
     (cpu-push8! c (lo (cpu-pc c)))]
    [(4) ; Push P (B flag clear for interrupts)
     (cpu-push8! c (set-bit (clear-bit (cpu-p c) flag-b) 5))]
    [(5) ; Fetch vector low
     (set-instr-state-addr-lo! state (cpu-read c vector))]
    [(6) ; Fetch vector high
     (set-instr-state-addr-hi! state (cpu-read c (+ vector 1)))]
    [(7) ; Set PC to vector, set I flag
     (set-cpu-pc! c (merge16 (instr-state-addr-lo state)
                             (instr-state-addr-hi state)))
     (set-cpu-flag! c flag-i)]))

;; ============================================================================
;; Instruction Cycle Execution
;; ============================================================================

;; The main dispatcher for instruction cycles
;; Rather than a huge case statement, we use the instruction pattern
(define (execute-instruction-cycle! c state opcode cycle)
  ;; Determine instruction pattern from opcode
  (define pattern (get-instruction-pattern opcode))
  (case pattern
    [(implied)     (execute-implied! c state opcode cycle)]
    [(accumulator) (execute-accumulator! c state opcode cycle)]
    [(immediate)   (execute-immediate! c state opcode cycle)]
    [(zeropage)    (execute-zeropage! c state opcode cycle)]
    [(zeropage-x)  (execute-zeropage-x! c state opcode cycle)]
    [(zeropage-y)  (execute-zeropage-y! c state opcode cycle)]
    [(absolute)    (execute-absolute! c state opcode cycle)]
    [(absolute-x)  (execute-absolute-x! c state opcode cycle)]
    [(absolute-y)  (execute-absolute-y! c state opcode cycle)]
    [(indirect-x)  (execute-indirect-x! c state opcode cycle)]
    [(indirect-y)  (execute-indirect-y! c state opcode cycle)]
    [(relative)    (execute-relative! c state opcode cycle)]
    [(push)        (execute-push! c state opcode cycle)]
    [(pull)        (execute-pull! c state opcode cycle)]
    [(jsr)         (execute-jsr! c state cycle)]
    [(rts)         (execute-rts! c state cycle)]
    [(rti)         (execute-rti! c state cycle)]
    [(brk)         (execute-brk! c state cycle)]
    [(jmp-abs)     (execute-jmp-abs! c state cycle)]
    [(jmp-ind)     (execute-jmp-ind! c state cycle)]
    [(rmw-zp)      (execute-rmw-zp! c state opcode cycle)]
    [(rmw-zpx)     (execute-rmw-zpx! c state opcode cycle)]
    [(rmw-abs)     (execute-rmw-abs! c state opcode cycle)]
    [(rmw-absx)    (execute-rmw-absx! c state opcode cycle)]
    [else
     (error 'cpu-tick! "unhandled opcode pattern: ~a for opcode $~a"
            pattern
            (~r opcode #:base 16 #:min-width 2 #:pad-string "0"))]))

;; Get the addressing pattern for an opcode
(define (get-instruction-pattern opcode)
  (case opcode
    ;; Implied instructions
    [(#x1A #x3A #x5A #x7A #xDA #xFA  ; *NOP implied
      #xEA                            ; NOP
      #xAA #xA8 #x8A #x98 #xBA #x9A   ; Transfers
      #xE8 #xC8 #xCA #x88             ; INC/DEC X/Y
      #x18 #x38 #x58 #x78 #xB8 #xD8 #xF8) ; Flags
     'implied]

    ;; Accumulator
    [(#x0A #x4A #x2A #x6A) 'accumulator]  ; ASL/LSR/ROL/ROR A

    ;; Immediate
    [(#xA9 #xA2 #xA0                       ; LDA/LDX/LDY
      #x69 #xE9 #xEB                       ; ADC/SBC/*SBC
      #xC9 #xE0 #xC0                       ; CMP/CPX/CPY
      #x29 #x09 #x49                       ; AND/ORA/EOR
      #x80 #x82 #x89 #xC2 #xE2             ; *NOP imm
      #x0B #x2B #x4B #x6B #xCB #xAB #x8B)  ; Illegal imm
     'immediate]

    ;; Zero page
    [(#xA5 #xA6 #xA4                       ; LDA/LDX/LDY
      #x85 #x86 #x84                       ; STA/STX/STY
      #x65 #xE5                            ; ADC/SBC
      #xC5 #xE4 #xC4                       ; CMP/CPX/CPY
      #x25 #x05 #x45                       ; AND/ORA/EOR
      #x24                                 ; BIT
      #x04 #x44 #x64                       ; *NOP zp
      #xA7 #x87                            ; *LAX/*SAX
      #xC7 #xE7 #x07 #x27 #x47 #x67)       ; Illegal RMW handled separately
     (if (is-rmw-opcode? opcode) 'rmw-zp 'zeropage)]

    ;; Zero page,X
    [(#xB5 #xB4                            ; LDA/LDY
      #x95 #x94                            ; STA/STY
      #x75 #xF5                            ; ADC/SBC
      #xD5                                 ; CMP
      #x35 #x15 #x55                       ; AND/ORA/EOR
      #x14 #x34 #x54 #x74 #xD4 #xF4        ; *NOP zpx
      #xD7 #xF7 #x17 #x37 #x57 #x77)       ; Illegal
     (if (is-rmw-opcode? opcode) 'rmw-zpx 'zeropage-x)]

    ;; Zero page,Y
    [(#xB6 #x96                            ; LDX/STX
      #xB7 #x97)                           ; *LAX/*SAX
     'zeropage-y]

    ;; Absolute
    [(#xAD #xAE #xAC                       ; LDA/LDX/LDY
      #x8D #x8E #x8C                       ; STA/STX/STY
      #x6D #xED                            ; ADC/SBC
      #xCD #xEC #xCC                       ; CMP/CPX/CPY
      #x2D #x0D #x4D                       ; AND/ORA/EOR
      #x2C                                 ; BIT
      #x0C                                 ; *NOP abs
      #xAF #x8F                            ; *LAX/*SAX
      #xCF #xEF #x0F #x2F #x4F #x6F)       ; Illegal
     (if (is-rmw-opcode? opcode) 'rmw-abs 'absolute)]

    ;; Absolute,X
    [(#xBD #xBC                            ; LDA/LDY
      #x9D                                 ; STA
      #x7D #xFD                            ; ADC/SBC
      #xDD                                 ; CMP
      #x3D #x1D #x5D                       ; AND/ORA/EOR
      #x1C #x3C #x5C #x7C #xDC #xFC        ; *NOP abx
      #x9C                                 ; *SHY
      #xDF #xFF #x1F #x3F #x5F #x7F)       ; Illegal
     (if (is-rmw-opcode? opcode) 'rmw-absx 'absolute-x)]

    ;; Absolute,Y
    [(#xB9 #xBE                            ; LDA/LDX
      #x99                                 ; STA
      #x79 #xF9                            ; ADC/SBC
      #xD9                                 ; CMP
      #x39 #x19 #x59                       ; AND/ORA/EOR
      #xBF                                 ; *LAX
      #x9E #x9F #x9B #xBB                  ; *SHX/*AHX/*TAS/*LAS
      #xDB #xFB #x1B #x3B #x5B #x7B)       ; Illegal RMW
     (if (is-rmw-opcode? opcode) 'absolute-y 'absolute-y)]  ; abs,Y RMW is 7 cycles, no skip

    ;; Indirect (JMP only)
    [(#x6C) 'jmp-ind]

    ;; Indexed Indirect (X)
    [(#xA1 #x81                            ; LDA/STA
      #x61 #xE1                            ; ADC/SBC
      #xC1                                 ; CMP
      #x21 #x01 #x41                       ; AND/ORA/EOR
      #xA3 #x83                            ; *LAX/*SAX
      #xC3 #xE3 #x03 #x23 #x43 #x63)       ; Illegal
     'indirect-x]

    ;; Indirect Indexed (Y)
    [(#xB1 #x91                            ; LDA/STA
      #x71 #xF1                            ; ADC/SBC
      #xD1                                 ; CMP
      #x31 #x11 #x51                       ; AND/ORA/EOR
      #xB3 #x93                            ; *LAX/*AHX
      #xD3 #xF3 #x13 #x33 #x53 #x73)       ; Illegal
     'indirect-y]

    ;; Relative (branches)
    [(#x10 #x30 #x50 #x70 #x90 #xB0 #xD0 #xF0) 'relative]

    ;; Push
    [(#x48 #x08) 'push]  ; PHA/PHP

    ;; Pull
    [(#x68 #x28) 'pull]  ; PLA/PLP

    ;; Special
    [(#x20) 'jsr]
    [(#x60) 'rts]
    [(#x40) 'rti]
    [(#x00) 'brk]
    [(#x4C) 'jmp-abs]

    ;; RMW instructions - zero page
    [(#xE6 #xC6 #x06 #x46 #x26 #x66) 'rmw-zp]

    ;; RMW instructions - zero page,X
    [(#xF6 #xD6 #x16 #x56 #x36 #x76) 'rmw-zpx]

    ;; RMW instructions - absolute
    [(#xEE #xCE #x0E #x4E #x2E #x6E) 'rmw-abs]

    ;; RMW instructions - absolute,X
    [(#xFE #xDE #x1E #x5E #x3E #x7E) 'rmw-absx]

    ;; KIL opcodes
    [(#x02 #x12 #x22 #x32 #x42 #x52 #x62 #x72 #x92 #xB2 #xD2 #xF2)
     (error 'cpu-tick! "KIL opcode $~a"
            (~r opcode #:base 16 #:min-width 2 #:pad-string "0"))]

    [else 'implied]))  ; Fallback

(define (is-rmw-opcode? opcode)
  (case opcode
    ;; Official RMW
    [(#xE6 #xF6 #xEE #xFE    ; INC
      #xC6 #xD6 #xCE #xDE    ; DEC
      #x06 #x16 #x0E #x1E    ; ASL
      #x46 #x56 #x4E #x5E    ; LSR
      #x26 #x36 #x2E #x3E    ; ROL
      #x66 #x76 #x6E #x7E)   ; ROR
     #t]
    ;; Illegal RMW
    [(#xC7 #xD7 #xCF #xDF #xDB #xC3 #xD3   ; DCP
      #xE7 #xF7 #xEF #xFF #xFB #xE3 #xF3   ; ISC
      #x07 #x17 #x0F #x1F #x1B #x03 #x13   ; SLO
      #x27 #x37 #x2F #x3F #x3B #x23 #x33   ; RLA
      #x47 #x57 #x4F #x5F #x5B #x43 #x53   ; SRE
      #x67 #x77 #x6F #x7F #x7B #x63 #x73)  ; RRA
     #t]
    [else #f]))

;; ============================================================================
;; Implied Instructions (2 cycles)
;; ============================================================================

(define (execute-implied! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Execute
     (case opcode
       ;; NOPs
       [(#x1A #x3A #x5A #x7A #xDA #xFA #xEA) (void)]
       ;; Transfers
       [(#xAA) (set-cpu-x! c (cpu-a c)) (cpu-update-nz! c (cpu-x c))]
       [(#xA8) (set-cpu-y! c (cpu-a c)) (cpu-update-nz! c (cpu-y c))]
       [(#x8A) (set-cpu-a! c (cpu-x c)) (cpu-update-nz! c (cpu-a c))]
       [(#x98) (set-cpu-a! c (cpu-y c)) (cpu-update-nz! c (cpu-a c))]
       [(#xBA) (set-cpu-x! c (cpu-sp c)) (cpu-update-nz! c (cpu-x c))]
       [(#x9A) (set-cpu-sp! c (cpu-x c))]
       ;; Inc/Dec
       [(#xE8) (set-cpu-x! c (u8 (+ (cpu-x c) 1))) (cpu-update-nz! c (cpu-x c))]
       [(#xC8) (set-cpu-y! c (u8 (+ (cpu-y c) 1))) (cpu-update-nz! c (cpu-y c))]
       [(#xCA) (set-cpu-x! c (u8 (- (cpu-x c) 1))) (cpu-update-nz! c (cpu-x c))]
       [(#x88) (set-cpu-y! c (u8 (- (cpu-y c) 1))) (cpu-update-nz! c (cpu-y c))]
       ;; Flags
       [(#x18) (clear-cpu-flag! c flag-c)]
       [(#x38) (set-cpu-flag! c flag-c)]
       [(#x58) (clear-cpu-flag! c flag-i)]
       [(#x78) (set-cpu-flag! c flag-i)]
       [(#xB8) (clear-cpu-flag! c flag-v)]
       [(#xD8) (clear-cpu-flag! c flag-d)]
       [(#xF8) (set-cpu-flag! c flag-d)])]))

;; ============================================================================
;; Accumulator Instructions (2 cycles)
;; ============================================================================

(define (execute-accumulator! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Execute on accumulator
     (define a (cpu-a c))
     (case opcode
       [(#x0A) ; ASL A
        (when (bit? a 7) (set-cpu-flag! c flag-c))
        (unless (bit? a 7) (clear-cpu-flag! c flag-c))
        (set-cpu-a! c (u8 (arithmetic-shift a 1)))
        (cpu-update-nz! c (cpu-a c))]
       [(#x4A) ; LSR A
        (when (bit? a 0) (set-cpu-flag! c flag-c))
        (unless (bit? a 0) (clear-cpu-flag! c flag-c))
        (set-cpu-a! c (arithmetic-shift a -1))
        (cpu-update-nz! c (cpu-a c))]
       [(#x2A) ; ROL A
        (define carry-in (if (cpu-flag? c flag-c) 1 0))
        (when (bit? a 7) (set-cpu-flag! c flag-c))
        (unless (bit? a 7) (clear-cpu-flag! c flag-c))
        (set-cpu-a! c (u8 (bitwise-ior (arithmetic-shift a 1) carry-in)))
        (cpu-update-nz! c (cpu-a c))]
       [(#x6A) ; ROR A
        (define carry-in (if (cpu-flag? c flag-c) #x80 0))
        (when (bit? a 0) (set-cpu-flag! c flag-c))
        (unless (bit? a 0) (clear-cpu-flag! c flag-c))
        (set-cpu-a! c (bitwise-ior (arithmetic-shift a -1) carry-in))
        (cpu-update-nz! c (cpu-a c))])]))

;; ============================================================================
;; Immediate Instructions (2 cycles)
;; ============================================================================

(define (execute-immediate! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch operand and execute
     (define pc (cpu-pc c))
     (define val (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))
     (execute-read-op! c opcode val)]))

;; ============================================================================
;; Zero Page Instructions (3 cycles for read, 3 for write)
;; ============================================================================

(define (execute-zeropage! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch address
     (define pc (cpu-pc c))
     (set-instr-state-effective-addr! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Read/write
     (define addr (instr-state-effective-addr state))
     (if (is-write-opcode? opcode)
         (cpu-write c addr (get-write-value c opcode))
         (execute-read-op! c opcode (cpu-read c addr)))]))

;; ============================================================================
;; Zero Page,X Instructions (4 cycles)
;; ============================================================================

(define (execute-zeropage-x! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch base address
     (define pc (cpu-pc c))
     (set-instr-state-addr-lo! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Dummy read, add X
     (define base (instr-state-addr-lo state))
     (cpu-read c base)  ; Dummy read
     (set-instr-state-effective-addr! state (u8 (+ base (cpu-x c))))]
    [(3) ; Cycle 4: Read/write
     (define addr (instr-state-effective-addr state))
     (if (is-write-opcode? opcode)
         (cpu-write c addr (get-write-value c opcode))
         (execute-read-op! c opcode (cpu-read c addr)))]))

;; ============================================================================
;; Zero Page,Y Instructions (4 cycles)
;; ============================================================================

(define (execute-zeropage-y! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch base address
     (define pc (cpu-pc c))
     (set-instr-state-addr-lo! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Dummy read, add Y
     (define base (instr-state-addr-lo state))
     (cpu-read c base)
     (set-instr-state-effective-addr! state (u8 (+ base (cpu-y c))))]
    [(3) ; Cycle 4: Read/write
     (define addr (instr-state-effective-addr state))
     (if (is-write-opcode? opcode)
         (cpu-write c addr (get-write-value c opcode))
         (execute-read-op! c opcode (cpu-read c addr)))]))

;; ============================================================================
;; Absolute Instructions (4 cycles)
;; ============================================================================

(define (execute-absolute! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch address low
     (define pc (cpu-pc c))
     (set-instr-state-addr-lo! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Fetch address high
     (define pc (cpu-pc c))
     (define hi (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))
     (set-instr-state-addr-hi! state hi)
     (set-instr-state-effective-addr! state (merge16 (instr-state-addr-lo state) hi))]
    [(3) ; Cycle 4: Read/write
     (define addr (instr-state-effective-addr state))
     (if (is-write-opcode? opcode)
         (cpu-write c addr (get-write-value c opcode))
         (execute-read-op! c opcode (cpu-read c addr)))]))

;; ============================================================================
;; Absolute,X Instructions (4-5 cycles for reads, 5 for writes)
;; ============================================================================

(define (execute-absolute-x! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch address low
     (define pc (cpu-pc c))
     (set-instr-state-addr-lo! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Fetch address high, start adding X
     (define pc (cpu-pc c))
     (define hi-byte (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))
     (set-instr-state-addr-hi! state hi-byte)
     (define base (merge16 (instr-state-addr-lo state) hi-byte))
     (define eff (u16 (+ base (cpu-x c))))
     (set-instr-state-effective-addr! state eff)
     (define crossed? (not (= hi-byte (hi eff))))
     (set-instr-state-page-crossed?! state crossed?)
     ;; If page crossed and this is a read, add extra cycle
     (when (and crossed? (not (is-write-opcode? opcode)))
       (set-instr-state-total-cycles! state (+ (instr-state-total-cycles state) 1)))]
    [(3) ; Cycle 4: Read (possibly from wrong page)
     (let* ([eff (instr-state-effective-addr state)]
            [crossed? (instr-state-page-crossed? state)])
       (if (is-write-opcode? opcode)
           ;; Writes always take the extra cycle
           (let* ([lo (instr-state-addr-lo state)]
                  [wrong-addr (merge16 (u8 (+ lo (cpu-x c))) (instr-state-addr-hi state))])
             (cpu-read c wrong-addr))  ; Dummy read
           ;; Reads may skip if no page cross
           (if crossed?
               ;; Page crossed - dummy read from wrong address
               (let* ([lo (instr-state-addr-lo state)]
                      [wrong-addr (merge16 (u8 (+ lo (cpu-x c))) (instr-state-addr-hi state))])
                 (cpu-read c wrong-addr))
               ;; No page cross - read and execute now, adjust cycle count
               (begin
                 (execute-read-op! c opcode (cpu-read c eff))
                 ;; Reduce total cycles by 1 to skip cycle 5
                 (set-instr-state-total-cycles! state 4)))))]
    [(4) ; Cycle 5: Final read/write
     (define addr (instr-state-effective-addr state))
     (if (is-write-opcode? opcode)
         (cpu-write c addr (get-write-value c opcode))
         (execute-read-op! c opcode (cpu-read c addr)))]))

;; ============================================================================
;; Absolute,Y Instructions (4-5 cycles for reads, 5 for writes)
;; ============================================================================

(define (execute-absolute-y! c state opcode cycle)
  (case cycle
    [(1)
     (define pc (cpu-pc c))
     (set-instr-state-addr-lo! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2)
     (define pc (cpu-pc c))
     (define hi-byte (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))
     (set-instr-state-addr-hi! state hi-byte)
     (define base (merge16 (instr-state-addr-lo state) hi-byte))
     (define eff (u16 (+ base (cpu-y c))))
     (set-instr-state-effective-addr! state eff)
     (define crossed? (not (= hi-byte (hi eff))))
     (set-instr-state-page-crossed?! state crossed?)
     ;; If page crossed and this is a read, add extra cycle
     (when (and crossed? (not (is-write-opcode? opcode)))
       (set-instr-state-total-cycles! state (+ (instr-state-total-cycles state) 1)))]
    [(3)
     (let* ([eff (instr-state-effective-addr state)]
            [crossed? (instr-state-page-crossed? state)])
       (if (is-write-opcode? opcode)
           (let* ([lo (instr-state-addr-lo state)]
                  [wrong-addr (merge16 (u8 (+ lo (cpu-y c))) (instr-state-addr-hi state))])
             (cpu-read c wrong-addr))
           (if crossed?
               (let* ([lo (instr-state-addr-lo state)]
                      [wrong-addr (merge16 (u8 (+ lo (cpu-y c))) (instr-state-addr-hi state))])
                 (cpu-read c wrong-addr))
               (begin
                 (execute-read-op! c opcode (cpu-read c eff))
                 (set-instr-state-total-cycles! state 4)))))]
    [(4)
     (define addr (instr-state-effective-addr state))
     (if (is-write-opcode? opcode)
         (cpu-write c addr (get-write-value c opcode))
         (execute-read-op! c opcode (cpu-read c addr)))]))

;; ============================================================================
;; Indirect,X Instructions (6 cycles)
;; ============================================================================

(define (execute-indirect-x! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch pointer
     (define pc (cpu-pc c))
     (set-instr-state-pointer! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Dummy read, add X
     (define ptr (instr-state-pointer state))
     (cpu-read c ptr)
     (set-instr-state-pointer! state (u8 (+ ptr (cpu-x c))))]
    [(3) ; Cycle 4: Read effective address low
     (define ptr (instr-state-pointer state))
     (set-instr-state-addr-lo! state (cpu-read c ptr))]
    [(4) ; Cycle 5: Read effective address high
     (define ptr (instr-state-pointer state))
     (define hi (cpu-read c (u8 (+ ptr 1))))
     (set-instr-state-addr-hi! state hi)
     (set-instr-state-effective-addr! state (merge16 (instr-state-addr-lo state) hi))]
    [(5) ; Cycle 6: Read/write
     (define addr (instr-state-effective-addr state))
     (if (is-write-opcode? opcode)
         (cpu-write c addr (get-write-value c opcode))
         (execute-read-op! c opcode (cpu-read c addr)))]))

;; ============================================================================
;; Indirect,Y Instructions (5-6 cycles for reads, 6 for writes)
;; ============================================================================

(define (execute-indirect-y! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch pointer
     (define pc (cpu-pc c))
     (set-instr-state-pointer! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Read base address low
     (define ptr (instr-state-pointer state))
     (set-instr-state-addr-lo! state (cpu-read c ptr))]
    [(3) ; Cycle 4: Read base address high, add Y
     (define ptr (instr-state-pointer state))
     (define hi-byte (cpu-read c (u8 (+ ptr 1))))
     (set-instr-state-addr-hi! state hi-byte)
     (define base (merge16 (instr-state-addr-lo state) hi-byte))
     (define eff (u16 (+ base (cpu-y c))))
     (set-instr-state-effective-addr! state eff)
     (define crossed? (not (= hi-byte (hi eff))))
     (set-instr-state-page-crossed?! state crossed?)
     ;; If page crossed and this is a read, add extra cycle
     (when (and crossed? (not (is-write-opcode? opcode)))
       (set-instr-state-total-cycles! state (+ (instr-state-total-cycles state) 1)))]
    [(4) ; Cycle 5: Read (possibly from wrong page)
     (let* ([eff (instr-state-effective-addr state)]
            [crossed? (instr-state-page-crossed? state)])
       (if (is-write-opcode? opcode)
           (let* ([lo (instr-state-addr-lo state)]
                  [wrong-addr (merge16 (u8 (+ lo (cpu-y c))) (instr-state-addr-hi state))])
             (cpu-read c wrong-addr))
           (if crossed?
               (let* ([lo (instr-state-addr-lo state)]
                      [wrong-addr (merge16 (u8 (+ lo (cpu-y c))) (instr-state-addr-hi state))])
                 (cpu-read c wrong-addr))
               (begin
                 (execute-read-op! c opcode (cpu-read c eff))
                 (set-instr-state-total-cycles! state 5)))))]
    [(5) ; Cycle 6: Final read/write
     (define addr (instr-state-effective-addr state))
     (if (is-write-opcode? opcode)
         (cpu-write c addr (get-write-value c opcode))
         (execute-read-op! c opcode (cpu-read c addr)))]))

;; ============================================================================
;; Relative (Branch) Instructions (2-4 cycles)
;; ============================================================================

(define (execute-relative! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch offset, check condition
     (define pc (cpu-pc c))
     (define offset (u8->s8 (cpu-read c pc)))
     (set-cpu-pc! c (u16 (+ pc 1)))
     (define condition
       (case opcode
         [(#x10) (not (cpu-flag? c flag-n))]  ; BPL
         [(#x30) (cpu-flag? c flag-n)]        ; BMI
         [(#x50) (not (cpu-flag? c flag-v))]  ; BVC
         [(#x70) (cpu-flag? c flag-v)]        ; BVS
         [(#x90) (not (cpu-flag? c flag-c))]  ; BCC
         [(#xB0) (cpu-flag? c flag-c)]        ; BCS
         [(#xD0) (not (cpu-flag? c flag-z))]  ; BNE
         [(#xF0) (cpu-flag? c flag-z)]))      ; BEQ
     (if condition
         (let* ([new-pc (cpu-pc c)]
                [target (u16 (+ new-pc offset))])
           (set-instr-state-effective-addr! state target)
           (set-instr-state-page-crossed?! state (not (= (hi new-pc) (hi target))))
           ;; Branch taken - need at least 1 more cycle
           (set-instr-state-total-cycles! state (if (instr-state-page-crossed? state) 4 3)))
         ;; Branch not taken - done
         (set-instr-state-total-cycles! state 2))]
    [(2) ; Cycle 3: Branch taken, adjust PC (may need page fix)
     (define target (instr-state-effective-addr state))
     (if (instr-state-page-crossed? state)
         ;; Dummy read at wrong address
         (cpu-read c (merge16 (lo target) (hi (cpu-pc c))))
         ;; No page cross - set PC
         (set-cpu-pc! c target))]
    [(3) ; Cycle 4: Page cross - set correct PC
     (set-cpu-pc! c (instr-state-effective-addr state))]))

;; ============================================================================
;; Push Instructions (3 cycles)
;; ============================================================================

(define (execute-push! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Internal operation
     (void)]
    [(2) ; Cycle 3: Push
     (case opcode
       [(#x48) (cpu-push8! c (cpu-a c))]                              ; PHA
       [(#x08) (cpu-push8! c (set-bit (set-bit (cpu-p c) flag-b) 5))] ; PHP
       )]))

;; ============================================================================
;; Pull Instructions (4 cycles)
;; ============================================================================

(define (execute-pull! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Internal operation
     (void)]
    [(2) ; Cycle 3: Increment SP
     (set-cpu-sp! c (u8 (+ (cpu-sp c) 1)))]
    [(3) ; Cycle 4: Read value
     (define val (cpu-read c (merge16 (cpu-sp c) #x01)))
     (case opcode
       [(#x68) ; PLA
        (set-cpu-a! c val)
        (cpu-update-nz! c val)]
       [(#x28) ; PLP
        (set-cpu-p! c (set-bit (clear-bit val flag-b) 5))])]))

;; ============================================================================
;; JSR (6 cycles)
;; ============================================================================

(define (execute-jsr! c state cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch address low
     (define pc (cpu-pc c))
     (set-instr-state-addr-lo! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Internal operation (SP)
     (void)]
    [(3) ; Cycle 4: Push PC high
     (cpu-push8! c (hi (cpu-pc c)))]
    [(4) ; Cycle 5: Push PC low
     (cpu-push8! c (lo (cpu-pc c)))]
    [(5) ; Cycle 6: Fetch address high, set PC
     (define hi (cpu-read c (cpu-pc c)))
     (set-cpu-pc! c (merge16 (instr-state-addr-lo state) hi))]))

;; ============================================================================
;; RTS (6 cycles)
;; ============================================================================

(define (execute-rts! c state cycle)
  (case cycle
    [(1) ; Cycle 2: Internal operation
     (void)]
    [(2) ; Cycle 3: Increment SP
     (set-cpu-sp! c (u8 (+ (cpu-sp c) 1)))]
    [(3) ; Cycle 4: Pull PC low
     (set-instr-state-addr-lo! state (cpu-read c (merge16 (cpu-sp c) #x01)))
     (set-cpu-sp! c (u8 (+ (cpu-sp c) 1)))]
    [(4) ; Cycle 5: Pull PC high
     (set-instr-state-addr-hi! state (cpu-read c (merge16 (cpu-sp c) #x01)))]
    [(5) ; Cycle 6: Increment PC
     (set-cpu-pc! c (u16 (+ (merge16 (instr-state-addr-lo state)
                                     (instr-state-addr-hi state)) 1)))]))

;; ============================================================================
;; RTI (6 cycles)
;; ============================================================================

(define (execute-rti! c state cycle)
  (case cycle
    [(1) ; Cycle 2: Internal operation
     (void)]
    [(2) ; Cycle 3: Increment SP
     (set-cpu-sp! c (u8 (+ (cpu-sp c) 1)))]
    [(3) ; Cycle 4: Pull P
     (define p (cpu-read c (merge16 (cpu-sp c) #x01)))
     (set-cpu-p! c (set-bit (clear-bit p flag-b) 5))
     (set-cpu-sp! c (u8 (+ (cpu-sp c) 1)))]
    [(4) ; Cycle 5: Pull PC low
     (set-instr-state-addr-lo! state (cpu-read c (merge16 (cpu-sp c) #x01)))
     (set-cpu-sp! c (u8 (+ (cpu-sp c) 1)))]
    [(5) ; Cycle 6: Pull PC high
     (set-instr-state-addr-hi! state (cpu-read c (merge16 (cpu-sp c) #x01)))
     (set-cpu-pc! c (merge16 (instr-state-addr-lo state) (instr-state-addr-hi state)))]))

;; ============================================================================
;; BRK (7 cycles)
;; ============================================================================

(define (execute-brk! c state cycle)
  (case cycle
    [(1) ; Cycle 2: Read and discard operand, increment PC
     (define pc (cpu-pc c))
     (cpu-read c pc)
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Push PC high
     (cpu-push8! c (hi (cpu-pc c)))]
    [(3) ; Cycle 4: Push PC low
     (cpu-push8! c (lo (cpu-pc c)))]
    [(4) ; Cycle 5: Push P with B set
     (cpu-push8! c (set-bit (set-bit (cpu-p c) flag-b) 5))]
    [(5) ; Cycle 6: Fetch vector low
     (set-instr-state-addr-lo! state (cpu-read c #xFFFE))
     (set-cpu-flag! c flag-i)]
    [(6) ; Cycle 7: Fetch vector high, set PC
     (set-instr-state-addr-hi! state (cpu-read c #xFFFF))
     (set-cpu-pc! c (merge16 (instr-state-addr-lo state) (instr-state-addr-hi state)))]))

;; ============================================================================
;; JMP Absolute (3 cycles)
;; ============================================================================

(define (execute-jmp-abs! c state cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch address low
     (define pc (cpu-pc c))
     (set-instr-state-addr-lo! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Fetch address high, set PC
     (define pc (cpu-pc c))
     (define hi (cpu-read c pc))
     (set-cpu-pc! c (merge16 (instr-state-addr-lo state) hi))]))

;; ============================================================================
;; JMP Indirect (5 cycles)
;; ============================================================================

(define (execute-jmp-ind! c state cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch pointer low
     (define pc (cpu-pc c))
     (set-instr-state-addr-lo! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Fetch pointer high
     (define pc (cpu-pc c))
     (set-instr-state-addr-hi! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(3) ; Cycle 4: Read target low (with page wrap bug)
     (define ptr (merge16 (instr-state-addr-lo state) (instr-state-addr-hi state)))
     (set-instr-state-pointer! state (cpu-read c ptr))]
    [(4) ; Cycle 5: Read target high (with page wrap bug), set PC
     (define ptr-lo (instr-state-addr-lo state))
     (define ptr-hi (instr-state-addr-hi state))
     ;; Bug: if low byte is $FF, wrap within page
     (define hi-addr (if (= ptr-lo #xFF)
                         (merge16 #x00 ptr-hi)
                         (merge16 (u8 (+ ptr-lo 1)) ptr-hi)))
     (define target-hi (cpu-read c hi-addr))
     (set-cpu-pc! c (merge16 (instr-state-pointer state) target-hi))]))

;; ============================================================================
;; RMW Instructions - Zero Page (5 cycles)
;; ============================================================================

(define (execute-rmw-zp! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch address
     (define pc (cpu-pc c))
     (set-instr-state-effective-addr! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Read value
     (define addr (instr-state-effective-addr state))
     (set-instr-state-data! state (cpu-read c addr))]
    [(3) ; Cycle 4: Dummy write of original value (modify)
     (define addr (instr-state-effective-addr state))
     (define val (instr-state-data state))
     (cpu-write c addr val)]  ; Write old value
    [(4) ; Cycle 5: Write modified value
     (define addr (instr-state-effective-addr state))
     (define val (instr-state-data state))
     (define result (execute-rmw-op! c opcode val))
     (cpu-write c addr result)]))

;; ============================================================================
;; RMW Instructions - Zero Page,X (6 cycles)
;; ============================================================================

(define (execute-rmw-zpx! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch base address
     (define pc (cpu-pc c))
     (set-instr-state-addr-lo! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Dummy read, add X
     (define base (instr-state-addr-lo state))
     (cpu-read c base)
     (set-instr-state-effective-addr! state (u8 (+ base (cpu-x c))))]
    [(3) ; Cycle 4: Read value
     (define addr (instr-state-effective-addr state))
     (set-instr-state-data! state (cpu-read c addr))]
    [(4) ; Cycle 5: Dummy write
     (define addr (instr-state-effective-addr state))
     (cpu-write c addr (instr-state-data state))]
    [(5) ; Cycle 6: Write modified value
     (define addr (instr-state-effective-addr state))
     (define result (execute-rmw-op! c opcode (instr-state-data state)))
     (cpu-write c addr result)]))

;; ============================================================================
;; RMW Instructions - Absolute (6 cycles)
;; ============================================================================

(define (execute-rmw-abs! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch address low
     (define pc (cpu-pc c))
     (set-instr-state-addr-lo! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Fetch address high
     (define pc (cpu-pc c))
     (define hi (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))
     (set-instr-state-effective-addr! state (merge16 (instr-state-addr-lo state) hi))]
    [(3) ; Cycle 4: Read value
     (set-instr-state-data! state (cpu-read c (instr-state-effective-addr state)))]
    [(4) ; Cycle 5: Dummy write
     (cpu-write c (instr-state-effective-addr state) (instr-state-data state))]
    [(5) ; Cycle 6: Write modified value
     (define result (execute-rmw-op! c opcode (instr-state-data state)))
     (cpu-write c (instr-state-effective-addr state) result)]))

;; ============================================================================
;; RMW Instructions - Absolute,X (7 cycles)
;; ============================================================================

(define (execute-rmw-absx! c state opcode cycle)
  (case cycle
    [(1) ; Cycle 2: Fetch address low
     (define pc (cpu-pc c))
     (set-instr-state-addr-lo! state (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))]
    [(2) ; Cycle 3: Fetch address high
     (define pc (cpu-pc c))
     (define hi (cpu-read c pc))
     (set-cpu-pc! c (u16 (+ pc 1)))
     (set-instr-state-addr-hi! state hi)]
    [(3) ; Cycle 4: Dummy read at wrong address, add X
     (define lo (instr-state-addr-lo state))
     (define hi (instr-state-addr-hi state))
     (define wrong-addr (merge16 (u8 (+ lo (cpu-x c))) hi))
     (cpu-read c wrong-addr)
     (set-instr-state-effective-addr! state (u16 (+ (merge16 lo hi) (cpu-x c))))]
    [(4) ; Cycle 5: Read value
     (set-instr-state-data! state (cpu-read c (instr-state-effective-addr state)))]
    [(5) ; Cycle 6: Dummy write
     (cpu-write c (instr-state-effective-addr state) (instr-state-data state))]
    [(6) ; Cycle 7: Write modified value
     (define result (execute-rmw-op! c opcode (instr-state-data state)))
     (cpu-write c (instr-state-effective-addr state) result)]))

;; ============================================================================
;; Instruction Helpers
;; ============================================================================

(define (is-write-opcode? opcode)
  (case opcode
    [(#x85 #x95 #x8D #x9D #x99 #x81 #x91  ; STA
      #x86 #x96 #x8E                       ; STX
      #x84 #x94 #x8C                       ; STY
      #x87 #x97 #x8F #x83                  ; *SAX
      #x9C #x9E #x9F #x93 #x9B)            ; Unstable stores
     #t]
    [else #f]))

(define (get-write-value c opcode)
  (case opcode
    [(#x85 #x95 #x8D #x9D #x99 #x81 #x91) (cpu-a c)]  ; STA
    [(#x86 #x96 #x8E) (cpu-x c)]                       ; STX
    [(#x84 #x94 #x8C) (cpu-y c)]                       ; STY
    [(#x87 #x97 #x8F #x83) (bitwise-and (cpu-a c) (cpu-x c))]  ; *SAX
    [else 0]))

;; Execute a read operation (LDA, ADC, etc.)
(define (execute-read-op! c opcode val)
  (case opcode
    ;; LDA
    [(#xA9 #xA5 #xB5 #xAD #xBD #xB9 #xA1 #xB1)
     (set-cpu-a! c val)
     (cpu-update-nz! c val)]
    ;; LDX
    [(#xA2 #xA6 #xB6 #xAE #xBE)
     (set-cpu-x! c val)
     (cpu-update-nz! c val)]
    ;; LDY
    [(#xA0 #xA4 #xB4 #xAC #xBC)
     (set-cpu-y! c val)
     (cpu-update-nz! c val)]
    ;; ADC
    [(#x69 #x65 #x75 #x6D #x7D #x79 #x61 #x71)
     (do-adc! c val)]
    ;; SBC
    [(#xE9 #xEB #xE5 #xF5 #xED #xFD #xF9 #xE1 #xF1)
     (do-sbc! c val)]
    ;; CMP
    [(#xC9 #xC5 #xD5 #xCD #xDD #xD9 #xC1 #xD1)
     (do-compare! c (cpu-a c) val)]
    ;; CPX
    [(#xE0 #xE4 #xEC)
     (do-compare! c (cpu-x c) val)]
    ;; CPY
    [(#xC0 #xC4 #xCC)
     (do-compare! c (cpu-y c) val)]
    ;; AND
    [(#x29 #x25 #x35 #x2D #x3D #x39 #x21 #x31)
     (set-cpu-a! c (bitwise-and (cpu-a c) val))
     (cpu-update-nz! c (cpu-a c))]
    ;; ORA
    [(#x09 #x05 #x15 #x0D #x1D #x19 #x01 #x11)
     (set-cpu-a! c (bitwise-ior (cpu-a c) val))
     (cpu-update-nz! c (cpu-a c))]
    ;; EOR
    [(#x49 #x45 #x55 #x4D #x5D #x59 #x41 #x51)
     (set-cpu-a! c (bitwise-xor (cpu-a c) val))
     (cpu-update-nz! c (cpu-a c))]
    ;; BIT
    [(#x24 #x2C)
     (if (zero? (bitwise-and (cpu-a c) val))
         (set-cpu-flag! c flag-z)
         (clear-cpu-flag! c flag-z))
     (if (bit? val 7)
         (set-cpu-flag! c flag-n)
         (clear-cpu-flag! c flag-n))
     (if (bit? val 6)
         (set-cpu-flag! c flag-v)
         (clear-cpu-flag! c flag-v))]
    ;; *LAX (LDA + LDX)
    [(#xA7 #xB7 #xAF #xBF #xA3 #xB3)
     (set-cpu-a! c val)
     (set-cpu-x! c val)
     (cpu-update-nz! c val)]
    ;; *NOP (reads that do nothing)
    [(#x04 #x44 #x64 #x14 #x34 #x54 #x74 #xD4 #xF4  ; DOP
      #x0C #x1C #x3C #x5C #x7C #xDC #xFC             ; TOP
      #x80 #x82 #x89 #xC2 #xE2)                      ; DOP imm
     (void)]
    ;; *ANC
    [(#x0B #x2B)
     (set-cpu-a! c (bitwise-and (cpu-a c) val))
     (cpu-update-nz! c (cpu-a c))
     (if (cpu-flag? c flag-n)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))]
    ;; *ALR
    [(#x4B)
     (define result (bitwise-and (cpu-a c) val))
     (if (bit? result 0)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))
     (set-cpu-a! c (arithmetic-shift result -1))
     (cpu-update-nz! c (cpu-a c))]
    ;; *ARR
    [(#x6B)
     (define and-result (bitwise-and (cpu-a c) val))
     (define carry-in (if (cpu-flag? c flag-c) #x80 0))
     (define result (u8 (bitwise-ior (arithmetic-shift and-result -1) carry-in)))
     (set-cpu-a! c result)
     (cpu-update-nz! c result)
     (if (bit? result 6)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))
     (if (not (= (if (bit? result 6) 1 0) (if (bit? result 5) 1 0)))
         (set-cpu-flag! c flag-v)
         (clear-cpu-flag! c flag-v))]
    ;; *AXS
    [(#xCB)
     (define ax (bitwise-and (cpu-a c) (cpu-x c)))
     (define result (- ax val))
     (if (>= result 0)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))
     (set-cpu-x! c (u8 result))
     (cpu-update-nz! c (cpu-x c))]
    ;; *ATX/LXA
    [(#xAB)
     (define result (bitwise-and (bitwise-ior (cpu-a c) #xFF) val))
     (set-cpu-a! c result)
     (set-cpu-x! c result)
     (cpu-update-nz! c result)]
    ;; *XAA
    [(#x8B)
     (define result (bitwise-and (cpu-a c) (bitwise-and (cpu-x c) val)))
     (set-cpu-a! c result)
     (cpu-update-nz! c result)]
    ;; *LAS
    [(#xBB)
     (define result (bitwise-and val (cpu-sp c)))
     (set-cpu-a! c result)
     (set-cpu-x! c result)
     (set-cpu-sp! c result)
     (cpu-update-nz! c result)]
    [else (void)]))

;; Execute an RMW operation, return the modified value
(define (execute-rmw-op! c opcode val)
  (case opcode
    ;; INC
    [(#xE6 #xF6 #xEE #xFE)
     (define result (u8 (+ val 1)))
     (cpu-update-nz! c result)
     result]
    ;; DEC
    [(#xC6 #xD6 #xCE #xDE)
     (define result (u8 (- val 1)))
     (cpu-update-nz! c result)
     result]
    ;; ASL
    [(#x06 #x16 #x0E #x1E)
     (if (bit? val 7)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))
     (define result (u8 (arithmetic-shift val 1)))
     (cpu-update-nz! c result)
     result]
    ;; LSR
    [(#x46 #x56 #x4E #x5E)
     (if (bit? val 0)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))
     (define result (arithmetic-shift val -1))
     (cpu-update-nz! c result)
     result]
    ;; ROL
    [(#x26 #x36 #x2E #x3E)
     (define carry-in (if (cpu-flag? c flag-c) 1 0))
     (if (bit? val 7)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))
     (define result (u8 (bitwise-ior (arithmetic-shift val 1) carry-in)))
     (cpu-update-nz! c result)
     result]
    ;; ROR
    [(#x66 #x76 #x6E #x7E)
     (define carry-in (if (cpu-flag? c flag-c) #x80 0))
     (if (bit? val 0)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))
     (define result (bitwise-ior (arithmetic-shift val -1) carry-in))
     (cpu-update-nz! c result)
     result]
    ;; *DCP (DEC then CMP)
    [(#xC7 #xD7 #xCF #xDF #xDB #xC3 #xD3)
     (define dec-val (u8 (- val 1)))
     (do-compare! c (cpu-a c) dec-val)
     dec-val]
    ;; *ISC (INC then SBC)
    [(#xE7 #xF7 #xEF #xFF #xFB #xE3 #xF3)
     (define inc-val (u8 (+ val 1)))
     (do-sbc! c inc-val)
     inc-val]
    ;; *SLO (ASL then ORA)
    [(#x07 #x17 #x0F #x1F #x1B #x03 #x13)
     (if (bit? val 7)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))
     (define shifted (u8 (arithmetic-shift val 1)))
     (set-cpu-a! c (bitwise-ior (cpu-a c) shifted))
     (cpu-update-nz! c (cpu-a c))
     shifted]
    ;; *RLA (ROL then AND)
    [(#x27 #x37 #x2F #x3F #x3B #x23 #x33)
     (define carry-in (if (cpu-flag? c flag-c) 1 0))
     (if (bit? val 7)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))
     (define rotated (u8 (bitwise-ior (arithmetic-shift val 1) carry-in)))
     (set-cpu-a! c (bitwise-and (cpu-a c) rotated))
     (cpu-update-nz! c (cpu-a c))
     rotated]
    ;; *SRE (LSR then EOR)
    [(#x47 #x57 #x4F #x5F #x5B #x43 #x53)
     (if (bit? val 0)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))
     (define shifted (arithmetic-shift val -1))
     (set-cpu-a! c (bitwise-xor (cpu-a c) shifted))
     (cpu-update-nz! c (cpu-a c))
     shifted]
    ;; *RRA (ROR then ADC)
    [(#x67 #x77 #x6F #x7F #x7B #x63 #x73)
     (define carry-in (if (cpu-flag? c flag-c) #x80 0))
     (if (bit? val 0)
         (set-cpu-flag! c flag-c)
         (clear-cpu-flag! c flag-c))
     (define rotated (bitwise-ior (arithmetic-shift val -1) carry-in))
     (do-adc! c rotated)
     rotated]
    [else val]))

;; ADC helper
(define (do-adc! c val)
  (define a (cpu-a c))
  (define carry (if (cpu-flag? c flag-c) 1 0))
  (define sum (+ a val carry))
  (if (> sum #xFF)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (define result (u8 sum))
  (if (not (zero? (bitwise-and (bitwise-xor a result)
                               (bitwise-and (bitwise-xor val result) #x80))))
      (set-cpu-flag! c flag-v)
      (clear-cpu-flag! c flag-v))
  (set-cpu-a! c result)
  (cpu-update-nz! c result))

;; SBC helper
(define (do-sbc! c val)
  (define a (cpu-a c))
  (define borrow (if (cpu-flag? c flag-c) 0 1))
  (define diff (- a val borrow))
  (if (< diff 0)
      (clear-cpu-flag! c flag-c)
      (set-cpu-flag! c flag-c))
  (define result (u8 diff))
  (define not-val (u8 (bitwise-not val)))
  (if (not (zero? (bitwise-and (bitwise-xor a result)
                               (bitwise-and (bitwise-xor not-val result) #x80))))
      (set-cpu-flag! c flag-v)
      (clear-cpu-flag! c flag-v))
  (set-cpu-a! c result)
  (cpu-update-nz! c result))

;; Compare helper
(define (do-compare! c reg val)
  (define diff (- reg val))
  (cpu-update-nz! c (u8 diff))
  (if (>= reg val)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c)))

;; ============================================================================
;; Need format for error messages
;; ============================================================================

(require racket/format)

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit
           "../bus.rkt")

  ;; Install executor for instruction-stepped tests
  (install-opcode-executor!)

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

  ;; Helper: run cpu-tick! until instruction completes
  (define (run-instruction-ticks c)
    (let loop ([cycles 0])
      (cpu-tick! c)
      (if (cpu-at-instruction-boundary? c)
          (+ cycles 1)
          (loop (+ cycles 1)))))

  (test-case "cpu-tick! LDA immediate takes 2 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xA9)  ; LDA #$42
    (bytes-set! ram #x0001 #x42)
    (set-cpu-pc! c #x0000)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 2)
    (check-equal? (cpu-a c) #x42)
    (check-equal? (cpu-pc c) #x0002))

  (test-case "cpu-tick! LDA zero page takes 3 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xA5)  ; LDA $10
    (bytes-set! ram #x0001 #x10)
    (bytes-set! ram #x0010 #x55)
    (set-cpu-pc! c #x0000)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 3)
    (check-equal? (cpu-a c) #x55))

  (test-case "cpu-tick! LDA absolute takes 4 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xAD)  ; LDA $1234
    (bytes-set! ram #x0001 #x34)
    (bytes-set! ram #x0002 #x12)
    (bytes-set! ram #x1234 #x77)
    (set-cpu-pc! c #x0000)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 4)
    (check-equal? (cpu-a c) #x77))

  (test-case "cpu-tick! LDA absolute,X no page cross takes 4 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xBD)  ; LDA $1200,X
    (bytes-set! ram #x0001 #x00)
    (bytes-set! ram #x0002 #x12)
    (bytes-set! ram #x1210 #x99)
    (set-cpu-pc! c #x0000)
    (set-cpu-x! c #x10)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 4)
    (check-equal? (cpu-a c) #x99))

  (test-case "cpu-tick! LDA absolute,X page cross takes 5 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xBD)  ; LDA $12FF,X
    (bytes-set! ram #x0001 #xFF)
    (bytes-set! ram #x0002 #x12)
    (bytes-set! ram #x1310 #xAA)  ; $12FF + $11 = $1310
    (set-cpu-pc! c #x0000)
    (set-cpu-x! c #x11)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 5)
    (check-equal? (cpu-a c) #xAA))

  (test-case "cpu-tick! STA absolute takes 4 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x8D)  ; STA $1234
    (bytes-set! ram #x0001 #x34)
    (bytes-set! ram #x0002 #x12)
    (set-cpu-pc! c #x0000)
    (set-cpu-a! c #xBB)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 4)
    (check-equal? (bytes-ref ram #x1234) #xBB))

  (test-case "cpu-tick! STA absolute,X always takes 5 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x9D)  ; STA $1200,X
    (bytes-set! ram #x0001 #x00)
    (bytes-set! ram #x0002 #x12)
    (set-cpu-pc! c #x0000)
    (set-cpu-a! c #xCC)
    (set-cpu-x! c #x05)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 5)
    (check-equal? (bytes-ref ram #x1205) #xCC))

  (test-case "cpu-tick! JMP absolute takes 3 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x4C)  ; JMP $1234
    (bytes-set! ram #x0001 #x34)
    (bytes-set! ram #x0002 #x12)
    (set-cpu-pc! c #x0000)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 3)
    (check-equal? (cpu-pc c) #x1234))

  (test-case "cpu-tick! BNE not taken takes 2 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xD0)  ; BNE +$10
    (bytes-set! ram #x0001 #x10)
    (set-cpu-pc! c #x0000)
    (set-cpu-flag! c flag-z)  ; Z set, so branch not taken
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 2)
    (check-equal? (cpu-pc c) #x0002))

  (test-case "cpu-tick! BNE taken no page cross takes 3 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xD0)  ; BNE +$10
    (bytes-set! ram #x0001 #x10)
    (set-cpu-pc! c #x0000)
    (clear-cpu-flag! c flag-z)  ; Z clear, so branch taken
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 3)
    (check-equal? (cpu-pc c) #x0012))  ; $0002 + $10 = $0012

  (test-case "cpu-tick! BNE taken with page cross takes 4 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x00F0 #xD0)  ; BNE +$20
    (bytes-set! ram #x00F1 #x20)
    (set-cpu-pc! c #x00F0)
    (clear-cpu-flag! c flag-z)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 4)
    (check-equal? (cpu-pc c) #x0112))  ; $00F2 + $20 = $0112 (page cross)

  (test-case "cpu-tick! INC zero page takes 5 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xE6)  ; INC $10
    (bytes-set! ram #x0001 #x10)
    (bytes-set! ram #x0010 #x05)
    (set-cpu-pc! c #x0000)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 5)
    (check-equal? (bytes-ref ram #x0010) #x06))

  (test-case "cpu-tick! INC absolute takes 6 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xEE)  ; INC $1234
    (bytes-set! ram #x0001 #x34)
    (bytes-set! ram #x0002 #x12)
    (bytes-set! ram #x1234 #xFF)
    (set-cpu-pc! c #x0000)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 6)
    (check-equal? (bytes-ref ram #x1234) #x00)
    (check-true (cpu-flag? c flag-z)))

  (test-case "cpu-tick! JSR takes 6 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x20)  ; JSR $1234
    (bytes-set! ram #x0001 #x34)
    (bytes-set! ram #x0002 #x12)
    (set-cpu-pc! c #x0000)
    (set-cpu-sp! c #xFF)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 6)
    (check-equal? (cpu-pc c) #x1234)
    (check-equal? (cpu-sp c) #xFD))

  (test-case "cpu-tick! RTS takes 6 cycles"
    (define-values (c ram) (make-test-cpu))
    ;; Set up return address on stack
    (bytes-set! ram #x01FE #x02)  ; low byte (will become $0003)
    (bytes-set! ram #x01FF #x00)  ; high byte
    (bytes-set! ram #x0000 #x60)  ; RTS
    (set-cpu-pc! c #x0000)
    (set-cpu-sp! c #xFD)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 6)
    (check-equal? (cpu-pc c) #x0003))  ; Return address + 1

  (test-case "cpu-tick! LDA absolute,Y no page cross takes 4 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xB9)  ; LDA $1200,Y
    (bytes-set! ram #x0001 #x00)
    (bytes-set! ram #x0002 #x12)
    (bytes-set! ram #x1210 #x88)
    (set-cpu-pc! c #x0000)
    (set-cpu-y! c #x10)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 4)
    (check-equal? (cpu-a c) #x88))

  (test-case "cpu-tick! LDA absolute,Y page cross takes 5 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xB9)  ; LDA $12FF,Y
    (bytes-set! ram #x0001 #xFF)
    (bytes-set! ram #x0002 #x12)
    (bytes-set! ram #x1310 #x77)  ; $12FF + $11 = $1310
    (set-cpu-pc! c #x0000)
    (set-cpu-y! c #x11)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 5)
    (check-equal? (cpu-a c) #x77))

  (test-case "cpu-tick! LDA (indirect),Y no page cross takes 5 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xB1)  ; LDA ($10),Y
    (bytes-set! ram #x0001 #x10)
    (bytes-set! ram #x0010 #x00)  ; Low byte of address
    (bytes-set! ram #x0011 #x12)  ; High byte of address -> $1200
    (bytes-set! ram #x1210 #x66)  ; $1200 + $10 = $1210
    (set-cpu-pc! c #x0000)
    (set-cpu-y! c #x10)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 5)
    (check-equal? (cpu-a c) #x66))

  (test-case "cpu-tick! LDA (indirect),Y page cross takes 6 cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xB1)  ; LDA ($10),Y
    (bytes-set! ram #x0001 #x10)
    (bytes-set! ram #x0010 #xFF)  ; Low byte of address
    (bytes-set! ram #x0011 #x12)  ; High byte of address -> $12FF
    (bytes-set! ram #x1310 #x55)  ; $12FF + $11 = $1310 (page cross)
    (set-cpu-pc! c #x0000)
    (set-cpu-y! c #x11)
    (define cycles (run-instruction-ticks c))
    (check-equal? cycles 6)
    (check-equal? (cpu-a c) #x55))

  (test-case "cpu-tick! matches cpu-step! cycle count for LDA"
    (define-values (c1 ram1) (make-test-cpu))
    (define-values (c2 ram2) (make-test-cpu))
    ;; Set up same program in both
    (bytes-set! ram1 #x0000 #xA9)  ; LDA #$42
    (bytes-set! ram1 #x0001 #x42)
    (bytes-set! ram2 #x0000 #xA9)
    (bytes-set! ram2 #x0001 #x42)
    (set-cpu-pc! c1 #x0000)
    (set-cpu-pc! c2 #x0000)
    ;; Run with tick
    (define tick-cycles (run-instruction-ticks c1))
    ;; Run with step
    (define step-cycles-before (cpu-cycles c2))
    (cpu-step! c2)
    (define step-cycles (- (cpu-cycles c2) step-cycles-before))
    ;; Should match
    (check-equal? tick-cycles step-cycles)
    (check-equal? (cpu-a c1) (cpu-a c2))
    (check-equal? (cpu-pc c1) (cpu-pc c2))))
