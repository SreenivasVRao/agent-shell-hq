;;; agent-shell-commander-label.el --- Async session labelling for agent-shell-commander  -*- lexical-binding: t -*-

;; Copyright (C) 2024

;; Author: Sreenivas Venkobarao
;; Package-Requires: ((emacs "29.1") (agent-shell "0.1"))

;;; Code:

(require 'agent-shell)
(require 'json)
(require 'url)

;;;; Customization

(defgroup agent-shell-commander-label nil
  "Session labelling for agent-shell-commander."
  :group 'agent-shell-commander-peek)

(defcustom agent-shell-commander-label-use-anthropic nil
  "When non-nil, call the Anthropic REST API directly for labelling.
When nil (default), spawn a hidden temporary shell using the session's
own backend — works for any agent."
  :type 'boolean)

(defcustom agent-shell-commander-label-anthropic-model "claude-haiku-4-5-20251001"
  "Anthropic model used when `agent-shell-commander-label-use-anthropic' is t."
  :type 'string)

(defcustom agent-shell-commander-label-shell-delay 0.5
  "Seconds to wait after starting a hidden shell before submitting.
Increase if your agent backend (e.g. Goose) needs longer to initialise."
  :type 'number)

;;;; Buffer-local label storage

(defvar-local agent-shell-commander-label nil
  "One-line summary label for this agent-shell session.
Nil until `agent-shell-commander-label-generate' resolves.")
(put 'agent-shell-commander-label 'permanent-local t)

;;;; Shared utilities

(defconst agent-shell-commander-label--prompt
  "Summarise this conversation in 6 words or fewer. \
Reply with ONLY the summary — no punctuation, no quotes, no trailing period.\n\n"
  "Preamble used for all label generation prompts.")

(defun agent-shell-commander-label--build-prompt (first-exchange)
  "Return a summarisation prompt from FIRST-EXCHANGE (command . response)."
  (concat agent-shell-commander-label--prompt
          "User: " (string-trim (or (car first-exchange) "")) "\n"
          "Assistant: "
          (let ((resp (string-trim (or (cdr first-exchange) ""))))
            (if (> (length resp) 300)
                (concat (substring resp 0 300) "…")
              resp))))

(defun agent-shell-commander-label--clean (raw)
  "Return a cleaned single-line label from RAW, or nil if blank."
  (when (stringp raw)
    (let ((line (car (split-string (string-trim raw) "\n"))))
      (when (not (string-empty-p line))
        (if (> (length line) 60)
            (concat (substring line 0 57) "…")
          line)))))

(defun agent-shell-commander-label--first-exchange (shell-buf)
  "Return the first (command . response) exchange from SHELL-BUF, or nil."
  (with-current-buffer shell-buf
    (condition-case nil
        (car (shell-maker-history))
      (error nil))))

;;;; Anthropic availability check

(defun agent-shell-commander-label--anthropic-available-p ()
  "Return non-nil if an Anthropic API key is resolvable."
  (and (fboundp 'agent-shell-anthropic-key)
       (stringp (ignore-errors (agent-shell-anthropic-key)))))

;;;; Hidden-shell approach (default, with Anthropic fallback)

(defun agent-shell-commander-label--via-shell (shell-buf callback)
  "Label SHELL-BUF by spinning up a hidden temp session with its own config.
If the hidden shell fails (common with ACP-based backends like Claude CLI),
falls back to `agent-shell-commander-label--via-anthropic' when Anthropic
auth is available.  Calls CALLBACK with the label string or nil."
  (let* ((config (condition-case nil
                     (with-current-buffer shell-buf (shell-maker-local-config))
                   (error nil)))
         (first  (agent-shell-commander-label--first-exchange shell-buf)))
    (unless first
      (funcall callback nil)
      (cl-return-from agent-shell-commander-label--via-shell))
    (if (null config)
        ;; No shell-maker config — go straight to fallback
        (agent-shell-commander-label--shell-fallback shell-buf callback)
      (let* ((prompt   (agent-shell-commander-label--build-prompt first))
             (tmp-name (format " *asc-label:%s*" (buffer-name shell-buf)))
             (tmp-buf  (get-buffer-create tmp-name)))
        (condition-case nil
            (with-current-buffer tmp-buf
              (shell-maker-start config t nil t tmp-name))
          (error
           (when (buffer-live-p tmp-buf) (kill-buffer tmp-buf))
           (agent-shell-commander-label--shell-fallback shell-buf callback)
           (cl-return-from agent-shell-commander-label--via-shell)))
        (run-with-timer
         agent-shell-commander-label-shell-delay nil
         (lambda ()
           (if (not (buffer-live-p tmp-buf))
               (agent-shell-commander-label--shell-fallback shell-buf callback)
             (with-current-buffer tmp-buf
               (condition-case nil
                   (shell-maker-submit
                    :input prompt
                    :on-finished
                    (lambda (_input output success)
                      (when (buffer-live-p tmp-buf)
                        (kill-buffer tmp-buf))
                      (if (and success output)
                          (funcall callback (agent-shell-commander-label--clean output))
                        (agent-shell-commander-label--shell-fallback shell-buf callback))))
                 (error
                  (when (buffer-live-p tmp-buf) (kill-buffer tmp-buf))
                  (agent-shell-commander-label--shell-fallback shell-buf callback)))))))))))

(defun agent-shell-commander-label--shell-fallback (shell-buf callback)
  "Fallback: try Anthropic direct if available, otherwise give up."
  (if (agent-shell-commander-label--anthropic-available-p)
      (progn
        (message "agent-shell-commander-label: hidden shell unavailable, trying Anthropic REST…")
        (agent-shell-commander-label--via-anthropic shell-buf callback))
    (message "agent-shell-commander-label: could not label — \
set agent-shell-commander-label-use-anthropic t for Anthropic sessions")
    (funcall callback nil)))

;;;; Anthropic direct approach

(defun agent-shell-commander-label--anthropic-key ()
  "Return the Anthropic API key, or signal an error."
  (or (and (fboundp 'agent-shell-anthropic-key)
           (agent-shell-anthropic-key))
      (user-error
       "No Anthropic API key found. \
Configure `agent-shell-anthropic-authentication' or disable \
`agent-shell-commander-label-use-anthropic'")))

(defun agent-shell-commander-label--via-anthropic (shell-buf callback)
  "Label SHELL-BUF with a direct call to the Anthropic messages REST API.
Calls CALLBACK with the label string or nil."
  (let* ((first (agent-shell-commander-label--first-exchange shell-buf)))
    (unless first
      (funcall callback nil)
      (cl-return-from agent-shell-commander-label--via-anthropic))
    (let* ((prompt  (agent-shell-commander-label--build-prompt first))
           (api-key (agent-shell-commander-label--anthropic-key))
           (payload (json-encode
                     `(("model"      . ,agent-shell-commander-label-anthropic-model)
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
                     (setq label (agent-shell-commander-label--clean text)))
                 (error nil))))
           (kill-buffer (current-buffer))
           (funcall callback label)))
       nil t))))

;;;; Public API

(defun agent-shell-commander-label-generate (shell-buf callback)
  "Asynchronously generate a one-line label for SHELL-BUF.
Calls CALLBACK with the label string when done, or nil on failure.

Uses the Anthropic REST API directly when
`agent-shell-commander-label-use-anthropic' is non-nil; otherwise
spawns a hidden temporary shell using the session's own backend."
  (if agent-shell-commander-label-use-anthropic
      (agent-shell-commander-label--via-anthropic shell-buf callback)
    (agent-shell-commander-label--via-shell shell-buf callback)))

(defun agent-shell-commander-label-set (shell-buf label)
  "Store LABEL as the session label on SHELL-BUF."
  (when (buffer-live-p shell-buf)
    (with-current-buffer shell-buf
      (setq-local agent-shell-commander-label label))))

(defun agent-shell-commander-label-get (shell-buf)
  "Return the stored label for SHELL-BUF, or nil if none yet."
  (and (buffer-live-p shell-buf)
       (buffer-local-value 'agent-shell-commander-label shell-buf)))

(provide 'agent-shell-commander-label)
;;; agent-shell-commander-label.el ends here
