# Paper Excellence — Epic Charter

Epic task: `task-4792223ca9eb5a7d` · Wave 1 Paper: `paper-excellence-wave-2026-08-12` · Benchmark artifact: `tooling/paper-excellence/evidence/erasure.html` (55,094 B, self-contained; 20 baseline PNGs + 5 reference JPEGs beside it, sealed by `MANIFEST.sha256`).

## Vision

A reader opening `/papers/<slug>` gets what the Eight-Minute Erasure artifact delivers — editorial display typography, a centered 66–72 CPL measure, accent discipline where color carries verdicts, and evidence devices (charts, casts, figures) that stay legible at every width — while a cold agent landing in Barkpark finds the Paper door easier and better-looking than hand-rolling HTML. Every change is systemic (improves all ~750 papers) or it is a ranked wave-2 block proposal; every claim is settled in measured pixels, never vibes. This is the Heggemsnes Act: humility enforced by instruments.

## Decisions

- **D1 — The crown defect is real and measured: reader body prose renders 16px while the token says 18px.** `--bp-body-size` has zero consumers on the reader (`bulldocs.html.heex:694` sets line-height but no font-size; the only consumers are Studio/editor surfaces). Fix by consuming the token on the reader surface. *Why: proven live in both themes; Studio edits at 18px while the world reads 16px.*
- **D2 — The token fix alone is a trap: rem-based role sizes must move to em in the same PR.** Applying 18px collapses the ingress/body scale 1.28×→1.14× because ingress/eyebrow/byline/pullquote are root-relative rem. *Why: simulated live; ratio measured before/after.*
- **D3 — Measure target is 66–72 CPL (today: 84 avg at 640px/16px); nothing is justified and the column is already centered.** The direction's "left-hugging justified" premise was refuted twice; only `hyphens: auto` is real, and it goes off with the new measure. *Why: Range-walked CPL counts; zero `text-align: justify` repo-wide and live.*
- **D4 — Gate before glow-up: the View↔Edit parity test must catch one-sided ADDs before any typography merges.** §2/§5/§6 are intersection-only — the literal crown fix (font-size on `.bp-paper-surface p`) shipped GREEN through all 1,156 portable_doc tests, the mirror check, and design/check.mjs. §7's View-exhaustive shape is the model. *Why: mutation-proven hole (v2 c1); shipping type changes unverifiable would be building on sand.*
- **D5 — Normalize at write, refuse only the unrescuable; the arm is TYPE-KEYED, never generic-over-items.** notes/cards/pipeline string items → `%{"text" => s}`; `text`-keyed inline leaves → `value`-keyed. Byline string items are CANONICAL (215 papers, 28% of corpus) — a generic "items must be maps" arm would refuse them all. *Why: census settled blast radius (2 papers malformed vs 215 canonical); silent acceptance already erased 4 live papers to hollow 200s.*
- **D6 — Adopt, don't re-file, the hollow-paper prior art.** `cch-w57-bl-eleven-papers-render-200-with-prose-the-reader-drops` is open (p1) and owns the text-keyed-leaf repair; corpus repair happens by re-publish AFTER the normalizer deploys. *Why: third duplicate of the same guard is a real risk (v5 warning).*
- **D7 — The 63KB ingest ceiling is FOLKLORE — refuted at 252,360 bytes → HTTP 200.** The real cap is 5,000 first-pass words / 80 blocks / 16 headings, and binds ONLY the exact tag `epic-cycle-wave-paper`; closed expandables are exempt from the word cap. *Why: bracket re-run at exact bytes; both wave-30 ends now answer 200.*
- **D8 — The twin publishes UNTAGGED (no `epic-cycle-wave-paper`)**, tags `authoring-excellence`/`bulldocs`/`design-language`, title differentiated against heggemsnes-act (dedup wall fires at similarity ≥~0.36). *Why: caps would not bind anyway (11 headings, ~1,950 words) and the tag semantically means "canonical Epic Cycle Paper".*
- **D9 — `lineage` is NOT the clock strip — refuted in pixels** (3+1 wrap at 720px, stacked list at 360, zero spine element). A true horizontal dated strip is a wave-2 block proposal. Chart/mermaid narrow-width illegibility (4.3px/3.7px text at 360) IS systemic and gets fixed now, plus the point-annotation edge clamp and region-tone opacity. *Why: v3 measured all of it; two of three survey lanes had guessed wrong.*
- **D10 — The merge instrument is a HERMETIC render+screenshot rig** (mix run --no-start `render_block` + layout assembly + local static serve + vendored Playwright): pixel-metric identical to guerrilla, no server, no DB, no network. Guerrilla-pointed rigs must cold-fetch (reader ETag is content+7-day-bucket, blind to renderer/CSS deploys). Assert page CONTENT, never HTTP status (port-squat trap proven). *Why: v7 proved 19/19 blocks byte-identical and CSS 154,732 B both sides.*
- **D11 — Onramp: demote the HTML door in copy, add Papers to the onramp body, point `bp paper` at the write door.** The manifest's one authoring line advertises HTML payloads; the onramp block mentions papers zero times; 31 papers (4.1%) are body_html-only and lose all table structure in the TUI. The summary string lives in 5 files and reds the OpenAPI drift gate (CI-artifact regen route; local regen OOMs). *Why: v10 located every copy + proved the onramp golden gate fires 4-way.*
- **D12 — Spacing doctrine is READER-OWNED: zero empty-paragraph spacers, ever** (the old "author gaps as spacers" law is retired; 351 purged). Additionally the spacing_norm advisory is doubly broken — counts `text`-keyed paragraphs as spacers (false positive on every correctly-authored paper) and never descends into nested blocks (false negative the tagged hard gate then catches) — both fixed in the wall slice. *Why: mutation-proven at both ends (v3, v4).*
- **D13 — Evidence durability: the benchmark + baselines get COMMITTED** (`tooling/paper-excellence/evidence/`, 28 files, 7.4 MB — invisible to the filebase critic, fanout under threshold) in the rig slice's PR. Baselines are fold-only 1× vs the artifact's full-page 2×; the rig reshoots full-page/2× before pinning thresholds. *Why: everything proven evaporates with the scratchpad otherwise (v6).*
- **D14 — Rounds are law: typography (S7) is round 2, after the gate (S1) merges.** A slice that would ship green through a blind gate never dispatches beside the gate fix. *Why: stale-green merge window + guard/fix co-merge lessons.*
- **D15 — Color-token work is deferred**: a new color token drags derive SLOTS + 5-theme formulas (Part F reds on sight) while type/measure tokens are free to add and inert until emitted+consumed. The verdict accent pair (loss/peace) is a wave-2 proposal. *Why: v8 measured the asymmetry end-to-end.*

