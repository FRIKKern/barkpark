# HTTP Edge Truth — Epic Charter

Epic task: `task-02ce7e5183108eb3` · Program task: `task-21cd02088dd2f762` ·
Founding papers: `/papers/hobby-hardening-capstone` (crown) · `/papers/hobby-hardening-http-edge` (lane) ·
`/papers/barkpark-hobby-scale-swot` (frame) · Wave 1 paper: `/papers/http-edge-truth-wave-2026-08-08`

This file is the epic's memory. Decisions (D#) are never silently reversed — a reversal is a new
numbered decision naming the old one and the evidence that moved.

## Vision

**The edge tells the truth.**

Falsifiable form: every cacheable public response carries an explicit, correct policy; every
conditional request the server invites, it honors; no header promises an immutability the write
paths can break.

**Ground truth at epic open (2026-08-07, live on guerrilla):** anonymous media curls observe
`public, max-age=31536000, immutable` on BOTH the original and rendition local-file branches; the
paper reader emits a sha256 ETag it never honors (an exact If-None-Match replay returns 200 plus
the full 200,809-byte body); the undigested Studio shell ships bare `public` and caches
heuristically stale after every deploy; `/v1/data/query`'s honored ETag is representation-blind
(id:rev inputs vs a body that varies by caller_context and `?fields=`).

The corrected defect model is the law here, not the SWOT's bullets: Plug.Conn defaults every
response to `max-age=0, private, must-revalidate` (deps/plug conn.ex:241, live-verified) — a safe
policy. This epic repairs the departures from and under-uses of that default. It is not "add
caching."

## Decisions

- **D1 — Every fix moves in the safe direction only: shorten, privatize, or validate. Never a new
  long-lived public header before the contract behind it is proven true.** *Why:* every `api/**`
  merge auto-deploys guerrilla, and a wrong long-lived header, once absorbed by strangers' caches,
  cannot be recalled. The sole irreversible residue already on the books — gated-capable bytes
  stamped public-immutable since 2026-05-25 — is disclosed, priced ~nil on guerrilla (zero
  mediaAsset docs; `Access.visibility(nil)` hardcodes "public"), and un-recallable. We add no more.
  *(Precision update, W1 verify: guerrilla holds 184 media_files with 184 draft mediaAsset docs,
  all `public` visibility, zero orphans — so the nil→public arm has zero live subjects and the
  "zero mediaAsset docs" phrasing meant zero PUBLISHED docs. Residue pricing unchanged.)*

- **D2 — Cache-policy slices are HUMAN-GATED with a named reviewer, and each carries a post-merge
  L1 proof: the curl transcript rerun against prod, pasted into the task before close.** *Why:*
  deploy-reliability D17 precedent; merged means live, cached means gone. *(Mechanics and scope
  boundary: D13.)*

- **D3 — SUPERSEDED BY D9.** The reader 304 fix was to validate on `released_revision_id`. W1
  verification refuted both halves of its rationale: (a) the field's writer is a PG trigger
  (`revisions_bind_document`, migration 20260719010000:285-324) fed by `Broadcast.save_revision`,
  and the dominant paper write path — `Papers.BlockOps.upsert_paper` (block_ops.ex:298 →
  persist_blocks_doc:443, bare Repo.insert/update:470-472) — never calls it, so 115/722 published
  papers (including the crown paper) have `released_revision_id` nil as an ONGOING leak (8 new
  nils in 2026-08, 13 after the trigger migration), not a closed era; (b) the "change signal the
  reader's own PubSub invalidation uses" sentence is refuted — the reader keys on
  `content["rev"]` (bulldocs_live.ex:618), not `released_revision_id`.

- **D4 — The media local-file branch becomes visibility-aware: public → short max-age +
  revalidate; private → no-store; token-visibility policy is decided in-wave (options: `private,
  max-age ≤ signature TTL` vs `no-store`) and recorded as a D# when decided.** *Why:*
  `urls.ex:11`/`:58` stamps the unconditional `@immutable_cache` AFTER `Access.allowed?` passes
  (media_controller.ex:99/:142). The 302-to-blob branch already sends `private, max-age=0`
  (media_controller.ex:196-201) and is untouched. The one pinned test
  (media_delivery_test.exs:100,136) co-changes in the same PR. *(Token arm decided: D12.)*

