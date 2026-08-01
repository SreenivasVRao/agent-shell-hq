;;; agent-shell-hq-label.el --- Session labelling for agent-shell-hq  -*- lexical-binding: t -*-

;; Copyright (C) 2024

;; Author: Sreenivas Venkobarao
;; Package-Requires: ((emacs "29.1") (agent-shell "0.66.1"))

;;; Code:

(require 'agent-shell)

;;;; Customization

(defgroup agent-shell-hq-label nil
  "Auto-titling for agent-shell-hq sessions."
  :group 'agent-shell
  :prefix "agent-shell-hq-label-")

(defcustom agent-shell-hq-label-command '("claude" "-p" "--model" "haiku")
  "Command and arguments for the titling subprocess.
The prompt text is appended as the final argument.

Examples:
  \\='(\"claude\" \"-p\" \"--model\" \"haiku\")
  \\='(\"llm\")
  \\='(\"ollama\" \"run\" \"llama3.2\")"
  :type '(repeat string))

(defcustom agent-shell-hq-label-context-chars 2000
  "Characters of buffer content sent as context to the titler.
Taken from the end of the buffer, since the start is always the
static welcome banner (which alone can exceed this many characters)."
  :type 'integer)

(defcustom agent-shell-hq-label-prompt
  "Reply with ONLY a terse 8-10 word title for this conversation, \
lowercase, no punctuation:\n\n%s"
  "Format string for the titling prompt.
%s is replaced with the buffer context."
  :type 'string)

;;;; Public API

;;;###autoload
(defun agent-shell-hq-label (&optional shell-buf)
  "Auto-title SHELL-BUF by passing its content to `agent-shell-hq-label-command'.
When called interactively, resolves the shell buffer from any agent-shell context."
  (interactive)
  (let* ((buf (or shell-buf
                  (agent-shell--shell-buffer :no-create t :no-error t)
                  (user-error "No agent-shell buffer found")))
         (context (with-current-buffer buf
                    (buffer-substring-no-properties
                     (max (point-min)
                          (- (point-max) agent-shell-hq-label-context-chars))
                     (point-max))))
         (prompt (format agent-shell-hq-label-prompt context))
         (output ""))
    (message "agent-shell-hq-label: labeling %s…" (buffer-name buf))
    (let ((proc (make-process
                 :name       "agent-shell-hq-label"
                 :buffer     nil
                 :command    (append agent-shell-hq-label-command (list prompt))
                 :connection-type 'pipe
                 :filter   (lambda (_proc chunk)
                             (setq output (concat output chunk)))
                 :sentinel (lambda (_proc event)
                             (when (string-prefix-p "finished" event)
                               (let ((title (string-trim output)))
                                 (when (and (buffer-live-p buf) (> (length title) 0))
                                   ;; `rename-buffer' alone leaves the buffer detached from
                                   ;; its process: shell-maker resolves buffer/process via
                                   ;; `shell-maker-buffer-name', which only respects the new
                                   ;; name if `shell-maker--buffer-name-override' is updated.
                                   (let ((old-viewport
                                          (get-buffer (concat (buffer-name buf) " [viewport]"))))
                                     (shell-maker-set-buffer-name buf title)
                                     (when (buffer-live-p old-viewport)
                                       (with-current-buffer old-viewport
                                         (rename-buffer (concat title " [viewport]") t))))
                                   (message "agent-shell-hq-label: labeled %s" title)
                                   (when (fboundp 'agent-shell-hq-toggle-refresh)
                                     (agent-shell-hq-toggle-refresh)))))))))
      ;; Close stdin immediately so the subprocess doesn't wait for piped input.
      (process-send-eof proc))))

(provide 'agent-shell-hq-label)
;;; agent-shell-hq-label.el ends here
