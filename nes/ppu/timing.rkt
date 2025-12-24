#lang racket/base

;; PPU Timing Constants
;;
;; Defines timing constants for the NES PPU (NTSC).
;; The PPU runs at 3x the CPU clock rate.
;;
;; Frame structure:
;; - 262 scanlines total (0-261)
;; - 341 PPU cycles per scanline (0-340)
;; - Visible: scanlines 0-239 (240 lines)
;; - Post-render: scanline 240
;; - VBlank: scanlines 241-260 (VBlank flag set at cycle 1 of 241)
;; - Pre-render: scanline 261 (odd frame skip on cycle 0)
;;
;; Reference: https://www.nesdev.org/wiki/PPU_rendering
;;            https://www.nesdev.org/wiki/PPU_frame_timing

(provide
 ;; Scanline counts
 SCANLINES-VISIBLE
 SCANLINES-POST-RENDER
 SCANLINES-VBLANK
 SCANLINES-PRE-RENDER
 SCANLINES-TOTAL

 ;; Cycle counts
 CYCLES-PER-SCANLINE
 CYCLES-PER-FRAME

 ;; Important scanlines
 SCANLINE-VBLANK-START
 SCANLINE-VBLANK-END
 SCANLINE-PRE-RENDER

 ;; Important cycles
 CYCLE-VBLANK-SET
 CYCLE-VBLANK-CLEAR

 ;; Rendering boundaries
 VISIBLE-WIDTH
 VISIBLE-HEIGHT

 ;; Helpers
 in-visible-scanline?
 in-vblank?
 in-pre-render?)

;; ============================================================================
;; Scanline Structure
;; ============================================================================

;; Visible rendering area (0-239)
(define SCANLINES-VISIBLE 240)

;; Post-render scanline (240) - PPU idle, no flag changes
(define SCANLINES-POST-RENDER 1)

;; VBlank period (241-260) - 20 scanlines
(define SCANLINES-VBLANK 20)

;; Pre-render scanline (261) - Setup for next frame
(define SCANLINES-PRE-RENDER 1)

;; Total scanlines per frame
(define SCANLINES-TOTAL 262)

;; ============================================================================
;; Cycle Counts
;; ============================================================================

;; PPU cycles per scanline
(define CYCLES-PER-SCANLINE 341)

;; Total PPU cycles per frame (approximate - odd frames skip one cycle)
(define CYCLES-PER-FRAME (* SCANLINES-TOTAL CYCLES-PER-SCANLINE))

;; ============================================================================
;; Important Positions
;; ============================================================================

;; VBlank starts at scanline 241
(define SCANLINE-VBLANK-START 241)

;; VBlank ends after scanline 260 (pre-render is 261)
(define SCANLINE-VBLANK-END 260)

;; Pre-render scanline
(define SCANLINE-PRE-RENDER 261)

;; VBlank flag set at cycle 1 of scanline 241
(define CYCLE-VBLANK-SET 1)

;; VBlank flag cleared at cycle 1 of pre-render scanline
(define CYCLE-VBLANK-CLEAR 1)

;; ============================================================================
;; Visible Area
;; ============================================================================

(define VISIBLE-WIDTH 256)
(define VISIBLE-HEIGHT 240)

;; ============================================================================
;; Helper Predicates
;; ============================================================================

;; Is this a visible (rendering) scanline?
(define (in-visible-scanline? scanline)
  (and (>= scanline 0) (< scanline SCANLINES-VISIBLE)))

;; Is this scanline in VBlank?
(define (in-vblank? scanline)
  (and (>= scanline SCANLINE-VBLANK-START)
       (<= scanline SCANLINE-VBLANK-END)))

;; Is this the pre-render scanline?
(define (in-pre-render? scanline)
  (= scanline SCANLINE-PRE-RENDER))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "frame structure adds up"
    (check-equal? (+ SCANLINES-VISIBLE
                     SCANLINES-POST-RENDER
                     SCANLINES-VBLANK
                     SCANLINES-PRE-RENDER)
                  SCANLINES-TOTAL))

  (test-case "visible scanline detection"
    (check-true (in-visible-scanline? 0))
    (check-true (in-visible-scanline? 100))
    (check-true (in-visible-scanline? 239))
    (check-false (in-visible-scanline? 240))
    (check-false (in-visible-scanline? 261)))

  (test-case "vblank detection"
    (check-false (in-vblank? 240))
    (check-true (in-vblank? 241))
    (check-true (in-vblank? 250))
    (check-true (in-vblank? 260))
    (check-false (in-vblank? 261)))

  (test-case "pre-render detection"
    (check-false (in-pre-render? 260))
    (check-true (in-pre-render? 261))
    (check-false (in-pre-render? 0))))
