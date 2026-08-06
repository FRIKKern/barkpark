<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-19 | budget: 2200tok -->
# Restart Verify 19 — TUI identity and history replay

Assignment `restart-verify-19` tested visible Paper identity, `H` history access, and newest/oldest revision replay for the four frozen Papers. Verdict: **refuted; identity 0/4, history open 0/4, replay 0/8**.

Live history is healthy and bounded. With the TUI's fixed limit 50, CCH28 returns 12 revisions, CCH29 14, PDS44 12, and PDS45 10. Exact newest and oldest revision payloads and eight canonical content hashes were preserved. Document `_rev` and history UUID remain explicitly separate identity domains.

The TUI never displays the Paper slug plus current document `_rev`. Its `Doc` model has no typed revision field and Paper rendering emits only the PortableDoc body. Exact-payload 80×24 frames therefore pass visible identity in 0/4 cells.

`H` is swallowed for a focused Paper. The Paper-specific read-only reducer branch handles known Paper keys and turns unknown keys into no-ops before the later generic `H` handler. Four PTYs open the correct frozen Paper, show `read-only`, and emit zero history requests after `H`; history open passes 0/4.

Even the ordinary-document history seam opens a diff, not historical replay. Revision projection converts only scalar strings, discarding blocks, body, and other structured content. Exact newest/oldest Paper replay is therefore impossible through this path and passes 0/8. No restore or write route was invoked.

| Contract arm | Observed |
|---|---:|
| Visible slug/current `_rev` | 0/4 |
| `H` opens Paper history | 0/4 |
| Newest/oldest exact replay | 0/8 |
| Live history counts within limit 50 | 4/4 |
| Restore/write requests | 0 |

The audit records 239 GETs, zero HEADs, zero writes, zero PTY history requests, and zero PTY revision requests. Direct live capture used only `doc get`, `doc history`, and `doc revision`. Targeted history/client tests pass but cover list/diff behavior, not Paper history or exact replay.

Installed binary SHA-256 is `7d501025836a0b3795a80b477069c3cc1634928dd4eaf9af56da8d3994909690` at commit `f59aaf717`; worktree binary SHA-256 is `4d2b3536a6a879ed541ec7108a45f08eabf2e743e1e3a8aa0d33d139138ad1f1`. Evidence root is `/private/tmp/bp-v19.Q0wP55`; verdict SHA-256 is `21b0248a4c0701727707efc9fbdeaa15a1b93cee61d6228aac36e6b3c2e464dd` and `artifact-sha256.txt` inventories the full set.

Normal live discovery cannot open the Papers because Verify15 independently refutes that rail. PTY interaction therefore used the real worktree binary against byte-exact live current/history/revision captures through a GET-only proxy while keeping schema/structure live. That boundary cannot manufacture the failure: history/revision payloads were available, but the reducer emitted no request. Repository, Barkpark, production, and credential mutations were zero.

## Cycle payload

```json
{"assignment_id":"restart-verify-19","assignment_uuid":"7246e8cb-c0ec-405c-80c1-afc49e994c20","verdict":"refuted","identity_visible":"0/4","history_open_on_paper":"0/4","replay_exact":"0/8","history_limit_requested":50,"history_counts":{"cch28":12,"cch29":14,"pds44":12,"pds45":10},"proxy_audit":{"get":239,"head":0,"writes":0,"history_requests":0,"revision_requests":0},"repository_mutations":0,"barkpark_mutations":0,"production_mutations":0,"verdict_sha256":"21b0248a4c0701727707efc9fbdeaa15a1b93cee61d6228aac36e6b3c2e464dd"}
```
