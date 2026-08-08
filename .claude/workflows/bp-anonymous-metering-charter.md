# Anonymous Metering — Epic Charter

Epic task: `task-8e9cac2018a7fe1c` · Program task: `task-21cd02088dd2f762` ·
Founding papers: `/papers/hobby-hardening-capstone` (crown) · `/papers/hobby-hardening-meter-free-lunch`
(lane) · `/papers/barkpark-hobby-scale-swot` (frame)

This file is the epic's memory. Decisions (D#) are never silently reversed — a reversal is a new
numbered decision naming the old one and the evidence that moved.

## Vision

**Anonymous load is measured, then bounded — in that order.**

Falsifiable form: the instance can state its anonymous read rate per route class, and no anonymous
surface can take the box down.

**Ground truth at epic open (2026-08-07):** NOTHING measures public-reader hits — RequestStats is
one global volatile 60-second number that resets on restart (request_stats.ex:83-137), the
Prometheus scrape has zero consumers repo-wide, Caddy writes no access logs, and no historical
data exists anywhere to size a scraper scenario. The genuinely unmetered doors are the
browser-class pipelines — `:browser`, `:public_root` (papers/sheets/quiz LiveViews — the real
DB-hitting anonymous surface), `:sso_browser` — plus the by-design-exempt `:api_unlimited`.
RateLimit already rides 13 pipelines and media reads ARE metered (`:api`, 300/min): the SWOT's
"unmetered public reader including media" is corrected here. One anonymous paper view runs the
LiveView mount twice (dead render + websocket join) at 7–9 Repo queries each; the five largest
papers ship 218–546 KB bodies that can never 304; the finder's connected mount forks a graph
derivation priced "seconds on a loaded box" whose flat twin already caused a measured prod
incident (#10016); any visitor-supplied quiz pin spawns a Room GenServer bounded only by a global
10,000-child cap (room.ex:99-111).

## Decisions

- **D1 — The instrument is the program's first merge. Nothing that will be scored on it merges
  before it.** *Why:* deploy-reliability's founding law, transplanted verbatim — every later
  absorption or limiter claim is a before/after against this baseline; without it every claim is
  vacuous green. Layer 0 extends RequestStats: its telemetry handler already fires on
  `[:phoenix, :endpoint, :stop]` with the full conn in scope and discarded — widen the ETS key
  with a coarse route class (anon-browser / API / static / LV) and an `authed?` bit; group
  `compute/4` by it. No new process, no Prometheus cardinality. One design unknown is verified
  before committing: whether optional_token resolution is present at endpoint-stop time for all
  route classes.

- **D2 — THE SHADOW LAW: the limiter ships log-only first. Non-negotiable. Promotion to enforcing
  is an explicit human decision against observed shadow data, with a kill switch and env-tunable
  budgets (the existing `BARKPARK_RATE_LIMIT_*` pattern).** *Why:* merges auto-deploy, and a
  false-positive 429 on a real reader is this epic's one-way door. Refusals land as Layer-0
  counter lines; the log-only window must show would-be-429s in logs while serving 200s. The
  window length is the user's risk-tolerance call, recorded here when made. The pinned-window /
  volume-beside-rate law (deploy-reliability D3) transfers verbatim to every number this epic
  reports.

- **D3 — Absorption before enforcement: make the hit cheap before limiting it.** *Why:* the
  measured incident history on the box is expensive work, not volume (p95 anti-correlated with
  request count on guerrilla; the swap-thrash incidents were build memory pressure). Stock Caddy
  has no cache module — only an in-app cache protects the box. Three absorption slices: an ETS
  reader render cache keyed `(dataset, slug, released_revision_id)` evicted by the existing
  `paper_topic` PubSub (the eviction signal already exists — bulldocs_live.ex:124-131 — and must
  be mutation-tested); a per-dataset TTL/single-flight cache for the finder graph derivation; and
  query-shape dedupe in the reader (duplicate reverse_referencers walk, driven-tasks N+1,
  unbatched task blocks) — the dedupe alone halves the reader's floor cost with no cache at all.

- **D4 — Two limiter gates, because one structurally cannot cover both lifecycles.** *Why:*
  websockets bypass every plug forever. Gate A: extend the existing RateLimit plug onto the
  browser pipelines with a new `:browser` class and a content-negotiated HTML 429 + Retry-After —
  meters the entire curl/crawler dead-render class; the class addition must not disturb the 13
  existing pipeline keys. Gate B: declare `:peer_data` + `:x_headers` in the `/live` socket's
  connect_info (today it carries session only — endpoint.ex:16-17 — a LiveView cannot even SEE the
  client IP), add a connect_info-shaped `client_ip` variant PRESERVING the Caddy trust walk
  (rate_limiter.ex:96-182 is @canonical — never solve the trust walk twice), and attach one
  on_mount + `attach_hook(:handle_event)` at the `:public_root` live_session emission
  (router/plugins.ex:44-51 — one macro line covers papers/sheets/quiz at once; that breadth is
  also the risk and carries the epic's heaviest test burden) plus FinderLive's session.

- **D5 — The quiz spawn budget is a per-IP budget at the single choke point, `Room.ensure/1`.**
  *Why:* the census's one anonymous stateful-process DoS vector — any visitor-supplied pin spawns
  a GenServer; the only brake is the global 10,000-child cap. The refusal needs a humane host-side
  message.

- **D6 — robots.txt is policy, not protection.** *Why:* robots.txt structurally cannot stop the
  worst 2026 crawlers — enforcement is D4's job. api gets a real policy (Allow `/papers/` and
  `/sheets/`; Disallow `/finder`, `/quiz/`, `/studio`, `/login`, `/s/`; AI-crawler stance = the
  user's pick of three prepared templates); the cloud console gets Disallow-all (a one-file
  cch coordination); web and spawned sites stay allow-all. Both files smoke-asserted
  byte-for-byte; instantly live via auto-deploy.

- **D7 — The router.ex pipeline edit is sequenced DEAD LAST and rebases onto whatever lands.**
  *Why:* the most contended file in the program — open PR #9530, site-spawner ssw10 residue (task
  open 7/9; its PR #7870 MERGED 2026-07-30 — L1 beats carried notes; ssw11 unresolved),
  deploy-reliability D17 gating the adjacent region. Rebase cost, not semantic duplication.

- **D8 — The two reader LiveViews are edited only under a numbered cch carve-out, requested in
  cch's own idiom.** *Why:* `bulldocs_live.ex` + `finder_live.ex` sit inside
  cloud-console-hardening's fence; cch has zero hits on them across 49 waves, making the carve-out
  a formality — but matching the fence law costs one sentence and removes all ambiguity.

## Fence

**In fence:** `api/lib/barkpark_web/request_stats.ex` · `api/lib/barkpark_web/plugs/rate_limit.ex`
· `api/lib/barkpark/rate_limiter.ex` (additive connect_info-shaped variant) ·
`api/priv/static/robots.txt` · `cloud/priv/static/robots.txt` (new; one-file cch coordination) ·
`api/lib/barkpark_web/router/plugins.ex` + a new live/hooks module ·
`api/lib/barkpark/quiz/room.ex` · router.ex pipeline bodies (D7 sequencing) ·
`bulldocs_live.ex` + `finder_live.ex` (D8 carve-out only) · `api/lib/barkpark_web/endpoint.ex`
(`/live` connect_info region only — disjoint from E1's statics region by ~30 lines).

**Out, by design:** box memory/swap levers (deploy-reliability owns them: task-cbde37238506ed7c,
task-aa775c3d30287a4b, dr-bl-* rows — cited by full slug, never rebuilt); the playground limiter
(bpb-playground-rate-limit — different surface); the pulse/bulldocs-form inline limiters (already
self-limiting); `public_read.ex` (never touched). Every fence widening is a numbered,
subject-scoped, not-to-be-widened-again decision in this file.

**Interface law (program-wide):** no new alert or email producers (deploy-reliability D14/D321);
every operator-facing signal names its audience explicitly (PLATFORM_ADMIN_EMAILS is unset on prod
— a signal addressed to the default population is addressed to nobody).

## Roadmap

Layered by D1/D3: instrument → policy → absorption → enforcement.

| # | Slice | Surface | Size | Wave | Status |
|---|---|---|---|---|---|
| 1 | Layer 0 — RequestStats route-class + authed? instrument (THE PROGRAM'S FIRST MERGE) | `api/**` | small | W1 | filed |
| 2 | robots.txt: api real policy + cloud Disallow-all, byte-for-byte smoke | `api/**` + `cloud/**` | small | W1 | filed |
| 3 | Reader query-shape dedupe (reverse_referencers, driven-tasks N+1, task blocks) | `api/**` | medium | W1 | filed |
| 4 | Reader render cache (ETS, PubSub-evicted, mutation-tested) + finder single-flight | `api/**` | medium | W2 | filed |
| 5 | Gate A: RateLimit `:browser` class, HTML 429 + Retry-After, shadow-first | `api/**` | medium | W2 | filed |
| 6 | Gate B: connect_info + client_ip variant + :public_root hook + finder hook, shadow-first | `api/**` | large | W2 | filed |
| 7 | Quiz per-IP spawn budget at Room.ensure/1 | `api/**` | small | W2 | filed |
| 8 | router.ex pipeline lines (SEQUENCED LAST, after E1 and ssw residue) | `api/**` | small | W2 r2 | filed |

**Not this epic:** header correctness and cache policy (E1, `task-02ce7e5183108eb3`); packaging
(E3, `task-3ae717d5f9324399`); box sizing and swap hygiene (deploy-reliability); the spawned-site
pipeline (site-spawner).

## Sequencing with the sibling epics

Slice 1 merges before anything in E1 or E3 that wants to be scored on traffic. E1 lands its
`paper_revision_headers.ex` change first; this epic's telemetry line in that plug rebases after.
Slice 8 waits for E1's plug change AND the ssw10/#9530 residue.

## Wave log

<!-- one row per wave: date · wave paper · slices merged · the number that moved (rate WITH volume, pinned window) -->
