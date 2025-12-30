#lang racket/base

;; APU (Audio Processing Unit)
;;
;; The NES APU handles audio generation and has timing-critical features
;; that many games depend on even when audio is not the primary concern:
;;
;; - Frame counter: Generates IRQs and clocks envelope/length/sweep units
;; - DMC: Can steal CPU cycles for sample fetches
;; - Length counters: Used for timing in some games
;;
;; Register Map ($4000-$4017):
;; $4000-$4003  Pulse 1 (duty, envelope, sweep, timer, length)
;; $4004-$4007  Pulse 2
;; $4008-$400B  Triangle (linear counter, timer, length)
;; $400C-$400F  Noise (envelope, mode, period, length)
;; $4010-$4013  DMC (flags, rate, address, length)
;; $4015        Status (channel enables, DMC/frame IRQ flags)
;; $4017        Frame counter (mode, IRQ inhibit)
;;
;; Reference: https://www.nesdev.org/wiki/APU

(provide
 ;; APU creation
 make-apu
 apu?

 ;; Register access (for memory map integration)
 apu-read
 apu-write!

 ;; Timing
 apu-tick!

 ;; IRQ status
 apu-irq-pending?
 apu-acknowledge-irq!

 ;; DMC DMA cycle stealing
 apu-dmc-stall-cycles
 apu-clear-dmc-stall-cycles!
 apu-set-memory-reader!

 ;; Audio output
 apu-output            ; Get current mixed audio output (0.0 to 1.0)
 apu-pulse1-output     ; Individual channel outputs (0-15)
 apu-pulse2-output
 apu-triangle-output
 apu-noise-output
 apu-dmc-output        ; DMC output (0-127)

 ;; State access (for debugging/save states)
 apu-frame-counter-mode
 apu-frame-irq-inhibit?
 apu-frame-irq-pending?
 apu-dmc-irq-pending?
 apu-dmc-bytes-remaining)

(require "../../lib/bits.rkt"
         "mixer.rkt")

;; ============================================================================
;; Length Counter Lookup Table
;; ============================================================================

;; The length counter uses a lookup table indexed by the top 5 bits
;; of the length counter load register
(define LENGTH-TABLE
  (vector
   10 254 20  2 40  4 80  6 160  8 60 10 14 12 26 14
   12  16 24 18 48 20 96 22 192 24 72 26 16 28 32 30))

;; ============================================================================
;; DMC Rate Table
;; ============================================================================

;; DMC rate periods in CPU cycles (NTSC)
;; The rate index (0-15) from $4010 selects a period
(define DMC-RATE-TABLE
  (vector
   428 380 340 320 286 254 226 214
   190 160 142 128 106  84  72  54))

;; ============================================================================
;; APU State Structure
;; ============================================================================

