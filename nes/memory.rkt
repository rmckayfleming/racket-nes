#lang racket/base

;; NES CPU Memory Map
;;
;; Implements the NES CPU address space with proper mirroring and
;; handler dispatch. This connects the CPU to RAM, PPU registers,
;; APU/IO registers, and cartridge space.
;;
;; Memory Map:
;; $0000-$07FF  2KB Internal RAM
;; $0800-$1FFF  Mirrors of $0000-$07FF
;; $2000-$2007  PPU registers
;; $2008-$3FFF  Mirrors of $2000-$2007
;; $4000-$4017  APU and I/O registers
;; $4018-$401F  APU and I/O functionality (normally disabled)
;; $4020-$FFFF  Cartridge space (PRG ROM, PRG RAM, mapper registers)
;;
;; Reference: https://www.nesdev.org/wiki/CPU_memory_map

(provide
 ;; Memory map creation
 make-nes-memory

 ;; Component accessors
 nes-memory-bus
 nes-memory-ram

 ;; PPU register hooks (to be connected to PPU)
 nes-memory-set-ppu-read!
 nes-memory-set-ppu-write!

 ;; APU/IO register hooks
 nes-memory-set-apu-read!
 nes-memory-set-apu-write!

 ;; Controller hooks
 nes-memory-set-controller-read!
 nes-memory-set-controller-write!

 ;; Cartridge hooks (mapper handles these)
 nes-memory-set-cart-read!
 nes-memory-set-cart-write!

 ;; DMA hook
 nes-memory-set-dma-write!

 ;; Open bus hook
 nes-memory-set-openbus-read!)

(require "../lib/bus.rkt"
         "../lib/bits.rkt")

;; ============================================================================
;; NES Memory Structure
;; ============================================================================