## Roadmap

### Wave 1 (this wave) — instrument, close the systemic half, open the door
1. **S1 `pe-w1-parity-gate-one-sided-adds`** — harden view_edit_parity §2/§5/§6 to View-exhaustive with a documented-divergence allowlist; mutation-proof it against the v2 c1 shape. (small, opus, round 1)
2. **S2 `pe-w1-write-path-normalizer`** — normalize-on-write for notes/cards/pipeline items + text→value leaf coercion; type-keyed wall arm for unrescuable shapes; fix both spacing_norm defects; accept bare-string table cells by normalizing. (large, fable, round 1)
3. **S3 `pe-w1-figure-legibility`** — chart+mermaid SVG text non-scaling at narrow widths; point-annotation edge clamp; region tone opacity. (medium, fable, round 1)
4. **S4 `pe-w1-erasure-twin`** — port erasure.html to `/papers/eight-minute-erasure` with only the existing deck; first-class friction log; publish the premium-paper guide `/papers/paper-authoring-excellence`. (large, fable, round 1)
5. **S5 `pe-w1-hermetic-screenshot-rig`** — commit the evidence archive; build the hermetic render+screenshot rig with full-page 2× baselines and a content-asserting gate script. (large, opus, round 1)
6. **S6 `pe-w1-paper-door-copy`** — bulldocs.ex summary + flag copy demote HTML; onramp AGENTS.md papers section (golden + 3 wrappers); `bp paper` usage names the write door + guide slug. (medium, opus, round 1)
7. **S7 `pe-w1-reader-editorial-typography`** — consume body tokens on the reader, rem→em role conversion, editorial scale (h1/body ≥ 2.0), measure to 66–72 CPL, hyphens off, both mirrors + emit plumbing. (large, fable, **round 2, after S1**)

