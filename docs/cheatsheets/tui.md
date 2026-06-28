<!-- doc-tier: human | canonical-for: tui-cheatsheet | budget: 600tok -->
# TUI — cheatsheet

Launch `bp` (no args). Miller columns: structure → doc lists → editor. `?` shows this map in-app. Connect with `bp setup --target connect --server <url>` (first run: wizard fires automatically).

## Navigate

| Key | Does |
|---|---|
| `j/k` `h/l` | move · pane left/right (`l` drills in) |
| `enter` | drill in / open document |
| `/` | search the scope (modal: `enter` opens a hit) |
| `s` | workspace / project / dataset selector |
| `?` · `q` | key overlay · quit |

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
| `enter` | edit field — reference: picker (`/` filters live); image: edits URL |
| | text/richText/arrays open a **textarea**: `enter` = newline / new item, `ctrl+s` = confirm |
| `space` | toggle bool / cycle select (5+ options: `enter` opens a picker) |
| `enter` on empty slug | pre-fills from the title — `enter` again accepts |
| datetime | `now`, `YYYY-MM-DD`, `YYYY-MM-DD HH:MM` |
| validation | required shows `*`; patterns/number/datetime/color refuse bad commits |
| `ctrl+s` → `ctrl+p` | save, then publish the draft |
| `U` | unpublish (back to draft) |
| `d` | diff draft ↔ published (− published, + draft) |
| `H` | revision history — `enter` diffs a revision vs current |
| `R R` | discard the draft (keeps the published twin) |

**Draft lifecycle:** edits stage locally (`ctrl+s` saves them to `drafts.<id>`); `ctrl+p` promotes, `U` demotes, `R R` throws the draft away. Use `d` before either. Restore-from-revision lives in Studio.

**Blocks-doc bodies** (edited in Studio's block editor) show read-only — the TUI won't edit them (would corrupt block structure). **Papers are read-only** here (scroll with `j/k`, `ctrl+d/u`); edit them in Studio.

**Scope selector:** pick from lists, or `n` creates a workspace/project (server slugs the name and seeds Default/production), `m` for manual entry.

Tasks in depth: [`tasks.md`](tasks.md) · CLI: [`bp.md`](bp.md)
