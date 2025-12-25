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
;;   --scale <n>          Integer scale factor (default: 3)

(require racket/cmdline
         racket/match
         racket/format
         racket/file
         "cart/ines.rkt"
         "nes/system.rkt"
         "nes/mappers/nrom.rkt"
         "nes/mappers/mapper.rkt"
         "nes/ppu/ppu.rkt"
         "nes/ppu/render.rkt"
         "nes/input/controller.rkt")

(define rom-path (make-parameter #f))
(define headless? (make-parameter #f))
(define step-limit (make-parameter #f))
(define frame-limit (make-parameter #f))
(define trace? (make-parameter #f))
(define screenshot-path (make-parameter #f))
(define scale-factor (make-parameter 3))

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
                              (screenshot-path path)]
   [("--scale" "-S") n
                     "Integer scale factor (1-8, default: 3)"
                     (scale-factor (string->number n))]))

;; Create appropriate mapper for ROM
(define (create-mapper rom)
  (define mapper-num (rom-mapper rom))
  (case mapper-num
    [(0) (make-nrom-mapper rom)]
    [else
     (eprintf "Warning: Mapper ~a not implemented, using NROM\n" mapper-num)
     (make-nrom-mapper rom)]))

;; Run in headless mode (no video)
(define (run-headless sys)
  (printf "Running in headless mode...\n")

  (when (trace?)
    (nes-set-trace! sys #t))

  (cond
    [(step-limit)
     ;; Run for N steps
     (for ([_ (in-range (step-limit))])
       (nes-step! sys))
     (printf "Completed ~a steps.\n" (step-limit))]

    [(frame-limit)
     ;; Run for N frames
     (for ([_ (in-range (frame-limit))])
       (nes-run-frame! sys))
     (printf "Completed ~a frames.\n" (frame-limit))]

    [else
     ;; Run forever (or until something stops it)
     (printf "Running indefinitely (Ctrl+C to stop)...\n")
     (let loop ()
       (nes-step! sys)
       (loop))]))

;; Run with video output
(define (run-with-video sys)
  ;; Lazy require SDL3 modules only when needed
  (local-require sdl3
                 "frontend/video.rkt")

  (printf "Starting with video output (scale: ~ax)...\n" (scale-factor))

  ;; Create video system
  (define video (make-video #:scale (scale-factor)
                            #:title "NES Emulator"))

  (when (trace?)
    (nes-set-trace! sys #t))

  ;; Get references we need
  (define ppu (nes-ppu sys))
  (define pbus (nes-ppu-bus sys))
  (define ctrl1 (nes-controller1 sys))
  (define framebuffer (video-framebuffer video))

  ;; Track frames for limiting
  (define frames-rendered 0)

  ;; Main emulation loop
  (define (emulation-loop)
    (let loop ([running? #t])
      (when running?
        ;; Process SDL events and check for quit
        (define should-quit?
          (for/or ([ev (in-events)])
            (match ev
              ;; Quit events
              [(quit-event) #t]
              [(window-event 'close-requested) #t]
              [(key-event 'down 'escape _ _ _) #t]

              ;; Keyboard input -> NES controller
              ;; Arrow keys for D-pad
              [(key-event 'down 'up _ _ _)
               (controller-set-button! ctrl1 BUTTON-UP #t) #f]
              [(key-event 'up 'up _ _ _)
               (controller-set-button! ctrl1 BUTTON-UP #f) #f]
              [(key-event 'down 'down _ _ _)
               (controller-set-button! ctrl1 BUTTON-DOWN #t) #f]
              [(key-event 'up 'down _ _ _)
               (controller-set-button! ctrl1 BUTTON-DOWN #f) #f]
              [(key-event 'down 'left _ _ _)
               (controller-set-button! ctrl1 BUTTON-LEFT #t) #f]
              [(key-event 'up 'left _ _ _)
               (controller-set-button! ctrl1 BUTTON-LEFT #f) #f]
              [(key-event 'down 'right _ _ _)
               (controller-set-button! ctrl1 BUTTON-RIGHT #t) #f]
              [(key-event 'up 'right _ _ _)
               (controller-set-button! ctrl1 BUTTON-RIGHT #f) #f]

              ;; Z = A button, X = B button
              [(key-event 'down 'z _ _ _)
               (controller-set-button! ctrl1 BUTTON-A #t) #f]
              [(key-event 'up 'z _ _ _)
               (controller-set-button! ctrl1 BUTTON-A #f) #f]
              [(key-event 'down 'x _ _ _)
               (controller-set-button! ctrl1 BUTTON-B #t) #f]
              [(key-event 'up 'x _ _ _)
               (controller-set-button! ctrl1 BUTTON-B #f) #f]

              ;; Enter = Start, Right Shift = Select
              [(key-event 'down 'return _ _ _)
               (controller-set-button! ctrl1 BUTTON-START #t) #f]
              [(key-event 'up 'return _ _ _)
               (controller-set-button! ctrl1 BUTTON-START #f) #f]
              [(key-event 'down 'rshift _ _ _)
               (controller-set-button! ctrl1 BUTTON-SELECT #t) #f]
              [(key-event 'up 'rshift _ _ _)
               (controller-set-button! ctrl1 BUTTON-SELECT #f) #f]

              [_ #f])))

        (unless should-quit?
          ;; Run one frame of emulation
          ;; (Sprite 0 hit is now detected during PPU tick, not after rendering)
          (nes-run-frame! sys)

          ;; Render background + sprites to framebuffer
          (render-frame! ppu pbus framebuffer)

          ;; Upload and present
          (video-update-frame! video)
          (video-present! video)

          ;; Track frame count
          (set! frames-rendered (+ frames-rendered 1))

          ;; Check frame limit and continue
          (define hit-limit? (and (frame-limit) (>= frames-rendered (frame-limit))))
          (loop (not hit-limit?))))))

  ;; Run with cleanup
  (dynamic-wind
    void
    emulation-loop
    (λ ()
      (printf "Shutting down video...\n")
      (video-destroy! video)))

  (printf "Rendered ~a frames.\n" frames-rendered))

(define (main)
  (parse-command-line)

  (unless (rom-path)
    (eprintf "Error: --rom is required\n")
    (exit 1))

  (unless (file-exists? (rom-path))
    (eprintf "Error: ROM file not found: ~a\n" (rom-path))
    (exit 1))

  (printf "NES Emulator\n")
  (printf "  ROM: ~a\n" (rom-path))
  (printf "  Headless: ~a\n" (headless?))
  (when (step-limit)
    (printf "  Steps: ~a\n" (step-limit)))
  (when (frame-limit)
    (printf "  Frames: ~a\n" (frame-limit)))
  (printf "  Trace: ~a\n" (trace?))
  (when (screenshot-path)
    (printf "  Screenshot: ~a\n" (screenshot-path)))
  (printf "\n")

  ;; Load ROM
  (printf "Loading ROM...\n")
  (define rom-bytes (file->bytes (rom-path)))
  (define rom (parse-rom rom-bytes))
  (define prg-size (quotient (bytes-length (rom-prg-rom rom)) 1024))
  (define chr-size (quotient (bytes-length (rom-chr-rom rom)) 1024))
  (printf "  PRG ROM: ~a KB\n" prg-size)
  (printf "  CHR: ~a KB ~a\n"
          chr-size
          (if (rom-chr-ram? rom) "(RAM)" "(ROM)"))
  (printf "  Mapper: ~a\n" (rom-mapper rom))
  (printf "  Mirroring: ~a\n" (rom-mirroring rom))
  (printf "\n")

  ;; Create mapper and system
  (printf "Creating system...\n")
  (define mapper (create-mapper rom))
  (define sys (make-nes mapper))
  (printf "  CPU PC: $~a\n" (number->string (cpu-pc (nes-cpu sys)) 16))
  (printf "\n")

  ;; Run
  (if (headless?)
      (run-headless sys)
      (run-with-video sys)))

;; Need cpu-pc from cpu module
(require "lib/6502/cpu.rkt")

(module+ main
  (main))
