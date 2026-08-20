# Re-derivation recipes — clamp-fix-shape A/B/C bake-off, search-template W10, 2026-07-26

Verifier lane: `clamp-fix-shape-decision`. Three candidate fixes for the public-read drafts
clamp-gap were applied IN PLACE, run against the five oracle test files plus a planted probe
(`api/test/barkpark_web/clampgap_probe_test.exs`, trashed after), and reverted
(`git checkout -- api/lib/...`; `git status --short api/` shows no tracked mods). Every row is
one literal command (or planted-probe recipe) that re-derives the fact.

Oracle suite (35 tests): `cd api && CC=clang mix test test/barkpark_web/anon_perspective_test.exs test/barkpark_web/contract/search_anon_perspective_test.exs test/barkpark_web/contract/anonymous_perspective_test.exs test/barkpark_web/integration/public_read_enforcement_test.exs test/barkpark_web/sibling_controller_leak_test.exs`

| # | Fact | Rerun |
|---|---|---|
| 1 | Exactly 3 `AnonPerspective.resolve` callers: search_controller.ex:106, federated_search_controller.ex:31, bulldocs_source_controller.ex:17 | `grep -rn 'AnonPerspective.resolve' api/lib --include='*.ex'` |
| 2 | WS channel hard-codes `perspective: :published` (only perspective word in the file) | `grep -n perspective api/lib/barkpark_web/channels/search_channel.ex` |
| 3 | PublicRead mounts on `:api_grant_read` (router.ex:83) and `:shared_docs_api` (:187) — NOT `:scoped_api` (:141-153) and NOT bare `:api` (:30) | `grep -n 'PublicRead\|pipeline :' api/lib/barkpark_web/router.ex \| head -30` |
| 4 | `OptionalSessionToken` assigns `:api_token` from `Authorization: Bearer` (Bearer wins over session) — so the paper-source route sees API tokens | `sed -n '44,56p' api/lib/barkpark_web/plugs/optional_session_token.ex` |
| 5 | BASELINE probe: scoped search + scoped federated + flat federated all 200 with draft ids for a public-read member token; flat search 403 "forbidden" (PublicRead route whitelist); scoped paper-source 200 with FULL draft blocks | plant probe: public-read token via `Auth.create_token(raw, n, ds, ["public-read"], ws.id)`, GET `/w/:ws/p/:proj/v1/data/search/:ds?q=..&perspective=drafts`, `.../v1/search/:ds?...`, `/v1/search/:ds?...` flat, `/w/:ws/p/:proj/d/:ds/papers/:slug/source?perspective=drafts` |
| 6 | Candidate A (pin `match?(%{permissions: ["public-read"]}, conn.assigns[:api_token])` in `AnonPerspective.anon_pinned?`) seals ALL FOUR routes (silent 200-published downgrade; paper-source 404); 36 tests 0 failures, ZERO existing tests flip | apply A to anon_perspective.ex:41, rerun oracle suite + probe |
| 7 | Candidate B (403 "perspective not allowed" guard in the two search controllers) seals the three SEARCH routes with 403 but leaves the paper-source draft leak LIVE; zero flips | apply guard to search/2 in both controllers, rerun |
| 8 | Candidate C (A + delete QueryController's `resolve_perspective`/`anon_pinned?` twins at :601/:626, delegate to AnonPerspective) — probe identical to A; 36 tests 0 failures; MUST keep `preview?/1`+`authed?/1` (used by backlinks/related/tag_browse/tag_docs gates — deleting them = CompileError `undefined function preview?/1` at :244/:276); `parse_perspective/1` becomes unused (delete it) | apply C, rerun; break: also delete preview?/authed? and watch the compile fail |
| 9 | NO existing test distinguishes any candidate from the leak — 35 oracle tests green at baseline AND under A, B, C | run oracle suite at baseline and under each candidate |
| 10 | anon_perspective_test.exs:20-26 does NOT flip under the exact-["public-read"] pin — its token is `%{tier: :member}` with NO permissions key; it is the unit-level over-clamp canary, not the mutation proof | `sed -n '20,26p' api/test/barkpark_web/anon_perspective_test.exs` |
| 11 | Over-clamp canaries green under all candidates: admin token keeps drafts on scoped search; sibling_controller_leak B1 (["read","write","admin"] member gets drafts.* hits) green | oracle suite + probe case 6 |
| 12 | Fail-broken tripwire green under all candidates: public-read + NO perspective on scoped search → 200, published rows only | probe case 2 assertion |
| 13 | `:api_local` pipeline is RequireLoopback-only (no token plug) — `:api_token` never assigned on `search_local/2`, so the chokepoint pin cannot key there; pinning it would break tokenless local drafts search | `sed -n '132,137p' api/lib/barkpark_web/router.ex` |
| 14 | Probes fully reverted; no tracked mods under api/ | `git status --short api/` |
