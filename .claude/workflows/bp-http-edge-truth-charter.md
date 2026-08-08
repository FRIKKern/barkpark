# HTTP Edge Truth — Epic Charter

Epic task: `task-02ce7e5183108eb3` · Program task: `task-21cd02088dd2f762` ·
Founding papers: `/papers/hobby-hardening-capstone` (crown) · `/papers/hobby-hardening-http-edge` (lane) ·
`/papers/barkpark-hobby-scale-swot` (frame)

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

- **D2 — Cache-policy slices are HUMAN-GATED with a named reviewer, and each carries a post-merge
  L1 proof: the curl transcript rerun against prod, pasted into the task before close.** *Why:*
  deploy-reliability D17 precedent; merged means live, cached means gone.

- **D3 — The reader 304 fix validates on `released_revision_id`, never a per-request sha256.**
  *Why:* `paper_revision_headers.ex:13-42` today costs a redundant `Repo.one` plus an uncached
  sha256 per request to mint an ETag nothing reads. The revision id is already the change signal
  the reader's own PubSub invalidation uses. The fix extends to the flat `/papers/:slug` route,
  which today has no ETag at all, and halts before the LiveView dead render.

- **D4 — The media local-file branch becomes visibility-aware: public → short max-age +
  revalidate; private → no-store; token-visibility policy is decided in-wave (options: `private,
  max-age ≤ signature TTL` vs `no-store`) and recorded as a D# when decided.** *Why:*
  `urls.ex:11`/`:58` stamps the unconditional `@immutable_cache` AFTER `Access.allowed?` passes
  (media_controller.ex:99/:142). The 302-to-blob branch already sends `private, max-age=0`
  (media_controller.ex:196-201) and is untouched. The one pinned test
  (media_delivery_test.exs:100,136) co-changes in the same PR.

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
  pipeline.

- **D8 — Every fix ships with mutation-proof header pins. The header test suite is a deliverable,
  not a nicety.** *Why:* two load-bearing header pins exist in the whole codebase (media immutable;
  cloud's two-plug doctrine). 9 of 11 override sites, all Vary behavior, and the statics policy are
  free-floating — regressions are currently invisible. House laws bind: distrust vacuous green,
  make the check able to fail, mutate don't read.

## Fence

**In fence:** `api/lib/barkpark_web/plugs/paper_revision_headers.ex` · `api/lib/barkpark/media/**`
(delivery, renditions, blobstore call sites) · `api/lib/barkpark_web/controllers/media_controller.ex`
· `api/lib/barkpark_web/endpoint.ex` (Plug.Static opts region only) ·
`api/lib/barkpark_web/controllers/query_controller.ex` + `capabilities_controller.ex` (ETag/Vary
regions) · `docs/api-v1.md` (co-change) · header test files.

**Out, by design:** `api/lib/barkpark_web/router.ex` public-read region (:461-471 — site-spawner
ssw10 precedent, human-gated) and `public_read.ex` — routed around entirely; everything
cloud-console-hardening fences (both reader LiveViews included: E1's fixes land at plug level, so
it never needs them). Every fence widening is a numbered, subject-scoped, not-to-be-widened-again
decision in this file.

**Interface law (program-wide):** no new alert or email producers (deploy-reliability D14/D321 is
fleet law); any operator-notification consequence routes into deploy-reliability's rails; every
operator-facing signal names its audience explicitly.

## Roadmap

Ordered by risk (D1): validators first, header caps second, URL contracts third.

| # | Slice | Surface | Size | Wave | Status |
|---|---|---|---|---|---|
| 1 | Reader 304: honor If-None-Match on `released_revision_id`, cover the flat route (the program's safest code change — a CLEAN 45-line plug) | `api/**` | small | W1 | filed |
| 2 | Media cache policy: visibility-aware local-file branch; pinned test co-changes; HUMAN-GATED | `api/**` | medium | W1 | filed |
| 3 | Statics doctrine port: two-plug split on api endpoint, exact-string pins | `api/**` | small | W1 | filed |
| 4 | Vary: Authorization + query-ETag omission fix; api-v1.md co-change; coordinate ctx-b2 | `api/**` + docs | medium | W2 | filed |
| 5 | Immutable made true: rendition URL content-addressing (watermark profile in the key); put_blob overwrite semantics decided | `api/**` | large | W2 | filed |
| 6 | Header pin suite: mutation-proof coverage of all 11 override sites + Vary | `api/test/**` | medium | W1–W2 | filed |

**Absorbs:** `bpb-step7-content-edge-cache` (bp-cloud-build epic) — closed into this epic by name.
**Cites as sibling:** `ctx-b2-server-view-brief` (owns the RFC 9110 capabilities fix — one shared
controller edit is coordinated, not duplicated).

**Not this epic:** the public_read clamp (site-spawner ssw10/ssw11); deploy-ledger notification
surfaces (deploy-reliability w18); the scoped-media tier-bypass audit (dr-w2-s7 follow-up —
different defect class); CJK / search engine (filed candidate, per the program interview);
anonymous metering and limiters (E2, `task-8e9cac2018a7fe1c`); packaging (E3,
`task-3ae717d5f9324399`).

## Sequencing with the sibling epics

E1 lands its `paper_revision_headers.ex` change before E2 touches the same plug for telemetry —
the one file both epics edit, resolved by this ordering rule. E3's "supported" blessing is
DAG-gated on E1's media fix (slice 2) merging.

## Wave log

<!-- one row per wave: date · wave paper · slices merged · the proof transcript that moved -->
