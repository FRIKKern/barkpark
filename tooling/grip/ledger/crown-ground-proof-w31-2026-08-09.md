# crown-ground-proof — Arm D is buildable (deploy-reliability W31, 2026-08-09)

Re-derivation recipes. Every command below was RUN; the quoted numbers are its output.
The local checkout was **790 commits behind origin/main** at probe time and does not
contain `scripts/crown-reconcile.sh` at all, so every proof runs from a full-tree
`git archive origin/main`, never from the worktree.

## 0. Stage the tree (all later recipes assume $D)

    D=$(mktemp -d); git archive origin/main | tar -x -C "$D"; cd "$D"

## 1. The harness passes today

    bash scripts/crown-reconcile.test.sh; echo "RC=$?"
    # → crown-reconcile.test.sh: 91 passed, 0 failed   RC=0

## 2. state_load's silence is REAL (mutation, with a control that loses)

Three runs over identical fixtures, differing only in `CROWN_STATE_FILE`:
(i) absent path, (ii) present, header-line only, (iii) present + one graced sha.

    bash <scratchpad>/probe_state_silence.sh

    # (i) rc=0   (ii) rc=0   (iii) rc=2
    # diff (i) vs (ii): IDENTICAL. md5 f394b3ab944a740ef91375e9922099e7 both sides.
    # diff (ii) vs (iii): DIFFERS — (iii) prints "the graced sha dddd… aged off the
    #   re-ask list after 86400s with no cp row", so the probe can lose.

The sharper consequence: run (i) — memory WIPED — printed
`RECONCILED: … and no earlier grace is still owed a row.` That final clause is a
claim about a memory the run does not have. A wiped list does not merely go quiet;
it asserts the absence of debt.

## 3. A persistent store on the control plane is writable

`/root/.ssh/authorized_keys` on the box holds EXACTLY ONE key, and its fingerprint
is `~/.ssh/barkpark_indx`'s — so this probe used the same credential `DEPLOY_SSH_KEY`
must carry (deploy.yml reaches `root@${CP_HOST}` daily with it).

    ssh-keygen -lf ~/.ssh/barkpark_indx
    # SHA256:OXWq5f0KhYQHIAZmGZmuvwxq5I0TrowDdQVJGGQE6QI barkpark-indx-spike
    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      'ssh-keygen -lf /root/.ssh/authorized_keys; wc -l < /root/.ssh/authorized_keys'
    # SHA256:OXWq5f0KhYQHIAZmGZmuvwxq5I0TrowDdQVJGGQE6QI barkpark-indx-spike ; 1

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
      'hostname; mkdir -p /var/lib/crown-reconcile && touch /var/lib/crown-reconcile/probe && ls -l /var/lib/crown-reconcile; df -h /var/lib | tail -1'
    # barkpark-cp
    # -rw-r--r-- 1 root root 0 Aug  9 16:10 probe
    # /dev/sda1  38G  30G  6.1G  84% /

Durability across a session boundary (session 2 writes, session 3 reads):

    ssh … 'echo "hello 12345" > /var/lib/crown-reconcile/probe'
    ssh … 'cat /var/lib/crown-reconcile/probe; stat -c "%y %s %n" /var/lib/crown-reconcile/probe'
    # hello 12345
    # 2026-08-09 16:10:46.611376315 +0000 12 /var/lib/crown-reconcile/probe

Residue left on the box by this probe: `/var/lib/crown-reconcile/probe` (12 bytes).

## 4. The whole slice end-to-end, live, with a persistent list

    env GH_TOKEN="$(gh auth token)" CP_HOST=barkpark.cloud \
        DEPLOY_SSH_KEY="$(cat ~/.ssh/barkpark_indx)" \
        CROWN_STATE_FILE=/tmp/live-state.txt \
        bash scripts/crown-reconcile.sh --repo FRIKKern/barkpark --window-hours 24
    # RC=0, and /tmp/live-state.txt exists afterwards carrying the header line.
    # It printed `note: the route answered HTTP 401 to the WORKER principal …` TEN
    # times — s7's "read path is a first-class verdict field, not a note: line"
    # criterion is confirmed UNMET on origin/main by this run's own output.

## 5. shell-harnesses.yml does NOT list crown-reconcile — and must not be made to

    git show origin/main:.github/workflows/shell-harnesses.yml | grep -c crown-reconcile
    # 0

That is NOT a gap. `.github/workflows/crown-reconcile.yml` carries its OWN
`pull_request:` trigger paths-filtered to exactly `scripts/crown-reconcile.sh`,
`scripts/crown-reconcile.test.sh`, `.github/workflows/crown-reconcile.yml`, plus a
`crown-reconcile-harness` job (`if: github.event_name == 'pull_request'`) that runs
`bash -n` + the mutation harness. Proven to FIRE, not merely to exist:

    gh run view 31320596893 --json jobs -q '.jobs[] | "\(.name) \(.conclusion)"'
    # Crown reconcile harness  success
    # Crown reconcile          skipped

Adding crown-reconcile to `shell-harnesses.yml` would double-run the harness. The
REAL gap is one line narrower: `scripts/crown-reconcile.test.sh:482` reads
`.github/required-checks.json` as a fixture ("crown-reconcile is not in the
required-check spec"), and that file is in NO crown-reconcile trigger path — an
input that can break the harness cannot trigger it, which is the exact doctrine
`shell-harnesses.yml`'s own header states.

## 6. The live launder, with a named sha, dated today

    gh run view 31321844876 --log | grep -E "SERVING GRACE|COULD NOT FULLY READ|warning"
    # SERVING GRACE: the serving sha 1d57725553b39db5feb38bf7d2517f429db1879b has no
    #   cp row, but that process is only 10s old … DEFERRED to the next run
    # COULD NOT FULLY READ: 1 unreadable-or-deferred condition(s) fired
    # ##[warning]the reconciler COULD NOT READ …
    gh run list --workflow=crown-reconcile.yml -L 1
    # …#31321844876 completed/SUCCESS

rc=2 → `exit 0` → run conclusion `success`. The grace was written to
`${TMPDIR}/crown-reconcile-graced.txt` on an ephemeral runner and died with it.
HONESTY: the debt settled anyway — the row appeared 65s later —

    ssh … docker exec <db> psql -tAc "SELECT sha,target,carried,first_seen_at FROM
      platform_deliveries WHERE sha LIKE '1d5772555%'"
    # 1d57725553b39db5feb38bf7d2517f429db1879b|cp|f|2026-08-09 15:44:03
    # 1d57725553b39db5feb38bf7d2517f429db1879b|instance|t|2026-08-09 15:51:11

so today's instance was benign. The MECHANISM is broken; this particular grace was
not a missed accusation. Do not quote it as one.
