#lang racket/base

;; AccuracyCoin Test Harness
;;
;; Runs the AccuracyCoin test ROM, which contains 131 accuracy tests for
;; NES emulator validation. The ROM has a menu-based interface:
;;
;; Navigation:
;; - D-Pad: Move cursor
;; - A: Run highlighted test
;; - B: Mark test to skip
;; - Start (at page header): Run all tests, display results table
;;
;; Test result statuses:
;; - PASS: Test passed
;; - FAIL N: Test failed with error code N
;; - DRAW: Inconclusive (power-on state tests depend on random RAM)
;; - SKIP: Test was skipped (not counted by this harness)
;;
;; This harness simulates the inputs needed to run all tests and reports
;; the parsed results from the screen. It navigates through all 20 result
;; pages and extracts individual test outcomes.
;;
;; Usage:
;;   PLTCOLLECTS="$PWD:" racket test/harness/accuracy-coin.rkt [options]
;;
;; Options:
;;   --detailed   Show all test results (not just failures)
;;   --failures   Show only failures (implies --detailed)
;;   --frames N   Run for N frames (default: 3000, about 50 seconds at 60fps)

(provide run-accuracy-coin
         run-all-tests!
         read-results-table
         parse-results
         get-test-results
         get-detailed-results
         run-and-collect-all-results)

(require nes/system
         nes/ppu/ppu
         nes/ppu/bus
         nes/input/controller
         cart/ines
         nes/mappers/nrom
         racket/string
         racket/list)

