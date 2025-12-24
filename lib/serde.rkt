#lang racket/base

;; Save State Serialization Primitives
;;
;; Provides helpers for serializing and deserializing emulator state
;; to bytes for save states. Uses a simple tagged format for forward
;; compatibility.
;;
;; Format:
;; - Each component writes a tagged section: (tag-symbol . bytes)
;; - Top-level is a list of tagged sections
;; - Version field for compatibility checking

(provide
 ;; Version
 serde-version

 ;; Byte packing
 pack-u8
 pack-u16-le
 pack-u16-be
 unpack-u8
 unpack-u16-le
 unpack-u16-be

 ;; Bytes helpers
 bytes-append*

 ;; State container
 make-state
 state-add!
 state-get
 state-sections
 state->bytes
 bytes->state)

(require "bits.rkt")

;; ============================================================================
;; Version
;; ============================================================================

;; Increment when format changes incompatibly
(define serde-version 1)

;; ============================================================================
;; Byte Packing
;; ============================================================================

;; Pack a u8 into a 1-byte bytes object
(define (pack-u8 n)
  (bytes (u8 n)))

;; Pack a u16 little-endian into a 2-byte bytes object
(define (pack-u16-le n)
  (bytes (lo n) (hi n)))

;; Pack a u16 big-endian into a 2-byte bytes object
(define (pack-u16-be n)
  (bytes (hi n) (lo n)))

;; Unpack a u8 from bytes at offset
(define (unpack-u8 bs [offset 0])
  (bytes-ref bs offset))

;; Unpack a u16 little-endian from bytes at offset
(define (unpack-u16-le bs [offset 0])
  (merge16 (bytes-ref bs offset)
           (bytes-ref bs (+ offset 1))))

;; Unpack a u16 big-endian from bytes at offset
(define (unpack-u16-be bs [offset 0])
  (merge16 (bytes-ref bs (+ offset 1))
           (bytes-ref bs offset)))

;; ============================================================================
;; Bytes Helpers
;; ============================================================================

;; Append multiple byte strings
(define (bytes-append* . bss)
  (apply bytes-append bss))

;; ============================================================================
;; State Container
;; ============================================================================

;; A state is a mutable container of tagged sections
(struct state (sections-box) #:transparent)

;; Create a new empty state container
(define (make-state)
  (state (box '())))

;; Add a section to the state
;; tag: symbol identifying the section (e.g., 'cpu, 'ppu, 'ram)
;; data: bytes containing the serialized data
(define (state-add! s tag data)
  (define sections (unbox (state-sections-box s)))
  (set-box! (state-sections-box s)
            (cons (cons tag data) sections)))

;; Get a section by tag (returns bytes or #f)
(define (state-get s tag)
  (define sections (unbox (state-sections-box s)))
  (define pair (assq tag sections))
  (and pair (cdr pair)))

;; Get all sections as an alist
(define (state-sections s)
  (reverse (unbox (state-sections-box s))))

;; ============================================================================
;; Serialization
;; ============================================================================

;; Serialize state to bytes
;; Format: version (u16-le) + count (u16-le) + sections
;; Each section: tag-length (u8) + tag-bytes + data-length (u32-le) + data
(define (state->bytes s)
  (define sections (state-sections s))
  (define out (open-output-bytes))

  ;; Write version
  (write-bytes (pack-u16-le serde-version) out)

  ;; Write section count
  (write-bytes (pack-u16-le (length sections)) out)

  ;; Write each section
  (for ([section (in-list sections)])
    (define tag (car section))
    (define data (cdr section))
    (define tag-bytes (string->bytes/utf-8 (symbol->string tag)))

    ;; Tag length + tag
    (write-byte (bytes-length tag-bytes) out)
    (write-bytes tag-bytes out)

    ;; Data length (32-bit) + data
    (define len (bytes-length data))
    (write-bytes (bytes (bitwise-and len #xFF)
                        (bitwise-and (arithmetic-shift len -8) #xFF)
                        (bitwise-and (arithmetic-shift len -16) #xFF)
                        (bitwise-and (arithmetic-shift len -24) #xFF))
                 out)
    (write-bytes data out))

  (get-output-bytes out))

;; Deserialize bytes to state
;; Returns #f if version mismatch or malformed
(define (bytes->state bs)
  (define in (open-input-bytes bs))

  ;; Read version
  (define version-bytes (read-bytes 2 in))
  (when (eof-object? version-bytes)
    (error 'bytes->state "unexpected end of data"))
  (define version (unpack-u16-le version-bytes))
  (unless (= version serde-version)
    (error 'bytes->state "version mismatch: got ~a, expected ~a"
           version serde-version))

  ;; Read section count
  (define count-bytes (read-bytes 2 in))
  (define count (unpack-u16-le count-bytes))

  ;; Read sections
  (define s (make-state))
  (for ([_ (in-range count)])
    ;; Tag length + tag
    (define tag-len (read-byte in))
    (define tag-bytes (read-bytes tag-len in))
    (define tag (string->symbol (bytes->string/utf-8 tag-bytes)))

    ;; Data length + data
    (define len-bytes (read-bytes 4 in))
    (define len (+ (bytes-ref len-bytes 0)
                   (arithmetic-shift (bytes-ref len-bytes 1) 8)
                   (arithmetic-shift (bytes-ref len-bytes 2) 16)
                   (arithmetic-shift (bytes-ref len-bytes 3) 24)))
    (define data (read-bytes len in))

    (state-add! s tag data))

  s)

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit)

  (test-case "pack/unpack u8"
    (check-equal? (pack-u8 #x42) #"\x42")
    (check-equal? (unpack-u8 #"\x42") #x42)
    (check-equal? (pack-u8 #x1FF) #"\xFF"))

  (test-case "pack/unpack u16-le"
    (check-equal? (pack-u16-le #x1234) #"\x34\x12")
    (check-equal? (unpack-u16-le #"\x34\x12") #x1234))

  (test-case "pack/unpack u16-be"
    (check-equal? (pack-u16-be #x1234) #"\x12\x34")
    (check-equal? (unpack-u16-be #"\x12\x34") #x1234))

  (test-case "state add and get"
    (define s (make-state))
    (state-add! s 'cpu #"cpu-data")
    (state-add! s 'ppu #"ppu-data")
    (check-equal? (state-get s 'cpu) #"cpu-data")
    (check-equal? (state-get s 'ppu) #"ppu-data")
    (check-false (state-get s 'apu)))

  (test-case "round-trip serialization"
    (define s1 (make-state))
    (state-add! s1 'cpu #"hello")
    (state-add! s1 'ram (make-bytes 256 #xAA))

    (define bs (state->bytes s1))
    (define s2 (bytes->state bs))

    (check-equal? (state-get s2 'cpu) #"hello")
    (check-equal? (state-get s2 'ram) (make-bytes 256 #xAA)))

  (test-case "state sections order preserved"
    (define s (make-state))
    (state-add! s 'a #"1")
    (state-add! s 'b #"2")
    (state-add! s 'c #"3")
    (check-equal? (map car (state-sections s)) '(a b c))))
