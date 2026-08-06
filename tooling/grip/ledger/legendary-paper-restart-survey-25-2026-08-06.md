<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-25 | budget: 1400tok -->
# Restart Survey 25 — CCH29 Studio provenance and current pin

Assignment `restart-survey-25` re-attested `cloud-console-hardening-wave-29-2026-08-03::studio` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **connected canvas content provenance proven; immutable document revision carrier absent**.

## Direct answer

The published Paper remains at `_rev=18768b0a14c2eead927181c4a0e37c18` with 252 unique blocks and canonical block SHA-256 `e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21`. Published and drafts-perspective documents were byte-identical; direct `drafts.<slug>` lookup returned 404. Studio’s draft-first selection therefore currently falls back to the pinned published row.

Anonymous canonical Studio redirected to login. An existing saved admin token was submitted through the documented form; login redirected back to the exact scoped deep link. Authenticated HTML returned 200 and 861,931 bytes.

Server HTML contained one editor, shell, LiveView session carrier, slug sentinel/input, and one canvas-block payload. Its 252 unique blocks exactly matched source. A fresh read-only Playwright session connected: one phx-connected root, three websocket frames each direction, one shell and canvas, 252 unique blocks, and the same canonical SHA-256. Slug input and sentinel matched the Paper. No clicks, typing, saves, autosave, or mutations occurred.

## Material limitation

The immutable `_rev` occurs zero times in both authenticated server HTML and connected DOM. No active-canvas `data-rev` exists. Studio internal `paper_rev` derives from `content["rev"] || 0`, a separate identity domain from top-level document `_rev`.

Thus connected content parity, current draft selection, LiveView connection, and visible slug are proven. Studio cannot independently prove the immutable revision. Save/autosave/conflicts, edits, alternate accounts, datasets, browsers, and persistence were unvisited. Credential-bearing temporary artifacts were moved to Trash; no repository or Barkpark data changed.

## Cycle payload

```json
{"assignment_id":"restart-survey-25","unit":"cloud-console-hardening-wave-29-2026-08-03::studio","verdict":"connected canvas content provenance proven; immutable document revision absent","paper":{"rev":"18768b0a14c2eead927181c4a0e37c18","blocks":252,"blocks_sha256":"e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21","draft_twin":false},"auth":{"anonymous":"302_login","login_post":"302_canonical_route","authenticated":200,"server_bytes":861931},"connected":{"phx_connected":true,"websocket_frames":"3_sent_3_received","canvas_blocks":"252/252","canvas_sha256":"e1cb807591caa511dadb1cc98311812aa364abc624f8da60c24562185b828b21","slug_visible":true,"document_rev_visible":false},"mutations":false}
```
