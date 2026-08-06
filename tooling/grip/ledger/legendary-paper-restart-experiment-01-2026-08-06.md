<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-01 | budget: 1900tok -->
# Restart Experiment 01 — canonical content baseline

Assignment `restart-experiment-01`, canonical round `baseline`, produced a fresh deterministic raw/envelope/semantic oracle for the four frozen Papers. Verdict: **baseline canonicalizer passes with known downstream-reader risks**. It selects no candidate format.

| Measure | Observed |
|---|---:|
| Frozen pins across two JSON projections | 8/8 |
| Canonical blocks | 815/815 |
| Authored table headers | 113/113 |
| Table body cells | 1,374/1,374 |
| Mark records | 388/388 |
| CCH29 nested-list words | 406/406 |
| Genuinely headerless tables | 11 |
| Invented headers | 0 |
| Block-local authored-loss events | 0 |
| Adversarial probes | 10/10 |

The canonicalizer keeps three boundaries explicit. Raw records byte count and digest. Envelope canonicalizes the complete JSON response. Semantic retains immutable identity, authored metadata, and ordered block trees, applying only recursive Unicode NFC. It does not trim/collapse whitespace, change punctuation or case, alias `header/head`, infer header intent, reorder blocks, or discard unknown fields.

The artifact verifier passed twice byte-identically for the experimenter and twice again independently for the leader, each with 141 checks and artifact-set SHA-256 `4c6bed078b71f6280233a57214b25e4446877e9ce900d0d6fe2bb443bea1b4e4`. Experimenter replay-output SHA-256 was `8560d06564745f6816fcc3a849740f8ed8f5d29dd43d20fcdb106ca8fbfab767`. Final capture time was 2.208467 seconds.

One earlier nonterminal rebuild returned exit 4 with empty stderr. It remains in `harness-attempts.json` without inferred cause and was not erased by the accepted clean build. This baseline proves the oracle is lossless; it does not prove human-reader parity.

Durable artifacts are under `.omx/state/legendary-paper-reader-upgrade-restart-experiments/E01`. Raw/canonical captures are in `evidence.tar.gz`, SHA-256 `db61dd8b614014de04fcf028abc8e0ed40129826649342fd66a914b14c8feed3`, and extract with `tar -xzf evidence.tar.gz`. Result SHA-256 is `614b3d182e3c0569a613779001147a9aaad899aa90dc3dbfa36545069528194e`; block-loss manifest SHA-256 is `3011d924c0bc9a9e6f1ba4ac764fe317a765a619cd46e4da279ea6fc092f3f24`; canonicalizer SHA-256 is `64f4bf3a0e2545621f206afd93b421f1e825230d4e1403508304959d87212d82`; zero-external-mutation proof SHA-256 is `c251ab9d76c7385467f7e93673ab0c912432bbdfd14313d866c90d7e7a11b64a`. Saved-token hits and external mutations were zero; all nine `bp` operations were reads.

## Cycle payload

```json
{"assignment_id":"restart-experiment-01","assignment_uuid":"f5556476-4677-4f31-ab90-d7bf5b9134ee","round":"baseline","verdict":"BASELINE_CANONICALIZER_PASS_WITH_KNOWN_READER_RISKS","blocks":"815/815","headers":"113/113","body_cells":"1374/1374","marks":"388/388","authored_loss":0,"invented_headers":0,"replay_runs":4,"replay_byte_identical":true,"external_mutations":0}
```
