<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-30 | budget: 2100tok -->
# Restart Verify 30 — revision-bound core and mutable Related appendix

Assignment `restart-verify-30` exercised six Related outcomes at widths 80 and 1 against a frozen CCH29 source. Verdict: **refuted**. The core Paper body is byte-stable and immune to Related variation, but secondary failures are silently erased and successful Related output violates width 1.

| Measure | Width 80 | Width 1 |
|---|---:|---:|
| Executions | 6/6 | 6/6 |
| Unique core hashes | 1 | 1 |
| Unique appendix hashes | 3 | 3 |
| Exit zero | 6/6 | 6/6 |
| Empty stderr | 6/6 | 6/6 |
| Complete output bounded | 6/6 | 4/6 |
| Maximum display width | 80 | 7 |

The six outcomes were happy A, happy B, legitimate empty, malformed JSON, HTTP 500, and transport close. All twelve executions used the literal `\nRelated\n` split boundary. The width-80 core occupied 125,535 bytes and 1,421 lines with SHA-256 `043582d797e8547fd3abcf83483ae0e65649913cb3df0eb12fdf782816d8a5c2`. The width-1 core occupied 128,662 bytes and 80,346 lines with SHA-256 `e4892e251353a50052e1b0942f9de59788c4125beaf137d426b0a499bbccdc1e`. Every outcome at each width shared its core hash.

Appendix variation remained isolated: A, B, and absent output produced three distinct hashes. However, malformed JSON, HTTP 500, and transport close produced no stderr and were indistinguishable from legitimate empty. Transport was retried twice per width and then silently erased. Both successful width-1 appendices emitted the seven-cell `Related` heading, so overall containment is 10/12.

Relevant Related wrapping, happy-path, and fail-open unit tests passed. They confirm current behavior but do not satisfy explicit secondary diagnosis. Standalone and taskboard TUI code both call the same `pdrender.RenderDoc` core without a Related append path; this is a code-traced inference rather than a PTY proof. The fixture exercised CCH29 only, revision `18768b0a14c2eead927181c4a0e37c18`, 252 blocks; the other three frozen Papers remain outside this assignment.

The tested binary SHA-256 is `4d2b3536a6a879ed541ec7108a45f08eabf2e743e1e3a8aa0d33d139138ad1f1`, built from `e80d068fff75d984d4444e51b9d89f516472e8d9`. Analysis is `/private/tmp/bp-rv30-analysis-v2.json`, SHA-256 `6e51e488094e242d8ece986d0c1c4e1f7205ed389057dd66d90d4bc0188812b1`; request log is `/private/tmp/bp-rv30-requests-v2.jsonl`, SHA-256 `79a8e8c4ac4db719d8e1c99f35d124f53a9e0bc20934e144d741fce2ec7da6c5`. Tracked diff was zero bytes and no Task, Paper, Cycle, content, or ledger mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-verify-30","assignment_uuid":"1f3aafdc-7e7c-4a4c-a410-e9d6770d141e","verdict":"refuted","outcomes":6,"captures":12,"width80":{"core_hashes":1,"appendix_hashes":3,"exit_zero":"6/6","stderr_empty":"6/6","bounded":"6/6","max_width":80},"width1":{"core_hashes":1,"appendix_hashes":3,"exit_zero":"6/6","stderr_empty":"6/6","bounded":"4/6","max_width":7},"secondary_failures_diagnosed":"0/6","overall_bounded":"10/12","mutations":0,"analysis_sha256":"6e51e488094e242d8ece986d0c1c4e1f7205ed389057dd66d90d4bc0188812b1"}
```
