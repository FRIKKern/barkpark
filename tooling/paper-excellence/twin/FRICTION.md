<!-- doc-tier: human | canonical-for: eight-minute-erasure twin friction log | budget: 4000tok -->

# The Eight-Minute Erasure twin — friction log

Wave 1 of the Heggemsnes Act's paper-excellence epic (`pe-w1-erasure-twin`,
wave Paper `paper-excellence-wave-2026-08-12`). The benchmark artifact
`tooling/paper-excellence/evidence/erasure.html` (55,094 B, fully
self-contained) was ported into `/papers/eight-minute-erasure` using ONLY the
existing block deck — `payload.json` in this directory is the exact published
payload. This file records every point where the deck resisted, every wall
refusal verbatim, every silent-drop class authored around, and the ranked
residual gaps after screenshot comparison (`shots/` vs
`../evidence/full.jpeg` + `../evidence/shots/`).

The port passed the publish wall on the FIRST attempt (`rev: 1`) — not
because the wall is soft, but because this wave's sixteen survey lanes and
ten verifiers had already mapped every trap before the port began. A cold
agent without that map would have hit most of the refusals below.

## 1 · Block mapping actually used

| Artifact device | Deck block(s) used | Fidelity |
|---|---|---|
| Masthead (eyebrow row, display h1, thesis) | `eyebrow` + `heading` level 1 + `ingress` | structure kept; display scale + accent-italic word lost |
| Four-stop clock strip | 2-col headed `table` (`lineage` REFUTED as a strip — wraps 3+1 at 720px) | data kept; tile geometry + peace/loss accents lost |
| Timeline SVG (proportional axis, span bracket) | `figure` wrapping `diagram` (mermaid flowchart LR) | events kept; proportional spacing + colored marks lost, loss logged in the figure caption itself |
| Forensics + race terminal casts | `asciicast` with HOSTED `.cast` src on guerrilla media | replayable; custom player chrome lost |
| Cast transcripts | `expandable` (summary + `code` child) each | full fidelity |
| He-wrote / it-was-replaced-with swap | `columns` of two `callout`s (success/danger) | full fidelity minus mono register |
| Erased / kept rails | `callout` tone danger / success | full fidelity minus mono quoted register |
| Aggregator code with `.hl`/`.ok` emphasis | `code` (lang elixir) | source kept; READ/MODIFY/WRITE color emphasis lost, ACCEPTED per brief |
| Stat tiles with per-trial dot arrays | `stats` (3 items) | numbers kept; dots degraded to "2 of 10 trials affected" label text |
| Measured verdict table | `table` with `code`-marked numeric cells | data kept; right-alignment + tabular-nums discipline lost |
| Declaration panel (2px ink frame, sig rule) | `section` + ordered `list` + neutral `callout` | content kept; the framed-panel gravity lost |

Block census of the published payload (46 top-level, 0 empty paragraphs):
asciicast 2 · callout 9 · code 3 · columns 1 · diagram 2 · expandable 2 ·
eyebrow 1 · figure 2 · heading 11 · ingress 1 · list 1 · paragraph 19 ·
section 1 · stats 1 · table 2. Rendered page: zero `Unsupported` placeholders
(the single grep hit is inside a CSS comment), both mermaid sources hydrated
to SVG, both cast players mounted.

## 2 · Every point the porter was tempted toward hand-rolled HTML

1. **The h1 accent word.** The artifact italicizes and reddens *erasure*
   inside the title. `heading` carries a plain `text` string — no inline
   marks. Temptation: `body_html` masthead. Resisted; the accent is gone.
2. **The two-label eyebrow row** (left: provenance, right: date, shared
   rule). One `eyebrow` block carries one string. Folded both labels into one
   string with `·` separators.
3. **The clock strip.** Strong pull toward a raw four-tile HTML grid; the
   probed answer is a headed table. The tile look is unreachable today.
