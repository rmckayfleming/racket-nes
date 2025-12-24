#lang racket/base

;; OAM DMA
;;
;; Implements the NES OAM DMA transfer triggered by writes to $4014.
;; Writing a value N to $4014 copies 256 bytes from CPU page $NN00-$NNFF
;; to PPU OAM memory.
;;
;; DMA takes 513 or 514 CPU cycles:
;; - 1 cycle for the write to $4014
;; - 1 extra cycle if starting on an odd CPU cycle (alignment)
;; - 512 cycles for the actual transfer (256 reads + 256 writes)
;;
;; During DMA, the CPU is stalled (cannot execute instructions).
;;
;; Reference: https://www.nesdev.org/wiki/PPU_registers#OAM_DMA_.28.244014.29_.3E_write

(provide
 ;; DMA execution
 oam-dma-transfer!

 ;; Cycle calculation
 oam-dma-cycles)

(require "ppu/ppu.rkt"
         "../lib/bits.rkt")

;; ============================================================================
;; DMA Transfer
;; ============================================================================

;; Perform OAM DMA transfer
;; page: The source page number (0-255), address = page << 8
;; cpu-read: Function to read from CPU bus (addr -> byte)
;; ppu: The PPU state to write OAM to
;;
;; Returns the number of bytes transferred (always 256)
(define (oam-dma-transfer! page cpu-read ppu)
  (define base-addr (arithmetic-shift page 8))
  (define oam (ppu-oam ppu))

  ;; Copy 256 bytes from CPU memory to OAM
  (for ([i (in-range 256)])
    (define src-addr (+ base-addr i))
    (define byte (cpu-read src-addr))
    (bytes-set! oam i byte))

  256)

;; ============================================================================
;; Cycle Calculation
;; ============================================================================

;; Calculate the number of CPU cycles consumed by OAM DMA
;; cpu-cycle: Current CPU cycle count (used to determine odd/even alignment)
;;
;; DMA timing:
;; - If starting on an even cycle: 513 cycles
;; - If starting on an odd cycle: 514 cycles (extra alignment cycle)
(define (oam-dma-cycles cpu-cycle)
  (if (odd? cpu-cycle)
      514
      513))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "DMA transfer copies 256 bytes"
    (define ppu (make-ppu))

    ;; Create mock CPU memory with test pattern
    (define cpu-mem (make-bytes #x10000 0))
    (for ([i (in-range 256)])
      (bytes-set! cpu-mem (+ #x0200 i) (u8 (+ i #x40))))

    (define (mock-cpu-read addr)
      (bytes-ref cpu-mem addr))

    ;; Perform DMA from page $02
    (define transferred (oam-dma-transfer! #x02 mock-cpu-read ppu))

    (check-equal? transferred 256)

    ;; Verify OAM contents
    (define oam (ppu-oam ppu))
    (check-equal? (bytes-ref oam 0) #x40)
    (check-equal? (bytes-ref oam 1) #x41)
    (check-equal? (bytes-ref oam 255) #x3F))  ; #x40 + 255 = #x13F, wrapped to #x3F

  (test-case "DMA from zero page"
    (define ppu (make-ppu))

    (define cpu-mem (make-bytes #x10000 0))
    (for ([i (in-range 256)])
      (bytes-set! cpu-mem i (u8 i)))

    (define (mock-cpu-read addr)
      (bytes-ref cpu-mem addr))

    (oam-dma-transfer! #x00 mock-cpu-read ppu)

    (define oam (ppu-oam ppu))
    (check-equal? (bytes-ref oam 0) #x00)
    (check-equal? (bytes-ref oam 127) #x7F)
    (check-equal? (bytes-ref oam 255) #xFF))

  (test-case "DMA cycle count even/odd"
    ;; Even cycle start: 513 cycles
    (check-equal? (oam-dma-cycles 0) 513)
    (check-equal? (oam-dma-cycles 100) 513)

    ;; Odd cycle start: 514 cycles
    (check-equal? (oam-dma-cycles 1) 514)
    (check-equal? (oam-dma-cycles 101) 514)))
