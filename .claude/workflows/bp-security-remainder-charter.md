# API Read-Path Security Sweep — Epic Charter

Epic task: `api-read-path-security-sweep` · Wave 1 Paper: `api-read-path-security-sweep-wave-2026-08-17`

## Vision

Seal and certify the SECURITY doors on Barkpark's API read paths so each one fails closed with its OWN mutation-proven verdict, per the field-visibility doctrine (every `Envelope.render` bypass sealed individually — a fix credited to a surface it was not re-probed on is a false seal). The honest finding that shapes this epic: four of the five named doors are ALREADY bolted on origin/main (#6270 pinned public-read at the AnonPerspective chokepoint, #7870 mounted `PublicRead` on `:require_token`, #9613 gave the graph corpus a visibility gate, the drafts-id clamp lives at `query_controller.ex:371`, and `astro.config.mjs` hard-fails the build on a privileged token). So this epic's value is **certification with mutation-proven verdicts, one genuine build, and honest rulings — not re-paving merged clamps**. The deliverable is a ledger where every rendering read path (flat doc, scoped doc, preview/doc, graph traverse, export, analytics, listen, history) is its own door with its own fail-closed proof: revert the clamp → the guarding test reds; restore it → green. A green a blind harness would also produce is not a seal.

## Decisions

- **SEAL-AND-CERTIFY, not build-from-zero** — verification confirmed most doors are already merged; a wave that ships "new" clamps and declares the doors closed manufactures the exact false-seal lie this epic exists to stop.
- **stw10 closes with THREE new committed regression tests, not as-is** — the clamp is real and mutation-proven, but three of its four fail-closed doors (scoped doc + public-read, scoped doc + docs:read share, scoped preview/doc) have ZERO test coverage today, so today's green is a green a blind harness would produce.
- **The scoped surface is the untested one, NOT preview** — preview is fail-closed by `PreviewToken` (not a bypass); the `:edit`-share draft-by-id un-pin is deliberate and must be asserted-open, not silently sealed.
- **d223 criterion 1 is REQUALIFIED before any claim** — the original "public-read on `?perspective=drafts`" repro is unreproducible (public-read is 403'd at the route, live-proven); the real leak is the DEFAULT-perspective draft-only-title exposure via `resolve_graph_root`, reachable by a plain read token. Requalified before claim so the close work-digest fence never blocks it.
- **The graph door's load-bearing proof is the `resolve_graph_root` existence/perspective gate, NOT the AnonPerspective reroute** — the reroute is zero-live-delta defense-in-depth (public-read already 403'd, plain read stays unpinned) and its mutation proof is near-vacuous; the honest seal is that a default-perspective draft-only id returns 404/empty. Fix BOTH callers (`graph_show` + `graph_tasks`).
- **758 is TWO doors + a backlogged ruling** — certify the astro guard by mutation, PORT the guard to the unguarded Next twin (`next.config.mjs` bakes `BARKPARK_TOKEN` unverified), and add CI that bites both configs (today deleting either guard goes green). The `auth_tier "read"` hole (a plain read token also passes the guard and ships to browsers) is a separate ruling needing an API-side capabilities field — backlogged.
- **Do NOT claim "an admin token ships to every visitor" as a live fact** — the tokens baked into the currently-deployed search sites are public-read (403 on flat search/export); the fix hardens an unguarded door, it does not close an actively-exploited one.
- **ssw8 certifies with the corrected teardown** — self-revoke is now 403'd by the clamp being certified; revoke via admin-bearer `DELETE /v1/auth/app-tokens`, and dead-check on a BEARER-GATED route (`/v1/data/query` is anonymously readable and reports false-alive). Close the scoped-listen coverage hole (listen has a flat arm only). Mutation proof (remove `PublicRead` from `:require_token` → suite reds) is owed by the builder — the verifier could not run it.
- **The cycle-fleet list-equality residue is FOLDED IN as a slice** — `cycle_fleet_controller.ex:399` is the ONLY surviving literal `permissions == ["public-read"]` match in enforcement code repo-wide; a `["public-read","read"]` token escapes it on the flat `/v1/cycles` route (live-verified). One-line membership fix + a mutation test. Bounded (same-workspace, admin must mint), not cross-tenant.
- **pdf-bl-anon is a RULING, not a build this wave** — anonymous `/v1/data/query` is per-schema opt-in (`schema.visibility`), already fail-closed by default; `task`/`paper` carry `visibility:public` as a DATA state. Flipping it breaks the project's own prod smoke test, `seal.mjs`, `scaffy`, and (silently) `reland-check.yml`. The sweep MAPS the exact public surface and escalates; it does NOT break the smoke test to look secure. The headline is HALF-WRONG: the primary serves 0 tasks / 15 stale papers — guerrilla (6181 tasks) + muscle-1 (3139) are the real exposure, so a muscle-1-only fix closes nothing.
- **The anon register write and `/api/schemas` disclosure are recorded, not fixed this wave** — `POST /v1/auth/register` is an unauthenticated account-creation write + email vector (bounded: no tenancy); `/api/schemas` dumps private-type field definitions to anon (deliberately un-gated for the deploy health gate). Both are ruling inputs, backlogged.
- **The five previously-scattered tasks are consolidated under this epic** — they lived as backlog in three unrelated epics (search-template, site-spawner, claude-ready-servers); each carries a `source_epic` field for traceability.

## Roadmap

Wave 1 — 5 build slices (all round 1, file-disjoint, buildable in parallel) + 1 ruling task + 6 backlog:

| Slice | Task | Surface | Size | Model |
|---|---|---|---|---|
| Drafts-id regression tests | `stw10-backlog-drafts-id-seam` | `api/test/.../drafts_id_doc_clamp_test.exs` (new) | small-med | opus |
| Graph perspective chokepoint + existence gate | `task-d223068f55efbf47` | `tasks_controller.ex` resolve_graph_root/graph_traverse_opts + new test | medium | fable |
| Astro certify + Next twin guard + CI | `task-758ef042eb60c65e` | `templates/search-starter/next.config.mjs` + astro CI + guard test | medium | opus |
| ssw8 certify: scoped-listen arm + mutation + live probe | `ssw8-bl-public-read-reaches-export-analytics-listen` | `public_read_enforcement_test.exs` | medium | opus |
| Cycle-fleet list-equality seal | `cycle-fleet-list-equality-seal` | `cycle_fleet_controller.ex` + its test | small | opus |

Ruling task (owner/lead, not a build slice): `pdf-bl-anon-read-exposure` — anonymous read-tier + register + `/api/schemas` disclosure.

Backlog (filed, published, children of the epic): `astro-guard-read-vs-publicread-tier`, `api-schemas-anon-field-disclosure`, `reland-check-silent-falsegreen`, `anon-register-unauth-write`, `legacy-documents-drafts-id-latent-clamp`, `foreign-scope-share-token-flat-read`. Referenced open prior-art (not duplicated): `dr-bl-graph-show-draft-leak` (d223 discharges its defect 1), `dr-bl-graph-phantom-id-exposure`, `dr-w2-s7-followup-scoped-media-public-read-audit`, `dr-bl-scoped-search-private-leak` (stale-open, code fixed on main), `stw11-ledger-honesty`.

HIGH-FLIP-RISK slices (a genuinely independent second reviewer is owed before merge): **d223** (the leak-mechanism + zero-delta judgment) and **cycle-fleet** (the mixed-token reachability judgment).

## Wave log

_(empty — wave 1 in flight)_
