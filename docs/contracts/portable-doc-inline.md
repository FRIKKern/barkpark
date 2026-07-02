<!-- doc-tier: agent | canonical-for: portable-doc-inline-wire | budget: 1700tok -->
# PortableDoc inline live-ref wire contract — valueref + task chip

The repo-side contract for the two net-new inline nodes (lvw-t1 valueref, lvw-t7 task chip). Canonical for node shapes and the resolver/degradation rules; the design paper `portabledoc-inline-liveref-taskchip-wire` (Barkpark) defers to this doc once landed.

## valueref — the node (wire §3)

```json
{"type": "valueref", "target": "<doc_id slug>", "field": "launch_delay",
 "as": "duration", "label": "launch delay", "fallback": "12 weeks",
 "children": [{"type": "text", "value": "12 weeks"}]}
```

- `target` — doc_id SLUG (D3), resolved with published-row preference, TENANT-SCOPED to the host paper's workspace/project/dataset. Out-of-scope / no match → fallback.
- `field` — REQUIRED single top-level declared field name. No dot-paths, no `content.` prefix — violations are dropped at collection time on every surface (renderer guards too).
- `as`, `label` — RESERVED. Round-trip opaquely; NEVER interpreted. The injected resolver is the single server-side formatting authority.
- `fallback` — the pinned literal: shown when unresolved AND the drift baseline (lvw-t2).
- `children` — D6 dual-write: authoring always writes the fallback as a `{type:"text"}` child so OLD renderers degrade to visible text; NEW renderers IGNORE children.
- Mark form: the paper editor round-trips the node through a text leaf with a `valueref` mark (attrs carry every wire field; the visible text is display-only and discarded on read-back).

## Resolution (wire §5 as amended)

NO per-node resolver in Elixir. `Papers.resolve_values_in_blocks/3` (grep `@canonical capability:valueref-resolve`) deep-walks via the shared `BodyWalk`, collects distinct `(target, field)` pairs, resolves targets in ONE batched typeless query (`Content.Query.resolve_docs_by_ids/3`), and threads `%{{target, field} => string}` as render opt `:values` → palette. Security (non-negotiable): render-then-read — `Envelope.render(doc, schema, caller_ctx)` then read the field off the REDACTED envelope; never `field_readable?` alone (caller-less returns true by design). `:caller_context` defaults to the anonymous `%CallerContext{}`; anything feeding body_html or delta frames stays anonymous. `published_only: true` on public surfaces (do NOT copy `Labels.reference_title`'s drafts-twin fallback — it leaks unpublished values). `_bpenc` FieldCipher envelopes stay redacted (maps never stringify).

Scalar rule (all three surfaces): non-empty string / number / boolean resolve; `""` counts as UNRESOLVED; maps/lists/nil → fallback.

- **Go**: `RenderCtx.ValueResolver func(target, field string) string` — nil-checked, `"" = unresolved → fallback`, output through `sanitizeText`. Wired in `internal/cli/paper_cmd.go` (`paperValueResolver`: memoised, one `filter[_id][in]` probe per schema type, early-exit) and `cmd/barkpark/paper.go` (datastore cache-only, non-blocking).
- **React (web)**: server-pre-resolve — `resolveValuerefsInBlocks` (web/lib/papers.ts) stamps `resolved` onto nodes in the server component; the component renders `resolved ?? fallback` as a TEXT node only (never `dangerouslySetInnerHTML`).
- **Elixir public reader (D2)**: `BulldocsLive` mount/refetch injects the value+wikilink palettes as the anonymous principal, published-only — fresh per page load. Studio threads `:values` in `paper_stream_items/3` for its own live view only, never into shared caches.

## Degradation (wire §6 — non-negotiable)

Nothing EVER raises or blanks. Unresolved/malformed → fallback. Explicit clauses: Elixir `compose_inline` valueref clause + `PdValueref` walk clause (the historical unknown-inline `raise` is GONE — unknown types degrade to children-or-empty); Go typed `valueref` case; React explicit case (+ unknown-inline degrades to children instead of vanishing). Sanitization: Elixir through `escape_html` (never `_raw`); Go through `sanitizeText` (strips C0/ESC); React text nodes.

## Drift + accept-baseline (lvw-t2, wire §8, D4)

Drift = the ONE comparison, pinned `fallback` vs resolved value, made where the pre-resolve pass injects (Elixir walk / React `valuerefState`); NO standalone checker. `data-valueref-state="resolved|drift|dangling"`: `drift` = pin stale (shows the resolved value); `dangling` = unresolvable — drift UNCOMPUTABLE, shows the pin. Two states, two treatments; public drift is against the PUBLISHED value (D5). Markers are data attributes only — Studio styles them (root.html.heex) and, on `drift` + palette `valueref_accept: true` (Studio's per-request view ONLY), emits the accept control → `Content.accept_valueref_baseline/6`: `if_rev`-guarded (CAS; `:precondition_failed` = retry-able) patch-block batch re-pinning `fallback` + the D6 child on the matching nodes; provenance = revision `valueref-accept-baseline` + actor. Authz = write access to the HOSTING paper; edit-through is lvw-t10, NOT this.

## Authoring (v1)

Bulldocs ingest block-ops API only (`POST /v1/plugins/bulldocs/papers/<slug>/ops`, `append-block`). The editor round-trips existing nodes (convert.js, both directions, per-block + canvas) but has no insert affordance yet. patch-block shallow-merges per block — patching `content` replaces the whole array.

## Tests / fixtures

Shared golden home: `fixtures/portable-doc-inline/` cases mirrored VERBATIM in `api/test/support/fixtures/portable-doc-inline/`, `internal/pdrender/testdata/portable-doc-inline/`, `web/__tests__/fixtures/portable-doc-inline/` — one JSON per case (resolved [= drifted: pin ≠ value] / baseline-match / unresolved-with-fallback / missing-resolver). Safety tests use a CHILDLESS node and assert VISIBLE fallback text; injection cases prove `<script>` + raw ESC render inert per surface. Drift tests must show a NON-drifted node stays `resolved` (`valueref_drift_test.exs`, `valueref.test.ts`).

## Code anchors

- `api/lib/barkpark/portable_doc/render/inline.ex` — valueref compose clause (node + mark) + unknown-inline degrade
- `api/lib/barkpark/portable_doc/render/walk.ex` — `PdValueref` renderer + task chip
- `api/lib/barkpark/content/papers.ex` — `resolve_values_in_blocks/3` (valueref-resolve), `accept_valueref_baseline/6` (drift-accept), `resolve_wikilink/3` (task-chip-resolve)
- `api/lib/barkpark_web/live/studio/studio_live/handlers/paper.ex` — `valueref_accept_baseline/2` (the Studio accept event)
- `internal/pdrender/inline.go` — Go valueref case + `valuerefText`
- `web/components/portable-doc.tsx` — React valueref case + unknown-inline degrade
- `api/assets/paper-editor/src/convert.js` — editor node↔mark mapping (both directions)
