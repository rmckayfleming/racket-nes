#lang info

(define collection "nes")
(define version "0.0.1")

(define deps
  '("base"
    "rackunit-lib"
    "sdl3"))

(define build-deps
  '("rackunit-lib"))

(define pkg-desc "NES emulator in Racket with SDL3 frontend")
(define pkg-authors '(ryan))

;; Test configuration
(define test-omit-paths
  '("test/roms"))
