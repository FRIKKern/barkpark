# Re-derivation recipes — ws-seal-and-dataset-validation (W10 verify, 2026-07-26)

Live-system probes. Site token below is PUBLIC BY CONSTRUCTION (shipped in the
browser bundle of `/sites/search-ember`); it is not a secret being disclosed here.

```
TOKEN=UXOvtfPOUiJF7Bw4kAz3jVW3IDyHGoLBz6Ygj7NcpnE
```

## R1 — extract the shipped token + the ONLY channel topic from the live bundle

```bash
curl -sL https://guerrilla.barkpark.cloud/sites/search-ember/ -o /tmp/ember.html
grep -oE 'src="[^"]+"' /tmp/ember.html | sed 's/src="//;s/"//' | sort -u |
  while read c; do curl -s "https://guerrilla.barkpark.cloud$c"; done |
  grep -oE 'search:[a-z]+:[a-z]+:[a-z]+|[AR]="[^"]{10,120}"'
```
Expect exactly ONE topic literal: `search:default:default:production`.
No `search:default:default:prod` exists in the deployed bundle.

## R2 — WS perspective is sealed; WS type-visibility is NOT

```bash
node /path/to/ws-probe.mjs   # see below; Node >= 22 (global WebSocket)
```
Minimal inline form:
```bash
node -e '
const T="search:default:default:production";
const ws=new WebSocket("wss://guerrilla.barkpark.cloud/socket/websocket?token=UXOvtfPOUiJF7Bw4kAz3jVW3IDyHGoLBz6Ygj7NcpnE&vsn=2.0.0");
let n=0;const P=[{q:" ",limit:5,seq:1},{q:" ",limit:5,seq:2,perspective:"drafts"},{q:" ",limit:3,seq:3,types:["session"]}];
ws.onopen=()=>ws.send(JSON.stringify(["1","1",T,"phx_join",{}]));
ws.onmessage=m=>{const[,r,,e,p]=JSON.parse(m.data);if(e!=="phx_reply")return;
 if(r!=="1"){const d=(p.response||{}).documents||[];console.log(r,"count=",p.response.count,"types=",[...new Set(d.map(x=>x._type))],"cwd=",d[0]&&d[0].cwd);}
 if(n>=P.length)return ws.close();ws.send(JSON.stringify(["1",String(n+2),T,"query",P[n++]]));};
setTimeout(()=>process.exit(0),25000);'
```

## R3 — the visibility leak needs NO token at all (HTTP twin of R2)

```bash
B=https://guerrilla.barkpark.cloud
curl -s -o /dev/null -w "query  %{http_code}\n" "$B/v1/data/query/production/session?limit=1"
curl -s -o /dev/null -w "search %{http_code} %{size_download}\n" \
  "$B/v1/data/search/production?q=%20&type=session&limit=1"
```
Expect `query 404` and `search 200 ~24786` — the asymmetry IS the finding.

## R4 — datasets rows + the site token's real permissions

```bash
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
 "sudo -u postgres psql barkpark_prod -c \"select w.slug ws,p.slug proj,d.slug ds from datasets d join projects p on p.id=d.project_id join workspaces w on w.id=p.workspace_id;\""
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
 "sudo -u postgres psql barkpark_prod -t -c \"select name,permissions,workspace_id,dataset from api_tokens where token_hash=encode(digest('$TOKEN','sha256'),'hex');\""
```

## R5 — dataset-validation blast radius (plant, measure, REVERT)

Plant in `api/lib/barkpark_web/channels/search_channel.ex` `join/3`:
```elixir
         %Tenancy.Project{} = proj <- Tenancy.get_project(ws_slug, proj_slug),
         {:dataset, %Tenancy.Dataset{}} <- {:dataset, Tenancy.get_dataset(proj, dataset)} do
...
      {:dataset, nil} -> {:error, %{reason: "unknown_dataset"}}
```
(The tagged tuple is REQUIRED — a bare `%Dataset{} <- ...` collapses into the
existing `_ -> "unauthorized"` else-branch and steals the unknown-workspace case.)

```bash
cd /Volumes/SATECHI/github/barkpark/api
for i in 1 2 3; do CC=clang mix test test/barkpark_web/channels/search_channel_test.exs 2>&1 | grep "tests, "; done
cd /Volumes/SATECHI/github/barkpark && git checkout -- api/lib/barkpark_web/channels/search_channel.ex
```
Baseline (unplanted) is FLAKY: 0/1/2/3 failures across 5 runs, all inside the
`live push on document mutation` describe. Planted: 8/11, deterministic.

## R6 — join-green-forever proof for a nonexistent dataset

Repeat R2 with `TOPIC=search:default:default:docs` and
`search:default:default:totally-bogus-xyz`: both reply `{"status":"ok"}` on join
and `count=0` on query. Today's behaviour, no error anywhere.
