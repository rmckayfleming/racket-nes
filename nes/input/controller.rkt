#lang racket/base

;; NES Controller
;;
;; Implements the standard NES controller with 8 buttons and shift register
;; behavior for serial reads via $4016/$4017.
;;
;; Button order (bit 0 first when reading):
;; A, B, Select, Start, Up, Down, Left, Right
;;
;; Strobe behavior:
;; - Writing 1 to $4016 holds the shift register in reset (continuously reloads)
;; - Writing 0 to $4016 allows serial reads to shift out button states
;; - Each read from $4016/$4017 returns bit 0 and shifts the register right
;;
;; After 8 reads, subsequent reads return 1 (official controllers)
;; or 0 (some clones). We return 1 for compatibility.
;;
;; Reference: https://www.nesdev.org/wiki/Standard_controller

(provide
 ;; Controller creation
 make-controller
 controller?

 ;; Button state (for frontend to set)
 controller-set-button!
 controller-get-buttons

 ;; I/O (for memory map)
 controller-write!    ; Strobe write
 controller-read      ; Serial read

 ;; Button constants
 BUTTON-A
 BUTTON-B
 BUTTON-SELECT
 BUTTON-START
 BUTTON-UP
 BUTTON-DOWN
 BUTTON-LEFT
 BUTTON-RIGHT)

(require "../../lib/bits.rkt")

;; ============================================================================
;; Button Constants
;; ============================================================================

(define BUTTON-A      0)
(define BUTTON-B      1)
(define BUTTON-SELECT 2)
(define BUTTON-START  3)
(define BUTTON-UP     4)
(define BUTTON-DOWN   5)
(define BUTTON-LEFT   6)
(define BUTTON-RIGHT  7)

;; ============================================================================
;; Controller Structure
;; ============================================================================

