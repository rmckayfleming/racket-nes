#lang racket/base

;; MMC3 Mapper (Mapper 4)
;;
;; One of the most feature-rich NES mappers with PRG/CHR banking,
;; mirroring control, and scanline counter IRQ.
;;
;; Hardware:
;; - PRG ROM: Up to 512KB, banked in 8KB units
;; - CHR ROM/RAM: Up to 256KB, banked in 1KB or 2KB units
;; - PRG RAM: 8KB at $6000-$7FFF (optionally battery-backed)
;; - Scanline counter: Generates IRQ after N scanlines
;;
;; Bank Select ($8000-$9FFE even):
;;   Bits 0-2: Target register (R0-R7)
;;   Bit 6: PRG ROM bank mode (0: $8000 swappable, 1: $C000 swappable)
;;   Bit 7: CHR ROM bank mode (0: 2KB at $0000, 1: 2KB at $1000)
;;
;; Bank Data ($8001-$9FFF odd):
;;   Value written goes to the register selected by Bank Select
;;
;; Mirroring ($A000-$BFFE even):
;;   Bit 0: 0 = vertical, 1 = horizontal
;;
;; PRG RAM Protect ($A001-$BFFF odd):
;;   Bit 6: Chip enable (0 = disable PRG RAM)
;;   Bit 7: Write protect (1 = write protect PRG RAM)
;;
;; IRQ Latch ($C000-$DFFE even):
;;   Value to reload into counter
;;
;; IRQ Reload ($C001-$DFFF odd):
;;   Any write triggers counter reload on next rising A12 edge
;;
;; IRQ Disable ($E000-$FFFE even):
;;   Disables IRQ and acknowledges pending IRQ
;;
;; IRQ Enable ($E001-$FFFF odd):
;;   Enables IRQ
;;
;; Scanline Counter:
;; The counter decrements on each rising edge of PPU A12 (typically once per
;; scanline when rendering BG or sprites from pattern table at $1000).
;; When counter reaches 0 and IRQ is enabled, IRQ is asserted.
;;
;; Games: Super Mario Bros. 2/3, Kirby's Adventure, Mega Man 3-6, etc.
;;
;; Reference: https://www.nesdev.org/wiki/MMC3

(provide
 make-mmc3-mapper)

(require "mapper.rkt"
         "../../cart/ines.rkt"
         "../../lib/bits.rkt")

;; ============================================================================
;; MMC3 Mapper Implementation
;; ============================================================================

