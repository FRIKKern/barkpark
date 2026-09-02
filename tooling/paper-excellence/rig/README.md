<!-- doc-tier: human | canonical-for: paper-excellence-render-rig | budget: 9000tok -->

# Paper render + screenshot rig

A paper goes in as committed JSON, a photograph comes out. **No server, no
database, no network** — so the same command answers the same way on a laptop,
in CI, and a year from now.

```sh
bash tooling/paper-excellence/rig/gate.sh              # the gate: render + shoot + assert
bash tooling/paper-excellence/rig/gate.sh --panel      # every committed fixture, one command
bash tooling/paper-excellence/rig/gate.sh --panel --check   # …and diff the committed numbers
bash tooling/paper-excellence/rig/baseline.sh          # re-capture the committed panel
bash tooling/paper-excellence/rig/fetch-fixtures.sh    # the ONE networked step: refresh fixtures
```

Any path the shell accepts works: `gate.sh` resolves the fixture and the out-dir
to **absolute** paths before it `cd`s into `api/`. Until 2026-08-17 it did not,
so the natural repo-relative invocation
(`gate.sh tooling/paper-excellence/rig/fixtures/design-probe.json`) died inside
`render.exs`, which `File.read!`s the path verbatim from `api/`.

| file | what it does |
|---|---|
| `render.exs` | renders a fixture through the real `PortableDoc.Render` + the real bulldocs layout |
| `shoot.mjs` | serves the rendered page on loopback and photographs it, asserting DOM content |
| `census.mjs` | the heavy-rule census — one measurement function, run on the artifact AND on a rendered paper |
| `gate.sh` | render + shoot a committed fixture (`heggemsnes-act` by default, `--panel` for all 8); nonzero on any content failure |
| `baseline.sh` | the same path, writing into `baselines/` so a refresh is a reviewable diff |
| `fetch-fixtures.sh` | pulls paper blocks from Barkpark via `bp` and rewrites `fixtures/*.json`; its default slug list is every **published** fixture (`design-probe` is authored and has no live doc — `eight-minute-erasure` once drifted purely by being absent from this list) |
| `fixtures/` | 8 papers, each stamped with the `source_rev` it was taken from (`design-probe` and `stat-partial-row` are authored, not published) |
| `baselines/` | the committed panel (see below) |

## How it stays hermetic

`render.exs` runs under `cd api && MIX_ENV=test mix run --no-start`. Only
`:phoenix`, a PubSub and `BarkparkWeb.Endpoint.start_link/0` come up; the Repo
is never started (nothing can touch a database) and `config/test.exs` sets
`server: false` (no socket is opened). First run recompiles ~823 files
(~30-90 s); after that it is warm.

`shoot.mjs` serves the page from a temp dir on **port 0** — the OS hands out a
free port, so nothing can be squatting it — and aborts every request whose host
is not `127.0.0.1`. Playwright is resolved from `$PLAYWRIGHT_DIR`, else from
`js/node_modules/node_modules/playwright` under this checkout or under the
primary checkout (derived at runtime from `git rev-parse --git-common-dir`).
There is not one absolute machine or session path in this directory:

```sh
grep -rE "(/Volumes/|/Users/|/home/)" tooling/paper-excellence/rig/   # no hits
```

## What the rig asserts (and what it deliberately does not)

Five assertions per cell, all on **DOM content**, never on an HTTP status — a
squatted port once answered `200` with unrelated JSON, which is exactly the
false green this rig exists to refuse:

1. `main.bp-paper-article` exists,
2. it still carries `bp-paper-surface`,
3. at least one paragraph is inside it,
4. its computed `max-width` is not `none` (a dead `.bp-paper-shell` rule leaves
   the paper measuring at BODY width — the shape that silently makes every
   typography number wrong),
5. the written image file is a real image (see the JPEG trap below).

**Excluded from every assertion**, because the network is blocked:
`diagram`/mermaid blocks, `asciicast` blocks (both hydrate from
`cdn.jsdelivr.net`), and remote images. Typography and geometry are unaffected
by the block — that was measured — but those blocks do not draw, so the
baselines show them un-hydrated and nothing here claims otherwise.

### Two traps the code is shaped around

* **`render_html/2` is the wrong door.** It takes a Pd tree, not a paper's
  `blocks` list. Handed `%{"blocks" => …}` it returns a ~97 KB CSS-only shell
  with the prose missing — a vacuous green. The rig renders block by block
  through `render_block/2`, the same call the reader LiveView makes.
* **The wrapper is not in the layout.** `<main class="bp-paper-shell
  bp-paper-surface bp-paper-article">` lives in `bulldocs_live.ex`. The rig
  hand-adds it and then asserts the class list against that file, so LiveView
  drift reds the rig instead of quietly re-measuring the wrong element.
