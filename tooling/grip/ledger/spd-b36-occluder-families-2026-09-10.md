<!-- doc-tier: cold | canonical-for: spd-b36 occluder-family census (2026-09-10) | budget: 9000tok -->

# spd-b36 — the occluder census: which families the metric counts, and the one hole nobody had named

**HISTORICAL RECORD, dated 2026-09-10.** Task `task-a5fbcb52ee751666`. Measured on deployed
guerrilla at viewport 1280x900 against
`/w/default/p/default/d/production/studio/paper/epic-paper-beauty-reference-wave-2026-07-31`
(band 146–899, content box 352–932, 100 rows in the Papers pane). Code read on
`origin/main` at `f997dc3a3`. Raw artifacts and the probes that produced them sit beside this
file: `spd-b36-browser-census-ui-triggers-2026-09-10.json`,
`spd-b36-browser-census-synthetic-2026-09-10.json`,
`spd-b36-unsampled-census-positive-control-2026-09-10.json`.

---

## The filing's premise is stale, and the stale half is the important half

The row was filed 2026-07-23 against `15e057f83`, when `visible_content_px` subtracted exactly
one occluder from a hand-maintained list — the inspector, and only when out of flow. Every
"counted by nothing" claim in the row follows from that.

**That list is gone.** D112 (shipped in #17276, merged 2026-09-10 as `973341770`) replaced it with
a hit-test whose classification is an **ancestry test, never a name match**
(`scripts/studio-desk-measure.mjs`, `classifyAt`): at each probed point, if the topmost element
is the surface or a descendant, the reader sees the surface; anything else is an occluder,
whatever it is called. A hand-maintained list cannot be incomplete when there is no list. So the
correct question is no longer "is family X on the list" but **"can a point that family covers ever
be probed"**, and that has exactly two failure modes:

1. `pointer-events: none` — the element is invisible to `elementsFromPoint` in both samples.
   Already named by `occlusion.invisible_occluder_census` (#17276).
2. **Nothing probes it.** The five scanlines sit at 10/30/50/70/90% of the band, i.e.
   `band_height / 5` apart — **150.6px on the measured row**. Horizontal chrome shorter than that
   spacing is stepped over entirely, with ordinary pointer-events and a perfect ancestry
   classification that never runs. **Counted by nothing, and named by nothing until this packet.**

---

## Re-derived line refs (origin/main `f997dc3a3`, `api/lib/barkpark_web/layouts/root.html.heex`, 6006 lines)

Every July line ref in the filing is wrong. Several selectors are not in that file at all.

| Filing said | Actually on main |
|---|---|
| `.modal-backdrop`/`.modal-card` at 3276-3280 | **3740** / **3745** (z-index 50, `position: absolute`, resolves against the ICB — the 3717-3737 comment says so verbatim) |
| `.image-picker-overlay` at 2105 | **2604** (fixed, inset 0, z-index 50) |
| `.bp-ab-overlay` at 2181-2183 | **not in root.html.heex at all** — `api/priv/static/assets/bp-media-picker.css:2`, class set in `bp-asset-browser.js:46` |
| `.bp-ae-modal` at 2547-2554 | **2975** (fixed, inset 0, z-index 60); backdrop 2980, card 2983 |
| `.history-modal`/`.delete-modal`/`.profile-modal` at 2615/2640/2724 | **3043** / **3068** / **3160** (all fixed, centred, z-index 51) |
| `.bp-slash-menu`, `.bp-paper-format` "both fixed z-index 200" in root.html.heex | **neither is styled in root.html.heex.** `.bp-slash-menu` → `api/assets/paper-editor/src/styles.css` + `api/priv/static/assets/bp-paper-editor-shell.css`. `.bp-paper-format` → same shell CSS; root.html.heex mentions it only in a JS comment at **5462**. Measured live: fixed, z-index 200 — the z-values were right, the location was not |
| `.bp-paper-context-menu` at 3714-3720, z-index 1000 | **not in root.html.heex.** Shell CSS; measured live z-index 1000, fixed. Lines 3714-3720 today are the `.modal-backdrop` explainer comment |
| `.bp-ae-toast` at 2381-2388 | **2810** (fixed, bottom 24px, centred, z-index 200, **`pointer-events: none`**) |
| `.bp-bulk-action-bar` at 3200-3210 | **3663** (fixed, bottom 20px, centred, z-index 50, pointer-events auto) |
| scrim `pointer-events:none` at 1350; measured at 530-544 | scrim rule **1567** (`.editor-with-preview:has(.bp-doc-sidebar.is-open)::after`), suppressor **2258**; measured into the row at `studio-desk-measure.mjs` ~1832-1841 |

---

## The verdict table

`counted?` = does a point the family covers get probed by the shipped metric.
`concurrent?` = can it paint while `.bp-paper-surface` is on screen.

| # | Family | Trigger used | Concurrent with the paper surface? | pointer-events | Counted by `visible_content_px`? |
|---|---|---|---|---|---|
| 1 | `.image-picker-overlay` (share / airdrop / access / item-share / ref-picker) | **real UI**, `phx-click="shares-open"`, `"airdrop-open"`, `"access-open"`, `"item-share-open"` | **YES, proven** | auto | **YES** — topmost at 148–180 of 240 points; the row went 240/240 visible → **0/240** |
| 2 | `.profile-modal` | **real UI**, `phx-click="show-profile"` | **YES, proven** | auto | **YES** — topmost at 60/240 with the overlay under it; row 0/240 visible |
| 3 | `.modal-backdrop` / `.modal-card` (secondary picker) | synthetic (the opener is not on a paper doc's header) | structurally yes — `editor_fields.ex:166` is rendered by `components.ex:1900` **outside** the pane `cond`, beside the editor | auto | **YES** — 580×753 over the band, 240/240 occluded |
| 4 | `.bp-ae-modal` (asset explorer "New folder") | synthetic | Media desk only (`bp-asset-explorer.js:241`, `media_live.ex:36`, `components.ex:1763` — a `cond` **branch** whose sibling is the editor) | auto | **YES if ever present** — 580×753, 240/240 occluded |
| 5 | `.bp-ab-overlay` (media picker) | synthetic | reachable from a doc's image field (`field_inputs.ex:280/338`) | auto | **YES** — 580×753, 240/240 occluded |
| 6 | `.bp-slash-menu`, `.bp-paper-context-menu` | synthetic only (need the beta block editor + typing) | body-portal, beta editor | auto | **NOT PROVEN.** Synthetic injection put them off-band (no default coords), so this run says nothing. Ancestry test would count them wherever a point lands. **Open residue.** |
| 7 | **`.bp-paper-format`** (format bubble) | **real UI** — right-click, and a text selection inside the surface | **YES, proven** | auto, z-index 200, fixed | **NO.** 115.453px of content width × 9–26px of band, **topmost at 0 of 240 points**, row still read **580px / 240 visible** |
| 8 | **`.bp-bulk-action-bar`** | **real UI** — tick one `.bp-doc-checkbox` in the list pane, surface stays open | **YES, proven** (rendered at `components.ex:1907`, outside the pane `cond`) | auto, z-index 50, fixed | **NO.** rect top 830 h 50, 422.563px of content width × 50px of band, **topmost at 0 of 240 points**; the 0.9 scanline sits at **823.7px — six pixels above the bar** |
| 9 | `.bp-ae-toast` | synthetic (its host is `bp-asset-explorer.js:184`, Media desk) | Media desk; **not** on a paper doc in this run | **none** | **NO** — and correctly so: it lands in `invisible_occluder_census`, which the synthetic arm fired (`count: 1`, `bp-ae-toast@200`) |
| 10 | `.bp-press-answer` | present by construction on every desk | **YES** | **none** | **NO** — `invisible_occluder_census` catches it. Observed live at `count: 1` in the first run, which is the proof that census is **occupied**, not merely non-crashing |
| 11 | The scrim (`::after` pseudo) | n/a | yes, at sub-860px user-opened widths | none | **Deliberately not subtracted** (D111) — reported as `dimmed_content_px` + `scrim_alpha`, forced-sample diff |

**Delete modals were not exercised.** `paper-delete-block` and the delete confirm were skipped by
name in the probe: opening a destructive confirm on production is not a read-only act worth the
risk, and their geometry is identical to `.history-modal`/`.profile-modal` (3068 vs 3043/3160 —
same `position: fixed`, same z-index 51, same centring), which WERE exercised.

**Nothing in this task is modal-exclusive with the paper surface.** The filing hoped `.bp-ae-toast`
or `.bp-bulk-action-bar` might be confined to Media Desk / list contexts. The bulk bar is not:
`bulk_action_bar/1` is rendered by `components.ex:1907` **outside** the per-pane `cond`, and it was
summoned for real with the surface open in two clicks. The toast IS Media-desk-hosted
(`bp-asset-explorer.js`), but the asset explorer is a pane, and panes stack — so a Media pane
beside a document pane is not excluded by anything read here. It is recorded as
**not-observed-concurrent**, never as impossible.

---

## What shipped

`occlusion.unsampled_occluder_census` in `scripts/studio-desk-measure.mjs`: every element that
paints, whose pointer-events are **not** none, whose rect overlaps the measured band, and which was
topmost at **none** of the points the natural sample probed. Plus `reject_reasons`, so a zero census
can say which test every candidate died on rather than being indistinguishable from a predicate that
never ran.

It **changes no number** (D81). Subtraction would be wrong twice: a band-overlap rectangle is not
the occluded WIDTH of a reading line, and raising scan density would multiply every row's cost for
chrome that narrows no column. What was missing was any statement that these existed.

The predicate `classifyUnsampledCandidate` is pure and exported; `PAGE_MEASURE` interpolates **its
own source**, and `scripts/studio-desk-unsampled-occluder.test.mjs` asserts that, so a hand-copied
twin cannot make the suite a green with no subject.

### Live positive control (shipped `PAGE_MEASURE`, same page, same session)

```
clean                | visible_content_px 580 | unsampled.count 2 | invisible.count 0
                       studio-footer 580x43.188 | phx-connected 580x17.594
with format bubble   | visible_content_px 580 | unsampled.count 8 | invisible.count 0
                       ... | bp-paper-format pe=auto z=200 115.453x9 | 5 of its buttons
scanline_spacing_px 150.6 | band_height_px 753 | sampled_topmost_count 11
```

`visible_content_px` is **identical** in both. That is the defect, stated as a number.

### Mutation proofs (`node --test scripts/studio-desk-unsampled-occluder.test.mjs`)

| Mutation | Result |
|---|---|
| predicate never returns a residue (the family removed from the metric) | `fail 2` — the bulk-bar and format-bubble arms |
| drop the `already sampled` guard | `fail 1` — the CONTROL arm |
| replace the interpolation with a hand copy | `fail 1` — THE SHARING PROOF |
| restored | `pass 10 / fail 0` |

Whole glob through the floor: `ran 139 tests from 11 files (pass 139, fail 0) [floor 9 files]`.
The workflow floor was raised 8 → 9 in the same commit that added the suite.

---

## What was NOT run

- No Elixir test ran; no Studio LiveView code was touched.
- The **beta block editor** was never entered, so `.bp-slash-menu` and `.bp-paper-context-menu`
  have **no measured verdict**. Their synthetic injections landed off-band (no default position)
  and prove nothing. This is the honest residue of this packet.
- No delete/destructive modal was opened.
- `scripts/studio-desk-measure.mjs` was never run end-to-end as a full 54-row sweep; the shipped
  `PAGE_MEASURE` was evaluated directly on one document, twice.
