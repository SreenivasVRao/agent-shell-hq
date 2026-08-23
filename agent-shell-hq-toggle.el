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

;;;; Customization

(defcustom agent-shell-hq-toggle-sidebar-width 50
  "Width of the toggle sidebar in columns."
  :type 'integer
  :group 'agent-shell-hq-peek)

(defcustom agent-shell-hq-toggle-lock-perspective nil
  "When non-nil, restrict the agent-shell workspace to only agent-shell buffers.
While the *agent-shell* perspective is active, `consult-buffer' and other
persp-mode-aware commands only offer agent-shell sessions.
`projectile-find-file' and `project-find-file' are blocked with a message
pointing to `my/agent-shell-share-project-file' and
`my/agent-shell-share-any-file', which continue to work normally."
  :type 'boolean
  :group 'agent-shell-hq-peek)

;;;; Constants

(defconst agent-shell-hq-toggle--persp-name "*agent-shell*")
(defconst agent-shell-hq-toggle--sidebar-name " *agent-shell-hq-sidebar*")

(defconst agent-shell-hq-toggle--hints
  '(("n/p" . "navigate")
    ("RET" . "select")
    ("TAB" . "collapse")
    ("r"   . "label")
    ("R"   . "label all")
    ("K"   . "kill")
    ("g"   . "refresh")
    ("s"   . "new shell")
    ("q"   . "quit"))
  "Key/description pairs shown in the sidebar's bottom hint footer.")

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

(defvar agent-shell-hq-toggle--refresh-timer nil
  "Repeating timer that auto-refreshes the sidebar when buffer states change.")

(defvar agent-shell-hq-toggle--state-snapshot nil
  "Alist of (buffer . state) captured at last render, used to detect state changes.")

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

(defface agent-shell-hq-toggle-hint-key
  '((t :inherit font-lock-constant-face))
  "Face for key names in the sidebar's bottom hint footer.")

(defface agent-shell-hq-toggle-hint-desc
  '((t :inherit shadow))
  "Face for descriptions in the sidebar's bottom hint footer.")

;;;; Keymap

(defvar agent-shell-hq-toggle-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "n")             #'agent-shell-hq-toggle-next)
    (define-key map (kbd "j")             #'agent-shell-hq-toggle-next)
    (define-key map (kbd "p")             #'agent-shell-hq-toggle-prev)
    (define-key map (kbd "k")             #'agent-shell-hq-toggle-prev)
    (define-key map (kbd "RET")           #'agent-shell-hq-toggle-select)
    (define-key map (kbd "TAB")           #'agent-shell-hq-toggle-collapse)
    (define-key map (kbd "r")             #'agent-shell-hq-toggle-label-current)
    (define-key map (kbd "R")             #'agent-shell-hq-toggle-label-all)
    (define-key map (kbd "K")             #'agent-shell-hq-toggle-kill-current)
    (define-key map (kbd "g")             #'agent-shell-hq-toggle-refresh)
    (define-key map (kbd "s")             #'agent-shell-hq-toggle-new-shell)
    (define-key map (kbd "q")             #'agent-shell-hq-toggle)
    (define-key map (kbd "C-g")           #'agent-shell-hq-toggle)
    (define-key map (kbd "<mouse-1>")     #'agent-shell-hq-toggle-mouse-select)
    (define-key map (kbd "<double-mouse-1>") #'agent-shell-hq-toggle-mouse-select-double)
    map)
  "Keymap for the agent-shell-hq toggle sidebar.")

;;;; Mouse commands

(defun agent-shell-hq-toggle-mouse-select (event)
  "Move sidebar selection to the entry clicked by mouse EVENT and preview it."
  (interactive "e")
  (with-current-buffer (get-buffer agent-shell-hq-toggle--sidebar-name)
    (let* ((pos       (posn-point (event-start event)))
           (buf-prop  (when pos (get-text-property pos 'agent-shell-hq-toggle-buffer)))
           (root-prop (when pos (get-text-property pos 'agent-shell-hq-toggle-root))))
      (cond
       (buf-prop
        (when-let ((idx (cl-position-if
                         (lambda (e)
                           (and (eq (plist-get e :type) 'buffer)
                                (eq (plist-get e :buffer) buf-prop)))
                         agent-shell-hq-toggle--entries)))
          (setq agent-shell-hq-toggle--current-idx idx)
          (agent-shell-hq-toggle--highlight idx)
          (agent-shell-hq-toggle--preview-current)))
       (root-prop
        (when-let ((idx (cl-position-if
                         (lambda (e)
                           (and (eq (plist-get e :type) 'project)
                                (equal (plist-get e :root) root-prop)))
                         agent-shell-hq-toggle--entries)))
          (setq agent-shell-hq-toggle--current-idx idx)
          (agent-shell-hq-toggle--highlight idx)))))))

(defun agent-shell-hq-toggle-mouse-select-double (event)
  "Select and focus the sidebar entry double-clicked by mouse EVENT."
  (interactive "e")
  (agent-shell-hq-toggle-mouse-select event)
  (agent-shell-hq-toggle-select))

;;;; Perspective locking

(defun agent-shell-hq-toggle--in-locked-persp-p ()
  "Return non-nil when inside the locked agent-shell perspective."
  (and agent-shell-hq-toggle-lock-perspective
       (string= (safe-persp-name (get-current-persp))
                agent-shell-hq-toggle--persp-name)))

(defun agent-shell-hq-toggle--populate-perspective ()
  "Restrict the current perspective to agent-shell and sidebar buffers.
Removes every other buffer from the perspective so that `consult-buffer'
and other persp-mode-aware pickers only show agent-shell sessions."
  (when agent-shell-hq-toggle-lock-perspective
    (let* ((persp      (get-current-persp))
           (shell-bufs (agent-shell-buffers))
           (sidebar    (get-buffer agent-shell-hq-toggle--sidebar-name))
           (keep       (append shell-bufs
                               (when (buffer-live-p sidebar) (list sidebar)))))
      (dolist (buf (copy-sequence (persp-buffers persp)))
        (unless (memq buf keep)
          (persp-remove-buffer buf persp t t)))
      (dolist (buf shell-bufs)
        (when (buffer-live-p buf)
          (persp-add-buffer buf persp nil t))))))

(defun agent-shell-hq-toggle--block-file-finder (&rest _)
  "Signal a user-error when a file-finder is invoked inside the locked workspace."
  (when (agent-shell-hq-toggle--in-locked-persp-p)
    (user-error
     "Use `my/agent-shell-share-project-file' or \
`my/agent-shell-share-any-file' in the agent-shell workspace")))

(advice-add 'projectile-find-file :before #'agent-shell-hq-toggle--block-file-finder)
(advice-add 'project-find-file    :before #'agent-shell-hq-toggle--block-file-finder)

;;;; Auto-refresh helpers

(defun agent-shell-hq-toggle--capture-states ()
  "Return alist of (buffer . state), sorted by buffer name for stable comparison.
Sorting by name rather than using the raw MRU order from `agent-shell-buffers'
prevents false positives in `agent-shell-hq-toggle--maybe-refresh': buffer
accesses change MRU order but not actual busy/idle/dead state."
  (sort (mapcar (lambda (buf)
                  (cons buf (agent-shell-hq-peek--buffer-state buf)))
                (agent-shell-buffers))
        (lambda (a b) (string< (buffer-name (car a)) (buffer-name (car b))))))

(defun agent-shell-hq-toggle--maybe-refresh ()
  "Re-render the sidebar only when at least one buffer state has changed."
  (when (get-buffer agent-shell-hq-toggle--sidebar-name)
    (let ((current (agent-shell-hq-toggle--capture-states)))
      (unless (equal current agent-shell-hq-toggle--state-snapshot)
        (setq agent-shell-hq-toggle--state-snapshot current)
        (let ((buf (agent-shell-hq-toggle--current-buffer)))
          (agent-shell-hq-toggle--render)
          (agent-shell-hq-toggle--populate-perspective)
          (agent-shell-hq-toggle--restore-idx buf)
          (agent-shell-hq-toggle--highlight agent-shell-hq-toggle--current-idx))))))

;;;; Cursor helpers

(defun agent-shell-hq-toggle--current-buffer ()
  "Return the buffer object for the currently highlighted entry, or nil."
  (when-let ((entry (nth agent-shell-hq-toggle--current-idx
                         agent-shell-hq-toggle--entries)))
    (plist-get entry :buffer)))

(defun agent-shell-hq-toggle--restore-idx (buf)
  "After a re-render, set `agent-shell-hq-toggle--current-idx' to BUF.
If BUF is live and still in the entries list, move to its new position.
Otherwise clamp the old index to the new list length."
  (setq agent-shell-hq-toggle--current-idx
        (or (and (buffer-live-p buf)
                 (cl-position-if (lambda (e)
                                   (and (eq (plist-get e :type) 'buffer)
                                        (eq (plist-get e :buffer) buf)))
                                 agent-shell-hq-toggle--entries))
            (min agent-shell-hq-toggle--current-idx
                 (max 0 (1- (length agent-shell-hq-toggle--entries)))))))

;;;; Rendering

(defun agent-shell-hq-toggle--insert-hint-footer ()
  "Insert the key/hint footer, padded with blank lines so it sits flush
against the bottom of the sidebar window regardless of session count."
  (let* ((win        (get-buffer-window (current-buffer)))
         (used-lines (line-number-at-pos (point)))
         (hint-lines (length agent-shell-hq-toggle--hints))
         (avail      (and win (window-body-height win))))
    (when avail
      (insert (make-string (max 0 (- avail used-lines hint-lines)) ?\n)))
    (dolist (hint agent-shell-hq-toggle--hints)
      (insert " "
              (propertize (car hint) 'face 'agent-shell-hq-toggle-hint-key)
              " "
              (propertize (cdr hint) 'face 'agent-shell-hq-toggle-hint-desc)
              "\n"))))

(defun agent-shell-hq-toggle--render ()
  "Render the sidebar buffer and rebuild the entries list."
  (let ((groups (agent-shell-hq-peek--grouped-buffers)))
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
                        (icon  (agent-shell-hq--icon state))
                        (bname (buffer-name buf)))
                   (push (list :type 'buffer :buffer buf :root root)
                         agent-shell-hq-toggle--entries)
                    (insert (propertize
                             (concat "    "
                                     icon
                                     " "
                                     bname
                                     "\n")
                             'agent-shell-hq-toggle-buffer buf)))))
            (insert "\n")))
        (agent-shell-hq-toggle--insert-hint-footer)
        (setq agent-shell-hq-toggle--entries
              (nreverse agent-shell-hq-toggle--entries))
        (setq buffer-read-only t)
        (setq-local cursor-type nil))
      (use-local-map agent-shell-hq-toggle-map))
    (setq agent-shell-hq-toggle--state-snapshot
          (agent-shell-hq-toggle--capture-states))))

;;;; Highlight + point sync

(defvar agent-shell-hq-toggle--highlight-overlay nil
  "Overlay used to highlight the selected entry in the sidebar.")

(defun agent-shell-hq-toggle--highlight (idx)
  "Highlight entry at IDX and sync point to that line in the sidebar window."
  (with-current-buffer (get-buffer-create agent-shell-hq-toggle--sidebar-name)
    (let ((inhibit-read-only t))
      (unless (overlayp agent-shell-hq-toggle--highlight-overlay)
        (setq agent-shell-hq-toggle--highlight-overlay
              (make-overlay (point-min) (point-min))))
      (let ((ov agent-shell-hq-toggle--highlight-overlay))
        (move-overlay ov (point-min) (point-min))
        (when-let* ((entry (nth idx agent-shell-hq-toggle--entries))
                    (type  (plist-get entry :type))
                    (pos   (if (eq type 'project)
                               (text-property-any (point-min) (point-max)
                                                  'agent-shell-hq-toggle-root
                                                  (plist-get entry :root))
                             (text-property-any (point-min) (point-max)
                                                'agent-shell-hq-toggle-buffer
                                                (plist-get entry :buffer)))))
          (move-overlay ov pos
                        (min (1+ (save-excursion (goto-char pos) (line-end-position)))
                             (point-max)))
          (overlay-put ov 'face 'agent-shell-hq-toggle-selection)
          (goto-char pos)
          (when-let ((win (get-buffer-window (current-buffer))))
            (set-window-point win pos)))))))

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

(defun agent-shell-hq-toggle--navigable-p (entry)
  "Return non-nil when ENTRY should be reachable via n/p navigation.
Buffer entries are always navigable.  Project headers are navigable only
while their group is collapsed, since collapsing removes every buffer
entry underneath them, leaving the header as the sole (and only)
keyboard-reachable way to expand the group again."
  (or (eq (plist-get entry :type) 'buffer)
      (member (plist-get entry :root) agent-shell-hq-toggle--collapsed)))

(defun agent-shell-hq-toggle--step (step)
  "Move the selection by STEP entries, skipping expanded project headers."
  (when agent-shell-hq-toggle--entries
    (let ((len (length agent-shell-hq-toggle--entries))
          (idx agent-shell-hq-toggle--current-idx))
      (catch 'found
        (dotimes (_ len)
          (setq idx (mod (+ idx step) len))
          (when (agent-shell-hq-toggle--navigable-p
                 (nth idx agent-shell-hq-toggle--entries))
            (throw 'found idx))))
      (setq agent-shell-hq-toggle--current-idx idx)
      (agent-shell-hq-toggle--highlight agent-shell-hq-toggle--current-idx)
      (agent-shell-hq-toggle--preview-current))))

(defun agent-shell-hq-toggle-next ()
  "Move to the next session entry and preview it."
  (interactive)
  (agent-shell-hq-toggle--step 1))

(defun agent-shell-hq-toggle-prev ()
  "Move to the previous session entry and preview it."
  (interactive)
  (agent-shell-hq-toggle--step -1))

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
  "Send a rename prompt for the highlighted buffer entry."
  (interactive)
  (when-let* ((entry     (nth agent-shell-hq-toggle--current-idx
                              agent-shell-hq-toggle--entries))
              ((eq (plist-get entry :type) 'buffer))
              (shell-buf (plist-get entry :buffer)))
    (agent-shell-hq-label shell-buf)))

(defun agent-shell-hq-toggle-kill-current ()
  "Kill the highlighted agent-shell session and its associated terminal buffer."
  (interactive)
  (when-let* ((entry     (nth agent-shell-hq-toggle--current-idx
                              agent-shell-hq-toggle--entries))
              ((eq (plist-get entry :type) 'buffer))
              (shell-buf (plist-get entry :buffer)))
    (let ((viewport-buf (agent-shell-hq-peek--preferred-buffer shell-buf)))
      (when (and (buffer-live-p viewport-buf)
                 (not (eq viewport-buf shell-buf)))
        (kill-buffer viewport-buf))
      (when (buffer-live-p shell-buf)
        (kill-buffer shell-buf)))
    (agent-shell-hq-toggle-refresh)))

(defun agent-shell-hq-toggle-label-all ()
  "Sequentially prompt to rename every agent-shell session."
  (interactive)
  (dolist (buf (agent-shell-buffers))
    (agent-shell-hq-label buf)))

(defun agent-shell-hq-toggle-refresh ()
  "Re-render the sidebar to pick up new or killed agent-shell buffers."
  (interactive)
  (let ((buf (agent-shell-hq-toggle--current-buffer)))
    (agent-shell-hq-toggle--render)
    (agent-shell-hq-toggle--populate-perspective)
    (agent-shell-hq-toggle--restore-idx buf)
    (agent-shell-hq-toggle--highlight agent-shell-hq-toggle--current-idx)
    (agent-shell-hq-toggle--preview-current)))

(defun agent-shell-hq-toggle-new-shell ()
  "Launch a new agent-shell and show it in the main window."
  (interactive)
  (when (window-live-p agent-shell-hq-toggle--main-window)
    (let* ((before      (agent-shell-buffers))
           (saved-wconf (current-window-configuration)))
      (with-selected-window agent-shell-hq-toggle--main-window
        (agent-shell-new-shell))
      (set-window-configuration saved-wconf)
      (when-let* ((after    (agent-shell-buffers))
                  (new-buf  (seq-find (lambda (b) (not (memq b before))) after))
                  ((buffer-live-p new-buf)))
        (set-window-buffer agent-shell-hq-toggle--main-window new-buf)))
    (when-let ((sidebar-win (get-buffer-window agent-shell-hq-toggle--sidebar-name)))
      (select-window sidebar-win)
      (agent-shell-hq-toggle-refresh))))

;;;; Workspace setup / teardown

(defun agent-shell-hq-toggle--setup ()
  "Build the sidebar + main window layout."
  (when (window-parameter (selected-window) 'window-side)
    (let ((non-side (seq-find (lambda (w) (not (window-parameter w 'window-side)))
                              (window-list))))
      (when non-side (select-window non-side))))
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
  (agent-shell-hq-toggle--populate-perspective)
  (agent-shell-hq-toggle--highlight 0)
  (agent-shell-hq-toggle--preview-current)
  (select-window (get-buffer-window agent-shell-hq-toggle--sidebar-name))
  (setq agent-shell-hq-toggle--refresh-timer
        (run-with-timer 2 2 #'agent-shell-hq-toggle--maybe-refresh)))

(defun agent-shell-hq-toggle--teardown ()
  "Clean up sidebar window and state."
  (when agent-shell-hq-toggle--refresh-timer
    (cancel-timer agent-shell-hq-toggle--refresh-timer)
    (setq agent-shell-hq-toggle--refresh-timer nil))
  (when-let ((sidebar-win (get-buffer-window agent-shell-hq-toggle--sidebar-name)))
    (delete-window sidebar-win))
  (setq agent-shell-hq-toggle--prev-persp      nil
        agent-shell-hq-toggle--entries         nil
        agent-shell-hq-toggle--current-idx     0
        agent-shell-hq-toggle--collapsed       nil
        agent-shell-hq-toggle--main-window     nil
        agent-shell-hq-toggle--state-snapshot  nil))

;;;; Entry point

;;;###autoload
(defun agent-shell-hq-toggle-jump-to-sidebar ()
  "Jump to the sidebar buffer if it exists, otherwise open the toggle workspace."
  (interactive)
  (if (get-buffer agent-shell-hq-toggle--sidebar-name)
      (if (get-buffer-window agent-shell-hq-toggle--sidebar-name)
          (select-window (get-buffer-window agent-shell-hq-toggle--sidebar-name))
        (agent-shell-hq-toggle))
    (agent-shell-hq-toggle)))

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
  r      label current session
  R      label all sessions
  K      kill current session + terminal
  g      refresh buffer list
  s      new agent-shell in current project
  q      quit (return to previous perspective)"
  (interactive)
  (if (string= (safe-persp-name (get-current-persp))
               agent-shell-hq-toggle--persp-name)
      (let ((prev agent-shell-hq-toggle--prev-persp))
        (when prev (persp-switch prev))
        (agent-shell-hq-toggle--teardown))
    (setq agent-shell-hq-toggle--prev-persp
          (safe-persp-name (get-current-persp)))
    (persp-switch agent-shell-hq-toggle--persp-name)
    (agent-shell-hq-toggle--setup)))

(provide 'agent-shell-hq-toggle)
;;; agent-shell-hq-toggle.el ends here
