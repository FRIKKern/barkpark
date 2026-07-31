# jarl.no Dogfood Publishing (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant — **CLI-Reliability** — is preserved in full at
> `.claude/workflows/bp-cli-reliability-charter.md`; do NOT read this file for CLI-Reliability
> history. This slot is now the memory of the **jarl.no Dogfood Publishing** epic.
>
> Epic anchor: bp task **`jarl-dogfood-publishing-epic`** (guerrilla ledger).
> Wave 1 paper: **`jarl-dogfood-wave-2026-07-31`** (style=article).
> Decided 2026-07-31.

## Vision

jarl.no goes paper-first by SKINNING THE CANON: posts are authored as Papers on the
jarl instance (jarl.barkpark.cloud) and rendered on jarl.no by the SAME canonical
engine that renders them in Studio — `renderPortableDocument(blocks)` inside
`.bp-paper-surface`, skinned by `paper-surface.css` with jarl token overrides in both
light and dark, `hydratePortableDoc` as the client island for mermaid/asciicast, all
inside jarl's Band composition. jarl's hand-rolled 8-of-70-type `PaperRenderer.tsx`
(silent drops, dead spacing law) is deleted. `/notater` becomes the single public
stream backed by papers; `/papers/:slug` 308-redirects into it; RSS/sitemap/OG/JSON-LD
read one normalized loader. The spacing law is the REPAIRED Reader-Owned doctrine
(readers skip empty paragraph groups; authored blank rows are never published layout),
landed upstream in both canonical engines and honoured in every jarl document.
Dogfood proof is content: three published pieces as papers on the jarl instance, one
carrying a real table + chart + mermaid diagram, all publishing through the label-spine
wall. jarl.no becomes the canonical renderer's first real external skin — the strongest
portability proof Barkpark can publish.

## Decisions

- **D1 — Skin the canon; delete jarl's PaperRenderer.** "Vi burde bruke våre" means
  consuming OUR renderer, not reimplementing its contract: jarl's 8-type renderer
  silently drops 62 of 70 registered types and hard-codes the retired mechanical
  spacing law; the canonical engine renders everything and degrades unknowns visibly
  (`bp-unknown-block`), never silently.
- **D2 — Distribution is the vendored tarball, not npm.** `@barkpark/react@1.0.0-preview.2`
  does not exist on npm and the published preview.1 is the legacy PortableText shim
  (no `renderPortableDocument`, no `./client`, no CSS — tarball unpacked, grep count 0).
  jarl-website vendors `file:./vendor/barkpark-react.tgz` + `barkpark-core.tgz`, packed
  with `pnpm pack` (NEVER `npm pack` — it emits `workspace:^`, uninstallable), lockfile
  REGENERATED after every byte swap (warm-cache installs old bytes green — proven trap),
  source commit recorded in `vendor/VENDOR.md`. Publishing preview.2 upstream is filed
  backlog (`jdf-bl-publish-react-preview2`) — release.yml is operator-gated.
- **D3 — jarl stamps `data-theme`; the package never will.** Zero `--paper-*`/`--bp-tone-*`
  tokens live under `prefers-color-scheme` (measured: 158 decls, 0 under the media query),
  so without the stamp an OS-dark reader gets a silent light paper. A pre-paint inline
  script in `layout.tsx` stamps `document.documentElement.dataset.theme` from
  `matchMedia('(prefers-color-scheme: dark)')` and re-stamps on `change` (a naive stamp
  would regress live OS flips). Script-only — never rendered as a JSX attribute
  (hydration-mismatch surface in Next 16).
- **D4 — The skin scopes to `.bp-paper-surface`, never `:root`, and lives in `globals.css`.**
  jarl owns a COLLIDING `--paper-*` namespace in oklch on `:root`; scoping keeps the
  canonical values winning inside the surface and jarl's values everywhere else.
  `check-tokens.mjs` bans colour literals outside `globals.css`, so the skin is authored
  there. Fonts ride the token seam: `--paper-font-serif: var(--font-display)`,
  `--paper-font-mono: var(--font-mono)` — never edit the canonical file's stacks
  (human-gated by au-w5-reading-typography).
- **D5 — The wire is `paper.blocks ?? paper.body?.blocks`; `body_html` is deliberately
  ignored; `fields=` never touches the detail fetch.** Top-level `blocks` is proven
  byte-equal to `body.blocks` on the live paper (both endpoints); `body_html` hardcodes
  a light palette in inline styles (drakt-proof, dark-impossible). `?fields=` is honoured
  and silently strips `blocks` with HTTP 200 — mandatory on LIST loaders (16MB unprojected
  list measured), forbidden on the detail path.
- **D6 — The spacing law is the Reader-Owned doctrine, repaired in three places.**
  The doctrine flipped 2026-07-31 and NO renderer on main implements invariant 2
  (`core.ts:470` and `walk.ex` emit `<p></p>` unconditionally; zero `:empty` CSS; zero
  golden fixtures cover it either direction). The swap alone does not deliver the law,
  so: (a) upstream suppression lands in BOTH engines with new golden coverage this wave;
  (b) jarl's live paper is content-migrated (three `sp-00*` spacers removed); (c) no new
  piece authors empty-paragraph layout. Wave paperwork follows the repaired law too.
