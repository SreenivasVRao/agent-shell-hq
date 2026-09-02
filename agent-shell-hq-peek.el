;;; agent-shell-hq-peek.el --- Posframe buffer switcher for agent-shell  -*- lexical-binding: t -*-

;; Copyright (C) 2024

;; Author: Sreenivas Venkobarao
;; Package-Requires: ((emacs "29.1") (agent-shell "0.66.1") (posframe "1.4"))

;;; Code:

(require 'agent-shell)
(require 'agent-shell-viewport)
(require 'posframe)

;;;; Customization

(defgroup agent-shell-hq-peek nil
  "Posframe buffer switcher for agent-shell."
  :group 'agent-shell
  :prefix "agent-shell-hq-peek-")

(defcustom agent-shell-hq-peek-position 'right
  "Edge of the frame where the peek posframe is anchored.
One of `top', `bottom', `left', `right'."
  :type '(choice (const top) (const bottom) (const left) (const right)))

(defcustom agent-shell-hq-peek-width 52
  "Width of the peek posframe in columns."
  :type 'integer)

(defcustom agent-shell-hq-peek-height 60
  "Maximum height of the peek posframe in rows."
  :type 'integer)

;;;; Faces

(defface agent-shell-hq-peek-project
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for project group headers in the peek posframe.")

;;;; Internal state

(defconst agent-shell-hq-peek--buffer-name " *agent-shell-hq-peek*")

(defvar agent-shell-hq-peek--entries nil
  "Flat list of selectable entries.  Each element: plist (:buffer SHELL-BUF).")

(defvar agent-shell-hq-peek--current-idx 0
  "Index into `agent-shell-hq-peek--entries' of the highlighted entry.")

(defvar agent-shell-hq-peek--origin-window nil
  "Window that was selected when peek was invoked.")

(defvar agent-shell-hq-peek--origin-buffer nil
  "Buffer displayed in the origin window when peek was invoked (restored on quit).")

(defvar agent-shell-hq-peek--saved-terminal-map nil
  "Saved `overriding-terminal-local-map' value, restored when peek is dismissed.")

;; Minimal override map — only C-g, so normal editing is unaffected in the
;; parent frame. `overriding-terminal-local-map' has the highest priority and
;; fires before the child-frame keymap lookup, making C-g reliable regardless
;; of which frame currently has focus.
(defvar agent-shell-hq-peek--quit-override-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-g") #'agent-shell-hq-peek-quit)
    map)
  "Terminal-wide override map active while the peek posframe is shown.")

;;;; Keymap

(defvar agent-shell-hq-peek-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "n")   #'agent-shell-hq-peek-next)
    (define-key map (kbd "j")   #'agent-shell-hq-peek-next)
    (define-key map (kbd "p")   #'agent-shell-hq-peek-prev)
    (define-key map (kbd "k")   #'agent-shell-hq-peek-prev)
    (define-key map (kbd "RET") #'agent-shell-hq-peek-select)
    (define-key map (kbd "g")   #'agent-shell-hq-peek-quit)
    (define-key map (kbd "q")   #'agent-shell-hq-peek-quit)
    (define-key map (kbd "C-g") #'agent-shell-hq-peek-quit)
    (define-key map (kbd "s")   #'agent-shell-hq-peek-new-shell)
    map)
  "Keymap active inside the agent-shell-hq peek posframe.")

;;;; Override map helpers

(defun agent-shell-hq-peek--clear-override ()
  "Restore `overriding-terminal-local-map' to its pre-peek value."
  (when (eq overriding-terminal-local-map agent-shell-hq-peek--quit-override-map)
    (setq overriding-terminal-local-map agent-shell-hq-peek--saved-terminal-map))
  (setq agent-shell-hq-peek--saved-terminal-map nil))

;;;; Preferred display buffer

(defun agent-shell-hq-peek--preferred-buffer (shell-buf)
  "Return the best buffer to display for SHELL-BUF.
Uses the existing viewport buffer when one already exists, so its mode
\(view or edit) is preserved.  Falls back to the shell buffer itself."
  (or (ignore-errors
        (agent-shell-viewport--buffer :shell-buffer shell-buf :existing-only t))
      shell-buf))

;;;; Preview

(defun agent-shell-hq-peek--preview-current ()
  "Show the highlighted buffer in the origin window (behind the posframe)."
  (when-let* ((entry      (nth agent-shell-hq-peek--current-idx
                               agent-shell-hq-peek--entries))
              (shell-buf  (plist-get entry :buffer))
              (display-buf (agent-shell-hq-peek--preferred-buffer shell-buf)))
    (when (and (window-live-p agent-shell-hq-peek--origin-window)
               (buffer-live-p display-buf))
      (set-window-buffer agent-shell-hq-peek--origin-window display-buf))))

;;;; SVG icon files

(defvar agent-shell-hq-peek--icon-cache nil
  "Alist of (STATE . IMAGE) for buffer status icons.")

(defconst agent-shell-hq-peek--icon-svgs
  '((idle . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\" viewBox=\"0 0 20 20\">
  <circle cx=\"10\" cy=\"10\" r=\"8.5\" fill=\"#4E9A72\"/>
  <polyline points=\"4.5,10.5 8.5,14.5 16,5.5\"
            stroke=\"white\" stroke-width=\"2.5\" fill=\"none\"
            stroke-linecap=\"round\" stroke-linejoin=\"round\"/>
</svg>")
    (busy . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\" viewBox=\"0 0 20 20\">
  <circle cx=\"10\" cy=\"10\" r=\"8.5\" fill=\"#C9922A\"/>
  <circle cx=\"10\" cy=\"10\" r=\"6\" fill=\"none\" stroke=\"white\" stroke-width=\"1.2\"/>
  <line x1=\"10\" y1=\"10\" x2=\"10\" y2=\"5.5\" stroke=\"white\" stroke-width=\"1.8\" stroke-linecap=\"round\"/>
  <line x1=\"10\" y1=\"10\" x2=\"13.5\" y2=\"10\" stroke=\"white\" stroke-width=\"1.8\" stroke-linecap=\"round\"/>
</svg>")
    (blocked . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\" viewBox=\"0 0 20 20\">
  <polygon points=\"10,2 18.5,17.5 1.5,17.5\" fill=\"#C0392B\"/>
  <line x1=\"10\" y1=\"7\" x2=\"10\" y2=\"12.5\" stroke=\"white\" stroke-width=\"1.8\" stroke-linecap=\"round\"/>
  <circle cx=\"10\" cy=\"14.5\" r=\"1\" fill=\"white\"/>
</svg>")
    (dead . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\" viewBox=\"0 0 20 20\">
  <circle cx=\"10\" cy=\"10\" r=\"8.5\" fill=\"#C0392B\"/>
  <line x1=\"6.5\" y1=\"6.5\" x2=\"13.5\" y2=\"13.5\" stroke=\"white\" stroke-width=\"2.5\" stroke-linecap=\"round\"/>
  <line x1=\"13.5\" y1=\"6.5\" x2=\"6.5\" y2=\"13.5\" stroke=\"white\" stroke-width=\"2.5\" stroke-linecap=\"round\"/>
</svg>"))
  "Inline SVG strings for each buffer state.")

(defun agent-shell-hq-peek--svg-icon (state)
  "Return the cached SVG image for STATE (`busy', `blocked', `idle', or `dead')."
  (unless agent-shell-hq-peek--icon-cache
    (setq agent-shell-hq-peek--icon-cache
          (mapcar (lambda (pair)
                    (cons (car pair)
                          (create-image (cdr pair) 'svg t :ascent 'center)))
                  agent-shell-hq-peek--icon-svgs)))
  (alist-get state agent-shell-hq-peek--icon-cache))

(defcustom agent-shell-hq-fallback-icons
  '((idle . ("✓" . success))
    (busy . ("◔" . warning))
    (blocked . ("⚠" . error))
    (dead . ("✗" . error)))
  "Fallback Unicode characters for TUI Emacs.
Each entry is (STATE . (CHAR . FACE)), used when image display is
unavailable (e.g. terminal Emacs).  Uses `font-lock-face' so the
color survives outer `face' text properties in the render code."
  :type '(alist :key-type (choice (const idle) (const busy) (const blocked) (const dead))
                :value-type (cons string face))
  :group 'agent-shell-hq-peek)

(defun agent-shell-hq--icon (state)
  "Return a propertized string displaying the icon for STATE.
In GUI Emacs with SVG support, this is a space with a `display' SVG
image property.  Otherwise, this is a Unicode character with a face."
  (if (and (display-graphic-p) (image-type-available-p 'svg))
      (propertize " " 'display (agent-shell-hq-peek--svg-icon state))
    (let ((fallback (or (alist-get state agent-shell-hq-fallback-icons)
                         '("?" . default))))
      (propertize (car fallback) 'face (cdr fallback) 'font-lock-face (cdr fallback)))))

(defun agent-shell-hq-peek--buffer-state (buf)
  "Return `busy', `blocked', `idle', or `dead' for BUF."
  (if (buffer-live-p buf)
      (with-current-buffer buf
        (cond
         ((and (fboundp 'agent-shell-status)
               (eq (ignore-errors (agent-shell-status :shell-buffer buf)) 'blocked))
          'blocked)
         ((and (fboundp 'agent-shell--permission-pending-p)
               (ignore-errors (agent-shell--permission-pending-p :shell-buffer buf)))
          'blocked)
         ((shell-maker-busy) 'busy)
         (t 'idle)))
    'dead))

;;;; Buffer grouping

(defun agent-shell-hq-peek--grouped-buffers ()
  "Return list of (root project-name buffers) groups, sorted alphabetically."
  (let ((table (make-hash-table :test 'equal))
        (order nil))
    (dolist (buf (agent-shell-buffers))
      (let* ((root  (with-current-buffer buf (agent-shell-cwd)))
             (pname (with-current-buffer buf (agent-shell--project-name))))
        (unless (gethash root table)
          (puthash root (list pname nil) table)
          (push root order))
        (let ((entry (gethash root table)))
          (setcar (cdr entry) (append (cadr entry) (list buf))))))
    (let ((groups (mapcar (lambda (root)
                            (let ((e (gethash root table)))
                              (list root (car e)
                                    (sort (copy-sequence (cadr e))
                                          (lambda (a b)
                                            (string< (buffer-name a)
                                                     (buffer-name b)))))))
                          (nreverse order))))
      (sort groups (lambda (a b) (string< (cadr a) (cadr b)))))))

;;;; Rendering

(defun agent-shell-hq-peek--render (groups)
  "Render GROUPS into the peek buffer."
  (with-current-buffer (get-buffer-create agent-shell-hq-peek--buffer-name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (setq agent-shell-hq-peek--entries nil)
      (insert "\n")
      (dolist (group groups)
        (let ((pname (cadr  group))
              (bufs  (caddr group)))
          (insert (propertize (concat "    " pname "\n")
                              'face 'agent-shell-hq-peek-project
                              'agent-shell-hq-peek-header t))
           (dolist (buf bufs)
             (let* ((state (agent-shell-hq-peek--buffer-state buf))
                    (icon  (agent-shell-hq--icon state))
                    (bname (buffer-name buf)))
                (push (list :buffer buf) agent-shell-hq-peek--entries)
                (insert (propertize
                         (concat "      "
                                 icon
                                 " "
                                 bname
                                 "\n")
                        'agent-shell-hq-peek-buffer buf))))
          (insert "\n")))
      (insert (propertize "    n/p navigate   RET select   q quit\n" 'face 'shadow))
      (insert "\n")
      (setq agent-shell-hq-peek--entries (nreverse agent-shell-hq-peek--entries))
      (setq buffer-read-only t))
    (goto-char (point-min))))

;;;; Highlight management

(defvar agent-shell-hq-peek--highlight-overlay nil
  "Overlay used to highlight the selected line in the peek buffer.")

(defun agent-shell-hq-peek--highlight-line (idx)
  "Highlight the entry at IDX, clearing all others."
  (with-current-buffer (get-buffer-create agent-shell-hq-peek--buffer-name)
    (let ((inhibit-read-only t))
      (unless (overlayp agent-shell-hq-peek--highlight-overlay)
        (setq agent-shell-hq-peek--highlight-overlay
              (make-overlay (point-min) (point-min))))
      (let ((ov agent-shell-hq-peek--highlight-overlay))
        (move-overlay ov (point-min) (point-min))
        (when-let* ((entry (nth idx agent-shell-hq-peek--entries))
                    (buf   (plist-get entry :buffer))
                    (pos   (text-property-any (point-min) (point-max)
                                              'agent-shell-hq-peek-buffer buf)))
          (move-overlay ov pos
                        (min (1+ (save-excursion
                                   (goto-char pos)
                                   (line-end-position)))
                             (point-max)))
        (overlay-put ov 'face 'highlight))))))

;;;; Posframe position handler

(defun agent-shell-hq-peek--poshandler (info)
  "Anchor the posframe to `agent-shell-hq-peek-position'."
  (let* ((fw  (plist-get info :parent-frame-width))
         (fh  (plist-get info :parent-frame-height))
         (pw  (plist-get info :posframe-width))
         (ph  (plist-get info :posframe-height))
         (pad 8))
    (pcase agent-shell-hq-peek-position
      ('right  (cons (- fw pw pad) pad))
      ('left   (cons pad pad))
      ('top    (cons (/ (- fw pw) 2) pad))
      ('bottom (cons (/ (- fw pw) 2) (- fh ph pad))))))

;;;; Commands

(defun agent-shell-hq-peek-next ()
  "Move highlight to the next entry and preview that buffer."
  (interactive)
  (when agent-shell-hq-peek--entries
    (setq agent-shell-hq-peek--current-idx
          (mod (1+ agent-shell-hq-peek--current-idx)
               (length agent-shell-hq-peek--entries)))
    (agent-shell-hq-peek--highlight-line agent-shell-hq-peek--current-idx)
    (agent-shell-hq-peek--preview-current)))

(defun agent-shell-hq-peek-prev ()
  "Move highlight to the previous entry and preview that buffer."
  (interactive)
  (when agent-shell-hq-peek--entries
    (setq agent-shell-hq-peek--current-idx
          (mod (1- agent-shell-hq-peek--current-idx)
               (length agent-shell-hq-peek--entries)))
    (agent-shell-hq-peek--highlight-line agent-shell-hq-peek--current-idx)
    (agent-shell-hq-peek--preview-current)))

(defun agent-shell-hq-peek-select ()
  "Confirm the highlighted buffer, switch to it, and dismiss the posframe."
  (interactive)
  (when-let* ((entry     (nth agent-shell-hq-peek--current-idx
                              agent-shell-hq-peek--entries))
              (shell-buf (plist-get entry :buffer))
              (disp-buf  (agent-shell-hq-peek--preferred-buffer shell-buf)))
    (let ((win agent-shell-hq-peek--origin-window))
      (agent-shell-hq-peek--clear-override)
      (posframe-delete agent-shell-hq-peek--buffer-name)
      (when-let ((pb (get-buffer agent-shell-hq-peek--buffer-name)))
        (kill-buffer pb))
      (setq agent-shell-hq-peek--entries    nil
            agent-shell-hq-peek--current-idx 0)
      (when (and (window-live-p win) (buffer-live-p disp-buf))
        (select-window win)
        (switch-to-buffer disp-buf)))))

(defun agent-shell-hq-peek-quit ()
  "Dismiss the peek posframe and restore the original buffer."
  (interactive)
  (agent-shell-hq-peek--clear-override)
  (let ((win      agent-shell-hq-peek--origin-window)
        (orig-buf agent-shell-hq-peek--origin-buffer))
    (posframe-delete agent-shell-hq-peek--buffer-name)
    (when-let ((buf (get-buffer agent-shell-hq-peek--buffer-name)))
      (kill-buffer buf))
    (setq agent-shell-hq-peek--entries      nil
          agent-shell-hq-peek--current-idx  0
          agent-shell-hq-peek--origin-buffer nil)
    (when (window-live-p win)
      (select-window win)
      (when (and (buffer-live-p orig-buf)
                 (not (eq (window-buffer win) orig-buf)))
        (set-window-buffer win orig-buf)))))

(defun agent-shell-hq-peek-new-shell ()
  "Launch a new agent-shell in the current project and dismiss peek."
  (interactive)
  (let ((win agent-shell-hq-peek--origin-window))
    (agent-shell-hq-peek-quit)
    (when (window-live-p win)
      (select-window win)
      (agent-shell-new-shell))))

;;;; Entry point

;;;###autoload
(defun agent-shell-hq-peek ()
  "Show a posframe listing all agent-shell buffers grouped by project.

n/p navigates, RET selects, g/q/C-g quits."
  (interactive)
  (let* ((origin-win   (selected-window))
         (groups       (agent-shell-hq-peek--grouped-buffers)))
    (unless groups
      (user-error "No agent-shell buffers found"))
    (setq agent-shell-hq-peek--origin-window origin-win
          agent-shell-hq-peek--origin-buffer  (window-buffer origin-win)
          agent-shell-hq-peek--current-idx   0)
    (agent-shell-hq-peek--render groups)
    (agent-shell-hq-peek--highlight-line 0)
    (with-current-buffer agent-shell-hq-peek--buffer-name
      (use-local-map agent-shell-hq-peek-map))
    (setq agent-shell-hq-peek--saved-terminal-map overriding-terminal-local-map
          overriding-terminal-local-map agent-shell-hq-peek--quit-override-map)
    (posframe-show agent-shell-hq-peek--buffer-name
                   :poshandler            #'agent-shell-hq-peek--poshandler
                   :width                 agent-shell-hq-peek-width
                   :max-height            agent-shell-hq-peek-height
                   :internal-border-width 4
                   :border-color          (face-foreground 'shadow nil t)
                   :accept-focus          t)
    (agent-shell-hq-peek--preview-current)
    (let ((pf-frame (buffer-local-value 'posframe--frame
                                        (get-buffer agent-shell-hq-peek--buffer-name))))
      (when (framep pf-frame)
        (select-frame-set-input-focus pf-frame)
        (select-window (frame-selected-window pf-frame) t)))))

(provide 'agent-shell-hq-peek)
;;; agent-shell-hq-peek.el ends here
