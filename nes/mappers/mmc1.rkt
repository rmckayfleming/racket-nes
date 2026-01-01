#lang racket/base

;; MMC1 Mapper (Mapper 1)
;;
;; One of the most common NES mappers with PRG/CHR banking and mirroring control.
;;
;; Hardware:
;; - PRG ROM: Up to 512KB, banked in 16KB or 32KB modes
;; - CHR ROM/RAM: Up to 128KB, banked in 4KB or 8KB modes
;; - PRG RAM: 8KB at $6000-$7FFF (optionally battery-backed)
;; - Mirroring: Controlled by mapper register
;;
;; Registers (serial interface):
;; - Write to $8000-$FFFF shifts a bit into internal shift register
;; - Bit 7 set = reset shift register
;; - After 5 writes, the value is transferred to the target register
;;   based on address bits 13-14:
;;   - $8000-$9FFF: Control register
;;   - $A000-$BFFF: CHR bank 0
;;   - $C000-$DFFF: CHR bank 1
;;   - $E000-$FFFF: PRG bank
;;
;; Control Register (reg 0):
;;   Bits 0-1: Mirroring (0=one-screen lower, 1=one-screen upper, 2=vertical, 3=horizontal)
;;   Bits 2-3: PRG ROM bank mode
;;     0,1: Switch 32KB at $8000, ignore low bit of bank number
;;     2: Fix first bank at $8000, switch 16KB at $C000
;;     3: Fix last bank at $C000, switch 16KB at $8000
;;   Bit 4: CHR ROM bank mode
;;     0: Switch 8KB at a time
;;     1: Switch two separate 4KB banks
;;
;; Games: The Legend of Zelda, Metroid, Mega Man 2, Final Fantasy, etc.
;;
;; Reference: https://www.nesdev.org/wiki/MMC1

(provide
 make-mmc1-mapper)

(require "mapper.rkt"
         "../../cart/ines.rkt"
         "../../lib/bits.rkt")

;; ============================================================================
;; MMC1 Mapper Implementation
;; ============================================================================

