#lang racket/base

;; 6502 Disassembler
;;
;; Provides instruction disassembly and trace output in nestest format.
;;
;; Trace format example:
;; C000  4C F5 C5  JMP $C5F5                       A:00 X:00 Y:00 P:24 SP:FD CYC:7

(provide
 ;; Disassembly
 disasm-instruction
 disasm-at

 ;; Trace output
 trace-line)

(require "cpu.rkt"
         "opcodes.rkt"
         "../bits.rkt"
         "../bus.rkt"
         racket/format
         racket/string)

;; ============================================================================
;; Disassembly Helpers
;; ============================================================================

;; Format a byte as 2-digit hex (uppercase)
(define (hex2 n)
  (string-upcase (~r n #:base 16 #:min-width 2 #:pad-string "0")))

;; Format a word as 4-digit hex (uppercase)
(define (hex4 n)
  (string-upcase (~r n #:base 16 #:min-width 4 #:pad-string "0")))

;; Read a byte from memory without side effects
;; (For disasm we want to peek, not modify open bus)
(define (peek c addr)
  (bus-read (cpu-bus c) addr))

;; Get the cpu's bus
(define (cpu-bus c)
  ;; Access the bus field from cpu struct
  ;; cpu struct is: (cpu a-box x-box y-box sp-box pc-box p-box cycles-box nmi-box irq-box bus openbus-box)
  (define fields (struct->vector c))
  (vector-ref fields 10))

;; ============================================================================
;; Instruction Disassembly
;; ============================================================================

;; Disassemble an instruction at the given address
;; Returns: (values mnemonic operand-string byte-count)
(define (disasm-at c addr)
  (define opcode (peek c addr))
  (define info (vector-ref opcode-table opcode))

  (if (not info)
      ;; Illegal opcode
      (values "???" "" 1)
      ;; Valid opcode
      (let* ([name (opcode-info-name info)]
             [mode (opcode-info-mode info)]
             [bytes (opcode-info-bytes info)])
        (define operand-str
          (case mode
            [(imp) ""]
            [(acc) "A"]
            [(imm)
             (format "#$~a" (hex2 (peek c (+ addr 1))))]
            [(zp)
             (format "$~a" (hex2 (peek c (+ addr 1))))]
            [(zpx)
             (format "$~a,X" (hex2 (peek c (+ addr 1))))]
            [(zpy)
             (format "$~a,Y" (hex2 (peek c (+ addr 1))))]
            [(abs ind)
             (let* ([lo (peek c (+ addr 1))]
                    [hi (peek c (+ addr 2))]
                    [target (merge16 lo hi)])
               (if (eq? mode 'ind)
                   (format "($~a)" (hex4 target))
                   (format "$~a" (hex4 target))))]
            [(abx)
             (let* ([lo (peek c (+ addr 1))]
                    [hi (peek c (+ addr 2))]
                    [target (merge16 lo hi)])
               (format "$~a,X" (hex4 target)))]
            [(aby)
             (let* ([lo (peek c (+ addr 1))]
                    [hi (peek c (+ addr 2))]
                    [target (merge16 lo hi)])
               (format "$~a,Y" (hex4 target)))]
            [(izx)
             (format "($~a,X)" (hex2 (peek c (+ addr 1))))]
            [(izy)
             (format "($~a),Y" (hex2 (peek c (+ addr 1))))]
            [(rel)
             (let* ([offset (u8->s8 (peek c (+ addr 1)))]
                    [target (u16 (+ addr 2 offset))])
               (format "$~a" (hex4 target)))]
            [else ""]))
        (values name operand-str bytes))))

;; Disassemble an instruction and return formatted string
(define (disasm-instruction c addr)
  (define-values (name operand bytes) (disasm-at c addr))
  (if (string=? operand "")
      name
      (format "~a ~a" name operand)))

;; ============================================================================
;; Trace Output (nestest format)
;; ============================================================================

;; Generate a trace line for the current CPU state
;; Format: ADDR  HH HH HH  MNEMONIC OPERAND          A:XX X:XX Y:XX P:XX SP:XX CYC:N
(define (trace-line c)
  (define pc (cpu-pc c))
  (define opcode (peek c pc))
  (define info (vector-ref opcode-table opcode))

  ;; Get bytes for this instruction
  (define bytes (if info (opcode-info-bytes info) 1))

  ;; Format address
  (define addr-str (string-upcase (hex4 pc)))

  ;; Format raw bytes (space-separated, padded to 9 chars for 3 bytes)
  ;; "AA BB CC" = 8 chars, we need a trailing space so 9 total
  (define byte-strs
    (for/list ([i (in-range bytes)])
      (hex2 (peek c (+ pc i)))))
  (define bytes-str
    (~a (string-join byte-strs " ") #:min-width 9 #:align 'left))

  ;; Format disassembly
  (define-values (name operand _) (disasm-at c pc))
  (define disasm-str
    (~a (if (string=? operand "")
            (string-upcase name)
            (format "~a ~a" (string-upcase name) (string-upcase operand)))
        #:min-width 32 #:align 'left))

  ;; Format registers (uppercase hex)
  (define a-str (string-upcase (hex2 (cpu-a c))))
  (define x-str (string-upcase (hex2 (cpu-x c))))
  (define y-str (string-upcase (hex2 (cpu-y c))))
  (define p-str (string-upcase (hex2 (cpu-p c))))
  (define sp-str (string-upcase (hex2 (cpu-sp c))))
  (define cyc-str (~a (cpu-cycles c)))

  (format "~a  ~a ~aA:~a X:~a Y:~a P:~a SP:~a CYC:~a"
          addr-str bytes-str disasm-str
          a-str x-str y-str p-str sp-str cyc-str))

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

  (test-case "disasm LDA immediate"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #xC000 #xA9)  ; LDA #$42
    (bytes-set! ram #xC001 #x42)
    (check-equal? (disasm-instruction c #xC000) "LDA #$42"))

  (test-case "disasm JMP absolute"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #xC000 #x4C)
    (bytes-set! ram #xC001 #xF5)
    (bytes-set! ram #xC002 #xC5)
    (check-equal? (disasm-instruction c #xC000) "JMP $C5F5"))

  (test-case "disasm branch relative"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #xC000 #xD0)  ; BNE +$10
    (bytes-set! ram #xC001 #x10)
    ;; Target = $C002 + $10 = $C012
    (check-equal? (disasm-instruction c #xC000) "BNE $C012"))

  (test-case "trace line format"
    (define-values (c ram) (make-test-cpu))
    (bytes-set! ram #xC000 #x4C)
    (bytes-set! ram #xC001 #xF5)
    (bytes-set! ram #xC002 #xC5)
    (set-cpu-pc! c #xC000)
    (set-cpu-a! c #x00)
    (set-cpu-x! c #x00)
    (set-cpu-y! c #x00)
    (set-cpu-p! c #x24)
    (set-cpu-sp! c #xFD)
    (define line (trace-line c))
    ;; Check key components of the trace line
    (check-true (string-contains? line "C000"))
    (check-true (string-contains? line "4C F5 C5"))
    (check-true (string-contains? line "JMP $C5F5"))
    (check-true (string-contains? line "A:00"))
    (check-true (string-contains? line "P:24"))
    (check-true (string-contains? line "SP:FD"))))
