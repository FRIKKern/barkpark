# w56 verify — three lead lines, re-derivation recipes (2026-08-08)

Pinned base: `origin/main` @ `b97663730a7a98c39f05a607110bdad5981c81e4`.
Prod read: `barkpark.cloud`, container `cloud-db-1`, db `barkpark_cloud_prod`.
Every row below re-derives ONE claim. No claim in the verify report is a reading
that lacks a row here.

## (i) GRACE SCHEDULER — no billing/dunning worker exists

```sh
# 14 crontab entries, enumerated (the equality set wave 55's manifest keys on)
git show origin/main:cloud/config/config.exs | sed -n '267,348p' \
  | grep -oE '^ +\{"[0-9*/, ]+ [^"]*", *[A-Za-z][A-Za-z.]*'
# 17 worker modules exist; 3 are event-driven (auto_deploy, chat_notification, push_delivery)
git ls-tree -r --name-only origin/main cloud/lib | grep -iE 'worker|reaper' | sed 's|.*/||' | sort
# grace is enforced IN-BAND, not scheduled
git show origin/main:cloud/lib/barkpark_cloud/billing.ex | sed -n '1239,1275p'   # entitled?/1
git show origin/main:cloud/lib/barkpark_cloud/billing.ex | sed -n '56,60p'       # @grace_days 3
```

## (ii) RECLAMATION — the Hetzner billing sentence, read for coverage

```sh
# the sentence itself + the ALREADY-LANDED cch-w55-s2 retraction above it
git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex | sed -n '749,768p'
# the briefed path is WRONG (exits 1)
git cat-file -e origin/main:cloud/lib/barkpark_cloud/registry/failure_copy.ex
# the two enforcement axes that a reclamation actor would have to pick between
git show origin/main:cloud/lib/barkpark_cloud/billing.ex | sed -n '164,170p;270,276p'
```

## (iii) ENV-VAR — prod measurement with a liveness control

```sh
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -At -F, \
   -c \"select relname,n_tup_ins,n_live_tup from pg_stat_user_tables where relname='env_vars'\" \
   -c \"select relname,n_tup_ins from pg_stat_user_tables order by n_tup_ins desc limit 5\" \
   -c \"select pg_postmaster_start_time(), now()\" \
   -c \"select count(*) from env_vars\" \
   -c \"select action,count(*) from audit_events group by 1 order by 1\""
```

NOTE the shell trap: `$$…$$` dollar-quoting inside a double-quoted `ssh` argument is
expanded by the LOCAL shell into the PID (`ERROR: trailing junk after numeric
literal at or near "1536416env_var"`). Use single-quoted SQL literals inside a
double-quoted ssh arg, as above. The briefed MUST-RUN command has this defect.

`stats_reset` is NULL on this database, so `n_tup_ins` is only as deep as
`pg_postmaster_start_time()` (2026-07-23). The LIFETIME evidence is the audit
census (`audit_events` runs 2026-07-02 → now) plus `count(*) = 0`.

```sh
# caller set — reveal_env_var/1 has ZERO non-test callers; resolved_env_for_barkpark/1 has ONE
git grep -n 'reveal_env_var\|resolved_env_for_barkpark' origin/main -- cloud/ internal/ js/ web/
# the sole delivery site is the PROVISION CLAIM, not any post-provision path
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '11064,11072p'
# and the worker's JobSpec declares no `env` tag → bare json.Unmarshal drops it
git show origin/main:internal/provisioner/worker.go | sed -n '142,192p'
git show origin/main:internal/provisioner/worker.go | grep -n 'DisallowUnknownFields'  # no hits
# the console copy ALREADY states non-delivery (cch-w53-s1, landed)
git show origin/main:cloud/priv/static/app.js | sed -n '20028,20040p'
```
