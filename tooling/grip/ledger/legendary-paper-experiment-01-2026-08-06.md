<!-- doc-tier: cold | canonical-for: legendary-paper-experiment-01-evidence | budget: 1800tok -->
# Experiment 01 — canonical losslessness and structure baseline

Verdict: `BASELINE_ESTABLISHED_CURRENT_READERS_FAIL_HARD_THRESHOLDS`. This is a Round-1 baseline, not a repair candidate or format selection.

The exact four Paper pins and frozen inventory digest reproduced. Accounting is complete: 815 canonical blocks, 113 authored legacy `header` cells, 11 genuinely headerless tables, 1,374 table body cells, 388 mark records, and 381 exact-empty spacer paragraphs. Cloud Console 29 contains 11 paragraph-wrapped list items totaling 406 words and 2,268 characters.

Machine CLI/API and the canonical source endpoint preserve all four revisions and block arrays exactly. Current human readers do not meet the frozen losslessness/semantic thresholds:

- public, email, and TUI80 preserve 0/406 Cloud Console 29 nested-list words;
- public and email display 113/113 authored header cells, but all 46 rendered tables use `role="presentation"`;
- Studio, TUI, and human CLI consume `head` while the live sources use `header`;
- no current human reader preserves all 388 mark semantics;
- callout aliases, missing tones, and unknown tones lack one explicit cross-reader mapping;
- all four TUI80 captures remain display-cell bounded at 80 columns but span 1,305–2,357 lines.

The failure taxonomy freezes seven cases: header-alias loss, nested-list loss, mark divergence, tone degradation, exact-empty spacer debt, unknown author intent for 11 headerless tables, and conflicting `header/head` quarantine. The last two cannot be silently normalized: headers must not be invented and conflicting values require explicit quarantine.

The fixture corpus contains dimension-level controls, all four known-bad pinned Papers, adversarial header/head conflicts, malformed/nested list shapes, marks, tones, and empty/non-empty boundaries. Raw machine API, source, public, email, and TUI80 captures are retained with hashes. The baseline explicitly separates observed facts, inferences, and format preferences.

Verification ran four times: twice by the typed experimenter and twice independently by the leader. Every replay passed 104 checks with the same artifact-set SHA-256:

`f8dc91ab8fa23a2a5d861f476905c6ef3fd786d4742063ba72143fd807a5bdc8`

The build took 16.106082 seconds; declared probes accounted for 15.992225 seconds. Live HTTP probes encountered transient 500s and used bounded retries. That behavior is retained as evidence rather than converted into a stable absence claim.

Authenticated hydrated Studio, actual mail clients, and assistive technologies were not exercised by E01. Public/email bytes may also vary with live auxiliary data while canonical source pins remain stable. These are explicit Round-2/3 gates, not baseline passes.

Durable artifacts live under `.omx/state/legendary-paper-reader-upgrade-experiments/E01`: assignment authority, README, source/control/bad/adversarial fixtures, raw reader captures, census, reader probes, taxonomy, thresholds, hash manifest, timing, verification result, and reproducible builder/verifier scripts. Reproduction is:

```text
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E01/scripts/build_baseline.py
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E01/scripts/verify.py
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E01/scripts/verify.py
```

The stop condition is met: frozen denominators, controls, known-bad and adversarial fixtures, raw captures, thresholds, taxonomy, timing, and stable double verification are durable; no candidate was built and no production Paper, task, Campaign Paper, Cycle result, or product source was mutated by the experimenter.
