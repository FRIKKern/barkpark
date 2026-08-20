# cch-w56-v12 — promise-census undercount: re-derivation recipes

Tree: `git archive origin/main | tar -x -C /tmp/w56` at `b97663730a7a98c39f05a607110bdad5981c81e4`.
All recipes assume `cd /tmp/w56`.

## R1 — the assigned "web/ templates" surface does not exist

```
find cloud/lib/barkpark_cloud/web -type f
find cloud -name '*.heex'
```
Expect exactly 3 files (`auth.ex`, `router.ex`, `raw_body_reader.ex`) and ZERO `.heex`.
The control plane renders no server-side templates; the console is `cloud/priv/static/app.js`.

## R2 — the ONE user-facing promise string in web/

```
grep -rnEi '"[^"]*(will be|we.ll|shortly|in a moment|on the next run|queued for|automatically|coming soon|retention|expires? (in|on|after)|renew|nightly|[0-9]+ days)[^"]*"' cloud/lib/barkpark_cloud/web/*.ex | grep -v '^\s*#'
```
Expect exactly `router.ex:8710` ("try again shortly"). Everything else the wide grep hits in
`router.ex` (43 lines) is comment or a JSON key name.

## R3 — the CLI promise-copy census (the real delta)

```
grep -rn --include='*.go' -E 'out\.(outf|userErr|progressf|warnf|errf)\(' internal/cli \
  | grep -v '_test.go' \
  | grep -Ei "will |once |within |shortly|in a moment|next run|queued|automatic|soon|every |daily|nightly|hourly|expire|renew|retention|[0-9]+ (days|hours|minutes)"
```

## R4 — the CLI carries ZERO billing/dunning promise copy (bounds cch-w54-s5)

```
grep -rn --include='*.go' -Ei '"[^"]*(trial|dunning|past due|past_due|suspend|unpaid|invoice|payment|billing period|period end)[^"]*"' internal/cli | grep -v '_test.go'
```
Every hit is a struct field / status token; no sentence.

## R5 — cloud_lifecycle_vocab.go line citations are stale (fold itself matches)

```
grep -n 'lifecyclePillState\|function instanceLifecycle' cloud/priv/static/app.js
sed -n '674,682p;1695,1703p;2375,2383p;6927,6935p' cloud/priv/static/app.js
```
`app.js:674-682` = `trapModalTab`; real `lifecyclePillState` = 1695-1703.
`app.js:2375-2383` = `launchBody`; real `instanceLifecycle` = 6927-6935.

## R6 — app.js renders NO agent-retention sentence

```
grep -n -Ei "retention|retain|prune|agent_events" cloud/priv/static/app.js
```
All 12 hits are comments about HTTP-fault retention. The retention worker exists
(`cloud/config/config.exs:328`, `{"30 3 * * *", AgentRetentionWorker}`) and is never named to a user.

## R7 — `audit_retention_days` (90) has no sweeper

```
grep -rn 'audit_retention_days' cloud/ --exclude-dir=_build
```
Definition + runtime override + one accessor. Zero call sites. `config.exs:120-124` says so itself
("a FUTURE retention sweeper", "The sweeper itself is a follow-up").

## R8 — trial reminder ABSENT (re-confirmed)

```
sed -n '14842p' cloud/priv/static/app.js
grep -rni 'remind' cloud/lib | wc -l     # → 0
```

## R9 — the go-live health gate passes an unchecked backup schedule

```
grep -rn 'StubsOptional' internal/cli --include='*.go' | grep -v _test
sed -n '419,423p;482,505p' internal/cli/setup/healthgate.go
CC=clang go test ./internal/cli/setup/ -run Health -count=1
```
`cloud/warmpool.go:975,1019` set `StubsOptional: true`; `stubProbe` then returns `Pass:true`
for `backup-scheduled-stub` with no probe URL. Declared + tested waiver, not a hidden lie.

## R10 — "it'll update automatically" IS backed, by an external clock

```
sed -n '16320,16352p' cloud/priv/static/app.js
grep -rn --include='*.ex' 'push_event([^,]*, *"subscription")' cloud/lib
```
Two emitters (`router.ex:5759` cancel, `router.ex:5792` Stripe webhook). Actor = Stripe delivery,
which has NO in-tree arming literal — the fifth-clock-value problem, live on a second promise.

## R11 — the Paper reader defect reproduces on wave 50

```
bp paper view cch-wave-50-2026-08-07
# → status 422: {"error":{"code":"semantic_empty"}}
```