### Wave 2+ (filed backlog)
- `pe-bl-clock-strip-block` — true horizontal dated strip with a connecting spine (lineage rewrite or new block).
- `pe-bl-verdict-accent-tokens` — semantic loss/peace token pair through derive SLOTS, 5 themes.
- `pe-bl-code-emphasis` — code block language + line-emphasis ranges (comment/offending/fixed).
- `pe-bl-asciicast-selfhost` — self-hosted player, .cast hosting via media, speed/transcript/idle-compression.
- `pe-bl-stat-tile-dots` — trial-dot arrays, second sub-line, verdict coloring on stat values.
- `pe-bl-type-literal-ratchet` — check.mjs type/measure literal ratchet + built bp-paper-editor.css freshness gate + reader-shell (bulldocs.html.heex) typography gate.
- `pe-bl-bp-paper-scaffold` — `bp paper new` emitting a valid starter block tree.
- `pe-bl-container-child-guard` — wall guard for unknown block types carrying children (silent content loss today).
- `pe-bl-probe-paper-cleanup` — delete the 10 probe papers this wave left on guerrilla.
- Corpus repair of the 10 hollow text-keyed papers: adopt `cch-w57-bl-eleven-papers-render-200-with-prose-the-reader-drops` (open, p1) — do not re-file.

## Wave log

### Wave 2026-08-12 — wave 1 (Twin and Close), reviewed A-

All six round-1 slices landed green, file-disjoint (octopus merge onto origin/main is conflict-free; integrated tree runs content+portable_doc at 2222/0). Review re-ran every gate, mutation-proved the parity gate (§2 reds on the exact crown-fix shape) and the evidence manifest (tamper → FAILED), and independently re-derived the S2 HIGH-FLIP-RISK blast radius: 46 live corpus blocks byte-identical through `normalize_render_shapes`, byline string items untouched, notes/text-keyed leaves rescued and rendering their prose. No review fixes were needed — final branches are the builders' own.

- **S1 `pe-w1-parity-gate-one-sided-adds`** — §2/§5/§6 now producer-exhaustive with a 9-entry `@documented_divergences` allowlist + rot guard. One direction per section is still ungated (mirror-only adds ship green) — recorded, acceptable this wave.
- **S2 `pe-w1-write-path-normalizer`** — all five defects fixed at the one chokepoint; refusals only got MORE satisfiable. Steps/columns nested containers are still unwalked by the leaf pass (narrow, recorded). Second independent review before merge is warranted per flip-risk protocol.
- **S3 `pe-w1-figure-legibility`** — measured floor: ticks 5.09→11.0px, mermaid 3.60→16.0px at 360; annotation clamp; region tone ladder. Every chart now scrolls below ~670px containers (uniform floor, accepted). Rig baselines with charts go stale on merge — regen after S3 lands.
- **S4 `pe-w1-erasure-twin`** — `/papers/eight-minute-erasure` (46 top-level blocks, zero HTML, zero spacers) + `/papers/paper-authoring-excellence` live; FRICTION.md's 12-row residual table classifies every gap SYSTEMIC/BESPOKE with an owner. The two .cast media assets are draft docs (purge hazard → `pe-bl-asciicast-selfhost`). Dedup wall non-fire on an exact-title clone is residual 12.
- **S5 `pe-w1-hermetic-screenshot-rig`** — rig green end-to-end in a cold worktree (render → 6 full-page 2x shots → 30 content assertions); 27-file evidence manifest verifies and can fail. Baselines are macOS-face; nothing may be pinned numerically until `pe-w2-rig-ci-image-baselines`. Gate not yet wired into CI.
- **S6 `pe-w1-paper-door-copy`** — all three door surfaces sell blocks + the leaf law + the guide slug; openapi hand-edit independently re-verified byte-equal to the Elixir literal. "56 renderer block types" is the survey's census (tiers.ex holds 77 incl. 14 field atoms + 6 chat rows) — defensible, not re-counted from scratch.

Merge order: any; S6's guide pointer is already live (S4 published before merge). Lead closes each task's "PR merged" criterion on merge. Deferred by design: **S7 `pe-w1-reader-editorial-typography` (round 2) dispatches only after S1 merges** — it is the wave's crown payoff (18px token, rem→em roles, 66–72 CPL, hyphens off). After S3 merges, refresh the rig baselines; after the corpus normalizer deploys, re-publish repairs ride `cch-w57-bl-…` (adopted, not re-filed). Wave Paper: `paper-excellence-wave-2026-08-12` (debrief appended).
