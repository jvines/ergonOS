;;; init.el --- Emacs configuration for Ergon  -*- lexical-binding: t; -*-
;; ---------------------------------------------------------------------------
;; Keep Custom out of this file.
;;
;; ~/.emacs.d/init.el is a SYMLINK into this repo (install.sh links the file,
;; not the directory), so anything `M-x customize' saves is written straight
;; into git. It is not hypothetical: two machines independently grew a
;; byte-identical `(custom-set-variables '(package-selected-packages nil))'
;; block that nobody typed, which left both working trees permanently dirty --
;; and any sync that refuses to pull over a dirty tree then stops converging,
;; silently.
;;
;; user-emacs-directory is a real directory on every machine, so
;; custom.el lands next to the symlink and outside the repo. emacs/custom.el is
;; gitignored as well, purely as a backstop in case install.sh is ever changed
;; to link the whole emacs/ directory.
;; ---------------------------------------------------------------------------
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))

(global-font-lock-mode 1)

;; ---------------------------------------------------------------------------
;; Terminal setup, per frame.
;;
;; Per-frame rather than once, because under `emacsclient' the daemon's first
;; frame has no terminal at all: anything touching terminal capabilities at
;; load time configures a frame that will never be displayed.
;;
;; The four <wheel-up>/<mouse-4> lambdas that used to live here are gone.
;; `mouse-wheel-mode' binds all of them, plus Shift-wheel for horizontal scroll
;; and C-wheel for text-scale; the lambdas overrode all of that and moved point
;; instead of scrolling the window.
;;
;; But "on by default" is only true of a build with a window system. A build
;; configured --without-x is not, and loadup.el only preloads mwheel.el when
;; the build has a window system. So `mouse-wheel-mode' reads t (its autoloaded
;; init value) while the mode body has never run: <wheel-down> is unbound, and
;; xterm-mouse-mode decodes every wheel event perfectly into nothing. Load it
;; and switch it on explicitly.
;;
;; The `xterm--set-selection' parameter is the one that pays off daily. Emacs 30
;; implements OSC 52 clipboard writes for text terminals, but term/tmux.el
;; hardcodes `xterm-tmux-extra-capabilities' to '(modifyOtherKeys) and omits
;; setSelection -- so M-w never reaches the clipboard of the machine you are
;; actually typing on. Setting the parameter by hand turns it on. Do NOT enable
;; the read direction: tmux does not answer OSC 52 queries, so a clipboard read
;; blocks until `xterm-query-timeout' and returns nothing. Paste with the
;; terminal's own paste; bracketed paste is already on.
;; ---------------------------------------------------------------------------
(setq select-enable-clipboard t
      select-enable-primary nil
      xterm-max-cut-length 1000000)

