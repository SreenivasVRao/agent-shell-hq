# agent-shell-commander — Package Specification

## Overview

`agent-shell-commander` is an Emacs package that provides two complementary UX experiences for navigating and managing `agent-shell` buffers across projects. It builds on top of the existing `agent-shell` package and its `agent-shell-buffers` / `agent-shell-project-buffers` APIs.

Both experiences share:
- Project-grouped buffer listings (via `projectile` or `project.el`)
- SVG-based status indicators (processing / waiting-for-input)
- Buffer preview that preserves the buffer's major mode (`agent-shell-mode`, `agent-shell-viewport-view-mode`, `agent-shell-viewport-edit-mode`)

**Resolved decisions:**
- Peek preview: posframe is list-only; the invoking buffer stays visible behind it naturally
- Perspective: hard dependency on `perspective.el`; no wconf fallback
- Treemacs API: v2 (`-node-type` suffix macros)

---

## 1. `agent-shell-commander-peek`

A transient posframe / childframe switcher that floats over the current frame.

### 1.1 Invocation

```
M-x agent-shell-commander-peek
```

Displays a posframe positioned relative to the current frame. Position is controlled by the customizable variable `agent-shell-commander-peek-position`, one of: `'top`, `'bottom`, `'left`, `'right`. Defaults to `'right`.

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

The buffer that was active when `agent-shell-commander-peek` was invoked remains visible behind the posframe, providing natural context. No preview pane is embedded inside the posframe.

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

- Width: `agent-shell-commander-peek-width` (default: 50 columns)
- Height: fit-to-content up to `agent-shell-commander-peek-height` (default: 40 rows)
- Position: anchored to `agent-shell-commander-peek-position` edge of the selected frame

### 1.6 Dependencies

- `posframe`
- `agent-shell`
- `projectile` or `project.el` (whichever is active)
- `svg` (built-in, Emacs 27+)

---

## 2. `agent-shell-commander-toggle`

A persistent workspace / perspective-based experience with a Treemacs sidebar.

### 2.1 Invocation

```
M-x agent-shell-commander-toggle
```

Toggles the agent-shell commander workspace. First call creates/shows it; second call hides it (restores prior window configuration). Implemented as an ephemeral perspective (using `persp-mode` or `perspective.el`) named `*agent-shell-commander*`, or falling back to a saved window configuration if neither is available.

### 2.2 Layout

```
+------------------+-----------------------------------+
| TREEMACS SIDEBAR |  MAIN AGENT-SHELL BUFFER          |
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

- The sidebar is a dedicated Treemacs buffer (custom node type, not file tree).
- The main pane shows the currently selected agent-shell buffer.
- Both panes persist across project switches.

### 2.3 Sidebar behavior

- Sidebar entries are custom Treemacs nodes backed by `agent-shell-buffers`.
- Project groupings are collapsible Treemacs tree nodes (`▸` / `▾`).
- The current buffer's entry is highlighted / marked in the sidebar.
- Sidebar updates automatically when agent-shell buffers are created or killed (via `kill-buffer-hook` and `agent-shell-mode-hook`).

### 2.4 Navigation and keybindings (sidebar focused)

| Key         | Action                                           |
|-------------|--------------------------------------------------|
| `RET` / `o` | Show buffer in main pane                         |
| `TAB`       | Collapse / expand project group                  |
| `p`         | Preview buffer in main pane without moving focus |
| `s`         | New agent-shell in project at point              |
| `d`         | Kill buffer at point (with confirmation)         |
| `q`         | `agent-shell-commander-toggle` (hide workspace)  |

### 2.5 Preview behavior

Pressing `p` (or navigating with preview mode enabled) shows the buffer in the main pane but keeps focus in the sidebar. The main pane displays the buffer in its actual mode. Switching focus to the main pane (`C-x o` or mouse) behaves normally — the buffer is live and editable.

### 2.6 Perspective / workspace handling

Hard dependency on `perspective.el`.

- On first invocation: record the current perspective name, create (or switch to) perspective `*agent-shell-commander*`, set up sidebar + main pane.
- On toggle-off: switch back to the recorded previous perspective. The `*agent-shell-commander*` perspective is not destroyed, so re-entering restores full state.
- Buffer-preference: reuse existing agent-shell buffers, never create duplicates.

### 2.7 Dependencies

- `treemacs` (v2 node API)
- `perspective.el` (hard dependency)
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

Icons are rendered via `(svg-create WIDTH HEIGHT)` using Emacs's built-in `svg` library.
- **Small** (14×14 px) — posframe list entries and Treemacs sidebar entries

No timer. Icons are regenerated only when state changes for a given buffer, detected via `post-command-hook` while the UI is visible.

### 3.3 Icon cache

Icons are cached as `image` objects keyed by `state` — three entries total. Cache is invalidated on theme change (`enable-theme-functions` hook).

Colors derived from theme faces:
- `busy`: `warning` face foreground
- `idle`: `shadow` face foreground
- `dead`: `error` face foreground

---

## 4. Shared Infrastructure

### 4.1 Buffer grouping

```elisp
(defun agent-shell-commander--grouped-buffers ()
  "Return alist of (project-root . buffer-list) sorted current-project-first."
  ...)
```

Groups `(agent-shell-buffers)` by `(agent-shell-cwd)` per buffer. Current project (from caller's context at invocation time) is placed first.

### 4.2 Project display name

```elisp
(defun agent-shell-commander--project-name (root)
  "Return display name for project ROOT.")
```

Uses `projectile-project-name` if available, otherwise the directory basename.

### 4.3 Customization group

All variables live under the `agent-shell-commander` customization group, child of `agent-shell`.

Key variables:

| Variable                              | Type    | Default  | Description                 |
|---------------------------------------|---------|----------|-----------------------------|
| `agent-shell-commander-peek-position` | symbol  | `'right` | Posframe anchor edge        |
| `agent-shell-commander-peek-width`    | integer | 50       | Posframe width in columns   |
| `agent-shell-commander-peek-height`   | integer | 40       | Posframe max height in rows |
| `agent-shell-commander-sidebar-width` | integer | 25       | Treemacs sidebar width      |

---

## 5. File Structure

```
agent-shell-commander/
├── agent-shell-commander.el          ; package entry point, autoloads, shared utils
├── agent-shell-commander-peek.el     ; posframe switcher
├── agent-shell-commander-toggle.el   ; treemacs/perspective workspace
├── agent-shell-commander-svg.el      ; SVG icon rendering and caching
└── SPEC.md                           ; this file
```
