# Local control-plane identity-journey recipe — onboarding-composition w4 (2026-08-17)

Verdict: the FULL identity leg (register → device/start → poll pending → inspect →
approve via Bearer session → poll token → replay burn) runs headlessly against a
LOCAL cloud control-plane boot in **0.32s wall-clock**, pollution-free. Epic
criterion 1's identity+receipt spine IS live-demonstrable this wave without
touching prod.

## Boot recipe (rederive from scratch)

```bash
# Substrate: local Postgres postgres/postgres@localhost:5432 (pg_isready must pass).
cd cloud && mix deps.get && mix ecto.create && mix ecto.migrate
nohup mix run --no-halt > /tmp/cloud-boot.log 2>&1 &   # NOT mix phx.server — plain Bandit+Plug
sleep 20 && curl -s -o /dev/null -w "%{http_code}" localhost:4100/v1/auth/oauth/providers  # 200 = up
```

Two premise corrections vs the assignment text:
- **No `mix phx.server`** — cloud/ is Bandit+Plug (application.ex:72 `{Bandit, plug: BarkparkCloud.Web.Router, port: ...}`), runner is `mix run --no-halt`.
- **`PORT=4190` is inert in dev** — runtime.exs's PORT read (line 242) sits inside `if config_env() == :prod` (line 13); dev port is fixed 4100 by config.exs:158.

## Identity sequence (all quoted bodies from the live local run)

```bash
curl -s -XPOST localhost:4100/v1/auth/register -H 'content-type: application/json' \
  -d '{"email":"probe-w4@example.test","password":"probe-pass-123456"}'
# {"token":"…","team_id":"af8128c5-…"}          — session, one transaction
curl -s -XPOST localhost:4100/v1/auth/device/start -d '{"client_name":"probe"}' -H 'content-type: application/json'
# {"interval":5,"user_code":"VC99-7XNW","expires_in":600,"device_code":"…","verification_uri":"http://localhost:4100/activate",…}
# poll before approve → {"status":"pending"}
# inspect (Bearer)    → {"client_name":"…","ip_address":"127.0.0.1",…}
# approve (Bearer)    → {"ok":true}
# poll after approve  → {"token":"…","team_id":"…"}
# poll replay         → {"error":"expired_or_invalid"}   — code burns, single-use
# re-register same email → HTTP 409 {"error":"email_taken"}  — retry names itself
# GET /v1/me (device token) → user+team+role+teams[]+team_authority+onboarding{steps[]}
```

## Rig-design consequences (pdf-mvp0-journey-proof.sh template)

- LIVE legs (local CP): register, device start/inspect/approve/poll, /v1/me
  receipt, `bp login --url http://localhost:4100` (flag proven at
  cloud12_cmd.go:140 — precedence --url > saved CloudURL > baked default),
  `--device-start`/`--device-poll` one-shots (cloud12_cmd.go:1098).
- --plan/self-test legs: install-cli.ps1 (no Windows host), instance
  provisioning (real money/boxes), MCP-vs-instance leg unless a local api/ boot
  is added as a second local substrate.
- Fresh-register per run IS the right shape locally: teardown = `mix ecto.drop`
  or nothing (dev DB). NEVER fresh-register against prod: cloud/accounts.ex has
  delete_user_session_tokens (line 1013) but NO delete_user — an account created
  on barkpark.cloud is permanent.
- Kill the server after (`kill <pid>`; verify curl → 000).
