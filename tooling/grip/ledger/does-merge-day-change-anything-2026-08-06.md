# Does merge day change anything? — re-derivation recipes (2026-08-06, wave 6 verify)

Every row is one literal command that re-derives the fact from scratch. Run from
the repo root. SSH rows use `~/.ssh/barkpark_indx`.

## R1 — deploy.yml reaches exactly ONE box, and cmd/ reaches none

```
git show origin/main:.github/workflows/deploy.yml | grep -n "GUERRILLA_HOST\|grep -qE"
```
Expect: the `instance` regex `^(api|internal|deploy|connectors|templates)/` and a
single `$SSH "root@${GUERRILLA_HOST}"`. `cmd/` and `scripts/` are absent from the
instance regex; `scripts/` is absent from `on.push.paths` entirely.

Apply the two regexes to a candidate file set:
```
for p in cmd/barkpark-agent/main.go internal/agent/report.go scripts/apply-update.sh; do \
  echo -n "$p cp="; echo "$p" | grep -qE '^(cloud|deploy|internal|cmd)/' && echo -n true || echo -n false; \
  echo -n " instance="; echo "$p" | grep -qE '^(api|internal|deploy|connectors|templates)/' && echo true || echo false; done
```

## R2 — nothing but instance-deploy.sh rebuilds the agent

```
grep -rn "barkpark-agent" scripts/ .githooks/
```
Expect: zero output on origin/main. The only rebuild site is
`deploy/instance-deploy.sh:818`.

## R3 — which boxes carry the new vitals fields (strings proof)

```
for h in 5.75.169.183 46.224.19.120 116.203.91.216 157.180.90.121 46.225.61.223 91.98.139.58; do \
  echo -n "$h "; ssh -i ~/.ssh/barkpark_indx -o BatchMode=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$h \
  'strings -a /usr/local/bin/barkpark-agent 2>/dev/null | grep -cE "load15|cpu_cores|err_5xx_per_s"; \
   ls -l --time-style=+%F /usr/local/bin/barkpark-agent 2>/dev/null' 2>&1 | tr '\n' ' '; echo; done
```

## R4 — the live beat, per box (L1, the owner's actual data)

```
CU=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_url'])"); \
CT=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['cloud_token'])"); \
curl -s -H "Authorization: Bearer $CT" "$CU/v1/barkparks" | \
python3 -c "import sys,json;[print(b['slug'],b.get('update_state'),b.get('update_running_release'),json.dumps(b.get('pressure'))) for b in json.load(sys.stdin)['barkparks']]"
```

## R5 — the fleet is pinned to a release cut four weeks before main

```
git tag --sort=-creatordate | grep -vE '^build-' | head -6
git log -1 --format='%h %ci' v0.2.25
git rev-list --count v0.2.25..origin/main
```

## R6 — the cap has not reached the box

```
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'cd /opt/barkpark && git merge-base --is-ancestor ef77af2748ceda54fdd6e078f71a6e6044b55439 HEAD && echo CAP_PRESENT || echo CAP_ABSENT'
gh run list --workflow=deploy.yml --branch=main --limit=3 \
  --json headSha,status,conclusion,createdAt --jq '.[]|"\(.headSha[0:9]) \(.status) \(.conclusion) \(.createdAt)"'
```

## R7 — the owner's bp carries none of the wave's field names

```
bp --version
for f in cpu_cores load15 err_5xx_per_s beam_pss_bytes swap_used_percent; do \
  echo -n "$f: "; strings -a "$(which bp)" | grep -c "$f"; done
```

## R8 — the only automatic path to a customer box, end to end

```
git show origin/main:api/lib/barkpark/self_update/runner.ex | grep -n 'default_command'
git show origin/main:scripts/self-update.sh | grep -n 'exec bash'
git grep -n 'EnsureFresh' origin/main -- internal/ cloud/ cmd/ | grep -v _test
git show origin/main:api/lib/barkpark/self_update/checker.ex | sed -n '12,16p'
```
Expect: `bash scripts/self-update.sh` → `exec bash scripts/deploy-rebuild.sh`;
every `EnsureFresh` call site is provision-time (support.go:147 configureHost,
warmpool.go:1275, provisioner/warmpool.go:131) — none is periodic; and `:behind`
is decided by an A.B.C semver release comparison, not by main.