(define (make-mmc3-mapper rom)
  (define prg-rom (rom-prg-rom rom))
  (define chr-data (rom-chr-rom rom))
  (define prg-size (bytes-length prg-rom))
  (define chr-size (bytes-length chr-data))

  ;; Determine if we have CHR RAM
  (define chr-is-ram? (zero? chr-size))

  ;; CHR ROM/RAM (up to 256KB ROM, or 8KB RAM if no CHR ROM)
  (define chr
    (if chr-is-ram?
        (make-bytes #x2000 0)   ; 8KB CHR RAM
        chr-data))

  (define actual-chr-size (bytes-length chr))

  ;; PRG RAM (8KB)
  (define prg-ram (make-bytes #x2000 0))

  ;; Number of 8KB PRG banks and 1KB CHR banks
  (define num-prg-banks (quotient prg-size #x2000))
  (define num-chr-banks (if chr-is-ram? 8 (quotient actual-chr-size #x400)))

  ;; Bank registers R0-R7 (selected via $8000)
  ;; R0, R1: 2KB CHR banks (low bit ignored in CHR mode)
  ;; R2-R5: 1KB CHR banks
  ;; R6, R7: 8KB PRG banks
  (define bank-regs (make-vector 8 0))

  ;; Bank select register ($8000)
  (define bank-select-box (box 0))

  ;; PRG/CHR bank modes (from bank select)
  ;; PRG mode: bit 6 - 0 = $8000 swappable, 1 = $C000 swappable
  ;; CHR mode: bit 7 - 0 = 2KB at $0000, 1 = 2KB at $1000
  (define (prg-mode) (if (bit? (unbox bank-select-box) 6) 1 0))
  (define (chr-mode) (if (bit? (unbox bank-select-box) 7) 1 0))

  ;; Mirroring (0 = vertical, 1 = horizontal)
  (define mirroring-box (box 0))

  ;; PRG RAM enable/write protect
  (define prg-ram-enabled-box (box #t))
  (define prg-ram-write-protect-box (box #f))

  ;; IRQ counter and control
  (define irq-latch-box (box 0))      ; Reload value
  (define irq-counter-box (box 0))    ; Current counter
  (define irq-reload-box (box #f))    ; Reload flag (set by write to $C001)
  (define irq-enabled-box (box #f))   ; IRQ enabled flag
  (define irq-pending-box (box #f))   ; IRQ pending (asserted)

  ;; A12 state tracking for scanline counter
  ;; The counter clocks on rising edge of A12 (low -> high)
  (define a12-state-box (box #f))     ; Previous A12 state
  ;; Filter: A12 must be low for several cycles before a rising edge counts
  ;; This prevents false clocks from rapid A12 toggling
  (define a12-low-cycles-box (box 0))
  (define A12-FILTER-CYCLES 8)        ; Typical filter delay

  ;; --- Helper: Get PRG bank number for an 8KB slot ---
  ;; slot 0: $8000-$9FFF
  ;; slot 1: $A000-$BFFF
  ;; slot 2: $C000-$DFFF
  ;; slot 3: $E000-$FFFF (always last bank)
  (define (prg-bank-for-slot slot)
    (define last-bank (- num-prg-banks 1))
    (define second-last (- num-prg-banks 2))
    (case (prg-mode)
      [(0)
       ;; Mode 0: R6 at $8000, R7 at $A000, second-last at $C000, last at $E000
       (case slot
         [(0) (modulo (vector-ref bank-regs 6) num-prg-banks)]
         [(1) (modulo (vector-ref bank-regs 7) num-prg-banks)]
         [(2) second-last]
         [(3) last-bank])]
      [(1)
       ;; Mode 1: second-last at $8000, R7 at $A000, R6 at $C000, last at $E000
       (case slot
         [(0) second-last]
         [(1) (modulo (vector-ref bank-regs 7) num-prg-banks)]
         [(2) (modulo (vector-ref bank-regs 6) num-prg-banks)]
         [(3) last-bank])]))

  ;; --- Helper: Calculate PRG ROM offset ---
  (define (prg-offset addr)
    (define slot (quotient (- addr #x8000) #x2000))
    (define bank (prg-bank-for-slot slot))
    (+ (* bank #x2000) (bitwise-and addr #x1FFF)))

  ;; --- Helper: Get CHR bank number for a 1KB slot ---
  ;; 8 slots of 1KB each for $0000-$1FFF
  (define (chr-bank-for-slot slot)
    (case (chr-mode)
      [(0)
       ;; Mode 0: R0 (2KB) at $0000, R1 (2KB) at $0800,
       ;;         R2-R5 (1KB each) at $1000-$1C00
       (case slot
         [(0 1) (+ (bitwise-and (vector-ref bank-regs 0) #xFE) (bitwise-and slot 1))]
         [(2 3) (+ (bitwise-and (vector-ref bank-regs 1) #xFE) (bitwise-and slot 1))]
         [(4) (vector-ref bank-regs 2)]
         [(5) (vector-ref bank-regs 3)]
         [(6) (vector-ref bank-regs 4)]
         [(7) (vector-ref bank-regs 5)])]
      [(1)
       ;; Mode 1: R2-R5 (1KB each) at $0000-$0C00,
       ;;         R0 (2KB) at $1000, R1 (2KB) at $1800
       (case slot
         [(0) (vector-ref bank-regs 2)]
         [(1) (vector-ref bank-regs 3)]
         [(2) (vector-ref bank-regs 4)]
         [(3) (vector-ref bank-regs 5)]
         [(4 5) (+ (bitwise-and (vector-ref bank-regs 0) #xFE) (bitwise-and slot 1))]
         [(6 7) (+ (bitwise-and (vector-ref bank-regs 1) #xFE) (bitwise-and slot 1))])]))

  ;; --- Helper: Calculate CHR offset ---
  (define (chr-offset addr)
    (define slot (quotient addr #x400))
    (define bank (modulo (chr-bank-for-slot slot) num-chr-banks))
    (+ (* bank #x400) (bitwise-and addr #x3FF)))

  ;; --- IRQ counter clock (called on A12 rising edge) ---
  (define (clock-irq-counter!)
    (cond
      [(or (unbox irq-reload-box) (zero? (unbox irq-counter-box)))
       ;; Reload counter from latch
       (set-box! irq-counter-box (unbox irq-latch-box))
       (set-box! irq-reload-box #f)]
      [else
       ;; Decrement counter
       (set-box! irq-counter-box (- (unbox irq-counter-box) 1))])

    ;; When counter reaches 0 and IRQ enabled, assert IRQ
    (when (and (zero? (unbox irq-counter-box))
               (unbox irq-enabled-box))
      (set-box! irq-pending-box #t)))

  ;; --- A12 edge detection (called on PPU address access) ---
  ;; Note: In a real implementation, this would be called on every PPU read/write
  ;; For simplicity, we use the scanline-tick! callback instead
  (define (update-a12! addr)
    (define new-a12 (bit? addr 12))
    (define old-a12 (unbox a12-state-box))

    (cond
      [new-a12
       ;; A12 is high
       (when (and (not old-a12)
                  (>= (unbox a12-low-cycles-box) A12-FILTER-CYCLES))
         ;; Rising edge after sufficient low time - clock the counter
         (clock-irq-counter!))
       (set-box! a12-low-cycles-box 0)]
      [else
       ;; A12 is low - increment low cycle counter (capped)
       (set-box! a12-low-cycles-box
                 (min (+ 1 (unbox a12-low-cycles-box)) (+ A12-FILTER-CYCLES 1)))])

    (set-box! a12-state-box new-a12))

  ;; --- Scanline tick (called by PPU at cycle 260 of visible scanlines) ---
  ;; This is a simplified approach - real MMC3 tracks A12 edges
  ;; We directly clock the counter once per scanline, which is accurate for
  ;; games using the standard 8x8 or 8x16 sprite pattern with sprites at $1000
  (define (scanline-tick!)
    ;; Directly clock the IRQ counter (simplified approach)
    (clock-irq-counter!))

  ;; --- CPU Read ($4020-$FFFF) ---
  (define (cpu-read addr)
    (cond
      ;; $6000-$7FFF: PRG RAM
      [(and (>= addr #x6000) (<= addr #x7FFF))
       (if (unbox prg-ram-enabled-box)
           (bytes-ref prg-ram (- addr #x6000))
           #x00)]  ; Open bus when disabled

      ;; $8000-$FFFF: PRG ROM
      [(>= addr #x8000)
       (bytes-ref prg-rom (prg-offset addr))]

      ;; $4020-$5FFF: Expansion (not used)
      [else #x00]))

  ;; --- CPU Write ($4020-$FFFF) ---
  (define (cpu-write addr val)
    (cond
      ;; $6000-$7FFF: PRG RAM
      [(and (>= addr #x6000) (<= addr #x7FFF))
       (when (and (unbox prg-ram-enabled-box)
                  (not (unbox prg-ram-write-protect-box)))
         (bytes-set! prg-ram (- addr #x6000) val))]

      ;; $8000-$FFFF: Mapper registers
      [(>= addr #x8000)
       (define even? (not (bit? addr 0)))
       (cond
         ;; $8000-$9FFF: Bank select/data
         [(< addr #xA000)
          (if even?
              ;; $8000: Bank select
              (set-box! bank-select-box val)
              ;; $8001: Bank data
              (let ([reg (bitwise-and (unbox bank-select-box) 7)])
                (vector-set! bank-regs reg val)))]

         ;; $A000-$BFFF: Mirroring/PRG RAM protect
         [(< addr #xC000)
          (if even?
              ;; $A000: Mirroring
              (set-box! mirroring-box (bitwise-and val 1))
              ;; $A001: PRG RAM protect
              (begin
                (set-box! prg-ram-enabled-box (bit? val 7))
                (set-box! prg-ram-write-protect-box (bit? val 6))))]

         ;; $C000-$DFFF: IRQ latch/reload
         [(< addr #xE000)
          (if even?
              ;; $C000: IRQ latch
              (set-box! irq-latch-box val)
              ;; $C001: IRQ reload
              (set-box! irq-reload-box #t))]

         ;; $E000-$FFFF: IRQ disable/enable
         [else
          (if even?
              ;; $E000: IRQ disable (and acknowledge)
              (begin
                (set-box! irq-enabled-box #f)
                (set-box! irq-pending-box #f))
              ;; $E001: IRQ enable
              (set-box! irq-enabled-box #t))])]))

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
      ;; Use same banking logic as reads for consistency
      (define offset (chr-offset addr))
      (when (< offset actual-chr-size)
        (bytes-set! chr offset val))))

  ;; --- Mirroring ---
  (define (get-mirroring)
    (if (zero? (unbox mirroring-box))
        mirroring-vertical
        mirroring-horizontal))

  ;; --- IRQ interface ---
  (define (irq-pending?)
    (unbox irq-pending-box))

  (define (irq-acknowledge!)
    (set-box! irq-pending-box #f))

  ;; --- Serialization ---
  (define (serialize)
    (bytes-append
     ;; Bank select register (1 byte)
     (bytes (unbox bank-select-box))
     ;; Bank registers (8 bytes)
     (apply bytes (for/list ([i (in-range 8)]) (vector-ref bank-regs i)))
     ;; Mirroring (1 byte)
     (bytes (unbox mirroring-box))
     ;; PRG RAM flags (1 byte: bit 0 = enabled, bit 1 = write protect)
     (bytes (bitwise-ior (if (unbox prg-ram-enabled-box) 1 0)
                         (if (unbox prg-ram-write-protect-box) 2 0)))
     ;; IRQ state (4 bytes)
     (bytes (unbox irq-latch-box)
            (unbox irq-counter-box)
            (bitwise-ior (if (unbox irq-reload-box) 1 0)
                         (if (unbox irq-enabled-box) 2 0)
                         (if (unbox irq-pending-box) 4 0))
            (if (unbox a12-state-box) 1 0))
     ;; PRG RAM (8KB)
     prg-ram
     ;; CHR RAM if applicable
     (if chr-is-ram? chr #"")))

  (define (deserialize! data)
    (set-box! bank-select-box (bytes-ref data 0))
    (for ([i (in-range 8)])
      (vector-set! bank-regs i (bytes-ref data (+ 1 i))))
    (set-box! mirroring-box (bytes-ref data 9))
    (define prg-flags (bytes-ref data 10))
    (set-box! prg-ram-enabled-box (bit? prg-flags 0))
    (set-box! prg-ram-write-protect-box (bit? prg-flags 1))
    (set-box! irq-latch-box (bytes-ref data 11))
    (set-box! irq-counter-box (bytes-ref data 12))
    (define irq-flags (bytes-ref data 13))
    (set-box! irq-reload-box (bit? irq-flags 0))
    (set-box! irq-enabled-box (bit? irq-flags 1))
    (set-box! irq-pending-box (bit? irq-flags 2))
    (set-box! a12-state-box (bit? (bytes-ref data 14) 0))
    (bytes-copy! prg-ram 0 data 15 (+ 15 #x2000))
    (when chr-is-ram?
      (bytes-copy! chr 0 data (+ 15 #x2000) (+ 15 #x2000 #x2000))))

  ;; Create and return the mapper
  (make-mapper
   #:number 4
   #:name "MMC3"
   #:cpu-read cpu-read
   #:cpu-write cpu-write
   #:ppu-read ppu-read
   #:ppu-write ppu-write
   #:get-mirroring get-mirroring
   #:irq-pending? irq-pending?
   #:irq-acknowledge! irq-acknowledge!
   #:scanline-tick! scanline-tick!
   #:serialize serialize
   #:deserialize! deserialize!))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit
           "../../lib/bits.rkt")

  ;; Create a fake iNES ROM for testing MMC3
  (define (make-test-rom-bytes #:prg-banks [prg-banks 4]
                               #:chr-banks [chr-banks 0])
    ;; iNES header
    (define header (make-bytes 16 0))
    (bytes-set! header 0 (char->integer #\N))
    (bytes-set! header 1 (char->integer #\E))
    (bytes-set! header 2 (char->integer #\S))
    (bytes-set! header 3 #x1A)
    (bytes-set! header 4 prg-banks)  ; PRG ROM in 16KB units
    (bytes-set! header 5 chr-banks)  ; CHR ROM in 8KB units
    (bytes-set! header 6 #x40)       ; Mapper 4 low nibble
    (bytes-set! header 7 #x00)       ; Mapper high nibble

    ;; Create PRG ROM - each 8KB bank's first byte is its bank number
    (define prg-size (* prg-banks #x4000))
    (define num-8k-banks (* prg-banks 2))
    (define prg (make-bytes prg-size))
    (for ([bank (in-range num-8k-banks)])
      (define offset (* bank #x2000))
      (bytes-set! prg offset (u8 bank)))

    ;; Create CHR ROM if specified
    (define chr-size (* chr-banks #x2000))
    (define chr
      (if (> chr-banks 0)
          (let ([c (make-bytes chr-size)])
            (for ([bank (in-range (* chr-banks 8))])  ; 1KB banks
              (define offset (* bank #x400))
              (bytes-set! c offset (u8 bank)))
            c)
          #""))

    (bytes-append header prg chr))

  (define (make-test-mapper #:prg-banks [prg-banks 4]
                            #:chr-banks [chr-banks 0])
    (define rom-bytes (make-test-rom-bytes #:prg-banks prg-banks
                                           #:chr-banks chr-banks))
    (define r (parse-rom rom-bytes))
    (make-mmc3-mapper r))

  (test-case "initial state - PRG banking"
    (define m (make-test-mapper #:prg-banks 4))  ; 8 x 8KB banks

    ;; Default bank select = 0, PRG mode 0
    ;; Mode 0: R6 at $8000, R7 at $A000, second-last at $C000, last at $E000
    ;; R6 and R7 are initially 0

    ;; $8000 = R6 = 0
    (check-equal? ((mapper-cpu-read m) #x8000) 0)
    ;; $A000 = R7 = 0
    (check-equal? ((mapper-cpu-read m) #xA000) 0)
    ;; $C000 = second-last = 6
    (check-equal? ((mapper-cpu-read m) #xC000) 6)
    ;; $E000 = last = 7
    (check-equal? ((mapper-cpu-read m) #xE000) 7))

  (test-case "PRG banking mode 0"
    (define m (make-test-mapper #:prg-banks 4))

    ;; Select R6 (PRG bank at $8000 or $C000)
    ((mapper-cpu-write m) #x8000 6)
    ;; Write bank 3
    ((mapper-cpu-write m) #x8001 3)

    (check-equal? ((mapper-cpu-read m) #x8000) 3)

    ;; Select R7 (PRG bank at $A000)
    ((mapper-cpu-write m) #x8000 7)
    ((mapper-cpu-write m) #x8001 2)

    (check-equal? ((mapper-cpu-read m) #xA000) 2))

  (test-case "PRG banking mode 1"
    (define m (make-test-mapper #:prg-banks 4))

    ;; Set PRG mode 1 (bit 6 = 1)
    ((mapper-cpu-write m) #x8000 #x46)  ; Select R6, PRG mode 1
    ((mapper-cpu-write m) #x8001 3)     ; Bank 3

    ;; Mode 1: second-last at $8000, R7 at $A000, R6 at $C000, last at $E000
    (check-equal? ((mapper-cpu-read m) #x8000) 6)   ; second-last
    (check-equal? ((mapper-cpu-read m) #xC000) 3))  ; R6

  (test-case "mirroring control"
    (define m (make-test-mapper))

    ;; Default is vertical (mirroring reg = 0)
    (check-equal? ((mapper-get-mirroring m)) mirroring-vertical)

    ;; Set horizontal (bit 0 = 1)
    ((mapper-cpu-write m) #xA000 1)
    (check-equal? ((mapper-get-mirroring m)) mirroring-horizontal)

    ;; Set vertical
    ((mapper-cpu-write m) #xA000 0)
    (check-equal? ((mapper-get-mirroring m)) mirroring-vertical))

  (test-case "IRQ counter"
    (define m (make-test-mapper))

    ;; Initially no IRQ
    (check-false ((mapper-irq-pending? m)))

    ;; Set latch to 3
    ((mapper-cpu-write m) #xC000 3)

    ;; Trigger reload
    ((mapper-cpu-write m) #xC001 0)

    ;; Enable IRQ
    ((mapper-cpu-write m) #xE001 0)

    ;; Tick scanlines
    ((mapper-scanline-tick! m))  ; Load 3
    (check-false ((mapper-irq-pending? m)))

    ((mapper-scanline-tick! m))  ; 3 -> 2
    (check-false ((mapper-irq-pending? m)))

    ((mapper-scanline-tick! m))  ; 2 -> 1
    (check-false ((mapper-irq-pending? m)))

    ((mapper-scanline-tick! m))  ; 1 -> 0, IRQ fires
    (check-true ((mapper-irq-pending? m)))

    ;; Acknowledge
    ((mapper-irq-acknowledge! m))
    (check-false ((mapper-irq-pending? m))))

  (test-case "IRQ disable clears pending"
    (define m (make-test-mapper))

    ;; Set up to trigger IRQ
    ((mapper-cpu-write m) #xC000 1)   ; Latch = 1
    ((mapper-cpu-write m) #xC001 0)   ; Reload
    ((mapper-cpu-write m) #xE001 0)   ; Enable

    ((mapper-scanline-tick! m))       ; Load 1
    ((mapper-scanline-tick! m))       ; 1 -> 0, IRQ fires
    (check-true ((mapper-irq-pending? m)))

    ;; Disable IRQ (also acknowledges)
    ((mapper-cpu-write m) #xE000 0)
    (check-false ((mapper-irq-pending? m))))

  (test-case "PRG RAM read/write"
    (define m (make-test-mapper))

    ;; Write to PRG RAM
    ((mapper-cpu-write m) #x6000 #x42)
    (check-equal? ((mapper-cpu-read m) #x6000) #x42)

    ((mapper-cpu-write m) #x7FFF #xAB)
    (check-equal? ((mapper-cpu-read m) #x7FFF) #xAB))

  (test-case "CHR RAM read/write"
    (define m (make-test-mapper #:chr-banks 0))

    ((mapper-ppu-write m) #x0000 #x12)
    (check-equal? ((mapper-ppu-read m) #x0000) #x12)

    ((mapper-ppu-write m) #x1FFF #x34)
    (check-equal? ((mapper-ppu-read m) #x1FFF) #x34)))
