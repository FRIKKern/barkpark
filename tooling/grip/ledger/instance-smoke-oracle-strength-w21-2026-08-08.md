# Re-derivation recipes — instance-smoke oracle strength (deploy-reliability wave 21)

Taken 2026-08-08, repo `FRIKKern/barkpark`, deploy.yml workflow id `304821157`.
Every row is a literal command. Nothing here is committed by me; Decide commits it.

## 1. Bad-creds 401 probe transplants to guerrilla unchanged

```
curl -s -o /dev/null -w '%{http_code}\n' --max-time 15 -X POST \
  -H 'content-type: application/json' \
  -d '{"email":"deploy-smoke-probe@invalid.example","password":"x"}' \
  https://guerrilla.barkpark.cloud/v1/auth/login
```
→ `401`. Same predicate the CP smoke now asserts (deploy.yml control-plane job).

## 2. /api/schemas is a real DB probe (Repo.all), public, un-authenticated

```
git show origin/main:api/lib/barkpark_web/router.ex | sed -n '2606,2610p'
git show origin/main:api/lib/barkpark_web/controllers/legacy_controller.ex | sed -n '109,123p'
git show origin/main:api/lib/barkpark/content/schema.ex | sed -n '83,104p'
curl -sI --max-time 20 https://guerrilla.barkpark.cloud/api/schemas | grep -i '^via:'
```
Route pipes through `[:api, LegacyDeprecation]` only — no `:require_token`.
`via: 1.1 Caddy` proves the outer probe traverses the edge.

## 3. Full-history failing job/step census for deploy.yml

```
wid=304821157
gh api "repos/FRIKKern/barkpark/actions/workflows/$wid/runs?status=failure&per_page=1" --jq '.total_count'
for p in 1 2; do gh api "repos/FRIKKern/barkpark/actions/workflows/$wid/runs?status=failure&per_page=100&page=$p" --jq '.workflow_runs[].id'; done | sort -u > allfails.txt
while read -r id; do gh api "repos/FRIKKern/barkpark/actions/runs/$id/jobs?per_page=100" \
  --jq ".jobs[]|select(.conclusion==\"failure\")|[\"$id\",.name,((.steps//[])|map(select(.conclusion==\"failure\")|.name)|join(\";\"))]|@tsv"; done < allfails.txt \
  | awk -F'\t' '{print $2" || "$3}' | sort | uniq -c | sort -rn
```
→ 89 `control-plane || Deploy control plane over SSH`, 25 `instance || Deploy content instance over SSH`, **1** `instance || Smoke test`.

## 4. The one instance-smoke firing, and its silence

```
gh api "repos/FRIKKern/barkpark/actions/runs/30686555528" --jq '[.created_at,.head_sha[0:9],.conclusion,.display_title]|@tsv'
gh api "repos/FRIKKern/barkpark/actions/runs/30686555528/jobs?per_page=100" --jq '.jobs[]|[.name,.conclusion]|@tsv'
gh api "repos/FRIKKern/barkpark/actions/jobs/91333459978/logs" | grep -i 'guerrilla /api/schemas'
```
→ 2026-08-01T05:49:12Z, `0679c5dcb`, `guerrilla /api/schemas = 500`.
Jobs present: `changes/success`, `instance/failure`, `control-plane/success` — **no
`report-deploy-failure` job existed yet**, so the oracle's only true positive in repo
history reported to nobody.

## 5. Denominator — how often the step actually runs

```
wid=304821157
gh api "repos/FRIKKern/barkpark/actions/workflows/$wid/runs?per_page=100&page=1" --jq '.workflow_runs[].id' > recent100.txt
while read -r id; do gh api "repos/FRIKKern/barkpark/actions/runs/$id/jobs?per_page=100" \
  --jq '.jobs[]|select(.name=="instance")|((.steps//[])|map(select(.name=="Smoke test")|.conclusion)|join(","))'; done < recent100.txt | sort | uniq -c
```
→ 100 runs sampled, 49 instance jobs, **21 `success`, 28 empty** (smoke never reached).

## 6. Mutation proof — the smoke passes on an EMPTY catalog

```
python3 - <<'EOF' &
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b=b"[]"
        self.send_response(200); self.send_header("content-type","application/json")
        self.send_header("content-length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",8791),H).serve_forever()
EOF
sleep 1
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:8791/api/schemas")"
echo "guerrilla /api/schemas = $code"; test "$code" = "200" && echo "SMOKE PASSES ON []"
```
→ `guerrilla /api/schemas = 200` / `SMOKE PASSES ON []`. Only the URL differs from
deploy.yml:178-180; the predicate is verbatim.

## 7. Inner gate vs outer smoke — NOT the same probe

```
git show origin/main:deploy/instance-deploy.sh | sed -n '739,743p'   # inner: http://localhost:$TARGET_PORT
git show origin/main:deploy/instance-deploy.sh | sed -n '793,795p'   # post-flip public curl — LOGGED, never asserted
git show origin/main:deploy/instance-deploy.sh | sed -n '311,316p'   # coalesce: exit 0 without moving
```
Inner gate = direct-to-slot, pre-flip. Outer smoke = public HTTPS through Caddy, and is
the ONLY place the post-flip public predicate is ever asserted.
