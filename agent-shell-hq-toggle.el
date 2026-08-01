;;; agent-shell-hq-toggle.el --- Perspective workspace for agent-shell  -*- lexical-binding: t -*-

;; Copyright (C) 2024

;; Author: Sreenivas Venkobarao
;; Package-Requires: ((emacs "29.1") (agent-shell "0.66.1") (persp-mode "2.9"))

;;; Code:

(require 'agent-shell)
(require 'agent-shell-viewport)
(require 'agent-shell-hq-peek)
(require 'agent-shell-hq-label)
(require 'persp-mode)
(require 'transient)

;;;; Customization

(defcustom agent-shell-hq-toggle-sidebar-width 36
  "Width of the toggle sidebar in columns."
  :type 'integer
  :group 'agent-shell-hq-peek)

;;;; Constants

(defconst agent-shell-hq-toggle--persp-name "*agent-shell*")
(defconst agent-shell-hq-toggle--sidebar-name " *agent-shell-hq-sidebar*")

;;;; Internal state

(defvar agent-shell-hq-toggle--prev-persp nil
  "Perspective name to return to on toggle-off.")

;; Each entry is a plist with :type ('project or 'buffer), :root ROOT,
;; and for buffer entries, :buffer BUF.  Project headers are navigable
;; entries so collapsed groups can be re-expanded via TAB.
(defvar agent-shell-hq-toggle--entries nil
  "Flat navigable entries including project headers and buffer lines.")

(defvar agent-shell-hq-toggle--current-idx 0
  "Index of the highlighted entry.")

(defvar agent-shell-hq-toggle--collapsed nil
  "List of project roots currently collapsed.")

(defvar agent-shell-hq-toggle--main-window nil
  "The main content window in the toggle workspace.")

;;;; Faces

(defface agent-shell-hq-toggle-project
  '((t :inherit agent-shell-hq-peek-project))
  "Face for project headers in the toggle sidebar.")

(defface agent-shell-hq-toggle-selection
  '((((class color) (background dark))
     :background "#2d3b2d" :extend t)
    (((class color) (background light))
     :background "#d4e4d4" :extend t))
  "Face for the selected entry in the toggle sidebar.
Intentionally dim — just enough to show position without glare.")

;;;; Keymap

(defvar agent-shell-hq-toggle-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "n")   #'agent-shell-hq-toggle-next)
    (define-key map (kbd "j")   #'agent-shell-hq-toggle-next)
    (define-key map (kbd "p")   #'agent-shell-hq-toggle-prev)
    (define-key map (kbd "k")   #'agent-shell-hq-toggle-prev)
    (define-key map (kbd "RET") #'agent-shell-hq-toggle-select)
    (define-key map (kbd "TAB") #'agent-shell-hq-toggle-collapse)
    (define-key map (kbd "g")   #'agent-shell-hq-toggle-refresh)
    (define-key map (kbd "s")   #'agent-shell-hq-toggle-new-shell)
    (define-key map (kbd "q")   #'agent-shell-hq-toggle)
    (define-key map (kbd "C-g") #'agent-shell-hq-toggle)
    map)
  "Keymap for the agent-shell-hq toggle sidebar.")

;;;; Rendering

(defun agent-shell-hq-toggle--render ()
  "Render the sidebar buffer and rebuild the entries list."
  (let ((groups (agent-shell-hq-peek--grouped-buffers
                 (ignore-errors (agent-shell-cwd)))))
    (with-current-buffer (get-buffer-create agent-shell-hq-toggle--sidebar-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq agent-shell-hq-toggle--entries nil)
        ;; Top heading
        (insert (propertize " Agent Shell HQ\n"
                            'face '(:inherit font-lock-function-name-face :weight bold)))
        (insert "\n")
        (dolist (group groups)
          (let* ((root      (car   group))
                 (pname     (cadr  group))
                 (bufs      (caddr group))
                 (collapsed (member root agent-shell-hq-toggle--collapsed)))
            ;; Project header — always a navigable entry
            (push (list :type 'project :root root) agent-shell-hq-toggle--entries)
            (insert (propertize
                     (concat " " (if collapsed "▸ " "▾ ") pname "\n")
                     'face 'agent-shell-hq-toggle-project
                     'agent-shell-hq-toggle-root root))
            (unless collapsed
              (dolist (buf bufs)
                (let* ((state (agent-shell-hq-peek--buffer-state buf))
                       (icon  (agent-shell-hq-peek--svg-icon state))
                       (bname (buffer-name buf)))
                  (let ((label (agent-shell-hq-label-get buf)))
                    (push (list :type 'buffer :buffer buf :root root)
                          agent-shell-hq-toggle--entries)
                    (insert (propertize
                             (concat "    "
                                     (propertize " " 'display icon)
                                     " "
                                     (or label bname)
                                     "\n")
                             'face 'default
                             'agent-shell-hq-toggle-buffer buf))))))
            (insert "\n")))
        (setq agent-shell-hq-toggle--entries
              (nreverse agent-shell-hq-toggle--entries))
        (setq buffer-read-only t)
        (setq-local cursor-type nil))
      (use-local-map agent-shell-hq-toggle-map))))

;;;; Highlight + point sync

(defun agent-shell-hq-toggle--highlight (idx)
  "Highlight entry at IDX and sync point to that line in the sidebar window."
  (with-current-buffer (get-buffer-create agent-shell-hq-toggle--sidebar-name)
    (let ((inhibit-read-only t))
      ;; Clear all entry highlights
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (cond
           ((get-text-property (point) 'agent-shell-hq-toggle-buffer)
            (put-text-property (point) (min (1+ (line-end-position)) (point-max))
                               'face 'default))
           ((get-text-property (point) 'agent-shell-hq-toggle-root)
            (put-text-property (point) (min (1+ (line-end-position)) (point-max))
                               'face 'agent-shell-hq-toggle-project)))
          (forward-line 1)))
      ;; Highlight and move to the selected entry
      (when-let* ((entry (nth idx agent-shell-hq-toggle--entries))
                  (type  (plist-get entry :type))
                  (pos   (if (eq type 'project)
                             (text-property-any (point-min) (point-max)
                                                'agent-shell-hq-toggle-root
                                                (plist-get entry :root))
                           (text-property-any (point-min) (point-max)
                                              'agent-shell-hq-toggle-buffer
                                              (plist-get entry :buffer)))))
        (put-text-property pos
                           (min (1+ (save-excursion (goto-char pos) (line-end-position)))
                                (point-max))
                           'face 'agent-shell-hq-toggle-selection)
        (goto-char pos)
        (when-let ((win (get-buffer-window (current-buffer))))
          (set-window-point win pos))))))

;;;; Preview

(defun agent-shell-hq-toggle--preview-current ()
  "Show the highlighted buffer entry in the main window.
No-ops when the highlighted entry is a project header."
  (when-let* ((entry     (nth agent-shell-hq-toggle--current-idx
                              agent-shell-hq-toggle--entries))
              ((eq (plist-get entry :type) 'buffer))
              (shell-buf (plist-get entry :buffer))
              (disp-buf  (agent-shell-hq-peek--preferred-buffer shell-buf)))
    (when (and (window-live-p agent-shell-hq-toggle--main-window)
               (buffer-live-p disp-buf))
      (set-window-buffer agent-shell-hq-toggle--main-window disp-buf))))

;;;; Commands

(defun agent-shell-hq-toggle-next ()
  "Move to the next entry and preview it."
  (interactive)
  (when agent-shell-hq-toggle--entries
    (setq agent-shell-hq-toggle--current-idx
          (mod (1+ agent-shell-hq-toggle--current-idx)
               (length agent-shell-hq-toggle--entries)))
    (agent-shell-hq-toggle--highlight agent-shell-hq-toggle--current-idx)
    (agent-shell-hq-toggle--preview-current)))

(defun agent-shell-hq-toggle-prev ()
  "Move to the previous entry and preview it."
  (interactive)
  (when agent-shell-hq-toggle--entries
    (setq agent-shell-hq-toggle--current-idx
          (mod (1- agent-shell-hq-toggle--current-idx)
               (length agent-shell-hq-toggle--entries)))
    (agent-shell-hq-toggle--highlight agent-shell-hq-toggle--current-idx)
    (agent-shell-hq-toggle--preview-current)))

(defun agent-shell-hq-toggle-select ()
  "On a buffer entry: move focus to main window.
On a project header: toggle collapse."
  (interactive)
  (when-let ((entry (nth agent-shell-hq-toggle--current-idx
                         agent-shell-hq-toggle--entries)))
    (if (eq (plist-get entry :type) 'project)
        (agent-shell-hq-toggle-collapse)
      (agent-shell-hq-toggle--preview-current)
      (when (window-live-p agent-shell-hq-toggle--main-window)
        (select-window agent-shell-hq-toggle--main-window)))))

(defun agent-shell-hq-toggle-collapse ()
  "Toggle collapse of the current entry's project group."
  (interactive)
  (when-let* ((entry (nth agent-shell-hq-toggle--current-idx
                          agent-shell-hq-toggle--entries))
              (root  (plist-get entry :root)))
    (if (member root agent-shell-hq-toggle--collapsed)
        (setq agent-shell-hq-toggle--collapsed
              (delete root agent-shell-hq-toggle--collapsed))
      (push root agent-shell-hq-toggle--collapsed))
    ;; Preserve position on the same project header after re-render
    (let ((saved-root root))
      (agent-shell-hq-toggle--render)
      (let ((new-idx (or (cl-position-if
                          (lambda (e)
                            (and (eq (plist-get e :type) 'project)
                                 (equal (plist-get e :root) saved-root)))
                          agent-shell-hq-toggle--entries)
                         0)))
        (setq agent-shell-hq-toggle--current-idx new-idx)
        (agent-shell-hq-toggle--highlight new-idx)))))

(defun agent-shell-hq-toggle-label-current ()
  "Generate a session label for the highlighted buffer entry."
  (interactive)
  (when-let* ((entry     (nth agent-shell-hq-toggle--current-idx
                              agent-shell-hq-toggle--entries))
              ((eq (plist-get entry :type) 'buffer))
              (shell-buf (plist-get entry :buffer)))
    (message "Labelling %s…" (buffer-name shell-buf))
    (agent-shell-hq-label-generate
     shell-buf
     (lambda (label)
       (if label
           (progn
             (agent-shell-hq-label-set shell-buf label)
             (when (get-buffer-window agent-shell-hq-toggle--sidebar-name)
               (agent-shell-hq-toggle-refresh))
             (message "Label: %s" label))
         (message "Could not generate label for %s" (buffer-name shell-buf)))))))

(defun agent-shell-hq-toggle-refresh ()
  "Re-render the sidebar to pick up new or killed agent-shell buffers."
  (interactive)
  (agent-shell-hq-toggle--render)
  (setq agent-shell-hq-toggle--current-idx
        (min agent-shell-hq-toggle--current-idx
             (max 0 (1- (length agent-shell-hq-toggle--entries)))))
  (agent-shell-hq-toggle--highlight agent-shell-hq-toggle--current-idx)
  (agent-shell-hq-toggle--preview-current))

(defun agent-shell-hq-toggle-new-shell ()
  "Launch a new agent-shell and show it in the main window."
  (interactive)
  (when (window-live-p agent-shell-hq-toggle--main-window)
    (select-window agent-shell-hq-toggle--main-window)
    (agent-shell-new-shell)
    (when-let ((sidebar-win (get-buffer-window agent-shell-hq-toggle--sidebar-name)))
      (select-window sidebar-win)
      (agent-shell-hq-toggle-refresh))))

;;;; Help transient

(transient-define-prefix agent-shell-hq-toggle-help ()
  "Keybindings for the agent-shell-hq sidebar."
  [["Navigate"
    ("n" "next entry"          agent-shell-hq-toggle-next)
    ("p" "previous entry"      agent-shell-hq-toggle-prev)]
   ["Actions"
    ("RET" "select / collapse" agent-shell-hq-toggle-select)
    ("TAB" "collapse / expand" agent-shell-hq-toggle-collapse)
    ("r"   "label session"     agent-shell-hq-toggle-label-current)
    ("g"   "refresh list"      agent-shell-hq-toggle-refresh)
    ("s"   "new shell"         agent-shell-hq-toggle-new-shell)]
   ["Quit"
    ("q"   "quit workspace"    agent-shell-hq-toggle)
    ("?"   "this help"         agent-shell-hq-toggle-help)]])

;; Top-level define-key calls so these bindings are updated on every
;; reload (defvar only initialises the keymap on first load).
(define-key agent-shell-hq-toggle-map (kbd "r") #'agent-shell-hq-toggle-label-current)
(define-key agent-shell-hq-toggle-map (kbd "?") #'agent-shell-hq-toggle-help)

;;;; Workspace setup / teardown

(defun agent-shell-hq-toggle--setup ()
  "Build the sidebar + main window layout."
  (delete-other-windows)
  (let ((sidebar-win
         (display-buffer-in-side-window
          (get-buffer-create agent-shell-hq-toggle--sidebar-name)
          `((side          . left)
            (window-width  . ,agent-shell-hq-toggle-sidebar-width)
            (window-parameters . ((no-delete-other-windows . t)))))))
    (setq agent-shell-hq-toggle--main-window
          (car (seq-filter (lambda (w) (not (eq w sidebar-win)))
                           (window-list)))))
  (setq agent-shell-hq-toggle--current-idx 0
        agent-shell-hq-toggle--collapsed    nil)
  (agent-shell-hq-toggle--render)
  (agent-shell-hq-toggle--highlight 0)
  (agent-shell-hq-toggle--preview-current)
  (select-window (get-buffer-window agent-shell-hq-toggle--sidebar-name)))

(defun agent-shell-hq-toggle--teardown ()
  "Clean up sidebar window and state."
  (when-let ((sidebar-win (get-buffer-window agent-shell-hq-toggle--sidebar-name)))
    (delete-window sidebar-win))
  (setq agent-shell-hq-toggle--prev-persp    nil
        agent-shell-hq-toggle--entries       nil
        agent-shell-hq-toggle--current-idx   0
        agent-shell-hq-toggle--collapsed     nil
        agent-shell-hq-toggle--main-window   nil))

;;;; Entry point

;;;###autoload
(defun agent-shell-hq-toggle ()
  "Toggle the agent-shell HQ workspace.

Opens a dedicated perspective with a sidebar listing all agent-shell
buffers grouped by project.  Calling again returns to the previous
perspective.

Sidebar keys:
  n/p    navigate and preview
  RET    select buffer / toggle project collapse
  TAB    collapse / expand project group
  g      refresh buffer list
  s      new agent-shell in current project
  q      quit (return to previous perspective)"
  (interactive)
  (if (string= (safe-persp-name (get-current-persp))
               agent-shell-hq-toggle--persp-name)
      (let ((prev agent-shell-hq-toggle--prev-persp))
        (agent-shell-hq-toggle--teardown)
        (when prev
          (persp-switch prev)))
    (setq agent-shell-hq-toggle--prev-persp
          (safe-persp-name (get-current-persp)))
    (persp-switch agent-shell-hq-toggle--persp-name)
    (agent-shell-hq-toggle--setup)))

(provide 'agent-shell-hq-toggle)
;;; agent-shell-hq-toggle.el ends here