* **Neither is the per-block wrapper.** The block-backed reader does not
  concatenate block HTML into the article: it streams each top-level block as
  its own keyed item, `<div id data-block-id>` (`phx-update="stream"`). The rig
  reproduces that, and asserts the item's shape against the LiveView the same
  way. Margins collapse to identical numbers either way, which is why the bare
  concatenation looked harmless for as long as it did — but any rule that
  selects on document POSITION is true in one shape and dead in the other, and a
  rig photographing the wrong one cannot tell those apart. The section head's
  `> #paper-body > div:not([class]) > h2` leg is the first such rule.
* **A JPEG capture can write nothing at all.** Playwright's JPEG encoder emits
  a **zero-byte file, without throwing**, when a full-page capture exceeds
  JPEG's 65,535 px dimension cap — which a ~100-block paper at 2x can do
  (`hobby-hardening-capstone`, found 2026-08-12). The rig stats every file it
  writes and **fails hard** on anything under `MIN_SHOT_BYTES`. An `@1x`
  demotion retry used to sit in front of that fail; it was removed as untested
  code — see the `@1x` bullet under Deliberate limits.

## The theme pin

`render.exs` pins `data-bp-theme` to **`evergreen`** and asserts the pin equals
`Barkpark.Tenancy.default_theme/0`. `Layouts.bp_theme_attr/1` omits the
attribute when the theme is the default, so pinning the default reproduces the
default page byte-identically. A workspace on another theme (e.g. `fjord`)
drifts **colors only** — geometry and type are unaffected. If the product
default moves, the rig reds rather than silently re-baselining every shot.

## Baselines

`baselines/` holds the 8-paper panel: `design-probe`, `eight-minute-erasure`,
`heggemsnes-act`, `hobby-hardening-capstone`, `mechanical-spacing-doctrine`,
`paper-excellence-wave-2026-08-12`, `portabledoc-showcase`, `stat-partial-row`
— **full page**,
light and dark, at **1280 and 1920**, `deviceScaleFactor: 2`, JPEG q72, plus a
`*.report.json` per paper recording column width, **evidence-band width per
component, prose characters-per-line, document horizontal overflow, the air
+ rule at every section boundary, and the full rule census** (total, heavy,
per-weight histogram and every heavy rule with its owner), paragraph count, scale
and blocked-request count — and, per cell, the four **crown measurements**
(pe-w2-bl-device5-ratio-arm):

* **`ingressRatio`** — the canonical-text ingress/body CPL ratio, **asserted**
  at `0.783 ± 0.01` per cell (see the next section).
* **`toneSamples`** — the computed color, background and left-margin accent of
  every tone-classed callout/card variant present, per theme. This is the
  **marginal-color-as-verdict** device (crown D5/D21) measured rather than
  claimed: the verdict a callout or card carries IS the colour of its left
  margin, resolved through the existing `--bp-tone-*` / `--st-*` tokens — the
  device already ships on those tokens, **zero new tokens**, and this key is
  where a token remap or a dead tone class becomes a text diff.
* **`h2Px`** — the rendered font-size + weight of a prose h2 (36px/400 since the
  display-scale device, charter D29/D36 — was 27px/600; this key is where that
  move is a reviewable number).
* **`statTracks`** — the resolved grid track count of every `.bp-stats` strip
  (8 at 1920, 7 at 1280, 4 at 768, 1 at 360 today): the stat-density device's
  width signal. Absent elements record null-with-reason; a strip that is
  present but yields zero tracks **fails the run** — the measurement refusing
  to go vacuous.
* **`statRemainder`** — per `.bp-stats` strip: the resolved track count, the
  cell count, the number of EMPTY tracks in the last row (only a strip with two
  or more rows can have any — `auto-fit` collapses a track that is empty in
  every row, so a lone short row stretches to full width), and — when there
  are any — what `elementFromPoint` hits at the centre of the first empty track
  plus that element's computed background. The partial-last-row slab
  (task-0098ba55d2642545): the hairline grid used to be a rule-tinted container
  ground showing through 1px gaps, which painted every empty track as a solid
  slab. The seams are drawn per cell now and the container is transparent, so
  the probe **asserts** the hit is the strip's own container with a
  transparent background; a fixture that carries a partial row but yields no
  probe fails too (anti-vacuity). `stat-partial-row` is the committed fixture
  that has one at every panel width (11 cells — prime, so no track count
  divides it: 8+3 @1280, 9+2 @1920).

## The ingress-ratio arm

The opening ingress reads bigger than the body prose, and the relationship is
asserted as a **ratio of characters-per-line — the same canonical probe text
measured under both computed styles** (`INGRESS_RATIO = 0.783`, tolerance
`± 0.01`, per cell). Canonical text, never each element's own words: own-text
ratios are per-character sampling noise (0.759–0.821 healthy across the panel,
0.003 of margin at any threshold) while the canonical form reads 0.783 on every
fixture at every width with ~0.05 of margin per side.

