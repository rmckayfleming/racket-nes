#lang racket/base

;; NES Video Frontend
;;
;; SDL3-based video output for the NES emulator.
;; Manages window creation, texture streaming, and frame presentation.
;;
;; Features:
;; - 256x240 native resolution
;; - Integer scaling (2x, 3x, 4x, etc.)
;; - Streaming texture for efficient framebuffer updates
;;
;; Reference: PLAN.md Phase 8

(provide
 ;; Video system management
 make-video
 video?
 video-destroy!

 ;; Frame operations
 video-update-frame!     ; Upload framebuffer bytes to texture
 video-present!          ; Present the current frame

 ;; Window operations
 video-set-scale!        ; Set integer scale factor
 video-scale

 ;; Framebuffer access
 video-framebuffer       ; Get the framebuffer bytes
 video-set-pixel!        ; Set a single pixel in framebuffer

 ;; Constants
 NES-WIDTH
 NES-HEIGHT
 BYTES-PER-PIXEL)

(require ffi/unsafe
         sdl3
         sdl3/private/constants
         "../nes/ppu/timing.rkt")

;; ============================================================================
;; Constants
;; ============================================================================

(define NES-WIDTH VISIBLE-WIDTH)    ; 256
(define NES-HEIGHT VISIBLE-HEIGHT)  ; 240
(define BYTES-PER-PIXEL 4)          ; RGBA8888
(define FRAMEBUFFER-SIZE (* NES-WIDTH NES-HEIGHT BYTES-PER-PIXEL))

;; ============================================================================
;; Video Structure
;; ============================================================================

(struct video
  (window
   renderer
   texture
   framebuffer       ; bytes object (256*240*4 = 245,760 bytes)
   scale-box)        ; Current integer scale factor
  #:transparent)

;; ============================================================================
;; Video Creation
;; ============================================================================

;; Create a new video system
;; #:scale - Integer scale factor (default: 2)
;; #:title - Window title
;; #:vsync - Enable vsync for frame pacing (default: #t)
(define (make-video #:scale [scale 2]
                    #:title [title "NES Emulator"]
                    #:vsync [vsync #t])
  ;; Initialize SDL video
  (sdl-init! 'video)

  ;; Calculate window size
  (define win-width (* NES-WIDTH scale))
  (define win-height (* NES-HEIGHT scale))

  ;; Create window and renderer
  (define-values (win rend)
    (make-window+renderer title win-width win-height
                          #:window-flags 'resizable))

  ;; Enable vsync if requested - this makes render-present! block until
  ;; the next display refresh, providing natural ~60fps frame pacing
  (when vsync
    (set-render-vsync! rend 1))

  ;; Create streaming texture for efficient updates
  ;; Use ABGR8888 format because our framebuffer stores bytes as [R,G,B,A]
  ;; and on little-endian systems, SDL reads 32-bit values as ABGR from that byte layout
  (define tex (create-texture rend NES-WIDTH NES-HEIGHT
                              #:access 'streaming
                              #:format SDL_PIXELFORMAT_ABGR8888
                              #:scale 'nearest))  ; Pixelated look

  ;; Create framebuffer
  (define fb (make-bytes FRAMEBUFFER-SIZE 0))

  ;; Initialize to black
  (for ([i (in-range 0 FRAMEBUFFER-SIZE 4)])
    (bytes-set! fb (+ i 3) 255))  ; Alpha = 255

  (video win rend tex fb (box scale)))

;; ============================================================================
;; Video Destruction
;; ============================================================================

(define (video-destroy! v)
  (texture-destroy! (video-texture v))
  (renderer-destroy! (video-renderer v))
  (window-destroy! (video-window v))
  (sdl-quit!))

;; ============================================================================
;; Frame Operations
;; ============================================================================

;; Upload the framebuffer to the texture
(define (video-update-frame! v)
  (define tex (video-texture v))
  (define fb (video-framebuffer v))

  ;; Use call-with-locked-texture for streaming texture
  (call-with-locked-texture tex
    (λ (pixels width height pitch)
      ;; Copy framebuffer to texture pixel memory
      ;; The pitch from SDL might differ from our framebuffer's pitch
      (define src-pitch (* NES-WIDTH BYTES-PER-PIXEL))
      (for ([y (in-range height)])
        (define src-offset (* y src-pitch))
        (define dst-offset (* y pitch))
        (for ([x (in-range (* width BYTES-PER-PIXEL))])
          (ptr-set! pixels _uint8 (+ dst-offset x)
                    (bytes-ref fb (+ src-offset x))))))))

;; Present the current frame to the window
(define (video-present! v)
  (define rend (video-renderer v))
  (define tex (video-texture v))
  (define scale (video-scale v))

  ;; Calculate scaled dimensions
  (define dst-width (* NES-WIDTH scale))
  (define dst-height (* NES-HEIGHT scale))

  ;; Get current window size for centering (optional)
  (define-values (win-w win-h) (window-size (video-window v)))

  ;; Calculate centered position
  (define x (quotient (- win-w dst-width) 2))
  (define y (quotient (- win-h dst-height) 2))

  ;; Clear and render
  (set-draw-color! rend 0 0 0)  ; Black background
  (render-clear! rend)

  ;; Render texture scaled and centered
  (render-texture! rend tex x y
                   #:width dst-width
                   #:height dst-height)

  ;; Present
  (render-present! rend))

;; ============================================================================
;; Scaling
;; ============================================================================

(define (video-scale v)
  (unbox (video-scale-box v)))

(define (video-set-scale! v scale)
  (define new-scale (max 1 (min 8 scale)))  ; Clamp to 1-8
  (set-box! (video-scale-box v) new-scale)

  ;; Resize window to match
  (define win (video-window v))
  (define new-width (* NES-WIDTH new-scale))
  (define new-height (* NES-HEIGHT new-scale))
  (window-set-size! win new-width new-height))

;; ============================================================================
;; Framebuffer Access
;; ============================================================================

;; Set a single pixel in the framebuffer
;; x, y: pixel coordinates (0-255, 0-239)
;; r, g, b: color values (0-255)
(define (video-set-pixel! v x y r g b)
  (when (and (>= x 0) (< x NES-WIDTH)
             (>= y 0) (< y NES-HEIGHT))
    (define fb (video-framebuffer v))
    (define offset (* (+ (* y NES-WIDTH) x) BYTES-PER-PIXEL))
    (bytes-set! fb offset r)
    (bytes-set! fb (+ offset 1) g)
    (bytes-set! fb (+ offset 2) b)
    (bytes-set! fb (+ offset 3) 255)))  ; Alpha

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "framebuffer constants"
    (check-equal? NES-WIDTH 256)
    (check-equal? NES-HEIGHT 240)
    (check-equal? BYTES-PER-PIXEL 4)
    (check-equal? FRAMEBUFFER-SIZE 245760)))