4. **The timeline SVG.** The artifact's is a hand-drawn, labeled,
   proportional axis with an 8m10s span bracket and an off-scale marker.
   Temptation: paste the SVG into `body_html`. Used mermaid via `figure` and
   logged the degradation in the caption, per brief.
5. **The cast player.** The artifact embeds cast JSON in `<script>` tags and
   ships its own 130-line player. `asciicast` demands a hosted `src` —
   `safe_url` silently neuters `data:` URIs to `#` (probed this wave), so
   inline data is impossible. Uploaded both casts through `bp media upload`
   (`/media/files/2026/08/race-97b047b6.cast`, `.../arch-3c4075aa.cast`) —
   relative `/media/...` paths survive `safe_url` by design.
6. **The mono "quoted" register.** Erased/kept quotes render in the
   artifact as 13.5px mono. Callout content is prose; only `code` inline
   marks approximate the register. Used sparingly, accepted the loss.
7. **Code emphasis spans.** `.hl`/`.ok` colored spans inside `pre` are
   inexpressible in a `value`-keyed code block. Accepted and logged.
8. **Stat-tile dots.** Ten-dot trial arrays are pure HTML in the artifact.
   Folded the counts into stats labels instead.
9. **Numeric column alignment.** `td.num` right-aligned tabular-nums has no
   table-cell attribute today. Wrapped numerals in `code` marks to at least
   hold a mono register.
10. **The declaration frame.** A 2px ink border with generous padding and a
    signature rule. `section` groups but draws no frame; the closing
    provenance line became a neutral callout.

## 3 · Wall refusals, verbatim

Hit during this port's probe run (failing publishes create no documents):

**Bare-string table cells** (`probe: head/rows as plain strings`):

```
bp: paper contains block content that readers cannot render
  blocks: ["blocks[1].head.cells[0] has no renderable inline content","blocks[1].head.cells[1] has no renderable inline content","blocks[1].rows[0].cells[0] has no renderable inline content","blocks[1].rows[0].cells[1] has no renderable inline content"]
  hint: Fix the listed block paths so every list item, table row/cell, and nested block has a reader-supported content shape, then republish.
```

**Unregistered tag**:

```
bp: publish references unregistered tag(s): not-a-registered-tag-xyz
  suggestions: {"not-a-registered-tag-xyz":["promise-actor-register","lifecycle-state-register","research-note"]}
  unknown: ["not-a-registered-tag-xyz"]
  hint: Every tags[].tag must be a registered tag — publish a type:tag document whose _id is the tag name, or switch to one of the registered tags in details.suggestions, then publish again.
```

**Dedup wall NON-refusal (finding).** A probe publish titled exactly
"The Heggemsnes Act" (h1 block) with a `bulldocs` tag was expected to 409 on
title similarity against `/papers/heggemsnes-act`. It PUBLISHED (`rev: 1`,
advisory `warning[label_norm]` only; probe deleted immediately after). The
dedup wall as deployed did not fire on an exact title clone with one
overlapping-register tag — either the similarity threshold sits above exact
title identity alone or the trigger needs combined title+tag mass. The twin's
differentiated title was therefore never actually load-bearing. Residual
filed in the table below (SYSTEMIC).

**Advisory band observed** (success path, not a refusal):

```
warning[label_norm]: pe-w1-friction-probe-dedup: 1 tag(s) — the norm is 2–4. Every extra label dilutes the strong ones; weak entries are pruning candidates.
```

## 4 · Silent-drop classes authored around (each proven live this wave)

| Silent drop | Consequence if hit | How the payload avoids it |
|---|---|---|
| `text`-keyed inline leaf | leaf renders as EMPTY string; paragraph vanishes behind a 200 | every inline leaf is `value`-keyed |
| `container` block type | renders Unsupported and DROPS its children | nesting via `section` / `columns` / `figure` only |
| `data:` URI in `asciicast.src` | `safe_url` neuters to `#` at render — no error at publish | casts hosted on guerrilla media, relative paths |
| plain-string `notes` items | empty 4px rows (the heggemsnes-act live defect) | no `notes` block used |
| empty-paragraph spacers | doctrine violation (reader-owned spacing; 351 purged) | zero spacers; rhythm left to reader tokens |
| `code` key on code blocks | empty `<pre>` | source under `value`, always |
| grid `span` inside a `layout` map | ignored | span/order are top-level child keys (none needed in final payload) |