- **D7 — Publish acceptance is "Studio-edit + API-publish".** Studio renders no publish
  control for papers (deliberate read-only sidebar; the affordance triple is filed as
  `spd-bl-publish-affordance-triple`, another desk's P1). The API lifecycle is proven
  end-to-end on jarl (create → label_spine 422s in charter order with machine-readable
  fixes → publish 200 → delete verified gone). The write credential is MINTED PER RUN
  from the Cloud CP (`GET /v1/barkparks/9fb839d6-…/credentials` with the team
  cloud_token), never stored.
- **D8 — Epic 6 boundary: the Korpuset/dossier piece is CEDED to Epic 6.** The corpus
  table+chart piece IS `frikk-tiaret-dossier` (Epic 6 criterion 3) and Epic 6 owns the
  dogfooding-content criterion verbatim. This epic's three pieces are Epic-6-neutral:
  (1) `velkommen-til-jarl-no` repaired + spacer-stripped, (2) "Spacing-loven som snudde"
  (carries table + dataviz chart + mermaid + callouts), (3) "Nettstedet skriver seg selv"
  (migration of note-velkommen, keeps URL `/notater/velkommen`).
- **D9 — The Historiene renderer conflict is resolved in favour of the canon, loudly.**
  Historiene's wave (VERIFYING today) decided to EXTEND `PaperRenderer.tsx` — a decision
  premised on the 8-type renderer this epic deletes. This epic proceeds; a P1 coordination
  task (`jdf-bl-historiene-renderer-reconciliation`) tells that wave to target the
  canonical engine, which dissolves its foreclosure rationale (charts/design blocks come
  free from the 70-type grammar). The lead relays before either wave merges content.
- **D10 — Deploy story is the manual `bp deploy` lane; no wording implies automation.**
  Push-to-deploy is hard-false on main (`github_build_available?/1 → false`; builder is
  `file://`-only) and is OWNED by the platform-followups wave (`sites-github-auto-build`).
  The PAX tar repair is source-true but production-unproven (crown proof 0/12; serving
  box BEAM may predate the fix) — every live acceptance fetch pairs a 200 with a control
  fetch (static misses return 503, so a bare 200 proves nothing).
- **D11 — Build honesty: published reads are public, so the build stops gating on the
  token and starts failing loud.** The read token gates nothing (tokenless reads return
  identical published content) yet its absence blanks the whole site with a green build.
  `client.ts` fetches without requiring the token and THROWS on API failure during
  production builds. Caveat recorded: the `vf-build-honesty` verifier never reported —
  the slice reproduces the silent-empty first, then fixes against observed output.
- **D12 — Counts derive from the registry, never a literal.** The grammar is 70 registered
  types (test-pinned against `REGISTERED_TYPES`), the golden corpus is 60, "42" is a stale
  floor surviving only in prose. Any smoke asserts against the registry or a readdir,
  never a hand-counted number. jarl's vendored smoke asserts zero `bp-unknown-block` over
  a vendored fixture plus empty-`<p>` suppression; the pinned-consumer parity harness is
  backlog (`jdf-bl-pinned-consumer-parity`).
- **D13 — Unified stream shape.** One normalized `getPosts()` loader (papers canonical,
  legacy note mapped) feeds `/notater`, feed.xml, sitemap, OG and JSON-LD. Excerpts:
  `description ?? preview.description ?? toPlainText(blocks filtered of eyebrow + empty
  paragraphs)`. Dates: `publishedAt ?? _createdAt` (the content slice stamps `publishedAt`
  on the papers). The migrated note-paper takes id `velkommen` so URL continuity costs
  zero redirects; the source note doc is retired to kill feed dupes; `preview.url` is
  never threaded into canonicals.

## Open unknowns this wave decided around (named, honestly)

- `vf-build-honesty` never reported (4 attempts): the silent-empty build was never RUN,
  only code-read. D11's slice reproduces it before fixing.
- The human Studio publish path for papers is unobserved on jarl (API path proven).
  Acceptance is set at Studio-edit + API-publish (D7), not "press publish in Studio".
- Whether jarl.no's site deploys through the prebuilt-artifact lane (vs on-box source
  build) was not verified; the lead's deploy step verifies live rendering with control
  fetches either way.

## Roadmap

Wave 1 (this wave — 8 slices, 3 rounds):

1. `jdf-w1-upstream-reader-owned-spacing` — invariant 2 in core.ts + walk.ex + golden
   coverage in both suites (barkpark, fable, M, round 1).
2. `jdf-w1-toplaintext-dual-shape` — heading/eyebrow read content[] via proseContent +
   content-shape golden case (barkpark, opus, S, round 1).
3. `jdf-w1-mermaid-theme` — hydrate mermaid theme-aware from html[data-theme], re-render
   on flip via data-bp-src (barkpark, opus, S, round 1).
4. `jdf-w1-canonical-swap-drakt` — vendor tarballs, swap PaperRenderer → canonical
   surface island, theme stamp, jarl drakt in globals.css (jarl-website, fable, L, round 1).
5. `jdf-w1-build-honesty` — tokenless public reads + fail-loud build (jarl-website,
   opus, S, round 1).
6. `jdf-w2-unified-stream-feeds` — getPosts(), /notater identity, /papers 308, feeds/OG/
   JSON-LD, fields= projection on lists (jarl-website, opus, M, round 2 after #4).
7. `jdf-w2-revendor-upstream` — re-pack tarballs from merged main; vendored smoke proves
   suppression + toPlainText fix (jarl-website, opus, S, round 2 after #1–#4).
8. `jdf-w3-content-pieces` — migrate + author + publish the three pieces on jarl through
   the wall; register tags; stamp publishedAt (content, fable, M, round 3 after #6, #7).

Later waves: publish @barkpark/react preview.2 and retire the vendor lane; pinned-consumer
parity harness; Studio publish affordance adoption for jarl authoring (after
spd-bl-publish-affordance-triple); the Epic-6 dossier lands on the then-canonical stack;
push-to-deploy adoption once sites-github-auto-build ships.

## Wave log

(empty — Review appends per wave)
