# jarl.no Historiene (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant — **CLI-Reliability** — is preserved in full at
> `.claude/workflows/bp-cli-reliability-charter.md`; do NOT read this file for CLI-Reliability
> history. This slot is now the memory of the **jarl.no Historiene** epic (Epic 6).
>
> CONCURRENT-SLOT NOTICE (2026-07-31 01:23Z, measured in the shared checkout): a sibling
> epic — **jarl.no Dogfood Publishing** (task `jarl-dogfood-publishing-epic`, paper
> `jarl-dogfood-wave-2026-07-31`) — wrote its own charter into this same slot as uncommitted
> work while this wave's Decide ran, and will open its own PR. Whichever PR merges second
> must, on conflict, preserve the earlier occupant verbatim at a dedicated
> `bp-<epic>-charter.md` path per slot convention. Cross-epic seams are pinned in D16.
>
> Epic anchor: bp task **`jarl-historiene-epic`** (guerrilla ledger).
> Wave 1 paper: **`jarl-historiene-wave-2026-07-31`** (style=article).
> Decided 2026-07-31.

## Vision

jarl.no captures its author's soul. Six stories — Scaffy (flagship), Bulldocs, Barkpark
Cloud, SVGLoop, Spreadsheet Wizard, and the decade dossier — told in warm, simple
Norwegian where a stranger understands the intention in one read: human intent in the
first lines, technology as seasoning. The stories are carried by a small family of
evidence figures native to the komposisjon design language: three new CMS section kinds
(`statBand`, `duel`, `lineage`) rendered as token-bound inline SVG/markup, correct on
paper/ink × light/dark by construction, every datum carrying a mandatory «kilde»
provenance ref rendered in the site's `.rail` idiom. Numbers are content: figure data
lives in the CMS (zero-hardcoded-content law), every headline number was re-derived from
its named artifact by this wave's verify round before any figure is drawn, and the
enforcement is layered so the site physically cannot paint a sourceless number. All
renderer code lands in ONE early slice (the code lane is a manual 3-step deploy); the
six stories then ship as pure CMS content on ISR-60s, which is free. The existing canon
gets a voice pass so the whole site speaks one language, and the self-referential
meta-story is told exactly once.

## Decisions

- **D1 — Hybrid direction stands; Rival B (static SVG uploads) is dead.** The blocking
  premise fell: an admin credential for jarl.barkpark.cloud is mintable in one command
  (`bp instance credentials 9fb839d6-9a4a-4c2f-b837-672e2bb97e9c`), `bp setup --target
  connect` persisted it as server `jarl` (tier admin), and `schema apply` was PROVEN by a
  zero-residue probe (hash ed7f5428f5b120b3 → probe → restored ed7f5428f5b120b3, 47 schemas).
- **D2 — One figure-data schema shape, applied once, GET→PATCH→APPLY, never from-scratch.**
  `SectionItem` += `value`, `value2`, `unit`, `source` (all strings — value is a display
  string on purpose, formatting is authorial); `Section` += `legendA`, `legendB`,
  `sourceDefault`; `kind` options += `statBand`, `duel`, `lineage`. page and project each
  own an independent copy of the sections composite, so the ONE shape costs exactly two
  applies — and a shape revision costs two more, which is why the shape is settled here
  and not iterated. `bp schema apply` is a whole-type upsert over 42 live documents:
  fetch the live schema, splice ONLY the sections field, diff, apply. Full pre-wave
  export backup: `tooling/jarl-schema-backup/` (42 docs, 49,251 bytes).
