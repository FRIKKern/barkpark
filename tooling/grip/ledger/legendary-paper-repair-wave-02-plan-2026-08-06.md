<!-- doc-tier: cold | canonical-for: legendary-paper-repair-wave-02-plan | budget: 3000tok -->
# Legendary Paper reader repair wave 02 — hard-gate-complete plan

Repair wave 01 opened with zero assignments, then independent architecture review proved that its 20-unit inventory collapsed materially different TUI widths, delivered-mail clients, CLI, and API evidence. It is preserved as a pre-dispatch superseded authority. Repair wave 02 is the first dispatchable successor: four frozen Paper revisions × nine homogeneous reader/evidence classes = 36 units.

## Immutable authority

- Wave: `legendary-paper-reader-upgrade-wave-2026-08-06-repair-02`.
- Inventory: [wave-open.json](../../../.omx/state/legendary-paper-reader-upgrade-repair-02/wave-open.json).
- Survey60 manifest: [survey-plan.json](../../../.omx/state/legendary-paper-reader-upgrade-repair-02/survey-plan.json).
- Experiment15 manifest: [experiment-plan.json](../../../.omx/state/legendary-paper-reader-upgrade-repair-02/experiment-plan.json).
- Scale: Survey 60, Verify 30, Experiment 15, computed Build at least 15, Review 15, concurrency width 3.

Open only the server-supported projection; `schema_version` and `prior_wave` are committed wrapper metadata:

```bash
inventory="$(jq -c '.inventory' .omx/state/legendary-paper-reader-upgrade-repair-02/wave-open.json)"
scale="$(jq -c '.scale_contract' .omx/state/legendary-paper-reader-upgrade-repair-02/wave-open.json)"
experiment="$(jq -c '.experiment_contract' .omx/state/legendary-paper-reader-upgrade-repair-02/wave-open.json)"
BARKPARK_MANIFEST=docs/cli/fixtures/full-manifest.json bp -s guerrilla cycle open \
  task-a768c69e659add58 legendary-paper-reader-upgrade-wave-2026-08-06-repair-02 \
  legendary "$inventory" "$scale" --experiment_contract_json "$experiment" --yes
```

The nine classes are public browser, authenticated Studio, TUI terminal, MIME, delivered Gmail, delivered Outlook, delivered Apple Mail, CLI, and API. Widths and clients are hard evidence cells inside their homogeneous class; no combined `tui80`, `email`, or `cli_api` unit remains.

## Survey and verification

Survey uses 60 exact assignments. S01–S36 pin one frozen unit each. S37–S48 cover all 36 units in disjoint three-unit real-reader/environment groups. S49–S60 cover all 36 again in disjoint three-unit predecessor-failure/repair-seam groups. Thus every unit receives all three lenses without overlap inside a lens.

Verify remains 30 exact assignments in ten waves of three:

1. authored counts, source hashes, recursive schema, and header intent;
2. alias quarantine, expected-revision CAS, read-side purity, rollback, retry, and idempotence;
3. public real-browser DOM, cache, long-token, narrow-width, and reflow behavior;
4. authenticated Studio mount, immutable identity, focus, scroll, click/Enter, expiry, and reconnect;
5. MIME plus delivered Gmail, Outlook, and Apple Mail;
6. VoiceOver plus NVDA or explicitly equivalent real assistive technologies;
7. TUI widths 1/20/40/80/120, controls, focus/scroll/click/Enter/history/Related/recovery;
8. typed failures, request IDs, identities, ETags, conditional requests, and perspectives;
9. CLI/API discovery, help/schema/OpenAPI, pagination, history limits, and negotiation;
10. runnable harness readiness, collision-free implementation seams, rollback, and credential scan.

Every claim receives a command/capture, denominator, proof/refutation verdict, evidence path, and residual risk. A blocked dependency must become executable or remain a hard failure.

## Experiment and Pilot

The committed Experiment manifest owns all 15 canonical IDs, dependencies, evidence roots, hard cells, and stop rules. Baseline must prove real authenticated Studio, deployed cache/reconnect, real delivered Gmail/Outlook/Apple Mail, Chrome/Safari/Firefox frames, VoiceOver plus NVDA/equivalent, and the five-width terminal harness before Diverge.

Pilot batches are disjoint and cover all 36 units: CCH29 (9), PDS45 (9), and CCH28+PDS44 (18). Each has 1800 seconds, error budget zero, stable golden hashes, and no FAIL/BLOCKED/proxy allowance. Proven capacity is the largest fully passing batch inside budget, reduced to the smallest result across materially different classes.

## Absolute stop

No score may average away a hard cell. If one integrated candidate does not pass the complete E10+E11+E12 union twice with zero FAIL, BLOCKED, proxy, unstable, missing-reader, credential, or positive hard-failure cells, Pilot is forbidden. The wave closes unsuccessful; immutable history is never patched.
