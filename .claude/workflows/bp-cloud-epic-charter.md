# jarl.no Flagship Aesthetics (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant on origin/main — **Jarl Platform Follow-ups** — is preserved
> verbatim in this PR at `.claude/workflows/bp-jarl-platform-followups-charter.md` (slot
> convention: whoever claims the slot moves the previous occupant to its named file). Before it:
> **jarl.no Historiene** (`bp-jarl-historiene-charter.md`), **jarl.no Dogfood Publishing**
> (`bp-jarl-dogfood-publishing-charter.md`), **CLI-Reliability** (`bp-cli-reliability-charter.md`).
> Do NOT read this file for their history. This slot is now the memory of the
> **jarl.no Flagship Aesthetics** epic (Epic 9).
>
> Epic anchor: bp task **`jarl-flagship-epic`** (default ledger).
> Wave 1 paper: **`jarl-flagship-wave-2026-07-31`** (style=article, jarl instance).
> Wave 1 referent: **`jarl-flagship-epic-wave-1-log`**.
> Decided 2026-07-31.
> Baselines: barkpark origin/main `0f28d541e2b8b1412c7f4ee373950443dca7f49c`;
> jarl-website origin/main `9262f5238cf7673907693920253ad04fde8c0cad` (cited line numbers pin here).

## Vision

Every reading surface on jarl.no shares one deliberate rhythm at any viewport, in both color
schemes — and that rhythm is *checkable, not vibes*. The epic ships three things: (1) a width
doctrine frozen as jarl-owned tokens and policed by a gate; (2) the visual eye — a one-command
screenshot rig (31 routes × 1440/390 × light/dark), a written per-page review rubric, and a
graded findings backlog replacing guesses; (3) honest media — real asciinema recordings and real
product screenshots flowing through the Barkpark media path, every capture kilde-stamped
(recorded-at + version), with the pipeline proven end to end before volume is authored.
Flagship means: at least one soul story plays a provenance-stamped terminal recording, every
route carries its own OG card, no page scrolls sideways at 390, and the instrument that keeps it
that way survives the wave.

## Decisions

- **D1 — The 1.6x width jump is ALREADY FIXED; wave 1 tokenizes and gates it, never re-lands
  it.** jarl-website `9262f52` ("one reading measure") shipped 2026-07-31 15:32 and is live in
  production (browser-measured: prose 672px/59.3ch, figures 1072px/94.6ch, both flush at
  left:184px). Planning from the pre-fix survey digest would re-land a shipped fix and conflict
  with globals.css:302-346.
- **D2 — Measure numbers are FROZEN this wave: `--measure: 42rem` (672px prose),
  new `--measure-figure: 67rem` (1072px — the currently-emergent figure width declared as a
  token), `--site-width: 70rem` (band).** 672px = 59.3ch sits inside Studio's proven 55–70ch
  doctrine; the 32px delta vs the Bulldocs reader's 640px content column is a recorded, accepted
  divergence between two different surfaces, both in range. Why frozen: the paper-measure-probe
  verify assignment (empirical A/B/C candidate reflow with screenshots) NEVER REPORTED — an open
  deficit — so no reflow ships on top of that hole; any future number change re-asks it first.
- **D3 — The width gate measures the VISIBLE measure, not the declared cap.** Studio's hardest
  lesson (spd wave 5/6: layout stamped 64.00ch while the reader saw 38ch) and jarl's own live
  disease (home-page Prose at 39.2ch under a never-binding 42rem ceiling) both prove a
  cap-only gate passes while the page is broken. Shape: `scripts/check-measure.mjs` (static:
  token presence + values, max-width literal discipline with a printed mandatory-reason
  allowlist for the ~12 deliberate ch caps, explicit `.shell`/`.storyShell` binding assertion)
  PLUS the rig's audit.json measuring rendered widths per route. Honest language until branch
  protection lands: gates are "checked in blocking CI", not "enforced at merge" — jarl-website
  main is UNPROTECTED (protection 404, rulesets [], 11/12 CI runs are post-hoc direct pushes).
  Protection is filed as a deliberate lead task, not flipped mid-wave.
