# Re-derivation recipe — beat-carries-new-vitals (2026-08-06, wave 4 verify)

Verdict: the restart CURES emission and ingest. All four #9784 fields reach the
control plane and are stored raw. There IS a second, independent break the
restart does not cure: the CP fold (`Telemetry.normalize/1` + `Metrics.@vitals`)
drops every one of them. Slice zero = deploy fix AND a CP fold.

## 1. The running agent predates #9784 (pre-restart state)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'systemctl show barkpark-agent -p ExecMainStartTimestamp -p MainPID; \
       ls -l --time-style=full-iso /usr/local/bin/barkpark-agent; \
       ls -l /proc/$(systemctl show barkpark-agent -p MainPID --value)/exe'

The running `/proc/<pid>/exe` reads `-> /usr/local/bin/barkpark-agent (deleted)`
whenever the binary was rebuilt without a restart. That `(deleted)` marker is the
whole finding in one string.

## 2. Field presence: on-disk binary vs running process

NOTE: `strings ... | grep -c '^field$'` returns 0 even when the field IS present
— Go packs struct tags into one contiguous blob, so anchors never match. Use
unanchored:

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'for f in swap_used_percent swap_total_bytes beam_pss_bytes pg_top_relations; do
         printf "disk %s=" "$f"; strings -n 6 /usr/local/bin/barkpark-agent | grep -c "$f";
         printf "proc %s=" "$f"; strings -n 6 /proc/<MAINPID>/exe        | grep -c "$f";
       done'

## 3. The health-token drop-in ALREADY EXISTS — a bare restart is safe

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'systemctl cat barkpark-agent'

`/etc/systemd/system/barkpark-agent.service.d/health-token.conf` overrides
ExecStart with `/bin/sh -c '... --health-token "$(cat /etc/barkpark/agent.health.token)"'`.
The committed unit's missing flag is therefore NOT drift that a restart exposes.

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'systemctl daemon-reload && systemctl restart barkpark-agent'

## 4. Raw payload at the control plane (the decisive read)

`GET /v1/barkparks/:id/events` serializes `payload: e.payload` UNFILTERED
(router.ex `event_json/1`). This is the only surface where the new fields are
visible at all.

    TOK=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.config/barkpark/config.json")))["cloud_token"])')
    curl -s -H "Authorization: Bearer $TOK" \
      'https://api.barkpark.cloud/v1/barkparks/b2b81e69-c79c-4eff-b6d7-84507d15b925/events?limit=12' \
      | python3 -c 'import sys,json
for e in reversed(json.load(sys.stdin)["events"]):
    p=e["payload"]
    print(e["inserted_at"], p.get("swap_used_percent","ABSENT"), p.get("beam_pss_bytes","ABSENT"))'

Cutover is exact: ABSENT through 11:44:56Z, restart 11:45:19Z, PRESENT from
11:45:23Z onward.

## 5. The fold that drops them

    git show origin/main:cloud/lib/barkpark_cloud/telemetry.ex   # normalize/1, fixed envelope
    git show origin/main:cloud/lib/barkpark_cloud/metrics.ex     # @vitals, 4-tuple
    git grep -n -E "swap_used_percent|beam_pss_bytes|pg_top_relations" origin/main -- cloud/ internal/cli/

The last grep returns ZERO hits outside `internal/agent/report.go`.

    bp cloud instance top guerrilla -o json | python3 -c 'import sys,json;print(sorted(json.load(sys.stdin)["series"]))'
    # => ['cpu', 'disk', 'load', 'mem']

## 6. Why the restart never happens on its own

    git show origin/main:deploy/instance-deploy.sh | sed -n '815,855p'

Line 821 `systemctl enable --now barkpark-agent` does not re-exec an active unit.
Line 851-853 (barkpark-mcp, 30 lines below) is the correct precedent and
documents the reason in its own comment.

Latent second mechanism (NOT the cause here): deploy.yml's instance filter is
`^(api|internal|deploy|connectors|templates)/` and excludes `cmd/`. #9784 touched
`internal/agent/report.go` so it DID deploy; a cmd/-only agent change would not.
