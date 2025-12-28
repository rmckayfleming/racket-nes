#lang racket/base

;; Generic Memory Bus
;;
;; A handler-based memory bus implementation supporting:
;; - Multiple address ranges with read/write handlers
;; - Address mirroring
;; - Default handler for unmapped addresses
;; - Priority-based handler dispatch (first match wins)
;;
;; This is a reusable component for any memory-mapped system.

(provide
 ;; Bus creation
 make-bus
 bus?

 ;; Handler registration
 bus-add-handler!

 ;; Memory access
 bus-read
 bus-write

 ;; Debugging
 bus-handlers
 bus-print-map)

(require "bits.rkt")

;; ============================================================================
;; Data Structures
;; ============================================================================

;; A handler covers an address range and provides read/write functions
;; - start: first address (inclusive)
;; - end: last address (inclusive)
;; - read: (addr -> byte) or #f for write-only
;; - write: (addr byte -> void) or #f for read-only
;; - mirror-size: if set, addresses are mirrored within this size
;;   e.g., 2KB RAM ($0000-$07FF) mirrored 4 times = mirror-size 2048
;; - name: symbolic name for debugging
(struct handler (start end read write mirror-size name) #:transparent)

;; The bus holds a list of handlers, a default handler, and a page table for O(1) lookup
;; page-table: vector of 256 entries, one per 256-byte page
;;             each entry is either #f (unmapped) or a handler
(struct bus (handlers-box default-read default-write page-table) #:transparent)

;; ============================================================================
;; Bus Creation
;; ============================================================================

;; Create a new bus with optional default handlers
;; default-read: called for unmapped read addresses, receives addr
;; default-write: called for unmapped write addresses, receives addr and value
(define (make-bus #:default-read [default-read (λ (addr) #xFF)]
                  #:default-write [default-write (λ (addr val) (void))])
  ;; Page table: 256 entries for 16-bit address space (256 pages of 256 bytes)
  (bus (box '()) default-read default-write (make-vector 256 #f)))

;; ============================================================================
;; Handler Registration
;; ============================================================================

;; Add a handler to the bus
;; Handlers are checked in order added (first match wins)
(define (bus-add-handler! b
                          #:start start
                          #:end end
                          #:read [read #f]
                          #:write [write #f]
                          #:mirror-size [mirror-size #f]
                          #:name [name 'unnamed])
  (define h (handler start end read write mirror-size name))
  (define handlers (unbox (bus-handlers-box b)))
  (set-box! (bus-handlers-box b) (append handlers (list h)))
  ;; Update page table for O(1) lookup
  ;; Only set pages that aren't already mapped (first handler wins)
  (define page-table (bus-page-table b))
  (define start-page (quotient start 256))
  (define end-page (quotient end 256))
  (for ([page (in-range start-page (+ end-page 1))])
    (when (not (vector-ref page-table page))
      (vector-set! page-table page h))))

;; Get list of handlers (for debugging)
(define (bus-handlers b)
  (unbox (bus-handlers-box b)))

;; ============================================================================
;; Memory Access
;; ============================================================================

;; Compute the effective address after mirroring
(define (mirror-addr h addr)
  (if (handler-mirror-size h)
      (+ (handler-start h)
         (modulo (- addr (handler-start h)) (handler-mirror-size h)))
      addr))

;; Read a byte from the bus (O(1) lookup via page table)
(define (bus-read b addr)
  (define page (quotient addr 256))
  (define h (vector-ref (bus-page-table b) page))
  (cond
    [(and h (handler-read h))
     (define effective-addr (mirror-addr h addr))
     ((handler-read h) effective-addr)]
    [h
     ;; Handler exists but no read function - use default
     ((bus-default-read b) addr)]
    [else
     ;; No handler found - use default
     ((bus-default-read b) addr)]))

;; Write a byte to the bus (O(1) lookup via page table)
(define (bus-write b addr val)
  (define page (quotient addr 256))
  (define h (vector-ref (bus-page-table b) page))
  (cond
    [(and h (handler-write h))
     (define effective-addr (mirror-addr h addr))
     ((handler-write h) effective-addr (u8 val))]
    [h
     ;; Handler exists but no write function - use default
     ((bus-default-write b) addr (u8 val))]
    [else
     ;; No handler found - use default
     ((bus-default-write b) addr (u8 val))]))

;; ============================================================================
;; Debugging
;; ============================================================================

;; Print the memory map for debugging
(define (bus-print-map b [port (current-output-port)])
  (define handlers (unbox (bus-handlers-box b)))
  (fprintf port "Memory Map:\n")
  (for ([h (in-list handlers)])
    (fprintf port "  $~a-$~a ~a~a\n"
             (~r (handler-start h) #:base 16 #:min-width 4 #:pad-string "0")
             (~r (handler-end h) #:base 16 #:min-width 4 #:pad-string "0")
             (handler-name h)
             (if (handler-mirror-size h)
                 (format " (mirror ~a)" (handler-mirror-size h))
                 ""))))

(require racket/format)

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "basic read/write"
    (define mem (make-bytes 256 0))
    (define b (make-bus))
    (bus-add-handler! b
                      #:start #x0000
                      #:end #x00FF
                      #:read (λ (addr) (bytes-ref mem addr))
                      #:write (λ (addr val) (bytes-set! mem addr val))
                      #:name 'ram)
    (bus-write b #x42 #xAB)
    (check-equal? (bus-read b #x42) #xAB)
    (check-equal? (bytes-ref mem #x42) #xAB))

  (test-case "mirroring"
    ;; 256 bytes mirrored 4 times across 1KB
    (define mem (make-bytes 256 0))
    (define b (make-bus))
    (bus-add-handler! b
                      #:start #x0000
                      #:end #x03FF
                      #:read (λ (addr) (bytes-ref mem (- addr #x0000)))
                      #:write (λ (addr val) (bytes-set! mem (- addr #x0000) val))
                      #:mirror-size 256
                      #:name 'mirrored-ram)
    ;; Write to base address
    (bus-write b #x0010 #x42)
    ;; Read from all mirrors
    (check-equal? (bus-read b #x0010) #x42)
    (check-equal? (bus-read b #x0110) #x42)
    (check-equal? (bus-read b #x0210) #x42)
    (check-equal? (bus-read b #x0310) #x42))

  (test-case "default handler for unmapped"
    (define b (make-bus #:default-read (λ (addr) #xFF)))
    (check-equal? (bus-read b #x1234) #xFF))

  (test-case "first handler wins (priority)"
    (define b (make-bus))
    (bus-add-handler! b
                      #:start #x0000
                      #:end #x00FF
                      #:read (λ (addr) #xAA)
                      #:name 'first)
    (bus-add-handler! b
                      #:start #x0000
                      #:end #x00FF
                      #:read (λ (addr) #xBB)
                      #:name 'second)
    (check-equal? (bus-read b #x0050) #xAA))

  (test-case "non-overlapping ranges"
    (define b (make-bus))
    (bus-add-handler! b
                      #:start #x0000
                      #:end #x00FF
                      #:read (λ (addr) #xAA)
                      #:name 'low)
    (bus-add-handler! b
                      #:start #x0100
                      #:end #x01FF
                      #:read (λ (addr) #xBB)
                      #:name 'high)
    (check-equal? (bus-read b #x0050) #xAA)
    (check-equal? (bus-read b #x0150) #xBB))

  (test-case "boundary addresses"
    (define b (make-bus #:default-read (λ (addr) #x00)))
    (bus-add-handler! b
                      #:start #x1000
                      #:end #x1FFF
                      #:read (λ (addr) #xFF)
                      #:name 'range)
    ;; Just before range
    (check-equal? (bus-read b #x0FFF) #x00)
    ;; First address in range
    (check-equal? (bus-read b #x1000) #xFF)
    ;; Last address in range
    (check-equal? (bus-read b #x1FFF) #xFF)
    ;; Just after range
    (check-equal? (bus-read b #x2000) #x00))

  (test-case "write-only handler"
    (define written-value #f)
    (define b (make-bus #:default-read (λ (addr) #xFF)))
    (bus-add-handler! b
                      #:start #x2000
                      #:end #x2000
                      #:write (λ (addr val) (set! written-value val))
                      #:name 'write-only)
    (bus-write b #x2000 #x42)
    (check-equal? written-value #x42)
    ;; Read should use default since no read handler
    (check-equal? (bus-read b #x2000) #xFF))

  (test-case "read-only handler"
    (define b (make-bus))
    (bus-add-handler! b
                      #:start #x3000
                      #:end #x3000
                      #:read (λ (addr) #xAB)
                      #:name 'read-only)
    (check-equal? (bus-read b #x3000) #xAB)
    ;; Write should not error (uses default write which is void)
    (bus-write b #x3000 #x99)))