- **D4 — The rig is ADOPTED, not built: shoot-matrix2.mjs canonized as
  `jarl-website/scripts/shoot.mjs`.** Routes derived from sitemap.xml (31, host-rewritten to
  localhost), `waitUntil:'load'` + `document.fonts.ready` (networkidle times out on this site;
  pre-fonts overflow data is proven noise in BOTH directions), one retry, per-capture overflow +
  measured-width audit written to audit.json, `--routes` filter (fleet run 8m02s/124 captures;
  the inner loop must be ~30s). Non-blocking: the rig serves review, not CI.
- **D5 — Review unit is the QUAD (1440/390 × light/dark); rubric is canonized to
  `docs/review-rubric.md`; frontend-design skill is generative-only and scoped to fix-time,
  never review verdicts.** Every finding is filed as a graded bp task (P0 = width/contrast/
  mobile hard gates, P1 = rhythm, P2 = figure/OG); the wave fixes only accepted top findings;
  the rest is the graded backlog wave 2 inherits.
- **D6 — Media CORS is fixed UPSTREAM (PublicCors on the barkpark media serve scope), never a
  jarl proxy.** Proven: ACAO is the sole deciding variable (mime is a non-issue — the player
  decodes octet-stream fine); the serve routes ride `pipe_through(:api)` which has no CORS plug
  while `PublicCors` exists and is wired elsewhere (router.ex:649). Necessity is proven by
  exact-shape replication; sufficiency is NOT (nobody executed the Elixir) — the slice carries
  an integration test asserting ACAO on GET /media/files/*. HIGH-FLIP-RISK (security): ACAO:*
  on tenant-scoped blobs — an independent second review is owed before merge. Note: missing
  ACAO never blocked `<img>` (not CORS-gated); only fetch consumers (the cast player).
- **D7 — Absolute-URL law + figure-as-kilde-carrier.** The upload 201 returns a RELATIVE url by
  construction and the portable-doc `image` block emits `src` verbatim (no baseUrl seam), so:
  blocks store the ABSOLUTE instance URL at authoring time; React components pass baseUrl.
  Captions ride the `figure` block ({child, caption} — wraps any block, auto-bolds "Figure N.");
  the kilde stamp for captures is the caption convention "opptak <date>, <tool> v<version>".
  Screenshot sources must be ≥1920w (renditions are fixed-target and UPSCALE). Media gates
  assert PLAYED CONTENT (`.ap-term` text / no `.ap-overlay-error`), never `div.ap-player` —
  the player mounts identically on total failure and hydratePortableDoc returns {asciicast:1}
  on failure; this chain fails green by default (proven twice in one session).
- **D8 — Engine fixes land upstream in barkpark, then ONE re-vendor at wave end.** The vendored
  tgz is AHEAD of stale local checkouts (renders lineage+duel that old worktrees lack; 5/7 live
  papers use lineage) — builders branch from CURRENT origin/main (verified to contain them at
  0f28d541). Canonical CSS is `api/assets/paper-surface/paper-surface.css`, byte-copied to dist
  by tsup (tsup.config.ts:17,107). Re-vendor lane: pnpm build + `pnpm pack` (never npm — the
  workspace:^ dep), replace vendor/*.tgz, delete+regenerate pnpm-lock.yaml, verify INSTALLED
  bytes, extend vendored-renderer test, and CREATE vendor/VENDOR.md (it has never existed;
  jdf-w2-revendor-upstream's criterion is unpassable without it).
- **D9 — Auth posture: non-admin write mint EXISTS and is proven (POST /v1/auth/app-tokens
  mints bpapp_ [read,write] that creates/patches/PUBLISHES and is 403'd by admin routes), but
  wave 1 content writes still run under the admin token as a deliberate, recorded exception
  (only lead/fable phases write content).** Any minted token MUST use the DEFAULT
  `app:<email>` label — custom-labeled app tokens are unrevocable by any HTTP surface (upstream
  fix filed). SECURITY: a verify lane exposed BOTH saved admin tokens (jarl + guerrilla) in its
  session transcript — rotation filed P0 and named to the lead.
- **D10 — OG: the four imageless routes (/om, /kontakt, /notater, /prosjekter) get their own
  opengraph-image routes.** Live truth is worse than the digest claimed: they emit NO og:image
  at all (not an inherited root card). og.tsx itself is untouched — it is already at the bar.
  OG stays a light-only sibling scale with its own named constants (deliberate: 1200×630 is a
  different medium; forcing --measure onto it would be worse).
- **D11 — The "77 block types" number is a MYTH, corrected publicly.** 77 was the block-wishlist
  charter's D14 census of broken "Unsupported block" placeholder INSTANCES in production (since
  remediated), never a vocabulary size. Real numbers: 62 canonical (Elixir tiers.ex), 60
  canonical + 10 aliases (JS registry, ≥72 in the shipped vendor), 12 in live use on jarl (a
  stat/kilde monoculture — the enrichment axis for wave 2).
- **D12 — Overflow truth at 390: exactly 2 of 31 routes scroll (the scaffy pair), culprit a
  408px unbreakable path token in `.bp-lineage__body` (no wrap guard, while `.bp-heat__scroll`
  ships one — inconsistency, not policy).** The duel table (no scroll wrapper, nowrap cells)
  and the chart ~5px tick text are LATENT (duel live on 2 routes without overflow today;
  bp-chart used nowhere). Both guarded in the engine slice anyway — the class of bug is
  fleet-wide (10 routes render lineage).
- **D13 — Verify coverage deficit, recorded:** `paper-measure-probe` never reported (see D2).
  `nonadmin-write-mint` was listed as unreported by the dispatcher but a full proof-bearing
  report EXISTS and is treated as authoritative — the deficit list is stale on that one point.

## Roadmap

Wave 1 (this wave — 7 slices; rounds are law):

| # | slice (task id) | round | model | size | one line |
|---|---|---|---|---|---|
| 1 | jf-w1-width-tokens-gate-rig | 1 | fable | large | --measure-figure token + check-measure.mjs gate + shoot.mjs rig canonized (jarl-website) |
| 2 | jf-w1-engine-narrow-dark-fixes | 1 | opus | medium | lineage wrap guard, duel scroll wrapper, asciicast theme-awareness + var()-ify (barkpark engine) |
| 3 | jf-w1-media-cors-upstream | 1 | opus | small | PublicCors on media serve scope + ACAO integration test (barkpark api) — HIGH-FLIP-RISK security |
| 4 | jf-w1-og-four-routes | 1 | fable | small | own OG cards for /om /kontakt /notater /prosjekter + OG render smoke test |
| 5 | jf-w1-media-doctrine-paper | 1 | fable | medium | the media doctrine paper on jarl (absolute-URL law, kilde-for-captures, 77-myth correction) |
| 6 | jf-w1-fleet-visual-review | 2 (after 1) | fable | large | full-matrix rig run, quad review of all 31 routes, rubric canonized, findings filed graded; fix home 39.2ch floor |
| 7 | jf-w1-revendor-honest-media | 2 (after 2,3 + instance deploy) | fable | large | ONE re-vendor (VENDOR.md born), first honest cast + screenshot live in a soul story, media gate asserts played content |

Wave 2+ candidates (filed as published backlog children of jarl-flagship-epic):
admin-token rotation (P0, lead — transcript exposure), branch protection + required `ci` on
jarl-website main (P1, lead), /papers index route, app-token revocation-gap upstream fix,
media absolute-url upstream field, Artwork size-props + soul-story heroes + paper/note OG
figures, block-vocabulary enrichment fed by the review backlog, asciicast 💥-overlay
no-empty-box fallback, jarl anonymous-read mechanism explanation, media volume build-out,
deep per-story block rewrites, OG dark variants.

## Wave log

(empty — Review appends per wave)
