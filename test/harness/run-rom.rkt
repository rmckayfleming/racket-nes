#lang racket/base

;; Headless ROM runner for automated testing
;;
;; Runs a ROM for a specified number of steps or frames without
;; video/audio output, for use in CI and automated testing.

(provide run-rom
         run-rom-steps
         run-rom-frames)

;; Forward declarations
;; (require nes/system)
;; (require cart/ines)

;; Run a ROM for a given number of CPU steps
;; Returns the final NES state
(define (run-rom-steps rom-path steps #:trace? [trace? #f])
  ;; TODO: Implement once system is available
  (error 'run-rom-steps "Not yet implemented"))

;; Run a ROM for a given number of frames
;; Returns the final NES state
(define (run-rom-frames rom-path frames #:trace? [trace? #f])
  ;; TODO: Implement once system is available
  (error 'run-rom-frames "Not yet implemented"))

;; Generic runner that dispatches based on parameters
(define (run-rom rom-path
                 #:steps [steps #f]
                 #:frames [frames #f]
                 #:trace? [trace? #f])
  (cond
    [steps (run-rom-steps rom-path steps #:trace? trace?)]
    [frames (run-rom-frames rom-path frames #:trace? trace?)]
    [else (error 'run-rom "Must specify either #:steps or #:frames")]))

(module+ main
  (require racket/cmdline)

  (define rom-path (make-parameter #f))
  (define steps (make-parameter #f))
  (define frames (make-parameter #f))
  (define trace? (make-parameter #f))

  (command-line
   #:program "run-rom"
   #:once-each
   [("--rom" "-r") path "ROM file path" (rom-path path)]
   [("--steps" "-s") n "Number of CPU steps" (steps (string->number n))]
   [("--frames" "-f") n "Number of frames" (frames (string->number n))]
   [("--trace" "-t") "Enable trace output" (trace? #t)])

  (unless (rom-path)
    (eprintf "Error: --rom is required\n")
    (exit 1))

  (run-rom (rom-path)
           #:steps (steps)
           #:frames (frames)
           #:trace? (trace?)))
