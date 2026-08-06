<!-- doc-tier: cold | canonical-for: legendary-paper-survey-58-evidence | budget: 1200tok -->
# Survey 58 — PDS wave 44 / CLI-API structure

Verdict: `found`, with projection and identity caveats. The pinned Paper's 99 blocks retain exact order, type, ID, and content across CLI get/query, canonical get/query APIs, public source, and the newest published history revision.

- Authority: `pds-wave-44-2026-08-03@8bbd5d874a1b697f1e4e437c473f8e52`; newest published history revision `344fe5ee-c8a0-4bb9-8b5e-17a3562992d5`.
- All six surfaces contain 99 blocks and normalize to exact object equality. Canonical block SHA is `a89dd730f1697b0ce25b86ace3f88d790ef6b13e24e5519d58b3ded2c09445cd`; ordered-ID SHA is `a8adf7045065c6444a270ca01dd376ffb56df463eeff02f631b3ae5facd2904f`; ordered-type SHA is `3d561bfa41e74098d144958af7357bea2a961582aa1d2e8c7b46e4084904b44a`.
- Inventory is 32 headings (1 H1/24 H2/7 H3), 48 paragraphs including 15 empty scaffolds, ten lists/85 items, five tables, and four callouts. All 99 IDs are present and unique.
- `--fields title,blocks` and API `fields=title,blocks` match across get/query and retain the seven system identity fields. Unknown fields are omitted.
- Document and HTTP ETags equal `_rev`; the independently reproduced query ETag is `27fdc5d28e8221b2d52f84f1f3b7401f`. Conditional get and query both return HTTP 304.
- Current content equals the newest history snapshot after projecting onto stored content keys. History UUID and document `_rev` are different identity domains; no explicit server-provided join relates them.
- Structured error behavior is correct for CLI/API missing documents, malformed filters, and bad revisions. Missing history returns an empty HTTP 200; missing public source returns plain-text HTTP 404, leaving three error dialects.
- `v1/capabilities` intermittently timed out or returned HTTP 500, while direct API retries succeeded. This is an operational discovery risk, not parity loss.
- No task title/content referencing this Paper was found.

Fresh targeted Go tests passed with `CGO_ENABLED=0` for response envelopes, query forwarding, and pagination keys. A default-CGO attempt could not compile because the configured compiler rejected `-E`; no test failure is claimed. Elixir contracts were inspected but not executed. Checked query/source/history controllers and routes, CLI response/query code, projection/history/source contract tests, the pinned Paper and revision, and task search. No repository or Barkpark mutation occurred.
