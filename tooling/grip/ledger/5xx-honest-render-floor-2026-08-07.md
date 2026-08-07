# Re-derivation recipes — is a D3-compliant 5xx render possible CLI-only? (wave 7 verify)

Taken 2026-08-06 22:46Z–22:55Z against the LIVE guerrilla instance and the LIVE control plane.
origin/main = ef77af2748ceda54fdd6e078f71a6e6044b55439.

## R1 — guerrilla's real 60s request volume (23 samples at 15s)

    TOK=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
    for i in $(seq 1 24); do printf "%s " "$(date -u +%H:%M:%SZ)"; \
      curl -s -H "Authorization: Bearer $TOK" https://guerrilla.barkpark.cloud/v1/instance/request-stats; echo; sleep 15; done

n = req_per_s * 60 (window_s is 60). Observed: min 58, median 90, max 647.
6 of 23 samples (26%) clear n >= 200. p95_ms is ANTI-correlated with n
(n=647 -> p95 121ms; n=58 -> p95 834ms; n=68 -> p95 1518ms).
The observer's own polling adds ~4-5 req per window, so the low-n figures are
INFLATED by the measurement; the true floor-clearance is lower, not higher.

## R2 — the epic's own reporting floor is 200 and it is a REFUSAL, not a rounding

    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | grep -n '@min_sample '
    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '534,562p'

## R3 — req_per_s / p95_ms are ABSENT from the fleet pressure block on main AND on #9888

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'req_per_s\|p95_ms'   # (only unrelated)
    git fetch -q origin pull/9888/head:refs/tmp/pr9888 --force
    git show refs/tmp/pr9888:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'req_per_s\|p95_ms'   # EMPTY

## R4 — but the denominator IS already in the stored beat payload (no agent change, no box deploy)

    python3 - <<'EOF'
    import json,os,urllib.request
    c=json.load(open(os.path.expanduser('~/.config/barkpark/config.json'))); ct=c['cloud_token']
    def get(p):
        r=urllib.request.Request("https://api.barkpark.cloud"+p, headers={"Authorization":"Bearer "+ct})
        return json.load(urllib.request.urlopen(r))
    rows=get("/v1/barkparks")["barkparks"]
    for b in rows:
        t=(get("/v1/barkparks/%s/telemetry"%b['id']) or {}).get('telemetry')
        print(b['name'], t and t.get('req_per_s'), t and t.get('p95_ms'))
    EOF

Guerrilla: req_per_s 1.83 / p95 2149. gyl, jarl, dooodo: **-1** (probe unwired).
Gyldendal: key absent. muscle-1: no telemetry at all.
/telemetry and merge_pressure read the SAME raw health payload
(router.ex:7689 Telemetry.normalize(event) vs router.ex:1851 latest_health_payload_map).

## R5 — dr-w6-s5 criterion 10 currently FORBIDS the fix

    bp task get dr-w6-s5-5xx-and-degraded-keep-the-reading -o json

Criterion 10: "zero entries under cloud/priv/static/, internal/cloudclient/ or internal/semrole/".
Adding the denominator requires internal/cloudclient/client.go (Pressure struct) and
cloud/lib/barkpark_cloud/web/router.ex. The re-brief must widen it or S3 cannot be honest.
