;;; agent-shell-hq.el --- Heads-up display and peek for agent-shell  -*- lexical-binding: t -*-

;; Copyright (C) 2024

;; Author: Sreenivas Venkobarao
;; Package-Requires: ((emacs "29.1") (agent-shell "0.66.1") (persp-mode "2.9"))

;;; Commentary:

;; Umbrella entry point that pulls in all three agent-shell-hq
;; modules (toggle, peek, label) so the package can be loaded and
;; configured as a single unit, e.g. via `use-package'.

;;; Code:

(require 'agent-shell-hq-toggle)

(provide 'agent-shell-hq)
;;; agent-shell-hq.el ends here