- **D5 — Immutability is earned in two sequenced slices: cap the lifetime NOW; content-address the
  rendition URL (fold in the watermark profile) SECOND, as its own slice.** *Why:* immutable is a
  lie three ways today — `put_blob` overwrites paths with no exists-check (media.ex:572-598;
  File.write truncates), renditions NEVER ride the blobstore even under S3 (blobstore.ex moduledoc
  — the 302-safe branch covers originals only), and an ordinary edit to `rights.watermarkProfile`
  swaps rendition bytes under an unchanged URL (renditions.ex:40-42 vs :54). URL re-keying is a
  link-rot risk for URLs already embedded in published paper HTML — headers first, re-keying
  deliberately second, old URLs must keep resolving to old bytes or 404 — never new bytes.

- **D6 — The query ETag is representation-fixed by OMISSION: no ETag when a token or `?fields=`
  projection is present. `Vary: Authorization` lands on tier-keyed ETags (capabilities, query) as
  defense-in-depth.** *Why:* simplest correct fix for an ETag keyed on id:rev while the body varies
  by principal and projection; CDN managed policies can cache through `private` (CloudFront's own
  docs — verbatim; the Cloudflare/Fastly rows are search-synthesized and must be pinned by direct
  fetch before the doctrine appendix cites them). The query envelope is documented contract —
  `docs/api-v1.md` co-changes; the capabilities edit is coordinated with sibling task
  `ctx-b2-server-view-brief`, never duplicated.

- **D7 — Port cloud's proven two-plug static doctrine to api's bare Plug.Static: hashed
  assets/fonts immutable, unversioned shell no-cache+etag. phx.digest is explicitly rejected.**
  *Why:* the doctrine is already encoded and exact-string-tested in
  `cloud/lib/barkpark_cloud/web/router.ex:326-421` (the fixed stale-console bug); api has 37 raw
  asset references and 0 sigils — the two-plug port is strictly cheaper than introducing a digest
  pipeline. *(Narrowed by D14: the fonts-immutable arm is deferred — api has no content-addressed
  URLs, so only the no-cache half ships in W1.)*

- **D8 — Every fix ships with mutation-proof header pins. The header test suite is a deliverable,
  not a nicety.** *Why:* two load-bearing header pins exist in the whole codebase (media immutable;
  cloud's two-plug doctrine). 9 of 11 override sites, all Vary behavior, and the statics policy are
  free-floating — regressions are currently invisible. House laws bind: distrust vacuous green,
  make the check able to fail, mutate don't read. *(W1 census reconciled: exactly 11
  `put_resp_header("cache-control", …)` sites in api/lib, 2 pinned — media_delivery_test.exs:100/:136
  and login_ticket_test.exs:77 count as the two SITES; api/test carries three pin ASSERTIONS.)*

- **D9 — (supersedes D3) The reader conditional emits a WEAK, time-bucketed, content-addressed
  ETag for EVERY published paper, and honors it: ETag = `W/"sha256:<canonical_digest(content)>.<bucket>"`
  with a 7-day UTC bucket; papers embedding live task blocks emit NO ETag at all.** *Why, all
  L1-proven in W1 verify:* (a) the real bug is simpler than D3 assumed — the ETag is emitted then
  IGNORED (exact replay → 200 + 200,809 bytes; no If-None-Match read exists in the plug); (b) the
  `released_revision_id` presence gate leaves an ongoing 16% hole (see D3) — the digest is
  computable for every paper, so the gate widens to "published paper exists";
  `x-barkpark-paper-revision` still emits only when the rrid is present; (c) the ETag MUST be weak:
  the rendered body differs on 12 lines per request (nonces, CSRF, LV tokens) — a strong validator
  over it is a protocol lie, and RFC 9110 §13.1.2 mandates weak comparison for If-None-Match
  anyway; (d) the 7-day bucket bounds staleness BELOW LiveView's 14-day session-token expiry —
  without it a "valid" 304 replays >14-day-old HTML whose expired LV token triggers a same-URL
  redirect loop; (e) papers with live task blocks (the `has_live_task_blocks?` predicate,
  bulldocs_live.ex:766 — ≤15 of 722 published papers, ~2.1%) re-render on task mutations without
  the paper's content moving, so a content-keyed 304 would serve stale boards; at 2.1% exclusion
  is cheap and honest. Co-change law: `scoped_paper_controller_test.exs:472-480`
  (`assert_revision_headers/2`, reached from :78 and :360) pins the strong etag byte-for-byte and
  MUST co-change in the same PR.

