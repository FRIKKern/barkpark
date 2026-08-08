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
LiveView mount twice (dead render + websocket join); the five largest papers ship 218–546 KB
bodies that can never 304; the finder's connected mount forks a graph derivation priced "seconds
on a loaded box" whose flat twin already caused a measured prod incident (#10016); any
visitor-supplied quiz pin spawns a Room GenServer bounded only by a global 10,000-child cap
(room.ex:99-111).

**Ground truth corrected at wave 1 (2026-08-08, measured on origin/main `5b68852f4`):** the
"7–9 Repo queries each" figure above was WRONG in both directions — the measured FLOOR for a bare
heading+paragraph paper is **10 statements dead / 20 both legs**, and a paper carrying the three
expensive shapes (one backlink edge + one driven task + one live task-list block) costs
**22 dead / 44 both legs**, the connected leg byte-identical to the dead leg (probe: 5 tests,
0 failures; rerun recipe in `tooling/grip/ledger/anon-metering-w1-origin-pins-2026-08-08.md` and
the harness spec in D14). The live meter payload today carries NO volume and NO window anchor —
seven live reads on an idle guerrilla swung req_per_s 2.77→11.58 and p95_ms 36→2885 with nothing
to interpret either by (D10).

## Decisions

- **D1 — The instrument is the program's first merge. Nothing that will be scored on it merges
  before it.** *Why:* deploy-reliability's founding law, transplanted verbatim — every later
  absorption or limiter claim is a before/after against this baseline; without it every claim is
  vacuous green. Layer 0 extends RequestStats: its telemetry handler already fires on
  `[:phoenix, :endpoint, :stop]` with the full conn in scope — widen the ETS key with a coarse
  route class and an `authed?` bit; group `compute/4` by it. No new process, no Prometheus
  cardinality. *(Class enum and authed? design RESOLVED by run-proof at wave 1 — see D9/D11; the
  original "anon-browser / API / static / LV" enum sketch is superseded: `static` is structurally
  unemittable and LV means dead-render only.)*

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
  unbatched task blocks) — the dedupe target is restated in measured absolute statements at D14
  (pure memoization alone has a measured ceiling of −32%, so "halves the floor" holds only as
  memo + N+1 batching + duplicate-walk removal combined).

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
  user's pick of three prepared templates); the cloud console gets Disallow-all (a cch
  coordination — corrected to THREE files at D15, not one); web and spawned sites stay allow-all.
  Both files smoke-asserted byte-for-byte; instantly live via auto-deploy. *(Shape, file set,
  smoke hosts, and the human-gated AI stanza are ruled at D15.)*

- **D7 — The router.ex pipeline edit is sequenced DEAD LAST and rebases onto whatever lands.**
  *Why:* the most contended file in the program — open PR #9530, site-spawner ssw10 residue (task
  open 7/9; its PR #7870 MERGED 2026-07-30 — L1 beats carried notes; ssw11 unresolved),
  deploy-reliability D17 gating the adjacent region. Rebase cost, not semantic duplication.
  *(The stale four-key meter comment at router.ex:1603-1613 is ruled stale-benign and scheduled
  into slice 8 — D13.)*

- **D8 — The two reader LiveViews are edited only under a numbered cch carve-out, requested in
  cch's own idiom.** *Why:* `bulldocs_live.ex` + `finder_live.ex` sit inside
  cloud-console-hardening's fence; cch has zero hits on them across 49 waves, making the carve-out
  a formality — but matching the fence law costs one sentence and removes all ambiguity.
  *(Authorship and mechanics ruled at D16 — this epic authors the block itself, D397-shaped.)*

### Wave-1 Decide rulings (2026-08-08, every claim run-proven — recipes in `tooling/grip/ledger/am-w1-*.md` + `anon-metering-*-2026-08-08.md` + `robots-parser-proof-2026-08-08.md`)