;; Holds the memory subsystem state and hook functions
(struct nes-memory
  (bus
   ram              ; 2KB internal RAM
   ;; PPU register callbacks
   ppu-read-box     ; (addr -> byte)
   ppu-write-box    ; (addr byte -> void)
   ;; APU register callbacks
   apu-read-box     ; (addr -> byte)
   apu-write-box    ; (addr byte -> void)
   ;; Controller callbacks
   ctrl-read-box    ; (port -> byte), port is 0 or 1
   ctrl-write-box   ; (port byte -> void)
   ;; Cartridge callbacks
   cart-read-box    ; (addr -> byte)
   cart-write-box   ; (addr byte -> void)
   ;; DMA callback
   dma-write-box    ; (page -> void), triggers OAM DMA
   ;; Open bus callback
   openbus-read-box) ; (-> byte), returns current CPU open bus value
  #:transparent)

;; ============================================================================
;; Hook Setters
;; ============================================================================

(define (nes-memory-set-ppu-read! mem proc)
  (set-box! (nes-memory-ppu-read-box mem) proc))

(define (nes-memory-set-ppu-write! mem proc)
  (set-box! (nes-memory-ppu-write-box mem) proc))

(define (nes-memory-set-apu-read! mem proc)
  (set-box! (nes-memory-apu-read-box mem) proc))

(define (nes-memory-set-apu-write! mem proc)
  (set-box! (nes-memory-apu-write-box mem) proc))

(define (nes-memory-set-controller-read! mem proc)
  (set-box! (nes-memory-ctrl-read-box mem) proc))

(define (nes-memory-set-controller-write! mem proc)
  (set-box! (nes-memory-ctrl-write-box mem) proc))

(define (nes-memory-set-cart-read! mem proc)
  (set-box! (nes-memory-cart-read-box mem) proc))

(define (nes-memory-set-cart-write! mem proc)
  (set-box! (nes-memory-cart-write-box mem) proc))

(define (nes-memory-set-dma-write! mem proc)
  (set-box! (nes-memory-dma-write-box mem) proc))

(define (nes-memory-set-openbus-read! mem proc)
  (set-box! (nes-memory-openbus-read-box mem) proc))

;; ============================================================================
;; Memory Map Construction
;; ============================================================================

(define (make-nes-memory)
  ;; Create 2KB internal RAM
  (define ram (make-bytes #x800 0))

  ;; Create callback boxes (initially stubbed)
  (define ppu-read-box (box (λ (addr) #x00)))
  (define ppu-write-box (box (λ (addr val) (void))))
  (define apu-read-box (box (λ (addr) #x00)))
  (define apu-write-box (box (λ (addr val) (void))))
  (define ctrl-read-box (box (λ (port) #x00)))
  (define ctrl-write-box (box (λ (port val) (void))))
  (define cart-read-box (box (λ (addr) #x00)))
  (define cart-write-box (box (λ (addr val) (void))))
  (define dma-write-box (box (λ (page) (void))))
  (define openbus-read-box (box (λ () #x00)))

  ;; Create bus
  (define b (make-bus))

  ;; --- Internal RAM $0000-$1FFF (2KB + mirrors) ---
  (bus-add-handler! b
                    #:start #x0000
                    #:end #x1FFF
                    #:read (λ (addr)
                             (bytes-ref ram (bitwise-and addr #x07FF)))
                    #:write (λ (addr val)
                              (bytes-set! ram (bitwise-and addr #x07FF) val))
                    #:name 'internal-ram)

  ;; --- PPU Registers $2000-$3FFF (8 regs + mirrors) ---
  (bus-add-handler! b
                    #:start #x2000
                    #:end #x3FFF
                    #:read (λ (addr)
                             (define reg (bitwise-and addr #x0007))
                             ((unbox ppu-read-box) reg))
                    #:write (λ (addr val)
                              (define reg (bitwise-and addr #x0007))
                              ((unbox ppu-write-box) reg val))
                    #:name 'ppu-regs)

  ;; --- APU and I/O Registers $4000-$4017 ---
  (bus-add-handler! b
                    #:start #x4000
                    #:end #x4017
                    #:read (λ (addr)
                             (cond
                               ;; $4016 - Controller 1
                               [(= addr #x4016)
                                ((unbox ctrl-read-box) 0)]
                               ;; $4017 - Controller 2 (also frame counter for APU)
                               [(= addr #x4017)
                                ((unbox ctrl-read-box) 1)]
                               ;; Other APU registers
                               [else
                                ((unbox apu-read-box) addr)]))
                    #:write (λ (addr val)
                              (cond
                                ;; $4014 - OAM DMA
                                [(= addr #x4014)
                                 ((unbox dma-write-box) val)]
                                ;; $4016 - Controller strobe
                                [(= addr #x4016)
                                 ((unbox ctrl-write-box) 0 val)]
                                ;; Other APU registers
                                [else
                                 ((unbox apu-write-box) addr val)]))
                    #:name 'apu-io)

  ;; --- APU Test Registers $4018-$401F (normally disabled) ---
  ;; These addresses are unmapped and return open bus value
  (bus-add-handler! b
                    #:start #x4018
                    #:end #x401F
                    #:read (λ (addr) ((unbox openbus-read-box)))
                    #:write (λ (addr val) (void))
                    #:name 'apu-test)

  ;; --- Cartridge Space $4020-$FFFF ---
  ;; Mapper can return #f for unmapped regions, in which case we use open bus
  (bus-add-handler! b
                    #:start #x4020
                    #:end #xFFFF
                    #:read (λ (addr)
                             (define v ((unbox cart-read-box) addr))
                             (if v v ((unbox openbus-read-box))))
                    #:write (λ (addr val)
                              ((unbox cart-write-box) addr val))
                    #:name 'cartridge)

  ;; Return the memory structure
  (nes-memory b ram
              ppu-read-box ppu-write-box
              apu-read-box apu-write-box
              ctrl-read-box ctrl-write-box
              cart-read-box cart-write-box
              dma-write-box
              openbus-read-box))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "internal RAM basic read/write"
    (define mem (make-nes-memory))
    (define b (nes-memory-bus mem))

    (bus-write b #x0000 #x42)
    (check-equal? (bus-read b #x0000) #x42)

    (bus-write b #x07FF #xAB)
    (check-equal? (bus-read b #x07FF) #xAB))

  (test-case "internal RAM mirroring"
    (define mem (make-nes-memory))
    (define b (nes-memory-bus mem))

    ;; Write to $0000, read from mirrors
    (bus-write b #x0000 #x12)
    (check-equal? (bus-read b #x0800) #x12)  ; Mirror 1
    (check-equal? (bus-read b #x1000) #x12)  ; Mirror 2
    (check-equal? (bus-read b #x1800) #x12)  ; Mirror 3

    ;; Write to mirror, read from base
    (bus-write b #x0801 #x34)
    (check-equal? (bus-read b #x0001) #x34)

    ;; Edge of RAM
    (bus-write b #x1FFF #xFF)
    (check-equal? (bus-read b #x07FF) #xFF))

  (test-case "PPU register mirroring"
    (define mem (make-nes-memory))
    (define b (nes-memory-bus mem))

    ;; Track which register was accessed
    (define last-reg #f)
    (define last-val #f)

    (nes-memory-set-ppu-read! mem
      (λ (reg)
        (set! last-reg reg)
        (+ reg #x10)))  ; Return reg + $10 for testing

    (nes-memory-set-ppu-write! mem
      (λ (reg val)
        (set! last-reg reg)
        (set! last-val val)))

    ;; Read $2000 -> reg 0
    (check-equal? (bus-read b #x2000) #x10)
    (check-equal? last-reg 0)

    ;; Read $2007 -> reg 7
    (check-equal? (bus-read b #x2007) #x17)
    (check-equal? last-reg 7)

    ;; Read $2008 -> mirrors to reg 0
    (check-equal? (bus-read b #x2008) #x10)
    (check-equal? last-reg 0)

    ;; Read $3FFF -> mirrors to reg 7
    (check-equal? (bus-read b #x3FFF) #x17)
    (check-equal? last-reg 7)

    ;; Write $2001 with value $AB
    (bus-write b #x2001 #xAB)
    (check-equal? last-reg 1)
    (check-equal? last-val #xAB))

  (test-case "controller register access"
    (define mem (make-nes-memory))
    (define b (nes-memory-bus mem))

    (define read-port #f)
    (define write-port #f)
    (define write-val #f)

    (nes-memory-set-controller-read! mem
      (λ (port)
        (set! read-port port)
        (if (= port 0) #x41 #x42)))

    (nes-memory-set-controller-write! mem
      (λ (port val)
        (set! write-port port)
        (set! write-val val)))

    ;; Read controller 1
    (check-equal? (bus-read b #x4016) #x41)
    (check-equal? read-port 0)

    ;; Read controller 2
    (check-equal? (bus-read b #x4017) #x42)
    (check-equal? read-port 1)

    ;; Write controller strobe
    (bus-write b #x4016 #x01)
    (check-equal? write-port 0)
    (check-equal? write-val #x01))

  (test-case "cartridge space access"
    (define mem (make-nes-memory))
    (define b (nes-memory-bus mem))

    (define last-addr #f)
    (define last-val #f)

    (nes-memory-set-cart-read! mem
      (λ (addr)
        (set! last-addr addr)
        #xEA))  ; Return NOP opcode

    (nes-memory-set-cart-write! mem
      (λ (addr val)
        (set! last-addr addr)
        (set! last-val val)))

    ;; Read from PRG ROM area
    (check-equal? (bus-read b #x8000) #xEA)
    (check-equal? last-addr #x8000)

    (check-equal? (bus-read b #xFFFC) #xEA)
    (check-equal? last-addr #xFFFC)

    ;; Write to cartridge space (mapper register)
    (bus-write b #x8000 #x00)
    (check-equal? last-addr #x8000)
    (check-equal? last-val #x00))

  (test-case "full address space coverage"
    (define mem (make-nes-memory))
    (define b (nes-memory-bus mem))

    ;; All addresses should be readable without error
    (for ([addr (in-list '(#x0000 #x0800 #x1FFF
                           #x2000 #x2007 #x3FFF
                           #x4000 #x4015 #x4016 #x4017
                           #x4018 #x401F
                           #x4020 #x6000 #x8000 #xC000 #xFFFF))])
      (check-not-exn (λ () (bus-read b addr))
                     (format "Read from $~a should not error"
                             (number->string addr 16))))))