;; Controller state:
;; - buttons: Current button state (8 bits, 1 = pressed)
;; - shift-reg: Shift register for serial reads
;; - strobe: Whether strobe is active (continuously reload shift register)
(struct controller
  (buttons-box      ; Current button state byte
   shift-reg-box    ; Shift register for serial output
   strobe-box)      ; Strobe state
  #:transparent)

;; ============================================================================
;; Controller Creation
;; ============================================================================

(define (make-controller)
  (controller (box 0)    ; No buttons pressed
              (box 0)    ; Empty shift register
              (box #f))) ; Strobe inactive

;; ============================================================================
;; Button State Management
;; ============================================================================

;; Set a single button state
;; button: One of the BUTTON-* constants (0-7)
;; pressed?: #t if pressed, #f if released
(define (controller-set-button! ctrl button pressed?)
  (define current (unbox (controller-buttons-box ctrl)))
  (define new-state
    (if pressed?
        (bitwise-ior current (arithmetic-shift 1 button))
        (bitwise-and current (bitwise-not (arithmetic-shift 1 button)))))
  (set-box! (controller-buttons-box ctrl) (u8 new-state))

  ;; If strobe is active, immediately update shift register
  (when (unbox (controller-strobe-box ctrl))
    (set-box! (controller-shift-reg-box ctrl) (unbox (controller-buttons-box ctrl)))))

;; Get the current button state byte (for debugging/display)
(define (controller-get-buttons ctrl)
  (unbox (controller-buttons-box ctrl)))

;; ============================================================================
;; I/O Operations
;; ============================================================================

;; Handle write to controller port ($4016)
;; Only bit 0 matters for strobe
(define (controller-write! ctrl val)
  (define strobe-bit (bitwise-and val 1))
  (define new-strobe (= strobe-bit 1))

  ;; If strobe transitions from 1 to 0, latch current button state
  ;; If strobe is 1, continuously reload shift register
  (when new-strobe
    (set-box! (controller-shift-reg-box ctrl) (unbox (controller-buttons-box ctrl))))

  ;; If transitioning from strobe=1 to strobe=0, the shift register
  ;; keeps its current value (already loaded above on the 1 write)
  (set-box! (controller-strobe-box ctrl) new-strobe))

;; Handle read from controller port ($4016 or $4017)
;; Returns bit 0 of shift register, then shifts right
;; After 8 reads, returns 1 (open bus behavior on official controllers)
(define (controller-read ctrl)
  ;; If strobe is active, return current A button state
  ;; (shift register is continuously being reloaded)
  (if (unbox (controller-strobe-box ctrl))
      (bitwise-and (unbox (controller-buttons-box ctrl)) 1)
      ;; Normal read: get bit 0, shift right, fill with 1s
      (let ([shift-reg (unbox (controller-shift-reg-box ctrl))])
        (define result (bitwise-and shift-reg 1))
        ;; Shift right and fill bit 7 with 1 (after 8 reads, all 1s)
        (set-box! (controller-shift-reg-box ctrl)
                  (bitwise-ior (arithmetic-shift shift-reg -1) #x80))
        result)))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "initial state"
    (define ctrl (make-controller))
    (check-equal? (controller-get-buttons ctrl) 0)
    (check-false (unbox (controller-strobe-box ctrl))))

  (test-case "button press and release"
    (define ctrl (make-controller))

    ;; Press A
    (controller-set-button! ctrl BUTTON-A #t)
    (check-equal? (controller-get-buttons ctrl) #b00000001)

    ;; Press B
    (controller-set-button! ctrl BUTTON-B #t)
    (check-equal? (controller-get-buttons ctrl) #b00000011)

    ;; Release A
    (controller-set-button! ctrl BUTTON-A #f)
    (check-equal? (controller-get-buttons ctrl) #b00000010)

    ;; Press Start
    (controller-set-button! ctrl BUTTON-START #t)
    (check-equal? (controller-get-buttons ctrl) #b00001010))

  (test-case "strobe and serial read"
    (define ctrl (make-controller))

    ;; Press A and Start
    (controller-set-button! ctrl BUTTON-A #t)
    (controller-set-button! ctrl BUTTON-START #t)
    ;; Buttons = #b00001001

    ;; Strobe to latch
    (controller-write! ctrl 1)
    (controller-write! ctrl 0)

    ;; Read 8 buttons in order: A, B, Select, Start, Up, Down, Left, Right
    (check-equal? (controller-read ctrl) 1 "A pressed")
    (check-equal? (controller-read ctrl) 0 "B not pressed")
    (check-equal? (controller-read ctrl) 0 "Select not pressed")
    (check-equal? (controller-read ctrl) 1 "Start pressed")
    (check-equal? (controller-read ctrl) 0 "Up not pressed")
    (check-equal? (controller-read ctrl) 0 "Down not pressed")
    (check-equal? (controller-read ctrl) 0 "Left not pressed")
    (check-equal? (controller-read ctrl) 0 "Right not pressed")

    ;; After 8 reads, should return 1
    (check-equal? (controller-read ctrl) 1 "Post-8 read 1")
    (check-equal? (controller-read ctrl) 1 "Post-8 read 2"))

  (test-case "strobe held high returns A button"
    (define ctrl (make-controller))

    ;; Press A
    (controller-set-button! ctrl BUTTON-A #t)

    ;; Hold strobe high
    (controller-write! ctrl 1)

    ;; Reads should all return A button state
    (check-equal? (controller-read ctrl) 1)
    (check-equal? (controller-read ctrl) 1)
    (check-equal? (controller-read ctrl) 1)

    ;; Release A while strobe still high
    (controller-set-button! ctrl BUTTON-A #f)
    (check-equal? (controller-read ctrl) 0)
    (check-equal? (controller-read ctrl) 0))

  (test-case "re-strobe reloads register"
    (define ctrl (make-controller))

    ;; Press A, strobe, read a few times
    (controller-set-button! ctrl BUTTON-A #t)
    (controller-write! ctrl 1)
    (controller-write! ctrl 0)

    (check-equal? (controller-read ctrl) 1 "First A read")
    (check-equal? (controller-read ctrl) 0 "First B read")
    (check-equal? (controller-read ctrl) 0 "First Select read")

    ;; Re-strobe should reset to beginning
    (controller-write! ctrl 1)
    (controller-write! ctrl 0)

    (check-equal? (controller-read ctrl) 1 "Second A read after re-strobe")
    (check-equal? (controller-read ctrl) 0 "Second B read")))