- **D10 — The 304 branch DELETES the content-security-policy header before send_resp, re-emits the
  SAME etag and cache-control, and co-lands with the weak etag and time bucket in ONE PR.** *Why,
  browser-proven (Chrome 151) + RFC-grounded in W1 verify:* PaperReaderCsp mints a fresh nonce
  eagerly in call/2 (paper_reader_csp.ex:87), upstream of any halt. A bare 304 therefore carries a
  fresh-nonce CSP, and Chrome APPLIES it to the cache-served body — the stored body's nonced
  inline scripts (including the LiveSocket boot) are blocked, the break is PERMANENT (each 304
  overwrites the stored CSP again), and it fires on plain navigations. RFC 9111 §3.2 makes this
  header-merge spec-mandated, so bare-304 breaks in ALL conforming browsers. A 304 that OMITS the
  header leaves the stored CSP retained and ENFORCED (Chrome-proven; spec-implied) — the policy
  governing the executed body stays byte-identical to the one that shipped with it, and CSP is not
  on RFC 9110 §15.4.5's 304 MUST-generate list (Content-Location, Date, ETag, Vary, Cache-Control,
  Expires — which IS why the 304 must re-emit etag + cache-control). sha256 script hashes rejected
  (larger surface; D1 prefers the minimal safe move); no-HTML-304 rejected (a safe 304 exists).
  Residual risk named: Mode-B retention observed in Chrome only — independent second review
  warranted before merge (see HIGH-FLIP-RISK flag on the slice).

- **D11 — One If-None-Match semantics, program-wide: fold ALL header values, split the list on
  commas, trim OWS, honor `*`, compare weakly (strip only a leading `W/` from BOTH sides, then
  compare the full quoted opaque-tag octet-for-octet).** *Why:* the repo has four INM matchers
  with three semantics and none does list/`*`/weak (urls.ex:61 pin-matches the first value;
  query_controller strips quotes too — over-lenient; capabilities/openapi do exact compare). The
  media gap is LIVE-PROVEN: against prod, strong replay → 304 but `W/"…"`, list, and `*` forms all
  → 200 full body — RFC 9110 §13.1.2 violations whose failure direction is cost, never a false
  304. The new reader validator (slice 1) implements D11 from birth; `urls.ex`'s matcher is
  co-fixed inside slice 2 as its own labelled hunk with its own red-before pins. Unifying all four
  into a shared helper is deliberately deferred (backlog `het-bl-inm-shared-helper`) — it would
  drag query/capabilities files into W1 PRs that W2 slice 4 and sibling ctx-b2 already edit.

- **D12 — (implements D4; decides the token arm) Media visibility→policy map: `public` →
  `public, max-age=86400, must-revalidate` keeping etag + 304; `token`, `private`, and any UNKNOWN
  value → `no-store` with NO etag, returning BEFORE the in-function 304; nil asset doc → the
  existing `public` default (defensive, zero live subjects — pinned by unit test only).** *Why:*
  the token arm gets `no-store`, not `private, max-age ≤ TTL`, for two proven reasons: guerrilla
  has ZERO token and ZERO private assets today (184/184 public — the no-store branch has no
  natural live subject and the D2 transcript must SEED one), and RFC 9111 §3.5 names
  `must-revalidate`/`public`/`s-maxage` as the exact directives that RE-ENABLE shared-cache reuse
  of Authorization-bearing responses — so the safe token arm is no-store until a real token
  consumer exists. `must-revalidate` on the public arm is safe: public media fetches are
  anonymous. Unknown visibility strings fail closed to no-store (mirrors `delivery_ok?/3`'s
  catch-all). The prod proof's private subject is seeded via the NON-ADMIN write path — router.ex
  :2160 `PATCH /v1/media/:dataset/:id` (`:media_mutate`, no require_admin) with `bp_visibility`
  in the `@metadata_fields` allowlist (media.ex:14) — then reverted.

