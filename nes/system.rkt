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
 nes-ppu
 nes-ppu-bus
 nes-mapper
 nes-ram
 nes-controller1
 nes-controller2
 nes-apu

 ;; Audio callback
 nes-set-audio-callback!  ; Set callback for audio samples

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
         "dma.rkt"
         "input/controller.rkt"
         "ppu/ppu.rkt"
         "ppu/regs.rkt"
         "ppu/bus.rkt"
         "ppu/timing.rkt"
         "ppu/render.rkt"
         "apu/apu.rkt"
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
   ppu              ; Picture Processing Unit
   ppu-bus          ; PPU memory bus
   apu              ; Audio Processing Unit
   mapper           ; Cartridge mapper
   controller1      ; Player 1 controller
   controller2      ; Player 2 controller
   frame-count-box  ; Frame counter
   total-cycles-box ; Total CPU cycles executed
   trace-box        ; Trace output enabled?
   dma-stall-box    ; DMA stall cycles pending
   nmi-pending-box  ; NMI pending flag
   audio-callback-box) ; Audio sample callback (sample cycles -> void)
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

  ;; Create PPU and its bus
  (define p (make-ppu))
  (define pbus (make-ppu-bus mapper))

  ;; Connect mapper to CPU memory
  (nes-memory-set-cart-read! mem (mapper-cpu-read mapper))
  (nes-memory-set-cart-write! mem
    (λ (addr val)
      ((mapper-cpu-write mapper) addr val)))

  ;; Box for NMI pending (shared between PPU and step function)
  (define nmi-pending-box (box #f))

  ;; Connect PPU registers to CPU memory
  (nes-memory-set-ppu-read! mem
    (λ (reg)
      ;; reg is 0-7 (PPU register within $2000-$2007)
      (define-values (byte nmi-changed?)
        (ppu-reg-read p reg (λ (addr) (ppu-bus-read pbus addr))))
      ;; Reading $2002 can affect NMI state
      (when nmi-changed?
        (set-box! nmi-pending-box (ppu-nmi-output? p)))
      byte))

  (nes-memory-set-ppu-write! mem
    (λ (reg val)
      ;; reg is 0-7 (PPU register within $2000-$2007)
      (define nmi-changed?
        (ppu-reg-write p reg val (λ (addr byte) (ppu-bus-write pbus addr byte))))
      ;; Writing to $2000 can trigger NMI if vblank is set
      (when nmi-changed?
        (set-box! nmi-pending-box (ppu-nmi-output? p)))))

  ;; DMA stall box (shared for DMA handler to set)
  (define dma-stall-box (box 0))

  ;; Connect DMA handler
  (nes-memory-set-dma-write! mem
    (λ (page)
      ;; Perform the DMA transfer
      (oam-dma-transfer! page (λ (addr) (bus-read bus addr)) p)
      ;; Calculate and set stall cycles
      ;; Use CPU cycles at time of DMA trigger (not including pending stalls)
      ;; The DMA takes 513 or 514 cycles depending on odd/even alignment
      (set-box! dma-stall-box (+ (unbox dma-stall-box)
                                  (oam-dma-cycles (cpu-cycles cpu))))))

  ;; Create controllers
  (define ctrl1 (make-controller))
  (define ctrl2 (make-controller))

  ;; Connect controllers to memory map
  (nes-memory-set-controller-read! mem
    (λ (port)
      (if (= port 0)
          (controller-read ctrl1)
          (controller-read ctrl2))))

  (nes-memory-set-controller-write! mem
    (λ (port val)
      ;; Both controllers share the same strobe signal
      (controller-write! ctrl1 val)
      (controller-write! ctrl2 val)))

  ;; Create APU
  (define ap (make-apu))

  ;; Connect APU to CPU bus for DMC sample reads
  (apu-set-memory-reader! ap (λ (addr) (bus-read bus addr)))

  ;; Connect APU registers to memory map
  (nes-memory-set-apu-read! mem
    (λ (addr)
      (apu-read ap addr)))

  (nes-memory-set-apu-write! mem
    (λ (addr val)
      (apu-write! ap addr val)))

  ;; Create the system
  (define sys
    (nes cpu
         mem
         p
         pbus
         ap
         mapper
         ctrl1
         ctrl2
         (box 0)          ; frame count
         (box 0)          ; total cycles
         (box #f)         ; trace disabled
         dma-stall-box
         nmi-pending-box
         (box #f)))       ; audio callback (disabled by default)

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

;; Set audio callback (called with (sample cycles) during execution)
;; sample: float 0.0-1.0 (mixed APU output)
;; cycles: number of CPU cycles this represents
(define (nes-set-audio-callback! sys callback)
  (set-box! (nes-audio-callback-box sys) callback))

;; ============================================================================
;; Execution
;; ============================================================================

;; Execute one CPU instruction (or consume DMA stall cycles)
;; Returns the number of cycles consumed
(define (nes-step! sys)
  (define cpu (nes-cpu sys))
  (define p (nes-ppu sys))
  (define dma-stall (unbox (nes-dma-stall-box sys)))

  ;; If there are DMA stall cycles pending, consume them instead of executing
  (if (> dma-stall 0)
      ;; DMA stall: consume stall cycles, tick PPU, no CPU execution
      (let ([stall-cycles (min dma-stall 1)])  ; Process 1 cycle at a time for accuracy
        (set-box! (nes-dma-stall-box sys) (- dma-stall stall-cycles))
        (set-box! (nes-total-cycles-box sys)
                  (+ (unbox (nes-total-cycles-box sys)) stall-cycles))
        ;; Tick PPU by stall cycles * 3
        (ppu-tick! sys (* stall-cycles 3))
        ;; Tick APU by stall cycles (APU runs at CPU clock rate)
        (apu-tick! (nes-apu sys) stall-cycles)
        ;; Call audio callback if set
        (define audio-cb (unbox (nes-audio-callback-box sys)))
        (when audio-cb
          (audio-cb (apu-output (nes-apu sys)) stall-cycles))
        ;; Check for DMC DMA stall cycles and add to stall counter
        (define dmc-stall (apu-dmc-stall-cycles (nes-apu sys)))
        (when (> dmc-stall 0)
          (set-box! (nes-dma-stall-box sys)
                    (+ (unbox (nes-dma-stall-box sys)) dmc-stall))
          (apu-clear-dmc-stall-cycles! (nes-apu sys)))
        stall-cycles)

      ;; Normal execution
      (let ([cycles-before (cpu-cycles cpu)])
        ;; Check for pending NMI and signal it to CPU
        (when (unbox (nes-nmi-pending-box sys))
          (set-box! (nes-nmi-pending-box sys) #f)
          (set-cpu-nmi-pending! cpu #t))

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

        ;; Tick PPU by cycles * 3 (PPU runs 3x faster than CPU)
        (ppu-tick! sys (* cycles 3))

        ;; Tick APU by cycles (APU runs at CPU clock rate)
        (apu-tick! (nes-apu sys) cycles)

        ;; Call audio callback if set
        (define audio-cb (unbox (nes-audio-callback-box sys)))
        (when audio-cb
          (audio-cb (apu-output (nes-apu sys)) cycles))

        ;; Check for DMC DMA stall cycles and add to stall counter
        (define dmc-stall (apu-dmc-stall-cycles (nes-apu sys)))
        (when (> dmc-stall 0)
          (set-box! (nes-dma-stall-box sys)
                    (+ (unbox (nes-dma-stall-box sys)) dmc-stall))
          (apu-clear-dmc-stall-cycles! (nes-apu sys)))

        ;; Check for APU IRQ and signal to CPU
        (when (apu-irq-pending? (nes-apu sys))
          (set-cpu-irq-pending! cpu #t))

        cycles)))

;; Advance PPU by the given number of PPU cycles
;; Updates scanline/cycle counters and handles VBlank/NMI
(define (ppu-tick! sys ppu-cycles)
  (define p (nes-ppu sys))
  (define pbus (nes-ppu-bus sys))

  (for ([_ (in-range ppu-cycles)])
    (define cycle (ppu-cycle p))
    (define scanline (ppu-scanline p))

    ;; Odd frame cycle skip: on pre-render scanline, cycle 0, if rendering
    ;; is enabled and this is an odd frame, skip cycle 0 entirely.
    ;; This means we don't process cycle 0 at all - just advance to cycle 1.
    ;; Reference: https://www.nesdev.org/wiki/PPU_frame_timing
    (define skip-this-cycle?
      (and (= scanline SCANLINE-PRE-RENDER)
           (= cycle 0)
           (ppu-odd-frame? p)
           (ppu-rendering-enabled? p)))

    (unless skip-this-cycle?
      ;; VBlank start: scanline 241, cycle 1
      (when (and (= scanline SCANLINE-VBLANK-START)
                 (= cycle 1))
        (set-ppu-nmi-occurred! p #t)
        ;; Trigger NMI if enabled
        (when (ppu-ctrl-flag? p CTRL-NMI-ENABLE)
          (set-ppu-nmi-output! p #t)
          (set-box! (nes-nmi-pending-box sys) #t)))

      ;; Pre-render scanline (261): clear flags at cycle 1
      (when (and (= scanline SCANLINE-PRE-RENDER)
                 (= cycle 1))
        (set-ppu-nmi-occurred! p #f)
        (set-ppu-nmi-output! p #f)
        (set-ppu-sprite0-hit! p #f)
        (set-ppu-sprite-overflow! p #f))

      ;; During pre-render (scanline 261), copy vertical scroll bits from t to v
      ;; This happens at cycles 280-304 when rendering is enabled
      (when (and (= scanline SCANLINE-PRE-RENDER)
                 (>= cycle 280)
                 (<= cycle 304)
                 (ppu-rendering-enabled? p))
        ;; Copy vertical bits: fine Y, coarse Y, and Y nametable bit
        ;; v: yyy NN YYYYY XXXXX
        ;;    |||  | |||||
        ;;    t: yyy NN YYYYY .....
        (define v (ppu-v p))
        (define t (ppu-t p))
        ;; Mask: bits 5-14 (Y parts) + bit 11 (vertical nametable)
        ;; = #b111_10_11111_00000 = #x7BE0
        (define new-v (bitwise-ior (bitwise-and v #x041F)    ; Keep X bits from v
                                   (bitwise-and t #x7BE0)))  ; Get Y bits from t
        (set-ppu-v! p new-v))

      ;; At dot 257, copy horizontal scroll bits from t to v (end of visible line)
      (when (and (or (< scanline VISIBLE-HEIGHT)             ; Visible scanlines
                     (= scanline SCANLINE-PRE-RENDER))       ; Or pre-render
                 (= cycle 257)
                 (ppu-rendering-enabled? p))
        ;; Copy horizontal bits: coarse X and X nametable bit
        (define v (ppu-v p))
        (define t (ppu-t p))
        ;; Mask: bits 0-4 (coarse X) + bit 10 (horizontal nametable)
        ;; = #b000_01_00000_11111 = #x041F
        (define new-v (bitwise-ior (bitwise-and v #x7BE0)    ; Keep Y bits from v
                                   (bitwise-and t #x041F)))  ; Get X bits from t
        (set-ppu-v! p new-v))

      ;; Capture scroll state at cycle 0 of each visible scanline
      ;; This is used by the renderer to get the correct scroll for each line
      (when (and (< scanline VISIBLE-HEIGHT)
                 (= cycle 0)
                 (ppu-rendering-enabled? p))
        (ppu-capture-scanline-scroll! p scanline))

      ;; Sprite 0 hit detection during visible scanlines
      ;; Check on cycles 1-255 (cycle corresponds to X position - 1)
      ;; Only check if not already hit (it latches until pre-render clears it)
      (when (and (< scanline VISIBLE-HEIGHT)  ; Visible scanlines 0-239
                 (>= cycle 1)
                 (<= cycle 255)               ; Visible pixels (X = cycle - 1)
                 (not (ppu-sprite0-hit? p)))  ; Not already hit
        (define x (- cycle 1))  ; X position is cycle - 1
        (when (check-sprite0-hit? p pbus scanline x)
          (set-ppu-sprite0-hit! p #t))))

    ;; Advance position (always advance by 1, skip is handled by skipping logic)
    (define next-cycle (+ cycle 1))
    (cond
      [(>= next-cycle CYCLES-PER-SCANLINE)
       ;; End of scanline
       (set-ppu-cycle! p 0)
       (define next-scanline (+ scanline 1))
       (cond
         [(>= next-scanline SCANLINES-TOTAL)
          ;; End of frame
          (set-ppu-scanline! p 0)
          (set-ppu-frame! p (+ 1 (ppu-frame p)))
          (set-ppu-odd-frame! p (not (ppu-odd-frame? p)))
          ;; Increment frame counter
          (set-box! (nes-frame-count-box sys)
                    (+ 1 (unbox (nes-frame-count-box sys))))]
         [else
          (set-ppu-scanline! p next-scanline)])]
      [else
       (set-ppu-cycle! p next-cycle)])))

;; Run until the next frame boundary (when PPU reaches scanline 0)
(define (nes-run-frame! sys)
  (define p (nes-ppu sys))
  (define start-frame (ppu-frame p))

  ;; Run until the PPU frame counter advances
  (let loop ()
    (when (= (ppu-frame p) start-frame)
      (nes-step! sys)
      (loop))))

;; ============================================================================
;; Reset
;; ============================================================================

(define (nes-reset! sys)
  (define cpu (nes-cpu sys))
  (define p (nes-ppu sys))

  ;; Reset CPU (loads PC from reset vector)
  (cpu-reset! cpu)

  ;; Reset PPU position
  (set-ppu-scanline! p 0)
  (set-ppu-cycle! p 0)
  (set-ppu-frame! p 0)
  (set-ppu-odd-frame! p #f)
  (set-ppu-nmi-occurred! p #f)
  (set-ppu-nmi-output! p #f)
  (set-ppu-sprite0-hit! p #f)
  (set-ppu-sprite-overflow! p #f)

  ;; Reset counters
  (set-box! (nes-frame-count-box sys) 0)
  (set-box! (nes-total-cycles-box sys) (cpu-cycles cpu))
  (set-box! (nes-dma-stall-box sys) 0)
  (set-box! (nes-nmi-pending-box sys) #f))

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
    (check-equal? (cpu-pc cpu) #xC000))

  (test-case "OAM DMA transfers data and stalls CPU"
    (define sys (make-test-system))
    (define cpu (nes-cpu sys))
    (define p (nes-ppu sys))
    (define mem (nes-memory sys))
    (define bus (nes-memory-bus mem))

    ;; Write test pattern to page $02 in RAM
    (for ([i (in-range 256)])
      (bus-write bus (+ #x0200 i) (bitwise-and (+ i #x10) #xFF)))

    ;; Record cycles before DMA
    (define cycles-before (nes-total-cycles sys))

    ;; Trigger OAM DMA by writing to $4014
    (bus-write bus #x4014 #x02)

    ;; DMA should have set stall cycles
    (check-true (> (unbox (nes-dma-stall-box sys)) 0))

    ;; Run enough steps to consume DMA stall cycles
    (for ([_ (in-range 520)])  ; More than 514 cycles
      (nes-step! sys))

    ;; DMA stall should be consumed
    (check-equal? (unbox (nes-dma-stall-box sys)) 0)

    ;; OAM should contain the transferred data
    (define oam (ppu-oam p))
    (check-equal? (bytes-ref oam 0) #x10)
    (check-equal? (bytes-ref oam 1) #x11)
    (check-equal? (bytes-ref oam 255) #x0F))  ; #x10 + 255 = #x10F, masked to #x0F

  (test-case "DMA stall cycles are correct"
    (define sys (make-test-system))
    (define mem (nes-memory sys))
    (define bus (nes-memory-bus mem))

    ;; Trigger DMA (starting cycles determine 513 vs 514)
    (bus-write bus #x4014 #x00)

    ;; Check that stall cycles are in expected range
    (define stall (unbox (nes-dma-stall-box sys)))
    (check-true (or (= stall 513) (= stall 514))
                (format "DMA stall should be 513 or 514, got ~a" stall)))

  (test-case "controller input via memory-mapped I/O"
    (define sys (make-test-system))
    (define ctrl1 (nes-controller1 sys))
    (define mem (nes-memory sys))
    (define bus (nes-memory-bus mem))

    ;; Press A and Start on controller 1
    (controller-set-button! ctrl1 BUTTON-A #t)
    (controller-set-button! ctrl1 BUTTON-START #t)

    ;; Strobe to latch button state
    (bus-write bus #x4016 1)
    (bus-write bus #x4016 0)

    ;; Read buttons via $4016
    (check-equal? (bus-read bus #x4016) 1 "A pressed")
    (check-equal? (bus-read bus #x4016) 0 "B not pressed")
    (check-equal? (bus-read bus #x4016) 0 "Select not pressed")
    (check-equal? (bus-read bus #x4016) 1 "Start pressed")
    (check-equal? (bus-read bus #x4016) 0 "Up not pressed")
    (check-equal? (bus-read bus #x4016) 0 "Down not pressed")
    (check-equal? (bus-read bus #x4016) 0 "Left not pressed")
    (check-equal? (bus-read bus #x4016) 0 "Right not pressed")

    ;; After 8 reads, should return 1
    (check-equal? (bus-read bus #x4016) 1 "Post-8 read")))