(define (make-mmc1-mapper rom)
  (define prg-rom (rom-prg-rom rom))
  (define chr-data (rom-chr-rom rom))
  (define prg-size (bytes-length prg-rom))
  (define chr-size (bytes-length chr-data))

  ;; Determine if we have CHR RAM
  (define chr-is-ram? (zero? chr-size))

  ;; CHR ROM/RAM (up to 128KB ROM, or 8KB RAM if no CHR ROM)
  (define chr
    (if chr-is-ram?
        (make-bytes #x2000 0)   ; 8KB CHR RAM
        chr-data))

  (define actual-chr-size (bytes-length chr))

  ;; PRG RAM (8KB)
  (define prg-ram (make-bytes #x2000 0))

  ;; Number of 16KB PRG banks and 4KB CHR banks
  (define num-prg-banks (quotient prg-size #x4000))
  (define num-chr-banks (if chr-is-ram? 2 (quotient actual-chr-size #x1000)))

  ;; MMC1 internal shift register (5-bit with counter)
  (define shift-reg-box (box 0))
  (define shift-count-box (box 0))

  ;; MMC1 registers
  (define control-box (box #x0C))     ; Default: PRG mode 3, mirroring vertical
  (define chr-bank0-box (box 0))
  (define chr-bank1-box (box 0))
  (define prg-bank-box (box 0))

  ;; PRG RAM enable (bit 4 of PRG bank register, active low)
  ;; Some MMC1 variants use this, we'll enable by default
  (define prg-ram-enabled-box (box #t))

  ;; --- Helper: Get current mirroring mode ---
  (define (current-mirroring)
    (case (bitwise-and (unbox control-box) #x03)
      [(0) mirroring-single-0]
      [(1) mirroring-single-1]
      [(2) mirroring-vertical]
      [(3) mirroring-horizontal]))

  ;; --- Helper: Get PRG bank mode ---
  (define (prg-mode)
    (bitwise-and (arithmetic-shift (unbox control-box) -2) #x03))

  ;; --- Helper: Get CHR bank mode ---
  (define (chr-mode-4k?)
    (bit? (unbox control-box) 4))

  ;; --- Helper: Calculate PRG ROM offset ---
  (define (prg-offset addr)
    (define mode (prg-mode))
    (define bank (bitwise-and (unbox prg-bank-box) #x0F))
    (define last-bank (sub1 num-prg-banks))

    (cond
      ;; Modes 0,1: 32KB switching (ignore low bit of bank)
      [(<= mode 1)
       (define bank32 (quotient bank 2))
       (define masked-bank (modulo bank32 (quotient num-prg-banks 2)))
       (+ (* masked-bank #x8000) (- addr #x8000))]

      ;; Mode 2: Fix first bank at $8000, switch at $C000
      [(= mode 2)
       (if (< addr #xC000)
           ;; $8000-$BFFF: First bank (bank 0)
           (- addr #x8000)
           ;; $C000-$FFFF: Switchable
           (+ (* (modulo bank num-prg-banks) #x4000) (- addr #xC000)))]

      ;; Mode 3: Switch at $8000, fix last bank at $C000
      [else
       (if (< addr #xC000)
           ;; $8000-$BFFF: Switchable
           (+ (* (modulo bank num-prg-banks) #x4000) (- addr #x8000))
           ;; $C000-$FFFF: Last bank
           (+ (* last-bank #x4000) (- addr #xC000)))]))

  ;; --- Helper: Calculate CHR offset ---
  (define (chr-offset addr)
    (define addr-4k (bitwise-and addr #x0FFF))

    (if (chr-mode-4k?)
        ;; 4KB mode: Two separate banks
        (if (< addr #x1000)
            ;; $0000-$0FFF: CHR bank 0
            (+ (* (modulo (unbox chr-bank0-box) num-chr-banks) #x1000) addr-4k)
            ;; $1000-$1FFF: CHR bank 1
            (+ (* (modulo (unbox chr-bank1-box) num-chr-banks) #x1000) addr-4k))
        ;; 8KB mode: Use bank 0 (ignore low bit)
        (let* ([bank8 (arithmetic-shift (unbox chr-bank0-box) -1)]
               [masked-bank (modulo bank8 (quotient num-chr-banks 2))])
          (+ (* masked-bank #x2000) (bitwise-and addr #x1FFF)))))

  ;; --- Write to shift register ---
  (define (write-shift-register! addr val)
    ;; Bit 7 set = reset
    (cond
      [(bit? val 7)
       (set-box! shift-reg-box 0)
       (set-box! shift-count-box 0)
       ;; Reset also sets control register to mode 3 (lock PRG at $C000)
       (set-box! control-box (bitwise-ior (unbox control-box) #x0C))]
      [else
       ;; Shift in bit 0
       (define current (unbox shift-reg-box))
       (define new-val (bitwise-ior
                        (arithmetic-shift current -1)
                        (arithmetic-shift (bitwise-and val 1) 4)))
       (set-box! shift-reg-box new-val)
       (define count (add1 (unbox shift-count-box)))
       (set-box! shift-count-box count)

       ;; After 5 writes, transfer to target register
       (when (= count 5)
         (define target (bitwise-and (arithmetic-shift addr -13) #x03))
         (case target
           [(0) (set-box! control-box new-val)]
           [(1) (set-box! chr-bank0-box new-val)]
           [(2) (set-box! chr-bank1-box new-val)]
           [(3)
            (set-box! prg-bank-box (bitwise-and new-val #x0F))
            (set-box! prg-ram-enabled-box (not (bit? new-val 4)))])
         ;; Reset shift register
         (set-box! shift-reg-box 0)
         (set-box! shift-count-box 0))]))

  ;; --- CPU Read ($4020-$FFFF) ---
  (define (cpu-read addr)
    (cond
      ;; $6000-$7FFF: PRG RAM
      [(and (>= addr #x6000) (<= addr #x7FFF))
       (if (unbox prg-ram-enabled-box)
           (bytes-ref prg-ram (- addr #x6000))
           #x00)]  ; Open bus when disabled (simplified)

      ;; $8000-$FFFF: PRG ROM
      [(>= addr #x8000)
       (bytes-ref prg-rom (prg-offset addr))]

      ;; $4020-$5FFF: Expansion (not used) - return open bus
      [else #f]))

  ;; --- CPU Write ($4020-$FFFF) ---
  (define (cpu-write addr val)
    (cond
      ;; $6000-$7FFF: PRG RAM
      [(and (>= addr #x6000) (<= addr #x7FFF))
       (when (unbox prg-ram-enabled-box)
         (bytes-set! prg-ram (- addr #x6000) val))]

      ;; $8000-$FFFF: Shift register
      [(>= addr #x8000)
       (write-shift-register! addr val)]))

  ;; --- PPU Read ($0000-$1FFF) ---
  (define (ppu-read addr)
    (define offset (chr-offset addr))
    (if (< offset actual-chr-size)
        (bytes-ref chr offset)
        0))

  ;; --- PPU Write ($0000-$1FFF) ---
  (define (ppu-write addr val)
    ;; Only CHR RAM is writable
    (when chr-is-ram?
      (bytes-set! chr (bitwise-and addr #x1FFF) val)))

  ;; --- Mirroring ---
  (define (get-mirroring)
    (current-mirroring))

  ;; --- Serialization (for save states) ---
  (define (serialize)
    (bytes-append
     ;; Registers (5 bytes)
     (bytes (unbox shift-reg-box)
            (unbox shift-count-box)
            (unbox control-box)
            (unbox chr-bank0-box)
            (unbox chr-bank1-box))
     ;; PRG bank + RAM enable (1 byte packed)
     (bytes (bitwise-ior
             (unbox prg-bank-box)
             (if (unbox prg-ram-enabled-box) 0 #x10)))
     ;; PRG RAM (8KB)
     prg-ram
     ;; CHR RAM if applicable
     (if chr-is-ram? chr #"")))

  (define (deserialize! data)
    (set-box! shift-reg-box (bytes-ref data 0))
    (set-box! shift-count-box (bytes-ref data 1))
    (set-box! control-box (bytes-ref data 2))
    (set-box! chr-bank0-box (bytes-ref data 3))
    (set-box! chr-bank1-box (bytes-ref data 4))
    (define prg-byte (bytes-ref data 5))
    (set-box! prg-bank-box (bitwise-and prg-byte #x0F))
    (set-box! prg-ram-enabled-box (not (bit? prg-byte 4)))
    (bytes-copy! prg-ram 0 data 6 (+ 6 #x2000))
    (when chr-is-ram?
      (bytes-copy! chr 0 data (+ 6 #x2000) (+ 6 #x2000 #x2000))))

  ;; Create and return the mapper
  (make-mapper
   #:number 1
   #:name "MMC1"
   #:cpu-read cpu-read
   #:cpu-write cpu-write
   #:ppu-read ppu-read
   #:ppu-write ppu-write
   #:get-mirroring get-mirroring
   #:serialize serialize
   #:deserialize! deserialize!))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit
           "../../lib/bits.rkt")

  ;; Create a fake iNES ROM for testing MMC1
  (define (make-test-rom-bytes #:prg-banks [prg-banks 8]
                               #:chr-banks [chr-banks 0]  ; 0 = CHR RAM
                               #:mirroring [mirror 'vertical])
    ;; iNES header
    (define header (make-bytes 16 0))
    (bytes-set! header 0 (char->integer #\N))
    (bytes-set! header 1 (char->integer #\E))
    (bytes-set! header 2 (char->integer #\S))
    (bytes-set! header 3 #x1A)
    (bytes-set! header 4 prg-banks)  ; PRG ROM in 16KB units
    (bytes-set! header 5 chr-banks)  ; CHR ROM in 8KB units (0 = CHR RAM)
    ;; Flags 6: mapper low nibble = 1, mirroring (ignored by MMC1)
    (bytes-set! header 6 (bitwise-ior #x10 (if (eq? mirror 'vertical) #x01 #x00)))
    (bytes-set! header 7 #x00)       ; Mapper high nibble = 0

    ;; Create PRG ROM - each bank's first byte is its bank number
    (define prg-size (* prg-banks #x4000))
    (define prg (make-bytes prg-size))
    (for ([bank (in-range prg-banks)])
      (define offset (* bank #x4000))
      (bytes-set! prg offset (u8 bank))
      (for ([i (in-range 1 #x4000)])
        (bytes-set! prg (+ offset i) (u8 i))))

    ;; Create CHR ROM if specified
    (define chr-size (* chr-banks #x2000))
    (define chr
      (if (> chr-banks 0)
          (let ([c (make-bytes chr-size)])
            (for ([bank (in-range (* chr-banks 2))])  ; 4KB banks
              (define offset (* bank #x1000))
              (bytes-set! c offset (u8 bank)))
            c)
          #""))

    (bytes-append header prg chr))

  (define (make-test-mapper #:prg-banks [prg-banks 8]
                            #:chr-banks [chr-banks 0])
    (define rom-bytes (make-test-rom-bytes #:prg-banks prg-banks
                                           #:chr-banks chr-banks))
    (define r (parse-rom rom-bytes))
    (make-mmc1-mapper r))

  ;; Helper to write 5 bits to MMC1 shift register
  (define (mmc1-write! mapper addr val)
    (for ([i (in-range 5)])
      ((mapper-cpu-write mapper) addr (arithmetic-shift val (- i)))))

  (test-case "initial state - PRG mode 3"
    (define m (make-test-mapper #:prg-banks 8))

    ;; Default control = $0C (PRG mode 3, vertical mirroring)
    ;; Mode 3: switchable at $8000, fixed last bank at $C000

    ;; $8000 should be bank 0 (initial)
    (check-equal? ((mapper-cpu-read m) #x8000) 0)

    ;; $C000 should be last bank (7)
    (check-equal? ((mapper-cpu-read m) #xC000) 7))

  (test-case "shift register reset on bit 7"
    (define m (make-test-mapper #:prg-banks 8))

    ;; Write partial data
    ((mapper-cpu-write m) #x8000 1)
    ((mapper-cpu-write m) #x8000 1)

    ;; Reset with bit 7
    ((mapper-cpu-write m) #x8000 #x80)

    ;; Should still be in initial state - complete a write to verify
    ;; Write control = $1F to set horizontal mirroring
    (mmc1-write! m #x8000 #x03)  ; Horizontal mirroring

    (check-equal? ((mapper-get-mirroring m)) mirroring-horizontal))

  (test-case "mirroring control"
    (define m (make-test-mapper))

    ;; Write mirroring modes
    (mmc1-write! m #x8000 #x00)  ; Single screen lower
    (check-equal? ((mapper-get-mirroring m)) mirroring-single-0)

    (mmc1-write! m #x8000 #x01)  ; Single screen upper
    (check-equal? ((mapper-get-mirroring m)) mirroring-single-1)

    (mmc1-write! m #x8000 #x02)  ; Vertical
    (check-equal? ((mapper-get-mirroring m)) mirroring-vertical)

    (mmc1-write! m #x8000 #x03)  ; Horizontal
    (check-equal? ((mapper-get-mirroring m)) mirroring-horizontal))

  (test-case "PRG mode 3 - switchable at $8000"
    (define m (make-test-mapper #:prg-banks 8))

    ;; Set control to mode 3 (bits 2-3 = 11)
    (mmc1-write! m #x8000 #x0E)

    ;; Switch PRG bank to 3
    (mmc1-write! m #xE000 3)
    (check-equal? ((mapper-cpu-read m) #x8000) 3)

    ;; Last bank still fixed at $C000
    (check-equal? ((mapper-cpu-read m) #xC000) 7))

  (test-case "PRG mode 2 - fixed at $8000, switchable at $C000"
    (define m (make-test-mapper #:prg-banks 8))

    ;; Set control to mode 2 (bits 2-3 = 10)
    (mmc1-write! m #x8000 #x0A)

    ;; First bank fixed at $8000
    (check-equal? ((mapper-cpu-read m) #x8000) 0)

    ;; Switch PRG bank
    (mmc1-write! m #xE000 5)

    ;; $C000 should now be bank 5
    (check-equal? ((mapper-cpu-read m) #xC000) 5)

    ;; $8000 still bank 0
    (check-equal? ((mapper-cpu-read m) #x8000) 0))

  (test-case "PRG RAM read/write"
    (define m (make-test-mapper))

    ;; Write to PRG RAM
    ((mapper-cpu-write m) #x6000 #x42)
    (check-equal? ((mapper-cpu-read m) #x6000) #x42)

    ((mapper-cpu-write m) #x7FFF #xAB)
    (check-equal? ((mapper-cpu-read m) #x7FFF) #xAB))

  (test-case "CHR RAM read/write (8KB mode)"
    (define m (make-test-mapper #:chr-banks 0))  ; CHR RAM

    ;; Write and read CHR RAM
    ((mapper-ppu-write m) #x0000 #x12)
    (check-equal? ((mapper-ppu-read m) #x0000) #x12)

    ((mapper-ppu-write m) #x1FFF #x34)
    (check-equal? ((mapper-ppu-read m) #x1FFF) #x34))

  (test-case "CHR ROM banking (4KB mode)"
    (define m (make-test-mapper #:prg-banks 8 #:chr-banks 4))

    ;; Set 4KB CHR mode (bit 4 of control)
    (mmc1-write! m #x8000 #x10)

    ;; CHR bank 0 register -> $0000-$0FFF
    (mmc1-write! m #xA000 2)  ; Bank 2
    (check-equal? ((mapper-ppu-read m) #x0000) 2)

    ;; CHR bank 1 register -> $1000-$1FFF
    (mmc1-write! m #xC000 5)  ; Bank 5
    (check-equal? ((mapper-ppu-read m) #x1000) 5))

  (test-case "serialization round-trip"
    (define m (make-test-mapper))

    ;; Set up some state
    ;; Control = $0F: PRG mode 3 (bits 2-3 = 11), horizontal mirroring (bits 0-1 = 11)
    (mmc1-write! m #x8000 #x0F)
    (mmc1-write! m #xE000 3)     ; PRG bank 3
    ((mapper-cpu-write m) #x6000 #x42)  ; PRG RAM
    ((mapper-ppu-write m) #x0000 #xAB)  ; CHR RAM

    ;; Verify initial state
    (check-equal? ((mapper-get-mirroring m)) mirroring-horizontal)
    (check-equal? ((mapper-cpu-read m) #x8000) 3)

    ;; Serialize
    (define saved ((mapper-serialize m)))

    ;; Change state
    (mmc1-write! m #x8000 #x0E)  ; PRG mode 3, vertical mirroring
    (mmc1-write! m #xE000 0)     ; PRG bank 0
    ((mapper-cpu-write m) #x6000 #x00)
    ((mapper-ppu-write m) #x0000 #x00)

    ;; Verify changed
    (check-equal? ((mapper-get-mirroring m)) mirroring-vertical)
    (check-equal? ((mapper-cpu-read m) #x8000) 0)

    ;; Deserialize
    ((mapper-deserialize! m) saved)

    ;; Verify restored
    (check-equal? ((mapper-get-mirroring m)) mirroring-horizontal)
    (check-equal? ((mapper-cpu-read m) #x8000) 3)
    (check-equal? ((mapper-cpu-read m) #x6000) #x42)
    (check-equal? ((mapper-ppu-read m) #x0000) #xAB)))