- **D13 — (scopes D2) Human gates discharge POST-merge in the cch D182 shape; pre-merge
  named-reviewer wording is banned as unsatisfiable. D2's reviewer gate binds slices that LENGTHEN
  a lifetime or widen a public promise; a pure SHORTENING carries the post-merge L1 transcript but
  no named reviewer.** *Why:* a pre-merge independent-reviewer criterion has NEVER been discharged
  in this repo (site-spawner D122: seven wave-10 PRs at reviews=0; cch D181 ruled the wording
  unsatisfiable; dr-w1-s1 c6 is stuck at 6/8 today on exactly that shape). The working precedent
  is cch D182: lead-dispatched, post-merge, re-derived by DRIVING merged bytes, durable ruling at
  `tooling/grip/ledger/<epic>-w<N>-<slice>-independent-review-<date>.md`. Timing law: there is NO
  503 window (guerrilla deploys are blue/green; instance job ~5.5-6.5 min) — the L1 transcript
  waits for deploy.yml run SUCCESS on the merge sha (that run's own smoke test is the live
  signal) and opens with a deploy-identity step. W1 application: slice 2 (lengthens nothing but
  rewrites the public promise — reviewer-gated); slice 3a (pure shortening, bare `public` →
  `no-cache` — transcript only, no reviewer).

