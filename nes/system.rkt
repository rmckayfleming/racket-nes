#lang racket/base

;; NES System
;;
;; The main NES emulator orchestration. Ties together CPU, PPU, APU,
;; memory map, and mapper into a cohesive system.
;;
;; Timing Model (Mode A - Instruction-level):
;; - Execute one CPU instruction
;; - Tick PPU by (cpu-cycles * 3) - PPU runs 3x faster
;; - Tick APU by cpu-cycles
;; - Handle DMA stalls
;;
;; This is the simpler timing model suitable for most games.
;; Mode B (cycle-level) can be added later for edge cases.
;;
;; Reference: https://www.nesdev.org/wiki/Cycle_reference_chart

(provide
 ;; System creation
 make-nes
 nes?

 ;; Accessors
 nes-cpu
 nes-mapper
 nes-ram

 ;; Execution
 nes-step!          ; Execute one CPU instruction
 nes-run-frame!     ; Run until next frame boundary (placeholder)
 nes-reset!         ; Reset the system

 ;; State
 nes-frame-count
 nes-total-cycles

 ;; Debug
 nes-trace-enabled?
 nes-set-trace!)

(require "memory.rkt"
         "mappers/mapper.rkt"
         "../lib/6502/cpu.rkt"
         "../lib/6502/opcodes.rkt"
         "../lib/6502/disasm.rkt"
         "../lib/bus.rkt"
         "../lib/bits.rkt")

;; ============================================================================
;; NES System Structure
;; ============================================================================

