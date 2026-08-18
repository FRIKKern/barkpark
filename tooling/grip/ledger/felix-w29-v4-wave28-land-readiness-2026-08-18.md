<!-- doc-tier: cold | canonical-for: felix-w29-v4-wave28-land-readiness | budget: 900tok -->

# felix w29 V4 — wave-28 land readiness (re-derivation recipes)

Verifier V4 proofs for the four unmerged wave-28 slice PRs (#12109 s3 receive_timeout,
#12111 checkout honesty, #12113 pulse deflake, #12114 dead-letter). Re-run any row.

## 1. Elixir Test gate — GREEN on all four PRs

    for p in 12109 12111 12113 12114; do gh pr checks $p | grep '^Test (Elixir'; done
    # each prints: Test (Elixir 1.18.1 / OTP 27.0)  pass  ...

## 2. Which shared reds are ambient on current origin/main HEAD

    git fetch origin main -q
    gh api repos/:owner/:repo/commits/$(git rev-parse origin/main)/check-runs \
      --paginate --jq '.check_runs[]|{name,conclusion}' | sort -u

main HEAD 71f06d62 conclusions:
  Compose smoke ............... failure  -> AMBIENT (also red on all 4 PRs)
  Green arm ................... failure  -> AMBIENT
  Sobelow (regression gate) ... failure  -> AMBIENT
  Doc budgets + anchors ...... SUCCESS   -> NOT ambient; PR reds are STALE-BASE (see §3)

## 3. Doc-budgets red on the PRs is a stale-base artifact, NOT the PR diffs

PR CI failed with:
  FAIL: canonical-for 'none' has more than one owner:
    tooling/grip/ledger/felix-w26-ssrf-toctou-verdict-2026-08-17.md
    tooling/grip/ledger/onb-w6-release-cache-criteria-vs-d38-2026-08-18.md

The PRs branched off a base where onb-w6's header still read `canonical-for: none`
(second owner of 'none'). Commit 479bca886a (#12116, "canonical-for heal", 02:10)
healed onb-w6 to a unique slug. Current main has exactly ONE header 'none' owner:

    git grep -c 'canonical-for: none ' origin/main -- '*.md' \
      ':(exclude)_attic/**' ':(exclude).claude/**'
    # -> 1 file (felix-w26 only) => uniqueness holds => main green

None of the four PR diffs touch ledger files:

    for p in 12109 12111 12113 12114; do gh pr diff $p --name-only | grep ledger; done
    # -> empty

=> Rebasing the four PRs onto current main HEAD clears the Doc-budgets red.
   Classic stale-green merge window (two green PRs each adding a 'none' header).

## 4. #12113 tref/timer-cancel — BENIGN for prod supervision

    gh pr diff 12113 --patch | grep -n sample_now
    # sample_now referenced ONLY at: def (:50), handle_call (:81), moduledoc,
    # and the TEST helper (:135). No lib/prod caller.
    git grep -n sample_now origin/main -- 'api/**'   # -> none (new symbol)

Metrics is a globally-supervised plugin worker:
    git grep -n 'register_workers' origin/main -- api/lib/barkpark/plugins/pulse.ex
    # -> def register_workers(_sup), do: [Barkpark.Pulse.Metrics]

Prod path unchanged: init arms one :tick (2 s), handle_info(:tick) samples + re-arms
one :tick (2 s) — same cadence, tref is pure bookkeeping. On crash the supervisor
restarts -> init re-arms fresh; tref (transient) correctly re-established. The only
new behavior, sample_now cancel-without-rearm, is test-only with zero prod callers.
No child_spec / supervision-tree / restart-semantics change.
