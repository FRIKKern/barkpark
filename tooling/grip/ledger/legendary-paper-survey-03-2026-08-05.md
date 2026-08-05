# Legendary Paper survey 03 — public semantic/accessibility parity

## Verdict

**found** — the pinned public reader preserves top-level block identity/order and the heading/list outline, but it does not preserve all source meaning or accessibility semantics.

Assignment: `survey-03`  
Unit: `cloud-console-hardening-wave-29-2026-08-03::public`  
Pinned Paper revision: `18768b0a14c2eead927181c4a0e37c18`  
Lens: semantic/accessibility parity  
Audit date: 2026-08-05

## Exact sample and captures

- Sample: 1 revision-pinned Paper, 1 public reader, all 252 source blocks.
- Public capture: `GET https://guerrilla.barkpark.cloud/papers/cloud-console-hardening-wave-29-2026-08-03` → HTTP 200, `text/html`; SHA-256 `10af842f3501ebea5b27ecaa1e8c8f75764439a31b9c237533a0c2390de82766`.
- Source capture: `GET .../source` → HTTP 200, `application/json`; source kind `blocks`, `_rev=18768b0a14c2eead927181c4a0e37c18`, 252 blocks; SHA-256 `d3bb064cffd3977a6cb466cfa450000f180511b2aac147a1d54c2620c480cfc9`.
- Independent CLI capture: `bp -s guerrilla paper view cloud-console-hardening-wave-29-2026-08-03 -o json`; the returned `_rev` is the same pinned revision and it also contains 252 top-level blocks.
- HTML parser: `lxml 6.0.2`; comparisons were scoped to `article#paper-body`, not the reader's terminal/mail demo overlays.

## Facts

### Preserved (`not_found` for loss)

- All 252 source block ids occur once in the public article, with zero missing ids, zero extra ids, and exact source order.
- The outline is semantic and stable: 1 `h1`, 27 `h2`, 9 `h3`, with no upward level skips.
- The 13 list blocks retain list containers: 2 `ol`, 11 `ul`.
- The document shell has `lang=en`, one `main`, one `article#paper-body`, one `h1`, and a title matching the Paper title.

### Complete visible-text loss (`found`, critical)