(struct nes
  (cpu              ; 6502 CPU
   memory           ; NES memory map
   mapper           ; Cartridge mapper
   frame-count-box  ; Frame counter
   total-cycles-box ; Total CPU cycles executed
   trace-box        ; Trace output enabled?
   dma-stall-box)   ; DMA stall cycles pending
  #:transparent)

;; ============================================================================
;; System Creation
;; ============================================================================

(define (make-nes mapper)
  ;; Create memory subsystem
  (define mem (make-nes-memory))
  (define bus (nes-memory-bus mem))

  ;; Create CPU connected to the bus
  (define cpu (make-cpu bus))

  ;; Install opcode executor
  (install-opcode-executor!)

  ;; Connect mapper to memory
  (nes-memory-set-cart-read! mem (mapper-cpu-read mapper))
  (nes-memory-set-cart-write! mem
    (λ (addr val)
      ;; Check for OAM DMA trigger at $4014
      ;; (This is handled by APU/IO, but we intercept it here)
      ((mapper-cpu-write mapper) addr val)))

  ;; Create the system
  (define sys
    (nes cpu
         mem
         mapper
         (box 0)     ; frame count
         (box 0)     ; total cycles
         (box #f)    ; trace disabled
         (box 0)))   ; no DMA stall

  ;; Reset to initialize
  (nes-reset! sys)

  sys)

;; ============================================================================
;; Accessors
;; ============================================================================

(define (nes-ram sys)
  (nes-memory-ram (nes-memory sys)))

(define (nes-frame-count sys)
  (unbox (nes-frame-count-box sys)))

(define (nes-total-cycles sys)
  (unbox (nes-total-cycles-box sys)))

(define (nes-trace-enabled? sys)
  (unbox (nes-trace-box sys)))

(define (nes-set-trace! sys enabled?)
  (set-box! (nes-trace-box sys) enabled?))

;; ============================================================================
;; Execution
;; ============================================================================

;; Execute one CPU instruction
;; Returns the number of cycles consumed
(define (nes-step! sys)
  (define cpu (nes-cpu sys))
  (define cycles-before (cpu-cycles cpu))

  ;; Print trace if enabled
  (when (nes-trace-enabled? sys)
    (displayln (trace-line cpu)))

  ;; Execute one instruction
  (cpu-step! cpu)

  ;; Calculate cycles consumed
  (define cycles-after (cpu-cycles cpu))
  (define cycles (- cycles-after cycles-before))

  ;; Update total cycles
  (set-box! (nes-total-cycles-box sys)
            (+ (unbox (nes-total-cycles-box sys)) cycles))

  ;; TODO: Tick PPU by cycles * 3
  ;; TODO: Tick APU by cycles
  ;; TODO: Handle DMA stalls

  cycles)

;; Run until the next frame boundary
;; For now, this is a placeholder that runs a fixed number of cycles
;; (Will be PPU-driven once PPU is implemented)
(define CYCLES-PER-FRAME 29780)  ; ~29780.5 CPU cycles per NTSC frame

(define (nes-run-frame! sys)
  (define target-cycles (+ (nes-total-cycles sys) CYCLES-PER-FRAME))

  (let loop ()
    (when (< (nes-total-cycles sys) target-cycles)
      (nes-step! sys)
      (loop)))

  ;; Increment frame counter
  (set-box! (nes-frame-count-box sys)
            (+ 1 (unbox (nes-frame-count-box sys)))))

;; ============================================================================
;; Reset
;; ============================================================================

(define (nes-reset! sys)
  (define cpu (nes-cpu sys))

  ;; Reset CPU (loads PC from reset vector)
  (cpu-reset! cpu)

  ;; Reset counters
  (set-box! (nes-frame-count-box sys) 0)
  (set-box! (nes-total-cycles-box sys) (cpu-cycles cpu))
  (set-box! (nes-dma-stall-box sys) 0))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit
           "mappers/nrom.rkt"
           "../cart/ines.rkt"
           racket/file)

  ;; Create a minimal test ROM
  (define (make-test-rom-bytes)
    ;; iNES header
    (define header (make-bytes 16 0))
    (bytes-set! header 0 (char->integer #\N))
    (bytes-set! header 1 (char->integer #\E))
    (bytes-set! header 2 (char->integer #\S))
    (bytes-set! header 3 #x1A)
    (bytes-set! header 4 1)  ; 16KB PRG ROM
    (bytes-set! header 5 0)  ; CHR RAM
    (bytes-set! header 6 #x01)  ; Vertical mirroring

    ;; PRG ROM with a simple program
    (define prg (make-bytes #x4000 #xEA))  ; Fill with NOP

    ;; Reset vector points to $C000
    (bytes-set! prg #x3FFC #x00)  ; Low byte
    (bytes-set! prg #x3FFD #xC0)  ; High byte

    ;; Simple program at $C000:
    ;; LDA #$42
    ;; STA $00
    ;; JMP $C000 (infinite loop)
    (bytes-set! prg #x0000 #xA9)  ; LDA #
    (bytes-set! prg #x0001 #x42)  ; $42
    (bytes-set! prg #x0002 #x85)  ; STA zp
    (bytes-set! prg #x0003 #x00)  ; $00
    (bytes-set! prg #x0004 #x4C)  ; JMP
    (bytes-set! prg #x0005 #x00)  ; Low
    (bytes-set! prg #x0006 #xC0)  ; High

    (bytes-append header prg))

  (define (make-test-system)
    (define rom-bytes (make-test-rom-bytes))
    (define rom (parse-rom rom-bytes))
    (define mapper (make-nrom-mapper rom))
    (make-nes mapper))

  (test-case "system creation and reset"
    (define sys (make-test-system))

    ;; CPU should be at reset vector
    (check-equal? (cpu-pc (nes-cpu sys)) #xC000)

    ;; Frame count should be 0
    (check-equal? (nes-frame-count sys) 0))

  (test-case "step executes instructions"
    (define sys (make-test-system))
    (define cpu (nes-cpu sys))

    ;; Initial state
    (check-equal? (cpu-pc cpu) #xC000)
    (check-equal? (cpu-a cpu) #x00)

    ;; Step: LDA #$42
    (nes-step! sys)
    (check-equal? (cpu-pc cpu) #xC002)
    (check-equal? (cpu-a cpu) #x42)

    ;; Step: STA $00
    (nes-step! sys)
    (check-equal? (cpu-pc cpu) #xC004)
    ;; Check RAM
    (check-equal? (bytes-ref (nes-ram sys) 0) #x42)

    ;; Step: JMP $C000
    (nes-step! sys)
    (check-equal? (cpu-pc cpu) #xC000))

  (test-case "cycles accumulate"
    (define sys (make-test-system))

    (define initial-cycles (nes-total-cycles sys))

    ;; Step a few times
    (nes-step! sys)  ; LDA # = 2 cycles
    (nes-step! sys)  ; STA zp = 3 cycles
    (nes-step! sys)  ; JMP = 3 cycles

    ;; Should have accumulated 8 cycles
    (check-equal? (- (nes-total-cycles sys) initial-cycles) 8))

  (test-case "trace output"
    (define sys (make-test-system))

    ;; Enable trace
    (nes-set-trace! sys #t)
    (check-true (nes-trace-enabled? sys))

    ;; Disable trace
    (nes-set-trace! sys #f)
    (check-false (nes-trace-enabled? sys)))

  (test-case "reset restores initial state"
    (define sys (make-test-system))
    (define cpu (nes-cpu sys))

    ;; Run some instructions
    (nes-step! sys)
    (nes-step! sys)
    (check-not-equal? (cpu-pc cpu) #xC000)

    ;; Reset
    (nes-reset! sys)

    ;; Should be back at reset vector
    (check-equal? (cpu-pc cpu) #xC000)))
