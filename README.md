# agent-shell-hq

This project is actively maintained! I use it everyday - contributions welcome! :)
An add-on to [agent-shell](https://github.com/xenodium/agent-shell) that provides heads-up display and peek features for managing multiple agent-shell sessions.

## Features

### HQ Toggle (heads-up display)

`M-x agent-shell-hq-toggle` opens a dedicated workspace with a sidebar listing all your agent-shell buffers grouped by project. Each buffer shows a live status icon (idle/busy/dead). Navigating the sidebar immediately previews the selected buffer in the main window.

Calling `agent-shell-hq-toggle` again returns you to your previous workspace.

**Sidebar keys:**

| Key       | Action                             |
|-----------|------------------------------------|
| `n` / `j` | Next entry, preview buffer         |
| `p` / `k` | Previous entry, preview buffer     |
| `RET`     | Focus selected buffer              |
| `TAB`     | Collapse / expand project group    |
| `r`       | Label (rename) session             |
| `g`       | Refresh buffer list                |
| `s`       | New agent-shell in project         |
| `q`       | Quit, return to previous workspace |
| `?`       | Show keybinding help               |

Mouse clicks and double-clicks are also supported.

### Peek

`M-x agent-shell-hq-peek` overlays a posframe listing all agent-shell buffers without leaving your current state. As you navigate the list, the buffer behind the posframe updates live so you can glance at any session. Selecting a buffer switches to it; quitting restores your original buffer.

**Peek keys:**

| Key             | Action                   |
|-----------------|--------------------------|
| `n` / `j`       | Next entry, preview      |
| `p` / `k`       | Previous entry, preview  |
| `RET`           | Select buffer            |
| `s`             | New agent-shell          |
| `q` / `C-g`     | Quit, restore buffer     |

### Label

`M-x agent-shell-hq-label` titles the current session. It takes the most
recent `agent-shell-hq-label-context-chars` characters of the buffer (the
tail, not the head — the start of every buffer is a fixed welcome banner
that's identical across sessions and would otherwise dominate the context),
sends them to an external CLI as a prompt, and renames the buffer to
whatever the CLI prints back.

The rename itself goes through `shell-maker-set-buffer-name` rather than
plain `rename-buffer`, since `agent-shell`/`shell-maker` resolve the
buffer's underlying process by name — renaming any other way would detach
it. Any paired viewport buffer is renamed to match, and the sidebar
refreshes automatically afterward.

The titling command is fully configurable — any CLI that reads a prompt as
its last argument works:

```elisp
;; default
(setq agent-shell-hq-label-command '("claude" "-p" "--model" "haiku"))

;; llm (https://llm.datasette.io)
(setq agent-shell-hq-label-command '("llm"))

;; ollama
(setq agent-shell-hq-label-command '("ollama" "run" "llama3.2"))
```

## Requirements

- Emacs 29.1+
- [agent-shell](https://github.com/xenodium/agent-shell) 0.66.1+
- [posframe](https://github.com/tumashu/posframe) 1.4+ (for peek)
- [persp-mode](https://github.com/Bad-ptr/persp-mode.el) 2.9+ (for toggle)
- [transient](https://github.com/magit/transient) (for the help menu)

## Installation

### Vanilla Emacs

Clone this repo and add the directory to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/agent-shell-hq")
(require 'agent-shell-hq-toggle)
(require 'agent-shell-hq-peek)
```

Bind the entry points to keys of your choice:

```elisp
(global-set-key (kbd "C-c a h") #'agent-shell-hq-toggle)
(global-set-key (kbd "C-c a p") #'agent-shell-hq-peek)
```

### Doom Emacs

In `packages.el`:

```elisp
(package! agent-shell-hq
  :recipe (:host nil :repo "https://github.com/YOUR-USERNAME/agent-shell-hq"
           :files ("*.el")))
```

In `config.el`:

```elisp
(use-package! agent-shell-hq-toggle
  :commands agent-shell-hq-toggle
  :custom
  ;; Width of the sidebar listing agent-shell buffers (columns)
  (agent-shell-hq-toggle-sidebar-width 50)
  :bind
  ("C-c a h" . agent-shell-hq-toggle))

(use-package! agent-shell-hq-peek
  :commands agent-shell-hq-peek
  :custom
  ;; Where the peek posframe is anchored: top, bottom, left, right
  (agent-shell-hq-peek-position 'right)
  ;; Width of the peek posframe (columns)
  (agent-shell-hq-peek-width 52)
  ;; Maximum height of the peek posframe (rows)
  (agent-shell-hq-peek-height 60)
  :bind
  ("C-c a p" . agent-shell-hq-peek))

(use-package! agent-shell-hq-label
  :commands agent-shell-hq-label
  :custom
  ;; CLI command that receives the prompt as its final argument
  (agent-shell-hq-label-command '("claude" "-p" "--model" "haiku"))
  ;; Characters of buffer content (from the end) used as context for the title
  (agent-shell-hq-label-context-chars 2000)
  ;; Prompt template sent to the command (%s = buffer context)
  (agent-shell-hq-label-prompt
   "Reply with ONLY a terse 8-10 word title for this conversation, lowercase, no punctuation:\n\n%s"))
```
