<!-- doc-tier: cold | canonical-for: none | budget: 900tok -->
# Re-derivation: are the 2 bpb search-tenant findings owned by an OPEN api-read-path-security-sweep child? — 2026-08-18

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Verdict: NO. Both are genuinely-unclaimed cloud-build residue (parent_id=bp-cloud-build-epic, both open), offline-buildable, security-adjacent → spin to a fresh follow-up build wave. NOT-SEAL stands.

## The two findings (parent=bp-cloud-build-epic, both open, 0/3 criteria met)
- `bpb-search-intel-record-insights-pipeline-align` — flat search synonyms/insights ADMIN routes run `[:api,:require_admin]` (NO DeriveWorkspaceFromToken) so every flat caller collapses to the seeded Default workspace. router.ex:1974-1981 (documents), 2176-2181 (media). Reviewer-corrected premise: record AND insights are consistent (both Default), the real gap is no per-tenant derivation on the flat admin routes.
- `bpb-search-scope-param-tenancy-check` — search WRITE actions trust URL `:dataset` as `scope` with no token-tenancy check. `create_search_synonym`/`promote`/`delete` use `workspace_id(conn)` (AssignDefaultScope-masked); the fail-closed `token_workspace_id` guard exists ONLY in `update_search_settings` (search_controller.ex:298), absent from the synonym write actions.

## sweep epic (api-read-path-security-sweep) — 10 OPEN children, NONE touch these paths
pdf-bl-anon-read-exposure (anon read ruling) · astro-guard-read-vs-publicread-tier (public-read attestation on /v1/capabilities + build-time token-guard.test.mjs "search-TEMPLATE" client guards — NOT server synonyms/insights) · api-schemas-anon-field-disclosure (/api anon field filter) · arpss-pr-task-gate-token-plumbing (human gate) · arpss-docs-anchors-canonical-none-collision · arpss-author-email-seed-note · arpss-bpml-manifest-declaration · arpss-reland-teach-closer-landed · arpss-envelope-schema-nil-residue-pin · arpss-gyldendal-author-email-notify.
Closest (astro-guard) governs the PUBLIC-READ tier attestation and client build guards, not the synonyms/insights admin write routes or the dataset/scope write-tenancy. Zero overlap.

## rerun
```
bp task get api-read-path-security-sweep -o json | python3 -c "import sys,json;d=json.load(sys.stdin);print([(c['doc_id'],c['lifecycle_status']) for c in d['children'] if c['lifecycle_status'] in ('open','considering')])"
git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1967,1981p'
git show origin/main:api/lib/barkpark_web/controllers/search_controller.ex | sed -n '252,300p'
```
