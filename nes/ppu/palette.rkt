#lang racket/base

;; NES Palette
;;
;; Defines the standard 64-color NES palette and provides lookup functions.
;; The NES generates colors using a NTSC signal, so the exact colors depend
;; on the TV. This implementation uses a commonly-accepted approximation.
;;
;; Palette structure:
;; - 64 unique colors (indices $00-$3F)
;; - Palette RAM uses 6-bit indices (upper 2 bits ignored for color)
;; - Color emphasis bits in PPUMASK can modify colors (not yet implemented)
;;
;; Reference: https://www.nesdev.org/wiki/PPU_palettes

(provide
 ;; Palette lookup
 nes-palette-ref       ; Get RGB values for a palette index
 nes-palette-ref-rgba  ; Get RGBA value (packed u32) for a palette index

 ;; Palette data
 nes-palette           ; The raw palette vector (for debugging)

 ;; Constants
 PALETTE-SIZE)

;; ============================================================================
;; Palette Definition
;; ============================================================================

(define PALETTE-SIZE 64)

;; Standard NES palette (2C02)
;; Each entry is (r g b) in 0-255 range
;; This uses the commonly-cited "2C02" palette approximation
;; Source: nesdev wiki / various community-accepted palettes
(define nes-palette
  (vector
   ;; Row 0 ($00-$0F)
   '#(84 84 84)     ; $00 - Gray
   '#(0 30 116)     ; $01 - Dark Blue
   '#(8 16 144)     ; $02 - Dark Blue-Violet
   '#(48 0 136)     ; $03 - Dark Violet
   '#(68 0 100)     ; $04 - Dark Purple
   '#(92 0 48)      ; $05 - Dark Red-Purple
   '#(84 4 0)       ; $06 - Dark Red
   '#(60 24 0)      ; $07 - Dark Orange
   '#(32 42 0)      ; $08 - Dark Olive
   '#(8 58 0)       ; $09 - Dark Green
   '#(0 64 0)       ; $0A - Dark Green
   '#(0 60 0)       ; $0B - Dark Green
   '#(0 50 60)      ; $0C - Dark Cyan
   '#(0 0 0)        ; $0D - Black
   '#(0 0 0)        ; $0E - Black (mirror)
   '#(0 0 0)        ; $0F - Black (mirror)

   ;; Row 1 ($10-$1F)
   '#(152 150 152)  ; $10 - Light Gray
   '#(8 76 196)     ; $11 - Blue
   '#(48 50 236)    ; $12 - Blue-Violet
   '#(92 30 228)    ; $13 - Violet
   '#(136 20 176)   ; $14 - Purple
   '#(160 20 100)   ; $15 - Red-Purple
   '#(152 34 32)    ; $16 - Red
   '#(120 60 0)     ; $17 - Orange
   '#(84 90 0)      ; $18 - Yellow-Green
   '#(40 114 0)     ; $19 - Green
   '#(8 124 0)      ; $1A - Green
   '#(0 118 40)     ; $1B - Green-Cyan
   '#(0 102 120)    ; $1C - Cyan
   '#(0 0 0)        ; $1D - Black
   '#(0 0 0)        ; $1E - Black (mirror)
   '#(0 0 0)        ; $1F - Black (mirror)

   ;; Row 2 ($20-$2F)
   '#(236 238 236)  ; $20 - White
   '#(76 154 236)   ; $21 - Light Blue
   '#(120 124 236)  ; $22 - Light Blue-Violet
   '#(176 98 236)   ; $23 - Light Violet
   '#(228 84 236)   ; $24 - Light Purple
   '#(236 88 180)   ; $25 - Light Red-Purple
   '#(236 106 100)  ; $26 - Light Red
   '#(212 136 32)   ; $27 - Light Orange
   '#(160 170 0)    ; $28 - Yellow
   '#(116 196 0)    ; $29 - Light Green
   '#(76 208 32)    ; $2A - Light Green
   '#(56 204 108)   ; $2B - Light Green-Cyan
   '#(56 180 204)   ; $2C - Light Cyan
   '#(60 60 60)     ; $2D - Dark Gray
   '#(0 0 0)        ; $2E - Black (mirror)
   '#(0 0 0)        ; $2F - Black (mirror)

   ;; Row 3 ($30-$3F)
   '#(236 238 236)  ; $30 - White
   '#(168 204 236)  ; $31 - Pale Blue
   '#(188 188 236)  ; $32 - Pale Blue-Violet
   '#(212 178 236)  ; $33 - Pale Violet
   '#(236 174 236)  ; $34 - Pale Purple
   '#(236 174 212)  ; $35 - Pale Red-Purple
   '#(236 180 176)  ; $36 - Pale Red
   '#(228 196 144)  ; $37 - Pale Orange
   '#(204 210 120)  ; $38 - Pale Yellow
   '#(180 222 120)  ; $39 - Pale Yellow-Green
   '#(168 226 144)  ; $3A - Pale Green
   '#(152 226 180)  ; $3B - Pale Green-Cyan
   '#(160 214 228)  ; $3C - Pale Cyan
   '#(160 162 160)  ; $3D - Gray
   '#(0 0 0)        ; $3E - Black (mirror)
   '#(0 0 0)))      ; $3F - Black (mirror)

;; ============================================================================
;; Palette Lookup
;; ============================================================================

;; Get RGB values for a palette index (0-63)
;; Returns: (values r g b) each in 0-255 range
(define (nes-palette-ref index)
  (define idx (bitwise-and index #x3F))  ; Mask to 6 bits
  (define rgb (vector-ref nes-palette idx))
  (values (vector-ref rgb 0)
          (vector-ref rgb 1)
          (vector-ref rgb 2)))

;; Get RGBA value as a packed u32 for a palette index
;; Returns: RGBA value in format suitable for SDL texture (RGBA8888)
;; Format: #xRRGGBBAA (alpha is always 255)
(define (nes-palette-ref-rgba index)
  (define-values (r g b) (nes-palette-ref index))
  (bitwise-ior (arithmetic-shift r 24)
               (arithmetic-shift g 16)
               (arithmetic-shift b 8)
               255))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "palette size"
    (check-equal? (vector-length nes-palette) PALETTE-SIZE))

  (test-case "palette lookup"
    ;; Black at $0D
    (define-values (r0 g0 b0) (nes-palette-ref #x0D))
    (check-equal? r0 0)
    (check-equal? g0 0)
    (check-equal? b0 0)

    ;; White-ish at $20
    (define-values (r1 g1 b1) (nes-palette-ref #x20))
    (check-equal? r1 236)
    (check-equal? g1 238)
    (check-equal? b1 236))

  (test-case "palette index masking"
    ;; Index $40 should wrap to $00
    (define-values (r0 g0 b0) (nes-palette-ref #x00))
    (define-values (r40 g40 b40) (nes-palette-ref #x40))
    (check-equal? r0 r40)
    (check-equal? g0 g40)
    (check-equal? b0 b40))

  (test-case "rgba packing"
    ;; Black should be #x000000FF
    (check-equal? (nes-palette-ref-rgba #x0D) #x000000FF)

    ;; Check that alpha is always 255
    (for ([i (in-range PALETTE-SIZE)])
      (check-equal? (bitwise-and (nes-palette-ref-rgba i) #xFF) 255
                    (format "Alpha should be 255 for index ~a" i)))))
