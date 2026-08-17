<!-- doc-tier: cold | canonical-for: none | budget: 1500tok -->
# foreign-scope share-token flat-read — LIVE CONFIRMED (2026-08-17)

Verifier [foreign-share-live], api-read-path-security-sweep wave 2. Finding
task: `foreign-scope-share-token-flat-read` (#11670). Charter rule satisfied:
"no credit before live confirmation" — this was test-env-only (stw10 C5/C6);
now confirmed on the live guerrilla content host with full cleanup.

## Verdict

LIVE-CONFIRMED (not blocked). A foreign-scoped `:edit` share-edit token
(`bpshare_…`, `share_scope = <ws>/default/production`) flat-reads a DEFAULT-scoped
draft on BOTH flat read routes; anon is 404/401; the same token is 403 on the
flat mutate route. Decide: this is a LANE-2 BUILD, not a packet item.

## Mechanism (origin/main, code-confirmed)

- `AnonPerspective.anon_pinned?/1` (`anon_perspective.ex:53`) is FALSE for a
  share-edit token: `authed?(conn)` = `not is_nil(assigns[:api_token])` is TRUE
  (a share-edit token IS a valid `kind:"api"` token) and its permissions are
  `["share-edit-docs"]`, so `public_read_token?` is false. → the `drafts.`-prefix
  clamp at `query_controller.ex:371` is SKIPPED.
- `ScopeHelpers.scope_opts/1` (`plugs/scope_helpers.ex:69` `from_assigns`) derives
  scope from `assigns[:current_workspace]` (seeded by `AssignDefaultScope` on the
  `:api` pipeline = the Default workspace), NEVER from the token's `share_scope`.
  So the read is Default-scoped regardless of the token's foreign binding.
- `/v1/data/doc/:dataset/:type/:doc_id` flat route: router.ex:1696, pipeline
  `[:api, :api_grant_read]`. `/api/documents/:type/:id`: router.ex:2607, pipeline
  `[:api, :require_token, LegacyDeprecation]` — LegacyController.show has NO
  drafts clamp (the separate `legacy-documents-drafts-id-latent-clamp` finding).

## Re-derivation recipe (run against a THROWAWAY workspace; mandatory cleanup)

Admin token on guerrilla required (`bp whoami` → auth_tier admin). Full script:
`scratchpad/fss_probe.sh` (trapped-cleanup). Steps, all admin HTTP:

1. `POST /api/workspaces {slug,name}` → throwaway ws (+ Default project + production ds).
2. `POST /v1/data/mutate/production` create `_id:"drafts.zzz-…"` `_type:"ability"` → Default-scoped draft.
3. control: anon `GET /v1/data/doc/production/ability/drafts.zzz-…` → 404; anon `GET /api/documents/ability/drafts.zzz-…` → 401.
4. `POST /v1/shares {scope:"<ws>/default/production",surfaces:"docs",access:"edit"}` → live edit-share.
5. `POST /v1/shares/tokens {scope,surfaces:"docs"}` → raw at `.token`, id at `.share_token.id`.
6. ESCAPE: `GET /v1/data/doc/production/ability/drafts.zzz-…` + `GET /api/documents/ability/drafts.zzz-…` with `Bearer <bpshare_…>` → BOTH 200, draft body returned.
7. negative: `POST /v1/data/mutate/production` with the share token → 403 forbidden.
8. cleanup: `DELETE /v1/shares/tokens/:id`; `DELETE /v1/shares?scope=…`; `DELETE /api/documents/ability/drafts.zzz-…`; `DELETE /api/workspaces/:slug` (cascades).
9. verify clean: ws→404, draft→404, `/v1/shares/tokens?scope=`→`[]`, share ABSENT.

## Decisive output (2026-08-17T08:40Z, guerrilla)

```
share-token /v1/data/doc/production/ability/drafts.zzz-fss-probe-…: 200
  body: {"result":{"_draft":true,"_id":"drafts.zzz-fss-probe-…","title":"FSS SECRET DRAFT …
share-token /api/documents/ability/drafts.zzz-fss-probe-…: 200
  body: {"id":"drafts.zzz-…","status":"draft","title":"FSS SECRET DRAFT …"}
anon /v1/data/doc: 404   anon /api/documents: 401
share-token flat mutate: 403  {"error":{"code":"forbidden","message":"token lacks required permission"…
cleanup: revoke 200 / delete-share 200 / delete-draft 200 / delete-ws 200
post-clean: ws 404 / draft 404 / tokens [] / share ABSENT
```

## Fix shape for the builder

Flat READ routes must consult the token's `share_scope` (like the mutate route's
`:share_writer` binding already does) OR refuse a `share-edit-*` token outside
its scope on reads. `shared_edit_test.exs` proves the MUTATE arm only (test 4,
line 151); the READ arm needs its own regression: mint a foreign-scope edit token,
assert the two flat GETs return 404/401 for a Default draft. Mutation-prove by
reverting the scope check → the two GETs go 200 again.