(require 'mwheel)
(mouse-wheel-mode 1)

(defun my/tty-frame-setup (&optional frame)
  "Enable mouse reporting and OSC 52 clipboard writes on a terminal FRAME."
  (when (frame-live-p (or frame (selected-frame)))
    (with-selected-frame (or frame (selected-frame))
      (unless (display-graphic-p)
        (xterm-mouse-mode 1)
        ;; Only xterm-family terminals understand OSC 52; a linux console would
        ;; print the escape verbatim, so keep this narrow.
        (when (string-match-p "\\`\\(xterm\\|tmux\\|screen\\|alacritty\\|foot\\|rxvt\\)"
                              (or (getenv "TERM") ""))
          (set-terminal-parameter nil 'xterm--set-selection t))))))

(my/tty-frame-setup)
(add-hook 'after-make-frame-functions #'my/tty-frame-setup)
(add-hook 'server-after-make-frame-hook #'my/tty-frame-setup)

;; ---------------------------------------------------------------------------
;; Packages.
;;
;; Three changes from the old guarded batch:
;;
;; 1. (package-initialize) is gone. Emacs 27+ runs `package-activate-all'
;;    automatically before this file is read -- but ONLY when package-user-dir
;;    already contains an installed package. On a host with no ~/.emacs.d/elpa
;;    package.el is not loaded here at all, so the (unless ...) below is
;;    load-bearing, not belt-and-braces. Do not delete it as redundant.
;;    Removing the explicit call cut startup 0.35s -> 0.18s, because the old
;;    line order meant reading MELPA's 2.6MB index on every single start.
;;
;; 2. use-package instead of (mapc #'package-install missing). The old form was
;;    unguarded, and an error anywhere in this file aborts EVERY line after it,
;;    including (load custom-file) at the bottom. That is how a machine ends
;;    up with no elpa/ directory and a config that silently stopped two thirds
;;    of the way down. `use-package-ensure-elpa' wraps each
;;    install in condition-case and demotes a failure to a warning, so one bad
;;    archive costs one package rather than the whole file.
;;
;; 3. Archive priorities. Nearly everything here is on GNU/NonGNU ELPA as a
;;    tagged release; MELPA ships a new build most days. Five hosts installing
;;    on different dates plus unprioritised MELPA guarantees version drift.
;;
;; NOTE: `:if' does NOT gate `:ensure' -- :ensure is keyword index 1 and :if is
;; index 8, so an :if-guarded package still downloads everywhere. Wrap the whole
;; form in a `when' when a package must not install on every host. And never
;; byte-compile this file: use-package evaluates :ensure at compile time,
;; bypassing every runtime guard in it.
;; ---------------------------------------------------------------------------
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(setq package-archive-priorities '(("gnu" . 10) ("nongnu" . 5) ("melpa" . 0)))

(unless (bound-and-true-p package--activated)
  (package-activate-all))

(require 'use-package)
(setq use-package-always-ensure t
      use-package-expand-minimally t)

(defun my/first-executable (&rest names)
  "Absolute path of the first of NAMES found on `exec-path', else nil.
Debian calls it fdfind, Homebrew calls it fd.  Ask for the tool, not the OS."
  (seq-some #'executable-find names))

(defvar my/rg (my/first-executable "rg"))

;; ---------------------------------------------------------------------------
;; Session state. All built in, all near-zero cost, and between them most of
;; what "switch documents easily" actually means: recentf is what fills the File
;; source in consult-buffer (without recentf-mode that source is disabled
;; outright, not merely empty), savehist makes most-recent-first ordering
;; survive a restart, save-place puts point back where it was.
;;
;; The /ssh: exclusion is not cosmetic. A recentf entry pointing at a machine
;; that is powered off, asleep or simply unreachable makes Emacs block on a TCP
;; connect at startup -- and under the daemon that hangs every frame in every
;; tmux pane at once.
;;
;; recentf normally only writes on kill-emacs. Every Linux host here runs a
;; 60-second hardware watchdog precisely because they have hung before, and a
;; watchdog reset loses the whole list. Hence the timer.
;; ---------------------------------------------------------------------------
(savehist-mode 1)
(setq savehist-additional-variables
      '(search-ring regexp-search-ring kill-ring compile-history))

(save-place-mode 1)

(recentf-mode 1)
(setq recentf-max-saved-items 500        ; default 20, useless across 11 worktrees
      recentf-exclude '("/tmp/" "/ssh:" "/docker:" "/elpa/" "\\.git/"))
(run-at-time 300 300
             (lambda () (let ((inhibit-message t)) (recentf-save-list))))

;; 50MB ASCII spectra and single-line JSON wedge font-lock, and now tree-sitter
;; too. Off by default; it should not be.
(global-so-long-mode 1)

;; ---------------------------------------------------------------------------
;; project.el + xref. Nothing to install; this is undoing bad defaults.
;;
;; A git worktree resolves to ITSELF rather than to the repository it hangs
;; off: a worktree's .git is a file containing a gitdir: pointer, and
;; project.el shells out to `git ls-files' rather than walking the filesystem,
;; so git resolves the pointer and the distinction never surfaces.
;;
;; Deliberately NOT set: project-vc-extra-root-markers. Adding "Project.toml"
;; fragments every Julia repo -- docs/, benchmark/, sysimage/ and any vendored
;; dependency each become their own root, so C-x p f inside docs/ only sees
;; docs/. Plain git detection is already correct.
;;
;; xref-search-program defaults to `grep'. Measured on a mid-sized repository:
;; grep 428ms vs ripgrep 73ms for the same 4241 hits.
;; ---------------------------------------------------------------------------
(when my/rg
  (setq xref-search-program 'ripgrep))

(setq xref-auto-jump-to-first-definition 'show
      xref-auto-jump-to-first-xref 'show
      ;; Keep multi-candidate results in the minibuffer instead of stealing a
      ;; window. In an 80-column pane with three windows open that matters.
      xref-show-definitions-function #'xref-show-definitions-completing-read)

;; pytest and ruff emit SGR colour; without this *compilation* is a wall of
;; raw ESC[31m.
(add-hook 'compilation-filter-hook #'ansi-color-compilation-filter)
(setq compilation-scroll-output 'first-error)

;; ---------------------------------------------------------------------------
;; Tree-sitter. Zero packages: treesit, ABI 14 and python-ts-mode are already in
;; this build. The only missing piece is a compiled grammar, and cc + git are
;; enough to build one (cmake and libtool are NOT needed and are absent here --
;; treesit compiles the pre-generated src/parser.c, it never runs the CLI).
;;
;; THE PIN IS THE WHOLE POINT. libtree-sitter here is 0.22.6, whose maximum
;; grammar ABI is 14. tree-sitter-python's default branch is generated at ABI 15
;; now: it clones, compiles without a single warning, and then refuses to load,
;; which reads exactly like a broken toolchain. v0.23.6 is the last ABI-14
;; python tag; v0.23.1 is the last for julia.
;;
;; Grammars land in ~/.emacs.d/tree-sitter/, outside the repo, so they are
;; per-machine: run M-x my/treesit-install-missing once per host. Everything
;; here degrades to plain python-mode when the grammar is absent, so a host that
;; has not been done yet is merely unimproved, not broken.
;; ---------------------------------------------------------------------------
(when (and (fboundp 'treesit-available-p) (treesit-available-p))
  (require 'treesit nil t)
  (setq treesit-font-lock-level 4)
  (add-to-list 'treesit-language-source-alist
               '(python "https://github.com/tree-sitter/tree-sitter-python" "v0.23.6"))
  (add-to-list 'treesit-language-source-alist
               '(julia "https://github.com/tree-sitter/tree-sitter-julia" "v0.23.1")))

;; Emacs 31 added `treesit-auto-install-grammar', defaulting to `ask' -- which
;; blocks on a prompt under --batch, --daemon and CI. boundp is nil on 30.1, so
;; this is inert until a host is upgraded. Grammar installation stays explicit,
;; via M-x my/treesit-install-missing.
(when (boundp 'treesit-auto-install-grammar)
  (setq treesit-auto-install-grammar nil))

(defun my/treesit-install-missing ()
  "Build every grammar in `treesit-language-source-alist' this host lacks.
Run once per machine, then restart.  Output goes to ~/.emacs.d/tree-sitter/."
  (interactive)
  (dolist (src treesit-language-source-alist)
    (let ((lang (car src)))
      (unless (treesit-language-available-p lang)
        (message "treesit: building %s..." lang)
        (treesit-install-language-grammar lang)))))

(defun my/treesit-remap (lang from to)
  "Remap major mode FROM to TO, but only if LANG's grammar loads and TO exists.
python.el's own auto-mode-alist entry for python-ts-mode lives inside the
python-ts-mode body, so it can never bootstrap itself, and Emacs 30 ships
nothing for python in `major-mode-remap-defaults'.  major-mode-remap-alist
rather than auto-mode-alist because python-ts-mode declares python-mode as its
parent, so derived-mode-p and python-base-mode-hook keep working either way."
  (when (and (fboundp 'treesit-ready-p)
             (treesit-ready-p lang t)
             (fboundp to))
    (add-to-list 'major-mode-remap-alist (cons from to))))

(my/treesit-remap 'python 'python-mode 'python-ts-mode)

;; ---------------------------------------------------------------------------
;; dired -- the file tree, without a sidebar.
;;
;; C-x C-j / C-x 4 C-j are already bound in stock Emacs 30 (dired-jump moved
;; into dired.el; it is not a dired-x thing any more). dired-omit-mode still is,
;; and is NOT autoloaded, hence the require.
;;
;; --group-directories-first and -v are GNU coreutils only. BSD ls -- macOS,
;; the BSDs -- rejects them and the dired buffer comes up EMPTY. This is the
;; single most likely way a dired config breaks off Linux.
;; ---------------------------------------------------------------------------
(setq dired-listing-switches
      (if (or (not (eq system-type 'darwin)) (executable-find "gls"))
          "-alhv --group-directories-first"
        "-alh")
      dired-kill-when-opening-new-dired-buffer t
      dired-dwim-target t
      dired-auto-revert-buffer #'dired-directory-changed-p
      dired-do-revert-buffer t
      dired-recursive-copies 'always
      dired-recursive-deletes 'top)

(when (and (eq system-type 'darwin) (executable-find "gls"))
  (setq insert-directory-program (executable-find "gls")))

(add-hook 'dired-mode-hook #'dired-hide-details-mode)

(with-eval-after-load 'dired
  (require 'dired-x)
  ;; Spelled out in full rather than concat'ed onto the default, so
  ;; re-evaluating this file does not append the same patterns twice.
  (setq dired-omit-verbose nil
        dired-omit-files
        (concat "\\`[.]?#\\|\\`[.][.]?\\'"
                "\\|\\`__pycache__\\'"
                "\\|\\`\\.\\(mypy\\|ruff\\|pytest\\)_cache\\'"
                "\\|\\`\\.\\(ipynb_checkpoints\\|venv\\|direnv\\)\\'"
                "\\|\\.pyc\\'"))
  ;; M-o is free in dired-mode-map; `.' is dired-clean-directory, worth keeping.
  (keymap-set dired-mode-map "M-o" #'dired-omit-mode))

;; TAB expands a directory inline. C-TAB cannot be encoded in a TTY at all, so
;; the cycle command goes on <backtab> (S-TAB sends CSI Z, which does arrive).
(use-package dired-subtree
  :after dired
  :bind (:map dired-mode-map
              ("TAB"       . dired-subtree-toggle)
              ("<backtab>" . dired-subtree-cycle)
              ("M-n"       . dired-subtree-next-sibling)
              ("M-p"       . dired-subtree-previous-sibling)
              ("M-u"       . dired-subtree-up))
  :custom
  ;; The depth faces hardcode dark hex backgrounds (#252e30 ...) which quantise
  ;; to mud at 256 colours and are simply wrong on a light theme.
  (dired-subtree-use-backgrounds nil))

;; Font-locks permissions/owner/size/date/type separately. One hook, no
;; dependencies, the cheapest legibility win available in a dired-heavy setup.
(use-package diredfl
  :hook (dired-mode . diredfl-mode))

;; ---------------------------------------------------------------------------
;; Completion -- switching documents.
;;
;; vertico only *renders* Emacs's native completion, so every prompt in the
;; editor is upgraded at once and there is no command to port: eglot's symbol
;; prompts, project.el, AUCTeX's \cite prompts all improve for free. That is the
;; opposite of ivy/counsel, which replaces the machinery and therefore needs a
;; parallel reimplementation of every command.
;;
;; orderless is the one that changes what matches. Emacs 30's default
;; completion-styles is (basic partial-completion emacs22) -- prefix-anchored,
;; close to useless across eleven wt-* worktrees whose files share names. With
;; it, "ccf keplerian" finds the file.
;;
;; consult adds capability rather than presentation: consult-buffer folds
;; buffers + recentf + project buffers + project files + bookmarks into one
;; narrowable prompt. consult-narrow-key defaults to nil, so narrowing -- the
;; entire reason it beats switch-to-buffer -- is off until set.
;; ---------------------------------------------------------------------------
(use-package vertico
  :init (vertico-mode 1)
  :custom
  (vertico-count 15)
  (vertico-cycle t)
  (vertico-resize nil))

(use-package vertico-directory
  :ensure nil                           ; ships inside the vertico tarball
  :after vertico
  :bind (:map vertico-map
              ("RET"   . vertico-directory-enter)
              ("DEL"   . vertico-directory-delete-char)
              ("M-DEL" . vertico-directory-delete-word))
  :hook (rfn-eshadow-update-overlay . vertico-directory-tidy))

;; With xterm-mouse-mode on, the wheel inside a Vertico minibuffer moves point
;; along the input string, which looks broken. vertico-mouse-mode does NOT fix
;; this -- it hangs its keymap off a text property on the candidate strings, so
;; it only fires while the pointer is physically over the list. Bind the map.
(with-eval-after-load 'vertico
  (keymap-set vertico-map "<wheel-up>"   #'vertico-previous)
  (keymap-set vertico-map "<wheel-down>" #'vertico-next))

(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  ;; completion--styles APPENDS an override to completion-styles rather than
  ;; replacing it, so orderless still applies to file completion; this only puts
  ;; basic/partial-completion first so ~/ and TRAMP path expansion behave.
  (completion-category-overrides '((file (styles basic partial-completion)))))

(use-package consult
  :bind (("C-x b"   . consult-buffer)
         ("C-x p b" . consult-project-buffer)
         ("C-x r b" . consult-bookmark)
         ("M-y"     . consult-yank-pop)
         ("M-g g"   . consult-goto-line)
         ("M-g i"   . consult-imenu)
         ("M-g I"   . consult-imenu-multi)
         ("M-g f"   . consult-flymake)
         ("M-s l"   . consult-line)
         ("M-s r"   . consult-ripgrep)
         ("M-s d"   . consult-fd)
         :map minibuffer-local-map
         ("M-r"     . consult-history))
  :custom
  (consult-narrow-key "<")
  :config
  ;; Do NOT set consult-fd-args. Its default already picks Debian's fdfind
  ;; where that is the name and plain fd elsewhere, including Arch; the usual
  ;; Debian advice to hardcode "fdfind" is exactly what breaks it everywhere
  ;; else.
  (consult-customize
   consult-ripgrep consult-fd consult-buffer
   :preview-key '(:debounce 0.3 any)))

(use-package marginalia
  :init (marginalia-mode 1)
  :bind (:map minibuffer-local-map ("M-A" . marginalia-cycle)))

;; ---------------------------------------------------------------------------
;; Project-wide find-and-replace -- "Replace in Files".
;;
;; embark-export on a consult-ripgrep result turns the live search into a real
;; grep buffer; wgrep makes that buffer EDITABLE, and C-c C-c writes every edit
;; back to every file at once. That pair is the refactor an IDE gives you.
;;
;; NOT bound to C-. -- the upstream binding cannot reach Emacs here: tmux's
;; extended-keys defaults to off and C-. has no terminal representation, so it
;; is never transmitted at all.
;; ---------------------------------------------------------------------------
(use-package embark
  :bind (("C-c a" . embark-act)
         ("C-c d" . embark-dwim)
         ("C-h B" . embark-bindings))
  :custom (prefix-help-command #'embark-prefix-help-command))

(use-package embark-consult
  :after (embark consult))

(use-package wgrep
  :defer t
  :custom (wgrep-auto-save-buffer t))

;; ---------------------------------------------------------------------------
;; In-buffer completion popup -- the IDE dropdown.
;;
;; This REPLACES global-completion-preview-mode, which was here before. Running
;; both means two competing UIs proposing candidates for the same prefix.
;;
;; corfu draws in a child frame, and corfu.el:1084 gates the popup on
;;   (or (display-graphic-p) (featurep 'tty-child-frames))
;; -- tty-child-frames is an Emacs 31 feature. On 30.1 in a terminal corfu
;; silently delegates to the default completion-in-region-function: the mode
;; line still says Corfu and nothing corfu-ish ever happens. corfu-terminal is
;; what actually renders it here, via popon (overlay-drawn popups). Its own
;; corfu-terminal-disable-on-gui defaults to t, so this stays correct if you
;; ever open a GUI frame.
;;
;; cape supplies the capfs Emacs lacks. The ordering matters: eglot installs
;; itself at the head of completion-at-point-functions, so file/dabbrev are
;; appended as fallbacks rather than competing with the LSP.
;; ---------------------------------------------------------------------------
(use-package corfu
  :init (global-corfu-mode 1)
  :custom
  (corfu-auto t)                ; pop up without asking -- the IDE behaviour
  (corfu-cycle t)
  (corfu-preselect 'prompt)     ; never silently commit to a candidate
  (corfu-quit-no-match 'separator)
  :bind (:map corfu-map
              ("M-d" . corfu-info-documentation)
              ("M-." . corfu-info-location))
  :config
  ;; corfu-auto-delay and corfu-auto-prefix live in corfu-auto.el, a separate
  ;; module in the same tarball, and corfu.el:1358 only requires it lazily when
  ;; corfu-mode first turns on in a buffer. Setting them via :custom therefore
  ;; assigns symbols that are still void at init time -- it happens to survive,
  ;; because defcustom will not clobber an already-set value, but it is silent
  ;; either way. Require the module and set them outright.
  (require 'corfu-auto)
  (setq corfu-auto-delay 0.2
        corfu-auto-prefix 2)
  ;; Where the selected candidate's docs go. corfu-popupinfo draws a child
  ;; frame (corfu-popupinfo.el:385), which on Emacs 30 does not exist in a TTY
  ;; and has no terminal fallback -- corfu-terminal only overrides
  ;; corfu--popup-show/-hide/-support-p, not popupinfo. Emacs 31 has TTY child
  ;; frames, so there it works in tmux and is strictly better.
  ;; M-d opens the full doc buffer either way.
  (if (featurep 'tty-child-frames)
      (corfu-popupinfo-mode 1)
    (corfu-echo-mode 1)))

;; Emacs 31 renders corfu natively in a TTY (corfu.el:1084 gates on the same
;; feature), and corfu-terminal is then a DOWNGRADE rather than a no-op: its
;; cl-defmethod on corfu--popup-show specialises on (&context corfu-terminal-mode)
;; and wins over the native path, which corfu itself warns about.
;;
;; `unless', never `:if'. use-package emits :ensure OUTSIDE the `when' that :if
;; generates, so an :if-guarded form still downloads corfu-terminal and popon on
;; every Emacs 31 host.
(unless (featurep 'tty-child-frames)
  (use-package corfu-terminal
    :after corfu
    :config (corfu-terminal-mode 1)))

(use-package cape
  :init
  (add-hook 'completion-at-point-functions #'cape-file t)
  (add-hook 'completion-at-point-functions #'cape-dabbrev t))

;; Built in on 30.x, so :ensure is a no-op there and installs from GNU ELPA on
;; 29.x. Here purely as a discovery aid: C-x p and C-x t are 19- and
;; 21-command keymaps that have been sitting unused.
(use-package which-key
  :config (which-key-mode 1))

;; ---------------------------------------------------------------------------
;; magit. With several worktrees hanging off one repository this is also the
;; best cross-worktree switcher available: `Z' opens the worktree
;; transient -- g visit, c branch+worktree in one step, b checkout, m move,
;; k delete. `Z c' is the feature/<CARD>-<slug>-in-a-worktree workflow minus the
;; shell. magit-log-buffer-file answers "why is this line here" in place.
;;
;; If magit ever fails at startup with a void-function transient-define-prefix,
;; it is the stale built-in transient loading first: delete elpa/transient-* and
;; reinstall. And never add transient (or seq, compat, project, eglot,
;; which-key) to a list guarded by `package-installed-p' -- it returns t for
;; built-ins, so the upgrade is silently skipped.
;; ---------------------------------------------------------------------------
(use-package magit
  :bind (("C-c g" . magit-status)
         ("C-c G" . magit-dispatch))
  :custom
  (magit-diff-refine-hunk 'all)
  :config
  ;; project.el looks the key up in project-prefix-map when the entry gives no
  ;; explicit key, so without the keymap-set the menu renders "  Magit" with a
  ;; blank key and nothing can select it.
  (with-eval-after-load 'project
    (keymap-set project-prefix-map "m" #'magit-project-status)
    (add-to-list 'project-switch-commands '(magit-project-status "Magit") t)
    (add-to-list 'project-switch-commands '(project-dired "Dired") t)))

;; ---------------------------------------------------------------------------
;; diff-hl -- per-line change marks in the buffer you are editing.
;;
;; magit already answers "what changed in this repo"; this answers "what did I
;; change on THIS line", live, without leaving the file.
;;
;; diff-hl draws in the FRINGE by default, and a terminal has no fringe -- the
;; mode turns on, reports success and displays nothing at all. diff-hl handles
;; moves it into the margin, which is the only version of this package that does
;; anything in a TTY. It is a global mode, hence the :config call rather than a
;; hook.
;;
;; flydiff updates the marks as you type instead of only after a save.
;; The magit-post-refresh hook is what stops the marks going stale the moment
;; you stage or commit from magit.
;; ---------------------------------------------------------------------------
(use-package diff-hl
  :hook ((prog-mode        . diff-hl-mode)
         (conf-mode        . diff-hl-mode)
         (dired-mode       . diff-hl-dired-mode)
         (magit-post-refresh . diff-hl-magit-post-refresh))
  :config
  ;; No (diff-hl-margin-mode 1) here. It is :global t with no display test,
  ;; while diff-hl itself defaults diff-hl-fallback-to-margin to t and checks
  ;; (not (display-graphic-p)) PER OVERLAY (diff-hl.el:150, :826) -- so the
  ;; margin fallback already happens on its own, per frame, which is the only
  ;; thing that can be correct under a daemon serving GUI and TTY frames at once.
  (diff-hl-flydiff-mode 1)
  ;; C-x v is the built-in vc prefix and already has = (vc-diff) and D
  ;; (vc-root-diff). These add hunk-level movement in the same place.
  (keymap-set vc-prefix-map "n" #'diff-hl-next-hunk)
  (keymap-set vc-prefix-map "p" #'diff-hl-previous-hunk)
  (keymap-set vc-prefix-map "r" #'diff-hl-revert-hunk))

;; Step through a file's history one revision at a time, in place: p/n move back
;; and forward, b blames the revision you are looking at, q restores the buffer.
;; This is the one git view magit does not give you -- magit shows a commit's
;; diff, this shows one FILE evolving.
(use-package git-timemachine
  :bind ("C-c v t" . git-timemachine))

;; ---------------------------------------------------------------------------
;; eglot. Built in; nothing to install on the Emacs side.
;;
;; This is the part tree-sitter cannot do. treesit is single-buffer: it knows
;; where the defuns are in THIS file and nothing else. It cannot resolve
;; `from mypackage.module import thing' to a file, list the call sites of a
;; function across a worktree, or rename project-wide. That is M-. / M-? /
;; eglot-rename, and it needs a server.
;;
;; The guard and the pin are keyed on the SAME binary on purpose: guarding on
;; "any of basedpyright/pyright/pylsp" while pinning to basedpyright means a
;; host with only pylsp starts eglot and then fails to exec a missing binary.
;; Nothing starts until you `uv tool install basedpyright'.
;;
;; Emacs 30.1's stock python entry is a completing-read over seven candidates,
;; so without the pin you get prompted on every fresh project.
;; ---------------------------------------------------------------------------
(defun my/python-eglot-maybe ()
  "Start Eglot only when the server this config pins is actually installed."
  (when (executable-find "basedpyright-langserver")
    (eglot-ensure)))

(use-package eglot
  :ensure nil
  :hook (python-base-mode . my/python-eglot-maybe)
  :config
  (setq eglot-autoshutdown t
        eglot-extend-to-xref t
        ;; Default is '(:size 2000000 :format full) -- 2MB of full JSON-RPC
        ;; logging per server, for a buffer nobody reads.
        eglot-events-buffer-config '(:size 0 :format short))
  (when (executable-find "basedpyright-langserver")
    (add-to-list 'eglot-server-programs
                 '((python-mode python-ts-mode)
                   . ("basedpyright-langserver" "--stdio"))))
  (setq-default eglot-workspace-configuration
                '(:basedpyright
                  (:analysis (:diagnosticMode "openFilesOnly"
                              :typeCheckingMode "standard")))))

;; flymake-mode-map has NO navigation bindings in Emacs 30 -- it contains a
;; menu-bar entry and a left-fringe mouse binding and nothing else. And
;; `C-c ! l' is flycheck's prefix, not flymake's; it is unbound here. Without
;; these, diagnostics are unreachable from the keyboard.
(with-eval-after-load 'flymake
  (keymap-set flymake-mode-map "M-n" #'flymake-goto-next-error)
  (keymap-set flymake-mode-map "M-p" #'flymake-goto-prev-error)
  (keymap-set flymake-mode-map "C-c e l" #'flymake-show-buffer-diagnostics)
  (keymap-set flymake-mode-map "C-c e p" #'flymake-show-project-diagnostics))

;; ---------------------------------------------------------------------------
;; The LSP action keys. eglot ships no prefix of its own -- every one of these
;; is M-x-only out of the box, which is most of why eglot feels less capable
;; than it is. C-c l is free.
;; ---------------------------------------------------------------------------
(defvar my/lsp-map (make-sparse-keymap) "Prefix map for LSP actions.")
(global-set-key (kbd "C-c l") my/lsp-map)
(with-eval-after-load 'eglot
  (keymap-set my/lsp-map "r" #'eglot-rename)
  (keymap-set my/lsp-map "a" #'eglot-code-actions)
  (keymap-set my/lsp-map "f" #'eglot-format-buffer)
  (keymap-set my/lsp-map "d" #'eldoc-doc-buffer)
  (keymap-set my/lsp-map "i" #'eglot-find-implementation)
  (keymap-set my/lsp-map "t" #'eglot-find-typeDefinition)
  (keymap-set my/lsp-map "R" #'eglot-reconnect)
  (keymap-set my/lsp-map "q" #'eglot-shutdown))

;; "Go to symbol in workspace" -- the project-wide symbol jump an IDE puts on
;; Ctrl-T. xref/imenu only see files you have open; this asks the server.
(use-package consult-eglot
  :after eglot
  :bind (:map my/lsp-map ("s" . consult-eglot-symbols)))

;; eglot expands LSP snippet completions (function call templates with
;; tab-through placeholders) ONLY when yasnippet is loaded -- without it you get
;; the bare name and no argument list. That is the whole reason it is here.
(use-package yasnippet
  :config (yas-global-mode 1))

;; Format on save, asynchronously, applied as an RCS diff so point, mark, scroll
;; position and undo history all survive. apheleia ships correct ruff recipes;
;; its python default is black, so this just repoints it.
(when (executable-find "ruff")
  (use-package apheleia
    :config
    (setf (alist-get 'python-mode    apheleia-mode-alist) '(ruff-isort ruff)
          (alist-get 'python-ts-mode apheleia-mode-alist) '(ruff-isort ruff))
    (apheleia-global-mode 1)))

;; Header-line crumbs: which project, which file, which class > which method.
;; Costs one screen row per window, which is why it is prog-mode only.
(use-package breadcrumb
  :hook (prog-mode . breadcrumb-local-mode))

;; ---------------------------------------------------------------------------
;; dape -- breakpoints and stepping, via the Debug Adapter Protocol. Pure elisp,
;; no external Emacs dependency.
;;
;; The adapter itself is NOT bundled: Python debugging needs `debugpy' importable
;; by the interpreter being debugged. That means it belongs in the environment
;; that actually runs your code -- i.e. inside the container, not on this host
;; -- and dape must then attach over a port rather than launch a local process.
;; Nothing here installs it; C-x C-a d prompts for a configuration.
;; ---------------------------------------------------------------------------
(use-package dape
  :defer t
  :custom
  (dape-buffer-window-arrangement 'right)
  (dape-inlay-hints t)
  :config
  (dape-breakpoint-global-mode 1))

;; ---------------------------------------------------------------------------
;; Editing behaviour an IDE has on by default and Emacs does not.
;;
;; display-line-numbers is prog-mode only: in an 80-column tmux pane the gutter
;; is real estate, and it is noise in dired, magit and compilation buffers.
;; ---------------------------------------------------------------------------
(add-hook 'prog-mode-hook #'display-line-numbers-mode)
(setq display-line-numbers-width-start t)

(add-hook 'prog-mode-hook #'subword-mode)        ; camelCase counts as words

;; :hook rather than a bare add-hook. A raw (add-hook 'prog-mode-hook
;; #'rainbow-delimiters-mode) placed before the package exists is a live
;; landmine: package.el byte-compiles in a prog-mode buffer, so the hook fires
;; mid-install against a void function and aborts every remaining install in
;; the file. use-package's :hook defers through the autoload instead.
(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

(electric-pair-mode 1)                           ; auto-close brackets and quotes
(delete-selection-mode 1)                        ; typing replaces the region
(global-hl-line-mode 1)
(setq-default indent-tabs-mode nil)

;; eglot routes signatures through eldoc, and an unbounded docstring will eat
;; half a short pane. Cap it; C-c l d opens the full buffer.
(setq eldoc-echo-area-use-multiline-p 1
      eldoc-idle-delay 0.2)

;; ruff is a single static binary with no Python runtime, so it needs no
;; argument about the Docker rule at all. It hooks eglot-managed-mode rather
;; than python-mode because eglot resets flymake-diagnostic-functions to just
;; its own backend -- hooking the mode instead silently loses the ruff backend.
;; `when' wrapper, not `:if', because :if does not gate :ensure.
(when (executable-find "ruff")
  (use-package flymake-ruff
    :hook (eglot-managed-mode . flymake-ruff-load)))

;; ---------------------------------------------------------------------------
;; imenu. Free, and with a grammar loaded python-imenu-treesit-create-index
;; walks the parse tree, so the index is correctly nested and does not miss
;; decorated or multi-line-signature defs the way the regexp index does.
;; ---------------------------------------------------------------------------
(setq imenu-auto-rescan t
      imenu-max-item-length 160)
(when (boundp 'imenu-flatten)
  (setq imenu-flatten 'prefix))

;; ---------------------------------------------------------------------------
;; Jumping and window navigation.
;;
;; avy is NOT bound to C-; -- that is the upstream README binding and it cannot
;; reach Emacs here: tmux's `extended-keys' defaults to off and C-; has no
;; standard terminal representation, so the key is never transmitted at all.
;; M-g c is plain Meta and always survives.
;;
;; windmove is commonly claimed to be TTY-fragile. It is not: tmux delivers
;; ^[[1;2C etc. for shifted arrows and term/xterm decodes them to [S-right].
;; That makes ace-window a package to solve a problem that does not exist.
;;
;; winner-undo is the highest value-per-line item here: the moment magit-status
;; takes over the frame, it puts the layout back.
;; ---------------------------------------------------------------------------
(use-package avy
  :bind (("M-g c" . avy-goto-char-timer)
         ("M-g w" . avy-goto-word-1))
  :custom (avy-timeout-seconds 0.35))

(winner-mode 1)
(global-set-key (kbd "C-c <left>")  #'winner-undo)
(global-set-key (kbd "C-c <right>") #'winner-redo)

(windmove-default-keybindings 'shift)

(defun my/tty-report ()
  "Report what this terminal actually handed Emacs.
cells=16777216 means truecolor arrived; 256 means the tmux change did not take.
Also reports whether the startup GC threshold was restored -- if that reads
most-positive-fixnum, early-init's restore hook never fired and Emacs has
stopped collecting garbage entirely."
  (interactive)
  (message "TERM=%s COLORTERM=%s cells=%s init=%s gcs=%d gc-thresh=%s"
           (getenv "TERM") (getenv "COLORTERM") (display-color-cells)
           (emacs-init-time "%.3fs") gcs-done gc-cons-threshold))

(global-set-key (kbd "C-c ?") #'my/tty-report)

;; ---------------------------------------------------------------------------
;; Julia.
;;
;; julia-ts-mode's own autoloads prepend ("\\.jl\\'" . julia-ts-mode) to
;; auto-mode-alist UNCONDITIONALLY, and its mode body opens with
;;   (unless (treesit-ready-p 'julia) (error "Tree-sitter for Julia is not available"))
;; -- so on any host that has not built the julia grammar, which today is all
;; three Macs, opening a .jl file is an ERROR rather than a fallback.
;;
;; python-ts-mode does not have this problem: python.el wraps its entire body,
;; including its auto-mode-alist entry, in (when (treesit-ready-p 'python) ...).
;; julia-ts-mode does not. So take the entry back and route through
;; major-mode-remap-alist, which is guarded. Once the grammar IS present the
;; remap loads julia-ts-mode, which re-adds its own entry -- harmless at that
;; point, because reaching it proves the grammar loaded.
;; ---------------------------------------------------------------------------
(use-package julia-mode
  :mode "\\.jl\\'")

(use-package julia-ts-mode
  :commands julia-ts-mode)

(setq auto-mode-alist (rassq-delete-all 'julia-ts-mode (copy-alist auto-mode-alist)))
(add-to-list 'auto-mode-alist '("\\.jl\\'" . julia-mode))
(my/treesit-remap 'julia 'julia-mode 'julia-ts-mode)

;; ---------------------------------------------------------------------------
;; LaTeX. AUCTeX supersedes the built-in tex-mode: better fontification of
;; macros, math and environments, and it understands multi-file documents.
;; TeX-parse-self/TeX-auto-save let it learn macros defined in a local .sty
;; (e.g. the LNA proposal template) instead of leaving them unhighlighted.
;;
;; Left exactly as it was, deliberately. This is the one part of the file that
;; has never misbehaved, and folding it into a use-package form would change
;; load semantics for no benefit; `tex' is the feature auctex provides.
;; ---------------------------------------------------------------------------
(use-package tex
  :ensure auctex
  :defer t)

(setq TeX-auto-save t
      TeX-parse-self t
      TeX-master t)                  ; assume self-contained; set per-file for \input'd children
(add-hook 'LaTeX-mode-hook #'LaTeX-math-mode)   ; C-c ~ math shortcuts
(add-hook 'LaTeX-mode-hook #'turn-on-reftex)    ; C-c ( / C-c [ for refs and citations
(setq reftex-plug-into-AUCTeX t)

;; Pick up files changed outside Emacs rather than silently showing stale text.
;; The non-file half is what stops dired listings going stale after a git
;; checkout and looking like a bug in whatever was installed most recently.
(global-auto-revert-mode 1)
(setq auto-revert-verbose nil
      global-auto-revert-non-file-buffers t)

;; Load this machine's Custom settings, if it has any. NOERROR and NOMESSAGE
;; both matter: custom.el does not exist until something is customized, and a
;; bare (load custom-file) would break init on every host until then.
;; KEEP THIS LAST.
(load custom-file t t)
