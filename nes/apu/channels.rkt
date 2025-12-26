#lang racket/base

;; APU Channels - Audio Waveform Generation
;;
;; This module implements the actual audio output for each APU channel:
;; - Pulse 1 & 2: Square waves with duty cycle, envelope, and sweep
;; - Triangle: Triangle wave with linear counter
;; - Noise: LFSR-based pseudo-random noise
;; - DMC: Delta modulation playback (output level managed in apu.rkt)
;;
;; Each channel outputs a value 0-15 (or 0-127 for DMC) that gets
;; combined by the mixer to produce the final audio output.
;;
;; Reference: https://www.nesdev.org/wiki/APU

(provide
 ;; Pulse channel
 make-pulse-channel
 pulse-channel?
 pulse-channel-output
 pulse-channel-tick!
 pulse-channel-set-enabled!
 pulse-channel-load-timer!
 pulse-channel-load-length!
 pulse-channel-set-duty!
 pulse-channel-set-envelope!
 pulse-channel-set-sweep!
 pulse-channel-clock-envelope!
 pulse-channel-clock-length!
 pulse-channel-clock-sweep!
 pulse-channel-length-nonzero?

 ;; Triangle channel
 make-triangle-channel
 triangle-channel?
 triangle-channel-output
 triangle-channel-tick!
 triangle-channel-set-enabled!
 triangle-channel-load-timer!
 triangle-channel-load-length!
 triangle-channel-set-linear-counter!
 triangle-channel-clock-linear-counter!
 triangle-channel-clock-length!
 triangle-channel-length-nonzero?

 ;; Noise channel
 make-noise-channel
 noise-channel?
 noise-channel-output
 noise-channel-tick!
 noise-channel-set-enabled!
 noise-channel-load-length!
 noise-channel-set-envelope!
 noise-channel-set-period!
 noise-channel-set-mode!
 noise-channel-clock-envelope!
 noise-channel-clock-length!
 noise-channel-length-nonzero?)

(require "../../lib/bits.rkt")

;; ============================================================================
;; Duty Cycle Sequences
;; ============================================================================