The arm is **mutation-proven**: re-imposing the pre-#11626 `font-size: 1.28rem`
on `.bp-role-ingress` (the rem-frozen sizing that #11626 removed) moves every
cell to **0.880** and the run reds with
`canonical ingress/body CPL ratio measures 0.88, outside 0.783±0.01`. A fixture
that carries `.bp-role-ingress` but yields no sample is a **failure**, not a
skip — an arm that silently misses the element it was built for is the vacuous
green this rig exists to refuse.

A paper opens a section in one of **two shapes**, and both are measured:

* **heading** — a top-level level-2 heading. The section-head device sizes this
  one (92px of air over a 2px rule), and it is the only shape the gate asserts.
* **container** — a `section` BLOCK, which composes to a flex stack whose first
  child is a leading rule (`compose_section_stack/2`). Its eyebrow and h2 live
  *inside* the container, so no top-level selector reaches them and the device
  does not size it. Measured at **16px over a 1px rule** on `design-probe`.

The container shape is reported, never asserted — it is an open finding, and a
gate that held a committed fixture to a target nothing implements would be a
red with no fix behind it. `doubledRules` rides the same rule: it records
consecutive containers stacking a trailing and a leading rule (**32px apart** on
`design-probe`), which is a three-engine contract and not a stylesheet bug.

`inkOffCentre` was the third such finding and is now **asserted**. A
content-narrow table had a full-width perfectly-centred **box** whose **ink**
pinned to the band's left edge (290.6px of ink, 374.7px off the column axis on
`design-probe`) — a shape the box-centre assertion passes at 0. The band is a
ceiling now rather than an issue, so ink and box agree; the assertion exempts a
row whose ink is WIDER than its box, because that component is self-scrolling and
where its ink sits is a scroll position rather than a layout fact.

## The report check — the committed numbers as an oracle

```sh
bash tooling/paper-excellence/rig/gate.sh --check [fixture.json] [out-dir]
bash tooling/paper-excellence/rig/gate.sh --panel --check
node tooling/paper-excellence/rig/shoot.mjs --report-diff <baseline.report.json> <fresh.report.json>
```

`--check` re-captures under the **baseline env** (`SHOT_FORMAT=jpeg`,
`SHOT_QUALITY=72`, `SHOT_WIDTHS=1280,1920`) and diffs this run's `report.json`
against the committed `baselines/<slug>.report.json`, exiting nonzero on any
numeric drift. Until 2026-08-17 nothing did: the gate shot to a temp dir and
asserted, `baseline.sh` overwrote the repo, and the promise above that "a band
regression is a text diff in `report.json`" had no code behind it.

**Image byte counts are ignored, and only they.** The reports are otherwise
byte-reproducible on one host — all 7 fixtures re-shot on 2026-08-17 matched the
committed baselines across **4437** measured values with zero differences — but
one JPEG byte count differed ~1.5% across hosts while every measurement matched.
That is encoder noise, and bytes are already refused as an oracle above.
Everything else is a measurement: column width, evidence band per component,
prose CPL, section beats, doubled rules, the full rule census, paragraph count,
scale, blocked requests.

The check **can lose**, proven by mutation on a copy of
`baselines/design-probe.report.json`:

| copy | result |
|---|---|
| unperturbed | exit 0 — `247 measured values compared, 0 differences (4 image byte counts ignored)` |
| `shots[0].columnWidth` 660 → 661 | exit 1 — `1 measurement(s) drifted … shots[0].columnWidth: 660 → 661` |
| `shots[0].bytes` +99999 | exit 0 — encoder noise is not a layout fact |

A red here is a review item, not a re-baseline reflex: read the drifted numbers,
then `bash tooling/paper-excellence/rig/baseline.sh <slug>` **only** once the
change behind them is the intended one.

`--panel` runs every `fixtures/*.json` in one command. Measured on 2026-08-17
(with the crown measurements in): all 7 pass, **56 shots / 1888 content
assertions** in the default four-width set, and **28 shots** under
`--panel --check`.

The PASS line counts **this run's** shots, read from the `report.json` this run
wrote. `find`ing the out-dir counted every image ever left there, so a 7-fixture
loop over one out-dir reported `8/16/24/…` while each fixture wrote 8 — a number
that grows with the temp dir's history is not a measurement.

## The heavy-rule census

