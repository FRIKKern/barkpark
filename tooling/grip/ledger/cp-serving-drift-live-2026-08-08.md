# cp-serving-drift-live — re-derivation recipe (2026-08-08)

Wave 20 / leg A. Answers: **what sha is barkpark.cloud actually serving, and how far from origin/main?**
Measured 2026-08-08 ~00:00Z. Answer that day: **drift = 0 commits**, proven at three layers.

## 1. Box checkout vs origin/main

```sh
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  'cd /opt/barkpark && git rev-parse HEAD && git log -1 --format=%cI && git status --porcelain'
git fetch origin -q && git rev-parse origin/main
git rev-list --count <BOX_HEAD>..origin/main    # = the drift number
```

## 2. Which container is actually behind Caddy

```sh
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  'docker ps -a --format "{{.Names}} | {{.Status}} | {{.Ports}}"; grep -n reverse_proxy /etc/caddy/Caddyfile'
```
Blue/green: the Caddyfile port (4100/4101) is slot truth; the other slot container is left Exited for rollback.

## 3. Identity of the code INSIDE the running slot (the layer with no version surface)

The release reports `0.1.0` forever (`/app/releases/start_erl.data`), carries no sha env var and no
image label — `docker inspect` cannot answer this. Two probes that can:

a) **Asset layer — byte identity over the wire:**
```sh
curl -s https://barkpark.cloud/app.js | md5sum
git show origin/main:cloud/priv/static/app.js | md5sum      # must match
git show origin/main~1:cloud/priv/static/app.js | md5sum    # must DIFFER (else the probe is inert)
```

b) **Compiled layer — RPC the running BEAM for a string the head commit changed:**
```sh
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  'docker exec cloud-control_plane_blue-1 /app/bin/barkpark_cloud rpc "IO.puts(BarkparkCloud.FailureCopy.domain_stage_remediation(\"platform\", \"points_here\"))"'
```
Compare to `git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex`.

**INERT PROBE — do not use:** `grep`/`strings` on a `.beam` for a source string literal. Literals live in
the compressed `LitT` chunk; the grep returns 0 for a string that IS present. Verified: `grep -ac Elixir`
= 2 (atom table readable) while `grep -ac "re-attach the domain."` = 0 on the same file that the RPC
above proves contains it. A 0 here means nothing.

## 4. The outer smoke's blind spot

`/` is `send_file(200, priv/static/index.html)` (router.ex `get("/", do: send_dashboard(conn))`) — zero
DB in the path. `.github/workflows/deploy.yml` "Smoke test" accepts `^(200|301|302|404)$` with no
DB-touching backstop, so it cannot fail on a DB-dead box. Live: any bogus path returns 404, which the
regex accepts.
```sh
curl -s -o /dev/null -w '%{http_code}\n' https://barkpark.cloud/definitely-not-a-route-xyz   # 404 → smoke PASSES
```
`deploy/cp-deploy.sh` (pre-flip, on the box) DOES have the backstop — a bad-creds
`POST /v1/auth/login` must answer 401 (cp-deploy.sh :133-141). The workflow-level smoke does not.

## 5. Where the sha goes today

`cp-deploy.sh:214` `log "DONE — … live at $(git rev-parse --short HEAD)"`, and `log()` is
`echo` to stdout (cp-deploy.sh:25) — no tee, no file. The sha exists only in a GitHub Actions job log.
```sh
git show origin/main:deploy/cp-deploy.sh | grep -n 'tee\|>> */var\|LOGFILE'   # empty
```
