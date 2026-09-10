# dr-w25 — what actually serves `gyldendal.barkpark.cloud`, probed 2026-09-10

Task: `dr-w25-bl-gyldendal-taker-is-also-a-ghost`. Read-only probes from a
workstation, 2026-09-10 22:45–22:46 UTC. No box write, no DB write, no DNS change,
no de-registration. No secrets, tokens or cookies appear below — every request is
unauthenticated.

## THE HEADLINE

**The "abandoned ghost" is a continuously serving, cert-renewing customer
instance.** The box behind `gyldendal.barkpark.cloud` reports **64.5 days of
unbroken uptime**, `operational` on database + migrations + plugins, and holds a
Let's Encrypt certificate **issued 2026-09-05** — i.e. the platform's own
`/v1/tls/ask` gate authorised issuance for that name five days ago. `last_seen_at
IS NULL` describes the AGENT, not the APP, and here the two disagree completely.

## 1. DNS + who owns the address

```
$ date -u +"%Y-%m-%dT%H:%M:%SZ"
2026-09-10T22:45:02Z

$ dig +short gyldendal.barkpark.cloud
116.203.98.0

$ dig +short -x 116.203.98.0
static.0.98.203.116.clients.your-server.de.

$ whois 116.203.98.0 | grep -Ei '^(netname|descr|country|inetnum):'
inetnum:      116.0.0.0 - 116.255.255.255
inetnum:        116.202.0.0 - 116.203.255.255
netname:        STUB-116-202SLASH15
descr:          Transferred to the RIPE region on 2018-08-28T00:42:30Z.
country:        ZZ
```

DNS still points the contested name at **116.203.98.0**, a Hetzner
(`your-server.de`) address — the same address every prior charter entry records.
Nothing has moved.

## 2. What answers, and whether it is a Barkpark

```
$ curl -sI https://gyldendal.barkpark.cloud/
HTTP/2 302
alt-svc: h3=":443"; ma=2592000
cache-control: max-age=0, private, must-revalidate
content-security-policy: base-uri 'self'; frame-ancestors 'self';
content-type: text/html; charset=utf-8
date: Thu, 10 Sep 2026 22:45:07 GMT
location: /w/default/p/default/d/production/studio
referrer-policy: strict-origin-when-cross-origin
via: 1.1 Caddy
x-content-type-options: nosniff
x-request-id: GNQXD8CWvjqdnNIACwzB
content-length: 106

$ curl -sI --resolve gyldendal.barkpark.cloud:443:116.203.98.0 https://gyldendal.barkpark.cloud/
HTTP/2 302
... identical, location: /w/default/p/default/d/production/studio, via: 1.1 Caddy
x-request-id: GNQXD8ZX8aidnNIACwzR
```

Pinned and unpinned agree, so DNS is not lying: **116.203.98.0 is the server**.
`via: 1.1 Caddy` and the `/w/<ws>/p/<proj>/d/<dataset>/studio` redirect shape are
Barkpark's own.

```
$ curl -sI https://gyldendal.barkpark.cloud/w/default/p/default/d/production/studio
HTTP/2 302
location: /login?return_to=%2Fw%2Fdefault%2Fp%2Fdefault%2Fd%2Fproduction%2Fstudio

$ curl -s -o /dev/null -w "%{http_code}\n" https://gyldendal.barkpark.cloud/api/schemas
200
```

Auth gate present, content API answering. It is a Barkpark, not a parked page.

## 3. The body: a healthy, long-running instance

```
$ curl -s https://gyldendal.barkpark.cloud/status.json
{"status":"operational","version":"0.2.24.1","components":[
 {"name":"database","status":"operational"},
 {"name":"migrations","status":"operational"},
 {"name":"plugins","status":"operational"}],
 "checked_at":"2026-09-10T22:45:15.773439Z",
 "sla":{...},"uptime_seconds":5568983,"incidents":[]}

$ curl -s https://gyldendal.barkpark.cloud/health
HTTP 404 (this build serves /status.json, not /health)
```

`uptime_seconds` **5,568,983 = 64.46 days**. Subtracted from the read at
22:45:15Z that puts the process start at **2026-07-08 ≈ 11:48:52 UTC** — within
about twenty seconds of the attach job row the charter dates at **11:48:34 UTC**
(D443). The box came up at provisioning and has not restarted since.

`version` is `0.2.24.1` while the fleet's other boxes run `0.2.25.x` / `0.2.26`.
Autoupdate is agent-driven, so a stale release is exactly what a live app with a
dead agent looks like — and it is the strongest single corroboration that
`last_seen_at IS NULL` here means "agent never installed/started", not "box gone".

## 4. TLS — the decisive fact

```
$ openssl s_client -connect 116.203.98.0:443 -servername gyldendal.barkpark.cloud \
    </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates
issuer= /C=US/O=Let's Encrypt/CN=YE1
subject= /CN=gyldendal.barkpark.cloud
notBefore=Sep  5 14:18:34 2026 GMT
notAfter=Dec  4 14:18:33 2026 GMT

$ ... | openssl x509 -noout -text | grep -A2 "Subject Alternative Name"
    X509v3 Subject Alternative Name:
        DNS:gyldendal.barkpark.cloud
```

