# Re-derivation recipes — "can this box deploy sites?" and who may honestly answer it

Wave 15 verifier lane `capability-producer`, 2026-08-07. Every row is a single command
that re-derives the fact from scratch. No conclusions here — see the wave Paper.

## R1 — `/v1/capabilities` does NOT advertise the site-deploy seam (live, L1)

```
curl -s https://guerrilla.barkpark.cloud/v1/capabilities \
  -H "Authorization: Bearer $(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);s=json.dumps(d);print('site_deploy' in s,'SITE_DEPLOY' in s);print(sorted(d.keys()));print([n['name'] for n in d['nouns']]);print([c['id'] for c in d['commands'] if 'site' in c['id'] or 'deploy' in c['id']])"
```

Expect: `False False` · 7 root keys · 25 nouns, none `site` · empty command list.
Caller tier is `admin`, so this is not a projection artifact.

## R2 — a `site_deploy` ROOT key bricks every released bp (mutation proof, no repo write)

Uses `go test -overlay` so the probe file never lands in the tree.

```
D=$(mktemp -d)
curl -s https://guerrilla.barkpark.cloud/v1/capabilities -H "Authorization: Bearer $(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")" > $D/live.json
python3 -c "import json;d=json.load(open('$D/live.json'));json.dump(d,open('$D/base.json','w'));d2=dict(d);d2['site_deploy']={'enabled':True};json.dump(d2,open('$D/mut.json','w'))"
cat > $D/probe_test.go <<EOF
package manifest
import ("os";"testing")
func TestProbe(t *testing.T){for _,f:=range []string{"base.json","mut.json"}{b,_:=os.ReadFile("$D/"+f);_,e:=Parse(b);t.Logf("PROBE %s -> err=%v",f,e)}}
EOF
printf '{"Replace":{"/Volumes/SATECHI/github/barkpark/internal/manifest/zz_probe_test.go":"%s/probe_test.go"}}' $D > $D/overlay.json
go test ./internal/manifest/ -overlay $D/overlay.json -run TestProbe -v
```

Expect: `base.json -> err=<nil>` and `mut.json -> err=parse manifest: json: unknown field "site_deploy"`.

## R3 — the enabled? guard is a pure app-env read, no GenServer call

```
git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '316,323p'
git show origin/main:api/lib/barkpark_web/controllers/site_deploy_controller.ex | sed -n '69,77p'
git show origin/main:api/config/runtime.exs | sed -n '960,968p'
```

## R4 — GET /v1/admin/site-deploy is NOT a capability oracle (live)

```
curl -s -w "\nHTTP %{http_code}\n" "https://guerrilla.barkpark.cloud/v1/admin/site-deploy?slug=probe-nonexistent-xyz" \
  -H "Authorization: Bearer $TOK"
```

Expect `HTTP 200` with `"state":"idle"` — the status action has no `enabled?` guard,
so it answers identically on a box that cannot deploy at all.

## R5 — the agent→BEAM probe precedent already ships and is live

```
git show origin/main:internal/agent/report.go | sed -n '620,700p'
git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1613,1622p'
curl -s -w "\nHTTP %{http_code}\n" https://guerrilla.barkpark.cloud/v1/instance/request-stats -H "Authorization: Bearer $TOK"
```

## R6 — the whole agent report lands as jsonb, zero migration

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1314,1318p'
```

`Registry.record_event(barkpark, "health", report)` — the full body.

## R7 — guerrilla's agent is rebuilt on every platform deploy; other boxes wait on a release

```
git show origin/main:deploy/instance-deploy.sh | sed -n '808,826p'
bp task get dr-bl-w6-cut-and-bless-v0-2-26 -o json | head -c 2500
```

## R8 — git_commit is on the wire and in -o json, but not in `bp cloud status`

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n git_commit
git show origin/main:internal/cloudclient/client.go | sed -n '93p'
git show origin/main:internal/cli/cloud12_cmd.go | sed -n '642,663p;678,682p'
bp cloud status -o json | python3 -c "import sys,json;print(sorted(json.load(sys.stdin)['barkparks'][0].keys()))"
```
