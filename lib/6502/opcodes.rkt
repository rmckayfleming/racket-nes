#lang racket/base

;; 6502 Opcode Table and Instruction Execution
;;
;; Implements all 56 official 6502 instructions across their addressing modes.
;; Uses a table-driven approach for easy extension and debugging.
;;
;; Reference: https://www.nesdev.org/wiki/CPU_opcodes

(provide
 ;; Install the opcode executor into cpu.rkt
 install-opcode-executor!

 ;; For testing/debugging
 opcode-table
 opcode-info
 opcode-info-name
 opcode-info-mode
 opcode-info-bytes
 opcode-info-cycles)

(require "cpu.rkt"
         "addressing.rkt"
         "../bits.rkt")

;; ============================================================================
;; Opcode Info
;; ============================================================================

;; Information about an opcode
(struct opcode-info (name mode bytes cycles executor) #:transparent)

;; The opcode table: vector of 256 opcode-info structs (or #f for illegal)
(define opcode-table (make-vector 256 #f))

;; Register an opcode
(define (register-opcode! op name mode bytes cycles executor)
  (vector-set! opcode-table op (opcode-info name mode bytes cycles executor)))

;; ============================================================================
;; Instruction Helpers
;; ============================================================================

;; Read operand using addressing mode
(define (read-operand c mode)
  (define result (mode c))
  (if (eq? mode addr-immediate)
      ;; Immediate returns the value directly
      (values (addr-result-addr result) (addr-result-crossed? result))
      ;; Other modes return an address, so read from it
      (values (cpu-read c (addr-result-addr result)) (addr-result-crossed? result))))

;; Get address using addressing mode (for stores and RMW)
(define (get-address c mode)
  (define result (mode c))
  (values (addr-result-addr result) (addr-result-crossed? result)))

;; ============================================================================
;; Instruction Implementations
;; ============================================================================

;; --- Load/Store ---

(define (exec-lda c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (set-cpu-a! c val)
  (cpu-update-nz! c val)
  (cpu-add-cycles! c (+ cycles (if crossed? 1 0))))

(define (exec-ldx c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (set-cpu-x! c val)
  (cpu-update-nz! c val)
  (cpu-add-cycles! c (+ cycles (if crossed? 1 0))))

(define (exec-ldy c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (set-cpu-y! c val)
  (cpu-update-nz! c val)
  (cpu-add-cycles! c (+ cycles (if crossed? 1 0))))

(define (exec-sta c mode cycles)
  (define-values (addr _) (get-address c mode))
  (cpu-write c addr (cpu-a c))
  (cpu-add-cycles! c cycles))

(define (exec-stx c mode cycles)
  (define-values (addr _) (get-address c mode))
  (cpu-write c addr (cpu-x c))
  (cpu-add-cycles! c cycles))

(define (exec-sty c mode cycles)
  (define-values (addr _) (get-address c mode))
  (cpu-write c addr (cpu-y c))
  (cpu-add-cycles! c cycles))

;; --- Transfers ---

(define (exec-tax c)
  (set-cpu-x! c (cpu-a c))
  (cpu-update-nz! c (cpu-x c))
  (cpu-add-cycles! c 2))

(define (exec-tay c)
  (set-cpu-y! c (cpu-a c))
  (cpu-update-nz! c (cpu-y c))
  (cpu-add-cycles! c 2))

(define (exec-txa c)
  (set-cpu-a! c (cpu-x c))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c 2))

(define (exec-tya c)
  (set-cpu-a! c (cpu-y c))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c 2))

(define (exec-tsx c)
  (set-cpu-x! c (cpu-sp c))
  (cpu-update-nz! c (cpu-x c))
  (cpu-add-cycles! c 2))

(define (exec-txs c)
  (set-cpu-sp! c (cpu-x c))
  (cpu-add-cycles! c 2))

;; --- Stack ---

(define (exec-pha c)
  (cpu-push8! c (cpu-a c))
  (cpu-add-cycles! c 3))

(define (exec-php c)
  ;; B flag and bit 5 are always set when P is pushed
  (cpu-push8! c (set-bit (set-bit (cpu-p c) flag-b) 5))
  (cpu-add-cycles! c 3))

(define (exec-pla c)
  (set-cpu-a! c (cpu-pull8! c))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c 4))

(define (exec-plp c)
  ;; B flag is ignored when pulling, bit 5 stays set
  (define pulled (cpu-pull8! c))
  (set-cpu-p! c (set-bit (clear-bit pulled flag-b) 5))
  (cpu-add-cycles! c 4))

;; --- Arithmetic ---

(define (exec-adc c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (define a (cpu-a c))
  (define carry (if (cpu-flag? c flag-c) 1 0))
  (define sum (+ a val carry))

  ;; Set carry if overflow past 8 bits
  (if (> sum #xFF)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))

  ;; Set overflow if sign changed incorrectly
  ;; V = (A ^ result) & (val ^ result) & 0x80
  (define result (u8 sum))
  (if (not (zero? (bitwise-and (bitwise-xor a result)
                               (bitwise-and (bitwise-xor val result) #x80))))
      (set-cpu-flag! c flag-v)
      (clear-cpu-flag! c flag-v))

  (set-cpu-a! c result)
  (cpu-update-nz! c result)
  (cpu-add-cycles! c (+ cycles (if crossed? 1 0))))

(define (exec-sbc c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (define a (cpu-a c))
  (define borrow (if (cpu-flag? c flag-c) 0 1))
  ;; SBC is A - val - (1 - C) = A + ~val + C
  (define diff (- a val borrow))

  ;; Carry clear if borrow occurred
  (if (< diff 0)
      (clear-cpu-flag! c flag-c)
      (set-cpu-flag! c flag-c))

  ;; Overflow if sign changed incorrectly
  (define result (u8 diff))
  (define not-val (u8 (bitwise-not val)))
  (if (not (zero? (bitwise-and (bitwise-xor a result)
                               (bitwise-and (bitwise-xor not-val result) #x80))))
      (set-cpu-flag! c flag-v)
      (clear-cpu-flag! c flag-v))

  (set-cpu-a! c result)
  (cpu-update-nz! c result)
  (cpu-add-cycles! c (+ cycles (if crossed? 1 0))))

;; --- Compare ---

(define (compare! c reg val)
  (define diff (- reg val))
  (cpu-update-nz! c (u8 diff))
  (if (>= reg val)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c)))

(define (exec-cmp c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (compare! c (cpu-a c) val)
  (cpu-add-cycles! c (+ cycles (if crossed? 1 0))))

(define (exec-cpx c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (compare! c (cpu-x c) val)
  (cpu-add-cycles! c cycles))

(define (exec-cpy c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (compare! c (cpu-y c) val)
  (cpu-add-cycles! c cycles))

;; --- Increment/Decrement ---

(define (exec-inc c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (u8 (+ (cpu-read c addr) 1)))
  (cpu-write c addr val)
  (cpu-update-nz! c val)
  (cpu-add-cycles! c cycles))

(define (exec-dec c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (u8 (- (cpu-read c addr) 1)))
  (cpu-write c addr val)
  (cpu-update-nz! c val)
  (cpu-add-cycles! c cycles))

(define (exec-inx c)
  (set-cpu-x! c (u8 (+ (cpu-x c) 1)))
  (cpu-update-nz! c (cpu-x c))
  (cpu-add-cycles! c 2))

(define (exec-iny c)
  (set-cpu-y! c (u8 (+ (cpu-y c) 1)))
  (cpu-update-nz! c (cpu-y c))
  (cpu-add-cycles! c 2))

(define (exec-dex c)
  (set-cpu-x! c (u8 (- (cpu-x c) 1)))
  (cpu-update-nz! c (cpu-x c))
  (cpu-add-cycles! c 2))

(define (exec-dey c)
  (set-cpu-y! c (u8 (- (cpu-y c) 1)))
  (cpu-update-nz! c (cpu-y c))
  (cpu-add-cycles! c 2))

;; --- Logical ---

(define (exec-and c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (set-cpu-a! c (bitwise-and (cpu-a c) val))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c (+ cycles (if crossed? 1 0))))

(define (exec-ora c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (set-cpu-a! c (bitwise-ior (cpu-a c) val))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c (+ cycles (if crossed? 1 0))))

(define (exec-eor c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (set-cpu-a! c (bitwise-xor (cpu-a c) val))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c (+ cycles (if crossed? 1 0))))

(define (exec-bit c mode cycles)
  (define-values (val _) (read-operand c mode))
  ;; Z flag = A & val == 0
  (if (zero? (bitwise-and (cpu-a c) val))
      (set-cpu-flag! c flag-z)
      (clear-cpu-flag! c flag-z))
  ;; N flag = bit 7 of val
  (if (bit? val 7)
      (set-cpu-flag! c flag-n)
      (clear-cpu-flag! c flag-n))
  ;; V flag = bit 6 of val
  (if (bit? val 6)
      (set-cpu-flag! c flag-v)
      (clear-cpu-flag! c flag-v))
  (cpu-add-cycles! c cycles))

;; --- Shifts ---

(define (exec-asl-a c)
  (define a (cpu-a c))
  (if (bit? a 7)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (set-cpu-a! c (u8 (arithmetic-shift a 1)))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c 2))

(define (exec-asl c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (cpu-read c addr))
  (if (bit? val 7)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (define result (u8 (arithmetic-shift val 1)))
  (cpu-write c addr result)
  (cpu-update-nz! c result)
  (cpu-add-cycles! c cycles))

(define (exec-lsr-a c)
  (define a (cpu-a c))
  (if (bit? a 0)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (set-cpu-a! c (arithmetic-shift a -1))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c 2))

(define (exec-lsr c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (cpu-read c addr))
  (if (bit? val 0)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (define result (arithmetic-shift val -1))
  (cpu-write c addr result)
  (cpu-update-nz! c result)
  (cpu-add-cycles! c cycles))

(define (exec-rol-a c)
  (define a (cpu-a c))
  (define carry-in (if (cpu-flag? c flag-c) 1 0))
  (if (bit? a 7)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (set-cpu-a! c (u8 (bitwise-ior (arithmetic-shift a 1) carry-in)))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c 2))

(define (exec-rol c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (cpu-read c addr))
  (define carry-in (if (cpu-flag? c flag-c) 1 0))
  (if (bit? val 7)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (define result (u8 (bitwise-ior (arithmetic-shift val 1) carry-in)))
  (cpu-write c addr result)
  (cpu-update-nz! c result)
  (cpu-add-cycles! c cycles))

(define (exec-ror-a c)
  (define a (cpu-a c))
  (define carry-in (if (cpu-flag? c flag-c) #x80 0))
  (if (bit? a 0)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (set-cpu-a! c (bitwise-ior (arithmetic-shift a -1) carry-in))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c 2))

(define (exec-ror c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (cpu-read c addr))
  (define carry-in (if (cpu-flag? c flag-c) #x80 0))
  (if (bit? val 0)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (define result (bitwise-ior (arithmetic-shift val -1) carry-in))
  (cpu-write c addr result)
  (cpu-update-nz! c result)
  (cpu-add-cycles! c cycles))

;; --- Branches ---

(define (branch-if c condition)
  (define result (addr-relative c))
  (define target (addr-result-addr result))
  (define crossed? (addr-result-crossed? result))
  (if condition
      (begin
        (set-cpu-pc! c target)
        ;; +1 for branch taken, +1 more for page cross
        (cpu-add-cycles! c (+ 3 (if crossed? 1 0))))
      (cpu-add-cycles! c 2)))

(define (exec-bpl c) (branch-if c (not (cpu-flag? c flag-n))))
(define (exec-bmi c) (branch-if c (cpu-flag? c flag-n)))
(define (exec-bvc c) (branch-if c (not (cpu-flag? c flag-v))))
(define (exec-bvs c) (branch-if c (cpu-flag? c flag-v)))
(define (exec-bcc c) (branch-if c (not (cpu-flag? c flag-c))))
(define (exec-bcs c) (branch-if c (cpu-flag? c flag-c)))
(define (exec-bne c) (branch-if c (not (cpu-flag? c flag-z))))
(define (exec-beq c) (branch-if c (cpu-flag? c flag-z)))

;; --- Jumps ---

(define (exec-jmp c mode)
  (define result (mode c))
  (set-cpu-pc! c (addr-result-addr result))
  (cpu-add-cycles! c 3))

(define (exec-jmp-ind c)
  (define result (addr-indirect c))
  (set-cpu-pc! c (addr-result-addr result))
  (cpu-add-cycles! c 5))

(define (exec-jsr c)
  ;; Push return address - 1 (points to last byte of JSR instruction)
  (define result (addr-absolute c))
  (cpu-push16! c (u16 (- (cpu-pc c) 1)))
  (set-cpu-pc! c (addr-result-addr result))
  (cpu-add-cycles! c 6))

(define (exec-rts c)
  (define addr (cpu-pull16! c))
  (set-cpu-pc! c (u16 (+ addr 1)))
  (cpu-add-cycles! c 6))

(define (exec-rti c)
  ;; Pull P (ignoring B flag, keeping bit 5)
  (define pulled-p (cpu-pull8! c))
  (set-cpu-p! c (set-bit (clear-bit pulled-p flag-b) 5))
  ;; Pull PC
  (set-cpu-pc! c (cpu-pull16! c))
  (cpu-add-cycles! c 6))

;; --- Flag Instructions ---

(define (exec-clc c) (clear-cpu-flag! c flag-c) (cpu-add-cycles! c 2))
(define (exec-sec c) (set-cpu-flag! c flag-c) (cpu-add-cycles! c 2))
(define (exec-cli c) (clear-cpu-flag! c flag-i) (cpu-add-cycles! c 2))
(define (exec-sei c) (set-cpu-flag! c flag-i) (cpu-add-cycles! c 2))
(define (exec-clv c) (clear-cpu-flag! c flag-v) (cpu-add-cycles! c 2))
(define (exec-cld c) (clear-cpu-flag! c flag-d) (cpu-add-cycles! c 2))
(define (exec-sed c) (set-cpu-flag! c flag-d) (cpu-add-cycles! c 2))

;; --- NOP ---

(define (exec-nop c) (cpu-add-cycles! c 2))

;; --- BRK ---

(define (exec-brk c)
  ;; Fetch and discard operand byte
  (set-cpu-pc! c (u16 (+ (cpu-pc c) 1)))
  ;; Push PC and P (with B set)
  (cpu-push16! c (cpu-pc c))
  (cpu-push8! c (set-bit (set-bit (cpu-p c) flag-b) 5))
  ;; Set I flag
  (set-cpu-flag! c flag-i)
  ;; Load IRQ vector
  (set-cpu-pc! c (cpu-read16 c #xFFFE))
  (cpu-add-cycles! c 7))

;; ============================================================================
;; Illegal/Unofficial Opcodes
;; ============================================================================
;; Reference: https://www.nesdev.org/undocumented_opcodes.txt

;; --- Illegal NOPs (1-byte, implied mode) ---
;; Opcodes: $1A, $3A, $5A, $7A, $DA, $FA
(define (exec-nop-illegal c) (cpu-add-cycles! c 2))

;; --- DOP (Double NOP / SKB - skip byte) ---
;; 2-byte NOPs that read and discard an operand
(define (exec-dop-imm c)
  (set-cpu-pc! c (u16 (+ (cpu-pc c) 1)))  ; Skip 1 byte
  (cpu-add-cycles! c 2))

(define (exec-dop-zp c)
  (set-cpu-pc! c (u16 (+ (cpu-pc c) 1)))  ; Skip 1 byte
  (cpu-add-cycles! c 3))

(define (exec-dop-zpx c)
  (set-cpu-pc! c (u16 (+ (cpu-pc c) 1)))  ; Skip 1 byte
  (cpu-add-cycles! c 4))

;; --- TOP (Triple NOP / SKW - skip word) ---
;; 3-byte NOPs that read and discard 2 operand bytes
(define (exec-top-abs c)
  (set-cpu-pc! c (u16 (+ (cpu-pc c) 2)))  ; Skip 2 bytes
  (cpu-add-cycles! c 4))

(define (exec-top-abx c)
  ;; Also performs dummy read (page crossing adds cycle)
  (define-values (addr crossed?) (get-address c addr-absolute-x))
  (cpu-add-cycles! c (+ 4 (if crossed? 1 0))))

;; --- LAX (Load A and X) ---
(define (exec-lax c mode cycles)
  (define-values (val crossed?) (read-operand c mode))
  (set-cpu-a! c val)
  (set-cpu-x! c val)
  (cpu-update-nz! c val)
  (cpu-add-cycles! c (+ cycles (if crossed? 1 0))))

;; --- SAX/AAX (Store A AND X) ---
(define (exec-sax c mode cycles)
  (define-values (addr _) (get-address c mode))
  (cpu-write c addr (bitwise-and (cpu-a c) (cpu-x c)))
  (cpu-add-cycles! c cycles))

;; --- DCP (Decrement then Compare) ---
(define (exec-dcp c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (u8 (- (cpu-read c addr) 1)))
  (cpu-write c addr val)
  (compare! c (cpu-a c) val)
  (cpu-add-cycles! c cycles))

;; --- ISC/ISB (Increment then Subtract) ---
(define (exec-isc c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (u8 (+ (cpu-read c addr) 1)))
  (cpu-write c addr val)
  ;; Now do SBC with the incremented value
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
  (cpu-update-nz! c result)
  (cpu-add-cycles! c cycles))

;; --- SLO (ASL then ORA) ---
(define (exec-slo c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (cpu-read c addr))
  ;; ASL
  (if (bit? val 7)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (define shifted (u8 (arithmetic-shift val 1)))
  (cpu-write c addr shifted)
  ;; ORA
  (set-cpu-a! c (bitwise-ior (cpu-a c) shifted))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c cycles))

;; --- RLA (ROL then AND) ---
(define (exec-rla c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (cpu-read c addr))
  (define carry-in (if (cpu-flag? c flag-c) 1 0))
  ;; ROL
  (if (bit? val 7)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (define rotated (u8 (bitwise-ior (arithmetic-shift val 1) carry-in)))
  (cpu-write c addr rotated)
  ;; AND
  (set-cpu-a! c (bitwise-and (cpu-a c) rotated))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c cycles))

;; --- SRE (LSR then EOR) ---
(define (exec-sre c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (cpu-read c addr))
  ;; LSR
  (if (bit? val 0)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (define shifted (arithmetic-shift val -1))
  (cpu-write c addr shifted)
  ;; EOR
  (set-cpu-a! c (bitwise-xor (cpu-a c) shifted))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c cycles))

;; --- RRA (ROR then ADC) ---
(define (exec-rra c mode cycles)
  (define-values (addr _) (get-address c mode))
  (define val (cpu-read c addr))
  (define carry-in (if (cpu-flag? c flag-c) #x80 0))
  ;; ROR
  (if (bit? val 0)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (define rotated (bitwise-ior (arithmetic-shift val -1) carry-in))
  (cpu-write c addr rotated)
  ;; ADC with the rotated value
  (define a (cpu-a c))
  (define carry (if (cpu-flag? c flag-c) 1 0))
  (define sum (+ a rotated carry))
  (if (> sum #xFF)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (define result (u8 sum))
  (if (not (zero? (bitwise-and (bitwise-xor a result)
                               (bitwise-and (bitwise-xor rotated result) #x80))))
      (set-cpu-flag! c flag-v)
      (clear-cpu-flag! c flag-v))
  (set-cpu-a! c result)
  (cpu-update-nz! c result)
  (cpu-add-cycles! c cycles))

;; --- ANC/AAC (AND then copy N to C) ---
(define (exec-anc c)
  (define-values (val _) (read-operand c addr-immediate))
  (set-cpu-a! c (bitwise-and (cpu-a c) val))
  (cpu-update-nz! c (cpu-a c))
  ;; Copy N flag to C
  (if (cpu-flag? c flag-n)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (cpu-add-cycles! c 2))

;; --- ALR/ASR (AND then LSR A) ---
(define (exec-alr c)
  (define-values (val _) (read-operand c addr-immediate))
  (define result (bitwise-and (cpu-a c) val))
  (if (bit? result 0)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (set-cpu-a! c (arithmetic-shift result -1))
  (cpu-update-nz! c (cpu-a c))
  (cpu-add-cycles! c 2))

;; --- ARR (AND then ROR, with special flag behavior) ---
(define (exec-arr c)
  (define-values (val _) (read-operand c addr-immediate))
  (define and-result (bitwise-and (cpu-a c) val))
  ;; ROR with carry
  (define carry-in (if (cpu-flag? c flag-c) #x80 0))
  (define result (u8 (bitwise-ior (arithmetic-shift and-result -1) carry-in)))
  (set-cpu-a! c result)
  (cpu-update-nz! c result)
  ;; Special flag behavior: C = bit 6, V = bit 6 XOR bit 5
  (if (bit? result 6)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (if (not (= (if (bit? result 6) 1 0) (if (bit? result 5) 1 0)))
      (set-cpu-flag! c flag-v)
      (clear-cpu-flag! c flag-v))
  (cpu-add-cycles! c 2))

;; --- AXS/SBX (A AND X, then subtract immediate, store in X) ---
(define (exec-axs c)
  (define-values (val _) (read-operand c addr-immediate))
  (define ax (bitwise-and (cpu-a c) (cpu-x c)))
  (define result (- ax val))
  ;; C is set like CMP (no borrow if result >= 0)
  (if (>= result 0)
      (set-cpu-flag! c flag-c)
      (clear-cpu-flag! c flag-c))
  (set-cpu-x! c (u8 result))
  (cpu-update-nz! c (cpu-x c))
  (cpu-add-cycles! c 2))

;; --- ATX/LXA (AND immediate with A, then transfer to X) ---
;; Note: The AND value is actually (A | magic_constant) AND imm
;; where magic_constant varies by chip. On NES it appears to always
;; be $FF, so the operation is: A = X = (A | $FF) & imm = imm
;; Reference: https://forums.nesdev.org/viewtopic.php?t=3831
(define (exec-atx c)
  (define-values (val _) (read-operand c addr-immediate))
  ;; On NES: A is ORed with $FF first, making it $FF
  ;; Then AND with immediate = immediate value
  (define result (bitwise-and (bitwise-ior (cpu-a c) #xFF) val))
  (set-cpu-a! c result)
  (set-cpu-x! c result)
  (cpu-update-nz! c result)
  (cpu-add-cycles! c 2))

;; --- SHY/SYA (Store Y AND (high byte of addr + 1)) ---
(define (exec-shy c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 2)))
  (define lo-byte (cpu-read c pc))
  (define hi-byte (cpu-read c (u16 (+ pc 1))))
  (define addr (u16 (+ (merge16 lo-byte hi-byte) (cpu-x c))))
  (define result (bitwise-and (cpu-y c) (u8 (+ hi-byte 1))))
  ;; If page crossing, the address gets modified
  (define actual-addr
    (if (not (= hi-byte (hi addr)))
        (merge16 lo-byte result)  ; Page crossed: use result as high byte
        addr))
  (cpu-write c actual-addr result)
  (cpu-add-cycles! c 5))

;; --- SHX/SXA (Store X AND (high byte of addr + 1)) ---
(define (exec-shx c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 2)))
  (define lo (cpu-read c pc))
  (define hi-byte (cpu-read c (u16 (+ pc 1))))
  (define addr (u16 (+ (merge16 lo hi-byte) (cpu-y c))))
  (define result (bitwise-and (cpu-x c) (u8 (+ hi-byte 1))))
  ;; If page crossing, the address gets modified
  (define actual-addr
    (if (not (= hi-byte (hi addr)))
        (merge16 lo result)
        addr))
  (cpu-write c actual-addr result)
  (cpu-add-cycles! c 5))

;; --- AHX/SHA (Store A AND X AND (high byte of addr + 1)) ---
(define (exec-ahx-aby c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 2)))
  (define lo (cpu-read c pc))
  (define hi-byte (cpu-read c (u16 (+ pc 1))))
  (define addr (u16 (+ (merge16 lo hi-byte) (cpu-y c))))
  (define result (bitwise-and (cpu-a c) (bitwise-and (cpu-x c) (u8 (+ hi-byte 1)))))
  (define actual-addr
    (if (not (= hi-byte (hi addr)))
        (merge16 lo result)
        addr))
  (cpu-write c actual-addr result)
  (cpu-add-cycles! c 5))

(define (exec-ahx-izy c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 1)))
  (define ptr (cpu-read c pc))
  (define lo (cpu-read c ptr))
  (define hi-byte (cpu-read c (u8 (+ ptr 1))))
  (define addr (u16 (+ (merge16 lo hi-byte) (cpu-y c))))
  (define result (bitwise-and (cpu-a c) (bitwise-and (cpu-x c) (u8 (+ hi-byte 1)))))
  (define actual-addr
    (if (not (= hi-byte (hi addr)))
        (merge16 lo result)
        addr))
  (cpu-write c actual-addr result)
  (cpu-add-cycles! c 6))

;; --- TAS/XAS (Transfer A AND X to SP, then store SP AND (high byte + 1)) ---
(define (exec-tas c)
  (define pc (cpu-pc c))
  (set-cpu-pc! c (u16 (+ pc 2)))
  (define lo (cpu-read c pc))
  (define hi-byte (cpu-read c (u16 (+ pc 1))))
  (define addr (u16 (+ (merge16 lo hi-byte) (cpu-y c))))
  (set-cpu-sp! c (bitwise-and (cpu-a c) (cpu-x c)))
  (define result (bitwise-and (cpu-sp c) (u8 (+ hi-byte 1))))
  (define actual-addr
    (if (not (= hi-byte (hi addr)))
        (merge16 lo result)
        addr))
  (cpu-write c actual-addr result)
  (cpu-add-cycles! c 5))

;; --- LAS/LAR (Load A, X, and SP with (memory AND SP)) ---
(define (exec-las c)
  (define-values (val crossed?) (read-operand c addr-absolute-y))
  (define result (bitwise-and val (cpu-sp c)))
  (set-cpu-a! c result)
  (set-cpu-x! c result)
  (set-cpu-sp! c result)
  (cpu-update-nz! c result)
  (cpu-add-cycles! c (+ 4 (if crossed? 1 0))))

;; --- XAA/ANE (A = (A OR magic) AND X AND imm) ---
;; Highly unstable. Magic constant varies, commonly $EE or $00.
(define (exec-xaa c)
  (define-values (val _) (read-operand c addr-immediate))
  ;; Using $FF as magic (acts as: A = A AND X AND imm)
  (define result (bitwise-and (cpu-a c) (bitwise-and (cpu-x c) val)))
  (set-cpu-a! c result)
  (cpu-update-nz! c result)
  (cpu-add-cycles! c 2))

;; --- KIL/JAM/HLT (Halt CPU) ---
(define (exec-kil c)
  ;; Just error - the CPU should halt
  (error 'cpu "illegal opcode: KIL/JAM at $~a"
         (~r (- (cpu-pc c) 1) #:base 16 #:min-width 4 #:pad-string "0")))

;; ============================================================================
;; Opcode Table Population
;; ============================================================================

;; --- LDA ---
(register-opcode! #xA9 "LDA" 'imm 2 2 (λ (c) (exec-lda c addr-immediate 2)))
(register-opcode! #xA5 "LDA" 'zp 2 3 (λ (c) (exec-lda c addr-zero-page 3)))
(register-opcode! #xB5 "LDA" 'zpx 2 4 (λ (c) (exec-lda c addr-zero-page-x 4)))
(register-opcode! #xAD "LDA" 'abs 3 4 (λ (c) (exec-lda c addr-absolute 4)))
(register-opcode! #xBD "LDA" 'abx 3 4 (λ (c) (exec-lda c addr-absolute-x 4)))
(register-opcode! #xB9 "LDA" 'aby 3 4 (λ (c) (exec-lda c addr-absolute-y 4)))
(register-opcode! #xA1 "LDA" 'izx 2 6 (λ (c) (exec-lda c addr-indirect-x 6)))
(register-opcode! #xB1 "LDA" 'izy 2 5 (λ (c) (exec-lda c addr-indirect-y 5)))

;; --- LDX ---
(register-opcode! #xA2 "LDX" 'imm 2 2 (λ (c) (exec-ldx c addr-immediate 2)))
(register-opcode! #xA6 "LDX" 'zp 2 3 (λ (c) (exec-ldx c addr-zero-page 3)))
(register-opcode! #xB6 "LDX" 'zpy 2 4 (λ (c) (exec-ldx c addr-zero-page-y 4)))
(register-opcode! #xAE "LDX" 'abs 3 4 (λ (c) (exec-ldx c addr-absolute 4)))
(register-opcode! #xBE "LDX" 'aby 3 4 (λ (c) (exec-ldx c addr-absolute-y 4)))

;; --- LDY ---
(register-opcode! #xA0 "LDY" 'imm 2 2 (λ (c) (exec-ldy c addr-immediate 2)))
(register-opcode! #xA4 "LDY" 'zp 2 3 (λ (c) (exec-ldy c addr-zero-page 3)))
(register-opcode! #xB4 "LDY" 'zpx 2 4 (λ (c) (exec-ldy c addr-zero-page-x 4)))
(register-opcode! #xAC "LDY" 'abs 3 4 (λ (c) (exec-ldy c addr-absolute 4)))
(register-opcode! #xBC "LDY" 'abx 3 4 (λ (c) (exec-ldy c addr-absolute-x 4)))

;; --- STA ---
(register-opcode! #x85 "STA" 'zp 2 3 (λ (c) (exec-sta c addr-zero-page 3)))
(register-opcode! #x95 "STA" 'zpx 2 4 (λ (c) (exec-sta c addr-zero-page-x 4)))
(register-opcode! #x8D "STA" 'abs 3 4 (λ (c) (exec-sta c addr-absolute 4)))
(register-opcode! #x9D "STA" 'abx 3 5 (λ (c) (exec-sta c addr-absolute-x 5)))
(register-opcode! #x99 "STA" 'aby 3 5 (λ (c) (exec-sta c addr-absolute-y 5)))
(register-opcode! #x81 "STA" 'izx 2 6 (λ (c) (exec-sta c addr-indirect-x 6)))
(register-opcode! #x91 "STA" 'izy 2 6 (λ (c) (exec-sta c addr-indirect-y 6)))

;; --- STX ---
(register-opcode! #x86 "STX" 'zp 2 3 (λ (c) (exec-stx c addr-zero-page 3)))
(register-opcode! #x96 "STX" 'zpy 2 4 (λ (c) (exec-stx c addr-zero-page-y 4)))
(register-opcode! #x8E "STX" 'abs 3 4 (λ (c) (exec-stx c addr-absolute 4)))

;; --- STY ---
(register-opcode! #x84 "STY" 'zp 2 3 (λ (c) (exec-sty c addr-zero-page 3)))
(register-opcode! #x94 "STY" 'zpx 2 4 (λ (c) (exec-sty c addr-zero-page-x 4)))
(register-opcode! #x8C "STY" 'abs 3 4 (λ (c) (exec-sty c addr-absolute 4)))

;; --- Transfers ---
(register-opcode! #xAA "TAX" 'imp 1 2 (λ (c) (exec-tax c)))
(register-opcode! #xA8 "TAY" 'imp 1 2 (λ (c) (exec-tay c)))
(register-opcode! #x8A "TXA" 'imp 1 2 (λ (c) (exec-txa c)))
(register-opcode! #x98 "TYA" 'imp 1 2 (λ (c) (exec-tya c)))
(register-opcode! #xBA "TSX" 'imp 1 2 (λ (c) (exec-tsx c)))
(register-opcode! #x9A "TXS" 'imp 1 2 (λ (c) (exec-txs c)))

;; --- Stack ---
(register-opcode! #x48 "PHA" 'imp 1 3 (λ (c) (exec-pha c)))
(register-opcode! #x08 "PHP" 'imp 1 3 (λ (c) (exec-php c)))
(register-opcode! #x68 "PLA" 'imp 1 4 (λ (c) (exec-pla c)))
(register-opcode! #x28 "PLP" 'imp 1 4 (λ (c) (exec-plp c)))

;; --- ADC ---
(register-opcode! #x69 "ADC" 'imm 2 2 (λ (c) (exec-adc c addr-immediate 2)))
(register-opcode! #x65 "ADC" 'zp 2 3 (λ (c) (exec-adc c addr-zero-page 3)))
(register-opcode! #x75 "ADC" 'zpx 2 4 (λ (c) (exec-adc c addr-zero-page-x 4)))
(register-opcode! #x6D "ADC" 'abs 3 4 (λ (c) (exec-adc c addr-absolute 4)))
(register-opcode! #x7D "ADC" 'abx 3 4 (λ (c) (exec-adc c addr-absolute-x 4)))
(register-opcode! #x79 "ADC" 'aby 3 4 (λ (c) (exec-adc c addr-absolute-y 4)))
(register-opcode! #x61 "ADC" 'izx 2 6 (λ (c) (exec-adc c addr-indirect-x 6)))
(register-opcode! #x71 "ADC" 'izy 2 5 (λ (c) (exec-adc c addr-indirect-y 5)))

;; --- SBC ---
(register-opcode! #xE9 "SBC" 'imm 2 2 (λ (c) (exec-sbc c addr-immediate 2)))
(register-opcode! #xE5 "SBC" 'zp 2 3 (λ (c) (exec-sbc c addr-zero-page 3)))
(register-opcode! #xF5 "SBC" 'zpx 2 4 (λ (c) (exec-sbc c addr-zero-page-x 4)))
(register-opcode! #xED "SBC" 'abs 3 4 (λ (c) (exec-sbc c addr-absolute 4)))
(register-opcode! #xFD "SBC" 'abx 3 4 (λ (c) (exec-sbc c addr-absolute-x 4)))
(register-opcode! #xF9 "SBC" 'aby 3 4 (λ (c) (exec-sbc c addr-absolute-y 4)))
(register-opcode! #xE1 "SBC" 'izx 2 6 (λ (c) (exec-sbc c addr-indirect-x 6)))
(register-opcode! #xF1 "SBC" 'izy 2 5 (λ (c) (exec-sbc c addr-indirect-y 5)))

;; --- CMP ---
(register-opcode! #xC9 "CMP" 'imm 2 2 (λ (c) (exec-cmp c addr-immediate 2)))
(register-opcode! #xC5 "CMP" 'zp 2 3 (λ (c) (exec-cmp c addr-zero-page 3)))
(register-opcode! #xD5 "CMP" 'zpx 2 4 (λ (c) (exec-cmp c addr-zero-page-x 4)))
(register-opcode! #xCD "CMP" 'abs 3 4 (λ (c) (exec-cmp c addr-absolute 4)))
(register-opcode! #xDD "CMP" 'abx 3 4 (λ (c) (exec-cmp c addr-absolute-x 4)))
(register-opcode! #xD9 "CMP" 'aby 3 4 (λ (c) (exec-cmp c addr-absolute-y 4)))
(register-opcode! #xC1 "CMP" 'izx 2 6 (λ (c) (exec-cmp c addr-indirect-x 6)))
(register-opcode! #xD1 "CMP" 'izy 2 5 (λ (c) (exec-cmp c addr-indirect-y 5)))

;; --- CPX ---
(register-opcode! #xE0 "CPX" 'imm 2 2 (λ (c) (exec-cpx c addr-immediate 2)))
(register-opcode! #xE4 "CPX" 'zp 2 3 (λ (c) (exec-cpx c addr-zero-page 3)))
(register-opcode! #xEC "CPX" 'abs 3 4 (λ (c) (exec-cpx c addr-absolute 4)))

;; --- CPY ---
(register-opcode! #xC0 "CPY" 'imm 2 2 (λ (c) (exec-cpy c addr-immediate 2)))
(register-opcode! #xC4 "CPY" 'zp 2 3 (λ (c) (exec-cpy c addr-zero-page 3)))
(register-opcode! #xCC "CPY" 'abs 3 4 (λ (c) (exec-cpy c addr-absolute 4)))

;; --- INC ---
(register-opcode! #xE6 "INC" 'zp 2 5 (λ (c) (exec-inc c addr-zero-page 5)))
(register-opcode! #xF6 "INC" 'zpx 2 6 (λ (c) (exec-inc c addr-zero-page-x 6)))
(register-opcode! #xEE "INC" 'abs 3 6 (λ (c) (exec-inc c addr-absolute 6)))
(register-opcode! #xFE "INC" 'abx 3 7 (λ (c) (exec-inc c addr-absolute-x 7)))

;; --- DEC ---
(register-opcode! #xC6 "DEC" 'zp 2 5 (λ (c) (exec-dec c addr-zero-page 5)))
(register-opcode! #xD6 "DEC" 'zpx 2 6 (λ (c) (exec-dec c addr-zero-page-x 6)))
(register-opcode! #xCE "DEC" 'abs 3 6 (λ (c) (exec-dec c addr-absolute 6)))
(register-opcode! #xDE "DEC" 'abx 3 7 (λ (c) (exec-dec c addr-absolute-x 7)))

;; --- INX/INY/DEX/DEY ---
(register-opcode! #xE8 "INX" 'imp 1 2 (λ (c) (exec-inx c)))
(register-opcode! #xC8 "INY" 'imp 1 2 (λ (c) (exec-iny c)))
(register-opcode! #xCA "DEX" 'imp 1 2 (λ (c) (exec-dex c)))
(register-opcode! #x88 "DEY" 'imp 1 2 (λ (c) (exec-dey c)))

;; --- AND ---
(register-opcode! #x29 "AND" 'imm 2 2 (λ (c) (exec-and c addr-immediate 2)))
(register-opcode! #x25 "AND" 'zp 2 3 (λ (c) (exec-and c addr-zero-page 3)))
(register-opcode! #x35 "AND" 'zpx 2 4 (λ (c) (exec-and c addr-zero-page-x 4)))
(register-opcode! #x2D "AND" 'abs 3 4 (λ (c) (exec-and c addr-absolute 4)))
(register-opcode! #x3D "AND" 'abx 3 4 (λ (c) (exec-and c addr-absolute-x 4)))
(register-opcode! #x39 "AND" 'aby 3 4 (λ (c) (exec-and c addr-absolute-y 4)))
(register-opcode! #x21 "AND" 'izx 2 6 (λ (c) (exec-and c addr-indirect-x 6)))
(register-opcode! #x31 "AND" 'izy 2 5 (λ (c) (exec-and c addr-indirect-y 5)))

;; --- ORA ---
(register-opcode! #x09 "ORA" 'imm 2 2 (λ (c) (exec-ora c addr-immediate 2)))
(register-opcode! #x05 "ORA" 'zp 2 3 (λ (c) (exec-ora c addr-zero-page 3)))
(register-opcode! #x15 "ORA" 'zpx 2 4 (λ (c) (exec-ora c addr-zero-page-x 4)))
(register-opcode! #x0D "ORA" 'abs 3 4 (λ (c) (exec-ora c addr-absolute 4)))
(register-opcode! #x1D "ORA" 'abx 3 4 (λ (c) (exec-ora c addr-absolute-x 4)))
(register-opcode! #x19 "ORA" 'aby 3 4 (λ (c) (exec-ora c addr-absolute-y 4)))
(register-opcode! #x01 "ORA" 'izx 2 6 (λ (c) (exec-ora c addr-indirect-x 6)))
(register-opcode! #x11 "ORA" 'izy 2 5 (λ (c) (exec-ora c addr-indirect-y 5)))

;; --- EOR ---
(register-opcode! #x49 "EOR" 'imm 2 2 (λ (c) (exec-eor c addr-immediate 2)))
(register-opcode! #x45 "EOR" 'zp 2 3 (λ (c) (exec-eor c addr-zero-page 3)))
(register-opcode! #x55 "EOR" 'zpx 2 4 (λ (c) (exec-eor c addr-zero-page-x 4)))
(register-opcode! #x4D "EOR" 'abs 3 4 (λ (c) (exec-eor c addr-absolute 4)))
(register-opcode! #x5D "EOR" 'abx 3 4 (λ (c) (exec-eor c addr-absolute-x 4)))
(register-opcode! #x59 "EOR" 'aby 3 4 (λ (c) (exec-eor c addr-absolute-y 4)))
(register-opcode! #x41 "EOR" 'izx 2 6 (λ (c) (exec-eor c addr-indirect-x 6)))
(register-opcode! #x51 "EOR" 'izy 2 5 (λ (c) (exec-eor c addr-indirect-y 5)))

;; --- BIT ---
(register-opcode! #x24 "BIT" 'zp 2 3 (λ (c) (exec-bit c addr-zero-page 3)))
(register-opcode! #x2C "BIT" 'abs 3 4 (λ (c) (exec-bit c addr-absolute 4)))

;; --- ASL ---
(register-opcode! #x0A "ASL" 'acc 1 2 (λ (c) (exec-asl-a c)))
(register-opcode! #x06 "ASL" 'zp 2 5 (λ (c) (exec-asl c addr-zero-page 5)))
(register-opcode! #x16 "ASL" 'zpx 2 6 (λ (c) (exec-asl c addr-zero-page-x 6)))
(register-opcode! #x0E "ASL" 'abs 3 6 (λ (c) (exec-asl c addr-absolute 6)))
(register-opcode! #x1E "ASL" 'abx 3 7 (λ (c) (exec-asl c addr-absolute-x 7)))

;; --- LSR ---
(register-opcode! #x4A "LSR" 'acc 1 2 (λ (c) (exec-lsr-a c)))
(register-opcode! #x46 "LSR" 'zp 2 5 (λ (c) (exec-lsr c addr-zero-page 5)))
(register-opcode! #x56 "LSR" 'zpx 2 6 (λ (c) (exec-lsr c addr-zero-page-x 6)))
(register-opcode! #x4E "LSR" 'abs 3 6 (λ (c) (exec-lsr c addr-absolute 6)))
(register-opcode! #x5E "LSR" 'abx 3 7 (λ (c) (exec-lsr c addr-absolute-x 7)))

;; --- ROL ---
(register-opcode! #x2A "ROL" 'acc 1 2 (λ (c) (exec-rol-a c)))
(register-opcode! #x26 "ROL" 'zp 2 5 (λ (c) (exec-rol c addr-zero-page 5)))
(register-opcode! #x36 "ROL" 'zpx 2 6 (λ (c) (exec-rol c addr-zero-page-x 6)))
(register-opcode! #x2E "ROL" 'abs 3 6 (λ (c) (exec-rol c addr-absolute 6)))
(register-opcode! #x3E "ROL" 'abx 3 7 (λ (c) (exec-rol c addr-absolute-x 7)))

;; --- ROR ---
(register-opcode! #x6A "ROR" 'acc 1 2 (λ (c) (exec-ror-a c)))
(register-opcode! #x66 "ROR" 'zp 2 5 (λ (c) (exec-ror c addr-zero-page 5)))
(register-opcode! #x76 "ROR" 'zpx 2 6 (λ (c) (exec-ror c addr-zero-page-x 6)))
(register-opcode! #x6E "ROR" 'abs 3 6 (λ (c) (exec-ror c addr-absolute 6)))
(register-opcode! #x7E "ROR" 'abx 3 7 (λ (c) (exec-ror c addr-absolute-x 7)))

;; --- Branches ---
(register-opcode! #x10 "BPL" 'rel 2 2 (λ (c) (exec-bpl c)))
(register-opcode! #x30 "BMI" 'rel 2 2 (λ (c) (exec-bmi c)))
(register-opcode! #x50 "BVC" 'rel 2 2 (λ (c) (exec-bvc c)))
(register-opcode! #x70 "BVS" 'rel 2 2 (λ (c) (exec-bvs c)))
(register-opcode! #x90 "BCC" 'rel 2 2 (λ (c) (exec-bcc c)))
(register-opcode! #xB0 "BCS" 'rel 2 2 (λ (c) (exec-bcs c)))
(register-opcode! #xD0 "BNE" 'rel 2 2 (λ (c) (exec-bne c)))
(register-opcode! #xF0 "BEQ" 'rel 2 2 (λ (c) (exec-beq c)))

;; --- JMP ---
(register-opcode! #x4C "JMP" 'abs 3 3 (λ (c) (exec-jmp c addr-absolute)))
(register-opcode! #x6C "JMP" 'ind 3 5 (λ (c) (exec-jmp-ind c)))

;; --- JSR/RTS/RTI ---
(register-opcode! #x20 "JSR" 'abs 3 6 (λ (c) (exec-jsr c)))
(register-opcode! #x60 "RTS" 'imp 1 6 (λ (c) (exec-rts c)))
(register-opcode! #x40 "RTI" 'imp 1 6 (λ (c) (exec-rti c)))

;; --- Flags ---
(register-opcode! #x18 "CLC" 'imp 1 2 (λ (c) (exec-clc c)))
(register-opcode! #x38 "SEC" 'imp 1 2 (λ (c) (exec-sec c)))
(register-opcode! #x58 "CLI" 'imp 1 2 (λ (c) (exec-cli c)))
(register-opcode! #x78 "SEI" 'imp 1 2 (λ (c) (exec-sei c)))
(register-opcode! #xB8 "CLV" 'imp 1 2 (λ (c) (exec-clv c)))
(register-opcode! #xD8 "CLD" 'imp 1 2 (λ (c) (exec-cld c)))
(register-opcode! #xF8 "SED" 'imp 1 2 (λ (c) (exec-sed c)))

;; --- NOP ---
(register-opcode! #xEA "NOP" 'imp 1 2 (λ (c) (exec-nop c)))

;; --- BRK ---
(register-opcode! #x00 "BRK" 'imp 1 7 (λ (c) (exec-brk c)))

;; ============================================================================
;; Illegal Opcode Table Population
;; ============================================================================

;; --- Illegal NOPs (1-byte, implied) ---
(register-opcode! #x1A "*NOP" 'imp 1 2 (λ (c) (exec-nop-illegal c)))
(register-opcode! #x3A "*NOP" 'imp 1 2 (λ (c) (exec-nop-illegal c)))
(register-opcode! #x5A "*NOP" 'imp 1 2 (λ (c) (exec-nop-illegal c)))
(register-opcode! #x7A "*NOP" 'imp 1 2 (λ (c) (exec-nop-illegal c)))
(register-opcode! #xDA "*NOP" 'imp 1 2 (λ (c) (exec-nop-illegal c)))
(register-opcode! #xFA "*NOP" 'imp 1 2 (λ (c) (exec-nop-illegal c)))

;; --- DOP (Double NOP / 2-byte NOP) ---
;; Immediate mode
(register-opcode! #x80 "*NOP" 'imm 2 2 (λ (c) (exec-dop-imm c)))
(register-opcode! #x82 "*NOP" 'imm 2 2 (λ (c) (exec-dop-imm c)))
(register-opcode! #x89 "*NOP" 'imm 2 2 (λ (c) (exec-dop-imm c)))
(register-opcode! #xC2 "*NOP" 'imm 2 2 (λ (c) (exec-dop-imm c)))
(register-opcode! #xE2 "*NOP" 'imm 2 2 (λ (c) (exec-dop-imm c)))
;; Zero page mode
(register-opcode! #x04 "*NOP" 'zp 2 3 (λ (c) (exec-dop-zp c)))
(register-opcode! #x44 "*NOP" 'zp 2 3 (λ (c) (exec-dop-zp c)))
(register-opcode! #x64 "*NOP" 'zp 2 3 (λ (c) (exec-dop-zp c)))
;; Zero page,X mode
(register-opcode! #x14 "*NOP" 'zpx 2 4 (λ (c) (exec-dop-zpx c)))
(register-opcode! #x34 "*NOP" 'zpx 2 4 (λ (c) (exec-dop-zpx c)))
(register-opcode! #x54 "*NOP" 'zpx 2 4 (λ (c) (exec-dop-zpx c)))
(register-opcode! #x74 "*NOP" 'zpx 2 4 (λ (c) (exec-dop-zpx c)))
(register-opcode! #xD4 "*NOP" 'zpx 2 4 (λ (c) (exec-dop-zpx c)))
(register-opcode! #xF4 "*NOP" 'zpx 2 4 (λ (c) (exec-dop-zpx c)))

;; --- TOP (Triple NOP / 3-byte NOP) ---
(register-opcode! #x0C "*NOP" 'abs 3 4 (λ (c) (exec-top-abs c)))
(register-opcode! #x1C "*NOP" 'abx 3 4 (λ (c) (exec-top-abx c)))
(register-opcode! #x3C "*NOP" 'abx 3 4 (λ (c) (exec-top-abx c)))
(register-opcode! #x5C "*NOP" 'abx 3 4 (λ (c) (exec-top-abx c)))
(register-opcode! #x7C "*NOP" 'abx 3 4 (λ (c) (exec-top-abx c)))
(register-opcode! #xDC "*NOP" 'abx 3 4 (λ (c) (exec-top-abx c)))
(register-opcode! #xFC "*NOP" 'abx 3 4 (λ (c) (exec-top-abx c)))

;; --- LAX (Load A and X) ---
(register-opcode! #xA7 "*LAX" 'zp 2 3 (λ (c) (exec-lax c addr-zero-page 3)))
(register-opcode! #xB7 "*LAX" 'zpy 2 4 (λ (c) (exec-lax c addr-zero-page-y 4)))
(register-opcode! #xAF "*LAX" 'abs 3 4 (λ (c) (exec-lax c addr-absolute 4)))
(register-opcode! #xBF "*LAX" 'aby 3 4 (λ (c) (exec-lax c addr-absolute-y 4)))
(register-opcode! #xA3 "*LAX" 'izx 2 6 (λ (c) (exec-lax c addr-indirect-x 6)))
(register-opcode! #xB3 "*LAX" 'izy 2 5 (λ (c) (exec-lax c addr-indirect-y 5)))

;; --- SAX (Store A AND X) ---
(register-opcode! #x87 "*SAX" 'zp 2 3 (λ (c) (exec-sax c addr-zero-page 3)))
(register-opcode! #x97 "*SAX" 'zpy 2 4 (λ (c) (exec-sax c addr-zero-page-y 4)))
(register-opcode! #x8F "*SAX" 'abs 3 4 (λ (c) (exec-sax c addr-absolute 4)))
(register-opcode! #x83 "*SAX" 'izx 2 6 (λ (c) (exec-sax c addr-indirect-x 6)))

;; --- DCP (Decrement then Compare) ---
(register-opcode! #xC7 "*DCP" 'zp 2 5 (λ (c) (exec-dcp c addr-zero-page 5)))
(register-opcode! #xD7 "*DCP" 'zpx 2 6 (λ (c) (exec-dcp c addr-zero-page-x 6)))
(register-opcode! #xCF "*DCP" 'abs 3 6 (λ (c) (exec-dcp c addr-absolute 6)))
(register-opcode! #xDF "*DCP" 'abx 3 7 (λ (c) (exec-dcp c addr-absolute-x 7)))
(register-opcode! #xDB "*DCP" 'aby 3 7 (λ (c) (exec-dcp c addr-absolute-y 7)))
(register-opcode! #xC3 "*DCP" 'izx 2 8 (λ (c) (exec-dcp c addr-indirect-x 8)))
(register-opcode! #xD3 "*DCP" 'izy 2 8 (λ (c) (exec-dcp c addr-indirect-y 8)))

;; --- ISC/ISB (Increment then Subtract) ---
(register-opcode! #xE7 "*ISC" 'zp 2 5 (λ (c) (exec-isc c addr-zero-page 5)))
(register-opcode! #xF7 "*ISC" 'zpx 2 6 (λ (c) (exec-isc c addr-zero-page-x 6)))
(register-opcode! #xEF "*ISC" 'abs 3 6 (λ (c) (exec-isc c addr-absolute 6)))
(register-opcode! #xFF "*ISC" 'abx 3 7 (λ (c) (exec-isc c addr-absolute-x 7)))
(register-opcode! #xFB "*ISC" 'aby 3 7 (λ (c) (exec-isc c addr-absolute-y 7)))
(register-opcode! #xE3 "*ISC" 'izx 2 8 (λ (c) (exec-isc c addr-indirect-x 8)))
(register-opcode! #xF3 "*ISC" 'izy 2 8 (λ (c) (exec-isc c addr-indirect-y 8)))

;; --- SLO (ASL then ORA) ---
(register-opcode! #x07 "*SLO" 'zp 2 5 (λ (c) (exec-slo c addr-zero-page 5)))
(register-opcode! #x17 "*SLO" 'zpx 2 6 (λ (c) (exec-slo c addr-zero-page-x 6)))
(register-opcode! #x0F "*SLO" 'abs 3 6 (λ (c) (exec-slo c addr-absolute 6)))
(register-opcode! #x1F "*SLO" 'abx 3 7 (λ (c) (exec-slo c addr-absolute-x 7)))
(register-opcode! #x1B "*SLO" 'aby 3 7 (λ (c) (exec-slo c addr-absolute-y 7)))
(register-opcode! #x03 "*SLO" 'izx 2 8 (λ (c) (exec-slo c addr-indirect-x 8)))
(register-opcode! #x13 "*SLO" 'izy 2 8 (λ (c) (exec-slo c addr-indirect-y 8)))

;; --- RLA (ROL then AND) ---
(register-opcode! #x27 "*RLA" 'zp 2 5 (λ (c) (exec-rla c addr-zero-page 5)))
(register-opcode! #x37 "*RLA" 'zpx 2 6 (λ (c) (exec-rla c addr-zero-page-x 6)))
(register-opcode! #x2F "*RLA" 'abs 3 6 (λ (c) (exec-rla c addr-absolute 6)))
(register-opcode! #x3F "*RLA" 'abx 3 7 (λ (c) (exec-rla c addr-absolute-x 7)))
(register-opcode! #x3B "*RLA" 'aby 3 7 (λ (c) (exec-rla c addr-absolute-y 7)))
(register-opcode! #x23 "*RLA" 'izx 2 8 (λ (c) (exec-rla c addr-indirect-x 8)))
(register-opcode! #x33 "*RLA" 'izy 2 8 (λ (c) (exec-rla c addr-indirect-y 8)))

;; --- SRE (LSR then EOR) ---
(register-opcode! #x47 "*SRE" 'zp 2 5 (λ (c) (exec-sre c addr-zero-page 5)))
(register-opcode! #x57 "*SRE" 'zpx 2 6 (λ (c) (exec-sre c addr-zero-page-x 6)))
(register-opcode! #x4F "*SRE" 'abs 3 6 (λ (c) (exec-sre c addr-absolute 6)))
(register-opcode! #x5F "*SRE" 'abx 3 7 (λ (c) (exec-sre c addr-absolute-x 7)))
(register-opcode! #x5B "*SRE" 'aby 3 7 (λ (c) (exec-sre c addr-absolute-y 7)))
(register-opcode! #x43 "*SRE" 'izx 2 8 (λ (c) (exec-sre c addr-indirect-x 8)))
(register-opcode! #x53 "*SRE" 'izy 2 8 (λ (c) (exec-sre c addr-indirect-y 8)))

;; --- RRA (ROR then ADC) ---
(register-opcode! #x67 "*RRA" 'zp 2 5 (λ (c) (exec-rra c addr-zero-page 5)))
(register-opcode! #x77 "*RRA" 'zpx 2 6 (λ (c) (exec-rra c addr-zero-page-x 6)))
(register-opcode! #x6F "*RRA" 'abs 3 6 (λ (c) (exec-rra c addr-absolute 6)))
(register-opcode! #x7F "*RRA" 'abx 3 7 (λ (c) (exec-rra c addr-absolute-x 7)))
(register-opcode! #x7B "*RRA" 'aby 3 7 (λ (c) (exec-rra c addr-absolute-y 7)))
(register-opcode! #x63 "*RRA" 'izx 2 8 (λ (c) (exec-rra c addr-indirect-x 8)))
(register-opcode! #x73 "*RRA" 'izy 2 8 (λ (c) (exec-rra c addr-indirect-y 8)))

;; --- ANC (AND then copy N to C) ---
(register-opcode! #x0B "*ANC" 'imm 2 2 (λ (c) (exec-anc c)))
(register-opcode! #x2B "*ANC" 'imm 2 2 (λ (c) (exec-anc c)))

;; --- ALR (AND then LSR A) ---
(register-opcode! #x4B "*ALR" 'imm 2 2 (λ (c) (exec-alr c)))

;; --- ARR (AND then ROR with special flags) ---
(register-opcode! #x6B "*ARR" 'imm 2 2 (λ (c) (exec-arr c)))

;; --- AXS (A AND X, subtract immediate, store in X) ---
(register-opcode! #xCB "*AXS" 'imm 2 2 (λ (c) (exec-axs c)))

;; --- ATX/LXA (AND then transfer to X) ---
(register-opcode! #xAB "*ATX" 'imm 2 2 (λ (c) (exec-atx c)))

;; --- SHY (Store Y AND (high byte + 1)) ---
(register-opcode! #x9C "*SHY" 'abx 3 5 (λ (c) (exec-shy c)))

;; --- SHX (Store X AND (high byte + 1)) ---
(register-opcode! #x9E "*SHX" 'aby 3 5 (λ (c) (exec-shx c)))

;; --- AHX (Store A AND X AND (high byte + 1)) ---
(register-opcode! #x9F "*AHX" 'aby 3 5 (λ (c) (exec-ahx-aby c)))
(register-opcode! #x93 "*AHX" 'izy 2 6 (λ (c) (exec-ahx-izy c)))

;; --- TAS (Transfer A AND X to SP, store AND with high byte) ---
(register-opcode! #x9B "*TAS" 'aby 3 5 (λ (c) (exec-tas c)))

;; --- LAS (Load A, X, SP with memory AND SP) ---
(register-opcode! #xBB "*LAS" 'aby 3 4 (λ (c) (exec-las c)))

;; --- XAA (Unstable: A = (A OR magic) AND X AND imm) ---
(register-opcode! #x8B "*XAA" 'imm 2 2 (λ (c) (exec-xaa c)))

;; --- Unofficial SBC (identical to $E9) ---
(register-opcode! #xEB "*SBC" 'imm 2 2 (λ (c) (exec-sbc c addr-immediate 2)))

;; --- KIL/JAM/HLT (Halt CPU - various opcodes) ---
(register-opcode! #x02 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))
(register-opcode! #x12 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))
(register-opcode! #x22 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))
(register-opcode! #x32 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))
(register-opcode! #x42 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))
(register-opcode! #x52 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))
(register-opcode! #x62 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))
(register-opcode! #x72 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))
(register-opcode! #x92 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))
(register-opcode! #xB2 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))
(register-opcode! #xD2 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))
(register-opcode! #xF2 "*KIL" 'imp 1 2 (λ (c) (exec-kil c)))

;; ============================================================================
;; Executor Installation
;; ============================================================================

;; The main opcode executor - fetches and executes one instruction
(define (execute-one-opcode c)
  (define opcode (cpu-read c (cpu-pc c)))
  (set-cpu-pc! c (u16 (+ (cpu-pc c) 1)))
  (define info (vector-ref opcode-table opcode))
  (if info
      ((opcode-info-executor info) c)
      (error 'execute "illegal opcode: $~a at $~a"
             (~r opcode #:base 16 #:min-width 2 #:pad-string "0")
             (~r (- (cpu-pc c) 1) #:base 16 #:min-width 4 #:pad-string "0"))))

(require racket/format)

;; Install the executor so cpu-step! can use it
(define (install-opcode-executor!)
  (cpu-execute-opcode execute-one-opcode))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit
           "../bus.rkt")

  ;; Install executor for tests
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

  (test-case "LDA immediate"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xA9)  ; LDA #$42
    (bytes-set! ram #x0001 #x42)
    (set-cpu-pc! c #x0000)
    (cpu-step! c)
    (check-equal? (cpu-a c) #x42)
    (check-equal? (cpu-pc c) #x0002)
    (check-equal? (cpu-cycles c) 2))

  (test-case "LDA sets N flag"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xA9)
    (bytes-set! ram #x0001 #x80)
    (set-cpu-pc! c #x0000)
    (cpu-step! c)
    (check-true (cpu-flag? c flag-n)))

  (test-case "LDA sets Z flag"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xA9)
    (bytes-set! ram #x0001 #x00)
    (set-cpu-pc! c #x0000)
    (cpu-step! c)
    (check-true (cpu-flag? c flag-z)))

  (test-case "STA zero-page"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x85)  ; STA $10
    (bytes-set! ram #x0001 #x10)
    (set-cpu-pc! c #x0000)
    (set-cpu-a! c #x42)
    (cpu-step! c)
    (check-equal? (bytes-ref ram #x10) #x42))

  (test-case "ADC basic"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x69)  ; ADC #$10
    (bytes-set! ram #x0001 #x10)
    (set-cpu-pc! c #x0000)
    (set-cpu-a! c #x20)
    (clear-cpu-flag! c flag-c)
    (cpu-step! c)
    (check-equal? (cpu-a c) #x30)
    (check-false (cpu-flag? c flag-c)))

  (test-case "ADC with carry in"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x69)
    (bytes-set! ram #x0001 #x10)
    (set-cpu-pc! c #x0000)
    (set-cpu-a! c #x20)
    (set-cpu-flag! c flag-c)
    (cpu-step! c)
    (check-equal? (cpu-a c) #x31))

  (test-case "ADC overflow"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x69)
    (bytes-set! ram #x0001 #xFF)
    (set-cpu-pc! c #x0000)
    (set-cpu-a! c #x01)
    (clear-cpu-flag! c flag-c)
    (cpu-step! c)
    (check-equal? (cpu-a c) #x00)
    (check-true (cpu-flag? c flag-c))
    (check-true (cpu-flag? c flag-z)))

  (test-case "JMP absolute"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #x4C)  ; JMP $1234
    (bytes-set! ram #x0001 #x34)
    (bytes-set! ram #x0002 #x12)
    (set-cpu-pc! c #x0000)
    (cpu-step! c)
    (check-equal? (cpu-pc c) #x1234))

  (test-case "JSR and RTS"
    (define-values (c ram) (make-test-cpu))
    ;; JSR $1000
    (bytes-set! ram #x0000 #x20)
    (bytes-set! ram #x0001 #x00)
    (bytes-set! ram #x0002 #x10)
    ;; RTS at $1000
    (bytes-set! ram #x1000 #x60)
    (set-cpu-pc! c #x0000)
    (set-cpu-sp! c #xFF)
    (cpu-step! c)  ; JSR
    (check-equal? (cpu-pc c) #x1000)
    (cpu-step! c)  ; RTS
    (check-equal? (cpu-pc c) #x0003))

  (test-case "branch taken adds cycles"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xD0)  ; BNE +$02
    (bytes-set! ram #x0001 #x02)
    (set-cpu-pc! c #x0000)
    (clear-cpu-flag! c flag-z)  ; Z clear, so branch taken
    (cpu-step! c)
    (check-equal? (cpu-pc c) #x0004)
    (check-equal? (cpu-cycles c) 3))  ; 2 base + 1 for taken

  (test-case "branch not taken"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #x0000 #xD0)  ; BNE +$02
    (bytes-set! ram #x0001 #x02)
    (set-cpu-pc! c #x0000)
    (set-cpu-flag! c flag-z)  ; Z set, so branch not taken
    (cpu-step! c)
    (check-equal? (cpu-pc c) #x0002)
    (check-equal? (cpu-cycles c) 2)))
