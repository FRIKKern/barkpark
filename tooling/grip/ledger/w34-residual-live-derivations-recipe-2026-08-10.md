# w34 — residual live re-derivations (RECIPE ONLY; NO VALUES STORED)

Wave 34, verifier lane `residual-live-derivations`. **Status: UNDERIVED.** The verifier's
host had no writable scratch (`ENOSPC` on the harness's own bash output path — every
`Bash` invocation, including `echo ok`, failed before the command ran), so not one of the
four residuals below was re-derived. They remain **L4 prose**. Nothing in this file is a
measured value; a grip row that stored one would be wrong by design.

Target sentences (charter `.claude/workflows/bp-deploy-reliability-charter.md:11606-11617`,
"WHAT THE WIND-DOWN WILL SAY WHEN THESE LAND"):

1. abandonment can lose a publish, **2 of 7**, `search` @ `947c0dbd0de8` and `search-ember`
   @ `91284be29666`, both saved only by a later whole-site rebuild (D544).
2. D38's `exit 15` lapse is undischarged and unfired, **0 rows all-time** (D560).
3. the **preview arm is `never_covered` by construction** (D557).
4. delivery's **healing tail 12-30h past the 2026-08-05T21:13:50Z boundary** — p95 refuses
   at b+0h and b+6h, first prints 7,820s at b+12h, settles to 336s by b+36h (D569).

## Re-run (control-plane Postgres; live slot is **GREEN**, not blue — D572)

```sh
cat > /tmp/w34resid.sql <<'SQL'
SELECT count(*) AS total FROM deployments;
SELECT count(*) AS exit15 FROM deployments WHERE failure_reason ILIKE '%exit 15%';
SELECT environment,status,count(*) FROM deployments GROUP BY 1,2 ORDER BY 1,2;
SELECT site_id,content_rev,status,inserted_at FROM deployments
  WHERE failure_reason LIKE '%rebuilds in a row for this site%' ORDER BY inserted_at;
SQL
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -f -"' \
  < /tmp/w34resid.sql; echo rc=$?
```

Reading rules, so the next runner does not repeat a known trap:

- The `total` row is the **anti-vacuity control**. A zero `exit15` beside a zero `total` is
  a broken query, not a finding.
- Residual 3 needs BOTH halves: exactly 2 `preview` rows AND
  `count(*) WHERE environment='preview' AND status='live'` = 0. The GROUP BY above answers
  both only if a `preview|live` row would have appeared — state that explicitly.
- Residual 1's two shas must be shown as real `content_rev` values on real `site_id`s in
  the fourth query's output, and the "saved" claim needs the LATER `live` row on the same
  `{site_id, environment}` — the fourth query alone does not prove "saved".
- `deferral_depth = deferral_bound` is **UNSATISFIABLE by construction** (D544) — the
  abandonment population is reachable only through the prose scan used above.
- `/app/bin/barkpark_cloud eval` cannot run the census (Repo not started); only `rpc` (D572).
- Never `cmd | tail && echo ok` — the pipe eats the rc.

Residual 4 is not answered by this SQL at all; it needs `DeployLedger.delivery/3` run via
`rpc` at b+0h/b+6h/b+12h/b+36h offsets from `2026-08-05T21:13:50Z`.

## Correction carried, unverified

The wave brief instructed correcting residual 2 from "names the wrong lock" to "names BOTH
locks now". **That phrase does not appear in residual 2 on this checkout** — the charter's
sentence at `:11611` reads only "D38's `exit 15` lapse is undischarged and unfired, 0 rows
all-time, and D525's chain-depth argument for it is struck (D560)". Whatever draft carried
the lock wording is not this one; verify against the draft actually being edited before
applying the correction. This checkout is itself **divergent** from `origin/main` (49 ahead
/ 823 behind per the wave digest), so treat the quoted lines as L3 until re-read with
`git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md`.
