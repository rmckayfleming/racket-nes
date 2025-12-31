#lang racket/base

;; Headless ROM runner for automated testing
;;
;; Runs a ROM for a specified number of steps or frames without
;; video/audio output, for use in CI and automated testing.
;;
;; Many blargg test ROMs output results to $6000-$7FFF as text,
;; with a status byte at $6000:
;; - $80: running
;; - $81: need reset
;; - $00: passed
;; - $01-$7F: failed with error code

(provide run-rom
         run-rom-steps
         run-rom-frames
         run-test-rom
         get-test-result)

(require nes/system
         nes/ppu/ppu
         cart/ines
         lib/bus
         nes/mappers/nrom
         nes/mappers/mmc1
         nes/mappers/uxrom
         nes/mappers/cnrom
         nes/mappers/mmc3)

;; Create appropriate mapper for ROM
(define (create-mapper rom)
  (define mapper-num (rom-mapper rom))
  (case mapper-num
    [(0) (make-nrom-mapper rom)]
    [(1) (make-mmc1-mapper rom)]
    [(2) (make-uxrom-mapper rom)]
    [(3) (make-cnrom-mapper rom)]
    [(4) (make-mmc3-mapper rom)]
    [else
     (error 'create-mapper "Unsupported mapper ~a" mapper-num)]))

;; Run a ROM for a given number of CPU steps
;; Returns the final NES state
(define (run-rom-steps rom-path steps #:trace? [trace? #f] #:mode [mode 'step])
  (define rom (load-rom rom-path))
  (define mapper (create-mapper rom))
  (define sys (make-nes mapper))
  (nes-reset! sys)

  (for ([_ (in-range steps)])
    (case mode
      [(step) (nes-step! sys)]
      [(tick)
       ;; In tick mode, we tick until an instruction completes
       (let loop ()
         (unless (nes-tick! sys)
           (loop)))]))

  sys)

;; Run a ROM for a given number of frames
;; Returns the final NES state
(define (run-rom-frames rom-path frames #:trace? [trace? #f] #:mode [mode 'step])
  (define rom (load-rom rom-path))
  (define mapper (create-mapper rom))
  (define sys (make-nes mapper))
  (nes-reset! sys)

  (for ([_ (in-range frames)])
    (case mode
      [(step) (nes-run-frame! sys)]
      [(tick) (nes-run-frame-tick! sys)]))

  sys)

;; Generic runner that dispatches based on parameters
(define (run-rom rom-path
                 #:steps [steps #f]
                 #:frames [frames #f]
                 #:trace? [trace? #f]
                 #:mode [mode 'step])
  (cond
    [steps (run-rom-steps rom-path steps #:trace? trace? #:mode mode)]
    [frames (run-rom-frames rom-path frames #:trace? trace? #:mode mode)]
    [else (error 'run-rom "Must specify either #:steps or #:frames")]))

;; Read a string from $6004 until null terminator
(define (read-test-output sys)
  (define cpu-bus (nes-cpu-bus sys))
  (let loop ([addr #x6004] [chars '()])
    (define byte (bus-read cpu-bus addr))
    (if (= byte 0)
        (list->string (reverse chars))
        (loop (+ addr 1) (cons (integer->char byte) chars)))))

;; Get test result from test ROM
;; Returns (values status message)
;; status: 'running, 'reset, 'passed, 'failed, or 'unknown
(define (get-test-result sys)
  (define cpu-bus (nes-cpu-bus sys))
  (define status-byte (bus-read cpu-bus #x6000))
  (define status
    (cond
      [(= status-byte #x80) 'running]
      [(= status-byte #x81) 'reset]
      [(= status-byte #x00) 'passed]
      [(and (> status-byte 0) (< status-byte #x80)) 'failed]
      [else 'unknown]))
  (define message (read-test-output sys))
  (values status message))

;; Run a test ROM until completion or timeout
;; Returns (values status message)
(define (run-test-rom rom-path
                      #:max-frames [max-frames 600]  ; 10 seconds at 60fps
                      #:mode [mode 'step])
  (define rom (load-rom rom-path))
  (define mapper (create-mapper rom))
  (define sys (make-nes mapper))
  (nes-reset! sys)

  (let loop ([frame 0])
    (if (>= frame max-frames)
        ;; Timed out
        (let-values ([(status message) (get-test-result sys)])
          (values 'timeout (format "Timeout after ~a frames. Status: ~a, Message: ~a"
                                   max-frames status message)))
        ;; Run one frame
        (begin
          (case mode
            [(step) (nes-run-frame! sys)]
            [(tick) (nes-run-frame-tick! sys)])

          ;; Check status
          (let-values ([(status message) (get-test-result sys)])
            (case status
              [(running) (loop (+ frame 1))]  ; Keep running
              [(reset)
               ;; Need to reset and continue
               (nes-reset! sys)
               (loop (+ frame 1))]
              [(passed) (values 'passed message)]
              [(failed) (values 'failed message)]
              [(unknown)
               ;; Check if we're at the start (status byte not written yet)
               (if (< frame 60)
                   (loop (+ frame 1))
                   (values 'timeout (format "No result after ~a frames" frame)))]))))))

(module+ main
  (require racket/cmdline)

  (define rom-path (make-parameter #f))
  (define steps (make-parameter #f))
  (define frames (make-parameter #f))
  (define trace? (make-parameter #f))
  (define test-mode? (make-parameter #f))
  (define tick-mode? (make-parameter #f))

  (command-line
   #:program "run-rom"
   #:once-each
   [("--rom" "-r") path "ROM file path" (rom-path path)]
   [("--steps" "-s") n "Number of CPU steps" (steps (string->number n))]
   [("--frames" "-f") n "Number of frames" (frames (string->number n))]
   [("--trace" "-t") "Enable trace output" (trace? #t)]
   [("--test") "Run as test ROM (check $6000 for result)" (test-mode? #t)]
   [("--tick") "Use Mode B (tick) instead of Mode A (step)" (tick-mode? #t)])

  (unless (rom-path)
    (eprintf "Error: --rom is required\n")
    (exit 1))

  (define mode (if (tick-mode?) 'tick 'step))

  (if (test-mode?)
      ;; Run as test ROM
      (let-values ([(status message) (run-test-rom (rom-path) #:mode mode)])
        (printf "~a: ~a\n" status message)
        (exit (if (eq? status 'passed) 0 1)))
      ;; Run for specified steps/frames
      (begin
        (run-rom (rom-path)
                 #:steps (steps)
                 #:frames (frames)
                 #:trace? (trace?)
                 #:mode mode)
        (printf "Completed\n"))))
