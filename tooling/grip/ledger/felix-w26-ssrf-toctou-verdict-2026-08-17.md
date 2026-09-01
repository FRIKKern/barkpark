<!-- doc-tier: cold | canonical-for: none | budget: 800tok -->
# Felix W26 — SafeOutbound DNS-rebinding TOCTOU verdict (re-derivation recipe)

> HISTORICAL RECORD (2026-08-17) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

VERDICT: **REAL** (not prove-clean). The check-time resolved IP is NOT pinned into the request; Finch re-resolves the hostname at connect time.

## Re-derive from scratch (origin/main)

```
# 1. The ONLY runtime caller of the guard (webhook dispatcher via ReqAdapter):
grep -rn 'check_url\|SafeOutbound.post' api/lib | grep -v safe_outbound.ex
#   -> api/lib/barkpark/webhooks/dispatcher.ex:1039 (sole caller)

# 2. post/2 hands the RAW URL string to Req.post — no pinned IP, no transport_opts, no :hostname:
git show origin/main:api/lib/barkpark/net/safe_outbound.ex | sed -n '52,58p'
#   def post(url, opts) -> Req.post(url, Keyword.put(opts, :redirect, false))
#   check_url resolves via :inet.getaddrs then DISCARDS the addresses (lines 107-138)

# 3. dispatcher passes only body/headers/receive_timeout — no connect pinning:
sed -n '1039,1047p' api/lib/barkpark/webhooks/dispatcher.ex

# 4. Guard active in prod (escape hatch true only dev/test):
grep -rn 'allow_private_outbound' api/config
#   dev.exs:94 true, test.exs:126 true; prod default false (safe_outbound.ex:182)

# 5. No test pins the resolved IP — suite only covers ip_allowed?/check_url shape:
cd api && mix test test/barkpark/net/safe_outbound_test.exs   # 13 tests, 0 failures
```

## Failure mode
DNS-rebinding TOCTOU (check-then-connect gap). `check_url/1` resolves+classifies the host,
but the winning IP is thrown away; `Req.post(url)` gives the raw hostname to Finch (Req.Finch
default pool), which performs an INDEPENDENT resolution at connect. Attacker controlling DNS
for the webhook host (low TTL) serves a public A record to the guard lookup and a private one
(169.254.169.254 / 127.0.0.1:4000 / RFC1918) to the Finch connect -> blind SSRF, exactly what
the moduledoc + webhook.ex:101 comment claim to prevent ("rebind protection" — currently false).

## Improvement-only-safe fix shape (confined to net/safe_outbound.ex — dispatcher untouched)
Have check_url return the validated IP; connect to that literal IP while preserving the original
host for SNI (`server_name_indication`) + Host header. Lives entirely in `SafeOutbound.post/2`,
which is NOT fence-hot; the fence-hot webhooks dispatcher already routes through it and needs no edit.
