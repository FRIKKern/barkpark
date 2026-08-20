# register-live-reproof — re-derivation recipes (2026-08-17)

Wave: api-read-path-security-sweep wave 2. Verifier assignment: `register-live-reproof`.
All probes use INVALID bodies (`"password":"x"` — 12-char minimum) so no account is created.

## R1 — API primary throttles anonymous register (bounded)

    for i in $(seq 1 70); do curl -s -o /dev/null -w '%{http_code} ' -X POST http://89.167.28.206/v1/auth/register -H 'content-type: application/json' -d '{"email":"p'$i'@example.invalid","password":"x"}'; done; echo

Observed 2026-08-17 08:3x UTC: 63x `422` then 7x `429`. Second burst tripped at i=58.
429 body/headers:

    curl -s -D- -X POST http://89.167.28.206/v1/auth/register -H 'content-type: application/json' -d '{"email":"qq@example.invalid","password":"x"}'
    # HTTP/1.1 429 Too Many Requests / Retry-After: 1
    # {"error":{"code":"rate_limited",...,"details":{"retry_after":1}}}

## R2 — control plane is UNMETERED and is a separate app

    for i in $(seq 1 70); do curl -s -o /dev/null -w '%{http_code} ' -X POST https://api.barkpark.cloud/v1/auth/register -H 'content-type: application/json' -d '{"email":"p'$i'@example.invalid","password":"x"}'; done; echo

Observed: 70/70 `422`, zero `429`. Re-run at 140 requests: `140 422`, zero `429` (210 total, no limiter).
App discriminator: the cloud 422 body is `{"error":"password_invalid",...}` (cloud router `register_error/1`),
the API 422 body is `{"error":{"code":"invalid_registration",...}}` (`Barkpark.Content.Errors` envelope).

## R3 — enumeration oracle: cloud YES, API NO

    curl -s -w ' [%{http_code}]\n' -X POST https://api.barkpark.cloud/v1/auth/register -H 'content-type: application/json' -d '{"email":"frikk@guerrilla.no","password":"x"}'
    # {"error":"email_taken"} [409]
    curl -s -w ' [%{http_code}]\n' -X POST https://api.barkpark.cloud/v1/auth/register -H 'content-type: application/json' -d '{"email":"admin@barkpark.cloud","password":"x"}'
    # {"error":"password_invalid",...} [422]
    curl -s -w ' [%{http_code}]\n' -X POST http://89.167.28.206/v1/auth/register -H 'content-type: application/json' -d '{"email":"frikk@guerrilla.no","password":"x"}'
    # {"error":{"code":"invalid_registration",...}} [422]  <- no taken/free signal

409-vs-422 on the SAME invalid password separates taken from free on the cloud plane. The API strips the
email signal (`errors_without_email_signal/1`) and answers a generic accepted for a taken-only collision.

## R4 — the route already rides Plugs.RateLimit on origin/main

    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '563,570p;1492,1496p'
    git show origin/main:api/lib/barkpark_web/plugs/rate_limit.ex | grep -n 'write_per_minute\|bucket_key\|ip:#{'

`:user_auth` = AcceptBarkparkVendor, accepts json, ErrorEnvelopeNegotiation, **Plugs.RateLimit**, fetch_session.
Bucket key for anonymous callers is `ip:<client_ip>:write:global` — one shared 60/min write budget for EVERY
anonymous write from that IP, register included. So a register-specific bucket is a GRANULARITY change.

## R5 — cloud register has no limiter, by written intent

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1032,1066p'
    # "YAGNI: no email verification, no captcha, no rate-limiter — rate-limiting this
    #  unauthenticated endpoint is a deploy concern (a fronting proxy / WAF rule)"
