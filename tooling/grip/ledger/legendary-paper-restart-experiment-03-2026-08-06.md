<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-03 | budget: 1900tok -->
# Restart Experiment 03 — terminal and platform baseline

Assignment `restart-experiment-03`, canonical round `baseline`, froze TUI/CLI/API rendering, identity, discovery, error, Related, and recovery evidence. Verdict: **fail / rework**. Static output is bounded and identity-safe, but authored visibility, error taxonomy, and silent-failure gates fail.

| Measure | Observed |
|---|---:|
| Frozen Papers / blocks | 4 / 815 |
| Tables / headers / body cells | 46 / 113 / 1,374 |
| Marks / callouts / empty spacers | 388 / 30 / 381 |
| CCH29 nested list | 11 items / 406 words |
| Width/profile captures | 32/32 at 20/40/80/120 |
| Display overflow / residual controls | 0 / 0 |
| Authored visibility | 2,018/3,472 comparisons |
| Missing visibility comparisons | 1,454 |
| False `not_found` | 1 |
| Silent failures | 2 |
| Related appendix isolation | 32/32 |

POST to an existing GET-only Paper source returns 404 `not_found` instead of a method error. Related suppresses secondary-read failures, and width zero exits successfully with default behavior. History `--limit 1` returns 14, 10, 12, and 12 rows rather than one. Source negotiation rejects JSON/text with 406 `internal_error` while HTML returns JSON MIME. Current capability, OpenAPI, and source probes expose no Paper ETag.

The static viewer help contains no outline, pager, history, or state-recovery control. Interactive TUI recovery, safe deployed 500 induction, and safe deployed timeout induction remain blocked and were not proxy-passed. This baseline separates raw command/HTTP bytes, normalized envelopes, canonical source/core projections, and mutable Related appendices.

The experimenter ran the pure verifier twice byte-identically; the leader independently repeated it twice. Each run passed 682 artifact checks while correctly retaining typed verdict FAIL. Artifact-set SHA-256 is `35b7a9d356bc2a884ba33e2f3d894b16689855fa9a09b37566aa1db721e6406f`; verifier-output SHA-256 is `6560b649b8906bfeb0a27e8aba6ce559a9808f1d4867d968de189eec769e4003`; Cycle JSON SHA-256 is `b08000d7f84cafa3f0f078e346b50ef8c448d797ff30d3e9612f7c2b338d0b4c`.

Durable artifacts are under `.omx/state/legendary-paper-reader-upgrade-restart-experiments/E03`. Raw/semantic/appendix/envelope evidence is in `evidence.tar.gz`, SHA-256 `04b73f0b0149e2a716bcfc849d30aee5021398ea8eddddb6e6e54e971f453363`, and extract with `tar -xzf evidence.tar.gz`. Seventy-one probes consumed 32.423328 seconds summed and 34.075901 seconds wall; replay took 0.045058 and 0.041755 seconds. Credential scan covered 215 files with zero hits. External writes attempted were zero, and all four source hashes matched before/after.

## Cycle payload

```json
{"assignment_id":"restart-experiment-03","assignment_uuid":"6a716097-1b44-4775-8e8e-46b5d1a1a5b1","round":"baseline","verdict":"FAIL","recommendation":"REWORK","captures":"32/32","visibility":{"visible":2018,"planned":3472,"missing":1454},"hard_gates":{"authored_loss":"FAIL","display_overflow":"PASS","silent_failures":"FAIL","false_not_found":"FAIL","control_byte_leaks":"PASS","identity_conflation":"PASS"},"related_isolation":"32/32","replay_runs":4,"external_mutations":0,"artifact_set_sha256":"35b7a9d356bc2a884ba33e2f3d894b16689855fa9a09b37566aa1db721e6406f"}
```
