;;; agent-shell-commander-peek.el --- Posframe buffer switcher for agent-shell  -*- lexical-binding: t -*-

;; Copyright (C) 2024

;; Author: Sreenivas Venkobarao
;; Package-Requires: ((emacs "29.1") (agent-shell "0.1") (posframe "1.4"))

;;; Code:

(require 'agent-shell)
(require 'posframe)
(require 'svg)

;;;; Customization

(defgroup agent-shell-commander-peek nil
  "Posframe buffer switcher for agent-shell."
  :group 'agent-shell
  :prefix "agent-shell-commander-peek-")

(defcustom agent-shell-commander-peek-position 'right
  "Edge of the frame where the peek posframe is anchored.
One of `top', `bottom', `left', `right'."
  :type '(choice (const top) (const bottom) (const left) (const right)))

(defcustom agent-shell-commander-peek-width 52
  "Width of the peek posframe in columns."
  :type 'integer)

(defcustom agent-shell-commander-peek-height 60
  "Maximum height of the peek posframe in rows."
  :type 'integer)

;;;; Faces

(defface agent-shell-commander-peek-project
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for project group headers in the peek posframe.")

;;;; Internal state

(defconst agent-shell-commander-peek--buffer-name " *agent-shell-commander-peek*")

(defvar agent-shell-commander-peek--entries nil
  "Flat list of selectable entries.  Each element: plist (:buffer SHELL-BUF).")

(defvar agent-shell-commander-peek--current-idx 0
  "Index into `agent-shell-commander-peek--entries' of the highlighted entry.")

(defvar agent-shell-commander-peek--origin-window nil
  "Window that was selected when peek was invoked.")

;;;; Keymap

(defvar agent-shell-commander-peek-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "n")   #'agent-shell-commander-peek-next)
    (define-key map (kbd "j")   #'agent-shell-commander-peek-next)
    (define-key map (kbd "p")   #'agent-shell-commander-peek-prev)
    (define-key map (kbd "k")   #'agent-shell-commander-peek-prev)
    (define-key map (kbd "RET") #'agent-shell-commander-peek-select)
    (define-key map (kbd "g")   #'agent-shell-commander-peek-quit)
    (define-key map (kbd "q")   #'agent-shell-commander-peek-quit)
    (define-key map (kbd "C-g") #'agent-shell-commander-peek-quit)
    (define-key map (kbd "s")   #'agent-shell-commander-peek-new-shell)
    map)
  "Keymap active inside the agent-shell-commander peek posframe.")

;;;; SVG status icons

(defun agent-shell-commander-peek--svg-icon (state)
  "Return a 14×14 SVG image for STATE (`busy', `idle', or `dead')."
  (let* ((size 14)
         (svg  (svg-create size size))
         (cx   (/ size 2.0))
         (cy   (/ size 2.0))
         (r    5.0))
    (pcase state
      ('busy
       (svg-circle svg cx cy r
                   :fill (face-foreground 'warning nil t)
                   :stroke "none")
       (svg-polygon svg (list (cons (- cx 3) (- cy 3.5))
                              (cons (+ cx 3) (- cy 3.5))
                              (cons cx cy))
                    :fill (face-background 'default nil t))
       (svg-polygon svg (list (cons cx cy)
                              (cons (- cx 3) (+ cy 3.5))
                              (cons (+ cx 3) (+ cy 3.5)))
                    :fill (face-background 'default nil t)))
      ('idle
       (svg-circle svg cx cy r
                   :fill "none"
                   :stroke (face-foreground 'shadow nil t)
                   :stroke-width 1.5))
      ('dead
       (svg-rectangle svg (- cx 4) (- cy 1) 8 2
                      :fill (face-foreground 'shadow nil t)
                      :rx 1)))
    (svg-image svg :ascent 'center)))

(defun agent-shell-commander-peek--buffer-state (buf)
  "Return `busy', `idle', or `dead' for BUF."
  (if (buffer-live-p buf)
      (with-current-buffer buf
        (if (shell-maker-busy) 'busy 'idle))
    'dead))

;;;; Buffer grouping

(defun agent-shell-commander-peek--grouped-buffers (current-root)
  "Return list of (root project-name buffers) groups.
Group matching CURRENT-ROOT is placed first; others alphabetical."
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
    (let* ((groups (mapcar (lambda (root)
                             (let ((e (gethash root table)))
                               (list root (car e) (cadr e))))
                           (nreverse order)))
           (current (seq-filter (lambda (g) (equal (car g) current-root)) groups))
           (rest    (seq-filter (lambda (g) (not (equal (car g) current-root))) groups)))
      (append current
              (sort rest (lambda (a b) (string< (cadr a) (cadr b))))))))

;;;; Rendering

(defun agent-shell-commander-peek--render (groups)
  "Render GROUPS into the peek buffer."
  (with-current-buffer (get-buffer-create agent-shell-commander-peek--buffer-name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (setq agent-shell-commander-peek--entries nil)
      (insert "\n")
      (dolist (group groups)
        (let ((pname (cadr  group))
              (bufs  (caddr group)))
          (insert (propertize (concat "    " pname "\n")
                              'face 'agent-shell-commander-peek-project
                              'agent-shell-commander-peek-header t))
          (dolist (buf bufs)
            (let* ((state (agent-shell-commander-peek--buffer-state buf))
                   (icon  (agent-shell-commander-peek--svg-icon state))
                   (bname (buffer-name buf)))
              (push (list :buffer buf) agent-shell-commander-peek--entries)
              (insert (propertize
                       (concat "      "
                               (propertize " " 'display icon)
                               " "
                               bname
                               "\n")
                       'face 'default
                       'agent-shell-commander-peek-buffer buf))))
          (insert "\n")))
      (insert (propertize "    n/p navigate   RET select   q quit\n" 'face 'shadow))
      (insert "\n")
      (setq agent-shell-commander-peek--entries (nreverse agent-shell-commander-peek--entries))
      (setq buffer-read-only t))
    (goto-char (point-min))))

;;;; Highlight management

(defun agent-shell-commander-peek--highlight-line (idx)
  "Highlight the entry at IDX, clearing all others."
  (with-current-buffer (get-buffer-create agent-shell-commander-peek--buffer-name)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (when (get-text-property (point) 'agent-shell-commander-peek-buffer)
            (put-text-property (point)
                               (min (1+ (line-end-position)) (point-max))
                               'face 'default))
          (forward-line 1)))
      (when-let* ((entry (nth idx agent-shell-commander-peek--entries))
                  (buf   (plist-get entry :buffer))
                  (pos   (text-property-any (point-min) (point-max)
                                            'agent-shell-commander-peek-buffer buf)))
        (put-text-property pos
                           (min (1+ (save-excursion
                                      (goto-char pos)
                                      (line-end-position)))
                                (point-max))
                           'face 'highlight)))))

;;;; Posframe position handler

(defun agent-shell-commander-peek--poshandler (info)
  "Anchor the posframe to `agent-shell-commander-peek-position'."
  (let* ((fw  (plist-get info :parent-frame-width))
         (fh  (plist-get info :parent-frame-height))
         (pw  (plist-get info :posframe-width))
         (ph  (plist-get info :posframe-height))
         (pad 8))
    (pcase agent-shell-commander-peek-position
      ('right  (cons (- fw pw pad) pad))
      ('left   (cons pad pad))
      ('top    (cons (/ (- fw pw) 2) pad))
      ('bottom (cons (/ (- fw pw) 2) (- fh ph pad))))))

;;;; Commands

(defun agent-shell-commander-peek-next ()
  "Move highlight to the next entry."
  (interactive)
  (when agent-shell-commander-peek--entries
    (setq agent-shell-commander-peek--current-idx
          (mod (1+ agent-shell-commander-peek--current-idx)
               (length agent-shell-commander-peek--entries)))
    (agent-shell-commander-peek--highlight-line agent-shell-commander-peek--current-idx)))

(defun agent-shell-commander-peek-prev ()
  "Move highlight to the previous entry."
  (interactive)
  (when agent-shell-commander-peek--entries
    (setq agent-shell-commander-peek--current-idx
          (mod (1- agent-shell-commander-peek--current-idx)
               (length agent-shell-commander-peek--entries)))
    (agent-shell-commander-peek--highlight-line agent-shell-commander-peek--current-idx)))

(defun agent-shell-commander-peek-select ()
  "Switch to the highlighted buffer and dismiss the posframe."
  (interactive)
  (when-let* ((entry (nth agent-shell-commander-peek--current-idx
                          agent-shell-commander-peek--entries))
              (buf   (plist-get entry :buffer)))
    (let ((win agent-shell-commander-peek--origin-window))
      (posframe-delete agent-shell-commander-peek--buffer-name)
      (when-let ((pb (get-buffer agent-shell-commander-peek--buffer-name)))
        (kill-buffer pb))
      (setq agent-shell-commander-peek--entries    nil
            agent-shell-commander-peek--current-idx 0)
      (when (and (window-live-p win) (buffer-live-p buf))
        (select-window win)
        (switch-to-buffer buf)))))

(defun agent-shell-commander-peek-quit ()
  "Dismiss the peek posframe."
  (interactive)
  (posframe-delete agent-shell-commander-peek--buffer-name)
  (when-let ((buf (get-buffer agent-shell-commander-peek--buffer-name)))
    (kill-buffer buf))
  (setq agent-shell-commander-peek--entries     nil
        agent-shell-commander-peek--current-idx 0)
  (when (window-live-p agent-shell-commander-peek--origin-window)
    (select-window agent-shell-commander-peek--origin-window)))

(defun agent-shell-commander-peek-new-shell ()
  "Launch a new agent-shell in the current project and dismiss peek."
  (interactive)
  (let ((win agent-shell-commander-peek--origin-window))
    (agent-shell-commander-peek-quit)
    (when (window-live-p win)
      (select-window win)
      (agent-shell-new-shell))))

;;;; Entry point

;;;###autoload
(defun agent-shell-commander-peek ()
  "Show a posframe listing all agent-shell buffers grouped by project.

n/p navigates, RET selects, g/q/C-g quits."
  (interactive)
  (let* ((origin-win   (selected-window))
         (current-root (ignore-errors (agent-shell-cwd)))
         (groups       (agent-shell-commander-peek--grouped-buffers current-root)))
    (unless groups
      (user-error "No agent-shell buffers found"))
    (setq agent-shell-commander-peek--origin-window origin-win
          agent-shell-commander-peek--current-idx   0)
    (agent-shell-commander-peek--render groups)
    (agent-shell-commander-peek--highlight-line 0)
    (with-current-buffer agent-shell-commander-peek--buffer-name
      (use-local-map agent-shell-commander-peek-map))
    (posframe-show agent-shell-commander-peek--buffer-name
                   :poshandler            #'agent-shell-commander-peek--poshandler
                   :width                 agent-shell-commander-peek-width
                   :max-height            agent-shell-commander-peek-height
                   :internal-border-width 10
                   :border-color          (face-foreground 'shadow nil t)
                   :accept-focus          t)
    (let ((pf-frame (buffer-local-value 'posframe--frame
                                        (get-buffer agent-shell-commander-peek--buffer-name))))
      (when (framep pf-frame)
        (select-frame-set-input-focus pf-frame)
        (select-window (frame-selected-window pf-frame) t)))))

(provide 'agent-shell-commander-peek)
;;; agent-shell-commander-peek.el ends here