- **D9 — The class enum is CLOSED AT FIVE: `lv_dead` / `browser` / `api` / `unrouted` /
  `pre_router`. D1's `static` member is DELETED and `LV` means dead-render only.** *Why, all
  run-proven:* (a) Plug.Static (endpoint.ex:56) halts before Plug.Telemetry (:75) — a served
  static file emits ZERO stop events (L2 probe: `stop_event_count=0` for a real 200; L1 mutation:
  400 static hits on live guerrilla moved req_per_s by 0.0 while 400 static misses and 400 API
  hits each moved it ~+6). A `static` class would count ONLY 404 misses — an honest-looking lie.
  (b) Socket paths are dispatched by `plug :socket_dispatch` inside the `use Phoenix.Endpoint`
  quote (deps/phoenix/endpoint.ex:506), BEFORE every user plug: even a real 400/403 handshake
  refusal is invisible to the meter — a check_origin 403 storm (Past Mistake #11) never appears.
  So the connected-LiveView leg is structurally unmetered; the moduledoc must name BOTH
  non-classes (`static_served`, `lv_connected`) as blindness, not coverage. (c) Classification at
  the stop handler reads `conn.private[:phoenix_live_view]` (present on LV dead renders) and
  `Phoenix.Router.route_info/4` — the ONLY door to `pipe_through` (`conn.private[:phoenix_route]`
  does not exist in ANY observed case; `:public_root` is a plugin scope tag, not a pipeline).
  `route_info == :error` with `:phoenix_router` present ⇒ `unrouted` (where a crawler storm
  lands); `:phoenix_router` absent ⇒ `pre_router` (halted upstream: PublicShareGuard,
  parse_body, CORS preflight). route_info/4 is one compiled dispatch per request — real but
  acceptable hot-path cost, stated in the module; never solved by stamping pipelines in router.ex
  (D7). W2's would-be-429 refusal counters are a DIMENSION inside class objects (`would_429`),
  never a sixth class.

- **D10 — The read shape widens ADDITIVELY with four new top-level keys — `count`, `elapsed_s`,
  `sampled_at`, `classes` — because no D3-legal line is writable from the current 4-key shape.**
  *Why:* `compute/4` computes `count` (:130) and discards it; the payload carries a rate with no
  volume over an unpinnable monotonic ring, and seven live reads on an idle box were 4x-incoherent
  (req_per_s 2.77–11.58, p95 36–2885ms). Each `classes` entry is
  `{count, req_per_s, authed, anon, auth_unknown}` — integer counts, the reader derives rates;
  `{}` on an empty window. **"Additive" still requires one deliberate edit at THREE sites** —
  the closed-world 4-key sort pin at `request_stats_controller_test.exs:41-42`, the test NAME at
  `:31`, and the controller moduledoc (:14-20 "Wire contract — FOUR keys") — plus request_stats.ex's
  own moduledoc. This exact pin already reded the ENFORCED Elixir gate once (#9888's widening;
  repair slice `dr-w6-s1-land-the-stack`). The ETS row widens too, and the prune matchspec's
  arity MUST widen with it (a stale-arity matchspec matches nothing and the prune becomes an
  unbounded leak — the code's own comment). NO Go-agent or CP edits: the agent's named-struct
  decode ignores unknown keys (mutation-proven; `window_s` is already served-and-dropped —
  `dr-w14-bl-agent-beat-drops-window-s`). **Window semantics, honestly:** the 60s ring can never
  satisfy dr D34(b) reproducibility; what it CAN produce is a timestamped spot observation —
  "at `sampled_at`, over the preceding `elapsed_s` s: n=`count`, rate=X/s". Wave-log lines take
  exactly that form; below n≈200 the rate is REFUSED and the volume printed (dr D3 via D2).
  Deterministic per-mount harness counts (D14) are full-population counts, NOT sampled rates —
  the n≈200 floor does not apply to them, and the wave log states that distinction.

- **D11 — `authed?` is THREE-VALUED — `{authed, anon, auth_unknown}` — derived from PIPELINE
  COVERAGE, never from assign absence.** *Why, run-proven:* OptionalToken passes an anonymous
  conn through UNTOUCHED, and the bare `:browser` pipeline runs NO auth plug at all — a
  signed-in browser session reaches endpoint-stop with zero identity assigns (probe e2), because
  reader identity resolves on the SOCKET (live_auth.ex on_mount, session-read), after the stop
  event. Rules: `authed` = `conn.assigns[:api_token]` present at stop; `anon` = absent AND the
  route's `pipe_through` intersects an explicit auth-resolving pipeline allowlist (a module
  attribute in request_stats.ex, pinned by its own test — same-file allowlist pins are correct);
  `auth_unknown` = absent AND no auth-resolving plug ran. Consequence stated up front: `lv_dead`
  and `browser` will report auth_unknown≈all — that is D1's named unknown SURFACED honestly, not
  a defect, and no surface may render `auth_unknown` as either "authed" or "anon". An invalid
  Bearer on `:api` counts as `anon`. Session-PRESENCE narrowing (the session map IS readable at
  stop on browser conns) is a W2 refinement, named `session_present` if built, never rendered as
  "authed" — and the handler must branch on `Map.has_key?(conn.private, :plug_session)` because
  `get_session/1` RAISES on `:api`/unrouted conns.

- **D12 — Wave 1's operator surface is the authed `GET /v1/instance/request-stats` itself; beat
  and console carriage is W2 work, filed with teeth.** *Why:* the wish's "operator can ask the
  box" is satisfied by asking the box — the route is live, and the token recipe is proven
  (`/etc/barkpark/agent.health.token` on the box, injected via the barkpark-agent systemd
  drop-in; ledger `anon-metering-live-box-l1-2026-08-08.md`). Riding the per-class map onto the
  #9888 beat NOW would mint the program's THIRD dead key: `err_5xx_per_s` is extracted by the
  agent and rendered by NOTHING (telemetry.ex reads only req_per_s/p95_ms), and `window_s` dies
  at the agent decode — the seam leaks in both directions. The W2 carriage task must carry:
  (a) the six-site checklist by name (report.go struct+probe, telemetry.ex, usage.ex,
  cloud_usage.go ×3 sites, app.js ×2 meter lists, payload_key_set_census allowlist — the census's
  `MapSet.size(p.top) == 42` pin trips the moment the Report struct widens); (b) a
  decoded-but-unrendered = RED criterion (any beat key present ⇒ rendered on a console surface,
  else the task cannot close); (c) full-slug citations of `dr-w5-s2-beat-carries-load15-and-5xx`
  (deploy-reliability's own half-done 5xx carriage — coordinate, never rebuild) and
  `dr-w14-bl-agent-beat-drops-window-s`. Interface law holds: no new alert producer.

- **D13 — router.ex:1603-1613's four-key meter comment is left STALE-BENIGN this wave; slice 8
  refreshes it.** *Why:* the fence grants router.ex "pipeline bodies (D7 sequencing)" ONLY — a
  comment edit is out-of-fence, and a numbered widening for zero behavior buys rebase exposure in
  the program's most contended file. Post-D10 the comment is under-inclusive, not false (its four
  named keys still exist; the test it cites still pins the wire). The note lives in
  request_stats.ex's moduledoc (rewritten by slice 1 anyway): "router.ex:1603-1613 enumerates the
  pre-class four-key shape; refreshed in slice 8." Slice 8 gains that criterion.

- **D14 — Slice 3's target is restated in MEASURED ABSOLUTE STATEMENTS on a pinned fixture; the
  harness is the wave's permanent scoring tool and carries its own mutation trap.** *Why:* the
  baseline is now measured (origin/main `5b68852f4`): three-shape fixture = **22 dead / 44 both
  legs**; bare paper = 10/20; identical-read memoization ceiling = 15 distinct (sql,params) pairs
  per leg (−32%, NOT −50%); driven-tasks N+1 slope = exactly 4.0 statements per additional citing
  task per leg (= `Content.get_document/4`'s scoped cost; the batch sibling
  `Content.get_documents_by_ids/3` already exists). Acceptance: on the pinned fixture, **dead leg
  ≤ 15 AND both legs ≤ 30 AND the slope ≤ 1.0 statements per additional citing task per leg** —
  never a bare percentage (D2/D3 law). The three dedupes: duplicate `reverse_referencers` walk
  (bulldocs_live.ex :249 + expectations.ex :78, identical args — dedupe by sharing ONE walk, the
  ~33-line bulldocs_live carve-out; a graph.ex memo layer is REJECTED as a new caching semantic
  in a 12-caller module), driven-tasks N+1 (batch inside expectations.ex), unbatched task blocks
  (memo inside task_resolver.ex/papers.ex closures). Harness: copy
  `count_repo_queries` from `graph_controller_test.exs:527` — the pid-filter-FREE shape — count
  the dead leg via `get/2` and both legs via `live/2` and subtract; the pid-filtered variant
  under-reports by EXACTLY the connected leg (mutation-measured 44→22) and the harness keeps that
  trap as a permanent failing-counter test. Fixture census pinned in the test (all three shapes,
  distinct task titles — the publish-time dedup wall refuses near-duplicates at 0.71 similarity —
  and every paper carries a body block past the quality gate). Known limit, stated in the
  moduledoc: a statement-count harness is structurally blind to rows-transferred savings.

- **D15 — Slice 2's exact shape: api is a CONTENT-ONLY rewrite in D6's literal order-insensitive
  form; cloud is a THREE-FILE edit; the AI-crawler stanza is a HUMAN GATE.** *Why, all proven:*
  (a) api: `robots.txt` is already in `static_paths/0` and already served live (203-byte stock
  stub, byte-identical origin↔guerrilla; no Caddy interception on either box — both Caddyfiles
  read on-box, api's is a bare reverse_proxy). Policy body = D6's literal list (Allow `/papers/`,
  `/sheets/`; Disallow `/finder`, `/quiz/`, `/studio`, `/login`, `/s/`) — parser-proven
  order-insensitive with zero urllib↔RFC-9309 divergence; the ALLOWLIST shape (`Disallow: /`
  first) is REJECTED: CPython's parser is first-match-wins and reads it as deny-all (measured
  divergence). Trailing slashes are load-bearing (`/s` without the slash also denies `/studio`);
  NO wildcards (urllib silently ignores `*`/`$`); the smoke must pass BARE product tokens (a
  Mozilla-shaped UA defeats urllib's group matching). Known accepted divergence, policy-not-
  protection: `/papers/:slug/source` + `/email` stay crawlable under Allow `/papers/`.
  (b) cloud: `cloud/priv/static/robots.txt` (NEW, `User-agent: *` / `Disallow: /`) + `robots.txt`
  APPENDED to the `only:` allowlist at `cloud/lib/barkpark_cloud/web/router.ex:418` (PREPEND reds
  `scripts/cloud-static-gz-guard.sh`, which anchors on `only: ~w(index.html`) + a 200 AND
  byte-for-byte body assertion in `cloud/test/web/static_allowlist_test.exs` — the existing test
  is blind in BOTH directions (three-state mutation proof: file-alone 404s, allowlist-alone 404s,
  suite green in all three states). robots.txt is NOT added to the Dockerfile gzip line.
  (c) Smoke hosts: `guerrilla.barkpark.cloud` (api) and `barkpark.cloud` (cloud) —
  **`api.barkpark.cloud` IS the cloud control plane** (3-line CP Caddyfile read on-box), and
  smoking it would test the wrong app. The deployed-box byte-for-byte smoke is merge evidence,
  tolerant of Caddy's transient 503 maintenance page during deploy windows.
  (d) The three AI-crawler templates D6 promises EXIST NOWHERE (charter grep: one unrelated hit).
  Inventing the user's stance would be the "signal addressed to nobody" failure — so wave 1 ships
  the shared path floor with no AI stanza (= the OPEN stance) and the pick is filed as human-gate
  task `am-hg-ai-crawler-stance`, carrying vendor-verified rosters (OpenAI is FOUR tokens incl.
  `OAI-AdsBot`; Anthropic publishes ClaudeBot/Claude-User/Claude-SearchBot — `anthropic-ai` is
  legacy; Meta's casing is lowercase `meta-externalagent`). When the user picks, the stanza is a
  one-file content edit riding the same smoke.

- **D16 — This epic AUTHORS the cch carve-out itself (D397-shaped foreign edit), riding this
  wave's charter PR: one Wave-anon-metering widening block + one pointing D-row in cch's charter,
  TWO subjects, FIVE files by name.** *Why:* sequencing (the block must exist before builders
  edit the fenced files, and waiting on cch's cadence serializes the wave), precedent (cch's own
  D397 edits a foreign charter by path+line; its widening idiom is designed to be smoke-read),
  and drown-risk (a request-task joins a 100+-row queue). Subjects: (1) cloud console robots
  Disallow-all — the three files of D15(b), and nothing else; (2) reader LiveView query-shape
  dedupe — `bulldocs_live.ex` (~33-line section surface) + `finder_live.ex`, read-path only, and
  nothing else. D-number picked from ORIGIN at commit time (D617 free at authoring, 2026-08-08;
  cch waves run daily — on any rebase collision RENUMBER, never squat), reported by line number
  in the PR body. Neither bullet licenses this epic's later waves — W2's socket hooks (D4 Gate B)
  return for their own numbered grant.

## Fence

**In fence:** `api/lib/barkpark_web/request_stats.ex` · `api/lib/barkpark_web/plugs/rate_limit.ex`
· `api/lib/barkpark/rate_limiter.ex` (additive connect_info-shaped variant) ·
`api/priv/static/robots.txt` · `cloud/priv/static/robots.txt` +
`cloud/lib/barkpark_cloud/web/router.ex` (`only:` allowlist line ONLY) +
`cloud/test/web/static_allowlist_test.exs` (the D15/D16 three-file cch coordination — widened
from the original one-file note by D15's proof that the file alone ships a 404) ·
`api/lib/barkpark_web/router/plugins.ex` + a new live/hooks module ·
`api/lib/barkpark/quiz/room.ex` · router.ex pipeline bodies (D7 sequencing) ·
`bulldocs_live.ex` + `finder_live.ex` (D8/D16 carve-out only) · `api/lib/barkpark_web/endpoint.ex`
(`/live` connect_info region only — disjoint from E1's statics region by ~30 lines) ·
the request-stats test files (`api/test/barkpark_web/request_stats_test.exs`,
`api/test/barkpark_web/controllers/request_stats_controller_test.exs`) + controller moduledoc —
named explicitly because D10's pin edit is deliberate, not incidental.

**Out, by design:** box memory/swap levers (deploy-reliability owns them: task-cbde37238506ed7c,
task-aa775c3d30287a4b, dr-bl-* rows — cited by full slug, never rebuilt); the playground limiter
(bpb-playground-rate-limit — different surface); the pulse/bulldocs-form inline limiters (already
self-limiting); `public_read.ex` (never touched); the Go agent + CP beat surfaces this wave
(D12 — W2, with teeth). Every fence widening is a numbered, subject-scoped,
not-to-be-widened-again decision in this file.

**Interface law (program-wide):** no new alert or email producers (deploy-reliability D14/D321);
every operator-facing signal names its audience explicitly (PLATFORM_ADMIN_EMAILS is unset on prod
— a signal addressed to the default population is addressed to nobody).

## Roadmap

Layered by D1/D3: instrument → policy → absorption → enforcement.

| # | Slice | Surface | Size | Wave | Status |
|---|---|---|---|---|---|
| 1 | Layer 0 — RequestStats route-class + authed? instrument (THE PROGRAM'S FIRST MERGE; D9/D10/D11) | `api/**` | medium | W1 | filed `am-w1-s1-request-stats-route-class` |
| 2 | robots.txt: api real policy + cloud Disallow-all THREE-file edit, byte-for-byte smoke (D15) | `api/priv/static/robots.txt` + cloud robots trio | small | W1 | filed `am-w1-s2-robots-policy-both-surfaces` |
| 3 | Reader query-shape dedupe + permanent query-count harness (D14; merges only AFTER slice 1) | `api/**` (D16 carve-out for bulldocs_live) | medium | W1 | filed `am-w1-s3-reader-dedupe-and-harness` |
| 4 | Reader render cache (ETS, PubSub-evicted, mutation-tested) + finder single-flight | `api/**` | medium | W2 | backlog `am-w2-s4-render-cache-and-single-flight` |
| 5 | Gate A: RateLimit `:browser` class, HTML 429 + Retry-After, shadow-first | `api/**` | medium | W2 | backlog `am-w2-s5-gate-a-browser-shadow-limiter` |
| 6 | Gate B: connect_info + client_ip variant + :public_root hook + finder hook, shadow-first | `api/**` | large | W2 | backlog `am-w2-s6-gate-b-socket-hooks` |
| 7 | Quiz per-IP spawn budget at Room.ensure/1 | `api/**` | small | W2 | backlog `am-w2-s7-quiz-spawn-budget` |
| 8 | router.ex pipeline lines + the D13 comment refresh (SEQUENCED LAST, after E1 and ssw residue) | `api/**` | small | W2 r2 | backlog `am-w2-s8-router-pipeline-lines` |
| — | Per-class carriage to beat/console, with teeth (D12) | `internal/**` + `cloud/**` | medium | W2 | backlog `am-w2-per-class-carriage` |
| — | AI-crawler stance pick (HUMAN GATE, D15d) | `api/priv/static/robots.txt` | small | any | filed `am-hg-ai-crawler-stance` |

*(The pre-wave-1 Status column claimed all eight slices "filed" while the epic task had ZERO
children — corrected 2026-08-08; every id above now names a published bp task.)*

**Not this epic:** header correctness and cache policy (E1, `task-02ce7e5183108eb3`); packaging
(E3, `task-3ae717d5f9324399`); box sizing and swap hygiene (deploy-reliability); the spawned-site
pipeline (site-spawner). The idle-box p95 anomaly (2.2–2.9 s p95 observed on an idle guerrilla —
possibly SSE/long-poll inflating the flat unweighted p95) is FILED for triage as
`am-bl-idle-p95-anomaly` and may transfer to deploy-reliability after slice 1's per-class split
makes it interpretable.

## Sequencing with the sibling epics

Slice 1 merges before anything in E1 or E3 that wants to be scored on traffic. E1 lands its
`paper_revision_headers.ex` change first; this epic's telemetry line in that plug rebases after.
Slice 8 waits for E1's plug change AND the ssw10/#9530 residue. The cloud router `only:` line
(:418) is co-tenanted by four open PRs (#10154/#10129/#9956/#6028) — none within ~1000 lines of
the allowlist; file-level rebase noise only. Builders brief from ORIGIN, never the working tree:
the primary checkout has run hundreds of commits behind and its request_stats.ex predates
err_5xx entirely; every worktree needs its own `mix deps.get` (the main checkout's api/deps does
not satisfy origin's mix.lock).

## Wave log

<!-- one row per wave: date · wave paper · slices merged · the number that moved (rate WITH volume, pinned window) -->
