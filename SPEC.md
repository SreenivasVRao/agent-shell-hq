# agent-shell-hq — Package Specification

## Overview

`agent-shell-hq` is an Emacs package that provides two complementary UX experiences for navigating and managing `agent-shell` buffers across projects. It builds on top of the existing `agent-shell` package and its `agent-shell-buffers` / `agent-shell-project-buffers` APIs.

Both experiences share:
- Project-grouped buffer listings (via `projectile` or `project.el`)
- SVG-based status indicators (processing / waiting-for-input)
- Buffer preview that preserves the buffer's major mode (`agent-shell-mode`, `agent-shell-viewport-view-mode`, `agent-shell-viewport-edit-mode`)

**Resolved decisions:**
- Peek preview: posframe is list-only; the invoking buffer stays visible behind it naturally
- Perspective: hard dependency on `persp-mode`; no wconf fallback
- Sidebar: plain side window with custom keymap (not Treemacs)

---

## 1. `agent-shell-hq-peek`

A transient posframe / childframe switcher that floats over the current frame.

### 1.1 Invocation

```
M-x agent-shell-hq-peek
```

Displays a posframe positioned relative to the current frame. Position is controlled by the customizable variable `agent-shell-hq-peek-position`, one of: `'top`, `'bottom`, `'left`, `'right`. Defaults to `'right`.

### 1.2 Layout

```
+------------------------------------+
|                                    |
|   Project 1                        |
|    ● agent-shell-buffer-1          |
|    ○ agent-shell-buffer-2          |
|    ○ agent-shell-buffer-3          |
|                                    |
|   Project 2                        |
|    ● agent-shell-buffer-4          |
|    ○ agent-shell-buffer-5          |
|                                    |
|                                    |
| n/p  navigate    RET  select       |
| g    quit                          |
+------------------------------------+
```

The buffer that was active when `agent-shell-hq-peek` was invoked remains visible behind the posframe, providing natural context. No preview pane is embedded inside the posframe.

- **Project headers** — bold face, derived from projectile project name or `project-name` via `agent-shell--project-name`.
- **Buffer entries** — indented under their project. Cursor line highlighted.
- **Status indicator** — SVG icon prefixed to each buffer entry (see §3).

### 1.3 Data model

Buffers are collected via `(agent-shell-buffers)` then grouped by project root (using `agent-shell-cwd` for each buffer). The current project's group is shown first. Within each group, buffers are ordered by recency (as returned by `agent-shell-buffers`).

### 1.4 Keybindings (inside posframe)

| Key               | Action                                           |
|-------------------|--------------------------------------------------|
| `n` / `j`         | Move to next buffer entry                        |
| `p` / `k`         | Move to previous buffer entry                    |
| `RET`             | Select buffer (close posframe, switch to buffer) |
| `g` / `q` / `ESC` | Dismiss posframe                                 |
| `s`               | Launch new agent-shell in current project        |

### 1.5 Posframe sizing

- Width: `agent-shell-hq-peek-width` (default: 52 columns)
- Height: fit-to-content up to `agent-shell-hq-peek-height` (default: 60 rows)
- Position: anchored to `agent-shell-hq-peek-position` edge of the selected frame

### 1.6 Dependencies

- `posframe`
- `agent-shell`
- `projectile` or `project.el` (whichever is active)
- `svg` (built-in, Emacs 27+)

---

## 2. `agent-shell-hq-toggle`

A persistent workspace / perspective-based experience with a sidebar.

### 2.1 Invocation

```
M-x agent-shell-hq-toggle
```

Toggles the agent-shell-hq workspace. First call creates/shows it; second call hides it (returns to the prior perspective). Implemented as a named perspective (`*agent-shell*`) using `persp-mode`.

### 2.2 Layout

```
+------------------+-----------------------------------+
| SIDEBAR          |  MAIN AGENT-SHELL BUFFER          |
|                  |                                   |
| ▾ Project 1      |  [agent-shell-mode content]       |
|   ● buffer-1     |                                   |
|   ○ buffer-2     |                                   |
|   ○ buffer-3     |                                   |
|                  |                                   |
| ▾ Project 2      |                                   |
|   ● buffer-4     |                                   |
|   ○ buffer-5     |                                   |
|                  |                                   |
| [s] new shell    |                                   |
+------------------+-----------------------------------+
```

- The sidebar is a plain side window with a custom read-only buffer and keymap.
- The main pane shows the currently selected agent-shell buffer.
- Both panes persist across project switches.

### 2.3 Sidebar behavior

