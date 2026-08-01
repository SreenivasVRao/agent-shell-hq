;;; agent-shell-hq-label.el --- Session labelling for agent-shell-hq  -*- lexical-binding: t -*-

;; Copyright (C) 2024

;; Author: Sreenivas Venkobarao
;; Package-Requires: ((emacs "29.1") (agent-shell "0.66.1"))

;;; Code:

(require 'agent-shell)
(require 'shell-maker)

;;;; Prompt

(defun agent-shell-hq-label--rename-prompt (buf-name)
  "Return a rename prompt referencing BUF-NAME."
  (format
   "Please rename this Emacs buffer to reflect our conversation. \
Run exactly: emacsclient -e '(agent-shell-hq-label-handler \"%s\" \"TITLE\")' \
— replace TITLE with a concise, descriptive name (no quotes inside the command). \
No other output needed."
   buf-name))

;;;; Handler

;;;###autoload
(defun agent-shell-hq-label-handler (buf-name title)
  "Rename BUF-NAME to TITLE and refresh the sidebar if loaded.
Intended to be called via emacsclient by the agent."
  (when-let ((buf (get-buffer buf-name)))
    (with-current-buffer buf
      (rename-buffer title t)
      (setq-local shell-maker--buffer-name-override (buffer-name))))
  (when (fboundp 'agent-shell-hq-toggle-refresh)
    (agent-shell-hq-toggle-refresh)))

;;;; Public API

;;;###autoload
(defun agent-shell-hq-label (&optional shell-buf)
  "Insert a buffer-rename prompt into SHELL-BUF and submit it.
When called interactively, resolves the shell buffer from any agent-shell
context (shell buffer, viewport buffer, or project)."
  (interactive)
  (let ((buf (or shell-buf
                 (agent-shell--shell-buffer :no-create t :no-error t)
                 (user-error "No agent-shell buffer found"))))
    (agent-shell--insert-to-shell-buffer
     :text         (agent-shell-hq-label--rename-prompt (buffer-name buf))
     :submit       t
     :shell-buffer buf)))

(provide 'agent-shell-hq-label)
;;; agent-shell-hq-label.el ends here
