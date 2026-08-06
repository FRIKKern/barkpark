<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-11 | budget: 2000tok -->
# Restart Verify 11 — connected Studio source and identity

Assignment `restart-verify-11` tested authenticated connected Studio parity and visible immutable identity across all four frozen Papers. Verdict: **refuted as a conjunction; source/connection partial pass**.

Authenticated Studio reached a genuinely connected LiveView in 4/4 cells. Every page had one `.phx-connected` root and one `data-phx-session`; websocket observations were open2/sent4/received3 for CCH28 and open1/sent3/received3 for each other Paper. Source → server seed → live `bp-paper-canvas.blocks` matched exactly in 4/4 cells, preserving 815/815 ordered blocks. Each cell exposed one editor/ProseMirror surface and the exact slug; no post-login content write occurred.

| Paper | Blocks | Source/seed/live semantic SHA-256 |
|---|---:|---|
| CCH28 | 237 | `a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09` |
| CCH29 | 252 | `46ed01f7416f064f950cee3b00f1a59da00cd0cef523b2a6e4cf1e7cee4b1a50` |
| PDS44 | 99 | `a89dd730f1697b0ce25b86ace3f88d790ef6b13e24e5519d58b3ded2c09445cd` |
| PDS45 | 227 | `f01937cbc0c28fc4f381136ba1ec8174591b1d60abc7b99454aaefd8a7f829da` |

The required identity conjunction fails. Visible perspective is 0/4 and visible immutable document `_rev` is 0/4; no `data-rev`, revision, or perspective carrier exists, only a generic `paper` badge. The exact source/API `_rev` must not be conflated with released-history UUIDs, content digests, or Studio's streaming revision.

Draft-first CLI reads returned each expected `_rev` and count but `_draft:false` in 4/4 cells. This proves published fallback, not preference behavior with a divergent draft.

The run used headless Chrome and one authenticated session. It did not exercise a divergent draft, save, reconnect, other role, or websocket payload bodies; no screenshot was retained. The temporary worktree disappeared during the run and was restored cleanly at `706e82340`; decisive evidence survived.

Security incident: two credential values were unintentionally printed in internal diagnostic output. They are not reproduced in this ledger or Cycle payload. The guerrilla admin API token and cloud token require rotation through the credential-owning operational path; no credential was altered during this read-only assignment.

## Cycle payload

```json
{"assignment_id":"restart-verify-11","cycle_assignment_uuid":"bdc4b59c-327f-4ca9-ac4d-7ad1ad593a25","verdict":"refuted_identity_partial_pass","authenticated_connected":"4/4","source_seed_live_exact":"4/4","blocks_exact":"815/815","one_editor":"4/4","visible_slug":"4/4","visible_perspective":"0/4","visible_immutable_document_rev":"0/4","draft_first":"4/4 published fallback","security_incident":"two credential values exposed in internal diagnostics; values omitted; rotation required","mutations":0}
```
