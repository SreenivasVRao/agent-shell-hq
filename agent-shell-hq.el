;;; agent-shell-hq.el --- Heads-up display and peek for agent-shell  -*- lexical-binding: t -*-

;; Copyright (C) 2024

;; Author: Sreenivas Venkobarao
;; Package-Requires: ((emacs "29.1") (agent-shell "0.66.1") (persp-mode "2.9"))

;;; Commentary:

;; Umbrella entry point that pulls in all three agent-shell-hq
;; modules (toggle, peek, label) so the package can be loaded and
;; configured as a single unit, e.g. via `use-package'.

;;; Code:

;; These autoload declarations live here (rather than at the real
;; defuns in the submodule files) so that invoking any of these
;; commands loads this umbrella file.

;;;###autoload
(autoload 'agent-shell-hq-peek "agent-shell-hq"
  "Show a posframe listing all agent-shell buffers grouped by project." t)

;;;###autoload
(autoload 'agent-shell-hq-toggle-jump-to-sidebar "agent-shell-hq"
  "Jump to the sidebar buffer if it exists, otherwise open the toggle workspace." t)

;;;###autoload
(autoload 'agent-shell-hq-toggle "agent-shell-hq"
  "Toggle the agent-shell HQ workspace." t)

;;;###autoload
(autoload 'agent-shell-hq-label "agent-shell-hq"
  "Auto-title SHELL-BUF by passing its content to `agent-shell-hq-label-command'." t)

(require 'agent-shell-hq-toggle)
(require 'agent-shell-hq-peek)
(require 'agent-shell-hq-label)

(provide 'agent-shell-hq)
;;; agent-shell-hq.el ends here
