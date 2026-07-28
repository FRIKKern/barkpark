# PDS wave 23 — re-derivation recipes: crown arm-time liveness + scratch pointer strand

Written by the v9 verifier (2026-07-28). Every row below is a command that re-derives
one fact from scratch. Nothing here is a claim; run the command.

## Crown launcher — ARMED is printed with no liveness read

| Fact | Command |
|---|---|
| The whole arm-time gate is `is_int` on the pid file; the very next claim is ARMED | `git show origin/main:scripts/pds-crown-launch.sh \| sed -n '512,527p'` |
| `pid_live` exists in the same file at :171 and is never called by `cmd_arm` | `git show origin/main:scripts/pds-crown-launch.sh \| grep -n 'pid_live'` |
| Selftest is green today (46 ok / 0 FAIL) and asserts nothing about the ARMED claim | `bash scripts/pds-crown-launch.sh selftest > /tmp/st.log 2>&1; echo $?; tail -3 /tmp/st.log; grep -c ARMED scripts/pds-crown-launch.sh` |
| A t+0 `pid_live` read on an instant-exit child is a COIN FLIP (rc=0 then rc=1 ms later) | see `probe/run.sh` recipe below |
| The failure is KNOWN and mitigated with a WARNING, not a read (PDS-D258) | `git show origin/main:scripts/pds-climb-preflight.sh \| sed -n '397,398p'` |
| No commit after the launcher's creation added an arm-time read | `git log --oneline origin/main -- scripts/pds-crown-launch.sh` |

Probe recipe (reproduces the t+0 race; writes only under /tmp):

```sh
sed '$d' scripts/pds-crown-launch.sh > /tmp/launch-lib.sh     # strip `main "$@"`
mkdir -p /tmp/pdsprobe && printf '#!/bin/bash\nexit 0\n' > /tmp/pdsprobe/instant.sh
bash -c 'set -uo pipefail; source /tmp/launch-lib.sh
  fire_detached t /tmp/pdsprobe/att /tmp/pdsprobe/i.log \
    "exec /bin/bash /tmp/pdsprobe/instant.sh" /tmp/pdsprobe/i.pid
  p=$(tr -d " \n" < /tmp/pdsprobe/i.pid)
  for t in 0 1 3; do [ $t != 0 ] && sleep 1
    set +e; pid_live "$p"; rc=$?; set -e
    echo "t+${t}s pid_live_rc=$rc classify=$(classify /tmp/pdsprobe/i.log /tmp/pdsprobe/i.pid)"
  done'
```

## Scratch target — one pointer, three ledger rows, one defect

| Fact | Command |
|---|---|
| The pointer is one global path | `git show origin/main:scripts/pds-scratch-target.sh \| sed -n '124p'` |
| `up` writes it unconditionally (:381); teardown clears it (:651) | `git show origin/main:scripts/pds-scratch-target.sh \| sed -n '381p;649,652p'` |
| `resolve_home` has exactly two sources: `$BARKPARK_HOME` or the pointer | `git show origin/main:scripts/pds-scratch-target.sh \| sed -n '249,261p'` |
| No test file for the scratch target exists anywhere | `git ls-files \| grep -i 'scratch.*test\|test.*scratch'` (empty) |
| No workflow runs any `scripts/pds-*` harness | `grep -rln 'pds-' .github/workflows/` (empty) |
| `shell-harnesses.yml` is path-pinned to doctor.sh only | `sed -n '10,22p' .github/workflows/shell-harnesses.yml` |

Strand reproduction (offline, no servers, ~5s — this IS the missing test's shape):

```sh
export PDS_SCRATCH_POINTER=/tmp/strand.pointer
for n in A:39411:39412 B:39413:39414; do
  d=/tmp/pds.st${n%%:*}; r=${n#*:}; mkdir -p $d
  printf 'export BARKPARK_HOME="%s"\nexport PORT="%s"\nexport BARKPARK_PG_PORT="%s"\nexport PHX_HOST=127.0.0.1\nexport PDS_SCRATCH_BASE="http://127.0.0.1:%s"\n' \
    "$d" "${r%%:*}" "${r##*:}" "${r%%:*}" > $d/scratch.env
  printf '%s\n' "$d" > $PDS_SCRATCH_POINTER          # cmd_up:381, verbatim
done
scripts/pds-scratch-target.sh env | grep BARKPARK_HOME   # -> B, not A
scripts/pds-scratch-target.sh teardown                   # -> destroys B, PASS, clears pointer
for v in env status teardown verify; do scripts/pds-scratch-target.sh $v; done  # all four die
```

Ports must be verified free first (`lsof -nP -iTCP:<p> -sTCP:LISTEN`) — teardown refuses
without both ports precisely because `barkpark stop` falls back to port 4000.
