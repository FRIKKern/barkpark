<!-- doc-tier: cold | canonical-for: felix-w27-held-claim-close-recipe | budget: 1200tok -->
# felix-w27 — held-claim ledger-close recipe (re-derivation)

> HISTORICAL RECORD (2026-08-17) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

**Verdict:** A foreign session CLOSES a held-claim row by presenting the LIVE claim's `worker` + `epoch` — **no re-claim needed**. The wave-26 D164 re-claim→stamp→close recipe is NOT required and would needlessly bump the epoch. Close is hard-CAS on `epoch`, honesty-gated on `worker`.

## Proof (live guerrilla, 2026-08-17)

Scratch task, claimed as `w27-probe-holder` (epoch 1), then closed from a fresh stateless `bp` invocation presenting `w27-probe-holder 1`:

```
bp task close <id> w27-probe-holder 1 done "..."
→ ok:true  lifecycle_status:"done"  closed_by:"w27-probe-holder"  epoch:1
```

Second scratch task proved the CAS is load-bearing:

- **wrong epoch** (`... w27-cas-probe 2`) → `{"error":{"code":"fenced_off", "hint":"your claim epoch is stale — re-claim under your worker id, then retry"}}`
- **wrong worker, right epoch** (`... not-the-holder 1`) → `{"error":{"code":"not_holder:w27-cas-probe", ...}}` — an HONESTY gate, overridable with `--set holder_override="<why>"` ("a lead sealing a merge-gated task is the normal case").
- **correct worker+epoch** (`... w27-cas-probe 1`) → `done`, `closed_by: w27-cas-probe`.

## Recipe for Decide (two forms)

Form A (recorded as the holder — matches wish): present the holder's exact `worker` + current `epoch`:
```
bp task close <id> <holder-worker> <epoch> done "<summary>"
```
Form B (recorded as a foreign lead-seal, auditable): close under the lead's own worker id + current epoch + honesty override:
```
bp task close <id> <lead-worker> <epoch> done "<summary>" --set holder_override="merge-gated seal, PR #NNNN merged"
```

## Two fences to respect

1. **Epoch is CAS.** A stale epoch → `fenced_off`. Builders may `pulse` (epoch bumps) or self-close on merge, so **re-read `claim.epoch` immediately before closing** — do NOT trust the snapshot below.
2. **Work-digest fence.** If the task's brief (title/description/acceptance_criteria) changed since the claim, close 409s `doc_changed_since_claim` naming `current_rev` + `changed_fields`. Recover: re-read, reconcile, close with `--set observed_rev=<current_rev>` (bypasses the digest fence via full-rev CAS).

## Live snapshot of the six paid rows (as of ~2026-08-17T20:51Z — RE-READ before use)

| task id | lifecycle | epoch | worker (verbatim, cap ~53 chars) | rev |
|---|---|---|---|---|
| felix-w26-s1-11853-rescue | in_progress | 6 | epic-builder-land-the-dataset-slug-guard-supersede-re | b4de74890c48b3e062d56133a1e0e4e6 |
| felix-w26-s3-ssrf-rebind-pin | in_progress | 6 | epic-builder-close-the-dns-rebinding-toctou-in-net-sa | a4bbb23b89232cb347f69033189a7f95 |
| felix-w24-bl-blobstore-runtime-guard | in_progress | 4 | epic-builder-blobstore-read-path-traversal-guard-prom | f4df2eb1012642f666fbab600e6db525 |
| task-felix-w22-bl-codex-completion-deadbranch | in_progress | 5 | epic-builder-chatlive-two-seam-honesty-resurrect-the- | fcabf1f375fec6d0f3e1a9c33899d391 |
| felix-w19-bl-authority-lock-remaining-sites | in_progress | 6 | epic-builder-authority-lock-remaining-sites-lock-wait | 6f40a104eda7524185e8a4828bac1014 |
| task-felix-w21-bl-releasecapture-bound-tests | in_progress | 7 | epic-builder-cover-the-release-capture-124-125-deadli | 7c92970885431a27ddbc18790a52f2d3 |

Re-derive any row:
```
bp task get <id> -o json | python3 -c "import json,sys;raw=sys.stdin.read();d=json.loads(raw[raw.find('{'):])['doc'];c=d['claim'];print(d['lifecycle_status'],c['epoch'],c['worker'],d['rev'])"
```
