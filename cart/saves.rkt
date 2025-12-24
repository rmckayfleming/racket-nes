#lang racket/base

;; Battery-Backed Save RAM Persistence
;;
;; Handles loading and saving PRG RAM for games with battery backup
;; (e.g., The Legend of Zelda, Final Fantasy).
;;
;; Save file location scheme:
;; - By default, saves are placed next to the ROM file with .sav extension
;; - Optionally, can use a dedicated save directory

(provide
 ;; Save path computation
 rom-save-path
 default-save-directory

 ;; Save/load operations
 load-save-ram
 save-save-ram
 save-ram-exists?)

(require racket/file
         racket/path)

;; ============================================================================
;; Save Path Computation
;; ============================================================================

;; Get the default save directory (platform-specific)
;; Returns #f to indicate "same directory as ROM"
(define (default-save-directory)
  #f)

;; Compute the save file path for a ROM
;; rom-path: path to the ROM file
;; save-dir: optional directory for saves (#f = same as ROM)
(define (rom-save-path rom-path #:save-dir [save-dir #f])
  (define rom-dir (path-only rom-path))
  (define rom-name (path->string (file-name-from-path rom-path)))

  ;; Strip .nes extension and add .sav
  (define base-name
    (cond
      [(regexp-match #rx"(?i:\\.nes)$" rom-name)
       (substring rom-name 0 (- (string-length rom-name) 4))]
      [else rom-name]))

  (define save-name (string-append base-name ".sav"))

  (if save-dir
      (build-path save-dir save-name)
      (build-path (or rom-dir (current-directory)) save-name)))

;; ============================================================================
;; Save/Load Operations
;; ============================================================================

;; Check if a save file exists for a ROM
(define (save-ram-exists? rom-path #:save-dir [save-dir #f])
  (file-exists? (rom-save-path rom-path #:save-dir save-dir)))

;; Load save RAM from disk
;; Returns bytes of the expected size, or fresh zeros if no save exists
;; rom-path: path to the ROM file
;; size: expected size of PRG RAM in bytes
;; save-dir: optional directory for saves
(define (load-save-ram rom-path size #:save-dir [save-dir #f])
  (define save-path (rom-save-path rom-path #:save-dir save-dir))

  (cond
    [(file-exists? save-path)
     (define data (file->bytes save-path))
     ;; Validate size
     (cond
       [(= (bytes-length data) size)
        data]
       [(> (bytes-length data) size)
        ;; Truncate if too large (shouldn't happen normally)
        (subbytes data 0 size)]
       [else
        ;; Pad with zeros if too small (shouldn't happen normally)
        (bytes-append data (make-bytes (- size (bytes-length data)) 0))])]
    [else
     ;; No save file - return fresh RAM
     (make-bytes size 0)]))

;; Save PRG RAM to disk
;; rom-path: path to the ROM file
;; data: bytes to save
;; save-dir: optional directory for saves
(define (save-save-ram rom-path data #:save-dir [save-dir #f])
  (define save-path (rom-save-path rom-path #:save-dir save-dir))

  ;; Ensure parent directory exists
  (define parent (path-only save-path))
  (when (and parent (not (directory-exists? parent)))
    (make-directory* parent))

  ;; Write the save file
  (call-with-output-file save-path
    (λ (out) (write-bytes data out))
    #:exists 'replace))

;; ============================================================================
;; Module Tests
;; ============================================================================

(module+ test
  (require rackunit
           racket/file)

  (test-case "rom-save-path computation"
    (check-equal?
     (path->string (file-name-from-path (rom-save-path "/games/zelda.nes")))
     "zelda.sav")
    (check-equal?
     (path->string (file-name-from-path (rom-save-path "/games/ZELDA.NES")))
     "ZELDA.sav")
    (check-equal?
     (path->string (file-name-from-path (rom-save-path "/games/no-ext")))
     "no-ext.sav"))

  (test-case "save and load round-trip"
    (define test-dir (make-temporary-file "saves~a" 'directory))
    (define fake-rom-path (build-path test-dir "test.nes"))

    ;; Create a fake ROM file so path computation works
    (call-with-output-file fake-rom-path
      (λ (out) (write-bytes #"NES\x1a" out)))

    ;; Save some data
    (define test-data (bytes 1 2 3 4 5 6 7 8))
    (save-save-ram fake-rom-path test-data)

    ;; Check it exists
    (check-true (save-ram-exists? fake-rom-path))

    ;; Load it back
    (define loaded (load-save-ram fake-rom-path 8))
    (check-equal? loaded test-data)

    ;; Cleanup
    (delete-directory/files test-dir))

  (test-case "load non-existent returns fresh bytes"
    (define test-dir (make-temporary-file "saves~a" 'directory))
    (define fake-rom-path (build-path test-dir "nonexistent.nes"))

    (define loaded (load-save-ram fake-rom-path 1024))
    (check-equal? (bytes-length loaded) 1024)
    (check-equal? loaded (make-bytes 1024 0))

    ;; Cleanup
    (delete-directory/files test-dir)))