(struct apu
  (;; ---- Pulse 1 Channel ($4000-$4003) ----
   pulse1-duty-box          ; Duty cycle (0-3)
   pulse1-halt-box          ; Length counter halt / envelope loop
   pulse1-const-vol-box     ; Constant volume flag
   pulse1-volume-box        ; Volume/envelope divider period (0-15)
   pulse1-sweep-enable-box  ; Sweep enable
   pulse1-sweep-period-box  ; Sweep divider period
   pulse1-sweep-negate-box  ; Sweep negate flag
   pulse1-sweep-shift-box   ; Sweep shift count
   pulse1-timer-box         ; Timer period (11-bit)
   pulse1-length-box        ; Length counter value

   ;; ---- Pulse 2 Channel ($4004-$4007) ----
   pulse2-duty-box
   pulse2-halt-box
   pulse2-const-vol-box
   pulse2-volume-box
   pulse2-sweep-enable-box
   pulse2-sweep-period-box
   pulse2-sweep-negate-box
   pulse2-sweep-shift-box
   pulse2-timer-box
   pulse2-length-box

   ;; ---- Triangle Channel ($4008-$400B) ----
   tri-control-box          ; Control flag (also length counter halt)
   tri-linear-load-box      ; Linear counter reload value
   tri-timer-box            ; Timer period (11-bit)
   tri-length-box           ; Length counter value
   tri-linear-counter-box   ; Current linear counter value
   tri-linear-reload-box    ; Linear counter reload flag

   ;; ---- Noise Channel ($400C-$400F) ----
   noise-halt-box           ; Length counter halt / envelope loop
   noise-const-vol-box      ; Constant volume flag
   noise-volume-box         ; Volume/envelope divider period
   noise-mode-box           ; Noise mode (short/long)
   noise-period-box         ; Noise period index
   noise-length-box         ; Length counter value

   ;; ---- DMC Channel ($4010-$4013) ----
   dmc-irq-enable-box       ; IRQ enable flag
   dmc-loop-box             ; Loop flag
   dmc-rate-box             ; Rate index
   dmc-output-box           ; Direct output level (0-127)
   dmc-sample-addr-box      ; Sample address (register value)
   dmc-sample-length-box    ; Sample length (register value)
   dmc-irq-pending-box      ; DMC IRQ pending flag

   ;; ---- DMC Playback State ----
   dmc-current-addr-box     ; Current sample read address
   dmc-bytes-remaining-box  ; Bytes remaining in current sample
   dmc-sample-buffer-box    ; Current sample byte being shifted out
   dmc-buffer-empty-box     ; True if sample buffer needs refill
   dmc-bits-remaining-box   ; Bits remaining in current sample byte (0-8)
   dmc-timer-box            ; Timer countdown for rate
   dmc-silence-box          ; True if output unit is silenced
   dmc-stall-cycles-box     ; CPU stall cycles from DMC DMA (consumed by system)

   ;; ---- Status Register ($4015) ----
   ;; Channel enable flags
   pulse1-enable-box
   pulse2-enable-box
   tri-enable-box
   noise-enable-box
   dmc-enable-box

   ;; ---- Frame Counter ($4017) ----
   frame-mode-box           ; 0 = 4-step, 1 = 5-step
   frame-irq-inhibit-box    ; IRQ inhibit flag
   frame-irq-pending-box    ; Frame IRQ pending
   frame-counter-box        ; Current frame counter step (0-4)
   frame-cycle-box          ; Cycles within current step

   ;; ---- Internal Timing ----
   cycle-count-box          ; Total APU cycles (for debugging)

   ;; ---- Memory Access (for DMC sample reads) ----
   memory-reader-box        ; Callback: (addr -> byte) for reading samples

   ;; ---- Audio Output State ----
   ;; Pulse 1 audio state
   pulse1-timer-counter-box     ; Current timer countdown
   pulse1-sequence-pos-box      ; Position in duty sequence (0-7)
   pulse1-envelope-decay-box    ; Envelope decay level (0-15)
   pulse1-envelope-divider-box  ; Envelope divider countdown
   pulse1-envelope-start-box    ; Envelope start flag
   pulse1-sweep-divider-box     ; Sweep divider countdown
   pulse1-sweep-reload-box      ; Sweep reload flag

   ;; Pulse 2 audio state
   pulse2-timer-counter-box
   pulse2-sequence-pos-box
   pulse2-envelope-decay-box
   pulse2-envelope-divider-box
   pulse2-envelope-start-box
   pulse2-sweep-divider-box
   pulse2-sweep-reload-box

   ;; Triangle audio state
   tri-timer-counter-box        ; Timer countdown
   tri-sequence-pos-box         ; Position in triangle sequence (0-31)

   ;; Noise audio state
   noise-timer-counter-box      ; Timer countdown
   noise-shift-register-box     ; 15-bit LFSR
   noise-envelope-decay-box     ; Envelope decay level (0-15)
   noise-envelope-divider-box   ; Envelope divider countdown
   noise-envelope-start-box     ; Envelope start flag
   )
  #:transparent)

;; ============================================================================
;; Duty Cycle Sequences
;; ============================================================================

;; Pulse duty cycle waveforms (8 steps each)
(define DUTY-TABLE
  (vector
   #(0 1 0 0 0 0 0 0)   ; 12.5%
   #(0 1 1 0 0 0 0 0)   ; 25%
   #(0 1 1 1 1 0 0 0)   ; 50%
   #(1 0 0 1 1 1 1 1))) ; 75%

;; Triangle wave is a 32-step sequence
(define TRIANGLE-SEQUENCE
  (vector 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0
          0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))

;; Noise period table (NTSC)
(define NOISE-PERIOD-TABLE
  (vector 4 8 16 32 64 96 128 160 202 254 380 508 762 1016 2034 4068))

;; ============================================================================
;; APU Creation
;; ============================================================================

(define (make-apu)
  (apu
   ;; Pulse 1
   (box 0) (box #f) (box #f) (box 0)
   (box #f) (box 0) (box #f) (box 0)
   (box 0) (box 0)

   ;; Pulse 2
   (box 0) (box #f) (box #f) (box 0)
   (box #f) (box 0) (box #f) (box 0)
   (box 0) (box 0)

   ;; Triangle
   (box #f) (box 0) (box 0) (box 0) (box 0) (box #f)

   ;; Noise
   (box #f) (box #f) (box 0) (box #f) (box 0) (box 0)

   ;; DMC registers
   (box #f) (box #f) (box 0) (box 0)
   (box #xC000) (box 0) (box #f)

   ;; DMC playback state
   (box #xC000)  ; current address
   (box 0)       ; bytes remaining
   (box 0)       ; sample buffer
   (box #t)      ; buffer empty
   (box 0)       ; bits remaining
   (box 0)       ; timer
   (box #t)      ; silence
   (box 0)       ; stall cycles

   ;; Channel enables
   (box #f) (box #f) (box #f) (box #f) (box #f)

   ;; Frame counter
   (box 0) (box #f) (box #f) (box 0) (box 0)

   ;; Timing
   (box 0)

   ;; Memory reader (set by system after creation)
   (box (λ (addr) 0))

   ;; Audio output state - Pulse 1
   (box 0)    ; timer counter
   (box 0)    ; sequence position
   (box 15)   ; envelope decay (starts at max)
   (box 0)    ; envelope divider
   (box #f)   ; envelope start
   (box 0)    ; sweep divider
   (box #f)   ; sweep reload

   ;; Audio output state - Pulse 2
   (box 0)    ; timer counter
   (box 0)    ; sequence position
   (box 15)   ; envelope decay
   (box 0)    ; envelope divider
   (box #f)   ; envelope start
   (box 0)    ; sweep divider
   (box #f)   ; sweep reload

   ;; Audio output state - Triangle
   (box 0)    ; timer counter
   (box 0)    ; sequence position

   ;; Audio output state - Noise
   (box 0)    ; timer counter
   (box 1)    ; shift register (starts at 1)
   (box 15)   ; envelope decay
   (box 0)    ; envelope divider
   (box #f))) ; envelope start

;; ============================================================================
;; Frame Counter Timing
;; ============================================================================

;; Frame counter step timing (in APU cycles = CPU cycles)
;;
;; The frame counter steps happen at specific cycle counts relative to $4017 write.
;; These are the cycle counts when each step fires:
;;
;; Mode 0 (4-step):
;;   Step 0 (quarter):     3728 cycles
;;   Step 1 (quarter+half): 7456 cycles
;;   Step 2 (quarter):     11185 cycles
;;   Step 3 (quarter+half+IRQ): 14914 cycles, then reset at 14915
;;
;; Mode 1 (5-step):
;;   Step 0: 3728, Step 1: 7456, Step 2: 11185, Step 3: 14914, Step 4: 18640
;;   Then reset at 18641
;;
;; In 4-step mode, the IRQ flag is also set on cycles 14914, 0, and 1.
;; Reference: https://www.nesdev.org/wiki/APU_Frame_Counter

;; Frame counter step timings in CPU cycles
;; The APU frame counter is clocked at CPU rate, and steps happen at:
;;
;; Mode 0 (4-step):
;;   Step 0 (quarter):     7457 cycles
;;   Step 1 (quarter+half): 14913 cycles
;;   Step 2 (quarter):     22371 cycles
;;   Step 3 (quarter+half+IRQ): 29829 cycles, then reset
;;
;; Mode 1 (5-step):
;;   Same as mode 0 for steps 0-3, plus step 4 at 37281
;;
;; IRQ flag is set on step 3 in mode 0 only.
;; Reference: https://www.nesdev.org/wiki/APU_Frame_Counter

(define FRAME-STEP-CYCLES-4STEP (vector 7457 14913 22371 29829))
(define FRAME-STEP-CYCLES-5STEP (vector 7457 14913 22371 29829 37281))

;; Frame length (cycle count before reset)
(define FRAME-LENGTH-4STEP 29830)
(define FRAME-LENGTH-5STEP 37282)

;; What happens at each step:
;; Step 0: Clock envelopes and triangle linear counter
;; Step 1: Clock envelopes, triangle, length counters, and sweep units
;; Step 2: Clock envelopes and triangle linear counter
;; Step 3: (4-step only) Clock envelopes, triangle, length, sweep, set frame IRQ
;; Step 4: (5-step only) Clock envelopes, triangle, length, sweep

;; ============================================================================
;; Register Read/Write
;; ============================================================================

(define (apu-read ap addr)
  (case addr
    ;; $4015 - Status register (read)
    [(#x4015)
     (define status
       (bitwise-ior
        ;; Bit 0: Pulse 1 length counter > 0
        (if (> (unbox (apu-pulse1-length-box ap)) 0) #x01 0)
        ;; Bit 1: Pulse 2 length counter > 0
        (if (> (unbox (apu-pulse2-length-box ap)) 0) #x02 0)
        ;; Bit 2: Triangle length counter > 0
        (if (> (unbox (apu-tri-length-box ap)) 0) #x04 0)
        ;; Bit 3: Noise length counter > 0
        (if (> (unbox (apu-noise-length-box ap)) 0) #x08 0)
        ;; Bit 4: DMC active (has bytes remaining)
        (if (> (unbox (apu-dmc-bytes-remaining-box ap)) 0) #x10 0)
        ;; Bit 6: Frame IRQ pending
        (if (unbox (apu-frame-irq-pending-box ap)) #x40 0)
        ;; Bit 7: DMC IRQ pending
        (if (unbox (apu-dmc-irq-pending-box ap)) #x80 0)))
     ;; Reading $4015 clears the frame IRQ flag
     (set-box! (apu-frame-irq-pending-box ap) #f)
     status]

    ;; Other APU registers are write-only, return open bus
    [else #x00]))

(define (apu-write! ap addr val)
  (case addr
    ;; ---- Pulse 1 ($4000-$4003) ----
    [(#x4000)
     (set-box! (apu-pulse1-duty-box ap) (extract val 6 2))
     (set-box! (apu-pulse1-halt-box ap) (bit? val 5))
     (set-box! (apu-pulse1-const-vol-box ap) (bit? val 4))
     (set-box! (apu-pulse1-volume-box ap) (bitwise-and val #x0F))]

    [(#x4001)
     (set-box! (apu-pulse1-sweep-enable-box ap) (bit? val 7))
     (set-box! (apu-pulse1-sweep-period-box ap) (extract val 4 3))
     (set-box! (apu-pulse1-sweep-negate-box ap) (bit? val 3))
     (set-box! (apu-pulse1-sweep-shift-box ap) (bitwise-and val #x07))
     (set-box! (apu-pulse1-sweep-reload-box ap) #t)]

    [(#x4002)
     ;; Timer low 8 bits
     (set-box! (apu-pulse1-timer-box ap)
               (bitwise-ior
                (bitwise-and (unbox (apu-pulse1-timer-box ap)) #x700)
                val))]

    [(#x4003)
     ;; Timer high 3 bits + length counter load
     (set-box! (apu-pulse1-timer-box ap)
               (bitwise-ior
                (bitwise-and (unbox (apu-pulse1-timer-box ap)) #x0FF)
                (arithmetic-shift (bitwise-and val #x07) 8)))
     ;; Load length counter if channel enabled
     (when (unbox (apu-pulse1-enable-box ap))
       (set-box! (apu-pulse1-length-box ap)
                 (vector-ref LENGTH-TABLE (arithmetic-shift val -3))))
     ;; Restart envelope and reset sequence
     (set-box! (apu-pulse1-envelope-start-box ap) #t)
     (set-box! (apu-pulse1-sequence-pos-box ap) 0)]

    ;; ---- Pulse 2 ($4004-$4007) ----
    [(#x4004)
     (set-box! (apu-pulse2-duty-box ap) (extract val 6 2))
     (set-box! (apu-pulse2-halt-box ap) (bit? val 5))
     (set-box! (apu-pulse2-const-vol-box ap) (bit? val 4))
     (set-box! (apu-pulse2-volume-box ap) (bitwise-and val #x0F))]

    [(#x4005)
     (set-box! (apu-pulse2-sweep-enable-box ap) (bit? val 7))
     (set-box! (apu-pulse2-sweep-period-box ap) (extract val 4 3))
     (set-box! (apu-pulse2-sweep-negate-box ap) (bit? val 3))
     (set-box! (apu-pulse2-sweep-shift-box ap) (bitwise-and val #x07))
     (set-box! (apu-pulse2-sweep-reload-box ap) #t)]

    [(#x4006)
     (set-box! (apu-pulse2-timer-box ap)
               (bitwise-ior
                (bitwise-and (unbox (apu-pulse2-timer-box ap)) #x700)
                val))]

    [(#x4007)
     (set-box! (apu-pulse2-timer-box ap)
               (bitwise-ior
                (bitwise-and (unbox (apu-pulse2-timer-box ap)) #x0FF)
                (arithmetic-shift (bitwise-and val #x07) 8)))
     (when (unbox (apu-pulse2-enable-box ap))
       (set-box! (apu-pulse2-length-box ap)
                 (vector-ref LENGTH-TABLE (arithmetic-shift val -3))))
     ;; Restart envelope and reset sequence
     (set-box! (apu-pulse2-envelope-start-box ap) #t)
     (set-box! (apu-pulse2-sequence-pos-box ap) 0)]

    ;; ---- Triangle ($4008-$400B) ----
    [(#x4008)
     (set-box! (apu-tri-control-box ap) (bit? val 7))
     (set-box! (apu-tri-linear-load-box ap) (bitwise-and val #x7F))]

    [(#x4009)
     ;; Unused
     (void)]

    [(#x400A)
     (set-box! (apu-tri-timer-box ap)
               (bitwise-ior
                (bitwise-and (unbox (apu-tri-timer-box ap)) #x700)
                val))]

    [(#x400B)
     (set-box! (apu-tri-timer-box ap)
               (bitwise-ior
                (bitwise-and (unbox (apu-tri-timer-box ap)) #x0FF)
                (arithmetic-shift (bitwise-and val #x07) 8)))
     (when (unbox (apu-tri-enable-box ap))
       (set-box! (apu-tri-length-box ap)
                 (vector-ref LENGTH-TABLE (arithmetic-shift val -3))))
     ;; Set linear counter reload flag
     (set-box! (apu-tri-linear-reload-box ap) #t)]

    ;; ---- Noise ($400C-$400F) ----
    [(#x400C)
     (set-box! (apu-noise-halt-box ap) (bit? val 5))
     (set-box! (apu-noise-const-vol-box ap) (bit? val 4))
     (set-box! (apu-noise-volume-box ap) (bitwise-and val #x0F))]

    [(#x400D)
     ;; Unused
     (void)]

    [(#x400E)
     (set-box! (apu-noise-mode-box ap) (bit? val 7))
     (set-box! (apu-noise-period-box ap) (bitwise-and val #x0F))]

    [(#x400F)
     (when (unbox (apu-noise-enable-box ap))
       (set-box! (apu-noise-length-box ap)
                 (vector-ref LENGTH-TABLE (arithmetic-shift val -3))))
     ;; Restart envelope
     (set-box! (apu-noise-envelope-start-box ap) #t)]

    ;; ---- DMC ($4010-$4013) ----
    [(#x4010)
     (set-box! (apu-dmc-irq-enable-box ap) (bit? val 7))
     (set-box! (apu-dmc-loop-box ap) (bit? val 6))
     (set-box! (apu-dmc-rate-box ap) (bitwise-and val #x0F))
     ;; If IRQ disabled, clear IRQ flag
     (unless (bit? val 7)
       (set-box! (apu-dmc-irq-pending-box ap) #f))]

    [(#x4011)
     (set-box! (apu-dmc-output-box ap) (bitwise-and val #x7F))]

    [(#x4012)
     ;; Sample address = $C000 + (val * 64)
     (set-box! (apu-dmc-sample-addr-box ap)
               (+ #xC000 (* val 64)))]

    [(#x4013)
     ;; Sample length = (val * 16) + 1
     (set-box! (apu-dmc-sample-length-box ap)
               (+ (* val 16) 1))]

    ;; ---- Status ($4015) ----
    [(#x4015)
     ;; Channel enables
     (set-box! (apu-pulse1-enable-box ap) (bit? val 0))
     (set-box! (apu-pulse2-enable-box ap) (bit? val 1))
     (set-box! (apu-tri-enable-box ap) (bit? val 2))
     (set-box! (apu-noise-enable-box ap) (bit? val 3))

     ;; If a channel is disabled, its length counter is zeroed
     (unless (bit? val 0)
       (set-box! (apu-pulse1-length-box ap) 0))
     (unless (bit? val 1)
       (set-box! (apu-pulse2-length-box ap) 0))
     (unless (bit? val 2)
       (set-box! (apu-tri-length-box ap) 0))
     (unless (bit? val 3)
       (set-box! (apu-noise-length-box ap) 0))

     ;; DMC enable/disable
     (define dmc-was-enabled (unbox (apu-dmc-enable-box ap)))
     (define dmc-now-enabled (bit? val 4))
     (set-box! (apu-dmc-enable-box ap) dmc-now-enabled)

     ;; If DMC is enabled and bytes remaining is 0, restart sample
     (when (and dmc-now-enabled
                (= (unbox (apu-dmc-bytes-remaining-box ap)) 0))
       (set-box! (apu-dmc-current-addr-box ap)
                 (unbox (apu-dmc-sample-addr-box ap)))
       (set-box! (apu-dmc-bytes-remaining-box ap)
                 (unbox (apu-dmc-sample-length-box ap))))

     ;; If DMC is disabled, clear bytes remaining
     (unless dmc-now-enabled
       (set-box! (apu-dmc-bytes-remaining-box ap) 0))

     ;; Writing to $4015 clears DMC IRQ flag
     (set-box! (apu-dmc-irq-pending-box ap) #f)]

    ;; ---- Frame Counter ($4017) ----
    [(#x4017)
     (set-box! (apu-frame-mode-box ap) (if (bit? val 7) 1 0))
     (set-box! (apu-frame-irq-inhibit-box ap) (bit? val 6))

     ;; If IRQ inhibit set, clear frame IRQ
     (when (bit? val 6)
       (set-box! (apu-frame-irq-pending-box ap) #f))

     ;; Reset frame counter
     (set-box! (apu-frame-counter-box ap) 0)
     (set-box! (apu-frame-cycle-box ap) 0)

     ;; In 5-step mode, clock immediately
     (when (bit? val 7)
       (clock-quarter-frame! ap)
       (clock-half-frame! ap))]

    [else (void)]))

;; ============================================================================
;; Frame Counter Clocking
;; ============================================================================

;; Quarter frame: clock envelopes and triangle linear counter
(define (clock-quarter-frame! ap)
  ;; Clock triangle linear counter
  (cond
    [(unbox (apu-tri-linear-reload-box ap))
     (set-box! (apu-tri-linear-counter-box ap)
               (unbox (apu-tri-linear-load-box ap)))]
    [(> (unbox (apu-tri-linear-counter-box ap)) 0)
     (set-box! (apu-tri-linear-counter-box ap)
               (sub1 (unbox (apu-tri-linear-counter-box ap))))])

  ;; Clear reload flag if control flag is clear
  (unless (unbox (apu-tri-control-box ap))
    (set-box! (apu-tri-linear-reload-box ap) #f))

  ;; Clock pulse 1 envelope
  (clock-envelope! (apu-pulse1-envelope-start-box ap)
                   (apu-pulse1-envelope-decay-box ap)
                   (apu-pulse1-envelope-divider-box ap)
                   (apu-pulse1-volume-box ap)
                   (apu-pulse1-halt-box ap))  ; halt = loop

  ;; Clock pulse 2 envelope
  (clock-envelope! (apu-pulse2-envelope-start-box ap)
                   (apu-pulse2-envelope-decay-box ap)
                   (apu-pulse2-envelope-divider-box ap)
                   (apu-pulse2-volume-box ap)
                   (apu-pulse2-halt-box ap))

  ;; Clock noise envelope
  (clock-envelope! (apu-noise-envelope-start-box ap)
                   (apu-noise-envelope-decay-box ap)
                   (apu-noise-envelope-divider-box ap)
                   (apu-noise-volume-box ap)
                   (apu-noise-halt-box ap)))

;; Clock an envelope unit
(define (clock-envelope! start-box decay-box divider-box volume-box loop-box)
  (cond
    [(unbox start-box)
     ;; Start envelope
     (set-box! start-box #f)
     (set-box! decay-box 15)
     (set-box! divider-box (unbox volume-box))]
    [else
     ;; Clock divider
     (let ([divider (unbox divider-box)])
       (if (= divider 0)
           (let ([decay (unbox decay-box)])
             ;; Reload divider
             (set-box! divider-box (unbox volume-box))
             ;; Clock decay
             (if (> decay 0)
                 (set-box! decay-box (sub1 decay))
                 ;; Loop?
                 (when (unbox loop-box)
                   (set-box! decay-box 15))))
           ;; Decrement divider
           (set-box! divider-box (sub1 divider))))]))

;; Half frame: clock length counters and sweep units
(define (clock-half-frame! ap)
  ;; Clock length counters (only if not halted and channel enabled)
  (when (and (unbox (apu-pulse1-enable-box ap))
             (not (unbox (apu-pulse1-halt-box ap)))
             (> (unbox (apu-pulse1-length-box ap)) 0))
    (set-box! (apu-pulse1-length-box ap)
              (sub1 (unbox (apu-pulse1-length-box ap)))))

  (when (and (unbox (apu-pulse2-enable-box ap))
             (not (unbox (apu-pulse2-halt-box ap)))
             (> (unbox (apu-pulse2-length-box ap)) 0))
    (set-box! (apu-pulse2-length-box ap)
              (sub1 (unbox (apu-pulse2-length-box ap)))))

  (when (and (unbox (apu-tri-enable-box ap))
             (not (unbox (apu-tri-control-box ap)))  ; Control flag = halt
             (> (unbox (apu-tri-length-box ap)) 0))
    (set-box! (apu-tri-length-box ap)
              (sub1 (unbox (apu-tri-length-box ap)))))

  (when (and (unbox (apu-noise-enable-box ap))
             (not (unbox (apu-noise-halt-box ap)))
             (> (unbox (apu-noise-length-box ap)) 0))
    (set-box! (apu-noise-length-box ap)
              (sub1 (unbox (apu-noise-length-box ap)))))

  ;; Clock sweep units
  (clock-sweep! (apu-pulse1-sweep-enable-box ap)
                (apu-pulse1-sweep-period-box ap)
                (apu-pulse1-sweep-negate-box ap)
                (apu-pulse1-sweep-shift-box ap)
                (apu-pulse1-sweep-divider-box ap)
                (apu-pulse1-sweep-reload-box ap)
                (apu-pulse1-timer-box ap)
                0)  ; Channel 0 = pulse 1

  (clock-sweep! (apu-pulse2-sweep-enable-box ap)
                (apu-pulse2-sweep-period-box ap)
                (apu-pulse2-sweep-negate-box ap)
                (apu-pulse2-sweep-shift-box ap)
                (apu-pulse2-sweep-divider-box ap)
                (apu-pulse2-sweep-reload-box ap)
                (apu-pulse2-timer-box ap)
                1)) ; Channel 1 = pulse 2

;; Clock a sweep unit
(define (clock-sweep! enable-box period-box negate-box shift-box
                      divider-box reload-box timer-box channel-num)
  (define divider (unbox divider-box))
  (define period (unbox timer-box))
  (define shift (unbox shift-box))

  ;; Calculate target period
  (define change-amount (arithmetic-shift period (- shift)))
  (define target
    (if (unbox negate-box)
        ;; Pulse 1 uses one's complement, pulse 2 uses two's complement
        (- period change-amount (if (= channel-num 0) 1 0))
        (+ period change-amount)))

  ;; Clock the sweep
  (cond
    [(unbox reload-box)
     ;; Reload divider
     (set-box! divider-box (unbox period-box))
     (set-box! reload-box #f)
     ;; Also update period if conditions are met
     (when (and (= divider 0)
                (unbox enable-box)
                (> shift 0)
                (>= period 8)
                (<= target #x7FF))
       (set-box! timer-box target))]
    [(= divider 0)
     ;; Update period if conditions are met
     (set-box! divider-box (unbox period-box))
     (when (and (unbox enable-box)
                (> shift 0)
                (>= period 8)
                (<= target #x7FF))
       (set-box! timer-box target))]
    [else
     (set-box! divider-box (sub1 divider))]))

;; ============================================================================
;; DMC Tick (sample playback and DMA)
;; ============================================================================

;; Tick the DMC channel by one CPU cycle
;; Returns the number of CPU stall cycles caused by DMA this tick
(define (dmc-tick! ap)
  (define stall-cycles 0)

  ;; Only process if DMC is enabled
  (when (unbox (apu-dmc-enable-box ap))
    ;; Decrement timer
    (define timer (unbox (apu-dmc-timer-box ap)))
    (if (> timer 0)
        (set-box! (apu-dmc-timer-box ap) (sub1 timer))
        ;; Timer expired - output a bit and reload
        (begin
          ;; Reload timer from rate table
          (set-box! (apu-dmc-timer-box ap)
                    (vector-ref DMC-RATE-TABLE (unbox (apu-dmc-rate-box ap))))

          ;; If buffer is empty and bytes remain, start a DMA fetch
          (when (and (unbox (apu-dmc-buffer-empty-box ap))
                     (> (unbox (apu-dmc-bytes-remaining-box ap)) 0))
            ;; Fetch a sample byte - this steals CPU cycles!
            ;; The DMA takes 4 cycles normally, but can vary based on alignment
            ;; We'll use 4 as a reasonable approximation
            (define addr (unbox (apu-dmc-current-addr-box ap)))
            (define reader (unbox (apu-memory-reader-box ap)))
            (define sample-byte (reader addr))

            ;; Load sample buffer
            (set-box! (apu-dmc-sample-buffer-box ap) sample-byte)
            (set-box! (apu-dmc-buffer-empty-box ap) #f)
            (set-box! (apu-dmc-bits-remaining-box ap) 8)

            ;; Advance address (wraps from $FFFF to $8000)
            (define next-addr (add1 addr))
            (set-box! (apu-dmc-current-addr-box ap)
                      (if (> next-addr #xFFFF) #x8000 next-addr))

            ;; Decrement bytes remaining
            (set-box! (apu-dmc-bytes-remaining-box ap)
                      (sub1 (unbox (apu-dmc-bytes-remaining-box ap))))

            ;; Add DMA stall cycles
            (set-box! (apu-dmc-stall-cycles-box ap)
                      (+ (unbox (apu-dmc-stall-cycles-box ap)) 4))

            ;; Check if sample finished
            (when (= (unbox (apu-dmc-bytes-remaining-box ap)) 0)
              (cond
                ;; Loop: restart sample
                [(unbox (apu-dmc-loop-box ap))
                 (set-box! (apu-dmc-current-addr-box ap)
                           (unbox (apu-dmc-sample-addr-box ap)))
                 (set-box! (apu-dmc-bytes-remaining-box ap)
                           (unbox (apu-dmc-sample-length-box ap)))]
                ;; No loop: set IRQ if enabled
                [(unbox (apu-dmc-irq-enable-box ap))
                 (set-box! (apu-dmc-irq-pending-box ap) #t)])))

          ;; Shift out a bit from the sample buffer (if not empty)
          (unless (unbox (apu-dmc-buffer-empty-box ap))
            (define bits-remaining (unbox (apu-dmc-bits-remaining-box ap)))
            (when (> bits-remaining 0)
              ;; Get the current bit (LSB first)
              (define current-byte (unbox (apu-dmc-sample-buffer-box ap)))
              (define current-bit (bitwise-and current-byte 1))

              ;; Update output level based on bit
              (define output (unbox (apu-dmc-output-box ap)))
              (cond
                [(and (= current-bit 1) (< output 126))
                 (set-box! (apu-dmc-output-box ap) (+ output 2))]
                [(and (= current-bit 0) (> output 1))
                 (set-box! (apu-dmc-output-box ap) (- output 2))])

              ;; Shift buffer right
              (set-box! (apu-dmc-sample-buffer-box ap)
                        (arithmetic-shift current-byte -1))

              ;; Decrement bits remaining
              (set-box! (apu-dmc-bits-remaining-box ap) (sub1 bits-remaining))

              ;; Mark buffer empty when all bits shifted out
              (when (= bits-remaining 1)
                (set-box! (apu-dmc-buffer-empty-box ap) #t)))))))

  stall-cycles)

;; ============================================================================
;; Channel Timer Ticking
;; ============================================================================

;; Tick a pulse channel timer (called at CPU/2 rate)
(define (tick-pulse! timer-period-box timer-counter-box sequence-pos-box)
  (define counter (unbox timer-counter-box))
  (if (= counter 0)
      (begin
        ;; Reload timer and advance sequence (backwards)
        (set-box! timer-counter-box (unbox timer-period-box))
        (set-box! sequence-pos-box
                  (bitwise-and (sub1 (unbox sequence-pos-box)) 7)))
      ;; Decrement counter
      (set-box! timer-counter-box (sub1 counter))))

;; Tick the triangle channel timer (called at CPU rate)
(define (tick-triangle! ap)
  ;; Only tick if length counter and linear counter are nonzero
  (when (and (> (unbox (apu-tri-length-box ap)) 0)
             (> (unbox (apu-tri-linear-counter-box ap)) 0))
    (define counter (unbox (apu-tri-timer-counter-box ap)))
    (if (= counter 0)
        (begin
          ;; Reload timer and advance sequence
          (set-box! (apu-tri-timer-counter-box ap) (unbox (apu-tri-timer-box ap)))
          (set-box! (apu-tri-sequence-pos-box ap)
                    (bitwise-and (add1 (unbox (apu-tri-sequence-pos-box ap))) 31)))
        ;; Decrement counter
        (set-box! (apu-tri-timer-counter-box ap) (sub1 counter)))))

;; Tick the noise channel timer (called at CPU/2 rate)
(define (tick-noise! ap)
  (define counter (unbox (apu-noise-timer-counter-box ap)))
  (if (= counter 0)
      ;; Timer expired - clock LFSR
      (let* ([sr (unbox (apu-noise-shift-register-box ap))]
             ;; Feedback bit: XOR of bit 0 and bit 6 (mode 1) or bit 1 (mode 0)
             [feedback-bit
              (if (unbox (apu-noise-mode-box ap))
                  (bitwise-xor (bitwise-and sr 1)
                               (bitwise-and (arithmetic-shift sr -6) 1))
                  (bitwise-xor (bitwise-and sr 1)
                               (bitwise-and (arithmetic-shift sr -1) 1)))])
        ;; Reload timer from period table
        (set-box! (apu-noise-timer-counter-box ap)
                  (vector-ref NOISE-PERIOD-TABLE (unbox (apu-noise-period-box ap))))
        ;; Shift right and set bit 14 to feedback
        (set-box! (apu-noise-shift-register-box ap)
                  (bitwise-ior (arithmetic-shift sr -1)
                               (arithmetic-shift feedback-bit 14))))
      ;; Decrement counter
      (set-box! (apu-noise-timer-counter-box ap) (sub1 counter))))

;; ============================================================================
;; APU Tick (called each CPU cycle)
;; ============================================================================

(define (apu-tick! ap cycles)
  (define mode (unbox (apu-frame-mode-box ap)))
  (define step-cycles
    (if (= mode 0) FRAME-STEP-CYCLES-4STEP FRAME-STEP-CYCLES-5STEP))
  (define max-steps (if (= mode 0) 4 5))
  (define frame-length (if (= mode 0) FRAME-LENGTH-4STEP FRAME-LENGTH-5STEP))

  ;; Process each cycle
  (for ([_ (in-range cycles)])
    (define cycle-count (unbox (apu-cycle-count-box ap)))
    (set-box! (apu-cycle-count-box ap) (add1 cycle-count))

    ;; Tick channel timers
    ;; Triangle runs at CPU rate
    (tick-triangle! ap)

    ;; Pulse and noise run at CPU/2 rate (even cycles only)
    (when (even? cycle-count)
      (tick-pulse! (apu-pulse1-timer-box ap)
                   (apu-pulse1-timer-counter-box ap)
                   (apu-pulse1-sequence-pos-box ap))
      (tick-pulse! (apu-pulse2-timer-box ap)
                   (apu-pulse2-timer-counter-box ap)
                   (apu-pulse2-sequence-pos-box ap))
      (tick-noise! ap))

    ;; Tick DMC (may accumulate stall cycles)
    (dmc-tick! ap)

    (define current-cycle (unbox (apu-frame-cycle-box ap)))
    (define current-step (unbox (apu-frame-counter-box ap)))

    ;; Check if we've reached a step boundary
    (when (and (< current-step max-steps)
               (= current-cycle (vector-ref step-cycles current-step)))

      ;; Execute step actions
      (case current-step
        [(0)  ; Step 1: Quarter frame
         (clock-quarter-frame! ap)]

        [(1)  ; Step 2: Quarter + half frame
         (clock-quarter-frame! ap)
         (clock-half-frame! ap)]

        [(2)  ; Step 3: Quarter frame
         (clock-quarter-frame! ap)]

        [(3)  ; Step 4
         (cond
           [(= mode 0)
            ;; 4-step mode: quarter + half frame + set IRQ
            (clock-quarter-frame! ap)
            (clock-half-frame! ap)
            (unless (unbox (apu-frame-irq-inhibit-box ap))
              (set-box! (apu-frame-irq-pending-box ap) #t))]
           [else
            ;; 5-step mode: nothing (this step is "empty")
            (void)])]

        [(4)  ; Step 5 (5-step mode only): Quarter + half frame
         (clock-quarter-frame! ap)
         (clock-half-frame! ap)])

      ;; Advance to next step
      (set-box! (apu-frame-counter-box ap) (add1 current-step)))

    ;; Advance cycle counter
    (set-box! (apu-frame-cycle-box ap) (add1 current-cycle))

    ;; Reset frame counter if we've reached the frame length
    ;; In 4-step mode, also set IRQ on wrap (cycles 0 and 1 of next frame)
    (when (>= (unbox (apu-frame-cycle-box ap)) frame-length)
      ;; Set IRQ again at frame wrap in 4-step mode
      (when (and (= mode 0)
                 (not (unbox (apu-frame-irq-inhibit-box ap))))
        (set-box! (apu-frame-irq-pending-box ap) #t))
      (set-box! (apu-frame-counter-box ap) 0)
      (set-box! (apu-frame-cycle-box ap) 0))))

;; ============================================================================
;; IRQ Interface
;; ============================================================================

(define (apu-irq-pending? ap)
  (or (unbox (apu-frame-irq-pending-box ap))
      (unbox (apu-dmc-irq-pending-box ap))))

(define (apu-acknowledge-irq! ap)
  ;; Frame IRQ is acknowledged by reading $4015 (handled in apu-read)
  ;; DMC IRQ is acknowledged by writing to $4015 (handled in apu-write!)
  ;; This function is for external acknowledgment if needed
  (void))

;; ============================================================================
;; State Accessors (for debugging)
;; ============================================================================

(define (apu-frame-counter-mode ap)
  (unbox (apu-frame-mode-box ap)))

(define (apu-frame-irq-inhibit? ap)
  (unbox (apu-frame-irq-inhibit-box ap)))

(define (apu-frame-irq-pending? ap)
  (unbox (apu-frame-irq-pending-box ap)))

(define (apu-dmc-irq-pending? ap)
  (unbox (apu-dmc-irq-pending-box ap)))

(define (apu-dmc-bytes-remaining ap)
  (unbox (apu-dmc-bytes-remaining-box ap)))

;; ============================================================================
;; DMC DMA Interface (for system integration)
;; ============================================================================

;; Get accumulated DMC stall cycles (CPU cycles stolen by DMC DMA)
(define (apu-dmc-stall-cycles ap)
  (unbox (apu-dmc-stall-cycles-box ap)))

;; Clear stall cycles after system has consumed them
(define (apu-clear-dmc-stall-cycles! ap)
  (set-box! (apu-dmc-stall-cycles-box ap) 0))

;; Set the memory reader callback for DMC sample fetches
(define (apu-set-memory-reader! ap reader)
  (set-box! (apu-memory-reader-box ap) reader))

;; ============================================================================
;; Audio Output
;; ============================================================================

;; Calculate pulse channel output (0-15)
;; Handles muting conditions: length=0, timer<8, sweep overflow
(define (pulse-output ap duty-box timer-box length-box enable-box
                      const-vol-box volume-box envelope-decay-box
                      sequence-pos-box sweep-negate-box sweep-shift-box
                      channel-num)
  (define length (unbox length-box))
  (define timer (unbox timer-box))
  (define enabled (unbox enable-box))

  (cond
    ;; Muted if disabled, length=0, or timer<8
    [(or (not enabled) (= length 0) (< timer 8)) 0]
    ;; Check sweep muting (target period > $7FF)
    [(let* ([shift (unbox sweep-shift-box)]
            [change (arithmetic-shift timer (- shift))]
            [target (if (unbox sweep-negate-box)
                        (- timer change (if (= channel-num 0) 1 0))
                        (+ timer change))])
       (> target #x7FF))
     0]
    ;; Output based on duty cycle and envelope
    [else
     (define duty (unbox duty-box))
     (define pos (unbox sequence-pos-box))
     (define duty-seq (vector-ref DUTY-TABLE duty))
     (if (= (vector-ref duty-seq pos) 0)
         0
         (if (unbox const-vol-box)
             (unbox volume-box)
             (unbox envelope-decay-box)))]))

;; Get pulse 1 output (0-15)
(define (apu-pulse1-output ap)
  (pulse-output ap
                (apu-pulse1-duty-box ap)
                (apu-pulse1-timer-box ap)
                (apu-pulse1-length-box ap)
                (apu-pulse1-enable-box ap)
                (apu-pulse1-const-vol-box ap)
                (apu-pulse1-volume-box ap)
                (apu-pulse1-envelope-decay-box ap)
                (apu-pulse1-sequence-pos-box ap)
                (apu-pulse1-sweep-negate-box ap)
                (apu-pulse1-sweep-shift-box ap)
                0))

;; Get pulse 2 output (0-15)
(define (apu-pulse2-output ap)
  (pulse-output ap
                (apu-pulse2-duty-box ap)
                (apu-pulse2-timer-box ap)
                (apu-pulse2-length-box ap)
                (apu-pulse2-enable-box ap)
                (apu-pulse2-const-vol-box ap)
                (apu-pulse2-volume-box ap)
                (apu-pulse2-envelope-decay-box ap)
                (apu-pulse2-sequence-pos-box ap)
                (apu-pulse2-sweep-negate-box ap)
                (apu-pulse2-sweep-shift-box ap)
                1))

;; Get triangle output (0-15)
(define (apu-triangle-output ap)
  (cond
    [(not (unbox (apu-tri-enable-box ap))) 0]
    [(= (unbox (apu-tri-length-box ap)) 0) 0]
    [(= (unbox (apu-tri-linear-counter-box ap)) 0) 0]
    [else
     (vector-ref TRIANGLE-SEQUENCE (unbox (apu-tri-sequence-pos-box ap)))]))

;; Get noise output (0-15)
(define (apu-noise-output ap)
  (cond
    [(not (unbox (apu-noise-enable-box ap))) 0]
    [(= (unbox (apu-noise-length-box ap)) 0) 0]
    ;; Output is 0 if bit 0 of shift register is 1
    [(bit? (unbox (apu-noise-shift-register-box ap)) 0) 0]
    [else
     (if (unbox (apu-noise-const-vol-box ap))
         (unbox (apu-noise-volume-box ap))
         (unbox (apu-noise-envelope-decay-box ap)))]))

;; Get DMC output (0-127)
(define (apu-dmc-output ap)
  (unbox (apu-dmc-output-box ap)))

;; Get mixed audio output (0.0 to 1.0)
(define (apu-output ap)
  (mix-channels (apu-pulse1-output ap)
                (apu-pulse2-output ap)
                (apu-triangle-output ap)
                (apu-noise-output ap)
                (apu-dmc-output ap)))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "APU creation"
    (define ap (make-apu))
    (check-true (apu? ap))
    ;; Initial state: all channels disabled
    (check-equal? (apu-read ap #x4015) #x00))

  (test-case "channel enable/disable via $4015"
    (define ap (make-apu))

    ;; Configure DMC sample first
    (apu-write! ap #x4012 1)  ; Sample address
    (apu-write! ap #x4013 1)  ; Sample length = 17 bytes

    ;; Enable all channels
    (apu-write! ap #x4015 #x1F)

    ;; DMC bytes remaining should now be > 0 (sample started)
    (check-true (bit? (apu-read ap #x4015) 4))

    ;; Disable DMC
    (apu-write! ap #x4015 #x0F)
    (check-false (bit? (apu-read ap #x4015) 4)))

  (test-case "length counter loading"
    (define ap (make-apu))

    ;; Enable pulse 1
    (apu-write! ap #x4015 #x01)

    ;; Write to $4003 loads length counter
    ;; Top 5 bits = index into length table
    ;; Index 0 = length 10
    (apu-write! ap #x4003 #x00)
    (check-true (bit? (apu-read ap #x4015) 0))  ; Length > 0

    ;; Disable channel should zero length counter
    (apu-write! ap #x4015 #x00)
    (check-false (bit? (apu-read ap #x4015) 0)))

  (test-case "frame counter mode setting"
    (define ap (make-apu))

    ;; Default is 4-step mode
    (check-equal? (apu-frame-counter-mode ap) 0)

    ;; Set 5-step mode
    (apu-write! ap #x4017 #x80)
    (check-equal? (apu-frame-counter-mode ap) 1)

    ;; Set 4-step mode with IRQ inhibit
    (apu-write! ap #x4017 #x40)
    (check-equal? (apu-frame-counter-mode ap) 0)
    (check-true (apu-frame-irq-inhibit? ap)))

  (test-case "frame IRQ in 4-step mode"
    (define ap (make-apu))

    ;; Set 4-step mode, IRQ enabled
    (apu-write! ap #x4017 #x00)
    (check-false (apu-frame-irq-pending? ap))

    ;; Tick through one full frame (29830 cycles for 4-step mode)
    (apu-tick! ap 29830)

    ;; Frame IRQ should be pending
    (check-true (apu-frame-irq-pending? ap))

    ;; Reading $4015 clears frame IRQ
    (apu-read ap #x4015)
    (check-false (apu-frame-irq-pending? ap)))

  (test-case "no frame IRQ in 5-step mode"
    (define ap (make-apu))

    ;; Set 5-step mode
    (apu-write! ap #x4017 #x80)

    ;; Tick through more than a full 4-step frame
    (apu-tick! ap 20000)

    ;; No frame IRQ in 5-step mode
    (check-false (apu-frame-irq-pending? ap)))

  (test-case "frame IRQ inhibit"
    (define ap (make-apu))

    ;; Set 4-step mode with IRQ inhibit
    (apu-write! ap #x4017 #x40)

    ;; Tick through one full frame (29830 cycles for 4-step mode)
    (apu-tick! ap 29830)

    ;; Frame IRQ should NOT be pending (inhibited)
    (check-false (apu-frame-irq-pending? ap)))

  (test-case "length counter clocking"
    (define ap (make-apu))

    ;; Enable pulse 1 with halt disabled
    (apu-write! ap #x4015 #x01)
    (apu-write! ap #x4000 #x00)  ; Halt = false

    ;; Load length counter (index 1 = 254)
    (apu-write! ap #x4003 #x08)

    ;; Initial length
    (check-true (bit? (apu-read ap #x4015) 0))

    ;; Tick past first half-frame point (around 7457 cycles)
    (apu-tick! ap 7457)

    ;; Length counter should have been decremented
    ;; (It starts at 254, should now be 253)
    (check-true (bit? (apu-read ap #x4015) 0))))
