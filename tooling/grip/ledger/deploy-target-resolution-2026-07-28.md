# `bp cloud deploy <target>` — which box, and can it answer the read-back? — 2026-07-28 (wave verifier: v2-deploy-target-resolution)

**VERDICT: UNPERFORMABLE is the PRIMARY outcome today, but NOT for the reason the direction
predicted.** There is no default target — `<target>` is a required positional, and the only
names that resolve are the 4 control-plane fleet rows. Of those 4, **3 serve a `/status.json`
with the `commit` key ENTIRELY ABSENT** (pre-`c73f22a0b` builds) and only **guerrilla** carries
a sha. `staging`, `prod`, a bare IP and `barkpark.cloud` all fail host resolution outright
(exit 2, usage error) — they were never deployable by name.

**The `--host` escape hatch manufactures a THIRD failure mode nobody filed:** with `--host`,
`healthHost` is *invented* from the target string (`deriveHealthHost`: FQDN verbatim if it
contains a dot, else `<target>.barkpark.cloud`). `bp cloud deploy prod --host 89.167.28.206`
health-hosts `prod.barkpark.cloud`, which **does not resolve** (curl http=000). The on-box gate
still passes, because `instance-deploy.sh:258,793` curls with `--resolve "${HEALTH_HOST}:443:127.0.0.1"`
— it bypasses public DNS. A CLI read-back over public DNS does not. So the box's own health
gate and the CLI's read-back do NOT see the same name.

**Control plane: never a legitimate deploy target.** `barkpark.cloud` → 178.105.92.191, a
distinct box from every fleet row, deployed by `deploy/cp-deploy.sh` (docker-compose blue/green),
not `instance-deploy.sh`. It has no fleet row, so it cannot resolve by name; `/status.json` is
**404**; `/health` and `/up` return only `{"db":"up","checked_at":…}` — no commit, no version.
Structurally unbackable, and forcing it via `--host` would run the *instance* deploy script on
the *control-plane* box.

**Refinement to the briefed 3 sub-states:** ABSENT is live (3 boxes) and UNREACHABLE is live
(the `--host`/invented-FQDN path). The legal string `"unknown"` was **not observed on any
reachable target** — `status.ex:95-107` documents "Never nil, never absent", so a post-dependency
build always emits *something*.

| Claim | Result | Re-derivation command |
|---|---|---|
| No default target; `<target>` required | usage error, exit 2 | `bp cloud deploy --dry-run` |
| Only 4 names resolve, all via control-plane | 4 rows | `bp cloud status -o json` |
| `staging` / `prod` / IP / `barkpark.cloud` unresolvable | `can't resolve a host for "…"` | `for t in prod staging 89.167.28.206 barkpark.cloud; do bp cloud deploy "$t" --dry-run -o json; done` |
| 3 of 4 fleet boxes have `commit` ABSENT | gyldendal/muscle-1/dooodo absent; guerrilla `a8c767dbd` | `for u in gyldendal-506f035e muscle-1 dooodo guerrilla; do curl -s https://$u.barkpark.cloud/status.json \| python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('commit','<ABSENT>'),d['version'])"; done` (gyldendal's host is `gyldendal-506f035e`) |
| The router's prod box also lacks `commit` | key absent, version 0.2.25.1871 | `curl -s http://89.167.28.206/status.json \| head -c 300` |
| Absent ⇒ pre-dependency build (never nil/absent after) | doc + `"unknown"` fallback | `git show origin/main:api/lib/barkpark/status.ex \| sed -n '95,107p'` |
| Dependency really shipped | ancestor, dated 2026-07-28 | `git merge-base --is-ancestor c73f22a0b origin/main && git log -1 --oneline c73f22a0b` |
| `--host` invents healthHost from the target name | `health_host=prod.barkpark.cloud` | `bp cloud deploy prod --host 89.167.28.206 --dry-run -o json` |
| …and that name does not resolve | http=000 | `curl -s -m 10 -o /dev/null -w 'http=%{http_code}\n' https://prod.barkpark.cloud/status.json` |
| An IP target yields `https://<ip>` (TLS fails) | `health_host=89.167.28.206`, http=000 | `bp cloud deploy 89.167.28.206 --host 89.167.28.206 --dry-run -o json; curl -s -m 10 -o /dev/null -w 'http=%{http_code}\n' https://89.167.28.206/status.json` |
| On-box gate bypasses DNS via `--resolve` | `--resolve "${HEALTH_HOST}:443:127.0.0.1"` | `grep -n 'resolve' deploy/instance-deploy.sh \| head` |
| CP is a different box, different deployer, 404 on status.json | 178.105.92.191; `/status.json` 404; `/health` = db only | `dig +short barkpark.cloud A; curl -s -o /dev/null -w '%{http_code}\n' https://barkpark.cloud/status.json; curl -s https://barkpark.cloud/health` |
