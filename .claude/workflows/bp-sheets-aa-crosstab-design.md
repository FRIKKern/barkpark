# DESIGN — Sheets formula engine: full-column ranges, cross-tab refs, dynamic-array spill

**Status:** design-complete, implementation-ready. Resolves bp task `drafts.sp-design-paper`.
**Scope:** three coupled formula capabilities that break the engine's current single-tab / bounded-range / one-cell-one-value assumptions. This is a design Paper — no `api/` code changes here.
**Read against `origin/main`** (working tree is stale). All code refs below are `origin/main` line numbers.

---

## 0. TL;DR for the human — skim this, then jump to §5/§6

Three features, one theme: each removes a load-bearing assumption from the formula engine.

| # | Feature | Breaks | Depth |
|---|---------|--------|-------|
| A:A | `=SUM(A:A)`, `B:B`, `3:3` — unbounded column/row ranges resolving to the **used range** | "every range has two fully-bounded A1 corners" | shallow (parser + Structure + one AST variant; eval is already free) |
| Cross-tab | `Sheet2!A1`, `Sheet2!A1:B5`, `Sheet2!A:A` — refs into other tabs | "the dep graph, ctx, and recompute are all keyed by `{col,row}` **within one tab**" | **deep** (coordinate-system change: node key gains a tab dimension; recompute goes whole-document; cross-tab cycles; cross-tab structural rewrite) |
| Spill | a formula that returns an array spills into neighbors; anchor owns it; a blocked spill is `#SPILL!` | "one cell = one stored value; `output/1` collapses `{:array}` to top-left" | medium (storage model: anchor + engine-owned region; new `#SPILL!` code; spill-collision detection; undo) |

**The four one-way-door decisions** (full detail in §4):

1. **Cross-tab refs are NAME-based with rename-rewrite (Excel semantics), not stable tab-ids.** `Sheet2!A1` is stored in the formula text; a `rename_tab` rewrites every referring formula across all tabs (the existing `Structure.rewrite_formula` philosophy — formula text is the source of truth). Names with spaces/punctuation quote as `'My Sheet'!A1`. *Hard to reverse:* the on-disk ref format is baked into every stored formula.
2. **`A:A` resolves to the used range at EVAL time, never stored as a fixed rectangle.** Adding a row below the data extends what `A:A` sees, for free, because the engine recomputes the whole tab and `occupied_positions/3` re-scans the occupied set each time. *Hard to reverse:* the invalidation model assumes no frozen rect.
3. **Spilled cells are ENGINE-MATERIALIZED into the sparse cells map as anchor-owned, marked cells** (`"spill" => anchorRef`) — NOT independent user cells, and NOT a separate non-stored overlay. This preserves the plugin's core invariant ("snapshot is a pure projection of stored `v`") so all five surfaces render spill for free. *Hard to reverse:* the cell-map shape carries the spill marker forever.
4. **Cross-tab forces WHOLE-DOCUMENT recompute** (one Kahn pass over a `{tab,col,row}` graph); the current per-tab fast path survives only as a zero-cross-tab-refs optimization. Two new error strings — `#SPILL!` and cross-tab-reaching `#CYCLE!`/`#REF!` — enter the persisted error vocabulary (`@error_values`). *Hard to reverse:* new persisted `"v"` strings that older readers must tolerate.

**Recommended slice order: cross-tab → A:A → spill.** Rationale in one line each:
- **Cross-tab first** because it generalizes the coordinate system (`{col,row}` → `{tab,col,row}`); doing it first means A:A's new range variant is born tab-qualified and we don't rewrite range normalization twice.
- **A:A second** rides the generalized range (`Sheet2!A:A` falls out for free) and adds only used-range bounding + Structure column/row-ref shifting.
- **Spill last** is an orthogonal storage-model change; it benefits from a settled coordinate system and naturally consumes A:A ranges (`=SORT(A:A)`).
- *Alternative considered and rejected:* A:A first (smaller, de-risks the parser). Rejected because cross-tab would then re-wrap every range — including A:A's — in a tab qualifier, redoing range-normalization work. Generalize the coordinate system once, extend bound-semantics on top.

---

## 1. Current engine architecture (the assumptions we are breaking)

```
Barkpark.Content save ─► Engine.recompute(content)         core.ex / content
                              │                             (whole content in, whole content out)
                              ▼
                     Enum.map(tabs, &recompute_tab/1)        ◄── PER-TAB, ISOLATED
                              │                                   (each tab wrapped alone:
                              ▼                                    %{"tabs" => [tab]})
        recompute_cells(cells)  — one tab's sparse cells map
             │
             ├─ parse every "A1" key ─► pos = {col,row}          ◄── 2-TUPLE node key, no tab
             ├─ occupied  = MapSet of {col,row}
             ├─ values    = %{ {col,row} => literal_value }
             ├─ parse_formula(f) ─► {ast, points, ranges}
             ├─ build_graph  — deps intersect the FORMULA set   ◄── range_node_deps: rect ∩ formulas,
             │                  (range = rect ∩ node_set)             NOT the rectangle → SUM(1M) cheap
             ├─ topo (Kahn)  — ctx = %{computed, values,
             │                        occupied, formulas, self}  ◄── ctx has NO tab field
             │                  cell_at(pos) = computed[pos]
             │                               ‖ values[pos] ‖ :blank
             ├─ Kahn leftovers (in_deg>0) ─► #CYCLE!            ◄── cycle detection = residual in-degree
             └─ write_back ─► output(value) ─► {v, t}           ◄── ONE {v,t} per cell.
                              output({:array,rows}) COLLAPSES        {:array} exists internally
                              to array_top_left(rows)                (SORT/UNIQUE/FILTER/SEQUENCE)
                                                                     but is scalar-out, never spills.
```

