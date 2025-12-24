#lang racket/base

;; Nestest Harness
;;
;; Runs the nestest ROM and compares CPU trace output against the
;; reference log. Reports the first divergence with context.
;;
;; Usage:
;;   raco test test/harness/nestest.rkt
;;
;; The nestest ROM tests all official 6502 opcodes. In automation mode
;; (starting at $C000), it writes test results to $02/$03.
;;
;; Note: nestest includes unofficial opcode tests starting at line 5004.
;; We only implement official opcodes, so we validate the first 5003 lines.

;; Number of instructions to test (official opcodes only)
(define OFFICIAL-OPCODE-LINES 5003)

(require rackunit
         racket/string
         racket/port
         racket/file
         racket/match
         "../../lib/bits.rkt"
         "../../lib/bus.rkt"
         "../../lib/6502/cpu.rkt"
         "../../lib/6502/opcodes.rkt"
         "../../lib/6502/disasm.rkt"
         "../../cart/ines.rkt")

;; ============================================================================
;; Trace Comparison
;; ============================================================================

;; Parse a trace line into comparable parts using regex
;; Returns: (addr a x y p sp cyc) or #f
(define trace-rx
  (pregexp "^([0-9A-Fa-f]{4}).*A:([0-9A-Fa-f]{2}) X:([0-9A-Fa-f]{2}) Y:([0-9A-Fa-f]{2}) P:([0-9A-Fa-f]{2}) SP:([0-9A-Fa-f]{2}).*CYC:([0-9]+)"))

(define (parse-trace line)
  (define m (regexp-match trace-rx line))
  (and m
       (list (string-upcase (list-ref m 1))   ; addr
             (string-upcase (list-ref m 2))   ; A
             (string-upcase (list-ref m 3))   ; X
             (string-upcase (list-ref m 4))   ; Y
             (string-upcase (list-ref m 5))   ; P
             (string-upcase (list-ref m 6))   ; SP
             (list-ref m 7))))                ; CYC (as string)

;; Compare two trace lines
;; Returns #t if they match on address, registers, and cycles
(define (traces-match? our-line ref-line)
  (define our-parts (parse-trace our-line))
  (define ref-parts (parse-trace ref-line))
  (and our-parts ref-parts
       (equal? our-parts ref-parts)))

;; ============================================================================
;; ROM Loading
;; ============================================================================

;; Load nestest ROM and create a CPU with it mapped
(define (load-nestest-cpu rom-path)
  (define rom (load-rom rom-path))
  (define prg (rom-prg-rom rom))

  ;; Create RAM for CPU
  (define ram (make-bytes #x800 0))  ; 2KB internal RAM

  ;; Create bus
  (define b (make-bus))

  ;; Map internal RAM ($0000-$1FFF, mirrored every $800)
  (bus-add-handler! b
                    #:start #x0000
                    #:end #x1FFF
                    #:read (λ (addr) (bytes-ref ram (bitwise-and addr #x7FF)))
                    #:write (λ (addr val) (bytes-set! ram (bitwise-and addr #x7FF) val))
                    #:name 'ram)

  ;; Map PRG ROM at $8000-$FFFF
  ;; nestest is 16KB, so mirror at both $8000 and $C000
  (define prg-size (bytes-length prg))
  (bus-add-handler! b
                    #:start #x8000
                    #:end #xFFFF
                    #:read (λ (addr)
                             (bytes-ref prg (modulo (- addr #x8000) prg-size)))
                    #:write (λ (addr val) (void))  ; ROM is read-only
                    #:name 'prg-rom)

  ;; Create CPU
  (define c (make-cpu b))

  ;; Install opcode executor
  (install-opcode-executor!)

  ;; Set up for automation mode: start at $C000
  (set-cpu-pc! c #xC000)

  ;; Initialize cycles to 7 (reset takes 7 cycles)
  (cpu-add-cycles! c 7)

  ;; Return CPU and RAM for test result inspection
  (values c ram))

;; ============================================================================
;; Harness
;; ============================================================================

(define (run-nestest rom-path log-path #:max-lines [max-lines #f])
  (define-values (c ram) (load-nestest-cpu rom-path))
  (define ref-lines (file->lines log-path))
  ;; Default to official opcodes only (5003 lines)
  (define max-steps (min (or max-lines OFFICIAL-OPCODE-LINES)
                         (length ref-lines)))

  (printf "Running nestest: ~a steps to validate\n" max-steps)

  (for/fold ([errors '()]
             [step 0]
             #:result (reverse errors))
            ([ref-line (in-list ref-lines)]
             [i (in-range max-steps)]
             #:break (> (length errors) 0))  ; Stop on first error

    ;; Generate our trace line BEFORE stepping
    (define our-line (trace-line c))

    ;; Compare
    (cond
      [(traces-match? our-line ref-line)
       ;; Step the CPU
       (cpu-step! c)
       (values errors (+ step 1))]
      [else
       ;; Mismatch! Return error info
       (values (list (list i our-line ref-line)) step)])))

;; ============================================================================
;; Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (define rom-path "test/roms/nestest.nes")
  (define log-path "test/reference/nestest.log")

  (test-case "nestest CPU validation"
    (when (and (file-exists? rom-path) (file-exists? log-path))
      (define errors (run-nestest rom-path log-path))

      (when (pair? errors)
        (define err (car errors))
        (define line-num (car err))
        (define our-line (cadr err))
        (define ref-line (caddr err))
        (printf "\n=== MISMATCH at line ~a ===\n" (+ line-num 1))
        (printf "Expected: ~a\n" ref-line)
        (printf "Got:      ~a\n" our-line)
        (printf "\nParsed expected: ~a\n" (parse-trace ref-line))
        (printf "Parsed got:      ~a\n" (parse-trace our-line)))

      (check-equal? errors '() "CPU trace should match reference"))))

;; Allow running directly
(module+ main
  (require racket/cmdline)

  (define rom-path "test/roms/nestest.nes")
  (define log-path "test/reference/nestest.log")
  (define max-lines #f)

  (command-line
   #:once-each
   [("-r" "--rom") path "Path to nestest.nes" (set! rom-path path)]
   [("-l" "--log") path "Path to reference log" (set! log-path path)]
   [("-n" "--lines") n "Max lines to compare" (set! max-lines (string->number n))])

  (define errors (run-nestest rom-path log-path #:max-lines max-lines))

  (cond
    [(null? errors)
     (printf "SUCCESS: All lines match!\n")]
    [else
     (define err (car errors))
     (define line-num (car err))
     (define our-line (cadr err))
     (define ref-line (caddr err))
     (printf "\n=== MISMATCH at line ~a ===\n" (+ line-num 1))
     (printf "Expected: ~a\n" ref-line)
     (printf "Got:      ~a\n" our-line)
     (printf "\nParsed expected: ~a\n" (parse-trace ref-line))
     (printf "Parsed got:      ~a\n" (parse-trace our-line))
     (exit 1)]))
