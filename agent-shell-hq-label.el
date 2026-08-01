;;; agent-shell-hq-label.el --- Async session labelling for agent-shell-hq  -*- lexical-binding: t -*-

;; Copyright (C) 2024

;; Author: Sreenivas Venkobarao
;; Package-Requires: ((emacs "29.1") (agent-shell "0.66.1"))

;; The hidden-shell approach was tried and abandoned: agent-shell uses
;; the ACP protocol (Claude CLI subprocess), so shell-maker-start
;; creates an agent-shell-mode buffer that appears in the session list
;; and cannot complete requests without the full agent-shell init flow.
;; The Anthropic REST API is the reliable path for Claude sessions.

;;; Code:

(require 'agent-shell)
(require 'json)
(require 'url)

;;;; Customization

(defgroup agent-shell-hq-label nil
  "Session labelling for agent-shell-hq."
  :group 'agent-shell-hq-peek)

(defcustom agent-shell-hq-label-anthropic-model "claude-haiku-4-5-20251001"
  "Anthropic model used for session label generation."
  :type 'string)

;;;; Buffer-local label storage

(defvar-local agent-shell-hq-label nil
  "One-line summary label for this agent-shell session.
Nil until `agent-shell-hq-label-generate' resolves.")
(put 'agent-shell-hq-label 'permanent-local t)

;;;; Utilities

(defconst agent-shell-hq-label--prompt
  "Summarise this conversation in 6 words or fewer. \
Reply with ONLY the summary — no punctuation, no quotes, no trailing period.\n\n"
  "Preamble for all label generation prompts.")

(defun agent-shell-hq-label--build-prompt (first-exchange)
  "Return a summarisation prompt from FIRST-EXCHANGE (command . response)."
  (concat agent-shell-hq-label--prompt
          "User: " (string-trim (or (car first-exchange) "")) "\n"
          "Assistant: "
          (let ((resp (string-trim (or (cdr first-exchange) ""))))
            (if (> (length resp) 300)
                (concat (substring resp 0 300) "…")
              resp))))

(defun agent-shell-hq-label--clean (raw)
  "Return a cleaned single-line label from RAW, or nil if blank."
  (when (stringp raw)
    (let ((line (car (split-string (string-trim raw) "\n"))))
      (unless (string-empty-p line)
        (if (> (length line) 60)
            (concat (substring line 0 57) "…")
          line)))))

(defun agent-shell-hq-label--first-exchange (shell-buf)
  "Return the first (command . response) from SHELL-BUF, or nil."
  (with-current-buffer shell-buf
    (condition-case nil
        (car (shell-maker-history))
      (error nil))))

(defun agent-shell-hq-label--anthropic-key ()
  "Return the Anthropic API key or signal a user-error."
  (or (and (fboundp 'agent-shell-anthropic-key)
           (ignore-errors (agent-shell-anthropic-key)))
      (user-error
       "No Anthropic API key found — configure `agent-shell-anthropic-authentication'")))

;;;; Anthropic REST API

(defun agent-shell-hq-label--via-anthropic (shell-buf callback)
  "Label SHELL-BUF via a direct async call to the Anthropic messages API.
Calls CALLBACK with the label string or nil."
  (let ((first   (agent-shell-hq-label--first-exchange shell-buf))
        (api-key (condition-case err
                     (agent-shell-hq-label--anthropic-key)
                   (error (message "%s" (error-message-string err)) nil))))
    (if (not (and first api-key))
        (funcall callback nil)
      (let* ((prompt  (agent-shell-hq-label--build-prompt first))
             (payload (json-encode
                       `(("model"      . ,agent-shell-hq-label-anthropic-model)
                         ("max_tokens" . 30)
                         ("messages"   . [((role . "user") (content . ,prompt))]))))
             (url-request-method "POST")
             (url-request-extra-headers
              `(("Content-Type"      . "application/json")
                ("x-api-key"         . ,api-key)
                ("anthropic-version" . "2023-06-01")))
             (url-request-data (encode-coding-string payload 'utf-8)))
        (url-retrieve
         "https://api.anthropic.com/v1/messages"
         (lambda (status)
           (let (label)
             (unless (plist-get status :error)
               (goto-char (point-min))
               (when (re-search-forward "^$" nil t)
                 (condition-case nil
                     (let* ((data    (json-parse-buffer :object-type 'alist))
                            (content (alist-get 'content data))
                            (text    (and (vectorp content)
                                          (> (length content) 0)
                                          (alist-get 'text (aref content 0)))))
                       (setq label (agent-shell-hq-label--clean text)))
                   (error nil))))
             (kill-buffer (current-buffer))
             (funcall callback label)))
         nil t)))))

;;;; Public API

(defun agent-shell-hq-label-generate (shell-buf callback)
  "Asynchronously generate a one-line label for SHELL-BUF.
Calls CALLBACK with the label string when done, or nil on failure."
  (agent-shell-hq-label--via-anthropic shell-buf callback))

(defun agent-shell-hq-label-set (shell-buf label)
  "Store LABEL as the session label on SHELL-BUF."
  (when (buffer-live-p shell-buf)
    (with-current-buffer shell-buf
      (setq-local agent-shell-hq-label label))))

(defun agent-shell-hq-label-get (shell-buf)
  "Return the stored label for SHELL-BUF, or nil if none yet."
  (and (buffer-live-p shell-buf)
       (buffer-local-value 'agent-shell-hq-label shell-buf)))

(provide 'agent-shell-hq-label)
;;; agent-shell-hq-label.el ends here