**The certificate was renewed on 2026-09-05**, five days before this probe — NOT
the `notBefore=Jul 8 10:50:19 2026` cert D457 recorded. The SAN is the contested
name and nothing else. On-demand issuance requires the control plane's ask-gate to
answer 200, so the platform itself authorised this issuance last week:

```
$ curl -s -o /dev/null -w "%{http_code}\n" \
    "https://barkpark.cloud/v1/tls/ask?domain=gyldendal.barkpark.cloud"
200
$ curl -s -o /dev/null -w "%{http_code}\n" \
    "https://barkpark.cloud/v1/tls/ask?domain=gyldendal-506f035e.barkpark.cloud"
404
```

This is the mechanical reason D457's "**DO NOT de-register
`gyldendal.barkpark.cloud` from `/v1/tls/ask`**" is load-bearing and D605 keeps
the gate name-bound: de-registering the name breaks a renewal that is
demonstrably still happening, roughly every 60 days.

## 5. Does the IP match a registered barkpark?

```
$ env -u BARKPARK_TOKEN bp cloud status
count: 8 — muscle-1 (46.224.19.120) · Gyldendal (5.75.169.183) · dnd (91.98.193.151)
· dooodo (116.203.91.216) · gyl (46.225.61.223) · jarl (91.98.139.58)
· remote-studio (167.235.134.47) · Guerrilla (157.180.90.121)
```

**No row in this view has host 116.203.98.0.** The `Gyldendal` row visible here is
`a9863194-…`, host `5.75.169.183`, `url=https://gyldendal-506f035e.barkpark.cloud`,
`agent_status: online`, `health_status: down`, `git_commit c80168100…`,
`commit_distance 5313`.

*Honest limit on that negative:* `bp cloud status` is TEAM-SCOPED. Absence from
this list is not absence from the registry — the rows the charter names
(`f5e1392e` team Gyldendal, `b1259514` team yo) belong to other teams and are not
readable from here. What this DOES establish is that the address serving the
contested name is not any box on the reading team's fleet.

The two sibling FQDNs, for completeness:

```
$ dig +short gyldendal-506f035e.barkpark.cloud
5.75.169.183
$ curl -s https://gyldendal-506f035e.barkpark.cloud/status.json
{"status":"operational","version":"0.2.25.164", ...}

$ dig +short gyldendal-71069eaa.barkpark.cloud
(empty — NXDOMAIN, as D457 recorded)

$ curl -sI --resolve gyldendal-506f035e.barkpark.cloud:443:116.203.98.0 \
    https://gyldendal-506f035e.barkpark.cloud/
(no response — 116.203.98.0 serves the contested name under SNI and nothing else)
```

So there are **two distinct live boxes** in this story, plus one dead name:
116.203.98.0 answering only `gyldendal.barkpark.cloud`, 5.75.169.183 answering the
suffixed FQDN, and `gyldendal-71069eaa` (team yo's provisioning name) NXDOMAIN.

## 6. WHAT THE FILING GOT WRONG

1. **"other_barkpark_custom_host?/2"** — no such function is on main. #14458
   (`3b34f91fc`) folded the four claim legs into `hostname_claimed?/2` and renamed
   this one `barkpark_custom_host_claimed?/2`. A repo-wide grep for the old
   spelling matched exactly ONE line, a stale COMMENT at `registry.ex:7819` — the
   filing read the comment, not the code. Corrected in this PR.
2. **"an abandoned ghost by the SAME predicate"** — false on the platform's own
   predicate. `provisioning_fqdn_claim/2` ANDs three legs, and
   `:active_subscription` alone holds a claim for any entitled team. D443 measured
   the silence-only predicate **0-for-3** on live data with team Gyldendal
   (`supporter`) explicitly among the three entitled rows. Porting the carve-out
   here would not release the row the filing wants released.
3. **"1,377 unreachable usage samples"** — that count belongs to `b1259514` (team
   yo), the row on the OTHER side of the collision, and D457 already corrected it:
   the number counts `usage_samples` ROWS, which the host-keyed sweeper writes on
   every tick regardless of outcome. D605 further shows the reason word lives at
   `envelope #>> '{meters,<meter>,unavailable_reason}'`, two levels down, so any
   top-level probe answers a comforting 0. Do not quote a row count as an
   unreachable count for either row.
4. **"a live Caddy … answers 200 for the name"** — it answers **302** to the
   Studio path (D505 recorded the same). 200 is what `/v1/tls/ask` answers for the
   name; the two 200s are different facts and the filing conflated them.
5. **"neither box has ever phoned home"**, framed as if it meant neither box is alive —
   the box behind the contested name has 64.5 days of unbroken uptime, all
   components `operational`, and a certificate renewed 5 days ago. Never phoning
   home is a statement about the agent.

## 7. WHAT THIS DOES NOT TOUCH

The `b1259514` / team-yo credential disclosure is unchanged and still LIVE. This
note is only about what serves the hostname and about the claim predicate. The
remediation stays a lead/operator act in D505's order — **NULL
`admin_token_encrypted` FIRST, `url` SECOND, one transaction**, then rotate team
`71069eaa`'s instance admin token. Nothing here was written, de-registered or
repointed.