;; Create appropriate mapper for ROM
(define (create-mapper rom)
  (define mapper-num (rom-mapper rom))
  (case mapper-num
    [(0) (make-nrom-mapper rom)]
    [else
     (error 'create-mapper "AccuracyCoin uses NROM (mapper 0), got ~a" mapper-num)]))

;; Run the AccuracyCoin ROM
;; Returns the NES system after execution
(define (run-accuracy-coin rom-path
                           #:frames [frames 3000]
                           #:verbose? [verbose? #t])
  (define rom (load-rom rom-path))
  (define mapper (create-mapper rom))
  (define sys (make-nes mapper))
  (nes-reset! sys)

  (when verbose?
    (printf "AccuracyCoin Test Harness\n")
    (printf "ROM: ~a\n" rom-path)
    (printf "Running for ~a frames (~a seconds)...\n"
            frames (exact->inexact (/ frames 60))))

  ;; Input sequence to run all tests:
  ;; 1. Wait for initial boot/menu (cursor starts at page header)
  ;; 2. Press Start to run all tests
  ;;
  ;; The ROM starts with cursor at the page index, so pressing Start
  ;; immediately will run all tests.

  (define ctrl1 (nes-controller1 sys))

  ;; Frame-based input timing
  (define start-time (current-inexact-milliseconds))

  (for ([frame (in-range frames)])
    ;; Input handling at specific frames
    (cond
      ;; Wait 60 frames for boot, then press Start
      [(= frame 60)
       (when verbose? (printf "Frame ~a: Pressing Start to run all tests...\n" frame))
       (controller-set-button! ctrl1 BUTTON-START #t)]
      ;; Release Start after 2 frames
      [(= frame 62)
       (controller-set-button! ctrl1 BUTTON-START #f)]
      ;; Progress updates every 500 frames
      [(and verbose? (= (modulo frame 500) 0) (> frame 0))
       (printf "Frame ~a/~a...\n" frame frames)])

    ;; Run one frame
    (nes-run-frame! sys))

  (define end-time (current-inexact-milliseconds))
  (define elapsed-ms (- end-time start-time))
  (define fps (/ (* frames 1000.0) elapsed-ms))

  (when verbose?
    (printf "\nCompleted ~a frames in ~a ms\n" frames (inexact->exact (round elapsed-ms)))
    (printf "Performance: ~a fps (~a%% of realtime)\n"
            (exact->inexact (round fps))
            (exact->inexact (round (* 100 (/ fps 60))))))

  sys)

;; Run all tests and return system state
;; This is a convenience function for programmatic use
(define (run-all-tests! sys #:frames [frames 2940])
  (define ctrl1 (nes-controller1 sys))

  ;; Press Start to run all tests (assumes cursor is at page header)
  (controller-set-button! ctrl1 BUTTON-START #t)
  (nes-run-frame! sys)
  (nes-run-frame! sys)
  (controller-set-button! ctrl1 BUTTON-START #f)

  ;; Run remaining frames for tests to complete
  (for ([_ (in-range frames)])
    (nes-run-frame! sys))

  sys)

;; ============================================================================
;; Results Table Reading
;; ============================================================================

;; The AccuracyCoin results table is displayed in the nametable.
;; After running all tests, it shows a grid where:
;; - Green numbers (or 'P') = passed
;; - Red numbers = failed with error code
;; - The table uses specific tile indices for digits and status
;;
;; Nametable layout (32 columns x 30 rows):
;; $2000 = top-left corner, each row is 32 bytes

;; Standard ASCII-like tile mapping for NES fonts:
;; Tiles $00-$0F often represent 0-9, A-F for hex display
;; Tiles $30-$39 = '0'-'9' (ASCII-like)
;; Tiles $41-$5A = 'A'-'Z' (ASCII-like)
;; Tile $00 or $20 = blank/space

;; Read a region of the nametable
(define (read-nametable-region sys start-x start-y width height)
  (define pbus (nes-ppu-bus sys))
  (define vram (ppu-bus-vram pbus))

  ;; Build a list of rows, each row is a list of tile indices
  (for/list ([y (in-range height)])
    (for/list ([x (in-range width)])
      (define addr (+ (* (+ start-y y) 32) (+ start-x x)))
      ;; VRAM is mirrored, nametable 0 is at offset 0
      (bytes-ref vram (bitwise-and addr #x7FF)))))

;; Read the full first nametable (32x30 tiles)
(define (read-results-table sys)
  (read-nametable-region sys 0 0 32 30))

;; Decode a tile index to a character (for debugging/display)
(define (tile->char tile)
  (cond
    ;; Common blank tiles
    [(or (= tile 0) (= tile #x20) (= tile #xFF)) #\space]
    ;; ASCII-like digits $30-$39 -> '0'-'9'
    [(and (>= tile #x30) (<= tile #x39))
     (integer->char tile)]
    ;; ASCII-like uppercase $41-$5A -> 'A'-'Z'
    [(and (>= tile #x41) (<= tile #x5A))
     (integer->char tile)]
    ;; ASCII-like lowercase $61-$7A -> 'a'-'z'
    [(and (>= tile #x61) (<= tile #x7A))
     (integer->char tile)]
    ;; Hex digits at $00-$0F (common NES pattern)
    [(and (>= tile #x00) (<= tile #x09))
     (integer->char (+ tile #x30))]  ; 0-9
    [(and (>= tile #x0A) (<= tile #x0F))
     (integer->char (+ tile #x41 -10))]  ; A-F
    ;; Some ROMs use $10-$19 for 0-9
    [(and (>= tile #x10) (<= tile #x19))
     (integer->char (+ (- tile #x10) #x30))]
    ;; Fallback: show as hex
    [else #\.]))

;; Convert nametable to a string for display
(define (nametable->string table)
  (string-join
   (for/list ([row (in-list table)])
     (list->string (map tile->char row)))
   "\n"))

;; Parse results from the nametable
;; Returns a hash with test results
;; The exact format depends on how AccuracyCoin displays results
(define (parse-results sys)
  (define table (read-results-table sys))

  ;; For now, just return the raw table and string representation
  ;; We can refine this once we see the actual tile values
  (define table-str (nametable->string table))

  ;; Count potential pass/fail indicators
  ;; This is a heuristic - we'll refine based on actual output
  (define all-tiles (apply append table))

  ;; Look for common patterns:
  ;; - Tile values that look like 'P' (pass) or 'F' (fail)
  ;; - Numeric error codes (1-9, A-Z for extended codes)
  (define p-count (count (λ (t) (or (= t #x50) (= t #x10))) all-tiles))  ; 'P'
  (define f-count (count (λ (t) (or (= t #x46) (= t #x16))) all-tiles))  ; 'F'

  (hasheq 'table table
          'display table-str
          'possible-passes p-count
          'possible-fails f-count
          'raw-tiles all-tiles))

;; Dump nametable for debugging
(define (dump-nametable sys #:all-rows? [all-rows? #f])
  (define table (read-results-table sys))
  (printf "Nametable dump (32x30):\n")
  (printf "~a\n" (nametable->string table))

  ;; Also show raw hex for rows
  (define rows-to-show (if all-rows? table (take table 10)))
  (printf "\nRaw tile values (~a rows):\n" (length rows-to-show))
  (for ([row (in-list rows-to-show)]
        [y (in-naturals)])
    (printf "Row ~a: ~a\n" y
            (string-join (map (λ (t) (format "~a" (if (< t 16)
                                                       (format "0~x" t)
                                                       (format "~x" t))))
                              row)
                         " "))))

;; Parse the "TESTS PASSED: X / Y" line from nametable
;; Returns (values passed total) or (values #f #f) if not found
(define (parse-test-summary sys)
  (define pbus (nes-ppu-bus sys))
  (define vram (ppu-bus-vram pbus))

  ;; The AccuracyCoin ROM uses a specific tile mapping:
  ;; - $00-$09 = digits 0-9
  ;; - $0a-$1d = letters A-T (roughly, $0a=A, $0b=B, etc.)
  ;; - $24 = space
  ;; - $33 = slash '/'
  ;; - $28 = colon ':'
  ;;
  ;; Row 20 shows: "TESTS PASSED: 83 / 131"
  ;; As hex: 1d 0e 1c 1d 1c 24 19 0a 1c 1c 0e 0d 28 24 08 03 24 33 24 01 03 01
  ;;         T  E  S  T  S  sp P  A  S  S  E  D  :  sp 8  3  sp /  sp 1  3  1

  ;; Read all 30 rows
  (define all-rows
    (for/list ([y (in-range 30)])
      (for/list ([x (in-range 32)])
        (bytes-ref vram (+ (* y 32) x)))))

  ;; Look for the slash character ($33) which separates passed/total
  ;; Format: [passed-digits] $24 $33 $24 [total-digits]
  (define (find-slash-separated-numbers row)
    ;; Find $33 (slash) and extract numbers before and after
    ;; Returns (list passed total) or #f
    (for/or ([x (in-range 32)])
      (and (= (list-ref row x) #x33)  ; Found slash
           ;; Look for number before slash (skip space)
           (let ([before-x (- x 1)])
             (and (>= before-x 1)
                  (= (list-ref row before-x) #x24)  ; Space before slash
                  (let ([num1 (find-number-before row (- before-x 1))])
                    (and num1
                         ;; Look for number after slash (skip space)
                         (let ([after-x (+ x 1)])
                           (and (< after-x 31)
                                (= (list-ref row after-x) #x24)  ; Space after slash
                                (let ([num2 (find-number-after row (+ after-x 1))])
                                  (and num2
                                       (list num1 num2))))))))))))

  (define (find-number-before row end-x)
    ;; Extract a number reading backwards from end-x
    ;; Returns number or #f
    (let loop ([x end-x] [digits '()] [multiplier 1])
      (if (< x 0)
          (if (null? digits)
              #f
              (apply + digits))
          (let ([tile (list-ref row x)])
            (if (and (>= tile 0) (<= tile 9))
                (loop (- x 1) (cons (* tile multiplier) digits) (* multiplier 10))
                (if (null? digits)
                    #f
                    (apply + digits)))))))

  (define (find-number-after row start-x)
    ;; Extract a number reading forwards from start-x
    ;; Returns number or #f
    (let loop ([x start-x] [num 0])
      (if (>= x 32)
          (if (= num 0)
              #f
              num)
          (let ([tile (list-ref row x)])
            (if (and (>= tile 0) (<= tile 9))
                (loop (+ x 1) (+ (* num 10) tile))
                (if (= num 0)
                    #f
                    num))))))

  ;; Search each row for the pattern
  ;; Returns (list passed total) or #f
  (for/or ([row (in-list all-rows)]
           [y (in-naturals)])
    (find-slash-separated-numbers row)))

;; Get test results summary
;; Returns a hash with 'passed, 'total, 'status
(define (get-test-results sys)
  (define result (parse-test-summary sys))
  (if result
      (let ([passed (first result)]
            [total (second result)])
        (hasheq 'passed passed
                'total total
                'failed (- total passed)
                'status (if (= passed total) 'all-passed 'some-failed)
                'summary (format "~a/~a passed (~a failed)"
                                 passed total (- total passed))))
      (hasheq 'passed #f
              'total #f
              'status 'unknown
              'summary "Could not parse test results")))

;; ============================================================================
;; Detailed Results Parsing
;; ============================================================================

;; AccuracyCoin tile mapping for text:
;; $00-$09 = digits 0-9
;; $0a = A, $0b = B, ..., $1d = T, etc.
;; $24 = space
;; Letter offset: tile - $0a + 'A' for A-Z

;; Convert a tile to its character representation
;; AccuracyCoin tile mapping (empirically determined):
;; $00-$09 = digits 0-9
;; $0a-$23 = letters A-Z
;; $24 = space
;; $29 = ' (apostrophe, used in "INDIRECT'Y")
;; $30 = + (plus, "DMA + OPEN BUS")
;; $31 = - (hyphen, "4-STEP", "5-STEP")
;; $33 = / (slash in "X / Y")
;; $35 = $ (dollar sign, before hex like "$93")
(define (tile->letter tile)
  (cond
    [(= tile #x24) #\space]
    [(and (>= tile 0) (<= tile 9))
     (integer->char (+ tile #x30))]  ; 0-9
    [(and (>= tile #x0a) (<= tile #x23))
     (integer->char (+ (- tile #x0a) (char->integer #\A)))]  ; A-Z
    [(= tile #x29) #\']    ; Apostrophe (INDIRECT'Y)
    [(= tile #x30) #\+]    ; Plus (DMA + OPEN BUS)
    [(= tile #x31) #\-]    ; Hyphen/minus (4-STEP, 5-STEP)
    [(= tile #x33) #\/]    ; Slash (X / Y)
    [(= tile #x35) #\$]    ; Dollar sign ($93)
    [(= tile #x26) #\:]    ; Colon
    [(= tile #x27) #\.]    ; Period
    [(= tile #x28) #\:]    ; Colon variant
    [(= tile #x2a) #\*]    ; Asterisk
    [(= tile #x2c) #\,]    ; Comma
    [(= tile #x2e) #\.]    ; Period
    [(= tile #x2f) #\/]    ; Slash
    [else #\?]))

;; Convert a row of tiles to a string
(define (tiles->string tiles)
  (list->string (map tile->letter tiles)))

;; Parse the current page of results from nametable
;; Returns a list of test results: (list (hash 'name "..." 'status 'pass/'fail 'error-code N) ...)
(define (parse-current-page sys)
  (define pbus (nes-ppu-bus sys))
  (define vram (ppu-bus-vram pbus))

  ;; Read all rows
  (define (read-row y)
    (for/list ([x (in-range 32)])
      (bytes-ref vram (+ (* y 32) x))))

  ;; Check if tiles match "PASS" at position
  ;; PASS = $19 $0a $1c $1c (P A S S)
  (define (is-pass? row x)
    (and (>= (- 32 x) 4)
         (= (list-ref row x) #x19)       ; P
         (= (list-ref row (+ x 1)) #x0a) ; A
         (= (list-ref row (+ x 2)) #x1c) ; S
         (= (list-ref row (+ x 3)) #x1c))) ; S

  ;; Check if tiles match "FAIL" at position
  ;; FAIL = $0f $0a $12 $15 (F A I L)
  (define (is-fail? row x)
    (and (>= (- 32 x) 4)
         (= (list-ref row x) #x0f)       ; F
         (= (list-ref row (+ x 1)) #x0a) ; A
         (= (list-ref row (+ x 2)) #x12) ; I
         (= (list-ref row (+ x 3)) #x15))) ; L

  ;; Check if tiles match "DRAW" at position
  ;; DRAW = $0d $1b $0a $20 (D R A W)
  (define (is-draw? row x)
    (and (>= (- 32 x) 4)
         (= (list-ref row x) #x0d)       ; D
         (= (list-ref row (+ x 1)) #x1b) ; R
         (= (list-ref row (+ x 2)) #x0a) ; A
         (= (list-ref row (+ x 3)) #x20))) ; W

  ;; Extract test name starting at position x
  (define (extract-name row start-x)
    (define name-tiles
      (for/list ([x (in-range start-x 32)])
        (list-ref row x)))
    ;; Trim trailing spaces
    (string-trim (tiles->string name-tiles)))

  ;; Parse a single row for test result
  ;; Tests start at column 1 (column 0 is space)
  ;; Format: " PASS   <name>" or " FAIL X <name>" or " DRAW   <name>"
  (define (parse-test-row row)
    (cond
      ;; Check for PASS at column 1
      [(is-pass? row 1)
       ;; Name starts after "PASS   " (column 8)
       (define name (extract-name row 8))
       (and (not (string=? name ""))
            (hasheq 'status 'pass
                    'error-code #f
                    'name name))]
      ;; Check for FAIL at column 1
      [(is-fail? row 1)
       ;; After "FAIL " is the error code digit, then space, then name
       ;; " FAIL X <name>" - error code at column 6, name at column 8
       (define error-tile (list-ref row 6))
       (define error-code (if (and (>= error-tile 0) (<= error-tile 9))
                              error-tile
                              0))
       (define name (extract-name row 8))
       (and (not (string=? name ""))
            (hasheq 'status 'fail
                    'error-code error-code
                    'name name))]
      ;; Check for DRAW at column 1 (power-on state tests - inconclusive)
      [(is-draw? row 1)
       ;; Name starts after "DRAW   " (column 8)
       (define name (extract-name row 8))
       (and (not (string=? name ""))
            (hasheq 'status 'draw
                    'error-code #f
                    'name name))]
      [else #f]))

  ;; Parse rows - tests appear on odd rows (7, 9, 11, ...) based on observation
  ;; Let's scan rows 5-25 to be safe
  (define results
    (for/list ([y (in-range 5 26)])
      (define row (read-row y))
      (parse-test-row row)))

  ;; Filter out #f entries
  (filter values results))

;; Parse the current page number from nametable
;; Returns (list current-page total-pages) or #f
;; Not currently used - we know there are 20 pages
(define (parse-page-number sys)
  #f)

;; Press right button for one frame cycle
(define (press-right! sys)
  (define ctrl1 (nes-controller1 sys))
  (controller-set-button! ctrl1 BUTTON-RIGHT #t)
  (nes-run-frame! sys)
  (nes-run-frame! sys)
  (controller-set-button! ctrl1 BUTTON-RIGHT #f)
  ;; Wait for screen to update - increase wait time for reliability
  (for ([_ (in-range 15)])
    (nes-run-frame! sys)))

;; Press start button for one frame cycle
(define (press-start! sys)
  (define ctrl1 (nes-controller1 sys))
  (controller-set-button! ctrl1 BUTTON-START #t)
  (nes-run-frame! sys)
  (nes-run-frame! sys)
  (controller-set-button! ctrl1 BUTTON-START #f)
  ;; Wait for response - need longer wait for screen transitions
  (for ([_ (in-range 10)])
    (nes-run-frame! sys)))

;; Run tests and collect detailed results from all pages
;; Returns a hash with 'tests (list of test hashes), 'passed, 'failed, 'total
(define (run-and-collect-all-results rom-path
                                      #:verbose? [verbose? #t])
  (define rom (load-rom rom-path))
  (define mapper (create-mapper rom))
  (define sys (make-nes mapper))
  (nes-reset! sys)

  (when verbose?
    (printf "AccuracyCoin Detailed Test Harness\n")
    (printf "ROM: ~a\n" rom-path))

  ;; Boot and wait
  (when verbose? (printf "Booting...\n"))
  (for ([_ (in-range 60)])
    (nes-run-frame! sys))

  ;; Press Start to run all tests
  (when verbose? (printf "Running all tests...\n"))
  (press-start! sys)

  ;; Wait for tests to complete (about 50 seconds = 3000 frames)
  (for ([frame (in-range 2900)])
    (when (and verbose? (= (modulo frame 500) 0))
      (printf "Frame ~a/2900...\n" frame))
    (nes-run-frame! sys))

  ;; Now press Start again to go back to page 1 of results
  (when verbose? (printf "Navigating to results pages...\n"))
  (press-start! sys)

  ;; Wait longer for the page to render (screen transition takes ~60 frames)
  (for ([_ (in-range 60)])
    (nes-run-frame! sys))

  ;; Collect results from all 20 pages
  (define all-tests '())

  (for ([page (in-range 20)])
    (when verbose? (printf "Reading page ~a/20...\n" (+ page 1)))

    ;; Parse current page
    (define page-tests (parse-current-page sys))
    (when verbose?
      (printf "  Found ~a tests on this page\n" (length page-tests)))
    (set! all-tests (append all-tests page-tests))

    ;; Go to next page (unless last page)
    (when (< page 19)
      (press-right! sys)))

  ;; Calculate summary
  (define passed (count (λ (t) (eq? (hash-ref t 'status) 'pass)) all-tests))
  (define failed (count (λ (t) (eq? (hash-ref t 'status) 'fail)) all-tests))
  (define drawn (count (λ (t) (eq? (hash-ref t 'status) 'draw)) all-tests))
  (define total (length all-tests))

  (when verbose?
    (printf "\n=== Results Summary ===\n")
    (printf "Total tests found: ~a\n" total)
    (printf "Passed: ~a\n" passed)
    (printf "Failed: ~a\n" failed)
    (when (> drawn 0)
      (printf "Draw (power-on state): ~a\n" drawn)))

  (hasheq 'tests all-tests
          'passed passed
          'failed failed
          'draw drawn
          'total total
          'status (if (= failed 0) 'all-passed 'some-failed)))

;; Get detailed results from the current system state
;; (Assumes tests have been run and we're on page 1)
(define (get-detailed-results sys #:verbose? [verbose? #f])
  ;; Collect from all pages
  (define all-tests '())

  (for ([page (in-range 20)])
    (when verbose? (printf "Reading page ~a/20...\n" (+ page 1)))
    (define page-tests (parse-current-page sys))
    (set! all-tests (append all-tests page-tests))
    (when (< page 19)
      (press-right! sys)))

  (define passed (count (λ (t) (eq? (hash-ref t 'status) 'pass)) all-tests))
  (define failed (count (λ (t) (eq? (hash-ref t 'status) 'fail)) all-tests))

  (hasheq 'tests all-tests
          'passed passed
          'failed failed
          'total (length all-tests)))

;; ============================================================================
;; Tests
;; ============================================================================

(module+ test
  (require rackunit
           racket/file)

  (define rom-path "test/roms/accuracy-coin/AccuracyCoin.nes")

  (test-case "accuracy-coin ROM loads and runs"
    (when (file-exists? rom-path)
      ;; Just verify it loads and runs without crashing
      ;; Run 120 frames (2 seconds) - enough to boot and start tests
      (define sys (run-accuracy-coin rom-path
                                     #:frames 120
                                     #:verbose? #f))
      (check-true (nes? sys))
      (check-true (> (nes-frame-count sys) 0))))

  (test-case "accuracy-coin full run parses results"
    (when (file-exists? rom-path)
      ;; Run full test suite and verify we can parse results
      (define sys (run-accuracy-coin rom-path
                                     #:frames 3000
                                     #:verbose? #f))
      (define results (get-test-results sys))
      (check-true (hash? results))
      (check-true (number? (hash-ref results 'passed)))
      (check-true (number? (hash-ref results 'total)))
      (check-equal? (hash-ref results 'total) 131)
      ;; Should pass at least 85 tests currently
      (check-true (>= (hash-ref results 'passed) 85)))))

;; ============================================================================
;; Main
;; ============================================================================

(module+ main
  (require racket/cmdline)

  (define rom-path (make-parameter "test/roms/accuracy-coin/AccuracyCoin.nes"))
  (define frames (make-parameter 3000))
  (define detailed? (make-parameter #f))
  (define show-failures-only? (make-parameter #f))

  (command-line
   #:program "accuracy-coin"
   #:once-each
   [("--rom" "-r") path "ROM file path" (rom-path path)]
   [("--frames" "-f") n "Number of frames to run" (frames (string->number n))]
   [("--detailed" "-d") "Parse and show detailed test results" (detailed? #t)]
   [("--failures" "-F") "Show only failures (implies --detailed)" (begin (detailed? #t) (show-failures-only? #t))]
   ;; Accept --tick for backwards compatibility but ignore it
   [("--tick" "-t") "Ignored (cycle-accurate mode is now default)" (void)])

  (unless (file-exists? (rom-path))
    (eprintf "Error: ROM not found: ~a\n" (rom-path))
    (exit 1))

  (if (detailed?)
      ;; Detailed mode: collect results from all pages
      (let ([results (run-and-collect-all-results (rom-path)
                                                   #:verbose? #t)])
        (printf "\n")

        ;; Show individual test results
        (define tests (hash-ref results 'tests))
        (define tests-to-show
          (if (show-failures-only?)
              (filter (λ (t) (eq? (hash-ref t 'status) 'fail)) tests)
              tests))

        (when (not (null? tests-to-show))
          (printf "~a\n" (if (show-failures-only?)
                             "=== Failed Tests ==="
                             "=== All Test Results ==="))
          (for ([test (in-list tests-to-show)]
                [i (in-naturals 1)])
            (define status (hash-ref test 'status))
            (define name (hash-ref test 'name))
            (define error-code (hash-ref test 'error-code))
            (case status
              [(pass) (printf "  PASS: ~a\n" name)]
              [(fail) (printf "  FAIL ~a: ~a\n" error-code name)]
              [(draw) (printf "  DRAW: ~a\n" name)]))
          (printf "\n"))

        (printf "=== Summary ===\n")
        (printf "Passed: ~a/~a\n" (hash-ref results 'passed) (hash-ref results 'total))
        (printf "Failed: ~a\n" (hash-ref results 'failed))
        (define draw-count (hash-ref results 'draw 0))
        (when (> draw-count 0)
          (printf "Draw: ~a\n" draw-count))
        (printf "Status: ~a\n" (hash-ref results 'status)))

      ;; Simple mode: just run and parse summary
      (let ([sys (run-accuracy-coin (rom-path)
                                    #:frames (frames)
                                    #:verbose? #t)])
        (printf "\n--- Test Results ---\n")
        (define results (get-test-results sys))
        (printf "~a\n" (hash-ref results 'summary))
        (printf "Status: ~a\n" (hash-ref results 'status))))

  (printf "\nTest run complete.\n"))
