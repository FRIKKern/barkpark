<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-33 | budget: 1400tok -->
# Restart Survey 33 — PDS44 CLI/API negative capability and evidence strength

Assignment `restart-survey-33` re-attested `pds-wave-44-2026-08-03::cli_api` at exact current revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **partial: exact current revision proven; immutable release attestation not proven**.

Erratum: commit `62d458133` and immutable result `restart-survey-33-result-v1` omitted `c3` from the full-document SHA. Fresh 3/3 capture in Survey 34 proves the corrected 64-character value used below; immutable history remains visible.

## Direct answer

Machine JSON passed `3/3`: 328,256 bytes, 99 blocks, SHA-256 `4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d`; all perspectives matched. Public source was 76,255 bytes, SHA-256 `9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7`. Canonical block SHA-256 `1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce` matched machine output and latest history content.

Exact immutable release attestation is unavailable. CLI `--revision-id` means immutable Cycle wave revision, not document `_rev`, and requires all six release pins. No real gate/candidate tuple was available; malformed and dummy complete tuples returned rc4.

## Negative findings

- Missing Paper, refused transport, malformed release revision, and wrong candidate all collapse to rc4/`not_found`.
- A hostile slug containing TAB, LF, and `ESC[2J` is echoed raw in stderr, creating a terminal-control injection path.
- Source content negotiation is inverted: JSON/text/XML Accept returns 406 `internal_error`, while HTML/wildcard returns 200 JSON. Missing+JSON masks 404 as 406; missing+HTML is raw 404; POST returns a third structured 404 dialect.
- Public scoped source returned 200 anonymously and with invalid bearer, consistent with public access but not proof of private-scope safety. Private/non-default auth remains unvisited.
- `doc history --limit 1` returns all 12 revisions.
- Widths 1/2 overflow only on literal `Related` at seven cells; widths 7–200 contain output. Width zero silently becomes 80. Human output carries no slug, document revision, or history UUID.
- Three tables carry 12 header cells under unsupported `header`; all disappear. The target contains no marks, links, wikilinks, or valuerefs, so those capabilities are unexercised.
- `--pager`, `--outline`, `--search`, and `--section` return rc2; `PAGER=/usr/bin/false` changes nothing.

Local adversarial fixtures show an explicit `unknown block: 7` fallback, while a nested list inside a table silently becomes an empty cell. Decoder skips invalid/null elements. These are executable local facts, not deployed-target proof. Private auth, live malformed fixtures, real release pins, forced 401/403/429/500/timeout, and hostile content fixtures remain required. Scratch captures were trashed; no state mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-33","unit":"pds-wave-44-2026-08-03::cli_api","verdict":"partial_current_revision_proven_release_attestation_unproven","paper_revision":"8bbd5d874a1b697f1e4e437c473f8e52","machine_samples":"3/3","machine_sha256":"4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d","blocks":99,"blocks_sha256":"1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce","immutable_release":false,"hard_findings":["release_tuple_unavailable","json_accept_406_internal_error","missing_json_masks_404","transport_collapses_rc4","hostile_slug_controls_raw","table_headers_0_of_12","nested_table_list_blanks","no_intrinsic_provenance","history_limit_ignored","width1_2_related_overflow"],"mutations":0}
```
