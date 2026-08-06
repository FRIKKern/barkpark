<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-02 | budget: 1900tok -->
# Restart Experiment 02 — human-reader baseline

Assignment `restart-experiment-02`, canonical round `baseline`, captured public, email, and Studio at desktop, 390, 320, and 200%-equivalent reflow for all four frozen Papers. Verdict: **baseline fails with blocked surfaces**. Browser and preview proxies were never counted as authenticated Studio, delivered mail, or real assistive technology.

| Measure | Observed |
|---|---:|
| Browser matrix captured | 48/48 |
| Frozen blocks / headers / body cells / marks | 815 / 113 / 1,374 / 388 |
| Authored carriers preserved | 3,456/3,472 |
| Reading order exact | 24/32 available cells |
| No page overflow | 18/32 |
| No control overlap | 32/32 |
| Focus behavior | 32/32 |
| Table semantics | 0/32 |
| Callout semantics | 0/32 |
| Mark threshold | 8/32 |
| Authenticated Studio | BLOCKED 16/16 |
| Real assistive technology | BLOCKED 48/48 |
| Delivered Gmail/Outlook/Apple Mail | BLOCKED 48/48 |

CCH29 blocks `w29D015` and `w29D022` are absent across all eight public/email profile cells, producing sixteen authored-carrier losses. Fourteen available cells overflow the page. HTTP email preview reports `text/html` 4/4, proving only preview MIME. Login-page captures and CDP accessibility trees remain observations, not target-reader substitutes.

The frozen denominator also preserves eleven intentionally headerless tables. No experiment inferred headers. The hard-gate scorecard contains four passes, six failures, and four blocked classes, so current human-reader behavior cannot advance as a candidate baseline.

Capture took 108.216960 seconds. The experimenter ran the 17-check verifier twice. After compact evidence was added, the leader independently repeated it twice; both final runs reproduced verification SHA-256 `87b910708dfc0fcb12c61a56d48d0708dd83a3776baebe5a37e4882494f5dfc8` and evidence aggregate `ad86c6426235fc356dd258d55033ae899f821c683cbe8b00d45957a7fb00e1b0` across 89 files.

Durable artifacts are under `.omx/state/legendary-paper-reader-upgrade-restart-experiments/E02`. Raw/browser evidence is in `evidence.tar.gz`, SHA-256 `ad48c681b0a98100569e67501a76d994869a1443eb3ee45dcee520887465b13b`, and extract with `tar -xzf evidence.tar.gz`. Result SHA-256 is `2bcc8b5468273c0ef7987fc1172ac3bc21d98e031ecc06b577d7058a4794e7f1`; Cycle handoff SHA-256 is `15620d628ef4d29d671c346cf4cf6612c063cb5666900ed1d5d2d1056dbee686`; replay proof SHA-256 is `00bd2d73efdfaaaabe5ed161ddda55e6bb9bab70d5148c96e4e07544c319f813`; mutation proof SHA-256 is `63099bda1aa0254d622340f3d9e49cf0ba426d1160d0fe4330fad4e4ce0e162e`. Token scan found zero issues; tracked mutations were zero and all four live pins remained exact.

## Cycle payload

```json
{"assignment_id":"restart-experiment-02","assignment_uuid":"d75c84e3-5f21-4830-818a-ce2b3f519b2a","round":"baseline","verdict":"BASELINE_FAIL_WITH_BLOCKED_SURFACES","matrix":"48/48","hard_gates":{"pass":4,"fail":6,"blocked":4},"carriers":{"preserved":3456,"planned":3472},"reading_order":"24/32","no_overflow":"18/32","table_semantics":"0/32","callout_semantics":"0/32","studio":"blocked_16/16","assistive_technology":"blocked_48/48","delivered_mail":"blocked_48/48","replay_runs":4,"external_mutations":0}
```