- Source block `w29D015` contains 5 unordered items, 1,431 characters / 256 word tokens. Public HTML renders five `<li><span></span></li>` items.
- Source block `w29D022` contains 6 unordered items, 837 characters / 150 word tokens. Public HTML renders six `<li><span></span></li>` items.
- Total: 11 source list items, 2,268 characters / 406 word tokens disappear. The public article has exactly 11 empty list items.
- The source shape is a list item array containing a paragraph map. The composer sends every list item through `compose_inline_children(normalize_list_item(item))` ([compose.ex:332](../../../api/lib/barkpark/portable_doc/render/compose.ex#L332)); `normalize_list_item/1` unwraps a paragraph only when the item itself is a map, not when it is the sole map inside a list ([compose.ex:1955](../../../api/lib/barkpark/portable_doc/render/compose.ex#L1955)). This is a renderer/source-shape mismatch, not a visual-only issue.

### Inline meaning flattened (`found`, high)

- The pinned source contains 313 marked text nodes: 200 `code`, 113 `strong`.
- These marks are stored as string values (`"code"`, `"strong"`). The public article emits zero `code`, zero `strong`, and zero `b` elements for them; marked text remains visible but loses code/emphasis semantics.
- The inline composer accepts a marks list ([inline.ex:29](../../../api/lib/barkpark/portable_doc/render/inline.ex#L29)), but its supported clauses require mark maps such as `%{"type" => "code"}` or `%{"type" => "strong"}` ([inline.ex:216](../../../api/lib/barkpark/portable_doc/render/inline.ex#L216)). String marks fall into the unknown pass-through clause ([inline.ex:308](../../../api/lib/barkpark/portable_doc/render/inline.ex#L308)).

### Data tables hidden from assistive technology (`found`, high)

- The source has 11 data-table blocks containing 35 header cells, 98 body rows, and 316 body cells.
- Public HTML renders all 11 as `<table role="presentation">`. It emits 35 `th` elements, but none has `scope`; no table has a `caption`.
- The renderer hard-codes the presentational role on article tables ([walk.ex:970](../../../api/lib/barkpark/portable_doc/render/walk.ex#L970), [walk.ex:1012](../../../api/lib/barkpark/portable_doc/render/walk.ex#L1012)). Inference: assistive technology is instructed to ignore the table relationship, so the visual header/body grid is not semantic parity.

### Callout tone is visual-only (`found`, medium)

- The source has 4 callouts (`warning`, `info`, `warning`, `note`). Public HTML renders 4 `.bp-callout` divs with zero roles and zero accessible labels.
- Non-collapsible article callouts are hard-coded as generic divs ([walk.ex:1413](../../../api/lib/barkpark/portable_doc/render/walk.ex#L1413), [walk.ex:1422](../../../api/lib/barkpark/portable_doc/render/walk.ex#L1422)). The source `note` tone also falls through to the `info` visual class because the renderer only names success/warning/danger/neutral/info.
- Inference: tone is not announced, and consumers that cannot perceive the visual styling cannot recover whether the source called a passage a warning/note/info.

## Commands used

```text
bp -s guerrilla paper view cloud-console-hardening-wave-29-2026-08-03 -o json
bp -s guerrilla doc history paper cloud-console-hardening-wave-29-2026-08-03 --limit 10 -o json
curl -fsSL https://guerrilla.barkpark.cloud/papers/cloud-console-hardening-wave-29-2026-08-03
curl -fsSL -H 'accept: */*' https://guerrilla.barkpark.cloud/papers/cloud-console-hardening-wave-29-2026-08-03/source
shasum -a 256 <public/source captures>
python3 + lxml: compare all source block ids/order/text and count article semantics
jq: count block types, mark encodings, table rows/cells, callout tones
```

## Coverage ledger

| Item checked | Checked for | Result |
|---|---|---|
| Paper `cloud-console-hardening-wave-29-2026-08-03`, rev `18768...` | exact pinned source, all block shapes/marks | **found** — 2 text-loss blocks; string-mark drift |
| Public Paper URL | HTTP availability, reading order, landmarks, headings, lists, tables, callouts, visible-text parity | **found** — semantic/accessibility loss above |
| `/source` endpoint | immutable source kind/revision/count | **not_found** for drift — exact revision and 252 blocks |
| `api/lib/barkpark/portable_doc/render/compose.ex` | list normalization path/root cause | **found** |
| `api/lib/barkpark/portable_doc/render/inline.ex` | supported mark wire shape/root cause | **found** |
| `api/lib/barkpark/portable_doc/render/walk.ex` | emitted table and callout semantics/root cause | **found** |
| `api/lib/barkpark_web/live/bulldocs_live.ex` | public block stream wrapper and article boundary | **found** — each top-level block is emitted independently at lines 1048–1057 |
| `api/CLAUDE.md` Bulldocs section | authoritative public-reader ownership | **found** — `BarkparkWeb.BulldocsLive` + PortableDoc renderer |
| Task `task-a768c69e659add58` | campaign scope, live criterion, pinned Paper resources | **found** — in progress; criterion 1 is this 20-surface audit; current pulse launches surveys 1–3 of 60 |
| Barkpark task inventory beyond the campaign root | related defect/task claims | **partial** — unrelated tasks deliberately unvisited |
| Other Papers/readers | cross-Paper prevalence | **not_found / unvisited** — outside `survey-03` scope |

## Risks and targeted proof still required

- Run a real accessibility-tree/assistive-technology capture after repair; static HTML proves the missing semantics but not every browser/AT announcement.
- Add regression fixtures for both actual drifted shapes: string marks and `items: [[{type:"paragraph", ...}]]`. A canonical-source migration alone would leave future raw imports vulnerable; renderer tolerance alone would leave stored schema drift unexplained.
- Decide deliberately whether data tables should remove `role=presentation`, add `scope=col`, and support captions. Do not change all email layout tables: this finding concerns the 11 article `table` blocks only.
- Decide a semantic contract for non-collapsible callout tone (`aside`, `role=note`, visible/accessible label, or another tested pattern) rather than translating color directly into ARIA severity.

## Unvisited ranges

- No Studio, TUI80, email, or CLI/API parity assessment beyond the CLI JSON revision check.
- No other Paper revisions.
- No keyboard, screen-reader, browser accessibility-tree, or CSS contrast run.
- No mutation, repair, production write, task update, or test-pass claim.