- **D3 — Ref grammar: one flat string, four prefixes, enforced in four layers.**
  Pattern `^(commit:[0-9a-f]{7,40}|paper:[a-z0-9][a-z0-9-]*|task:[A-Za-z0-9._-]+|https://.+)$`.
  Layer 0: schema `validation.pattern` rejects malformed refs at write time. Layer A:
  the normalizer drops any figure-kind datum whose resolved source (item.source ??
  section.sourceDefault) is empty — the site cannot render a sourceless number. Layer B:
  `scripts/check-sources.mjs` (node, matching the three existing gates) fetches live
  page/project/paper docs and asserts every figure datum parses, with a MANDATORY
  vacuity guard: exit nonzero when the token is missing or zero docs return (the
  unauthenticated endpoint 200s and silently downgrades drafts→published — a gate
  without the guard passes forever while proving nothing). Escape hatch: an authored
  `ingen-kilde: <reason>` sentinel, printed on every run, never silent. Layer C (CI):
  the check-sources step gets `BARKPARK_URL` + `secrets.BARKPARK_READ_TOKEN` env —
  today only Build has env, which is exactly why the naive gate would be vacuous.
- **D4 — Normalizer edits are surgical and guarded.** `itemHasContent` gains
  `item.value` in its `hasText` list (strictly additive — no existing item carries
  value, so every current keep/drop decision is bit-identical). `isRenderable` gains
  `statBand`/`lineage` (items > 0) and `duel` (items > 0 && hasText(legendA, legendB)),
  plus a `default: ((k: never) => false)(section.kind)` exhaustiveness guard — this
  tsconfig has `noImplicitReturns` OFF, so without the guard a future kind silently
  drops its section.
- **D5 — og-parity for figure sections is out of scope v1 BY CONSTRUCTION.** og.tsx
  renders only overline/title + a flat-string artwork data URI; page sections never
  reach the og pipeline, so the satori-`<text>` question gates nothing this wave.
  Future path (backlogged): figures export data-URI strings through the same
  one-geometry-two-renderers module as `artwork.ts`.
- **D6 — One early code slice; stories are pure content.** Content lands free (ISR 60s,
  verified live: `x-nextjs-cache` + `s-maxage=60`); code lands through the manual
  3-step lane (push → cp-ops `site-artifact-fetch` → `bp deploy --artifact-url`), a
  human gate. So ALL renderer/gate/schema work is slice 1; the six stories are round-2
  CMS writes with zero further deploys. The deploy itself is a LEAD step after merge.
- **D7 — «Kilde» is the `.rail` idiom, per-datum model, footer presentation.** Data is
  strict per-datum (with `sourceDefault` inheritance); the stamp renders as one deduped
  footer line per figure (mono/xs/muted — already contrast-guaranteed on every surface),
  `https://` refs link, `commit:`/`paper:`/`task:` refs render as text. `kilde` is not
  a kind or block name anywhere — it is the rendering of a resolved ref.
- **D8 — One accent per surface; no new tokens.** The duel scoreboard separates
  contenders by weight/dash/fill/position — accent marks the emphasized side only.
  SVG fills are attributes (never CSS backgrounds), colors only via `--color-*`
  (flat renderers via `palette.ts token()`), motion only `--ease`/`--dur`. A new token
  would cost 4 declarations + 3 bindings + palette mirror + a check-contrast PAIRS
  entry and ships contrast-unverified by default — refused.
