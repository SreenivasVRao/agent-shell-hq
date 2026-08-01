;;; agent-shell-commander-toggle.el --- Perspective workspace for agent-shell  -*- lexical-binding: t -*-

;; Copyright (C) 2024

;; Author: Sreenivas Venkobarao
;; Package-Requires: ((emacs "29.1") (agent-shell "0.1") (persp-mode "2.9"))

;;; Code:

(require 'agent-shell)
(require 'agent-shell-viewport)
(require 'agent-shell-commander-peek)
(require 'persp-mode)

;;;; Customization

(defcustom agent-shell-commander-toggle-sidebar-width 36
  "Width of the toggle sidebar in columns."
  :type 'integer
  :group 'agent-shell-commander-peek)

;;;; Constants

(defconst agent-shell-commander-toggle--persp-name "*agent-shell*")
(defconst agent-shell-commander-toggle--sidebar-name " *agent-shell-commander-sidebar*")

;;;; Internal state

(defvar agent-shell-commander-toggle--prev-persp nil
  "Perspective name to return to on toggle-off.")

(defvar agent-shell-commander-toggle--entries nil
  "Flat selectable entries: each a plist (:buffer SHELL-BUF :root ROOT).")

(defvar agent-shell-commander-toggle--current-idx 0
  "Index of the highlighted entry.")

(defvar agent-shell-commander-toggle--collapsed nil
  "List of project roots currently collapsed.")

(defvar agent-shell-commander-toggle--main-window nil
  "The main content window in the toggle workspace.")

;;;; Faces

(defface agent-shell-commander-toggle-project
  '((t :inherit agent-shell-commander-peek-project))
  "Face for project headers in the toggle sidebar.")

;;;; Keymap

(defvar agent-shell-commander-toggle-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "n")   #'agent-shell-commander-toggle-next)
    (define-key map (kbd "j")   #'agent-shell-commander-toggle-next)
    (define-key map (kbd "p")   #'agent-shell-commander-toggle-prev)
    (define-key map (kbd "k")   #'agent-shell-commander-toggle-prev)
    (define-key map (kbd "RET") #'agent-shell-commander-toggle-select)
    (define-key map (kbd "TAB") #'agent-shell-commander-toggle-collapse)
    (define-key map (kbd "g")   #'agent-shell-commander-toggle-refresh)
    (define-key map (kbd "s")   #'agent-shell-commander-toggle-new-shell)
    (define-key map (kbd "q")   #'agent-shell-commander-toggle)
    (define-key map (kbd "C-g") #'agent-shell-commander-toggle)
    map)
  "Keymap for the agent-shell-commander toggle sidebar.")

;;;; Rendering

(defun agent-shell-commander-toggle--render ()
  "Render the sidebar buffer and rebuild the entries list."
  (let ((groups (agent-shell-commander-peek--grouped-buffers
                 (ignore-errors (agent-shell-cwd)))))
    (with-current-buffer (get-buffer-create agent-shell-commander-toggle--sidebar-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq agent-shell-commander-toggle--entries nil)
        (insert "\n")
        (dolist (group groups)
          (let* ((root      (car   group))
                 (pname     (cadr  group))
                 (bufs      (caddr group))
                 (collapsed (member root agent-shell-commander-toggle--collapsed)))
            ;; project header with collapse indicator
            (insert (propertize
                     (concat "  " (if collapsed "▸ " "▾ ") pname "\n")
                     'face 'agent-shell-commander-toggle-project
                     'agent-shell-commander-toggle-root root))
            (unless collapsed
              (dolist (buf bufs)
                (let* ((state (agent-shell-commander-peek--buffer-state buf))
                       (icon  (agent-shell-commander-peek--svg-icon state))
                       (bname (buffer-name buf)))
                  (push (list :buffer buf :root root)
                        agent-shell-commander-toggle--entries)
                  (insert (propertize
                           (concat "      "
                                   (propertize " " 'display icon)
                                   " "
                                   bname
                                   "\n")
                           'face 'default
                           'agent-shell-commander-toggle-buffer buf)))))
            (insert "\n")))
        (insert (propertize "  n/p  navigate   RET  select\n" 'face 'shadow))
        (insert (propertize "  TAB  collapse     g  refresh\n" 'face 'shadow))
        (insert (propertize "    s  new shell     q  quit\n"   'face 'shadow))
        (insert "\n")
        (setq agent-shell-commander-toggle--entries
              (nreverse agent-shell-commander-toggle--entries))
        (setq buffer-read-only t))
      (use-local-map agent-shell-commander-toggle-map))))

;;;; Highlight

(defun agent-shell-commander-toggle--highlight (idx)
  "Highlight the entry at IDX, clearing all others."
  (with-current-buffer (get-buffer-create agent-shell-commander-toggle--sidebar-name)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (when (get-text-property (point) 'agent-shell-commander-toggle-buffer)
            (put-text-property (point)
                               (min (1+ (line-end-position)) (point-max))
                               'face 'default))
          (forward-line 1)))
      (when-let* ((entry (nth idx agent-shell-commander-toggle--entries))
                  (buf   (plist-get entry :buffer))
                  (pos   (text-property-any (point-min) (point-max)
                                            'agent-shell-commander-toggle-buffer buf)))
        (put-text-property pos
                           (min (1+ (save-excursion
                                      (goto-char pos)
                                      (line-end-position)))
                                (point-max))
                           'face 'highlight)))))

;;;; Preview

(defun agent-shell-commander-toggle--preview-current ()
  "Show the highlighted buffer in the main window."
  (when-let* ((entry     (nth agent-shell-commander-toggle--current-idx
                              agent-shell-commander-toggle--entries))
              (shell-buf (plist-get entry :buffer))
              (disp-buf  (agent-shell-commander-peek--preferred-buffer shell-buf)))
    (when (and (window-live-p agent-shell-commander-toggle--main-window)
               (buffer-live-p disp-buf))
      (set-window-buffer agent-shell-commander-toggle--main-window disp-buf))))

;;;; Commands

(defun agent-shell-commander-toggle-next ()
  "Move to the next entry and preview it."
  (interactive)
  (when agent-shell-commander-toggle--entries
    (setq agent-shell-commander-toggle--current-idx
          (mod (1+ agent-shell-commander-toggle--current-idx)
               (length agent-shell-commander-toggle--entries)))
    (agent-shell-commander-toggle--highlight agent-shell-commander-toggle--current-idx)
    (agent-shell-commander-toggle--preview-current)))

(defun agent-shell-commander-toggle-prev ()
  "Move to the previous entry and preview it."
  (interactive)
  (when agent-shell-commander-toggle--entries
    (setq agent-shell-commander-toggle--current-idx
          (mod (1- agent-shell-commander-toggle--current-idx)
               (length agent-shell-commander-toggle--entries)))
    (agent-shell-commander-toggle--highlight agent-shell-commander-toggle--current-idx)
    (agent-shell-commander-toggle--preview-current)))

(defun agent-shell-commander-toggle-select ()
  "Move focus to the highlighted buffer in the main window."
  (interactive)
  (agent-shell-commander-toggle--preview-current)
  (when (window-live-p agent-shell-commander-toggle--main-window)
    (select-window agent-shell-commander-toggle--main-window)))

(defun agent-shell-commander-toggle-collapse ()
  "Collapse or expand the project group at point or current entry's project."
  (interactive)
  (let ((root (or (get-text-property (line-beginning-position)
                                     'agent-shell-commander-toggle-root)
                  (when-let ((entry (nth agent-shell-commander-toggle--current-idx
                                         agent-shell-commander-toggle--entries)))
                    (plist-get entry :root)))))
    (when root
      (if (member root agent-shell-commander-toggle--collapsed)
          (setq agent-shell-commander-toggle--collapsed
                (delete root agent-shell-commander-toggle--collapsed))
        (push root agent-shell-commander-toggle--collapsed))
      (agent-shell-commander-toggle--render)
      (setq agent-shell-commander-toggle--current-idx
            (min agent-shell-commander-toggle--current-idx
                 (max 0 (1- (length agent-shell-commander-toggle--entries)))))
      (agent-shell-commander-toggle--highlight
       agent-shell-commander-toggle--current-idx))))

(defun agent-shell-commander-toggle-refresh ()
  "Re-render the sidebar to pick up new or killed agent-shell buffers."
  (interactive)
  (agent-shell-commander-toggle--render)
  (setq agent-shell-commander-toggle--current-idx
        (min agent-shell-commander-toggle--current-idx
             (max 0 (1- (length agent-shell-commander-toggle--entries)))))
  (agent-shell-commander-toggle--highlight agent-shell-commander-toggle--current-idx)
  (agent-shell-commander-toggle--preview-current))

(defun agent-shell-commander-toggle-new-shell ()
  "Launch a new agent-shell and show it in the main window."
  (interactive)
  (when (window-live-p agent-shell-commander-toggle--main-window)
    (select-window agent-shell-commander-toggle--main-window)
    (agent-shell-new-shell)
    (when-let ((sidebar-win (get-buffer-window agent-shell-commander-toggle--sidebar-name)))
      (select-window sidebar-win)
      (agent-shell-commander-toggle-refresh))))

;;;; Workspace setup

(defun agent-shell-commander-toggle--setup ()
  "Build the sidebar + main window layout."
  (delete-other-windows)
  (let ((sidebar-win
         (display-buffer-in-side-window
          (get-buffer-create agent-shell-commander-toggle--sidebar-name)
          `((side          . left)
            (window-width  . ,agent-shell-commander-toggle-sidebar-width)
            (window-parameters . ((no-delete-other-windows . t)))))))
    (setq agent-shell-commander-toggle--main-window
          (car (seq-filter (lambda (w) (not (eq w sidebar-win)))
                           (window-list)))))
  (setq agent-shell-commander-toggle--current-idx 0
        agent-shell-commander-toggle--collapsed    nil)
  (agent-shell-commander-toggle--render)
  (agent-shell-commander-toggle--highlight 0)
  (agent-shell-commander-toggle--preview-current)
  (select-window (get-buffer-window agent-shell-commander-toggle--sidebar-name)))

(defun agent-shell-commander-toggle--teardown ()
  "Clean up sidebar window and state."
  (when-let ((sidebar-win (get-buffer-window agent-shell-commander-toggle--sidebar-name)))
    (delete-window sidebar-win))
  (setq agent-shell-commander-toggle--prev-persp    nil
        agent-shell-commander-toggle--entries       nil
        agent-shell-commander-toggle--current-idx   0
        agent-shell-commander-toggle--collapsed     nil
        agent-shell-commander-toggle--main-window   nil))

;;;; Entry point

;;;###autoload
(defun agent-shell-commander-toggle ()
  "Toggle the agent-shell commander workspace.

Opens a dedicated perspective with a sidebar listing all agent-shell
buffers grouped by project.  Calling again returns to the previous
perspective.

Sidebar keys:
  n/p    navigate and preview
  RET    move focus to main window
  TAB    collapse / expand project group
  g      refresh buffer list
  s      new agent-shell in current project
  q      quit (return to previous perspective)"
  (interactive)
  (if (string= (safe-persp-name (get-current-persp))
               agent-shell-commander-toggle--persp-name)
      (let ((prev agent-shell-commander-toggle--prev-persp))
        (agent-shell-commander-toggle--teardown)
        (when prev
          (persp-switch prev)))
    (setq agent-shell-commander-toggle--prev-persp
          (safe-persp-name (get-current-persp)))
    (persp-switch agent-shell-commander-toggle--persp-name)
    (agent-shell-commander-toggle--setup)))

(provide 'agent-shell-commander-toggle)
;;; agent-shell-commander-toggle.el ends here
