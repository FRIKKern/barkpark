<!-- doc-tier: human | canonical-for: tui-cheatsheet | budget: 600tok -->
# TUI — cheatsheet

Launch `bp` (no args). Miller columns: structure → doc lists → editor. `?` shows this map in-app. Connect: `bp setup --target connect --server <url>` (first run auto-wizards).

## Navigate

| Key | Does |
|---|---|
| `j/k` `h/l` | move · pane left/right (`l` drills in) |
| `enter` | drill in / open document |
| `/` | search the scope (modal: `enter` opens a hit) |
| `s` | workspace / project / dataset selector |
| `?` · `q` | key overlay · quit |

## Mouse (task board)

| Input | Does |
|---|---|
| wheel | scroll the list / detail |
| click | select row · click again activates |
| drag divider | resize the two panes (ratio persists) |
| `M` | toggle mouse reporting on/off |

## Documents (list pane)

| Key | Does |
|---|---|
| `n` | new doc — type a title, `enter` |
| `y` | duplicate (verbatim content, " (copy)" title) |
| `space` | mark row (✓) for bulk |
| `ctrl+p` / `U` | publish / unpublish **all marked** |
| `R R` / `D D` | discard draft / delete (twice = confirm) |
| `c` / `x` | claim / close (task lists) |
| `esc` | clear marks, then go back |

## Editor

| Key | Does |
|---|---|
| `enter` | edit field — ref: picker (`/` filters live); image: edits URL |
| | text/richText/arrays open a **textarea**: `enter`=newline/item, `ctrl+s`=confirm |
| `space` | toggle bool / cycle select (5+ options: `enter` opens a picker) |
| `enter` on empty slug | pre-fills from title, `enter` again accepts |
| datetime | `now`, `YYYY-MM-DD`, `YYYY-MM-DD HH:MM` |
| validation | required shows `*`; bad pattern/number/date/color refused |
| `ctrl+s` → `ctrl+p` | save, then publish the draft |
| `U` | unpublish (back to draft) |
| `d` | diff draft ↔ published (−pub, +draft) |
| `H` | revision history — `enter` diffs a revision vs current |
| `R R` | discard the draft (keeps the published twin) |

**Draft lifecycle:** `ctrl+s` saves to `drafts.<id>`, `ctrl+p` promotes, `U` demotes, `R R` discards; `d` first. Restore-from-revision is in Studio.

**Blocks-doc bodies & Papers** are read-only here (editing would corrupt block structure); scroll Papers `j/k`, `ctrl+d/u`; edit in Studio.

**Scope selector:** pick from lists; `n` creates a workspace/project (seeds Default/production), `m` = manual entry.

Tasks in depth: [`tasks.md`](tasks.md) · CLI: [`bp.md`](bp.md)
