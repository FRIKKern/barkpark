<!-- doc-tier: human | canonical-for: paper-excellence-render-rig | budget: 9000tok -->

# Paper render + screenshot rig

A paper goes in as committed JSON, a photograph comes out. **No server, no
database, no network** — so the same command answers the same way on a laptop,
in CI, and a year from now.

```sh
bash tooling/paper-excellence/rig/gate.sh              # the gate: render + shoot + assert
bash tooling/paper-excellence/rig/baseline.sh          # re-capture the committed panel
bash tooling/paper-excellence/rig/fetch-fixtures.sh    # the ONE networked step: refresh fixtures
```

| file | what it does |
|---|---|
| `render.exs` | renders a fixture through the real `PortableDoc.Render` + the real bulldocs layout |
| `shoot.mjs` | serves the rendered page on loopback and photographs it, asserting DOM content |
| `gate.sh` | render + shoot the committed `heggemsnes-act` fixture; nonzero on any content failure |
| `baseline.sh` | the same path, writing into `baselines/` so a refresh is a reviewable diff |
| `fetch-fixtures.sh` | pulls paper blocks from Barkpark via `bp` and rewrites `fixtures/*.json` |
| `fixtures/` | 5 papers, each stamped with the `source_rev` it was taken from |
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
* **A JPEG capture can write nothing at all.** Playwright's JPEG encoder emits
  a **zero-byte file, without throwing**, when a full-page capture exceeds
  JPEG's 65,535 px dimension cap — which a ~100-block paper at 2x does
  (`hobby-hardening-capstone`, found 2026-08-12). The rig stats every file it
  writes; over-tall pages are re-captured full-page at 1x and get an `@1x`
  suffix so a shorter baseline can never pass as a 2x one.

## The theme pin

`render.exs` pins `data-bp-theme` to **`evergreen`** and asserts the pin equals
`Barkpark.Tenancy.default_theme/0`. `Layouts.bp_theme_attr/1` omits the
attribute when the theme is the default, so pinning the default reproduces the
default page byte-identically. A workspace on another theme (e.g. `fjord`)
drifts **colors only** — geometry and type are unaffected. If the product
default moves, the rig reds rather than silently re-baselining every shot.

## Baselines

`baselines/` holds the 5-paper panel: `heggemsnes-act`,
`hobby-hardening-capstone`, `mechanical-spacing-doctrine`,
`paper-excellence-wave-2026-08-12`, `portabledoc-showcase` — **full page**,
light and dark, at 1440, `deviceScaleFactor: 2`, JPEG q72, plus a
`*.report.json` per paper recording column width, paragraph count, scale and
blocked-request count.

Deliberate limits, stated rather than hidden:

* **Format and widths are a weight decision.** The same panel is **166 MB** as
  full-page 2x PNG and **23 MB** in the committed shape. The 768 and 360 cells
  still run in the gate on every invocation; they are simply not carried in the
  repo. JPEG baselines are for human review and layout regression — quantization
  noise makes them unsuitable as an exact pixel-diff oracle.
* **`hobby-hardening-capstone` is `@1x`** (the JPEG cap above), and its files
  say so in their names.
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
