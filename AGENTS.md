# AGENTS.md — agent-shell-hq

## What this repo is

An Emacs package (Emacs 29.1+, lexical binding) that provides two UX overlays for managing `agent-shell` buffers across projects:

- **`agent-shell-hq-peek`** — transient posframe buffer switcher
- **`agent-shell-hq-toggle`** — persistent sidebar workspace backed by `persp-mode`
- **`agent-shell-hq-label`** — async session labelling via a configurable external CLI subprocess

All public symbols use the `agent-shell-hq-` prefix; internal helpers use `agent-shell-hq-<module>--` (double dash).

## File map

| File                       | Purpose                                                 |
|----------------------------|---------------------------------------------------------|
| `agent-shell-hq.el`        | Umbrella entry point — `require`s toggle (which pulls in peek + label) |
| `agent-shell-hq-peek.el`   | Posframe switcher — `agent-shell-hq-peek` entry point   |
| `agent-shell-hq-toggle.el` | Sidebar workspace — `agent-shell-hq-toggle` entry point |
| `agent-shell-hq-label.el`  | Async label generation via external CLI subprocess      |
| `SPEC.md`                  | Package specification                                   |
| `posframe-layout.md`       | Notes on posframe positioning                           |

## Dependencies

- `agent-shell` ≥ 0.66.1 (provides `agent-shell-buffers`, `agent-shell-cwd`, `agent-shell--project-name`, `agent-shell-viewport`)
- `posframe` ≥ 1.4 (peek only)
- `persp-mode` ≥ 2.9 (toggle only — hard dependency, no fallback)
- `transient` (toggle help menu)
- `projectile` or `project.el` (either; used via `agent-shell--project-name`)
- Emacs built-ins: `image`

## Key design decisions

**Label generation** shells out to an external CLI (`agent-shell-hq-label-command`, default `("claude" "-p" "--model" "haiku")`) via `make-process`, async, with the prompt passed as the final CLI argument. Context sent to the CLI is the last `agent-shell-hq-label-context-chars` characters of the buffer (default 2000) — taken from the *end*, not the start, because every buffer opens with a fixed welcome banner that alone exceeds the default context window and would otherwise make every title request identical. The reply is trimmed and used verbatim as the new buffer name via `shell-maker-set-buffer-name` (not plain `rename-buffer` — `agent-shell`/`shell-maker` resolve the buffer's process by name, so a plain rename detaches it); any paired viewport buffer is renamed to match.

**Peek posframe** installs an `overriding-terminal-local-map` while active so `C-g` reliably quits regardless of which frame has focus. This map is saved/restored around the posframe lifetime.

**Toggle workspace** uses a named perspective (`*agent-shell*`). Toggle-off switches back to the recorded previous perspective — the workspace perspective is not destroyed.

**SVG icons** are loaded from `icons/` at package load time and cached as Emacs `image` objects keyed by state (`idle`, `busy`, `dead`). Icons are regenerated on state change, not on a timer. Buffer state is derived from `shell-maker-busy`.

**Buffer grouping** — `agent-shell-hq-peek--grouped-buffers` returns `(root project-name buffers)` triples sorted alphabetically by project name, with buffers within each group also sorted alphabetically by buffer name.

## Conventions

- `agent-shell-hq-peek` and `agent-shell-hq-label` each define their own `defgroup` (children of `agent-shell`); `agent-shell-hq-toggle`'s `defcustom`s reuse the `agent-shell-hq-peek` group rather than defining a new one.
- Internal state variables are `defvar` at file top-level; they hold the live UI state for the active posframe or sidebar.
- Peek refreshes via `post-command-hook` while visible; toggle refreshes explicitly (`agent-shell-hq-toggle-refresh`, e.g. after labelling) and also via a 2s repeating timer (`agent-shell-hq-toggle--refresh-timer`) that re-renders only when a buffer's idle/busy/dead state actually changed, restoring the selected buffer's position afterward.

## When making changes

- **Adding a new module**: follow the `agent-shell-hq-<module>.el` naming pattern; `require` it from `agent-shell-hq-toggle.el` or whichever consumer needs it.
- **Changing buffer grouping logic**: the shared function is `agent-shell-hq-peek--grouped-buffers` in `agent-shell-hq-peek.el`; both peek and toggle call it.
- **Changing SVG icons**: icons live in `icons/` as `idle.svg`, `busy.svg`, `dead.svg`. The cache is populated lazily on first use.
- **Changing the titling model/CLI**: update the `agent-shell-hq-label-command` default in `agent-shell-hq-label.el`.
- **Keymap changes**: peek keys are in `agent-shell-hq-peek-map`; toggle keys are in `agent-shell-hq-toggle-map`. The transient help menu (`agent-shell-hq-toggle-help`) must be kept in sync with the keymap manually.
- **Testing**: load the file in a running Emacs with `agent-shell` active and exercise the entry points interactively. There is no automated test suite.