- **D9 — Scaffy number canon (the flagship's honesty floor).** Figure data comes from
  `tooling/scaffy-duels/results/scores.json` ONLY (never directory globs — results/
  sums to $66.40 with off-matrix envelopes): $16.54 matrix, 32/32 gates green, pin
  591fdcd53, byte-identity shas 17f6ffab2bd3 / f614a3d4b67b / 42ec6e0e63cc, engine
  8–29s vs agents 51–300s. Meter verify today: 34/34 (METER.md's 24/24 is its frozen
  scope — state scope in captions). The R-vs-S duel (−52% cost / −60% wall) is
  **recipe-told vs catalog-told, BOTH scaffy-armed** (commit 354db3e9c) — captioning it
  "Scaffy vs hand-built" would be false; it is a footnote with the n=1 caveat, kilde
  `commit:354db3e9c`. The −84% wall figure is DROPPED (unarchived, differently-metered
  baseline). The honest cross-chore win is OUTPUT TOKENS (arm A beats B on every chore,
  −1.7%…−34.8%), not dollars. Banned forever: "$17.19" as machine-derived, "56–80k
  tokens", "38/295/739", "73 blokktyper".
- **D10 — Spreadsheet Wizard is the 2022→2026 arc, co-credited.** 2022:
  `Guerrilla-Interactive/spreadsheet-wizard` / npm `sanity-plugin-spreadsheet-wizard`
  v0.0.96, 2022-04-15→06-12, 41 commits (36 Suman Chapai / 5 Frikk — say "vi", credit
  Suman by name; sole-credit dies to one public grep), "seven releases in eight weeks"
  (never "96 versions"). 2026: the idea reborn as Barkpark **Sheets** (12,162 LOC
  engine, 120 functions, ~10 days, spreadsheet-as-document-block) — Barkpark has
  nothing named Spreadsheet Wizard; 2022 material is never captioned Barkpark. Two
  public kilde URLs exist (github repo + npm page) — use them.
- **D11 — SVGLoop = svg-animate-check, and the story is the honest one.** The app
  self-titles at `app/layout.tsx:11` ("SVGLoop: SVG Animation Tool") — identity closed.
  Frame: I wanted my drawings to move, so I built the tool that moves them; a four-week
  burst (66 commits, 2024-05-22→06-18), abandoned mid-polish — same instinct that later
  became Scaffy. The repo is PRIVATE: kilde = quoted title + `commit:e414f58`, never a
  dead link. The live self-demo (a `loop` section kind with CMS keyframe JSON + SMIL
  playback) is BACKLOGGED — it needs a schema revision and an author-drawn
  structure-parity keyframe pair, and shipping the story does not wait for it.
- **D12 — Cloud story: «én person + en flåte av agenter», dated receipts, honest crack.**
  Bare "written by one person" is refuted by one grep (30 Claude + 131 agent co-author
  trailers in public history). Spine: first `cloud/` commit 2026-06-26 → jarl.no live
  over TLS 2026-07-30 18:24Z (35 days by authored date — name the boundary, don't
  inherit "34"), charter-to-live in six hours. Fleet stat cites `bp cloud status`
  specifically (5 managed Barkparks; `bp cloud instance list` is a DIFFERENT five —
  never conflate). The honest crack is content: golive closed 4/5 with push-to-deploy
  open (`task:sites-github-auto-build`), trigger "manual". The linking proof: jarl.no's
  serving IP == the `jarl` instance host, 91.98.139.58. Never quote
  jarl.barkpark.cloud/sites/… (404 live) or the deployment stage rows (all "pending"
  while live). TLS/live claims carry their timestamp.
- **D13 — Pelle is a machine; Full Blast's shape is silence → burst → human audit.**
  `pelle@Pelles-Mac-mini.home` is Frikk's own AI grid runner on a Mac mini (repo
  `pelle-jarl/pelle`, README line 3) — 1,157 of 1,535 commits in five days, then the
  human's 275 zero-Claude-trailer cleanup commits. The Full Blast skyline figure
  (12 → 481) is BACKLOGGED to a later wave; the "resten er meg" clause needs the
  frikk@guerrilla.no human-leg check first (backlogged).
- **D14 — Dossier is a Paper on jarl; stat blocks in canonical upstream shape; NO
  PaperRenderer work this wave.** The sibling Dogfood epic deletes jarl's
  PaperRenderer.tsx and vendors the canonical `@barkpark/react` engine, which already
  renders `stat`/`stat-grid` natively — so this epic does NOT touch PaperRenderer
  (collision avoided, work saved). The dossier authors stat blocks in the upstream
  shape `{value, label, max?, spark?, denom?}` + optional `source` (superset; canonical
  renderer ignores unknown attrs gracefully), and carries every headline number in
  prose as well, so it degrades honestly if rendering lands later. Registry truth is
  **75** block types (element 29 / widget 43 / section 3, gate-enforced) — 73, 69 and
  70 are all measurement artifacts, banned. The dossier's duel-style table is a plain
  `table` block (prior art: scaffy-loop-bench-status) — no new block kind.