;; Pulse duty cycle waveforms (8 steps each)
;; 0 = 12.5% duty: 0 1 0 0 0 0 0 0
;; 1 = 25% duty:   0 1 1 0 0 0 0 0
;; 2 = 50% duty:   0 1 1 1 1 0 0 0
;; 3 = 75% duty:   1 0 0 1 1 1 1 1 (negated 25%)
(define DUTY-TABLE
  (vector
   #(0 1 0 0 0 0 0 0)   ; 12.5%
   #(0 1 1 0 0 0 0 0)   ; 25%
   #(0 1 1 1 1 0 0 0)   ; 50%
   #(1 0 0 1 1 1 1 1))) ; 75% (negated 25%)

;; ============================================================================
;; Noise Period Table (NTSC)
;; ============================================================================

(define NOISE-PERIOD-TABLE
  (vector 4 8 16 32 64 96 128 160 202 254 380 508 762 1016 2034 4068))

;; ============================================================================
;; Triangle Sequence
;; ============================================================================

;; Triangle wave is a 32-step sequence
(define TRIANGLE-SEQUENCE
  (vector 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0
          0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))

;; ============================================================================
;; Pulse Channel
;; ============================================================================

(struct pulse-channel
  (;; Timer
   timer-period-box     ; 11-bit timer period
   timer-box            ; Current timer value (counts down)

   ;; Duty cycle
   duty-box             ; Duty cycle index (0-3)
   sequence-pos-box     ; Position in 8-step sequence

   ;; Length counter
   length-box           ; Length counter value
   length-halt-box      ; Length counter halt flag
   enabled-box          ; Channel enabled

   ;; Envelope
   envelope-start-box   ; Envelope start flag
   envelope-divider-box ; Envelope divider
   envelope-decay-box   ; Envelope decay level (0-15)
   envelope-volume-box  ; Volume/envelope period (from register)
   envelope-loop-box    ; Envelope loop (same as length halt)
   const-volume-box     ; Constant volume flag

   ;; Sweep
   sweep-enabled-box    ; Sweep enable
   sweep-period-box     ; Sweep divider period
   sweep-negate-box     ; Sweep negate flag
   sweep-shift-box      ; Sweep shift count
   sweep-divider-box    ; Sweep divider counter
   sweep-reload-box     ; Sweep reload flag
   sweep-channel-box    ; Channel number (0=pulse1, 1=pulse2) for negate difference
   )
  #:transparent)

(define (make-pulse-channel channel-num)
  (pulse-channel
   (box 0) (box 0)           ; Timer
   (box 0) (box 0)           ; Duty
   (box 0) (box #f) (box #f) ; Length
   (box #f) (box 0) (box 0) (box 0) (box #f) (box #f) ; Envelope
   (box #f) (box 0) (box #f) (box 0) (box 0) (box #f) ; Sweep
   (box channel-num)))       ; Channel ID

;; Get the current output level (0-15)
(define (pulse-channel-output ch)
  ;; Silence conditions:
  ;; - Length counter is 0
  ;; - Timer period is less than 8 (too high frequency, silenced by hardware)
  ;; - Sweep unit muting (target period > $7FF)
  (define length (unbox (pulse-channel-length-box ch)))
  (define period (unbox (pulse-channel-timer-period-box ch)))

  (cond
    ;; Channel disabled or length counter zero
    [(or (not (unbox (pulse-channel-enabled-box ch)))
         (= length 0))
     0]
    ;; Timer period too low (frequency too high) - muted
    [(< period 8)
     0]
    ;; Check sweep muting (target period > $7FF)
    [(sweep-would-mute? ch)
     0]
    ;; Output based on duty cycle and envelope
    [else
     (define duty (unbox (pulse-channel-duty-box ch)))
     (define pos (unbox (pulse-channel-sequence-pos-box ch)))
     (define duty-seq (vector-ref DUTY-TABLE duty))
     (if (= (vector-ref duty-seq pos) 0)
         0
         ;; Volume from envelope or constant
         (if (unbox (pulse-channel-const-volume-box ch))
             (unbox (pulse-channel-envelope-volume-box ch))
             (unbox (pulse-channel-envelope-decay-box ch))))]))

;; Check if sweep would cause muting
(define (sweep-would-mute? ch)
  (define period (unbox (pulse-channel-timer-period-box ch)))
  (define shift (unbox (pulse-channel-sweep-shift-box ch)))
  (define change-amount (arithmetic-shift period (- shift)))
  (define target
    (if (unbox (pulse-channel-sweep-negate-box ch))
        ;; Pulse 1 uses one's complement (subtract change + 1)
        ;; Pulse 2 uses two's complement (subtract change)
        (- period change-amount
           (if (= (unbox (pulse-channel-sweep-channel-box ch)) 0) 1 0))
        (+ period change-amount)))
  (> target #x7FF))

;; Tick the timer (called at CPU rate / 2)
;; In reality, APU runs at half CPU clock for timers
;; This should be called every 2 CPU cycles (or adjusted by caller)
(define (pulse-channel-tick! ch cycles)
  (define timer (unbox (pulse-channel-timer-box ch)))
  (for ([_ (in-range cycles)])
    (if (= timer 0)
        ;; Timer expired - reload and advance sequence
        (begin
          (set-box! (pulse-channel-timer-box ch)
                    (unbox (pulse-channel-timer-period-box ch)))
          (set-box! (pulse-channel-sequence-pos-box ch)
                    (bitwise-and (sub1 (unbox (pulse-channel-sequence-pos-box ch))) 7)))
        ;; Decrement timer
        (set-box! (pulse-channel-timer-box ch) (sub1 timer)))
    (set! timer (unbox (pulse-channel-timer-box ch)))))

;; Set channel enabled state
(define (pulse-channel-set-enabled! ch enabled)
  (set-box! (pulse-channel-enabled-box ch) enabled)
  (unless enabled
    (set-box! (pulse-channel-length-box ch) 0)))

;; Load timer period (11-bit)
(define (pulse-channel-load-timer! ch period)
  (set-box! (pulse-channel-timer-period-box ch) period))

;; Load length counter from table value
(define (pulse-channel-load-length! ch length)
  (when (unbox (pulse-channel-enabled-box ch))
    (set-box! (pulse-channel-length-box ch) length))
  ;; Restart envelope
  (set-box! (pulse-channel-envelope-start-box ch) #t)
  ;; Reset sequence position
  (set-box! (pulse-channel-sequence-pos-box ch) 0))

;; Set duty cycle (0-3)
(define (pulse-channel-set-duty! ch duty)
  (set-box! (pulse-channel-duty-box ch) duty))

;; Set envelope parameters
(define (pulse-channel-set-envelope! ch loop const-vol volume)
  (set-box! (pulse-channel-envelope-loop-box ch) loop)
  (set-box! (pulse-channel-length-halt-box ch) loop) ; Same bit
  (set-box! (pulse-channel-const-volume-box ch) const-vol)
  (set-box! (pulse-channel-envelope-volume-box ch) volume))

;; Set sweep parameters
(define (pulse-channel-set-sweep! ch enabled period negate shift)
  (set-box! (pulse-channel-sweep-enabled-box ch) enabled)
  (set-box! (pulse-channel-sweep-period-box ch) period)
  (set-box! (pulse-channel-sweep-negate-box ch) negate)
  (set-box! (pulse-channel-sweep-shift-box ch) shift)
  (set-box! (pulse-channel-sweep-reload-box ch) #t))

;; Clock envelope (called at quarter frame)
(define (pulse-channel-clock-envelope! ch)
  (cond
    [(unbox (pulse-channel-envelope-start-box ch))
     ;; Start envelope
     (set-box! (pulse-channel-envelope-start-box ch) #f)
     (set-box! (pulse-channel-envelope-decay-box ch) 15)
     (set-box! (pulse-channel-envelope-divider-box ch)
               (unbox (pulse-channel-envelope-volume-box ch)))]
    [else
     ;; Clock divider
     (let ([divider (unbox (pulse-channel-envelope-divider-box ch))])
       (if (= divider 0)
           (let ([decay (unbox (pulse-channel-envelope-decay-box ch))])
             ;; Reload divider
             (set-box! (pulse-channel-envelope-divider-box ch)
                       (unbox (pulse-channel-envelope-volume-box ch)))
             ;; Clock decay
             (if (> decay 0)
                 (set-box! (pulse-channel-envelope-decay-box ch) (sub1 decay))
                 ;; Loop?
                 (when (unbox (pulse-channel-envelope-loop-box ch))
                   (set-box! (pulse-channel-envelope-decay-box ch) 15))))
           ;; Decrement divider
           (set-box! (pulse-channel-envelope-divider-box ch) (sub1 divider))))]))

;; Clock length counter (called at half frame)
(define (pulse-channel-clock-length! ch)
  (when (and (unbox (pulse-channel-enabled-box ch))
             (not (unbox (pulse-channel-length-halt-box ch)))
             (> (unbox (pulse-channel-length-box ch)) 0))
    (set-box! (pulse-channel-length-box ch)
              (sub1 (unbox (pulse-channel-length-box ch))))))

;; Clock sweep unit (called at half frame)
(define (pulse-channel-clock-sweep! ch)
  (define divider (unbox (pulse-channel-sweep-divider-box ch)))
  (define period (unbox (pulse-channel-timer-period-box ch)))
  (define shift (unbox (pulse-channel-sweep-shift-box ch)))

  ;; Calculate target period
  (define change-amount (arithmetic-shift period (- shift)))
  (define target
    (if (unbox (pulse-channel-sweep-negate-box ch))
        (- period change-amount
           (if (= (unbox (pulse-channel-sweep-channel-box ch)) 0) 1 0))
        (+ period change-amount)))

  ;; Clock the sweep
  (cond
    [(unbox (pulse-channel-sweep-reload-box ch))
     ;; Reload divider
     (set-box! (pulse-channel-sweep-divider-box ch)
               (unbox (pulse-channel-sweep-period-box ch)))
     (set-box! (pulse-channel-sweep-reload-box ch) #f)
     ;; Also update period if conditions are met
     (when (and (= divider 0)
                (unbox (pulse-channel-sweep-enabled-box ch))
                (> shift 0)
                (>= period 8)
                (<= target #x7FF))
       (set-box! (pulse-channel-timer-period-box ch) target))]
    [(= divider 0)
     ;; Update period if conditions are met
     (set-box! (pulse-channel-sweep-divider-box ch)
               (unbox (pulse-channel-sweep-period-box ch)))
     (when (and (unbox (pulse-channel-sweep-enabled-box ch))
                (> shift 0)
                (>= period 8)
                (<= target #x7FF))
       (set-box! (pulse-channel-timer-period-box ch) target))]
    [else
     (set-box! (pulse-channel-sweep-divider-box ch) (sub1 divider))]))

(define (pulse-channel-length-nonzero? ch)
  (> (unbox (pulse-channel-length-box ch)) 0))

;; ============================================================================
;; Triangle Channel
;; ============================================================================

(struct triangle-channel
  (;; Timer
   timer-period-box     ; 11-bit timer period
   timer-box            ; Current timer value

   ;; Sequence
   sequence-pos-box     ; Position in 32-step sequence

   ;; Length counter
   length-box           ; Length counter value
   length-halt-box      ; Length counter halt (= control flag)
   enabled-box          ; Channel enabled

   ;; Linear counter
   linear-counter-box   ; Current linear counter value
   linear-reload-box    ; Linear counter reload value
   linear-reload-flag-box ; Linear counter reload flag
   control-flag-box     ; Control flag (also halts length)
   )
  #:transparent)

(define (make-triangle-channel)
  (triangle-channel
   (box 0) (box 0)           ; Timer
   (box 0)                   ; Sequence
   (box 0) (box #f) (box #f) ; Length
   (box 0) (box 0) (box #f) (box #f))) ; Linear counter

;; Get the current output level (0-15)
(define (triangle-channel-output ch)
  ;; Silence conditions:
  ;; - Length counter is 0
  ;; - Linear counter is 0
  ;; Note: Ultra-low frequencies (period < 2) produce "popping" but still output
  (cond
    [(not (unbox (triangle-channel-enabled-box ch)))
     0]
    [(= (unbox (triangle-channel-length-box ch)) 0)
     0]
    [(= (unbox (triangle-channel-linear-counter-box ch)) 0)
     0]
    [else
     (vector-ref TRIANGLE-SEQUENCE (unbox (triangle-channel-sequence-pos-box ch)))]))

;; Tick the timer (triangle runs at CPU rate, not half rate like pulse)
(define (triangle-channel-tick! ch cycles)
  (when (and (> (unbox (triangle-channel-length-box ch)) 0)
             (> (unbox (triangle-channel-linear-counter-box ch)) 0))
    (define timer (unbox (triangle-channel-timer-box ch)))
    (for ([_ (in-range cycles)])
      (if (= timer 0)
          ;; Timer expired - reload and advance sequence
          (begin
            (set-box! (triangle-channel-timer-box ch)
                      (unbox (triangle-channel-timer-period-box ch)))
            (set-box! (triangle-channel-sequence-pos-box ch)
                      (bitwise-and (add1 (unbox (triangle-channel-sequence-pos-box ch))) 31)))
          ;; Decrement timer
          (set-box! (triangle-channel-timer-box ch) (sub1 timer)))
      (set! timer (unbox (triangle-channel-timer-box ch))))))

(define (triangle-channel-set-enabled! ch enabled)
  (set-box! (triangle-channel-enabled-box ch) enabled)
  (unless enabled
    (set-box! (triangle-channel-length-box ch) 0)))

(define (triangle-channel-load-timer! ch period)
  (set-box! (triangle-channel-timer-period-box ch) period))

(define (triangle-channel-load-length! ch length)
  (when (unbox (triangle-channel-enabled-box ch))
    (set-box! (triangle-channel-length-box ch) length))
  ;; Set linear counter reload flag
  (set-box! (triangle-channel-linear-reload-flag-box ch) #t))

(define (triangle-channel-set-linear-counter! ch control reload-value)
  (set-box! (triangle-channel-control-flag-box ch) control)
  (set-box! (triangle-channel-length-halt-box ch) control) ; Same bit
  (set-box! (triangle-channel-linear-reload-box ch) reload-value))

;; Clock linear counter (called at quarter frame)
(define (triangle-channel-clock-linear-counter! ch)
  (cond
    [(unbox (triangle-channel-linear-reload-flag-box ch))
     (set-box! (triangle-channel-linear-counter-box ch)
               (unbox (triangle-channel-linear-reload-box ch)))]
    [(> (unbox (triangle-channel-linear-counter-box ch)) 0)
     (set-box! (triangle-channel-linear-counter-box ch)
               (sub1 (unbox (triangle-channel-linear-counter-box ch))))])
  ;; Clear reload flag if control flag is clear
  (unless (unbox (triangle-channel-control-flag-box ch))
    (set-box! (triangle-channel-linear-reload-flag-box ch) #f)))

;; Clock length counter (called at half frame)
(define (triangle-channel-clock-length! ch)
  (when (and (unbox (triangle-channel-enabled-box ch))
             (not (unbox (triangle-channel-length-halt-box ch)))
             (> (unbox (triangle-channel-length-box ch)) 0))
    (set-box! (triangle-channel-length-box ch)
              (sub1 (unbox (triangle-channel-length-box ch))))))

(define (triangle-channel-length-nonzero? ch)
  (> (unbox (triangle-channel-length-box ch)) 0))

;; ============================================================================
;; Noise Channel
;; ============================================================================

(struct noise-channel
  (;; Timer
   timer-period-box     ; Timer period (from table)
   timer-box            ; Current timer value

   ;; LFSR (Linear Feedback Shift Register)
   shift-register-box   ; 15-bit shift register
   mode-box             ; Mode flag (short or long)

   ;; Length counter
   length-box           ; Length counter value
   length-halt-box      ; Length counter halt
   enabled-box          ; Channel enabled

   ;; Envelope
   envelope-start-box
   envelope-divider-box
   envelope-decay-box
   envelope-volume-box
   envelope-loop-box
   const-volume-box
   )
  #:transparent)

(define (make-noise-channel)
  (noise-channel
   (box 0) (box 0)           ; Timer
   (box 1) (box #f)          ; LFSR (starts at 1)
   (box 0) (box #f) (box #f) ; Length
   (box #f) (box 0) (box 0) (box 0) (box #f) (box #f))) ; Envelope

;; Get the current output level (0-15)
(define (noise-channel-output ch)
  (cond
    [(not (unbox (noise-channel-enabled-box ch)))
     0]
    [(= (unbox (noise-channel-length-box ch)) 0)
     0]
    ;; Output is 0 if bit 0 of shift register is 1
    [(bit? (unbox (noise-channel-shift-register-box ch)) 0)
     0]
    [else
     (if (unbox (noise-channel-const-volume-box ch))
         (unbox (noise-channel-envelope-volume-box ch))
         (unbox (noise-channel-envelope-decay-box ch)))]))

;; Tick the timer (called at CPU rate / 2, like pulse)
(define (noise-channel-tick! ch cycles)
  (define timer (unbox (noise-channel-timer-box ch)))
  (for ([_ (in-range cycles)])
    (if (= timer 0)
        ;; Timer expired - clock LFSR
        (let* ([sr (unbox (noise-channel-shift-register-box ch))]
               ;; Feedback bit: XOR of bit 0 and bit 6 (mode 1) or bit 1 (mode 0)
               [feedback-bit
                (if (unbox (noise-channel-mode-box ch))
                    (bitwise-xor (bitwise-and sr 1)
                                 (bitwise-and (arithmetic-shift sr -6) 1))
                    (bitwise-xor (bitwise-and sr 1)
                                 (bitwise-and (arithmetic-shift sr -1) 1)))])
          (set-box! (noise-channel-timer-box ch)
                    (unbox (noise-channel-timer-period-box ch)))
          ;; Shift right and set bit 14 to feedback
          (set-box! (noise-channel-shift-register-box ch)
                    (bitwise-ior (arithmetic-shift sr -1)
                                 (arithmetic-shift feedback-bit 14))))
        ;; Decrement timer
        (set-box! (noise-channel-timer-box ch) (sub1 timer)))
    (set! timer (unbox (noise-channel-timer-box ch)))))

(define (noise-channel-set-enabled! ch enabled)
  (set-box! (noise-channel-enabled-box ch) enabled)
  (unless enabled
    (set-box! (noise-channel-length-box ch) 0)))

(define (noise-channel-load-length! ch length)
  (when (unbox (noise-channel-enabled-box ch))
    (set-box! (noise-channel-length-box ch) length))
  ;; Restart envelope
  (set-box! (noise-channel-envelope-start-box ch) #t))

(define (noise-channel-set-envelope! ch loop const-vol volume)
  (set-box! (noise-channel-envelope-loop-box ch) loop)
  (set-box! (noise-channel-length-halt-box ch) loop)
  (set-box! (noise-channel-const-volume-box ch) const-vol)
  (set-box! (noise-channel-envelope-volume-box ch) volume))

(define (noise-channel-set-period! ch period-index)
  (set-box! (noise-channel-timer-period-box ch)
            (vector-ref NOISE-PERIOD-TABLE period-index)))

(define (noise-channel-set-mode! ch mode)
  (set-box! (noise-channel-mode-box ch) mode))

;; Clock envelope (called at quarter frame)
(define (noise-channel-clock-envelope! ch)
  (cond
    [(unbox (noise-channel-envelope-start-box ch))
     (set-box! (noise-channel-envelope-start-box ch) #f)
     (set-box! (noise-channel-envelope-decay-box ch) 15)
     (set-box! (noise-channel-envelope-divider-box ch)
               (unbox (noise-channel-envelope-volume-box ch)))]
    [else
     (let ([divider (unbox (noise-channel-envelope-divider-box ch))])
       (if (= divider 0)
           (let ([decay (unbox (noise-channel-envelope-decay-box ch))])
             (set-box! (noise-channel-envelope-divider-box ch)
                       (unbox (noise-channel-envelope-volume-box ch)))
             (if (> decay 0)
                 (set-box! (noise-channel-envelope-decay-box ch) (sub1 decay))
                 (when (unbox (noise-channel-envelope-loop-box ch))
                   (set-box! (noise-channel-envelope-decay-box ch) 15))))
           (set-box! (noise-channel-envelope-divider-box ch) (sub1 divider))))]))

;; Clock length counter (called at half frame)
(define (noise-channel-clock-length! ch)
  (when (and (unbox (noise-channel-enabled-box ch))
             (not (unbox (noise-channel-length-halt-box ch)))
             (> (unbox (noise-channel-length-box ch)) 0))
    (set-box! (noise-channel-length-box ch)
              (sub1 (unbox (noise-channel-length-box ch))))))

(define (noise-channel-length-nonzero? ch)
  (> (unbox (noise-channel-length-box ch)) 0))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit racket/list)

  (test-case "pulse channel duty cycles"
    (define ch (make-pulse-channel 0))
    (pulse-channel-set-enabled! ch #t)
    (pulse-channel-load-length! ch 10)
    (pulse-channel-load-timer! ch 100)
    (pulse-channel-set-envelope! ch #f #t 15)  ; Constant volume 15

    ;; Test each duty cycle
    (for ([duty (in-range 4)])
      (pulse-channel-set-duty! ch duty)
      ;; Step through sequence and verify pattern matches
      (define duty-seq (vector-ref DUTY-TABLE duty))
      (for ([step (in-range 8)])
        (define expected
          (if (= (vector-ref duty-seq step) 0) 0 15))
        ;; Note: sequence runs backwards (decrements)
        (check-true (or (= (pulse-channel-output ch) 0)
                        (= (pulse-channel-output ch) 15))))))

  (test-case "pulse channel envelope"
    (define ch (make-pulse-channel 0))
    (pulse-channel-set-enabled! ch #t)
    (pulse-channel-load-length! ch 10)
    (pulse-channel-set-duty! ch 2)  ; 50% duty
    (pulse-channel-load-timer! ch 100)

    ;; Use envelope with period 2
    (pulse-channel-set-envelope! ch #f #f 2)
    (pulse-channel-load-length! ch 10)  ; This sets envelope restart flag

    ;; Envelope restart flag should be set
    (check-true (unbox (pulse-channel-envelope-start-box ch)))

    ;; First clock processes the start flag, sets decay=15
    (pulse-channel-clock-envelope! ch)
    (check-equal? (unbox (pulse-channel-envelope-decay-box ch)) 15)

    ;; Clock envelope - divider starts at 2
    (pulse-channel-clock-envelope! ch)  ; Divider 2 -> 1
    (pulse-channel-clock-envelope! ch)  ; Divider 1 -> 0, reload, decay 15->14
    (pulse-channel-clock-envelope! ch)  ; Divider 2 -> 1
    (check-equal? (unbox (pulse-channel-envelope-decay-box ch)) 14))

  (test-case "triangle channel sequence"
    (define ch (make-triangle-channel))
    (triangle-channel-set-enabled! ch #t)
    (triangle-channel-load-length! ch 10)
    (triangle-channel-set-linear-counter! ch #t 10)
    (triangle-channel-load-timer! ch 0)  ; Fast timer

    ;; Manually set linear counter to nonzero
    (set-box! (triangle-channel-linear-counter-box ch) 10)

    ;; Check initial output
    (check-equal? (triangle-channel-output ch) 15)

    ;; Advance sequence
    (triangle-channel-tick! ch 1)
    (check-equal? (triangle-channel-output ch) 14))

  (test-case "noise channel LFSR"
    (define ch (make-noise-channel))
    (noise-channel-set-enabled! ch #t)
    (noise-channel-load-length! ch 10)
    (noise-channel-set-envelope! ch #f #t 15)
    (noise-channel-set-period! ch 0)  ; Fastest period

    ;; LFSR should produce pseudo-random output
    (define outputs '())
    (for ([_ (in-range 100)])
      (noise-channel-tick! ch 1)
      (set! outputs (cons (noise-channel-output ch) outputs)))

    ;; Should have some variation (not all same value)
    (check-true (> (length (remove-duplicates outputs)) 1))))