`census.mjs` counts the horizontal rules a reader can see, and it is the SAME
function on both sides of the comparison — the CLI runs it on the benchmark
artifact, `shoot.mjs` runs it on every rendered cell. A rule is a horizontal
border edge that is visible, inked and non-zero; a row of `th` cells merges into
the one underline a reader actually sees; vertical edges are excluded, because a
left edge is a margin accent (the artifact's own verdict device) and not a line
in the page's vertical rhythm.

```sh
node tooling/paper-excellence/rig/census.mjs \
  tooling/paper-excellence/evidence/erasure.html --structural ".sec-head, .declaration"
# → 59 rules, 8 HEAVY — 6 sec-head, 2 declaration frame
```

The artifact spends the heavy weight (2px) on 8 of 59 rules: its six section
openings and the two edges of its closing declaration frame. **That is the
hierarchy** — a thick line means a new argument starts here — and every heavy
rule a component draws costs the boundary its meaning. `shoot.mjs` attributes
every heavy rule to the element that drew it and fails on any that is not a
section head, so this is not a count that has to be re-blessed when a fixture
gains a section. Its twin lives in `design/check.mjs` Part M, which censuses the
stylesheet DECLARATIONS: the rendered arm is blind to a heavy rule on a class no
fixture happens to use, the declaration arm is blind to an inline style, and
neither subsumes the other.

`.bp-declaration` is deliberately **not** on the allowlist. No Barkpark block
emits the framed finale yet, and an allowlist entry that can never match reads as
coverage while gating nothing.

A section beat is measured from the last block that actually **paints**. The
Mechanical Spacing Doctrine authors vertical rhythm as empty paragraph blocks and
the engines emit nothing for them, so the stream carries a real but zero-height
`<div>` per gap. A zero-height box has no margins of its own and comes to rest
*inside* the collapsed margin run above the heading — measuring to it reported
69.6px of a 92px boundary on `hobby-hardening-capstone` until the walk skipped
back past it. The count skipped is recorded per boundary (`skippedEmpty`).

Deliberate limits, stated rather than hidden:

* **Format and widths are a weight decision.** The same panel is **166 MB** as
  full-page 2x PNG and **60 MB** in the committed shape. The 768 and 360 cells
  still run in the gate on every invocation; they are simply not carried in the
  repo. JPEG baselines are for human review and layout regression — quantization
  noise makes them unsuitable as an exact pixel-diff oracle.
* **1280 + 1920 replaced 1440** with `pe-w1-evidence-breakout`. The evidence
  band sits at its 1040px base from ~1120px of viewport up to 1600px and grows
  above that, so 1440 was the same picture as 1280 and no committed cell
  exercised the growth clause. The pair is the smallest panel carrying both ends
  of the band's range. It doubles the panel's weight, which is why the
  **numbers** moved into `report.json`: a band regression is a text diff there
  and needs no image comparison at all.
* **The JPEGs are carried once, the numbers are carried twice.** A new width has
  no counterpart on `main` to diff a picture against, so a change that
  introduces one commits the *measurements* first (captured on the unmodified
  tree) and the pictures with the change — the `report.json` diff is then a true
  before/after at identical paths, and the panel does not have to be stored
  twice to get one.
* **The `@1x` demotion branch is GONE** (removed with
  `pe-w2-bl-device5-ratio-arm`, 2026-08-17). It re-captured at 1x when a JPEG
  came back under `MIN_SHOT_BYTES`, and it **never fired**: zero `*@1x.*` files
  ever landed in `baselines/`, and `hobby-hardening-capstone` — the paper it was
  written for — photographs at **2x** in both formats (18.5 MB as PNG at 1920,
  and its committed JPEGs carry no suffix). Untested code is not a guard, so the
  code caught up with this README: the `MIN_SHOT_BYTES` stat check remains, and
  an under-size capture is now a plain hard red. If a paper ever genuinely
  clears the 65,535px cap, the rig fails loudly and the fix is a deliberate
  decision, not a silent scale change.
* **The legacy shots in `../evidence/shots/` are a different capture**:
  above-the-fold only, `deviceScaleFactor: 1`, 1440x1200, taken against
  guerrilla over the network. They are not comparable to these below the fold,
  and a panel that mixes them compares unlike captures.
* **Type metrics are host-dependent.** On macOS the paper's serif stack
  resolves to **Iowan Old Style**; `document.fonts.check('16px "Source Serif 4"')`
  is `false`. A Linux CI image has neither and falls further down the stack, so
  characters-per-line and font metrics differ by host. **Re-baseline inside the
  same image the gate runs in before pinning any numeric threshold.**
* Wikilinks, valuerefs, note-embeds and live-task blocks resolve through
  caller-supplied maps that the rig does not pin, so they render as fallbacks.

Refreshing a fixture is a content change and needs a re-baseline:

```sh
bash tooling/paper-excellence/rig/fetch-fixtures.sh <slug>
bash tooling/paper-excellence/rig/baseline.sh <slug>
```