- Sidebar entries are backed by `agent-shell-buffers`.
- Project groupings are collapsible (`▸` / `▾`).
- The current buffer's entry is highlighted in the sidebar.
- Sidebar is refreshed manually via `g` or automatically after `s` (new shell).

### 2.4 Navigation and keybindings (sidebar focused)

| Key         | Action                                        |
|-------------|-----------------------------------------------|
| `n` / `j`   | Move to next entry and preview                |
| `p` / `k`   | Move to previous entry and preview            |
| `RET`       | Select buffer / toggle project collapse       |
| `TAB`       | Collapse / expand project group               |
| `r`         | Generate session label for highlighted buffer |
| `g`         | Refresh buffer list                           |
| `s`         | New agent-shell in current project            |
| `q`         | `agent-shell-hq-toggle` (hide workspace)      |
| `?`         | Show keybinding help (transient)              |

### 2.5 Preview behavior

Navigating with `n`/`p` shows the buffer in the main pane but keeps focus in the sidebar. The main pane displays the buffer in its actual mode. Switching focus to the main pane (`C-x o` or mouse) behaves normally — the buffer is live and editable.

### 2.6 Perspective / workspace handling

Hard dependency on `persp-mode`.

- On first invocation: record the current perspective name, create (or switch to) perspective `*agent-shell*`, set up sidebar + main pane.
- On toggle-off: switch back to the recorded previous perspective. The `*agent-shell*` perspective is not destroyed, so re-entering restores full state.
- Buffer-preference: reuse existing agent-shell buffers, never create duplicates.

### 2.7 Dependencies

- `persp-mode` (hard dependency)
- `transient` (help menu)
- `agent-shell`
- `projectile` or `project.el`
- `svg` (built-in)

---

## 3. SVG Status Indicators

Both experiences use the same static SVG icon set. No animation; icons are redrawn only when buffer state changes.

### 3.1 States

| State  | Visual                                 | Meaning                                            |
|--------|----------------------------------------|----------------------------------------------------|
| `busy` | Filled circle with hourglass glyph (⧗) | Agent is processing (`(shell-maker-busy)` non-nil) |
| `idle` | Hollow circle                          | Agent is waiting for input                         |
| `dead` | Filled grey dash                       | Buffer process has exited                          |

Detection logic:
```elisp
(with-current-buffer shell-buf
  (cond
   ((not (buffer-live-p shell-buf)) 'dead)
   ((shell-maker-busy) 'busy)
   (t 'idle)))
```

### 3.2 SVG rendering

Icons are loaded from `icons/` as SVG files using Emacs's built-in `create-image`.
- **Small** (14×14 px) — posframe list entries and sidebar entries

No timer. Icons are loaded lazily on first use and cached. State is checked per-buffer during render.

### 3.3 Icon cache

Icons are cached as `image` objects keyed by `state` — three entries total (`idle`, `busy`, `dead`). Cache is populated lazily on first call to `agent-shell-hq-peek--svg-icon`.

Colors are baked into the SVG files on disk (not derived dynamically from theme faces).

---

## 4. Shared Infrastructure

### 4.1 Buffer grouping

```elisp
(defun agent-shell-hq-peek--grouped-buffers (current-root)
  "Return list of (root project-name buffers) sorted current-project-first."
  ...)
```

Groups `(agent-shell-buffers)` by `(agent-shell-cwd)` per buffer. Current project (from caller's context at invocation time) is placed first; remaining groups sorted alphabetically by project name.

### 4.2 Project display name

Resolved via `agent-shell--project-name` (called inside the buffer), which uses `projectile-project-name` if available, otherwise the directory basename.

### 4.3 Customization group

All variables live under the `agent-shell-hq-peek` customization group, child of `agent-shell`.

Key variables:

| Variable                             | Type    | Default  | Description                  |
|--------------------------------------|---------|----------|------------------------------|
| `agent-shell-hq-peek-position`       | symbol  | `'right` | Posframe anchor edge         |
| `agent-shell-hq-peek-width`          | integer | 52       | Posframe width in columns    |
| `agent-shell-hq-peek-height`         | integer | 60       | Posframe max height in rows  |
| `agent-shell-hq-toggle-sidebar-width`| integer | 36       | Sidebar width in columns     |

---

## 5. File Structure

```
agent-shell-hq/
├── agent-shell-hq-peek.el    ; posframe switcher, shared buffer grouping
├── agent-shell-hq-toggle.el  ; sidebar workspace
├── agent-shell-hq-label.el   ; async session labelling via Anthropic REST API
├── icons/                    ; idle.svg, busy.svg, dead.svg
└── SPEC.md                   ; this file
```
