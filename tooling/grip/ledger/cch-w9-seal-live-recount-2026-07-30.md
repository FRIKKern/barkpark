# Re-derivation: cloud-console-hardening seal predicate, live recount (wave 9 verify)

Measured 2026-07-30 ~17:22-17:30Z against the live ledger (`https://guerrilla.barkpark.cloud`)
and `origin/main` @ `08d4c869a`.

## WARNING — the primary checkout was 86 commits stale and dirty

```sh
cd /Volumes/SATECHI/github/barkpark && git fetch origin -q
git rev-parse HEAD          # a31faa52dc7586168cecc7dc2d2324b3732943f6
git rev-parse origin/main   # 08d4c869a4d997a0092198c67f75707294210c33
git rev-list --count HEAD..origin/main   # 86
```

Authoritative repo reads were taken from a scratchpad snapshot, never the checkout:

```sh
D=$(mktemp -d); git archive origin/main | tar -x -C "$D"
node "$D/cloud/priv/static/__preview__/seal-predicate.mjs" --repo "$D" --successor task-47bc4168392dec17
```

Both trees produced the identical token, so staleness did not move the verdict here.

## The three legal invocations all REFUSE — with THREE DISTINCT reasons

```sh
node cloud/priv/static/__preview__/seal-predicate.mjs --repo "$PWD"
# VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=NO-SUCCESSOR a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED
node cloud/priv/static/__preview__/seal-predicate.mjs --repo "$PWD" --successor cloud-console-hardening-epic
# VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=SELF-SUCCESSOR   a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED
node cloud/priv/static/__preview__/seal-predicate.mjs --repo "$PWD" --successor TERMINAL
# VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=TERMINAL-CLAIM-REFUTED a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED
```

### The `for s in '' ... ; do ... $s ; done` loop form is BROKEN under zsh

zsh does not word-split unquoted parameter expansions, so `$s` arrives as ONE argv
element and `arg('--successor')` never matches. All three iterations then print
`reason=NO-SUCCESSOR` — a vacuous pass that looks like agreement.

```sh
echo $ZSH_VERSION                      # 5.9
s='--successor TERMINAL'
node -e 'console.log(process.argv.slice(1))' $s   # node: bad option: --successor TERMINAL
```

Write the three invocations out literally, or run the loop under `bash -c`.

## Live verdict (successor = task-47bc4168392dec17, the only resolving one)

```
VERDICT-TOKEN: SEAL-PREDICATE NO-SEAL a=FAIL b=FAIL c=PASS orphans=58 considering=1 \
  successor=task-47bc4168392dec17 epic=cloud-console-hardening-epic mode=live stubbed=0 waived=0
roster: 135 children  {"open":60,"done":64,"cancelled":10,"considering":1}
CLAUSE (a) forwarding — residue 61 (live 60, considering 1)
  forwarded under successor : 0
  permanent human gate      : 3
  UNNAMED RESIDUE (orphans) : 58
```

Clause (b) fails on EXACTLY ONE entry:
`CCH-D5-rate-limiter-sees-every-user-as-one (rung 3) — NO MEASUREMENT`.
Three entries sit at rung 2, all naming the identical
`.github/workflows/cloud.yml` job `test` on `cloud/**` (D2, D3, D4).

## 60 vs 61 live, 135 vs 136 children — the delta is the drafts twin

The predicate reads the PUBLISHED dataset; `bp task get` counts drafts too.

```sh
bp task get cloud-console-hardening-epic -o json | tr -d '\000-\037' | \
  python3 -c "import json,sys,collections;d=json.load(sys.stdin);print(d['child_count'],collections.Counter(c['lifecycle_status'] for c in d['children']))"
# 136 Counter({'done': 64, 'open': 61, 'cancelled': 10, 'considering': 1})

curl -sG https://guerrilla.barkpark.cloud/v1/data/query/production/task \
  --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' --data-urlencode 'limit=500' | \
  python3 -c "import json,sys,collections;d=json.load(sys.stdin);x=d['result']['documents'];print(len(x),collections.Counter(y['lifecycle_status'] for y in x))"
# 135 Counter({'done': 64, 'open': 60, 'cancelled': 10, 'considering': 1})
```

The single missing id is `drafts.gr-backlog-css-brace-detector` (filed
2026-07-30T15:17:43); its published twin `gr-backlog-css-brace-detector`
(2026-07-19) IS counted and IS an orphan. Never pair "61 live" with
"135 children" — they come from different datasets.

## Wave 8's "orphans=55" is a misquote of an OPEN count

`bp paper view cloud-console-hardening-wave-8-2026-07-30 | grep -n 55` yields
`roster 138 to 129, open 80 to 55` — an OPEN row count, not an orphan count.
No `orphans=` string appears anywhere in the wave-8 Paper or in the charter
(`grep -n "orphans=" .claude/workflows/bp-cloud-console-hardening-charter.md` -> no match).

## The three newest orphans — all filed 2026-07-30 by the wave-9 lead

```sh
# sort the live rows by inserted_at; the only 2026-07-30 published entries are:
# 15:59:56 open 0/4 cch-bl-pat-touch-not-authz-aware
# 15:59:58 open 0/4 cch-bl-ability-matrix-red-on-main
# 16:00:00 open 0/4 cch-bl-task-create-intermittent-500
```

None is a wave-8 slice shipped-and-left-open. The wave-8 clause-(b) slice
`task-43f7662b33e8e0b7` is open at 9/11 and its promise ("clause (b) can PASS")
is genuinely unmet live — b=FAIL — so its open state is HONEST, not stale.

## `cch-bl-ability-matrix-red-on-main` IS a free lead close

```sh
gh pr view 8139 --json state,mergedAt,mergeCommit
# {"state":"MERGED","mergedAt":"2026-07-30T16:46:04Z","mergeCommit":{"oid":"ce8d855167061b35ec34c95343e7c3e3cf830fca"}}
git merge-base --is-ancestor ce8d855167061b35ec34c95343e7c3e3cf830fca origin/main && echo ANCESTOR
gh run list --workflow=cloud.yml --branch=main --limit=8 \
  --json conclusion,headSha,createdAt,displayTitle
# 2026-07-30T16:46:07 success ce8d85516   <- first green after SEVEN consecutive failures
# 2026-07-30T16:25:39 failure fca9ee3a7
# 2026-07-30T16:25:29 failure f5508a6e5
# 2026-07-30T16:24:06 failure 9b78c20b2
# 2026-07-30T15:27:42 failure a8f915190
# 2026-07-30T12:57:45 failure ed61436fa
# 2026-07-30T12:52:52 failure 5ed99d9ef
# 2026-07-30T02:08:00 failure 4f046cce1
bp task get cch-bl-ability-matrix-red-on-main -o json   # lifecycle open, criteria 0/4
```

The row was filed 15:59:58 and its fix merged 16:46:04 — 46 minutes later.
Closing it drops orphans 58 -> 57 for free.
