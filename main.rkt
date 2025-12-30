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
;;   --test-addr <hex>    Check Blargg test result at address (e.g. 0x6000)
;;   --pc <hex>           Override initial PC (e.g. 0xC000 for nestest)

(require racket/cmdline
         racket/match
         racket/format
         racket/file
         racket/string
         "cart/ines.rkt"
         "nes/system.rkt"
         "nes/mappers/nrom.rkt"
         "nes/mappers/mmc1.rkt"
         "nes/mappers/uxrom.rkt"
         "nes/mappers/cnrom.rkt"
         "nes/mappers/mapper.rkt"
         "nes/ppu/ppu.rkt"
         "nes/ppu/render.rkt"
         "nes/input/controller.rkt"
         "lib/bus.rkt")

(define rom-path (make-parameter #f))
(define headless? (make-parameter #f))
(define step-limit (make-parameter #f))
(define frame-limit (make-parameter #f))
(define trace? (make-parameter #f))
(define screenshot-path (make-parameter #f))
(define scale-factor (make-parameter 3))
(define test-addr (make-parameter #f))
(define initial-pc (make-parameter #f))

;; Parse hex string like "0x6000" or "6000" or "$6000"
(define (parse-hex str)
  (define cleaned
    (cond
      [(string-prefix? str "0x") (substring str 2)]
      [(string-prefix? str "0X") (substring str 2)]
      [(string-prefix? str "$") (substring str 1)]
      [else str]))
  (string->number cleaned 16))

;; Read null-terminated string from memory starting at addr
(define (read-test-message bus addr)
  (define chars
    (for/list ([i (in-range 256)]  ; Max 256 chars
               #:break (= (bus-read bus (+ addr i)) 0))
      (integer->char (bus-read bus (+ addr i)))))
  (list->string chars))

;; Check Blargg-style test result at the given address
;; Returns exit code: 0 = pass, 1 = fail, 2 = inconclusive
;; halted-early? indicates if test hit illegal opcode before completion
(define (check-test-result sys addr #:halted-early? [halted-early? #f])
  (define bus (nes-cpu-bus sys))

  (define status (bus-read bus addr))
  (define magic1 (bus-read bus (+ addr 1)))
  (define magic2 (bus-read bus (+ addr 2)))
  (define magic3 (bus-read bus (+ addr 3)))

  (cond
    ;; Check magic bytes: $DE $B0 $61
    [(not (and (= magic1 #xDE) (= magic2 #xB0) (= magic3 #x61)))
     (printf "INCONCLUSIVE: Magic bytes not found at $~a (got $~a $~a $~a)\n"
             (number->string (+ addr 1) 16)
             (number->string magic1 16)
             (number->string magic2 16)
             (number->string magic3 16))
     (printf "  Test ROM may not have initialized or doesn't use Blargg protocol.\n")
     2]

    ;; Status $00 = passed
    [(= status #x00)
     (printf "PASS\n")
     0]

    ;; Status $80 = still running
    [(= status #x80)
     (cond
       [halted-early?
        ;; Crashed during test - this is a failure, not inconclusive
        (printf "FAIL: Test crashed (illegal opcode) before completion\n")
        (printf "  Status was still $80 (running) when crash occurred.\n")
        1]
       [else
        (printf "INCONCLUSIVE: Test still running (status=$80)\n")
        (printf "  Try increasing --frames count.\n")
        2])]

    ;; Any other status = failed
    [else
     (printf "FAIL: Status code $~a\n" (number->string status 16))
     ;; Read and display error message from addr+4
     (define msg (read-test-message bus (+ addr 4)))
     (unless (string=? msg "")
       (printf "  Message: ~a\n" msg))
     1]))

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
                     (scale-factor (string->number n))]
   [("--test-addr" "-T") addr
                         "Check Blargg test result at address (hex, e.g. 0x6000)"
                         (test-addr (parse-hex addr))]
   [("--pc" "-P") addr
                  "Override initial PC (hex, e.g. 0xC000)"
                  (initial-pc (parse-hex addr))]))

;; Create appropriate mapper for ROM
(define (create-mapper rom)
  (define mapper-num (rom-mapper rom))
  (case mapper-num
    [(0) (make-nrom-mapper rom)]
    [(1) (make-mmc1-mapper rom)]
    [(2) (make-uxrom-mapper rom)]
    [(3) (make-cnrom-mapper rom)]
    [else
     (eprintf "Warning: Mapper ~a not implemented, falling back to NROM\n" mapper-num)
     (make-nrom-mapper rom)]))

;; Run in headless mode (no video)
;; Returns exit code (0 = success, non-zero = failure/inconclusive)
(define (run-headless sys)
  (printf "Running in headless mode...\n")

  (when (trace?)
    (nes-set-trace! sys #t))

  ;; Wrap execution in exception handler to catch illegal opcodes
  ;; (many test ROMs halt with illegal opcodes like $FF after completing)
  (define halted-early #f)

  (with-handlers ([exn:fail?
                   (lambda (e)
                     (define msg (exn-message e))
                     (cond
                       ;; Illegal opcode = test halt, check results
                       [(string-contains? msg "illegal opcode")
                        (set! halted-early #t)]
                       ;; Re-raise other exceptions
                       [else (raise e)]))])
    (cond
      [(step-limit)
       ;; Run for N steps (use fast mode - no PPU graphics, minimal timing)
       (for ([_ (in-range (step-limit))])
         (nes-step-fast! sys))
       (printf "Completed ~a steps.\n" (step-limit))]

      [(frame-limit)
       ;; Run for N frames (use fast mode - no PPU graphics, minimal timing)
       (for ([_ (in-range (frame-limit))])
         (nes-run-frame-fast! sys))
       (printf "Completed ~a frames.\n" (frame-limit))]

      [else
       ;; Run forever (or until something stops it)
       (printf "Running indefinitely (Ctrl+C to stop)...\n")
       (let loop ()
         (nes-step-fast! sys)
         (loop))]))

  (when halted-early
    (printf "Test halted (illegal opcode).\n"))

  ;; Check test result if --test-addr was specified
  (if (test-addr)
      (check-test-result sys (test-addr) #:halted-early? halted-early)
      0))

;; Run with video output
(define (run-with-video sys)
  ;; Lazy require SDL3 modules only when needed
  (local-require sdl3
                 "frontend/video.rkt"
                 "frontend/audio.rkt")

  (printf "Starting with video and audio output (scale: ~ax)...\n" (scale-factor))

  ;; Create video system
  (define video (make-video #:scale (scale-factor)
                            #:title "NES Emulator"))

  ;; Create audio system
  (define aud (make-audio))

  ;; Set audio callback - called during each nes-step! with APU output
  (nes-set-audio-callback! sys
    (λ (sample cycles)
      (audio-push-sample! aud sample cycles)))

  ;; Start audio playback
  (audio-start! aud)

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
              [(key-event 'down 'right-shift _ _ _)
               (controller-set-button! ctrl1 BUTTON-SELECT #t) #f]
              [(key-event 'up 'right-shift _ _ _)
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

          ;; Frame pacing is handled by vsync - video-present! blocks until
          ;; the next display refresh (~16.67ms at 60Hz). Audio is generated
          ;; as a side effect of emulation and should stay in sync naturally.

          ;; Check frame limit and continue
          (define hit-limit? (and (frame-limit) (>= frames-rendered (frame-limit))))
          (loop (not hit-limit?))))))

  ;; Run with cleanup
  (dynamic-wind
    void
    emulation-loop
    (λ ()
      (printf "Shutting down audio and video...\n")
      (audio-stop! aud)
      (audio-destroy! aud)
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
  (when (test-addr)
    (printf "  Test addr: $~a\n" (number->string (test-addr) 16)))
  (when (initial-pc)
    (printf "  Initial PC: $~a\n" (number->string (initial-pc) 16)))
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

  ;; Override PC if requested (e.g., for nestest automation mode)
  (when (initial-pc)
    (set-cpu-pc! (nes-cpu sys) (initial-pc)))

  (printf "  CPU PC: $~a\n" (number->string (cpu-pc (nes-cpu sys)) 16))
  (printf "\n")

  ;; Run and get exit code
  (define exit-code
    (if (headless?)
        (run-headless sys)
        (begin (run-with-video sys) 0)))

  ;; Exit with appropriate code for test automation
  (when (test-addr)
    (exit exit-code)))

;; Need cpu-pc and set-cpu-pc! from cpu module
(require "lib/6502/cpu.rkt")

(module+ main
  (main))
