# anonymous-metering W1 — live-box L1 re-derivation recipes (2026-08-08)

Verifier lane `live-box-l1`. Every row below is a command that re-derives a fact
from a RUNNING system (L1), not from repo source. Nothing here was reasoned; each
row was executed and its output quoted in the wave Paper.

Boxes: guerrilla `157.180.90.121` (Phoenix API, `guerrilla.barkpark.cloud`) ·
control plane `178.105.92.191` (`barkpark.cloud`, `www.`, **and `api.barkpark.cloud`**).
Key: `~/.ssh/barkpark_indx`. NOTE: macOS has no `timeout(1)` — use `-o ConnectTimeout=`.

## Caddy — no edge interception on either box

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cat -n /etc/caddy/Caddyfile'
    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'cat -n /etc/caddy/Caddyfile'

guerrilla: 108 lines, one host block; every `root */file_server` is inside a
`handle_path /sites/<name>/*` block; catch-all is a bare `reverse_proxy
localhost:4000` (line 91). `handle_errors` (92-107) serves a 503 maintenance
page — it does NOT rewrite upstream 404s (proven below). No `/robots.txt`
directive anywhere. CP: 3 lines, bare `reverse_proxy localhost:4101`.

    curl -s https://guerrilla.barkpark.cloud/definitely-not-a-real-path-9f3   # nested Phoenix 404 envelope, HTTP 404

## Live RequestStats payload (the 4-key shape, first observation)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'TOK=$(cat /etc/barkpark/agent.health.token); curl -s -H "Authorization: Bearer $TOK" \
       http://localhost:4000/v1/instance/request-stats'

The token is `/etc/barkpark/agent.health.token` (41 bytes), injected by the
drop-in `/etc/systemd/system/barkpark-agent.service.d/health-token.conf`.
It is NOT in `/opt/barkpark/.env` (that file holds no `*TOKEN*` key).

## Static-class emission (the D1 enum proof) — MUTATION, not reading

    ssh ... 'TOK=$(cat /etc/barkpark/agent.health.token)
      S(){ curl -s -H "Authorization: Bearer $TOK" http://localhost:4000/v1/instance/request-stats; }
      echo "BEFORE: $(S)"; for i in $(seq 1 400); do curl -s -o /dev/null http://localhost:4000/robots.txt; done
      echo "AFTER:  $(S)"'

400 static **hits** (200) move `req_per_s` not at all; 400 static **misses**
(404, `/images/nope-9f3.png`) and 400 API hits (`/api/schemas`) each move it by
~+6. Plug.Static (`endpoint.ex:56`) halts before Plug.Telemetry (`:75`).

## robots.txt / envelope re-confirmations

    diff <(git show origin/main:api/priv/static/robots.txt) <(curl -s https://guerrilla.barkpark.cloud/robots.txt)
    for p in /styleguide.html /button.svg /__preview__/mock.js /__fixtures__/event_types.json /robots.txt; do \
      printf '%-34s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' https://barkpark.cloud$p)"; done
    curl -s -w '\n%{http_code}\n' https://api.barkpark.cloud/api/schemas

The middle command is the live proof that `cloud`'s `Plug.Static` `only:`
allowlist (`cloud/lib/barkpark_cloud/web/router.ex:418` on origin/main) gates
reachability: allowlisted files 200, everything else 404 — so a `robots.txt`
dropped into `cloud/priv/static/` without the allowlist edit ships a 404.
