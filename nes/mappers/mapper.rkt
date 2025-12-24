#lang racket/base

;; Mapper Interface
;;
;; Defines the common interface that all NES mappers must implement.
;; Mappers handle bank switching for PRG ROM/RAM and CHR ROM/RAM,
;; as well as mirroring control and optional IRQ generation.
;;
;; Reference: https://www.nesdev.org/wiki/Mapper

(provide
 ;; Mapper interface
 (struct-out mapper)

 ;; Mapper construction helper
 make-mapper

 ;; Mirroring modes
 mirroring-horizontal
 mirroring-vertical
 mirroring-single-0
 mirroring-single-1
 mirroring-four-screen)

;; ============================================================================
;; Mirroring Modes
;; ============================================================================

;; Nametable mirroring affects how the PPU's $2000-$2FFF address range
;; maps to the 2KB of internal VRAM.
(define mirroring-horizontal 'horizontal)  ; Vertical arrangement (SMB)
(define mirroring-vertical 'vertical)      ; Horizontal arrangement (Ice Climber)
(define mirroring-single-0 'single-0)      ; All nametables point to first
(define mirroring-single-1 'single-1)      ; All nametables point to second
(define mirroring-four-screen 'four-screen) ; 4KB VRAM on cart (rare)

;; ============================================================================
;; Mapper Structure
;; ============================================================================

;; Generic mapper structure with callback functions
(struct mapper
  (;; Identification
   number           ; iNES mapper number
   name             ; Human-readable name

   ;; CPU bus handlers ($4020-$FFFF typically, but $6000-$FFFF for PRG)
   cpu-read         ; (addr -> byte)
   cpu-write        ; (addr byte -> void)

   ;; PPU bus handlers ($0000-$1FFF for CHR)
   ppu-read         ; (addr -> byte)
   ppu-write        ; (addr byte -> void)

   ;; Mirroring
   get-mirroring    ; (-> mirroring-mode)

   ;; IRQ (optional, for mappers like MMC3)
   irq-pending?     ; (-> boolean)
   irq-acknowledge! ; (-> void)
   scanline-tick!   ; (-> void), called once per scanline

   ;; State for save states
   serialize        ; (-> bytes)
   deserialize!)    ; (bytes -> void)
  #:transparent)

;; ============================================================================
;; Mapper Construction Helper
;; ============================================================================

;; Create a mapper with default implementations for optional callbacks
(define (make-mapper #:number number
                     #:name name
                     #:cpu-read cpu-read
                     #:cpu-write cpu-write
                     #:ppu-read ppu-read
                     #:ppu-write ppu-write
                     #:get-mirroring get-mirroring
                     #:irq-pending? [irq-pending? (λ () #f)]
                     #:irq-acknowledge! [irq-acknowledge! void]
                     #:scanline-tick! [scanline-tick! void]
                     #:serialize [serialize (λ () #"")]
                     #:deserialize! [deserialize! void])
  (mapper number name
          cpu-read cpu-write
          ppu-read ppu-write
          get-mirroring
          irq-pending? irq-acknowledge! scanline-tick!
          serialize deserialize!))
