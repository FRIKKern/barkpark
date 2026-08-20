# live-host-truths — self-host-blessing wave 1 (2026-08-08)

Two probes for wave 1: (1) does the guerrilla BEAM really see the 64-byte
SECRET_KEY_BASE that was measured in `/opt/barkpark/.env`, or can a unit-level
override shadow it; (2) what does docker compose do when ONE `environment:` list
carries both `- KEY=value` and a bare `- KEY`.

## 1. Guerrilla: the BEAM's real environ (L1)

The slot unit does NOT read `/opt/barkpark/.env`. It reads a per-slot file:

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'systemctl cat barkpark-slot@* 2>/dev/null | grep -n -i environment'

    30:Environment=LANG=C.UTF-8
    31:EnvironmentFile=/opt/barkpark/.slots/%i.env
    41:EnvironmentFile=/opt/barkpark/.release-capture.env

`/opt/barkpark/.slots/blue.env` holds only `BARKPARK_PORT_OVERRIDE`,
`MIX_BUILD_ROOT`, `BARKPARK_SITE_DEPLOY_APPLY` — no secrets. The secrets arrive
one layer down: `ExecStart=/opt/barkpark/api/start.sh`, whose lines 13-16 do
`if [ -f ../.env ]; then set -a; source ../.env; fi`. So `.env` IS the source,
but by SHELL SOURCING inside ExecStart, not by `EnvironmentFile=`.

Do not trust the file — read the process. Authoritative re-derivation:

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'P=$(systemctl show -p MainPID --value barkpark-slot@blue.service);
       tr "\0" "\n" < /proc/$P/environ |
       grep -E "^(SECRET_KEY_BASE|BARKPARK_KEK)=" |
       while IFS= read -r l; do k=${l%%=*}; v=${l#*=}; echo "$k len=${#v}"; done'

    BARKPARK_KEK len=44
    SECRET_KEY_BASE len=64

MEASUREMENT TRAP (bit me on the first pass): `while IFS== read k v` eats the
base64 `=` padding and reports KEK as 43. Split with `${l%%=*}` / `${l#*=}`
under a DEFAULT IFS, never with `IFS==`. KEK decodes to exactly 32 bytes:

    K=$(grep -E "^BARKPARK_KEK=" /opt/barkpark/.env | cut -d= -f2-)
    printf %s "$K" | base64 -d | wc -c   # => 32

## 2. CP compose oracle: duplicate key in one environment list

Scratch dir, `docker compose config` only, removed after. Docker Compose v5.2.0.

    D=/tmp/vfy$$; mkdir -p $D; cd $D
    printf "services:\n  a:\n    image: busybox\n    environment:\n      - K=assigned\n      - K\n  b:\n    image: busybox\n    environment:\n      - K\n      - K=assigned\n" > compose.yaml
    docker compose config          # host K unset
    K=from_host docker compose config
    cd /; rm -rf $D

LAST-WINS, silently — no error, no warning, either direction:

| list order | host K unset | host K=from_host |
|---|---|---|
| `- K=assigned` then `- K` | `K: null` | `K: from_host` |
| `- K` then `- K=assigned` | `K: assigned` | `K: assigned` |

And `null` means ABSENT in the container, not empty string:

    command: ["sh","-c","echo K=[$${K-UNSET_IN_CONTAINER}]"]
    docker compose run --rm a          # => K=[UNSET_IN_CONTAINER]
    K=from_host docker compose run --rm a  # => K=[from_host]

CONSEQUENCE FOR S1: appending a bare `- KEY` BELOW an existing `- KEY=value`
silently destroys the assignment. Never add bare lines for keys that keep an
assignment (root compose: DATABASE_URL, SECRET_KEY_BASE, PHX_HOST, PORT; cloud:
DATABASE_URL, PORT, POOL_SIZE, OAUTH_BASE_URL, SMTP_HOST/PORT/VERIFY_PEER,
MAIL_FROM_*, TRUSTED_PROXY_PEERS). The grep-proof script should REFUSE a
duplicate key within one `environment:` list rather than assume an order.

No intra-list duplicate exists on origin/main today (the SMTP_USERNAME /
SMTP_PASSWORD pairs in cloud/docker-compose.yml are CROSS-SERVICE — the
`x-control-plane` anchor vs the `postfix` service — which is correct and
intentional per the comment there). This is a prospective trap, not a live bug:

    for f in docker-compose.yml cloud/docker-compose.yml; do
      git show origin/main:$f | awk '/environment:/{inb=1;delete s;next}
        inb && /^[^ ]|^  [a-z]/{inb=0}
        inb && match($0,/- [A-Z_]+/){k=substr($0,RSTART+2,RLENGTH-2);
          if(k in s) print FILENAME" DUP "k; s[k]=1}'
    done
