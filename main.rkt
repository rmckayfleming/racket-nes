#lang racket/base

;; NES Emulator - Main Entry Point
;;
;; Usage:
;;   racket main.rkt --rom <path.nes> [options]
;;
;; Options:
;;   --rom <path>         Path to NES ROM file (required)
;;   --headless           Run without video/audio output
;;   --steps <n>          Run for N CPU steps then exit
;;   --frames <n>         Run for N frames then exit
;;   --trace              Enable CPU trace output
;;   --screenshot-out <path>  Save screenshot after running

(require racket/cmdline
         racket/format)

;; Forward declarations for modules we'll implement
;; (require nes/system)
;; (require cart/ines)
;; (require frontend/sdl)

(define rom-path (make-parameter #f))
(define headless? (make-parameter #f))
(define step-limit (make-parameter #f))
(define frame-limit (make-parameter #f))
(define trace? (make-parameter #f))
(define screenshot-path (make-parameter #f))

(define (parse-command-line)
  (command-line
   #:program "nes"
   #:once-each
   [("--rom" "-r") path
                   "Path to NES ROM file"
                   (rom-path path)]
   [("--headless" "-H")
    "Run without video/audio output"
    (headless? #t)]
   [("--steps" "-s") n
                     "Run for N CPU steps then exit"
                     (step-limit (string->number n))]
   [("--frames" "-f") n
                      "Run for N frames then exit"
                      (frame-limit (string->number n))]
   [("--trace" "-t")
    "Enable CPU trace output"
    (trace? #t)]
   [("--screenshot-out" "-o") path
                              "Save screenshot after running"
                              (screenshot-path path)]))

(define (main)
  (parse-command-line)

  (unless (rom-path)
    (eprintf "Error: --rom is required\n")
    (exit 1))

  (unless (file-exists? (rom-path))
    (eprintf "Error: ROM file not found: ~a\n" (rom-path))
    (exit 1))

  ;; TODO: Implement once we have the system components
  (printf "NES Emulator\n")
  (printf "  ROM: ~a\n" (rom-path))
  (printf "  Headless: ~a\n" (headless?))
  (printf "  Steps: ~a\n" (or (step-limit) "unlimited"))
  (printf "  Frames: ~a\n" (or (frame-limit) "unlimited"))
  (printf "  Trace: ~a\n" (trace?))
  (when (screenshot-path)
    (printf "  Screenshot: ~a\n" (screenshot-path)))

  (printf "\n[Stub: System not yet implemented]\n"))

(module+ main
  (main))