**Six load-bearing facts** (each is a wall one of the three features must move):

- **F1 — single-tab isolation.** `recompute/1` (engine.ex:949) maps `recompute_tab/1` over each tab independently; `recompute_tab` wraps ONE tab as `%{"tabs" => [tab]}`. The session leans on this: *"formulas are tab-local, so other tabs cannot change; tabs holding NO formula cell skip the engine entirely"* (session.ex:192-195). A per-tab `formula_counts` map (session state) skips the engine for formula-free tabs — the O(1) bulk-import path.
- **F2 — `{col,row}` node key.** The dep graph (`build_graph/2` engine.ex:1017), `ctx` (engine.ex:1052), `cell_at/2` (engine.ex:1507), `occupied`, `values` — all keyed by a bare `{col,row}` tuple. No tab dimension anywhere.
- **F3 — bounded ranges only.** A range is parsed ONLY as `{:ref} :colon {:ref}` where both sides are fully-bounded A1 refs (`parse_primary/1` engine.ex:1442). `ref_like?/1` (engine.ex:1320) `~r/^\$?[A-Za-z]+\$?[0-9]+$/` **requires a digit** — `A`, `A:A`, `3:3` never lex as refs; the dangling `:colon` fails the parser → `:invalid` → `#REF!`.
- **F4 — `!` is rejected.** `tokenize/2` has no `!` case; the fallback `defp tokenize(_,_), do: :error` (engine.ex:1251) kills cross-tab syntax. Moduledoc: *"no `Tab!A1` syntax; `!` fails the grammar, yielding `#REF!`"* (engine.ex:29-30).
- **F5 — ranges already scale by the used set, not the rectangle.** `occupied_positions/3` (engine.ex:3903) iterates `min(rectangle, occupied)`; `range_node_deps/3` (engine.ex:1033) intersects the formula set. **This is the gift that makes A:A nearly free** — an unbounded rect just takes the "filter the occupied set" branch.
- **F6 — one cell, one value; `{:array}` collapses.** `write_value/2`→`output/1` stores exactly one `{v,t}`. The internal `{:array, rows}` value (produced by UNIQUE/SORT/FILTER/SEQUENCE, engine.ex:2779-2842) is explicitly *array-in/scalar-out*: `output({:array,rows})` → `array_top_left` (engine.ex:1088); `scalarize/1` implicit-intersects (engine.ex:3895). **The array machinery exists; spill is "don't collapse — distribute."**

**Six error values** (`err/1` engine.ex:5046, `@error_values` engine.ex:385): `#CYCLE! #REF! #VALUE! #DIV/0! #N/A #NUM!`. Stored as `"v" => "#CODE!", "t" => "e"`. No `#SPILL!`, no `#NAME?`. This is the one `@canonical capability:engine-error-vocabulary` marker (engine.ex:938) — the single owner of the error vocabulary.