- **D15 — Corpus numbers and the dossier's content law.** 83 narrative survey records
  + a separate 284-repo inventory (never "82"; wave-e is an inventory, not records).
  All 18 B-lines, one sentence each; paperflow/portable-doc-mvp B-lines cross-link to
  the Bulldocs story rather than re-narrating; nextgen sub-repos fold into the Nextgen
  lineage. The census corrections ARE the soul hook and must survive: unge-venstre 0
  Frikk commits, pwdr-horizon 82% bot sync, codehouseno/inligo-as colleagues' work,
  aquatiq's hidden plugin work behind an 8% share, Lunnheim Stripe+Klarna not Vipps.
  Sealed grade split from the epic close (9 A / 17 B / 27 C), source `task:jarl-corpus-epic`.
- **D16 — Cross-epic seams with jarl-dogfood-publishing (pinned so builders don't
  collide).** (a) This epic does not touch `PaperRenderer.tsx`, `layout.tsx`,
  `globals.css`, `/notater` routes, or `vendor/` — those are Dogfood's. (b) This
  epic owns `src/content/types.ts` (Section*), `src/content/sections.ts`,
  `src/components/Sections.*`, `src/lib/figures/`, `scripts/check-sources.mjs`.
  (c) Shared touch: `package.json` (Dogfood adds deps, we add one script — mergeable)
  and `.github/workflows/ci.yml` (we add one step). (d) The dossier renders through
  whichever paper engine is live; it never assumes a route (`/papers/` may 308 to
  `/notater/`).
- **D17 — Every bp write to jarl passes `-s jarl` explicitly.** The active server was
  restored to Guerrilla; a bare `bp` in a neutral cwd hits Guerrilla, and inside
  jarl-website hits jarl UNAUTHENTICATED (tier none — the survey's "no schema verb"
  was exactly this trap, plus zsh non-splitting). Ledger reads (tasks/papers/search)
  run from a neutral cwd. The `jarl` server entry has an empty instance_id — always
  address it by name.
- **D18 — Drafts are now checkable, and slice 1 checks them first.** The read-token
  "perspective not allowed" clamp is deliberate; the admin credential is NOT clamped.
  S1's first act: query drafts for the six story ids and stamp the result — a found
  draft flips that story's brief from create to extend.
- **D19 — Voice pass rewrites the 11 failing texts; the 7 passing ones are templates,
  untouched.** Rewrite: project-barkpark, page-hjem, project-frick-design-system,
  project-aquatiq-synk, project-polyflor-ordre, project-lunnheim, project-hundesteder,
  page-om intro, project-doey ¶2, note-velkommen, paper velkommen-til-jarl-no. The
  meta-story ("content lives in the CMS") is told ONCE — condensed into
  project-barkpark; deleted everywhere else. Prose numbers get re-derived + a named
  source in-text, or get cut. Templates: full-blast, ticket-realtime, galleryspace.

## Roadmap

### Wave 1 (this wave — 8 slices)

Round 1 (dependency-free, builds this run):
- **S1 `jh-w1-figure-family`** (fable, large) — schema apply (page+project) on jarl +
  types/normalizer/sources parser + three figure renderers + kilde footer +
  check-sources gate + CI env wiring. HIGH-FLIP-RISK: live schema upsert over 42 docs.
- **S2 `jh-w1-voice-pass`** (fable, large) — the 11 failing texts rewritten to the
  soul voice via `bp -s jarl`; meta-story deduped to one home; no figure sections.

Round 2 (AFTER S1 merges — schema + gate live):
- **S3 `jh-w1-story-scaffy`** (fable, large) — flagship story: lineage
  (Nextgen→Scaffy), duel (A vs B from scores.json), stat band, recipe-duel footnote.
- **S4 `jh-w1-story-bulldocs`** (opus, medium) — three-way-merge lineage with unequal
  arrows; 10→75 in two months; «det aller mest imponerende».
