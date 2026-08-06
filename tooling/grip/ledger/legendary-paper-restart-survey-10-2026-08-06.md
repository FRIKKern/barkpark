<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-10 | budget: 1400tok -->
# Restart Survey 10 — Studio provenance and current pin

Assignment `restart-survey-10` re-attested `cloud-console-hardening-wave-28-2026-08-03::studio` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **published pin and real Studio chain proven; current draft-first editor identity unavailable and not proxy-passed**.

## Direct answer

Published source remains pinned at `_rev=49c1534d9fb76d0d9adc7b97f25ec471`, with 237 blocks and canonical block SHA-256 `a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09`. The canonical Studio route is `/w/default/p/default/d/production/studio/paper/cloud-console-hardening-wave-28-2026-08-03`; it mounts Studio behind browser-session authentication, organization MFA, and scoped workspace/project resolution.

An authenticated Studio DOM was unavailable. Bearer access redirected to login, scoped published/draft reads returned 403, and the existing Chrome profile rendered the Studio sign-in page. No login, credential injection, click, typing, edit, or submission occurred.

Studio is draft-first: it selects `drafts.<slug>` when present and published content only as fallback. Draft existence and identity could not be read. Therefore a published pin cannot prove the content currently editable in Studio.

## Proven chain and samples

Static code establishes the route/auth chain, Paper pane dispatch, draft-first query, block projection, editor/preview branches, and default-on canvas. The editable canvas consumes stored blocks directly; read-only View resolves live tasks/references/embeds/values before rendering. Studio’s local `paper_rev` is `content["rev"] || 0`, a different identity domain from document `_rev`.

- Published source: three contemporaneous routes, 3/3 HTTP 200 and byte-identical.
- Source response SHA-256: `34332ee5666902161af9abe4f96c8243374f93f1f143ba567d2d5bc2b51fba8b`.
- Ordered block-ID SHA-256: `af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff`.
- Studio route with bearer: one HTTP 302 to login.
- Scoped published API: one 403. Scoped draft API: one 403 `forbidden`.
- Flat published retry: one HTTP 500, request ID `GMkZY-SRIoa8LIkAAFhS`.
- Existing browser profile: one navigation, two AX snapshots, one screenshot; final URL is login and no Studio Paper shell/editor appears.

## Ruling and risk

Found: exact published source identity; canonical route/auth layers; draft-first semantics; editor source projection; local revision-domain mismatch; default editable-canvas code path; and the fact that an API token is not a Studio browser session.

Not found: authenticated Studio shell, editor, canvas, Paper sentinel, current selected row, absence of a draft twin, draft revision/count/hash, draft-versus-published equality, or deployed canvas configuration. Current editor pin and deployed canvas state remain partial.

If no draft exists, Studio should fall back to the published 237 blocks. If a draft exists, it may be materially different. The deployed default-on canvas is inference without authenticated DOM/config evidence. Even a later screenshot must be tied to document ID, draft flag, document `_rev`, content revision, and ordered block IDs before parity can be claimed. Editor and preview require separate hashes because their projection behavior differs.

Save/autosave, revision fencing, canvas conversion, interactions, authenticated live socket, other Papers/readers, tests, and the 500 root cause were not visited.

## Cycle payload

```json
{"assignment_id":"restart-survey-10","unit":"cloud-console-hardening-wave-28-2026-08-03::studio","published":{"revision":"49c1534d9fb76d0d9adc7b97f25ec471","source_kind":"blocks","blocks":237,"source_response_sha256":"34332ee5666902161af9abe4f96c8243374f93f1f143ba567d2d5bc2b51fba8b","blocks_sha256":"a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09","ordered_ids_sha256":"af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff"},"studio":{"route":"/w/default/p/default/d/production/studio/paper/cloud-console-hardening-wave-28-2026-08-03","selection":"draft-first","revision_domain":"content.rev integer, distinct from document _rev","default_surface":"editable canvas","authenticated_dom":"unavailable","bearer_route_status":302,"browser_observation":"login page","draft_exists":"unknown","draft_revision":"unknown","editor_blocks":"unknown","editor_hash":"unknown"},"api_samples":{"scoped_published":403,"scoped_draft":403,"flat_published":500,"flat_500_request_id":"GMkZY-SRIoa8LIkAAFhS"},"verdict":"partial: published pin and real Studio chain proven; current draft-first editor identity unavailable and not proxy-passed"}
```
