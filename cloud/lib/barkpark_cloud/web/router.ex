defmodule BarkparkCloud.Web.Router do
  @moduledoc """
  The control-plane HTTP API (cloud-12a) — a minimal JSON `Plug.Router` over the
  Accounts / Registry / Billing contexts. Deliberately NOT Phoenix/LiveView: this
  is the callable JSON surface the agent (cloud-10) POSTs to, the Go CLI client
  (cloud-12b) calls, and the live dashboard (served by this app, SSE-pushed via
  `GET /v1/events`) consumes.

  ## Route table

  Every GET below also answers HEAD with the same status and headers and an
  empty body — `plug(Plug.Head)` rewrites the method once, before matching, so
  HEAD earns no rows of its own here (it is not a route, it is a rewrite).

      METHOD  PATH                 AUTH      PURPOSE
      GET     /up                  —         control-plane liveness (200 db up | 503 db down)
      GET     /health              —         alias of /up
      GET     /                    —         SPA shell (dashboard) at the bare root (HTML, not JSON)
      GET     /dashboard           —         SPA shell — deep-link/refresh lands the HTML
      GET     /new                 —         deploy-button landing (?template=<slug>) → SPA shell
      GET     /activate            —         bp-login device-approve page → SPA shell
      POST    /v1/auth/login       —         email+password → {token, team_id} | {two_factor_required, challenge_token}
      POST    /v1/auth/two-factor-challenge — challenge_token + code/recovery_code → {token, team_id} (429 carries retry_after)
      POST    /v1/auth/device/start   —      {client_name} → {device_code, user_code, verification_uri, ...}
      POST    /v1/auth/device/poll    —      {device_code} → pending | {token, team_id} | slow_down | expired
      POST    /v1/auth/device/inspect user   {user_code} → {client_name, ip_address, user_agent, expires_at}
      POST    /v1/auth/device/approve user   {user_code} → {ok: true} (pending→approved CAS)
      POST    /v1/auth/device/deny    user   {user_code} → {ok: true}
      GET     /v1/auth/oauth/providers           —  enabled OAuth providers (SPA buttons)
      GET     /v1/auth/oauth/:provider           —  302 → IdP authorize URL (signed, single-use state)
      GET     /v1/auth/oauth/:provider/callback  —  identity → 302 /#oauth_code=<one-time code>&team=<id>
      POST    /v1/auth/oauth/exchange            —  burn the one-time code → session token (no GET twin)
      DELETE  /v1/auth/logout      user      revoke the calling session token
      POST    /v1/auth/sse-ticket  user      mint a 60s single-use ticket for GET /v1/events
      POST    /v1/account/two-factor/enroll user   start TOTP enroll → {otpauth_uri, secret}
      POST    /v1/account/two-factor/confirm user  {code} → {recovery_codes} (2FA on)
      GET     /v1/account/two-factor user   {enabled: bool}
      DELETE  /v1/account/two-factor user   disable 2FA → {ok: true}
      POST    /v1/account/two-factor/recovery-codes user  regenerate → {recovery_codes}
      POST    /v1/auth/verify-email        —     {token} → confirm the account (single-use)
      POST    /v1/auth/register    —         create an account {email,password} → session
      POST    /v1/auth/request-reset       —  request a password-reset email (always 200)
      POST    /v1/auth/reset       —         {token,password} → reset password (single-use)
      POST    /v1/auth/resend-verification user  re-send the confirm mail (always 200)
      POST    /v1/account/email/change     user  {new_email} → stage + email a 6-digit code
      POST    /v1/account/email/confirm    user  {code} → swap email + Stripe sync
      GET     /v1/me               user(s)   {user{id,email,confirmed,two_factor_enabled,platform_operator}, team{id,name,slug}, teams[], role, team_authority{team_id,role,admin,owner}, onboarding}
      GET     /v1/onboarding       user      the team's onboarding checklist state
      POST    /v1/onboarding       admin     advance/dismiss an onboarding step
      GET     /v1/archives         user      the team's archived (torn-down) instances, restorable
      GET     /v1/account/sessions         user  list live sessions (current flagged)
      DELETE  /v1/account/sessions/:id     user  revoke one session by id (own only)
      DELETE  /v1/account/sessions         user  sign out everywhere except this tab
      PUT     /v1/account/password         user  change password ⇒ sign out everywhere
      GET     /v1/subscription     user      {subscription | nil} — current plan
      GET     /v1/events           user*     Server-Sent-Events live stream (*ticket= or Bearer)
      POST    /v1/agent/report     agent     land a health report (health + events)
      POST    /v1/agent/space      agent     land the disk-consumption payload (event only)
      GET     /v1/agent/commands   agent     approved-command queue (empty for now)
      POST    /v1/agent/results    agent     ack command results
      GET     /v1/barkparks        user      the team's registered Barkparks (+provision_status)
      GET     /v1/audit            admin     the team's append-only audit trail (keyset-paginated; ?actor_user_id= / ?action_prefix= narrow it)
      DELETE  /v1/barkparks/:id    admin     remove an instance (deregister; live box → 409)
      GET     /v1/barkparks/:id/events user  the instance's agent-event history (team-scoped)
      GET     /v1/barkparks/:id/telemetry user  the instance's latest health report, normalized (team-scoped)
      GET     /v1/barkparks/:id/metrics user  a window of health beats as cpu/mem/disk/load series (team-scoped)
      GET     /v1/barkparks/:id/usage user   the console's usage meters, honest per D48 (team-scoped)
      GET     /v1/barkparks/:id/usage/history user  usage-meter series over the trailing 14d of samples, for sparklines (team-scoped)
      GET     /v1/usage/summary    user      cross-instance usage-meter rollup for the team
      GET     /v1/barkparks/:id/domain-status user  per-domain, per-stage DNS/TLS/serving checklist (team-scoped)
      POST    /v1/barkparks/:id/retry admin  re-enqueue a FAILED provision
      GET     /v1/barkparks/:id/credentials admin  reveal the per-instance admin token (team-admin; a PAT must also hold `root`)
      POST    /v1/barkparks/:id/studio-link user   one-click Studio entry → {url} (single-use 60s ticket)
      POST    /v1/barkparks/:id/app-token user  mint a member-reachable, workspace-bound data-plane token (mobile D4; JIT MEMBER; admin token stays server-side)
      DELETE  /v1/barkparks/:id/app-token user  revoke app token(s) — body {token} for one, EMPTY (never {token:""}) for logout-everywhere (wave 2; admin token stays server-side)
      POST    /v1/push/device-tokens user  register this device's APNs/FCM push token (push-relay spike D15; idempotent upsert)
      POST    /v1/barkparks/:id/push-relay admin  provision the instance chat_blocked webhook that drives the push relay (D15; idempotent, converges)
      POST    /v1/fleet/supports   admin(d)  register a SUPPORT machine bound to a main (PDF-D61; PAT needs `deploy` / session team-admin)
      DELETE  /v1/fleet/supports/:id admin(d)  remove a SUPPORT fleet row (PDF-D61; live box -> deprovision job 202 so its A record dies WITH it; ?mode=detach = row only; mains refused 409)
      POST    /v1/barkparks/:id/agent-key admin(d)  paste-a-key delivery to a LIVE support box (PDF-D94; key rides memory only, never stored)
      GET     /v1/barkparks/:id/agent-key admin(d)  latest push_agent_key job status (status/error only — the row never held the key)
      POST    /v1/barkparks/:id/site-url user  wire the deployed site URL → activate the ISR webhook (dwb-6)
      GET     /v1/barkparks/:id/bootstrap admin  reveal the dwb-4 content-bootstrap outputs (team-admin only)
      PATCH   /v1/barkparks/:id/autoupdate admin  set fleet-autoupdate policy (isu-w4 opt-out/pause/pin)
      POST    /v1/barkparks/:id/verify user  run the post-provision health verification
      POST    /v1/barkparks/:id/self-update admin  trigger an in-place self-update on the box
      POST    /v1/barkparks/:id/rollback admin  roll the box back to the previous release
      POST    /v1/barkparks/:id/domain admin  attach a custom domain — platform-zone or any customer FQDN already pointed at the box (V2 ownership proof)
      POST    /v1/barkparks/:id/vercel-deploy admin  wire a Vercel deploy for the instance's site
      GET     /v1/barkparks/:id/api/webhooks user  proxy → the instance's own webhooks list (admin token stays server-side)
      POST    /v1/barkparks/:id/api/webhooks user  proxy → create a webhook on the instance
      GET     /v1/barkparks/:id/api/webhooks/:webhook_id user  proxy → show one instance webhook
      PUT     /v1/barkparks/:id/api/webhooks/:webhook_id user  proxy → update one instance webhook
      DELETE  /v1/barkparks/:id/api/webhooks/:webhook_id user  proxy → delete one instance webhook
      POST    /v1/barkparks/:id/api/webhooks/:webhook_id/rotate user  proxy → rotate a webhook signing secret
      GET     /v1/barkparks/:id/api/webhooks/:webhook_id/deliveries user  proxy → a webhook's delivery log
      POST    /v1/barkparks/:id/api/webhooks/:webhook_id/deliveries/:event_id/replay user  proxy → replay one delivery
      POST    /v1/barkparks/:id/api/webhooks/:webhook_id/test-send user  proxy → one-shot synthetic webhook test-send
      GET     /v1/admin/autoupdate worker    global fleet-autoupdate policy snapshot
      POST    /v1/admin/autoupdate/halt worker  halt fleet autoupdate (kill-switch)
      POST    /v1/admin/autoupdate/resume worker  resume fleet autoupdate
      GET     /v1/operator/fleet   operator  fleet snapshot for the session-gated operator console
      GET     /v1/operator/autoupdate operator  fleet-autoupdate policy snapshot (console read)
      POST    /v1/operator/autoupdate/halt operator  halt fleet autoupdate (console brake)
      POST    /v1/operator/autoupdate/resume operator  resume fleet autoupdate (console)
      GET     /v1/operator/deliveries operator  notification delivery log (console read)
      GET     /v1/operator/warm-pool operator  warm-pool status (console read)
      GET     /v1/operator/deploy-ledger/census operator  fleet deploy ledger: class + site counts and the failure rate WITH its denominator, over a pinned window
      GET     /v1/deliveries       user(s)+worker  the platform's OWN per-sha delivery record — what was delivered, on whose run, and the clocks around it (?sha= narrows; a pinned window otherwise). PAT-reachable on purpose (D385/D412)
      GET     /v1/deploy-ledger/census user(s)  the SAME deploy ledger, scoped to the caller's own team sites (+ a scope line naming the team slug); the read a non-operator can actually reach
      PATCH   /v1/admin/barkparks/:id/channel worker set one box's release channel
      GET     /v1/templates        —         PUBLIC deploy-button catalog (title/desc/env-keys/repo) (dwb-6)
      GET     /v1/providers        user      the team's connected cloud providers
      POST    /v1/providers        admin     connect a cloud provider
      DELETE  /v1/providers/:kind  admin     disconnect a cloud provider
      GET     /v1/providers/:kind/catalog user  a provider's allowlisted action catalog
      GET     /v1/providers/:kind/overview user  a provider's server-side estate snapshot
      GET     /v1/providers/capabilities user  per-provider capability matrix (SPA gating)
      GET     /v1/hetzner/catalog  user      the allowlisted Hetzner action catalog (resource/verb/tier/params)
      GET     /v1/hetzner/overview admin     server-side Hetzner estate snapshot (token never reaches the browser)
      GET     /v1/github/installation      user  the team's GitHub connection state (no secrets)
      POST    /v1/github/installations     admin record a GitHub App install (require_team_admin; 503 if unconfigured)
      DELETE  /v1/github/installation      admin disconnect GitHub (require_team_admin; 404 if none)
      GET     /v1/github/repos             user  the installation's repos (the "Import Git Repository" picker)
      POST    /v1/github/repos             admin create a repo from a template + push app files (deploy button)
      GET     /v1/notifications/settings  user the team's email-notification settings (secrets masked)
      PUT     /v1/notifications/settings  admin  update transport / per-event toggles / SMTP secrets
      PUT     /v1/notifications/channels admin  update per-channel transport settings
      PUT     /v1/notifications/events admin  update per-event notification toggles
      POST    /v1/notifications/test      admin  send a rate-limited test email
      GET     /v1/notifications/deliveries user  the durable notification delivery log (newest first; ?channel/?status/?event/?before narrow it). owner/admin sees the whole team's; any other member sees only sends addressed to them
      GET     /v1/tokens           user      list the caller's Personal Access Tokens (session-only: PAT management is never PAT-reachable)
      POST    /v1/tokens           user      mint a PAT → {token: <plaintext ONCE>, pat} (session-only — the escalation firewall)
      DELETE  /v1/tokens/:id       user      revoke a PAT (own only) → {ok:true} | 404 (session-only)
      GET     /v1/teams/:id/members user     list a team's members (member+)
      POST    /v1/teams/:id/invitations admin  invite a member {email,role?} → {invitation, accept_url}
      GET     /v1/teams/:id/invitations admin  list a team's live invitations
      DELETE  /v1/teams/:id/invitations/:inv_id admin  revoke a pending invitation
      PATCH   /v1/teams/:id/members/:user_id admin  change a member's role
      DELETE  /v1/teams/:id/members/:user_id admin  remove a member from the team
      GET     /v1/teams/:id/tokens admin  list every PAT minted against the team (holder named; no secrets)
      DELETE  /v1/teams/:id/tokens/:token_id admin  revoke a team member's PAT (foreign id → 404)
      GET     /v1/invitations/:token —         preview an invitation by token (public accept page)
      POST    /v1/invitations/accept user    accept an invitation (join the team)
      POST    /v1/billing/checkout owner     open a hosted Checkout Session → {checkout_url}
      POST    /v1/billing/webhook  —*        Stripe events (signature-verified, raw body)
      POST    /v1/billing/portal   owner     open the Stripe billing portal → {portal_url}
      POST    /v1/billing/cancel   owner     cancel the active subscription (period-end)
      POST    /v1/resurrect        admin     restore a torn-down instance from an object-storage bundle (billed box ⇒ same admin gate as launch)
      POST    /v1/launch           admin(d)  go-live (alias of /v1/go-live)
      POST    /v1/go-live          admin(d)  gate on active subscription + create a provisioning Barkpark
      POST    /v1/internal/provision-jobs/claim       worker  claim oldest pending job
      POST    /v1/internal/provision-jobs/:id/succeed worker  flip barkpark up at {ip} (+ optional encrypted admin_token/bootstrap)
      POST    /v1/internal/provision-jobs/:id/fail    worker  mark job failed {error}
      POST    /v1/internal/provision-jobs/:id/step    worker  step transition {step,status,detail?}; progress updates live caption in place → SSE (dwb-14/dwb-19)
      POST    /v1/internal/provision-jobs/:id/console worker  append a live console line {line} (capped, append-only) → SSE (dwb-16)
      POST    /v1/internal/provision-jobs/:id/release worker  claimed→pending on graceful shutdown, no attempt consumed (dwb-15)
      POST    /v1/internal/deprovision-jobs/claim worker  claim oldest pending deprovision job
      POST    /v1/internal/deprovision-jobs/:id/succeed worker  mark a deprovision done
      POST    /v1/internal/deprovision-jobs/:id/fail worker  mark a deprovision failed {error}
      POST    /v1/internal/attach-domain-jobs/claim worker  claim oldest pending attach-domain job
      POST    /v1/internal/attach-domain-jobs/:id/succeed worker  mark an attach-domain done
      POST    /v1/internal/attach-domain-jobs/:id/fail worker  mark an attach-domain failed {error}
      POST    /v1/internal/resurrect-jobs/claim worker  claim oldest pending resurrect job
      POST    /v1/internal/support-jobs/claim worker  claim oldest pending provision_support job (+pinned support map)
      POST    /v1/internal/agent-key-jobs/claim worker  claim oldest pending push_agent_key job (+one-time key pop — delete-on-read)
      POST    /v1/internal/agent-key-jobs/:id/succeed worker  key line landed + listener restarted (job row only)
      POST    /v1/internal/agent-key-jobs/:id/fail worker  delivery failed (row untouched; re-paste recovers)
      POST    /v1/internal/enable-apply-jobs/claim worker  claim oldest pending enable_apply job (retro-arm the self-update executor)
      POST    /v1/internal/enable-apply-jobs/:id/succeed worker  flag landed + app restarted (job row only; next probe measures armed)
      POST    /v1/internal/enable-apply-jobs/:id/fail worker  arming failed (row untouched; next unarmed measurement re-enqueues)
      GET     /v1/internal/barkparks worker  list registry rows for the provisioner
      POST    /v1/internal/barkparks worker  create a registry row (provisioner-side)
      POST    /v1/internal/barkparks/:id/deprovision worker  enqueue a deprovision for one box
      POST    /v1/internal/warm-servers worker  register a warm-pool server
      POST    /v1/internal/warm-servers/claim worker  claim a warm server for a provision
      POST    /v1/internal/warm-servers/claim-retire worker  claim a warm server to retire
      POST    /v1/internal/warm-servers/claim-refresh worker  claim a warm server to refresh
      POST    /v1/internal/warm-servers/:name/refreshed worker  mark a warm server refreshed
      GET     /v1/internal/warm-servers/count worker  the warm-pool depth
      DELETE  /v1/internal/warm-servers/:name worker  drop a warm server
      POST    /v1/internal/platform-deliveries worker  record a BATCH of platform delivery rows for one delivering run (idempotent on sha+run+target; 503 unavailable when the migration has not landed)
      POST    /v1/sites            user      create a hosted Site under a Barkpark
      GET     /v1/sites            user(s)   list the team's sites (across all boxes)
      GET     /v1/sites/:id        user      one site
      PATCH   /v1/sites/:id        user(s)   update a site's settings (write ability)
      DELETE  /v1/sites/:id        user(s)   delete a site — tear it down on the box + deregister (write ability)
      GET     /v1/sites/:id/domain-status user  per-domain DNS/TLS/serving checklist, CF-mode-aware (team-scoped)
      POST    /v1/sites/:id/deploy user(s)   enqueue a Deployment (the build job) (write ability)
      GET     /v1/sites/:id/deployments user list a site's PRODUCTION deployments, newest first
      GET     /v1/sites/:id/deployments/:dep_id user(s)  one deployment (read ability)
      POST    /v1/sites/:id/rollback user(s) roll a site back to a prior deployment (write ability)
      POST    /v1/sites/:id/deployments/:dep_id/promote user(s) rollback/redeploy — mint a NEW queued prod deployment pinned to the source artifact (write ability)
      GET     /v1/sites/:id/previews user    list a site's branch previews (gh-6), one per branch
      POST    /v1/sites/:id/deployments/:dep_id/artifact user(s)  upload a PREBUILT dist for a minted deployment, then start it (write ability)
      POST    /v1/sites/:id/env    user      replace the encrypted env blob
      POST    /v1/sites/:id/domains user     add a domain to a site
      DELETE  /v1/sites/:id/domains user     remove a domain from a site — frees the hostname
      POST    /v1/sites/:id/github  admin    link a GitHub repo + branch + webhook secret (manual)
      POST    /v1/sites/:id/github/connect admin  pick a repo → auto-register the push webhook on GitHub (gh-4)
      DELETE  /v1/sites/:id/github  admin  disconnect a Site's GitHub link (gh-4)
      POST    /v1/webhooks/github/:site_id —  GitHub push → enqueue Deployment (HMAC)
      POST    /v1/sites/webhooks/content-publish/:site_id —*  content-publish webhook → ISR revalidate (signed)
      POST    /v1/relay/chat-blocked/:barkpark_id —*  instance chat_blocked webhook → member-device push fan-out (signed; D15)
      GET     /v1/tls/ask          —         on-demand-TLS gate (200/404 by domain)
      POST    /v1/builder/claim    agent     atomic next-queued deployment claim (own box only)
      POST    /v1/builder/deployments/:id/transition agent fenced status update (own box only)
      POST    /v1/builder/deployments/:id/console agent append a live build-console line {line} (capped, append-only) → SSE (gh-5; own box only)
      POST    /v1/builder/deployments/:id/detail  agent set the live sub-caption {detail} (latest-wins) → SSE (dwb-19; own box only)
      GET     /v1/builder/sites/:id/env agent decrypted site env for build-time injection (nixpacks --env; own box only)
      GET     /v1/agent/pending    agent     deployments in pushing for this box
      GET     /v1/agent/sites/:id/env agent  decrypted site env for the running container (own box only)
      POST    /v1/agent/deployments/claim agent atomic pickup of the next pushing
      POST    /v1/agent/deployments/:id/transition agent fenced live transition
      *       (anything else)      —         404 JSON

  Every `/v1/*` response is JSON; errors are `{"error": "<reason>"}`. The bare-path
  routes (`/`, `/dashboard`, `/new`, `/activate`) instead serve the SPA HTML shell.
  The AUTH column: `—` public · `user` a USER session token, and ONLY a session —
  a PAT bearer is turned away · `user(s)` EITHER a session OR a Personal Access
  Token; where the route also demands an ability the DESCRIPTION names it
  (`(write ability)`, `(read ability)`), because this column states the credential
  KIND and never the ability · `user*` a session presented either as a Bearer
  token or as a single-use `?ticket=` (the SSE stream, which no `Auth.require_*`
  guards) · `admin`/`owner` that session plus a team-admin/owner role ·
  `admin(d)` EITHER of two credentials — a
  session with the team-admin role, OR a Personal Access Token carrying the `deploy`
  ability (a deploy-PAT needs no role, so `admin` on these rows would be its own
  lie) · `agent` an AGENT token · `worker` the shared WORKER token · `—*` a
  signature-verified webhook. A row's tier is the tier its body ENFORCES, gate or
  post-gate: seven of these routes call a permissive `Auth.require_*` and then
  refuse a plain member from the `cond` below it, and the tier column reports the
  refusal (`router_moduledoc_table_test.exs` re-derives both sides from this file
  and fails on any disagreement). The agent routes authenticate
  with an AGENT token (`Registry.verify_agent_token`); the user routes with a USER
  session token (`Accounts.verify_user_session_token`); the internal `/v1/internal/*`
  routes with the shared WORKER token (`require_worker` — Bearer WORKER_TOKEN, never a
  user/agent token) — all via `BarkparkCloud.Web.Auth`.

  This table is a hand-maintained mirror of the `Plug.Router` match clauses below.
  It does not drift silently: `router_moduledoc_table_test.exs` parses both the match
  macros and this table from the source and fails CI on any mismatch — add the row
  here (or drop the stale one) when you change a route.
  """
  use Plug.Router

  # THE CRASH PATH IS A ROUTE TOO (cch-w30-s5). Without this, an uncaught raise
  # or a body Plug.Parsers refuses answers with ZERO BYTES and NO content-type —
  # measured against a booted control plane on origin/main: a malformed JSON body
  # → `400 size_download=0 content_type=[]`, a `text/plain` content-type → 415
  # same, a 20 MB body → 413 same. The STATUS was always right (Bandit honours
  # `Plug.Exception.plug_status`, so a guard asserting `status == 500` would be
  # green by construction); the lie was the empty body, because `api()` in
  # app.js parses a response ONLY when its content-type contains
  # `application/json` and substitutes `{}` otherwise — so every crash reached
  # the SPA as `{ok:false, data:{}}` and `friendly()` fell through to the
  # caller's fallback copy, which was written for a VALIDATION failure. The
  # person then read "Check the details and try again." about a server fault
  # they had no part in.
  #
  # `use Plug.ErrorHandler` must come after `use Plug.Router` (it overrides the
  # `call/2` Plug.Router generates, wrapping the WHOLE pipeline — including the
  # `Plug.Parsers` plug below, which runs BEFORE `:dispatch`, so a parse fault
  # needs no route defect at all). It re-raises after responding, so Bandit
  # still logs the crash; the response is already committed, so nothing is sent
  # twice. See `handle_errors/2` below for the envelope.
  use Plug.ErrorHandler
  require Logger

  alias BarkparkCloud.{
    Accounts,
    ArchiveStore,
    Azure,
    Billing,
    Cloudflare,
    DeployLedger,
    DeviceAuth,
    DomainOwnership,
    DomainStatus,
    Events,
    FailureCopy,
    GitHub,
    Metrics,
    Notifications,
    OAuth,
    PlatformDelivery,
    Push,
    Registry,
    Repo,
    Telemetry,
    Usage,
    Vercel,
    Verify,
    Webhooks
  }

  alias BarkparkCloud.Accounts.{Authz, Team, TwoFactorRateLimiter, UserToken}
  alias BarkparkCloud.DeviceAuth.RateLimiter, as: DeviceAuthRateLimiter
  alias BarkparkCloud.Registry.AgentKeyStash
  alias BarkparkCloud.Registry.AzureCatalog
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Registry.HetznerCatalog
  alias BarkparkCloud.Registry.InstanceApiCatalog
  alias BarkparkCloud.Sites
  alias BarkparkCloud.Web.Auth

  # Recover the REAL client IP from X-Forwarded-For BEFORE anything reads
  # conn.remote_ip (peer_ip/1 → the device-auth `start:<ip>` rate bucket and the
  # minted-session ip_address). Behind Caddy the raw peer is always the loopback
  # hop, so without this every remote client shares one global rate bucket and
  # every session records 127.0.0.1. RemoteIp only rewrites remote_ip when the
  # ACTUAL peer is a trusted loopback proxy (see :trust_forwarded_ip) — a spoofed
  # header from a directly-reachable client is ignored, so no remote caller can
  # forge its bucket. Placed first: it must run before RewriteOn's builders and
  # before any matcher reads remote_ip.
  plug(:trust_forwarded_ip)

  # Normalize scheme/host/port from the Caddy TLS front's forwarding headers
  # BEFORE any plug (or builder) reads conn.scheme/host/port. The app never
  # terminates TLS itself — it listens plain on :4100/:4101 behind Caddy — so
  # every emailed reset/accept link and stored webhook URL must be derived from
  # the ORIGINAL external request, not the loopback hop. Safe because the slot
  # ports are loopback-bound (docker-compose.yml), so these headers can only
  # arrive from the trusted front, never a spoofing external client.
  plug(Plug.RewriteOn, [:x_forwarded_proto, :x_forwarded_host, :x_forwarded_port])

  # Canonicalize the front door: a request that reached the www subdomain of the
  # dashboard host (www.barkpark.cloud) is permanently redirected to the apex
  # (barkpark.cloud), preserving BOTH the path and the query string — the
  # `?code=` device-link payload MUST survive. 308 (not 302) so the method is
  # preserved and browsers/proxies cache the canonical form. Runs AFTER RewriteOn
  # so conn.host is the ORIGINAL external host, not the loopback hop. Scoped
  # STRICTLY to www.<dashboard-host>: localhost / raw-IP health probes (the
  # blue/green /up gate hits localhost:410x with no X-Forwarded-Host),
  # api.barkpark.cloud, and any unknown/lookalike host all pass through untouched.
  # http->https is already Caddy's 308 — not duplicated here.
  plug(:canonicalize_dashboard_host)

  # HEAD is GET-without-a-body, and every uptime checker, link previewer and
  # `curl -I` in the world speaks it. This router declared only `get`/`post`/…
  # matches, so HEAD fell through to the catch-all and answered 404 on EVERY
  # path — including `/` and `/up` — which is a lie about what is there.
  # `Plug.Head` rewrites the method to GET exactly once, here, so ONE block
  # gives every current and future GET route its HEAD twin with the same status
  # and headers; the body is dropped by the adapter (`Bandit.Adapter`'s
  # `send_resp_body?/1`, and `Plug.Adapters.Test.Conn` in tests), which is the
  # only layer that can drop it for a `send_file/3` response too. It runs BEFORE
  # `Plug.Static` so HEAD /favicon.ico and HEAD /app.css are honest as well, and
  # AFTER the www→apex canonicalization so a HEAD still gets the 308.
  #
  # …but HEAD-as-GET is only honest for routes that READ. A handful of GETs
  # MUTATE, and `Plug.Head` hands them to every unfurler, prefetcher, AV link
  # scanner and uptime checker on the internet. Measured over a real Bandit
  # socket: `HEAD /v1/auth/oauth/github/callback` ran the whole with-chain
  # (state consume → identity fetch → user create → session-token mint) and
  # answered `302` with a LIVE session token verbatim in the `location` header,
  # because Bandit suppresses only the BODY on HEAD (`send_resp_body?/1`,
  # adapter.ex:263) — `send_headers/4` runs unconditionally. Same probe also
  # BURNED the single-use state nonce, so the user's own click then failed.
  # Note the shape: this exposure was CREATED by the HEAD-honesty fix above.
  # Two individually-correct fixes jointly producing a defect.
  #
  # So: fence the side-effecting GETs BEFORE the rewrite. It has to be here.
  # `Plug.Head.call/2` is `%{conn | method: "GET"}` and stashes nothing — no
  # assign, no private — so by the time control reaches a route, HEAD-ness is
  # destroyed and a per-route short-circuit is IMPOSSIBLE, not merely inferior
  # (D11). One fenced greppable list is also directly mutation-testable: drop an
  # entry and its test reds.
  plug(:refuse_head_on_side_effecting_gets)

  plug(Plug.Head)

  # The dashboard SPA (plain HTML+CSS+JS, no build step) is served straight from
  # priv/static. This runs BEFORE :match so a real asset short-circuits the
  # router; `only:` is an explicit allowlist that DELIBERATELY excludes "v1" so
  # the JSON API can never be shadowed by a same-named file — every /v1/* request
  # falls through to the matchers below. A missing asset (e.g. no favicon.ico)
  # just falls through too. priv/ ships in the OTP release by default, so
  # `from: :barkpark_cloud` resolves the same in dev and prod.
  # Fonts are content-stable (a self-hosted, subsetted family whose bytes only
  # change when the FILENAME changes), so they earn a long immutable lifetime —
  # `immutable` tells the browser never even to revalidate for a year. This
  # dedicated plug runs FIRST and only claims `/fonts/*`, so a font short-
  # circuits here with the immutable header before the no-cache plug below can
  # see it. (Before this split, fonts fell through the general plug and were
  # served `no-cache` — the code contradicted the promise this comment makes.)
  plug(Plug.Static,
    at: "/fonts",
    from: {:barkpark_cloud, "priv/static/fonts"},
    headers: %{"cache-control" => "public, max-age=31536000, immutable"},
    cache_control_for_etags: "public, max-age=31536000, immutable"
  )

  # `no-cache` ≠ "don't cache": it means REVALIDATE every time — the browser
  # keeps the bytes but must ask (If-None-Match), and Plug.Static answers 304
  # off the etag when unchanged. Without this the SPA's unversioned app.js/
  # app.css shipped bare `cache-control: public`, so browsers heuristically
  # served STALE console UI after every deploy (live-caught: a whole deploy-UX
  # wave was invisible to a returning operator until a hard refresh). Fonts are
  # handled by the dedicated immutable plug above, so they are NOT in this
  # allowlist.
  #
  # `gzip: true` — the cold boot shipped 1,195,515 uncompressed bytes
  # (index.html 31,219 + app.js 965,342 + app.css 198,954) because the edge in
  # front of us compresses nothing (measured: the live responses carry no
  # `content-encoding` and no `vary`). With this flag Plug.Static serves the
  # pre-built `<file>.gz` sibling whenever the request says
  # `accept-encoding: gzip`, and adds `vary: Accept-Encoding` so caches key the
  # two representations apart: 346,777 bytes on the wire, −71.0%. The siblings
  # are NOT committed — they are produced by one
  # `RUN gzip -9 -k priv/static/index.html priv/static/app.js priv/static/app.css` in
  # cloud/Dockerfile (see the comment there for why that placement is the whole
  # staleness story), and `cloud/.gitignore` + `scripts/cloud-static-gz-guard.sh`
  # keep one from ever being checked in. A missing sibling is not an error:
  # Plug.Static falls back to the identity file.
  #
  # DO NOT ADD A RUNTIME FRESHNESS CHECK HERE. It cannot work, and the reason is
  # structural: Plug.Static's etag is `phash2({size, mtime})` of THE FILE IT
  # SERVES — in plug 1.20.1, `etag_for_path/3` (static.ex:404-413) hashes the
  # `file_info` handed to it by `file_encoding/4` (:416-437), and that clause
  # stats `path <> ext` (:423) — i.e. the .gz's OWN size and mtime, never the
  # source's. Nothing on the path compares the two. Two consequences. Every
  # build mints a fresh etag for byte-identical content (mtime moved), and a
  # same-size same-mtime replacement collides on the old one. Mutation-proven:
  # with a stale sibling on disk the SAME url answers gzip etag "1483F61" /
  # 50,187 bytes of OLD css and identity etag "6BE30A" / 198,991 bytes of NEW
  # css in the same second, and the `no-cache` above buys nothing because
  # revalidation is answered 304 off the stale etag. An etag comparison is
  # therefore not a sound staleness guard. Same-layer generation is: the
  # Dockerfile builds the sibling from the very bytes it just COPYed, so a
  # stale one cannot exist to be detected.
  plug(Plug.Static,
    at: "/",
    from: :barkpark_cloud,
    # robots.txt is APPENDED, never prepended: cloud-static-gz-guard.sh finds
    # this allowlist by grepping for the opening of the list with index.html as
    # its FIRST entry, so anything inserted ahead of index.html loses the guard
    # its anchor. (Do not quote that literal in a comment either — the grep
    # takes the first line that matches and would anchor on the prose.) It is
    # also absent from the Dockerfile gzip line on purpose: at ~100 bytes the
    # .gz sibling costs more than it saves.
    only: ~w(index.html app.css app.js favicon.ico button.svg styleguide.html robots.txt),
    gzip: true,
    headers: %{"cache-control" => "no-cache"},
    cache_control_for_etags: "no-cache"
  )

  plug(:match)

  # `application/octet-stream` is passed through unparsed: the artifact upload
  # route reads the raw binary body itself with Plug.Conn.read_body so a 100 MB
  # tarball never gets JSON-decoded (or memory-buffered by the parser).
  #
  # `body_reader: {__MODULE__, :cache_raw_body, []}` stashes the unmodified
  # bytes on `conn.assigns[:raw_body]` for the HMAC-verifying webhook paths
  # (Stripe billing + GitHub push) so signature checks see the EXACT bytes the
  # sender signed — the parsed JSON map is not stable enough (key order,
  # whitespace, anything would break the HMAC). Non-webhook paths skip the
  # cache (no needless buffering). The same function handles both webhooks.
  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json", "application/octet-stream"],
    body_reader: {__MODULE__, :cache_raw_body, []},
    json_decoder: Jason
  )

  plug(:dispatch)

  @raw_body_paths ["/v1/billing/webhook"]
  # site-spawner W5 (charter D46): the content-publish receiver verifies an HMAC
  # over the EXACT bytes the box signed, so its raw body must be cached too
  # (the parsed JSON map is not stable enough to re-derive the signature).
  # push-relay spike (charter D15b): the chat_blocked relay receiver verifies the
  # instance's HMAC over the exact signed bytes, so its raw body is cached too.
  @raw_body_path_prefixes [
    "/v1/webhooks/github/",
    "/v1/sites/webhooks/content-publish/",
    "/v1/relay/chat-blocked/"
  ]

  # RemoteIp resolver options, built once at compile time. Only X-Forwarded-For
  # is honored (Caddy's forwarding header); `proxies` lists the loopback CIDRs of
  # our own front.
  #
  # MEASURED, and the whole reason this is safe: RemoteIp resolves the RIGHTMOST
  # entry of the chain that is not a known proxy, NOT the leftmost. Given
  # `x-forwarded-for: "1.2.3.4, 203.0.113.5"` it yields 203.0.113.5. Caddy
  # APPENDS the peer it actually saw at the right end, so a client-supplied XFF
  # prefix is discarded — which is why trusting the bridge gateway below cannot
  # open client-side IP forgery. (An earlier version of this comment claimed
  # "leftmost"; that was false, and under leftmost semantics the peer-trust
  # widening below WOULD have been exploitable.) Pinned by the rightmost-chain
  # test in router_test.exs.
  #
  # `proxies` is deliberately NOT widened alongside the trusted-peer list:
  # RemoteIp resolves from the header chain and never consults conn.remote_ip,
  # so the peer-trust guard in :trust_forwarded_ip is the only knob that matters
  # here. Adding the bridge gateway to `proxies` would only start DISCARDING a
  # legitimately-appended hop.
  @remote_ip_opts RemoteIp.init(
                    headers: ["x-forwarded-for"],
                    proxies: ["127.0.0.0/8", "::1/128"]
                  )

  # dr-w4-s4: the all-unmetered host-pressure block a fleet row carries when the
  # box has NEVER phoned home a health beat (a just-created / just-enqueued
  # instance, and every box whose agent predates the vitals beat). Every signal
  # is nil — "we did not measure" — never a fabricated 0, which would read as a
  # perfectly idle machine. Shape is fixed so a consumer can always destructure.
  @unmetered_pressure %{
    cpu_percent: nil,
    cpu_cores: nil,
    mem_used_percent: nil,
    load1: nil,
    load15: nil,
    req_per_s: nil,
    p95_ms: nil,
    err_5xx_per_s: nil,
    disk_used_percent: nil,
    swap_used_percent: nil,
    swap_total_bytes: nil,
    beam_pss_bytes: nil,
    beam_swap_bytes: nil,
    beam_pid: nil,
    beam_slot: nil,
    runaway_procs: nil,
    slot_units: nil,
    slot_units_truncated: nil,
    reported_at: nil
  }

  # Rewrite conn.remote_ip to the real client IP from X-Forwarded-For, but ONLY
  # when the immediate peer is a trusted front (loopback, or the docker bridge
  # gateway — see trusted_peer?/1). A request whose actual peer is NOT trusted is
  # left untouched: its X-Forwarded-For is attacker-controlled and must never
  # move remote_ip, or a directly-reachable client could forge its rate-limit
  # bucket / session IP.
  defp trust_forwarded_ip(conn, _opts) do
    if trusted_peer?(conn.remote_ip) do
      RemoteIp.call(conn, @remote_ip_opts)
    else
      conn
    end
  end

  # cch-w1-peer-ip-pin. Loopback alone was a PERMANENT NO-OP in production, and
  # it was measured as one: 48 of 49 user_tokens rows carried 172.18.0.1 and
  # exactly one carried a real client IP.
  #
  # Why: Caddy is a HOST systemd service whose Caddyfile is a bare
  # `reverse_proxy localhost:4100`, and the app container publishes
  # 127.0.0.1:4100 only. Caddy dials loopback, but Docker's hairpin NAT rewrites
  # the source address the CONTAINER sees to the bridge GATEWAY. So the peer is
  # never 127.0.0.1 in prod, the guard never fired, and both consumers of
  # remote_ip degraded: the session ip_address the account modal shows, and the
  # device-auth `start:<ip>` bucket (the only IP-keyed limiter in cloud/), which
  # collapsed into ONE GLOBAL bucket.
  #
  # The gateway is PINNED to a single address, never a CIDR range (charter D5).
  # With a 172.16.0.0/12 widening applied, peer {172,18,0,77} successfully forged
  # 203.0.113.5 — and cloud-postfix-1 sits on 172.18.0.2 publishing 0.0.0.0:587
  # to the internet, so the wide version would hand an internet-facing SMTP
  # container the ability to forge any client's session IP and rate bucket.
  # Pinning excludes .2/.3/.4 by construction.
  #
  # The list is config-driven (charter D6) so it shares ONE source of truth with
  # the pinned `networks:` subnet in cloud/docker-compose.yml: an operator who
  # moves the bridge sets TRUSTED_PROXY_PEERS and the compose subnet together.
  # A bare hardcoded tuple would rot into a silent no-op the next time the stack
  # is recreated onto a different auto-allocated subnet — with a test still
  # asserting it works.
  #
  # conn.remote_ip is an :inet address tuple; anything else (nil / malformed) is
  # treated as untrusted.
  defp trusted_peer?({127, _, _, _}), do: true
  defp trusted_peer?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp trusted_peer?(peer) when is_tuple(peer) do
    # `|| []` because an explicit `nil` in config is a plausible operator typo
    # and `x in nil` raises — a 500 on EVERY request. Fail closed, never loudly.
    peer in (Application.get_env(:barkpark_cloud, :trusted_proxy_peers) || [])
  end

  defp trusted_peer?(_), do: false

  # Front-door canonicalization: 308 www.<dashboard-host> -> the apex dashboard
  # origin, carrying the path AND query string through (the device-link `?code=`
  # is the payload). Scoped to an EXACT match on "www." <> dashboard host, so
  # localhost / raw-IP probes, api.barkpark.cloud, and lookalike hosts fall
  # through. 308 keeps the method and is cacheable as permanent.
  defp canonicalize_dashboard_host(conn, _opts) do
    base = dashboard_base_url()
    dashboard_host = URI.parse(base).host

    if is_binary(dashboard_host) and conn.host == "www." <> dashboard_host do
      conn
      |> put_resp_header("location", canonical_dashboard_location(conn, base))
      |> send_resp(308, "")
      |> halt()
    else
      conn
    end
  end

  # The canonical dashboard origin (scheme + host, no trailing slash), from
  # :dashboard_url config — DASHBOARD_URL-overridable, "https://barkpark.cloud"
  # in every env. Shared with activate_url/1 so there is one source of truth.
  defp dashboard_base_url do
    String.trim_trailing(
      Application.get_env(:barkpark_cloud, :dashboard_url) || "https://barkpark.cloud",
      "/"
    )
  end

  # Rebuild the target URL on the canonical origin, preserving the original path
  # and (when present) the query string verbatim.
  defp canonical_dashboard_location(conn, base) do
    case conn.query_string do
      "" -> base <> conn.request_path
      query -> base <> conn.request_path <> "?" <> query
    end
  end

  # The side-effecting-GET fence (see the block above `plug(Plug.Head)`).
  #
  # Answers 405 + `allow: GET` — NOT 404 (D12). "This path exists, that method is
  # refused" is the honest answer; 404 is the exact lie `plug(Plug.Head)` was
  # landed to remove, and re-telling it here would undo that fix on these paths.
  #
  # Matching is on `conn.path_info` SEGMENT LISTS, never a string prefix (D14).
  # This plug runs before `:match`, so `conn.path_params` is EMPTY — there is no
  # `:provider` to read — and the initiator and the callback share a prefix, so a
  # `String.starts_with?("/v1/auth/oauth")` guard would be both over-broad (it
  # would swallow the read-only providers list) and under-specific. The segment
  # arity does the discrimination for free.
  #
  # COVERAGE BOUNDARY, stated deliberately: this list fences exactly THREE routes,
  # and 3 is a FLOOR, not a ceiling. It does NOT cover the 45 authenticated GETs
  # on which a bare HEAD also performs a DB write (every authenticated request
  # touches `user_tokens.last_used_at`) — that is a property of AUTHENTICATION,
  # not of any route, so there is no route subset to carve out, and denying HEAD
  # across 45 of the 56 top-level GETs would reinstate the 404 lie on four fifths
  # of the API (D34). Out of scope BY DECISION. Do not grow this list to cover
  # them. Full measurement lives on task cch-w2-head-sideeffect-fence.
  defp refuse_head_on_side_effecting_gets(%Plug.Conn{method: "HEAD"} = conn, _opts) do
    if side_effecting_get?(conn.path_info) do
      conn
      |> put_resp_header("allow", "GET")
      |> json(405, %{error: "method_not_allowed"})
      |> halt()
    else
      conn
    end
  end

  defp refuse_head_on_side_effecting_gets(conn, _opts), do: conn

  # `/v1/auth/oauth/providers` is a READ (the SPA's button list) and shares the
  # initiator's segment arity, because `get "/v1/auth/oauth/providers"` is
  # declared BEFORE `get "/v1/auth/oauth/:provider"` and wins the match. It must
  # be excluded FIRST or this fence would 405 a harmless read — the concrete form
  # of the D14 trap.
  defp side_effecting_get?(["v1", "auth", "oauth", "providers"]), do: false

  # cch-w10: `/v1/auth/oauth/exchange` is a POST-ONLY path that shares the
  # initiator's segment arity, so without this clause the fence would 405 it — and
  # a 405 with `allow: GET` would be a LIE about a path that has no GET handler.
  # It is not side-effecting under a GET either: `OAuth.authorize_url/1` resolves
  # the provider before `mint_state/1` runs, and "exchange" resolves to nothing, so
  # the initiator answers 404 `provider_not_enabled` having written no row. Same
  # shape as the `providers` exclusion above (the D14 trap) and it must likewise
  # come FIRST.
  defp side_effecting_get?(["v1", "auth", "oauth", "exchange"]), do: false

  # Mints an `oauth_states` row per hit (OAuth.authorize_url → mint_state), on an
  # UNAUTHENTICATED route.
  defp side_effecting_get?(["v1", "auth", "oauth", _provider]), do: true

  # Consumes the single-use state nonce, may CREATE a user, and mints a live
  # session token that it returns in the `location` header.
  defp side_effecting_get?(["v1", "auth", "oauth", _provider, "callback"]), do: true

  # BURNS a live single-use SSE ticket. `require_user_sse` reads `?ticket=` and
  # hands it to `Accounts.consume_sse_ticket_binding/1` (the same redemption as
  # `consume_sse_ticket/1`, returning the stream's session binding as well), which
  # takes a BARE BINARY and stamps `revoked_at` unconditionally — structurally
  # method-blind, and rightly so: the credential is spent by REDEMPTION, not by a
  # verb. Without this clause any unfurler's `HEAD /v1/events?ticket=…` (the URL is
  # in every access log, because EventSource cannot set headers) spends a ticket
  # the real stream has not yet redeemed, and the user's own connect then 401s.
  # There is exactly ONE ticket-redeeming call site in lib/, so this one clause is
  # SUFFICIENT, not a sample — see `router_sse_ticket_head_burn_test.exs`.
  defp side_effecting_get?(["v1", "events"]), do: true

  defp side_effecting_get?(_path_info), do: false

  @doc """
  A `Plug.Parsers` `:body_reader` that caches the RAW request body on
  `conn.assigns[:raw_body]` for HMAC-verifying webhook paths (Stripe billing +
  GitHub push), then returns those same bytes so the JSON parser still runs.
  Every other path falls through to the default reader with no buffering.
  """
  def cache_raw_body(conn, opts) do
    if needs_raw_body?(conn.request_path) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
      {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
    else
      Plug.Conn.read_body(conn, opts)
    end
  end

  defp needs_raw_body?(path) do
    path in @raw_body_paths or
      Enum.any?(@raw_body_path_prefixes, &String.starts_with?(path, &1))
  end

  ## Dashboard SPA — GET / and GET /dashboard serve the single-page app.
  ##
  ## Plug.Static (above) handles the named assets (/index.html, /app.css,
  ## /app.js); these two routes serve the SPA shell at the bare root and at
  ## /dashboard so a deep-link or a refresh on either lands the HTML (the SPA
  ## then routes client-side on the hash). The JSON API lives entirely under
  ## /v1/*, so this never collides with it.

  get("/", do: send_dashboard(conn))
  get("/dashboard", do: send_dashboard(conn))

  ## dwb-6 "/new?template=<slug>" — the deploy-button landing. A REAL path (not a
  ## hash) so a marketing badge links straight to it and a refresh/deep-link lands
  ## the SPA shell; app.js reads `?template=` off location.search and drives the
  ## template-card → Launch → live-progress → ready flow client-side. Served by the
  ## same shell as "/"; the JSON API is entirely under /v1/*, so no collision.
  get("/new", do: send_dashboard(conn))

  ## bp-login-ux W1 — "/activate" is the device-login approve page. A REAL path
  ## (like "/new") so `bp login`'s boxed verification_uri deep-links straight to
  ## it and a refresh/paste lands the SPA shell; app.js detects location.pathname
  ## === "/activate", reads an optional ?code= prefill, and drives the
  ## inspect → Approve/Deny flow against POST /v1/auth/device/* (owned by S1).
  ## Served by the same shell as "/"; the JSON API is entirely under /v1/*.
  get("/activate", do: send_dashboard(conn))

  ## Stripe Checkout returns the customer to the SPA root with a ?checkout=
  ## success|cancel flag (see Billing.StripeGateway / #282) — no dedicated route
  ## is needed since "/" already serves the SPA and it's hash-routed. app.js
  ## reads the query flag, shows the right state, and refetches the now-active
  ## subscription (the webhook activates it server-side; SSE also pushes a
  ## "subscription" event the moment it lands).

  defp send_dashboard(conn) do
    path = Application.app_dir(:barkpark_cloud, "priv/static/index.html")

    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, path)
  end

  ## Auth — POST /v1/auth/login {email, password}
  ##   → 200 {token, team_id}                          — non-2FA user, logged in
  ##   → 200 {two_factor_required: true, challenge_token} — 2FA user, step two
  ##   → 401 {error: "invalid_credentials"}
  ##
  ## two-factor-auth: the non-2FA response shape is UNCHANGED ({token, team_id}),
  ## so existing clients/tests keep working. A user with confirmed 2FA gets a
  ## short-lived challenge_token instead of a session — they must clear
  ## POST /v1/auth/two-factor-challenge to upgrade it into a real session.

  post "/v1/auth/login" do
    email = conn.body_params["email"]
    password = conn.body_params["password"]

    with true <- is_binary(email) and is_binary(password),
         %{} = user <- Accounts.get_user_by_email_and_password(email, password) do
      if Accounts.two_factor_enabled?(user) do
        case Accounts.create_two_factor_pending_token(user) do
          {:ok, pending} ->
            json(conn, 200, %{two_factor_required: true, challenge_token: pending})

          {:error, %Ecto.Changeset{} = cs} ->
            json(conn, 422, %{error: "invalid", details: errors(cs)})
        end
      else
        # ORIGIN "password": this branch is reached only when 2FA is OFF, so the
        # password check above is the whole of what established the session.
        case Accounts.create_user_session_token(user, session_opts(conn) ++ [origin: "password"]) do
          {:ok, token} ->
            team = Accounts.primary_team(user)
            json(conn, 200, %{token: token, team_id: team && team.id})

          {:error, %Ecto.Changeset{} = cs} ->
            json(conn, 422, %{error: "invalid", details: errors(cs)})
        end
      end
    else
      _ -> json(conn, 401, %{error: "invalid_credentials"})
    end
  end

  ## two-factor-auth — POST /v1/auth/two-factor-challenge
  ##   body {challenge_token, code} OR {challenge_token, recovery_code}
  ##   → 200 {token, team_id}        — OTP/recovery accepted; full session minted
  ##   → 401 {error: "invalid_code"} — bad token, bad OTP, or unknown recovery code
  ##   → 429 {error: "rate_limited", retry_after: <seconds>} — >5 attempts/min
  ##     for this pending user
  ##
  ## Step two of the two-phase login. The challenge_token is the 2fa-pending
  ## token from /v1/auth/login; a correct OTP or an unused recovery code swaps it
  ## for a real session token (same {token, team_id} shape login returns for a
  ## non-2FA user). The minted session records device metadata via
  ## session_opts(conn), exactly like the non-2FA path. The rate limiter mirrors
  ## Coolify's 5/min on this challenge.
  ##
  ## `retry_after` is the whole seconds left of the limiter's fixed window (the
  ## `POST /v1/notifications/test` precedent below): the caller is told exactly
  ## when the budget refills instead of being left to guess, and the SPA can
  ## count a real number down. It is a legitimate-user affordance only — the
  ## number leaks nothing an attacker can't derive from the 60s window itself.

  post "/v1/auth/two-factor-challenge" do
    pending = conn.body_params["challenge_token"]
    code = conn.body_params["code"]
    recovery = conn.body_params["recovery_code"]

    case is_binary(pending) and Accounts.verify_two_factor_pending_token(pending) do
      %{} = user ->
        case TwoFactorRateLimiter.check(user.id) do
          {:error, {:rate_limited, retry_after}} ->
            json(conn, 429, %{error: "rate_limited", retry_after: retry_after})

          :ok ->
            ok? =
              cond do
                is_binary(code) and code != "" ->
                  Accounts.verify_two_factor_otp(user, code)

                is_binary(recovery) and recovery != "" ->
                  match?({:ok, _}, Accounts.consume_recovery_code(user, recovery))

                true ->
                  false
              end

            if ok? do
              # Read the first factor BEFORE the burn below deletes the row that
              # carries it.
              first_factor = Accounts.two_factor_pending_first_factor(pending)

              Accounts.delete_two_factor_pending_tokens(user)

              # ORIGIN, RESOLVED FROM WHATEVER MINTED THIS CHALLENGE — never
              # assumed. A second factor — an OTP or a recovery code — cleared to
              # reach here; deliberately not split into otp-vs-recovery, since the
              # `ok?` cond above collapses both to a boolean before this point and
              # re-deriving which one fired would be a guess.
              #
              # WHICH FIRST factor cleared is NOT a guess, though, and since
              # cch-w53-s6 it is no longer assumed to be the password. The plain
              # "two_factor" still means what its old comment said — the password
              # leg passed and minted this token. An OAuth-minted challenge
              # (POST /v1/auth/oauth/exchange) carries its provider here on the
              # pending token's own `sent_to`, and the session says so: stamping
              # an IdP sign-in as a password sign-in would be exactly the
              # misattribution this surface exists to avoid.
              case Accounts.create_user_session_token(
                     user,
                     session_opts(conn) ++
                       case first_factor do
                         "oauth:" <> _ -> [origin: first_factor <> "+two_factor"]
                         _ -> [origin: "two_factor"]
                       end
                   ) do
                {:ok, token} ->
                  team = Accounts.primary_team(user)
                  json(conn, 200, %{token: token, team_id: team && team.id})

                {:error, %Ecto.Changeset{} = cs} ->
                  json(conn, 422, %{error: "invalid", details: errors(cs)})
              end
            else
              json(conn, 401, %{error: "invalid_code"})
            end
        end

      _ ->
        json(conn, 401, %{error: "invalid_code"})
    end
  end

  ## Device authorization (bp-login-ux) — Claude-Code-style copy-link `bp login`.
  ##
  ## An RFC-8628-shaped handshake with two secrets: the CLI polls with a
  ## `device_code`; the human types a short `user_code` (XXXX-XXXX) into the
  ## browser to approve. See `BarkparkCloud.DeviceAuth`. Five routes:
  ##
  ##   POST /v1/auth/device/start   —      {client_name} → codes + verification URIs
  ##   POST /v1/auth/device/poll    —      {device_code} → pending | {token,team_id} | slow_down | expired
  ##   POST /v1/auth/device/inspect user   {user_code}   → who is asking (confirm screen)
  ##   POST /v1/auth/device/approve user   {user_code}   → {ok:true} (pending→approved CAS)
  ##   POST /v1/auth/device/deny    user   {user_code}   → {ok:true}
  ##
  ## start + poll are unauthenticated (the CLI has no session yet) but rate-limited
  ## by IP / device_code. inspect/approve/deny are behind Auth.require_user — the
  ## Bearer session is the 2FA guarantee: the mint function itself doesn't enforce
  ## 2FA, so approve must NEVER run unauthenticated (charter decision 5).

  ## POST /v1/auth/device/start {client_name}
  ##   → 200 {device_code, user_code, verification_uri, verification_uri_complete,
  ##          interval, expires_in}
  ##   → 429 {error: "rate_limited"} — >10 starts/min for this IP
  post "/v1/auth/device/start" do
    ip = peer_ip(conn)

    case DeviceAuthRateLimiter.check("start:" <> (ip || "unknown")) do
      {:error, :rate_limited} ->
        json(conn, 429, %{error: "rate_limited"})

      :ok ->
        attrs = %{
          client_name: conn.body_params["client_name"],
          ip_address: ip,
          user_agent: get_first_header(conn, "user-agent")
        }

        case DeviceAuth.start(attrs) do
          {:ok, %{device_code: dc, user_code: uc, interval: interval, expires_in: expires_in}} ->
            base = activate_url(conn)

            json(conn, 200, %{
              device_code: dc,
              user_code: uc,
              verification_uri: base,
              verification_uri_complete: base <> "?code=" <> uc,
              interval: interval,
              expires_in: expires_in
            })

          {:error, _changeset} ->
            json(conn, 500, %{error: "server_error"})
        end
    end
  end

  ## POST /v1/auth/device/poll {device_code}
  ##   → 200 {status: "pending"}          — not yet approved
  ##   → 200 {token, team_id}             — approved: session minted (byte-identical to /login)
  ##   → 429 {error: "slow_down"}         — >20 polls/min for this device_code
  ##   → 404 {error: "expired_or_invalid"} — expired, denied, replayed, or unknown
  post "/v1/auth/device/poll" do
    device_code = conn.body_params["device_code"]

    if is_binary(device_code) and device_code != "" do
      case DeviceAuthRateLimiter.check("poll:" <> DeviceAuth.device_code_hash(device_code)) do
        {:error, :rate_limited} ->
          json(conn, 429, %{error: "slow_down"})

        :ok ->
          case DeviceAuth.poll(device_code) do
            {:pending} ->
              json(conn, 200, %{status: "pending"})

            {:ok, token, team} ->
              json(conn, 200, %{token: token, team_id: team && team.id})

            {:error, :expired_or_invalid} ->
              json(conn, 404, %{error: "expired_or_invalid"})
          end
      end
    else
      json(conn, 404, %{error: "expired_or_invalid"})
    end
  end

  ## POST /v1/auth/device/inspect {user_code} (require_user)
  ##   → 200 {client_name, ip_address, user_agent, expires_at} — for the confirm screen
  ##   → 404 {error: "expired_or_invalid"}
  ##   → 429 {error: "rate_limited"} — shares the approve:<user_id> budget: inspect
  ##     answers "is this user_code valid?", so an unmetered inspect would be the
  ##     brute-force oracle the approve limit exists to close (charter decision 7)
  post "/v1/auth/device/inspect" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      user = conn.assigns.current_user

      case DeviceAuthRateLimiter.check("approve:" <> user.id) do
        {:error, :rate_limited} ->
          json(conn, 429, %{error: "rate_limited"})

        :ok ->
          case DeviceAuth.inspect(conn.body_params["user_code"] || "") do
            {:ok, row} ->
              json(conn, 200, %{
                client_name: row.client_name,
                ip_address: row.ip_address,
                user_agent: row.user_agent,
                expires_at: row.expires_at
              })

            {:error, :expired_or_invalid} ->
              json(conn, 404, %{error: "expired_or_invalid"})
          end
      end
    end
  end

  ## POST /v1/auth/device/approve {user_code} (require_user)
  ##   → 200 {ok: true}                   — pending→approved, user_id stamped
  ##   → 404 {error: "expired_or_invalid"} — unknown / already-approved / denied / expired
  ##   → 429 {error: "rate_limited"}      — >10 approve attempts/min for this user
  post "/v1/auth/device/approve" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      user = conn.assigns.current_user

      case DeviceAuthRateLimiter.check("approve:" <> user.id) do
        {:error, :rate_limited} ->
          json(conn, 429, %{error: "rate_limited"})

        :ok ->
          case DeviceAuth.approve(conn.body_params["user_code"] || "", user.id) do
            :ok -> json(conn, 200, %{ok: true})
            {:error, :expired_or_invalid} -> json(conn, 404, %{error: "expired_or_invalid"})
          end
      end
    end
  end

  ## POST /v1/auth/device/deny {user_code} (require_user) → 200 {ok: true} (idempotent)
  post "/v1/auth/device/deny" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      user = conn.assigns.current_user

      case DeviceAuthRateLimiter.check("approve:" <> user.id) do
        {:error, :rate_limited} ->
          json(conn, 429, %{error: "rate_limited"})

        :ok ->
          :ok = DeviceAuth.deny(conn.body_params["user_code"] || "")
          json(conn, 200, %{ok: true})
      end
    end
  end

  ## Auth — POST /v1/auth/register {email, password, team_name?}
  ##   → 201 {token, team_id} (user created + a team + an owner membership + a
  ##     session token; the caller is logged in immediately, exactly like login)
  ##   → 409 {error: "email_taken"}              (email already registered, and
  ##     the submitted password is VALID — see the enumeration note below)
  ##   → 422 {error: "<field>_invalid"|..., details?}  (bad payload / invalid password)
  ##   → 429 {error: "rate_limited"}             (>30 register attempts/min per IP)
  ##
  ## The whole user→team→membership→token chain runs inside ONE Repo.transaction
  ## (`register/3` below), so a half-way failure rolls back — no orphan user or
  ## team is ever left behind. The duplicate-email check runs BEFORE the insert,
  ## and the citext unique index is the race backstop (a unique-violation on the
  ## email maps to 409, never a 500).
  ##
  ## RATE-LIMITED per IP (arpss w3): each hit is an unauthenticated write that
  ## mints a whole user→team→membership→trial. `"register:"<peer_ip>` (30/60s)
  ## brakes a signup flood — its OWN bucket, distinct from the authed
  ## `"push_register:"` device bucket (same word, different physics). Corporate-NAT
  ## headroom is why it is 30, not the default 10 (see RateLimiter @limits).
  ##
  ## ENUMERATION-SAFE (arpss w3): the password-FORMAT gate runs BEFORE the
  ## `get_user_by_email` duplicate lookup, so an EXISTING email + an INVALID
  ## password answers 422 byte-for-byte identically to a FRESH email + the same
  ## invalid password — a probe cannot turn "409 vs 422" into an account-existence
  ## oracle. Reusing the SAME length rules the registration changeset applies
  ## (`min_password_length()`..72) guarantees the 422 body is the same bytes the
  ## fresh-email path emits from `register_error/1`. The 409 email_taken survives
  ## ONLY for a duplicate carrying a VALID password — the honest signal a real
  ## signup needs (app.js maps {error:"email_taken"} → "That email is already
  ## registered."; client_test.go pins the 409 body). Because the invalid-password
  ## gate sits ahead of BOTH the pre-insert `get_user_by_email` guard AND
  ## `register/4` (whose `classify_register_error` is the citext-race backstop),
  ## neither 409 path can fire for an invalid password — both oracle layers closed.
  post "/v1/auth/register" do
    case DeviceAuthRateLimiter.check("register:" <> (peer_ip(conn) || "unknown")) do
      {:error, :rate_limited} ->
        json(conn, 429, %{error: "rate_limited"})

      :ok ->
        email = conn.body_params["email"]
        password = conn.body_params["password"]
        team_name = conn.body_params["team_name"]

        with true <- is_binary(email) and is_binary(password),
             %Ecto.Changeset{valid?: true} <- register_password_changeset(password),
             nil <- Accounts.get_user_by_email(email) do
          case register(email, password, team_name, session_opts(conn)) do
            {:ok, %{token: token, team: team}} ->
              json(conn, 201, %{token: token, team_id: team.id})

            {:error, :email_taken} ->
              json(conn, 409, %{error: "email_taken"})

            {:error, %Ecto.Changeset{} = changeset} ->
              json(conn, 422, register_error(changeset))
          end
        else
          false -> json(conn, 422, %{error: "validation_failed"})
          # Invalid-password changeset — 422 BEFORE the email lookup (the
          # enumeration seal). Must precede the `%{}` clause: a changeset is a
          # struct and would otherwise be caught as the "existing user" map.
          %Ecto.Changeset{} = changeset -> json(conn, 422, register_error(changeset))
          %{} -> json(conn, 409, %{error: "email_taken"})
        end
    end
  end

  ## Auth — POST /v1/auth/request-reset {email} → 200 {ok: true} (ALWAYS)
  ##
  ## Forgot-password step 1. ENUMERATION-SAFE: answers 200 whether or not the
  ## email is registered, so a probe can't learn which addresses have accounts.
  ## When a user matches, a single-use reset token is minted and the reset LINK is
  ## EMAILED — never returned in the response. (Contrast the invite flow, which
  ## hands the accept token back in `accept_url` for copy-paste: a reset link in
  ## the HTTP body would let anyone reset anyone's password by calling this.)
  ## YAGNI: rate-limiting is a fronting-proxy/WAF concern, as for login/register.
  post "/v1/auth/request-reset" do
    email = conn.body_params["email"]

    # Best-effort: a mailer/DB hiccup must not change the response (still 200) or
    # leak via timing of a 500 — the user is told "check your email" regardless.
    if is_binary(email) do
      case Accounts.request_password_reset(email) do
        {:ok, {user, raw_token}} ->
          _ = Notifications.deliver_password_reset(user.email, reset_url(conn, raw_token))
          :ok

        _ ->
          :ok
      end
    end

    json(conn, 200, %{ok: true})
  end

  ## Auth — POST /v1/auth/reset {token, password} → 200 {ok: true}
  ##   → 401 {error: "invalid_token"}            (no live/single-use token; also replay/expiry)
  ##   → 422 {error: "password_invalid", ...}    (new password too short/weak)
  ##
  ## Forgot-password step 2. Proving control of the emailed token IS the auth, so
  ## no current password is required. On success the user is signed out everywhere
  ## (sessions + agent tokens revoked in `reset_password_by_token/2`); the client
  ## then sends them to log in fresh with the new password.
  post "/v1/auth/reset" do
    token = conn.body_params["token"]
    password = conn.body_params["password"]

    with true <- is_binary(token) and is_binary(password),
         {:ok, _user} <- Accounts.reset_password_by_token(token, password) do
      json(conn, 200, %{ok: true})
    else
      false -> json(conn, 422, %{error: "validation_failed"})
      {:error, :invalid_token} -> json(conn, 401, %{error: "invalid_token"})
      {:error, %Ecto.Changeset{} = changeset} -> json(conn, 422, register_error(changeset))
    end
  end

  ## OAuth / SSO (oauth-sso) — "Continue with GitHub / Google".
  ##
  ## Four UNAUTHENTICATED routes (they PRECEDE a session, exactly like
  ## /v1/auth/login). The flow is cookieless: a stateless HMAC-signed, SINGLE-USE
  ## `state` guards CSRF + replay.
  ##
  ## cch-w10 — WHAT COMES BACK ON THE FRAGMENT IS NO LONGER A SESSION TOKEN. A
  ## fragment stays out of access logs and Referer, which is what made the
  ## original handoff defensible, but `location` is a RESPONSE HEADER and the
  ## 302 that carried `#oauth=<30-day token>` handed a live credential to every
  ## TLS-terminating middlebox, reverse proxy and APM on the path. The callback
  ## now mints a 120s, hashed, single-use EXCHANGE CODE; the SPA POSTs it to
  ## /v1/auth/oauth/exchange at boot and gets the real token in a response BODY.
  ## See BarkparkCloud.OAuth and Accounts.create_oauth_exchange_code/2.
  ##
  ##   GET  /v1/auth/oauth/providers          200 {providers:[…]}  (enabled only)
  ##   GET  /v1/auth/oauth/:provider          302 → IdP authorize URL (404 if off)
  ##   GET  /v1/auth/oauth/:provider/callback 302 → /#oauth_code=<code>&team=<id>
  ##                                          (302 → /#oauth_error=oauth_failed on any failure)
  ##   POST /v1/auth/oauth/exchange           200 {token, team_id} | 401 {error:"invalid_code"}
  ##                                          (no GET twin on the path — see the route)

  # The SPA reads this to decide which "Continue with …" buttons to render —
  # only fully-configured providers (client_id+secret set) appear. No auth: a
  # logged-out visitor needs it to render the sign-in screen.
  get "/v1/auth/oauth/providers" do
    json(conn, 200, %{providers: OAuth.enabled_providers()})
  end

  # dwb-6 template catalog — PUBLIC (no auth): it's the marketing surface the
  # `/new?template=<slug>` card renders BEFORE the visitor signs in. Returns the
  # display metadata mirror (title/description/what-you-get/env-keys/repo), whose
  # slugs are lock-tested against Registry.known_templates/0. No secrets — env
  # KEYS only (values are pasted by the user at deploy time).
  get "/v1/templates" do
    # `deployable` marks the templates that ship a standalone Next.js app tree
    # (so the gh-3 "Create GitHub repo" affordance can push one). place-directory
    # is launchable as a managed instance but has no app tree → not deployable.
    templates =
      Enum.map(BarkparkCloud.Templates.catalog(), fn t ->
        Map.put(t, :deployable, BarkparkCloud.Templates.AppFiles.app_template?(t.slug))
      end)

    json(conn, 200, %{templates: templates})
  end

  # Kick off the flow: 302 the browser to the IdP's authorization URL (carrying
  # client_id, the derived redirect_uri, scope, and a freshly-minted single-use
  # signed state). An unknown or disabled :provider is a 404 — same gate Coolify
  # puts on the route via the provider's `enabled` flag.
  get "/v1/auth/oauth/:provider" do
    provider = conn.path_params["provider"]

    case OAuth.authorize_url(provider) do
      {:ok, url, _state} -> redirect_to(conn, url)
      {:error, :provider_not_enabled} -> json(conn, 404, %{error: "provider_not_enabled"})
    end
  end

  # The IdP redirects back here with ?code&state (or ?error= when the user
  # declined / the IdP refused). An IdP error is handled FIRST — a clean generic
  # redirect, never a crash and never an exchange attempt. Otherwise: verify the
  # single-use state (CSRF + replay), trade the code for the user's VERIFIED
  # identity, resolve-or-birth the Cloud user (safe (provider, provider_uid)
  # linking — never email), mint a ONE-TIME EXCHANGE CODE, and 302 to the SPA
  # with THAT on the fragment.
  #
  # cch-w10 — WHAT USED TO RIDE THE FRAGMENT AND WHY IT MOVED. This handler used
  # to mint the session token itself and 302 to `/#oauth=<token>`. `redirect_to/2`
  # is `put_resp_header("location", …) + send_resp(302, "")`, so the ONE
  # legitimate response of the whole sign-in carried a live 30-day session token
  # in a RESPONSE HEADER. A fragment never reaches a SERVER access log, which is
  # what made the original design defensible — but it is fully visible to
  # anything that logs RESPONSE headers: a TLS-terminating middlebox, a reverse
  # proxy, an APM agent. Same class as the `?token=` that `GET /v1/events` used
  # to take, and the same answer: make the thing on the wire worthless. The code
  # here lives 120 seconds, is stored only as a SHA-256 hash, and is burned by the
  # SPA's own `POST /v1/auth/oauth/exchange`.
  #
  # IDENTITY RESOLUTION STAYS HERE. Only the session mint moved. Every failure
  # therefore still collapses to ONE generic /#oauth_error=oauth_failed redirect
  # (like Coolify's single translated `auth.failed`) — no provider/internal
  # detail leaks, and a bad/expired/forged/replayed state creates NO user and NO
  # credential of any kind.
  get "/v1/auth/oauth/:provider/callback" do
    provider = conn.path_params["provider"]

    if is_binary(conn.query_params["error"]) do
      # The IdP declined (e.g. ?error=access_denied) — the user cancelled or the
      # provider refused. No code to exchange; render the clean auth error.
      redirect_to(conn, "/#oauth_error=oauth_failed")
    else
      code = conn.query_params["code"]
      state = conn.query_params["state"]

      with true <- OAuth.enabled?(provider),
           true <- is_binary(code) and is_binary(state),
           :ok <- OAuth.verify_state(state, provider),
           {:ok, identity} <- OAuth.fetch_identity(provider, code),
           {:ok, user} <- Accounts.get_or_create_user_from_oauth(identity),
           # `provider` is already bound by this with-chain and IS the answer, so
           # it rides the code's own `sent_to` as "oauth:<provider>" — that is how
           # the honest `origin: "oauth:<provider>"` survives the mint moving to
           # the exchange. No inference anywhere; each provider reports itself
           # rather than collapsing to a generic "oauth".
           {:ok, exchange_code} <- Accounts.create_oauth_exchange_code(user, provider) do
        team = Accounts.primary_team(user)
        redirect_to(conn, "/#oauth_code=#{exchange_code}&team=#{team && team.id}")
      else
        _ -> redirect_to(conn, "/#oauth_error=oauth_failed")
      end
    end
  end

  # POST /v1/auth/oauth/exchange {code}
  #   → 200 {token, team_id}                             — no second factor, signed in
  #   → 200 {two_factor_required: true, challenge_token}  — 2FA user, step two
  #   → 401 {error: "invalid_code"}
  #   → 429 {error: "rate_limited"}
  #
  # The second half of the cch-w10 handoff: the SPA boots,
  # reads the one-time code off its own fragment, and trades it here for the real
  # session token — over a request whose credential is in the BODY, never in a
  # response header.
  #
  # UNAUTHENTICATED by construction (there is no session yet), so it is NOT behind
  # Auth.require_user. What stands in for auth is the code itself: 32 bytes of
  # `:crypto.strong_rand_bytes`, hashed at rest, 120s TTL, burned matched-row-only
  # under `FOR UPDATE`, plus a per-IP rate limit on the redemption attempt.
  #
  # DELIBERATELY NO GET TWIN ON THIS PATH — and the PATH-has-no-GET part is the
  # actual invariant, not the verb. `plug(Plug.Head)` rewrites HEAD→GET
  # unconditionally BEFORE matching, so a HEAD prober can only be refused by there
  # being no GET clause that reaches this handler. (Measured counterexample
  # elsewhere in this router: HEAD /v1/tokens answers 401, not 404, precisely
  # because a GET twin lives beside its POST.) Pinned by router_oauth_test.exs.
  #
  # HONEST FOOTNOTE ON THAT 404, because "no GET clause on the path" is not
  # literally true here: `get "/v1/auth/oauth/:provider"` has the same segment
  # arity and DOES pattern-match "/v1/auth/oauth/exchange". It answers 404
  # `provider_not_enabled` because `OAuth.authorize_url/1` resolves the provider
  # BEFORE it mints anything, so "exchange" fails closed with zero side effects —
  # no oauth_states row, no credential, no reachable handler. The prober's outcome
  # is the one the invariant is about; the route it fell through is named here so
  # nobody later reads the test's `== 404` as proof of a route that isn't there.
  #
  # SESSION METADATA MOVES WITH THE MINT: session_opts(conn) now captures the
  # BROWSER's own IP + User-Agent (this XHR) instead of the IdP redirect hop's, so
  # the sessions security panel gets the more useful of the two.
  post "/v1/auth/oauth/exchange" do
    code = conn.body_params["code"]

    # 30/min/IP, an EXPLICIT entry rather than the limiter's @default_limit of 10:
    # this is the last hop of a sign-in and every user behind one corporate NAT
    # shares a peer_ip, so 10 starves exactly the population the module's own
    # push_register docstring flags. It is still a hard bound on guessing a
    # 256-bit code.
    case DeviceAuthRateLimiter.check("oauth_exchange:" <> (peer_ip(conn) || "unknown")) do
      {:error, :rate_limited} ->
        json(conn, 429, %{error: "rate_limited"})

      :ok ->
        with true <- is_binary(code),
             {user, origin} <- Accounts.consume_oauth_exchange_code(code) do
          if Accounts.two_factor_enabled?(user) do
            # cch-w53-s6 — THE SECOND FACTOR IS NOT OPTIONAL ON THIS LEG EITHER.
            # A verified IdP identity is ONE factor, and `get_or_create_user_from_oauth`
            # links by verified email on purpose (accounts.ex:139), so a password
            # account that enrolled in TOTP is reachable through here the moment a
            # provider is configured. Minting a session at this point would let
            # control of an email address stand in for the enrolled second factor.
            #
            # NEVER A HARD REFUSE — the answer is the challenge shape the password
            # leg already returns above, because an OAuth-born account can be
            # passwordless (User.oauth_changeset hashes 32 random bytes) with a
            # synthetic `@oauth.users.barkpark.cloud` address the emailed reset
            # can never reach. Refusing them here would be permanent.
            case Accounts.create_two_factor_pending_token(user, origin) do
              {:ok, pending} ->
                json(conn, 200, %{two_factor_required: true, challenge_token: pending})

              # Falls in with the single refusal below rather than leaking a
              # changeset: the code is already burned, so a retry is the sign-in,
              # not a repair.
              {:error, %Ecto.Changeset{}} ->
                json(conn, 401, %{error: "invalid_code"})
            end
          else
            case Accounts.create_user_session_token(user, session_opts(conn) ++ [origin: origin]) do
              {:ok, token} ->
                team = Accounts.primary_team(user)
                json(conn, 200, %{token: token, team_id: team && team.id})

              {:error, %Ecto.Changeset{}} ->
                json(conn, 401, %{error: "invalid_code"})
            end
          end
        else
          # ONE generic refusal for unknown / burned / expired / malformed, exactly
          # like the callback's single redirect: a prober must not learn which.
          _ -> json(conn, 401, %{error: "invalid_code"})
        end
    end
  end

  ## Auth — POST /v1/auth/verify-email {token} → 200 {ok: true} | 422 {error:
  ## "invalid_token"}. The emailed `?confirm=` link reaches the hash-routed SPA,
  ## which POSTs the token here (no cookie session, so CSRF-trivial). Confirming
  ## twice / after a revoke fails closed as invalid_token (single-use).
  post "/v1/auth/verify-email" do
    token = conn.body_params["token"]

    with true <- is_binary(token),
         {:ok, _user} <- Accounts.confirm_user(token) do
      json(conn, 200, %{ok: true})
    else
      _ -> json(conn, 422, %{error: "invalid_token"})
    end
  end

  ## Agent routes (agent-token auth)

  # POST /v1/agent/report — body is the cloud-10 agent Report (see
  # internal/agent/report.go). Lands the health columns via upsert_health and the
  # health-gate signals via record_event. → 200 {ok: true}.
  post "/v1/agent/report" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      barkpark = conn.assigns.current_barkpark
      report = conn.body_params

      # The health BEFORE this report — so we can detect an up↔down FLIP and
      # email only on the transition (Coolify alerts on the flip, not every
      # cycle), never on a steady-state report.
      prior_health = barkpark.health_status
      new_health = normalize_health(report["health_status"])

      # health-status: land the report AND re-arm the staleness latch in one
      # call. record_agent_report/2 lands the health columns (upsert_health) and
      # then zeroes unreachable_count + clears unreachable_notification_sent, so a
      # box the StalenessWorker had latched offline can alert again on a LATER
      # outage. The recovery EMAIL itself is emitted below by
      # maybe_dispatch_health_flip (unknown→up ⇒ :agent_reachable) — no parallel
      # dispatch here.
      _ =
        Registry.record_agent_report(barkpark, %{
          health_status: new_health,
          agent_status: normalize_agent(report["agent_status"]),
          version: report["version"],
          git_commit: report["git_commit"],
          last_seen_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
        })

      # The agent's per-cycle signals become one append-only event. The full
      # report rides in the payload so the dashboard/event stream can show disk,
      # PG size, dirty-tree, and the granular health checks. (The payload's
      # `backup_ok` key rides too, but it is an unwired constant false — no
      # BackupProbe exists — so it is not a signal the stream can honestly
      # show; cch-w50-bl owns wiring it.)
      _ = Registry.record_event(barkpark, "health", report)

      # Push "fleet" so a live health change (up/down, version, agent online)
      # reflects on the dashboard without a manual refresh.
      push_event(barkpark.team_id, "fleet")

      # notifications-email: alert on a health FLIP only (down→up reachable,
      # up→down unreachable). Additive to the SSE push above.
      maybe_dispatch_health_flip(barkpark, prior_health, new_health)

      json(conn, 200, %{ok: true})
    end
  end

  # POST /v1/agent/space — body is the agent's SpaceReport (see
  # internal/agent/report.go): root used/total bytes, journal bytes, PG size +
  # its biggest named relations, and the sites tree + its biggest slugs. Lands
  # ONE append-only `space` AgentEvent and answers 200 {ok: true}. This is the
  # ingest half of "what is taking up space"; `Telemetry.normalize_space/1` is
  # the read half.
  #
  # STRICTLY SMALLER THAN /v1/agent/report — the same agent auth, and then five
  # deliberate NON-actions, each a decision rather than an omission:
  #
  #   * NO record_agent_report. A space post must never move health_status /
  #     last_seen_at / version / agent_status: a box whose disk probe still
  #     succeeds while its BEAT is dead must keep reading as stale. This is the
  #     most important negative in the design.
  #   * NO maybe_dispatch_health_flip — a disk reading is not a health signal
  #     and must not email anyone that a box came back.
  #   * NO push_event(team_id, "fleet") — a 15-minute disk row does not justify
  #     waking every open dashboard.
  #   * NO dispatch on the body's `type` field. The agent carries `type:
  #     "space"` inline so a landing site records it verbatim rather than
  #     guessing, but the TYPE THIS ROUTE WRITES IS HARDCODED; the schema's
  #     validate_inclusion is the second fence, never the first.
  #   * NO retention change. AgentRetentionWorker prunes agent_events on
  #     inserted_at with no type predicate, so space rows inherit the 14-day
  #     window for free (+96 rows/day/box against ~1440 health beats, +6.7%).
  post "/v1/agent/space" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      _ = Registry.record_event(conn.assigns.current_barkpark, "space", conn.body_params)

      json(conn, 200, %{ok: true})
    end
  end

  # GET /v1/agent/commands — the approved-command queue. Empty for now: the
  # command-queue source is a later concern (cloud-13). Returns [] so the Go
  # agent's `len(cmds) == 0` fast-path is exercised. Shape: a JSON array of
  # {id, name} — the agent decodes straight into []Command.
  get "/v1/agent/commands" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, command_queue())
    end
  end

  # POST /v1/agent/results — body is a JSON array of CommandResult. With an empty
  # queue the agent never POSTs here, but the route exists and acks so a future
  # queue source has its landing spot. → 200 {ok: true}.
  post "/v1/agent/results" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, %{ok: true})
    end
  end

  ## User routes (session-token auth)

  # GET /v1/me → 200 {user: {id, email}, team: {id, name, slug}} — who am I.
  # The dashboard topbar uses this for the real team NAME + the account email
  # instead of a raw, opaque "Team a1b2c3d4" id slice.
  get "/v1/me" do
    conn = conn |> Auth.require_user_or_pat([]) |> Auth.require_ability("read")

    if conn.halted do
      conn
    else
      user = conn.assigns.current_user
      team = conn.assigns.current_team
      # ONE role read, spent by both the top-level `role:` key and
      # `team_authority.role` — the two state the same fact and a second lookup
      # would let a future edit desync them (and costs an extra membership read
      # on every boot).
      team_role = team && Accounts.team_role(user, team)

      json(conn, 200, %{
        # two-factor-auth: the SPA reads two_factor_enabled to render the right
        # Security-panel state on load. The secret/codes columns are NEVER
        # serialized — only the boolean on/off switch. email-verification adds
        # `confirmed` so the SPA can nudge an unverified account.
        user: %{
          id: user.id,
          email: user.email,
          confirmed: not is_nil(user.confirmed_at),
          two_factor_enabled: Accounts.two_factor_enabled?(user),
          # platform-operator: fail-closed boolean derived SOLELY from the
          # `:platform_admin_emails` config allowlist (resolved to registered
          # users), NEVER a team role — owner/admin is a different axis (Authz
          # law: authority reads from the membership row, never anything
          # global). Unset/empty allowlist ⇒ false, always. Interim principal
          # per charter GR9 — isu-backlog-operator-principal inherits/reconciles
          # this boolean once a first-class platform-operator principal lands.
          platform_operator: user.email in Notifications.platform_admin_emails()
        },
        team: team && %{id: team.id, name: team.name, slug: team.slug},
        # EVERY membership, so the SPA's team switcher can render — a user who
        # accepted an invite into a second team is otherwise stranded on their
        # oldest (signup) team with no way to reach the one they joined.
        teams:
          Enum.map(Accounts.list_user_teams(user), fn t ->
            %{id: t.id, name: t.name, slug: t.slug, role: Accounts.team_role(user, t)}
          end),
        # The caller's role in their current team — the SPA hides/shows the
        # invite + member-management controls on this. nil when teamless.
        role: team_role,
        # The team authority the GATE will enforce, stated on the wire so the
        # console stops re-deriving `role in ["owner","admin"]` locally (six
        # hand-written copies in app.js, none of which can be wrong-proofed).
        # Scoped to the SAME `team` variable as `team:` and `role:` above — one
        # resolved team, never a role from one team beside an id from another.
        # nil when teamless, so a consumer fails CLOSED.
        #
        # These are ROLE facts, NOT capability claims, and the distinction is
        # load-bearing. GR9 is a TWO-AXIS law: `platform_operator` is the other
        # axis and is NOT folded in here, and neither are a PAT's token
        # abilities. `/v1/me` is PAT-reachable behind require_ability("read"),
        # so a READ-ONLY PAT held by an owner already receives role: "owner" —
        # inert while it describes membership, but emitting a CAPABILITY set
        # ("may delete the instance") would make that over-statement
        # load-bearing against a require_ability("write") 403. Membership is
        # the whole scope.
        #
        # Both booleans come from Authz — the same module the SEVENTEEN
        # `require_team_admin` routes call (auth.ex `&Authz.team_admin?/2`), so
        # against THOSE the wire and the gate are one read. They are NOT the
        # only admin gate: the SEVEN `require_primary_team_admin` routes (1591,
        # 2020, 2059, 3081, 3218, 3342, 3638) go through `Accounts.team_admin?/2`
        # -> `TeamMembership.admin?/1`, a RANK THRESHOLD over `@ranks`, while
        # this boolean is SET MEMBERSHIP over `Authz.@admin_roles` — two
        # hand-maintained tables in two modules. They agree today by
        # coincidence, not by construction, so agreement is ENFORCED rather than
        # assumed: `test/barkpark_cloud/accounts/role_agreement_census_test.exs`
        # ARM C walks a domain DERIVED from both ladders
        # (`TeamMembership.ranked_roles/0` + `Authz.admin_roles/0`), so adding a
        # role to either ladder alone reds by name instead of shipping green.
        team_authority:
          team &&
            %{
              team_id: team.id,
              role: team_role,
              admin: Authz.team_admin?(user, team),
              owner: Authz.team_owner?(user, team)
            },
        # Fold the onboarding summary into the boot read so the SPA renders the
        # "Finish setup" checklist without a second round-trip. Non-secret shape
        # (no gateway/customer ids) — safe for a PAT caller too.
        onboarding: team && onboarding_json(Accounts.onboarding_status(team))
      })
    end
  end

  ## two-factor-auth — account routes (require_user). Enroll / confirm / disable
  ## / regenerate / status. The secret + recovery codes are never echoed except
  ## the one-time recovery-code list and the enroll provisioning material.

  # activity-audit-log (cch-w53-s3): turning 2FA ON and OFF is the most
  # security-relevant act a PLAIN MEMBER can perform on their own account, and
  # until this slice it left no trace under a console heading that promises
  # "Who did what on your team — an append-only audit trail."
  #
  # BEST-EFFORT AND POST-COMMIT, deliberately. The state change has already
  # happened (2FA is on / off) by the time this runs, so nothing here may turn
  # into a 500: a user who cannot enable 2FA because the audit insert failed is
  # a far worse security outcome than a missing row.
  #
  # THE nil-TEAM ARM IS REAL, NOT DEFENSIVE PADDING. `Auth.require_user/2`
  # assigns `:current_team` on every request, but it resolves through
  # `Accounts.primary_team/1`, which is `list_user_teams() |> List.first()` and
  # returns nil for a membership-less user — while `AuditEvent.changeset`
  # requires `team_id` (the column is `null: false`). So that user gets a LOGGED
  # SKIP, never a crash and never a silent discard
  # (cch-w51-bl-record-audit-errors-are-discarded-at-every-call-site).
  #
  # No metadata: there is nothing to say about enabling 2FA that is not the
  # secret or the recovery codes.
  defp audit_account_security(conn, action) do
    user = conn.assigns.current_user

    case conn.assigns[:current_team] do
      nil ->
        Logger.warning(
          "audit #{action} SKIPPED for user #{user.id}: no current_team " <>
            "(Accounts.primary_team/1 returned nil) and audit_events.team_id is null: false"
        )

      team ->
        case Accounts.record_audit(%{
               team_id: team.id,
               actor_user_id: user.id,
               action: action,
               target_type: "user",
               target_id: user.id
             }) do
          {:ok, _event} -> push_event(team.id, "audit")
          {:error, cs} -> Logger.error("audit #{action} failed: #{inspect(cs)}")
        end
    end

    :ok
  end

  # POST /v1/account/two-factor/enroll → 200 {otpauth_uri, secret}
  # Generate + persist a pending (unconfirmed) TOTP secret and return the
  # provisioning material; the SPA renders the QR client-side from otpauth_uri.
  post "/v1/account/two-factor/enroll" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      {:ok, %{otpauth_uri: uri, secret_base32: secret}} =
        Accounts.start_two_factor_enrollment(conn.assigns.current_user)

      json(conn, 200, %{otpauth_uri: uri, secret: secret})
    end
  end

  # POST /v1/account/two-factor/confirm {code}
  #   → 200 {recovery_codes: [...]} — 2FA now ON; codes shown EXACTLY once
  #   → 422 {error: "invalid_otp" | "not_enrolled"}
  post "/v1/account/two-factor/confirm" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      case Accounts.confirm_two_factor(conn.assigns.current_user, conn.body_params["code"] || "") do
        {:ok, codes} ->
          # THIS is the enable moment — the 422 arms below changed nothing, so
          # they stamp nothing.
          audit_account_security(conn, "twofa.enabled")
          json(conn, 200, %{recovery_codes: codes})

        {:error, :invalid_otp} ->
          json(conn, 422, %{error: "invalid_otp"})

        {:error, :not_enrolled} ->
          json(conn, 422, %{error: "not_enrolled"})
      end
    end
  end

  # GET /v1/account/two-factor → 200 {enabled: bool} — status for the panel.
  get "/v1/account/two-factor" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, %{enabled: Accounts.two_factor_enabled?(conn.assigns.current_user)})
    end
  end

  # DELETE /v1/account/two-factor → 200 {ok: true} — disable (nulls all columns).
  delete "/v1/account/two-factor" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      # The route is idempotent (it nulls the columns whether or not 2FA was on),
      # so the audit row is gated on 2FA having ACTUALLY been enabled. A
      # `twofa.disabled` row for a user who never enabled it would be a trail
      # entry describing a change that did not happen.
      was_enabled? = Accounts.two_factor_enabled?(conn.assigns.current_user)
      {:ok, _} = Accounts.disable_two_factor(conn.assigns.current_user)
      if was_enabled?, do: audit_account_security(conn, "twofa.disabled")
      json(conn, 200, %{ok: true})
    end
  end

  # POST /v1/account/two-factor/recovery-codes
  #   → 200 {recovery_codes: [...]} — fresh set; old codes invalidated; once
  #   → 422 {error: "not_enabled"}  — 2FA is not on
  post "/v1/account/two-factor/recovery-codes" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      case Accounts.regenerate_recovery_codes(conn.assigns.current_user) do
        {:ok, codes} -> json(conn, 200, %{recovery_codes: codes})
        {:error, :not_enabled} -> json(conn, 422, %{error: "not_enabled"})
      end
    end
  end

  # GET /v1/onboarding → 200 {onboarding: {completed, completed_at, last_step,
  # all_done, steps:[{key,done}]} | nil}. The SPA reads this (on boot via /v1/me,
  # and again on a subscription/fleet live event) to render the persistent
  # "Finish setup" checklist. Steps are SERVER-computed, so they reflect state
  # the user changed outside the checklist (subscribed via Billing, launched via
  # the Launch view) with zero client logic. Readable by ANY team member. A
  # teamless user gets nil.
  get "/v1/onboarding" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, %{onboarding: nil})

      true ->
        status = Accounts.onboarding_status(conn.assigns.current_team)
        json(conn, 200, %{onboarding: onboarding_json(status)})
    end
  end

  # POST /v1/onboarding {action: "advance"|"ack"|"complete"|"skip", step?}
  #   advance  — persist the resume pointer (step required, must be a known step)
  #   ack      — manually tick a server-unverifiable step (published_doc)
  #   complete — finish (only honored when all steps done; else 422 steps_incomplete)
  #   skip     — dismiss early (Coolify's skipBoarding) — stamps completed_at
  # RBAC: the mutations change TEAM state (they finish/dismiss the whole team's
  # onboarding + set the activation metric), so they are gated at owner/admin via
  # `Auth.require_primary_team_admin/1` — a plain `member` gets 403. GET stays
  # readable to any member. (401 unauth, 403 no_team, 403 non-admin all handled
  # inside the gate.) Deliberate Coolify divergence: NO force-redirect middleware
  # — the checklist is a soft, dismissable SPA surface; the real launch gate stays
  # the existing 402 on /v1/go-live. On any state change we push an "onboarding"
  # invalidation so other tabs refetch.
  post "/v1/onboarding" do
    conn = Auth.require_primary_team_admin(conn)

    if conn.halted do
      conn
    else
      handle_onboarding_action(conn, conn.body_params, conn.assigns.current_team)
    end
  end

  # POST /v1/auth/resend-verification (user) → ALWAYS 200 {ok: true}. Re-sends the
  # confirm mail for the current user. An already-confirmed user, an unknown
  # state, or a throttled resend is STILL 200 — no information is leaked and no
  # error is surfaced (the deliver context is fail-soft).
  post "/v1/auth/resend-verification" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      _ = Accounts.deliver_user_confirmation_instructions(conn.assigns.current_user)
      json(conn, 200, %{ok: true})
    end
  end

  # POST /v1/account/email/change (user) {new_email} → 202 {ok: true} (stages the
  # pending address + emails a 6-digit code to it) | 422 {error: "email_invalid"}.
  # ENUMERATION-SAFE: an already-registered target, a throttled request, and a
  # down mailer ALL answer the same 202 — only a malformed address (a syntax
  # fact) is 422. So a prober can't learn which addresses have accounts.
  post "/v1/account/email/change" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      not is_binary(conn.body_params["new_email"]) ->
        json(conn, 422, %{error: "email_invalid"})

      true ->
        case Accounts.deliver_user_update_email_instructions(
               conn.assigns.current_user,
               conn.body_params["new_email"]
             ) do
          {:error, %Ecto.Changeset{}} -> json(conn, 422, %{error: "email_invalid"})
          _ -> json(conn, 202, %{ok: true})
        end
    end
  end

  # POST /v1/account/email/confirm (user) {code} → 200 {user:{id,email,confirmed}}
  # (swaps the email + syncs the Stripe customer) | 422 {error: "invalid_code"} |
  # 422 {error: "locked"} (too many wrong codes — restart the change) | 422
  # {error: "no_pending_email"}.
  post "/v1/account/email/confirm" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      not is_binary(conn.body_params["code"]) ->
        json(conn, 422, %{error: "invalid_code"})

      true ->
        case Accounts.update_user_email(conn.assigns.current_user, conn.body_params["code"]) do
          {:ok, user} ->
            json(conn, 200, %{
              user: %{id: user.id, email: user.email, confirmed: not is_nil(user.confirmed_at)}
            })

          {:error, :no_pending_email} ->
            json(conn, 422, %{error: "no_pending_email"})

          {:error, :locked} ->
            json(conn, 422, %{error: "locked"})

          _ ->
            json(conn, 422, %{error: "invalid_code"})
        end
    end
  end

  ## Account & sessions (session-token auth)

  # DELETE /v1/auth/logout → 200 {ok: true}. Revokes THE CALLING token (the
  # leaked-session kill switch for a single device). Idempotent — a second
  # logout on an already-revoked token is still 200. The current token plaintext
  # is re-extracted via Auth.bearer_token/1 (the same value require_user already
  # resolved) so the exact row presented gets revoked.
  delete "/v1/auth/logout" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      _ = Accounts.revoke_user_session_token(Auth.bearer_token(conn))
      json(conn, 200, %{ok: true})
    end
  end

  # POST /v1/auth/sse-ticket → 200 {ticket, expires_in}. Mints a single-use,
  # 60-second, SSE-scoped ticket over a request carrying the session token in an
  # Authorization HEADER. The browser's EventSource API cannot set headers, so
  # GET /v1/events has to take its credential from the URL; this route makes the
  # thing in that URL a burn-on-open ticket instead of a 30-day session token.
  #
  # It is a POST, and there is deliberately NO `get "/v1/auth/sse-ticket"` — and
  # the PATH-has-no-GET part is the actual invariant, not the verb. `plug(Plug.Head)`
  # rewrites HEAD→GET unconditionally BEFORE matching, so a HEAD prober can only
  # be refused by there being no GET clause on the path at all. (Measured
  # counterexample: HEAD /v1/tokens answers 401, not 404, precisely because a GET
  # twin lives beside its POST.) Pinned by router_sse_ticket_test.exs.
  post "/v1/auth/sse-ticket" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      # The bearer here is the SESSION token of the device asking for a stream,
      # and passing it BINDS the ticket to that session row (cch-w53-bl) — which
      # is what makes revoking this one device from the sessions panel end this
      # one stream. Drop the argument and the ticket mints unbound: every stream
      # falls back to the user-wide liveness check and per-row revoke goes back to
      # not ending anything.
      case Accounts.create_sse_ticket(
             conn.assigns.current_user,
             Auth.bearer_token(conn)
           ) do
        {:ok, ticket} ->
          json(conn, 200, %{
            ticket: ticket,
            expires_in: Accounts.sse_ticket_validity_seconds()
          })

        {:error, _cs} ->
          json(conn, 500, %{error: "ticket_mint_failed"})
      end
    end
  end

  # GET /v1/account/sessions → 200 {sessions: [{id, ip_address, user_agent,
  # last_used_at, inserted_at, current}]}. `current` flags the row matching the
  # calling token so the UI can label "This device". The token_hash is NEVER
  # echoed.
  get "/v1/account/sessions" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      current_hash = Accounts.UserToken.hash_token(Auth.bearer_token(conn) || "")
      rows = Accounts.list_user_sessions(conn.assigns.current_user)
      json(conn, 200, %{sessions: Enum.map(rows, &session_json(&1, current_hash))})
    end
  end

  # DELETE /v1/account/sessions/:id → 200 {ok: true} | 404. Revoke one of the
  # caller's sessions by row id. Ownership-scoped: another user's token id is a
  # 404, never an existence leak.
  delete "/v1/account/sessions/:id" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      case Accounts.revoke_user_session(conn.assigns.current_user, conn.path_params["id"]) do
        {:ok, _} -> json(conn, 200, %{ok: true})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      end
    end
  end

  # DELETE /v1/account/sessions → 200 {revoked: N}. "Sign out everywhere" EXCEPT
  # the acting browser, kept alive via :except so the caller stays logged in
  # here. N is the number of OTHER sessions just revoked.
  delete "/v1/account/sessions" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      {:ok, n} =
        Accounts.revoke_all_user_sessions(conn.assigns.current_user,
          except: Auth.bearer_token(conn)
        )

      json(conn, 200, %{revoked: n})
    end
  end

  # PUT /v1/account/password {current_password, new_password} → 200 {ok: true,
  # token: <fresh>} | 401 wrong current | 422 weak new. On success EVERY other
  # session + all reachable agent tokens are revoked; the response carries a
  # freshly-minted session for THIS browser so the caller stays logged in. The
  # old token they presented is revoked among the rest, so the SPA MUST swap to
  # the returned token (mirrors Coolify's dispatch('reloadWindow')).
  put "/v1/account/password" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      cur = to_string(conn.body_params["current_password"])
      new = to_string(conn.body_params["new_password"])
      user = conn.assigns.current_user
      old_token = Auth.bearer_token(conn)

      case Accounts.update_user_password(user, cur, new, keep: old_token) do
        {:ok, _u} ->
          # The old token was kept alive THROUGH the bulk revoke (via :keep) so
          # the in-flight request never lost its own auth mid-call. Revoke it now
          # and hand back a fresh one so the SPA swaps and stays authenticated.
          _ = Accounts.revoke_user_session_token(old_token)

          # ORIGIN "password_change": this row is NOT a login — it is the
          # replacement token handed back after "sign out everywhere", and
          # calling it "password" would misreport a re-mint as a fresh sign-in.
          {:ok, fresh} =
            Accounts.create_user_session_token(
              user,
              session_opts(conn) ++ [origin: "password_change"]
            )

          json(conn, 200, %{ok: true, token: fresh})

        {:error, :invalid_current_password} ->
          json(conn, 401, %{error: "invalid_current_password"})

        {:error, %Ecto.Changeset{} = cs} ->
          json(conn, 422, %{error: "invalid", details: errors(cs)})
      end
    end
  end

  # GET /v1/subscription → 200 {subscription: {plan, status, started_at} | nil,
  #                             billing_capability: {checkout, plans}}.
  # The Billing view reads this to show the REAL current plan (and gate the
  # already-subscribed state) instead of hardcoding "Free = current plan". A
  # team with no active subscription gets {subscription: nil}.
  #
  # D554 — `billing_capability` is a TOP-LEVEL SIBLING, not a field inside
  # `subscription`, precisely so it is present in the `{subscription: nil}` arm:
  # that is the arm the UNSUBSCRIBED owner staring at the Subscribe button gets,
  # and it is the only one where knowing whether checkout can work MATTERS. It
  # rides this route (not /v1/me — see that route's comment: "Membership is the
  # whole scope") because the fact is "whether a subscription can be created",
  # and renderBilling already reads here, so it costs zero new round-trips.
  get "/v1/subscription" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, %{subscription: nil, billing_capability: billing_capability_json()})

      true ->
        # The LIVE subscription (active OR past_due) so the Billing view shows a
        # paying-but-in-dunning customer their real plan + status, not "no plan".
        case Billing.live_subscription(conn.assigns.current_team) do
          nil ->
            json(conn, 200, %{subscription: nil, billing_capability: billing_capability_json()})

          sub ->
            json(conn, 200, %{
              subscription: subscription_json(sub),
              billing_capability: billing_capability_json()
            })
        end
    end
  end

  # GET /v1/providers → 200 {providers: [...]} for the user's team. Backs the
  # Providers view so connected providers SURVIVE a reload (the connect flow was
  # previously optimistic-only — a connected provider vanished on refresh).
  get "/v1/providers" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, %{providers: []})

      true ->
        providers = Registry.list_providers(conn.assigns.current_team)
        json(conn, 200, %{providers: Enum.map(providers, &provider_json/1)})
    end
  end

  # GET /v1/events — the live dashboard's Server-Sent-Events stream. Auth is by
  # `?ticket=<single-use-sse-ticket>` (a query param, because the browser
  # EventSource API CANNOT set an Authorization header — so the query param takes
  # a 60s burn-on-open ticket from POST /v1/auth/sse-ticket, NEVER a session
  # token) OR a normal Bearer header for non-browser clients. The ticket is
  # consumed by the connect: a replay of the URL out of an access log gets 401.
  # On success the request process subscribes to its team's :pg group
  # and parks in a receive loop, chunking each broadcast as an SSE `data:` frame
  # plus a periodic heartbeat comment to keep proxies from idling it out. The
  # browser refetches the relevant GET on each event — the event is an
  # invalidation signal, not authoritative state.
  get "/v1/events" do
    conn = require_user_sse(conn)

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns[:current_team]) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        stream_events(conn, conn.assigns.current_team.id)
    end
  end

  # GET /v1/barkparks → 200 {barkparks: [...]} for the user's team. A signed-in
  # human may request `?scope=all` to list every Team membership; PATs remain
  # team-scoped. Each row
  # carries the LATEST provision job's status/error (merged from a single batch
  # query) so the dashboard can show a FAILED launch distinctly from one still
  # provisioning — a failed job leaves the barkpark health "unknown"/host nil,
  # otherwise indistinguishable from in-progress.
  #
  # dr-w4-s4: each row also carries `pressure` — the host's live vitals off the
  # latest health beat, prefetched the same batched way. AUTHORIZATION NOTE
  # (charter D63, a deliberate decision): this default branch accepts a
  # read-scoped PAT while /metrics — the only other pressure surface — is
  # `require_user` only, so host pressure is now visible to MACHINE principals
  # holding a read token for their own team's boxes. Accepted: it is the team's
  # own box, and it is what `bp cloud status` in CI wants.
  get "/v1/barkparks" do
    conn = fetch_query_params(conn)
    all_teams? = conn.query_params["scope"] == "all"

    conn =
      if all_teams? do
        Auth.require_user(conn, [])
      else
        conn |> Auth.require_user_or_pat([]) |> Auth.require_ability("read")
      end

    if conn.halted do
      conn
    else
      scoped_barkparks =
        if all_teams? do
          Registry.list_barkparks_for_user(conn.assigns.current_user)
        else
          case conn.assigns.current_team do
            nil -> []
            team -> Enum.map(Registry.list_barkparks(team), &{&1, nil})
          end
        end

      barkparks = Enum.map(scoped_barkparks, &elem(&1, 0))
      ids = Enum.map(barkparks, & &1.id)
      pmap = Registry.latest_provision_status_map(ids)
      dmap = Registry.latest_deprovision_status_map(ids)
      # dr-w4-s4: host pressure rides the SAME prefetch shape — one DISTINCT ON
      # query for the whole page, never a per-row lookup (that is the N+1 this
      # domain already paid for once).
      hmap = Registry.latest_health_payload_map(ids)
      # jpf-w1-queue-age-alarm: the queued-deployment age rides the SAME
      # prefetch shape — one GROUP BY query for the whole page, never a per-row
      # lookup (the N+1 this domain already paid for once).
      qmap = Registry.queued_deploy_age_map(ids)

      json(conn, 200, %{
        barkparks:
          Enum.map(scoped_barkparks, fn {barkpark, role} ->
            row =
              barkpark_json(
                barkpark,
                pmap[barkpark.id],
                dmap[barkpark.id],
                hmap[barkpark.id],
                qmap[barkpark.id]
              )

            if all_teams? do
              Map.put(row, :team, %{
                id: barkpark.team.id,
                name: barkpark.team.name,
                slug: barkpark.team.slug,
                role: role
              })
            else
              row
            end
          end),
        # The deploy rail's MEASURED per-stage medians ride ALONG on this
        # envelope — additive key, no new route, and the SPA already fetches
        # this payload before it can render a rail (site detail awaits
        # `ensureFleet()`). Fleet-wide and identity-free: stage names, medians
        # and counts only, nothing team- or site-shaped, so it is safe on a
        # response every reader of every team already receives. Stages whose
        # distribution the fold REFUSES are simply absent and the client keeps
        # its constant — see `Registry.deploy_stage_estimates/1`.
        step_estimates: Registry.deploy_stage_estimates()
      })
    end
  end

  # GET /v1/archives → 200 {ok:true, archives:[...]} — the team's portable
  # archive bundles, read straight from object storage (charter S14 / D39). The
  # bundle manifest IS the index: there is NO archives table. Strictly
  # team-scoped by the `archives/<team_id>/` key prefix (derived from the
  # authenticated team, never client input), so another team's bundles can
  # NEVER be served. Newest-first. Each row is {fqdn, slug, source_provider,
  # created_at, bundle_ref, spec:{region, server_type}} — enough for the console
  # to render the row + a `bp cloud instance resurrect <slug> --provider <kind>`
  # affordance.
  #
  # Honest degrade (D39): an unconfigured or unreachable store returns
  # {ok:false, error} at 502 — NEVER a fabricated empty-success, which would
  # tell an operator their archives vanished when the store is merely down. No
  # team → a true empty (a team with no bundles is indistinguishable, correctly).
  get "/v1/archives" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, %{ok: true, archives: []})

      true ->
        case ArchiveStore.list_archives(conn.assigns.current_team.id) do
          {:ok, archives} ->
            json(conn, 200, %{ok: true, archives: archives})

          {:error, reason} ->
            json(conn, 502, %{ok: false, error: archive_store_error(reason)})
        end
    end
  end

  # GET /v1/audit?limit=&before=&target_type=&target_id=&actor_user_id=&action_prefix=
  # → 200 {events: [...]}.
  # The authenticated admin's team audit trail, newest first, keyset-paginated
  # (`?before=<oldest inserted_at>` walks the next page). Strictly team-scoped via
  # conn.assigns.current_team — an admin only ever sees their OWN team's events.
  #
  # The two narrowing filters answer the questions the trail is actually read
  # for: `?actor_user_id=` is "what did this member do?" and `?action_prefix=` is
  # "show me the webhook story" (a prefix of the closed `noun.verb` vocabulary,
  # so `webhook` matches every `webhook.*`). Both are IGNORED when absent, empty,
  # or unparseable — a garbage actor id is a no-op filter, never a 500 and never
  # a silently wider result set. They compose with each other and with
  # target_type/target_id; filtering happens INSIDE the limit, so a filtered page
  # is a real page of matches, not a filtered slice of the newest 50.
  #
  # RBAC: ADMIN-gated (rbac-roles). Reading the audit log is owner/admin-only —
  # require_primary_team_admin halts 401 (no session) / 403 no_team / 403 (a plain
  # member). This is the docstring-promised tightening the swarm candidate could
  # only hint at: main now ships the team-role gate, so a plain member can no
  # longer read the trail.
  get "/v1/audit" do
    conn = Auth.require_primary_team_admin(conn)

    if conn.halted do
      conn
    else
      opts = [
        limit: parse_int(conn.query_params["limit"], 50),
        before: parse_dt(conn.query_params["before"]),
        before_id: conn.query_params["before_id"],
        target_type: conn.query_params["target_type"],
        target_id: conn.query_params["target_id"],
        actor_user_id: conn.query_params["actor_user_id"],
        action_prefix: conn.query_params["action_prefix"]
      ]

      events = Accounts.list_audit_events(conn.assigns.current_team, opts)
      json(conn, 200, %{events: Enum.map(events, &audit_json/1)})
    end
  end

  # DELETE /v1/barkparks/:id → 200 {ok: true} — remove an instance from the
  # dashboard. Team-scoped: a wrong-team / nonexistent id is the same 404 (no
  # existence leak). Guard: a LIVE managed box (host set) is NOT removable here —
  # deleting only the registry row would strand a billed server (deprovisioning
  # the actual box is a Go-worker follow-up). Failed / never-provisioned rows are
  # safe to remove (a failed provision already tore its box down). 409 with a
  # clear reason for the blocked live case.
  # DELETE /v1/barkparks/:id — remove an instance. Team-scoped (wrong-team /
  # nonexistent → 404, no existence leak). LIVE box (host set) → enqueue a
  # DEPROVISION job, 202 {status: "deprovisioning"} (the worker tears the real box
  # + DNS down, then the row is deleted; a duplicate concurrent remove is deduped
  # → still 202). NON-live box (host nil) → delete the row now, 200 {status:
  # "removed"} (no live server to tear down).
  # ADMIN-gated: removing an instance (and tearing down a billed box) is
  # privileged. require_primary_team_admin halts 401 / 403 no_team / 403 for a
  # member; a non-admin can no longer deprovision the team's infrastructure.
  delete "/v1/barkparks/:id" do
    # Infra-destructive → team admin (owner/admin) only. require_primary_team_admin
    # gates the user's PRIMARY team (401 / 403 no_team / 403), matching the doc above.
    conn = Auth.require_primary_team_admin(conn)

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            cond do
              # Live box → tear the real server + DNS down (deprovision job).
              is_binary(bp.host) and bp.host != "" ->
                deprovision_live_barkpark(conn, team, bp)

              # Not live YET, but a provision is in flight: deleting the row now
              # would let the worker bring a box up the control plane can't see
              # (succeed_job no-ops on the missing row) — a stranded billed box,
              # and for a support an orphan A record too. ANY BLOCKING KIND
              # counts, not a named list: this route matches on team alone, so a
              # SUPPORT row (kind "provision_support") reaches it, and a
              # `resurrect` can be in flight here too (task-688ebffc4b0aa50a).
              # See active_job_blocking_delete?/1 — the set is a DENYLIST, so a
              # newly added kind is covered by default rather than silently missed.
              # Refuse until the job lands (then it's a live-box deprovision)
              # or fails (then it's a clean non-live remove).
              Registry.active_job_blocking_delete?(bp) ->
                json(conn, 409, %{
                  error: "provisioning_in_progress",
                  detail:
                    "This instance is still provisioning. Try removing it once it's up or has failed."
                })

              # Non-live, nothing in flight (never provisioned, or a failed
              # provision that already tore its own box down) → delete the row
              # now, ATOMIC with a `barkpark.deleted` audit event (the row delete
              # and the audit insert share one transaction — never one without
              # the other).
              true ->
                audit_attrs = %{
                  team_id: team.id,
                  actor_user_id: conn.assigns.current_user.id,
                  action: "barkpark.deleted",
                  target_type: "barkpark",
                  target_id: bp.id,
                  metadata: %{name: bp.name}
                }

                case Accounts.audit(audit_attrs, fn -> Registry.delete_barkpark(bp) end) do
                  {:ok, _} ->
                    push_event(team.id, "fleet")
                    push_event(team.id, "audit")
                    json(conn, 200, %{ok: true, status: "removed"})

                  {:error, %Ecto.Changeset{} = cs} ->
                    json(conn, 422, %{error: "invalid", details: errors(cs)})
                end
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/fleet/supports → 201 {barkpark} — register a SUPPORT machine as a
  # fleet group row bound to a main (Personal Dev Fleet Wave C, PDF-D61). Body:
  # {name, parent_id, host?, token_id?}. `parent_id` MUST resolve to a Barkpark
  # in the CALLER'S team — a cross-team (or unknown/malformed) parent is the same
  # 404, no existence leak; a parent that is ITSELF a support is 422 (the shape is
  # exactly two-tier main -> N supports, never a chain). The created row carries
  # fleet_role:"support", fleet_parent_id:<main>, fleet_token_id:<opaque id>.
  # Team-scoped WRITE, same credential-aware family as go-live: a PAT must carry
  # the `deploy` ability; a session must be team-admin (owner/admin).
  post "/v1/fleet/supports" do
    conn = Auth.require_user_or_pat(conn, [])

    conn =
      cond do
        conn.halted -> conn
        conn.assigns[:current_token] -> Auth.require_ability(conn, "deploy")
        is_nil(conn.assigns[:current_team]) -> conn
        Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) -> conn
        # cch-w37-s2: NAME THE AUTHORITY. This refusal shipped as a bare
        # %{error: "forbidden"}, which the console's friendly() resolves to the
        # owner-only BILLING sentence — so a plain member who clicks the rendered
        # "Add support server" CTA was told, confidently, about billing. Adding a
        # support machine needs ADMIN on the resolved team; paying needs OWNER.
        true -> Auth.forbidden(conn, required: "admin", scope: "team")
      end

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      not (is_binary(conn.body_params["name"]) and conn.body_params["name"] != "") ->
        json(conn, 422, %{error: "invalid", details: %{name: ["can't be blank"]}})

      # PDF-D83: mode:"provision" is the CP-provisioned add-support path — register
      # a host-nil support row, then enqueue a provision_support job (202). The
      # register-only mode (no `mode` param) falls through unchanged.
      conn.body_params["mode"] == "provision" ->
        fleet_provision_support(conn)

      not is_binary(conn.body_params["parent_id"]) ->
        json(conn, 422, %{error: "invalid", details: %{parent_id: ["can't be blank"]}})

      true ->
        team = conn.assigns.current_team
        name = conn.body_params["name"]

        case Registry.get_barkpark(conn.body_params["parent_id"]) do
          # A support may never be a parent — two-tier is the whole shape. Refuse
          # BEFORE the team match would 404 it, so an in-team support parent gets a
          # clear 422 rather than being conflated with a cross-team miss.
          %Barkpark{team_id: tid, fleet_role: "support"} when tid == team.id ->
            json(conn, 422, %{
              error: "invalid_parent",
              detail: "a support cannot be a parent (fleets are two-tier: main -> supports)"
            })

          %Barkpark{team_id: tid} = parent when tid == team.id ->
            attrs = %{
              name: name,
              slug: slugify(name),
              host: string_param_or_nil(conn.body_params["host"]),
              parent_id: parent.id,
              token_id: string_param_or_nil(conn.body_params["token_id"])
            }

            # PDF-D86: register_support_barkpark/2 is quota-exempt — a support
            # never returns :limit_reached, so a saturated ceiling can't 403 here.
            case Registry.register_support_barkpark(team, attrs) do
              {:ok, support} ->
                push_event(team.id, "fleet")
                json(conn, 201, %{barkpark: barkpark_json(support)})

              {:error, %Ecto.Changeset{} = cs} ->
                json(conn, 422, %{error: "invalid", details: errors(cs)})
            end

          # Cross-team, unknown, or malformed parent id → 404 (no existence leak).
          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # PDF-D83/D86 (Personal Dev Fleet MVP-0) — the mode:"provision" arm of POST
  # /v1/fleet/supports. Body {name, barkpark_id: <parent main id>, mode:
  # "provision", server_type?}. Sequence: resolve the parent main (team-scoped) →
  # require its admin token (409 no_admin_token — the token is the credential
  # spine of the claim payload, D93; mirrors the mint_app_token arm) → register a
  # host-NIL support row FIRST (quota-exempt, D86) → enqueue the provision_support
  # job → push a fleet tick → 202 {barkpark, job_id}. `barkpark_id` names the
  # parent (a `parent_id` alias is accepted so the register-only body shape still
  # works). Name validity + auth were already gated by the route's cond.
  defp fleet_provision_support(conn) do
    team = conn.assigns.current_team
    parent_id = conn.body_params["barkpark_id"] || conn.body_params["parent_id"]

    case Registry.get_barkpark(parent_id) do
      # A support may never be a parent — two-tier is the whole shape (mirror the
      # register-only refusal so an in-team support parent gets a clear 422).
      %Barkpark{team_id: tid, fleet_role: "support"} when tid == team.id ->
        json(conn, 422, %{
          error: "invalid_parent",
          detail: "a support cannot be a parent (fleets are two-tier: main -> supports)"
        })

      %Barkpark{team_id: tid} = parent when tid == team.id ->
        case Registry.reveal_admin_token(parent) do
          {:ok, admin_token} when is_binary(admin_token) and admin_token != "" ->
            do_fleet_provision_support(conn, team, parent)

          # The parent has no admin token → the provision_support claim payload
          # would carry a null credential and the worker could never bind/roster
          # the box. Refuse at ENQUEUE (409) so the job never exists in a broken
          # state (PDF-D83), mirroring mint_app_token's no_admin_token arm.
          {:ok, nil} ->
            json(conn, 409, %{
              error: "no_admin_token",
              detail:
                "the parent main has no admin token yet — it must be live before a support can be provisioned"
            })

          :error ->
            json(conn, 500, %{error: "decrypt_failed"})
        end

      # Cross-team, unknown, or malformed parent id → 404 (no existence leak).
      _ ->
        json(conn, 404, %{error: "not_found"})
    end
  end

  # Register the host-nil support row FIRST, then enqueue its provision_support
  # job (PDF-D83 ordering — the row must exist before the worker can claim it).
  defp do_fleet_provision_support(conn, team, parent) do
    attrs = %{
      name: conn.body_params["name"],
      slug: slugify(conn.body_params["name"]),
      # host NIL — the CP provisioner fills the box in.
      host: nil,
      parent_id: parent.id,
      token_id: nil,
      server_type: string_param_or_nil(conn.body_params["server_type"])
    }

    case Registry.register_support_barkpark(team, attrs) do
      {:ok, support} ->
        case Registry.enqueue_support_provision_job(support) do
          {:ok, job} ->
            push_event(team.id, "fleet")
            json(conn, 202, %{barkpark: barkpark_json(support), job_id: job.id})

          # A brand-new row can't already hold an active job, but stay honest
          # rather than 500 if a race ever produces one.
          {:error, :already_provisioning} ->
            json(conn, 409, %{error: "already_provisioning", barkpark: barkpark_json(support)})

          {:error, %Ecto.Changeset{} = cs} ->
            json(conn, 422, %{error: "invalid", details: errors(cs)})
        end

      {:error, %Ecto.Changeset{} = cs} ->
        json(conn, 422, %{error: "invalid", details: errors(cs)})
    end
  end

  # DELETE /v1/fleet/supports/:id — remove a SUPPORT fleet row (Personal Dev
  # Fleet Wave C, PDF-D61). Team-scoped: a wrong-team / unknown / malformed id is
  # the same 404 (no existence leak). ONLY a support row is removable here — a
  # main (or an ungrouped legacy row) is refused 409, so this endpoint can never
  # tear down the developer's home base.
  # Credential-aware, the SAME family as POST /v1/fleet/supports and go-live: a
  # credential that can BIND can UNBIND — a PAT must carry the `deploy` ability;
  # a session must be team-admin (owner/admin). Anon 401. The no-team case falls
  # through to the downstream 404 (POST's is 422 — the asymmetry is left for
  # backlog pdf-bl-cp-no-team-status-mismatch, deliberately not normalized here).
  #
  # task-688ebffc4b0aa50a — THE LIVE/NON-LIVE DISJUNCTION, the same one
  # `DELETE /v1/barkparks/:id` above already makes, and for the same reason.
  # A `mode: "provision"` support (PDF-D83) is not a bookkeeping row: the worker
  # gave it a real Hetzner box AND an `A <label>.barkpark.cloud` record pointing
  # at that box (`provision_support`'s secure step). Deleting the row alone
  # stranded BOTH — a billed box nothing can see, and a dangling A record whose
  # address Hetzner will eventually reassign to a stranger, at which point the
  # abandoned hostname resolves to someone else's machine (subdomain takeover).
  #
  #   * LIVE (host set) → enqueue a DEPROVISION job, 202 {status:"deprovisioning"}.
  #     The Go worker deletes the server and sweeps the box's A records BY VALUE
  #     (`DeprovisionWith` → `WarmPool.DeprovisionByIP`), and ONLY THEN does
  #     `succeed_deprovision_job/1` delete the row. That ordering is the point:
  #     the row is the sole pointer to what to delete (the claim payload derives
  #     `dns_label`/`dns_zone` from `url` at claim time), so dropping it first
  #     would lose the record's name while the record stayed live. If the DNS
  #     sweep fails the worker reports /fail, the row SURVIVES, and the operator
  #     can re-run — never a state where the record is unreachable AND live.
  #     Re-running a remove is safe: a second DELETE dedups onto the in-flight job
  #     and answers 202 again (`:already_deprovisioning`), never a second teardown.
  #   * PROVISIONING (host nil, a `provision_support` job in flight) → 409.
  #     Deleting now would let the worker bring up a box — and publish an A
  #     record — that the control plane can no longer see; the support-job succeed
  #     path no-ops on the missing row, so both leak with nothing left to name them.
  #   * NON-LIVE, nothing in flight (register-only bind, or a failed provision
  #     that already tore its own box down) → delete the row now, 200
  #     {status:"removed"} — the historical behaviour, and the only arm where
  #     there is no box and no record to lose.
  #
  # `?mode=detach` deletes the ROW ONLY (200 {status:"removed", mode:"detach"})
  # even when host is set — the same escape hatch, and the same words, as
  # `POST /v1/internal/barkparks/:id/deprovision`'s detach mode. It exists for a
  # caller that tore the box and its DNS down ITSELF and can prove it:
  # `bp cloud support remove` deletes the server and sweeps the zone by value
  # before it ever reaches this route, and passes `mode=detach` ONLY on the runs
  # where that sweep actually happened. On a run where the sweep was SKIPPED (no
  # dedicated DNS credential — the fleet compute token sees zero zones) the CLI
  # omits the mode on purpose, so this route takes the deprovision path and the
  # worker — which does hold a DNS credential — sweeps instead. Detach is the
  # caller ASSERTING the record is already gone; it is never the default.
  delete "/v1/fleet/supports/:id" do
    conn = Auth.require_user_or_pat(conn, [])

    conn =
      cond do
        conn.halted -> conn
        conn.assigns[:current_token] -> Auth.require_ability(conn, "deploy")
        is_nil(conn.assigns[:current_team]) -> conn
        Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) -> conn
        # cch-w37-s2: SHAPE PARITY with POST /v1/fleet/supports above — a
        # credential that can BIND can UNBIND, so its refusal must read the same.
        # This one is CLI-only today (zero console call sites), so no user reads
        # it yet; it is labelled anyway so the pair cannot drift apart.
        true -> Auth.forbidden(conn, required: "admin", scope: "team")
      end

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid, fleet_role: "support"} = support when tid == team.id ->
            cond do
              # The caller tore box + DNS down itself and says so (see above).
              fleet_support_detach?(conn) ->
                case Registry.delete_barkpark(support) do
                  {:ok, _} ->
                    push_event(team.id, "fleet")
                    json(conn, 200, %{ok: true, status: "removed", mode: "detach"})

                  {:error, %Ecto.Changeset{} = cs} ->
                    json(conn, 422, %{error: "invalid", details: errors(cs)})
                end

              # Live box — tear the real server AND its A record down (deprovision
              # job). The row is deleted by the worker's succeed callback, never
              # here: it is the only thing that still names the record to delete.
              is_binary(support.host) and support.host != "" ->
                deprovision_live_barkpark(conn, team, support)

              # Not live YET, but a job that would build or restore this box is
              # in flight (a provision_support here, or a resurrect) — refuse
              # until it lands (then it is a live-box deprovision) or fails (then
              # it is a clean non-live remove).
              Registry.active_job_blocking_delete?(support) ->
                json(conn, 409, %{
                  error: "provisioning_in_progress",
                  detail:
                    "This support is still provisioning. Try removing it once it's up or has failed."
                })

              # Non-live, nothing in flight: no box, no record — the row IS the
              # whole resource, so removing it strands nothing.
              true ->
                case Registry.delete_barkpark(support) do
                  {:ok, _} ->
                    push_event(team.id, "fleet")
                    json(conn, 200, %{ok: true, status: "removed"})

                  {:error, %Ecto.Changeset{} = cs} ->
                    json(conn, 422, %{error: "invalid", details: errors(cs)})
                end
            end

          # Exists in-team but is a main / ungrouped — NOT a support. Refuse: this
          # endpoint unbinds supports only (a main is deleted via /v1/barkparks).
          %Barkpark{team_id: tid} when tid == team.id ->
            json(conn, 409, %{
              error: "not_a_support",
              detail: "only support rows can be unbound here"
            })

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # ── Agent-key custody (PDF-D94, `pdf-bl-console-key-custody`) ──────────────
  # The console replacement for the SSH one-liner: the developer pastes their
  # provider key, the plane is TRANSPORT ONLY. Custody law (D62 amended by D94:
  # NEVER WRITES → NEVER KEEPS): the key goes into the in-memory AgentKeyStash
  # keyed by the enqueued push_agent_key job id; the DB job row, the audit
  # event, and the logs carry NO key material (the audit metadata records the
  # VAR NAME only). The SSH one-liner remains the documented fallback and the
  # BYO story (the console card keeps rendering it, folded).
  @agent_key_vars ~w(ANTHROPIC_API_KEY OPENAI_API_KEY)
  # Provider keys are url-safe token material (sk-ant-…/sk-proj-…). Bounded +
  # shape-fenced BEFORE the key is accepted at all, mirroring the worker-side
  # fence — a value that could break shell quoting is refused at the door.
  @agent_key_re ~r/^[A-Za-z0-9._~+\/=-]{20,512}$/

  # POST /v1/barkparks/:id/agent-key {key, key_var?} → 202 {ok, job_id}.
  # Same credential family as POST /v1/fleet/supports: a PAT must carry
  # `deploy`; a session must be team-admin. Support rows only, and only once
  # the box is LIVE (a keyless host can't be written to). One delivery in
  # flight per box (409 already_delivering).
  post "/v1/barkparks/:id/agent-key" do
    conn = Auth.require_user_or_pat(conn, [])

    conn =
      cond do
        conn.halted -> conn
        conn.assigns[:current_token] -> Auth.require_ability(conn, "deploy")
        is_nil(conn.assigns[:current_team]) -> conn
        Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) -> conn
        # cch-w37-s2 shape parity: handing a box a credential is group
        # management — ADMIN on the resolved team, and the refusal names it.
        true -> Auth.forbidden(conn, required: "admin", scope: "team")
      end

    key = conn.body_params["key"]
    key_var = conn.body_params["key_var"] || "ANTHROPIC_API_KEY"

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      key_var not in @agent_key_vars ->
        json(conn, 422, %{
          error: "invalid",
          details: %{key_var: ["must be one of: #{Enum.join(@agent_key_vars, ", ")}"]}
        })

      not (is_binary(key) and Regex.match?(@agent_key_re, key)) ->
        # The shape sentence NEVER echoes the value — a malformed secret is
        # still a secret.
        json(conn, 422, %{
          error: "invalid",
          details: %{key: ["must be 20-512 url-safe characters (the pasted value is not echoed)"]}
        })

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid, fleet_role: "support", host: host} = bp
          when tid == team.id and is_binary(host) and host != "" ->
            case Registry.enqueue_agent_key_push_job(bp) do
              {:ok, job} ->
                # The DURABLE job row is routing-only; the key itself rides
                # memory, popped exactly once by the worker's claim.
                :ok = AgentKeyStash.put(job.id, key_var, key)
                # OC24 async-trigger discipline (the go_live prior art): the
                # job is enqueued — record best-effort, never roll it back.
                # Metadata carries the var NAME, never the key.
                audit_lifecycle_trigger(conn, team, bp.id, "barkpark.agent_key_delivered", %{
                  key_var: key_var
                })

                push_event(team.id, "fleet")
                json(conn, 202, %{ok: true, job_id: job.id})

              {:error, :already_delivering} ->
                json(conn, 409, %{
                  error: "already_delivering",
                  detail: "a key delivery is already in flight for this box"
                })

              {:error, %Ecto.Changeset{} = cs} ->
                json(conn, 422, %{error: "invalid", details: errors(cs)})
            end

          # In-team support that is NOT live yet — the key has nowhere to land.
          %Barkpark{team_id: tid, fleet_role: "support"} when tid == team.id ->
            json(conn, 409, %{
              error: "not_live",
              detail: "this support box has no host yet — deliver the key once it is live"
            })

          # In-team but a main / ungrouped row: the listener env is a SUPPORT
          # concept (mirrors DELETE /v1/fleet/supports/:id's refusal).
          %Barkpark{team_id: tid} when tid == team.id ->
            json(conn, 422, %{
              error: "not_a_support",
              detail: "agent keys are delivered to fleet support boxes only"
            })

          # Cross-team, unknown, or malformed id → 404 (no existence leak).
          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # GET /v1/barkparks/:id/agent-key → 200 {job: {id,status,error,inserted_at,
  # updated_at} | null} — the console's delivery-status poll. Status/error
  # ONLY: the job row cannot leak what it never held. Same auth disjunction as
  # the POST (the read narrates a write only admins can make).
  get "/v1/barkparks/:id/agent-key" do
    conn = Auth.require_user_or_pat(conn, [])

    conn =
      cond do
        conn.halted -> conn
        conn.assigns[:current_token] -> Auth.require_ability(conn, "deploy")
        is_nil(conn.assigns[:current_team]) -> conn
        Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) -> conn
        true -> Auth.forbidden(conn, required: "admin", scope: "team")
      end

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            job = Registry.latest_agent_key_job(bp)

            json(conn, 200, %{
              job:
                job &&
                  %{
                    id: job.id,
                    status: job.status,
                    error: job.error,
                    inserted_at: job.inserted_at,
                    updated_at: job.updated_at
                  }
            })

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # OC24 pattern law (async triggers): record an instance-lifecycle operator
  # TRIGGER post-commit, on the SUCCESS branch only — best-effort, the
  # barkpark.go_live discipline: the action already succeeded (a job enqueued,
  # a remote run started), so a failed audit insert is LOGGED and never rolls
  # it back or 500s it. Detail maps carry small FACTS only — never a token, a
  # ticket, or a URL that embeds one (studio-link audits THAT a link was
  # minted, never the link). Sync DB writes (autoupdate / site-url / domain)
  # do NOT use this — they wrap in the transactional Accounts.audit/3 so the
  # row and the record land or fail together (the barkpark.deleted prior art).
  defp audit_lifecycle_trigger(conn, team, bp_id, action, metadata) do
    case Accounts.record_audit(%{
           team_id: team.id,
           actor_user_id: conn.assigns.current_user.id,
           action: action,
           target_type: "barkpark",
           target_id: bp_id,
           metadata: metadata
         }) do
      {:ok, _event} -> push_event(team.id, "audit")
      {:error, cs} -> Logger.error("audit #{action} failed: #{inspect(cs)}")
    end
  end

  # A REFUSED WRITE LEAVES A NAMED ROW (cch-w63-s8). When the plane refuses to
  # send an instance write because the box already answered our stored admin
  # credential 401, the operator gets a 409 in a browser they will close. The
  # audit trail is the only surface where that refusal is still findable an hour
  # later — and a silence there is indistinguishable from "nobody tried".
  #
  # DELIBERATELY NOT `Accounts.audit/3`. That wrapper runs the mutation inside a
  # transaction and `Repo.rollback`s the WHOLE thing on `{:error, reason}` —
  # correct for a mutation that must never outlive its record, and certified by
  # accounts_audit_test.exs's "writes NO event when the inner mutation fails".
  # But a REFUSAL is an error by definition, so routed through `audit/3` it could
  # never leave a row. `record_audit/1` directly, outside any transaction, on the
  # OC24 best-effort discipline: the refusal already happened, so a failed insert
  # is LOGGED and never turns a 409 into a 500.
  #
  # The verb is a LITERAL here rather than a parameter, unlike the two
  # call-site-keyed helpers above. A shared helper reached with the verb in a
  # module attribute is invisible to EVERY arm of the audit vocabulary census at
  # once while `validate_inclusion` rejects every write at runtime — 0 failures
  # over a producer that has never written a row.
  #
  # `attempted` names WHICH write was refused ("self_update" / "rollback");
  # `reason` is the wire word verbatim, so the console's expanded timeline detail
  # (payload = e.metadata, rendered as pretty JSON by tlvDetailHtml) carries the
  # same slug the 409 body carried. Facts only — never the credential itself.
  defp audit_credentials_refused(conn, team, bp_id, attempted) do
    case Accounts.record_audit(%{
           team_id: team.id,
           actor_user_id: conn.assigns.current_user.id,
           action: "barkpark.credentials_refused",
           target_type: "barkpark",
           target_id: bp_id,
           metadata: %{reason: "identity_refused", attempted: attempted}
         }) do
      {:ok, _event} ->
        push_event(team.id, "audit")

      {:error, cs} ->
        Logger.error("audit barkpark.credentials_refused failed: #{inspect(cs)}")
    end
  end

  # POST /v1/barkparks/:id/retry → 201 {job} — re-enqueue provisioning for an
  # instance whose LAST provision attempt FAILED. Gated on a failed latest job so
  # a retry can never open a second concurrent provision (and a second billed
  # box) while one is pending/claimed/succeeded → 409 conflict in that case.
  #
  # dwb-11: ALSO retryable when a MANAGED, never-live (host nil) instance has NO
  # provision job at all — the stranded-launch state a go-live enqueue hiccup
  # leaves behind (the 201 stood, the job insert failed and was only logged).
  # Without this the row is a permanent dead end: nothing failed, nothing in
  # flight, Retry 409s forever. The one-active-job index still backstops the
  # enqueue, so this can never open a concurrent second provision.
  post "/v1/barkparks/:id/retry" do
    # RBAC (rbac-roles): re-provisions a billed box → team admin only.
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            if retryable_provision_state?(bp) do
              case Registry.enqueue_provision_job(bp) do
                {:ok, _job} ->
                  # OC24: the enqueue committed — record the operator trigger.
                  audit_lifecycle_trigger(conn, team, bp.id, "barkpark.retry_requested", %{
                    name: bp.name
                  })

                  push_event(team.id, "fleet")
                  json(conn, 201, %{ok: true})

                # dwb-11: a concurrent double-click already re-opened the
                # provision (the one-active-job index / app-level guard rejected
                # this second enqueue). NO second box, NO second charge — report
                # the provision already underway rather than a false 422.
                {:error, :already_provisioning} ->
                  json(conn, 409, %{error: "already_provisioning"})

                {:error, cs} ->
                  json(conn, 422, %{error: "invalid", details: errors(cs)})
              end
            else
              json(conn, 409, %{error: "not_retryable"})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/barkparks/:id/verify → 200 {ok, reachable, verified_at, probes} —
  # re-run the golden-path VERIFY suite ON DEMAND (C8/D53). The control plane
  # probes the live box over HTTPS with the STORED admin token (the studio-link
  # custody — the token never reaches the client, a log line, or a result field)
  # and returns the full probe envelope: api answers, the auth stack cleanly
  # rejects bad creds (no 5xx — the #957 class), Studio renders through the
  # scoped redirect. The suite is SYNCHRONOUS (per-request transport timeouts;
  # at most 6 bounded requests, ~30s absolute worst case, sub-second typical) —
  # "ready" becomes a claim the operator can re-issue, not hope. The
  # result is appended as a `verify` instance event (so every run lands on the
  # Timeline) and the fleet SSE type is broadcast (D2: NO new event type — a
  # verify run is a fleet-relevant change the dashboard already refetches on).
  #
  # An UNREACHABLE box is a normal 200 result with `reachable: false` on every
  # probe, NOT a 502 — a failed verification is data the operator acts on, not a
  # transport error to swallow.
  #
  # USER-authed + TEAM-SCOPED, fail-closed: a wrong-team / nonexistent /
  # malformed id is the SAME 404 (no existence leak). 409 not_live while the box
  # is provisioning (no url yet) or deprovisioning (being torn down); 404
  # no_admin_token for pre-feature rows; 500 on tampered ciphertext.
  post "/v1/barkparks/:id/verify" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case resolve_team_barkpark(team, conn.path_params["id"]) do
          %Barkpark{} = bp ->
            if instance_deprovisioning?(bp) do
              # Being removed — its box is on its way out; verifying it is a lie
              # in the making. Mirrors the provisioning 409 Verify.run/1 gives.
              json(conn, 409, %{error: "not_live"})
            else
              run_verify(conn, team, bp)
            end

          nil ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # Run the synchronous suite, record the run as a `verify` event, nudge the
  # fleet stream, and relay the envelope. The admin token is resolved + used
  # entirely inside `Verify.run/1` — never seen here.
  defp run_verify(conn, team, bp) do
    case Verify.run(bp) do
      {:ok, result} ->
        # Best-effort telemetry — a failed insert must never fail the proof the
        # operator just asked for (mirrors the health-event seam).
        case Registry.record_event(bp, "verify", result) do
          {:ok, _event} -> :ok
          {:error, cs} -> Logger.error("verify event insert failed: #{inspect(cs)}")
        end

        # BP-ONB-09: cache the headline verdict onto the fleet row so the fleet
        # list carries a queryable "last verified" fact. Best-effort, right
        # beside the telemetry seam — a failed persist must never fail the proof.
        case Registry.record_verify_result(bp, result) do
          {:ok, _bp} -> :ok
          {:error, cs} -> Logger.error("verify result persist failed: #{inspect(cs)}")
        end

        # OC24: the suite ran — record who asked, and the headline verdict
        # (never the probe envelope; the `verify` instance event above carries
        # the full detail on the Timeline).
        audit_lifecycle_trigger(conn, team, bp.id, "barkpark.verify_requested", %{
          name: bp.name,
          reachable: result.reachable
        })

        push_event(team.id, "fleet")
        json(conn, 200, result)

      {:error, :not_live} ->
        json(conn, 409, %{error: "not_live"})

      {:error, :no_admin_token} ->
        json(conn, 404, %{
          error: "no_admin_token",
          detail:
            "No admin token is stored for this instance yet. It is captured at " <>
              "provision time — a pre-existing instance may need a re-provision."
        })

      {:error, :decrypt_failed} ->
        json(conn, 500, %{error: "decrypt_failed"})
    end
  end

  # A box with a pending/claimed DEPROVISION job is on its way out — not a live
  # target for the verify suite. (A provisioning box has no url yet, which
  # Verify.run/1 already gates as :not_live.)
  defp instance_deprovisioning?(%Barkpark{id: id}) do
    case Registry.latest_deprovision_status_map([id]) do
      %{^id => %{status: status}} -> status in ["pending", "claimed"]
      _ -> false
    end
  end

  # GET /v1/barkparks/:id/credentials → 200 {admin_token, url, host} — the
  # OWNER-facing retrieval of the per-instance admin bearer the warm-pool minted on
  # the box (instance-admin-token). Eliminates the SSH/rescue-reboot dance: the
  # token was reported on /succeed and stored ENCRYPTED, and this decrypts it for
  # the owner. Show-to-owner — treat the response as a secret.
  #
  # ADMIN-gated + team-scoped, fail-closed: the gate 401s an unauthenticated
  # caller and 403s a member who is not owner/admin; a barkpark in
  # ANOTHER team (or no such id) is the SAME 404 — NO existence leak for a
  # non-member. 409 "suspended" when the box is under a billing suspension (the
  # credential is not revealed while access is revoked — cch-w54-s2).
  # 404 "no_admin_token" when the row never got one (ip-only succeed /
  # pre-feature instance); 500 if the stored ciphertext fails to decrypt.
  #
  # THE ROOT-PAT PATH (cloud-agent onramp). This was `Auth.require_team_admin`
  # alone, i.e. a SESSION-ONLY route — and the committed onramp config
  # (`.mcp.json` / `scripts/ensure-bp.sh`, #12729) needs an agent in a fresh
  # container to fetch its instance credentials with a Personal Access Token,
  # which no session cookie can supply. `require_user_or_pat/2` opens that door;
  # everything below it keeps the door the same width.
  #
  # NOT the `admin(d)` DISJUNCTION the two go-live rows use. There a PAT needs
  # only the `deploy` ability and NO team role, because launching a box is a
  # capability the mint sells outright. This route hands back the PLAINTEXT
  # instance admin token — the strongest credential the control plane holds — so
  # the role axis is enforced for BOTH credential kinds and a PAT must ALSO
  # carry `root`. The tier column therefore stays a plain `admin`: every caller
  # here is a team admin, which is exactly what the table has always said.
  #
  # `root` and not `read`: `Auth.ability_implies/0` widens `write` and `deploy`
  # INTO `read`, so a read-gated route is reachable by every PAT tier. Only a
  # `root` PAT satisfies `root` — the exclusive mint (`normalize_abilities/1`
  # collapses `root` -> ["root"]) means a read/write/deploy PAT is refused here,
  # and `pat_abilities_allowed?/2` already caps a non-admin's mint at `read`.
  #
  # THE ROLE ARM IS DEFENCE IN DEPTH, AND SAYING SO IS THE HONEST VERSION.
  # It is NOT closing a live hole: measured on this tree, `do_update_role/4`
  # calls `revoke_team_pats_exceeding_role/3` on any rank drop and `do_remove/3`
  # calls `revoke_team_pats/2`, so a root PAT whose holder is demoted or removed
  # is REVOKED and 401s here — it never reaches the role check at all
  # (provisioning_test.exs pins that 401, because it is the property actually
  # protecting this route). What the role arm buys is that `root` alone can
  # never be sufficient: the ability and the grant are read on every request, so
  # any future path that drops a grant WITHOUT revoking the credential lands on
  # a 403 instead of on the plaintext admin token.
  #
  # THE ORDER OF THE TWO REFUSALS IS STILL THE POINT. The role check runs FIRST,
  # so a caller who lacks the grant is told `required: "admin", scope: "team"`
  # and a read/write/deploy PAT held by a real admin is told `required: "root",
  # scope: "token"`. Each refusal names the axis that would have admitted it.
  #
  # The two SESSION refusal shapes are unchanged and are pinned in
  # router_ability_matrix_test.exs ("gate_role names the label its opaque check
  # cannot introspect" / "the no-team arm states a CAUSE and never an
  # authority"): a member of a team still gets `required: "admin"`, and a user
  # holding NO team grant still gets `reason: "no_team"` and never an authority
  # it would be a lie to name.
  get "/v1/barkparks/:id/credentials" do
    # RBAC (rbac-roles): reveals a live admin credential → team admin
    # (owner/admin) on either credential kind, and a PAT must also hold `root`.
    conn = Auth.require_user_or_pat(conn, [])

    conn =
      cond do
        conn.halted ->
          conn

        is_nil(conn.assigns[:current_team]) ->
          Auth.forbidden(conn, reason: "no_team", scope: "team")

        # `Authz.team_admin?/2` and not `Accounts.team_admin?/2`: this is the
        # LITERAL predicate `Auth.gate_role/4` ran before this slice, so the
        # session arm is the same decision on the same read, not a lookalike.
        not Authz.team_admin?(conn.assigns.current_user, conn.assigns.current_team) ->
          Auth.forbidden(conn, required: "admin", scope: "team")

        conn.assigns[:current_token] ->
          Auth.require_ability(conn, "root")

        true ->
          conn
      end

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          # cch-w54-s2 — a SUSPENDED box reveals nothing. Suspension is billing's
          # "data retained, access revoked", and this route hands back the
          # PLAINTEXT instance admin token — the strongest credential the control
          # plane holds. Keyed on the boolean the console already paints
          # ("stopped"), and placed ABOVE the reveal so the ciphertext is never
          # decrypted. Same 409 shape as the two mint routes below.
          %Barkpark{team_id: tid, suspended: true} when tid == team.id ->
            json(conn, 409, %{
              error: "suspended",
              detail:
                "This instance is suspended. The admin credential is not revealed " <>
                  "until the suspension is cleared."
            })

          %Barkpark{team_id: tid} = bp when tid == team.id ->
            case Registry.reveal_admin_token(bp) do
              {:ok, nil} ->
                json(conn, 404, %{
                  error: "no_admin_token",
                  detail:
                    "No admin token is stored for this instance yet. It is captured at " <>
                      "provision time — a pre-existing instance may need a re-provision."
                })

              {:ok, token} ->
                json(conn, 200, %{admin_token: token, url: bp.url, host: bp.host})

              :error ->
                json(conn, 500, %{error: "decrypt_failed"})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/barkparks/:id/studio-link → 200 {url} — one-click Studio entry
  # (dwb-7). The control plane uses the STORED per-instance admin token
  # server-side to mint a single-use, 60s login ticket on the instance
  # (POST /v1/auth/login-tickets) and returns the handoff URL
  # `<instance>/login/ticket/<t>`. The dashboard window.open()s it — one click,
  # zero token paste, works from a fresh browser. The admin token itself never
  # reaches the client (contrast /credentials above, which reveals it and is
  # therefore admin-gated); only the short-lived single-use ticket travels.
  #
  # USER-authed + TEAM-SCOPED, fail-closed: any member of the owning team may
  # open Studio; a wrong-team / nonexistent / malformed id is the SAME 404 (no
  # existence leak). 409 suspended when the box is under a billing suspension
  # (no ticket is minted and the instance is never called — cch-w54-s2);
  # 409 not_live while provisioning; 404 no_admin_token for
  # pre-feature instances (parity with /credentials); 502 when the instance
  # call fails; 500 on tampered ciphertext.
  post "/v1/barkparks/:id/studio-link" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            # cloud-identity handoff: pass the cloud account's email so the
            # instance signs the browser in AS this user (JIT-provisioned
            # owner) rather than an anonymous admin-token session. Older
            # instances ignore the field — legacy ticket, still one-click.
            case Registry.mint_studio_link(bp, conn.assigns.current_user.email) do
              {:ok, url} ->
                # OC24: audit THAT a link was minted — never the URL (it embeds
                # the single-use login ticket) and never the admin token.
                audit_lifecycle_trigger(conn, team, bp.id, "barkpark.studio_link_minted", %{
                  name: bp.name
                })

                json(conn, 200, %{url: url})

              # cch-w54-s2 — the box is suspended: no ticket is minted and the
              # instance is never called. Distinct slug from `not_live` (which
              # means "still provisioning") because this is a verdict the owner
              # resolves, not a wait.
              #
              # REVIEW (cch-w54 wave review) — the detail deliberately does NOT
              # say "until the subscription is current". `suspended` is one
              # column written by TWO independent producers, and only one of them
              # is money: `Billing.reconcile_plan_limit/1` suspends for
              # `quota_exceeded` on a team that is fully paid and `status:
              # "active"`. Naming the subscription here would tell that team the
              # same falsehood cch-w54-s1 just removed from the instance-card
              # banner. "Until the suspension is cleared" is true on both axes and
              # is the same vocabulary as the console's ERRORS.suspended string.
              {:error, :suspended} ->
                json(conn, 409, %{
                  error: "suspended",
                  detail:
                    "This instance is suspended. Studio access is closed until the " <>
                      "suspension is cleared."
                })

              {:error, :not_live} ->
                json(conn, 409, %{error: "not_live"})

              {:error, :no_admin_token} ->
                json(conn, 404, %{
                  error: "no_admin_token",
                  detail:
                    "No admin token is stored for this instance yet. It is captured at " <>
                      "provision time — a pre-existing instance may need a re-provision."
                })

              {:error, :decrypt_failed} ->
                json(conn, 500, %{error: "decrypt_failed"})

              {:error, :instance_error} ->
                json(conn, 502, %{error: "instance_unreachable"})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/barkparks/:id/app-token → 200 {token, workspace_id, permissions,
  # expires_at} — the member-reachable app-token exchange (mobile charter D4).
  # The control plane uses the STORED per-instance admin token server-side to
  # mint a workspace-bound [read,write,chat] instance token AS the calling
  # cloud user (JIT member on the instance) via POST /v1/auth/app-tokens.
  # The admin token never travels; unlike studio-link the PLAINTEXT minted app
  # token IS the payload (returned ONCE, never audited, never logged).
  #
  # USER-authed + TEAM-SCOPED, fail-closed: any member of the owning team may
  # mint their own app token; a wrong-team / nonexistent / malformed id is the
  # SAME 404 (no existence leak). Rate-limited per IP (`app_token:<ip>` bucket,
  # 10/min — each hit costs a server-side admin-authed instance call; peer-ip
  # physics fixed by cch-w1-peer-ip-pin, PR #5305). 409 suspended when the box
  # is under a billing suspension — the token this route mints is DURABLE, so
  # minting one through a suspended box would outlive the suspension
  # (cch-w54-s2). 409 not_live while
  # provisioning; 409 app_token_unsupported when the instance predates the
  # mint route (charter D8 — the client maps it to manual token paste);
  # 404 no_admin_token for pre-feature instances; 502 when the instance call
  # fails; 500 on tampered ciphertext.
  post "/v1/barkparks/:id/app-token" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      match?(
        {:error, :rate_limited},
        DeviceAuthRateLimiter.check("app_token:" <> (peer_ip(conn) || "unknown"))
      ) ->
        json(conn, 429, %{error: "rate_limited"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            case Registry.mint_app_token(bp, conn.assigns.current_user.email) do
              {:ok, payload} ->
                # OC24: audit THAT an app token was minted — NEVER the token
                # value (it is a live credential) and never the admin token.
                audit_lifecycle_trigger(conn, team, bp.id, "barkpark.app_token_minted", %{
                  name: bp.name
                })

                json(conn, 200, payload)

              # cch-w54-s2 — the box is suspended: no app token is minted and the
              # instance is never called. This one matters most of the three —
              # the credential it withholds is durable read+write+chat and would
              # outlive the suspension that was supposed to revoke access.
              {:error, :suspended} ->
                json(conn, 409, %{
                  error: "suspended",
                  detail:
                    "This instance is suspended. New app tokens are not issued until " <>
                      "the suspension is cleared."
                })

              {:error, :not_live} ->
                json(conn, 409, %{error: "not_live"})

              {:error, :app_token_unsupported} ->
                json(conn, 409, %{error: "app_token_unsupported"})

              {:error, :no_admin_token} ->
                json(conn, 404, %{
                  error: "no_admin_token",
                  detail:
                    "No admin token is stored for this instance yet. It is captured at " <>
                      "provision time — a pre-existing instance may need a re-provision."
                })

              {:error, :decrypt_failed} ->
                json(conn, 500, %{error: "decrypt_failed"})

              {:error, :instance_error} ->
                json(conn, 502, %{error: "instance_unreachable"})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # DELETE /v1/barkparks/:id/app-token → 200 — the revoke half of the
  # member-reachable app-token exchange (wave 2, mob-w2-app-token-revoke).
  # Body {"token": raw} kills exactly that token (logout on THIS device — the
  # phone presents the credential it wants dead; relayed once, never stored);
  # an EMPTY body means logout-everywhere: the instance revokes every live
  # app:<email> token for the CALLING user, email derived SERVER-SIDE from the
  # session — a caller can never aim this at another user's tokens. Same
  # custody physics as the mint above: the stored admin token is decrypted and
  # used server-side only, never serialized into any response. USER-authed +
  # TEAM-SCOPED fail-closed: wrong-team / nonexistent / malformed id is the
  # SAME 404. Rate-limited per IP (`app_token_revoke:<ip>` bucket, 10/min, D7) —
  # and the caller's IP is RELAYED to the instance as X-Forwarded-For, so the
  # instance's sibling bucket keys per phone rather than lumping a whole team
  # behind the single Cloud egress address.
  # Body validation is EXACTLY-ONE-OF, enforced: `{"token": ""}` is a 422
  # naming the field (it must never fall through to logout-everywhere) and a
  # body carrying both "token" and "email" is a 422 (email is server-derived
  # here, so "token wins" would be a silent wrong answer).
  # 404 not_found when the instance knows no such token; 409 revoke_unsupported
  # when the instance predates the revoke route (D8 capability-vs-absence);
  # 422 revoke_refused and 429 instance_rate_limited are the instance's own
  # deliberate verdicts kept out of the 502 collapse; the rest mirror the mint
  # arm. Audited as "barkpark.app_token_revoked" — the mode and count, NEVER a
  # token value.
  delete "/v1/barkparks/:id/app-token" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      match?(
        {:error, :rate_limited},
        DeviceAuthRateLimiter.check("app_token_revoke:" <> (peer_ip(conn) || "unknown"))
      ) ->
        json(conn, 429, %{error: "rate_limited"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            mode =
              case conn.body_params do
                # EXACTLY-ONE-OF, enforced (not merely documented). The proxy
                # derives the email SERVER-SIDE, so a body naming both a token
                # and an email is a caller confusion about which credential dies
                # — refuse it instead of letting "token" silently win.
                %{"token" => _, "email" => _} ->
                  {:invalid, "exactly_one_of",
                   ~s|send exactly one of: "token" to log out THIS device, or an | <>
                     ~s|empty body to log out everywhere. "email" is derived | <>
                     ~s|server-side and is never accepted in the body.|}

                %{"token" => raw} when is_binary(raw) and raw != "" ->
                  {:token, raw}

                # A present-but-EMPTY (or non-string) token used to fall through
                # to logout-everywhere: an unset variable on the phone signed the
                # user out on every device. Now a 422 naming the field.
                %{"token" => _} ->
                  {:invalid, "invalid_token",
                   ~s|"token" must be a non-empty string; omit it entirely to log | <>
                     ~s|out everywhere.|}

                _ ->
                  {:email, conn.assigns.current_user.email}
              end

            case mode do
              {:invalid, code, detail} ->
                json(conn, 422, %{error: code, detail: detail})

              mode ->
                revoke_app_token_on_instance(conn, team, bp, mode)
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/push/device-tokens {platform, token, metadata?} → 201 — register
  # THIS device for needs-you push (push-relay spike, mobile charter D15a).
  # USER-authed: the row binds to the calling user; per-user × per-device rows
  # (see Push.DevicePushToken). Idempotent: re-registering the same
  # (platform, token) upserts — clears revoked_at, refreshes metadata — so the
  # app can register on every launch. The registered token is NOT echoed back
  # (the client already holds it; keep responses minimal). 422 on an unknown
  # platform / missing-short-oversize token (token capped at 1024 bytes — the
  # unique-index row cap would otherwise turn oversize into a raw 500).
  # Rate-limited per USER (`push_register:<user_id>` bucket, 10/min — the
  # approve:<user_id> idiom, not per-IP: mobile clients share carrier-NAT IPs)
  # and capped at Push.max_devices_per_user/0 rows per user with
  # revoked-first/stalest-next eviction (mob-bl-push-hardening). Registration
  # rows are the relay's ONLY switch: zero rows → the chat_blocked receiver
  # fans out to nothing.
  post "/v1/push/device-tokens" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      match?(
        {:error, :rate_limited},
        DeviceAuthRateLimiter.check("push_register:" <> conn.assigns.current_user.id)
      ) ->
        json(conn, 429, %{error: "rate_limited"})

      true ->
        case Push.register_device_token(conn.assigns.current_user, conn.body_params) do
          {:ok, device} ->
            json(conn, 201, %{
              id: device.id,
              platform: device.platform,
              registered: true
            })

          {:error, %Ecto.Changeset{}} ->
            json(conn, 422, %{error: "invalid"})
        end
    end
  end

  # POST /v1/barkparks/:id/push-relay → 200 {status, webhook_id, url, workspace,
  # project, dataset} — turn ON needs-you push for this instance (mobile charter
  # D15). The ONE operator action that closes the relay's loop: it provisions the
  # box's workspace-scoped `chat_blocked` webhook row pointed at Cloud's
  # /v1/relay/chat-blocked/:id receiver, and agrees a shared signing secret.
  # Until it runs, Cloud's receiver is a door nobody knocks on.
  #
  # TEAM-ADMIN gated (`/credentials`' RBAC, not `/site-url`'s member gate): it
  # spends the stored admin token to WRITE instance config and ROTATES a signing
  # secret. Team-scoped fail-closed — a wrong-team / nonexistent / malformed id
  # is the SAME 404 (no existence leak). Idempotent: re-running converges an
  # existing row (re-enable + rotate + adopt) instead of duplicating it.
  #
  # NOTE this route is orthogonal to the CREDENTIAL gate: with the row
  # provisioned and no APNs/FCM credentials, deliveries enqueue and cancel
  # terminally at the adapter — honest, inert, zero dead code. See
  # BarkparkCloud.Push.Adapters.NotConfigured for exactly what a human must
  # supply to open that half.
  #
  # Body (all optional): {workspace, project, dataset, blocked_threshold_s}.
  # Defaults come from the barkpark's bootstrap_* triple.
  post "/v1/barkparks/:id/push-relay" do
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            opts = push_relay_opts(conn.body_params)

            # OC24: the audit row commits with the success verdict and never
            # lands on a failed wire. Metadata carries the receiver URL and the
            # scope — public facts. NEVER the secret and never the admin token.
            audit_attrs = %{
              team_id: team.id,
              actor_user_id: conn.assigns.current_user.id,
              action: "barkpark.push_relay_provisioned",
              target_type: "barkpark",
              target_id: bp.id
            }

            result =
              Accounts.audit(
                audit_attrs,
                fn -> Registry.provision_push_relay_webhook(bp, opts) end,
                fn payload ->
                  %{
                    metadata: %{
                      status: payload.status,
                      webhook_id: payload.webhook_id,
                      receiver_url: payload.url,
                      workspace: payload.workspace,
                      dataset: payload.dataset
                    }
                  }
                end
              )

            case result do
              {:ok, payload} ->
                push_event(team.id, "audit")
                json(conn, 200, payload)

              # cch-w58-bl: an EXPLICIT clause, because the `{:error, _other}`
              # catch-all below would report a deliberate refusal as a 500.
              {:error, :suspended} ->
                json(conn, 409, %{error: "suspended"})

              {:error, :not_live} ->
                json(conn, 409, %{error: "not_live"})

              {:error, :no_admin_token} ->
                json(conn, 404, %{error: "no_admin_token"})

              {:error, :decrypt_failed} ->
                json(conn, 500, %{error: "decrypt_failed"})

              {:error, :instance_error} ->
                json(conn, 502, %{error: "instance_unreachable"})

              {:error, {:instance, status, _body}} ->
                # The box answered and refused. 404 there means this instance is
                # too old to carry the scoped webhook route — the same
                # capability-detection shape as the app-token exchange's D8
                # `app_token_unsupported`, so a client can branch on it.
                if status == 404 do
                  json(conn, 409, %{error: "push_relay_unsupported"})
                else
                  json(conn, 502, %{error: "instance_refused", status: status})
                end

              {:error, _other} ->
                json(conn, 500, %{error: "provision_failed"})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/barkparks/:id/site-url {url} → 200 {site_url, webhook_url} — the
  # dwb-6 deferred-URL step. After the user deploys the template repo (Vercel),
  # they paste the live site URL here; the control plane points the instance's
  # bootstrap ISR-revalidation webhook (registered DISABLED with a `.invalid`
  # placeholder at bootstrap, dwb-5) at `<url>/api/barkpark/webhook` and flips it
  # ACTIVE — server-side, with the STORED admin token (never sent to the client),
  # exactly the studio-link pattern.
  #
  # USER-authed + TEAM-SCOPED, fail-closed: any MEMBER of the owning team may wire
  # their site; a wrong-team / nonexistent / malformed id is the SAME 404 (no
  # existence leak). 422 invalid_url (not an http(s) origin); 409 suspended (a
  # suspended box is not written — the refusal fires BEFORE the stored admin
  # token is decrypted, so nothing reaches a wire); 409 not_live while
  # provisioning; 404 no_admin_token / no_bootstrap (pre-feature / template-less);
  # 409 no_webhook (template registered no revalidation hook); 502 on instance
  # failure; 500 on tampered ciphertext. Idempotent — a re-PUT converges (200).
  post "/v1/barkparks/:id/site-url" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      not (is_binary(conn.body_params["url"]) and conn.body_params["url"] != "") ->
        json(conn, 422, %{error: "url_required"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            # OC24 (transactional): the audit row commits with the success
            # verdict and NEVER lands on a failed wire — audit/3 rolls the
            # insert back on any error tuple. The metadata carries the wired
            # URLs (public site facts), never the admin token that did the
            # wiring.
            audit_attrs = %{
              team_id: team.id,
              actor_user_id: conn.assigns.current_user.id,
              action: "barkpark.site_url_set",
              target_type: "barkpark",
              target_id: bp.id
            }

            wire_result =
              Accounts.audit(
                audit_attrs,
                fn -> Registry.wire_site_url(bp, conn.body_params["url"]) end,
                fn %{site_url: site_url, webhook_url: webhook_url} ->
                  %{metadata: %{site_url: site_url, webhook_url: webhook_url}}
                end
              )

            case wire_result do
              {:ok, %{site_url: site_url, webhook_url: webhook_url}} ->
                push_event(team.id, "audit")
                json(conn, 200, %{site_url: site_url, webhook_url: webhook_url})

              {:error, :invalid_url} ->
                json(conn, 422, %{error: "invalid_url"})

              # cch-w58-bl: the control plane does not rewrite a SUSPENDED box's
              # webhook configuration. `app.js` already ships a named human
              # message for this code (ERRORS.suspended).
              {:error, :suspended} ->
                json(conn, 409, %{error: "suspended"})

              {:error, :not_live} ->
                json(conn, 409, %{error: "not_live"})

              {:error, :no_admin_token} ->
                json(conn, 404, %{error: "no_admin_token"})

              {:error, :no_bootstrap} ->
                json(conn, 404, %{error: "no_bootstrap"})

              {:error, :no_webhook} ->
                json(conn, 409, %{error: "no_webhook"})

              {:error, :decrypt_failed} ->
                json(conn, 500, %{error: "decrypt_failed"})

              {:error, :instance_error} ->
                json(conn, 502, %{error: "instance_unreachable"})

              # The wire succeeded but the audit insert did not — audit/3
              # refuses to report an unrecorded success. The instance-side
              # wiring is idempotent (a re-POST converges), so the honest
              # move is a 422 the operator can simply retry.
              {:error, %Ecto.Changeset{} = cs} ->
                json(conn, 422, %{error: "invalid", details: errors(cs)})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/barkparks/:id/self-update → 202 {status: "updating"} — trigger a
  # self-update RUN on the instance (isu-6). The instance is the SOURCE OF
  # TRUTH: the control plane relays POST /v1/admin/self-update server-side with
  # the STORED admin token (never sent to the client), exactly the studio-link
  # pattern, and RELAYS the instance's verdict with its semantics intact:
  #
  #   202 {status: "updating"}                — run started; we also enqueue a
  #                                             one-row status refresh (~60s) so
  #                                             the fleet row reflects the run.
  #   409 {error: {code: "already_running"}}  — a run is already in flight.
  #   503 {error: {code: "not_enabled"}}      — instance did not set
  #                                             BARKPARK_SELF_UPDATE_APPLY=1.
  #   500 {error: {code: "runner_start_failed"}}
  #   404 {error: {code: "not_supported"}}    — pre-feature instance (404s the
  #                                             admin endpoint).
  #
  # ADMIN-gated: rewriting a live box's running code is privileged infra, like
  # DELETE above — require_primary_team_admin halts 401 / 403 no_team / 403 for
  # a plain member. TEAM-SCOPED fail-closed: wrong-team / nonexistent /
  # malformed id is the SAME 404 (no existence leak). 409 not_live while
  # provisioning; 404 no_admin_token for pre-feature rows; 502 when the
  # instance is unreachable; 500 on tampered ciphertext.
  post "/v1/barkparks/:id/self-update" do
    conn = Auth.require_primary_team_admin(conn)

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            cond do
              # cch-w54-bl — a SUSPENDED box is not ASKED TO RUN ANYTHING with
              # the platform's stored admin credential. Isolation (D653) is
              # "the control plane withholds new credentials and maintenance
              # attention; nothing stops, nothing is deleted" — and rewriting a
              # suspended box's running code is the most maintenance-shaped act
              # the control plane has. Same axis as the instance-API proxy's
              # `:mutate` tier (D673): a relay that CHANGES the box is refused,
              # a read is not.
              #
              # Placed as a sibling `cond` clause ABOVE the trigger call — not a
              # leg inside it — exactly as `dispatch_instance_api/4` does, so
              # the ciphertext is never decrypted and NOTHING reaches the wire
              # on the refused path. Same 409 `suspended` slug as studio-link /
              # app-token, which `app.js` (ERRORS.suspended) already renders, so
              # no new console copy is minted.
              bp.suspended ->
                json(conn, 409, %{ok: false, error: %{code: "suspended"}})

              true ->
                self_update_relay(conn, team, bp)
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # The self-update relay itself — split out so the suspension refusal above can
  # be a sibling clause of the whole working path rather than a leg inside it.
  defp self_update_relay(conn, team, bp) do
    force? = conn.body_params["force"] == true

    case Registry.trigger_self_update(bp, force: force?) do
      # PIN HONESTY (isu-w5.2): a pinned box is frozen; an unforced Update
      # click is a 409 (not a silent no-op). `force: true` overrides. The
      # body names the pin so the console can say WHICH release holds the
      # box (S3 reads error.pinned_release for its conflict modal).
      {:error, :pinned} ->
        json(conn, 409, %{error: %{code: "pinned", pinned_release: bp.pinned_release}})

      {:ok, 202, _body} ->
        # OC24: the run started on the box — record the operator
        # trigger (and whether the pin was force-overridden).
        audit_lifecycle_trigger(conn, team, bp.id, "barkpark.self_update_triggered", %{
          name: bp.name,
          force: force?
        })

        # Refresh the row's cached status once the run has had time to
        # land (the run itself takes a minute or two — the sweep would
        # otherwise leave the row stale for up to an hour).
        _ =
          %{"barkpark_id" => bp.id}
          |> BarkparkCloud.Workers.UpdateStatusWorker.new(schedule_in: 60)
          |> Oban.insert()

        push_event(team.id, "fleet")
        json(conn, 202, %{ok: true, status: "updating"})

      {:ok, 409, _body} ->
        json(conn, 409, %{error: %{code: "already_running"}})

      # A REAL instance 503 carries {"error":{"code":"feature_not_configured"}}
      # (self_update_controller.ex). A bare/HTML 503 is the box's front
      # proxy during a restart window — which the 202 path itself causes —
      # and telling the operator to flip BARKPARK_SELF_UPDATE_APPLY=1 for
      # that would be actively wrong. Match on the body, not the status.
      {:ok, 503, %{"error" => %{"code" => "feature_not_configured"}}} ->
        json(conn, 503, %{error: %{code: "not_enabled"}})

      {:ok, 503, _proxy_or_restart_window} ->
        json(conn, 502, %{error: %{code: "instance_unavailable"}})

      {:ok, 404, _body} ->
        json(conn, 404, %{error: %{code: "not_supported"}})

      {:ok, 500, _body} ->
        json(conn, 500, %{error: %{code: "runner_start_failed"}})

      # Any other instance status is outside the endpoint's contract —
      # report the instance misbehaving rather than inventing semantics.
      {:ok, _status, _body} ->
        json(conn, 502, %{error: %{code: "instance_error"}})

      {:error, :not_live} ->
        json(conn, 409, %{error: %{code: "not_live"}})

      # Same mapping as the studio-link route: a missing token is a
      # permanent, actionable condition (re-provision), a decrypt
      # failure an integrity signal — neither is "unreachable".
      {:error, :no_admin_token} ->
        json(conn, 404, %{
          error: %{
            code: "no_admin_token",
            detail:
              "No admin token is stored for this instance yet. It is captured at " <>
                "provision time — a pre-existing instance may need a re-provision."
          }
        })

      {:error, :decrypt_failed} ->
        json(conn, 500, %{error: %{code: "decrypt_failed"}})

      # cch-w60-s4: the box already answered our stored admin credential 401,
      # so the plane refused to spend it again — nothing reached the wire. This
      # arm MUST sit above the catch-all: without it we would relay "we could
      # not reach your box" (502 instance_unreachable) about a box that answered
      # us, which is this epic's own thesis defect committed by the fix. 409 is
      # the shipped family for terminal refusals here (`pinned`, `not_live`) and
      # the code is the Registry's whitelist word verbatim — no third vocabulary.
      #
      # cch-w63-s8: and it leaves a ROW. The 409 is gone the moment the tab is,
      # so the refusal is recorded before it is relayed.
      {:error, :identity_refused} ->
        audit_credentials_refused(conn, team, bp.id, "self_update")
        json(conn, 409, %{error: %{code: "identity_refused"}})

      {:error, _reason} ->
        json(conn, 502, %{error: %{code: "instance_unreachable"}})
    end
  end

  # POST /v1/barkparks/:id/rollback → 202 {status: "started", target_sha,
  # pinned_release} — trigger a blue/green ROLLBACK run on the instance
  # (isu-w6). The control plane relays POST /v1/admin/rollback server-side
  # with the STORED admin token (the self-update seam above) and relays the
  # instance's verdict:
  #
  #   202 {status:"started",target_sha:…}      — preflight passed, the async
  #                                              flip started; by the time we
  #                                              answer, the CP has ALREADY
  #                                              pinned (below).
  #   409 {error:{code:"no_previous_slot"      — typed refusals, relayed
  #               |"already_running"             VERBATIM (D23) — the console
  #               |"not_supported"}}             and CLI key their copy off
  #                                              these exact codes.
  #   503 {error:{code:"not_enabled"}}         — instance did not set
  #                                              BARKPARK_SELF_UPDATE_APPLY=1
  #                                              (matched on the BODY, like
  #                                              self-update: a bare 503 is
  #                                              the front proxy's restart
  #                                              window → 502).
  #
  # PIN ATOMICITY (D16/D17): on instance 202 the CP atomically writes
  # pinned_release = the instance-REPORTED target_sha (never operator input)
  # through the narrow autoupdate_changeset path, then enqueues the one-row
  # status refresh + fleet push exactly like the update trigger. Why: an
  # unpinned rollback is re-updated within one 5-minute rollout tick — a lie.
  # There is NO pin precondition — a pinned box CAN roll back (rollback
  # re-pins by design; the fresh pin replaces the stale one). Freeze-only
  # semantics: if the async flip later fails closed, the pin stays at the
  # intended target while the refreshed status shows reality (OC10 law: a pin
  # freezes, it never downgrades).
  #
  # The fleet-wide halt does NOT gate this route (D18): the halt is the
  # autonomous-rollout brake; a human override wins, matching self-update.
  #
  # ADMIN-gated + TEAM-SCOPED fail-closed exactly like self-update above:
  # 401 / 403 no_team / 403 plain member; wrong-team / nonexistent /
  # malformed id → the SAME 404 (no existence leak); 409 not_live while
  # provisioning; 404 no_admin_token; 500 decrypt_failed; 502 unreachable.
  post "/v1/barkparks/:id/rollback" do
    conn = Auth.require_primary_team_admin(conn)

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            cond do
              # cch-w54-bl — same refusal as self-update above, for the same
              # reason: a rollback is the control plane ASKING A SUSPENDED BOX
              # TO RUN SOMETHING with the stored admin credential, and it would
              # additionally re-pin the row. Sibling `cond` clause above the
              # relay so the ciphertext is never decrypted and nothing reaches
              # the wire; the 409 `suspended` slug is the one `app.js` already
              # maps.
              bp.suspended ->
                json(conn, 409, %{ok: false, error: %{code: "suspended"}})

              true ->
                rollback_relay(conn, team, bp)
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # The rollback relay itself — split out so the suspension refusal above can be
  # a sibling clause of the whole working path rather than a leg inside it.
  defp rollback_relay(conn, team, bp) do
    case Registry.trigger_rollback(bp) do
      {:ok, 202, body} ->
        # Pin at the instance-REPORTED target — never a client value.
        # A 202 without a parsable target_sha is outside the W6
        # instance contract; the run has still started, so relay
        # honestly with the pin untouched rather than unpinning or
        # pretending the flip never began.
        target_sha =
          case body["target_sha"] do
            sha when is_binary(sha) and sha != "" -> sha
            _ -> nil
          end

        pinned_release =
          with sha when is_binary(sha) <- target_sha,
               {:ok, %Barkpark{} = updated} <-
                 Registry.set_autoupdate(bp, %{pinned_release: sha}) do
            updated.pinned_release
          else
            _ -> bp.pinned_release
          end

        # OC24: the flip started on the box — record the operator
        # trigger with the instance-REPORTED target and the pin that
        # now holds it (both facts, never operator input).
        audit_lifecycle_trigger(conn, team, bp.id, "barkpark.rollback_triggered", %{
          name: bp.name,
          target_sha: target_sha,
          pinned_release: pinned_release
        })

        # Refresh the row's cached status once the flip has had time
        # to land — the sweep would otherwise leave the row (and the
        # console) stale for up to an hour.
        _ =
          %{"barkpark_id" => bp.id}
          |> BarkparkCloud.Workers.UpdateStatusWorker.new(schedule_in: 60)
          |> Oban.insert()

        push_event(team.id, "fleet")

        json(conn, 202, %{
          status: "started",
          target_sha: target_sha,
          pinned_release: pinned_release
        })

      {:ok, 409, %{"error" => %{"code" => code}}}
      when code in ["no_previous_slot", "already_running", "not_supported"] ->
        json(conn, 409, %{error: %{code: code}})

      # A REAL instance 503 carries {"error":{"code":"feature_not_
      # configured"}}; a bare/HTML 503 is the box's front proxy during
      # a restart window. Match on the body, not the status.
      {:ok, 503, %{"error" => %{"code" => "feature_not_configured"}}} ->
        json(conn, 503, %{error: %{code: "not_enabled"}})

      {:ok, 503, _proxy_or_restart_window} ->
        json(conn, 502, %{error: %{code: "instance_unavailable"}})

      # Anything else — an unknown 409 code, a pre-rollback instance
      # 404ing the admin endpoint, a 500 — is outside the W6 contract:
      # report the instance misbehaving, never invent semantics.
      {:ok, _status, _body} ->
        json(conn, 502, %{error: %{code: "instance_error"}})

      {:error, :not_live} ->
        json(conn, 409, %{error: %{code: "not_live"}})

      {:error, :no_admin_token} ->
        json(conn, 404, %{
          error: %{
            code: "no_admin_token",
            detail:
              "No admin token is stored for this instance yet. It is captured at " <>
                "provision time — a pre-existing instance may need a re-provision."
          }
        })

      {:error, :decrypt_failed} ->
        json(conn, 500, %{error: %{code: "decrypt_failed"}})

      # cch-w60-s4: same refusal as the self-update relay — the box refuted our
      # stored admin credential, so the plane did not spend it on a rollback
      # either. Above the catch-all, or a refuted box reads as unreachable.
      #
      # cch-w63-s8: same named row as the self-update arm, differing only in the
      # `attempted` fact — one verb, two writes it refused.
      {:error, :identity_refused} ->
        audit_credentials_refused(conn, team, bp.id, "rollback")
        json(conn, 409, %{error: %{code: "identity_refused"}})

      {:error, _reason} ->
        json(conn, 502, %{error: %{code: "instance_unreachable"}})
    end
  end

  # PATCH /v1/barkparks/:id/autoupdate {autoupdate_enabled?, autoupdate_paused?,
  # pinned_release?} → 200 {ok, autoupdate: {enabled, paused, pinned_release,
  # channel}} — set the isu-w4 fleet-autoupdate POLICY (the opt-out / pause /
  # pin escape hatch). Managed instances auto-ride blessed releases by default
  # (opt-out); this is how a team disables, temporarily pauses, or pins one.
  # Only the three team-facing policy fields are accepted — Registry.set_autoupdate
  # → the narrow autoupdate_changeset can touch nothing else (never the in-flight
  # marker, never identity, and NEVER `channel`: the rollout channel is a
  # platform-operator lever — a tenant-writable channel would let any team admin
  # park a behind staging box and close the canary gate for the WHOLE fleet, so
  # a `channel` key in the body is ignored and only echoed read-only). PATCH:
  # absent keys are left unchanged (cast ignores them).
  #
  # ADMIN-gated: a policy that governs unattended production deploys is
  # privileged, like self-update above — require_primary_team_admin halts 401 /
  # 403 no_team / 403 for a plain member. TEAM-SCOPED fail-closed: wrong-team /
  # nonexistent / malformed id is the SAME 404 (no existence leak).
  patch "/v1/barkparks/:id/autoupdate" do
    conn = Auth.require_primary_team_admin(conn)

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            case refuse_unarmed_resume(bp, conn.body_params) do
              {:refuse, arming_checked_at} ->
                json(conn, 409, %{
                  error: "instance_not_armed",
                  details: %{
                    field: "autoupdate_paused",
                    apply_arming: "unarmed",
                    apply_arming_checked_at: arming_checked_at,
                    remedy:
                      "The instance reports one-click apply is off, so the rollout cannot " <>
                        "land a release on it. An enable-apply job has been queued to arm " <>
                        "it automatically (isu-w5) — retry the resume once it lands, or arm " <>
                        "by hand: set BARKPARK_SELF_UPDATE_APPLY=1 on the instance and " <>
                        "restart it."
                  }
                })

              :allow ->
                set_autoupdate_with_audit(conn, team, bp)
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # THE ARM-BEFORE-RESUME ORDERING, ENFORCED (task-0dd7578bc3d2bcbd).
  #
  # Resuming an unarmed box does not achieve what the operator is asking for.
  # The rollout's next advance onto it draws a 503 `feature_not_configured` off
  # the box's own `Runner.enabled?/0`; since #13474 that no longer re-latches
  # `autoupdate_paused` (it records `apply_arming: "unarmed"` and the candidate
  # query skips the box), so the box does not FLAP — but it does silently never
  # update, which is a stuck state wearing a healthy-looking flag. The operator
  # asked for "resume autoupdate" and would have got "unpaused and still never
  # updating", with nothing on this route saying so.
  #
  # So the ordering is refused-with-a-reason rather than documented: arm, THEN
  # resume.
  #
  # ONLY THE TRANSITION, never the steady state. `get_change/2` returns a value
  # only when it DIFFERS from what is stored, so this fires exactly on
  # `paused: true -> false`. An admin editing `pinned_release` on a box that is
  # already unpaused changes nothing here and is not refused, and reading the
  # CHANGESET rather than the raw body means a string `"false"` is caught by the
  # same cast Ecto would have applied.
  #
  # IT RE-MEASURES BEFORE IT REFUSES, and that is the load-bearing part. The
  # stored `apply_arming` is up to an hour old (the `UpdateStatusWorker` sweep
  # runs at :17), so refusing on it would block an operator who armed the box
  # thirty seconds ago until the next sweep — turning this guard into the very
  # thing it exists to remove. One live probe makes arm-then-resume work
  # immediately.
  #
  # AND IT FAILS OPEN ON AN UNPROVABLE NEGATIVE. If the probe cannot reach the
  # box (unreachable, not live, no admin token, 404, bad shape) the stored value
  # is left untouched and the resume is ALLOWED. Refusing on a measurement we
  # could not take would strand an operator with no way forward — a new
  # unclearable state, which is the defect this whole row is about. Allowing is
  # safe precisely because the 503 branch no longer latches: a box that is in
  # fact unarmed gets recorded and skipped on the next advance, not paused.
  defp refuse_unarmed_resume(%Barkpark{} = bp, body_params) do
    resuming? =
      bp
      |> Barkpark.autoupdate_changeset(body_params)
      |> Ecto.Changeset.get_change(:autoupdate_paused) == false

    if resuming? do
      # The RETURN VALUE is the discriminator, not a re-read. `{:ok, _}` is
      # emitted by exactly one path — a decoded 200, i.e. the box answered and we
      # read its body. Every failure rung answers `{:error, reason}` and leaves
      # the arming columns exactly as it found them, so a re-read after an
      # unreachable box would hand back the STALE "unarmed" and refuse on a
      # measurement that was never taken. That distinction is the whole fail-open.
      #
      # A `nil` arming inside a decoded 200 is a real measurement too — a
      # pre-#12995 box that carries no `apply_enabled` key — and it ALLOWS,
      # matching `next_autoupdate_candidate/1`, which treats unmeasured as
      # eligible. Only the literal word "unarmed" refuses.
      case Registry.refresh_update_status(bp) do
        {:ok, %Barkpark{apply_arming: "unarmed"} = fresh} ->
          {:refuse, fresh.apply_arming_checked_at}

        _ ->
          :allow
      end
    else
      :allow
    end
  end

  defp set_autoupdate_with_audit(conn, team, bp) do
    # OC24 (transactional): a policy governing unattended production
    # deploys changes ONLY with its record — the policy write and the
    # barkpark.autoupdate_changed row share one transaction (the
    # barkpark.deleted prior art), and the metadata carries the NEW
    # settings as persisted (never client input).
    audit_attrs = %{
      team_id: team.id,
      actor_user_id: conn.assigns.current_user.id,
      action: "barkpark.autoupdate_changed",
      target_type: "barkpark",
      target_id: bp.id
    }

    set_result =
      Accounts.audit(
        audit_attrs,
        fn -> Registry.set_autoupdate(bp, conn.body_params) end,
        fn updated ->
          %{
            metadata: %{
              enabled: updated.autoupdate_enabled,
              paused: updated.autoupdate_paused,
              pinned_release: updated.pinned_release
            }
          }
        end
      )

    case set_result do
      {:ok, updated} ->
        # isu-w5 (task-509f5fd02bc48f9c criterion 1): enabling autoupdate on a
        # box already MEASURED unarmed files its repair right here — the earlier
        # unarmed measurement could not enqueue (the consent gate reads
        # autoupdate_enabled, which was false until this write). Best-effort +
        # deduped; the hourly sweep's re-measurement is the backstop.
        if updated.autoupdate_enabled and updated.apply_arming == "unarmed" do
          _ = Registry.maybe_enqueue_enable_apply_job(updated)
        end

        push_event(team.id, "fleet")
        push_event(team.id, "audit")

        json(conn, 200, %{
          ok: true,
          autoupdate: %{
            enabled: updated.autoupdate_enabled,
            paused: updated.autoupdate_paused,
            pinned_release: updated.pinned_release,
            channel: updated.channel
          }
        })

      {:error, %Ecto.Changeset{} = cs} ->
        # cch-w62-bl — ONE envelope shape for the whole route. The 404
        # arms are flat, and this arm used to be the route's lone nested
        # `%{error: %{code: "invalid"}}` — one route, two shapes, and a
        # validation refusal that reached the console details-blind: the
        # wave-37 per-field ladder reads `details` off the TOP level, so
        # the changeset's own answer (which field, what rule) was thrown
        # away and a permanent refusal rendered as a generic. Flat
        # `error` + `details` is the shape ~100 sibling 422 emitters
        # already use, and both consumers of this route read it today:
        # `friendly()` (app.js) keys flat strings natively, and the Go
        # CLI's `decodeRouteErrorCode` tries object-then-string. The
        # envelope-shape census pins this route all-flat.
        json(conn, 422, %{error: "invalid", details: errors(cs)})
    end
  end

  # ── Fleet-wide autoupdate kill switch (isu-w5.2) ──────────────────────────
  #
  # WORKER-gated, cross-team by design — the same faceless WORKER token
  # (`require_worker`) behind the `/v1/internal/*` fleet-ops surface, NOT a
  # team-scoped admin and NOT the platform operator (this block's opening line
  # used to say "PLATFORM-OPERATOR gated" one sentence before naming
  # `require_worker`, which is the contradiction isu-backlog-operator-principal
  # exists to delete). The HUMAN principal is the `/v1/operator/autoupdate*`
  # trio below — that is what the console and `bp cloud rollout` call. These
  # three stay the worker's alone. Fails CLOSED: an unset/blank/wrong token 401s
  # every route, so the kill switch can never be flipped by omission.
  #
  #   GET  /v1/admin/autoupdate         → 200 {halted: bool}   — current state
  #   POST /v1/admin/autoupdate/halt    → 200 {halted: true}   — engage
  #   POST /v1/admin/autoupdate/resume  → 200 {halted: false}  — release
  #
  # Halt stops the AutoupdateRolloutWorker from ADVANCING new self-updates fleet-
  # wide; settle bookkeeping for in-flight boxes continues so state stays honest.
  get "/v1/admin/autoupdate" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, %{halted: Registry.autoupdate_halted?()})
    end
  end

  post "/v1/admin/autoupdate/halt" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      {:ok, _} = Registry.set_autoupdate_halted(true)
      json(conn, 200, %{halted: true})
    end
  end

  post "/v1/admin/autoupdate/resume" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      {:ok, _} = Registry.set_autoupdate_halted(false)
      json(conn, 200, %{halted: false})
    end
  end

  # ── Operator console: session-gated /v1/operator/* read seam (GR39) ────────
  #
  # The fleet-ops surface above (/v1/admin/* + /v1/internal/*) is `require_worker`
  # — a faceless off-box secret, 401-DEAD to a browser SESSION bearer. The
  # Operator console (its sidebar entry gated on /v1/me's `platform_operator`)
  # reads the fleet through the operator's SESSION, so these thin proxies are the
  # NET-NEW seam. `Auth.require_platform_operator` fails closed: no session 401,
  # a non-operator session 403, reading the SAME
  # `Notifications.platform_admin_emails/0` allowlist as the /v1/me boolean (ONE
  # definition of operator-ness — isu-backlog-operator-principal inherits both).
  # Zero new business logic: every handler is a thin read/toggle over an existing
  # Registry/Notifications function, mirroring the /v1/admin/autoupdate* trio
  # above. NO digest-send route here (GR40 cut it — gr-backlog-operator-digest-
  # send is the successor). The require_worker routes stay untouched (GR9/GR39).
  get "/v1/operator/autoupdate" do
    conn = Auth.require_platform_operator(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, %{halted: Registry.autoupdate_halted?()})
    end
  end

  post "/v1/operator/autoupdate/halt" do
    conn = Auth.require_platform_operator(conn, [])

    if conn.halted do
      conn
    else
      {:ok, _} = Registry.set_autoupdate_halted(true)
      json(conn, 200, %{halted: true})
    end
  end

  post "/v1/operator/autoupdate/resume" do
    conn = Auth.require_platform_operator(conn, [])

    if conn.halted do
      conn
    else
      {:ok, _} = Registry.set_autoupdate_halted(false)
      json(conn, 200, %{halted: false})
    end
  end

  # GET /v1/operator/fleet → 200 {barkparks: [...], staging_gate_open: bool} —
  # the cross-team fleet roll-up the console renders. Per-instance projection:
  # id/name/channel/update_state + the in-flight marker autoupdate_triggered_at
  # (nil until a self-update is triggered) + the three-valued arming pair
  # apply_arming/apply_arming_checked_at (null = NOT MEASURED, never false).
  # Top-level staging_gate_open mirrors
  # the canary gate the kill switch respects (Registry.staging_gate_open?/0).
  get "/v1/operator/fleet" do
    conn = Auth.require_platform_operator(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, %{
        barkparks: Enum.map(Registry.all_barkparks(), &operator_fleet_json/1),
        staging_gate_open: Registry.staging_gate_open?()
      })
    end
  end

  # GET /v1/operator/deploy-ledger/census?from=&to= → 200 <census> — the
  # cross-site deploy ledger: counts per failure class, counts per site, and the
  # failure rate WITH its denominator, over a PINNED inserted_at window
  # (deploy-reliability W1 S2).
  #
  # COUNTS, not rows: one grouped query folds ~1,400 (site, stage, reason) groups
  # instead of the 26,000 rows a caller would otherwise pull over 13 per-site
  # round trips. `Registry.latest_deployment_status_map/1` is deliberately NOT
  # widened to carry this — it is LIMIT-1-per-site by construction, so it can
  # express freshness but never a rate, and bp-search-template D24 froze its
  # four-key select as an honesty law. This is built beside it.
  #
  # `from` and `to` are REQUIRED (422 otherwise). There is no default window on
  # purpose: daily volume fell 2,766 → 332 over six days, so an unpinned
  # "now minus" window silently compares two different populations and reports a
  # volume collapse as a repair. Below `DeployLedger.min_sample/0` attempted rows
  # the rate node REFUSES a percentage and says so instead.
  #
  # W15 S3: the envelope also carries `delivery` — the time-to-web census, whose
  # percentiles REFUSE rather than print a number they cannot identify. See
  # `deploy_census_json/2`.
  get "/v1/operator/deploy-ledger/census" do
    conn = Auth.require_platform_operator(conn, [])

    if conn.halted do
      conn
    else
      case DeployLedger.parse_window(conn.query_params["from"], conn.query_params["to"]) do
        {:ok, from, to} ->
          json(conn, 200, deploy_census_json(from, to))

        {:error, detail} ->
          json(conn, 422, %{error: "invalid_window", detail: detail})
      end
    end
  end

  # GET /v1/deploy-ledger/census?from=&to=[&site_ids=a,b] → 200 <census + scope>
  # — THE SAME census, over the CALLER'S OWN sites (dr-w16-s6). The operator
  # route above is gated by `require_platform_operator`, and PLATFORM_ADMIN_EMAILS
  # is unset in production: measured live this wave, that route answers
  # `403 {"error":"forbidden","scope":"platform","required":"platform_operator"}`
  # to every real account, in the same minute GET /v1/sites answers 200 to the
  # same token. Sixteen waves built a correct number nobody could read. This is
  # the read.
  #
  # ONE census computation, never two: `DeployLedger.census/3` is called here
  # with a `:site_ids` scope and nowhere else re-implemented — an OPT on the one
  # entry point rather than a second entry point. (The in-repo precedent this
  # used to cite was itself deleted by dr-w26-s6 as reader-less; the rule it
  # illustrated stands on its own.)
  #
  # THE CREDENTIAL IS `require_user_or_pat` + `require_ability("read")`, NOT a
  # session. A session-only gate is PAT-dead (D219), so no CI or automation
  # credential could ever compute the owner's own number — the same class of
  # unreadable-by-construction defect the operator route already demonstrates.
  # The precedents agree: GET /v1/barkparks and GET /v1/sites both gate this way.
  #
  # THE SCOPE IS DERIVED, NEVER SUPPLIED. `deployments` has NO `team_id` column
  # (Registry.Deployment `belongs_to :site` only), so team scope must hop through
  # `sites.team_id`. `?site_ids=` therefore NARROWS the team's own set — it is
  # INTERSECTED with it, never used as the source. If it were the source, a
  # caller naming another team's site id would read that team's rows out of their
  # own census body.
  #
  # THE INTERSECTION IS COMPUTED IN ELIXIR, not in SQL. `sites.id` and
  # `deployments.site_id` are `binary_id`, so a client-supplied non-UUID reaching
  # either column raises `Ecto.Query.CastError` → a 500, i.e. a brand-new silent
  # failure on the route this epic built to END silent failures. Filtering the
  # OWNED list (always well-formed UUIDs from the DB) drops junk before any query
  # runs, so `?site_ids=nope` is an honest `200` with `volume: 0`.
  #
  # A TEAMLESS CALLER GETS 422 no_team, not 404. Every one of the router's 404
  # nil-team arms belongs to a PATH-ID route, where 404 correctly conflates
  # "wrong team" with "no such id". This route has no path id, so a 404 would lie
  # about a route that exists; a 403 would assert an authority no grant supplies.
  get "/v1/deploy-ledger/census" do
    conn = conn |> Auth.require_user_or_pat([]) |> Auth.require_ability("read")

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        team = conn.assigns.current_team
        owned = Enum.map(Registry.list_sites_for_team(team), & &1.id)
        scoped = intersect_owned_sites(owned, conn.query_params["site_ids"])

        case DeployLedger.parse_window(conn.query_params["from"], conn.query_params["to"]) do
          {:ok, from, to} ->
            census = DeployLedger.census(from, to, site_ids: scoped)

            json(
              conn,
              200,
              census
              |> Map.put(:scope, census_scope(team, scoped))
              # THE DELIVERY NODE, SCOPED (dr-w21-s6). It was added ONLY by
              # `deploy_census_json/2` on the OPERATOR route, so wave 15's
              # reader shipped onto a route nobody can reach: measured live,
              # `bp cloud deployments -o table` rendered "NOT MEASURED — this
              # control plane sends no delivery census" to every real operator,
              # because the only route a real token can reach is this one and it
              # carried no `delivery` key.
              #
              # `site_ids: scoped` IS THE WHOLE SAFETY ARGUMENT and it is not
              # optional decoration. `DeployLedger.delivery/3` filtered
              # `inserted_at` + `environment` and nothing else until this slice
              # threaded the option through — a bare `delivery(from, to)` here
              # would pool FOREIGN teams' waits into this team's percentiles and
              # name their `site_id`s in the `sites` list under them.
              |> Map.put(:delivery, DeployLedger.delivery(from, to, site_ids: scoped))
            )

          {:error, detail} ->
            json(conn, 422, %{error: "invalid_window", detail: detail})
        end
    end
  end

  # GET /v1/deliveries[?sha=<sha>][&limit=n] → 200 {deliveries, count, …} — THE
  # PLATFORM'S OWN PAST, readable by a human (dr-w23-s2, charter D385).
  #
  # THE CREDENTIAL IS `require_user_or_pat_or_worker` + `require_ability("read")`,
  # and that is the load-bearing half of this slice.
  #
  # AN OPERATOR GATE WOULD BE WRONG HERE, and that ruling is unchanged:
  # `require_platform_operator` delegates to `require_user`, which authenticates
  # SESSION tokens ONLY — so an operator gate would answer a PAT **401, never
  # 403** (D412, measured live). A record that only a browser session can read is
  # a record no script, no CI job and no `bp` invocation can ever check, which is
  # the same unreadable-by-construction defect the operator census demonstrates.
  # PAT reachability (D385/D412) is PRESERVED here, not replaced.
  #
  # AND THE WRITER CAN READ ITS OWN RECORD (task-e2acb66e9ed0da09). The write
  # half is `POST /v1/internal/platform-deliveries` under `require_worker` —
  # deploy.yml's crown step carries `WORKER_TOKEN` and no other credential. Under
  # `require_user_or_pat` alone this route answered that same principal 401, so
  # the record had no working API read path for the principal that WRITES it:
  # crown-reconcile run 31311887504 printed the downgrade 22 times, once per sha,
  # and survived only by SSH-ing in and reading `platform_deliveries` out of the
  # control plane's own postgres container. A fallback that always fires is a
  # broken door with a working window.
  #
  # THIS WIDENS NOTHING A WORKER DID NOT ALREADY HOLD. `WORKER_TOKEN` is a
  # faceless off-box shared secret that already reaches the cross-team
  # `GET /v1/internal/barkparks`, every team's provision-job queue, and the
  # writer of these very rows. It is admitted here FACELESSLY (no current_user,
  # no current_team) and clamped to `["read"]`, so `require_ability` 403s it on
  # write/deploy/root. It gains no reach into the TENANT delivery logs — GET
  # /v1/notifications/deliveries (`require_user` + team scoping) and GET
  # /v1/barkparks/:id/api/webhooks/:webhook_id/deliveries (`proxy_instance_webhook`
  # → `require_user`) are untouched and still 401 a worker. Both arms are pinned
  # in `test/barkpark_cloud/platform_delivery_test.exs` §4.
  #
  # NOT a node on GET /v1/sites/:id/deployments: that route is session-only and
  # 401s a read PAT today, and re-tiering it is D219's cross-epic ruling — filed,
  # not built, and emphatically not this slice's to build.
  #
  # NOT TEAM-SCOPED, on purpose. These rows are Barkpark's OWN deploys; there is
  # no `sites` row and therefore no `team_id` to scope by (that is also why they
  # cannot live in `deployments`). The body carries no tenant content — a sha,
  # a run id and four clocks — so the read is the platform's operational record,
  # and `scope: "platform"` says so in the envelope rather than leaving a reader
  # to assume it was filtered to them.
  #
  # AN UNKNOWN SHA IS AN HONEST EMPTY LIST, not a 404. "Nothing was ever recorded
  # for this sha" is the single most useful thing this table can say about a
  # deploy that went silent, and a 404 would render it as "no such route".
  get "/v1/deliveries" do
    conn = conn |> Auth.require_user_or_pat_or_worker([]) |> Auth.require_ability("read")

    if conn.halted do
      conn
    else
      qp = fetch_query_params(conn).query_params
      sha = PlatformDelivery.normalize_sha(qp["sha"])
      limit = PlatformDelivery.clamp_limit(qp["limit"])

      case PlatformDelivery.list(sha: sha, limit: limit) do
        {:ok, rows} ->
          json(conn, 200, %{
            deliveries: Enum.map(rows, &PlatformDelivery.to_json/1),
            count: length(rows),
            sha: sha,
            limit: limit,
            scope: "platform"
          })

        {:error, :unavailable} ->
          json(conn, 503, platform_deliveries_unavailable())

        {:error, reason} ->
          Logger.error("platform_deliveries: read refused: #{inspect(reason)}")
          json(conn, 500, %{error: "read_failed"})
      end
    end
  end

  # The ONE refusal body both platform-delivery routes answer when this control
  # plane has no `platform_deliveries` table yet — written once so the recorder
  # and the reader can never drift into two different names for one condition.
  # 503, not 404: the route exists and the caller should retry after the
  # `cloud/**` merge lands, which is precisely what the detail says.
  defp platform_deliveries_unavailable do
    %{
      error: "unavailable",
      reason: "platform_deliveries_missing",
      detail:
        "this control plane has not run the platform_deliveries migration yet — " <>
          "an api-only merge deploys the instance leg without the cloud/ one. Retry " <>
          "after the cloud release lands; nothing was recorded."
    }
  end

  # The scope line the team census prints on EVERY response. It carries the team
  # SLUG and not the team_id, because the route already holds the whole %Team{}
  # and a UUID cannot render "team guerrilla — 13 sites".
  #
  # AND THE COUNT NAMES ITS POPULATION. `registered_sites` is sites REGISTERED to
  # the team and inside this request's scope — NOT the number of sites that
  # deployed in the window, which is smaller and always will be: on the live
  # control plane the owning team holds 13 sites while only 12 distinct site_ids
  # appear in `deployments` at all (`auto-proof` has never deployed). An
  # unlabelled "13" beside a `sites` node of length 12 is the first thing an
  # operator would have to explain away.
  defp census_scope(team, site_ids) do
    %{
      team: team.slug,
      site_ids: site_ids,
      registered_sites: length(site_ids),
      registered_sites_population:
        "sites registered to this team and inside this request's scope — not the " <>
          "number of sites that deployed in the window (a site that has never " <>
          "deployed is counted here and absent from `sites`)"
    }
  end

  # The team's own site ids, optionally NARROWED by `?site_ids=a,b`. The owned
  # list is the SOURCE and the request is only ever a filter over it, so a
  # foreign id contributes nothing and a malformed one cannot reach a binary_id
  # column. Absent/blank param = the team's whole set.
  defp intersect_owned_sites(owned, raw) when is_binary(raw) do
    requested =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case requested do
      [] -> owned
      list -> Enum.filter(owned, &(&1 in list))
    end
  end

  defp intersect_owned_sites(owned, _raw), do: owned

  # GET /v1/operator/deliveries → 200 {deliveries: [<delivery_json>]} — the
  # FLEET-DIGEST send log (event fleet_digest, ANY team), newest first.
  #
  # RETRACTED (cch-w56-s3): this comment used to claim "these rows are
  # structurally invisible to the team-scoped /v1/notifications/deliveries, so
  # this is their only read surface". Both halves were false. The writer stamps
  # a REAL team_id, so a team's own admins DO see their receipts through
  # /v1/notifications/deliveries?event=fleet_digest — dispatched against the
  # reader as it stands, a team owner got rows=2 and a plain member rows=1,
  # correctly self-scoped. What this route adds is OPERATOR scope: every team's
  # receipts on one page, which is a cross-team disclosure of member addresses
  # and is gated on require_platform_operator alone. `?limit` caps the page via
  # parse_int, hard-capped at 200 HERE (list_fleet_deliveries rides the context
  # default; the router owns the clamp — the /v1/notifications/deliveries
  # precedent).
  get "/v1/operator/deliveries" do
    conn = Auth.require_platform_operator(conn, [])

    if conn.halted do
      conn
    else
      limit = min(parse_int(conn.query_params["limit"], 50), 200)
      deliveries = Notifications.list_fleet_deliveries(limit)
      json(conn, 200, %{deliveries: Enum.map(deliveries, &delivery_json/1)})
    end
  end

  # GET /v1/operator/warm-pool → 200 {ready: n} — the warm-pool depth
  # (ready + refreshing, the reconciler's grow/shrink input).
  get "/v1/operator/warm-pool" do
    conn = Auth.require_platform_operator(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, %{ready: Registry.count_ready_warm_servers()})
    end
  end

  # PATCH /v1/admin/barkparks/:id/channel {channel: "prod"|"staging"} → 200
  # {ok, id, channel} — assign an instance's rollout channel (isu-w5.2).
  # PLATFORM-OPERATOR gated (`require_worker`), cross-team by design, like the
  # kill switch above: a staging box IS the fleet-wide canary gate, so channel
  # assignment is an operator lever — never the tenant autoupdate PATCH, where
  # channel is echoed read-only. 422 on anything but prod|staging; unknown /
  # malformed id → 404. Fails CLOSED: unset/blank/wrong token 401s.
  patch "/v1/admin/barkparks/:id/channel" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.get_barkpark(conn.path_params["id"]) do
        %Barkpark{} = bp ->
          case Registry.set_channel(bp, conn.body_params["channel"]) do
            {:ok, updated} ->
              push_event(updated.team_id, "fleet")
              json(conn, 200, %{ok: true, id: updated.id, channel: updated.channel})

            {:error, %Ecto.Changeset{}} ->
              json(conn, 422, %{error: %{code: "invalid"}})
          end

        nil ->
          json(conn, 404, %{error: "not_found"})
      end
    end
  end

  # POST /v1/barkparks/:id/domain {domain} → 202 {ok, custom_host, status:
  # "attaching"} — attach a custom domain to a managed instance: a platform-zone
  # host (gyldendal.barkpark.cloud) or, since attach-domain V2, an ARBITRARY
  # customer-owned FQDN (barkpark.jarl.no). Persists the validated custom_host
  # on the row (Registry.set_custom_host; a malformed domain is 422
  # invalid_domain) and enqueues an "attach_domain" job the Go worker drains
  # (platform hosts: DNS A record + box wiring; external hosts: box wiring only
  # — the customer owns DNS).
  #
  # V2 OWNERSHIP PROOF, fail-closed: an external FQDN must ALREADY resolve
  # (A/AAAA, system resolver — injectable via :attach_domain_dns) to the
  # instance's box IP before anything is persisted or enqueued; a miss is 422
  # {error: domain_not_pointed, expected_ip, observed}. You can only attach a
  # domain you already pointed at your own box. The Go worker re-verifies
  # resolution box-side before touching the machine (defense in depth).
  #
  # 409 taken when the host is already claimed by a site domain / another
  # instance's custom_host (exact, or nesting under a different team's host) /
  # a provisioning FQDN; 409 already_attaching while a previous attach is still
  # in flight (the one-active-job-per-kind partial index); 409 already_attached
  # {custom_host, detail} when THIS instance already answers on a different
  # host — a re-attach is refused, never an overwrite, because an overwrite
  # strands the previous host's A record on a live box (cch-w54-bl). Attaching
  # the SAME host again is still a 202 (the failed-attach recovery path).
  #
  # ADMIN-gated: pointing platform DNS + rewriting a live box's Caddy/env is
  # privileged infra, like self-update above — require_primary_team_admin halts
  # 401 / 403 no_team / 403 for a plain member. TEAM-SCOPED fail-closed:
  # wrong-team / nonexistent / malformed id is the SAME 404 (no existence leak).
  post "/v1/barkparks/:id/domain" do
    conn = Auth.require_primary_team_admin(conn)

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team
        domain = conn.body_params["domain"]

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            if is_binary(domain) and domain != "" do
              attach_custom_domain(conn, team, bp, domain)
            else
              json(conn, 422, %{error: "domain_required"})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # The validate → ownership-proof → persist/enqueue tail of POST
  # /v1/barkparks/:id/domain, after the auth + team-scope + presence gates all
  # passed. Shape validation runs FIRST (a malformed domain 422s before any
  # resolver call); a platform-zone host then rides straight to persist (we own
  # that DNS — pointing it IS the attach), while an external FQDN must pass the
  # V2 ownership proof (DomainOwnership.pointed_at? against the box IP,
  # fail-closed) before anything is written.
  defp attach_custom_domain(conn, team, bp, domain) do
    case Registry.validate_custom_host(bp, domain) do
      {:ok, host} ->
        if Barkpark.platform_custom_host?(host) do
          persist_and_enqueue_domain(conn, team, bp, domain)
        else
          case DomainOwnership.pointed_at?(host, bp.host) do
            :ok ->
              persist_and_enqueue_domain(conn, team, bp, domain)

            {:error, observed} ->
              json(conn, 422, %{
                error: "domain_not_pointed",
                expected_ip: bp.host,
                observed: observed
              })
          end
        end

      {:error, %Ecto.Changeset{}} ->
        json(conn, 422, %{error: "invalid_domain"})
    end
  end

  # OC24 (transactional): the custom_host persist and its
  # barkpark.domain_attached row share one transaction — a rejected/taken host
  # writes NO row (the barkpark.deleted prior art). The audited fact is the
  # PERSISTED host (normalized by the changeset, never raw input); the enqueue
  # below is the async half and its 409/422 does not unwrite the host — the
  # audit honestly records the attach that DID land on the row.
  defp persist_and_enqueue_domain(conn, team, bp, domain) do
    audit_attrs = %{
      team_id: team.id,
      actor_user_id: conn.assigns.current_user.id,
      action: "barkpark.domain_attached",
      target_type: "barkpark",
      target_id: bp.id
    }

    set_result =
      Accounts.audit(
        audit_attrs,
        fn -> Registry.set_custom_host(bp, domain) end,
        fn bp -> %{metadata: %{custom_host: bp.custom_host}} end
      )

    case set_result do
      {:ok, bp} ->
        push_event(team.id, "audit")

        case Registry.enqueue_attach_domain_job(bp) do
          {:ok, _job} ->
            push_event(team.id, "fleet")
            json(conn, 202, %{ok: true, custom_host: bp.custom_host, status: "attaching"})

          {:error, :already_attaching} ->
            json(conn, 409, %{error: "already_attaching"})

          {:error, _changeset} ->
            json(conn, 422, %{error: "invalid"})
        end

      # cch-w54-bl: this instance already answers on a DIFFERENT host. The
      # persist is refused rather than overwritten — overwriting strands the
      # previous host's A record on a live, billed box and drops the only
      # pointer the plane had to it. There is no detach verb on this surface to
      # sequence instead, so the refusal names the host that is in the way.
      # Re-attaching the SAME host still succeeds (the failed-job recovery
      # path) and never reaches this arm.
      {:error, {:already_attached, existing}} ->
        json(conn, 409, %{
          error: "already_attached",
          custom_host: existing,
          detail:
            "This instance already answers on #{existing}. Attaching a different " <>
              "domain would leave #{existing}'s DNS record pointing at a live box " <>
              "with nothing tracking it, so the attach is refused. Re-attaching " <>
              "#{existing} itself is still allowed."
        })

      {:error, :taken} ->
        json(conn, 409, %{error: "taken"})

      {:error, %Ecto.Changeset{}} ->
        json(conn, 422, %{error: "invalid_domain"})
    end
  end

  # GET /v1/barkparks/:id/bootstrap → 200 {template, workspace, project, dataset,
  # read_token, env} — the dwb-4 content-bootstrap outputs the worker reported on
  # /succeed, decrypted for the OWNER (the dashboard/dwb-6 deploy step consumes
  # them). Follows the /credentials pattern exactly: team-admin-gated,
  # fail-closed, the same 404 for another team's barkpark / an unknown id (no
  # existence leak). 404 "no_bootstrap" when no template bootstrap ever ran
  # (template-less launch / pre-feature instance); 500 on a tampered ciphertext.
  # Show-to-owner — treat the response as a secret (it carries the read token).
  get "/v1/barkparks/:id/bootstrap" do
    # RBAC (rbac-roles): reveals the instance read token → team admin (owner/admin) only.
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          # cch-idor-s3 — a SUSPENDED box reveals nothing. Mirrors /credentials
          # (cch-w54-s2): suspension is billing's "data retained, access
          # revoked", and this route hands back the instance read_token, the
          # build env, and the webhook HMAC — all secrets. Keyed on the same
          # boolean the console paints, and placed ABOVE the reveal so
          # Registry.reveal_bootstrap is never reached on a suspended box. Same
          # 409 "suspended" shape as /credentials, /studio-link, /app-token.
          %Barkpark{team_id: tid, suspended: true} when tid == team.id ->
            json(conn, 409, %{
              error: "suspended",
              detail:
                "This instance is suspended. The content bootstrap is not revealed " <>
                  "until the suspension is cleared."
            })

          %Barkpark{team_id: tid} = bp when tid == team.id ->
            case Registry.reveal_bootstrap(bp) do
              {:ok, nil} ->
                json(conn, 404, %{
                  error: "no_bootstrap",
                  detail:
                    "No content bootstrap is stored for this instance. It is captured at " <>
                      "provision time when a template was chosen at launch."
                })

              {:ok, boot} ->
                # `vercel` rides along so the ready screen knows whether the
                # zero-paste handoff is available / already deployed — same
                # team-admin custody as the read token this payload carries.
                json(conn, 200, Map.merge(boot, %{url: bp.url, vercel: Vercel.state(bp)}))

              :error ->
                json(conn, 500, %{error: "decrypt_failed"})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/barkparks/:id/vercel-deploy — the zero-paste Vercel handoff
  # (task-4e4a53b101a97051): platform-deploy the instance's template with its
  # bootstrap env installed server-side, mint a claim code, and return the
  # claim/deployment state. Idempotent on the project (a re-click re-mints only
  # the code). Team-admin-gated (it spends the team's content credentials) and
  # feature-flagged off with a 503 until the platform token is wired — the SPA
  # then keeps the classic /new/clone copy-block handoff.
  post "/v1/barkparks/:id/vercel-deploy" do
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      not Vercel.configured?() ->
        json(conn, 503, %{
          error: "feature_not_configured",
          detail: "The Vercel platform token is not configured on this control plane."
        })

      true ->
        team = conn.assigns.current_team

        case Registry.get_barkpark(conn.path_params["id"]) do
          %Barkpark{team_id: tid} = bp when tid == team.id ->
            case Vercel.deploy_for(bp) do
              {:ok, state} ->
                # OC24: the deploy + claim-code mint landed — record the
                # trigger. Never the state: its claim_url is a bearer-shaped
                # capability link (whoever holds it claims the deployment).
                audit_lifecycle_trigger(conn, team, bp.id, "barkpark.vercel_deploy_triggered", %{
                  name: bp.name
                })

                push_event(bp.team_id, "fleet")
                json(conn, 201, %{ok: true, vercel: state})

              {:error, :no_bootstrap} ->
                json(conn, 409, %{
                  error: "no_bootstrap",
                  detail:
                    "No content bootstrap is stored for this instance, so there is " <>
                      "nothing to wire the deployment to."
                })

              {:error, :not_deployable} ->
                json(conn, 422, %{
                  error: "not_deployable",
                  detail: "This template does not ship a standalone app to deploy."
                })

              {:error, reason} ->
                # The client seam failed (Vercel API error / not configured
                # mid-flight). The RAW Vercel v13 response body rides
                # `{:vercel_http_error, status, body}` (Vercel.Real.request/1 on a
                # non-2xx) and can carry account/project internals — so it is
                # NEVER echoed: the full detail stays server-side for operators
                # (origin/main did NOT log here — redaction alone would blind
                # them), the client gets only the bounded, status-keyed
                # `vercel_reason/1`.
                Logger.error("vercel_error: #{inspect(reason)}")
                json(conn, 502, %{error: "vercel_error", detail: vercel_reason(reason)})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # A SAFE, generic Vercel-error summary for the CLIENT. `Vercel.Real.request/1`
  # binds the RAW Vercel v13 response body into `{:vercel_http_error, status,
  # body}` on a non-2xx (deploy_for/1's with-chain short-circuits it verbatim to
  # the 502 detail), and that body can carry account/project internals. So it is
  # NEVER echoed to the client: the http-error shape collapses to a bounded
  # message keyed ONLY on the integer status, and EVERY other error shape
  # (`:not_configured`, `:http_client_not_configured`, a `Jason.DecodeError`
  # whose `.data` is body-bearing, a raw transport tuple) collapses to one
  # generic constant via the BARE `_` catch-all (fail-closed — an unexpected term
  # never reaches the wire raw). The full detail is `Logger.error`'d at the router
  # else arm, so operators keep the diagnostic. The `error:` CODE
  # (`vercel_error`) is unchanged, so the JS `friendly()` / Go `cloudError` key
  # still resolves with zero UI regression. Mirrors `cloudflare_reason/1` +
  # `billing_reason/1` above.
  defp vercel_reason({:vercel_http_error, status, _body}) when is_integer(status) do
    "Vercel rejected the deploy (HTTP #{status})"
  end

  defp vercel_reason(_reason) do
    "the Vercel deploy could not be completed"
  end

  # A SAFE, generic billing-error summary for the CLIENT. The Stripe gateway
  # binds the RAW Stripe HTTP response body into `{:stripe_http_error, status,
  # body}` (StripeGateway.request/2), and that body can carry customer/PII
  # internals — `cus_…` ids, request echoes. So it is NEVER echoed to the
  # client: the http-error shape collapses to a bounded message keyed ONLY on
  # the integer status, and EVERY other error shape collapses to one generic
  # constant (fail-closed — an unexpected term never reaches the wire raw). The
  # full detail is logged server-side at the gateway bind, so operators keep the
  # diagnostic. NOTE: deliberately NOT `vercel_reason/1` — a shared summariser
  # would couple two providers' redaction; each keeps its own status-keyed +
  # bare-`_` fail-closed pair. The `error:` CODE is unchanged, so the
  # JS `friendly()` / Go cloudError key still resolves with zero UI regression.
  defp billing_reason({:stripe_http_error, status, _body}) when is_integer(status) do
    "billing provider returned an error (HTTP #{status})"
  end

  defp billing_reason(_reason) do
    "billing request could not be completed"
  end

  # The cf-in-front deploy binding (D57) THREADS the raw Cloudflare v4 response
  # body into `{:cloudflare_http_error, status, body}` (Cloudflare.Real.request/1
  # on a non-2xx), and that body can carry account/zone internals — `cf_zone_id`,
  # record ids, the connected account's own metadata. So it is NEVER echoed to
  # the client: the http-error shape collapses to a bounded message keyed ONLY on
  # the integer status, and EVERY other shape reaching the else arm (a
  # Jason.DecodeError struct whose `.data` is body-bearing, the `:not_configured`
  # / `:http_client_not_configured` atoms, an Ecto.Changeset from set_cf_binding)
  # collapses to one generic constant via the BARE `_` catch-all (fail-closed —
  # an unexpected term never reaches the wire raw). The full detail is logged
  # server-side at the router else arm, so operators keep the diagnostic. The
  # `error:` CODE (`cloudflare_bind_failed`) is unchanged, so the Go CLI key still
  # resolves with zero UI regression. Mirrors `billing_reason/1` above.
  defp cloudflare_reason({:cloudflare_http_error, status, _body}) when is_integer(status) do
    "Cloudflare rejected the DNS/proxy write (HTTP #{status})"
  end

  defp cloudflare_reason(_reason) do
    "Cloudflare rejected the DNS/proxy write — the box is still serving standalone"
  end

  # The deploy/upload TRANSPORT boundary (transport-leak wave, D93). Three client
  # echoes serialize `Sites.Deploy.start_reported/1`'s `{:error, term()}` (spec'd
  # `term()`, unbounded) or `Plug.Conn.read_body`'s `{:error, reason, conn}` — the
  # box-build 503, the artifact-upload 500, the prebuilt-upload 503. Prod is
  # BOUNDED (`TaskStarter` spawns `run/1` fire-and-forget and DISCARDS its rich
  # terms; only a supervisor refusal like `{:error, :max_children}` or a
  # `read_body` `:timeout`/`:closed` atom travels), so this is hygiene, not a live
  # token/PII escape — but a starter swap (`SyncStarter` forwards `run/1`'s rich
  # terms) WOULD leak, so it is redacted fail-closed now for defense-in-depth. The
  # busy-box refusal keeps a retry-actionable message (both the prod double-wrapped
  # `{:error, {:error, :max_children}}` and the flat `{:error, :max_children}`
  # shape); EVERY other shape collapses to one generic constant via the BARE `_`
  # catch-all (fail-closed — an unexpected term never reaches the wire raw). The
  # full detail is `Logger.error`'d at EACH router emit site, so operators keep the
  # diagnostic (the log MUST live in router.ex, never the driver module — Golden
  # Rule 4 / #11723 cp-deploy brick guard). The `error:` CODE
  # (`deploy_not_started` / `upload_failed`) is unchanged, so the Go `cloudError`
  # and JS `friendly()` keys still resolve with zero UI regression. Mirrors
  # `cloudflare_reason/1` + `billing_reason/1` above.
  defp transport_reason(reason)
       when reason in [{:error, {:error, :max_children}}, {:error, :max_children}] do
    "the deploy could not be started — the box is busy; retry shortly"
  end

  defp transport_reason(_reason) do
    "the request could not be completed"
  end

  ## Instance-API proxy (C4 — charter decisions D46 / D51) — the console's
  ## gateway into a live instance's OWN HTTP API. EXPLICIT routes only, no
  ## free-form passthrough: each match names ONE `Registry.InstanceApiCatalog`
  ## capability and dispatches through it (`proxy_instance_webhook/2`). The
  ## stored per-instance admin token is decrypted SERVER-SIDE and travels only
  ## control-plane → instance — never to the browser, a log line, or an error
  ## tuple (the studio-link / self-update relay custody). `?dataset=` selects the
  ## dataset, defaulting "production". Auth is user-authed + team-scoped
  ## fail-closed: a wrong-team / nonexistent / malformed id is the SAME 404 (no
  ## existence leak). Every response is the uniform envelope documented on the
  ## catalog module; every `:mutate` writes exactly one audit event. Catalog v1
  ## is webhooks only.

  get "/v1/barkparks/:id/api/webhooks" do
    proxy_instance_webhook(conn, :"webhook.list")
  end

  post "/v1/barkparks/:id/api/webhooks" do
    proxy_instance_webhook(conn, :"webhook.create")
  end

  get "/v1/barkparks/:id/api/webhooks/:webhook_id" do
    proxy_instance_webhook(conn, :"webhook.show")
  end

  put "/v1/barkparks/:id/api/webhooks/:webhook_id" do
    proxy_instance_webhook(conn, :"webhook.update")
  end

  delete "/v1/barkparks/:id/api/webhooks/:webhook_id" do
    proxy_instance_webhook(conn, :"webhook.delete")
  end

  post "/v1/barkparks/:id/api/webhooks/:webhook_id/rotate" do
    proxy_instance_webhook(conn, :"webhook.rotate")
  end

  get "/v1/barkparks/:id/api/webhooks/:webhook_id/deliveries" do
    proxy_instance_webhook(conn, :"webhook.deliveries")
  end

  post "/v1/barkparks/:id/api/webhooks/:webhook_id/deliveries/:event_id/replay" do
    proxy_instance_webhook(conn, :"webhook.replay")
  end

  # webhook TEST-SEND (GR45 — always spelled "webhook test-send"; the
  # notifications email test-send is an unrelated surface). One-shot synthetic
  # event to the customer's endpoint, single attempt: a `:mutate` because the
  # instance really does make the outbound request and record a delivery row.
  post "/v1/barkparks/:id/api/webhooks/:webhook_id/test-send" do
    proxy_instance_webhook(conn, :"webhook.test_send")
  end

  # POST /v1/providers → 201 {provider: ...}. Provider-neutral connect:
  #
  #   * hetzner: {kind:"hetzner", token, label?}
  #   * azure:   {kind:"azure", credentials:{tenant_id, client_id, client_secret,
  #              subscription_id}, label?}
  #
  # VERIFY-BEFORE-SAVE: a cheap authenticated call to the provider runs FIRST
  # (hetzner — a one-row server list; azure — a token-exchange + tagged resource
  # list via the `Azure.client/0` seam). Only if it succeeds is the credential
  # encrypted at rest and the row inserted. On failure NOTHING is saved and the
  # per-kind remediation copy (naming the exact console/portal fix) is returned,
  # so the user never connects a dead credential and never sees raw provider
  # jargon. The plaintext credential is encrypted by connect_provider — it is
  # NEVER echoed back.
  post "/v1/providers" do
    # RBAC (rbac-roles): stores a cloud credential at rest → team admin only.
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        connect_provider_request(conn)
    end
  end

  # DELETE /v1/providers/:kind → 200 {ok: true} — disconnect the team's connected
  # provider of `kind` (drops the row + its encrypted credential). The plugin law:
  # disconnecting a provider degrades gracefully back to standalone. 404 not_found
  # when the team has no connection of that kind (no existence leak). RBAC: team
  # admin only (parity with the connect side). Mirrors DELETE
  # /v1/github/installation.
  delete "/v1/providers/:kind" do
    conn = Auth.require_team_admin(conn, [])
    kind = conn.params["kind"]

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        # The label (if any) for the audit metadata — read before the delete. No
        # row of this kind → 404 (no existence leak). This is the ONLY place the
        # label is available; the delete drops the row.
        disconnect_provider_request(conn, team, kind)
    end
  end

  # GET /v1/providers/:kind/catalog → 200 {regions, server_types} — the
  # PROVIDER-NEUTRAL provisioning menu (what this team can provision into its
  # connected account), normalized to one shape across providers so the
  # dashboard and CLI render one menu:
  #
  #     {regions: [{slug, name}, …],
  #      server_types: [{slug, cores, ram_gb, disk_gb, monthly_price}, …]}
  #
  # Requires a connected provider of that kind (404 no_provider otherwise — the
  # connect-first empty state). Any team member may read the menu.
  get "/v1/providers/:kind/catalog" do
    conn = Auth.require_user(conn, [])
    if conn.halted, do: conn, else: providers_catalog(conn, conn.params["kind"])
  end

  # GET /v1/providers/:kind/overview → 200 {provider:{kind,label,identity},
  # regions, server_types} — the same normalized menu wrapped with the connected
  # provider's header (a lightweight "what this connection offers" overview).
  # `identity` names WHICH cloud account the connection points at, or says
  # explicitly that it can't (see provider_identity/2). Auth.require_user only:
  # any authenticated team member, including a plain member, reads it.
  get "/v1/providers/:kind/overview" do
    conn = Auth.require_user(conn, [])
    if conn.halted, do: conn, else: providers_overview(conn, conn.params["kind"])
  end

  # GET /v1/providers/capabilities → 200
  #   {providers: {<kind>: {tier, capabilities, gaps}}}
  #
  # The CP-SERVED capability/tier conduit (charter Decision 16, folded into S11):
  # the SPA and the `bp` CLI read ONE server-owned contract instead of each
  # parsing the committed `providers_capabilities.json` and each inventing its
  # own gap copy — the drift that "honest degradation" needs designed out. For
  # every provider kind we emit:
  #
  #   * tier         — "dev" for fixture/dev-only providers (the SPA filters
  #                    them), "prod" by default; read from the fixture, never
  #                    hardcoded here.
  #   * capabilities — the fixture's capability bools passed through
  #                    GENERICALLY (every boolean key, no hardcoded list) so
  #                    S9's lifecycle facet split flows through with ZERO
  #                    conduit change.
  #   * gaps         — a server-owned reason for EVERY false capability
  #                    (FailureCopy.capability_gap_reason/2), so no disabled
  #                    action is ever reason-less.
  #
  # Any signed-in user may read it — it's a static cross-surface contract, not
  # team-scoped estate data. Dev-tier rows are included; hiding them is the
  # reading surface's call (the SPA filters, `bp cloud providers` uses --all).
  get "/v1/providers/capabilities" do
    conn = Auth.require_user(conn, [])
    if conn.halted, do: conn, else: json(conn, 200, providers_capabilities_payload())
  end

  ## Hetzner control-plane proxy (epic charter decision 3) — the dashboard's
  ## server-side path into the customer's Hetzner account. The vault-stored
  ## provider token is decrypted HERE and only ever travels control-plane →
  ## api.hetzner.cloud; it never reaches the browser, a log line, or an error
  ## tuple. `Registry.HetznerCatalog` is the allowlist: every upstream path is
  ## derived from a catalog template by exact `(resource, verb)` lookup — no
  ## prefix matching, no passthrough. THIS wave serves tier :read only;
  ## :mutate/:destroy entries are declared in the catalog but not routed
  ## (wave 3 wires them with audit events + the typed-name confirm echo).

  # GET /v1/hetzner/catalog → 200 {catalog: [{resource, verb, tier, params}]}.
  # The dashboard reads this to know which actions exist and how dangerous each
  # is (tier drives the confirm grammar, charter decision 5). Serialization is
  # resource/verb/tier/params ONLY — upstream method/path templates stay
  # server-side. Readable by any team member.
  get "/v1/hetzner/catalog" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, %{catalog: Enum.map(HetznerCatalog.catalog(), &hetzner_catalog_json/1)})
    end
  end

  # GET /v1/hetzner/overview → 200 <charter envelope> — the team's Hetzner
  # estate in one call, the SAME envelope `bp cloud hetzner overview -o json`
  # prints (charter decision 4):
  #
  #     {ok, fetched_at, provider: {kind, label},
  #      resources: {servers, volumes, networks, firewalls, load_balancers,
  #                  floating_ips, primary_ips, dns_zones, backups},
  #      counts: {<one int per resources key>}}
  #
  # Each row carries at least id/name/status ("n/a" where the kind has none).
  # Partial upstream failure degrades PER KIND — that kind is null, counts 0,
  # and an `errors` map names the failure — the envelope itself never 500s over
  # one slow upstream. 404 no_provider when the team has no connected hetzner
  # account (the dashboard renders its connect-first empty state from this).
  get "/v1/hetzner/overview" do
    # team_admin: the overview reveals the team's whole Hetzner estate (server
    # IPs, DNS zones, firewalls) — privileged infra, gated like every other
    # cloud/ privileged op (require_team_admin runs require_user first, so
    # current_team is still assigned). A plain member is 403'd.
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "no_provider"})

      true ->
        case hetzner_provider(conn.assigns.current_team) do
          nil ->
            json(conn, 404, %{error: "no_provider"})

          provider ->
            case Registry.reveal_provider_token(provider) do
              {:ok, token} ->
                json(conn, 200, hetzner_overview_envelope(provider, token))

              :error ->
                # Tampered ciphertext fails closed — same mapping as the
                # studio-link route. Nothing upstream was called.
                json(conn, 500, %{error: "decrypt_failed"})
            end
        end
    end
  end

  ## GitHub App (gh-2) — connect / state / disconnect. HUMAN-LAST: the App
  ## credentials (id + RSA private key) are a later human gate. The endpoints
  ## EXIST and the app BOOTS regardless; a connect attempt with the credentials
  ## absent is a 503 feature_not_configured (the feature is flagged off, not
  ## half-broken — the plugins-off philosophy). Every external GitHub call runs
  ## through the config-selected `GitHub.client/0` seam (the in-memory Fake in
  ## dev/test), so nothing here ever touches api.github.com in the suite.

  # GET /v1/github/installation → 200 {connected, account_login, configured,
  # install_url}. The dashboard's GitHub card reads this: connected → show the
  # account login; not-connected-but-configured → a "Connect GitHub" link to
  # install_url; not-configured → a graceful off state. NO secret is emitted (the
  # encrypted installation handle NEVER leaves the server). Readable by any team
  # member; a teamless user gets connected:false.
  get "/v1/github/installation" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, github_installation_json(%{connected: false, account_login: nil}))

      true ->
        state = GitHub.connection_state(conn.assigns.current_team)
        json(conn, 200, github_installation_json(state))
    end
  end

  # GET /v1/github/repos → 200 {repos: [{full_name, private}]} — the "Import Git
  # Repository" picker's data source (gh-4). Lists the repos the team's GitHub
  # App installation can reach, through the client seam. Team-scoped, readable by
  # any member (it drives the site-detail picker). 503 feature_not_configured when
  # the App credentials are absent (HUMAN-LAST); 409 no_installation when the team
  # hasn't connected GitHub yet (the UI shows "Connect GitHub" first).
  get "/v1/github/repos" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 409, %{error: "no_installation"})

      not GitHub.configured?() ->
        json(conn, 503, %{error: "feature_not_configured"})

      true ->
        case GitHub.list_repos_for(conn.assigns.current_team) do
          {:ok, repos} ->
            json(conn, 200, %{repos: Enum.map(repos, &github_repo_json/1)})

          {:error, :no_installation} ->
            json(conn, 409, %{error: "no_installation"})

          {:error, _reason} ->
            json(conn, 502, %{error: "github_error"})
        end
    end
  end

  # POST /v1/github/installations {installation_id} → 201 {installation:
  # {connected, account_login, …}} — records the team's GitHub App installation
  # after the App-install redirect (GitHub sends the browser back with the
  # installation_id). The id is VALIDATED through the client seam before it lands
  # (a forged / uninstalled id → 422 installation_not_found, nothing written).
  # 503 feature_not_configured when the App credentials are absent (HUMAN-LAST).
  # RBAC: stores a capability handle → team admin only (parity with providers).
  # One installation per team (v1) — a re-connect replaces the existing row.
  post "/v1/github/installations" do
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      not GitHub.configured?() ->
        json(conn, 503, %{error: "feature_not_configured"})

      not valid_installation_id?(conn.body_params["installation_id"]) ->
        json(conn, 422, %{error: "installation_id_required"})

      true ->
        team = conn.assigns.current_team

        # activity-audit-log: the installation row + a `github.installation_connected`
        # audit event commit atomically. Detail carries only the account_login (the
        # decrypted installation handle NEVER touches the audit row).
        audited =
          Accounts.audit(
            %{
              team_id: team.id,
              actor_user_id: conn.assigns.current_user.id,
              action: "github.installation_connected",
              target_type: "github_installation"
            },
            fn -> GitHub.record_installation(team, conn.body_params["installation_id"]) end,
            fn inst -> %{target_id: inst.id, metadata: %{account_login: inst.account_login}} end
          )

        case audited do
          {:ok, inst} ->
            push_event(team.id, "github")
            push_event(team.id, "audit")

            json(conn, 201, %{
              installation:
                github_installation_json(%{connected: true, account_login: inst.account_login})
            })

          {:error, :installation_not_found} ->
            json(conn, 422, %{error: "installation_not_found"})

          {:error, %Ecto.Changeset{} = cs} ->
            json(conn, 422, %{error: "invalid", details: errors(cs)})
        end
    end
  end

  # DELETE /v1/github/installation → 200 {ok: true} — disconnect the team's GitHub
  # installation (drops the row; the App stays installed on GitHub's side until
  # the user removes it there). 404 not_found when the team has no connection (no
  # existence leak). RBAC: team admin only (parity with the connect side).
  delete "/v1/github/installation" do
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        # activity-audit-log: the installation-row delete + a
        # `github.installation_disconnected` audit event commit atomically. The
        # bare `:ok` from disconnect/1 is lifted to `{:ok, :disconnected}` so it
        # rides the audit/3 contract; a `{:error, :not_found}` rolls back with NO
        # audit row (nothing was disconnected).
        audited =
          Accounts.audit(
            %{
              team_id: team.id,
              actor_user_id: conn.assigns.current_user.id,
              action: "github.installation_disconnected",
              target_type: "github_installation"
            },
            fn ->
              case GitHub.disconnect(team) do
                :ok -> {:ok, :disconnected}
                {:error, _} = err -> err
              end
            end
          )

        case audited do
          {:ok, :disconnected} ->
            push_event(team.id, "github")
            push_event(team.id, "audit")
            json(conn, 200, %{ok: true})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/github/repos {template, name, private} → 201 {repo_full_name,
  # html_url, pushed, steps} — create a repo in the team's connected GitHub
  # account and push the template's Next.js app into it (gh-3). This repo is what
  # "Deploy to Vercel" then clones. Uses the contents API (create-repo +
  # push-files), NOT GitHub's template-repo feature, so ANY template works.
  #
  # Gates (checked in order, honest surfacing):
  #   401 unauth · 422 no_team · 503 feature_not_configured (App creds absent) ·
  #   409 no_installation (team not connected) · 422 invalid_name ·
  #   422 unknown_template (no deployable app tree for the slug) ·
  #   409 repo_exists (name already taken on the account) · 502 github_error.
  # RBAC: creates a repo + pushes on the team's behalf → team admin only (parity
  # with the connect side).
  post "/v1/github/repos" do
    conn = Auth.require_team_admin(conn, [])
    name = conn.body_params["name"]
    template = conn.body_params["template"]
    private? = conn.body_params["private"] == true

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      not GitHub.configured?() ->
        json(conn, 503, %{error: "feature_not_configured"})

      not GitHub.connected?(conn.assigns.current_team) ->
        json(conn, 409, %{error: "no_installation"})

      not valid_repo_name?(name) ->
        json(conn, 422, %{error: "invalid_name"})

      not is_binary(template) or template == "" ->
        json(conn, 422, %{error: "unknown_template"})

      true ->
        team = conn.assigns.current_team

        case GitHub.create_repo_from_template(team, template, name, private?) do
          {:ok, %{repo_full_name: full, html_url: url, pushed: pushed}} ->
            # activity-audit-log: this route RELAYS to GitHub (create-repo +
            # push-files) rather than opening one local transaction, so the audit
            # is a post-commit best-effort record_audit/1 (the repo already exists
            # on GitHub — an audit-insert failure must never 500 the success). The
            # detail carries the repo name + template + file count, no secrets.
            case Accounts.record_audit(%{
                   team_id: team.id,
                   actor_user_id: conn.assigns.current_user.id,
                   action: "github.repo_pushed",
                   target_type: "github_repo",
                   target_id: full,
                   metadata: %{repo_full_name: full, template: template, pushed: pushed}
                 }) do
              {:ok, _event} -> push_event(team.id, "audit")
              {:error, cs} -> Logger.error("audit github.repo_pushed failed: #{inspect(cs)}")
            end

            push_event(team.id, "github")

            json(conn, 201, %{
              repo_full_name: full,
              html_url: url,
              pushed: pushed,
              steps: ["Created #{full}", "Pushed #{pushed} files"]
            })

          {:error, :unknown_template} ->
            json(conn, 422, %{error: "unknown_template"})

          {:error, :no_installation} ->
            json(conn, 409, %{error: "no_installation"})

          {:error, :repo_exists} ->
            json(conn, 409, %{error: "repo_exists"})

          {:error, {:github_error, _reason}} ->
            json(conn, 502, %{error: "github_error"})
        end
    end
  end

  # GET /v1/notifications/settings → 200 {settings: <masked>} for the user's team.
  # Secrets are MASKED ("********" when set, nil when unset) — the ciphertext is
  # never serialized. Auto-creates the row on first read (lazy backstop).
  get "/v1/notifications/settings" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        settings = Notifications.get_or_create_settings(conn.assigns.current_team)
        json(conn, 200, %{settings: Notifications.settings_view(settings)})
    end
  end

  # PUT /v1/notifications/settings {transport?, alerts_enabled?, smtp_*?,
  # from_*?, <event toggles>?} → 200 {settings: <masked>} | 422 {error, details}.
  # cch-w52-s1: `api_key?` was documented here and is GONE — the "api" transport
  # it belonged to had no adapter behind it, so the parameter is no longer read.
  # An SDK author reading a stale line here would send a field the plane drops.
  # Plaintext secrets are encrypted at rest by update_settings (Registry.Vault);
  # they are NEVER echoed back. A PUT that omits a secret keeps the stored one.
  #
  # ADMIN-gated (matches the sibling credential route POST /v1/providers and
  # `@action_min connect_provider: [admin]`): these settings store SMTP creds at
  # rest and toggle alert delivery — a plain member must not repoint team alert
  # mail to an attacker relay or silence past_due alerts. 403 for a non-admin.
  put "/v1/notifications/settings" do
    conn = Auth.require_team_admin(conn, [])

    if conn.halted do
      conn
    else
      team = conn.assigns.current_team

      # activity-audit-log: the settings update + a `notifications.settings_changed`
      # audit event commit atomically. Detail records only the FIELD NAMES that were
      # submitted (e.g. "smtp_password", "smtp_username") — never the plaintext secret
      # values (those are Vault-encrypted at rest and never echoed).
      audited =
        Accounts.audit(
          %{
            team_id: team.id,
            actor_user_id: conn.assigns.current_user.id,
            action: "notifications.settings_changed",
            target_type: "notification_settings",
            metadata: %{fields: Map.keys(conn.body_params)}
          },
          fn -> Notifications.update_settings(team, conn.body_params) end,
          fn settings -> %{target_id: settings.id} end
        )

      case audited do
        {:ok, settings} ->
          push_event(team.id, "audit")
          json(conn, 200, %{settings: Notifications.settings_view(settings)})

        {:error, changeset} ->
          json(conn, 422, %{error: "invalid", details: errors(changeset)})
      end
    end
  end

  # notifications-chat: PUT /v1/notifications/channels {type, enabled, credentials?}
  # → 200 {settings: <masked>} | 422. Upsert one chat channel. `credentials` is a
  # plaintext map the context seals via Vault before it hits the DB; omit it to
  # toggle enable/disable without re-supplying the secret. A `webhook` URL that
  # resolves to a private/metadata address is REJECTED at save time (SSRF guard).
  # ADMIN-gated like the sibling settings route — a member must not repoint a
  # team's alert egress to an attacker-controlled endpoint.
  put "/v1/notifications/channels" do
    conn = Auth.require_team_admin(conn, [])

    if conn.halted do
      conn
    else
      params = conn.body_params
      type = params["type"]
      enabled = params["enabled"] == true
      creds = if is_map(params["credentials"]), do: params["credentials"], else: nil
      team = conn.assigns.current_team

      # activity-audit-log: the channel upsert + a `notifications.channels_changed`
      # audit event commit atomically. Detail records the channel TYPE + enabled
      # flag only — NEVER the channel `credentials` (chat/webhook secrets sealed
      # via Vault before they hit the DB).
      audited =
        Accounts.audit(
          %{
            team_id: team.id,
            actor_user_id: conn.assigns.current_user.id,
            action: "notifications.channels_changed",
            target_type: "notification_settings",
            metadata: %{type: type, enabled: enabled}
          },
          fn -> Notifications.put_channel(team, type, enabled, creds) end,
          fn settings -> %{target_id: settings.id} end
        )

      case audited do
        {:ok, settings} ->
          push_event(team.id, "notifications")
          push_event(team.id, "audit")
          json(conn, 200, %{settings: Notifications.settings_view(settings)})

        {:error, changeset} ->
          json(conn, 422, %{error: "invalid", details: errors(changeset)})
      end
    end
  end

  # notifications-chat: PUT /v1/notifications/events {event, channels:[...]} → 200
  # {settings: <masked>} | 422. Set which chat channel types receive `event` (the
  # event×channel matrix toggle). ADMIN-gated for parity with the settings route.
  put "/v1/notifications/events" do
    conn = Auth.require_team_admin(conn, [])

    if conn.halted do
      conn
    else
      params = conn.body_params
      event = params["event"]
      channels = if is_list(params["channels"]), do: params["channels"], else: []
      team = conn.assigns.current_team

      # activity-audit-log: the event×channel route change + a
      # `notifications.events_changed` audit event commit atomically. Detail carries
      # the event name + the target channel TYPES (routing labels, never secrets).
      audited =
        Accounts.audit(
          %{
            team_id: team.id,
            actor_user_id: conn.assigns.current_user.id,
            action: "notifications.events_changed",
            target_type: "notification_settings",
            metadata: %{event: event, channels: channels}
          },
          fn -> Notifications.set_event_route(team, event, channels) end,
          fn settings -> %{target_id: settings.id} end
        )

      case audited do
        {:ok, settings} ->
          push_event(team.id, "notifications")
          push_event(team.id, "audit")
          json(conn, 200, %{settings: Notifications.settings_view(settings)})

        {:error, changeset} ->
          json(conn, 422, %{error: "invalid", details: errors(changeset)})
      end
    end
  end

  # POST /v1/notifications/test {to?} → 200 {ok: true} | 429 {error: "rate_limited",
  # retry_after} | 422 {error: "no_team"|"no_recipient"}. Sends a test email over
  # the platform transport. Rate-limited to one per 10s per team (Coolify parity),
  # enforced in the context via last_test_sent_at. `to` defaults to the first
  # team member's email and MUST be a team member (the platform mailer is not an
  # open relay) — a non-member recipient is 403. ADMIN-gated for parity with the
  # settings route.
  #
  # notifications-chat: when the body carries `{"channel": "<type>"|null}` (or
  # `{"target": "chat"}`), this instead fires the always-send `test` CHAT event to
  # the enabled chat channels (all, or just `channel`), enqueuing one Oban job each
  # → 202 {ok: true, queued: <n>}. `channel: null` with `target: "chat"` fans to
  # every enabled channel.
  #
  # cch-w32-s1: `queued` is the COUNT OF CHANNELS ACTUALLY REACHED, and it can be
  # 0 — no channels, only a disabled channel, or a `channel` matching nothing.
  # This route used to render an unconditional `{ok: true}` over a bare `:ok`, so
  # a fan-out to nobody read as accepted to the console, to `bp` and to curl
  # alike. `ok: true` still means "the request was accepted"; `queued` is the
  # separate question of whether anything was sent, and the console reads it.
  post "/v1/notifications/test" do
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      chat_test?(conn.body_params) ->
        {:ok, queued} =
          Notifications.send_test_chat(conn.assigns.current_team, conn.body_params["channel"])

        json(conn, 202, %{ok: true, queued: queued})

      true ->
        test_email(conn)
    end
  end

  # GET /v1/notifications/deliveries → 200 {deliveries: [<delivery_json>]}, newest
  # first, strictly team-scoped via conn.assigns.current_team. Pure read-only
  # exposure of the durable notification_deliveries table — the delivery-log surface
  # the Settings wave renders. `?limit` caps the page via parse_int, hard-capped
  # at 200 HERE (the /v1/audit precedent — list_audit_events caps in the context,
  # but list_deliveries leaves the clamp to its caller, so the router owns it).
  #
  # TWO AUDIENCES, TWO ROW SETS — and the narrower one is the point.
  # This route used to open `Auth.require_team_admin`, which made it the only
  # surface that can answer "was I notified?" while 403ing the people it
  # notifies: alert email fans out to EVERY member (`dispatch_event/3` loops
  # `team_member_emails/1`, no role filter), so a plain member was a recipient of
  # every alert and could never ask whether one reached them — a WITHHELD alert
  # read byte-identically to "alerts are off". `accounts/authz.ex` already says
  # verbatim "Reads stay at `member`"; this pure read gated at admin was a
  # documented divergence from the codebase's own policy table.
  #
  # So: an owner/admin still reads the WHOLE team log, unchanged. Anyone else
  # holding a grant on the team reads it SELF-SCOPED — `recipient:` fences the
  # query to their own address (case-insensitively; see
  # `Notifications.maybe_delivery_recipient/2`). The honest cost of that fence is
  # structural and must be said out loud on the surface: chat deliveries store
  # the CHANNEL TYPE as the recipient (`log_chat_delivery/6` writes
  # `recipient: type`), so a self-scoped log answers "was I emailed?" and can
  # NEVER answer "did the team's Slack get it?".
  #
  # `require_user/2` implies a team grant (`resolve_team/2` honours the
  # `x-barkpark-team` header only after `get_membership/2` succeeds, else falls
  # back to `primary_team/1`) — but it does NOT close the nil-team hole that
  # `gate_role/2` closes explicitly. A user with no membership anywhere resolves
  # to `current_team = nil`, so 403 BEFORE querying rather than running the fence
  # against a nil team_id.
  #
  # THE SELF-SCOPED READ IS NOT FREE, AND THE NUMBER IS MEASURED, NOT ARGUED.
  # EXPLAIN (ANALYZE, BUFFERS) against a seeded table (one team, 200k rows, 50
  # recipients) shows the planner DECLINING `notification_deliveries_team_id_
  # inserted_at_index` for the fenced query — `lower(recipient)` is not indexed,
  # so it bitmap-scans `notification_deliveries_team_id_index`, filters 196k rows
  # away and top-N heapsorts what is left: 30.8 ms / 3798 shared buffers. The
  # ADMIN read on the same team still walks the compound index backwards and
  # stops at the LIMIT: 0.037 ms / 6 buffers. The team fence keeps it bounded and
  # 30 ms is a fine page today, but it scales with the TEAM'S WHOLE LOG rather
  # than the page size, and this table has no retention policy. The fix is an
  # index on `(team_id, lower(recipient), inserted_at)` — deliberately NOT taken
  # in this slice (it is a migration, outside this slice's file fence). It is
  # OPEN WORK, not a solved problem: re-run the same EXPLAIN (ANALYZE, BUFFERS)
  # after adding it and quote both plans, because a green suite proves nothing
  # about a query plan.
  #
  # `?channel=` / `?status=` / `?event=` narrow the log, and `?before=<oldest
  # inserted_at>&before_id=<that row's id>` walks the next page (the /v1/audit
  # keyset — both halves of the `(inserted_at, id)` sort key, so a boundary that
  # lands mid-timestamp-tie cannot drop the far side; `before` alone keeps its
  # historical stamp-only meaning for bookmarked URLs). Filters run INSIDE
  # the query, so "show me the failures" is a real page of failures rather than
  # the failures that happen to be in the newest 50. A filter value outside the
  # closed vocabulary matches nothing rather than being dropped — a dropped
  # filter would silently show MORE than was asked for.
  get "/v1/notifications/deliveries" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 403, %{error: "forbidden"})

      true ->
        user = conn.assigns.current_user
        team = conn.assigns.current_team
        admin? = Accounts.team_admin?(user, team)

        # THE FENCE MUST FAIL CLOSED, and `list_deliveries/2` cannot make it do
        # so on its own: `:recipient` is an OPTIONAL filter, so a nil or blank
        # value there means "no fence" — which is exactly right for the admin
        # read and exactly WRONG for a member. A non-admin whose account carries
        # no usable address would therefore fall through to the UNFENCED query
        # and be handed the whole team's log. The router owns the self-scope
        # decision, so the router owns its failure mode: no address, no read.
        cond do
          # LEFT BARE ON PURPOSE — charter D396(5). Admin is sufficient but NOT
          # necessary here (a member WITH a usable address reads their own rows),
          # so `required: "admin"` would misdescribe the gate. It is additionally
          # unreachable in practice: `self_scopable_address?/1` is true for any
          # non-blank email and `users.email` is `null: false`.
          not admin? and not self_scopable_address?(user) ->
            json(conn, 403, %{error: "forbidden"})

          true ->
            opts = [
              limit: min(parse_int(conn.query_params["limit"], 50), 200),
              channel: conn.query_params["channel"],
              status: conn.query_params["status"],
              event: conn.query_params["event"],
              before: parse_dt(conn.query_params["before"]),
              before_id: conn.query_params["before_id"],
              recipient: if(admin?, do: nil, else: user.email)
            ]

            deliveries = Notifications.list_deliveries(team, opts)
            json(conn, 200, %{deliveries: Enum.map(deliveries, &delivery_json/1)})
        end
    end
  end

  # The address a self-scoped read is fenced on must be exactly what
  # `Notifications.maybe_delivery_recipient/2` will accept as a filter — a
  # non-empty binary. Anything else (a nil-email account, a blank string) cannot
  # be fenced, and an unfenceable member read is a 403, never a wider one.
  defp self_scopable_address?(%{email: email}) when is_binary(email),
    do: String.trim(email) != ""

  defp self_scopable_address?(_user), do: false

  # True when the caller wants a CHAT test rather than the default email test.
  defp chat_test?(params) do
    Map.has_key?(params, "channel") or params["target"] == "chat"
  end

  defp test_email(conn) do
    if conn.halted do
      conn
    else
      to = conn.body_params["to"]

      case Notifications.deliver_test(conn.assigns.current_team, to) do
        {:ok, _} ->
          json(conn, 200, %{ok: true})

        {:error, {:rate_limited, retry_after}} ->
          json(conn, 429, %{error: "rate_limited", retry_after: retry_after})

        {:error, :no_recipient} ->
          json(conn, 422, %{error: "no_recipient"})

        {:error, :recipient_not_member} ->
          json(conn, 403, %{error: "recipient_not_member"})

        {:error, _reason} ->
          json(conn, 502, %{error: "send_failed"})
      end
    end
  end

  ## Teams — members & invitations (cloud adaptation of Coolify's Team Livewire).
  ##
  ## Every per-team route resolves + role-gates the team from the path `:id` via
  ## `with_team_role/3` (NOT the user's primary team), so the feature is correct
  ## even before a team-switcher exists. A non-member of the path team gets the
  ## same 404 as a nonexistent team — no existence leak.

  # GET /v1/teams/:id/members → 200 {members: [{user_id, email, role, joined_at}]}.
  get "/v1/teams/:id/members" do
    with_team_role(conn, "member", fn conn, team ->
      json(conn, 200, %{members: Enum.map(Accounts.list_team_members(team), &member_json/1)})
    end)
  end

  # POST /v1/teams/:id/invitations {email, role?} → 201 {invitation, accept_url}.
  # The raw accept token appears ONCE here, in accept_url, and is never persisted
  # in plaintext. Email is the PRIMARY invite path — the invitee is mailed the
  # accept link over the PLATFORM transport — and the same accept_url is ALSO
  # returned as the operator copy-paste fallback (console-wish Members
  # ratification). The email send is fail-soft: a relay hiccup is logged but
  # never 500s the invite (the record is committed + accept_url is still
  # returned).
  post "/v1/teams/:id/invitations" do
    with_team_role(conn, "admin", fn conn, team ->
      email = conn.body_params["email"]
      role = conn.body_params["role"] || "member"

      cond do
        not (is_binary(email) and email != "") ->
          json(conn, 422, %{error: "email_required"})

        true ->
          # activity-audit-log: the invite + a `member.invited` audit row commit
          # in one transaction (target_id resolved from the created invitation).
          audit_invite =
            Accounts.audit(
              %{
                team_id: team.id,
                actor_user_id: conn.assigns.current_user.id,
                action: "member.invited",
                target_type: "invitation",
                metadata: %{email: email, role: role}
              },
              fn -> Accounts.invite_member(team, email, role, conn.assigns.current_user) end,
              fn %{invitation: inv} -> %{target_id: inv.id} end
            )

          case audit_invite do
            {:ok, %{invitation: inv, token: raw}} ->
              push_event(team.id, "members")
              push_event(team.id, "audit")

              url = accept_url(conn, raw)
              send_invite_email(email, url, team)

              json(conn, 201, %{
                invitation: invitation_json(inv),
                accept_url: url
              })

            {:error, :already_member} ->
              json(conn, 409, %{error: "already_member"})

            {:error, :role_too_high} ->
              json(conn, 422, %{error: "role_too_high"})

            {:error, :invalid_role} ->
              json(conn, 422, %{error: "invalid_role"})

            {:error, %Ecto.Changeset{} = cs} ->
              # Partial-unique violation → one live invite per email per team.
              json(conn, 409, %{error: "already_invited", details: errors(cs)})
          end
      end
    end)
  end

  # GET /v1/teams/:id/invitations → 200 {invitations: [...]} — pending only.
  get "/v1/teams/:id/invitations" do
    with_team_role(conn, "admin", fn conn, team ->
      json(conn, 200, %{
        invitations: Enum.map(Accounts.list_invitations(team), &invitation_json/1)
      })
    end)
  end

  # DELETE /v1/teams/:id/invitations/:inv_id → 200 {ok: true} | 404.
  delete "/v1/teams/:id/invitations/:inv_id" do
    with_team_role(conn, "admin", fn conn, team ->
      inv_id = conn.path_params["inv_id"]

      # activity-audit-log: the revoke + an `invitation.revoked` audit row commit
      # in one transaction. target_id is the path invitation id (known up front).
      audit_revoke =
        Accounts.audit(
          %{
            team_id: team.id,
            actor_user_id: conn.assigns.current_user.id,
            action: "invitation.revoked",
            target_type: "invitation",
            target_id: inv_id
          },
          fn -> Accounts.revoke_invitation(team, inv_id) end
        )

      case audit_revoke do
        {:ok, _} -> json(conn, 200, %{ok: true})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      end
    end)
  end

  # PATCH /v1/teams/:id/members/:user_id {role} → 200 {member} — change a role.
  # ANTI-ESCALATION: the acting admin must out-rank the target's current role and
  # may not grant a role above their own (an admin cannot self-promote to owner,
  # mint an owner, or demote an owner/peer admin) → 403 forbidden. 409 last_owner
  # when demoting the sole owner; 422 invalid_role; 404 not a member.
  patch "/v1/teams/:id/members/:user_id" do
    with_team_role(conn, "admin", fn conn, team ->
      role = conn.body_params["role"]

      with %{} = target <- Accounts.get_user(conn.path_params["user_id"]),
           # activity-audit-log: the role change + a `member.role_changed` audit
           # row commit in one transaction (the update itself opens a txn for the
           # last-owner lock; audit nests it as a savepoint).
           {:ok, membership} <-
             Accounts.audit(
               %{
                 team_id: team.id,
                 actor_user_id: conn.assigns.current_user.id,
                 action: "member.role_changed",
                 target_type: "user",
                 target_id: target.id,
                 metadata: %{new_role: to_string(role)}
               },
               fn ->
                 Accounts.update_member_role_as(
                   conn.assigns.current_user,
                   team,
                   target,
                   to_string(role)
                 )
               end
             ) do
        push_event(team.id, "members")
        push_event(team.id, "audit")

        json(conn, 200, %{
          member:
            member_json(%{user: target, role: membership.role, joined_at: membership.inserted_at})
        })
      else
        nil ->
          json(conn, 404, %{error: "not_found"})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :invalid_role} ->
          json(conn, 422, %{error: "invalid_role"})

        # cch-w37-s2: A CAUSE, NEVER AN AUTHORITY. The caller is ALREADY inside
        # with_team_role(conn, "admin", …), so `required: "admin"` would be a new
        # lie — and no static authority label is sound here anyway: the SAME
        # admin refused on a peer admin succeeds on a plain member. The refusal
        # is RANK-RELATIVE, so it names the relation instead. Re-deriving
        # can_grant?/3 (total, no side effects) separates the two arms
        # `update_member_role_as/4` collapses into one `{:error, :forbidden}`:
        # granting ABOVE your own rank vs. targeting someone you do not outrank.
        {:error, :forbidden} ->
          reason =
            if Authz.can_grant?(conn.assigns.current_user, team, to_string(role)) == :ok,
              do: "outranked",
              else: "cannot_grant_higher_role"

          Auth.forbidden(conn, reason: reason)

        {:error, :last_owner} ->
          json(conn, 409, %{error: "last_owner"})
      end
    end)
  end

  # DELETE /v1/teams/:id/members/:user_id → 200 {ok: true}. Evicts the removed
  # user's sessions. ANTI-ESCALATION: an admin may remove only members they
  # out-rank; an owner may remove any peer (while owner_count > 1) → 403 forbidden
  # otherwise. 409 last_owner; 404 not a member.
  delete "/v1/teams/:id/members/:user_id" do
    with_team_role(conn, "admin", fn conn, team ->
      with %{} = target <- Accounts.get_user(conn.path_params["user_id"]),
           # activity-audit-log: the removal (+ its session eviction) and a
           # `member.removed` audit row commit in one transaction.
           {:ok, :removed} <-
             Accounts.audit(
               %{
                 team_id: team.id,
                 actor_user_id: conn.assigns.current_user.id,
                 action: "member.removed",
                 target_type: "user",
                 target_id: target.id,
                 metadata: %{email: target.email}
               },
               fn -> Accounts.remove_member_as(conn.assigns.current_team_role, team, target) end
             ) do
        push_event(team.id, "members")
        push_event(team.id, "audit")
        json(conn, 200, %{ok: true})
      else
        nil -> json(conn, 404, %{error: "not_found"})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        # cch-w37-s2: A CAUSE, NEVER AN AUTHORITY — same reasoning as the PATCH
        # above. `remove_member_as/3` refuses on ONE relation only (the actor
        # does not out-rank the target), so the cause is always `outranked`; the
        # caller is already an admin, and the same admin succeeds on a member.
        {:error, :forbidden} -> Auth.forbidden(conn, reason: "outranked")
        {:error, :last_owner} -> json(conn, 409, %{error: "last_owner"})
      end
    end)
  end

  # GET /v1/invitations/:token → 200 {team, email, role, expires_at} | 404.
  # UNAUTHENTICATED on purpose: the accept page shows "you've been invited to
  # <team>" before the invitee logs in / registers. A garbage / expired / already
  # accepted token is the same 404 (no enumeration signal).
  get "/v1/invitations/:token" do
    case Accounts.get_live_invitation(conn.path_params["token"]) do
      nil ->
        json(conn, 404, %{error: "invalid_or_expired"})

      inv ->
        json(conn, 200, %{
          team: %{name: inv.team.name, slug: inv.team.slug},
          email: inv.email,
          role: inv.role,
          expires_at: inv.expires_at
        })
    end
  end

  # POST /v1/invitations/accept {token} → 200 {team_id}. Authed but NOT
  # team-scoped (the user is not yet a member). The email-match guard ensures the
  # logged-in user's email equals the invited email.
  post "/v1/invitations/accept" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      # activity-audit-log: accepting lands a membership; the audit row's team_id
      # + target_id are resolved FROM that membership (this route is not team-
      # scoped up front — the user is not yet a member), so the whole unit commits
      # atomically under the accepted team.
      audit_accept =
        Accounts.audit(
          %{
            actor_user_id: conn.assigns.current_user.id,
            action: "invitation.accepted",
            target_type: "user"
          },
          fn ->
            Accounts.accept_invitation(conn.body_params["token"] || "", conn.assigns.current_user)
          end,
          fn membership ->
            %{team_id: membership.team_id, target_id: conn.assigns.current_user.id}
          end
        )

      case audit_accept do
        {:ok, membership} ->
          push_event(membership.team_id, "members")
          push_event(membership.team_id, "audit")
          json(conn, 200, %{team_id: membership.team_id})

        {:error, :invalid_token} ->
          json(conn, 404, %{error: "invalid_or_expired"})

        {:error, :email_mismatch} ->
          json(conn, 403, %{error: "email_mismatch"})

        {:error, _} ->
          json(conn, 422, %{error: "accept_failed"})
      end
    end
  end

  ## Personal access tokens (session-authed management)
  ##
  ## Managing PATs is SESSION-ONLY — you mint / list / revoke tokens from the
  ## logged-in dashboard, never WITH a PAT. This is the privilege-escalation
  ## firewall: a leaked `read` token can never mint itself a `root` one (the
  ## mint route 401s a PAT bearer because it requires a session). Adapted from
  ## Coolify's Security/ApiTokens Livewire component.

  # GET /v1/tokens → 200 {tokens: [...]} — the caller's PATs, newest first.
  # NEVER emits the token_hash or any plaintext (a PAT is shown once, at mint).
  get "/v1/tokens" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      tokens = Accounts.list_personal_access_tokens(conn.assigns.current_user)
      json(conn, 200, %{tokens: Enum.map(tokens, &pat_json/1)})
    end
  end

  # POST /v1/tokens {name, abilities[], expires_in_days?} → 201
  # {token: <plaintext ONCE>, pat: {...}}. The plaintext is the ONLY moment the
  # credential leaves the server; pat carries no hash/no plaintext.
  #   422 {error: "no_team"}            — the user has no team to mint under.
  #   422 {error: "invalid", details}   — changeset rejection (bad name/ability).
  post "/v1/tokens" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        user = conn.assigns.current_user

        attrs = %{
          name: conn.body_params["name"],
          abilities: conn.body_params["abilities"] || ["read"],
          expires_in_days: parse_expiry(conn.body_params["expires_in_days"])
        }

        # activity-audit-log: the mint + a `token.minted` audit row commit in one
        # transaction. create_personal_access_token returns a 3-tuple
        # {:ok, plaintext, pat}; normalize it to {:ok, {plaintext, pat}} so it
        # threads through audit/3 (which matches a 2-tuple {:ok, result}), then
        # unwrap on the far side. The plaintext is NEVER written to the audit row.
        audit_mint =
          Accounts.audit(
            %{
              team_id: conn.assigns.current_team.id,
              actor_user_id: user.id,
              action: "token.minted",
              target_type: "token",
              # ssw10: the metadata here is a PLACEHOLDER, overwritten by the
              # `target_fun` below off the PERSISTED row. `attrs.abilities` is the
              # REQUESTED list and `UserToken.normalize_abilities/1` has not run
              # yet, so recording it here would have the issuance log claim a grant
              # the credential does not hold. `Accounts.audit/3` merges
              # `target_fun.(result)` OVER `base_attrs`, so the key is replaced.
              metadata: %{name: attrs.name, abilities: attrs.abilities}
            },
            fn ->
              case Accounts.create_personal_access_token(user, conn.assigns.current_team, attrs) do
                {:ok, plaintext, pat} -> {:ok, {plaintext, pat}}
                other -> other
              end
            end,
            fn {_plaintext, pat} ->
              %{target_id: pat.id, metadata: mint_audit_metadata(attrs, pat)}
            end
          )

        case audit_mint do
          {:ok, {plaintext, pat}} ->
            json(conn, 201, %{token: plaintext, pat: pat_json(pat)})

          # A plain member may mint only a `read` PAT — minting deploy/root/write
          # is owner/admin-only (anti-escalation, see create_personal_access_token).
          # cch-w37-s2: NAME THE AUTHORITY, so the console can say "minting this
          # ability needs admin" instead of the owner-only billing sentence.
          {:error, :forbidden} ->
            Auth.forbidden(conn, required: "admin", scope: "team")

          {:error, cs} ->
            json(conn, 422, %{error: "invalid", details: errors(cs)})
        end
    end
  end

  # DELETE /v1/tokens/:id → 200 {ok: true} — revoke the caller's own PAT
  # (idempotent). A wrong-user / nonexistent id is the same 404 (no existence
  # leak across users).
  delete "/v1/tokens/:id" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      # activity-audit-log: the revoke + a `token.revoked` audit row commit in one
      # transaction. team_id + target_id are resolved from the revoked PAT (which
      # carries the team it was minted under), so the row is correctly team-scoped
      # even though this route resolves no team up front.
      audit_revoke_token =
        Accounts.audit(
          %{
            actor_user_id: conn.assigns.current_user.id,
            action: "token.revoked",
            target_type: "token"
          },
          fn ->
            Accounts.revoke_personal_access_token(
              conn.assigns.current_user,
              conn.path_params["id"]
            )
          end,
          fn token -> %{team_id: token.team_id, target_id: token.id} end
        )

      case audit_revoke_token do
        {:ok, _token} -> json(conn, 200, %{ok: true})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        {:error, cs} -> json(conn, 422, %{error: "invalid", details: errors(cs)})
      end
    end
  end

  ## Team-scoped PAT visibility (admin) — the OTHER half of the surface above.
  ##
  ## Everything above this comment is CALLER-scoped: a PAT is listable and
  ## revocable by exactly one principal, its holder. That made a still-current
  ## member's leaked credential un-killable by anyone else — a team owner could
  ## not even ENUMERATE the programmatic credentials that act on their team, let
  ## alone kill one, and PATs may be minted with no expiry at all. The
  ## membership-scoped eviction (`revoke_team_pats/2`, on removal / demotion)
  ## covers only a MEMBERSHIP CHANGE; these two routes cover the leak with the
  ## membership intact.
  ##
  ## Same session-only firewall (they ride `with_team_role/3`, which calls
  ## `Auth.require_user/2`), same 404-no-leak convention as the caller-scoped
  ## routes: a foreign team is 404 (never 403 — do not confirm it exists) and a
  ## token id from another team is 404, not a 403 that would confirm the id.

  # GET /v1/teams/:id/tokens → 200 {tokens: [...]} — every PAT minted against
  # THIS team, whoever holds it, newest first. admin+ (a plain member gets 403;
  # a non-member / nonexistent team gets 404). Carries the holder (user_id +
  # email) so an admin can act on the row; NEVER a hash and never a plaintext.
  get "/v1/teams/:id/tokens" do
    with_team_role(conn, "admin", fn conn, team ->
      tokens = Accounts.list_team_personal_access_tokens(team)
      json(conn, 200, %{tokens: Enum.map(tokens, &team_pat_json/1)})
    end)
  end

  # DELETE /v1/teams/:id/tokens/:token_id → 200 {ok: true} — an admin kills a
  # team member's PAT (idempotent). A token id belonging to another team is the
  # same 404 as a nonexistent one.
  #
  # The audit action is `token.revoked`, the SAME verb the caller-scoped revoke
  # writes — one act, one verb; the admin case is distinguished by metadata
  # (`admin_revoke: true` plus the holder), not by a second word for the same
  # thing. That keeps the closed vocabulary in cloud/priv/audit-actions.json
  # (and the console label generated from it) unchanged.
  delete "/v1/teams/:id/tokens/:token_id" do
    with_team_role(conn, "admin", fn conn, team ->
      audit_revoke =
        Accounts.audit(
          %{
            team_id: team.id,
            actor_user_id: conn.assigns.current_user.id,
            action: "token.revoked",
            target_type: "token",
            target_id: conn.path_params["token_id"]
          },
          fn ->
            Accounts.revoke_team_personal_access_token(team, conn.path_params["token_id"])
          end,
          fn token ->
            %{
              metadata: %{
                admin_revoke: true,
                name: token.name,
                user_id: token.user_id,
                email: token.user && token.user.email
              }
            }
          end
        )

      case audit_revoke do
        {:ok, _token} ->
          push_event(team.id, "audit")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, cs} ->
          json(conn, 422, %{error: "invalid", details: errors(cs)})
      end
    end)
  end

  # POST /v1/billing/checkout {plan} → 200 {checkout_url} — open a hosted
  # Checkout Session for the AUTHED user's team on `plan` (the customer opens the
  # url in a browser to pay). team_id is the authed team, NEVER client-supplied.
  # checkout). 403 {error: "forbidden", reason: "no_team", scope: "team"}
  # when the user has no team to bill.
  # OWNER-gated: billing is owner-only (`@action_min billing: [owner]`) — spending
  # money / changing the plan is the team owner's call, not any member or admin.
  # require_primary_team_owner halts with 401 (no auth), 403 no_team, or 403
  # (not-owner) before we reach here.
  post "/v1/billing/checkout" do
    # Spends money / changes plan → owner-only. Gated to the user's PRIMARY team
    # owner (401 / 403 no_team / 403), matching `@action_min billing: [owner]`.
    conn = Auth.require_primary_team_owner(conn)

    cond do
      conn.halted ->
        conn

      # UNREACHABLE belt-and-braces: require_primary_team_owner above already
      # halts a teamless caller (403 forbidden/no_team since cch-w38-s2; 422
      # before it), so `conn.halted` catches that case one clause earlier. Kept
      # as a fail-closed guard, NOT as a contract this route can emit.
      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        plan = conn.body_params["plan"]

        case Billing.checkout(conn.assigns.current_team, to_string(plan)) do
          {:ok, checkout_url} ->
            json(conn, 200, %{checkout_url: checkout_url})

          {:error, :plan_invalid} ->
            # BILL-2: distinguish a genuinely bad plan from a deploy where billing
            # was never wired (StripeGateway with no prices / webhook secret) — in
            # the latter EVERY paid plan resolves to no price, so :plan_invalid is
            # misleading. Surface an operator-actionable error `bp subscribe` can
            # report instead of telling the user their plan choice was wrong.
            # cch-w50-bl: the enum, not the boolean. `configured?/0` is
            # `capability == :available`, so once `:test_mode` split off it, a
            # genuinely bad plan name on the (test-keyed) live plane would have
            # started reading "billing_not_configured" — wrong, because there
            # the prices DO resolve and the plan really is the problem. Both
            # keyed states keep the plan-level answer; only the two states where
            # no price resolves take the deploy-level one.
            if Billing.checkout_capability() in [:available, :test_mode] do
              json(conn, 422, %{error: "plan_invalid"})
            else
              json(conn, 422, %{error: "billing_not_configured"})
            end

          {:error, :billing_test_mode} ->
            # cch-w50-bl: the plane is keyed `sk_test_…`. A REAL hosted session
            # would open that no real card can pay, so `Billing.checkout/2`
            # refuses BEFORE one is created and THE SERVER is the gate — the
            # console's disabled button is the courtesy, not the enforcement.
            # The reason is `Billing.test_mode_disclosure/0` verbatim, so a
            # `bp` client or a hand-rolled POST reads the same sentence the
            # money screen prints.
            reason = Billing.test_mode_disclosure()
            json(conn, 422, %{error: "billing_test_mode", reason: reason})

          {:error, :billing_not_configured} ->
            # D553: the plan IS priced, but the deploy could never honour the
            # charge (no webhook secret → the activation event can never
            # verify). Billing.checkout/2 refuses BEFORE a session is created,
            # so no card is touched; the owner gets the same operator-actionable
            # error the never-wired case already had.
            json(conn, 422, %{error: "billing_not_configured"})

          {:error, reason} ->
            json(conn, 422, %{error: "checkout_failed", reason: billing_reason(reason)})
        end
    end
  end

  # POST /v1/billing/portal → 200 {portal_url} — open a Stripe Customer Portal
  # session for the AUTHED user's team so they self-manage their subscription
  # (update card, view invoices, cancel) in a browser. 403 {forbidden, reason:
  # "no_team", scope: "team"} when the user has no team (the owner gate
  # answers it); 422 {no_subscription} when the team has no live sub.
  # Coolify-anchor: getStripeCustomerPortalSession.
  # OWNER-gated: the portal exposes card/PII/cancel — owner-only, like checkout.
  post "/v1/billing/portal" do
    conn = Auth.require_primary_team_owner(conn)

    cond do
      conn.halted ->
        conn

      # UNREACHABLE belt-and-braces: require_primary_team_owner above already
      # halts a teamless caller (403 forbidden/no_team since cch-w38-s2; 422
      # before it), so `conn.halted` catches that case one clause earlier. Kept
      # as a fail-closed guard, NOT as a contract this route can emit.
      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        case Billing.billing_portal_url(conn.assigns.current_team) do
          {:ok, url} ->
            json(conn, 200, %{portal_url: url})

          {:error, :no_subscription} ->
            json(conn, 422, %{error: "no_subscription"})

          {:error, reason} ->
            json(conn, 422, %{error: "portal_failed", reason: billing_reason(reason)})
        end
    end
  end

  # POST /v1/billing/cancel {password, at_period_end?} → 200 {status,
  # cancel_at_period_end}. DESTRUCTIVE → password re-confirmation (Coolify-anchor:
  # the Subscription Livewire cancel re-checks Hash::check before acting).
  # at_period_end defaults true (reversible grace — stays entitled until the
  # period end); false cancels immediately (status canceled + the team's managed
  # boxes suspended). 401 {password_invalid} on a wrong password; 403 {forbidden,
  # reason: "no_team", scope: "team"} / 422 {no_subscription}.
  post "/v1/billing/cancel" do
    # OWNER-gated, and the gate is placed BEFORE the password re-confirm: the
    # `confirm_password` check verifies the CALLER's own password (not authority),
    # so it must never be the sole gate on a destructive cancel. The owner gate
    # halts 401 / 403 no_team / 403 first.
    conn = Auth.require_primary_team_owner(conn)

    cond do
      conn.halted ->
        conn

      not confirm_password(conn) ->
        json(conn, 401, %{error: "password_invalid"})

      true ->
        # Default to grace; only an explicit `false` cancels immediately.
        at_end = conn.body_params["at_period_end"] != false

        # activity-audit-log: the cancel + a `subscription.canceled` audit row
        # commit in one transaction (target_id + metadata resolved from the
        # updated subscription). A grace cancel (at_period_end) and an immediate
        # cancel both record here; the metadata distinguishes them.
        audit_cancel =
          Accounts.audit(
            %{
              team_id: conn.assigns.current_team.id,
              actor_user_id: conn.assigns.current_user.id,
              action: "subscription.canceled",
              target_type: "subscription",
              metadata: %{at_period_end: at_end}
            },
            fn -> Billing.request_cancel(conn.assigns.current_team, at_end) end,
            fn sub -> %{target_id: sub.id} end
          )

        case audit_cancel do
          {:ok, sub} ->
            # The plan state changed and (on immediate cancel) the fleet was
            # suspended — push both so an open dashboard reflects it live.
            push_event(conn.assigns.current_team.id, "subscription")
            push_event(conn.assigns.current_team.id, "fleet")
            push_event(conn.assigns.current_team.id, "audit")
            json(conn, 200, %{status: sub.status, cancel_at_period_end: sub.cancel_at_period_end})

          {:error, :no_subscription} ->
            json(conn, 422, %{error: "no_subscription"})

          {:error, reason} ->
            json(conn, 422, %{error: "cancel_failed", reason: billing_reason(reason)})
        end
    end
  end

  # POST /v1/billing/webhook — UNAUTHENTICATED but SIGNATURE-VERIFIED. Stripe
  # posts subscription events here. We read the RAW body (cached by
  # cache_raw_body/2 — the signature is over the raw bytes) + the Stripe-Signature
  # header and hand both to Billing.handle_webhook/2, which verifies the
  # signature and, on a valid activating event, marks the team's subscription
  # active from the SIGNED metadata. 200 {ok: true} on a handled/ignored valid
  # event; 400 {error: "invalid_signature"} on a bad/missing signature — a forged
  # webhook MUST NOT grant a subscription. Idempotent (a repeat is a no-op).
  post "/v1/billing/webhook" do
    raw_body = conn.assigns[:raw_body] || ""
    signature = stripe_signature(conn)

    case Billing.handle_webhook(raw_body, signature) do
      {:ok, result} ->
        # A newly-activated subscription pushes "subscription" so the customer's
        # post-checkout dashboard (the ?checkout=success return) flips to active
        # live — and "fleet" since launching is now unblocked.
        case result do
          %BarkparkCloud.Billing.Subscription{team_id: tid} = sub ->
            push_event(tid, "subscription")
            push_event(tid, "fleet")

            # notifications-email: a past_due subscription emails the team (on by
            # default — a billing failure is exactly the kind of alert a hosted
            # customer must not miss). Additive; the SSE push above still fires.
            # dunning-email-dedup: this branch only sees a `%Subscription{}` on the
            # TRUE `active → past_due` transition — a webhook REDELIVERY / repeat
            # dunning event resolves to `{:ok, :already_past_due}` (an atom, not a
            # struct) in Billing.mark_past_due/2 and falls to the `_ -> :ok` arm
            # below, so a paying customer is NOT emailed twice.
            if sub.status == "past_due" do
              Notifications.dispatch_event(tid, :subscription_past_due, %{})
            end

            # activity-audit-log: a genuinely-landed ACTIVE subscription records a
            # SYSTEM-actor `subscription.activated` event (a Stripe-fired change
            # has NO human actor, so actor_user_id is nil — the schema allows it).
            # Best-effort + post-commit ON PURPOSE: handle_webhook already
            # persisted the subscription and must stay free of an Accounts
            # dependency, so the audit is recorded here at the router seam; a
            # failed insert is LOGGED, never 500s the webhook (and never rolls the
            # subscription back — a forged event never reaches this branch, it
            # failed signature verification above). Gated on "active" so a
            # past_due / recovery result is not mislabeled an activation.
            if sub.status == "active" do
              case Accounts.record_audit(%{
                     team_id: tid,
                     actor_user_id: nil,
                     action: "subscription.activated",
                     target_type: "subscription",
                     target_id: sub.id,
                     metadata: %{plan: sub.plan, source: "stripe_webhook"}
                   }) do
                {:ok, _event} ->
                  push_event(tid, "audit")

                {:error, cs} ->
                  Logger.error("audit subscription.activated failed: #{inspect(cs)}")
              end
            end

          _ ->
            :ok
        end

        json(conn, 200, %{ok: true})

      {:error, :invalid_signature} ->
        json(conn, 400, %{error: "invalid_signature"})

      {:error, reason} ->
        json(conn, 400, %{error: "invalid_webhook", reason: billing_reason(reason)})
    end
  end

  # POST /v1/launch {provider, name} and POST /v1/go-live {name, plan} — the
  # control-plane half of go-live: auth + an ACTIVE-SUBSCRIPTION gate (the
  # subscription replaces the old per-go-live charge) + create the registry row
  # in a provisioning state. No active subscription → 402 {no_active_subscription,
  # checkout_path} and NOTHING is provisioned. The actual Go warm-pool
  # provisioning + reporting-back is cloud-12b/cloud-13. → 201 {barkpark} honestly
  # carrying health_status:"unknown", agent_status:"offline".
  post("/v1/launch", do: go_live(conn))
  post("/v1/go-live", do: go_live(conn))

  # azh-w6 (S14c) — POST /v1/resurrect {name, provider, bundle_ref, region?,
  # server_type?}: the portable-archive restore. Recreate a torn-down instance
  # from an object-storage bundle onto a FRESH box (Remove/deprovision DELETES the
  # registry row, so resurrect stands up a new row rather than reviving a soft-
  # deleted one). Creates the barkpark row NIL-HONEST (provider/region/size ride
  # the request or stay NULL — D23) and enqueues a `resurrect` job carrying the
  # bundle_ref. → 202 {ok, id, job_id}. The actual pull + rehydrate is the Go
  # worker's resurrect drain (S14 portable archives).
  post("/v1/resurrect", do: resurrect(conn))

  ## Internal routes (worker-token auth) — the Go warm-pool provisioner's queue.
  ## NEVER user/agent-reachable: require_worker matches the shared WORKER_TOKEN
  ## only, 401 otherwise.

  # POST /v1/internal/provision-jobs/claim → claim the oldest pending job (FOR UPDATE SKIP LOCKED) for this
  # worker. 200 {job_id, name, slug, region, server_type} for a claimed job, or
  # 204 (no body) when none is pending (the worker sleeps + retries). The
  # claim_token is generated here — one per claim, traceable on the job row.
  post "/v1/internal/provision-jobs/claim" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.claim_next_job(generate_claim_token()) do
        nil ->
          send_resp(conn, 204, "")

        {job, barkpark} ->
          json(conn, 200, claim_json(job, barkpark))
      end
    end
  end

  # POST /v1/internal/provision-jobs/:id/succeed {ip} → mark the job succeeded
  # and flip its Barkpark to up at {ip}. IDEMPOTENT + status-guarded:
  #   200 {ok: true} — a fresh "claimed"→"succeeded" OR a retried succeed for an
  #     already-"succeeded" job (a dropped response self-heals; the worker KEEPS
  #     its box).
  #   409 {error: "conflict"} — the job is in a terminal NON-succeeded state
  #     ("failed"). The control plane already gave up; the worker treats the 4xx
  #     as "tear down the orphan box".
  #   422 when ip is missing (or a changeset rejection); 404 when no job has that id.
  post "/v1/internal/provision-jobs/:id/succeed" do
    conn = Auth.require_worker(conn, [])

    cond do
      conn.halted ->
        conn

      not (is_binary(conn.body_params["ip"]) and conn.body_params["ip"] != "") ->
        json(conn, 422, %{error: "ip_required"})

      true ->
        # instance-admin-token: the worker MAY report the per-instance admin token
        # it minted on the box alongside {ip}. When present it is stored encrypted
        # (Vault) on the barkpark row so the owner can retrieve it from the product;
        # absent is fine (back-compat — the ip-only succeed path is unchanged).
        # dwb-4: the worker MAY also report the content-bootstrap outputs
        # alongside — stored (secrets Vault-encrypted) in the same transaction.
        # task-5866ec745efcd7f7: a provision_support worker MAY report the OPAQUE
        # id of the ledger token it minted on the parent main as `token_id`; the
        # Registry persists it as the SUPPORT row's fleet_token_id (the sole
        # durable token-id holder, PDF-D68 — what `bp cloud support remove`
        # revokes). Additive + tolerant both ways: absent → the ip-only path is
        # byte-unchanged (older workers), and a non-support row never takes it.
        # claim-fence (bp-c55): the worker MAY echo the claim_token it holds; when
        # present the Registry fences a stale re-claim, when absent behavior is
        # unchanged (the deployed Go fleet doesn't echo it yet — Stage 1 compat).
        opts =
          succeed_opts(conn.body_params["admin_token"], conn.body_params["bootstrap"]) ++
            fleet_token_id_opts(conn.body_params["token_id"]) ++
            claim_token_opts(conn)

        case Registry.succeed_job(conn.path_params["id"], conn.body_params["ip"], opts) do
          {:ok, job} ->
            # The box just went live — push "fleet" so the dashboard flips it
            # from "provisioning" to up without a manual refresh.
            broadcast_barkpark_team(job.barkpark_id, "fleet")
            # notifications-email: additive alert (the SSE signal still fires).
            dispatch_barkpark_event(job.barkpark_id, :provision_succeeded)
            # dwb (charter D9): kick a best-effort isu-6 update-status refresh so a
            # freshen that degraded to baked code (slice 2) is VISIBLE as
            # update_state="behind" with a working self-update button from minute
            # zero. Fire-and-forget — the refresh makes an HTTP call to the
            # instance and must NEVER block or fail this 200.
            kick_update_status_refresh(job.barkpark_id)
            json(conn, 200, %{ok: true})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})

          {:error, :conflict} ->
            json(conn, 409, %{error: "conflict"})

          # claim-fence (bp-c55): a stale worker whose claim was swept + re-claimed.
          {:error, :stale_claim} ->
            json(conn, 409, %{error: "stale_claim"})

          {:error, _} ->
            json(conn, 422, %{error: "invalid"})
        end
    end
  end

  # POST /v1/internal/provision-jobs/:id/step {step, status, detail?} → dwb-14:
  # record one worker-reported step transition (create|secure|configure|content|
  # verify|ready × started|progress|done|failed), then push "fleet" so the /new
  # progress screen refetches + renders SERVER-confirmed state. started/done/
  # failed APPEND a new entry; dwb-19 `progress` UPDATES the in-flight step's
  # live caption in place (no new entry; a progress on a terminal/unstarted
  # step is a 200 no-op).
  # Best-effort telemetry: a step report NEVER affects the job's provisioning
  # outcome. The worker treats any non-2xx as "log and continue".
  #   200 {ok: true}   — recorded (append, in-place caption update, or a no-op).
  #   404 {not_found}  — no job with that id.
  #   422 {invalid_step} — unknown step/status pair.
  post "/v1/internal/provision-jobs/:id/step" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.append_provision_step(
             conn.path_params["id"],
             conn.body_params["step"],
             conn.body_params["status"],
             conn.body_params["detail"]
           ) do
        {:ok, job} ->
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :invalid_step} ->
          json(conn, 422, %{error: "invalid_step"})
      end
    end
  end

  # POST /v1/internal/provision-jobs/:id/console {line} → dwb-16: APPEND one
  # worker-reported LIVE console line (the create→live + bootstrap narration,
  # already redacted worker-side) to the job's console, then push "fleet" so the
  # /new console panel refetches + streams the new line. Append-only + capped
  # server-side (oldest dropped). Best-effort telemetry: a console report NEVER
  # affects the job's provisioning outcome; the worker treats any non-2xx as "log
  # and continue".
  #   200 {ok: true}   — appended (or a late line after the job is terminal).
  #   404 {not_found}  — no job with that id.
  #   422 {invalid}    — missing/blank line.
  post "/v1/internal/provision-jobs/:id/console" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.append_provision_console(
             conn.path_params["id"],
             conn.body_params["line"]
           ) do
        {:ok, job} ->
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :invalid} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  # POST /v1/internal/provision-jobs/:id/release → dwb-15: flip a CLAIMED job back
  # to pending for graceful worker shutdown, WITHOUT consuming an attempt, so the
  # next worker re-claims in seconds instead of waiting the >12min stale-claim
  # reaper. Status-guarded + idempotent:
  #   200 {ok: true}  — a "claimed"→"pending" release, OR a retried release for an
  #     already-"pending" job (a dropped response self-heals).
  #   409 {conflict}  — the job already succeeded/failed (terminal); never resurrect.
  #   404 {not_found} — no job with that id.
  post "/v1/internal/provision-jobs/:id/release" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.release_job(conn.path_params["id"], claim_token_opts(conn)) do
        {:ok, job} ->
          # Push "fleet" so a dashboard/parked /new page sees the job return to
          # pending (still "provisioning") rather than appear stuck.
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        # claim-fence (bp-c55): a stale worker whose claim was swept + re-claimed.
        {:error, :stale_claim} ->
          json(conn, 409, %{error: "stale_claim"})
      end
    end
  end

  ## Internal deprovision queue (worker-token auth) — the Remove path's drain.

  post "/v1/internal/deprovision-jobs/claim" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.claim_next_deprovision_job(generate_claim_token()) do
        nil ->
          send_resp(conn, 204, "")

        {job, barkpark} ->
          json(conn, 200, deprovision_claim_json(job, barkpark))
      end
    end
  end

  post "/v1/internal/deprovision-jobs/:id/succeed" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      team_id = team_id_for_barkpark_of_job(conn.path_params["id"])

      case Registry.succeed_deprovision_job(conn.path_params["id"], claim_token_opts(conn)) do
        # cch-w57: a real delete also stamped a `barkpark.deleted` audit row in
        # the same transaction, so the console's audit pane is nudged too — the
        # `:already_gone` arm deleted nothing and wrote nothing, so it must not
        # claim a trail change.
        {:ok, :deleted} ->
          push_event(team_id, "fleet")
          push_event(team_id, "audit")
          json(conn, 200, %{ok: true})

        {:ok, _} ->
          push_event(team_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        # claim-fence (bp-c55): a stale worker whose claim was swept + re-claimed.
        {:error, :stale_claim} ->
          json(conn, 409, %{error: "stale_claim"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  post "/v1/internal/deprovision-jobs/:id/fail" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      reason = conn.body_params["error"]

      case Registry.fail_job(
             conn.path_params["id"],
             if(is_binary(reason), do: reason, else: "unspecified"),
             claim_token_opts(conn)
           ) do
        {:ok, job} ->
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        # claim-fence (bp-c55): a stale worker whose claim was swept + re-claimed.
        {:error, :stale_claim} ->
          json(conn, 409, %{error: "stale_claim"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  ## Internal attach-domain queue (worker-token auth) — the custom-domain drain.

  post "/v1/internal/attach-domain-jobs/claim" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.claim_next_attach_domain_job(generate_claim_token()) do
        nil ->
          send_resp(conn, 204, "")

        {job, barkpark} ->
          json(conn, 200, attach_domain_claim_json(job, barkpark))
      end
    end
  end

  post "/v1/internal/attach-domain-jobs/:id/succeed" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      # The box ip the worker configured — optional telemetry stamped as
      # result_ip when echoed; the custom_host itself was persisted at enqueue.
      ip =
        case conn.body_params["ip"] do
          ip when is_binary(ip) and ip != "" -> ip
          _ -> nil
        end

      case Registry.succeed_attach_domain_job(conn.path_params["id"], ip, claim_token_opts(conn)) do
        {:ok, job} ->
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        # claim-fence (bp-c55): a stale worker whose claim was swept + re-claimed.
        {:error, :stale_claim} ->
          json(conn, 409, %{error: "stale_claim"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  post "/v1/internal/attach-domain-jobs/:id/fail" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      reason = conn.body_params["error"]

      case Registry.fail_attach_domain_job(
             conn.path_params["id"],
             if(is_binary(reason), do: reason, else: "unspecified"),
             claim_token_opts(conn)
           ) do
        {:ok, job} ->
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        # claim-fence (bp-c55): a stale worker whose claim was swept + re-claimed.
        {:error, :stale_claim} ->
          json(conn, 409, %{error: "stale_claim"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  ## Internal resurrect queue (worker-token auth) — the portable-archive restore
  ## drain (azh-w6/S14c). Reuses the provision-jobs succeed/fail/step/console
  ## routes (they operate by job id, kind-agnostically) — only the CLAIM is
  ## kind-filtered so a resurrect job is never handed to a provision worker.

  # POST /v1/internal/resurrect-jobs/claim → claim the oldest pending resurrect
  # job (FOR UPDATE SKIP LOCKED). 200 with the provision claim payload PLUS
  # `bundle_ref` (the archive to restore from), or 204 when none is pending.
  post "/v1/internal/resurrect-jobs/claim" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.claim_next_resurrect_job(generate_claim_token()) do
        nil ->
          send_resp(conn, 204, "")

        {job, barkpark} ->
          json(conn, 200, resurrect_claim_json(job, barkpark))
      end
    end
  end

  # POST /v1/internal/support-jobs/claim → claim the oldest pending
  # `provision_support` job (FOR UPDATE SKIP LOCKED). 200 with the provision claim
  # payload PLUS the PINNED `support` map (parent url + admin token, dataset,
  # workspace, name — the credential spine the Go fleet provisioner binds the box
  # with, PDF-D83/D89/D93), or 204 when none is pending. Kind-filtered so a
  # support job is never handed to a main-provision worker.
  post "/v1/internal/support-jobs/claim" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.claim_next_support_provision_job(generate_claim_token()) do
        nil ->
          send_resp(conn, 204, "")

        {job, barkpark} ->
          json(conn, 200, support_provision_claim_json(job, barkpark))
      end
    end
  end

  # POST /v1/internal/agent-key-jobs/claim → 200 {job:{id,claim_token}, ip,
  # key_var, key} | 204 (PDF-D94). Kind-filtered (push_agent_key) so no other
  # drain grabs it. THE ONE MOMENT key material leaves the plane: the stash pop
  # is DELETE-ON-READ, so a stale re-claim (worker crash) or a CP restart finds
  # nothing — and the job is failed HONESTLY right here ("paste it again"),
  # never handed out keyless. A host-less row (removed mid-flight) fails the
  # same way. The 204 lets the worker's poll loop continue to the next tick.
  post "/v1/internal/agent-key-jobs/claim" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.claim_next_agent_key_job(generate_claim_token()) do
        nil ->
          send_resp(conn, 204, "")

        {job, barkpark} ->
          case AgentKeyStash.take(job.id) do
            {:ok, {key_var, key}} when is_binary(barkpark.host) and barkpark.host != "" ->
              json(conn, 200, %{
                job: %{id: job.id, claim_token: job.claim_token},
                ip: barkpark.host,
                key_var: key_var,
                key: key
              })

            {:ok, _} ->
              _ =
                Registry.fail_agent_key_job(
                  job.id,
                  "the support box has no host — nowhere to deliver the key",
                  claim_token: job.claim_token
                )

              broadcast_barkpark_team(job.barkpark_id, "fleet")
              send_resp(conn, 204, "")

            :error ->
              _ =
                Registry.fail_agent_key_job(
                  job.id,
                  "the pasted key expired in transit (control-plane restart or timeout) — paste it again",
                  claim_token: job.claim_token
                )

              broadcast_barkpark_team(job.barkpark_id, "fleet")
              send_resp(conn, 204, "")
          end
      end
    end
  end

  # POST /v1/internal/agent-key-jobs/:id/succeed [{ip}] → the key line landed +
  # listener restarted. Flips the JOB ROW ONLY (succeed_agent_key_job — a key
  # push must never clobber a live row's health/host the way a provision
  # succeed does). Mirrors the attach-domain succeed contract verbatim.
  post "/v1/internal/agent-key-jobs/:id/succeed" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      ip =
        case conn.body_params["ip"] do
          ip when is_binary(ip) and ip != "" -> ip
          _ -> nil
        end

      case Registry.succeed_agent_key_job(conn.path_params["id"], ip, claim_token_opts(conn)) do
        {:ok, job} ->
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        {:error, :stale_claim} ->
          json(conn, 409, %{error: "stale_claim"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  # POST /v1/internal/agent-key-jobs/:id/fail {error} → delivery failed; the
  # support row is untouched (still live — re-paste is the recovery).
  post "/v1/internal/agent-key-jobs/:id/fail" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      reason = conn.body_params["error"]

      case Registry.fail_agent_key_job(
             conn.path_params["id"],
             if(is_binary(reason), do: reason, else: "unspecified"),
             claim_token_opts(conn)
           ) do
        {:ok, job} ->
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        {:error, :stale_claim} ->
          json(conn, 409, %{error: "stale_claim"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  # POST /v1/internal/enable-apply-jobs/claim → 200 {job_id, claim_token, ip} |
  # 204 (isu-w5, task-509f5fd02bc48f9c). Kind-filtered (enable_apply) so no
  # other drain grabs it. FLAT payload — the exact JSON the Go worker's
  # EnableApplySpec decodes. A host-less row (removed mid-flight) is failed
  # HONESTLY right here rather than handed out undeliverable; the 204 lets the
  # worker's poll loop continue to the next tick.
  post "/v1/internal/enable-apply-jobs/claim" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.claim_next_enable_apply_job(generate_claim_token()) do
        nil ->
          send_resp(conn, 204, "")

        {job, barkpark} ->
          if is_binary(barkpark.host) and barkpark.host != "" do
            json(conn, 200, %{
              job_id: job.id,
              claim_token: job.claim_token,
              ip: barkpark.host
            })
          else
            _ =
              Registry.fail_enable_apply_job(
                job.id,
                "the box has no host — nowhere to deliver the arming flag",
                claim_token: job.claim_token
              )

            broadcast_barkpark_team(job.barkpark_id, "fleet")
            send_resp(conn, 204, "")
          end
      end
    end
  end

  # POST /v1/internal/enable-apply-jobs/:id/succeed [{ip}] → the env flag landed
  # + the app restarted. Flips the JOB ROW ONLY (succeed_enable_apply_job — an
  # arming push must never clobber a live row's health/host the way a provision
  # succeed does). `apply_arming` stays a MEASUREMENT: the next probe/sweep reads
  # `apply_enabled: true` off the restarted box and re-enters it into the
  # candidate set. Mirrors the agent-key succeed contract verbatim.
  post "/v1/internal/enable-apply-jobs/:id/succeed" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      ip =
        case conn.body_params["ip"] do
          ip when is_binary(ip) and ip != "" -> ip
          _ -> nil
        end

      case Registry.succeed_enable_apply_job(conn.path_params["id"], ip, claim_token_opts(conn)) do
        {:ok, job} ->
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        {:error, :stale_claim} ->
          json(conn, 409, %{error: "stale_claim"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  # POST /v1/internal/enable-apply-jobs/:id/fail {error} → arming failed; the
  # barkpark row is untouched (still live, still MEASURED-unarmed — the next
  # unarmed measurement re-enqueues, which is the retry loop).
  post "/v1/internal/enable-apply-jobs/:id/fail" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      reason = conn.body_params["error"]

      case Registry.fail_enable_apply_job(
             conn.path_params["id"],
             if(is_binary(reason), do: reason, else: "unspecified"),
             claim_token_opts(conn)
           ) do
        {:ok, job} ->
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        {:error, :stale_claim} ->
          json(conn, 409, %{error: "stale_claim"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  ## Internal fleet-ops (worker-token auth) — the registry surface behind the
  ## `bp cloud hetzner instance` admin verbs (decommission/adopt/eject/audit).
  ## Cross-team BY DESIGN: this is an operator tool authenticated with the
  ## shared WORKER_TOKEN, the same credential that can already claim and
  ## complete every team's provision jobs. NEVER user/agent-reachable.

  # GET /v1/internal/barkparks → 200 {barkparks: […]} — every row across all
  # teams, with its dns_label and latest provision/deprovision job statuses, so
  # the fleet audit can cross-check registry ↔ servers ↔ DNS.
  get "/v1/internal/barkparks" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      barkparks = Registry.all_barkparks()
      ids = Enum.map(barkparks, & &1.id)
      pmap = Registry.latest_provision_status_map(ids)
      dmap = Registry.latest_deprovision_status_map(ids)

      json(conn, 200, %{
        barkparks: Enum.map(barkparks, &internal_barkpark_json(&1, pmap[&1.id], dmap[&1.id]))
      })
    end
  end

  # POST /v1/internal/barkparks {team_id, name, slug, url, host, admin_token?}
  # → 201 {barkpark} — ADOPT an already-running box as a managed tenant row
  # (standalone → SaaS). The quota + slug/url uniqueness of the normal register
  # path all apply; the optional admin_token is Vault-encrypted at rest.
  post "/v1/internal/barkparks" do
    conn = Auth.require_worker(conn, [])

    cond do
      conn.halted ->
        conn

      not (is_binary(conn.body_params["team_id"]) and conn.body_params["team_id"] != "") ->
        json(conn, 422, %{error: "team_id_required"})

      true ->
        attrs = %{
          name: conn.body_params["name"],
          slug: conn.body_params["slug"],
          url: conn.body_params["url"],
          host: conn.body_params["host"],
          mode: "managed"
        }

        case Registry.adopt_barkpark(conn.body_params["team_id"], attrs,
               admin_token: conn.body_params["admin_token"]
             ) do
          {:ok, bp} ->
            push_event(bp.team_id, "fleet")
            json(conn, 201, %{ok: true, barkpark: internal_barkpark_json(bp, nil, nil)})

          {:error, :limit_reached} ->
            json(conn, 403, %{error: "limit_reached"})

          {:error, %Ecto.Changeset{} = cs} ->
            json(conn, 422, %{error: "invalid", details: errors(cs)})
        end
    end
  end

  # POST /v1/internal/barkparks/:id/deprovision [{mode: "detach"}] — remove any
  # team's instance. Default: the SAME branch logic as the team-facing DELETE
  # (live → enqueue a worker deprovision job, 202; provisioning → 409; non-live
  # → delete the row now, 200). mode "detach" deletes the ROW ONLY (200) even
  # when host is set — for a row whose host is a stale/recycled IP the worker's
  # fqdn fence would (rightly) refuse to act on, or a box the caller manages
  # itself (eject). The caller asserts no live box of this row is stranded.
  post "/v1/internal/barkparks/:id/deprovision" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      detach? = conn.body_params["mode"] == "detach"

      case Registry.get_barkpark(conn.path_params["id"]) do
        %Barkpark{} = bp ->
          cond do
            detach? ->
              case Registry.delete_barkpark(bp) do
                {:ok, _} ->
                  push_event(bp.team_id, "fleet")
                  json(conn, 200, %{ok: true, status: "removed"})

                {:error, %Ecto.Changeset{} = cs} ->
                  json(conn, 422, %{error: "invalid", details: errors(cs)})
              end

            is_binary(bp.host) and bp.host != "" ->
              case Registry.enqueue_deprovision_job(bp) do
                {:ok, _job} ->
                  push_event(bp.team_id, "fleet")
                  json(conn, 202, %{ok: true, status: "deprovisioning"})

                {:error, :already_deprovisioning} ->
                  json(conn, 202, %{ok: true, status: "deprovisioning"})

                {:error, cs} ->
                  json(conn, 422, %{error: "invalid", details: errors(cs)})
              end

            # ANY BLOCKING KIND — this internal route takes any row, supports
            # included, and a resurrect can be in flight (task-688ebffc4b0aa50a);
            # see active_job_blocking_delete?/1.
            Registry.active_job_blocking_delete?(bp) ->
              json(conn, 409, %{error: "provisioning_in_progress"})

            true ->
              case Registry.delete_barkpark(bp) do
                {:ok, _} ->
                  push_event(bp.team_id, "fleet")
                  json(conn, 200, %{ok: true, status: "removed"})

                {:error, %Ecto.Changeset{} = cs} ->
                  json(conn, 422, %{error: "invalid", details: errors(cs)})
              end
          end

        _ ->
          json(conn, 404, %{error: "not_found"})
      end
    end
  end

  ## Internal warm-pool queue (worker-token auth) — dwb-10. The pre-baked box
  ## store the Go worker registers into + claims from. Claiming is a FOR UPDATE
  ## SKIP LOCKED row flip (race-safe; Hetzner labels are not CAS). NEVER
  ## user/agent-reachable: require_worker matches the shared WORKER_TOKEN only.

  # POST /v1/internal/warm-servers {name, ip} → register a freshly-created warm box
  # into the pool. IDEMPOTENT on name (a retried register is a no-op).
  post "/v1/internal/warm-servers" do
    conn = Auth.require_worker(conn, [])

    cond do
      conn.halted ->
        conn

      not (is_binary(conn.body_params["name"]) and conn.body_params["name"] != "") ->
        json(conn, 422, %{error: "name_required"})

      true ->
        case Registry.register_warm_server(conn.body_params["name"], conn.body_params["ip"]) do
          {:ok, _} -> json(conn, 201, %{ok: true})
          {:error, _} -> json(conn, 422, %{error: "invalid"})
        end
    end
  end

  # POST /v1/internal/warm-servers/claim → atomically pop the oldest ready warm box
  # for an ASSIGN. 200 {name, ip} for a claimed box, or 204 when the pool is empty
  # (the go-live falls through to one-shot create).
  post "/v1/internal/warm-servers/claim" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.claim_warm_server(generate_claim_token()) do
        nil -> send_resp(conn, 204, "")
        # claim-fence (bp-c55): return the claim_token so the worker can echo it on
        # DELETE — fencing a stale delete of a re-registered box. Additive key.
        ws -> json(conn, 200, %{name: ws.name, ip: ws.ip, claim_token: ws.claim_token})
      end
    end
  end

  # POST /v1/internal/warm-servers/claim-retire → atomically pop the oldest ready
  # warm box for RETIREMENT (the reconciler shrinking an oversized pool). 200
  # {name, ip} or 204 when there is nothing ready to retire.
  post "/v1/internal/warm-servers/claim-retire" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      case Registry.claim_warm_server_for_retire(generate_claim_token()) do
        nil -> send_resp(conn, 204, "")
        # claim-fence (bp-c55): echo the claim_token for a fenced DELETE. Additive.
        ws -> json(conn, 200, %{name: ws.name, ip: ws.ip, claim_token: ws.claim_token})
      end
    end
  end

  # POST /v1/internal/warm-servers/claim-refresh {min_age_seconds?} → atomically
  # pop the STALEST ready box for a background REFRESH to origin/main
  # (snapshot-management self-refresh loop). 200 {name, ip, claim_token} or 204
  # when no ready box is due. The box is `refreshing` (out of the assignable set)
  # until the worker releases it via .../refreshed. min_age_seconds gates churn:
  # a box refreshed within it is not re-picked (default 90s).
  post "/v1/internal/warm-servers/claim-refresh" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      min_age =
        case conn.body_params["min_age_seconds"] do
          n when is_integer(n) and n >= 0 -> n
          _ -> 90
        end

      case Registry.claim_warm_server_for_refresh(generate_claim_token(), min_age) do
        nil -> send_resp(conn, 204, "")
        ws -> json(conn, 200, %{name: ws.name, ip: ws.ip, claim_token: ws.claim_token})
      end
    end
  end

  # POST /v1/internal/warm-servers/:name/refreshed {claim_token, refreshed?} →
  # release a refreshing box BACK to ready (refreshing → ready). claim-fenced;
  # `refreshed: true` (default) stamps refreshed_at now (drop to the back of the
  # queue), `false` leaves it (retry sooner). A refresh failure NEVER removes a
  # box — it still serves working code. 200 {ok: true}.
  post "/v1/internal/warm-servers/:name/refreshed" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      token =
        case conn.body_params["claim_token"] do
          t when is_binary(t) and t != "" -> t
          _ -> nil
        end

      refreshed? = conn.body_params["refreshed"] != false

      cond do
        is_nil(token) ->
          json(conn, 422, %{error: "claim_token_required"})

        true ->
          {:ok, _} =
            Registry.release_warm_server_after_refresh(
              conn.path_params["name"],
              token,
              refreshed?
            )

          json(conn, 200, %{ok: true})
      end
    end
  end

  # GET /v1/internal/warm-servers/count → 200 {ready: N}. The reconciler's grow/
  # shrink input (pool size = ready + refreshing; a refreshing box is a transient
  # pool member, so it never triggers a spurious grow).
  get "/v1/internal/warm-servers/count" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      json(conn, 200, %{ready: Registry.count_ready_warm_servers()})
    end
  end

  # DELETE /v1/internal/warm-servers/:name → drop the row once its box is consumed
  # (assigned live, torn down on a failed assign, or retired). IDEMPOTENT.
  delete "/v1/internal/warm-servers/:name" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      # claim-fence (bp-c55): the worker MAY echo the claim_token it holds (body key
      # or `?claim_token=`); when present the delete only removes the row while the
      # token still matches, so a stale delete of a re-registered box is a no-op.
      # Absent → today's delete-by-name (Stage 1 compat).
      qp = fetch_query_params(conn)

      claim_token =
        case conn.body_params["claim_token"] || qp.query_params["claim_token"] do
          t when is_binary(t) and t != "" -> t
          _ -> nil
        end

      {:ok, _} = Registry.delete_warm_server(conn.path_params["name"], claim_token)
      json(conn, 200, %{ok: true})
    end
  end

  # POST /v1/internal/platform-deliveries {deliveries: [row, ...]} → the recorder
  # for the platform's OWN deploys (dr-w23-s2, charter D385).
  #
  # THE CREDENTIAL IS `require_worker`, deliberately. This is written by a deploy
  # job, never by a human, and `WORKER_TOKEN` is already in
  # `/opt/barkpark/cloud/.env` — the file the deploy already sources. Zero new
  # credentials, and the family is proven fail-closed live (401 without a token).
  # The READ half is a different tier on purpose: see GET /v1/deliveries, which is
  # PAT-reachable, because a record no human credential can read is not a record.
  #
  # A LIST IN ONE CALL. One delivering run carries one row per sha it delivered —
  # ~36% of merged shas have no run of their own and ride someone else's — so the
  # natural unit of the write is the run's whole batch, not a row.
  #
  # IDEMPOTENT on (sha, delivering_run_id, target) — W24, charter D422, which
  # amends D410. `target` is IN the key because deploy.yml's control-plane and
  # instance jobs share one GITHUB_RUN_ID, so the W23 key ate the second leg of
  # every deploy and still answered 200. A retried deploy job
  # re-posts the same batch and writes nothing. The 200 counts BOTH — `received`
  # is what the caller sent, `recorded` is what was new — so a re-post reads as
  # `{received: 3, recorded: 0}` instead of a fake success.
  #
  # 503 unavailable IS THE POINT. deploy.yml's `instance` job fires on
  # `^(api|internal|deploy|connectors|templates)/` and does NOT require the
  # `cloud/**` merge that carries this table's migration, so an api-only merge
  # posts here against a control plane that has no `platform_deliveries` yet.
  # That answer must be a typed, retryable refusal the caller LOGS — never a 500,
  # and never a silent `|| true`, which is the exact blindness this wave exists
  # to end. (An older control plane without this ROUTE answers the router's 404;
  # the caller treats both as "the crown did not record this".)
  post "/v1/internal/platform-deliveries" do
    conn = Auth.require_worker(conn, [])

    cond do
      conn.halted ->
        conn

      not is_list(conn.body_params["deliveries"]) ->
        json(conn, 422, %{
          error: "deliveries_required",
          detail: "body must carry a `deliveries` LIST of rows, one per sha this run delivered"
        })

      true ->
        case PlatformDelivery.record_all(conn.body_params["deliveries"]) do
          {:ok, %{received: received, recorded: recorded}} ->
            json(conn, 200, %{ok: true, received: received, recorded: recorded})

          {:error, :unavailable} ->
            json(conn, 503, platform_deliveries_unavailable())

          {:error, {:invalid_row, index, errors}} ->
            json(conn, 422, %{error: "invalid_row", index: index, errors: errors})

          # A required column arrived explicitly NULL (W24, D422). That is the
          # CALLER's payload, not a broken crown, so it is a typed 422 that names
          # the column — a 500 here told a deploy job the platform had failed and
          # sent it retrying identical bytes forever.
          {:error, {:null_column, column}} ->
            json(conn, 422, %{
              error: "null_column",
              column: column,
              detail:
                "column `#{column}` arrived explicitly null and is required — " <>
                  "omit the key entirely if the value is unknown"
            })

          {:error, reason} ->
            Logger.error("platform_deliveries: record refused: #{inspect(reason)}")
            json(conn, 500, %{error: "record_failed"})
        end
    end
  end

  ## Sites — hosted websites running co-located with a Barkpark.

  # POST /v1/sites {barkpark_id, name, framework?, domains?, scale_mode?} → 201
  # {site}. The site inherits its team_id from the Barkpark — the caller doesn't
  # (and can't) pick a different team.
  #
  # site-spawner D29: a STATIC site also carries its CONTENT BINDING — the
  # workspace/project/dataset triple it builds from — and the control plane MINTS
  # its public-read content token here, server-side, over the instance's scoped
  # token route. Both halves matter: without the binding the site is a ghost the
  # reaper later kills, and without the token the build has nothing to read with.
  # site-spawner W8 (charter D73): and the route READS the binding back before it
  # writes the row. `content_bound` is only "a token exists" — a name-level truth
  # and a claim-level falsehood — so the 201 additionally carries a
  # `content_binding` verdict the control plane actually OBSERVED: `bound` (the
  # site read its own content, with the count) or `unverified` (with the reason it
  # could not be checked). A binding the site provably CANNOT read is refused 422
  # `content_binding_empty` at the door, with the menu of types it can read.
  post "/v1/sites" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        team = conn.assigns.current_team
        bp_id = conn.body_params["barkpark_id"]
        name = conn.body_params["name"]

        with true <- is_binary(bp_id) or {:error, :barkpark_required},
             %Registry.Barkpark{team_id: tid} = bp when tid == team.id <-
               Registry.get_barkpark(bp_id),
             true <- (is_binary(name) and name != "") or {:error, :name_required},
             slug <- conn.body_params["slug"] || slugify(name),
             # site-spawner W1: `kind` discriminates container (BYO-repo, the
             # default) from static (content-bound Astro/Hugo/…). Framework
             # defaults per kind so a static site with no explicit framework lands
             # on astro rather than the container default nextjs (an illegal pair).
             kind <- conn.body_params["kind"] || "container",
             framework <- conn.body_params["framework"] || default_framework(kind),
             attrs <- %{
               name: name,
               slug: slug,
               kind: kind,
               framework: framework,
               domains: conn.body_params["domains"] || [],
               scale_mode: conn.body_params["scale_mode"] || "always_on"
             },
             # The content binding (static sites) + the plaintext read token the
             # build fetches with. create_site encrypts the token at rest; only
             # present keys are folded in so a container site stays unchanged.
             attrs <- put_site_content_binding(attrs, conn.body_params),
             # A static site IS its content binding — refuse an unbound one AT THE
             # DOOR rather than writing a row the deploy path can never build.
             :ok <- require_content_binding(kind, attrs),
             # site-spawner W7 (charter D68): a node site owns a per-site blue/green
             # port pair — allocate the lowest-free EVEN base ONCE, here at create.
             # A container/static site allocates nothing (attrs pass through). A box
             # whose node-slot window is full fails closed with an honest 503 rather
             # than minting a portless (un-servable) node row.
             {:ok, attrs} <- allocate_node_port(kind, attrs),
             # site-spawner D29: MINT the public-read content token on the box
             # BEFORE the row exists, so a 201 can never be a ghost (a site with a
             # binding but no token can't build, and nothing downstream would say
             # so). An unreachable/refusing instance is a 502 with its own words —
             # no site row is written.
             {:ok, attrs} <- mint_site_read_token(bp, attrs, slug),
             # site-spawner W8 (charter D73): PROVE the binding by READING it,
             # here — the last moment the PLAINTEXT read token is in hand. Until
             # now `content_bound: true` meant only "a token was minted", so a
             # typo'd dataset or a type the site cannot see was accepted and died
             # minutes later inside the build as a bare
             # `BarkparkNotFoundError: document not found`.
             {:ok, binding} <- verify_content_binding(bp, attrs),
             # activity-audit-log: the create + a `site.created` audit event share
             # ONE transaction (the target_id is resolved from the created site).
             # target_fun supplies the id only knowable after the insert.
             {:ok, site} <-
               Accounts.audit(
                 %{
                   team_id: team.id,
                   actor_user_id: conn.assigns.current_user.id,
                   action: "site.created",
                   target_type: "site",
                   metadata: %{
                     name: name,
                     kind: attrs.kind,
                     framework: attrs.framework,
                     barkpark_id: bp.id
                   }
                 },
                 fn -> Registry.create_site(bp, attrs) end,
                 fn s -> %{target_id: s.id} end
               ) do
          # Push "sites" so an open sites list / instance detail (including other
          # browser tabs) picks up the new site without a manual refresh.
          push_event(site.team_id, "sites")
          push_event(site.team_id, "audit")
          json(conn, 201, Map.merge(%{site: site_json(site, bp)}, binding_note(binding)))
        else
          nil ->
            json(conn, 404, %{error: "barkpark_not_found"})

          %Registry.Barkpark{} ->
            # Existed but wrong team — same 404 as "not found" to avoid an
            # existence leak across team boundaries.
            json(conn, 404, %{error: "barkpark_not_found"})

          # site-spawner D29: `barkpark_id` is validate_required AND NOT NULL, but
          # omitting it used to answer `name_required` — an error that names the
          # wrong field and sends the caller looking for a bug that isn't there.
          {:error, :barkpark_required} ->
            json(conn, 422, %{
              error: "barkpark_required",
              detail: "name the instance to host this site (barkpark_id)"
            })

          {:error, :name_required} ->
            json(conn, 422, %{error: "name_required"})

          {:error, {:binding_required, missing}} ->
            json(conn, 422, %{
              error: "content_binding_required",
              detail:
                "a static site builds FROM your content — bind it with " <>
                  "`--dataset <workspace>/<project>/<dataset>` (missing: #{Enum.join(missing, ", ")})"
            })

          {:error, :ports_exhausted} ->
            json(conn, 503, %{
              error: "node_ports_exhausted",
              detail:
                "this instance has no free node-slot port left — retire a node site or move to a larger box"
            })

          {:error, {:mint_failed, detail}} ->
            json(conn, 502, %{error: "read_token_mint_failed", detail: detail})

          # site-spawner W8 (charter D73): the binding was READ and it is empty —
          # the site's OWN token sees nothing at workspace/project/dataset/type.
          # Refuse at the door with the real menu (what that token could actually
          # read) and the exact re-run, rather than 201ing a site whose first
          # build dies on a message naming neither the type nor the dataset.
          {:error, {:binding_empty, detail, menu}} ->
            json(
              conn,
              422,
              %{error: "content_binding_empty", detail: detail}
              |> maybe_put_menu(menu)
            )

          # The hostname namespace is ONE namespace and the CREATE path is a
          # claim door: `domains` goes straight into `Registry.create_site/2`,
          # which now runs the same collision leaf the attach route runs. A name
          # another site — or another team's instance `custom_host` — already
          # holds is a CONFLICT, so it answers the same 409 as
          # `POST /v1/sites/:id/domains`, never a 201 the ask-gate would then
          # honour for two owners.
          {:error, :domain_taken} ->
            json(conn, 409, %{error: "domain_taken"})

          {:error, %Ecto.Changeset{} = cs} ->
            json(conn, 422, %{error: "invalid", details: errors(cs)})
        end
    end
  end

  # GET /v1/sites → 200 {sites: [...]} for the user's team.
  get "/v1/sites" do
    conn = conn |> Auth.require_user_or_pat([]) |> Auth.require_ability("read")

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, %{sites: []})

      true ->
        sites = Registry.list_sites_for_team(conn.assigns.current_team)
        # stw4-freshness (charter D24): ONE batched query for the latest
        # deployment per site so each row carries an at-a-glance freshness badge
        # (amber while a content-auto rebuild is in flight) without an N+1. The
        # embed is slim — status/trigger/timestamps only, HONESTY LAW: never
        # console/build_log_url/content_rev. nil-honest when a site never deployed.
        fresh = Registry.latest_deployment_status_map(Enum.map(sites, & &1.id))
        json(conn, 200, %{sites: Enum.map(sites, &put_last_deployment(site_json(&1), &1, fresh))})
    end
  end

  # GET /v1/sites/:id → 200 {site} | 404. Team-scoped — a wrong-team caller
  # gets the same 404 as a nonexistent id.
  get "/v1/sites/:id" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.get_team_site(conn.assigns.current_team, conn.path_params["id"]) do
          %Registry.Site{} = site ->
            bp = Registry.get_barkpark(site.barkpark_id)
            json(conn, 200, %{site: site_json(site, bp) |> put_current_deployment(site, bp)})

          nil ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # PATCH /v1/sites/:id {theme?, doc_type?} → 200 {site}. The operator-settings
  # update (search-template W8): ONLY the between-deploys-safe fields — theme
  # (deploy-pinned palette, next build) and doc_type (featured content type).
  # Everything infrastructural (name/slug/kind/framework/template/ports) stays
  # immutable. Changes take effect on the NEXT deploy; the response says so.
  patch "/v1/sites/:id" do
    with_team_site(conn, {:ability, "write"}, fn conn, site ->
      attrs =
        conn.body_params
        # site-spawner W9 (charter D87): this allow-list is INDEPENDENT of
        # `Site.settings_changeset/2`'s cast list — widening only the changeset
        # would make a PATCH of prebuilt_enabled a green-looking no-op (200, an
        # unchanged row, no error anywhere). Both, or neither.
        |> Map.take(["theme", "doc_type", "prebuilt_enabled"])
        |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

      # TURNING ON off-box builds is a CAPABILITY GRANT, not a content setting,
      # and it needs the `deploy` ability — the same one domain bind/unbind
      # demands, and for the same reason: it changes what this site will accept
      # and serve rather than what it renders. Without this, ONE `write` PAT both
      # ENABLES the prebuilt lane and USES it, so the per-site opt-in gates
      # nothing against the credential most likely to be over-scoped.
      #
      # Scoped deliberately to the ON transition. Turning it OFF is a
      # de-escalation any `write` holder may perform (never trap a site in a
      # riskier mode than its operator can leave), and `theme`/`doc_type` stay
      # plain `write` — this adds one gate, it does not re-tier the family.
      # NOTE the sibling asymmetry that is NOT a defect: DELETE /v1/sites/:id is
      # `write`. Deleting a site destroys it; enabling off-box builds makes it
      # serve bytes the box never built. Those are different risks, and only the
      # second one is a lasting grant.
      # Read the resolved credential the same way `Auth.require_ability/2` does —
      # `root` is its documented superset, so a browser SESSION (which carries
      # ["root"]) is never locked out of the dashboard toggle.
      abilities = conn.assigns[:current_abilities] || []
      may_grant? = "root" in abilities or "deploy" in abilities
      enabling_prebuilt? = Map.get(attrs, :prebuilt_enabled) == true

      cond do
        enabling_prebuilt? and not may_grant? ->
          json(conn, 403, %{
            error: "deploy_ability_required",
            detail:
              "enabling off-box builds grants this site the right to serve bytes it did not build — " <>
                "use a SESSION (the dashboard) or a root credential. A deploy PAT cannot do it today: " <>
                "the mint collapses [write, deploy] to [deploy], and deploy does not satisfy write, so " <>
                "no PAT can hold both. Turning it OFF needs only write."
          })

        attrs == %{} ->
          json(conn, 422, %{
            error: "nothing_to_update",
            detail:
              "mutable fields: theme (palette), doc_type (featured content type), prebuilt_enabled (accept off-box builds)"
          })

        true ->
          case Registry.update_site_settings(site, attrs) do
            {:ok, updated} ->
              push_event(updated.team_id, "sites")
              bp = Registry.get_barkpark(updated.barkpark_id)

              json(conn, 200, %{
                site: site_json(updated, bp),
                note: "settings apply on the next deploy"
              })

            {:error, cs} ->
              json(conn, 422, %{error: "invalid_settings", detail: errors(cs)})
          end
      end
    end)
  end

  # DELETE /v1/sites/:id → 200 {ok, status:"deleted"} | error. The inverse of a
  # spawn: tear the site down on its box (stop slots, disarm the Caddy route,
  # delete the tree) THEN deregister the row. BOX FIRST — a failed teardown must
  # not orphan a still-serving box behind a deleted registration. Team-scoped,
  # write ability (same as rollback).
  #
  # W67 S2 (D811) — NO "the box is gone" ARM. This route used to open with
  # `teardown_result = if is_nil(bp), do: :ok, else: Sites.Deploy.teardown(site, bp)`
  # and stamp `box_present: not is_nil(bp)` into the audit row. Both were DEAD:
  # `sites.barkpark_id` is NOT NULL and `sites_barkpark_id_fkey` is ON DELETE
  # CASCADE (confdeltype='c'), so deleting a Barkpark deletes its sites with it —
  # a persisted site ALWAYS has its box row, `get_barkpark/1` cannot answer nil
  # for one, and `box_present` could only ever record `true`. A constant dressed
  # as a measurement is exactly what this epic exists to remove. The FK is now
  # asserted by `site_cascade_census_test.exs` — specifically by its
  # "sites.barkpark_id is NOT NULL and ON DELETE CASCADE" test, added in W67
  # REVIEW because the four census tests it shipped with all looked the OTHER way
  # (FKs whose PARENT is `sites`) and `fk_census_test.exs` reads no delete
  # behaviour at all, so this sentence was claiming a guard nobody had written.
  # Drop the NOT NULL or loosen the FK now and that test reds, naming this arm. The one residual window — another request
  # deleting the Barkpark between the load above and this line, cascading this
  # site away — is a 500 either way: it was `Repo.delete` raising
  # `Ecto.StaleEntryError` before, it is `teardown/2`'s function clause now.
  delete "/v1/sites/:id" do
    with_team_site(conn, {:ability, "write"}, fn conn, site ->
      # THE AUDIT IS THE GATE, AND IT RUNS FIRST — the standing ruling on the
      # `record_audit` discard class, applied to the one route where the row is
      # the ONLY thing that survives the act it describes. `delete_site/1` is a
      # hard `Repo.delete`, so once this request finishes nothing in this
      # database can say the site existed or who removed it.
      #
      # It cannot be the transactional `Accounts.audit/3` the twenty-eight other
      # fail-closed writes use, and the reason is ORDERING, not taste: the box
      # teardown below is an outbound call that `Repo.rollback` cannot undo. An
      # `audit/3` wrapper around `delete_site/1` would refuse the registration
      # delete with the Caddy route already disarmed and the tree already gone —
      # a site row pointing at a dead box, the exact inverse orphan the
      # box-first ordering and the typed `registration_not_removed` 500 exist to
      # prevent. So the gate moves EARLIER instead of wrapping: record the row
      # BEFORE anything is torn down, and on a refused insert answer the same
      # 422 shape the `barkpark.deleted` twin answers with NOTHING touched — no
      # teardown, no delete, no orphan of either polarity.
      #
      # TWO COSTS, NAMED RATHER THAN DISCOVERED LATER.
      #
      # (1) The row now describes an INTENT, so it can outlive a delete that
      # then fails. A refused teardown (a box that is down — routine, and the
      # relay arms below exist for it) leaves a `site.deleted` row for a site
      # that is still registered and still serving. That is the lesser evil the
      # ruling accepts: a trail that occasionally over-reports a removal is
      # recoverable, a removal with no trail at all is not. The arms are pinned
      # by `router_sites_test.exs` so the over-report is a DECISION on the
      # record, not a surprise.
      #
      # (2) The metadata can no longer carry `read_token`. That fact is the
      # OUTCOME of `revoke_site_read_token/1`, which happens inside
      # `delete_site/1` — it does not exist yet at this point in the request and
      # `audit_events` is append-only, so there is no second write to add it.
      # The 200 body below still reports it to the caller, and
      # `Mix.Tasks.BarkparkCloud.SiteReadTokens` is the sweep that finds a
      # credential nobody confirmed dead.
      audit_attrs = %{
        team_id: site.team_id,
        actor_user_id: conn.assigns.current_user.id,
        action: "site.deleted",
        target_type: "site",
        target_id: site.id,
        metadata: %{slug: site.slug, kind: site.kind}
      }

      case Accounts.record_audit(audit_attrs) do
        {:error, %Ecto.Changeset{} = cs} ->
          json(conn, 422, %{error: "invalid", details: errors(cs)})

        {:ok, _event} ->
          push_event(site.team_id, "audit")
          delete_site_after_audit(conn, site)
      end
    end)
  end

  # The act half of `DELETE /v1/sites/:id`, reached ONLY once the audit row is
  # committed. Split out so the route above reads as gate-then-act rather than
  # as five levels of nesting.
  defp delete_site_after_audit(conn, site) do
    bp = Registry.get_barkpark(site.barkpark_id)
    teardown_result = Sites.Deploy.teardown(site, bp)

    case teardown_result do
      :ok ->
        # THE INVERSE ORPHAN, NOW TYPED (W70 S2 / D848, D856 — supersedes the
        # W67 S2 / D820 hard match). `Registry.delete_site/1` is a bare
        # `Repo.delete` on a struct with no declared constraint, so every child
        # row is swept by the DATABASE. Three FKs reference `sites`
        # (deployments, site_artifacts, content_publishes) and all three are ON
        # DELETE CASCADE. If one were ever loosened to RESTRICT, `Repo.delete`
        # RAISES `Ecto.ConstraintError` — AFTER the box teardown above already
        # disarmed the Caddy route, so the box is gone and the site row SURVIVES:
        # a dead site that is still registered. Under the old hard match that
        # raise became `handle_errors`' `500 {"error":"server_error"}` with no
        # `ok`, no `detail`, and no name for either half of the outcome. That
        # was rejected as a lie by omission: the answer measured TWO facts (the
        # instance IS torn down; the registration was NOT removed) and stated
        # neither. `delete_site/1` now RESCUES the foreign_key case and returns
        # `{:error, :foreign_key_constraint, constraint}`, so the nested case
        # below answers a typed `500 registration_not_removed` whose detail
        # names the blocking constraint and BOTH halves. It is still a 500 — the
        # box being already gone means neither retry nor refuse is true, and a
        # human (support) must remove the surviving row — but it is an HONEST
        # 500 the console and CLI can read. The tripwire that keeps the branch
        # from silently regressing is `site_cascade_census_test.exs` (an
        # EXACT-SET census of the FKs referencing `sites` plus their confdeltype)
        # backed by per-child delete-path tests in `router_sites_test.exs` and
        # the behavioural 500 in `router_sites_destroy_failures_test.exs`.
        #
        # NB: the sibling `{:error, status, detail, code}` relay arm below
        # matches `teardown_result` (the box seam), NOT this delete — it is
        # unreachable from inside `:ok`, which is why the delete's own failure
        # needs this nested case rather than a fourth outer arm.
        case Registry.delete_site(site) do
          {:ok, _, %{read_token: read_token}} ->
            # The `site.deleted` row is ALREADY COMMITTED — it gated this
            # branch. Nothing is recorded here.
            push_event(site.team_id, "sites")

            # ssw8 — DO NOT CLAIM A CLEAN TEARDOWN THE BOX DID NOT CONFIRM.
            # The delete succeeded either way (the CP row is the truth, and a
            # box that is down must not make its sites undeletable), but the
            # 200 states which of the two happened. On `:error` it also NAMES
            # the leftover, because this response is the last place the pointer
            # exists: the site row that carried the box, the workspace scope and
            # the slug has just been deleted. `Mix.Tasks.BarkparkCloud.SiteReadTokens`
            # is the sweep that finds it again if this line is missed.
            body = %{
              ok: true,
              status: "deleted",
              slug: site.slug,
              read_token: read_token_status(read_token)
            }

            json(conn, 200, site_delete_token_warning(body, site, read_token))

          {:error, :foreign_key_constraint, constraint} ->
            json(conn, 500, %{
              ok: false,
              error: "registration_not_removed",
              detail:
                "the instance was torn down, but the registration could not be removed: deleting " <>
                  "the site row was refused by the foreign-key constraint #{constraint}. The site " <>
                  "is no longer serving, yet it is still registered here — support must remove the " <>
                  "row by hand. This is not something a retry can fix."
            })
        end

      # Same typed relay as the rollback route (cch-w63-s3 / D763). THE
      # DEFERRAL IS OVER: the console gained its site-delete flow — and the
      # reader for these two arms — in W67 S1
      # (cch-w63-bl-teardown-failed-has-no-console-reader-at-all, cloud/priv/static
      # only). Until then `teardown_failed` had ZERO readers in `app.js` and no
      # console caller could even reach this route, so the refusal had no human
      # surface at all. The wire shape below is unchanged by that slice; this
      # comment is edited here because S2 owns router.ex this wave.
      {:error, status, detail, code} ->
        json(conn, status, %{ok: false, error: code, detail: detail})

      {:error, status, detail} ->
        json(conn, status, %{ok: false, error: "teardown_failed", detail: detail})
    end
  end

  # POST /v1/sites/:id/deploy {git_ref?, artifact_url?} → 201 {deployment}.
  # Enqueues a Deployment with status:"queued"; the off-box builder (P2) polls
  # for queued rows and walks them through building → pushing → live.
  #
  # site-spawner D30: KIND-BRANCHED. A STATIC site builds from CONTENT, not from
  # an artifact or a repo — `deploy_static_site/2` mints the build and drives the
  # box through the six stages. The container path below is untouched.
  post "/v1/sites/:id/deploy" do
    with_team_site(conn, {:ability, "write"}, fn conn, site ->
      # cf-in-front (D57): when a deploy asks to go THROUGH Cloudflare
      # (via=cloudflare + a domain), resolve the team's CF credential, point the
      # domain at the box origin, flip the record proxied, and persist the
      # binding — all BEFORE the normal build. With no `via` this is a pure
      # no-op: the standalone deploy path below is byte-identical to today. A
      # missing/unreadable CF provider fails closed here and NEVER half-binds.
      with {:cont, site} <- maybe_bind_cloudflare(conn, site) do
        cond do
          # site-spawner W7 (charter D62): a NODE site is content-bound just like a
          # static one — it builds FROM a Barkpark dataset and is driven through the
          # SAME six-stage deploy machine (`deploy_static_site/2` mints the build and
          # drives PLAN→BUILD→STAGE→HEALTH→SWITCH→RETIRE). The only difference is the
          # runtime target the box switches to (a running node process vs a symlink),
          # which the deploy_payload carries down — not this route's concern. The
          # container artifact/repo path below is NOT taken.
          site.kind in ["static", "node"] ->
            deploy_static_site(conn, site)

          # dwb-webhook-deploy-artifact-gap: a deploy with NO artifact AND NO
          # connected repo can never build regardless of fleet — the row would sit
          # "queued" forever as an eternal dashboard spinner. Refuse it up front so
          # no un-buildable row is ever minted.
          is_nil(conn.body_params["artifact_url"]) and is_nil(site.github_repo) ->
            json(conn, 422, %{
              error: "no_build_source",
              detail: "upload an artifact (bp deploy) or connect a GitHub repo"
            })

          true ->
            attrs = %{
              git_ref: conn.body_params["git_ref"],
              artifact_url: conn.body_params["artifact_url"]
            }

            # manual-deploy-no-dedup: a double-click or client retry must not mint a
            # duplicate queued build. When a git_ref is present, coalesce onto any
            # already-active (queued|building|pushing) PRODUCTION deploy of this
            # exact ref and 200 the existing row — the same "active" definition the
            # GitHub webhook path (handle_production_push) uses via
            # find_active_deployment/2. An artifact-only deploy (no ref) can't be
            # coalesced and always mints a fresh row.
            existing =
              case attrs.git_ref do
                ref when is_binary(ref) -> Registry.find_active_deployment(site.id, ref)
                _ -> nil
              end

            case existing do
              %{} = deployment ->
                json(conn, 200, %{deployment: deployment_json(deployment)})

              nil ->
                case Registry.create_deployment(site, attrs) do
                  {:ok, deployment} ->
                    # activity-audit-log: a deploy request ENQUEUES a queued row the
                    # off-box builder later walks — a relay, so the audit is a
                    # post-commit best-effort record_audit/1 (never rolls the queued
                    # row back). Only a FRESHLY minted row is audited; a coalesced /
                    # lost-race 200 re-uses an existing row and stamps nothing (no
                    # double-audit on a double-click). Detail carries git_ref + whether
                    # an artifact was supplied, never the artifact bytes.
                    case Accounts.record_audit(%{
                           team_id: site.team_id,
                           actor_user_id: conn.assigns.current_user.id,
                           action: "site.deploy_requested",
                           target_type: "deployment",
                           target_id: deployment.id,
                           metadata: %{
                             site_id: site.id,
                             git_ref: attrs.git_ref,
                             has_artifact: not is_nil(attrs.artifact_url)
                           }
                         }) do
                      {:ok, _event} ->
                        push_event(site.team_id, "audit")

                      {:error, cs} ->
                        Logger.error("audit site.deploy_requested failed: #{inspect(cs)}")
                    end

                    push_event(site.team_id, "deployments")
                    json(conn, 201, %{deployment: deployment_json(deployment)})

                  {:error, %Ecto.Changeset{errors: errs} = cs} ->
                    # A lost race: a concurrent double-click won the active
                    # site+ref partial-unique index between our lookup and this
                    # INSERT. Recover its row as a 200 duplicate rather than
                    # surfacing the constraint error (mirrors the webhook path).
                    winner =
                      if is_binary(attrs.git_ref) and Keyword.has_key?(errs, :git_ref) do
                        Registry.find_active_deployment(site.id, attrs.git_ref)
                      end

                    case winner do
                      %{} = deployment ->
                        json(conn, 200, %{deployment: deployment_json(deployment)})

                      _ ->
                        json(conn, 422, %{error: "invalid", details: errors(cs)})
                    end
                end
            end
        end
      else
        # maybe_bind_cloudflare already sent the fail-closed response (409/422/502).
        {:halt, conn} -> conn
      end
    end)
  end

  # GET /v1/sites/:id/deployments → 200 {deployments: [...], next_cursor} newest
  # first. Bounded by ?limit= (default 100, capped at 200) — a busy repo accrues
  # one Deployment row per push plus duplicates on redelivery, so newest-first +
  # cap returns exactly the rows a dashboard poll needs.
  #
  # deploy-reliability W1 S2: and by ?before=<next_cursor> for everything BEHIND
  # that cap. `Registry.list_deployments/3` has no offset clause, so `offset`,
  # `page` and `cursor` were all silently ignored — `?offset=200` returned the
  # byte-identical first row — and on the five hot sites 200 rows is a 51-hour
  # window, i.e. nothing outside the database could audit the ledger's own
  # numbers. `DeployLedger.list_page/2` is a KEYSET read on
  # (inserted_at, id) DESC, so a row inserted mid-pagination cannot duplicate or
  # skip a later page the way an offset would. An unparseable cursor is a 422,
  # never a silent page one.
  get "/v1/sites/:id/deployments" do
    with_team_site(conn, fn site ->
      limit = parse_limit(conn.query_params["limit"], 100, 200)

      # gh-6: production-only — branch previews are surfaced distinctly at
      # GET /v1/sites/:id/previews so the dashboard keeps the two apart.
      opts = [
        limit: limit,
        environment: "production",
        before: conn.query_params["before"] || conn.query_params["cursor"]
      ]

      case DeployLedger.list_page(site, opts) do
        {:ok, %{deployments: deployments, next_cursor: next_cursor}} ->
          json(conn, 200, %{
            deployments: Enum.map(deployments, &deployment_json/1),
            next_cursor: next_cursor
          })

        {:error, :invalid_cursor} ->
          json(conn, 422, %{
            error: "invalid_cursor",
            detail: "before must be a next_cursor returned by a previous page"
          })
      end
    end)
  end

  # GET /v1/sites/:id/deployments/:dep_id → 200 {deployment} — the STAGE-AWARE
  # poll `bp cloud site deploy` streams and `bp cloud site status` reads
  # (site-spawner D30).
  #
  # The response shape is the CLI's contract, not a suggestion: it decodes
  # `{"deployment": {…, "stages": [{"name","status",…}]}}` and prints a stage line
  # ONLY for a per-stage status of `done` | `failed` | `skipped`. Every mismatch
  # here is a SILENT failure — the six-stage bar simply renders empty and the user
  # watches a spinner that never says anything. A wrong-site / nonexistent /
  # non-UUID dep_id is the same 404 as a wrong-team site (existence-leak
  # protection).
  get "/v1/sites/:id/deployments/:dep_id" do
    with_team_site(conn, {:ability, "read"}, fn site ->
      case Registry.get_deployment(conn.path_params["dep_id"]) do
        %Registry.Deployment{site_id: sid} = d when sid == site.id ->
          bp = Registry.get_barkpark(site.barkpark_id)
          json(conn, 200, %{deployment: site_deployment_json(d, site, bp)})

        _ ->
          json(conn, 404, %{error: "not_found"})
      end
    end)
  end

  # POST /v1/sites/:id/rollback → 200 {ok, status, deployment_id,
  # previous_deployment_id, url} — the sub-second symlink flip back to the previous
  # release (charter D5, site-spawner D30).
  #
  # THREE things about this route are load-bearing, and each one is a lie if it's
  # wrong:
  #
  #   * The body is FLAT, never enveloped. Wrap it as {"deployment": …} and Go's
  #     decoder silently leaves every field at its zero value — the CLI still
  #     prints "✓ site rolled back", naming no build, and nothing anywhere errors.
  #   * It BLOCKS on the real on-box flip. There is no client-side poll for
  #     rollback; if this answered before the symlink moved, "sub-second rollback"
  #     would be a vacuous green baked into the wire.
  #   * A rollback that CANNOT happen answers non-2xx. The CLI gates success on the
  #     HTTP status ALONE (it never reads `ok`), so a 200 with ok:false would print
  #     a checkmark for a rollback that never occurred.
  #
  # It invokes site-deploy.sh --rollback on the box — never Deployment.promotion_attrs,
  # which is promote-by-NEW-deployment (charter D5: seconds-to-minutes, and a
  # rebuild of content that may since have changed). Container sites keep the
  # promote route; rollback is the static verb.
  post "/v1/sites/:id/rollback" do
    with_team_site(conn, {:ability, "write"}, fn conn, site ->
      cond do
        # site-spawner W7 (charter D67): a NODE site rolls back the SAME way a
        # static one does — instantly, by flipping the Caddy upstream back to the
        # previous slot's still-running node process (no rebuild). Container sites
        # keep the promote verb; static AND node both get the sub-second flip.
        site.kind not in ["static", "node"] ->
          json(conn, 422, %{
            error: "not_rollbackable",
            detail:
              "instant rollback is a static-site verb — redeploy a container site's previous build with `bp sites promote`"
          })

        is_nil(Registry.get_barkpark(site.barkpark_id)) ->
          json(conn, 404, %{error: "not_found"})

        true ->
          bp = Registry.get_barkpark(site.barkpark_id)

          case Sites.Deploy.rollback(site, bp) do
            {:ok, result} ->
              case Accounts.record_audit(%{
                     team_id: site.team_id,
                     actor_user_id: conn.assigns.current_user.id,
                     action: "site.rolled_back",
                     target_type: "site",
                     target_id: site.id,
                     metadata: %{
                       deployment_id: result.deployment_id,
                       previous_deployment_id: result.previous_deployment_id
                     }
                   }) do
                {:ok, _event} -> push_event(site.team_id, "audit")
                {:error, cs} -> Logger.error("audit site.rolled_back failed: #{inspect(cs)}")
              end

              push_event(site.team_id, "deployments")

              json(conn, 200, %{
                ok: true,
                status: "rolled_back",
                deployment_id: result.deployment_id,
                previous_deployment_id: result.previous_deployment_id,
                url: result.url
              })

            # A TYPED refusal (cch-w63-s3 / D763): the plane measured WHICH refusal
            # this is, so the wire carries that word instead of the flat
            # `rollback_failed` this route stamps on every other error status —
            # which is the reason the console cannot classify a site rollback
            # failure at all. The STATUS still comes from `Sites.Deploy`; this
            # route only relays it.
            {:error, status, detail, code} ->
              json(conn, status, %{ok: false, error: code, detail: detail})

            {:error, status, detail} ->
              json(conn, status, %{ok: false, error: "rollback_failed", detail: detail})
          end
      end
    end)
  end

  # POST /v1/sites/:id/deployments/:dep_id/promote → 201 {deployment}.
  #
  # Rollback/redeploy as a control-plane primitive (charter decision 7). This is
  # promote-by-NEW-deployment, NEVER a `sites.current_deployment_id` pointer flip:
  # the source deployment's already-built artifact (git_ref + artifact_url) is
  # pinned onto a FRESH queued production Deployment that rides the same fenced
  # builder → agent pipeline as a normal deploy. The live pointer stays
  # agent-owned — the on-box agent flips it once the new row reaches `live`, and
  # the previously-live deployment stays terminal-`live` (eligibility keys on the
  # environment, not on the pointer). Promoting a redeploy of the current artifact
  # IS a redeploy; promoting an OLDER artifact IS a rollback — one primitive.
  #
  # A branch PREVIEW is not promotable (it answers on its own host, never the
  # production slot) → 422 not_promotable. A source with no artifact and a site
  # with no connected repo has nothing to rebuild from → 422 no_build_source
  # (parity with POST /deploy). A build already in flight at this git_ref (the
  # production active-ref unique index) → 409 build_in_progress. A wrong-site /
  # nonexistent / non-UUID dep_id → 404 (existence-leak protection, same shape as
  # a wrong-team site). The mint + a `deployment.promoted` audit row commit
  # atomically; both `deployments` and `audit` SSE invalidations fire (no new
  # event type — decision 2).
  post "/v1/sites/:id/deployments/:dep_id/promote" do
    # Inline auth (not with_team_site) so the audit row has the acting user —
    # with_team_site's closure only receives the site, not the authed conn.
    conn = conn |> Auth.require_user_or_pat([]) |> Auth.require_ability("write")

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.get_team_site(conn.assigns.current_team, conn.path_params["id"]) do
          %Registry.Site{} = site -> promote_deployment(conn, site)
          nil -> json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # GET /v1/sites/:id/previews → 200 {previews: [...]} — gh-6 branch previews,
  # one row per branch (the latest push), newest first. Each carries its branch,
  # preview_host (the URL), status, and live build console (the #815 standard).
  # Cancelled/failed-only branches (torn down / evicted) are omitted.
  get "/v1/sites/:id/previews" do
    with_team_site(conn, fn site ->
      previews = Registry.list_preview_deployments(site)
      json(conn, 200, %{previews: Enum.map(previews, &deployment_json/1)})
    end)
  end

  # POST /v1/sites/:id/artifact — RETIRED (site-spawner W10). No replacement at
  # this path: the DEPLOYMENT-scoped route below is the whole artifact plane.
  #
  # It was not deprecated for tidiness, it was broken by construction. The route
  # inserted a `SiteArtifact` carrying a `site_id` and NO `deployment_id`, while
  # the only read (`Sites.Deploy.artifact_for/1`) and the only delete
  # (`Sites.Deploy.drop_artifact/1`) BOTH key on `deployment_id`, and nothing ever
  # backfilled it. So every row it created was unreadable AND unreapable: a
  # permanent up-to-32 MB bytea on `cloud_pgdata`, the control plane's only
  # durable volume, in flat contradiction of the read-once-then-drop lifecycle
  # `Registry.SiteArtifact`'s own moduledoc documents.
  #
  # Nothing consumed it, either. `POST /v1/sites/:id/deploy` kind-branches to
  # `deploy_static_site/2` BEFORE it ever reads `artifact_url`, so for every site
  # this epic serves the tarball was never opened — which made `bp deploy`'s
  # default no-flag path a guaranteed orphan insert. Prod agreed: 0 rows in
  # `site_artifacts`, and 0 audit rows with `target_type: "site"` across four
  # weeks while the deployment-scoped sibling's rows prove the audit fires at all.
  #
  # The lane that replaces it binds bytes to a deployment at INSERT — mint
  # (`POST /v1/sites/:id/deploy {"source": "prebuilt"}`) → upload (below) → drive
  # → drop — so they can always be found and always be reaped.
  # `bp cloud site deploy <site> --prebuilt ./dist` speaks it end to end.

  # POST /v1/sites/:id/deployments/:dep_id/artifact (application/octet-stream)
  # → 201 {deployment, artifact_sha256, bytes} — the UPLOAD half of
  # mint-then-upload (charter D86/D91).
  #
  # The prebuilt deploy route minted this row and deliberately did NOT start it:
  # the caller needed `build_id` (baked into the bytes) and `content_rev` before
  # it could build. This route takes the resulting tarball, records its digest,
  # and only THEN hands the row to the driver — so a deployment can never be in
  # flight while the control plane cannot say which bytes it is serving.
  #
  # Honest states, each its own answer:
  #
  #   * a box-build row → 422 not_prebuilt (nothing would ever read the bytes)
  #   * a row that already left `queued` → 409 (the build is gone; mint another)
  #   * the SAME digest again → 200 no-op, driver NOT restarted (a client retry
  #     after a dropped response must not run the deploy twice)
  #   * a DIFFERENT digest → 409 artifact_conflict (silently swapping the bytes
  #     under a build_id that is already baked would be a lie about what is live)
  post "/v1/sites/:id/deployments/:dep_id/artifact" do
    with_team_site(conn, {:ability, "write"}, fn conn, site ->
      case Registry.get_deployment(conn.path_params["dep_id"]) do
        %Registry.Deployment{site_id: sid} = deployment when sid == site.id ->
          upload_deployment_artifact(conn, site, deployment)

        # Wrong-site / nonexistent / non-UUID — the same 404 a wrong-team site
        # gets (existence-leak protection).
        _ ->
          json(conn, 404, %{error: "not_found"})
      end
    end)
  end

  # POST /v1/sites/:id/env {env: {...}} → 200 {ok: true}. Replaces the whole
  # encrypted env blob (Vault.encrypt-stored, never echoed back).
  post "/v1/sites/:id/env" do
    with_team_site(conn, fn conn, site ->
      env = conn.body_params["env"]

      cond do
        not is_map(env) ->
          json(conn, 422, %{error: "env_required"})

        true ->
          # activity-audit-log: the env-blob update + a `site.env_changed` audit
          # event commit atomically. Detail records only the KEY NAMES of the env
          # map — NEVER the values (the whole blob is Vault-encrypted at rest).
          audited =
            Accounts.audit(
              %{
                team_id: site.team_id,
                actor_user_id: conn.assigns.current_user.id,
                action: "site.env_changed",
                target_type: "site",
                target_id: site.id,
                metadata: %{site_id: site.id, keys: Map.keys(env)}
              },
              fn -> Registry.set_site_env(site, env) end
            )

          case audited do
            {:ok, _} ->
              push_event(site.team_id, "audit")
              json(conn, 200, %{ok: true})

            {:error, cs} ->
              json(conn, 422, %{error: "invalid", details: errors(cs)})
          end
      end
    end)
  end

  # POST /v1/sites/:id/domains {domain} → 200 {site}. Adds the domain to the
  # site's array; the domain becomes acceptable to the on-demand-TLS ask-gate.
  post "/v1/sites/:id/domains" do
    with_team_site(conn, fn conn, site ->
      domain = conn.body_params["domain"]

      cond do
        not is_binary(domain) or domain == "" ->
          json(conn, 422, %{error: "domain_required"})

        true ->
          # activity-audit-log: the domain-array update + a `site.domain_added`
          # audit event commit atomically. Detail carries the domain (a public
          # hostname, not a secret). A cross-site collision rolls back with NO row.
          audited =
            Accounts.audit(
              %{
                team_id: site.team_id,
                actor_user_id: conn.assigns.current_user.id,
                action: "site.domain_added",
                target_type: "site",
                target_id: site.id,
                metadata: %{site_id: site.id, domain: domain}
              },
              fn -> Registry.add_site_domain(site, domain) end
            )

          case audited do
            {:ok, site} ->
              push_event(site.team_id, "audit")
              json(conn, 200, %{site: site_json(site)})

            # Cross-team collision guard: a domain owned by another site is a
            # conflict, not a validation error — 409, never a 200 the ask-gate
            # would honor for two owners (domain-takeover guard).
            {:error, :domain_taken} ->
              json(conn, 409, %{error: "domain_taken"})

            {:error, cs} ->
              json(conn, 422, %{error: "invalid", details: errors(cs)})
          end
      end
    end)
  end

  # DELETE /v1/sites/:id/domains {domain} → 200 {site}. The inverse of the POST
  # above, and the reason it had to exist: a hostname written into a site's
  # `domains` array could not be taken back over HTTP AT ALL. `PATCH
  # /v1/sites/:id` touches only theme/doc_type/prebuilt_enabled, and
  # `Registry.remove_site_domain/2` had zero router callers — so freeing a
  # wrongly-claimed name meant deleting the whole site, and a name claimed across
  # a team boundary could not be freed by its rightful owner at all.
  #
  # TIER, chosen deliberately: `user`, the same guard its inverse runs
  # (`with_team_site/3`'s `:session` default = `Auth.require_user/2`, team-scoped
  # site lookup, no role check). Releasing a name must never be HARDER than
  # claiming it — an `admin` wall here would recreate, at the role level, exactly
  # the "no way back" this route closes, and would sit oddly beside `DELETE
  # /v1/sites/:id`, which lets the same member destroy the entire site. Scope is
  # unchanged from every other site route: only the team that HOLDS the name can
  # release it.
  delete "/v1/sites/:id/domains" do
    with_team_site(conn, fn conn, site ->
      domain = conn.body_params["domain"]

      cond do
        not is_binary(domain) or domain == "" ->
          json(conn, 422, %{error: "domain_required"})

        true ->
          # activity-audit-log: the domain-array update + a `site.domain_removed`
          # audit event commit atomically, exactly as the add side does. Releasing
          # a hostname is precisely the act an audit register exists to record.
          audited =
            Accounts.audit(
              %{
                team_id: site.team_id,
                actor_user_id: conn.assigns.current_user.id,
                action: "site.domain_removed",
                target_type: "site",
                target_id: site.id,
                metadata: %{site_id: site.id, domain: domain}
              },
              fn -> Registry.remove_site_domain(site, domain) end
            )

          case audited do
            {:ok, site} ->
              push_event(site.team_id, "audit")
              json(conn, 200, %{site: site_json(site)})

            {:error, cs} ->
              json(conn, 422, %{error: "invalid", details: errors(cs)})
          end
      end
    end)
  end

  # POST /v1/sites/:id/github {repo, branch?, webhook_secret?} → 200
  # {webhook_url, webhook_secret, site}.
  #
  # Link a GitHub repo + branch to this Site so pushes to <branch> of <repo>
  # auto-create a Deployment (verified via HMAC-SHA256 against the stored
  # secret). `repo` is the "owner/repo" form GitHub uses. `branch` defaults to
  # "main" on the server. The webhook secret is the value the user will paste
  # into GitHub's webhook "Secret" field. The SERVER always mints it — a
  # `webhook_secret` in the request body is ignored — and returns it ONCE in
  # this response (it is Vault-encrypted at rest and never returned again).
  #
  # The caller does not choose it because the secret is the HMAC key for
  # POST /v1/webhooks/github/:site_id, a route with no bearer auth by design
  # where the HMAC + the opaque site UUID are the only gates. A caller-chosen
  # key is a durable deploy trigger that is not team-scoped, not session-tied,
  # not revoked when the actor loses access, and not visible in the audit log.
  # This matches /github/connect, which has always minted unconditionally.
  #
  # RBAC: binding a repo is a capability action -> TEAM ADMIN only, the same tier
  # /github/connect and DELETE /v1/sites/:id/github already enforce. The three
  # doors reach one outcome — the team's production site builds and serves code
  # the caller chose — so a member-open create against an admin-only delete let
  # the weaker principal mint state only the stronger one could clear (and
  # OVERWRITE an admin-established link, rotating its secret, in the same call).
  # That connect spends the team's GitHub App credential and this route does not
  # bounds what CONNECT may do; it never bounded what the member may achieve.
  post "/v1/sites/:id/github" do
    with_team_site(conn, :team_admin, fn conn, site ->
      repo = conn.body_params["repo"]
      branch = conn.body_params["branch"]

      cond do
        not (is_binary(repo) and repo != "") ->
          json(conn, 422, %{error: "repo_required"})

        true ->
          # The server mints the secret, always — a caller-supplied
          # `webhook_secret` is ignored. Echo the plaintext BACK in the success
          # response (this is the ONLY moment plaintext leaves the server) so
          # the user can paste it into GitHub's webhook form.
          plaintext_secret = generate_webhook_secret()

          # activity-audit-log: the repo/branch/secret link update + a
          # `site.github_connected` audit event commit atomically. Detail carries
          # the repo + branch (public references) — NEVER the webhook secret.
          audited =
            Accounts.audit(
              %{
                team_id: site.team_id,
                actor_user_id: conn.assigns.current_user.id,
                action: "site.github_connected",
                target_type: "site",
                target_id: site.id,
                metadata: %{site_id: site.id, repo: repo, branch: branch || "main"}
              },
              fn -> Registry.set_site_github(site, repo, branch, plaintext_secret) end
            )

          case audited do
            {:ok, updated} ->
              push_event(site.team_id, "audit")

              json(conn, 200, %{
                site: site_json(updated),
                webhook_url: webhook_url_for(conn, updated.id),
                webhook_secret: plaintext_secret
              })

            {:error, cs} ->
              json(conn, 422, %{error: "invalid", details: errors(cs)})
          end
      end
    end)
  end

  # POST /v1/sites/:id/github/connect {repo_full_name, branch?} → 200
  # {site, webhook_url, repo_full_name, branch}.
  #
  # The Vercel "Import Git Repository" moment (gh-4). Unlike the manual
  # POST /v1/sites/:id/github (user pastes the secret into GitHub by hand), this
  # does the whole handshake server-side:
  #   1. Validates the repo belongs to the TEAM'S GitHub App installation (a
  #      caller cannot wire a webhook onto a repo it doesn't control).
  #   2. Generates a fresh inbound webhook secret.
  #   3. Registers the push webhook ON GITHUB via the seam — events: push; url:
  #      this site's inbound POST /v1/webhooks/github/:site_id endpoint.
  #   4. Persists the repo+branch+secret link (secret Vault-encrypted at rest).
  # The registered secret is EXACTLY the one the inbound handler verifies.
  #
  # Idempotent: re-connecting the same repo→site replaces the same hook (no
  # duplicate registration) and rotates the secret. RBAC: registering a webhook
  # is a capability action → team admin only (parity with the installation
  # connect). Honest errors: 503 feature_not_configured, 409 no_installation,
  # 422 repo_not_in_installation / repo_full_name_required, 404 wrong-team site.
  post "/v1/sites/:id/github/connect" do
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      not GitHub.configured?() ->
        json(conn, 503, %{error: "feature_not_configured"})

      true ->
        team = conn.assigns.current_team

        case Registry.get_team_site(team, conn.path_params["id"]) do
          nil ->
            json(conn, 404, %{error: "not_found"})

          %Registry.Site{} = site ->
            connect_site_github(conn, team, site)
        end
    end
  end

  # DELETE /v1/sites/:id/github → 200 {site} — disconnect a Site's GitHub link
  # (drops repo/branch/secret; the webhook on GitHub's side is left for the user
  # to remove there — its deliveries simply stop deploying once the secret is
  # gone). Team admin only, team-scoped, 404 on a wrong-team site.
  delete "/v1/sites/:id/github" do
    conn = Auth.require_team_admin(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.get_team_site(conn.assigns.current_team, conn.path_params["id"]) do
          nil ->
            json(conn, 404, %{error: "not_found"})

          %Registry.Site{} = site ->
            # activity-audit-log: the link-clear + a `site.github_disconnected`
            # audit event commit atomically (repo reference only, no secret).
            {:ok, updated} =
              Accounts.audit(
                %{
                  team_id: site.team_id,
                  actor_user_id: conn.assigns.current_user.id,
                  action: "site.github_disconnected",
                  target_type: "site",
                  target_id: site.id,
                  metadata: %{site_id: site.id, repo: site.github_repo}
                },
                fn -> Registry.clear_site_github(site) end
              )

            push_event(conn.assigns.current_team.id, "sites")
            push_event(conn.assigns.current_team.id, "audit")
            json(conn, 200, %{site: site_json(updated)})
        end
    end
  end

  # POST /v1/webhooks/github/:site_id  — NO bearer auth (verified via HMAC).
  #
  # GitHub POSTs a push event here; the route:
  #   1. Looks up the Site by id (404 silently when missing or not configured).
  #   2. Verifies X-Hub-Signature-256 (HMAC-SHA256 over the raw body) against
  #      the Vault-decrypted webhook secret — CONSTANT-TIME compare. 401 on bad
  #      sig (no detail; do not help an attacker tune their guesses).
  #   3. Only ACTS on `X-GitHub-Event: push`. Other events (ping, pull_request,
  #      …) are acknowledged 200 with `ignored:true` so GitHub stops retrying.
  #   4. Compares the pushed ref (`refs/heads/<branch>`) to the Site's
  #      configured branch — a push to a different branch is a no-op 200
  #      `{ignored: true, reason: "branch_mismatch"}`.
  #   5. Creates a Deployment with `git_ref = <pushed sha>`. Returns 201
  #      `{deployment_id, sha, branch}`.
  #
  # This route is OUTSIDE the team-auth path on purpose: a webhook fires before
  # any user is logged in. The HMAC + the opaque site UUID are the only gates.
  post "/v1/webhooks/github/:site_id" do
    site_id = conn.path_params["site_id"]
    site = Registry.get_site(site_id)

    cond do
      is_nil(site) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.reveal_site_github_secret(site) do
          {:ok, nil} ->
            # No webhook configured — same shape as "not found" so a probe
            # cannot distinguish unconfigured from nonexistent.
            json(conn, 404, %{error: "not_found"})

          :error ->
            json(conn, 500, %{error: "secret_unreadable"})

          {:ok, secret} when is_binary(secret) ->
            raw = raw_request_body(conn)
            sig = get_first_header(conn, "x-hub-signature-256")

            if verify_github_signature(raw, secret, sig) do
              handle_verified_github_push(conn, site)
            else
              json(conn, 401, %{error: "bad_signature"})
            end
        end
    end
  end

  # POST /v1/sites/webhooks/content-publish/:site_id — NO bearer auth (HMAC IS the
  # auth). site-spawner W5 (charter D45/D46): the publish-to-live receiver.
  #
  # The box fires this off a content publish/unpublish/delete on the site's bound
  # dataset (the box's existing Webhooks.Dispatcher delivers one signed POST per
  # registered webhook row, each to its own :site_id endpoint — the fan-out is
  # free, the routing is exact). The route:
  #   1. Loads the Site by id (404 silently when missing or unconfigured).
  #   2. Verifies x-barkpark-signature (`t=<unix>,v1=<hex>` = HMAC-SHA256 over
  #      "<t>.<raw-body>", ±300s) against the site's own stored secret — a
  #      StripeGateway-clone scheme, NOT the GitHub sha256= scheme. 401 on a bad
  #      OR expired signature (no detail — don't help an attacker tune guesses).
  #   3. On a valid delivery, enqueues the DEBOUNCED AutoDeployWorker for THIS
  #      site (a burst coalesces to one rebuild; a publish mid-build mints one
  #      trailing rebuild) and answers 202.
  #
  # Per-site (not per-dataset) on purpose (charter D45): (workspace,project,dataset)
  # is NOT unique across the sites table, so a dataset→sites resolver would
  # cross-trigger two boxes sharing default slugs; :site_id is the PK, unambiguous.
  post "/v1/sites/webhooks/content-publish/:site_id" do
    site_id = conn.path_params["site_id"]
    site = Registry.get_site(site_id)

    cond do
      is_nil(site) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.reveal_site_content_secret(site) do
          {:ok, nil} ->
            # No content webhook configured — same shape as "not found" so a probe
            # cannot distinguish unconfigured from nonexistent.
            json(conn, 404, %{error: "not_found"})

          :error ->
            json(conn, 500, %{error: "secret_unreadable"})

          {:ok, secret} when is_binary(secret) ->
            raw = raw_request_body(conn)
            sig = get_first_header(conn, "x-barkpark-signature")

            case Webhooks.InboundSignature.verify(raw, sig, [secret]) do
              :ok ->
                # THE PUBLISH INSTANT (deploy-reliability D162). Stamped HERE, before
                # the enqueue, because the enqueue's own clock is ≥60s late (D44) and
                # is ABSENT entirely when the rebuild coalesces. This row is the only
                # record of a publish that mints no deployment. Best-effort by
                # construction: `record_content_publish/2` swallows everything, so
                # the 202 below is byte-identical whether or not it landed.
                publish = record_content_publish(site, raw)

                # Debounced (charter D44): N publishes in the window = ONE rebuild.
                enqueue_result = Sites.AutoDeployWorker.enqueue(site.id)
                _ = Registry.ContentPublish.mark_enqueued(publish, enqueue_result)
                json(conn, 202, %{ok: true, trigger: "content-auto"})

              {:error, _reason} ->
                # A bad OR expired signature is the same 401 — never leak which.
                json(conn, 401, %{error: "bad_signature"})
            end
        end
    end
  end

  # POST /v1/relay/chat-blocked/:barkpark_id — NO bearer auth (HMAC IS the auth).
  # Push-relay spike (mobile charter D15b/D15c): Cloud's inbound receiver for the
  # INSTANCE-originated chat_blocked webhook — the box's Webhooks.Dispatcher
  # signs every delivery `x-barkpark-signature: t=<unix>,v1=<hex>` (HMAC-SHA256
  # over "<t>.<raw-body>", ±300s replay window); verification reuses
  # Webhooks.InboundSignature, the byte-for-byte CP-side twin of that signing
  # (same scheme, same tolerance, constant-time compare).
  #
  # Per-BARKPARK route on purpose: the D59h payload identifies no user and its
  # workspace_id is an instance-side value Cloud cannot uniquely resolve (the
  # charter-D45 ambiguity that made content-publish per-site). The opaque
  # :barkpark_id names the instance; its OWN Vault-stored secret
  # (Registry.reveal_push_relay_secret/1) proves the sender. The route:
  #   1. Loads the barkpark (404 silently when missing or no relay secret is
  #      configured — a probe cannot tell them apart).
  #   2. Verifies the signature over the cached raw bytes. 401 on a forged OR
  #      stale signature (no detail).
  #   3. Fans out via Push.enqueue_chat_blocked_fanout/2 — one Oban job per
  #      registered member device (row-absence severable: zero registrations →
  #      202 {enqueued: 0}, nothing fires). 422 when session_id is absent
  #      (nothing to deep-link to).
  post "/v1/relay/chat-blocked/:barkpark_id" do
    bp = Registry.get_barkpark(conn.path_params["barkpark_id"])

    cond do
      is_nil(bp) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.reveal_push_relay_secret(bp) do
          {:ok, nil} ->
            # No relay configured — same shape as "not found" so a probe cannot
            # distinguish unconfigured from nonexistent.
            json(conn, 404, %{error: "not_found"})

          :error ->
            json(conn, 500, %{error: "secret_unreadable"})

          {:ok, secret} when is_binary(secret) ->
            raw = raw_request_body(conn)
            sig = get_first_header(conn, "x-barkpark-signature")

            case Webhooks.InboundSignature.verify(raw, sig, [secret]) do
              :ok ->
                case Push.enqueue_chat_blocked_fanout(bp, conn.body_params) do
                  {:ok, enqueued} ->
                    json(conn, 202, %{ok: true, enqueued: enqueued})

                  {:error, :invalid_payload} ->
                    json(conn, 422, %{error: "invalid_payload"})
                end

              {:error, _reason} ->
                # A bad OR expired signature is the same 401 — never leak which.
                json(conn, 401, %{error: "bad_signature"})
            end
        end
    end
  end

  # GET /v1/tls/ask?domain=... → 200 (registered) | 404 (not). NO AUTH on
  # purpose: this is the Caddy `on_demand_tls.ask` gate. Caddy calls this
  # BEFORE attempting a cert issuance for a hostname; a 200 says "we own this,
  # go ahead", a 404 says "stop". The 404 is what prevents the box from being
  # a cert-issuance DoS target. Bodies are empty — Caddy only reads the status.
  get "/v1/tls/ask" do
    domain = conn.query_params["domain"] || ""

    cond do
      domain == "" -> send_resp(conn, 404, "")
      Registry.domain_registered?(domain) -> send_resp(conn, 200, "")
      true -> send_resp(conn, 404, "")
    end
  end

  ## Builder routes — the off-box build plane (P2 / Move A).
  ##
  ## Builders authenticate with a user session token for now (a dedicated
  ## builder-token type is a hardening follow-up). Auth scope: a builder may
  ## claim any queued deployment regardless of team — the build plane is
  ## fleet-wide. The user-token check is a coarse "is this a real user of
  ## Barkpark Cloud" gate. Sites the builder touches still belong to whichever
  ## team owns them; the builder never re-team a deployment.

  # POST /v1/internal/provision-jobs/:id/fail {error} → mark the job failed; the
  # Barkpark stays provisioning. IDEMPOTENT + status-guarded:
  #   200 {ok: true} — a fresh fail OR a retried fail for an already-"failed" job.
  #   409 {error: "conflict"} — the job already "succeeded"; a straggler fail must
  #     not un-succeed a live box.
  #   404 when no job has that id.
  post "/v1/internal/provision-jobs/:id/fail" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      reason = conn.body_params["error"]

      case Registry.fail_job(
             conn.path_params["id"],
             if(is_binary(reason), do: reason, else: "unspecified"),
             claim_token_opts(conn)
           ) do
        {:ok, job} ->
          # Push "fleet" so the dashboard surfaces the failed launch (with its
          # error + a retry affordance) instead of a stuck "provisioning".
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          # notifications-email: failure alert (on by default — alert hygiene).
          dispatch_barkpark_event(job.barkpark_id, :provision_failed, %{detail: job.error})
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        # claim-fence (bp-c55): a stale worker whose claim was swept + re-claimed.
        {:error, :stale_claim} ->
          json(conn, 409, %{error: "stale_claim"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  # POST /v1/builder/claim {worker_id} → 200 {deployment, observed_epoch} |
  # 404 {error: "no_queued"} | 422 missing worker_id.
  # Atomic via Registry.claim_queued_deployment_for_barkpark/2 (FOR UPDATE SKIP
  # LOCKED + epoch bump in one transaction). NOT claim_next_deployment/1 — that
  # one is fleet-wide and is no longer reachable from any route.
  #
  # AGENT-gated and BOX-SCOPED (jpf-w1-builder-identity). This route used to
  # gate on `require_worker` — the shared fleet WORKER_TOKEN, one secret that
  # ALSO opens /v1/internal/* (list and deprovision any box) and, through the
  # env route below, read any site's decrypted env. That secret had been placed
  # on a customer box that runs untrusted nixpacks builds, so a build escaping
  # its sandbox inherited the fleet.
  #
  # The credential is now the box's OWN hashed, revocable agent token, and the
  # query behind it is narrowed to that box's sites, because a per-box identity
  # in front of a fleet-wide query would still hand box A a build belonging to
  # box B. Identity and scope only work as a pair.
  #
  # CHARTER D14 — the ordering matters and this route is where it is paid. No
  # credential may ride the claim before the box-scoped flip. The claim envelope
  # already carries `source` (the git clone recipe, and for a private repo a
  # short-lived installation token, via builder_claim_source/1 below): as of
  # this route, that is served ONLY to the box hosting the site.
  #
  # The runtime half of this same pipeline (/v1/agent/*) has been require_agent
  # + barkpark-scoped all along — the builder half was the asymmetric outlier,
  # not a deliberately broader design.
  post "/v1/builder/claim" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      worker_id = conn.body_params["worker_id"]

      cond do
        not (is_binary(worker_id) and worker_id != "") ->
          json(conn, 422, %{error: "worker_id_required"})

        true ->
          bp = conn.assigns.current_barkpark

          case Registry.claim_queued_deployment_for_barkpark(bp, worker_id) do
            {:ok, deployment} ->
              response =
                Map.merge(
                  %{
                    deployment: deployment_json(deployment),
                    observed_epoch: deployment.claim_epoch
                  },
                  builder_claim_source(deployment)
                )

              json(conn, 200, response)

            {:error, :no_queued} ->
              json(conn, 404, %{error: "no_queued"})
          end
      end
    end
  end

  # git-ref clone lane: the clone source for an artifact-less repo-backed
  # deployment — %{source: %{kind, url, ref}} merged as a SIBLING of
  # `deployment` in the builder-claim 200 envelope, or %{} when the row has an
  # artifact (nothing to clone) or the site has no linked repo.
  #
  # TENANCY: this map rides ONLY the builder-claim response, which as of
  # jpf-w1-builder-identity is gated to the AGENT TOKEN OF THE BOX HOSTING THE
  # SITE — not, as before, to a shared fleet secret held by every box. That is
  # charter D14's ordering: the clone recipe and its installation token became
  # box-confined in the same commit that box-scoped the claim. It must NEVER
  # enter deployment_json/1 —
  # that serializer feeds tenant-facing reads (site deployments list/get, SSE)
  # and the agent claim, none of which may carry a build-plane clone recipe.
  # (deployment_json's own `source` field is the UNRELATED build-provenance
  # string, "box-build" | "prebuilt".)
  #
  # Applies to every artifact-less row alike: webhook production pushes,
  # branch previews, and `bp deploy --git-ref` rows.
  defp builder_claim_source(deployment) do
    artifactless? = deployment.artifact_url in [nil, ""]
    site = if artifactless?, do: Registry.get_site(deployment.site_id)

    case site do
      %{github_repo: repo} = s when is_binary(repo) ->
        %{
          source:
            put_clone_token(
              %{
                kind: "git",
                url: "https://github.com/#{repo}.git",
                ref: deployment.git_ref
              },
              s
            )
        }

      _ ->
        %{}
    end
  end

  # dwb-webhook-deploy-artifact-gap: the AUTHENTICATED half of the clone lane.
  #
  # The anonymous URL above can only ever clone a PUBLIC repo — which made
  # push-to-deploy structurally impossible for exactly the repos the product
  # creates (`POST /v1/github/repos {"private": true}`) and imports (the picker
  # lists private repos). When the site's team has a connected GitHub App
  # installation, mint a short-lived installation token and hand it to the
  # builder as its OWN field.
  #
  # `token` is a separate field, NOT credentials spliced into `url`, on purpose:
  # a credential inside a remote URL is written into the clone workdir's config
  # by `git remote add`, echoed back by git's own error messages, and would ride
  # every console line that narrates the URL. A separate field keeps exactly one
  # consumer (the builder's git auth env) and keeps the URL loggable.
  #
  # Minting is BEST-EFFORT, and the catch-all arm is load-bearing: this runs
  # inside the builder's claim, so ANY unhandled shape here would 500 the claim
  # and stall the whole build queue for every tenant — strictly worse than the
  # gap it is fixing. A failure (unwired App, no installation, GitHub down,
  # tampered handle, an unexpected seam return) leaves the anonymous source
  # untouched, so a public repo keeps deploying and a private one fails at the
  # builder with the honest terminal repo-inaccessible reason.
  defp put_clone_token(source, site) do
    case GitHub.installation_token_for(site.team_id) do
      {:ok, token} when is_binary(token) and token != "" ->
        Map.put(source, :token, token)

      {:error, reason} when reason in [:not_configured, :no_installation] ->
        # The ordinary un-connected shapes — not worth a log line per claim.
        source

      other ->
        Logger.warning(
          "builder clone token mint failed for site #{site.id}: #{inspect(other)} — " <>
            "falling back to an anonymous clone (a private repo will fail at fetch)"
        )

        source
    end
  end

  # POST /v1/builder/deployments/:id/transition
  # {worker_id, observed_epoch, status, image_tag?, build_log_url?,
  #  failure_reason?, became_live_at?} → 200 {deployment} |
  #  409 stale_epoch | 409 illegal_transition | 404 not_found | 422 invalid.
  #
  # CASes on (claim_worker, claim_epoch) — the only protection against a stale
  # lease-swept worker writing after another worker re-claimed the row. The
  # from-status transition graph is enforced too: an illegal edge (e.g.
  # failed → live) → 409 illegal_transition.
  #
  # AGENT-gated + BOX-SCOPED (jpf-w1-builder-identity), mirroring the agent
  # transition route exactly.
  #
  # The (worker, epoch) fence is NOT a tenant scope — it only proves the caller
  # holds the claim it was handed, and it cannot say whose box the row belongs
  # to. That is why the fence needs a scope check beside it rather than instead
  # of one: `agent_owns_deployment?/2` answers 404 (never 403) for a row on
  # another box, the same shape as a row that does not exist, so the route
  # cannot be used to probe for another tenant's deployment ids. The fence
  # itself is unchanged.
  post "/v1/builder/deployments/:id/transition" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      params = conn.body_params
      worker_id = params["worker_id"]
      epoch = parse_epoch(params["observed_epoch"])

      cond do
        not (is_binary(worker_id) and worker_id != "") ->
          json(conn, 422, %{error: "worker_id_required"})

        is_nil(epoch) ->
          json(conn, 422, %{error: "observed_epoch_required"})

        not agent_owns_deployment?(conn.assigns.current_barkpark, conn.path_params["id"]) ->
          json(conn, 404, %{error: "not_found"})

        true ->
          attrs =
            %{}
            |> maybe_put(:status, params["status"])
            |> maybe_put(:image_tag, params["image_tag"])
            |> maybe_put(:build_log_url, params["build_log_url"])
            |> maybe_put(:failure_reason, params["failure_reason"])
            |> maybe_put_datetime(:became_live_at, params["became_live_at"])
            # Explicit null-clearing handoff between stages. The builder, when
            # transitioning a row to `pushing`, explicitly sends `claim_worker:
            # null` + `claim_epoch: 0` so the row appears unclaimed to the
            # agent's claim query. Only null/zero values pass — never a
            # different worker id, never a positive epoch. This is the only
            # path that mutates claim_* outside the claim/sweep paths.
            |> put_handoff_claim_worker(params)
            |> put_handoff_claim_epoch(params)

          case Registry.transition_deployment_fenced(
                 conn.path_params["id"],
                 worker_id,
                 epoch,
                 attrs
               ) do
            {:ok, deployment} ->
              # Push "deployments" so an open site view advances the row
              # (queued → building → pushing → live) without a manual refresh.
              broadcast_site_team(deployment.site_id, "deployments")
              json(conn, 200, %{deployment: deployment_json(deployment)})

            {:error, :stale_epoch} ->
              json(conn, 409, %{error: "stale_epoch"})

            {:error, :illegal_transition} ->
              json(conn, 409, %{error: "illegal_transition"})

            {:error, :not_found} ->
              json(conn, 404, %{error: "not_found"})

            {:error, %Ecto.Changeset{} = cs} ->
              json(conn, 422, %{error: "invalid", details: errors(cs)})
          end
      end
    end
  end

  # POST /v1/builder/deployments/:id/console {line} → gh-5: APPEND one
  # builder-reported LIVE build-console line (the claim → fetch source → build →
  # artifact → activate narration, already redacted worker-side) to the
  # deployment's console, then push "deployments" so an open site view refetches
  # + streams the new line. Append-only + capped server-side (oldest dropped).
  #
  # Auth mirrors the builder claim/transition routes (`require_agent` + the box
  # scope check — jpf-w1-builder-identity). Nobody may inject text into another
  # team's SSE-broadcast build console, and before this flip the shared
  # WORKER_TOKEN let any box do exactly that to any team's console. A row on
  # another box now answers 404, indistinguishable from a row that does not
  # exist. Best-effort telemetry: a console report NEVER affects the build's
  # outcome; the builder treats any non-2xx as "log and continue" — so the
  # scope check cannot break a legitimate build even if it were wrong.
  #   200 {ok: true}   — appended (or a late line after the deploy is terminal).
  #   404 {not_found}  — no deployment with that id, OR it is on another box.
  #   422 {invalid}    — missing/blank line.
  post "/v1/builder/deployments/:id/console" do
    conn = Auth.require_agent(conn, [])

    cond do
      conn.halted ->
        conn

      not agent_owns_deployment?(conn.assigns.current_barkpark, conn.path_params["id"]) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.append_deployment_console(
               conn.path_params["id"],
               conn.body_params["line"]
             ) do
          {:ok, deployment} ->
            broadcast_site_team(deployment.site_id, "deployments")
            json(conn, 200, %{ok: true})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})

          {:error, :invalid} ->
            json(conn, 422, %{error: "invalid"})
        end
    end
  end

  # POST /v1/builder/deployments/:id/detail {detail} → dwb-19: SET the
  # deployment's LIVE sub-caption (latest-wins, not appended), then push
  # "deployments" so an open site view renders the caption under the status pill.
  # The build-side twin of a provision step's `progress`. Same builder auth
  # (`require_agent` + the box scope check — jpf-w1-builder-identity) and the
  # same best-effort posture as /console: a detail report NEVER affects the
  # build's outcome; the builder treats any non-2xx as "log and continue".
  #   200 {ok: true}   — the caption was set (or a late one after the deploy is terminal).
  #   404 {not_found}  — no deployment with that id, OR it is on another box.
  #   422 {invalid}    — missing/blank detail.
  post "/v1/builder/deployments/:id/detail" do
    conn = Auth.require_agent(conn, [])

    cond do
      conn.halted ->
        conn

      not agent_owns_deployment?(conn.assigns.current_barkpark, conn.path_params["id"]) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.set_deployment_detail(
               conn.path_params["id"],
               conn.body_params["detail"]
             ) do
          {:ok, deployment} ->
            broadcast_site_team(deployment.site_id, "deployments")
            json(conn, 200, %{ok: true})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})

          {:error, :invalid} ->
            json(conn, 422, %{error: "invalid"})
        end
    end
  end

  # GET /v1/builder/sites/:id/env → 200 {env: {...}} | 404 | 500.
  #
  # The DECRYPTED site env for the off-box builder: nixpacks receives each pair
  # as `--env KEY=VAL` so build-time prerendering (e.g. a Next.js SSG page
  # reading BARKPARK_READ_TOKEN) sees the values the user set via
  # `bp sites env set`. A site with no blob answers `{env: {}}` — the build
  # proceeds env-less rather than failing.
  #
  # AGENT-gated + BOX-SCOPED (jpf-w1-builder-identity), and this route is the
  # sharpest reason the flip could not wait. It hands back DECRYPTED site env —
  # every secret a tenant set with `bp sites env set`. Gated on the shared
  # WORKER_TOKEN it was an unscoped read: one secret, held by every box
  # including customer boxes running untrusted nixpacks builds, returned ANY
  # site's plaintext env. The scope is now the caller's own box, and a site on
  # another box answers 404 — the same shape as a site that does not exist, so
  # the route cannot be walked to discover which ids are real.
  #
  # Reveals are still not audit-logged, matching the existing secret-reveal
  # surfaces (/v1/barkparks/:id/credentials, /bootstrap), which record writes
  # (`site.env_changed`) but not reads.
  get "/v1/builder/sites/:id/env" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      bp = conn.assigns.current_barkpark

      case Registry.get_site(conn.path_params["id"]) do
        %Registry.Site{barkpark_id: bp_id} = site when bp_id == bp.id ->
          site_env_response(conn, site)

        _ ->
          json(conn, 404, %{error: "not_found"})
      end
    end
  end

  ## Agent runtime routes (P3 / Move A finish) — agent-authed via require_agent.
  ## The on-box runtime executor calls these to walk a Deployment from `pushing`
  ## (set by the builder) → `live` (running container behind Caddy) or `failed`
  ## (health-check failure). Scope is strictly the agent's current_barkpark.

  # GET /v1/agent/pending → 200 {deployments: [{... site: {slug, domains}}]}.
  # The agent runtime needs the site's slug + domains to render its Caddyfile
  # block on a first-time deploy; bundling the site shape with each deployment
  # avoids a second round trip for the common case.
  get "/v1/agent/pending" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      bp = conn.assigns.current_barkpark
      ds = Registry.list_pending_deployments_for_barkpark(bp)
      json(conn, 200, %{deployments: Enum.map(ds, &deployment_with_site_json/1)})
    end
  end

  # POST /v1/agent/deployments/claim {worker_id} → 200 {deployment,
  # observed_epoch} | 404 no_pending | 422 missing.
  #
  # Atomic — picks the oldest pushing row whose site is on current_barkpark,
  # bumps the epoch, stamps the worker. Same fencing semantics as the builder
  # claim, narrower filter. Status STAYS `pushing` (the agent transitions to
  # `live` via /transition once the container is up).
  post "/v1/agent/deployments/claim" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      worker_id = conn.body_params["worker_id"]

      cond do
        not (is_binary(worker_id) and worker_id != "") ->
          json(conn, 422, %{error: "worker_id_required"})

        true ->
          bp = conn.assigns.current_barkpark

          case Registry.claim_pending_deployment_for_barkpark(bp, worker_id) do
            {:ok, deployment} ->
              json(conn, 200, %{
                deployment: deployment_with_site_json(deployment),
                observed_epoch: deployment.claim_epoch
              })

            {:error, :no_pending} ->
              json(conn, 404, %{error: "no_pending"})
          end
      end
    end
  end

  # POST /v1/agent/deployments/:id/transition
  # {worker_id, observed_epoch, status, image_tag?, became_live_at?,
  #  failure_reason?, site_port?, make_current?}
  #
  # The agent's fenced transition. When `make_current=true` AND `status=live`,
  # the Site's `current_deployment_id` is set to this deployment AND `port` is
  # set to `site_port` — in the SAME transaction as the deployment status flip.
  # No window where the deployment is `live` but the site's pointer is stale.
  # An illegal from-status edge (e.g. failed → live) → 409 illegal_transition,
  # so a broken row can never repoint the Site at a never-built deployment.
  #
  # Scope: the deployment's site must belong to current_barkpark — otherwise
  # 404 (no cross-box transition leak).
  post "/v1/agent/deployments/:id/transition" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      params = conn.body_params
      worker_id = params["worker_id"]
      epoch = parse_epoch(params["observed_epoch"])

      cond do
        not (is_binary(worker_id) and worker_id != "") ->
          json(conn, 422, %{error: "worker_id_required"})

        is_nil(epoch) ->
          json(conn, 422, %{error: "observed_epoch_required"})

        true ->
          deployment_id = conn.path_params["id"]
          bp = conn.assigns.current_barkpark

          # Cross-box check: the deployment's site must belong to current_barkpark.
          # 404 (same as nonexistent) — never an existence leak.
          case agent_owns_deployment?(bp, deployment_id) do
            false ->
              json(conn, 404, %{error: "not_found"})

            true ->
              attrs =
                %{}
                |> maybe_put(:status, params["status"])
                |> maybe_put(:image_tag, params["image_tag"])
                |> maybe_put(:failure_reason, params["failure_reason"])
                |> maybe_put(:build_log_url, params["build_log_url"])
                |> maybe_put_datetime(:became_live_at, params["became_live_at"])

              site_attrs =
                cond do
                  params["make_current"] == true and params["status"] == "live" ->
                    %{}
                    |> maybe_put(:current_deployment_id, deployment_id)
                    |> maybe_put(:port, params["site_port"])

                  true ->
                    nil
                end

              result =
                if site_attrs do
                  Registry.transition_deployment_with_site_update(
                    deployment_id,
                    worker_id,
                    epoch,
                    attrs,
                    site_attrs
                  )
                else
                  Registry.transition_deployment_fenced(
                    deployment_id,
                    worker_id,
                    epoch,
                    attrs
                  )
                end

              case result do
                {:ok, deployment} ->
                  # Push "deployments" so an open site view advances the row to its
                  # FINAL state (pushing → live / failed) without a manual refresh —
                  # the agent owns this last transition (mirrors the builder route).
                  broadcast_site_team(deployment.site_id, "deployments")
                  json(conn, 200, %{deployment: deployment_json(deployment)})

                {:error, :stale_epoch} ->
                  json(conn, 409, %{error: "stale_epoch"})

                {:error, :illegal_transition} ->
                  json(conn, 409, %{error: "illegal_transition"})

                {:error, :not_found} ->
                  json(conn, 404, %{error: "not_found"})

                {:error, %Ecto.Changeset{} = cs} ->
                  json(conn, 422, %{error: "invalid", details: errors(cs)})
              end
          end
      end
    end
  end

  # GET /v1/agent/sites/:id/env → 200 {env: {...}} | 404 | 500.
  #
  # The DECRYPTED site env for the ON-BOX runtime executor: each pair becomes a
  # `-e KEY=VAL` on the `docker run` so the live container (not just the build)
  # sees the values from `bp sites env set`. A site with no blob answers
  # `{env: {}}`.
  #
  # AGENT-gated + BOX-SCOPED, fail-closed: the site must belong to the agent's
  # current_barkpark — a site on another box (or nonexistent / non-UUID) is the
  # SAME 404, indistinguishable from missing (no existence leak), mirroring
  # agent_owns_deployment?/2 on the transition route above. Reveals are not
  # audit-logged (see the builder twin above for why).
  get "/v1/agent/sites/:id/env" do
    conn = Auth.require_agent(conn, [])

    if conn.halted do
      conn
    else
      bp = conn.assigns.current_barkpark

      case Registry.get_site(conn.path_params["id"]) do
        %Registry.Site{barkpark_id: bp_id} = site when bp_id == bp.id ->
          site_env_response(conn, site)

        _ ->
          json(conn, 404, %{error: "not_found"})
      end
    end
  end

  ## Health / status surfaces (health-status)

  # GET /up, GET /health — control-plane liveness. 200 {db: "up"} | 503 {db: "down"}.
  # UNAUTHENTICATED: this is the load-balancer / uptime-monitor probe. The check
  # is a single `SELECT 1` round-trip to the control plane's own Postgres (its
  # only hard dependency) via BarkparkCloud.Health.health/0. Sits OUTSIDE /v1 (so
  # it never collides with the JSON API) and is NOT in the Plug.Static allowlist
  # (so nothing shadows it). `/up` mirrors Phoenix's conventional liveness path;
  # `/health` is the common alias.
  get("/up", do: send_health(conn))
  get("/health", do: send_health(conn))

  # GET /v1/barkparks/:id/events → 200 {events: [...]} newest first | 404.
  # User-authed + TEAM-SCOPED: a wrong-team / nonexistent id is the SAME 404 (no
  # existence leak), matching DELETE /v1/barkparks/:id. Surfaces the granular
  # history the agent already writes. The event kinds are exactly the four live
  # `Registry.record_event` producers (cch-w51-bl, re-derived 2026-08-23):
  # "health" — the full beat (disk%, PG size, dirty-tree, the health-gate
  # array; NOT backup — the beat's `backup_ok` key is an unwired constant
  # false, no BackupProbe exists, so the feed carries no backup truth) — plus
  # "space", "verify", and the "status" transition rows the staleness worker
  # writes. A pure read over Registry.recent_events_for_team/3, no new model.
  # `?limit=` caps the window (default 50, max 200).
  #
  # LIMIT, stated on purpose (charter D341): __agent_event_vocabulary_census.mjs
  # reads `Registry.record_event(` CALL SITES, not prose, so it can never red on
  # this comment — and widening it to grep comments would be a false-red
  # machine. This sentence is the durable note instead.
  get "/v1/barkparks/:id/events" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        conn = fetch_query_params(conn)
        limit = parse_limit(conn.query_params["limit"], 50, 200)

        case Registry.recent_events_for_team(
               conn.assigns.current_team,
               conn.path_params["id"],
               limit
             ) do
          nil -> json(conn, 404, %{error: "not_found"})
          events -> json(conn, 200, %{events: Enum.map(events, &event_json/1)})
        end
    end
  end

  # GET /v1/barkparks/:id/telemetry → 200 {telemetry: <envelope> | nil} | 404.
  # User-authed + TEAM-SCOPED with the SAME no-existence-leak 404 as the
  # sibling events route (wrong-team / absent id are indistinguishable). Pure
  # OBSERVABILITY over data the agent ALREADY captured (charter decision 16): it
  # finds the LATEST "health" event in the instance's append-only stream and
  # re-serves it through `Telemetry.normalize/1` as one stable envelope. A live
  # instance that has simply not phoned home a health beat yet is NOT an error —
  # it returns `telemetry: nil` (never 500). The 100-event window is ample: the
  # per-cycle health beat is by far the most frequent event kind, so the newest
  # health row lives at the head of the stream.
  get "/v1/barkparks/:id/telemetry" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.recent_events_for_team(
               conn.assigns.current_team,
               conn.path_params["id"],
               100
             ) do
          nil ->
            json(conn, 404, %{error: "not_found"})

          events ->
            telemetry =
              case Enum.find(events, &(&1.type == "health")) do
                nil -> nil
                event -> Telemetry.normalize(event)
              end

            json(conn, 200, %{telemetry: telemetry})
        end
    end
  end

  # GET /v1/barkparks/:id/metrics?points=N → 200 {ok, collected_at, instance,
  # beat, points, series, latest, pressure, space, service_health} | 404. The time-series companion to
  # /telemetry (which serves the single latest beat): it folds a WINDOW of the
  # instance's health beats — the vitals the agent now rides on its 60s beat
  # (cpu/mem/disk/load) — into oldest-to-newest series the console's Metrics tab
  # (S12b) and `bp cloud instance top` render. Pure OBSERVABILITY over data the
  # agent ALREADY captures: no new ingest route, no new store — the durable
  # `agent_events` table IS the window (a per-60s beat adds no rows beyond the
  # health event that already lands; an ETS ring would empty on every blue/green
  # deploy). `BarkparkCloud.Metrics.build/3` is the pure, total shaper.
  #
  # USER-authed + TEAM-SCOPED with the SAME no-existence-leak 404 as the sibling
  # telemetry / usage / domain-status routes (wrong-team / absent / malformed id
  # are indistinguishable). `points` is clamped (default 30, cap 200) via the
  # shared parse_limit idiom. TOTAL over a sick/silent box: an instance that has
  # never phoned home a beat is a normal 200 with beat.status "absent" and empty
  # series, never a 500. beat.status live|stale|absent keys off
  # Registry.health_stale_after_seconds() — the CP-wide degraded threshold,
  # never a new constant.
  get "/v1/barkparks/:id/metrics" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        conn = fetch_query_params(conn)
        points = parse_limit(conn.query_params["points"], 30, 200)

        case resolve_team_barkpark(conn.assigns.current_team, conn.path_params["id"]) do
          nil ->
            json(conn, 404, %{error: "not_found"})

          %Barkpark{} = bp ->
            # TYPE-FILTERED at the FETCH, not just at the fold: `points` is the
            # number of HEALTH beats the caller asked to chart, so the LIMIT has
            # to be applied to health rows. A type-blind read hands the window
            # `points` rows of the MIXED stream and Metrics then drops the
            # non-health ones — at the shipped cadence (60s health beside a
            # 15-minute `space` row) that renders 188 of a requested 200 while
            # the envelope still says 200 (D58's separation was enforced at
            # WRITE and at FOLD, never at FETCH).
            events = Registry.recent_events_of_type(bp, "health", points)

            # The SPACE row is fetched SEPARATELY and deliberately: it rides its
            # own 15-minute cadence on its own route (D58), so it is not in the
            # health window at all — a type-blind read is exactly what D58
            # separated. ONE row is enough: space is a scalar snapshot ("what is
            # on the disk right now"), not a series, and asking for one row of a
            # type-filtered, already-indexed scan is a bounded cost added to a
            # route that was already doing the same scan for health.
            #
            # `nil` when the box has never sent one (an agent older than #9889,
            # or one whose probes are all unwired) → `space: nil` in the
            # envelope, which every surface renders as "no space report yet"
            # rather than as an empty disk.
            space_event = List.first(Registry.recent_events_of_type(bp, "space", 1))

            json(
              conn,
              200,
              Metrics.build(bp, events, points: points, space_event: space_event)
            )
        end
    end
  end

  # GET /v1/barkparks/:id/usage → 200 {usage: <envelope>} | 404. User-authed +
  # TEAM-SCOPED with the SAME no-existence-leak 404 as the sibling events /
  # telemetry routes (wrong-team / absent / malformed id are indistinguishable).
  #
  # Composes the console's usage meters (charter decision D48 — two honesty
  # tiers). The endpoint NEVER 500s on a sick box and NEVER blocks the
  # control-plane-sourced meters on the instance: seats (team members) and the
  # telemetry-sourced db_size/disk are computed from control-plane data and
  # returned even when the instance is unreachable; only the instance-sourced
  # inventory counts (documents / datasets / webhooks — all live over the wire
  # since C11) reach across, and any failure there degrades that ONE meter
  # to `value:"unmetered"` (never a fake zero) rather than failing the request.
  # `BarkparkCloud.Usage.compose/1` is the pure, total shaper; this handler only
  # gathers the (possibly partial / failed) inputs. The vault-stored admin token
  # used for the instance count fetch NEVER appears in the response body.
  get "/v1/barkparks/:id/usage" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        team = conn.assigns.current_team

        case resolve_team_barkpark(team, conn.path_params["id"]) do
          nil -> json(conn, 404, %{error: "not_found"})
          %Barkpark{} = bp -> json(conn, 200, %{usage: Usage.gather(bp)})
        end
    end
  end

  # GET /v1/barkparks/:id/usage/history?points=N → 200 <history envelope> | 404.
  # User-authed + TEAM-SCOPED with the SAME no-existence-leak 404 as the sibling
  # usage / metrics routes (wrong-team / absent / malformed id are
  # indistinguishable). The Usage sub-tab's sparklines (cloud-console wave 4): a
  # PURE DB read of the instance's cached `usage_samples` rows over the trailing
  # 14-day window — ZERO instance HTTP (the ~15s live fan-out would disqualify a
  # sparkline). `points` uniform buckets (default 56, cap 200) via the shared
  # parse_limit idiom; each bucket carries the latest sample that fell in it, an
  # empty bucket → value nil, an "unmetered" meter → nil (a gap, never a fake
  # zero). A never-sampled instance is a normal 200 with all-nil series.
  # `BarkparkCloud.Usage.history/2` is the pure, total shaper.
  get "/v1/barkparks/:id/usage/history" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        conn = fetch_query_params(conn)
        points = parse_limit(conn.query_params["points"], 56, 200)

        case resolve_team_barkpark(conn.assigns.current_team, conn.path_params["id"]) do
          nil -> json(conn, 404, %{error: "not_found"})
          %Barkpark{} = bp -> json(conn, 200, Usage.history(bp, points))
        end
    end
  end

  # GET /v1/usage/summary → 200 {usage: {team, instances}} | 404. User-authed +
  # team-scoped. The Overview fleet meter strip (cloud-console wave 3): a PURE DB
  # read of the LATEST cached usage sample per checkable instance — ZERO instance
  # HTTP on this path (the ~15s live `/usage` fan-out would disqualify a fleet
  # view). The `team.instances` fleet-quota meter IS live (a cheap control-plane
  # count), everything else is cached, per-instance `measured_at`. A never-sampled
  # instance serves the honest all-"unmetered" envelope with measured_at nil.
  get "/v1/usage/summary" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        json(conn, 200, %{usage: Usage.summary(conn.assigns.current_team)})
    end
  end

  # GET /v1/barkparks/:id/domain-status → 200 {ok, checked_at, instance, domains}
  # — the per-domain, per-stage DNS/TLS/serving checklist (charter S13 /
  # BarkparkCloud.DomainStatus). The control plane's honest answer to "why isn't
  # my domain working?": for the platform FQDN (and the custom host when
  # attached) it probes dns_found → points_here → tls → serving, each with a
  # status + evidence + server-owned remediation, so the console (S13b) and CLI
  # can render a Vercel-grade checklist. The probe is SYNCHRONOUS but bounded
  # (per-probe transport timeouts, at most two hosts) and TOTAL over failure — a
  # stuck domain is a normal 200 result with pending/failed stages, never a 502.
  #
  # USER-authed + TEAM-SCOPED with the SAME no-existence-leak 404 as the sibling
  # telemetry / usage routes (wrong-team / absent / malformed id are
  # indistinguishable). It reads only public DNS + the box's own TLS/HTTP — no
  # admin token, no zone read — so unlike verify it needs no liveness gate.
  get "/v1/barkparks/:id/domain-status" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case resolve_team_barkpark(conn.assigns.current_team, conn.path_params["id"]) do
          nil -> json(conn, 404, %{error: "not_found"})
          %Barkpark{} = bp -> json(conn, 200, DomainStatus.check(bp))
        end
    end
  end

  # GET /v1/sites/:id/domain-status → 200 {ok, checked_at, instance, domains} —
  # the Site sibling of the barkparks checklist above (charter D56, CF-in-front
  # wave). Probes each of the site's custom `domains` dns_found → points_here →
  # tls → serving against the box it runs on (`site.barkpark.host`).
  #
  # MODE-AWARE: a :cf_proxied site (behind Cloudflare's orange cloud) resolves to
  # CF edge anycast IPs, not the origin, so `points_here` is classified :proxied
  # (informational) instead of compared — the mode is read from the Site record,
  # NEVER inferred from the resolved IP. A :direct site (the default, and every
  # standalone box) is the exact addr == box intersection, unchanged.
  #
  # USER-authed + TEAM-SCOPED with the SAME no-existence-leak 404 as the sibling
  # barkparks route (wrong-team / absent / malformed id are indistinguishable).
  # Reads only public DNS + the box's own TLS/HTTP — no admin token, no zone read.
  get "/v1/sites/:id/domain-status" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.get_team_site(conn.assigns.current_team, conn.path_params["id"]) do
          %Registry.Site{} = site ->
            json(conn, 200, DomainStatus.check(Repo.preload(site, :barkpark)))

          nil ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  ## Catch-all → 404 JSON

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  ## Crash path → the SAME flat JSON envelope every other route answers with

  # The one handler for everything that RAISES instead of returning a conn:
  # an uncaught error inside a route, and the `Plug.Parsers` faults that fire
  # before `:dispatch` ever runs (unreadable body → 400, content-type we don't
  # parse → 415, body over the limit → 413).
  #
  # Three things have to be true together, or the person still reads copy that
  # blames them (all three measured by RUNNING app.js's real `friendly()`, not
  # by reading it):
  #
  #   1. FLAT `%{error: "<slug>"}`. Cloud's envelope is flat and the SPA keys on
  #      `data.error` as a STRING (app.js `friendly()`); api/'s NESTED
  #      `%{error: %{code: …}}` shape would read as no slug at all and fall
  #      straight back to the blaming fallback.
  #   2. A slug the SPA's `ERRORS` map knows. Precedence there is curated copy →
  #      `details` → the caller's fallback → the humanized slug, so an
  #      UNREGISTERED slug loses to the caller's fallback — shipping
  #      `%{error: "internal_error"}` alone would have changed nothing on screen.
  #   3. `content-type: application/json`, or `api()` throws the body away
  #      before `friendly()` can ever see it.
  #
  # The status is whatever `Plug.Exception` already says (400/413/415/500) — it
  # was never the broken part, so it is preserved rather than flattened to 500.
  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason}) do
    status = conn.status || 500
    request_id = request_id(conn)

    # A 5xx is OURS and belongs at :error; a 4xx parse fault is the caller
    # sending something we don't accept — real, worth seeing, but not a page.
    level = if status >= 500, do: :error, else: :warning

    Logger.log(
      level,
      "crash_envelope request_id=#{request_id} status=#{status} " <>
        "method=#{conn.method} path=#{conn.request_path} kind=#{inspect(kind)}"
    )

    conn
    |> put_resp_header("x-request-id", request_id)
    |> json(status, %{error: crash_slug(reason, status), request_id: request_id})
  end

  # Distinct slugs for the faults a person can actually provoke, so the console
  # can say something true and specific ("that was too large") instead of one
  # undifferentiated apology. Anything else splits on status: a 5xx is OURS to
  # own, a residual 4xx is a malformed request but still not a form the person
  # filled in wrong.
  defp crash_slug(%Plug.Parsers.ParseError{}, _status), do: "malformed_body"

  defp crash_slug(%Plug.Parsers.UnsupportedMediaTypeError{}, _status),
    do: "unsupported_media_type"

  defp crash_slug(%Plug.Parsers.RequestTooLargeError{}, _status), do: "request_too_large"
  defp crash_slug(_reason, status) when status >= 500, do: "server_error"
  defp crash_slug(_reason, _status), do: "malformed_request"

  # Echo the front's request id when Caddy sent one, otherwise mint one, so the
  # id the person can read off the screen is the id in our logs.
  # The incoming value is REFLECTED into a response header and a JSON body, so
  # it is accepted only as a bounded, boring token — never trusted verbatim.
  # Anything else (or nothing) gets a freshly minted id.
  defp request_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [id | _] when is_binary(id) ->
        if id =~ ~r/\A[A-Za-z0-9._-]{1,200}\z/, do: id, else: mint_request_id()

      _ ->
        mint_request_id()
    end
  end

  defp mint_request_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  ## Health surface helpers (health-status)

  # Routes BarkparkCloud.Health.health/0 to an HTTP status: 200 when the Repo
  # answers SELECT 1, 503 when it doesn't. Never raises (health/0 rescues).
  defp send_health(conn) do
    case BarkparkCloud.Health.health() do
      {:ok, body} -> json(conn, 200, body)
      {:error, body} -> json(conn, 503, body)
    end
  end

  # One agent-event row, JSON-shaped for GET /v1/barkparks/:id/events. The
  # append-only stream has no updated_at — only inserted_at.
  defp event_json(e) do
    %{id: e.id, type: e.type, payload: e.payload, inserted_at: e.inserted_at}
  end

  # Clamp the ?limit= window: a positive integer capped at `max`, else `default`.
  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(s, default, max) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> min(n, max)
      _ -> default
    end
  end

  defp parse_limit(_, default, _max), do: default

  # User-facing message for a GET /v1/archives degrade (S14). Server-owned copy
  # (JS never invents a reason) — an unconfigured deployment reads distinctly
  # from a transient store outage so the operator knows whether to wait or ask.
  defp archive_store_error(:not_configured),
    do: "Archive storage isn't configured for this deployment."

  defp archive_store_error(_other),
    do: "Couldn't reach the archive store. It may be temporarily unavailable — try again shortly."

  ## go-live handler (shared by /launch and /go-live)

  # dwb-13 entitlement gate with trial auto-start. True when the team is already
  # entitled, OR its ONE free trial started here (first launch, unused ledger).
  # `start_trial/1` is idempotent + race-safe: an already-entitled team returns
  # `:already_entitled`, a fresh team stamps + grants the trial, a team that
  # already consumed its trial returns `{:error, :trial_used}` → false → 402.
  defp entitled_or_trial_started?(team) do
    Billing.entitled?(team) or match?({:ok, _}, Billing.start_trial(team))
  end

  # dwb-11: is this barkpark in a state POST /v1/barkparks/:id/retry may
  # re-provision? Two states qualify:
  #
  #   * latest provision job FAILED — the classic one-click Retry.
  #   * NO provision job at all, on a MANAGED instance that never went live
  #     (host nil) — the stranded-launch state a go-live enqueue hiccup leaves
  #     (201 stood, job insert failed, only logged). Narrow BY DESIGN: a
  #     self_hosted/byo row (registered, never provisioned by us) and a live
  #     managed box (host set) must never grow a provision job from a stray
  #     Retry click.
  #
  # Anything in flight or succeeded stays 409 not_retryable; the one-active-job
  # index backstops the enqueue against a concurrent race either way.
  defp retryable_provision_state?(%Barkpark{} = bp) do
    case Registry.latest_provision_job(bp) do
      %{status: "failed"} ->
        true

      nil ->
        bp.mode == "managed" and (is_nil(bp.host) or bp.host == "")

      _ ->
        false
    end
  end

  defp go_live(conn) do
    # go-live is the launch action — accept a session OR a PAT, but gate each
    # principal correctly (CREDENTIAL-AWARE):
    #   * a PAT must carry the `deploy` ability (Coolify's exclusive deploy-token).
    #   * a SESSION carries ["root"], so `require_ability` is a no-op for it — gate
    #     the session branch on TEAM-ADMIN inline here. NOT
    #     `require_primary_team_admin/1`, which re-runs `require_user` and discards
    #     the resolved PAT/session assigns.
    # The ROLE check precedes the entitlement (402) check, so a plain member gets
    # 403 (not 402) and the deploy-PAT path still works.
    conn = Auth.require_user_or_pat(conn, [])

    conn =
      cond do
        conn.halted ->
          conn

        # PAT bearer → must carry the `deploy` ability.
        conn.assigns[:current_token] ->
          Auth.require_ability(conn, "deploy")

        # Session with no team → fall through to the 422 no_team branch below.
        is_nil(conn.assigns[:current_team]) ->
          conn

        # Session → must be owner/admin of the resolved team.
        Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) ->
          conn

        # cch-w36-s1: NAME THE AUTHORITY. This refusal and the owner-only
        # billing one were the same three bytes on the wire, so the console
        # could only guess — and it guessed "plan limit reached". Launching
        # needs ADMIN on the resolved team; paying needs OWNER. Emitted through
        # Auth.forbidden/2 so there is one shape, not a second copy.
        true ->
          Auth.forbidden(conn, required: "admin", scope: "team")
      end

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      # The launch gate: ENTITLEMENT is REQUIRED — an active subscription, or a
      # past_due one still inside its grace window (a transient dunning state
      # must not lock out a paying customer; Coolify-anchor: isSubscriptionActive
      # stays true through stripe_past_due).
      #
      # dwb-13 — AUTO-START THE ONE FREE TRIAL: a team that reaches go-live NOT
      # entitled and has NEVER used its trial gets it started HERE, then launches
      # — the fewest-clicks experience contract (the /new entitlement step, dwb-6),
      # so a first launch is never a dead-end 402. One-trial-per-team-EVER is
      # enforced on the durable team ledger by `Billing.start_trial/1` (race-safe;
      # a torn-down / expired trial is never re-granted). Signup already grants a
      # trial, so this is the belt-and-braces fallback for any team that arrives
      # un-entitled with an unused ledger. A team whose trial was already consumed
      # → `{:error, :trial_used}` → the 402 stands and it must subscribe.
      not entitled_or_trial_started?(conn.assigns.current_team) ->
        json(conn, 402, %{
          error: "no_active_subscription",
          checkout_path: "/v1/billing/checkout"
        })

      # usage-limits-quotas: the QUOTA gate — the plan's managed-instance ceiling.
      # 403 (authenticated AND entitled, but the plan forbids one more) with the
      # actionable upgrade path, surfaced BEFORE the caller fills in a name. It
      # runs AFTER the 402 so an unsubscribed caller still learns "subscribe"
      # first. The Registry.register_barkpark/2 guard below is the un-bypassable
      # backstop for any path that skips this handler (the agent/internal register).
      Billing.barkpark_limit_reached?(conn.assigns.current_team) ->
        json(conn, 403, %{
          error: "limit_reached",
          limit: Billing.barkpark_limit(conn.assigns.current_team),
          upgrade_path: "/v1/billing/checkout"
        })

      # dwb-4: an UNKNOWN template is rejected HERE, before any row/job/box
      # exists — a 4xx at launch, never a burned box discovered mid-provision.
      # No template (nil/blank) → the pre-template launch exactly.
      not valid_template?(conn.body_params["template"]) ->
        json(conn, 422, %{
          error: "unknown_template",
          known_templates: Registry.known_templates()
        })

      # Provider-neutral launch (charter Decision 9): the provider must be one we
      # host. An unknown/malformed provider is rejected HERE — a 4xx at the button,
      # never a burned box. Absent/blank → hetzner (the default), always valid.
      launch_provider(conn.body_params["provider"]) == :error ->
        json(conn, 422, %{
          error: "invalid_provider",
          known_providers: BarkparkCloud.Registry.Provider.kinds()
        })

      # Azure REQUIRES a verified connected azure provider row (Decision 4/9): the
      # credential that PROVISIONS the box lives on the team's providers row, saved
      # only after the verify-before-save preflight. No row → fail at the button
      # with remediation, never mid-provision on a box that can't be created.
      launch_provider(conn.body_params["provider"]) == "azure" and
          is_nil(provider_of_kind(conn.assigns.current_team, "azure")) ->
        json(conn, 422, %{
          error: "provider_not_connected",
          provider: "azure",
          remediation: FailureCopy.provider_not_connected_remediation("azure")
        })

      true ->
        team = conn.assigns.current_team
        name = conn.body_params["name"]
        slug = if(is_binary(name), do: slugify(name), else: nil)
        template = template_or_nil(conn.body_params["template"])
        # Provider-neutral launch config (charter Decision 9). The provider was
        # validated by the cond above (:error already 422'd), so it is a known
        # slug or the hetzner default here; region/server_type ride through as
        # given (nil → the claim's warm-pool fallback).
        provider = launch_provider(conn.body_params["provider"])
        region = string_param_or_nil(conn.body_params["region"])
        server_type = string_param_or_nil(conn.body_params["server_type"])

        with true <- is_binary(name) and name != "",
             # Clean-first FQDN: `<slug>.barkpark.cloud` when the slug is free
             # and not reserved, else the globally-unique
             # `<slug>-<team_short_id>` form. The `:url` global unique index is
             # both the reservation mechanism and the cross-tenant backstop;
             # claim_json reads the DNS label back off the stored `url` so the
             # provisioned FQDN == the customer-facing FQDN (clean or suffixed).
             {:ok, barkpark} <-
               Registry.register_managed_barkpark(team, name, slug,
                 template: template,
                 provider: provider,
                 region: region,
                 server_type: server_type
               ) do
          # activity-audit-log: record `barkpark.go_live` POST-COMMIT, best-effort.
          # register_managed_barkpark is clean-first-then-suffix: its FIRST insert
          # may hit the url unique index and RECOVER by retrying with the suffixed
          # FQDN. That recovery is incompatible with an enclosing transaction (the
          # failed insert would poison it), so this seam CANNOT use the atomic
          # audit/3 wrapper. Recording after the row commits mirrors the
          # already-best-effort provision-job enqueue below; a failed audit insert
          # is logged, never 500s a successful launch.
          case Accounts.record_audit(%{
                 team_id: team.id,
                 actor_user_id: conn.assigns.current_user.id,
                 action: "barkpark.go_live",
                 target_type: "barkpark",
                 target_id: barkpark.id,
                 metadata: %{name: name, plan: conn.body_params["plan"]}
               }) do
            {:ok, _} -> :ok
            {:error, cs} -> Logger.error("audit barkpark.go_live failed: #{inspect(cs)}")
          end

          # Async half: hand the provisioning work to the Go warm-pool worker
          # via a pending job. The subscription gate ALREADY passed and the
          # barkpark row ALREADY exists in a provisioning state by this point, so
          # an enqueue hiccup (a DB blip) must NOT 500 the request — that would
          # strand a launched-but-unprovisioned go-live. A missed job is
          # recoverable (the row carries the provisioning state; re-enqueue is a
          # separate concern), so on error we LOG and still return the normal 201.
          case Registry.enqueue_provision_job(barkpark) do
            {:ok, _job} ->
              :ok

            {:error, reason} ->
              Logger.error(
                "go_live: failed to enqueue provision job for barkpark #{barkpark.id}: " <>
                  inspect(reason)
              )
          end

          # Live-push the new provisioning row to any open dashboard tab.
          push_event(team.id, "fleet")
          push_event(team.id, "audit")
          json(conn, 201, %{barkpark: barkpark_json(barkpark)})
        else
          false ->
            json(conn, 422, %{error: "name_required"})

          # usage-limits-quotas: a race that slipped past the cond's quota check
          # (a concurrent create that filled the last slot between the check and
          # the insert) still returns 403, never a 500. The context guard is the
          # backstop; this maps it to the same friendly response.
          {:error, :limit_reached} ->
            json(conn, 403, %{
              error: "limit_reached",
              limit: Billing.barkpark_limit(team),
              upgrade_path: "/v1/billing/checkout"
            })

          {:error, %Ecto.Changeset{} = changeset} ->
            json(conn, 422, %{error: "invalid", details: errors(changeset)})
        end
    end
  end

  ## resurrect handler (POST /v1/resurrect) — azh-w6 (S14c)

  # Restore a torn-down instance from a portable-archive bundle. Team-scoped +
  # admin-gated (a resurrect stands up — and bills — a real box). The gate order
  # mirrors go_live's 4xx-at-the-button doctrine: reject everything cheap BEFORE
  # any row/job exists so a bad request never strands a half-built instance.
  #
  #   * no team / not admin        → 422 no_team / 403 forbidden
  #   * blank name                 → 422 name_required
  #   * unknown provider           → 422 invalid_provider
  #   * azure w/o a verified row    → 422 provider_not_connected + remediation (D17)
  #   * a LIVE box already named X  → 422 live_twin (resurrect would double it)
  #
  # The bundle_ref is RESOLVED, not required (azh-w7 / D47): an explicit
  # bundle_ref rides verbatim (the escape hatch — resurrect THIS exact bundle);
  # absent, the team's NEWEST archive is resolved server-side via
  # `ArchiveStore.list_archives/1` (newest-first, team-scoped by key prefix) — so
  # "resurrect my latest" needs no client bookkeeping. An empty store is an honest
  # 404 no_archives; an unconfigured / unreachable store degrades EXACTLY like GET
  # /v1/archives (502 + the same server-owned copy) — NEVER a fabricated
  # "no archives" that would say your box is gone when the store is merely down.
  #
  # On success: a FRESH barkpark row (provider/region/size nil-honest — D23) + a
  # pending `resurrect` job carrying the resolved bundle_ref → 202
  # {ok, id, job_id, bundle_ref} (the resolved ref is echoed so the console can
  # name which bundle it restored).
  defp resurrect(conn) do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns[:current_team]) ->
        json(conn, 422, %{error: "no_team"})

      # cch-w37-s2: NAME THE AUTHORITY. The rendered "Resurrect" CTA sends a
      # member's refusal through resurrectOutcome → friendly(), where a bare body
      # resolves to the owner-only BILLING sentence — and the very next branch
      # here is a REAL billing refusal (402), so the two were indistinguishable
      # to the user. Resurrecting needs ADMIN; paying needs OWNER.
      not Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) ->
        Auth.forbidden(conn, required: "admin", scope: "team")

      # A resurrect stands up — and bills — a real box, so it honors the SAME
      # entitlement gate as launch (an active subscription, or the one auto-started
      # free trial). Restoring your own archive is still a billed instance; letting
      # a lapsed team resurrect around the 402 would be a billing hole.
      not entitled_or_trial_started?(conn.assigns.current_team) ->
        json(conn, 402, %{
          error: "no_active_subscription",
          checkout_path: "/v1/billing/checkout"
        })

      not present_param?(conn.body_params["name"]) ->
        json(conn, 422, %{error: "name_required"})

      launch_provider(conn.body_params["provider"]) == :error ->
        json(conn, 422, %{
          error: "invalid_provider",
          known_providers: BarkparkCloud.Registry.Provider.kinds()
        })

      launch_provider(conn.body_params["provider"]) == "azure" and
          is_nil(provider_of_kind(conn.assigns.current_team, "azure")) ->
        json(conn, 422, %{
          error: "provider_not_connected",
          provider: "azure",
          remediation: FailureCopy.provider_not_connected_remediation("azure")
        })

      not is_nil(
        Registry.get_barkpark_by_name(conn.assigns.current_team, conn.body_params["name"])
      ) ->
        json(conn, 422, %{error: "live_twin", name: conn.body_params["name"]})

      # The bundle_ref resolution is the LAST gate — it may cost a store round
      # trip, so every cheap 4xx above fires first (nothing stood up yet). An
      # explicit ref rides verbatim; absent, the team's newest archive resolves;
      # an empty store is 404, a down/unconfigured store degrades to 502 (D47).
      true ->
        case resolve_resurrect_bundle_ref(conn) do
          {:ok, bundle_ref} ->
            do_resurrect(conn, bundle_ref)

          {:error, :no_archives} ->
            json(conn, 404, %{error: "no_archives"})

          {:error, :invalid_bundle_ref} ->
            json(conn, 422, %{error: "invalid_bundle_ref"})

          {:error, {:store, reason}} ->
            json(conn, 502, %{ok: false, error: archive_store_error(reason)})
        end
    end
  end

  # Resolve the bundle to resurrect from. An explicit (non-blank) bundle_ref is
  # the verbatim escape hatch — resurrect THIS exact bundle. Absent or blank, the
  # team's NEWEST archive is resolved via the same store GET /v1/archives reads
  # (newest-first, team-scoped by the `archives/<team_id>/` key prefix), so a
  # console "Resurrect latest" needs no client bookkeeping.
  #
  # Honest degrade (D47): the store is never allowed to fabricate an absence —
  #   * `{:ok, [newest | _]}` → resurrect its bundle_ref;
  #   * `{:ok, []}`           → `{:error, :no_archives}` (a TRUE empty → 404);
  #   * `{:error, reason}`    → `{:error, {:store, reason}}` (down/unconfigured →
  #     502 with the same server-owned copy GET /v1/archives uses), so a store
  #     outage never reads as "your archives are gone".
  defp resolve_resurrect_bundle_ref(conn) do
    case conn.body_params["bundle_ref"] do
      ref when is_binary(ref) ->
        case String.trim(ref) do
          "" -> newest_bundle_ref(conn.assigns.current_team)
          trimmed -> {:ok, trimmed}
        end

      nil ->
        newest_bundle_ref(conn.assigns.current_team)

      # A NON-STRING bundle_ref (a number, a map…) is a malformed request, never
      # "absent": silently resolving the newest archive would stand up a billed
      # box from a bundle the caller never named.
      _other ->
        {:error, :invalid_bundle_ref}
    end
  end

  defp newest_bundle_ref(team) do
    case ArchiveStore.list_archives(team.id) do
      {:ok, [%{bundle_ref: ref} | _]} -> {:ok, ref}
      {:ok, []} -> {:error, :no_archives}
      {:error, reason} -> {:error, {:store, reason}}
    end
  end

  # Stand up the fresh row + enqueue the resurrect job for a resolved bundle_ref.
  # All cheap 4xx gates already passed in resurrect/1; only the register/enqueue
  # (and quota) outcomes remain.
  defp do_resurrect(conn, bundle_ref) do
    team = conn.assigns.current_team
    name = conn.body_params["name"]
    slug = slugify(name)
    # provider validated in resurrect/1 (:error already 422'd) → a known slug or
    # the hetzner default; region/size ride through nil-honest (D23).
    provider = launch_provider(conn.body_params["provider"])
    region = string_param_or_nil(conn.body_params["region"])
    server_type = string_param_or_nil(conn.body_params["server_type"])

    case Registry.register_managed_barkpark(team, name, slug,
           provider: provider,
           region: region,
           server_type: server_type
         ) do
      {:ok, barkpark} ->
        case Registry.enqueue_resurrect_job(barkpark, bundle_ref) do
          {:ok, job} ->
            # OC24: row + job both landed — record the operator trigger with
            # the RESOLVED bundle (a storage key, not a secret). The enqueue-
            # failure branch below deletes the row again, so only this branch
            # is a resurrect that actually happened.
            audit_lifecycle_trigger(conn, team, barkpark.id, "barkpark.resurrected", %{
              name: name,
              bundle_ref: bundle_ref
            })

            # Live-push the new restoring row to any open dashboard tab.
            push_event(team.id, "fleet")
            # Echo the RESOLVED bundle_ref so a "resurrect latest" caller learns
            # which bundle was chosen (the console names it in the step feed).
            json(conn, 202, %{ok: true, id: barkpark.id, job_id: job.id, bundle_ref: bundle_ref})

          # A resurrect is USELESS without its job (the worker pulls the
          # bundle), so — unlike go_live's best-effort enqueue — an enqueue
          # failure is surfaced honestly rather than a lying 202. Rare (a DB
          # blip; the fresh row can't already hold an active resurrect job).
          # Roll back the just-created row so it neither bills nor blocks a
          # name re-resurrect via the live-twin guard.
          {:error, reason} ->
            Logger.error(
              "resurrect: failed to enqueue resurrect job for barkpark #{barkpark.id}: " <>
                inspect(reason)
            )

            Registry.delete_barkpark(barkpark)
            json(conn, 500, %{error: "enqueue_failed"})
        end

      # The quota backstop fired in register_barkpark/2 — surface as 403 (never
      # a 500), mirroring go_live.
      {:error, :limit_reached} ->
        json(conn, 403, %{
          error: "limit_reached",
          limit: Billing.barkpark_limit(team),
          upgrade_path: "/v1/billing/checkout"
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        json(conn, 422, %{error: "invalid", details: errors(changeset)})
    end
  end

  # A request param is "present" when it is a non-blank binary (a whitespace-only
  # name is as absent as nil).
  defp present_param?(v) when is_binary(v), do: String.trim(v) != ""
  defp present_param?(_), do: false

  ## register handler (POST /v1/auth/register)

  # The transactional signup: register the user, create a team (the given
  # team_name, or one derived from the email local-part, deduped against the
  # slug unique), grant the user "owner" on it, and mint a session token. All
  # four steps share ONE transaction — any failure rolls the whole thing back,
  # so a rejected membership/token never strands a half-created user+team.
  #
  # The citext unique index on users.email is the race backstop: two concurrent
  # registers that both pass the pre-insert get_user_by_email check collide here
  # on insert; the loser's changeset carries the unique-constraint error, which
  # register_error/1 maps to 409 (never a 500).
  defp register(email, password, team_name, session_opts) do
    result =
      Repo.transaction(fn ->
        with {:ok, user} <- Accounts.register_user(%{email: email, password: password}),
             {:ok, team} <- create_signup_team(user, team_name),
             {:ok, _membership} <- Accounts.add_member(team, user, "owner"),
             # BILL-1: grant the new team a self-serve FREE TRIAL in the SAME tx,
             # right after the team+membership land — so a brand-new user is
             # ENTITLED immediately and can go live with no operator/SSH and no
             # card. No gateway/charge; the trial lapses after 14 days (entitlement
             # enforced against current_period_end), after which they subscribe.
             # Inside the transaction so a trial-grant failure rolls the whole
             # signup back rather than stranding an un-entitled team.
             {:ok, _trial} <- Billing.grant_trial(team),
             # notifications-email: auto-create the team's email-notification
             # settings row in the SAME tx (mirrors Coolify's Team.php:59
             # auto-create). A lazy get_or_create_settings/1 backstops any team
             # that predates this.
             {:ok, _settings} <- Notifications.ensure_settings(team),
             # ORIGIN "register": stamped HERE, at the write site, not by the
             # caller — `register/4` has exactly one caller and this insert is
             # the account's very first session, so "register" is the whole
             # truth about it. Appending to the passed-in `session_opts` keeps
             # `session_opts/1` itself origin-free.
             {:ok, token} <-
               Accounts.create_user_session_token(
                 user,
                 session_opts ++ [origin: "register"]
               ) do
          %{user: user, team: team, token: token}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, payload} -> {:ok, payload}
      {:error, %Ecto.Changeset{} = changeset} -> classify_register_error(changeset)
      {:error, other} -> {:error, other}
    end
  end

  # Create the signup team. With an explicit team_name we slugify it directly;
  # otherwise we derive a slug from the email local-part. Either way the slug is
  # deduped against the teams.slug unique by appending -2, -3, … on collision.
  #
  # Dedup is a PRE-INSERT lookup (get_team_by_slug), NOT a try-insert-on-error
  # loop: this whole call runs inside the signup transaction, and a unique
  # violation there aborts the entire Postgres transaction (25P02) — every later
  # statement then fails. So we pick a free slug first, then insert once. The
  # teams.slug unique index is still the race backstop; a genuine concurrent
  # collision surfaces as a changeset error → 422 (rare, user-retriable).
  defp create_signup_team(user, team_name) do
    {name, base_slug} =
      if is_binary(team_name) and String.trim(team_name) != "" do
        {team_name, slugify(team_name)}
      else
        local = user.email |> String.split("@") |> List.first()
        {local, slugify(local)}
      end

    Accounts.create_team(%{name: name, slug: dedupe_slug(base_slug, 0)})
  end

  # Find a free slug by pre-checking the teams.slug unique: base, then base-2,
  # base-3, … Bounded so a pathological run can't loop forever (falls through to
  # the base slug, letting the insert + unique index reject it as a 422).
  defp dedupe_slug(base_slug, attempt) when attempt < 50 do
    candidate = if attempt == 0, do: base_slug, else: "#{base_slug}-#{attempt + 1}"

    if Accounts.get_team_by_slug(candidate),
      do: dedupe_slug(base_slug, attempt + 1),
      else: candidate
  end

  defp dedupe_slug(base_slug, _attempt), do: base_slug

  # A changeset bubbling out of the transaction is either a duplicate-email
  # unique-violation (→ :email_taken, the citext race backstop) or a genuine
  # validation failure (→ the changeset, mapped to 422 by the caller).
  defp classify_register_error(%Ecto.Changeset{errors: errors} = changeset) do
    email_unique? =
      Enum.any?(errors, fn
        {:email, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
        _ -> false
      end)

    if email_unique?, do: {:error, :email_taken}, else: {:error, changeset}
  end

  # arpss w3 — the enumeration seal. Validate ONLY the password's FORMAT (the same
  # length window `User.validate_password/1` enforces: min..72), with NO email
  # lookup and NO hashing, so the register handler can answer 422 for a malformed
  # password BEFORE it ever asks whether the email exists. A validation-only
  # changeset (not `User.password_changeset/2`) is deliberate: the happy path
  # re-hashes inside `register/4`, and hashing here too would bcrypt every signup
  # twice. 72 is the Bcrypt 72-byte input cap User pins as `@max_password_length`;
  # the min tracks `User.min_password_length/0` so the two paths can't drift and
  # the 422 body stays byte-identical to the fresh-email path's `register_error/1`.
  defp register_password_changeset(password) do
    %Accounts.User{}
    |> Ecto.Changeset.cast(%{password: password}, [:password])
    |> Ecto.Changeset.validate_required([:password])
    |> Ecto.Changeset.validate_length(:password,
      min: Accounts.User.min_password_length(),
      max: 72
    )
  end

  # Map a validation changeset to the 422 body. A single offending field becomes
  # `{error: "<field>_invalid"}`; multiple fields fall back to
  # `{error: "validation_failed", details: {...}}`. Either way `details` carries
  # the per-field messages for an honest client surface.
  defp register_error(%Ecto.Changeset{} = changeset) do
    details = errors(changeset)

    case Map.keys(details) do
      [field] -> %{error: "#{field}_invalid", details: details}
      _ -> %{error: "validation_failed", details: details}
    end
  end

  ## Serializers — the precise JSON shapes cloud-12b's Go client must match.

  # instance-admin-token: build the succeed_job opts from the (optional) reported
  # admin token. A non-empty binary becomes `[admin_token: t]`; anything else
  # (missing/blank/non-string) yields `[]`, preserving the ip-only succeed path.
  defp succeed_opts(token) when is_binary(token) and token != "", do: [admin_token: token]
  defp succeed_opts(_), do: []

  # claim-fence (bp-c55): pull the OPTIONAL worker-supplied claim_token off a
  # provision-job transition request (body key or `?claim_token=` query param),
  # returning `[claim_token: t]` for a non-empty binary or `[]` otherwise. Absent
  # → the Registry transition falls back to status-only behavior (the compat
  # window for the deployed Go fleet, which doesn't echo the token yet). Additive:
  # the token key is harmless when the Registry ignores it.
  defp claim_token_opts(conn) do
    conn = fetch_query_params(conn)

    case conn.body_params["claim_token"] || conn.query_params["claim_token"] do
      t when is_binary(t) and t != "" -> [claim_token: t]
      _ -> []
    end
  end

  # dwb-4: build the full succeed_job opts — admin token + the (optional)
  # content-bootstrap outputs map. A non-map bootstrap payload is dropped, so a
  # malformed/absent field preserves the pre-bootstrap succeed path.
  defp succeed_opts(token, %{} = bootstrap), do: succeed_opts(token) ++ [bootstrap: bootstrap]
  defp succeed_opts(token, _bootstrap), do: succeed_opts(token)

  # task-5866ec745efcd7f7: build the succeed_job opts from the (optional)
  # reported ledger-token id. A non-empty binary becomes `[token_id: t]`;
  # anything else (missing/blank/non-string — every pre-fix worker) yields `[]`,
  # preserving the ip-only succeed path byte-for-byte.
  defp fleet_token_id_opts(token_id) when is_binary(token_id) and token_id != "",
    do: [token_id: token_id]

  defp fleet_token_id_opts(_), do: []

  # dwb-4 launch validation: nil/blank means "no template" (valid — the
  # pre-template path); a non-empty string must be in the known catalog; any
  # other shape (list/map/number) is invalid.
  defp valid_template?(nil), do: true
  defp valid_template?(""), do: true
  defp valid_template?(t) when is_binary(t), do: Registry.known_template?(t)
  defp valid_template?(_), do: false

  defp template_or_nil(t) when is_binary(t) and t != "", do: t
  defp template_or_nil(_), do: nil

  # Normalize the launch `provider` param (charter Decision 9). Absent/blank → the
  # hetzner default (a provider-less launch is Hetzner, as before). A known slug →
  # itself. Anything else (an unknown string, a non-binary) → `:error`, which the
  # go_live cond maps to a 422 invalid_provider before any row/box exists.
  defp launch_provider(p) when is_binary(p) do
    cond do
      p == "" -> "hetzner"
      p in BarkparkCloud.Registry.Provider.kinds() -> p
      true -> :error
    end
  end

  defp launch_provider(nil), do: "hetzner"
  defp launch_provider(_), do: :error

  # A request param coerced to a trimmed non-blank binary, else nil — so a bare or
  # whitespace-only region/server_type leaves the column NULL (the claim's
  # warm-pool fallback), never persists "".
  defp string_param_or_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_param_or_nil(_), do: nil

  # `pressure` is the PREFETCHED latest health beat for this box
  # (`Registry.latest_health_payload_map/1`), passed IN as a parameter and
  # defaulting to nil. Deliberately a parameter, not a lookup inside this
  # function: four of the five call sites serialize a box that by construction
  # has never beaten (a just-created / just-enqueued instance), and an internal
  # lookup would put a per-row query on those four WRITE paths. nil → the
  # `pressure` key renders all-unmetered, never zeros.
  # `queued_age` is the PREFETCHED queued-deployment age for this box
  # (`Registry.queued_deploy_age_map/1`), same parameter-not-lookup rule as
  # `pressure` above: only the fleet list computes it (one GROUP BY for the
  # page); the four write-path call sites serialize a box that by construction
  # has no queued container deployment and pass nothing. nil means NONE QUEUED
  # — clients own the stalled threshold (charter D6), the payload only carries
  # the raw number.
  defp barkpark_json(bp, provision \\ nil, deprovision \\ nil, pressure \\ nil, queued_age \\ nil) do
    base = %{
      id: bp.id,
      name: bp.name,
      slug: bp.slug,
      url: bp.url,
      host: bp.host,
      mode: bp.mode,
      health_status: bp.health_status,
      agent_status: bp.agent_status,
      version: bp.version,
      git_commit: bp.git_commit,
      # dr-w22-bl SINCE WHEN this box has served that commit. The `(sha,
      # first_seen)` history already existed — every 60 s beat lands in
      # `agent_events` with the full report and AgentRetentionWorker keeps 14
      # days of it (measured on prod 2026-09-01: 132,120 rows spanning
      # 2026-08-18T03:30:20Z -> 2026-09-01T23:19:22Z) — but its ONLY reader is
      # `GET /v1/barkparks/:id/events`, which is `Auth.require_user` and pages
      # at 200 rows: about three hours of a fourteen-day record, handed to a
      # NARROWER caller than this route's `require_user_or_pat` + `read`. The
      # materialised column answers the question here instead, so no page and
      # no auth widening is needed to get it.
      #
      # NULL is UNMEASURED, never "now" — the same contract `commit_distance`
      # carries below. A box that has not changed sha since the column shipped,
      # and a box whose stored sha was empty when a sha first arrived, both read
      # NULL because neither transition was OBSERVED. Renderers must paint it as
      # unmetered and must not sort it as fresh.
      git_commit_first_seen_at: bp.git_commit_first_seen_at,
      last_seen_at: bp.last_seen_at,
      # Reachability bookkeeping (health-status) — the raw counters behind the
      # health axis, so a client can state the EVIDENCE ("N consecutive missed
      # heartbeat windows", "the one unreachable alert has been sent") instead of
      # inferring it from `health_status` alone. Facts only: `unreachable_count`
      # is the consecutive-miss counter the StalenessWorker bumps per tick, and
      # `unreachable_notification_sent` is the once-per-outage alert latch.
      unreachable_count: bp.unreachable_count,
      unreachable_notification_sent: bp.unreachable_notification_sent,
      team_id: bp.team_id,
      # Provider-neutral hosting (charter Decision 9): the cloud this box lives on
      # (the SPA fleet provider-chip) + the launch placement/size. Identity only —
      # never a status axis. `provider` defaults to hetzner on legacy rows.
      provider: bp.provider,
      region: bp.region,
      server_type: bp.server_type,
      # Billing-suspension axis (subscription-billing) — the dashboard renders a
      # "suspended (billing)" state distinct from a health-down box.
      suspended: bp.suspended,
      suspended_reason: bp.suspended_reason,
      # cch-w54-bl SINCE WHEN. Suspension is one UPDATE of THREE columns
      # (`Registry.suspend_barkpark/2` and the bulk
      # `Registry.suspend_team_barkparks/2` behind it) and only two of them
      # reached a wire, so every reader could say a box was suspended and why
      # but never since when.
      #
      # The absence was not rendered as absence. `suspendedCardBannerHtml` in
      # app.js fell through to a helper computed off `sub.current_period_end`
      # — the NEXT renewal day — so a box suspended today painted a FUTURE date
      # as a past-tense suspension day. A field with no reader is invisible; one
      # whose absence is papered over by a wrong value is a silent-failure
      # defect, which is why the fix is the field and not the copy.
      #
      # THE CONSUMER SIDE IS CLOSED TOO. `suspendedCardBannerHtml` reads this
      # key through `suspendedDay` on both the billing and quota arms, and the
      # helper that borrowed the renewal day was DELETED rather than left
      # orphaned — the card has no path to a subscription date any more. Named
      # by SYMBOL and not by line: app.js is edited constantly and a line
      # number here would rot inside a week.
      #
      # NULL means NOT SUSPENDED, never "suspended at an unknown time":
      # `unsuspend_barkpark/1` and the bulk resume clear all three columns
      # together, so a live box never carries a stale stamp. Consumers render
      # null as no-date and must NOT substitute a billing date for it — the
      # console's own guard for that is the `never from current_period_end`
      # case in `__app.test.mjs`.
      suspended_at: bp.suspended_at,
      # isu-6 self-update status — the cached mirror of the instance's OWN
      # update verdict (the UpdateStatusWorker sweep / post-trigger refresh).
      update_state: bp.update_state,
      update_running_release: bp.update_running_release,
      update_latest_release: bp.update_latest_release,
      update_checked_at: bp.update_checked_at,
      # WHY the update verdict above is unknown, when it is. The
      # UpdateStatusWorker writes this the moment a status probe cannot answer
      # (`identity_refused`, a transport failure, an unparseable reply) — it is
      # the plane's OWN measurement of the cause, and until now it had no reader
      # anywhere outside its producer, so the console said "No update state
      # reported yet" about a box that had in fact answered 401.
      update_unavailable_reason: bp.update_unavailable_reason,
      # dr-w24-s2 COMMIT DISTANCE — the control plane's OWN measurement of the
      # commit each box actually serves (`BarkparkCloud.GitHub.CommitDistance`,
      # written hourly by the UpdateStatusWorker), beside the box's release-tag
      # self-grade above. They are DIFFERENT questions and they disagree today:
      # prod carries rows reading `commit_distance: 2493, commit_ancestry:
      # "behind", update_state: "current"` — the tag grade is pinned at `current`
      # because no release tag has been cut since 2026-07-08, however far `main`
      # runs ahead. Until this line existed the measurement had ZERO readers: no
      # serializer, no CLI, no console.
      #
      # `commit_distance` is NULL for UNMEASURED — an empty `git_commit`, a 404
      # on an unknown sha, and a rate-limit refusal all land NULL, never 0 — so
      # every consumer must render it as unmetered and sort it to the TOP
      # (registry/barkpark.ex, the field's own contract). `commit_ancestry` is
      # one of unknown|current|behind|ahead_of_main|diverged and
      # `commit_distance_checked_at` says when we last asked, so a consumer can
      # age the reading instead of trusting it blindly.
      commit_distance: bp.commit_distance,
      commit_ancestry: bp.commit_ancestry,
      commit_distance_checked_at: bp.commit_distance_checked_at,
      # isu-w5.2 fleet-autoupdate policy + channel — the console renders the
      # rollout state (enabled/paused/pinned/channel) per row. EXACT names —
      # sibling slices S3/S4 read these off the fleet-list JSON. The in-flight
      # marker rides along so the console's "Updating" badge can outrank a
      # stale cached verdict while a rollout is actively landing.
      autoupdate_enabled: bp.autoupdate_enabled,
      autoupdate_paused: bp.autoupdate_paused,
      pinned_release: bp.pinned_release,
      channel: bp.channel,
      autoupdate_triggered_at: bp.autoupdate_triggered_at,
      # Instance custom domain — the attached platform-zone host (nil until a
      # team attaches one), so the dashboard can render it on the fleet row.
      custom_host: bp.custom_host,
      # BP-ONB-09 on-demand VERIFY verdict — the cached headline of the last
      # golden-path probe run (nil until the suite first runs), so the fleet row
      # can render a "last verified" fact. `verify_reachable` false is a real
      # verdict, distinct from the null "never verified".
      last_verified_at: bp.last_verified_at,
      verify_reachable: bp.verify_reachable,
      # Personal Dev Fleet GROUP record (Wave C, PDF-D61) — the machine's role in
      # a fleet (main | support | nil ungrouped), the main it binds to, and the
      # opaque revocation-token id. `fleet_token_id` is deliberately NOT a secret
      # (custody note in the schema), so it is safe to serialize here.
      fleet_role: bp.fleet_role,
      fleet_parent_id: bp.fleet_parent_id,
      fleet_token_id: bp.fleet_token_id,
      # jpf-w1-queue-age-alarm (charter D6): age in SECONDS of the oldest
      # `queued` container-site deployment on this box, nil when none. A NUMBER
      # rather than a verdict on purpose — the Go CLI and the SPA own the
      # 5-minute `deploy_stalled` threshold and can render "queued 7m" honestly;
      # the CP stays read-only here (the 15-min reaper is a different, MUTATING
      # mechanism and never sees a never-claimed row). Always present, so a
      # consumer branches on the VALUE, not the key.
      queued_deploy_age_seconds: queued_age,
      inserted_at: bp.inserted_at
    }

    base
    |> merge_job_status(:provision_status, :provision_error, provision)
    |> merge_job_status(:deprovision_status, :deprovision_error, deprovision)
    |> merge_provision_steps(provision)
    |> merge_provision_console(provision)
    |> merge_pressure(pressure)
  end

  # dr-w4-s4: the host's LIVE resource pressure on the fleet row. Until now
  # `barkpark_json/3` carried ~30 fields and ZERO vitals, so a box at 100% cpu
  # and load1 5.57 was indistinguishable from an idle one to any consumer that
  # ranks the fleet off this payload.
  #
  # Read straight off the agent-shaped RAW jsonb of the latest health beat (not
  # `Telemetry.normalize/1`, whose fixed envelope drops swap and the BEAM's own
  # footprint — the two signals that name a box swapping itself to death).
  #
  # HONESTY LAW, and the whole point of the slice: an ABSENT key and the agent's
  # `-1` "probe not wired" sentinel both render `nil` — UNMETERED — never 0. A
  # box whose agent predates the vitals beat must read "we did not measure",
  # never "measured, and it is fine". Same guard the usage meters already keep
  # (`n >= 0`). `swap_used_percent` travels WITH `swap_total_bytes` because a
  # bare percent cannot separate a swapless box (0, 0) from an idle one (0, >0).
  # `reported_at` is the beat's own timestamp, so a consumer can age the reading
  # rather than trust it blindly.
  #
  # The key is always present (all-nil when the box has never beaten), so a
  # consumer branches on the VALUES, not on the key's existence.
  defp merge_pressure(map, %{payload: payload, reported_at: at}) when is_map(payload) do
    Map.put(map, :pressure, %{
      cpu_percent: measured_or_nil(Map.get(payload, "cpu_percent")),
      # The strained fence's DENOMINATOR (charter D52): sustained load-PER-CORE,
      # never a raw load number and never a hardcoded core count. It rides here
      # rather than beside `server_type` because `server_type` is a nullable
      # LAUNCH PIN, not observed truth — wrong or empty on adopted boxes — while
      # this is `runtime.NumCPU()` off the beat itself. An agent that predates
      # the field simply omits it, so it renders nil and a nil vital never
      # strains (D42's factual arm).
      cpu_cores: measured_or_nil(Map.get(payload, "cpu_cores")),
      mem_used_percent: measured_or_nil(Map.get(payload, "mem_used_percent")),
      load1: measured_or_nil(Map.get(payload, "load1")),
      # The SUSTAIN signal (charter D67), and the reason the fence is evaluatable
      # from this payload at all: this row is ONE beat
      # (`latest_health_payload_map/1` is a DISTINCT ON … ORDER BY inserted_at
      # DESC), so a "2 of the last 3 beats" rule has no window to read here.
      # load15 is a 15-minute kernel EWMA — sustained, and delivered as one
      # scalar. `load1` stays for the reason string's present-tense colour: a box
      # can read load1 0.64/core (idle-looking) while load15 reads 1.89/core.
      load15: measured_or_nil(Map.get(payload, "load15")),
      # THE DENOMINATOR (charter D103). `err_5xx_per_s` is a rate whose severity
      # cannot be read without the volume it came out of: 0.22 5xx/s is 14.4% of
      # traffic at the median observed n and 2.0% at the max — a 7x severity
      # spread from one unchanged number. So the request rate rides WITH the
      # error rate, always, and a consumer that prints a share without it is
      # printing a number it cannot bound. Same honesty law as every vital
      # above: absent key or the agent's -1 sentinel renders nil, and a
      # genuinely idle box (a measured 0.0 req/s) survives as a measured zero.
      req_per_s: measured_or_nil(Map.get(payload, "req_per_s")),
      # p95 request latency, and it lands here as a VITAL — colour for a reason
      # string — and is REFUSED as a fence (charter D131). The beat carries ONE
      # p95 off a 60s per-slot ring that dies on every blue/green flip, so it is
      # a small-sample lottery; most boxes in the field still report the -1
      # unwired sentinel, which renders nil rather than "0ms — instant".
      p95_ms: measured_or_nil(Map.get(payload, "p95_ms")),
      # 5xx per second off the instance's own 60s ring (D75). Same law as every
      # vital above: an absent key (an agent predating the field) and the -1
      # sentinel (probe unwired, instance too old, or an EMPTY window) both
      # render nil. A fabricated 0 here would read "this box is serving no
      # errors" about a box nobody measured — the most reassuring lie available.
      err_5xx_per_s: measured_or_nil(Map.get(payload, "err_5xx_per_s")),
      disk_used_percent: measured_or_nil(Map.get(payload, "disk_used_percent")),
      swap_used_percent: measured_or_nil(Map.get(payload, "swap_used_percent")),
      swap_total_bytes: measured_or_nil(Map.get(payload, "swap_total_bytes")),
      beam_pss_bytes: measured_or_nil(Map.get(payload, "beam_pss_bytes")),
      beam_swap_bytes: measured_or_nil(Map.get(payload, "beam_swap_bytes")),
      # The two beam figures above are useless without knowing WHICH process
      # they came from. The box runs blue/green and two beam.smp processes
      # coexist through a cutover, so a beam_swap series stepping 0 -> ~190 MB
      # across a flip is TWO PROCESSES, not a leak. These are STRINGS, so they
      # take named_or_nil rather than measured_or_nil: an agent predating the
      # attribution omits the key, and a box with no barkpark-slot@ cgroup
      # sends "" for the slot — both are "not attributable" and render nil.
      # Never a fabricated pid, which would attribute a measurement to a
      # process nobody identified.
      beam_pid: named_or_nil(Map.get(payload, "beam_pid")),
      beam_slot: named_or_nil(Map.get(payload, "beam_slot")),
      # WHO is spending the box. Every vital above is an AGGREGATE and none of
      # them can answer that: on 2026-08-06 guerrilla read load 6.3 on 2 cores
      # with /api/schemas flapping 200/500/500, and the cause was ONE orphaned
      # `journalctl -u bp-site-build-* --since -14d` left by a dead SSH session,
      # 2h46m old at 66.3% of a core. A human found it because a `bp` write
      # failed. Nothing on this row could have named it.
      #
      # This is the one pressure key that is a LIST, and it keeps a distinction
      # the scalars express with nil alone: `nil` is UNMEASURED (an agent that
      # predates the probe, or a box without `ps`), while `[]` is MEASURED AND
      # QUIET. Collapsing those would re-enact the incident exactly — "we did not
      # look" rendered as "nothing to see".
      runaway_procs: runaway_procs(Map.get(payload, "runaway_procs")),
      # WHETHER THE DEPLOY PAIR IS INTACT — the one fact on this block that is
      # not about the host at all, and the one nothing here could say. On
      # 2026-08-06 `barkpark-slot@blue` sat in `failed` (an 8m30s stop-sigterm
      # timeout, SIGKILLed) while every operator surface read `ok`, because the
      # verdict was computed from the vitals above and had ZERO unit-state
      # inputs — it would have read `ok` with either half dead, and with both.
      #
      # These are systemd's OWN properties, relayed, never a verdict: whether a
      # failed half matters depends on whether the OTHER half is serving, and
      # that is the consumer's call to make (bp cloud status makes it in
      # slotUnitMarker). Same three-state law as runaway_procs, and for the same
      # reason: `nil` is UNMEASURED (no systemd, no dbus, an agent predating the
      # probe) and `[]` is MEASURED AND INTACT. Rendering the first as the second
      # would re-create the exact silence the field exists to break.
      slot_units: slot_units(Map.get(payload, "slot_units")),
      # How many failed SITE units the agent's cap hid. A measured 0 means the
      # list is complete; nil means unmeasured (absent key, or the agent's -1
      # sentinel) — so a short list can never pass for a whole one.
      slot_units_truncated: measured_or_nil(Map.get(payload, "slot_units_truncated")),
      reported_at: at
    })
  end

  defp merge_pressure(map, _), do: Map.put(map, :pressure, @unmetered_pressure)

  # A vital counts as MEASURED only when it is a non-negative number. Anything
  # else — absent, non-numeric, or the agent's `-1` unwired sentinel — is nil.
  # The string counterpart of measured_or_nil: a non-empty binary is an
  # attribution, and anything else — absent, non-binary, or the empty string the
  # agent sends when a pid has no barkpark-slot@ cgroup — is nil. "Not
  # attributable" must never render as a guess.
  defp named_or_nil(s) when is_binary(s) and s != "", do: s
  defp named_or_nil(_), do: nil

  defp measured_or_nil(n) when is_number(n) and n >= 0, do: n
  defp measured_or_nil(_), do: nil

  # The agent's `runaway_procs` rows, kept in the agent's own order (worst
  # first — by CPU-seconds actually spent) and reduced to the four fields a
  # surface renders. A row survives only when ALL FOUR are readable: a runaway
  # with no command is a number an operator cannot act on, and one with no
  # elapsed or cpu is an accusation with no evidence, so a malformed row is
  # DROPPED rather than rendered half-blank.
  #
  # A non-list — absent key, JSON null, garbage — is nil: NOT measured, which is
  # not the same as measured and empty. An honestly empty list stays [].
  defp runaway_procs(rows) when is_list(rows), do: Enum.flat_map(rows, &runaway_proc/1)
  defp runaway_procs(_), do: nil

  defp runaway_proc(row) when is_map(row) do
    with pid when is_number(pid) <- measured_or_nil(Map.get(row, "pid")),
         elapsed when is_number(elapsed) <- measured_or_nil(Map.get(row, "elapsed_s")),
         cpu when is_number(cpu) <- measured_or_nil(Map.get(row, "cpu_percent")),
         command when is_binary(command) <- named_or_nil(Map.get(row, "command")) do
      [%{pid: pid, elapsed_s: elapsed, cpu_percent: cpu, command: command}]
    else
      _ -> []
    end
  end

  defp runaway_proc(_), do: []

  # The agent's `slot_units` rows, in the agent's own order (the blue/green pair
  # first, then the failed site units), reduced to the six properties a surface
  # renders. Same non-list-is-nil law as runaway_procs above: absent key, JSON
  # null or garbage is NOT MEASURED, which is not the same as measured and intact.
  defp slot_units(rows) when is_list(rows), do: Enum.flat_map(rows, &slot_unit/1)
  defp slot_units(_), do: nil

  # A row survives on its THREE NAMING fields — the unit, and the two systemd
  # state axes. main_pid / exec_main_status / state_since are OPTIONAL and render
  # nil when unreadable, because dropping the whole row over an unparseable pid
  # would delete the `failed` that is the point of the row.
  #
  # `result` and `exec_main_status` are kept as a PAIR on purpose: measured
  # 2026-09-01, barkpark-site@search__b reads Result=exit-code with
  # ExecMainStatus=143 — 128+15, a clean SIGTERM retire that systemd files as an
  # exit code (PR #14863 adds SuccessExitStatus=143). A consumer handed `result`
  # alone would read a deliberate stop as a crash.
  defp slot_unit(row) when is_map(row) do
    with unit when is_binary(unit) <- named_or_nil(Map.get(row, "unit")),
         active when is_binary(active) <- named_or_nil(Map.get(row, "active_state")),
         sub when is_binary(sub) <- named_or_nil(Map.get(row, "sub_state")) do
      [
        %{
          unit: unit,
          active_state: active,
          sub_state: sub,
          result: named_or_nil(Map.get(row, "result")),
          main_pid: measured_or_nil(Map.get(row, "main_pid")),
          exec_main_status: measured_or_nil(Map.get(row, "exec_main_status")),
          state_since: named_or_nil(Map.get(row, "state_since"))
        }
      ]
    else
      _ -> []
    end
  end

  defp slot_unit(_), do: []

  # The fleet-ops row shape (GET/POST /v1/internal/barkparks): the identity +
  # placement fields the `bp cloud hetzner instance` verbs cross-check, plus
  # dns_label (derived — the registry never stores the label itself) and the
  # latest job statuses. Leaner than barkpark_json on purpose: no steps/console
  # payloads, this is a fleet list.
  defp internal_barkpark_json(bp, provision, deprovision) do
    %{
      id: bp.id,
      name: bp.name,
      slug: bp.slug,
      url: bp.url,
      host: bp.host,
      dns_label: Barkpark.subdomain_from_url(bp),
      mode: bp.mode,
      health_status: bp.health_status,
      suspended: bp.suspended,
      team_id: bp.team_id,
      inserted_at: bp.inserted_at
    }
    |> merge_job_status(:provision_status, :provision_error, provision)
    |> merge_job_status(:deprovision_status, :deprovision_error, deprovision)
  end

  defp merge_job_status(map, status_key, error_key, %{status: status, error: error}),
    # Humanize the raw provision/deprovision error (e.g. "exceeded max provision
    # attempts (3)") at the JSON boundary so the fleet banner reads plainly. DB
    # stays raw for the provision_failed email alert + ops.
    do: Map.merge(map, %{status_key => status, error_key => FailureCopy.humanize(error)})

  defp merge_job_status(map, _status_key, _error_key, _), do: map

  # dwb-14: surface the latest provision job's step narration so a freshly-loaded
  # /new page renders honest, refresh-durable progress. Always present (defaults
  # to []) so the SPA can branch on presence without an existence check.
  #
  # wave 13 S2: each step's "detail" is a REMOTE capture (an ssh stderr fold, a
  # provider body) and reaches a person's screen verbatim, so it is scrubbed at
  # this boundary. The stored row keeps the raw bytes for ops.
  #
  # cchi-w26 / D310 tail: scrubbing is not the whole boundary. `app.js` paints the
  # HUMANIZED `provision_error` as the timeline's failureDetail while the step
  # rows directly beneath it carried raw provider jargon — one event, two stories,
  # the exact asymmetry wave 26 S3 closed in the provision_failed email. A bare
  # `FailureCopy.humanize/1` is the WRONG remedy here (and `Sites.Deploy`'s `stage_caption/2` moduledoc
  # says so): it REPLACES the narration, and this payload holds the only copy of
  # it. `class_then_capture/1` emits BOTH.
  defp merge_provision_steps(map, %{steps: steps}) when is_list(steps),
    do: Map.put(map, :provision_steps, Enum.map(steps, &class_then_capture_entry(&1, "detail")))

  defp merge_provision_steps(map, _), do: Map.put(map, :provision_steps, [])

  # dwb-16: surface the latest provision job's LIVE console so /new renders a live,
  # refresh-durable console. Always present (defaults to []) so the SPA can branch
  # on presence without an existence check.
  #
  # wave 13 S2: console lines are raw remote output — scrubbed here, raw in the DB.
  # cchi-w26 / D310 tail: same both-not-either fold as the step details above.
  defp merge_provision_console(map, %{console: console}) when is_list(console),
    do: Map.put(map, :provision_console, Enum.map(console, &class_then_capture_entry(&1, "line")))

  defp merge_provision_console(map, _), do: Map.put(map, :provision_console, [])

  # cchi-w26 / task-3b59e1ea682c03a1 (charter D310): CLASS ALONGSIDE CAPTURE, the
  # shape `Notifications.EventEmail.cause_then_capture/1` already ships.
  #
  # A provision step's `detail` and a console `line` are the ONLY copy of the
  # worker's narration on this payload — there is no sibling key holding the raw
  # bytes, which is why `Sites.Deploy.stage_caption/2` (classify-or-scrub) is
  # right on a deploy stage and wrong here: it would destroy the narration waves
  # 12-14 built. So this fold emits the class AND keeps the capture, in one
  # string, in the element group the person is already looking at.
  #
  # An entry whose capture does NOT classify is BYTE-IDENTICAL to what this
  # boundary shipped before (`FailureCopy.raw/1` = strip_ansi |> scrub), so no
  # existing narration moves.
  defp class_then_capture_entry(%{} = entry, key) do
    case Map.fetch(entry, key) do
      {:ok, value} when is_binary(value) -> Map.put(entry, key, class_then_capture(value))
      _ -> entry
    end
  end

  defp class_then_capture_entry(entry, _key), do: entry

  # STRIP FIRST, THEN CLASSIFY — the same order `cause_then_capture/1` documents
  # and for the same load-bearing reason. `humanize/1` ends `scrub |> strip_ansi`,
  # so on its PASS-THROUGH arm (an unclassified capture returns itself) it scrubs
  # colourised bytes — the leaky order. Feeding it an already-stripped capture
  # makes that arm land on exactly `capture`, which keeps the `^capture` equal-arm
  # below firing (a colourised unclassified capture would otherwise fall to the
  # `cause` arm and print the leaky pass-through paragraph ABOVE the clean one).
  defp class_then_capture(value) do
    stripped = FailureCopy.strip_ansi(value)
    capture = FailureCopy.scrub(stripped)

    case FailureCopy.humanize(stripped) do
      ^capture -> capture
      cause -> "#{cause} — #{capture}"
    end
  end

  # wave 13 S2: redact secret-shaped substrings in the string-valued keys of a
  # step/console entry. No-ops on a non-map entry and on a non-binary value, so a
  # shape the worker has not written yet passes through rather than crashing the
  # list serializer.
  # Keys are string-typed on a JSONB-loaded step/console entry and atom-typed on
  # a map this module composed (the stage fold), so both are accepted.
  defp scrub_entry(entry, key) when not is_list(key), do: scrub_entry(entry, [key])

  defp scrub_entry(%{} = entry, keys) when is_list(keys) do
    Enum.reduce(keys, entry, fn key, acc ->
      case Map.fetch(acc, key) do
        # dr-w22-s1: `raw/1`, never a bare `scrub/1`. These entries are UNclassified
        # remote captures, and a CSI run immediately left of a key blocks the
        # scrub's key clause — this boundary shipped `\e[31mapi_key=…\e[0m` back
        # byte-identical to input on all three of its call sites.
        {:ok, value} when is_binary(value) -> Map.put(acc, key, FailureCopy.raw(value))
        _ -> acc
      end
    end)
  end

  defp scrub_entry(entry, _keys), do: entry

  # cch-w27-s2: fold a stage/console entry's DETAIL through
  # `Sites.Deploy.stage_caption/2` — classify it when that entry's own status is
  # `failed`, scrub it otherwise. The status is read off the SAME entry, so an
  # entry the worker has not stamped a status on falls to the scrub arm rather
  # than being classified on a guess.
  #
  # Key-typed like `scrub_entry/2` above and for the identical reason: a
  # JSONB-loaded console entry is string-keyed, a map `Sites.Deploy.stages/1`
  # composed is atom-keyed. A non-map entry, or a non-binary detail, passes
  # through untouched — a shape the worker has not written yet must degrade to
  # "no caption", never crash the list serializer.
  defp caption_entry(%{} = entry, status_key, detail_key) do
    case Map.fetch(entry, detail_key) do
      {:ok, detail} when is_binary(detail) ->
        Map.put(entry, detail_key, Sites.Deploy.stage_caption(Map.get(entry, status_key), detail))

      _ ->
        entry
    end
  end

  defp caption_entry(entry, _status_key, _detail_key), do: entry

  ## Onboarding action dispatch + serializer

  defp handle_onboarding_action(conn, %{"action" => "advance", "step" => step}, team) do
    if step in Team.onboarding_steps() do
      case Accounts.advance_onboarding(team, step) do
        {:ok, team} ->
          onboarding_ok(conn, team)

        {:error, %Ecto.Changeset{} = cs} ->
          json(conn, 422, %{error: "invalid", details: errors(cs)})
      end
    else
      json(conn, 422, %{error: "unknown_step"})
    end
  end

  defp handle_onboarding_action(conn, %{"action" => "ack", "step" => step}, team) do
    if step in Team.onboarding_steps() do
      case Accounts.ack_onboarding_step(team, step) do
        {:ok, team} ->
          onboarding_ok(conn, team)

        {:error, %Ecto.Changeset{} = cs} ->
          json(conn, 422, %{error: "invalid", details: errors(cs)})
      end
    else
      json(conn, 422, %{error: "unknown_step"})
    end
  end

  defp handle_onboarding_action(conn, %{"action" => "skip"}, team) do
    case Accounts.skip_onboarding(team) do
      {:ok, team} ->
        onboarding_ok(conn, team)

      {:error, %Ecto.Changeset{} = cs} ->
        json(conn, 422, %{error: "invalid", details: errors(cs)})
    end
  end

  defp handle_onboarding_action(conn, %{"action" => "complete"}, team) do
    if Accounts.onboarding_status(team).all_done? do
      case Accounts.complete_onboarding(team) do
        {:ok, team} ->
          onboarding_ok(conn, team)

        {:error, %Ecto.Changeset{} = cs} ->
          json(conn, 422, %{error: "invalid", details: errors(cs)})
      end
    else
      json(conn, 422, %{error: "steps_incomplete"})
    end
  end

  defp handle_onboarding_action(conn, _bad, _team), do: json(conn, 422, %{error: "bad_action"})

  defp onboarding_ok(conn, team) do
    push_event(team.id, "onboarding")
    json(conn, 200, %{onboarding: onboarding_json(Accounts.onboarding_status(team))})
  end

  # The non-secret onboarding shape for the dashboard's "Finish setup" checklist.
  defp onboarding_json(status) do
    %{
      completed: status.completed?,
      completed_at: status.completed_at,
      last_step: status.last_step,
      all_done: status.all_done?,
      steps: Enum.map(status.steps, &%{key: &1.key, done: &1.done})
    }
  end

  # D554: what this deploy can actually do about money, declared BEFORE the
  # click instead of only in the 422 after it. Both values are computed by
  # CALLING the context (`checkout_capability/0`, `priced_plans/0`) — never a
  # constant — so the wire cannot claim a capability the server does not have.
  # No secrets: the enum says whether a secret exists, never its value, and the
  # plan keys are the public tier names, never gateway price ids.
  defp billing_capability_json do
    %{
      checkout: Atom.to_string(Billing.checkout_capability()),
      plans: Billing.priced_plans()
    }
  end

  # The non-secret subscription shape for the dashboard's Billing view. Gateway
  # customer / subscription ids are NEVER serialized.
  defp subscription_json(sub) do
    %{
      plan: sub.plan,
      status: sub.status,
      # Lifecycle / dunning state (subscription-billing) so the Billing view can
      # show "past due" / "cancels at period end" without a second call.
      past_due: sub.past_due,
      cancel_at_period_end: sub.cancel_at_period_end,
      current_period_end: sub.current_period_end,
      canceled_at: sub.canceled_at,
      started_at: sub.inserted_at,
      # dwb-13: trial surface for the dashboard's days-remaining badge + upgrade
      # CTA. `trial_days_remaining` is nil for a non-trial plan, 0 once expired.
      is_trial: sub.plan == "trial",
      trial_days_remaining: Billing.trial_days_remaining(sub)
    }
  end

  # A team member row for the dashboard's Members view. No secrets — just the
  # identity + the grant.
  defp member_json(%{user: user, role: role, joined_at: joined_at}) do
    %{user_id: user.id, email: user.email, role: role, joined_at: joined_at}
  end

  # A pending invitation. token_hash is NEVER serialized — the plaintext appears
  # exactly once, in the POST response's accept_url.
  defp invitation_json(inv) do
    %{
      id: inv.id,
      email: inv.email,
      role: inv.role,
      expires_at: inv.expires_at,
      inserted_at: inv.inserted_at
    }
  end

  # Mail the invitee the accept link over the PLATFORM transport (the primary
  # invite path). Fail-soft: a relay error is logged but never propagated — the
  # invite is already committed and the accept_url is returned regardless, so a
  # mail hiccup degrades to the copy-paste fallback instead of 500ing the invite.
  # A failed send is OBSERVABLE (logged), never silent (mirrors the request-reset
  # best-effort deliver + the api email-logging convention). Exactly one send per
  # invite creation.
  defp send_invite_email(email, url, team) do
    case Notifications.deliver_invite(%{
           to: email,
           url: url,
           team_name: team.name,
           team_id: team.id
         }) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "invite email delivery failed for team=#{team.id} to=#{email}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Build the copy-paste accept URL the inviter shares out-of-band. The scheme +
  # host come from the request (so dev http:// and prod https://api.barkpark.cloud
  # both work without threading config) — mirrors webhook_url_for/2. The SPA is
  # hash-routed, so the token rides a `#/invitations/accept?token=` fragment.
  defp accept_url(conn, raw_token) do
    scheme = conn.scheme |> to_string()
    host = conn.host

    port_part = https_safe_port_part(scheme, conn.port)

    "#{scheme}://#{host}#{port_part}/#/invitations/accept?token=#{raw_token}"
  end

  # The emailed password-reset link. Same request-derived scheme/host/port as
  # accept_url/2 (dev http:// and prod https://api.barkpark.cloud both work with
  # no threaded config); the SPA is hash-routed, so the token rides a
  # `#/auth/reset?token=` fragment the reset view reads.
  defp reset_url(conn, raw_token) do
    scheme = conn.scheme |> to_string()
    host = conn.host

    port_part = https_safe_port_part(scheme, conn.port)

    "#{scheme}://#{host}#{port_part}/#/auth/reset?token=#{raw_token}"
  end

  # One audit-trail row for GET /v1/audit. `actor` is the actor User flattened to
  # {id, email} (preloaded by list_audit_events) or nil for a system/webhook
  # action. metadata is the free jsonb context map, echoed as-is.
  defp audit_json(e) do
    %{
      id: e.id,
      action: e.action,
      actor: e.actor_user && %{id: e.actor_user.id, email: e.actor_user.email},
      target_type: e.target_type,
      target_id: e.target_id,
      metadata: e.metadata,
      inserted_at: e.inserted_at
    }
  end

  # One delivery-log row for GET /v1/notifications/deliveries. Mirrors audit_json/1:
  # the durable send record flattened to its observable fields.
  #
  # `last_error` USED TO BE the one field here that was not safe (wave 31 S1).
  # This comment claimed it was "a non-sensitive routing label"; it was in fact
  # `inspect/1` of the raw transport term, and gen_smtp names the SMTP relay host
  # in every arm of `host_failure()` — so a DNS failure published, verbatim to
  # every team admin, the relay host that `Notifications.settings_view/1` masks
  # to "********" even for the owner. It is safe NOW, and only because
  # `Notifications.DeliveryReason` classifies at the WRITE seam: `last_error`
  # carries a constant sentence from a closed vocabulary (the sole interpolated
  # value being an integer HTTP status), never a raw capture. The encrypted
  # transport credentials still never live on a Delivery. If a future write site
  # puts a raw term in this column, this row leaks again — the guard is
  # `test/barkpark_cloud/notifications/delivery_reason_test.exs`, not this fence.
  defp delivery_json(d) do
    %{
      id: d.id,
      recipient: d.recipient,
      event: d.event,
      channel: d.channel,
      kind: d.kind,
      status: d.status,
      attempts: d.attempts,
      last_error: d.last_error,
      http_status: d.http_status,
      inserted_at: d.inserted_at
    }
  end

  # One fleet row for GET /v1/operator/fleet — the cross-team operator roll-up.
  # A thin projection of the Barkpark row: identity + rollout channel + update
  # state + the in-flight marker (nil until a self-update is triggered). No
  # secrets — every field is an observable operational label.
  #
  # `apply_arming` is the ARMING ROSTER this route exists to carry: `"unarmed"`
  # names a box whose one-click apply is off. SINCE #13474 that no longer means
  # "the rollout will pause it permanently": the candidate query DISQUALIFIES a
  # measured-unarmed box, so the rollout never advances onto it and never draws
  # the 503 that used to latch `autoupdate_paused` (a flag no code path clears).
  # The word now means SKIPPED, and the box re-enters on its own the moment the
  # hourly sweep reads it armed — so this roster is a retro-arm worklist, not a
  # damage report. It is emitted RAW and three-valued — `null` means NOT MEASURED, never
  # "armed" and never "unarmed" — and the console's arming derivations whitelist
  # the two words rather than testing truthiness, so an unmeasured box can never
  # be rendered onto the worklist. `apply_arming_checked_at` rides with it
  # because a measurement with no age is a measurement an operator cannot grade;
  # it is stamped only when a body was actually decoded, so it is NOT a copy of
  # `update_checked_at`.
  defp operator_fleet_json(bp) do
    %{
      id: bp.id,
      name: bp.name,
      channel: bp.channel,
      update_state: bp.update_state,
      autoupdate_triggered_at: bp.autoupdate_triggered_at,
      apply_arming: bp.apply_arming,
      apply_arming_checked_at: bp.apply_arming_checked_at
    }
  end

  # The census envelope the operator route answers with: `DeployLedger.census/3`
  # (counts per class, per site, and the rate WITH its denominator) plus the
  # `delivery` node — how long content WAITED to reach the web.
  #
  # deploy-reliability W15 S3. `DeployLedger.delivery/3` shipped in W11 with its
  # Go reader (`cloudclient.DeployDelivery`, PR #10192) and NO caller anywhere in
  # `cloud/lib` — proven by MUTATION, not by grep: renaming it left the whole
  # control plane compiling. The consequence was not "a missing feature": the
  # CLI's `renderDeployDelivery` `d == nil` arm printed "NOT MEASURED — this
  # control plane sends no delivery census" to every operator, forever, as the
  # only arm it had ever executed. This route is the ONLY place the census
  # escapes Elixir, so this is the one hop that ends that.
  #
  # It is a SECOND grouped read over the same window, deliberately not folded
  # into `census/3`: census/3 groups by [site_id, stage, status, failure_reason]
  # and carries no time dimension at all, and widening it to carry one would put
  # a latency estimator's censoring policy inside a counter. Two reads, two
  # honest shapes, one envelope.
  defp deploy_census_json(from, to) do
    DeployLedger.census(from, to)
    |> Map.put(:delivery, DeployLedger.delivery(from, to))
  end

  defp provider_json(p) do
    # encrypted_token is NEVER serialized — the connected token stays at rest.
    #
    # `updated_at` is not decoration: `connect_provider/4` is an upsert, so a
    # credential ROTATION mutates :encrypted_token and :updated_at while leaving
    # :id and :inserted_at exactly where they were. Serialize only the five
    # original fields and the payload is BYTE-IDENTICAL before and after a
    # successful rotation — the console would have no way to show that anything
    # happened. `updated_at > inserted_at` is the rotation signal the roster
    # renders as "credential updated <rel>".
    %{
      id: p.id,
      kind: p.kind,
      label: p.label,
      team_id: p.team_id,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  # Did this connect REPLACE an existing credential? Read off the row Postgres
  # returned (`returning: true`), so it reports what actually happened rather
  # than what a pre-read predicted.
  defp provider_rotated?(provider),
    do: DateTime.compare(provider.inserted_at, provider.updated_at) == :lt

  ## Provider-neutral connect + catalog helpers ────────────────────────────────
  ## Hetzner and Azure are peers: one connect endpoint (verify-before-save), one
  ## normalized catalog shape. Kind-specific bits (credential shape, preflight,
  ## raw-catalog fetch) split per provider; the persisted row and the JSON are
  ## one shape.

  # Kinds that own a normalized provisioning CATALOG (GET /v1/providers/:kind/…):
  # a connected account can be listed as a provisioning menu. Cloudflare is NOT
  # here — it is a free-superpower EDGE provider (DNS/TLS/CDN), not a box source,
  # so it has no `build_provider_catalog` clause and must NOT expose a backing-less
  # `GET /v1/providers/cloudflare/catalog`.
  @neutral_kinds ~w(hetzner azure)

  # Kinds a team may CONNECT via POST /v1/providers. A SUPERSET of
  # @neutral_kinds — cloudflare is connectable (it stores a verified credential)
  # WITHOUT being catalog-backed, so the connect gate reads THIS list while the
  # catalog route keeps reading @neutral_kinds. Keeping the two lists distinct is
  # what lets cloudflare connect without leaking a menu route it can't serve.
  @connectable_kinds ~w(hetzner azure cloudflare)

  # The Hetzner Cloud API host. Lives HERE (the impure call site), never in the
  # pure catalog and never in any response. Defined above the first use (module
  # attributes are read at their point of reference).
  @hetzner_api_base "https://api.hetzner.cloud"

  # POST /v1/providers body → verify-before-save → insert. Refuses to persist a
  # credential the provider can't authenticate, returning the per-kind
  # remediation copy instead.
  defp connect_provider_request(conn) do
    kind = conn.body_params["kind"]
    label = conn.body_params["label"]

    with true <- kind in @connectable_kinds,
         {:ok, credential} <- provider_credential(kind, conn.body_params),
         :ok <- preflight_provider(kind, credential) do
      # activity-audit-log: the credential row insert + a `provider.connected`
      # audit event share ONE transaction. The detail map carries only the
      # provider KIND and LABEL — NEVER the credential material (the token /
      # service-principal blob never reaches an audit row or a log line).
      #
      # Rotation is recorded as `rotated: true|false` METADATA, never as a second
      # `provider.rotated` ACTION: `action` lives in the base attrs and is fixed
      # before the transaction runs, and a new action string would widen the
      # closed `noun.verb` vocabulary that `list_audit_events`' `:action_prefix`
      # filter reads. The signal costs nothing and cannot race — the upsert
      # replaces :updated_at on the conflict branch only, while a fresh insert
      # fills both timestamps from ONE autogenerate entry, so
      # `inserted_at < updated_at` IS "this was a replacement". A `Repo.exists?`
      # pre-read would cost a round trip AND read pre-state, mislabelling a
      # rotation as a first connect under a concurrent connect.
      # `target_fun`'s map merges OVER the base attrs, so the whole distinction
      # is one key and `Accounts.audit/3` is untouched.
      audited =
        Accounts.audit(
          %{
            team_id: conn.assigns.current_team.id,
            actor_user_id: conn.assigns.current_user.id,
            action: "provider.connected",
            target_type: "provider",
            metadata: %{kind: kind, label: label}
          },
          fn ->
            Registry.connect_provider(conn.assigns.current_team, kind, credential, label: label)
          end,
          fn provider ->
            %{
              target_id: provider.id,
              metadata: %{kind: kind, label: label, rotated: provider_rotated?(provider)}
            }
          end
        )

      case audited do
        {:ok, provider} ->
          push_event(conn.assigns.current_team.id, "audit")
          json(conn, 201, %{provider: provider_json(provider)})

        {:error, changeset} ->
          json(conn, 422, %{error: "invalid", details: errors(changeset)})
      end
    else
      false ->
        json(conn, 422, %{error: "invalid", details: %{kind: ["is invalid"]}})

      {:error, :bad_credentials} ->
        json(conn, 422, %{error: "invalid", details: %{credentials: ["is invalid"]}})

      {:error, :unverified} ->
        # The credential authenticates to nothing — do NOT save it. Return the
        # per-kind remediation naming the exact console/portal fix.
        json(conn, 422, %{
          error: "provider_unverified",
          remediation: FailureCopy.connect_remediation(kind)
        })
    end
  end

  # DELETE /v1/providers/:kind body → 404-if-none → audited row delete. The label
  # (for the audit metadata) is read BEFORE the delete; the delete + a
  # `provider.disconnected` audit event commit atomically. The detail map carries
  # ONLY the provider KIND and LABEL — NEVER the credential material.
  defp disconnect_provider_request(conn, team, kind) do
    label =
      team
      |> Registry.list_providers()
      |> Enum.find(&(&1.kind == kind))
      |> case do
        nil -> :none
        provider -> provider.label
      end

    case label do
      :none ->
        json(conn, 404, %{error: "not_found"})

      label ->
        audited =
          Accounts.audit(
            %{
              team_id: team.id,
              actor_user_id: conn.assigns.current_user.id,
              action: "provider.disconnected",
              target_type: "provider",
              metadata: %{kind: kind, label: label}
            },
            fn ->
              case Registry.disconnect_provider(team, kind) do
                :ok -> {:ok, :disconnected}
                {:error, _} = err -> err
              end
            end
          )

        case audited do
          {:ok, :disconnected} ->
            push_event(team.id, "audit")
            json(conn, 200, %{ok: true})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # The plaintext credential to validate + encrypt, per kind. hetzner: the token
  # string. azure: the four-field service-principal blob as JSON — the single
  # encrypted_token home holds it (Decision 4), so stray input is dropped here.
  defp provider_credential("hetzner", params) do
    case params["token"] do
      token when is_binary(token) -> {:ok, token}
      _ -> {:ok, ""}
    end
  end

  defp provider_credential("azure", params) do
    case params["credentials"] do
      creds when is_map(creds) -> {:ok, Jason.encode!(azure_credential_blob(creds))}
      _ -> {:error, :bad_credentials}
    end
  end

  # cloudflare: EITHER a bare API-token string (`token`, the common paste) OR a
  # `{api_token, account_id?, zone_id?}` JSON blob (`credentials`). Both ride the
  # single encrypted_token column (the Provider changeset validates each shape).
  # A blob keeps only the three known fields — never stray request input.
  defp provider_credential("cloudflare", params) do
    case params["credentials"] do
      creds when is_map(creds) -> {:ok, Jason.encode!(cloudflare_credential_blob(creds))}
      _ -> {:ok, credential_string(params["token"])}
    end
  end

  # Keep ONLY the four known azure fields (string keys) — never persist stray
  # request input alongside the credential. A field is stringified only when it
  # is genuinely a string; any other JSON shape (nested object, array, number,
  # bool) is coerced to "" so a malformed body fails the shape gate / preflight
  # with a clean 422 remediation instead of raising a Protocol.UndefinedError
  # (to_string/1 has no impl for maps/lists) and 500-ing the request.
  defp azure_credential_blob(creds) do
    for field <- BarkparkCloud.Registry.Provider.azure_fields(),
        into: %{},
        do: {field, credential_string(Map.get(creds, field))}
  end

  defp credential_string(value) when is_binary(value), do: value
  defp credential_string(_), do: ""

  # Keep ONLY the three known cloudflare blob fields (string keys) — never persist
  # stray request input alongside the credential, and coerce any non-string value
  # to "" so a malformed body fails the changeset shape gate cleanly (never a
  # to_string/1 crash). account_id/zone_id are optional (dropped when blank/absent
  # so the stored blob stays minimal), but a JSON blob MUST carry a non-blank
  # api_token — the Provider changeset enforces that.
  defp cloudflare_credential_blob(creds) do
    %{"api_token" => credential_string(Map.get(creds, "api_token"))}
    |> maybe_put_field(creds, "account_id")
    |> maybe_put_field(creds, "zone_id")
  end

  defp maybe_put_field(blob, creds, field) do
    case credential_string(Map.get(creds, field)) do
      "" -> blob
      value -> Map.put(blob, field, value)
    end
  end

  # Verify-before-save: a cheap authenticated call proving the credential works.
  # :ok to proceed; {:error, :unverified} to refuse the save with remediation.
  defp preflight_provider("hetzner", token) do
    if hetzner_token_ok?(token), do: :ok, else: {:error, :unverified}
  end

  defp preflight_provider("azure", credential) do
    with {:ok, creds} when is_map(creds) <- Jason.decode(credential),
         {:ok, _meta} <- Azure.verify(creds) do
      :ok
    else
      _ -> {:error, :unverified}
    end
  end

  # cloudflare: verify the API token is LIVE + active before saving. The token to
  # verify is the bare credential, or a JSON blob's `api_token` — extracted here,
  # then handed to the SSRF-guarded Cloudflare.Client (Fake in dev/test). Only
  # {:ok, %{status: "active"}} proceeds; anything else refuses the save with the
  # per-kind remediation. Never routes any private/loopback/metadata host (the
  # Real client's shared Billing.HttpClient enforces verify_peer + no-redirect).
  defp preflight_provider("cloudflare", credential) do
    case Cloudflare.verify_token(cloudflare_api_token(credential)) do
      {:ok, %{status: "active"}} -> :ok
      _ -> {:error, :unverified}
    end
  end

  # The API token to verify — a bare token IS the token; a JSON blob's `api_token`
  # is. Falls back to the raw credential (a non-blob string) so a pasted token
  # verifies directly; "" when there is nothing to verify (verify then fails
  # closed and the changeset backstops the blank).
  defp cloudflare_api_token(credential) when is_binary(credential) do
    case Jason.decode(credential) do
      {:ok, %{"api_token" => token}} when is_binary(token) -> token
      _ -> credential
    end
  end

  defp cloudflare_api_token(_), do: ""

  # A one-row authenticated server list — the cheapest proof the token is live.
  # Success is a 2xx from api.hetzner.cloud; anything else (401/403/transport)
  # means "can't verify". The token never leaves this call.
  defp hetzner_token_ok?(token) when is_binary(token) and token != "" do
    request = %{
      method: :get,
      url: @hetzner_api_base <> "/v1/servers?per_page=1",
      headers: [{"Authorization", "Bearer " <> token}, {"Accept", "application/json"}],
      body: ""
    }

    case hetzner_http_client().request(request) do
      {:ok, %{status: status}} when status in 200..299 -> true
      _ -> false
    end
  end

  defp hetzner_token_ok?(_), do: false

  # The CP's committed copy of the cross-surface capabilities fixture,
  # byte-identical to internal/cli/cloud/providers_capabilities.json (the
  # providers_capabilities_contract_test gates the two are the same bytes). Read
  # ONCE at compile time — it's a static contract, not runtime data — and
  # @external_resource recompiles the router when the fixture changes.
  @providers_capabilities_fixture Path.expand(
                                    "../../../priv/static/__fixtures__/providers_capabilities.json",
                                    __DIR__
                                  )
  @external_resource @providers_capabilities_fixture
  @providers_capabilities @providers_capabilities_fixture |> File.read!() |> Jason.decode!()

  # Build the GET /v1/providers/capabilities body from the committed fixture.
  # For each kind: split the tier (fixture value or the "prod" default) from the
  # capability bools (every boolean key, generically — no hardcoded list),
  # overlay the ONE capability this control plane owns rather than reads
  # (`catalog`, see own_catalog_capability/2), then attach a server-owned gap
  # reason for every FALSE capability so no disabled action is reason-less.
  defp providers_capabilities_payload do
    providers =
      Map.new(@providers_capabilities, fn {kind, row} ->
        {tier, capabilities} = split_provider_tier(row)
        capabilities = own_catalog_capability(kind, capabilities)

        gaps =
          for {capability, false} <- capabilities, into: %{} do
            {capability, FailureCopy.capability_gap_reason(kind, capability)}
          end

        {kind, %{tier: tier, capabilities: capabilities, gaps: gaps}}
      end)

    %{providers: providers}
  end

  # tier reads from the fixture row ("dev" for the fake provider); every row
  # without an explicit tier defaults to "prod". capabilities are the row's
  # boolean-valued keys ONLY, so a future non-bool metadata key never leaks in
  # as a capability.
  # THE CONTROL PLANE STATES ITS OWN CATALOG CAPABILITY.
  #
  # `providers_capabilities.json` is the GO SEAM's contract, and its
  # `catalog: false` for hetzner/azure is HONEST THERE: no Go provider
  # implements `Catalog(ctx)` (`DetectCapabilities` type-asserts `Cataloger`).
  # But THIS control plane builds those catalogs itself — see
  # `build_provider_catalog/2`, served at `GET /v1/providers/:kind/catalog` for
  # every `@neutral_kinds` kind, and painted as priced regions in the console's
  # launch wizard. Passing the Go bool through unmodified made the capability
  # matrix print "doesn't publish a size-and-region catalog HERE yet" about a
  # menu the same session renders two clicks away.
  #
  # So: for the kinds this CP catalogs, `catalog` is answered by the CP, not by
  # the fixture. @neutral_kinds is the SAME set the catalog route reads, so the
  # claim and the route can't drift — and `providers_catalog_capability_test.exs`
  # joins it BOTH ways against the `build_provider_catalog/2` clause heads, so
  # neither deleting a clause nor widening this list buys a green.
  #
  # The overlay is exactly one key, and only where the fixture already declares
  # it: every other capability (and every other kind) still flows from the Go
  # seam untouched. NEVER "fix" this by editing the fixture — that would claim a
  # Go capability that does not exist and reds the Go seam's own honesty tests.
  defp own_catalog_capability(kind, capabilities) do
    if kind in @neutral_kinds and Map.has_key?(capabilities, "catalog") do
      Map.put(capabilities, "catalog", true)
    else
      capabilities
    end
  end

  defp split_provider_tier(row) do
    tier = Map.get(row, "tier", "prod")
    capabilities = for {key, value} <- row, is_boolean(value), into: %{}, do: {key, value}
    {tier, capabilities}
  end

  # GET /v1/providers/:kind/catalog handler.
  defp providers_catalog(conn, kind) do
    with_provider_catalog(conn, kind, fn _provider, catalog, _identity ->
      json(conn, 200, catalog)
    end)
  end

  # GET /v1/providers/:kind/overview handler — the catalog wrapped with the
  # connected provider's header, which now names WHICH cloud account the
  # connection points at (or says out loud that it can't).
  defp providers_overview(conn, kind) do
    with_provider_catalog(conn, kind, fn provider, catalog, identity ->
      header = %{kind: provider.kind, label: provider.label, identity: identity}
      json(conn, 200, Map.put(catalog, :provider, header))
    end)
  end

  # Shared resolve → build → serve for both neutral catalog routes. 404
  # unknown_kind for a kind we don't host; 404 no_provider when the team has
  # none connected (connect-first empty state); 502 catalog_unavailable when the
  # provider is connected but the upstream fetch failed (honest degraded state,
  # no jargon leaked).
  defp with_provider_catalog(conn, kind, on_ok) do
    cond do
      kind not in @neutral_kinds ->
        json(conn, 404, %{error: "unknown_kind"})

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "no_provider"})

      true ->
        case provider_of_kind(conn.assigns.current_team, kind) do
          nil ->
            json(conn, 404, %{error: "no_provider"})

          provider ->
            case build_provider_catalog(kind, provider) do
              {:ok, catalog, identity} -> on_ok.(provider, catalog, identity)
              {:error, _reason} -> json(conn, 502, %{error: "catalog_unavailable"})
            end
        end
    end
  end

  # The team's connected provider of `kind` (newest first, first wins), or nil.
  defp provider_of_kind(team, kind) do
    team
    |> Registry.list_providers()
    |> Enum.find(&(&1.kind == kind))
  end

  # Build the normalized {regions, server_types} for a connected provider, plus
  # the connection's ACCOUNT IDENTITY, off the SAME already-decrypted credential
  # (no second decrypt, no extra upstream call). Both branches decrypt the stored
  # credential SERVER-SIDE, fetch the provider's raw regions/sizes over its seam,
  # and normalize to the identical shape.
  defp build_provider_catalog("hetzner", provider) do
    # per_page=50 (hcloud's max, matching the proxy's @hetzner_per_page) so the
    # menu isn't silently truncated to hcloud's default first 25 — Hetzner lists
    # 40+ server types. Not paginated beyond page 1: one page of 50 covers the
    # whole current catalog for both server_types and the handful of locations.
    with {:ok, token} <- Registry.reveal_provider_token(provider),
         {:ok, %{"server_types" => server_types}} <-
           hetzner_get_json("/v1/server_types?per_page=50", token),
         {:ok, %{"locations" => locations}} <- hetzner_get_json("/v1/locations", token) do
      {:ok, HetznerCatalog.normalize(List.wrap(server_types), List.wrap(locations)),
       provider_identity("hetzner", token)}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp build_provider_catalog("azure", provider) do
    with {:ok, credential} <- Registry.reveal_provider_token(provider),
         {:ok, creds} when is_map(creds) <- Jason.decode(credential),
         {:ok, %{locations: locations, vm_sizes: vm_sizes}} <- Azure.list_catalog(creds) do
      priced = enrich_azure_prices(List.wrap(vm_sizes))

      {:ok, AzureCatalog.normalize(List.wrap(locations), priced),
       provider_identity("azure", creds)}
    else
      _ -> {:error, :unavailable}
    end
  end

  # WHICH cloud account this connection points at — the fact a person needs
  # BEFORE they press "Verify & replace" on a stored credential.
  #
  # `source: "stored"` is the whole honesty of this shape: the value is read back
  # out of the credential blob the person themselves typed at connect time, and
  # is NOT a server-confirmed identity. Nothing in this tree asks a provider
  # "whose account is this?" — Azure.verify/1 echoes back the subscription_id it
  # was handed, and no request builder fetches a subscription displayName — so
  # the console must never call this "verified".
  #
  # The key is ALWAYS emitted. An identity we don't have is an EXPLICIT absence
  # carrying its own reason (`value: nil`), never a silently omitted key the
  # client would paint as a blank that looks known.
  #
  # Only the @neutral_kinds reach here (with_provider_catalog 404s anything
  # else), so cloudflare — whose stored blob may carry an account_id — has no
  # clause: it owns no catalog route, and the console's provider picker has no
  # cloudflare entry at all, so a clause here would be unreachable code rather
  # than a rendered fact.
  defp provider_identity("azure", creds) do
    case creds |> Map.get("subscription_id") |> to_string() |> String.trim() do
      "" ->
        identity_absent("Subscription", "This connection didn't store a subscription ID.")

      subscription_id ->
        %{label: "Subscription", value: subscription_id, source: "stored", reason: nil}
    end
  end

  # Hetzner Cloud tokens are PROJECT-scoped and the API exposes no account or
  # project identity resource: `hetzner_token_ok?/1` is a one-row
  # `GET /v1/servers?per_page=1` matched on status class alone and returning a
  # bare boolean, and nothing anywhere in this tree fetches a Hetzner account,
  # project or organization identifier. So we say that, rather than guessing.
  defp provider_identity("hetzner", _token),
    do: identity_absent("Project", "Hetzner doesn't report which project this token belongs to.")

  defp identity_absent(label, reason),
    do: %{label: label, value: nil, source: "unavailable", reason: reason}

  # Stamp REAL retail monthly USD onto each vm size BEFORE AzureCatalog.normalize
  # (the normalizer already reads "monthlyPriceUsd"). Prices come from the global,
  # unauthenticated Retail Prices sheet via the credential-free Azure.Pricing
  # cache — joined by armSkuName == the size's slug. A pricing outage returns %{}
  # → sizes keep whatever price they carried (nil in prod) and the catalog STILL
  # serves; never the 502 catalog_unavailable. A slug we have no price for is left
  # untouched (nil monthly_price renders "price unavailable", not a fake number).
  defp enrich_azure_prices(vm_sizes) do
    prices = Azure.Pricing.monthly_prices()

    Enum.map(vm_sizes, fn size ->
      with %{"name" => slug} <- size,
           usd when is_number(usd) <- Map.get(prices, slug) do
        Map.put(size, "monthlyPriceUsd", usd)
      else
        _ -> size
      end
    end)
  end

  # A single authenticated hetzner GET returning the decoded JSON map, or an
  # error. The token never leaves this call.
  defp hetzner_get_json(path, token) do
    request = %{
      method: :get,
      url: @hetzner_api_base <> path,
      headers: [{"Authorization", "Bearer " <> token}, {"Accept", "application/json"}],
      body: ""
    }

    case hetzner_http_client().request(request) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> {:error, :bad_payload}
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, _} ->
        {:error, :unreachable}
    end
  end

  ## Hetzner proxy helpers (charter decisions 3+4)

  # The nine overview kinds, in charter envelope key order. Each row is
  # {envelope/catalog resource, upstream JSON list key, extra query string}:
  # dns_zones live under "zones", and backups are Hetzner images filtered to
  # type=backup (the catalog's allowed "type" query param).
  @hetzner_overview_kinds [
    {:servers, "servers", nil},
    {:volumes, "volumes", nil},
    {:networks, "networks", nil},
    {:firewalls, "firewalls", nil},
    {:load_balancers, "load_balancers", nil},
    {:floating_ips, "floating_ips", nil},
    {:primary_ips, "primary_ips", nil},
    {:dns_zones, "zones", nil},
    {:backups, "images", "type=backup"}
  ]

  # The catalog's public serialization: resource/verb/tier/params ONLY — the
  # upstream method/path templates (and host) never leave the server.
  defp hetzner_catalog_json(entry) do
    %{
      resource: entry.resource,
      verb: entry.verb,
      tier: entry.tier,
      params: entry.params
    }
  end

  # The team's connected hetzner provider (newest first, first wins), or nil.
  defp hetzner_provider(team) do
    team
    |> Registry.list_providers()
    |> Enum.find(&(&1.kind == "hetzner"))
  end

  # Fan out to the nine read kinds and assemble the charter envelope. The
  # fan-out is SEQUENTIAL and in-process — the injected client seam (like the
  # notifications fake) runs in the calling process, and nine bounded-timeout
  # paginated GET walks are fine for a dashboard snapshot (revisit with an
  # ownership-aware fake if the Infrastructure panel wants Task.async_stream).
  # Partial failure degrades per kind: that kind is null, its count 0, and
  # `errors` names the failure; `ok` stays true because the envelope itself
  # succeeded (charter decision 4).
  defp hetzner_overview_envelope(provider, token) do
    results =
      for {kind, list_key, query} <- @hetzner_overview_kinds do
        # The catalog is the ONLY path source — exact-match lookup, so the
        # proxy cannot call a URL that isn't a catalog template. Only the
        # `:list` verb (tier `:read`) is ever resolved here — mutate/destroy
        # entries are inert data (charter decision 11), asserted by the
        # reconciliation test's destroy-tier tripwire.
        {:ok, entry} = HetznerCatalog.fetch(kind, :list)
        {kind, hetzner_fetch_kind(entry, kind, list_key, query, token)}
      end

    resources =
      Map.new(results, fn
        {kind, {:ok, rows}} -> {kind, rows}
        {kind, {:error, _}} -> {kind, nil}
      end)

    counts =
      Map.new(results, fn
        {kind, {:ok, rows}} -> {kind, length(rows)}
        {kind, {:error, _}} -> {kind, 0}
      end)

    errors = for {kind, {:error, reason}} <- results, into: %{}, do: {kind, reason}

    envelope = %{
      ok: true,
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      provider: %{kind: provider.kind, label: provider.label},
      resources: resources,
      counts: counts
    }

    if errors == %{}, do: envelope, else: Map.put(envelope, :errors, errors)
  end

  # Hetzner paginates EVERY list endpoint (25/page default, 50 max). The
  # fan-out asks for the max and walks `meta.pagination.next_page` so `counts`
  # is estate truth, not first-page truth — an operator with 60 servers must
  # see 60, and the Go CLI reference (hcloud-go `AllWithOpts`) auto-paginates,
  # so stopping at page 1 here would be exactly the GUI/CLI drift the charter
  # forbids. The page walk is bounded (50 rows × 20 pages = 1000 rows/kind) so
  # a hostile/looping upstream can't wedge the request.
  @hetzner_per_page 50
  @hetzner_max_pages 20

  # All pages of one upstream list, path taken verbatim from the catalog
  # entry. Returns {:ok, rows} | {:error, reason} where reason is a SAFE
  # string ("http_502" / "unreachable" / "bad_payload") — never the transport
  # term, never a header, never the token. A failure on ANY page fails the
  # whole kind: partial rows would silently lie about counts.
  defp hetzner_fetch_kind(entry, kind, list_key, query, token) do
    base_query =
      [query, "per_page=#{@hetzner_per_page}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("&")

    hetzner_fetch_pages(entry, kind, list_key, base_query, token, 1, [])
  end

  defp hetzner_fetch_pages(entry, kind, list_key, base_query, token, page, acc) do
    url = @hetzner_api_base <> entry.path <> "?" <> base_query <> "&page=#{page}"

    request = %{
      method: :get,
      url: url,
      headers: [
        {"Authorization", "Bearer " <> token},
        {"Accept", "application/json"}
      ],
      body: ""
    }

    case hetzner_http_client().request(request) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) ->
            rows = decoded |> Map.get(list_key, []) |> List.wrap()
            acc = acc ++ (rows |> Enum.filter(&is_map/1) |> Enum.map(&hetzner_row(kind, &1)))

            # Follow the upstream's own next-page pointer. Guards: it must be
            # an integer strictly beyond the page just fetched (a payload that
            # points backwards or at itself can't loop us), within the bound.
            case get_in(decoded, ["meta", "pagination", "next_page"]) do
              next when is_integer(next) and next > page and next <= @hetzner_max_pages ->
                hetzner_fetch_pages(entry, kind, list_key, base_query, token, next, acc)

              _ ->
                {:ok, acc}
            end

          _ ->
            {:error, "bad_payload"}
        end

      {:ok, %{status: status}} ->
        {:error, "http_" <> Integer.to_string(status)}

      {:error, _reason} ->
        # The transport reason term stays server-side — it can carry request
        # internals, and nothing the dashboard can act on beyond "unreachable".
        {:error, "unreachable"}
    end
  end

  # The charter row contract, RECONCILED with the Go reference implementation
  # (`bp cloud hetzner overview -o json`, hzOverviewKinds) so the two surfaces
  # emit one shape: every row carries id/name/status ("n/a" where the kind has
  # none) PLUS the kind-specific fields the golden fixture
  # (priv/static/__fixtures__/hetzner_overview.json) pins. Two emission rules:
  #
  #   * array-derived counts (server_count/rule_count/applied_to_count/
  #     service_count/target_count) are ALWAYS emitted — 0 for an empty
  #     collection — matching hcloud-go's `len()`;
  #   * optional scalar/nested fields (type/location/ipv4/ip/server_id/
  #     assignee_id/mode/record_count/size_gb/created/created_from) are emitted
  #     only when the raw upstream supplies them, so a row never carries a null.
  #
  # The one deliberate delta from Go: Go emits a handful of scalars it treats as
  # always-present (size_gb/mode/record_count/ip type) as their zero value when
  # hcloud has no data, whereas this proxy omits them if the raw JSON omits
  # them. That divergence cannot manifest on a real Hetzner payload (those
  # fields are always present upstream) — it is documented in the
  # reconciliation test and never affects the golden fixture.
  defp hetzner_row(:servers, m) do
    hetzner_base(m)
    |> hetzner_merge(%{
      type: hetzner_dig(m, ["server_type", "name"]),
      location: hetzner_dig(m, ["datacenter", "location", "name"]),
      ipv4: hetzner_dig(m, ["public_net", "ipv4", "ip"]),
      created: Map.get(m, "created")
    })
  end

  defp hetzner_row(:volumes, m) do
    hetzner_base(m)
    |> hetzner_merge(%{
      size_gb: Map.get(m, "size"),
      server_id: Map.get(m, "server"),
      location: hetzner_dig(m, ["location", "name"]),
      created: Map.get(m, "created")
    })
  end

  defp hetzner_row(:networks, m) do
    hetzner_base(m)
    |> Map.put(:server_count, hetzner_count(m, "servers"))
    |> hetzner_merge(%{
      ip_range: Map.get(m, "ip_range"),
      created: Map.get(m, "created")
    })
  end

  defp hetzner_row(:firewalls, m) do
    hetzner_base(m)
    |> Map.put(:rule_count, hetzner_count(m, "rules"))
    |> Map.put(:applied_to_count, hetzner_count(m, "applied_to"))
    |> hetzner_merge(%{created: Map.get(m, "created")})
  end

  defp hetzner_row(:load_balancers, m) do
    hetzner_base(m)
    |> Map.put(:service_count, hetzner_count(m, "services"))
    |> Map.put(:target_count, hetzner_count(m, "targets"))
    |> hetzner_merge(%{
      type: hetzner_dig(m, ["load_balancer_type", "name"]),
      location: hetzner_dig(m, ["location", "name"]),
      ipv4: hetzner_dig(m, ["public_net", "ipv4", "ip"]),
      created: Map.get(m, "created")
    })
  end

  defp hetzner_row(:floating_ips, m) do
    hetzner_base(m)
    |> hetzner_merge(%{
      ip: Map.get(m, "ip"),
      type: Map.get(m, "type"),
      server_id: Map.get(m, "server"),
      created: Map.get(m, "created")
    })
  end

  defp hetzner_row(:primary_ips, m) do
    hetzner_base(m)
    |> hetzner_merge(%{
      ip: Map.get(m, "ip"),
      type: Map.get(m, "type"),
      assignee_id: Map.get(m, "assignee_id"),
      created: Map.get(m, "created")
    })
  end

  defp hetzner_row(:dns_zones, m) do
    hetzner_base(m)
    |> hetzner_merge(%{
      mode: Map.get(m, "mode"),
      record_count: Map.get(m, "record_count"),
      created: Map.get(m, "created")
    })
  end

  defp hetzner_row(:backups, m) do
    hetzner_base(m)
    |> hetzner_merge(%{
      created_from: hetzner_created_from(m),
      created: Map.get(m, "created")
    })
  end

  # id/name/status — always present. name falls back description→"n/a" (backups
  # are name-less images whose description is the human handle); status is "n/a"
  # for the kinds Hetzner gives none (networks/firewalls/load_balancers/*_ips).
  defp hetzner_base(m) do
    %{
      id: Map.get(m, "id"),
      name:
        hetzner_present(Map.get(m, "name")) || hetzner_present(Map.get(m, "description")) || "n/a",
      status: hetzner_present(Map.get(m, "status")) || "n/a"
    }
  end

  # Merge optional fields, dropping any the upstream omitted so a row never
  # carries a null key (the Go reference omits absent optionals too).
  defp hetzner_merge(row, extras) do
    extras
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(row)
  end

  # An array-derived count: length of the upstream collection, 0 when the key is
  # absent or not a list — always emitted (matches hcloud-go's `len()`).
  defp hetzner_count(m, key) do
    case Map.get(m, key) do
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  # A nested string field (e.g. server_type.name), present-guarded to nil.
  defp hetzner_dig(m, path), do: hetzner_present(get_in(m, path))

  # backups' created_from: the source image's name, or its id as a string when
  # name-less (matches the Go reference's created_from resolution).
  defp hetzner_created_from(m) do
    case Map.get(m, "created_from") do
      %{"name" => n} = cf -> hetzner_present(n) || hetzner_stringify(Map.get(cf, "id"))
      %{"id" => id} -> hetzner_stringify(id)
      _ -> nil
    end
  end

  defp hetzner_stringify(nil), do: nil
  defp hetzner_stringify(v) when is_binary(v), do: hetzner_present(v)
  defp hetzner_stringify(v), do: to_string(v)

  defp hetzner_present(v) when is_binary(v) and v != "", do: v
  defp hetzner_present(_), do: nil

  # Transport seam — swappable in tests via
  # `config :barkpark_cloud, :hetzner_http_client, FakeClient` (same shape as
  # the notifications/studio-link seams; default is the verified-TLS :httpc
  # client).
  defp hetzner_http_client do
    Application.get_env(:barkpark_cloud, :hetzner_http_client, BarkparkCloud.Billing.HttpClient)
  end

  ## Instance-API proxy helpers (C4) — token custody + bounded relay + uniform
  ## envelope. See `Registry.InstanceApiCatalog`'s moduledoc for the envelope and
  ## failure-code contract these produce.

  # The one entry point every /v1/barkparks/:id/api/webhooks* route funnels
  # through. User-authed + team-scoped fail-closed: a wrong-team / nonexistent /
  # malformed id is the SAME 404 as a teamless caller (no existence leak). A
  # resolved instance dispatches through the catalog capability.
  defp proxy_instance_webhook(conn, capability) do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        instance_api_error(conn, 404, "not_found")

      true ->
        team = conn.assigns.current_team

        case resolve_team_barkpark(team, conn.path_params["id"]) do
          %Barkpark{} = bp -> dispatch_instance_api(conn, team, bp, capability)
          nil -> instance_api_error(conn, 404, "not_found")
        end
    end
  end

  # Team-scoped lookup: only the owning team's instance resolves; everything else
  # (another team's id, an unknown id, a non-UUID string) is `nil` → the same
  # 404. `Registry.get_barkpark/1` already guards the `:binary_id` cast, so a
  # malformed id never raises an `Ecto.CastError` here.
  defp resolve_team_barkpark(team, id) do
    case Registry.get_barkpark(id) do
      %Barkpark{team_id: tid} = bp when tid == team.id -> bp
      _ -> nil
    end
  end

  # Resolve liveness + admin token + upstream path, then relay. Each guard maps
  # to a distinct, honest failure the GUI/CLI can act on.
  defp dispatch_instance_api(conn, team, bp, capability) do
    {:ok, entry} = InstanceApiCatalog.fetch(capability)

    cond do
      # cch-w57-s4 — a SUSPENDED box is not WRITTEN TO through the platform's
      # stored admin credential. Isolation (D653) is "the control plane withholds
      # new credentials and maintenance attention; nothing stops, nothing is
      # deleted" — and a `:mutate` relayed with the decrypted admin token IS the
      # platform touching a server the console's own banner says it has stopped
      # managing (six of the nine v1 capabilities are `:mutate`, including
      # test_send, which makes the box perform an outbound request).
      #
      # `:read` deliberately still relays (D673): it grants nothing durable — the
      # contrast with the two MINT routes above, whose grants OUTLIVE the
      # suspension — deletes nothing, and keeps a lapsed team able to SEE its own
      # configuration. The webhooks tab is still offered, so blanking it would
      # paint a transport excuse for a billing decision.
      #
      # Placed ABOVE `instance_admin_token/1` on purpose: the ciphertext is never
      # decrypted on the refused path. Same 409 `suspended` slug as studio-link.
      bp.suspended and entry.tier == :mutate ->
        instance_api_error(conn, 409, "suspended")

      true ->
        with {:ok, base} <- instance_base_url(bp),
             {:ok, admin_token} <- instance_admin_token(bp),
             {:ok, path} <- render_instance_path(conn, entry) do
          relay_instance_api(conn, team, bp, entry, base, admin_token, path)
        else
          {:error, :not_live} -> instance_api_error(conn, 409, "not_live")
          {:error, :no_admin_token} -> instance_api_error(conn, 404, "no_admin_token")
          {:error, :decrypt_failed} -> instance_api_error(conn, 500, "decrypt_failed")
          {:error, :bad_request} -> instance_api_error(conn, 400, "bad_request")
        end
    end
  end

  # The instance-API read transport now has ONE home — `BarkparkCloud.Usage`
  # (extracted with the /usage gather it was born beside). The proxy relay below
  # delegates so base-URL / token-custody / headers / client-seam rules aren't
  # duplicated; the failure shapes are IDENTICAL (`:not_live` / `:no_admin_token`
  # / `:decrypt_failed`), so `dispatch_instance_api/4`'s `else` clauses are
  # unchanged.
  defp instance_base_url(bp), do: Usage.instance_base_url(bp)
  defp instance_admin_token(bp), do: Usage.instance_admin_token(bp)

  # Substitute the catalog template's placeholders from the request: `{dataset}`
  # from `?dataset=` (default "production"), `{id}` from the `:webhook_id` path
  # param, `{event_id}` from the `:event_id` path param. A template that can't be
  # rendered (a missing/garbage segment) is a 400 rather than a malformed
  # upstream call.
  defp render_instance_path(conn, entry) do
    values = %{
      "dataset" => instance_dataset(conn),
      "id" => conn.path_params["webhook_id"],
      "event_id" => conn.path_params["event_id"]
    }

    case InstanceApiCatalog.render_path(entry, values) do
      {:ok, path} -> {:ok, path}
      {:error, _} -> {:error, :bad_request}
    end
  end

  defp instance_dataset(conn) do
    case fetch_query_params(conn).query_params["dataset"] do
      d when is_binary(d) and d != "" -> d
      _ -> "production"
    end
  end

  # Perform the bounded relay and normalise the reply into the uniform envelope.
  # Timeouts/connect failures are bounded by the shared verified-TLS client
  # (`Billing.HttpClient`: 10s connect, 15s total) — a hung instance can never
  # wedge the request; it surfaces as `{:error, _}` → 502 reachable:false.
  defp relay_instance_api(conn, team, bp, entry, base, admin_token, path) do
    request = %{
      method: entry.method,
      url: base <> path,
      headers: instance_api_headers(admin_token),
      body: instance_api_body(conn, entry)
    }

    case instance_api_http_client().request(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        maybe_audit_instance_mutation(conn, team, bp, entry)
        json(conn, status, %{ok: true, resource: "webhook", data: decode_instance_body(body)})

      # A bare upstream 404 on one of the LATE-ADDED routes (rotate / deliveries
      # / replay from C5, test-send from GR45) is AMBIGUOUS from the status alone
      # (C11 / D25 / OC4):
      # the instance may be too OLD to serve the route at all, OR the route exists
      # and the webhook/event was simply DELETED — very likely elsewhere, on a
      # modern autoupdate-by-default fleet. "Update this instance" is an actively
      # WRONG dead-end for the deleted case. `instance_capability_404/2`
      # discriminates on the instance's OWN coded body (see there).
      {:ok, %{status: 404, body: body}}
      when entry.capability in [
             :"webhook.rotate",
             :"webhook.deliveries",
             :"webhook.replay",
             :"webhook.test_send"
           ] ->
        instance_capability_404(conn, body)

      # Any other non-2xx is relayed with the instance's OWN status so a caller
      # can distinguish 404-not-found from 422-invalid.
      {:ok, %{status: status, body: body}} ->
        json(conn, status, %{
          ok: false,
          error: %{code: "upstream_error", status: status, detail: decode_instance_body(body)}
        })

      # Connect failure or bounded-timeout — never a hang, never a raw exception.
      {:error, _reason} ->
        json(conn, 502, %{ok: false, error: %{code: "instance_unreachable"}, reachable: false})
    end
  end

  # Disambiguate a 404 on a C5-added route. The instance disambiguates for us BY
  # DESIGN: its WebhookController answers a genuine miss with a resource-CODED
  # body (`webhook_not_found` / `event_not_found` — see api WebhookController's
  # coded_not_found/3, added precisely so the console can tell the two apart),
  # while a route-missing 404 on a too-old box is Phoenix's UNCODED
  # `{"errors":{"detail":"Not Found"}}`.
  #
  #   coded body   → `webhook_gone` + "refresh the list" — the resource is gone
  #                  (likely deleted elsewhere); re-fetching the list is the ONE
  #                  recovery (D25). The SPA's failureCopy owns this exact code
  #                  string (C10 — merge order irrelevant).
  #   uncoded body → `capability_unavailable` + "update this instance" — the
  #                  genuinely-old box that never served the route.
  #
  # Both stay HTTP 502, mirroring the sibling capability_unavailable envelope the
  # SPA/CLI already transport: the honest story rides the code + hint, not the
  # status. (A version/capability discriminator that could also flag a truly
  # ancient box WITHOUT the coded-body signal is a wave-2 follow-on.)
  defp instance_capability_404(conn, body) do
    if upstream_webhook_gone?(body) do
      json(conn, 502, %{ok: false, error: %{code: "webhook_gone", hint: "refresh the list"}})
    else
      json(conn, 502, %{
        ok: false,
        error: %{code: "capability_unavailable", hint: "update this instance"}
      })
    end
  end

  # True when the upstream 404 body carries the instance's resource-coded
  # not-found (`webhook_not_found` / `event_not_found`) — proof the endpoint
  # EXISTS and the webhook/event is simply gone, not the route missing. Anything
  # else (an uncoded body, a string `error`, unparseable bytes) is NOT a
  # confident "gone" → stays capability_unavailable.
  defp upstream_webhook_gone?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code}}}
      when code in ["webhook_not_found", "event_not_found"] ->
        true

      _ ->
        false
    end
  end

  defp upstream_webhook_gone?(_), do: false

  # Only :mutate capabilities audit, and only on a landed 2xx (never a recorded
  # action that did not happen). Best-effort + post-relay, mirroring the
  # `barkpark.go_live` seam: a failed insert is logged, never fails the request.
  defp maybe_audit_instance_mutation(conn, team, bp, %{tier: :mutate, capability: cap}) do
    # The operator's "what happened": capability + dataset always; webhook_id /
    # event_id only when the route carries them (create has no id yet; only
    # replay names an event) — absent rather than null in the stored metadata.
    metadata =
      %{
        capability: to_string(cap),
        dataset: instance_dataset(conn),
        webhook_id: conn.path_params["webhook_id"],
        event_id: conn.path_params["event_id"]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Accounts.record_audit(%{
           team_id: team.id,
           actor_user_id: conn.assigns.current_user.id,
           action: instance_mutation_action(cap),
           target_type: "barkpark",
           target_id: bp.id,
           metadata: metadata
         }) do
      {:ok, _event} -> push_event(team.id, "audit")
      {:error, cs} -> Logger.error("audit #{cap} failed: #{inspect(cs)}")
    end

    :ok
  end

  defp maybe_audit_instance_mutation(_conn, _team, _bp, _entry), do: :ok

  defp instance_mutation_action(:"webhook.create"), do: "webhook.created"
  defp instance_mutation_action(:"webhook.update"), do: "webhook.updated"
  defp instance_mutation_action(:"webhook.delete"), do: "webhook.deleted"
  defp instance_mutation_action(:"webhook.rotate"), do: "webhook.rotated"
  defp instance_mutation_action(:"webhook.replay"), do: "webhook.replayed"
  # LOAD-BEARING, not optional: maybe_audit_instance_mutation/4 calls this for
  # EVERY :mutate-tier catalog entry and there is no catch-all clause, so a
  # :mutate capability without a clause here raises FunctionClauseError the first
  # time the route lands a 2xx in production.
  defp instance_mutation_action(:"webhook.test_send"), do: "webhook.test_sent"

  # GET carries no body; a mutation forwards the parsed request body re-encoded
  # as JSON (an absent body is an empty object, harmless for rotate/replay).
  defp instance_api_body(_conn, %{method: :get}), do: ""
  defp instance_api_body(conn, _entry), do: Jason.encode!(conn.body_params || %{})

  defp instance_api_headers(admin_token), do: Usage.instance_api_headers(admin_token)

  # A 2xx instance body is JSON; an empty body (e.g. a 204-style delete) is nil;
  # anything non-JSON is passed through verbatim rather than swallowed.
  defp decode_instance_body(body) when is_binary(body) do
    case String.trim(body) do
      "" ->
        nil

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, decoded} -> decoded
          _ -> body
        end
    end
  end

  defp decode_instance_body(_), do: nil

  defp instance_api_error(conn, status, code) do
    json(conn, status, %{ok: false, error: %{code: code}})
  end

  defp instance_api_http_client, do: Usage.instance_api_http_client()

  # The non-secret GitHub-connection shape (gh-2). NEVER emits the encrypted
  # installation handle — only the boolean connected state + display login, plus
  # the config-derived `configured` flag + `install_url` so the dashboard renders
  # the right card (connected / connect / not-configured) without a second call.
  defp github_installation_json(state) do
    %{
      connected: state.connected,
      account_login: state.account_login,
      configured: GitHub.configured?(),
      install_url: GitHub.install_url()
    }
  end

  # A GitHub installation id arrives as JSON — GitHub uses a numeric id, but the
  # SPA may hand it back as a string. Accept a non-empty string or an integer;
  # everything else (nil, "", a map) is a bad request.
  defp valid_installation_id?(id) when is_integer(id), do: true
  defp valid_installation_id?(id) when is_binary(id), do: String.trim(id) != ""
  defp valid_installation_id?(_), do: false

  # A GitHub repo name: non-empty, ≤100 chars, only the URL-safe set GitHub
  # accepts (letters/digits/`-`/`_`/`.`). Not `.`/`..` (reserved path segments).
  defp valid_repo_name?(name) when is_binary(name) do
    name != "" and name not in [".", ".."] and String.length(name) <= 100 and
      Regex.match?(~r/^[A-Za-z0-9._-]+$/, name)
  end

  defp valid_repo_name?(_), do: false

  # ssw10: what the `token.minted` audit row records — read off the PERSISTED
  # row, never off the request.
  #
  # `UserToken.normalize_abilities/1` is the server-side authority on ability
  # EXCLUSIVITY: a mint asking for `["write", "deploy"]` stores `["deploy"]`, and
  # `["read", "root"]` stores `["root"]`. Recording `attrs.abilities` wrote an
  # issuance record for a grant that never existed — on the one surface an
  # incident review reads to answer "what was this credential allowed to do".
  #
  # The collapse is also NAMED rather than silently absorbed: when the stored
  # list is narrower than the requested one, the row carries the requested list
  # and the dropped abilities alongside the granted one. Both keys are ABSENT
  # when nothing was dropped, so an ordinary mint's row is unchanged.
  defp mint_audit_metadata(attrs, pat) do
    granted = pat.abilities || []
    requested = attrs.abilities || []
    dropped = Enum.uniq(requested -- granted)

    base = %{name: attrs.name, abilities: granted}

    if dropped == [],
      do: base,
      else: Map.merge(base, %{requested_abilities: requested, dropped_abilities: dropped})
  end

  # The non-secret PAT shape for the dashboard's API-tokens view. NEVER emits
  # token_hash and NEVER the plaintext (the plaintext is returned once, only in
  # the POST /v1/tokens mint response). `revoked_at` non-nil renders as a
  # "revoked" tombstone client-side.
  defp pat_json(t) do
    %{
      id: t.id,
      name: t.name,
      abilities: t.abilities,
      last_used_at: t.last_used_at,
      expires_at: t.expires_at,
      revoked_at: t.revoked_at,
      inserted_at: t.inserted_at
    }
  end

  # The admin (team-scoped) PAT shape: `pat_json/1` plus WHO HOLDS IT. An admin
  # list is useless without the holder — "revoke this one" needs a name attached
  # — and the two extra fields are already visible to any admin through
  # GET /v1/teams/:id/members. Still NEVER a token_hash and never a plaintext.
  defp team_pat_json(t) do
    t
    |> pat_json()
    |> Map.put(:user_id, t.user_id)
    |> Map.put(:email, t.user && t.user.email)
  end

  # Map the requested expiry to a bounded day-count (or nil = never). The set
  # `7/30/60/90/365` mirrors Coolify's ApiTokens expiry select
  # (app/Livewire/Security/ApiTokens.php) so every token has a finite horizon
  # unless "never" is explicitly chosen. `0` / "never" → nil; anything outside
  # the set falls back to the PAT default (30 days) — the server is the
  # authority, the client cannot smuggle an arbitrary lifetime.
  defp parse_expiry(nil), do: UserToken.pat_default_validity_days()
  defp parse_expiry(0), do: nil
  defp parse_expiry("never"), do: nil
  defp parse_expiry(n) when is_integer(n) and n in [7, 30, 60, 90, 365], do: n

  defp parse_expiry(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> parse_expiry(n)
      _ -> UserToken.pat_default_validity_days()
    end
  end

  defp parse_expiry(_), do: UserToken.pat_default_validity_days()

  # The provision + resurrect claim: the flat payload PLUS the per-instance agent
  # token minted at claim time. `put_agent_token/2` is deliberately HERE and not
  # in `base_claim_json/2` — the SUPPORT claim reuses the flat payload but must
  # NOT mint, because minting is what writes the false custody record. See
  # `support_provision_claim_json/2`.
  defp claim_json(job, barkpark) do
    base_claim_json(job, barkpark)
    |> put_agent_token(barkpark)
    |> add_provider_claim_fields(barkpark)
  end

  # The claim payload the Go warm-pool provisioner decodes into a go-live spec:
  # the job id to report back against, the Barkpark's name + subdomain label, and
  # the region / server_type (warm-pool defaults — nbg1/cax11 — since the Barkpark
  # row doesn't pin them yet). Keys are EXACTLY what the Go worker expects.
  #
  # `slug` carries the GLOBALLY-unique provisioning subdomain (`<slug>-<team_short_id>`),
  # NOT the bare per-team slug — the worker turns this label into the DNS record
  # (`<label>.barkpark.cloud`) and the Hetzner box name, both of which MUST be
  # globally unique or two tenants collide. This is the SAME value stored in the
  # Barkpark's `:url`, so the provisioned FQDN == the customer-facing FQDN.
  defp base_claim_json(job, barkpark) do
    %{
      job_id: job.id,
      # claim-fence (bp-c55): the token stamped on this claim. The worker echoes it
      # back on succeed/fail/release so the server can fence a swept-and-re-claimed
      # job's stale worker. Additive: an OLD worker simply ignores the key.
      claim_token: job.claim_token,
      name: barkpark.name,
      slug: Barkpark.subdomain_from_url(barkpark),
      # Region/size come straight off the row (charter Decision 9 + 23): the PINNED
      # value or nil. An UNPINNED launch emits nil for EVERY provider — the worker
      # fills its OWN platform default (hetzner: the env-derived FreshSpec; azure:
      # eastus/Standard_B1s). azh-w3: stamping the Hetzner warm-pool default HERE
      # was the warm-pool-pin bug — nbg1/cax11 made every unpinned launch look
      # pinned, differing from the pool's env truth (nbg1/cx23) and skipping the
      # ≤15s warm path; a nil unpinned claim is the signal the Go warm pin-guard
      # reads as "serve from the pool". A Hetzner slug leaking into an azure claim
      # would still fail at ARM after the button — the exact failure Decision 17
      # exists to prevent.
      region: claim_region(barkpark),
      server_type: claim_server_type(barkpark),
      # dwb-4: the content-template slug picked at launch (validated then). nil →
      # no bootstrap; an OLD worker ignores the key.
      template: barkpark.template
    }
  end

  # azh-w6 (S14c): the resurrect worker's claim payload = the FULL provision claim
  # (agent token minted at claim, azure creds decrypted, region/size nil-honest —
  # all unchanged) PLUS `bundle_ref`, the object-storage archive to pull +
  # rehydrate onto the fresh box. Reusing claim_json keeps the provision claim
  # bytes untouched (the `bundle_ref` key is additive and only present here).
  defp resurrect_claim_json(job, barkpark) do
    claim_json(job, barkpark)
    |> Map.put(:bundle_ref, job.bundle_ref)
  end

  # PDF-D83/D89/D93: the support provisioner's claim payload = the flat provision
  # claim MINUS the agent-token mint (region/size off the support row, env as
  # usual) PLUS the PINNED `support` map. The Go slice binds the box + joins the
  # fleet from these exact keys — DO NOT rename them:
  #   parent_url         — the parent MAIN's public url (the box beats/rosters home)
  #   parent_admin_token — the main's DECRYPTED admin token (roster is :token_root;
  #                        the credential spine, minted-once server-to-box crossing)
  #   dataset            — always "production" (the support serves the main's prod)
  #   workspace          — the main's bootstrap_workspace (scope the support binds to)
  #   name               — the support row's SLUG (task-314de6aa36248bea: the Go
  #                        worker uses it as its DNS-shaped worker identity — the
  #                        free-form display name ("My Helper") is never sent)
  # The parent is resolved off the support's `fleet_parent_id`. A vanished parent
  # or a stripped admin token degrades to nil (the enqueue-time 409 guard makes
  # that path near-impossible; the worker then fails the job honestly rather than
  # the CP crashing).
  #
  # NO AGENT TOKEN (cch-w53-bl-…-a-live-agent-token). This used to call
  # `claim_json/2`, which mints a per-instance "report" token and PERSISTS ITS
  # SHA-256 HASH before shipping the plaintext. On this claim the plaintext
  # landed nowhere: `SupportJobSpec` (internal/provisioner/support.go) declares
  # no `agent_token` field, and `claimSupport`'s tolerated-dialect fallback
  # rescues only job_id/claim_token/name/slug/region/server_type — a
  # `grep -i 'agent.token' internal/provisioner/support.go` is one comment and
  # no code. So every support provision left the plane holding a LIVE
  # credential row asserting an install that never happened, and
  # `Registry.revoke_agent_token/1`'s own ruling says that state is
  # unrecoverable without a re-provision.
  #
  # A support box never runs barkpark-agent.service — it reports through the
  # PARENT MAIN's fleet roster beat (PDF-D89), which the `support` map above
  # already wires. Under the custody type gate (`claim_payload_manifest_test`'s
  # @custody_ineligible) agent_token must be CONSUMED or REMOVED, never
  # reserved; with no consumer on this seam the answer is REMOVE, and removing
  # the MINT — not just the key — is what stops the record from being false.
  # Byte-safe for a deployed worker: no support decode site ever read the key.
  # A future Go slice that installs the agent on support boxes re-adds the mint
  # HERE, together with the field.
  defp support_provision_claim_json(job, barkpark) do
    base_claim_json(job, barkpark)
    |> add_provider_claim_fields(barkpark)
    |> Map.put(:support, support_claim_map(barkpark))
  end

  defp support_claim_map(%Barkpark{fleet_parent_id: parent_id, slug: slug}) do
    parent = parent_id && Registry.get_barkpark(parent_id)

    %{
      parent_url: parent && parent.url,
      parent_admin_token: reveal_parent_admin_token(parent),
      dataset: "production",
      # Template-less mains never get bootstrap_workspace written; "" would die
      # at the Go slug fence, so default like every other consumer of the column.
      workspace: parent && (parent.bootstrap_workspace || "default"),
      # The SLUG, deliberately under the pinned `name` key (the Go slice binds
      # against these exact keys) — DNS-shaped worker identity, never the
      # display name.
      name: slug
    }
  end

  defp reveal_parent_admin_token(%Barkpark{} = parent) do
    case Registry.reveal_admin_token(parent) do
      {:ok, token} -> token
      :error -> nil
    end
  end

  defp reveal_parent_admin_token(_), do: nil

  # Charter Decision 33 — the monitoring beat goes live. Mint a per-instance agent
  # token (scope "report") at CLAIM time and thread the PLAINTEXT into the claim
  # payload for EVERY provider, mirroring env-at-claim above: the single sanctioned
  # plaintext crossing, sent ONLY over the worker-token-authed internal channel.
  # Only the SHA-256 hash is persisted server-side (plaintext-once) — the worker
  # writes the plaintext to /etc/barkpark/agent.token and enables
  # barkpark-agent.service so the box reports its health + vitals home. Resolved at
  # CLAIM time (not launch), so a stale-reclaim / retry carries a FRESH token, and
  # the box the worker actually configures holds a live credential.
  #
  # Fail-OPEN: a mint error omits the key and logs — a monitoring hiccup must never
  # strand a provision (an old worker ignores the key too). The box then serves
  # without the beat rather than never coming up.
  #
  # CALLED FROM `claim_json/2` ONLY — i.e. the provision and resurrect claims,
  # the two whose worker decodes (`provisioner.JobSpec`, `resurrectClaimSpec`)
  # declare an `agent_token` field and install it to /etc/barkpark/agent.token.
  # `support_provision_claim_json/2` builds off `base_claim_json/2` and does NOT
  # call this: minting for a box with no install path records a credential
  # handover that never happened. Read that function's comment before wiring a
  # fourth claim through here.
  defp put_agent_token(base, barkpark) do
    case Registry.mint_agent_token(barkpark, "report") do
      {:ok, plaintext, _token} ->
        Map.put(base, :agent_token, plaintext)

      {:error, changeset} ->
        Logger.error(
          "claim_json: mint_agent_token failed for barkpark #{barkpark.id}: #{inspect(changeset)}"
        )

        base
    end
  end

  # The claim's region/size come straight off the row — the PINNED value or nil,
  # for EVERY provider (azh-w3). The Go worker fills its own provider default when
  # nil (hetzner: the env-derived FreshSpec — which is the warm pool's OWN truth,
  # so an unpinned launch stays warm-pool-compatible; azure: eastus/Standard_B1s).
  # Registry.default_region/0 + default_server_type/0 survive as the public
  # documented default (other callers keep them) — they are just no longer stamped
  # into the claim, which is what wrongly made every unpinned launch look pinned.
  defp claim_region(%Barkpark{region: region}), do: region

  defp claim_server_type(%Barkpark{server_type: server_type}), do: server_type

  # Fold the provider routing fields into the claim payload (charter Decision 9).
  #
  # Hetzner (the default) → the payload is BYTE-IDENTICAL to the pre-provider-neutral
  # shape: no `kind`, no `credentials`. The Go worker reads a missing/"hetzner" kind
  # as the existing warm-pool path, so the prod Hetzner claim is unchanged.
  #
  # Azure → `kind: "azure"` routes the worker to a pool-size-zero cold create, and
  # `credentials` carries the DECRYPTED 4-field service-principal (the single
  # sanctioned plaintext crossing, mirroring env-at-claim above) so the worker
  # resolves the provider through `ProviderFor` at provision time. The credential is
  # omitted only if the team's azure provider row vanished after launch — the worker
  # then fails the job with an honest incomplete-credentials error rather than crash.
  defp add_provider_claim_fields(base, %Barkpark{provider: "azure"} = barkpark) do
    base = Map.put(base, :kind, "azure")

    case Registry.resolved_azure_credentials_for_barkpark(barkpark) do
      creds when is_map(creds) -> Map.put(base, :credentials, creds)
      _ -> base
    end
  end

  defp add_provider_claim_fields(base, _barkpark), do: base

  defp deprovision_claim_json(job, barkpark) do
    %{
      job_id: job.id,
      # claim-fence (bp-c55): echoed back on succeed to fence a stale re-claim.
      claim_token: job.claim_token,
      ip: barkpark.host,
      dns_label: Barkpark.subdomain_from_url(barkpark),
      dns_zone: Barkpark.base_domain()
    }
  end

  # The claim payload the Go worker decodes into an attach-domain spec (instance
  # custom domains). Keys are EXACTLY the pinned cross-language contract:
  # {job_id, claim_token, ip, custom_host, dns_label, dns_zone, app_port}.
  # `ip` is the instance box the worker SSHes to. `dns_label`/`dns_zone` split
  # a PLATFORM custom host for the A-record upsert (`<label>.<zone>` ==
  # custom_host by construction); for an EXTERNAL customer FQDN (attach-domain
  # V2) BOTH are null — the customer owns DNS, and the worker verifies the host
  # already resolves to the box instead of upserting anything.
  defp attach_domain_claim_json(job, barkpark) do
    %{
      job_id: job.id,
      # claim-fence (bp-c55): echoed back on succeed/fail to fence a stale re-claim.
      claim_token: job.claim_token,
      ip: barkpark.host,
      custom_host: barkpark.custom_host,
      dns_label: Barkpark.custom_host_label(barkpark),
      dns_zone:
        if(Barkpark.platform_custom_host?(barkpark.custom_host),
          do: Barkpark.base_domain(),
          else: nil
        ),
      # Every managed instance serves Phoenix on 4000 behind Caddy (the
      # provision-time `reverse_proxy localhost:4000`). A LITERAL on purpose —
      # the registry doesn't store a per-row port; make it a column the day a
      # box can run on anything else.
      app_port: 4000
    }
  end

  defp site_json(s), do: site_json(s, nil)

  # `bp` (optional) is the site's instance — when it is loaded, the spawned-site
  # view can carry the live URL + instance handle the CLI renders
  # (`bp cloud site open|status`). Absent (the list surface, which would N+1 to
  # fetch it) those keys are simply nil: honest, never invented.
  defp site_json(s, bp) do
    # env_encrypted is NEVER serialized — the env blob stays at rest.
    # github_webhook_secret_encrypted is NEVER serialized either; the plaintext
    # is shown ONCE in the POST /v1/sites/:id/github response body and that's it.
    %{
      id: s.id,
      barkpark_id: s.barkpark_id,
      team_id: s.team_id,
      name: s.name,
      slug: s.slug,
      kind: s.kind,
      framework: s.framework,
      # search-template W2/W6/W8: the starter + palette this site deploys with.
      template: s.template,
      theme: s.theme,
      # search-template W10: the featured content type the shipped site reads
      # (injected as BARKPARK_DOC_TYPE at deploy). Writable at create and via
      # PATCH since W8 — serialized here so every surface can read it back.
      doc_type: s.doc_type,
      domains: s.domains,
      scale_mode: s.scale_mode,
      port: s.port,
      # site-spawner W7: the node-slot port base (blue=base, green=base+1). Null on
      # static/container sites. `port` above is the currently-live serving port.
      port_base: s.port_base,
      current_deployment_id: s.current_deployment_id,
      # site-spawner W1: the content binding (which Barkpark dataset a static
      # build reads). read_token_encrypted is NEVER serialized — the plaintext
      # read token stays at rest, like env_encrypted.
      bootstrap_workspace: s.bootstrap_workspace,
      bootstrap_project: s.bootstrap_project,
      bootstrap_dataset: s.bootstrap_dataset,
      # site-spawner D29: the CLI's spelling of the same triple
      # (cloudclient.SpawnSite reads `workspace`/`project`/`dataset`), plus the
      # live PATH url and the instance handle it renders. One row, both
      # vocabularies — the container view is unchanged.
      workspace: s.bootstrap_workspace,
      project: s.bootstrap_project,
      dataset: s.bootstrap_dataset,
      url: bp && Sites.Deploy.site_url(s, bp),
      instance: bp && bp.slug,
      content_bound: not is_nil(s.read_token_encrypted),
      github_repo: s.github_repo,
      github_branch: s.github_branch,
      github_webhook_configured: not is_nil(s.github_webhook_secret_encrypted),
      previews_enabled: s.previews_enabled,
      # site-spawner W9 (charter D87): does this site accept builds produced
      # somewhere other than its box? Serialized so a PATCH of it is READABLE
      # back — a settings flip nothing can observe is indistinguishable from one
      # that never landed.
      prebuilt_enabled: s.prebuilt_enabled,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end

  # stw4-freshness (charter D24): fold the batched `latest_deployment_status_map`
  # entry for `site` into its row JSON as a slim `last_deployment` key. Absent
  # from the map (a site that never deployed) → nil, never invented. HONESTY LAW:
  # the map already carries ONLY status/trigger/timestamps — the badge renders
  # freshness, never a fabricated content_rev.
  defp put_last_deployment(json, site, fresh_map) do
    Map.put(json, :last_deployment, Map.get(fresh_map, site.id))
  end

  # The stable repo shape the picker renders — just the full name + visibility,
  # never any GitHub token or the installation handle. Accepts either GitHub's
  # string-keyed maps (from the seam) or atom-keyed maps.
  defp github_repo_json(repo) do
    %{
      full_name: repo["full_name"] || repo[:full_name],
      private: repo["private"] || repo[:private] || false
    }
  end

  defp deployment_json(d) do
    %{
      id: d.id,
      site_id: d.site_id,
      status: d.status,
      git_ref: d.git_ref,
      artifact_url: d.artifact_url,
      image_tag: d.image_tag,
      build_log_url: d.build_log_url,
      # Humanize the raw internal reason (reaper/builder jargon) at the JSON
      # boundary — server-side twin of app.js failureCopy() (#939). DB stays raw.
      #
      # site-spawner W11: `humanize/1` passes a TYPED refusal (an `E_*` extractor
      # code, or the box-refusal prefix) through verbatim — see
      # `FailureCopy.typed_refusal?/1`. That is what keeps this field and the raw
      # `detail` below (`Sites.Deploy.fail/2` writes the SAME string to both) from
      # contradicting each other in one response, which is exactly what happened
      # while an `E_ABSOLUTE_PATH` on "/quota/index.html" rendered here as
      # "Hetzner ran out of server capacity".
      failure_reason: FailureCopy.humanize(d.failure_reason),
      # deploy-reliability W1 S2: the HONEST pair beside the prose.
      #
      #   * `failure_class` — the ledger's NAMED class for this row
      #     (`DeployLedger.classify/1`), computed from `stage` + the RAW column,
      #     never from the humanized string above: `humanize/1` is a display fold
      #     that maps many distinct causes onto one sentence, so counting it
      #     groups by prose and prose collapses causes. `nil` on rows that were
      #     never refused — but NOT on every non-failed row (cch-w64-s6): a
      #     DEFERRED row is classified too (`DeployLedger.classify/1` has an
      #     explicit deferred arm), and prod serves e.g.
      #     `BOX_AT_CAPACITY_DEFERRED` on a `status: "deferred"` row. The old
      #     wording read as a guarantee the console could key on, and it is false.
      #   * `failure_reason_raw` — the capture WITHOUT the humanize rewrite, so a
      #     reader can see what the box actually said when the prose above is the
      #     generic arm. Raw of the REWRITE, never raw of the SECRETS:
      #     `humanize/1` is this payload's scrub carrier (`classify |> scrub`), so
      #     an unscrubbed twin field beside it would ship the credential the
      #     neighbouring field just redacted — exactly the leak shape
      #     task-4f363dc65ac43203 names ("an eighth channel added later ships
      #     unscrubbed and nothing reds"). STRIPPED, THEN scrubbed: 1,366 of
      #     17,395 failed rows carry real 0x1B bytes from the build PTY.
      failure_class: DeployLedger.classify(d),
      #
      #     dr-w22-s1 (REVIEW FIX): this key shipped as `scrub |> strip_ansi` —
      #     the FOURTH instance of the very leak `scrub_entry/2` carried, and the
      #     worst-rendering one. A CSI run parks an alphanumeric immediately left
      #     of the key so the scrub's key clause never fires, and the TRAILING
      #     strip then removes the escapes that blocked it — the credential
      #     landed here in clean CLEARTEXT, in the same payload whose sibling
      #     `console[].line` had just redacted it. `FailureCopy.raw/1` is the one
      #     order; do not re-pipe this by hand.
      failure_reason_raw: FailureCopy.raw(d.failure_reason),
      # deploy-reliability W15 S3 (the dr-w14-s3 follow-up): WHICH PHASE the box
      # refused in — "start" (the trigger; no build ever began) or "poll" (a beat
      # of a build already running, killed mid-flight). Same class, very
      # different blast radius, and the taxonomy deliberately does NOT split on
      # it, so this is the only way the phase reaches a reader.
      #
      # Read off the RAW column, never the humanized prose above: `humanize/1`
      # folds many causes onto one sentence and the caption the phase lives in is
      # exactly what it rewrites.
      #
      # `nil` on every row that is not a box refusal — never coerced to "start",
      # because "this was not a refusal" and "this was refused at trigger time"
      # are different sentences.
      #
      # HONEST LIMIT: this is a TRIPWIRE, not a live discriminator. cloud-db-1
      # holds ZERO poll-phase rows all-time against 14,848 start-phase ones, so
      # in production today this key answers "start" or nil and nothing else. It
      # is emitted so the FIRST poll refusal is legible the day it lands, not
      # because it distinguishes anything in the corpus we have.
      refusal_phase: DeployLedger.refusal_phase(d.failure_reason),
      # deploy-reliability W13 S3: the WAIT, as data. W12 shipped the writer
      # (`Sites.Deploy.defer/3`) and no reader at all — these three columns
      # populated into a serializer that did not mention them, so the only way
      # any client could recover a deferral's depth was
      # `internal/cli/cloud_site_cmd.go`'s `siteDeferralChainRe`, a regex over
      # the English in `failure_reason` ("refusal 3 of 12"). One reworded clause
      # silently zeroes every count taken that way.
      #
      #   * `deferral_depth` — how many times IN A ROW this site has been
      #     refused for this cause; `deferral_bound` is that CAUSE's own budget
      #     (12 for capacity, 6 for a busy box), so a client never hardcodes
      #     either.
      #   * `deferral_cause` — the LEDGER CLASS, frozen at defer time:
      #     `Deploy.deferral_cause/2` computes it through
      #     `DeployLedger.classify/1`, so this is a classification and not the
      #     raw box code. A later taxonomy repair does NOT retroactively apply
      #     to a row already written.
      #
      # `nil` on every non-deferred row AND on every deferral written before
      # the 20260807150000 migration landed — which is most of them today (23
      # of 1,841 prod deferrals carry columns, the oldest 2026-08-07 10:12:35Z).
      # That nil is the TRUTHFUL answer and is never coerced to 0: a zero depth
      # would claim "this row deferred zero times", which is a different and
      # false sentence from "nobody recorded it".
      deferral_depth: d.deferral_depth,
      deferral_bound: d.deferral_bound,
      deferral_cause: d.deferral_cause,
      became_live_at: d.became_live_at,
      # gh-6: branch-preview identity. `environment` is "production"|"preview";
      # for a preview, `branch` + `preview_host` + `preview_url` describe the
      # preview surface the dashboard renders (and the click-through target).
      environment: d.environment,
      branch: d.branch,
      preview_host: d.preview_host,
      preview_url: preview_url(d),
      # site-spawner W5 (charter D49): deploy provenance — "manual" | "content-auto".
      # The wish's "observable — content-triggered, not manual" bar reads off this;
      # emitted from the SOLE base serializer so list/get/deploy-response/agent-claim
      # all carry it.
      trigger: d.trigger,
      # site-spawner W9 (charter D86): WHERE the bytes were built —
      # "box-build" | "prebuilt" — plus the digest of the uploaded ones. Emitted
      # from the SOLE base serializer, because a deploy stream that cannot say
      # whether the control plane produced what it health-gated is claiming a
      # provenance it does not have. Null digest on every box build.
      source: d.source,
      artifact_sha256: d.artifact_sha256,
      # gh-5: the live build-console lines ride along so the site-detail deploy
      # row renders them and a refresh recovers mid-build console state.
      #
      # wave 13 S2: build console lines are raw remote output, so they are
      # scrubbed at this boundary alongside failure_reason above.
      #
      # cch-w27-s2: the two keys now fold DIFFERENTLY, because two different
      # readers hold them. `line` is the narration `deployConsoleHtml` prints —
      # the raw capture, scrubbed and otherwise untouched. `detail` has exactly
      # ONE client reader, `deployRailLedgerFromConsole`, which seeds the six-stage
      # rail whose `.deploy-rail-fail` caption a person watches; on a `failed`
      # entry that caption contradicted the `failure_reason` rendered ten lines
      # above. `Sites.Deploy.stage_caption/2` classifies that one key on that one
      # status and scrubs everything else — so the class reaches the rail and the
      # capture keeps its only copy, in `line`, in the same payload.
      console:
        Enum.map(
          d.console || [],
          &(&1 |> scrub_entry("line") |> caption_entry("status", "detail"))
        ),
      # dwb-19: the live sub-caption under the status pill (nil when none). The
      # site-detail deploy row renders it while the deploy is active.
      #
      # wave 13 S2: SCRUBBED, and not optionally. `Sites.Deploy.fail/2` writes the
      # SAME string to `failure_reason` and to `detail`, so scrubbing only the
      # former would ship a redacted field sitting beside its unredacted twin in
      # one payload.
      #
      # cch-w28-s5 (the D321(3) remainder): scrubbing is not ENOUGH here. On a
      # `failed` row `fail/2` writes the same capture to `failure_reason`, which
      # this very payload humanizes ten lines above — so the sub-caption under
      # the status pill contradicted the row's own reason with raw jargon.
      # `stage_caption/2` classifies on `failed` and scrubs on every other
      # status, which is exactly the fold `console[].detail` and `stages[].detail`
      # already use. One string, one class, one payload.
      detail: Sites.Deploy.stage_caption(d.status, d.detail),
      # site-spawner D30: the static-build identity + which of the six stages is in
      # flight. Null on every container row, so the container view is unchanged.
      build_id: d.build_id,
      content_rev: d.content_rev,
      stage: d.stage,
      # site-spawner (node slot truth): WHICH SLOT IS SERVING THIS BUILD, and
      # WHETHER ITS HEALTH GATE ACTUALLY RAN. `deploy/site-spawner-node-live-proof.sh`
      # reads all three off `bp cloud site deploy -o json`; before these columns
      # existed this payload carried no slot, no port and no health key of any
      # kind, so the proof's node assertions ran against empty strings.
      #
      #   * `slot` / `port` — the blue/green position the BOX MEASURED Caddy to be
      #     proxying to after SWITCH, read back out of its own Caddyfile, plus the
      #     loopback port. NEVER the slot the control plane intended: in a
      #     blue/green deploy the Caddy upstream port IS the slot truth, and an
      #     intent-derived slot reports intent while looking like state. `port`
      #     can stand while `slot` is nil (a served port matching neither of the
      #     site's two allocated slots) — that pair is a real signal, not a bug.
      #
      #   * `health_exit_code` — 0 (HEALTH ran and passed), 14 (ran and failed),
      #     `nil` (never measured). THE NIL IS NEVER COERCED TO 0, and this is the
      #     one field on this payload where the coercion would be actively
      #     dangerous: 0 is the SUCCESS code, so a defaulted zero would render a
      #     build that died in BUILD as health-certified. Same rule the three
      #     `deferral_*` keys above state, for the same reason. The Go side reads
      #     it as `*int` and renders nil as an explicit dash.
      #
      # All three are nil on every static row, on every container row, and on
      # every row written before the 20260902091000 migration — honestly unknown,
      # never backfilled.
      slot: d.slot,
      port: d.port,
      health_exit_code: d.health_exit_code,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  # site-spawner D30: the STAGE-AWARE deployment view — deployment_json plus the
  # six-stage bar and the live URL, i.e. exactly what `bp cloud site deploy`
  # streams and `bp cloud site status` renders.
  #
  # The per-stage `status` is LITERALLY `done` | `failed` | `skipped` (or
  # `running`/`pending` for what's still ahead): the CLI's stream prints a stage
  # ONLY for those three words and silently ignores anything else, so an `ok` or a
  # `passed` here would blank the progress bar with no error anywhere — a lie that
  # looks like a hang. `Sites.Deploy.stages/1` is the one place that vocabulary is
  # enforced.
  defp site_deployment_json(d, site, bp) do
    d
    |> deployment_json()
    # wave 13 S2: `Sites.Deploy.stages/1` recomputes the fold from the RAW
    # `d.console` rather than from `deployment_json/1`'s already-scrubbed copy, so
    # it is its OWN display boundary and needs its own scrub — otherwise the
    # stage detail ships the credential that the console entry it was derived
    # from just redacted, in the same payload.
    #
    # cch-w27-s2: and its own CLASSIFICATION, for the same reason. This is the
    # stage bar `bp cloud site deploy` streams and `bp cloud site status` prints;
    # a FAILED stage here named the raw cause while the `failure_reason` beside it
    # named the human one. `stage_caption/2`'s non-failed arm IS the scrub this
    # replaces, so no entry loses redaction. Atom keys — `stages/1` composes maps.
    |> Map.put(:stages, Enum.map(Sites.Deploy.stages(d), &caption_entry(&1, :status, :detail)))
    |> Map.put(:url, deployment_url(d, site, bp))
  end

  # A deployment's URL is the site's live URL — but ONLY once this deployment is
  # the one actually serving. A queued/failed build has no URL: claiming one would
  # send the user to a page showing somebody else's build (or the previous one),
  # which is precisely the confusion a health-gated deploy exists to prevent.
  defp deployment_url(%{status: "live"} = _d, site, bp), do: Sites.Deploy.site_url(site, bp)
  defp deployment_url(_d, _site, _bp), do: nil

  # The click-through URL for a preview deployment (https on the preview host),
  # or nil for a production deployment.
  defp preview_url(%{environment: "preview", preview_host: host}) when is_binary(host),
    do: "https://" <> host

  defp preview_url(_), do: nil

  # Agent-route serialization that bundles the Site shape (slug + domains) the
  # runtime executor needs to render its Caddyfile. Encoded once so claim +
  # pending responses are identical.
  defp deployment_with_site_json(d) do
    base = deployment_json(d)
    site = if Ecto.assoc_loaded?(d.site), do: d.site, else: Registry.get_site(d.site_id)

    # gh-6: for a PREVIEW deployment the runtime must render its Caddy block on
    # the preview slug + host (NOT the site's production slug/domains) and skip
    # the production-slot pointer update — so the agent claim inlines the preview
    # identity too. `preview_slug`/`preview_host` are null on production rows, so
    # the executor keys on the production site shape exactly as before.
    Map.put(base, :site, %{
      slug: site && site.slug,
      domains: (site && site.domains) || [],
      preview_slug: d.preview_slug,
      preview_host: d.preview_host
    })
  end

  # Scope check: does deployment_id's site belong to barkpark? Used by the
  # agent transition route to return 404 (not 422 / 403) when a malicious or
  # confused agent points at a deployment on another box — same shape as
  # nonexistent, never an existence leak.
  defp agent_owns_deployment?(barkpark, deployment_id) when is_binary(deployment_id) do
    case Registry.get_deployment(deployment_id) do
      nil ->
        false

      %Registry.Deployment{site_id: site_id} ->
        case Registry.get_site(site_id) do
          %Registry.Site{barkpark_id: bp_id} -> bp_id == barkpark.id
          _ -> false
        end
    end
  end

  defp agent_owns_deployment?(_, _), do: false

  # The shared tail of the two site-env read routes (builder: worker-gated;
  # agent: box-scoped) — decrypt the blob and answer it, ONCE the caller has
  # already authenticated and scoped the site. `{:ok, %{}}` when no blob was
  # ever set (the fleet proceeds env-less); `:error` (tampered/undecryptable
  # ciphertext, fail-closed in Vault.decrypt) is a 500, never a silent `{}` —
  # building a site without the env it was configured with would ship a broken
  # deploy that LOOKS healthy.
  defp site_env_response(conn, site) do
    case Registry.reveal_site_env(site) do
      {:ok, env} -> json(conn, 200, %{env: env})
      :error -> json(conn, 500, %{error: "decrypt_failed"})
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Handoff helpers: only the null-clear is accepted. The wire MUST include the
  # key explicitly (with value null) — a body that omits the key leaves the
  # field alone. A non-null value silently no-ops (defence in depth).
  defp put_handoff_claim_worker(map, params) do
    if Map.has_key?(params, "claim_worker") and is_nil(params["claim_worker"]) do
      Map.put(map, :claim_worker, nil)
    else
      map
    end
  end

  defp put_handoff_claim_epoch(map, params) do
    if Map.has_key?(params, "claim_epoch") and params["claim_epoch"] == 0 do
      Map.put(map, :claim_epoch, 0)
    else
      map
    end
  end

  defp maybe_put_datetime(map, _key, nil), do: map

  defp maybe_put_datetime(map, key, iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Map.put(map, key, DateTime.truncate(dt, :microsecond))
      _ -> map
    end
  end

  defp maybe_put_datetime(map, _key, _), do: map

  defp parse_epoch(n) when is_integer(n) and n >= 0, do: n

  defp parse_epoch(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_epoch(_), do: nil

  # GET /v1/audit query parsing. parse_int/2 reads ?limit= (a bad/absent value
  # falls back to the default; list_audit_events hard-caps it at 200 anyway).
  defp parse_int(nil, default), do: default

  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  # parse_dt/1 reads the ?before= keyset cursor as an ISO-8601 timestamp; a
  # malformed/absent value yields nil (no cursor → first page).
  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  # Resolve + role-gate the path team, then run `fun.(conn, team)`. 401/403/404
  # are handled inside Auth.require_team_role (halts the conn); we only invoke
  # `fun` on a passing gate.
  defp with_team_role(conn, min_role, fun) do
    conn = Auth.require_team_role(conn, conn.path_params["id"], min_role)
    if conn.halted, do: conn, else: fun.(conn, conn.assigns.current_team_scoped)
  end

  # Walk: auth → team check → fetch site (team-scoped) → run fn(site).
  #
  # `auth` selects the credential mode:
  #   * `:session` (the default) — session-token ONLY (the dashboard / browser
  #     management routes). A PAT cannot reach these.
  #   * `:team_admin` — session-token AND the team-admin role. Same credential
  #     kind as `:session`, one tier up: for the site-management verbs whose
  #     outcome a plain member must not be able to reach (linking a GitHub repo,
  #     which mints a deploy trigger only an admin can clear).
  #   * `{:ability, ab}` — accept a session OR a PAT, then gate on ability `ab`
  #     (a session implies `root`, so the browser always passes). Used by the
  #     programmatic routes external integrations call (e.g. deploy → "write").
  defp with_team_site(conn, fun), do: with_team_site(conn, :session, fun)

  defp with_team_site(conn, auth, fun) do
    conn =
      case auth do
        :session -> Auth.require_user(conn, [])
        :team_admin -> Auth.require_team_admin(conn, [])
        {:ability, ab} -> conn |> Auth.require_user_or_pat([]) |> Auth.require_ability(ab)
      end

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.get_team_site(conn.assigns.current_team, conn.path_params["id"]) do
          %Registry.Site{} = site -> apply_site_fun(fun, conn, site)
          nil -> json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # A read-only site handler takes just the site; a MUTATING one that must stamp
  # an audit row needs the AUTHED conn too (current_user is assigned inside
  # with_team_site, so the outer route body's conn never carries it). Arity picks
  # the right shape: `fn site -> … end` for reads, `fn conn, site -> … end` for
  # audited writes.
  defp apply_site_fun(fun, _conn, site) when is_function(fun, 1), do: fun.(site)
  defp apply_site_fun(fun, conn, site) when is_function(fun, 2), do: fun.(conn, site)

  # site-spawner D30: deploy a content-bound STATIC site — the verb the whole
  # spawner exists for.
  #
  # It answers 201 IMMEDIATELY (the build takes tens of seconds; the CLI streams
  # the six stages by polling GET /v1/sites/:id/deployments/:dep_id) and hands the
  # row to the driver, which walks the box through PLAN → BUILD → STAGE → HEALTH →
  # SWITCH → RETIRE and narrates every transition back onto it.
  #
  # The two refusals are the honest ones a static site can actually hit:
  #
  #   * no content binding — the site was created without a dataset, so there is
  #     nothing to build FROM. (The reaper says the same thing about a row that
  #     slips past this; both name the same cure.)
  #   * the instance isn't live — its URL/admin token isn't there yet, so no
  #     deploy can be driven on it.
  #
  # `no_build_source` — the container refusal about artifacts and GitHub repos —
  # is exactly what a static site must NEVER hear: it is not what it builds from.
  # cf-in-front deploy binding (D57). Returns `{:cont, site}` to let the normal
  # deploy proceed (the standalone path — the overwhelming common case, since a
  # deploy WITHOUT `via` is byte-identical to today), or `{:halt, conn}` after
  # sending a fail-closed response when a Cloudflare cutover was asked for but
  # can't be completed. The binding is persisted LAST (after the DNS write + the
  # proxy flip both succeed) so a deploy NEVER half-binds: if any CF step fails
  # the site's serving_mode is left untouched and the box keeps serving directly.
  defp maybe_bind_cloudflare(conn, site) do
    via = conn.body_params["via"]
    domain = conn.body_params["domain"]

    cond do
      # No `via` (or any value other than "cloudflare") → standalone, untouched.
      via != "cloudflare" ->
        {:cont, site}

      not is_binary(domain) or String.trim(domain) == "" ->
        {:halt,
         json(conn, 422, %{
           error: "cloudflare_domain_required",
           detail:
             "`--via cloudflare` needs a `--domain` (the custom hostname to point at this box)"
         })}

      true ->
        bind_cloudflare(conn, site, String.trim(domain))
    end
  end

  defp bind_cloudflare(conn, site, domain) do
    case Registry.resolve_cloudflare_credential(site.team_id) do
      {:ok, %{token: token, zone_id: zone_id}} when is_binary(zone_id) and zone_id != "" ->
        do_bind_cloudflare(conn, site, domain, token, zone_id)

      {:ok, %{}} ->
        {:halt,
         json(conn, 422, %{
           error: "cloudflare_zone_missing",
           detail:
             "the connected Cloudflare provider carries no zone_id — reconnect it with `bp provider add cloudflare` including the zone for #{domain}"
         })}

      {:error, :no_cloudflare_provider} ->
        {:halt,
         json(conn, 409, %{
           error: "no_cloudflare_provider",
           detail:
             "connect Cloudflare first: `bp provider add cloudflare` (the box keeps serving standalone until you do)"
         })}

      {:error, _reason} ->
        {:halt,
         json(conn, 409, %{
           error: "cloudflare_credential_unreadable",
           detail:
             "the stored Cloudflare credential could not be read — reconnect it with `bp provider add cloudflare`"
         })}
    end
  end

  defp do_bind_cloudflare(conn, site, domain, token, zone_id) do
    bp = Registry.get_barkpark(site.barkpark_id)
    origin = bp && bp.host

    cond do
      not is_binary(origin) or origin == "" ->
        {:halt,
         json(conn, 422, %{
           error: "instance_no_origin",
           detail:
             "the instance hosting this site has no address yet — wait for it to finish provisioning before pointing a domain at it"
         })}

      # BEFORE the write: refuse when the box read above is already stale — the
      # same fail-closed discipline the Go worker's platform-DNS branch uses
      # (cch orphan-fix, #14039). Narrow on its own (the box can still vanish a
      # moment later, in the network round trip below), but cheap, so it stays.
      not box_still_holds_origin?(site.barkpark_id, origin) ->
        {:halt,
         json(conn, 409, %{
           error: "instance_not_live",
           detail:
             "the instance backing this site was deprovisioned while this request was in flight; refusing to point DNS at a freed address (fail closed)"
         })}

      true ->
        # Point the domain at the box origin (A record), flip it PROXIED (orange
        # cloud), and only THEN persist the binding — the token + zone_id are
        # THREADED as arguments (D52), never global config.
        #
        # AFTER the upsert (and the proxy flip), `orphan_guard/5` re-reads the
        # box and DELETES the record just written if it went away underneath
        # us. This is the half the pre-check above cannot cover: deprovision
        # can land in the gap the two Cloudflare HTTP round trips stand for,
        # same as the Go sibling's window between its pre-check and its DNS
        # write. Cloudflare zones are per-team BYOA — there is no
        # `SweepOrphans` equivalent that could ever reach this record another
        # way, so this re-check is the ONLY thing that ever will.
        with {:ok, %{record_id: record_id}} <-
               Cloudflare.upsert_dns_record(token, zone_id, %{
                 type: "A",
                 name: domain,
                 content: origin,
                 proxied: true
               }),
             {:ok, %{proxied: true}} <- Cloudflare.ensure_zone_proxied(token, zone_id, record_id),
             :ok <- orphan_guard(token, zone_id, record_id, site.barkpark_id, origin, domain),
             {:ok, bound_site} <-
               Registry.set_cf_binding(site, %{
                 serving_mode: "cf_proxied",
                 tls_mode: "cf_internal",
                 cf_domain: domain,
                 cf_zone_id: zone_id,
                 cf_record_id: record_id
               }) do
          case Accounts.record_audit(%{
                 team_id: site.team_id,
                 actor_user_id: conn.assigns.current_user.id,
                 action: "site.cloudflare_bound",
                 target_type: "site",
                 target_id: site.id,
                 metadata: %{site_id: site.id, cf_domain: domain, cf_zone_id: zone_id}
               }) do
            {:ok, _event} -> :ok
            {:error, cs} -> Logger.error("audit site.cloudflare_bound failed: #{inspect(cs)}")
          end

          {:cont, bound_site}
        else
          {:error, {:orphan_cleaned, cleaned_domain}} ->
            Logger.error(
              "cloudflare_bind_orphan_cleaned: #{cleaned_domain} deprovisioned mid-write, the A record just written was deleted again"
            )

            {:halt,
             json(conn, 409, %{
               error: "instance_not_live",
               detail:
                 "the instance backing this site was deprovisioned while the A record was being written — #{cleaned_domain} has been deleted again (fail closed)"
             })}

          {:error, {:orphan_cleanup_failed, orphan_domain, orphan_ip, reason}} ->
            # The loudest thing this process will ever say about this record:
            # no other artefact anywhere will ever name it again.
            Logger.error(
              "cloudflare_bind_ORPHANED_RECORD: #{orphan_domain} -> #{orphan_ip} the box was deprovisioned mid-write and deleting the record again failed: #{inspect(reason)}"
            )

            {:halt,
             json(conn, 502, %{
               error: "cloudflare_orphan_cleanup_failed",
               detail:
                 "ORPHANED A RECORD #{orphan_domain} -> #{orphan_ip}: the instance was " <>
                   "deprovisioned mid-write and deleting the record again failed. Delete it " <>
                   "by hand in Cloudflare — nothing else can reach a record whose box is gone."
             })}

          {:error, reason} ->
            # Belt: the FULL raw provider body stays server-side for operators;
            # the client gets only the bounded, status-keyed `cloudflare_reason/1`
            # (never `inspect(reason)`, which echoed the zone/account internals).
            Logger.error("cloudflare_bind_failed: #{inspect(reason)}")

            {:halt,
             json(conn, 502, %{
               error: "cloudflare_bind_failed",
               detail: cloudflare_reason(reason)
             })}
        end
    end
  end

  # Does a managed box still hold `origin`? Reads `Registry.get_barkpark/1`
  # FRESH (never a struct fetched earlier in the request) so a deprovision that
  # lands mid-request is seen. A deprovision success DELETES the barkpark row
  # (`Registry.succeed_deprovision_job/2`, cascade removes its sites), and a
  # re-provision-in-place would change `host` on the SAME row — either one
  # means "not live any more", exactly like the Go worker's `boxHoldsIP` reads
  # the fleet by VALUE (the IP), never by a name/id that can go stale.
  defp box_still_holds_origin?(barkpark_id, origin) do
    case Registry.get_barkpark(barkpark_id) do
      %Barkpark{host: ^origin} -> true
      _ -> false
    end
  end

  # The orphan edge. Re-checks liveness AFTER the write and, if the box went
  # away underneath us, deletes the record just created — the money edge a
  # pre-check cannot cover, mirroring `AttachDomainWith`'s post-upsert
  # liveness re-check + `DeleteRecord` call on the Go worker side (cch
  # orphan-fix, #14039). Returns `:ok` when the box is still live,
  # `{:error, {:orphan_cleaned, domain}}` when the cleanup delete succeeded, or
  # `{:error, {:orphan_cleanup_failed, domain, ip, reason}}` when it did not —
  # that last shape carries the only artefact that will ever name this record.
  defp orphan_guard(token, zone_id, record_id, barkpark_id, origin, domain) do
    if box_still_holds_origin?(barkpark_id, origin) do
      :ok
    else
      case Cloudflare.delete_dns_record(token, zone_id, record_id) do
        {:ok, _} -> {:error, {:orphan_cleaned, domain}}
        {:error, reason} -> {:error, {:orphan_cleanup_failed, domain, origin, reason}}
      end
    end
  end

  defp deploy_static_site(conn, site) do
    bp = Registry.get_barkpark(site.barkpark_id)
    source = conn.body_params["source"] || "box-build"
    prebuilt = source == "prebuilt"

    cond do
      # A `source` the control plane does not implement must be REFUSED, never
      # silently treated as a box build: a CI runner that typed "prebuilt-v2"
      # would otherwise get a 201 for a deploy that ignored its artifact and
      # rebuilt on the box.
      source not in Registry.Deployment.sources() ->
        json(conn, 422, %{
          error: "unknown_source",
          detail: "source must be one of: #{Enum.join(Registry.Deployment.sources(), ", ")}"
        })

      # site-spawner W9 (charter D87): prebuilt is per-site opt-in. Accepting
      # bytes the control plane did not produce is a different trust statement
      # from building them here, so a site must say so first.
      prebuilt and not site.prebuilt_enabled ->
        json(conn, 422, %{
          error: "prebuilt_not_enabled",
          detail:
            "this site builds on its box — enable off-box builds first (PATCH /v1/sites/#{site.id} {\"prebuilt_enabled\": true})"
        })

      is_nil(site.bootstrap_dataset) ->
        json(conn, 422, %{
          error: "no_content_binding",
          detail:
            "this site isn't bound to any content — create it with `--dataset <workspace>/<project>/<dataset>`"
        })

      is_nil(bp) or is_nil(bp.url) or bp.url == "" ->
        json(conn, 422, %{
          error: "instance_not_live",
          detail:
            "the instance hosting this site has no URL yet — wait for it to finish provisioning"
        })

      true ->
        # site-spawner W4 (charter D36): `{force: true}` mints a genuinely new
        # build on unchanged content (a nonce varies the build_id), so a re-deploy
        # can actually re-run instead of returning the cached duplicate. Anything
        # but a literal `true` keeps the idempotent default.
        force = conn.body_params["force"] == true

        case Sites.Deploy.enqueue(site, bp, force, "manual", nil, source) do
          {:ok, deployment} ->
            case Accounts.record_audit(%{
                   team_id: site.team_id,
                   actor_user_id: conn.assigns.current_user.id,
                   action: "site.deploy_requested",
                   target_type: "deployment",
                   target_id: deployment.id,
                   metadata: %{
                     site_id: site.id,
                     kind: site.kind,
                     build_id: deployment.build_id,
                     source: deployment.source
                   }
                 }) do
              {:ok, _event} -> :ok
              {:error, cs} -> Logger.error("audit site.deploy_requested failed: #{inspect(cs)}")
            end

            # MINT-THEN-UPLOAD (charter D86), and the order is FORCED, not
            # preferred: `build_id` is baked INTO the bytes at build time
            # (site-deploy.sh exports BARKPARK_BUILD_ID and HEALTH asserts the
            # served marker BY VALUE), and `content_rev` is computed by relaying
            # to the box with the instance admin token — neither is knowable to
            # an uploader. So a prebuilt deploy mints FIRST, hands both values
            # back in this 201, and the caller uploads the resulting dist to the
            # deployment-scoped artifact route, which starts the driver.
            #
            # A box build is unchanged: the row is handed to the driver AFTER it
            # is committed and audited, so the deploy the box is asked to run is
            # one the control plane can already see, reap, and report on.
            # THE 201 IS DOWNSTREAM OF THIS. Nothing has been written to the
            # socket yet, so a refused driver spawn can still be ANSWERED rather
            # than laundered: this used to be `:ok = Sites.Deploy.start(row)`
            # against a wrapper spec'd `:: :ok`, i.e. a match that could not
            # fail, so a deploy the control plane never started was reported to
            # the operator as `201 created` with a row that would sit `queued`.
            # The row is committed and audited BEFORE the driver is asked to
            # start, so the live console is told about it either way. A refused
            # spawn leaves a real `queued` row on the record, and a console that
            # never heard about it is the same blindness one layer up: the
            # operator would read the 503 and see nothing to go look at.
            push_event(site.team_id, "deployments")
            push_event(site.team_id, "audit")

            case start_box_build(prebuilt, deployment) do
              :ok ->
                json(
                  conn,
                  201,
                  %{deployment: site_deployment_json(deployment, site, bp)}
                  |> maybe_put_upload_instruction(prebuilt, site, deployment)
                )

              {:error, reason} ->
                # The row is minted and audited, so the attempt is on the record
                # and reapable — but no build is running, and saying otherwise is
                # the failure this route exists to stop reporting. The raw term is
                # kept server-side and the client sees a bounded message (D93).
                Logger.error("site deploy_not_started (box build): #{inspect(reason)}")

                json(conn, 503, %{
                  error: "deploy_not_started",
                  detail:
                    "the deployment row was created but the build driver could not be started" <>
                      " — nothing is building. Retry the deploy; if it keeps failing the control" <>
                      " plane is out of build capacity.",
                  reason: transport_reason(reason),
                  deployment: site_deployment_json(deployment, site, bp)
                })
            end

          # Same code + same content + same config = the same build. The box's PLAN
          # stage would no-op on it anyway (build_id is already live), so answer
          # 200 with the row that already exists rather than minting a twin.
          {:duplicate, deployment} ->
            json(conn, 200, %{deployment: site_deployment_json(deployment, site, bp)})

          {:error, %Ecto.Changeset{} = cs} ->
            json(conn, 422, %{error: "invalid", details: errors(cs)})
        end
    end
  end

  # MINT-THEN-UPLOAD (charter D86): a prebuilt row deliberately starts NO driver
  # here — it waits for its artifact, and the upload route hands it over. That is
  # a success, not a skipped start. A box build starts now and reports.
  defp start_box_build(true = _prebuilt, _deployment), do: :ok

  defp start_box_build(false = _prebuilt, deployment) do
    case Sites.Deploy.start_reported(deployment) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Embed the site's LIVE deployment (stage-aware) so `bp cloud site status` shows
  # the six-stage bar without a second round trip. Absent (never deployed) it is
  # simply not there — the CLI's honest empty state ("no deployment yet — kick the
  # first build with…") depends on this key being missing, not on a fake row.
  defp put_current_deployment(json, site, bp) do
    case site.current_deployment_id && Registry.get_deployment(site.current_deployment_id) do
      %Registry.Deployment{} = d ->
        Map.put(json, :current_deployment, site_deployment_json(d, site, bp))

      _ ->
        json
    end
  end

  # Promote (rollback/redeploy) the `dep_id` deployment onto `site` — charter
  # decision 7. The source must belong to THIS (already team-scoped) site and be
  # a production deployment; a nil / non-UUID / cross-site id is the same 404 as
  # a missing one (existence-leak protection), a preview is 422 not_promotable.
  # On success the new queued Deployment + a `deployment.promoted` audit row
  # commit atomically, then the `deployments` + `audit` SSE invalidations fire.
  defp promote_deployment(conn, site) do
    source = Registry.get_deployment(conn.path_params["dep_id"])

    cond do
      is_nil(source) or source.site_id != site.id ->
        json(conn, 404, %{error: "not_found"})

      not Registry.Deployment.production?(source) ->
        json(conn, 422, %{
          error: "not_promotable",
          detail: "branch previews cannot be promoted — promote a production deployment"
        })

      # site-spawner D30: a STATIC site is never promoted. Promote is
      # promote-by-NEW-deployment (a rebuild); a static site's previous build is
      # already on disk under releases/<build_id>/, so going back to it is a
      # symlink repoint — POST /v1/sites/:id/rollback, sub-second, no rebuild.
      # Without this branch the guard below would 422 no_build_source on every
      # static row (no artifact, no repo) — the SAME lie the deploy route told.
      # site-spawner W7: a NODE site is likewise never promoted (it rolls back by
      # flipping the Caddy upstream to the previous slot), so it takes this arm too.
      site.kind in ["static", "node"] ->
        json(conn, 422, %{
          error: "not_promotable",
          detail:
            "a static site rolls back instantly (`bp cloud site rollback`) — promote is for container sites"
        })

      # Parity with POST /deploy's no_build_source guard: a source with neither a
      # pinned artifact NOR a site with a connected repo has nothing to rebuild
      # from — refuse up front with honest feedback instead of minting a queued
      # row the stale-reaper only later flips to `failed`. Reachable only if the
      # repo was disconnected after an artifact-less (github-repo) deploy; real
      # deploys always carry a build source.
      is_nil(source.artifact_url) and is_nil(site.github_repo) ->
        json(conn, 422, %{
          error: "no_build_source",
          detail: "the source deployment has no artifact and the site has no connected repo"
        })

      true ->
        # activity-audit-log: the new queued Deployment + a `deployment.promoted`
        # audit row commit in one transaction (target_id = the minted row).
        audit_promote =
          Accounts.audit(
            %{
              team_id: site.team_id,
              actor_user_id: conn.assigns.current_user.id,
              action: "deployment.promoted",
              target_type: "deployment",
              metadata: %{
                site_id: site.id,
                source_deployment_id: source.id,
                git_ref: source.git_ref
              }
            },
            fn ->
              Registry.create_deployment(site, Registry.Deployment.promotion_attrs(source))
            end,
            fn deployment -> %{target_id: deployment.id} end
          )

        case audit_promote do
          {:ok, deployment} ->
            push_event(site.team_id, "deployments")
            push_event(site.team_id, "audit")
            json(conn, 201, %{deployment: deployment_json(deployment)})

          {:error, %Ecto.Changeset{} = cs} ->
            if git_ref_conflict?(cs) do
              # A production build is already in flight at this git_ref (the
              # active-ref unique index). This is a state conflict, not bad input,
              # so answer 409 with a precise message — a generic 422 `invalid`
              # would misattribute the conflict to a git_ref the operator (who
              # POSTs an empty body) never sent.
              json(conn, 409, %{
                error: "build_in_progress",
                detail: "a build for this git ref is already in progress — wait for it to finish"
              })
            else
              # Any other insert failure — surface it honestly rather than 500.
              json(conn, 422, %{error: "invalid", details: errors(cs)})
            end
        end
    end
  end

  # True when `cs` failed on the production active-ref unique index
  # (`deployments_active_site_ref_index`) — i.e. a build is already in flight at
  # this git_ref. Matches on the constraint metadata, not the message string, so
  # it stays precise even if the human-facing message is reworded.
  defp git_ref_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:git_ref, {_msg, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  ## Helpers

  # The approved-command queue source. Empty by default; a configurable stub lets
  # a test (or cloud-13) inject commands without a queue backend.
  defp command_queue do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:command_queue, [])
  end

  # Pull the Stripe-Signature header off the inbound webhook request. Absent →
  # "" so verify_webhook fails closed (an unsigned event grants nothing) instead
  # of crashing on a nil signature.
  defp stripe_signature(conn) do
    case Plug.Conn.get_req_header(conn, "stripe-signature") do
      [sig | _] -> sig
      _ -> ""
    end
  end

  # Re-confirm the authed user's password for a destructive billing action
  # (cancel). Delegates to Accounts.get_user_by_email_and_password/2, which runs
  # Bcrypt.verify_pass with a timing-safe no_user_verify fallback. A non-binary
  # / absent password fails closed (false) without touching the hash.
  defp confirm_password(conn) do
    user = conn.assigns[:current_user]
    password = conn.body_params["password"]

    is_binary(password) and not is_nil(user) and
      match?(%{}, Accounts.get_user_by_email_and_password(user.email, password))
  end

  # A per-claim opaque token stamped onto the claimed job — traces a job to the
  # worker run that holds it. Not a credential (the worker auths with the shared
  # WORKER_TOKEN); just a claim marker.
  defp generate_claim_token,
    do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  # The agent reports health_status ∈ up/down/unknown; default unknown if absent
  # or out-of-enum so a malformed field never crashes the health changeset.
  defp normalize_health(s) when s in ["up", "down", "unknown"], do: s
  defp normalize_health(_), do: "unknown"

  # A report means the agent is online; honour an explicit offline, else online.
  defp normalize_agent("offline"), do: "offline"
  defp normalize_agent(_), do: "online"

  # site-spawner W1: the default framework for a Site `kind` — a static site with
  # no explicit framework lands on astro (the flagship), a container site on
  # nextjs (the pre-W1 default). An unknown kind keeps nextjs; the changeset's
  # kind-inclusion check is what rejects it.
  defp default_framework("static"), do: "astro"
  defp default_framework(_), do: "nextjs"

  # site-spawner W1/D29: fold the content binding into the create attrs — the
  # bootstrap_* dataset triple (which Barkpark dataset the build reads) plus the
  # plaintext read_token (create_site encrypts it at rest). Only present,
  # non-blank keys are added, so a container site's attrs stay exactly as before.
  #
  # BOTH spellings are accepted, and that is the whole point: the CLI sends
  # `workspace` / `project` / `dataset` (cloudclient.SpawnSiteCreate), while
  # `Site.changeset` casts only `:bootstrap_*`. Ecto's `cast/3` DISCARDS unknown
  # keys SILENTLY — so before this, `bp cloud site create --dataset …` returned a
  # cheerful 201 for a site with no content binding at all, and the first thing
  # that ever mentioned it was the reaper, 60 seconds later, killing the deploy.
  # The explicit `bootstrap_*` spelling wins when both are sent.
  defp put_site_content_binding(attrs, body) when is_map(body) do
    [
      {:bootstrap_workspace, ["bootstrap_workspace", "workspace"]},
      {:bootstrap_project, ["bootstrap_project", "project"]},
      {:bootstrap_dataset, ["bootstrap_dataset", "dataset"]},
      # site-spawner W4 (charter D35): the content type the build reads. OPTIONAL
      # — a create with no `doc_type` keeps the schema default "post"; it is NOT
      # part of require_content_binding (the content binding is workspace/project/
      # dataset, doc_type just selects which type within it).
      {:doc_type, ["doc_type"]},
      # search-template W2 (charter D8): explicit shipped-starter selection.
      # OPTIONAL — nil keeps the framework-derived default (astro->astro-starter,
      # nextjs->next-starter); Site.changeset validates the closed slug set.
      {:template, ["template"]},
      # search-template W6: the deploy-pinned palette. OPTIONAL — nil keeps the
      # template default; Site.changeset validates the closed palette set.
      {:theme, ["theme"]},
      {:read_token, ["read_token"]}
    ]
    |> Enum.reduce(attrs, fn {key, params}, acc ->
      case Enum.find_value(params, fn p ->
             case body[p] do
               v when is_binary(v) and v != "" -> v
               _ -> nil
             end
           end) do
        nil -> acc
        v -> Map.put(acc, key, v)
      end
    end)
  end

  # site-spawner D29: mint the site's PUBLIC-READ content token on the instance
  # and fold the plaintext into the create attrs (`Registry.create_site/2`
  # Vault-encrypts it; the plaintext never lands in the DB and is never
  # serialized back).
  #
  # Only for a content-bound STATIC site: a container site brings its own repo and
  # has nothing to read, and a caller who explicitly supplied a `read_token` keeps
  # theirs (BYO-token stays possible). Everything else — a container site, a
  # static site with an incomplete triple — passes straight through, and the
  # changeset/reaper give the honest verdict for a half-bound row.
  # A static site with no content binding is the GHOST this route exists to
  # prevent: `Site.changeset` would happily insert it, the CLI would print a
  # cheerful 201, and ~60s later the deploy reaper would terminally fail it with
  # a message the user can no longer act on (the site already exists). The build
  # fetches from workspace/project/dataset and has literally nothing to render
  # without all three, so the honest answer is a 422 at the door naming the flag.
  # The reaper's static pass stays as the safety net for rows that predate this.
  defp require_content_binding("static", attrs), do: require_content_triple(attrs)

  # site-spawner W7 (charter D62): a NODE site is content-bound EXACTLY like a
  # static one — its SSR build fetches from workspace/project/dataset and has
  # literally nothing to render without all three. It must NOT fall through to the
  # `_kind -> :ok` catch-all (which is for container BYO-repo sites): an unbound
  # node site is the same ghost the static clause exists to kill.
  defp require_content_binding("node", attrs), do: require_content_triple(attrs)

  defp require_content_binding(_kind, _attrs), do: :ok

  # site-spawner W7 (charter D68): fold the allocated node-slot port base into the
  # create attrs for a node site. Non-node sites pass through untouched (no
  # port_base). An exhausted window fails closed — no portless node row is minted.
  defp allocate_node_port("node", attrs) do
    case Sites.NodePortAllocator.allocate() do
      {:ok, base} -> {:ok, Map.put(attrs, :port_base, base)}
      {:error, :exhausted} -> {:error, :ports_exhausted}
    end
  end

  defp allocate_node_port(_kind, attrs), do: {:ok, attrs}

  defp require_content_triple(attrs) do
    missing =
      [
        {:bootstrap_workspace, "workspace"},
        {:bootstrap_project, "project"},
        {:bootstrap_dataset, "dataset"}
      ]
      |> Enum.reject(fn {key, _label} -> is_binary(attrs[key]) end)
      |> Enum.map(fn {_key, label} -> label end)

    if missing == [], do: :ok, else: {:error, {:binding_required, missing}}
  end

  # site-spawner W7 (charter D62): a node site is content-bound like a static one,
  # so it mints the SAME public-read token over the SAME scoped route.
  defp mint_site_read_token(bp, %{kind: kind} = attrs, slug) when kind in ["static", "node"] do
    ws = attrs[:bootstrap_workspace]
    proj = attrs[:bootstrap_project]
    ds = attrs[:bootstrap_dataset]

    cond do
      is_binary(attrs[:read_token]) ->
        {:ok, attrs}

      is_binary(ws) and is_binary(proj) and is_binary(ds) ->
        # The label comes from `Registry.site_read_token_label/1`, not a local
        # literal: the revoke on delete and the orphan sweep find this credential
        # BY that label (the CP never stores its box-side id), so a drift between
        # mint and revoke would silently reopen the leak ssw8 closed.
        label = Registry.site_read_token_label(slug)

        case Registry.mint_public_read_token(bp, ws, proj, ds, label) do
          {:ok, token} -> {:ok, Map.put(attrs, :read_token, token)}
          {:error, reason} -> {:error, {:mint_failed, mint_failure_copy(bp, reason)}}
        end

      true ->
        {:ok, attrs}
    end
  end

  defp mint_site_read_token(_bp, attrs, _slug), do: {:ok, attrs}

  # ssw8 — the DELETE's credential half, in the wire's own words.
  #
  #   "revoked"     — the box confirms no live token by this site's label remains
  #   "none"        — the site had no content binding, so none was ever minted
  #   "not_revoked" — the revoke could NOT be confirmed; assume the credential is live
  #
  # Three values, not a boolean, because "there was nothing to revoke" and "we
  # could not revoke it" are opposite facts and a boolean would collapse one of
  # them into the other.
  defp read_token_status(:ok), do: "revoked"
  defp read_token_status(:noop), do: "none"
  defp read_token_status(_), do: "not_revoked"

  # On an unconfirmed revoke, hand the caller the pointer the deleted row can no
  # longer hold: which box, which workspace scope, which label. Without these
  # three the credential is live AND unreachable — the state this row exists to
  # prevent — because nothing else in the control plane records a site's box-side
  # token identity. A confirmed (or absent) credential adds nothing.
  defp site_delete_token_warning(body, _site, status) when status in [:ok, :noop], do: body

  defp site_delete_token_warning(body, site, _status) do
    bp = Registry.get_barkpark(site.barkpark_id)
    box = if bp, do: bp.slug, else: "its instance"
    scope = "#{site.bootstrap_workspace}/#{site.bootstrap_project}"

    Map.put(
      body,
      :warning,
      "the site is deleted, but its read token could not be revoked: #{box} did not confirm " <>
        "the revoke. The credential #{Registry.site_read_token_label(site)} in workspace scope " <>
        "#{scope} may still be LIVE and can still read published content. Revoke it on the box " <>
        "(DELETE /w/#{site.bootstrap_workspace}/p/#{site.bootstrap_project}/v1/tokens/:id) or run " <>
        "`mix barkpark_cloud.site_read_tokens #{box}` on the control plane to find and revoke it."
    )
  end

  # The instance's own words, in plain language. A mint failure is almost always
  # an instance-side fact (not live yet, no stored admin token, the token route is
  # older than public-read), and naming WHICH box and WHAT it said is the
  # difference between a fixable error and a shrug.
  defp mint_failure_copy(bp, {:instance, status, body}) do
    detail = mint_failure_detail(body)

    base =
      "#{bp.slug} refused to mint the site's read token (HTTP #{status})"

    if is_binary(detail) and detail != "", do: "#{base}: #{detail}", else: base
  end

  defp mint_failure_copy(bp, :not_live),
    do: "#{bp.slug} has no URL yet — wait for it to finish provisioning, then create the site"

  defp mint_failure_copy(bp, :no_admin_token),
    do: "#{bp.slug} has no stored admin token — the control plane cannot mint a read token on it"

  defp mint_failure_copy(bp, :decrypt_failed),
    do: "#{bp.slug}'s admin token could not be decrypted"

  defp mint_failure_copy(bp, _reason),
    do: "#{bp.slug} is unreachable — could not mint the site's read token"

  # The box's refusal arrives one of two ways: FLAT (`{"error": "forbidden"}`)
  # or wrapped in a typed envelope (`{"error": {"code": ..., "message": ...}}` —
  # TokenController's 422, and the 401/403 auth plugs nest the same way). A
  # wrapped body used to reach the is_binary guard in mint_failure_copy/2 as a
  # MAP, fail it, and the box's own words were discarded — the sibling of the
  # rollback/teardown relay's nested-envelope drop (#11846). Reach INTO the
  # envelope BEFORE the guard: compose the machine `code` and the human string
  # as `code — message` so the 502 detail names WHY, not just WHICH box. The flat
  # arm is untouched, so flat bodies resolve BYTE-IDENTICALLY to pre-fix output.
  defp mint_failure_detail(%{"error" => %{} = err}) do
    human = err["message"] || err["detail"] || err["reason"]
    code = err["code"]

    cond do
      is_binary(code) and code != "" and is_binary(human) and human != "" ->
        "#{code} — #{human}"

      is_binary(human) and human != "" ->
        human

      is_binary(code) and code != "" ->
        code

      true ->
        nil
    end
  end

  defp mint_failure_detail(body) when is_map(body),
    do: body["error"] || body["detail"] || body["reason"]

  defp mint_failure_detail(_body), do: nil

  ## site-spawner W8 (charter D73/D74/D75) — CREATE VERIFIES THE BINDING BY
  ## READING IT.
  ##
  ## `content_bound: true` used to mean `not is_nil(read_token_encrypted)` — i.e.
  ## "a token was minted", which every content-bound site has, so the field
  ## discriminated nothing. The triple was checked for PRESENCE and never for
  ## TRUTH: a typo'd dataset or a doc_type the site cannot see was accepted, the
  ## row was written, and the build died minutes later on one line naming neither
  ## the type nor the dataset nor a remedy.
  ##
  ## The read is done with the SITE'S OWN just-minted public-read token, over the
  ## SAME scoped `query/:ds/:type` route the build later fetches with — never over
  ## the instance admin token, which sees content the clamped build credential
  ## cannot (charter D74). `counts` is deliberately NOT probed with that token:
  ## `Plugs.PublicRead` admits only `query` and `doc`, so counts 403s it.
  ##
  ## THREE verdicts, a dialect of `cloud_deploy_cmd.go`'s five outcomes:
  ##
  ##   * BOUND      — the site read its own content. Proceed, and say what it saw.
  ##   * EMPTY      — a body the control plane could INTERPRET, showing nothing
  ##                  (or a definite 404 on the exact route the build uses).
  ##                  Refuse 422 with the real menu and the exact re-run.
  ##   * UNVERIFIED — the read could not be PERFORMED, or its body could not be
  ##                  interpreted. Proceed — but never call it `ok`: the 201 says
  ##                  `unverified` with the reason in the same breath.
  ##
  ## The EMPTY/UNVERIFIED split is load-bearing (charter D75): an unexpected
  ## 200-with-a-shape-we-do-not-know is a control-plane blind spot, not a verdict
  ## on the user's content, and turning it into a refusal would lock strangers out
  ## of creating sites the moment the box's response envelope changed.

  # At most this many candidate types are probed when BUILDING THE REFUSAL MENU.
  # The happy path costs exactly ONE extra box call; only a create that is already
  # being refused pays for the menu, and it pays a bounded price.
  @binding_menu_probe_limit 8

  defp verify_content_binding(bp, %{kind: kind} = attrs) when kind in ["static", "node"] do
    ws = attrs[:bootstrap_workspace]
    proj = attrs[:bootstrap_project]
    ds = attrs[:bootstrap_dataset]
    # `doc_type` is optional on the wire; the Site schema defaults it to "post",
    # so that is the type the build would actually read.
    type = attrs[:doc_type] || "post"
    token = attrs[:read_token]

    cond do
      not (is_binary(ws) and is_binary(proj) and is_binary(ds)) ->
        {:ok, {:unverified, "the site is not fully bound — there was nothing to read"}}

      not (is_binary(token) and token != "") ->
        {:ok, {:unverified, "the site has no read token — its content could not be probed"}}

      true ->
        case site_token_read(bp, ws, proj, ds, type, token) do
          {:readable, total} -> {:ok, {:bound, type, total}}
          {:unverified, why} -> {:ok, {:unverified, why}}
          {:empty, why} -> refuse_empty_binding(bp, ws, proj, ds, token, why)
        end
    end
  end

  # A container site builds from a repo — it has no binding to verify, and the
  # 201 says nothing about one rather than inventing a verdict.
  defp verify_content_binding(_bp, _attrs), do: {:ok, :not_applicable}

  # THE read: the site's own credential, the build's own route.
  defp site_token_read(bp, ws, proj, ds, type, token) do
    path = scoped_query_probe(ws, proj, ds, type)

    case Registry.relay_as(bp, :get, path, token) do
      {:ok, status, body} when status in 200..299 ->
        case interpret_query_body(body) do
          {:ok, page, total} when page > 0 ->
            {:readable, total}

          {:ok, 0, _total} ->
            {:empty, "#{type} in #{ds} has no documents this site can read"}

          :uninterpretable ->
            {:unverified,
             "#{bp.slug} answered the content read with a body the control plane " <>
               "could not interpret (HTTP #{status})"}
        end

      # The box's definite "there is nothing here" for the exact URL the build
      # uses. A typo'd dataset, a typo'd type and a non-public type are BYTE
      # IDENTICAL here (both 404 "not found") — which is precisely why the menu
      # below is worth the extra calls: it answers the question the 404 cannot.
      {:ok, 404, _body} ->
        {:empty,
         "#{ds}/#{type} answered 404 for this site's own read token — that dataset " <>
           "or type does not exist, or the type is not readable by a public-read token"}

      {:ok, status, _body} ->
        {:unverified,
         "#{bp.slug} answered the content read HTTP #{status} — the binding could not be checked"}

      {:error, reason} ->
        {:unverified, binding_relay_failure_copy(bp, reason)}
    end
  end

  # The query envelope is `{"result": {...}}` when the box's response filter is on
  # and the bare inner map when it is off — interpret BOTH, and nothing else. A
  # body that matches neither is a shape we do not know, which is `unverified`
  # (charter D75), never `empty`.
  #
  # TWO numbers, and they are NOT interchangeable. `count` is the PAGE size the
  # query returned, so under `?limit=1` it is 0 or 1 and nothing else — it answers
  # "is there anything here", never "how much". `total` is the box's own published
  # aggregate for the type, present only because the probe asks `?count=true`, and
  # it is the ONLY number this route is entitled to report to a user. An older box
  # that does not know `count=true` returns no `total`, and then the verdict
  # carries NO magnitude rather than passing the page size off as one.
  defp interpret_query_body(%{"result" => %{} = result}), do: interpret_query_body(result)

  defp interpret_query_body(%{"count" => count} = body) when is_integer(count),
    do: {:ok, count, query_total(body)}

  defp interpret_query_body(%{"documents" => docs} = body) when is_list(docs),
    do: {:ok, length(docs), query_total(body)}

  defp interpret_query_body(_body), do: :uninterpretable

  defp query_total(%{"total" => total}) when is_integer(total), do: total
  defp query_total(_body), do: nil

  # The refusal: name what is wrong, what this site CAN read, and the exact re-run.
  defp refuse_empty_binding(bp, ws, proj, ds, token, why) do
    menu = readable_type_menu(bp, ws, proj, ds, token)

    detail =
      "this site would build from nothing — #{why}. " <>
        menu_sentence(menu, ds) <>
        " Re-run naming a type this site can read: " <>
        "`bp cloud site create <name> --kind static --framework astro " <>
        "--dataset #{ws}/#{proj}/#{ds} --doc-type <type>`"

    {:error, {:binding_empty, detail, menu}}
  end

  # The honest menu is the INTERSECTION: the instance admin token lists what EXISTS
  # (one `counts` call, no N+1), and the site's own token says which of those it can
  # actually read. Offering the admin list raw would hand a stranger a private type
  # and set up a build that 404s.
  #
  # The admin `counts` supply the CANDIDATE LIST and the probe ORDER — never the
  # magnitudes the user is shown. A sentence that opens "This site CAN read" may
  # only carry numbers the SITE's own token produced, or the count is an admin
  # number wearing a site label (an admin sees drafts-free totals over types whose
  # documents may still be field-redacted for a public-read caller, so it is an
  # upper bound, not the site's number). Each surviving type therefore reports the
  # `total` its own probe returned, and a type whose probe reports no total is
  # listed WITHOUT a number.
  defp readable_type_menu(bp, ws, proj, ds, token) do
    path = "/w/#{URI.encode(ws)}/p/#{URI.encode(proj)}/v1/data/counts/#{URI.encode(ds)}"

    case Registry.relay_admin(bp, :get, path, nil) do
      {:ok, status, %{"counts" => counts}} when status in 200..299 and is_map(counts) ->
        {:ok, intersect_readable_types(bp, ws, proj, ds, token, counts)}

      _ ->
        :unavailable
    end
  end

  defp intersect_readable_types(bp, ws, proj, ds, token, counts) do
    counts
    |> Enum.filter(fn {type, count} -> is_binary(type) and is_integer(count) and count > 0 end)
    |> Enum.sort_by(fn {type, count} -> {-count, type} end)
    |> Enum.take(@binding_menu_probe_limit)
    |> Enum.flat_map(fn {type, _admin_count} ->
      case site_readable_total(bp, ws, proj, ds, type, token) do
        {:readable, total} -> [{type, total}]
        :no -> []
      end
    end)
  end

  # Readable, and — when the box reports one — the site's OWN published total for
  # the type. `:no` covers both "the site cannot read this" and "the answer was a
  # shape we do not know": neither may be offered as a candidate.
  defp site_readable_total(bp, ws, proj, ds, type, token) do
    path = scoped_query_probe(ws, proj, ds, type)

    case Registry.relay_as(bp, :get, path, token) do
      {:ok, status, body} when status in 200..299 ->
        case interpret_query_body(body) do
          {:ok, _page, total} -> {:readable, total}
          :uninterpretable -> :no
        end

      _ ->
        :no
    end
  end

  defp menu_sentence({:ok, []}, ds),
    do: "Nothing in #{ds} is readable by this site's public-read token."

  defp menu_sentence({:ok, menu}, _ds) do
    "This site CAN read: " <>
      (menu |> Enum.map(&menu_entry/1) |> Enum.join(", ")) <> "."
  end

  defp menu_sentence(:unavailable, ds),
    do: "The control plane could not list what IS readable in #{ds}."

  defp menu_entry({type, total}) when is_integer(total), do: "#{type} (#{total})"
  defp menu_entry({type, nil}), do: type

  # The build's own route, plus `count=true` — which is what makes the reported
  # magnitude the box's published TOTAL for the type rather than the page size the
  # `limit=1` probe itself chose.
  defp scoped_query_probe(ws, proj, ds, type) do
    scoped_query_path(ws, proj, ds, type) <> "?limit=1&count=true"
  end

  defp scoped_query_path(ws, proj, ds, type) do
    "/w/#{URI.encode(ws)}/p/#{URI.encode(proj)}/v1/data/query/#{URI.encode(ds)}/#{URI.encode(type)}"
  end

  defp binding_relay_failure_copy(bp, :not_live),
    do: "#{bp.slug} has no URL yet — the site's content could not be read"

  defp binding_relay_failure_copy(bp, _reason),
    do: "#{bp.slug} could not be reached — the site's content could not be read"

  # What the 201 SAYS about the read. `bound` carries what the site actually saw;
  # `unverified` carries WHY it could not be confirmed — never a bare `ok`. The
  # `count` key is the box's published TOTAL for the bound type and is OMITTED
  # entirely when the box reported none: `bound` without a magnitude is the honest
  # shape, and an absent key cannot be misread the way a fabricated `1` would be.
  defp binding_note({:bound, type, total}) when is_integer(total),
    do: %{content_binding: %{status: "bound", doc_type: type, count: total}}

  defp binding_note({:bound, type, nil}),
    do: %{content_binding: %{status: "bound", doc_type: type}}

  defp binding_note({:unverified, why}),
    do: %{content_binding: %{status: "unverified", detail: why}}

  defp binding_note(:not_applicable), do: %{}

  defp maybe_put_menu(body, {:ok, [_ | _] = menu}) do
    Map.put(body, :readable_types, Enum.map(menu, &menu_row/1))
  end

  defp maybe_put_menu(body, _menu), do: body

  defp menu_row({type, total}) when is_integer(total), do: %{type: type, count: total}
  defp menu_row({type, nil}), do: %{type: type}

  # name → slug: lowercase, non-alnum → hyphen, trim hyphens. Falls back to a
  # short random suffix so a name like "!!!" still yields a valid slug.
  defp slugify(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if base == "" do
      "bp-" <>
        (:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false) |> String.downcase())
    else
      base
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # A bare 302 to `location` with an empty body — the OAuth routes' only response
  # shape (kick-off → IdP, callback → SPA fragment). The browser follows the
  # Location header; nothing is rendered.
  defp redirect_to(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  # Narrow the push-relay provisioning body to the four options
  # Registry.provision_push_relay_webhook/2 accepts. An ALLOWLIST, not a
  # pass-through: the keyword list reaches a function that talks to the
  # instance with the admin token, so an unrecognised key must never ride
  # along. Absent/blank values are dropped so the barkpark's bootstrap_*
  # defaults win, and a non-integer threshold is ignored rather than crashing
  # the box's changeset.
  defp push_relay_opts(params) when is_map(params) do
    slugs =
      for key <- [:workspace, :project, :dataset],
          value = params[Atom.to_string(key)],
          is_binary(value) and value != "",
          do: {key, value}

    case params["blocked_threshold_s"] do
      n when is_integer(n) and n > 0 -> [{:blocked_threshold_s, n} | slugs]
      _ -> slugs
    end
  end

  defp push_relay_opts(_params), do: []

  ## Live events (SSE) helpers

  # Broadcast a coarse invalidation `type` to a team's connected dashboards.
  # Thin wrapper over BarkparkCloud.Events so the mutation sites read cleanly.
  defp push_event(team_id, type), do: Events.broadcast(team_id, type)

  # Resolve a barkpark's owning team and push `type` to it. Used by the WORKER
  # routes (succeed/fail job), which authenticate as a faceless principal and so
  # have no current_team — the team is derived from the affected barkpark. A
  # since-deleted barkpark is a silent no-op.
  defp broadcast_barkpark_team(barkpark_id, type) do
    case Registry.get_barkpark(barkpark_id) do
      %Barkpark{team_id: tid} -> push_event(tid, type)
      _ -> :ok
    end
  end

  # notifications-email: resolve a barkpark's owning team + name and fire an
  # email alert for `event`. Used by the WORKER routes (succeed/fail job), which
  # have no current_team — the team is derived from the affected barkpark. A
  # since-deleted barkpark is a silent no-op. dispatch_event itself never raises.
  defp dispatch_barkpark_event(barkpark_id, event, payload \\ %{}) do
    case Registry.get_barkpark(barkpark_id) do
      %Barkpark{team_id: tid, name: name} ->
        Notifications.dispatch_event(tid, event, Map.put_new(payload, :name, name))

      _ ->
        :ok
    end
  end

  # notifications-email: email only on a health up↔down FLIP. down/unknown → up
  # is "reachable again"; up → down is "unreachable". A steady-state report (no
  # change) or a flip to/from "unknown" mid-provision sends nothing.
  defp maybe_dispatch_health_flip(%Barkpark{} = bp, prior, new) when prior != new do
    case {prior, new} do
      {"down", "up"} -> dispatch_barkpark_event(bp.id, :agent_reachable)
      {"unknown", "up"} -> dispatch_barkpark_event(bp.id, :agent_reachable)
      {"up", "down"} -> dispatch_barkpark_event(bp.id, :agent_unreachable)
      _ -> :ok
    end
  end

  defp maybe_dispatch_health_flip(_bp, _prior, _new), do: :ok

  # dwb (charter D9): fire-and-forget an isu-6 update-status refresh for a
  # now-live barkpark. `refresh_update_status/1` makes an HTTP call to the
  # instance and best-effort-persists even on transport failure (it never raises),
  # so this can NEVER block or fail the caller's response.
  #
  # Spawned with raw `spawn/1` — deliberately NOT `Task.start`, which propagates
  # `$callers` and would let the probe BORROW the caller's Ecto.Sandbox connection
  # under `async: true` tests, then race test teardown (the repo's known
  # sandbox-ownership cascade). A plain spawn inherits no ownership, so in the test
  # sandbox the DB read fails cleanly (rescued below, zero noise) while in prod it
  # checks out a normal pooled connection. A since-deleted barkpark is a no-op.
  defp kick_update_status_refresh(barkpark_id) do
    spawn(fn ->
      try do
        case Registry.get_barkpark(barkpark_id) do
          %Barkpark{} = bp -> Registry.refresh_update_status(bp)
          _ -> :ok
        end
      rescue
        # Best-effort telemetry: any probe failure (including the test sandbox's
        # no-ownership DBConnection error) must never crash-log. refresh itself
        # never raises in prod, so this only ever fires under the async test seam.
        _ -> :ok
      end
    end)

    :ok
  end

  # Resolve a site's owning team and push `type` to it. Used by the deployment
  # transition routes (builder/agent principals have no current_team).
  defp broadcast_site_team(site_id, type) do
    case Registry.get_site(site_id) do
      %Registry.Site{team_id: tid} -> push_event(tid, type)
      _ -> :ok
    end
  end

  defp team_id_for_barkpark_of_job(job_id) do
    with id when is_binary(id) <- job_id,
         %BarkparkCloud.Registry.ProvisionJob{barkpark_id: bp_id} <- safe_get_job(id),
         %Barkpark{team_id: tid} <- Registry.get_barkpark(bp_id) do
      tid
    else
      _ -> nil
    end
  end

  defp safe_get_job(id), do: Repo.get_by_uuid(BarkparkCloud.Registry.ProvisionJob, id)

  # `?mode=detach` on DELETE /v1/fleet/supports/:id — registry-only removal, for
  # a caller that already tore the box and its DNS record down (task-688ebffc4b0aa50a).
  # Read from the QUERY STRING, not a body: a DELETE body is not reliably sent by
  # every client (the Go CLI's own delete helper sends none), so a mode that only
  # arrived in a body would silently degrade to the default — which here means an
  # unexpected 202 rather than a leak, but a silent shape change either way.
  defp fleet_support_detach?(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    conn.query_params["mode"] == "detach"
  end

  defp deprovision_live_barkpark(conn, team, bp) do
    case Registry.enqueue_deprovision_job(bp) do
      {:ok, _job} ->
        push_event(team.id, "fleet")
        json(conn, 202, %{ok: true, status: "deprovisioning"})

      {:error, :already_deprovisioning} ->
        json(conn, 202, %{ok: true, status: "deprovisioning"})

      {:error, cs} ->
        json(conn, 422, %{error: "invalid", details: errors(cs)})
    end
  end

  # Auth for GET /v1/events. The browser EventSource API can't set headers, so
  # the stream credential HAS to ride the URL — but what rides it is a `?ticket=`,
  # never a session token: a single-use, 60-second, SSE-scoped ticket minted over
  # POST /v1/auth/sse-ticket with the bearer in an Authorization header. Redeeming
  # it BURNS it, so the copy left behind in every access log and proxy trace is
  # dead on arrival. An Authorization header is still honoured and still takes a
  # full session token (curl, an EventSource polyfill, the CLI) — that path never
  # writes the credential into a URL, so it is not the leak.
  #
  # A burnt/expired/absent ticket answers 401, which is TERMINAL for EventSource
  # (measured: the browser goes to readyState 2 and NEVER retries), so recovery is
  # the SPA's job, not the browser's: app.js remints and reopens on every stream
  # error rather than letting the native retry replay a spent ticket.
  #
  # Both credential paths also resolve the SESSION ROW behind the stream
  # (cch-w53-bl): the header path knows it directly, the ticket path reads the
  # binding stamped at mint. `nil` is legitimate — an unbound legacy ticket — and
  # means the loop falls back to the user-wide liveness check.
  #
  # Assigns :current_user + :current_team + :sse_session_token_id on success;
  # halts 401 otherwise.
  defp require_user_sse(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    {user, session_token_id} =
      case Auth.bearer_token(conn) do
        header when is_binary(header) and header != "" ->
          case Accounts.verify_user_session_token(header) do
            %{} = user -> {user, Accounts.live_session_token_id(header)}
            _ -> {nil, nil}
          end

        _ ->
          case conn.query_params["ticket"] do
            ticket when is_binary(ticket) and ticket != "" ->
              case Accounts.consume_sse_ticket_binding(ticket) do
                {user, session_token_id} -> {user, session_token_id}
                nil -> {nil, nil}
              end

            _ ->
              {nil, nil}
          end
      end

    case user do
      %{} = user ->
        conn
        |> assign(:current_user, user)
        |> assign(:current_team, Accounts.primary_team(user))
        |> assign(:sse_session_token_id, session_token_id)

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  # Subscribe the request process to the team's event group, then hold the
  # connection open as an SSE stream: an opening comment, then one `data:` frame
  # per broadcast, with a heartbeat comment every 25s so an idle stream isn't
  # reaped by a fronting proxy. A failed chunk (client gone) ends the loop; :pg
  # auto-unsubscribes the dying process.
  #
  # The loop carries the connecting PRINCIPAL — the user's id and, when the
  # credential carried one, the session row the stream belongs to — because it
  # must OUTLIVE its own credential check. See `sse_loop/3`.
  defp stream_events(conn, team_id) do
    :ok = Events.subscribe(team_id)

    principal = %{
      user_id: conn.assigns.current_user.id,
      session_token_id: conn.assigns[:sse_session_token_id]
    }

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case Plug.Conn.chunk(conn, ": connected\n\n") do
      {:ok, conn} -> sse_loop(conn, principal, System.monotonic_time(:millisecond))
      {:error, _} -> conn
    end
  end

  # The parked stream, and the ONE thing to understand about it: authentication
  # happened once, at connect, and the credential is already gone by the time we
  # get here (an `?ticket=` is BURNED inside the connect transaction). So the loop
  # cannot re-verify a token — it remembers a PRINCIPAL and re-asks the sharpest
  # question that survives the burn: is the SESSION ROW this stream belongs to
  # still live? (`session_token_id`; and where there is none, the older, blunter
  # question — does this user still have any live session at all?)
  #
  # Before cch-w53-s4 it asked nothing. "Sign out everywhere" stamped every
  # session row revoked and this loop kept chunking team events to the signed-out
  # device forever — measured across two heartbeats at ~t+55s, with no bound at
  # all except the client hanging up. For the console SPA that self-heals (the
  # refetch each event triggers 401s and bounces to login); for a client that
  # only READS — curl, a script, a stolen laptop — nothing ended it, and the
  # frames are not all contentless (`site.deploy.stage` carries site/deployment/
  # stage, `barkpark.suspended` carries a barkpark_id).
  #
  # THE BOUND IS ONE HEARTBEAT, NOT IMMEDIACY. The heartbeat tick ALWAYS
  # rechecks, so an idle stream dies within ~25s of the revoke. The event path
  # rechecks too but THROTTLED to the same window, so a chatty team cannot turn
  # every broadcast into a query. Worst case a revoked stream sees frames for one
  # more window; before, it saw them for its whole life.
  #
  # PER-ROW REVOKE IS NOW COVERED TOO (cch-w53-bl). The user-wide check could not
  # see it: `DELETE /v1/account/sessions/:id` revokes ONE session and the ACTING
  # session keeps the count >= 1, so a user who spotted an unfamiliar device and
  # revoked it got a row that disappeared and a stream that did not. The
  # `user_tokens.session_token_id` column binds a stream to the session that
  # minted its credential, and `sse_principal_live?/1` rechecks THAT row — same
  # one-heartbeat bound, now per device.
  #
  # A stream with NO binding (a ticket minted before the column existed) keeps the
  # user-wide behaviour exactly: strictly weaker, never wrong, and it drains
  # within one ticket TTL of a deploy.
  defp sse_loop(conn, principal, checked_at) do
    receive do
      {:bpcloud_event, event} ->
        case sse_session_check(principal, checked_at, sse_recheck_ms()) do
          :revoked ->
            end_revoked_sse(conn, principal)

          {:live, checked_at} ->
            case encode_sse_frame(event) do
              {:ok, frame} ->
                case Plug.Conn.chunk(conn, frame) do
                  {:ok, conn} -> sse_loop(conn, principal, checked_at)
                  {:error, _} -> conn
                end

              :error ->
                # An unencodable event must NOT crash (and so close) the whole SSE
                # stream — the event is only an invalidation hint, safely dropped.
                # Log and keep parking for the next (good) event / heartbeat.
                Logger.error("sse_loop: dropping unencodable event #{inspect(event)}")
                sse_loop(conn, principal, checked_at)
            end
        end
    after
      sse_heartbeat_ms() ->
        # `0` forces the check: the heartbeat is the guaranteed recheck point,
        # and it is what makes the revocation bound a bound.
        case sse_session_check(principal, checked_at, 0) do
          :revoked ->
            end_revoked_sse(conn, principal)

          {:live, checked_at} ->
            case Plug.Conn.chunk(conn, ": ping\n\n") do
              {:ok, conn} -> sse_loop(conn, principal, checked_at)
              {:error, _} -> conn
            end
        end
    end
  end

  # `{:live, checked_at}` (possibly the SAME checked_at, when the throttle window
  # has not elapsed) or `:revoked`. Throttled by monotonic time, never wall clock.
  defp sse_session_check(principal, checked_at, recheck_ms) do
    now = System.monotonic_time(:millisecond)

    cond do
      now - checked_at < recheck_ms -> {:live, checked_at}
      sse_principal_live?(principal) -> {:live, now}
      true -> :revoked
    end
  end

  # A BOUND stream asks about its own session row, so revoking that one device
  # ends that one stream while every sibling device keeps streaming. An UNBOUND
  # one asks the user-wide question, which is the pre-cch-w53-bl behaviour and
  # still ends the stream on sign-out-everywhere / password change.
  #
  # The clause order is the whole fix: swap them and a bound stream falls back to
  # the count that per-row revoke can never drive to zero.
  defp sse_principal_live?(%{session_token_id: session_token_id})
       when is_binary(session_token_id),
       do: Accounts.session_token_live?(session_token_id)

  defp sse_principal_live?(%{user_id: user_id}),
    do: Accounts.user_has_live_session?(user_id)

  # End a stream whose user has no live session left. Returning `conn` ends the
  # chunked response, which the client sees as the stream closing; the SPA's
  # error handler remints and gets a 401, which is its normal path to /login.
  # Logged because a stream ending for AUTHORISATION reasons is otherwise
  # indistinguishable from a network drop in the access log.
  defp end_revoked_sse(conn, %{user_id: user_id, session_token_id: session_token_id}) do
    Logger.info(
      "sse_loop: ending stream for user #{user_id}, session #{inspect(session_token_id)} not live"
    )

    conn
  end

  # The idle heartbeat cadence, and the throttle window for the liveness recheck
  # on the event path. Overridable ONLY so a test can observe the recheck without
  # sleeping 25 seconds per assertion — production reads the defaults.
  defp sse_heartbeat_ms,
    do: Application.get_env(:barkpark_cloud, :sse_heartbeat_ms, 25_000)

  defp sse_recheck_ms,
    do: Application.get_env(:barkpark_cloud, :sse_recheck_ms, 25_000)

  # Encode one event as an SSE `data:` frame. A Jason failure (an unencodable
  # payload) returns :error so the loop can SKIP this frame instead of raising
  # and tearing down the connection — uses Jason.encode/1, never the `!` variant.
  defp encode_sse_frame(event) do
    case Jason.encode(event) do
      {:ok, json} -> {:ok, "data: " <> json <> "\n\n"}
      {:error, _} -> :error
    end
  end

  ## GitHub webhook helpers (P7 stream B)

  # Recover the EXACT request bytes Plug.Parsers consumed. `cache_raw_body/2`
  # stashes the body as a single binary on `conn.assigns[:raw_body]` for the
  # webhook paths; we hand it back as-is. Returns "" when nothing was stashed
  # (e.g. a request with no body) so HMAC verification sees a stable empty
  # string rather than nil.
  defp raw_request_body(conn), do: conn.assigns[:raw_body] || ""

  defp get_first_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [v | _] -> v
      _ -> nil
    end
  end

  ## Account & sessions helpers

  # The non-secret session shape for the active-sessions list. NEVER echoes the
  # token_hash; `current` is computed against the caller's hash so the UI can
  # badge "This device" and disable its own Revoke button.
  defp session_json(%Accounts.UserToken{} = t, current_hash) do
    %{
      id: t.id,
      ip_address: t.ip_address,
      user_agent: t.user_agent,
      # ALWAYS emitted, `null` when unknown — a present-and-null key lets the SPA
      # tell "this server does not know where the session came from" apart from
      # "this server is too old to have the field at all". Rows minted before the
      # `origin` column existed are exactly the first case, and nothing guesses
      # on their behalf.
      origin: t.origin,
      last_used_at: t.last_used_at,
      inserted_at: t.inserted_at,
      current: t.token_hash == current_hash
    }
  end

  # Device metadata for a freshly-minted session token: the caller's peer IP and
  # User-Agent. Captured at login / register / password-change re-mint so the
  # sessions list has something to show. Both nil-tolerant — a missing header or
  # peer just stores nil.
  defp session_opts(conn) do
    [ip_address: peer_ip(conn), user_agent: get_first_header(conn, "user-agent")]
  end

  # Render conn.remote_ip (an :inet address tuple) as a printable string, or nil
  # when absent. :inet.ntoa returns a charlist; to_string makes it a binary.
  defp peer_ip(conn) do
    case conn.remote_ip do
      nil -> nil
      ip -> ip |> :inet.ntoa() |> to_string()
    end
  end

  # The instance leg of DELETE /v1/barkparks/:id/app-token, once the body has
  # resolved to exactly ONE revoke mode. Every verdict the instance reaches
  # deliberately keeps its OWN status — its 422 (this token is an admin token,
  # unkillable here) is a 422 and its 429 (its per-IP revoke bucket) is a 429.
  # Only a transport failure, or a status this route does not model, is the 502
  # `instance_unreachable`: telling a phone "your instance is down" about an
  # answer the instance gave on purpose sends it into a pointless retry loop.
  # The caller's IP rides along as X-Forwarded-For so the instance buckets per
  # phone instead of per control plane (see Registry.revoke_app_token/3).
  defp revoke_app_token_on_instance(conn, team, bp, mode) do
    case Registry.revoke_app_token(bp, mode, client_ip: peer_ip(conn)) do
      {:ok, payload} ->
        audit_lifecycle_trigger(conn, team, bp.id, "barkpark.app_token_revoked", %{
          name: bp.name,
          mode: elem(mode, 0),
          revoked_count: payload["revoked_count"]
        })

        json(conn, 200, payload)

      {:error, :not_found} ->
        json(conn, 404, %{error: "not_found"})

      {:error, :not_live} ->
        json(conn, 409, %{error: "not_live"})

      {:error, :revoke_unsupported} ->
        json(conn, 409, %{error: "revoke_unsupported"})

      {:error, :revoke_refused} ->
        json(conn, 422, %{
          error: "revoke_refused",
          detail:
            "The instance refused to revoke that token: admin tokens cannot be " <>
              "revoked through the app-token path."
        })

      {:error, :instance_rate_limited} ->
        json(conn, 429, %{
          error: "instance_rate_limited",
          detail: "The instance's own revoke rate limit tripped. Retry in a minute."
        })

      {:error, :no_admin_token} ->
        json(conn, 404, %{
          error: "no_admin_token",
          detail:
            "No admin token is stored for this instance yet. It is captured at " <>
              "provision time — a pre-existing instance may need a re-provision."
        })

      {:error, :decrypt_failed} ->
        json(conn, 500, %{error: "decrypt_failed"})

      {:error, :instance_error} ->
        json(conn, 502, %{error: "instance_unreachable"})
    end
  end

  # Verify a GitHub X-Hub-Signature-256 header against `raw_body` using `secret`.
  # GitHub format: "sha256=<lowercase-hex of HMAC-SHA256(secret, raw_body)>".
  # Compare with Plug.Crypto.secure_compare/2 so the check is CONSTANT TIME —
  # a byte-by-byte mismatch must not leak timing info.
  defp verify_github_signature(_raw, _secret, nil), do: false
  defp verify_github_signature(_raw, _secret, ""), do: false

  defp verify_github_signature(raw_body, secret, "sha256=" <> hex) do
    computed_hex =
      :crypto.mac(:hmac, :sha256, secret, raw_body)
      |> Base.encode16(case: :lower)

    # Both strings must be the same length for secure_compare; if GitHub sent a
    # malformed header (wrong length) treat it as a mismatch up front.
    if byte_size(hex) == byte_size(computed_hex) do
      Plug.Crypto.secure_compare(String.downcase(hex), computed_hex)
    else
      false
    end
  end

  defp verify_github_signature(_raw, _secret, _other), do: false

  # The body of POST /v1/sites/:id/github/connect once auth + config + the
  # team-scoped site lookup have passed. Registers the push webhook on GitHub via
  # the seam, then persists the repo/branch/secret link. The webhook_url is the
  # site's own inbound endpoint, so the URL registered on GitHub === the URL the
  # inbound handler is mounted at, and the secret registered === the secret the
  # inbound handler verifies.
  defp connect_site_github(conn, team, site) do
    repo = conn.body_params["repo_full_name"]
    branch = conn.body_params["branch"]

    cond do
      not (is_binary(repo) and repo != "") ->
        json(conn, 422, %{error: "repo_full_name_required"})

      true ->
        secret = generate_webhook_secret()
        url = webhook_url_for(conn, site.id)

        case GitHub.register_site_webhook(team, repo, url, secret) do
          {:ok, _hook} ->
            case Registry.set_site_github(site, repo, branch, secret) do
              {:ok, updated} ->
                # activity-audit-log: same `site.github_connected` event as the
                # manual link route. This path already RELAYED to GitHub (the hook
                # is registered), so the audit is a post-commit best-effort
                # record_audit/1 — an audit-insert failure must not strand a live
                # GitHub webhook by rolling the local link back. Repo/branch only,
                # never the webhook secret.
                case Accounts.record_audit(%{
                       team_id: team.id,
                       actor_user_id: conn.assigns.current_user.id,
                       action: "site.github_connected",
                       target_type: "site",
                       target_id: site.id,
                       metadata: %{
                         site_id: site.id,
                         repo: updated.github_repo,
                         branch: updated.github_branch
                       }
                     }) do
                  {:ok, _event} ->
                    push_event(team.id, "audit")

                  {:error, cs} ->
                    Logger.error("audit site.github_connected failed: #{inspect(cs)}")
                end

                push_event(team.id, "sites")

                json(conn, 200, %{
                  site: site_json(updated),
                  webhook_url: url,
                  repo_full_name: updated.github_repo,
                  branch: updated.github_branch
                })

              {:error, cs} ->
                json(conn, 422, %{error: "invalid", details: errors(cs)})
            end

          {:error, :no_installation} ->
            json(conn, 409, %{error: "no_installation"})

          {:error, :repo_not_in_installation} ->
            json(conn, 422, %{error: "repo_not_in_installation"})

          {:error, _reason} ->
            json(conn, 502, %{error: "github_error"})
        end
    end
  end

  # The publish-instant recorder for the verified arm of the content-publish
  # receiver (deploy-reliability D162). Returns the row, or nil when the write did
  # not land — the CALLER MUST NOT CARE, and the 202 must not: a telemetry row that
  # can fail a delivery is worse than no row, because the box would then retry a
  # publish the control plane in fact accepted.
  #
  # Registry.ContentPublish.record/3 is itself total (it rescues), so this is a
  # `case` over values rather than a second try/rescue — one guard, in the module
  # that owns the write, is easier to reason about than two half-guards. It logs at
  # warning: the row going missing is a real hole in the fleet's only publish clock,
  # just not one worth failing a webhook over.
  #
  # `doc_type` is ECHOED from the delivery payload's `type` (the box's
  # Webhooks.Dispatcher.build_payload/6 shape) and is nil for any body that does not
  # carry a string there — an unparseable or type-less delivery records an unknown
  # doc type, never an invented one.
  defp record_content_publish(site, raw_body) do
    case Registry.ContentPublish.record(site.id, DateTime.utc_now(), %{
           doc_type: payload_doc_type(raw_body)
         }) do
      {:ok, publish} ->
        publish

      {:error, reason} ->
        Logger.warning(
          "content_publish record failed site=#{site.id} reason=#{inspect(reason)} " <>
            "(delivery still accepted)"
        )

        nil
    end
  end

  # An over-long `type` must cost the DOC TYPE, never the INSTANT. The changeset's
  # `validate_length(:doc_type, max: 255)` rejects the whole row, so a payload with
  # an absurd type would silently delete the one thing this table exists to record.
  # Refuse the field here instead: an unknown doc type reads as unknown (NULL),
  # which is the module's own doctrine, and the publish clock still gets its row.
  @doc_type_max 255

  defp payload_doc_type(raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"type" => type}} when is_binary(type) ->
        if String.length(type) <= @doc_type_max, do: type, else: nil

      _ ->
        nil
    end
  end

  defp payload_doc_type(_raw_body), do: nil

  # The verified-push branch of POST /v1/webhooks/github/:site_id. By this point
  # the HMAC has passed; we still 200 (not 4xx) on non-push events and ignored
  # pushes so GitHub stops retrying. A push to the connected branch creates a
  # PRODUCTION Deployment; a push to any OTHER branch (gh-6) creates a PREVIEW
  # deployment (unless the site has previews disabled); a branch DELETE tears the
  # preview down.
  defp handle_verified_github_push(conn, site) do
    event = get_first_header(conn, "x-github-event")
    body = conn.body_params

    cond do
      event == nil ->
        json(conn, 200, %{ok: true, ignored: true, reason: "missing_event_header"})

      event == "ping" ->
        # The "set up" hit GitHub fires when you save a webhook config. Always
        # 200 so the webhook config UI shows "Last delivery was successful".
        json(conn, 200, %{ok: true, pong: true})

      event != "push" ->
        json(conn, 200, %{ok: true, ignored: true, reason: "unsupported_event"})

      true ->
        ref = body["ref"]
        sha = body["after"] || (is_map(body["head_commit"]) and body["head_commit"]["id"]) || nil
        configured_branch = site.github_branch || "main"
        branch = branch_from_ref(ref)

        # dwb-18: GitHub's X-GitHub-Delivery is unique per redelivery-chain — the
        # DB-backstopped idempotency key for BOTH the production and the preview
        # (gh-6) deploy paths. A missing header leaves it nil — the partial
        # unique index ignores nulls, so pre-dwb-18 behavior is preserved.
        delivery_id = get_first_header(conn, "x-github-delivery")

        # A branch DELETE push carries deleted:true, head_commit:null, and an
        # `after` of 40 zeros — a truthy non-empty string that would otherwise
        # sail past the missing_sha guard.
        deleted? = body["deleted"] == true or sha == String.duplicate("0", 40)

        cond do
          not is_binary(ref) ->
            json(conn, 200, %{ok: true, ignored: true, reason: "missing_ref"})

          # Only refs/heads/* (branches) deploy. Tags and other refs are ignored.
          is_nil(branch) ->
            json(conn, 200, %{ok: true, ignored: true, reason: "non_branch_ref", pushed_ref: ref})

          # A production-branch DELETE is a no-op — it NEVER tears down the live
          # site (that would take prod down on a stray force-delete). 200 so
          # GitHub stops retrying; no Deployment.
          deleted? and branch == configured_branch ->
            json(conn, 200, %{ok: true, ignored: true, reason: "branch_deleted"})

          # gh-6: a NON-production branch DELETE tears down that branch's preview.
          deleted? ->
            torn = Registry.teardown_branch_previews(site, branch)
            if torn > 0, do: push_event(site.team_id, "deployments")

            json(conn, 200, %{
              ok: true,
              preview_torn_down: true,
              branch: branch,
              count: torn
            })

          not is_binary(sha) or sha == "" ->
            json(conn, 200, %{ok: true, ignored: true, reason: "missing_sha"})

          # Anything that isn't a 40-char hex object name is not a commit we can
          # build. 200 (not 4xx) so GitHub stops retrying a malformed payload.
          not (sha =~ ~r/^[0-9a-f]{40}$/i) ->
            json(conn, 200, %{ok: true, ignored: true, reason: "invalid_sha"})

          # Push to the connected branch → PRODUCTION deploy (unchanged).
          branch == configured_branch ->
            handle_production_push(conn, site, sha, branch, delivery_id)

          # gh-6: push to any other branch → PREVIEW, unless the site opted out.
          site.previews_enabled == false ->
            json(conn, 200, %{
              ok: true,
              ignored: true,
              reason: "previews_disabled",
              branch: branch
            })

          true ->
            handle_preview_push(conn, site, sha, branch, delivery_id)
        end
    end
  end

  # git-ref clone lane: the RAW machine reason stamped on the born-failed
  # fallback row when a push arrives for a site with NO linked repo. Human copy
  # is applied at the serialization boundary (FailureCopy.humanize / app.js
  # failureCopy) — this stays raw for logs+ops. The webhook route already 404s
  # sites without github config, so this is a flip-safe defensive fallback, not
  # a path a configured site ever takes.
  @github_push_build_reason "github push builds require the GitHub App integration (not yet available) — deploy an artifact via bp deploy"

  # git-ref clone lane: whether a source build for a GitHub push is available —
  # a REAL repo-present predicate. Repo visibility is not persisted, so
  # repo-present is the only honest gate: a push on a repo-backed site mints a
  # queued artifact-less row the builder claims, and the builder-claim envelope
  # (`builder_claim_source/1`) hands it the clone source; a private repo fails
  # at clone with a classified reason, which is honest. False only when no repo
  # is linked, where the born-failed fallback below keeps the delivery log true.
  defp github_build_available?(site), do: is_binary(site.github_repo)

  # A push to the connected branch → production Deployment. dwb-18: two dedup
  # gates BEFORE minting a row — (1) this exact X-GitHub-Delivery already
  # produced a Deployment (a redelivery of a push we handled, even one now live —
  # find_deployment_by_delivery_id is nil-safe on a missing/blank id), else
  # (2) an active build of this exact commit already exists. Both are DB-
  # backstopped by partial unique indexes; a lost race surfaces as a changeset
  # error that is recovered into a 200 duplicate below.
  #
  # git-ref clone lane: a push on a repo-backed site (`github_build_available?/1`)
  # mints a QUEUED artifact-less deployment (git_ref = the pushed sha) the
  # builder claims like any other row — the claim envelope carries the clone
  # source. The queued row is ACTIVE, so gate (2) above dedups a same-sha
  # redelivery against it. A push we CAN'T build from source (no linked repo —
  # defensive; the webhook route 404s such sites) is recorded as a born-`failed`
  # deployment (Registry.create_failed_deployment/3) instead of a source-less
  # `queued` zombie the builder never claims; its honest 201 body carries the
  # terminal status + humanized reason so the GitHub delivery log tells the
  # truth, and `find_active_deployment` ignores the failed row so a later REAL
  # `bp deploy` at the same sha is unblocked.
  defp handle_production_push(conn, site, sha, branch, delivery_id) do
    existing =
      Registry.find_deployment_by_delivery_id(delivery_id) ||
        Registry.find_active_deployment(site.id, sha)

    case existing do
      %{} = dep ->
        json(conn, 200, %{
          ok: true,
          ignored: true,
          reason: "duplicate_delivery",
          deployment_id: dep.id
        })

      nil ->
        # The artifact_url is left empty — the builder clones the repo at
        # git_ref via the claim-envelope source instead of pulling an artifact.
        attrs = %{git_ref: sha, artifact_url: nil, delivery_id: delivery_id}

        result =
          if github_build_available?(site) do
            Registry.create_deployment(site, attrs)
          else
            Registry.create_failed_deployment(site, attrs, @github_push_build_reason)
          end

        case result do
          {:ok, deployment} ->
            push_event(site.team_id, "deployments")

            json(conn, 201, %{
              ok: true,
              deployment_id: deployment.id,
              sha: sha,
              branch: branch,
              environment: "production",
              status: deployment.status,
              reason: FailureCopy.humanize(deployment.failure_reason)
            })

          {:error, %Ecto.Changeset{errors: errs} = cs} ->
            # A lost race: between the dedup lookups above and this INSERT a
            # concurrent redelivery inserted the winner, and a DB partial unique
            # index (delivery_id or the active site+ref index) rejected ours.
            # Re-fetch the winner and 200 it as a duplicate rather than
            # surfacing the constraint error.
            winner =
              if Keyword.has_key?(errs, :delivery_id) or Keyword.has_key?(errs, :git_ref) do
                Registry.find_deployment_by_delivery_id(delivery_id) ||
                  Registry.find_active_deployment(site.id, sha)
              end

            case winner do
              %{} = dep ->
                json(conn, 200, %{
                  ok: true,
                  ignored: true,
                  reason: "duplicate_delivery",
                  deployment_id: dep.id
                })

              nil ->
                json(conn, 422, %{error: "invalid", details: errors(cs)})
            end
        end
    end
  end

  # gh-6: a push to a NON-production branch → PREVIEW deployment on its own host.
  # Mirrors handle_production_push's dwb-18 idempotency exactly: gate (1) is the
  # same X-GitHub-Delivery lookup (globally unique — a redelivered preview push
  # points back at its row even after it went live/cancelled); gate (2) is the
  # preview twin — an active preview of this branch at this sha. The create path
  # replaces this branch's prior preview + enforces the per-site cap, and is DB-
  # backstopped by the partial unique (site, branch) active-preview index; a lost
  # race (two concurrent pushes to one branch) is recovered into a 200 duplicate
  # pointing at the winner.
  defp handle_preview_push(conn, site, sha, branch, delivery_id) do
    existing =
      Registry.find_deployment_by_delivery_id(delivery_id) ||
        Registry.find_active_preview(site.id, branch, sha)

    case existing do
      %{} = dep ->
        json(conn, 200, %{
          ok: true,
          ignored: true,
          reason: "duplicate_delivery",
          deployment_id: dep.id,
          environment: "preview"
        })

      nil ->
        case Registry.create_preview_deployment(site, branch, sha, delivery_id) do
          {:ok, deployment} ->
            push_event(site.team_id, "deployments")

            json(conn, 201, %{
              ok: true,
              deployment_id: deployment.id,
              sha: sha,
              branch: branch,
              environment: "preview",
              preview_host: deployment.preview_host,
              preview_url: "https://" <> deployment.preview_host
            })

          {:error, %Ecto.Changeset{errors: errs} = cs} ->
            winner =
              if Keyword.has_key?(errs, :delivery_id) or Keyword.has_key?(errs, :branch) do
                Registry.find_deployment_by_delivery_id(delivery_id) ||
                  Registry.find_active_preview_for_branch(site.id, branch)
              end

            case winner do
              %{} = dep ->
                json(conn, 200, %{
                  ok: true,
                  ignored: true,
                  reason: "duplicate_delivery",
                  deployment_id: dep.id,
                  environment: "preview"
                })

              nil ->
                json(conn, 422, %{error: "invalid", details: errors(cs)})
            end
        end
    end
  end

  # Extract the branch name from a push `ref`. Only `refs/heads/<branch>` yields a
  # branch; tags (`refs/tags/*`) and any other ref shape return nil.
  defp branch_from_ref("refs/heads/" <> branch) when branch != "", do: branch
  defp branch_from_ref(_), do: nil

  # Build the user-facing webhook URL the user pastes into GitHub's "Payload
  # URL" field. The scheme + host come from the request so dev (http://...)
  # and prod (https://api.barkpark.cloud) both land on a working URL without
  # threading config through.
  defp webhook_url_for(conn, site_id) do
    scheme = conn.scheme |> to_string()
    host = conn.host

    port_part = https_safe_port_part(scheme, conn.port)

    "#{scheme}://#{host}#{port_part}/v1/webhooks/github/#{site_id}"
  end

  # The browser approve page for a device-authorization login (bp-login-ux). The
  # approve page is an SPA view on the DASHBOARD host (barkpark.cloud), where the
  # user already holds their authed session — so when the request arrives on the
  # dashboard host or a subdomain of it (prod: api.barkpark.cloud → barkpark.cloud),
  # we box the canonical dashboard origin and the user lands already-signed-in
  # rather than through a second login. Any OTHER host (local dev: localhost:4100,
  # a test host) keeps the request-host construction — :dashboard_url is
  # barkpark.cloud in EVERY env, so an unconditional swap would point a localhost
  # CLI at barkpark.cloud (a different DB) and break local device login.
  defp activate_url(conn) do
    dashboard_base = dashboard_base_url()

    if within_dashboard_host?(conn.host, URI.parse(dashboard_base).host) do
      dashboard_base <> "/activate"
    else
      scheme = conn.scheme |> to_string()
      host = conn.host
      port_part = https_safe_port_part(scheme, conn.port)

      "#{scheme}://#{host}#{port_part}/activate"
    end
  end

  # True when the request host IS the dashboard host or a subdomain of it
  # (api.barkpark.cloud is within barkpark.cloud). Only then do we canonicalize
  # onto the dashboard origin.
  defp within_dashboard_host?(request_host, dashboard_host)
       when is_binary(request_host) and is_binary(dashboard_host) do
    request_host == dashboard_host or String.ends_with?(request_host, "." <> dashboard_host)
  end

  defp within_dashboard_host?(_request_host, _dashboard_host), do: false

  # The port segment for a user-facing URL, shared by accept_url/reset_url/
  # webhook_url_for. HTTPS ALWAYS omits the port: the app never terminates TLS
  # itself, so an https request always came through the Caddy 443 front — never
  # the raw :4100/:4101 listener (Plug.RewriteOn hands us the external scheme but
  # keeps the loopback port, which we must not leak). HTTP keeps the port unless
  # it's the default :80 (so dev http://localhost:4100 links stay clickable).
  defp https_safe_port_part("https", _port), do: ""
  defp https_safe_port_part("http", 80), do: ""
  defp https_safe_port_part(_scheme, port), do: ":" <> Integer.to_string(port)

  # Generate a fresh webhook secret — 32 cryptographic random bytes,
  # url-safe-Base64 encoded (no padding) so it pastes cleanly into GitHub's
  # secret field.
  defp generate_webhook_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  ## Artifact upload helpers (site-spawner W9, charter D91)

  # The prebuilt upload cap. A build OUTPUT, not a project dir: 12-16 KB for an
  # Astro `dist/`, ~18 MB for a Next standalone — against the 137-148 MB of
  # node_modules the box no longer has to install. 32 MB leaves real headroom
  # and still bounds one row on `cloud_pgdata`.
  #
  # Overridable through the same `config :barkpark_cloud, BarkparkCloud.Web.Router`
  # key the test env already sets, so the too-large test ships kilobytes instead
  # of megabytes. The `artifact_dir` half of that config is GONE — see the
  # upload route for why the file:// plane never worked.
  @max_artifact_bytes 32 * 1024 * 1024

  defp max_artifact_bytes do
    :barkpark_cloud
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_artifact_bytes, @max_artifact_bytes)
  end

  defp sha256_hex(bytes) when is_binary(bytes),
    do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # The client's declared digest, downcased, or nil when it sent none. A blank or
  # malformed header reads as ABSENT rather than as a mismatch: this check exists
  # to catch corrupted BYTES, and refusing a well-formed upload over a badly
  # formed header would only turn a client bug into a deploy outage.
  defp declared_artifact_digest(conn) do
    case Plug.Conn.get_req_header(conn, "x-artifact-sha256") do
      [value | _] ->
        value = value |> String.trim() |> String.downcase()
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: value, else: nil

      [] ->
        nil
    end
  end

  # The upload half of mint-then-upload. Runs INSIDE `with_team_site`, so the
  # site is already team-scoped and the caller already carries write ability.
  defp upload_deployment_artifact(conn, site, deployment) do
    cond do
      not Registry.Deployment.prebuilt?(deployment) ->
        json(conn, 422, %{
          error: "not_prebuilt",
          detail:
            "this deployment builds on its box — mint a prebuilt one with POST /v1/sites/#{site.id}/deploy {\"source\":\"prebuilt\"}"
        })

      deployment.status != "queued" ->
        json(conn, 409, %{
          error: "deployment_not_queued",
          detail:
            "this deployment is already #{deployment.status} — mint a new prebuilt deployment for a new artifact"
        })

      true ->
        receive_deployment_artifact(conn, site, deployment)
    end
  end

  defp receive_deployment_artifact(conn, site, deployment) do
    case read_artifact_body(conn, max_artifact_bytes()) do
      {:ok, conn, ""} ->
        json(conn, 422, %{
          error: "empty_artifact",
          detail:
            "the request body was empty — POST the tar.gz of dist/ as application/octet-stream"
        })

      {:ok, conn, bytes} ->
        # The client declares the digest it computed over exactly the bytes it
        # put on the wire (`X-Artifact-Sha256`). Comparing it here is what makes
        # that header load-bearing rather than decorative: without it a body
        # corrupted or altered between the client and the control plane would be
        # stored, hashed by US, and re-verified by the box against OUR hash —
        # i.e. every downstream check would agree on the wrong bytes. Optional,
        # because an older client sends no header and nothing about this route
        # requires one.
        sha = sha256_hex(bytes)

        case declared_artifact_digest(conn) do
          declared when declared in [nil, sha] ->
            settle_deployment_artifact(conn, site, deployment, bytes, sha)

          declared ->
            json(conn, 422, %{
              error: "artifact_digest_mismatch",
              detail:
                "the body hashes to #{sha}, but X-Artifact-Sha256 declared #{declared} — the upload was altered in transit; retry it"
            })
        end

      {:error, :too_large, conn} ->
        json(conn, 413, %{error: "artifact_too_large", max_bytes: max_artifact_bytes()})

      {:error, reason, conn} ->
        Logger.error("site upload_failed (artifact read_body): #{inspect(reason)}")
        json(conn, 500, %{error: "upload_failed", reason: transport_reason(reason)})
    end
  end

  defp settle_deployment_artifact(conn, site, deployment, bytes, sha) do
    case Sites.Deploy.artifact_for(deployment.id) do
      # A client retry after a dropped response. Answer the same success WITHOUT
      # re-starting the driver: the deploy is already in flight.
      %{sha256: ^sha} ->
        json(conn, 200, %{
          deployment: site_deployment_json(deployment, site, nil),
          artifact_sha256: sha,
          bytes: byte_size(bytes),
          status: "already_uploaded"
        })

      %{sha256: other} ->
        json(conn, 409, %{
          error: "artifact_conflict",
          detail:
            "this deployment already carries a different artifact (#{other}) — mint a new prebuilt deployment for new bytes"
        })

      nil ->
        start_prebuilt_deploy(conn, site, deployment, bytes, sha)
    end
  end

  defp start_prebuilt_deploy(conn, site, deployment, bytes, sha) do
    case Sites.Deploy.store_artifact(deployment, bytes, sha) do
      {:ok, stamped} ->
        case Accounts.record_audit(%{
               team_id: site.team_id,
               actor_user_id: conn.assigns.current_user.id,
               action: "site.artifact_uploaded",
               target_type: "deployment",
               target_id: deployment.id,
               metadata: %{site_id: site.id, sha256: sha, bytes: byte_size(bytes)}
             }) do
          {:ok, _event} -> :ok
          {:error, cs} -> Logger.error("audit site.artifact_uploaded failed: #{inspect(cs)}")
        end

        # ONLY NOW. The digest is committed, so the row can already name the
        # bytes it is about to serve; a driver started before this could reach
        # the box with a deployment the control plane could not describe.
        #
        # And the 201 below is DOWNSTREAM of this call — no byte of this
        # request's response has been sent (the earlier 201 the caller saw
        # belonged to the MINT request, a different exchange), so a refused spawn
        # is answerable. It used to be `:ok = Sites.Deploy.start(stamped)`, a
        # match that could not fail: the artifact landed, nothing built, and the
        # uploader was told `201`.
        #
        # The console is told BEFORE the start is attempted, for the same reason
        # as the box-build arm above: the artifact is stored and the row is
        # stamped, so the console must learn about the row whether or not a
        # build follows it.
        push_event(site.team_id, "deployments")
        push_event(site.team_id, "audit")
        bp = Registry.get_barkpark(site.barkpark_id)

        case Sites.Deploy.start_reported(stamped) do
          {:ok, _outcome} ->
            json(conn, 201, %{
              deployment: site_deployment_json(stamped, site, bp),
              artifact_sha256: sha,
              bytes: byte_size(bytes)
            })

          {:error, reason} ->
            # THE RETRY INSTRUCTION IS "MINT A NEW DEPLOYMENT", NOT "RE-POST".
            # The bytes ARE stored, so `settle_deployment_artifact/5` above
            # answers a same-sha re-POST `200 already_uploaded` and explicitly
            # does NOT re-start the driver — telling the caller to retry the
            # upload would send them into a 200 that builds nothing, which is the
            # same lie in a new costume. THIS row is now a dead end: `queued`,
            # `claim_epoch` 0, covered by no reaper pass.
            Logger.error("site deploy_not_started (prebuilt upload): #{inspect(reason)}")

            json(conn, 503, %{
              error: "deploy_not_started",
              detail:
                "the artifact was stored but the build driver could not be started" <>
                  " — nothing is building, and re-uploading these bytes will answer" <>
                  " `already_uploaded` without starting one. Mint a NEW prebuilt deployment" <>
                  " and upload again.",
              reason: transport_reason(reason),
              artifact_sha256: sha,
              deployment: site_deployment_json(stamped, site, bp)
            })
        end

      {:error, cs} ->
        json(conn, 422, %{error: "invalid", details: errors(cs)})
    end
  end

  # The prebuilt 201 tells the caller what to do NEXT — the verb is otherwise
  # discoverable only by reading source, which is how this whole gap survived.
  defp maybe_put_upload_instruction(body, false, _site, _deployment), do: body

  defp maybe_put_upload_instruction(body, true, site, deployment) do
    Map.put(body, :upload, %{
      method: "POST",
      path: "/v1/sites/#{site.id}/deployments/#{deployment.id}/artifact",
      content_type: "application/octet-stream",
      max_bytes: max_artifact_bytes(),
      detail:
        "build with BARKPARK_BUILD_ID=#{deployment.build_id}, then upload the tar.gz of dist/ — the deploy starts on upload"
    })
  end

  # Reads the whole request body into memory, abandoning early when `max_bytes`
  # is exceeded. Returns `{:ok, conn, bytes}`, `{:error, :too_large, conn}`, or
  # `{:error, reason, conn}`.
  #
  # In memory rather than to a temp file because the bytes are bound for a
  # Postgres column and a base64 field on the box payload — a spool file would
  # be a third copy with nothing to gain. The cap is what bounds it.
  defp read_artifact_body(conn, max_bytes), do: read_artifact_body(conn, max_bytes, [], 0)

  defp read_artifact_body(conn, max_bytes, acc, read) do
    # 8 MiB window: large enough that the per-call overhead is amortized against
    # the cap, small enough that a refused upload stops early.
    case Plug.Conn.read_body(conn, length: 8 * 1024 * 1024, read_length: 1024 * 1024) do
      {:ok, chunk, conn} ->
        total = read + byte_size(chunk)

        if total > max_bytes do
          {:error, :too_large, conn}
        else
          {:ok, conn, IO.iodata_to_binary(Enum.reverse([chunk | acc]))}
        end

      {:more, chunk, conn} ->
        total = read + byte_size(chunk)

        if total > max_bytes do
          {:error, :too_large, conn}
        else
          read_artifact_body(conn, max_bytes, [chunk | acc], total)
        end

      {:error, reason} ->
        {:error, {:read, reason}, conn}
    end
  end
end
