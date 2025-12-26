#lang racket/base

;; NES Audio Frontend
;;
;; SDL3-based audio output for the NES emulator.
;; Manages audio device, stream, and buffering.
;;
;; The NES APU runs at 1.789773 MHz (CPU clock), generating samples at
;; that rate. We need to resample to the output device rate (typically
;; 44100 or 48000 Hz).
;;
;; Reference: PLAN.md Phase 14

(provide
 ;; Audio system management
 make-audio
 audio?
 audio-destroy!

 ;; Audio control
 audio-start!
 audio-stop!
 audio-paused?

 ;; Audio output
 audio-push-sample!     ; Push a single sample (called at APU rate)
 audio-flush!           ; Flush buffer to device

 ;; Buffer management
 audio-available        ; Bytes queued in output
 audio-buffer-size      ; Get current buffer target size
 audio-set-buffer-size! ; Set buffer target size

 ;; Constants
 NES-CPU-CLOCK
 DEFAULT-SAMPLE-RATE
 DEFAULT-BUFFER-MS)

(require ffi/unsafe
         sdl3
         sdl3/safe/audio)

;; ============================================================================
;; Constants
;; ============================================================================

;; NES CPU clock rate (NTSC)
(define NES-CPU-CLOCK 1789773)

;; Default output sample rate
(define DEFAULT-SAMPLE-RATE 44100)

;; Default buffer size in milliseconds
;; Lower = less latency but more chance of underrun
;; Higher = more latency but smoother playback
(define DEFAULT-BUFFER-MS 50)

;; Number of APU cycles per output sample
(define (cycles-per-sample output-rate)
  (/ NES-CPU-CLOCK output-rate))

;; ============================================================================
;; Audio Structure
;; ============================================================================