- **S5 `jh-w1-story-cloud`** (opus, medium) — dated rail + stat band + honest 4/5
  callout; én person + en flåte.
- **S6 `jh-w1-story-svgloop`** (opus, small) — the honest curiosity; quoted self-title.
- **S7 `jh-w1-story-spreadsheet-wizard`** (opus, medium) — 2022→2026 arc, co-credited.
- **S8 `jh-w1-dossier`** (fable, large) — frikk-tiaret-dossier as a Paper on jarl:
  18 B-lines, corrections, stat blocks in canonical shape + prose fallback.

### Later waves / backlog (filed as published children of the epic)
- `jh-bl-svgloop-live-loop` — the self-demoing morph figure (loop kind, SMIL, reduced-motion).
- `jh-bl-fullblast-skyline` — the 12→481 commit skyline + 270-agent audit figures.
- `jh-bl-og-figures` — og-parity for figure sections via the data-URI route.
- `jh-bl-sitemap-stale` — sitemap.xml lists 10 URLs, missing 10 of 13 live project pages.
- `jh-bl-nextgen-root-and-kilde` — survey Guerrilla-Interactive/nextgen (2021); author
  decision on publishing FRIKKern/nextgen-vscode for a public kilde.
- `jh-bl-guerrilla-identity` — prove frikk@guerrilla.no is the human leg.
- `jh-bl-canon-figures` — retrofit stat bands + kilde onto remaining canon numbers.

## Wave log

### Wave 2026-07-31 — round 1 built + reviewed, grade A-

- **Landed (2/2 round-1 slices green; round 2 deferred by design, dispatches after S1
  merges):**
  - S1 `jh-w1-figure-family` — PR FRIKKern/jarl-website#1, final branch
    `loop-epic/figurfamilien-statband-duel-lineage-seks-0-r` (REVIEWER FIX ed40daf:
    a duel row carrying only `value2` slipped the normalizer's Layer-A provenance
    drop and painted a sourceless number — value2 now counts like value in
    itemHasContent/itemHasProvenance/the kilde footer, matching what check-sources
    already enforced; and check-sources now counts NUMERIC stat values — `value: 75`
    owes a source like `value: "75"` — both mutation-proven on a mock CMS). Schema
    applied live to page+project (dataset hash ed7f5428f5b120b3 → bb00ae821fd2c525);
    reviewer independently re-derived the HIGH-FLIP-RISK upsert against the PR #8320
    backup: 47 schemas before/after, only page+project changed, only their sections
    field, every other field byte-equal. Gate green on the final branch (typecheck,
    check, live check-sources exit 0, statBand readback = 1). E2: an independent
    second look at the schema splice is still warranted before merge. Deploy is the
    lead's 3-step lane AFTER merge — content slices are blocked until it lands.
  - S2 `jh-w1-voice-pass` — pure CMS, no branch/PR; all 11 texts live in production
    (verified 02:13–02:14Z stamps): project-barkpark opens with intent, meta-story
    single-homed in its quote section, jargon grep 0, Vipps 0, templates untouched,
    Barkpark timeline months re-checked against real git history (April 2026 first
    commit, June 2026 apiclient extraction). Residue for later: project-doey ¶3's
    «1 350 endringer på ni dager» retained un-rederived (was out of the brief's
    scope), page-om body still says «headless CMS» (only the intro was in scope).
- **Stalled:** nothing. Brief-vs-live id drift absorbed by the builder correctly
  (project-aquatiq / project-polyflor — the briefs' -synk/-ordre ids never existed).
- **Next wave:** lead merges jarl-website#1 (after the E2 second look), runs the
  3-step deploy, then dispatches round 2 in order: jh-w1-story-scaffy (flagship),
  jh-w1-story-bulldocs, jh-w1-story-cloud, jh-w1-story-spreadsheet-wizard,
  jh-w1-story-svgloop, jh-w1-dossier — every one gated on check-sources against the
  now-live schema. Then the backlog children (jh-bl-canon-figures retrofits kilde
  onto the standing canon numbers, incl. the doey re-derivation).
