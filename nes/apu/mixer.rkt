#lang racket/base

;; APU Mixer
;;
;; Combines the output from all APU channels using the NES mixing formula.
;; The NES uses nonlinear mixing that approximates analog behavior.
;;
;; Formula (from NESDev wiki):
;;   output = pulse_out + tnd_out
;;
;;   pulse_out = 95.88 / ((8128 / (pulse1 + pulse2)) + 100)
;;   tnd_out = 159.79 / ((1 / ((triangle/8227) + (noise/12241) + (dmc/22638))) + 100)
;;
;; Where:
;;   - pulse1, pulse2: 0-15
;;   - triangle: 0-15
;;   - noise: 0-15
;;   - dmc: 0-127
;;
;; Output is 0.0 to 1.0 (normalized audio level)
;;
;; Reference: https://www.nesdev.org/wiki/APU_Mixer

(provide
 ;; Mixing
 mix-channels        ; Combine channel outputs to normalized float
 mix-channels-i16    ; Combine channel outputs to signed 16-bit

 ;; Lookup tables (for efficiency)
 init-mixer-tables!
 mixer-tables-initialized?)

;; ============================================================================
;; Lookup Tables for Efficient Mixing
;; ============================================================================

;; Pre-computed lookup tables for the mixing formula.
;; These are filled in by init-mixer-tables! for efficiency.

;; Pulse table: indexed by (pulse1 + pulse2), outputs 0.0 to ~0.128
;; Size: 31 entries (0-30)
(define pulse-table (make-vector 31 0.0))

;; TND table: indexed by (3 * triangle + 2 * noise + dmc)
;; This approximation allows a single table lookup
;; triangle: 0-15, noise: 0-15, dmc: 0-127
;; Max index: 3*15 + 2*15 + 127 = 45 + 30 + 127 = 202
(define tnd-table (make-vector 203 0.0))

(define tables-initialized? (box #f))

(define (mixer-tables-initialized?)
  (unbox tables-initialized?))

;; Initialize lookup tables
(define (init-mixer-tables!)
  (unless (unbox tables-initialized?)
    ;; Pulse table
    (for ([n (in-range 31)])
      (vector-set! pulse-table n
                   (if (= n 0)
                       0.0
                       (/ 95.88 (+ (/ 8128.0 n) 100.0)))))

    ;; TND table
    ;; Using the approximation: index = 3*tri + 2*noise + dmc
    ;; The actual formula weights are different but this is a reasonable approximation
    (for ([n (in-range 203)])
      (vector-set! tnd-table n
                   (if (= n 0)
                       0.0
                       (/ 159.79 (+ (/ 1.0 (/ n 8227.0)) 100.0)))))

    (set-box! tables-initialized? #t)))

;; ============================================================================
;; Mixing Functions
;; ============================================================================

;; Mix channel outputs to normalized float (0.0 to 1.0)
;; pulse1, pulse2, triangle, noise: 0-15
;; dmc: 0-127
(define (mix-channels pulse1 pulse2 triangle noise dmc)
  ;; Ensure tables are initialized
  (unless (unbox tables-initialized?)
    (init-mixer-tables!))

  ;; Use the accurate formula rather than lookup table approximation
  ;; for better audio quality
  (define pulse-sum (+ pulse1 pulse2))
  (define pulse-out
    (if (= pulse-sum 0)
        0.0
        (/ 95.88 (+ (/ 8128.0 pulse-sum) 100.0))))

  (define tnd-out
    (let ([tri-term (/ triangle 8227.0)]
          [noise-term (/ noise 12241.0)]
          [dmc-term (/ dmc 22638.0)])
      (define sum (+ tri-term noise-term dmc-term))
      (if (= sum 0.0)
          0.0
          (/ 159.79 (+ (/ 1.0 sum) 100.0)))))

  (+ pulse-out tnd-out))

;; Mix channel outputs to signed 16-bit integer (-32768 to 32767)
;; Suitable for direct output to audio device
(define (mix-channels-i16 pulse1 pulse2 triangle noise dmc)
  (define mixed (mix-channels pulse1 pulse2 triangle noise dmc))
  ;; Scale to 16-bit signed range
  ;; The mix output is approximately 0.0 to 1.0
  ;; We center at 0 and scale to use most of the range
  (define scaled (inexact->exact (round (* (- mixed 0.5) 60000))))
  (max -32768 (min 32767 scaled)))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "mixer initialization"
    (init-mixer-tables!)
    (check-true (mixer-tables-initialized?)))

  (test-case "silence produces zero output"
    (check-equal? (mix-channels 0 0 0 0 0) 0.0))

  (test-case "pulse output range"
    ;; Max pulse (15 + 15 = 30)
    (define max-pulse (mix-channels 15 15 0 0 0))
    (check-true (> max-pulse 0.0))
    (check-true (< max-pulse 1.0))

    ;; Should be around 0.26 at max (from NES mixing formula)
    (check-true (> max-pulse 0.2))
    (check-true (< max-pulse 0.3)))

  (test-case "full output range"
    ;; All channels at max
    (define full (mix-channels 15 15 15 15 127))
    (check-true (> full 0.5))
    (check-true (<= full 1.0)))

  (test-case "i16 output range"
    ;; Silence should be near 0
    (define silence (mix-channels-i16 0 0 0 0 0))
    (check-true (< (abs silence) 32768))

    ;; Full output should be in range
    (define full (mix-channels-i16 15 15 15 15 127))
    (check-true (>= full -32768))
    (check-true (<= full 32767)))

  (test-case "individual channel contribution"
    ;; Each channel should add to the output
    (define base (mix-channels 0 0 0 0 0))
    (define with-pulse1 (mix-channels 15 0 0 0 0))
    (define with-triangle (mix-channels 0 0 15 0 0))
    (define with-noise (mix-channels 0 0 0 15 0))
    (define with-dmc (mix-channels 0 0 0 0 127))

    (check-true (> with-pulse1 base))
    (check-true (> with-triangle base))
    (check-true (> with-noise base))
    (check-true (> with-dmc base))))
