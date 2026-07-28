# Re-derivation recipes — site-spawner W8 / node-bare-path-blast-radius (2026-07-28)

Subject: the `/sites/<slug>` bare-path 404 on guerrilla (157.180.90.121), its blast
radius, the basePath 308-loop trap, and the search-capstone `curl 000`.

| subject | quantity | rerun | level |
|---|---|---|---|
| guerrilla site dirs | count=10 | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'ls /opt/barkpark/sites/'` | L1 |
| guerrilla Caddy site blocks | count=8 | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'grep -c BARKPARK_SITE_ROUTE /etc/caddy/Caddyfile'` | L1 |
| bare-vs-slash matrix (10 sites) | http codes | `for s in astro-search live-auto next-capstone next-proof nodeproof-20260718-73191 perfect-demo-2 perfect-proof search search-capstone search-ember; do printf '%-28s bare=' $s; curl -s -o /dev/null -w '%{http_code}' -m 20 "https://guerrilla.barkpark.cloud/sites/$s"; printf ' slash='; curl -s -o /dev/null -w '%{http_code}\n' -m 20 "https://guerrilla.barkpark.cloud/sites/$s/"; done` | L1 |
| static engine emits NO bare-path redir | grep miss | `git show origin/main:deploy/site-deploy.sh \| grep -n 'redir @\|bare_'` | L2 |
| node engine emits redir (non-basePath) / abstains (basePath) | lines 262,277,294 | `git show origin/main:deploy/site-deploy-node.sh \| sed -n '258,300p'` | L2 |
| arm is marker-guarded, never re-armed | `grep -q "$marker" ... return 0` | `git show origin/main:deploy/site-deploy.sh \| sed -n '1150,1165p'` | L2 |
| next-capstone block predates the fix | oldest release 2026-07-15 15:22 UTC; #3382 merged 2026-07-15, #3510 2026-07-16 | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'ls -1t --full-time /opt/barkpark/sites/next-capstone/releases \| tail -3'` | L1 |
| bare path falls through to Phoenix, not Caddy | Barkpark API `not_found` JSON w/ request_id | `curl -s -m 15 "https://guerrilla.barkpark.cloud/sites/astro-search" \| head -c 200` | L1 |
| basePath sites 308 slash -> bare (loop trap) | `redirect=…/sites/search-capstone` | `curl -s -o /dev/null -w 'code=%{http_code} redirect=%{redirect_url}\n' -m 20 "https://guerrilla.barkpark.cloud/sites/search-capstone/"` | L1 |
| basePath SSR TTFB ~6.5-9.2s (the `000`) | exit 28 at `-m 5` | `curl -s -o /dev/null -w 'code=%{http_code}\n' -m 5 "https://guerrilla.barkpark.cloud/sites/search-capstone"` | L1 |
| non-basePath SSR TTFB ~1.1s | t=1.08 / 1.23 | `curl -s -o /dev/null -w '%{time_total}\n' -m 25 "https://guerrilla.barkpark.cloud/sites/next-proof/"` | L1 |
| `search` orphan: 628M, unit FAILED (not running) | `ExecMainStatus=143`, ActiveState=failed | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'du -sh /opt/barkpark/sites/search; systemctl is-active barkpark-site@search__a.service'` | L1 |
| charter carries NO bare-path decision | 0 hits | `grep -c 'bare path\|bare-path\|trailing slash' .claude/workflows/bp-cloud-site-spawner-charter.md` | L2 |