## 5 · Ranked residual gaps (screenshots: `shots/` vs `../evidence/`)

Compared: twin light/dark at 1440 and 768 (full-page 1x) against the artifact
`full.jpeg` (2x) and `shots/` baselines. Rank 1 = greatest remaining visual
distance to the benchmark.

| # | Residual gap | Measured observation | Class | Owner |
|---|---|---|---|---|
| 1 | Display type scale | artifact h1 clamp(42–82px) serif at 1.02 leading; twin h1 renders at reader default (~2.6x smaller), no accent-italic word | SYSTEMIC | `pe-w1-reader-editorial-typography` |
| 2 | No wide band | artifact floats figures/casts/tiles to 1040px while prose holds 66ch; twin caps EVERY block at the ~720px text column — casts and diagrams feel cramped at 1440 | SYSTEMIC | `pe-w1-reader-editorial-typography` |
| 3 | Verdict accent semantics | artifact's loss-red/peace-green thread (clock, timeline, code, dots, table) collapses to callout tones only; color stops meaning something between blocks | BESPOKE | `pe-bl-verdict-accent-tokens` |
| 4 | Clock-strip geometry | four mono tiles with colored time stamps became a 2-col table — correct data, none of the "dashboard" gravity | BESPOKE | `pe-bl-clock-strip-block` |
| 5 | Timeline proportionality | mermaid flowchart spaces four events evenly; the artifact's axis makes the 8-minute compression VISIBLE, which is the argument | SYSTEMIC | `pe-w1-figure-legibility` (chart-annotation route becomes viable once ticks/labels are legible) |
| 6 | Body prose 16px vs 18px token | crown defect, both themes, measured by v1 | SYSTEMIC | `pe-w1-reader-editorial-typography` |
| 7 | Stat-tile dots | per-trial dot arrays degraded to label prose ("2 of 10 trials affected") | BESPOKE | `pe-bl-stat-tile-dots` |
| 8 | Code emphasis | READ/MODIFY/WRITE hl spans flattened to plain mono | BESPOKE | `pe-bl-code-emphasis` |
| 9 | Cast player chrome | CDN asciinema player with stock chrome vs the artifact's integrated bar/track/transcript unit; player JS is third-party | BESPOKE | `pe-bl-asciicast-selfhost` |
| 10 | Numeric table discipline | no right-align/tabular-nums cell affordance; `code`-mark workaround changes the register instead | SYSTEMIC | `pe-w1-reader-editorial-typography` |
| 11 | Declaration framed panel | section renders children flat; the 2px ink frame + sig rule that makes VII read as a signed document is gone | BESPOKE | `pe-bl-declaration-panel` (filed this wave by this slice) |
| 12 | Dedup wall under-fires | exact-title clone of a live paper published without a 409 — the wall the twin was told to route around did not exist at this threshold | SYSTEMIC | `pe-w1-write-path-normalizer` (wall ownership; needs its own verification before any threshold change) |

Gaps 1, 2, 6, 10 fall to round-2 typography (dispatched after the parity
gate merges, charter D14). Gap 5 falls to this wave's figure-legibility
slice. Gap 12 is a finding for the write-path slice's reviewer, not a
regression this port introduced.

## 6 · What did NOT hurt

Worth recording so the onramp sells the truth: paragraph/strong/em/code
inline marks, ordered lists, headed tables (with map cells), toned callouts,
two-column layout, section grouping, expandable transcripts, mermaid
hydration on the reader, and `bp media upload` for cast hosting all worked
FIRST TRY, exactly as documented by this wave's probes. The friction is real
but narrow: display typography, accent color, and four bespoke devices.
