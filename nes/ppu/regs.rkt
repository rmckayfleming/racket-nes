#lang racket/base

;; PPU Register Access
;;
;; Implements the CPU-visible PPU registers at $2000-$2007.
;; These have complex side effects that this module handles.
;;
;; Registers:
;; $2000 PPUCTRL   - write only
;; $2001 PPUMASK   - write only
;; $2002 PPUSTATUS - read only (with side effects)
;; $2003 OAMADDR   - write only
;; $2004 OAMDATA   - read/write
;; $2005 PPUSCROLL - write x2
;; $2006 PPUADDR   - write x2
;; $2007 PPUDATA   - read/write
;;
;; Reference: https://www.nesdev.org/wiki/PPU_registers

(provide
 ;; Register read/write
 ppu-reg-read
 ppu-reg-write

 ;; Individual register operations (for testing)
 ppu-read-status
 ppu-write-ctrl
 ppu-write-mask
 ppu-write-oam-addr
 ppu-read-oam-data
 ppu-write-oam-data
 ppu-write-scroll
 ppu-write-addr
 ppu-read-data
 ppu-write-data)

(require "ppu.rkt"
         "timing.rkt"
         "../../lib/bits.rkt")

;; ============================================================================
;; Register Read
;; ============================================================================

;; Read from PPU register (0-7)
;; Returns (values byte nmi-changed?)
;; nmi-changed? indicates if NMI state may have changed
;;
;; Write-only registers return the I/O latch value (last value on PPU data bus).
;; Reading any register updates the I/O latch with the value read.
;; Reference: https://www.nesdev.org/wiki/Open_bus_behavior
(define (ppu-reg-read p reg ppu-bus-read)
  (define latch (ppu-io-latch p))
  (define-values (result nmi-changed?)
    (case reg
      [(0) (values latch #f)]              ; PPUCTRL - write only, returns I/O latch
      [(1) (values latch #f)]              ; PPUMASK - write only, returns I/O latch
      [(2)                                 ; PPUSTATUS - bits 7-5 from status, bits 4-0 from latch
       (define status (ppu-read-status p))
       ;; Upper 3 bits from status, lower 5 bits from latch
       (values (bitwise-ior (bitwise-and status #xE0)
                            (bitwise-and latch #x1F))
               #t)]
      [(3) (values latch #f)]              ; OAMADDR - write only, returns I/O latch
      [(4) (values (ppu-read-oam-data p) #f)] ; OAMDATA
      [(5) (values latch #f)]              ; PPUSCROLL - write only, returns I/O latch
      [(6) (values latch #f)]              ; PPUADDR - write only, returns I/O latch
      [(7) (values (ppu-read-data p ppu-bus-read) #f)] ; PPUDATA
      [else (values latch #f)]))
  ;; Update I/O latch with the value being returned
  (set-ppu-io-latch! p result)
  (values result nmi-changed?))

;; ============================================================================
;; Register Write
;; ============================================================================

;; Write to PPU register (0-7)
;; Returns nmi-changed? boolean
;; All writes update the I/O latch with the value written.
(define (ppu-reg-write p reg val ppu-bus-write)
  ;; Update I/O latch with value being written
  (set-ppu-io-latch! p val)
  (case reg
    [(0) (ppu-write-ctrl p val)]     ; PPUCTRL
    [(1) (ppu-write-mask p val) #f]  ; PPUMASK
    [(2) #f]                         ; PPUSTATUS - read only
    [(3) (ppu-write-oam-addr p val) #f] ; OAMADDR
    [(4) (ppu-write-oam-data p val) #f] ; OAMDATA
    [(5) (ppu-write-scroll p val) #f]   ; PPUSCROLL
    [(6) (ppu-write-addr p val) #f]     ; PPUADDR
    [(7) (ppu-write-data p val ppu-bus-write) #f] ; PPUDATA
    [else #f]))

;; ============================================================================
;; $2000 - PPUCTRL (write only)
;; ============================================================================

;; Write to PPUCTRL
;; Updates t register nametable select bits
;; Returns nmi-changed? boolean
(define (ppu-write-ctrl p val)
  (define old-nmi (ppu-ctrl-flag? p CTRL-NMI-ENABLE))

  ;; Set control register
  (set-ppu-ctrl! p val)

  ;; Update t register bits 10-11 (nametable select)
  (define t (ppu-t p))
  (define new-t (bitwise-ior
                 (bitwise-and t #x73FF)  ; Clear bits 10-11
                 (arithmetic-shift (bitwise-and val #x03) 10)))
  (set-ppu-t! p new-t)

  ;; Check if NMI should be triggered
  ;; (NMI fires if enabled and VBlank flag is set)
  (define new-nmi (bit? val CTRL-NMI-ENABLE))
  (define nmi-occurred (ppu-nmi-occurred? p))

  ;; Update NMI output
  (set-ppu-nmi-output! p (and new-nmi nmi-occurred))

  ;; Return whether NMI state changed
  (not (eq? old-nmi new-nmi)))

;; ============================================================================
;; $2001 - PPUMASK (write only)
;; ============================================================================

(define (ppu-write-mask p val)
  (set-ppu-mask! p val))

;; ============================================================================
;; $2002 - PPUSTATUS (read only)
;; ============================================================================

;; Read PPUSTATUS
;; Side effects:
;; - Clears VBlank flag
;; - Resets w toggle
(define (ppu-read-status p)
  ;; Build status byte from flags
  (define status
    (bitwise-ior
     (if (ppu-sprite-overflow? p) #x20 0)
     (if (ppu-sprite0-hit? p) #x40 0)
     (if (ppu-nmi-occurred? p) #x80 0)))

  ;; Clear VBlank flag
  (set-ppu-nmi-occurred! p #f)

  ;; Update NMI output
  (set-ppu-nmi-output! p #f)

  ;; Reset write toggle
  (set-ppu-w! p #f)

  status)

;; ============================================================================
;; $2003 - OAMADDR (write only)
;; ============================================================================

(define (ppu-write-oam-addr p val)
  (set-ppu-oam-addr! p val))

;; ============================================================================
;; $2004 - OAMDATA (read/write)
;; ============================================================================

(define (ppu-read-oam-data p)
  (bytes-ref (ppu-oam p) (ppu-oam-addr p)))

(define (ppu-write-oam-data p val)
  (bytes-set! (ppu-oam p) (ppu-oam-addr p) val)
  ;; Increment OAM address
  (set-ppu-oam-addr! p (u8 (+ (ppu-oam-addr p) 1))))

;; ============================================================================
;; $2005 - PPUSCROLL (write x2)
;; ============================================================================

;; Write to PPUSCROLL
;; First write: X scroll (coarse X to t, fine X to x)
;; Second write: Y scroll (coarse Y and fine Y to t)
(define (ppu-write-scroll p val)
  (if (not (ppu-w p))
      ;; First write (X scroll)
      (let* ([t (ppu-t p)]
             [new-t (bitwise-ior
                     (bitwise-and t #x7FE0)  ; Clear bits 0-4
                     (arithmetic-shift val -3))])
        ;; Fine X goes to x register (bits 0-2)
        (set-ppu-x! p (bitwise-and val #x07))
        ;; Coarse X goes to t register (bits 0-4)
        (set-ppu-t! p new-t)
        ;; Toggle w
        (set-ppu-w! p #t))
      ;; Second write (Y scroll)
      (let* ([t (ppu-t p)]
             ;; Fine Y: bits 0-2 of val -> bits 12-14 of t
             ;; Coarse Y: bits 3-7 of val -> bits 5-9 of t
             [fine-y (bitwise-and val #x07)]
             [coarse-y (arithmetic-shift val -3)]
             [new-t (bitwise-ior
                     (bitwise-and t #x0C1F)  ; Keep bits 0-4, 10-11
                     (arithmetic-shift fine-y 12)
                     (arithmetic-shift coarse-y 5))])
        (set-ppu-t! p new-t)
        ;; Toggle w
        (set-ppu-w! p #f))))

;; ============================================================================
;; $2006 - PPUADDR (write x2)
;; ============================================================================

;; Write to PPUADDR
;; First write: High byte of address (bits 8-13, bit 14 cleared)
;; Second write: Low byte, then t copied to v
(define (ppu-write-addr p val)
  (if (not (ppu-w p))
      ;; First write (high byte)
      (let* ([t (ppu-t p)]
             ;; Clear bits 8-14, set bits 8-13 from val (bit 14 always 0)
             [new-t (bitwise-ior
                     (bitwise-and t #x00FF)
                     (arithmetic-shift (bitwise-and val #x3F) 8))])
        (set-ppu-t! p new-t)
        (set-ppu-w! p #t))
      ;; Second write (low byte)
      (let* ([t (ppu-t p)]
             [new-t (bitwise-ior
                     (bitwise-and t #x7F00)
                     val)])
        (set-ppu-t! p new-t)
        ;; Copy t to v
        (set-ppu-v! p new-t)
        (set-ppu-w! p #f))))

;; ============================================================================
;; $2007 - PPUDATA (read/write)
;; ============================================================================

;; Read from PPUDATA
;; For addresses < $3F00: returns buffered value, updates buffer
;; For palette ($3F00+): returns value directly, buffer gets nametable data
(define (ppu-read-data p ppu-bus-read)
  (define v (ppu-v p))
  (define result
    (if (< v #x3F00)
        ;; Non-palette read: return buffer, fetch new value
        (let ([buffered (ppu-read-buffer p)])
          (set-ppu-read-buffer! p (ppu-bus-read v))
          buffered)
        ;; Palette read: return directly, buffer gets nametable underneath
        (begin
          (set-ppu-read-buffer! p (ppu-bus-read (bitwise-and v #x2FFF)))
          (ppu-bus-read v))))

  ;; Increment v
  (set-ppu-v! p (+ v (ppu-vram-increment p)))

  result)

;; Write to PPUDATA
(define (ppu-write-data p val ppu-bus-write)
  (define v (ppu-v p))
  (ppu-bus-write v val)
  ;; Increment v
  (set-ppu-v! p (+ v (ppu-vram-increment p))))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  ;; Mock PPU bus read/write
  (define test-vram (make-bytes #x4000 0))

  (define (mock-ppu-read addr)
    (bytes-ref test-vram (bitwise-and addr #x3FFF)))

  (define (mock-ppu-write addr val)
    (bytes-set! test-vram (bitwise-and addr #x3FFF) val))

  (test-case "PPUSTATUS read clears vblank and w"
    (define p (make-ppu))
    (set-ppu-nmi-occurred! p #t)
    (set-ppu-w! p #t)

    (define status (ppu-read-status p))
    (check-equal? (bitwise-and status #x80) #x80)  ; VBlank was set
    (check-false (ppu-nmi-occurred? p))            ; Now cleared
    (check-false (ppu-w p)))                       ; Toggle reset

  (test-case "PPUCTRL updates t nametable bits"
    (define p (make-ppu))
    (ppu-write-ctrl p #x03)  ; Nametable 3
    (check-equal? (bitwise-and (ppu-t p) #x0C00) #x0C00))

  (test-case "PPUSCROLL first write"
    (define p (make-ppu))
    (ppu-write-scroll p #xD5)  ; X = 213 (coarse: 26, fine: 5)
    (check-equal? (ppu-x p) 5)
    (check-equal? (bitwise-and (ppu-t p) #x001F) 26)
    (check-true (ppu-w p)))

  (test-case "PPUSCROLL second write"
    (define p (make-ppu))
    (ppu-write-scroll p #x00)  ; First write
    (ppu-write-scroll p #xE8)  ; Y = 232 (coarse: 29, fine: 0)
    (check-equal? (bitwise-and (arithmetic-shift (ppu-t p) -5) #x1F) 29)
    (check-false (ppu-w p)))

  (test-case "PPUADDR sets v after second write"
    (define p (make-ppu))
    (ppu-write-addr p #x21)  ; High byte
    (ppu-write-addr p #x00)  ; Low byte
    (check-equal? (ppu-v p) #x2100))

  (test-case "PPUDATA read buffering"
    (define p (make-ppu))
    ;; Set up test data
    (bytes-set! test-vram #x2000 #x42)
    (bytes-set! test-vram #x2001 #x43)

    (set-ppu-v! p #x2000)
    (define first (ppu-read-data p mock-ppu-read))
    ;; First read returns old buffer (0)
    (check-equal? first 0)
    ;; Second read returns previously buffered value
    (define second (ppu-read-data p mock-ppu-read))
    (check-equal? second #x42))

  (test-case "PPUDATA write increments v"
    (define p (make-ppu))
    (set-ppu-v! p #x2000)
    (ppu-write-data p #xAB mock-ppu-write)
    (check-equal? (bytes-ref test-vram #x2000) #xAB)
    (check-equal? (ppu-v p) #x2001))

  (test-case "PPUDATA increment by 32 when CTRL bit set"
    (define p (make-ppu))
    (ppu-write-ctrl p #x04)  ; Set increment mode
    (set-ppu-v! p #x2000)
    (ppu-write-data p #x00 mock-ppu-write)
    (check-equal? (ppu-v p) #x2020))

  (test-case "OAMDATA read/write"
    (define p (make-ppu))
    (ppu-write-oam-addr p #x10)
    (ppu-write-oam-data p #x42)
    (check-equal? (ppu-oam-addr p) #x11)  ; Incremented
    (ppu-write-oam-addr p #x10)
    (check-equal? (ppu-read-oam-data p) #x42)))