- **D14 — (narrows D7) The statics port ships in W1 as 3a ONLY: the single endpoint Plug.Static
  gains `headers: %{"cache-control" => "no-cache"}` AND `cache_control_for_etags: "no-cache"`
  (both keys, cloud's two-key discipline). The fonts-immutable arm (3b) is DEFERRED — barred by
  D1's second sentence, not merely gated.** *Why:* api's fonts are content-STABLE, not
  content-ADDRESSED, and rule 3 of the header doctrine permits `immutable` solely for
  content-addressed URLs. The stability premise is empirically broken on this codebase:
  `Inter-var.woff2` exists in two byte-versions under one filename across surfaces (api 223,892 B
  full vs cloud 40,644 B latin subset; cloud's own copy has held 2 distinct blobs), and
  `au-eg-s9-reading-serif-selfhost` explicitly parked the reading-stack cutover — a NAMED open
  future edit to the serif bytes. A year-long immutable would strand stale faces with no recall
  lever. Fonts ride no-cache+etag until content addressing (slice 5 class) reaches them
  (`het-bl-fonts-immutable-behind-addressing`). Port mechanics: the correct pin source is cloud
  `router_test.exs:2018-2041` (the survey's 1992-2014 cite is SPA body tests — wrong 23 lines);
  the `gzip:` flag STAYS (it is a no-op for bytes — zero .gz siblings — but removing it silently
  drops `Vary: Accept-Encoding`); NO etag-based freshness check may be added (cch D139
  non-contradiction: Plug.Static's etag is phash2({size, mtime}) of the served file — one
  identical git blob serves under three different etags on three hosts); the policy explicitly
  NAMES `/assets/bp-pdrender.wasm.gz` (3,016,905 B, deploy-built, name-stable/bytes-volatile —
  no-cache is correct for it; steady state is a 304). Stated cost, accepted: mtime etags rotate
  every deploy even for unchanged bytes, so the first post-deploy load is full 200s across the
  asset set — that IS the stale-shell fix working; no mutation proof may be phrased as "the etag
  changed."

- **D15 — Slice 6 (W1 half) pins the 9 unpinned override sites in a new ConnCase suite
  (`api/test/barkpark_web/integration/http_cache_policy_test.exs`), full-list-equality assertions,
  each proven by a mutation transcript. Vary pins wait for W2 slice 4.** *Why:* census reconciled
  at exactly 11 sites / 2 pinned; ConnCase reaches the endpoint chain with zero new infra
  (proven by probe: `build_conn() |> get(path)` runs Plug.Static and every endpoint plug). api's
  own pin shape (full-list `== ["…"]`, media_delivery_test.exs:100) beats cloud's first-header
  helper — a duplicate header cannot hide.

- **D16 — E1/E2 first-merge ruling: E1 slice 1 merges without waiting on E2. The two "first merge"
  laws are orthogonal — E2's binds work E2 SCORES (absorption/limiter work measured by its
  RequestStats instrument); E1's plug validator is not scored work. E1 owes E2 WRITTEN NOTICE that
  slice 3a adds cache opts to endpoint.ex's Plug.Static; E2's charter correction (a) premise
  (Plug.Static halts before Plug.Telemetry, so a static class is unemittable) REMAINS TRUE after
  3a — same plug, same position, opts only.** *Why:* E2's wave paper asserts its slice 1 is "the
  PROGRAM'S FIRST MERGE" while banking on "nothing in E1 has merged"; left unruled, whoever merges
  first silently falsifies the other epic's paper. E2's fence sweep predates E1's task filings by
  construction. Notice filed as `het-w1-bl-e2-endpoint-notice`; the lead relays it. E2 has no
  plug-telemetry slice and never targets `paper_revision_headers.ex` (verified against its live
  wave paper — the file appears once, as an observation).

- **D17 — `bpb-step7-content-edge-cache` closes AFTER W2 slice 4 merges, on a fresh claim by the
  W2 slice-4 builder (its `claim` is null — no epoch exists to close on). Leg C is refiled NOW as
  its own row: read-envelope `syncTags` are metadata-only IN THIS REPO (nothing keys a cache off
  the /v1/data/query envelope), while the WEBHOOK-path consumers are real and tested
  (js/packages/nextjs revalidate/index.ts:149→revalidateTag; web webhook route.ts:96) — so a
  blanket "tags are metadata only" ruling would be FALSE; the pin is scoped to the read envelope.**
  *Why:* the crown paper ratifies ABSORB-and-close but states no timing; step7's legs A+B are
  exactly W2 slice 4's payload; its own criterion 2 pre-authorizes the metadata-only recording.
  Also repaired this wave: the epic task description's slice numbering contradicted the charter
  (3/5 swapped) — the charter's numbering (3=statics, 5=rendition URL) is canonical and the task
  description is patched to match.

- **D18 — (implements D6; widens its shaping set, reverses nothing) The query ETag is withdrawn for
  THREE shaping params, not one — `?fields=`, `?expand=`, `?resolve=` — and for ANY bound principal,
  not only a token: `conditional_safe?/1` requires an anonymous caller context AND no shaping param
  before an ETag is emitted or an If-None-Match honored.** *Why:* D6 named `?fields=` and "a token"
  because those were the two the capstone had measured. Reading the code for this slice found the
  same blindness on two more axes with the same mechanism and no additional cost to close:
  `project_fields/2` keeps every `_`-prefixed key, so `_id`/`_rev` — the ENTIRE ETag input — survive
  a projection byte-identical, and `Expand.expand/4` and `maybe_resolve_tasks/3` both rewrite the
  body strictly after the ids and revs are fixed. The principal arm widens from "token" to "any
  non-anonymous `CallerContext`" because `RequireUserSession` installs a context WITHOUT setting
  `:api_token`, so a token-only test would have left every session-authenticated read still
  emitting a principal-blind validator. Direction is unchanged and still D1-safe: every arm
  WITHDRAWS a validator, so the worst outcome of overreach is a full 200 where a 304 would have
  done — never a stale or cross-principal body. *Live evidence that moved it (prod, anonymous, with
  a working 200-control):* `GET /v1/data/doc/production/task/task-f69b2c1a31b71ec0` and the same URL
  with `?fields=title` both answered the strong validator `"b75c68f15a031a542076615145dbe70c"` over a
  10,174-byte and a 630-byte body, and replaying the first ETag against the `?fields=` URL answered
  **304 with an empty body**; a bogus ETag on that same URL answered 200/630.

- **D19 — Capabilities is EXONERATED on the ETag axis and gets the `Vary` header only.** *Why:* the
  survey premise was that the tier-keyed ETag might collide across tiers. It cannot:
  `Capabilities.project/2` overwrites `auth_tier` and filters commands/nouns, and `etag_for/1`
  digests the PROJECTED map (dropping only `etag` and `generated_at`), so the tier is inside the
  validator by construction. A live anon-vs-token probe against guerrilla returned one identical
  ETag — but the DIFF showed the two bodies differing only in `generated_at`, and both reported
  `auth_tier: "none"`: the config token is stale and was resolving to anonymous, so that probe
  compared anonymous against anonymous and proved NOTHING about the tier axis. Recorded here so the
  next reader does not re-derive a collision from that transcript. The remaining real gap is the
  missing cache instruction, which is what this slice adds.

## Fence

**In fence:** `api/lib/barkpark_web/plugs/paper_revision_headers.ex` · `api/lib/barkpark/media/**`
(delivery, renditions, blobstore call sites) · `api/lib/barkpark_web/controllers/media_controller.ex`
· `api/lib/barkpark_web/endpoint.ex` (Plug.Static opts region only) ·
`api/lib/barkpark_web/controllers/query_controller.ex` + `capabilities_controller.ex` (ETag/Vary
regions) · `docs/api-v1.md` (co-change) · header test files · `api/lib/barkpark_web/router.ex`
ONLY at the :paper_reader_csp pipeline block (:356-358) and the :public_root scope's pipe_through
(:1184) — never the :461-471 public-read region.

**Out, by design:** `api/lib/barkpark_web/router.ex` public-read region (:461-471 — site-spawner
ssw10 precedent, human-gated) and `public_read.ex` — routed around entirely; everything
cloud-console-hardening fences (both reader LiveViews included: E1's fixes land at plug level, so
it never needs them — the live-task-block predicate is REIMPLEMENTED in the plug with a comment
naming its source, never imported from or edited in `bulldocs_live.ex`). Every fence widening is
a numbered, subject-scoped, not-to-be-widened-again decision in this file.

**Latent cross-fence row, named:** `cch-w34-bl-media-search-cursor-or-decomposition` (open,
unclaimed) targets `api/lib/barkpark/media/delivery/search.ex` — inside E1's fence, outside cch's
own. E1 does not build it; a future cch pickup requires a cch dispensation naming this line.

**Interface law (program-wide):** no new alert or email producers (deploy-reliability D14/D321 is
fleet law); any operator-notification consequence routes into deploy-reliability's rails; every
operator-facing signal names its audience explicitly.

## Roadmap

Ordered by risk (D1): validators first, header caps second, URL contracts third.

| # | Slice | Surface | Size | Wave | Status |
|---|---|---|---|---|---|
| 1 | Reader conditional honored: weak time-bucketed ETag on every published paper, CSP-safe 304, flat route covered (D9/D10/D11) | `api/**` | medium | W1 | **building** — `het-w1-s1-reader-304-conditional` |
| 2 | Media cache policy: visibility-aware local-file branch (D12); INM conformance co-fix; pinned test co-changes; HUMAN-GATED (D13) | `api/**` | medium | W1 | **building** — `het-w1-s2-media-visibility-cache` |
| 3a | Statics: no-cache on both Plug.Static keys, exact-string pins (D14) | `api/**` | small | W1 | **building** — `het-w1-s3-statics-nocache` |
| 3b | Fonts immutable — DEFERRED behind content addressing (D14 bars it under D1) | `api/**` | small | W3+ | deferred — `het-bl-fonts-immutable-behind-addressing` |
| 4 | Vary: Authorization + query-ETag omission fix; api-v1.md co-change; coordinate ctx-b2; closes bpb-step7 (D17) | `api/**` + docs | medium | W2 | filed — `het-w2-s4-vary-query-etag` |
| 5 | Immutable made true: rendition URL content-addressing (watermark profile in the key); put_blob overwrite semantics decided | `api/**` | large | W2 | filed — `het-w2-s5-rendition-content-addressing` |
| 6 | Header pin suite: W1 half = 9 unpinned override sites, mutation-proven (D15); Vary pins ride W2 slice 4 | `api/test/**` | medium | W1–W2 | **building** — `het-w1-s6-header-pin-sweep` |

**Absorbs:** `bpb-step7-content-edge-cache` (bp-cloud-build epic) — closed into this epic by name,
timing per D17 (after W2 slice 4 merges).
**Cites as sibling:** `ctx-b2-server-view-brief` (owns the RFC 9110 capabilities fix — one shared
controller edit is coordinated, not duplicated).

**Not this epic:** the public_read clamp (site-spawner ssw10/ssw11); deploy-ledger notification
surfaces (deploy-reliability w18); the scoped-media tier-bypass audit (dr-w2-s7 follow-up —
different defect class); CJK / search engine (filed candidate, per the program interview);
anonymous metering and limiters (E2, `task-8e9cac2018a7fe1c`); packaging (E3,
`task-3ae717d5f9324399`); the BlockOps no-revision publish leak (content-layer defect surfaced by
W1 verify — filed as `het-bl-blockops-revision-leak` for routing, not built here).

## Sequencing with the sibling epics

E1 lands its `paper_revision_headers.ex` change before E2 touches the same plug for telemetry —
the one file both epics edit, resolved by this ordering rule plus D16's first-merge ruling and
written notice. E3's "supported" blessing is DAG-gated on E1's media fix (slice 2) merging.

## Wave log

<!-- one row per wave: date · wave paper · slices merged · the proof transcript that moved -->
- 2026-08-08 · `/papers/http-edge-truth-wave-2026-08-08` · W1 cut: slices 1, 2, 3a, 6 (tasks
  `het-w1-s1-reader-304-conditional`, `het-w1-s2-media-visibility-cache`,
  `het-w1-s3-statics-nocache`, `het-w1-s6-header-pin-sweep`), all round 1, parallel. Decisions
  D9–D17 recorded. Decisive proofs: exact-ETag replay → 200 + 200,809 B (reader ignores its own
  validator); Chrome 151 — fresh-nonce CSP on a 304 permanently kills the cached reader, CSP-less
  304 leaves stored CSP enforced; prod census 115/722 nil-rrid ongoing (BlockOps writes no
  revision); weak/list/`*` INM forms all 200 against prod media; 184/184 media assets public
  (no-store branch needs a seeded subject); fonts content-stability refuted on cloud's own
  Inter-var.woff2 (2 blobs, one name). Verifier ledger rows committed alongside this charter
  revision.
- 2026-08-08 (review) · `/papers/http-edge-truth-wave-2026-08-08` · W1 outcome: all four slices
  built, reviewed, ZERO reviewer fixes needed, pushed as PRs #10834 (s1 reader conditional),
  #10835 (s2 media visibility, HUMAN-GATED D13), #10836 (s3a statics no-cache), #10837 (s6 pin
  suite). Reviewer re-ran every gate green in a fresh worktree (42+31+9+7 tests) PLUS an
  octopus-merge integration smoke of all four: clean merge, 89 tests, 0 failures. Census
  independently re-derived (exactly 11 cache-control sites in api/lib). HIGH-FLIP-RISK
  re-derivations done: D12 mapping is sound (policy and access gate share `Access.visibility/1`
  — the policy can never out-permit the gate); D10 CSP-on-304 remains Chrome-151-only observed —
  independent second reviewer owed on #10834/#10835 before merge (lead dispatches, cch D182
  shape). Grade A-. Merge order: s6 or s3a first (smallest), then s1, then s2 (reviewer-gated);
  lead closes the merge-gated criteria (s1 c7, s2 c5-c7, s3a c4, s6 c3) with post-merge L1
  transcripts per D13. Next wave: W2 slices 4 (Vary + query-ETag omission, closes bpb-step7 per
  D17) and 5 (rendition content-addressing) once all W1 PRs merge; E2 notice
  `het-w1-bl-e2-endpoint-notice` still open for the lead to relay.
- 2026-08-24 · W2 slice 4 built by lane `http-edge-truth` on `http-edge-truth-w2`. Decisions D18
  (shaping set widened to fields/expand/resolve + any bound principal) and D19 (capabilities
  exonerated on the ETag axis, Vary-only) recorded. Decisive proof: the cross-representation 304 on
  prod named in D18, reproduced as a test. Files: `query_controller.ex` (respond/6 + three new
  private helpers), `capabilities_controller.ex` (Vary, merged not overwritten), new pin suite
  `api/test/barkpark_web/integration/http_conditional_policy_test.exs`, `docs/api-v1.md` §3.
  OPEN, for the lead: the api-v1.md co-change puts that file 103 B over its 14,000 B budget — the
  doc had SIX bytes of headroom and carries no defensible fat, so the cap needs a ration decision
  (trim a neighbouring section, or split the doc) that is above this slice's pay grade. `Doc budgets
  + anchors` is not in the required set, so it does not block the merge.
