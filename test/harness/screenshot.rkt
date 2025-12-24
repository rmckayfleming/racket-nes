#lang racket/base

;; Screenshot Capture for Visual Regression Testing
;;
;; Runs a ROM for N frames and captures the framebuffer as a PNG.
;; Used for screenshot-based regression tests.

(provide capture-screenshot
         compare-screenshots
         framebuffer->png)

;; Forward declarations
;; (require nes/system)
;; (require nes/ppu/palette)

;; Capture a screenshot after running for N frames
;; Returns PNG bytes
(define (capture-screenshot rom-path frames #:palette [palette 'default])
  ;; TODO: Implement once PPU rendering is available
  (error 'capture-screenshot "Not yet implemented"))

;; Convert a framebuffer (256x240 RGBA u8vector) to PNG bytes
(define (framebuffer->png framebuffer #:palette [palette 'default])
  ;; TODO: Implement once we have framebuffer format defined
  (error 'framebuffer->png "Not yet implemented"))

;; Compare two screenshots, returning #t if they match
;; Optional tolerance for fuzzy matching
(define (compare-screenshots a b #:tolerance [tolerance 0])
  ;; TODO: Implement
  (error 'compare-screenshots "Not yet implemented"))

(module+ main
  (require racket/cmdline)

  (define rom-path (make-parameter #f))
  (define out-path (make-parameter "screenshot.png"))
  (define frames (make-parameter 60))

  (command-line
   #:program "screenshot"
   #:once-each
   [("--rom" "-r") path "ROM file path" (rom-path path)]
   [("--out" "-o") path "Output PNG path" (out-path path)]
   [("--frames" "-f") n "Number of frames to run" (frames (string->number n))])

  (unless (rom-path)
    (eprintf "Error: --rom is required\n")
    (exit 1))

  (printf "[Stub: screenshot not yet implemented]\n"))