(struct audio
  (stream               ; SDL audio stream
   sample-rate          ; Output sample rate (e.g., 44100)
   buffer-ms-box        ; Target buffer size in ms
   sample-accumulator-box ; Accumulates fractional samples
   sample-buffer-box    ; Ring buffer for output samples
   buffer-pos-box       ; Write position in sample buffer
   internal-buffer-samples ; Size of sample buffer in samples
   last-sample-box      ; Last sample value for interpolation
   hp-capacitor-box)    ; High-pass filter capacitor (for DC removal)
  #:transparent)

;; Size of the internal sample buffer (in samples)
;; Should be large enough to hold several milliseconds of audio
(define INTERNAL-BUFFER-SAMPLES 8192)

;; ============================================================================
;; Audio Creation
;; ============================================================================

(define (make-audio #:sample-rate [sample-rate DEFAULT-SAMPLE-RATE]
                    #:buffer-ms [buffer-ms DEFAULT-BUFFER-MS])
  ;; Initialize SDL audio subsystem
  (sdl-init! 'audio)

  ;; Create audio spec for signed 16-bit stereo
  (define spec (make-audio-spec SDL_AUDIO_S16 2 sample-rate))

  ;; Open audio device with stream
  ;; Device starts paused
  (define stream (open-audio-device-stream SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK spec))

  ;; Create sample buffer (S16 stereo = 4 bytes per sample)
  (define buffer-bytes (* INTERNAL-BUFFER-SAMPLES 4))
  (define sample-buffer (make-bytes buffer-bytes 0))

  (audio stream
         sample-rate
         (box buffer-ms)
         (box 0.0)       ; Sample accumulator
         (box sample-buffer)
         (box 0)         ; Buffer position
         INTERNAL-BUFFER-SAMPLES
         (box 0)         ; Last sample
         (box 0.0)))     ; High-pass filter capacitor

;; ============================================================================
;; Audio Destruction
;; ============================================================================

(define (audio-destroy! a)
  (destroy-audio-stream! (audio-stream a)))

;; ============================================================================
;; Audio Control
;; ============================================================================

(define (audio-start! a)
  (resume-audio-stream-device! (audio-stream a)))

(define (audio-stop! a)
  (pause-audio-stream-device! (audio-stream a)))

(define (audio-paused? a)
  (audio-stream-device-paused? (audio-stream a)))

;; ============================================================================
;; Sample Generation
;; ============================================================================

;; Push a sample from the APU (called once per APU tick, at ~1.79 MHz)
;; sample: float 0.0 to 1.0 from mixer
;; cycles: number of APU cycles this represents (usually 1)
;;
;; This handles downsampling from APU rate to output rate
(define (audio-push-sample! a sample cycles)
  (define sample-rate (audio-sample-rate a))
  (define accumulator (unbox (audio-sample-accumulator-box a)))
  (define cps (cycles-per-sample sample-rate))

  ;; Accumulate cycles
  (set! accumulator (+ accumulator cycles))

  ;; When we've accumulated enough cycles, output one or more samples
  (let loop ()
    (when (>= accumulator cps)
      (set! accumulator (- accumulator cps))

      ;; Apply high-pass filter to remove DC offset
      ;; Simple first-order high-pass: y[n] = alpha * (y[n-1] + x[n] - x[n-1])
      ;; With alpha ~= 0.996 for a cutoff around ~90Hz at 44.1kHz
      ;; The capacitor stores the previous output (y[n-1]) and input (x[n-1])
      (define hp-alpha 0.996)
      (define prev-output (unbox (audio-hp-capacitor-box a)))
      (define prev-input (unbox (audio-last-sample-box a)))
      (define filtered (* hp-alpha (+ prev-output (- sample prev-input))))
      (set-box! (audio-hp-capacitor-box a) filtered)
      (set-box! (audio-last-sample-box a) sample)

      ;; Convert filtered sample to S16
      ;; Filtered output is roughly -0.5 to +0.5 (centered around 0)
      ;; Scale to use most of S16 range
      (define s16-sample
        (let ([scaled (inexact->exact (round (* filtered 50000.0)))])
          (max -32768 (min 32767 scaled))))

      ;; Get buffer
      (define buf (unbox (audio-sample-buffer-box a)))
      (define pos (unbox (audio-buffer-pos-box a)))
      (define max-samples (audio-internal-buffer-samples a))

      ;; Write stereo sample (left = right for mono NES audio)
      (define byte-pos (* pos 4))
      (when (< byte-pos (- (bytes-length buf) 4))
        ;; Little-endian S16
        (bytes-set! buf byte-pos (bitwise-and s16-sample #xFF))
        (bytes-set! buf (+ byte-pos 1) (bitwise-and (arithmetic-shift s16-sample -8) #xFF))
        (bytes-set! buf (+ byte-pos 2) (bitwise-and s16-sample #xFF))
        (bytes-set! buf (+ byte-pos 3) (bitwise-and (arithmetic-shift s16-sample -8) #xFF))

        ;; Advance position
        (set-box! (audio-buffer-pos-box a) (add1 pos))

        ;; Flush if buffer is getting full
        (when (>= (add1 pos) (quotient max-samples 2))
          (audio-flush! a)))

      (loop)))

  (set-box! (audio-sample-accumulator-box a) accumulator))

;; Flush buffered samples to the audio device
(define (audio-flush! a)
  (define stream (audio-stream a))
  (define buf (unbox (audio-sample-buffer-box a)))
  (define pos (unbox (audio-buffer-pos-box a)))

  (when (> pos 0)
    (define byte-count (* pos 4))  ; 4 bytes per stereo sample

    ;; Put audio data into stream
    ;; We need to use the FFI to pass the bytes pointer
    (define ptr (cast buf _bytes _pointer))
    (audio-stream-put! stream ptr byte-count)

    ;; Reset buffer position
    (set-box! (audio-buffer-pos-box a) 0)))

;; ============================================================================
;; Buffer Management
;; ============================================================================

;; Get the number of bytes queued in the output stream
(define (audio-available a)
  (audio-stream-available (audio-stream a)))

;; Get the current target buffer size in milliseconds
(define (audio-buffer-size a)
  (unbox (audio-buffer-ms-box a)))

;; Set the target buffer size in milliseconds
(define (audio-set-buffer-size! a ms)
  (set-box! (audio-buffer-ms-box a) (max 10 (min 500 ms))))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "constants"
    (check-equal? NES-CPU-CLOCK 1789773)
    (check-equal? DEFAULT-SAMPLE-RATE 44100)
    ;; ~40.58 APU cycles per output sample at 44100 Hz
    (check-true (> (cycles-per-sample 44100) 40))
    (check-true (< (cycles-per-sample 44100) 41))))
