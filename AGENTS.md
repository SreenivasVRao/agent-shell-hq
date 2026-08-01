# AGENTS.md — agent-shell-hq

## What this repo is

An Emacs package (Emacs 29.1+, lexical binding) that provides two UX overlays for managing `agent-shell` buffers across projects:

- **`agent-shell-hq-peek`** — transient posframe buffer switcher
- **`agent-shell-hq-toggle`** — persistent sidebar workspace backed by `persp-mode`
- **`agent-shell-hq-label`** — async session labelling via the Anthropic REST API

All public symbols use the `agent-shell-hq-` prefix; internal helpers use `agent-shell-hq-<module>--` (double dash).

## File map

| File                       | Purpose                                                 |
|----------------------------|---------------------------------------------------------|
| `agent-shell-hq-peek.el`   | Posframe switcher — `agent-shell-hq-peek` entry point   |
| `agent-shell-hq-toggle.el` | Sidebar workspace — `agent-shell-hq-toggle` entry point |
| `agent-shell-hq-label.el`  | Async label generation via Anthropic messages API       |
| `SPEC.md`                  | Package specification                                   |
| `posframe-layout.md`       | Notes on posframe positioning                           |

## Dependencies

- `agent-shell` ≥ 0.66.1 (provides `agent-shell-buffers`, `agent-shell-cwd`, `agent-shell--project-name`, `agent-shell-viewport`)
- `posframe` ≥ 1.4 (peek only)
- `persp-mode` ≥ 2.9 (toggle only — hard dependency, no fallback)
- `transient` (toggle help menu)
- `projectile` or `project.el` (either; used via `agent-shell--project-name`)
- Emacs built-ins: `json`, `url`, `svg`

## Key design decisions

**Label generation** uses the Anthropic REST API directly (`url-retrieve`, async). The ACP/CLI subprocess path was tried and abandoned — see the comment block at the top of `agent-shell-hq-label.el`. The API key is fetched via `agent-shell-anthropic-key`. The model is configurable via `agent-shell-hq-label-anthropic-model` (default: `claude-haiku-4-5-20251001`).

**Peek posframe** installs an `overriding-terminal-local-map` while active so `C-g` reliably quits regardless of which frame has focus. This map is saved/restored around the posframe lifetime.

**Toggle workspace** uses a named perspective (`*agent-shell*`). Toggle-off switches back to the recorded previous perspective — the workspace perspective is not destroyed.

**SVG icons** are loaded from `icons/` at package load time and cached as Emacs `image` objects keyed by state (`idle`, `busy`, `dead`). Icons are regenerated on state change, not on a timer. Buffer state is derived from `shell-maker-busy`.

**Buffer grouping** — `agent-shell-hq-peek--grouped-buffers` returns `(root project-name buffers)` triples sorted current-project-first, then alphabetically by project name.

## Conventions

- All `defcustom` variables belong to the `agent-shell-hq-peek` customization group (or its children).
- Buffer-local state on shell buffers uses `defvar-local` with `permanent-local t` (see `agent-shell-hq-label`).
- Internal state variables are `defvar` at file top-level; they hold the live UI state for the active posframe or sidebar.
- No timers — UI is refreshed via `post-command-hook` while visible (peek) or explicit `agent-shell-hq-toggle-refresh` (toggle).

## When making changes

- **Adding a new module**: follow the `agent-shell-hq-<module>.el` naming pattern; `require` it from `agent-shell-hq-toggle.el` or whichever consumer needs it.
- **Changing buffer grouping logic**: the shared function is `agent-shell-hq-peek--grouped-buffers` in `agent-shell-hq-peek.el`; both peek and toggle call it.
- **Changing SVG icons**: icons live in `icons/` as `idle.svg`, `busy.svg`, `dead.svg`. The cache is populated lazily on first use.
- **Changing the Anthropic model**: update `agent-shell-hq-label-anthropic-model` default in `agent-shell-hq-label.el`.
- **Keymap changes**: peek keys are in `agent-shell-hq-peek-map`; toggle keys are in `agent-shell-hq-toggle-map`. The transient help menu (`agent-shell-hq-toggle-help`) must be kept in sync with the keymap manually.
- **Testing**: load the file in a running Emacs with `agent-shell` active and exercise the entry points interactively. There is no automated test suite.
