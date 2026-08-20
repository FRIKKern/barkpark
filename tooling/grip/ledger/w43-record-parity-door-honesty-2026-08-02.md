# w43 — record-parity door honesty: what the 76 checks actually cover, and what axis B costs by aperture

Derived 2026-08-02 against `origin/main` @ `c6107095a`, from a `git archive` export into a
directory that is **not** a git repo (`git rev-parse --is-inside-work-tree` → fatal, rc=128).
Host was NOT quiet — absolute seconds are inflated; the ratios and the hermeticity results are not.

## Re-derivation

```bash
# 0. clean export of origin/main's scripts into a non-repo dir
D=$(mktemp -d) && cd "$D" && git -C <repo> archive origin/main scripts .claude | tar -x

# 1. the harness, green, timed in USER CPU (D605)
TIMEFORMAT='user=%U sys=%S wall=%R' bash -c 'time bash scripts/pds-record-parity.test.sh; echo rc=$?'
#   -> user=1.355 sys=2.817 wall=5.952 ; rc=0 ; "PASS  76 checks, 0 failures"

# 2. the same, with the network DENIED (macOS sandbox)
printf '(version 1)\n(allow default)\n(deny network*)\n' > /tmp/nonet.sb
sandbox-exec -f /tmp/nonet.sb bash scripts/pds-record-parity.test.sh    # rc=0, 76/76, user=1.53
sandbox-exec -f /tmp/nonet.sb curl -sS -m 8 https://guerrilla.barkpark.cloud/   # rc=6 — the deny bites

# 3. HOW MANY of the 76 can reach the ledger?  Count real curl calls with a logging shim.
mkdir -p /tmp/curlshim && printf '#!/bin/bash\nprintf "CURLCALL %%s\\n" "$*" >> /tmp/curlcalls.log\nexec '"$(command -v curl)"' "$@"\n' > /tmp/curlshim/curl
chmod +x /tmp/curlshim/curl && : > /tmp/curlcalls.log
PATH=/tmp/curlshim:$PATH bash scripts/pds-record-parity.test.sh   # rc=0
wc -l < /tmp/curlcalls.log        # -> 0     ZERO ledger reads across all 76

# 4. HOW MANY reach GitHub?  Same trick on gh.
mkdir -p /tmp/ghshim && printf '#!/bin/bash\nprintf "GHCALL %%s\\n" "$*" >> /tmp/ghcalls.log\nexec '"$(command -v gh)"' "$@"\n' > /tmp/ghshim/gh
chmod +x /tmp/ghshim/gh && : > /tmp/ghcalls.log
PATH=/tmp/ghshim:$PATH bash scripts/pds-record-parity.test.sh
cat /tmp/ghcalls.log
#   -> exactly ONE line:
#      GHCALL pr list --repo FRIKKern/pds-record-parity-selftest-no-such-repo --state merged --limit 400 --json ...
#      (test.sh:521-523 — a deliberately unresolvable repo; its FAILURE is the assertion)

# 5. the flag the task is written against does not exist
bash scripts/pds-record-parity.sh --selftest ; echo rc=$?     # -> "unknown argument '--selftest'", rc=3

# 6. neither script is declared to the Elixir ratchet, and .github never names it
git show origin/main:scripts/elixir-path-escape-check.sh | sed -n '89,101p'   # only scripts/pds-status-only-residue.exs
git grep -n record-parity origin/main -- .github                              # rc=1, no output

# 7. axis B, both apertures (LIVE — needs gh + network + ledger)
bash scripts/pds-record-parity.sh --axis b --limit 400   # rc=1
bash scripts/pds-record-parity.sh --axis b --limit 150   # rc=1
```

## The numbers

| aperture | terminal | divergent set | advisory epic-roots | grace-suppressed | LEAF REDDING | PDS-owned | foreign | user CPU |
|---|---|---|---|---|---|---|---|---|
| `--limit 400` (default) | 225 | 81 | 10 | 12 | **59** | **11 (18.6%)** | 48 (81.4%) | 11.62 s |
| `--limit 150` | 98 | 25 | 3 | 9 | **13** | **9 (69.2%)** | 4 (30.8%) | 4.50 s |

Wave-39's filing (`pds-bl-w39-record-parity-61-reds-owner-report`, issue #9097) measured the SAME
aperture (400) and got 61 reds / 4 PDS-owned = 6.6% PDS, 93.4% foreign.

Today, same aperture: 59 reds / **11** PDS-owned. All four rows wave 39 named by hand are STILL red
(`pds-w23-triage-round`, `pds-w27-round-bare-30`, `pds-w29-pay-lb`, `pds-w34-hand-bucket-register`)
and seven more PDS rows joined them. The filing is not stale in its thesis (majority-foreign) but its
per-owner table is: PDS's own share nearly TRIPLED, 6.6% → 18.6%, in three waves.

The 69%-PDS figure is an **aperture artifact**, not a contradiction: the most recent 150 merged PRs
are dominated by this epic's own churn, so a narrow window measures the epic, and a wide window
measures the fleet.

## Parent split @ 400 (LEAF REDDING only, by the rows' own `parent_id`)

```
11 task-2ac1f95237c4a8e5 (PDS)      10 studio-space-priority-desk      9 task-96a908af98698118 (Felix)
 8 bp-cloud-site-spawner-epic        5 auth-totp-tests-are-time-boundary-flaky
 3 task-c31a4f0a6c5be3ea  3 jarl-platform-followups-epic  3 cloud-console-hardening-epic  3 cch-instruments-epic
 1 jarl-innleggene-epic   1 jarl-flagship-epic  1 jarl-dogfood-publishing-epic
 1 important-paper-quality-wave-2-paper-2026-07-31
```

## The honesty finding

`scripts/pds-record-parity.test.sh` is CI-portable and genuinely hermetic w.r.t. the ledger:
`GIT_CONFIG_GLOBAL=/dev/null`, its own synthetic `file://` origin, its own `$TMP/charter.md`, and
every axis-B fixture routed through `--fixture-dir` (the canned transport). It never reads the real
charter, never reads a live ledger row, and makes exactly one (deliberately failing) GitHub call.

That is precisely why gating it does NOT gate record parity. It gates the ARM.
