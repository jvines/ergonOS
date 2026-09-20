;;; early-init.el --- runs before package activation and the first frame -*- lexical-binding: t; -*-

;; Startup GC: one collection instead of fourteen. THE RESTORE HOOK AT THE
;; BOTTOM IS NOT OPTIONAL -- most-positive-fixnum means Emacs stops collecting
;; entirely, so if that hook is ever removed this file becomes a memory leak.
;; `C-c ?' reports the live threshold; a 19-digit number there means the hook
;; never fired.
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.6)

;; The default, stated explicitly so a future package-manager experiment has one
;; obvious switch rather than a mystery.
(setq package-enable-at-startup t)

(setq frame-inhibit-implied-resize t)

;; Debian patches native-comp-async-jobs-number to 1 (upstream default is 0 =
;; half the CPUs), which turns "install ten packages" into ten serial compiles.
;; Homebrew's plain `emacs' formula is built without native compilation, so on
;; a Mac this is correctly a no-op.
(when (and (fboundp 'native-comp-available-p) (native-comp-available-p))
  (setq native-comp-async-jobs-number 0))

;; emacs-startup-hook runs after init.el AND after any --eval on the command
;; line, which is why a --eval probe reports the un-restored value and looks
;; like a bug. Depth 100 so it runs last.
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 32 1024 1024)
                  gc-cons-percentage 0.1))
          100)