**Session / storage substrate** (session.ex, ops.ex, replay_ring.ex):
- **Tabs addressed by INDEX** (`"tab" => i`, 0-based) — NO stable id in the schema (`sheet.json` tab fields: `name`, `frozen_rows/cols`, `col_widths`, `row_heights`, `merges`, `cells`, `cond_formats`). Identity == list position. `move_tab`/`delete_tab`/`duplicate_tab` remap every pinned undo index (`remap_tab_indexes/2`).
- **Recompute is whole-tab, coalesced.** Cell ops defer; `flush_pending/1` (ops.ex) recomputes each dirty tab ONCE at the batch boundary and broadcasts a compact `{:sheets_op, %{tab: i, changed: %{...}}}` delta. Recompute NEVER crosses tabs today.
- **Structure ops rewrite formula refs.** `insert_rows/delete_rows/insert_cols/delete_cols` delegate to `Structure` (structure.ex) — cell keys shift, formula refs/ranges rewrite via the span-preserving `scan` (structure.ex:891), dead refs → literal `#REF!`. `sort_range` moves cells verbatim WITHOUT rewriting `f`.
- **/ops replay ring** (replay_ring.ex): content-agnostic, keyed `{dataset, pubid}`, caches the reply map only. **No change needed** for any of the three features (both a spill's many-cell write and a cross-tab many-tab write still return one `rev` under one op).
- **Undo = op-inverse**, per-user, depth 100. Shapes: `{:cell, tab, ref, prior|nil}` (full prior stored map), `{:structural, op}`, `{:structural_restore, op, cells}`, `{:tab_restore, idx, tab}`, `{:permute, tab, rect, perm}`. Delete-shift undo is lossy (rewritten `#REF!`s not restored).
- **Concurrency = the GenServer mailbox is the serializer** (one session per `{dataset,pubid}` via `SessionRegistry`; a bypassing direct mutate is a documented session-wins conflict). The `bp-sheet-grid.js` / `sheet_grid.ex` "single-writer" rule is a *dev-workflow* serialization (one builder per file per wave), not a runtime lock — it constrains the SLICE PLAN (§5), not the design.

---

## 2. Assumption-breaks, per capability (exact violations)

### 2.1 A:A / full-column & full-row ranges
- **B-AA-1 (parser, F3):** `A:A` has no digit → not `ref_like?` → no `:ref` token → `parse_primary` has no clause for a bare `:colon` → `:invalid` → `#REF!`. Needs a new lexer token and AST variant for a column-only / row-only reference.
- **B-AA-2 (range normalization, F3):** the range node `{:range, {c1,r1}, {c2,r2}}` assumes finite corners. `A:A` has no row bound.
- **B-AA-3 (Structure shifting):** `Structure.rewrite_formula` only knows `$?LETTERS$?DIGITS` refs (`ref_like?` structure.ex:936, same digit requirement). It cannot shift `A:A`/`3:3`, so a column insert/delete would leave `A:A` un-shifted (wrong) or the scanner would pass it through as non-ref text (also wrong — it must become `B:B` on a column insert, and `#REF!` if its column is deleted).
- **B-AA-4 (nothing breaks in eval or the dep graph):** thanks to F5, `occupied_positions/3` and `range_node_deps/3` already handle a giant rect. **This is the whole point of decision 2.**

### 2.2 Cross-tab refs
- **B-CT-1 (grammar, F4):** `!` is a hard tokenizer reject.
- **B-CT-2 (node key, F2):** every graph node, `ctx` field, `cell_at`, `occupied`, `values` key is `{col,row}` — no way to name "A1 in tab 2". This is the deepest break; it touches the coordinate type itself.
- **B-CT-3 (recompute isolation, F1):** `recompute_tab` sees one tab. A formula in tab 0 reading `Sheet2!A1` cannot resolve — tab 2's cells aren't in scope. The session's `formula_counts` skip and single-tab `dirty_tabs` model assume an edit to tab 2 can never change a value in tab 0.
- **B-CT-4 (cycle detection across tabs):** Kahn runs per-tab; a cycle `Sheet1!A1 → Sheet2!A1 → Sheet1!A1` spans two independent recompute passes and would never be detected — both cells would resolve stale/`0` instead of `#CYCLE!`.
- **B-CT-5 (Structure cross-tab rewrite):** inserting a row in tab 2 must shift `Sheet2!A5` refs that live in OTHER tabs' formulas. Today Structure rewrites only the mutated tab's own formulas. A `rename_tab`/`delete_tab`/`move_tab` has NO formula-rewrite path at all today.
- **B-CT-6 (delta broadcast):** `{:sheets_op, %{tab: i, changed}}` carries one tab's changes. A cross-tab edit dirties multiple tabs → multiple deltas, or a multi-tab delta shape.

### 2.3 Dynamic arrays / spill
- **B-SP-1 (F6, the core break):** `output/1` collapses `{:array}` to top-left; there is no multi-cell write. Spill must distribute an array across a rectangle of cells.
- **B-SP-2 (no anchor/spill model):** the cells map has no notion of "this cell's value is owned by a formula in a neighboring cell." A cell is a value or a formula, full stop.
- **B-SP-3 (no `#SPILL!`):** the error vocabulary has six codes; a spill blocked by existing content needs a seventh.
- **B-SP-4 (no array-literal syntax):** `{` / `;` are not tokens; `={1;2;3}` fails lexing. (In-scope per the brief's example `={1;2;3}`.)
- **B-SP-5 (spill invalidation):** when the anchor is edited/deleted, or when a cell inside the spill region is written by the user (collision), the region must be vacated/recomputed. No such mechanism exists.
- **B-SP-6 (undo):** `{:cell, anchor, prior}` captures one cell. Undoing an anchor edit must also clear/restore the whole spill region.

---

## 3. Design, per capability

### 3.1 A:A full-column and full-row ranges

**Reference representation.** Add a lexer path and AST variant for axis-unbounded references. Two viable encodings — **recommend encoding into the existing `{:range, p1, p2}` node with sentinel bounds** so the entire downstream (`walk`, `build_graph`, `occupied_positions`, aggregates) is untouched:

- `A:A` → `{:range, {colA, 1}, {colA, @max_row}}`
- `3:3` → `{:range, {1, 3}, {@max_col, 3}}`
- `A:C` (multi-column) → `{:range, {colA, 1}, {colC, @max_row}}`
- `B:B` cross-tab → tab-qualified per §3.2.

Carry a small flag so Structure and F4-cycle can tell a full-axis range from a coincidentally-max one: extend the node to `{:range, p1, p2, bounds}` where `bounds ∈ {:cell, :col, :row}` (default `:cell` = today). `bounds` is `nil`/absent on the legacy shape → **byte-compatible** with the current two-corner node; only the new lexer sets it. This keeps `parse_primary`'s existing clause working and adds new clauses for `col :colon col` and `row :colon row`.

*Lexer:* today `ref_like?` needs a digit. Add sibling tokens `{:col, n}` (a bare `A`, `$A`) and `{:row, n}` (a bare `1`… — careful: a bare number is already `{:num}`; a row-ref is only recognized in the `col? :colon` / `num :colon num` **parser** position, not the lexer, to avoid making every literal `5` a row-ref). Cleanest: keep the lexer emitting `{:num}` for bare integers and `{:colword, col}` for a bare column word, and let `parse_primary` recognize three new colon shapes:
- `{:colword,c1} :colon {:colword,c2}` → column range
- `{:num,r1} :colon {:num,r2}` → row range (both integer, 1..@max_row)
- (existing) `{:ref} :colon {:ref}` → cell range

**Evaluation strategy.** Zero new eval code. `{:range, {c,1}, {c,@max_row}}` flows through `range_values/3` → `occupied_positions/3`, which — because `area = @max_row` vastly exceeds the occupied-set size — takes the `else` branch and filters the occupied set (F5). `range_grid/3` clamps to the occupied bounding box. So `=SUM(A:A)` iterates the used cells of column A only. **A blank column A → `[]` → `SUM` = 0**, correct.

**Used-range semantics (decision 2, precise):**
- `A:A` "used range" = *the occupied cells of column A at recompute time*. There is NO stored rect. Adding a value in A100 makes it visible to `=SUM(A:A)` on the next recompute automatically, because the session recomputes the whole tab on any edit and `occupied` is rebuilt each pass.
- Empty tail rows never cost anything (occupied-set iteration, not 1M-row walk).
- A full-column range that spans a formula in its own column (`=SUM(A:A)` placed in A10) includes A10 as a `range_node_deps` self-member → self-edge → Kahn never zeroes A10's in-degree → **`#CYCLE!`**, matching Excel's circular-reference behavior. **No new cycle code.**

**Dependency-graph impact.** `range_node_deps/3` already filters the formula set inside the rect — an unbounded rect just yields "every formula cell in column A". **A subtle but important consequence of whole-tab recompute:** literals are NOT graph nodes; they're read during eval. Because the engine recomputes the WHOLE tab on every mutation (no incremental dep-walk), `=SUM(A:A)` re-evaluates on every edit regardless of whether the edited cell is a formula — so "a new literal in column A extends A:A" needs NO incremental invalidation. The dep graph only orders formula-to-formula edges, which `range_node_deps` already covers.

**Storage model.** No new storage. `A:A` is stored verbatim in the formula string `f` (canonical form, uppercase). Nothing persisted per-range.

**Recompute / invalidation.** Covered by whole-tab recompute (above). No session change needed for eval; the ONE session-adjacent concern is that a formula-free tab that gains its first `A:A` formula bumps `formula_counts` exactly as any formula does (unchanged path).

**Structure (the real A:A work) — insert/delete shifting (B-AA-3):**
- Row insert/delete: a full-COLUMN ref `A:A` is row-unbounded → **invariant** (Excel: `A:A` unchanged by row ops). A full-ROW ref `3:3` shifts like a row (`3:3`→`4:4` on insert above; deleted row → `#REF!`).
- Column insert/delete: `A:A` shifts like a column (`A:A`→`B:B` on column insert to the left; delete of column A → `#REF!`). `3:3` (full row) is column-unbounded → invariant.
- `Structure.scan` must recognize the `LETTERS:LETTERS` and `DIGITS:DIGITS` shapes (its `ref_like?` and `take_range_tail` today require digit-bearing refs). Add full-axis recognition to the scanner and shift each axis-ref through the existing `shift_index`/`shift_span` machinery (the arithmetic is identical — only the token recognition is new).

**Acceptance:** `=SUM(A:A)` over A1:A3 = 1/2/3 → 6; add A100=4 → 10 (used-range extends); `=COUNT(B:B)`; `3:3` full-row; insert a column left of A rewrites `A:A`→`B:B`; delete column A → `#REF!`; `=SUM(A:A)` in A10 → `#CYCLE!`.

---

### 3.2 Cross-tab references

**Reference representation (decision 1 — NAME-based).** `Sheet2!A1` is stored in the formula text. The lexer gains a `!` path: a preceding tab-name token binds to the following ref/range, producing tab-qualified AST nodes:
- `{:ref, {tab, col, row}}` — a **3-tuple coordinate** (the coordinate-system generalization).
- `{:range, {tab,c1,r1}, {tab,c2,r2}, bounds}` — a same-tab range (both corners carry the same tab; cross-tab ranges spanning two tabs are `#REF!`, matching Excel).

Two encoding choices for the tab dimension inside the coordinate:
- **Recommended: resolve tab NAME → tab INDEX at parse time**, storing `{idx, col, row}` internally, where `idx` is the tab's current position. The name lives only in the formula string; the engine works in indices (so `cell_at`, `occupied`, the graph stay integer-keyed and fast). *Because refs are name-based on disk (decision 1), a rename/move rewrites the string; the parser always re-resolves name→index fresh on each recompute, so the internal index is never stale.*
- Rejected: thread names through the whole engine — slower keys, and every `occupied`/`values` map would need string keys.

**Name grammar & quoting (part of decision 1, one-way-door):**
- Bare names: `Sheet2!A1` when the name matches `[A-Za-z_][A-Za-z0-9_]*` and isn't ref-shaped.
- Quoted names: `'My Sheet'!A1` / `'Q1 2026'!A1` for names with spaces/punctuation; `''` escapes a literal apostrophe (Excel convention).
- Unknown tab name → `#REF!` (Excel). A ref to the formula's OWN tab by name (`Sheet1!A1` inside Sheet1) is legal and resolves same-tab.

**Evaluation strategy.** `cell_at({tab,col,row}, ctx)` reads from a per-tab `computed`/`values`. Two ctx shapes:
- **Recommended: ctx carries all tabs.** `ctx.values`/`ctx.computed`/`ctx.occupied` become maps keyed by the 3-tuple (or `%{tab => per-tab-map}`). `eval` resolves any tab's cell uniformly. `occupied_positions/3` filters within one tab's occupied set (the range's tab).

**Dependency-graph impact (B-CT-2/3/4).** The graph is built over **all formula cells of all tabs**, node key `{tab,col,row}`. `range_node_deps` intersects the formula set of the range's tab. One Kahn pass over the whole document orders cross-tab edges correctly and **detects cross-tab cycles as ordinary residual-in-degree leftovers** — `Sheet1!A1 → Sheet2!A1 → Sheet1!A1` is a 2-node cycle in the unified graph → both `#CYCLE!`. **No new cycle algorithm** — the existing Kahn-leftover rule generalizes for free once the graph is unified.

**Recompute scope (decision 4 — whole-document).** `recompute/1` gains a branch:
- **Zero cross-tab refs** (a document-level count, computed once) → keep the current per-tab `Enum.map(tabs, &recompute_tab/1)` fast path unchanged. This preserves the O(1) bulk-import path for the overwhelmingly common single-tab document.
- **Any cross-tab ref present** → build ONE unified `{tab,col,row}` graph across all tabs and run a single Kahn pass. Cost: bounded by total formula count + cross-tab edges; still O(cells+edges).

**Storage model.** No new persisted structure — the ref is text in `f`. The document-level "has cross-tab refs" flag is derived (a walk during recompute), not stored, or cached in session state alongside `formula_counts`.

**Session recompute + invalidation (B-CT-3/6).** The session's `dirty_tabs`/`formula_counts` model must learn cross-tab dependency:
- A `set_cell` on tab `j` must dirty not only tab `j` but every tab holding a formula that reads tab `j`. Maintain a session-side **cross-tab precedent index** `%{target_tab => MapSet_of_dependent_tabs}` (rebuilt on formula writes, cheap — it's tab-granular, not cell-granular). On a cell op to tab `j`, mark `{j} ∪ dependents(j)` dirty.
- `flush_pending/1` then recomputes the affected tabs. **Simplest correct v1:** when any dirty tab has cross-tab refs anywhere in the document, recompute the whole document in one `Engine.recompute(content)` call (not per-tab) and diff each tab. The tab-granular precedent index is the optimization that avoids whole-doc recompute when the edit's tab has no dependents.
- Delta broadcast: emit one `{:sheets_op, %{tab: i, changed}}` per dirty tab (the shape already supports this; the client already handles per-tab deltas).

**Structure cross-tab rewrite (B-CT-5 — the second real cost):**
- `insert_rows`/`delete_rows`/`insert_cols`/`delete_cols` on tab `i` must rewrite cross-tab refs to tab `i` that live in **other tabs'** formulas. Extend the structural pass: after rewriting tab `i`'s own formulas, sweep all other tabs' formulas and shift any `Name_i!` ref/range whose resolved tab is `i`. (The scanner already isolates refs; it gains a tab-qualifier-aware branch that only shifts refs matching the mutated tab's name.)
- `rename_tab i → newname`: rewrite every `OldName!`/`'Old Name'!` qualifier across ALL tabs to the new (possibly re-quoted) name. This is a NEW Structure entry (`rename_refs/3`). Excel does exactly this.
- `delete_tab i`: rewrite every `Name_i!` ref across all tabs to `#REF!` (Excel). Also decrement/rebuild the cross-tab precedent index.
- `move_tab`: because refs are name-based, **no ref rewrite** — names are position-stable (a second win for decision 1; index-based refs would have forced a rewrite here).
- **Undo:** these cross-tab rewrites touch other tabs' formulas, so the structural inverse must capture the prior formulas of every tab it rewrote (extend `{:structural_restore, ...}` to carry a multi-tab cell capture), or accept the same documented lossy-undo contract as delete-shift `#REF!`s. Recommend: capture the touched other-tab formulas for `rename_tab`/`delete_tab` (they're few — only cells with cross-tab refs) so rename is losslessly undoable.

**Acceptance:** `=Sheet2!A1` reads across tabs; `=SUM(Sheet2!A1:A3)`; `=SUM(Sheet2!A:A)` (composes with §3.1); editing `Sheet2!A1` recomputes the dependent tab-0 formula + broadcasts its delta; `Sheet1!A1 → Sheet2!A1 → Sheet1!A1` → `#CYCLE!` on both; `'My Sheet'!A1`; rename Sheet2→Data rewrites `Sheet2!A1`→`Data!A1` everywhere; delete Sheet2 → dependents become `#REF!`; move Sheet2 → refs unchanged; a zero-cross-tab document still hits the per-tab fast path (perf golden).

---

### 3.3 Dynamic arrays / spill

**The seed.** The engine already produces `{:array, rows}` (rows-major list of single-element rows) from UNIQUE/SORT/FILTER/SEQUENCE (engine.ex:2779-2842) and collapses it at `output/1` (F6). Spill = *don't collapse; distribute, with anchor ownership.*

**Anchor ownership & storage model (decision 3 — engine-materialized, marked).** The anchor cell (where the user typed the array formula) stores its `f` as today, plus a computed spill dimension. Recompute distributes the array's values into the anchor + neighboring cells by **writing engine-owned marked cells** into the sparse cells map:

```
anchor A1:  %{"f" => "=SORT(C1:C3)", "v" => <top-left value>, "t" => .., "spill" => "A1", "spill_dims" => [3,1]}
spilled A2: %{"v" => <2nd value>, "t" => .., "spill" => "A1"}   # engine-written, NOT user-authored
spilled A3: %{"v" => <3rd value>, "t" => .., "spill" => "A1"}
```

- `"spill" => anchorRef` marks a cell as **owned by the anchor**. The anchor's own `spill` points at itself and carries `spill_dims` (rows×cols).
- Spilled cells (non-anchor) carry NO `f` and NO user style; they are pure engine output, rewritten every recompute.
- **Why materialize (not a pure overlay):** the plugin's whole architecture is "recompute stamps `v`, `Core.snapshot_for` projects `v`, every surface (embeds, CSV, MD, HTML, xlsx, TUI, Studio) renders `v` with zero renderer changes." Materializing spilled `v` keeps that invariant — spill renders on all five surfaces for free, and CF (which styles by stored `v`) applies to spilled cells naturally. A non-stored overlay would force every surface + CF + snapshot to learn spill expansion (huge surface, high drift risk). Rejected.
- **"Computed-not-stored" reconciled:** spilled cells are *stored* but *not user-authored* — engine-owned, excluded from `nonempty` user-content counts, never individually undoable, cleared/rewritten on every recompute. That is the brief's "computed-not-stored" in the sense that matters (ownership/authoring), implemented to preserve the projection invariant.

**Spill-region computation.** After eval produces `{:array, rows}` at the anchor, `write_back` (extended) computes the target rectangle: `rows × cols` starting at the anchor. Then the **collision check**:
- For each target cell other than the anchor: if it holds USER content (a value, a formula, or a *different* anchor's spill) → **the whole spill is blocked** → anchor gets `#SPILL!`, NO cells are written. (Excel: any obstruction blocks the entire spill.)
- Empty target cells, and cells owned by THIS anchor from the previous recompute, are writable.
- On success: write anchor + spilled cells; clear any previously-owned cells now outside the new region.

**`#SPILL!` (decision 4, part).** Add `#SPILL!` to `@error_values` (engine.ex:385) and `err(:spill)` to `err/1` (engine.ex:5046). This is a new persisted `"v"` string — older readers must tolerate it (they already treat any `t:"e"` cell as an error passthrough, so this is safe). Update the `@canonical engine-error-vocabulary` marker's `aka:` list.

**Dependency graph impact.** Spilled cells are engine outputs — they must be graph-ordered so a formula reading `A2` (a spilled cell) computes AFTER the anchor `A1`. Model the spill region as **dynamic dependents of the anchor**: after the anchor evaluates, its spilled positions are known; any formula whose range/ref covers a spilled cell depends transitively on the anchor. Because the spilled values are written into `computed` during the anchor's `topo` step, a reader evaluated later in the same Kahn pass sees them via `cell_at`. The subtlety: a formula `=A2` where A2 is *going to be* spilled must not evaluate before the anchor. **v1 rule:** treat any formula that references a cell inside a live spill region as depending on that region's anchor (add the edge during graph build using the PRIOR recompute's spill map, then a bounded second pass if the region grew — or accept one-recompute-lag for newly-spilled-into references, documented). Recommend: a two-phase recompute when spills are present (phase 1: compute anchors + spill regions; phase 2: recompute readers with the spill map materialized) — bounded, only when the document has array formulas.

**Recompute / invalidation (B-SP-5).**
- **Anchor edited to a smaller/larger array:** recompute recomputes the region; cells vacated (now outside the region) are cleared (emit `nil` in the delta); new cells written.
- **Anchor deleted:** the whole owned region is cleared (all `"spill" => anchor` cells removed).
- **User writes into a spilled cell:** that cell now holds user content → next recompute's collision check blocks the spill → anchor becomes `#SPILL!` and the region vacates (Excel behavior).
- **Structural shift:** insert/delete rows/cols moves the anchor cell key like any cell; the spill region is recomputed from the (possibly shifted) anchor position — spilled cells are re-derived, not shifted, so no special Structure handling beyond moving the anchor. A structural op that drops content into the region triggers `#SPILL!` on next recompute.

**Undo (B-SP-6).** The anchor edit's inverse is the ordinary `{:cell, tab, anchorRef, prior_anchor_cell}`. On undo:
- restore the prior anchor cell (its prior `f`/`v`),
- recompute the tab → the region re-derives from the restored anchor (re-spills the old array, or vacates if the prior anchor wasn't an array formula).
- Spilled cells are engine-owned, so they need NO individual inverse — recompute reconstructs them. The delta from the undo recompute carries the vacated/rewritten spilled cells. **This is why decision 3 (engine-owned, recompute-derived) keeps undo simple** — the alternative (N stored user cells) would need a span-capture inverse for every spill.
- One edge: undoing an edit that CAUSED a `#SPILL!` (user typed into a spilled cell) restores that cell to empty → recompute re-spills. Handled by the same "restore prior cell + recompute" path.

**Array literals (B-SP-4).** `={1;2;3}` (column) / `={1,2,3}` (row) / `={1,2;3,4}` (grid): lexer gains `{` `}` `;` `,`-in-array tokens; parser produces `{:array_lit, rows}`; eval yields `{:array, rows}` — which then spills through the same path. `;` = row separator, `,` = column separator (Excel). Scope-limited to literals of scalars.

**Acceptance:** `={1;2;3}` in A1 spills to A1:A3; `=SORT(C1:C3)` spills sorted; a value in A2 below a 3-tall spill anchor → `#SPILL!` and nothing written; delete the anchor → A2/A3 clear; `=A2` reads the spilled value; undo an anchor edit re-spills the prior array; a spilled cell shows in a paper embed + CSV export (projection invariant); CF colors a spilled cell by its value.

---

## 4. One-way-door decisions (human: skim these)

1. **Cross-tab refs are NAME-based, rewritten on rename/delete (Excel), NOT stable-tab-id.**
   *Chosen* because it matches the existing "formula text is truth, refs rewritten by Structure" model, makes `move_tab` a no-op for refs, and needs no schema migration. *Cost:* a rename rewrites every referring formula across all tabs (new `Structure.rename_refs`); delete makes refs `#REF!`. *Alternative (stable ids):* rename-stable but requires a `sheet.json` tab-id field, an id→name resolver on every surface, non-Excel display, and a migration for existing docs. **Reversal is expensive** — the on-disk ref format is in every stored formula. Includes the quoting grammar (`'My Sheet'!A1`, `''` escape) — also hard to change post-hoc.

2. **`A:A` resolves to the used range at EVAL time; never stored as a fixed rect.**
   *Chosen* because whole-tab recompute + `occupied_positions` make it free and make "add a row → A:A extends" automatic. *Alternative (freeze to a concrete rect at parse):* would break the extend expectation and need invalidation when the used range grows. **Reversal is expensive** — the no-stored-rect assumption is baked into the invalidation story.

3. **Spilled cells are engine-materialized into the cells map as anchor-owned marked cells** (`"spill" => anchorRef`), preserving "snapshot = projection of stored `v`."
   *Chosen* to render spill on all five surfaces + CF for free and keep undo trivial (recompute re-derives). *Alternative (non-stored overlay):* every surface + CF + snapshot must learn spill expansion; undo needs span-capture. **Reversal is expensive** — the cell-map shape carries the marker; existing spilled data would need migration.

4. **Cross-tab forces whole-document recompute** (per-tab fast path survives only for zero-cross-tab-ref docs); **`#SPILL!` and cross-tab-reaching `#CYCLE!`/`#REF!` enter the persisted error vocabulary.**
   *Chosen* because a unified `{tab,col,row}` Kahn graph is the only sound way to order and cycle-detect across tabs. *Cost:* new persisted `"v"` strings older readers must tolerate (safe — all error strings already passthrough via `t:"e"`); a perf regression risk for large multi-tab docs mitigated by the zero-cross-tab fast path + the tab-granular precedent index. **Reversal is expensive** — `@error_values` is the `@canonical` single-owner set; adding a code is a data-format commitment.

---

## 5. Slice plan (file-disjoint, single-writer-aware)

**Single-writer constraint (dev-workflow):** at most ONE builder per wave touches `engine.ex`; ONE touches `structure.ex`; ONE touches the `sheet_grid.ex`/`bp-sheet-grid.js` cluster. Pure test files, the schema, and disjoint modules are the parallel surface. Order the waves by the coordinate-system dependency (cross-tab generalizes the key that A:A extends).

### Wave 1 — Cross-tab foundation (the coordinate-system generalization)
- **X1 — Engine: `{tab,col,row}` coordinate + `!` grammar + unified graph.** `engine.ex` sole writer. Lexer `!` path + tab-name (bare + quoted) tokens; `{:ref,{tab,c,r}}` / tab-qualified `{:range}`; ctx/`cell_at`/`occupied`/`values` keyed by 3-tuple; `recompute/1` branch (per-tab fast path when zero cross-tab refs, unified Kahn otherwise); cross-tab cycle via existing Kahn-leftover rule. **Gate:** `engine_test.exs` — cross-tab read, cross-tab range, cross-tab cycle → `#CYCLE!`, unknown-tab-name → `#REF!`, and a *regression lock* that a zero-cross-tab document produces byte-identical results + hits the fast path. **Acceptance:** `=Sheet2!A1`, `=SUM(Sheet2!A1:A3)`, the 2-tab cycle.
- **X2 — Structure: cross-tab ref shift + `rename_refs`/delete-ref rewrite.** `structure.ex` sole writer. Scanner recognizes tab-qualified refs; `insert/delete` on tab `i` sweeps other tabs' `Name_i!` refs; new `rename_refs/3`; delete-tab → `#REF!` rewrite. Pure functions, no session. **Gate:** `structure_test.exs` — cross-tab shift on row/col insert/delete, rename rewrite (incl. re-quoting), delete → `#REF!`, move-tab leaves refs untouched. Parallel with X1 (disjoint file) *except* both consume the tab-qualified ref shape — X1 defines it first, X2 rebases (small).
- **X3 — Session: cross-tab dirty propagation + precedent index + Structure wiring.** `session.ex`/`ops.ex` cluster sole writer. Cross-tab precedent index in state; `flush_pending` recomputes dependent tabs (whole-doc when a dirty tab has dependents); wire `rename_tab`/`delete_tab`/`move_tab`/`insert*`/`delete*` to the new Structure entries + capture other-tab formula inverses for lossless rename undo; multi-tab delta emission. **Gate:** `session_test.exs` — edit Sheet2!A1 dirties + broadcasts the dependent tab; rename undo restores refs; move-tab no-op; replay-ring unchanged. **Depends on X1+X2 merged.**

### Wave 2 — A:A full-column / full-row (rides the generalized range)
- **A1 — Engine: unbounded range variant.** `engine.ex` sole writer. Lexer `{:colword}` token; `parse_primary` clauses for `col:col`, `num:num`; `{:range, p1, p2, bounds}` with `:col`/`:row` sentinels (tab-qualified for free via wave 1). Eval unchanged (F5). **Gate:** `engine_test.exs` — `SUM(A:A)`, `COUNT(B:B)`, `3:3`, used-range-extends, `A:A`-in-column-A → `#CYCLE!`, `Sheet2!A:A`. **Acceptance:** `=SUM(A:A)`=6 then +A100 → 10.
- **A2 — Structure: full-axis ref shifting.** `structure.ex` sole writer. Scanner recognizes `LETTERS:LETTERS`/`DIGITS:DIGITS`; column ops shift col-refs / row-invariant; row ops shift row-refs / col-invariant; deleted axis → `#REF!`. **Gate:** `structure_test.exs` — insert col left of A rewrites `A:A`→`B:B`; delete col A → `#REF!`; row ops leave `A:A` untouched; `3:3` mirrors. Parallel with A1 (disjoint file; rebases on the new range shape).
- **A3 — Docs + function-spec/UX stamp** (disjoint): update the engine moduledoc grammar section, `docs/contracts/schema-v2.md` if range grammar is documented there, and any `data-fns`/point-mode header-click that inserts `A:A` (client already inserts `B:B` per the formula-UX charter — verify it now round-trips through eval). Small, parallel.

### Wave 3 — Dynamic arrays / spill (orthogonal storage-model change)
- **S1 — Engine: spill distribution + `#SPILL!` + array literals.** `engine.ex` sole writer. `err(:spill)` + `@error_values`; `write_back`/`output` distribute `{:array,rows}` to anchor+region with the collision check + engine-owned marked cells; two-phase recompute when spills present; `{:array_lit}` lexer/parser. **Gate:** `engine_test.exs` — `={1;2;3}` spills; `=SORT(C1:C3)` spills; obstruction → `#SPILL!` (nothing written); vacate on shrink; `=A2` reads spilled; anchor delete clears region. **Acceptance:** the brief's spill scenario.
- **S2 — Session/undo + delta for spill regions.** `session.ex`/`ops.ex` cluster sole writer. Ensure `nonempty` excludes engine-owned spill cells; anchor-edit/delete delta carries vacated cells as `nil`; undo re-derives region via recompute (no new inverse shape). **Gate:** `session_test.exs` — spill delta, undo re-spills, `#SPILL!` on user-typed collision, spilled cell not counted as user content. **Depends on S1.**
- **S3 — Cross-surface + CF projection lock** (disjoint): golden tests that a spilled cell appears in a paper embed, CSV/MD/HTML export, and TUI snapshot (projection invariant), and that a CF rule colors a spilled cell. `core.ex`/render goldens only; no engine change. Parallel with S2.

**Merge order:** X1 → X2 → X3 (wave 1) → A1 → A2 → A3 (wave 2) → S1 → S2 → S3 (wave 3). Within a wave the pure test/doc/disjoint slices parallelize; the `engine.ex` and `structure.ex` and session-cluster writers serialize per the single-writer rule.

---

## 6. Risks & interactions with shipped features

- **A:A × sort:** sort moves formula cells verbatim (`f` unchanged). `=SUM(A:A)` sorted to a new row still reads `=SUM(A:A)` — correct (column-absolute). **No conflict.**
- **A:A × insert/delete (Structure):** the real work item — a full-axis ref must shift on the perpendicular axis and `#REF!` on axis deletion (slice A2). Miss it and `A:A` silently fails to track column moves.
- **A:A / cross-tab × the 200k snapshot cap & 50k cell cap:** unbounded ranges never materialize a dense rect (F5), so they don't inflate the snapshot — the cap is on OCCUPIED cells, unaffected. **No conflict.**
- **Cross-tab × the per-tab recompute fast path:** the biggest perf risk. Mitigated by decision 4's zero-cross-tab fast path + the tab-granular precedent index. A pathological all-tabs-reference-all-tabs document falls to whole-doc recompute within the 30s mailbox budget — bounded by total formula count. **Add a perf golden** locking the zero-cross-tab fast path.
- **Cross-tab × undo tab-index remapping:** undo entries pin absolute tab indices and remap on move/delete/duplicate. Cross-tab structural rewrites (rename/delete) now also touch OTHER tabs' formulas — their inverses must capture those formulas (slice X3) or inherit the documented lossy-undo contract. **Risk: silent cross-user corruption if the multi-tab capture is skipped** — call it out in the X3 brief.
- **Cross-tab × /ops replay ring:** content-agnostic, keyed `{dataset,pubid}`, caches only the reply. **No change** — a multi-tab batch dedups like any other.
- **Cross-tab × write-through snapshot:** `snapshot_for/2` is already per-tab; cross-tab changes only what `Engine.recompute` must SEE (whole content, which it already receives). Snapshots regenerate per embed at persist. **No conflict**, but the persist-time `Content` recompute must use the same unified path (it calls `Engine.recompute` on whole content already — verify it takes the cross-tab branch).
- **Spill × undo:** decision 3 keeps it a plain `{:cell, anchor, prior}` + recompute; the ONE hazard is a delta that forgets to emit vacated spilled cells as `nil` (client shows stale spill). Locked by slice S2's delta test.
- **Spill × CF / per-viewer filter:** CF styles by stored `v` → engine-materialized spill cells get CF for free (decision 3 win). Per-viewer filter is a client view-state over `visible_rows`; server-side spill eval is filter-agnostic — a spilled `=SORT(A:A)` sorts all data; the viewer's filter merely hides rows. **No conflict**, note it in S3.
- **Spill × structural shift:** the anchor moves like any cell; the region re-derives. A structural op dropping content into a region → `#SPILL!` next recompute. **No special Structure handling** beyond moving the anchor key.
- **Spill × `nonempty` / bulk-import counts:** engine-owned spill cells must be excluded from `nonempty` or a spill inflates the session's cell-count guard. Slice S2.
- **All three × the formula-UX point-mode client (`bp-sheet-grid.js`):** cross-tab and `A:A` are engine/Structure/session changes; the client already inserts `A:A`/`B:B` (formula-UX charter Decision 10/point-mode). Cross-tab ref insertion (clicking a cell in another tab while pointing) is a LATER client slice — **out of scope for this engine design**; the charter's Decision 15 listed cross-tab as out-of-scope for arc-1 *precisely because the engine couldn't evaluate it* — this design removes that blocker, and a future formula-UX wave can wire the client gesture.

---

## 7. Open questions for the human (non-blocking; sensible defaults chosen)

1. **Cross-tab ref insertion in point-mode** — wire the "click a cell in another tab while editing a formula" gesture now, or defer to a formula-UX wave? *Default: defer* (engine-first; the design unblocks it).
2. **Spill scope for v1** — array literals + spilling the existing UNIQUE/SORT/FILTER/SEQUENCE, or also add new spill-native functions (`SEQUENCE` grids, `TRANSPOSE`)? *Default: spill what already produces `{:array}` + literals; new functions are a follow-up.*
3. **Whole-document recompute perf ceiling** — is a whole-doc recompute acceptable for a worst-case dense multi-tab document within the 30s mailbox budget, or do we need incremental cross-tab invalidation in v1? *Default: whole-doc + tab-granular precedent index; incremental is a follow-up if a real doc bites.*
