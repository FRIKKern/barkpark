defmodule BarkparkCloud.Web.Router do
  @moduledoc """
  The control-plane HTTP API (cloud-12a) — a minimal JSON `Plug.Router` over the
  Accounts / Registry / Billing contexts. Deliberately NOT Phoenix/LiveView: this
  is the callable JSON surface the agent (cloud-10) POSTs to, the Go CLI client
  (cloud-12b) calls, and the live dashboard (served by this app, SSE-pushed via
  `GET /v1/events`) consumes.

  ## Route table

      METHOD  PATH                 AUTH      PURPOSE
      POST    /v1/auth/login       —         email+password → {token, team_id}
      GET     /v1/me               user      {user{id,email}, team{id,name,slug}}
      GET     /v1/subscription     user      {subscription | nil} — current plan
      GET     /v1/events           user*     Server-Sent-Events live stream (*token= or Bearer)
      POST    /v1/agent/report     agent     land a health report (health + events)
      GET     /v1/agent/commands   agent     approved-command queue (empty for now)
      POST    /v1/agent/results    agent     ack command results
      GET     /v1/barkparks        user      the team's registered Barkparks (+provision_status)
      DELETE  /v1/barkparks/:id    user      remove an instance (deregister; live box → 409)
      POST    /v1/barkparks/:id/retry user   re-enqueue a FAILED provision
      GET     /v1/providers        user      the team's connected cloud providers
      POST    /v1/providers        user      connect a cloud provider
      POST    /v1/billing/checkout user      open a hosted Checkout Session → {checkout_url}
      POST    /v1/billing/webhook  —*        Stripe events (signature-verified, raw body)
      POST    /v1/launch           user      go-live (alias of /v1/go-live)
      POST    /v1/go-live          user      gate on active subscription + create a provisioning Barkpark
      POST    /v1/internal/provision-jobs/claim       worker  claim oldest pending job
      POST    /v1/internal/provision-jobs/:id/succeed worker  flip barkpark up at {ip}
      POST    /v1/internal/provision-jobs/:id/fail    worker  mark job failed {error}
      POST    /v1/sites            user      create a hosted Site under a Barkpark
      GET     /v1/sites            user      list the team's sites (across all boxes)
      GET     /v1/sites/:id        user      one site
      POST    /v1/sites/:id/deploy user      enqueue a Deployment (the build job)
      GET     /v1/sites/:id/deployments user list a site's deployments, newest first
      POST    /v1/sites/:id/artifact user    upload tarball (octet-stream) → file:// URL
      POST    /v1/sites/:id/env    user      replace the encrypted env blob
      POST    /v1/sites/:id/domains user     add a domain to a site
      POST    /v1/sites/:id/github  user     link a GitHub repo + branch + webhook secret
      POST    /v1/webhooks/github/:site_id —  GitHub push → enqueue Deployment (HMAC)
      GET     /v1/tls/ask          —         on-demand-TLS gate (200/404 by domain)
      POST    /v1/builder/claim    user      atomic next-queued deployment claim
      POST    /v1/builder/deployments/:id/transition user fenced status update
      GET     /v1/agent/pending    agent     deployments in pushing for this box
      POST    /v1/agent/deployments/claim agent atomic pickup of the next pushing
      POST    /v1/agent/deployments/:id/transition agent fenced live transition
      *       (anything else)      —         404 JSON

  Every response is JSON. Errors are `{"error": "<reason>"}`. The agent routes
  authenticate with an AGENT token (`Registry.verify_agent_token`); the user
  routes with a USER session token (`Accounts.verify_user_session_token`); the
  internal `/v1/internal/*` routes with the shared WORKER token (`require_worker`
  — Bearer WORKER_TOKEN, never a user/agent token) — all via
  `BarkparkCloud.Web.Auth`.
  """
  use Plug.Router
  require Logger

  alias BarkparkCloud.{Accounts, Billing, Events, Registry, Repo}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Auth

  # The dashboard SPA (plain HTML+CSS+JS, no build step) is served straight from
  # priv/static. This runs BEFORE :match so a real asset short-circuits the
  # router; `only:` is an explicit allowlist that DELIBERATELY excludes "v1" so
  # the JSON API can never be shadowed by a same-named file — every /v1/* request
  # falls through to the matchers below. A missing asset (e.g. no favicon.ico)
  # just falls through too. priv/ ships in the OTP release by default, so
  # `from: :barkpark_cloud` resolves the same in dev and prod.
  plug(Plug.Static,
    at: "/",
    from: :barkpark_cloud,
    only: ~w(index.html app.css app.js favicon.ico)
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
  @raw_body_path_prefixes ["/v1/webhooks/github/"]

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

  ## Auth — POST /v1/auth/login {email, password} → 200 {token, team_id} | 401

  post "/v1/auth/login" do
    email = conn.body_params["email"]
    password = conn.body_params["password"]

    with true <- is_binary(email) and is_binary(password),
         %{} = user <- Accounts.get_user_by_email_and_password(email, password),
         {:ok, token} <- Accounts.create_user_session_token(user) do
      team = Accounts.primary_team(user)
      json(conn, 200, %{token: token, team_id: team && team.id})
    else
      _ -> json(conn, 401, %{error: "invalid_credentials"})
    end
  end

  ## Auth — POST /v1/auth/register {email, password, team_name?}
  ##   → 201 {token, team_id} (user created + a team + an owner membership + a
  ##     session token; the caller is logged in immediately, exactly like login)
  ##   → 409 {error: "email_taken"}              (email already registered)
  ##   → 422 {error: "<field>_invalid"|..., details?}  (changeset rejection)
  ##
  ## The whole user→team→membership→token chain runs inside ONE Repo.transaction
  ## (`register/3` below), so a half-way failure rolls back — no orphan user or
  ## team is ever left behind. The duplicate-email check runs BEFORE the insert,
  ## and the citext unique index is the race backstop (a unique-violation on the
  ## email maps to 409, never a 500). YAGNI: no email verification, no captcha,
  ## no rate-limiter — rate-limiting this unauthenticated endpoint is a deploy
  ## concern (a fronting proxy / WAF rule), not application logic.
  post "/v1/auth/register" do
    email = conn.body_params["email"]
    password = conn.body_params["password"]
    team_name = conn.body_params["team_name"]

    with true <- is_binary(email) and is_binary(password),
         nil <- Accounts.get_user_by_email(email) do
      case register(email, password, team_name) do
        {:ok, %{token: token, team: team}} ->
          json(conn, 201, %{token: token, team_id: team.id})

        {:error, :email_taken} ->
          json(conn, 409, %{error: "email_taken"})

        {:error, %Ecto.Changeset{} = changeset} ->
          json(conn, 422, register_error(changeset))
      end
    else
      false -> json(conn, 422, %{error: "validation_failed"})
      %{} -> json(conn, 409, %{error: "email_taken"})
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

      _ =
        Registry.upsert_health(barkpark, %{
          health_status: normalize_health(report["health_status"]),
          agent_status: normalize_agent(report["agent_status"]),
          version: report["version"],
          git_commit: report["git_commit"],
          last_seen_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
        })

      # The agent's per-cycle signals become one append-only event. The full
      # report rides in the payload so the dashboard/event stream can show disk,
      # PG size, backup, dirty-tree, and the granular health checks.
      _ = Registry.record_event(barkpark, "health", report)

      # Push "fleet" so a live health change (up/down, version, agent online)
      # reflects on the dashboard without a manual refresh.
      push_event(barkpark.team_id, "fleet")

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
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      user = conn.assigns.current_user
      team = conn.assigns.current_team

      json(conn, 200, %{
        user: %{id: user.id, email: user.email},
        team: team && %{id: team.id, name: team.name, slug: team.slug}
      })
    end
  end

  # GET /v1/subscription → 200 {subscription: {plan, status, started_at} | nil}.
  # The Billing view reads this to show the REAL current plan (and gate the
  # already-subscribed state) instead of hardcoding "Free = current plan". A
  # team with no active subscription gets {subscription: nil}.
  get "/v1/subscription" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, %{subscription: nil})

      true ->
        case Billing.active_subscription(conn.assigns.current_team) do
          nil -> json(conn, 200, %{subscription: nil})
          sub -> json(conn, 200, %{subscription: subscription_json(sub)})
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
  # `?token=<session-token>` (a query param, because the browser EventSource API
  # CANNOT set an Authorization header) OR a normal Bearer header for non-browser
  # clients. On success the request process subscribes to its team's :pg group
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

  # GET /v1/barkparks → 200 {barkparks: [...]} for the user's team. Each row
  # carries the LATEST provision job's status/error (merged from a single batch
  # query) so the dashboard can show a FAILED launch distinctly from one still
  # provisioning — a failed job leaves the barkpark health "unknown"/host nil,
  # otherwise indistinguishable from in-progress.
  get "/v1/barkparks" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      barkparks =
        case conn.assigns.current_team do
          nil -> []
          team -> Registry.list_barkparks(team)
        end

      ids = Enum.map(barkparks, & &1.id)
      pmap = Registry.latest_provision_status_map(ids)
      dmap = Registry.latest_deprovision_status_map(ids)

      json(conn, 200, %{
        barkparks: Enum.map(barkparks, &barkpark_json(&1, pmap[&1.id], dmap[&1.id]))
      })
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
  delete "/v1/barkparks/:id" do
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
            if is_binary(bp.host) and bp.host != "" do
              deprovision_live_barkpark(conn, team, bp)
            else
              case Registry.delete_barkpark(bp) do
                {:ok, _} ->
                  push_event(team.id, "fleet")
                  json(conn, 200, %{ok: true, status: "removed"})

                {:error, cs} ->
                  json(conn, 422, %{error: "invalid", details: errors(cs)})
              end
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/barkparks/:id/retry → 201 {job} — re-enqueue provisioning for an
  # instance whose LAST provision attempt FAILED. Gated on a failed latest job so
  # a retry can never open a second concurrent provision (and a second billed
  # box) while one is pending/claimed/succeeded → 409 conflict in that case.
  post "/v1/barkparks/:id/retry" do
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
            case Registry.latest_provision_job(bp) do
              %{status: "failed"} ->
                case Registry.enqueue_provision_job(bp) do
                  {:ok, _job} ->
                    push_event(team.id, "fleet")
                    json(conn, 201, %{ok: true})

                  {:error, cs} ->
                    json(conn, 422, %{error: "invalid", details: errors(cs)})
                end

              _ ->
                json(conn, 409, %{error: "not_retryable"})
            end

          _ ->
            json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/providers {kind, token, label?} → 201 {provider: ...}. The plaintext
  # token is encrypted at rest by connect_provider — it is NEVER echoed back.
  post "/v1/providers" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        kind = conn.body_params["kind"]
        token = conn.body_params["token"]
        label = conn.body_params["label"]

        case Registry.connect_provider(conn.assigns.current_team, kind, token || "", label: label) do
          {:ok, provider} -> json(conn, 201, %{provider: provider_json(provider)})
          {:error, changeset} -> json(conn, 422, %{error: "invalid", details: errors(changeset)})
        end
    end
  end

  # POST /v1/billing/checkout {plan} → 200 {checkout_url} — open a hosted
  # Checkout Session for the AUTHED user's team on `plan` (the customer opens the
  # url in a browser to pay). team_id is the authed team, NEVER client-supplied.
  # 422 {error: "plan_invalid"} for an unknown plan or "free" (free needs no
  # checkout). 422 {error: "no_team"} when the user has no team to bill.
  post "/v1/billing/checkout" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      true ->
        plan = conn.body_params["plan"]

        case Billing.checkout(conn.assigns.current_team, to_string(plan)) do
          {:ok, checkout_url} ->
            json(conn, 200, %{checkout_url: checkout_url})

          {:error, :plan_invalid} ->
            json(conn, 422, %{error: "plan_invalid"})

          {:error, reason} ->
            json(conn, 422, %{error: "checkout_failed", reason: inspect(reason)})
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
          %BarkparkCloud.Billing.Subscription{team_id: tid} ->
            push_event(tid, "subscription")
            push_event(tid, "fleet")

          _ ->
            :ok
        end

        json(conn, 200, %{ok: true})

      {:error, :invalid_signature} ->
        json(conn, 400, %{error: "invalid_signature"})

      {:error, reason} ->
        json(conn, 400, %{error: "invalid_webhook", reason: inspect(reason)})
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
        case Registry.succeed_job(conn.path_params["id"], conn.body_params["ip"]) do
          {:ok, job} ->
            # The box just went live — push "fleet" so the dashboard flips it
            # from "provisioning" to up without a manual refresh.
            broadcast_barkpark_team(job.barkpark_id, "fleet")
            json(conn, 200, %{ok: true})

          {:error, :not_found} ->
            json(conn, 404, %{error: "not_found"})

          {:error, :conflict} ->
            json(conn, 409, %{error: "conflict"})

          {:error, _} ->
            json(conn, 422, %{error: "invalid"})
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

      case Registry.succeed_deprovision_job(conn.path_params["id"]) do
        {:ok, _} ->
          push_event(team_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

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
             if(is_binary(reason), do: reason, else: "unspecified")
           ) do
        {:ok, job} ->
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  ## Sites — hosted websites running co-located with a Barkpark.

  # POST /v1/sites {barkpark_id, name, framework?, domains?, scale_mode?} → 201
  # {site}. The site inherits its team_id from the Barkpark — the caller doesn't
  # (and can't) pick a different team.
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

        with true <- is_binary(bp_id),
             %Registry.Barkpark{team_id: tid} = bp when tid == team.id <-
               Registry.get_barkpark(bp_id),
             true <- is_binary(name) and name != "",
             slug <- conn.body_params["slug"] || slugify(name),
             attrs <- %{
               name: name,
               slug: slug,
               framework: conn.body_params["framework"] || "nextjs",
               domains: conn.body_params["domains"] || [],
               scale_mode: conn.body_params["scale_mode"] || "always_on"
             },
             {:ok, site} <- Registry.create_site(bp, attrs) do
          # Push "sites" so an open sites list / instance detail (including other
          # browser tabs) picks up the new site without a manual refresh.
          push_event(site.team_id, "sites")
          json(conn, 201, %{site: site_json(site)})
        else
          nil ->
            json(conn, 404, %{error: "barkpark_not_found"})

          %Registry.Barkpark{} ->
            # Existed but wrong team — same 404 as "not found" to avoid an
            # existence leak across team boundaries.
            json(conn, 404, %{error: "barkpark_not_found"})

          false ->
            json(conn, 422, %{error: "name_required"})

          {:error, %Ecto.Changeset{} = cs} ->
            json(conn, 422, %{error: "invalid", details: errors(cs)})
        end
    end
  end

  # GET /v1/sites → 200 {sites: [...]} for the user's team.
  get "/v1/sites" do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 200, %{sites: []})

      true ->
        sites = Registry.list_sites_for_team(conn.assigns.current_team)
        json(conn, 200, %{sites: Enum.map(sites, &site_json/1)})
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
          %Registry.Site{} = site -> json(conn, 200, %{site: site_json(site)})
          nil -> json(conn, 404, %{error: "not_found"})
        end
    end
  end

  # POST /v1/sites/:id/deploy {git_ref?, artifact_url?} → 201 {deployment}.
  # Enqueues a Deployment with status:"queued"; the off-box builder (P2) polls
  # for queued rows and walks them through building → pushing → live.
  post "/v1/sites/:id/deploy" do
    with_team_site(conn, fn site ->
      attrs = %{
        git_ref: conn.body_params["git_ref"],
        artifact_url: conn.body_params["artifact_url"]
      }

      case Registry.create_deployment(site, attrs) do
        {:ok, deployment} ->
          push_event(site.team_id, "deployments")
          json(conn, 201, %{deployment: deployment_json(deployment)})

        {:error, cs} ->
          json(conn, 422, %{error: "invalid", details: errors(cs)})
      end
    end)
  end

  # GET /v1/sites/:id/deployments → 200 {deployments: [...]} newest first.
  get "/v1/sites/:id/deployments" do
    with_team_site(conn, fn site ->
      deployments = Registry.list_deployments(site)
      json(conn, 200, %{deployments: Enum.map(deployments, &deployment_json/1)})
    end)
  end

  # POST /v1/sites/:id/artifact (application/octet-stream body) → 201
  # {artifact_url}. The CLI's `bp deploy` streams a tar.gz of the project dir
  # here; the control plane writes it to a configured artifact dir and returns
  # a `file://` URL the builder can read. This is the MVP of off-box artifact
  # storage — no S3, no signed URLs, just a host-local path the builder
  # process shares with the control plane.
  #
  # Size cap: 100 MB by default (configurable via :max_artifact_bytes). A
  # larger payload is refused with 413 and the partial file is removed.
  #
  # Ownership: a site in another team returns 404 (existence-leak protection),
  # same shape as a nonexistent id — never 403.
  post "/v1/sites/:id/artifact" do
    with_team_site(conn, fn site ->
      cfg = artifact_config()
      max = cfg[:max_artifact_bytes]
      dir = cfg[:artifact_dir]
      :ok = File.mkdir_p!(dir)

      filename = artifact_filename(site.slug)
      path = Path.join(dir, filename)

      case stream_body_to_file(conn, path, max) do
        {:ok, conn, bytes} ->
          url = "file://" <> path

          json(conn, 201, %{
            artifact_url: url,
            bytes: bytes,
            filename: filename
          })

        {:error, :too_large, conn} ->
          _ = File.rm(path)
          json(conn, 413, %{error: "artifact_too_large", max_bytes: max})

        {:error, reason, conn} ->
          _ = File.rm(path)
          json(conn, 500, %{error: "upload_failed", reason: inspect(reason)})
      end
    end)
  end

  # POST /v1/sites/:id/env {env: {...}} → 200 {ok: true}. Replaces the whole
  # encrypted env blob (Vault.encrypt-stored, never echoed back).
  post "/v1/sites/:id/env" do
    with_team_site(conn, fn site ->
      env = conn.body_params["env"]

      cond do
        not is_map(env) ->
          json(conn, 422, %{error: "env_required"})

        true ->
          case Registry.set_site_env(site, env) do
            {:ok, _} -> json(conn, 200, %{ok: true})
            {:error, cs} -> json(conn, 422, %{error: "invalid", details: errors(cs)})
          end
      end
    end)
  end

  # POST /v1/sites/:id/domains {domain} → 200 {site}. Adds the domain to the
  # site's array; the domain becomes acceptable to the on-demand-TLS ask-gate.
  post "/v1/sites/:id/domains" do
    with_team_site(conn, fn site ->
      domain = conn.body_params["domain"]

      cond do
        not is_binary(domain) or domain == "" ->
          json(conn, 422, %{error: "domain_required"})

        true ->
          case Registry.add_site_domain(site, domain) do
            {:ok, site} -> json(conn, 200, %{site: site_json(site)})
            {:error, cs} -> json(conn, 422, %{error: "invalid", details: errors(cs)})
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
  # "main" on the server. `webhook_secret` is the value the user will paste
  # into GitHub's webhook "Secret" field — when omitted, the server generates a
  # cryptographically random one and returns it ONCE in this response (it is
  # Vault-encrypted at rest and never returned again).
  post "/v1/sites/:id/github" do
    with_team_site(conn, fn site ->
      repo = conn.body_params["repo"]
      branch = conn.body_params["branch"]
      provided = conn.body_params["webhook_secret"]

      cond do
        not (is_binary(repo) and repo != "") ->
          json(conn, 422, %{error: "repo_required"})

        true ->
          # Generate a secret when the user didn't pass one. Always echo BACK
          # the plaintext secret in the success response (this is the ONLY
          # moment plaintext leaves the server) so the user can paste it into
          # GitHub's webhook form.
          plaintext_secret =
            cond do
              is_binary(provided) and provided != "" -> provided
              true -> generate_webhook_secret()
            end

          case Registry.set_site_github(site, repo, branch, plaintext_secret) do
            {:ok, updated} ->
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
             if(is_binary(reason), do: reason, else: "unspecified")
           ) do
        {:ok, job} ->
          # Push "fleet" so the dashboard surfaces the failed launch (with its
          # error + a retry affordance) instead of a stuck "provisioning".
          broadcast_barkpark_team(job.barkpark_id, "fleet")
          json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :conflict} ->
          json(conn, 409, %{error: "conflict"})

        {:error, _} ->
          json(conn, 422, %{error: "invalid"})
      end
    end
  end

  # POST /v1/builder/claim {worker_id} → 200 {deployment, observed_epoch} |
  # 404 {error: "no_queued"} | 422 missing worker_id.
  # Atomic via Registry.claim_next_deployment/1 (FOR UPDATE SKIP LOCKED +
  # epoch bump in one transaction).
  post "/v1/builder/claim" do
    conn = Auth.require_user(conn, [])

    if conn.halted do
      conn
    else
      worker_id = conn.body_params["worker_id"]

      cond do
        not (is_binary(worker_id) and worker_id != "") ->
          json(conn, 422, %{error: "worker_id_required"})

        true ->
          case Registry.claim_next_deployment(worker_id) do
            {:ok, deployment} ->
              json(conn, 200, %{
                deployment: deployment_json(deployment),
                observed_epoch: deployment.claim_epoch
              })

            {:error, :no_queued} ->
              json(conn, 404, %{error: "no_queued"})
          end
      end
    end
  end

  # POST /v1/builder/deployments/:id/transition
  # {worker_id, observed_epoch, status, image_tag?, build_log_url?,
  #  failure_reason?, became_live_at?} → 200 {deployment} | 409 stale_epoch |
  # 404 not_found | 422 invalid.
  #
  # CASes on (claim_worker, claim_epoch) — the only protection against a stale
  # lease-swept worker writing after another worker re-claimed the row.
  post "/v1/builder/deployments/:id/transition" do
    conn = Auth.require_user(conn, [])

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

            {:error, :not_found} ->
              json(conn, 404, %{error: "not_found"})

            {:error, %Ecto.Changeset{} = cs} ->
              json(conn, 422, %{error: "invalid", details: errors(cs)})
          end
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

                {:error, :not_found} ->
                  json(conn, 404, %{error: "not_found"})

                {:error, %Ecto.Changeset{} = cs} ->
                  json(conn, 422, %{error: "invalid", details: errors(cs)})
              end
          end
      end
    end
  end

  ## Catch-all → 404 JSON

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  ## go-live handler (shared by /launch and /go-live)

  defp go_live(conn) do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 422, %{error: "no_team"})

      # The launch gate: a live subscription is REQUIRED. No subscription → 402
      # and provision NOTHING — the customer must subscribe first. The check runs
      # before any name validation so an unsubscribed caller always learns to
      # subscribe (the actionable next step), not "name_required".
      is_nil(Billing.active_subscription(conn.assigns.current_team)) ->
        json(conn, 402, %{
          error: "no_active_subscription",
          checkout_path: "/v1/billing/checkout"
        })

      true ->
        team = conn.assigns.current_team
        name = conn.body_params["name"]
        slug = if(is_binary(name), do: slugify(name), else: nil)

        with true <- is_binary(name) and name != "",
             {:ok, barkpark} <-
               Registry.register_barkpark(team, %{
                 name: name,
                 slug: slug,
                 # The customer-facing FQDN is computed up front and stored, so it
                 # is IDENTICAL to the provisioning subdomain the worker stands up
                 # (claim_json sends the same `provisioning_subdomain`). The `:url`
                 # carries a GLOBAL unique index — the never-two-boxes-on-one-FQDN
                 # backstop against any cross-tenant collision.
                 url: Barkpark.provisioning_url({slug, team.id}),
                 mode: "managed",
                 health_status: "unknown",
                 agent_status: "offline"
               }) do
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
          json(conn, 201, %{barkpark: barkpark_json(barkpark)})
        else
          false ->
            json(conn, 422, %{error: "name_required"})

          {:error, %Ecto.Changeset{} = changeset} ->
            json(conn, 422, %{error: "invalid", details: errors(changeset)})
        end
    end
  end

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
  defp register(email, password, team_name) do
    result =
      Repo.transaction(fn ->
        with {:ok, user} <- Accounts.register_user(%{email: email, password: password}),
             {:ok, team} <- create_signup_team(user, team_name),
             {:ok, _membership} <- Accounts.add_member(team, user, "owner"),
             {:ok, token} <- Accounts.create_user_session_token(user) do
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

  defp barkpark_json(bp, provision \\ nil, deprovision \\ nil) do
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
      last_seen_at: bp.last_seen_at,
      team_id: bp.team_id,
      inserted_at: bp.inserted_at
    }

    base
    |> merge_job_status(:provision_status, :provision_error, provision)
    |> merge_job_status(:deprovision_status, :deprovision_error, deprovision)
  end

  defp merge_job_status(map, status_key, error_key, %{status: status, error: error}),
    do: Map.merge(map, %{status_key => status, error_key => error})

  defp merge_job_status(map, _status_key, _error_key, _), do: map

  # The non-secret subscription shape for the dashboard's Billing view. Gateway
  # customer / subscription ids are NEVER serialized.
  defp subscription_json(sub) do
    %{
      plan: sub.plan,
      status: sub.status,
      started_at: sub.inserted_at
    }
  end

  defp provider_json(p) do
    # encrypted_token is NEVER serialized — the connected token stays at rest.
    %{
      id: p.id,
      kind: p.kind,
      label: p.label,
      team_id: p.team_id,
      inserted_at: p.inserted_at
    }
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
  defp claim_json(job, barkpark) do
    %{
      job_id: job.id,
      name: barkpark.name,
      slug: Barkpark.provisioning_subdomain(barkpark),
      region: Registry.default_region(),
      server_type: Registry.default_server_type()
    }
  end

  defp deprovision_claim_json(job, barkpark) do
    %{
      job_id: job.id,
      ip: barkpark.host,
      dns_label: Barkpark.provisioning_subdomain(barkpark),
      dns_zone: Barkpark.base_domain()
    }
  end

  defp site_json(s) do
    # env_encrypted is NEVER serialized — the env blob stays at rest.
    # github_webhook_secret_encrypted is NEVER serialized either; the plaintext
    # is shown ONCE in the POST /v1/sites/:id/github response body and that's it.
    %{
      id: s.id,
      barkpark_id: s.barkpark_id,
      team_id: s.team_id,
      name: s.name,
      slug: s.slug,
      framework: s.framework,
      domains: s.domains,
      scale_mode: s.scale_mode,
      port: s.port,
      current_deployment_id: s.current_deployment_id,
      github_repo: s.github_repo,
      github_branch: s.github_branch,
      github_webhook_configured: not is_nil(s.github_webhook_secret_encrypted),
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
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
      failure_reason: d.failure_reason,
      became_live_at: d.became_live_at,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  # Agent-route serialization that bundles the Site shape (slug + domains) the
  # runtime executor needs to render its Caddyfile. Encoded once so claim +
  # pending responses are identical.
  defp deployment_with_site_json(d) do
    base = deployment_json(d)
    site = if Ecto.assoc_loaded?(d.site), do: d.site, else: Registry.get_site(d.site_id)

    Map.put(base, :site, %{
      slug: site && site.slug,
      domains: (site && site.domains) || []
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

  # Walk: auth → team check → fetch site (team-scoped) → run fn(site).
  defp with_team_site(conn, fun) do
    conn = Auth.require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns.current_team) ->
        json(conn, 404, %{error: "not_found"})

      true ->
        case Registry.get_team_site(conn.assigns.current_team, conn.path_params["id"]) do
          %Registry.Site{} = site -> fun.(site)
          nil -> json(conn, 404, %{error: "not_found"})
        end
    end
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

  defp safe_get_job(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(BarkparkCloud.Registry.ProvisionJob, uuid)
      :error -> nil
    end
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

  # Auth for GET /v1/events. The browser EventSource API can't set headers, so a
  # `?token=` query param is accepted in addition to the normal Bearer header.
  # Assigns :current_user + :current_team on success; halts 401 otherwise.
  defp require_user_sse(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    token = Auth.bearer_token(conn) || conn.query_params["token"]

    case is_binary(token) && token != "" && Accounts.verify_user_session_token(token) do
      %{} = user ->
        conn
        |> assign(:current_user, user)
        |> assign(:current_team, Accounts.primary_team(user))

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
  defp stream_events(conn, team_id) do
    :ok = Events.subscribe(team_id)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case Plug.Conn.chunk(conn, ": connected\n\n") do
      {:ok, conn} -> sse_loop(conn)
      {:error, _} -> conn
    end
  end

  defp sse_loop(conn) do
    receive do
      {:bpcloud_event, event} ->
        case encode_sse_frame(event) do
          {:ok, frame} ->
            case Plug.Conn.chunk(conn, frame) do
              {:ok, conn} -> sse_loop(conn)
              {:error, _} -> conn
            end

          :error ->
            # An unencodable event must NOT crash (and so close) the whole SSE
            # stream — the event is only an invalidation hint, safely dropped.
            # Log and keep parking for the next (good) event / heartbeat.
            Logger.error("sse_loop: dropping unencodable event #{inspect(event)}")
            sse_loop(conn)
        end
    after
      25_000 ->
        case Plug.Conn.chunk(conn, ": ping\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end

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

  # The verified-push branch of POST /v1/webhooks/github/:site_id. By this point
  # the HMAC has passed; we still 200 (not 4xx) on non-push events and
  # mismatched-branch pushes so GitHub stops retrying. Only an actual push to
  # the configured branch creates a Deployment.
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
        expected_ref = "refs/heads/" <> configured_branch

        cond do
          not is_binary(ref) ->
            json(conn, 200, %{ok: true, ignored: true, reason: "missing_ref"})

          ref != expected_ref ->
            json(conn, 200, %{
              ok: true,
              ignored: true,
              reason: "branch_mismatch",
              pushed_ref: ref,
              expected_ref: expected_ref
            })

          not is_binary(sha) or sha == "" ->
            json(conn, 200, %{ok: true, ignored: true, reason: "missing_sha"})

          true ->
            # The artifact_url is left empty — the MVP only records that a
            # push happened at this sha. A future builder enhancement (P7+)
            # can git-clone github_repo at this sha and build from source.
            case Registry.create_deployment(site, %{git_ref: sha, artifact_url: nil}) do
              {:ok, deployment} ->
                push_event(site.team_id, "deployments")

                json(conn, 201, %{
                  ok: true,
                  deployment_id: deployment.id,
                  sha: sha,
                  branch: configured_branch
                })

              {:error, cs} ->
                json(conn, 422, %{error: "invalid", details: errors(cs)})
            end
        end
    end
  end

  # Build the user-facing webhook URL the user pastes into GitHub's "Payload
  # URL" field. The scheme + host come from the request so dev (http://...)
  # and prod (https://api.barkpark.cloud) both land on a working URL without
  # threading config through.
  defp webhook_url_for(conn, site_id) do
    scheme = conn.scheme |> to_string()
    host = conn.host

    port_part =
      cond do
        scheme == "https" and conn.port == 443 -> ""
        scheme == "http" and conn.port == 80 -> ""
        true -> ":" <> Integer.to_string(conn.port)
      end

    "#{scheme}://#{host}#{port_part}/v1/webhooks/github/#{site_id}"
  end

  # Generate a fresh webhook secret — 32 cryptographic random bytes,
  # url-safe-Base64 encoded (no padding) so it pastes cleanly into GitHub's
  # secret field.
  defp generate_webhook_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  ## Artifact upload helpers

  # Reads the runtime artifact-upload config: the on-disk dir and the max
  # body size. The dir falls through Application env → BARKPARK_CLOUD_ARTIFACT_DIR
  # env var → /tmp/barkpark-cloud-artifacts dev default. Size cap default: 100 MB.
  defp artifact_config do
    cfg = Application.get_env(:barkpark_cloud, __MODULE__, [])

    dir =
      Keyword.get(cfg, :artifact_dir) ||
        System.get_env("BARKPARK_CLOUD_ARTIFACT_DIR") ||
        "/tmp/barkpark-cloud-artifacts"

    max = Keyword.get(cfg, :max_artifact_bytes, 100 * 1024 * 1024)

    [artifact_dir: dir, max_artifact_bytes: max]
  end

  # Filename: <slug>-<8-byte-random>.tar.gz. The random suffix lets repeated
  # uploads for the same site coexist; the builder reads via file:// URL so
  # the path is the contract — no DB row for the artifact itself.
  defp artifact_filename(slug) do
    rand =
      :crypto.strong_rand_bytes(8)
      |> Base.url_encode64(padding: false)
      |> String.downcase()

    safe_slug = if is_binary(slug) and slug != "", do: slug, else: "site"
    "#{safe_slug}-#{rand}.tar.gz"
  end

  # Streams the request body to `path`, abandoning early when `max_bytes` is
  # exceeded. Returns `{:ok, conn, bytes}` on success, `{:error, :too_large,
  # conn}` when the body crosses the cap, `{:error, reason, conn}` on any I/O
  # failure. The file is opened once, written incrementally, and closed by
  # this function — partial files are caller's responsibility to remove on
  # error (since the path is known there).
  defp stream_body_to_file(conn, path, max_bytes) do
    case File.open(path, [:write, :binary]) do
      {:ok, file} ->
        try do
          do_stream(conn, file, 0, max_bytes)
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, {:open, reason}, conn}
    end
  end

  defp do_stream(conn, file, written, max_bytes) do
    # 8 MiB chunk window — large enough that the per-call overhead is amortized
    # against the 100 MB cap; small enough that a refused upload stops early.
    case Plug.Conn.read_body(conn, length: 8 * 1024 * 1024, read_length: 1024 * 1024) do
      {:ok, chunk, conn} ->
        new_written = written + byte_size(chunk)

        cond do
          new_written > max_bytes ->
            {:error, :too_large, conn}

          true ->
            case IO.binwrite(file, chunk) do
              :ok -> {:ok, conn, new_written}
              {:error, reason} -> {:error, {:write, reason}, conn}
            end
        end

      {:more, chunk, conn} ->
        new_written = written + byte_size(chunk)

        cond do
          new_written > max_bytes ->
            {:error, :too_large, conn}

          true ->
            case IO.binwrite(file, chunk) do
              :ok -> do_stream(conn, file, new_written, max_bytes)
              {:error, reason} -> {:error, {:write, reason}, conn}
            end
        end

      {:error, reason} ->
        {:error, {:read, reason}, conn}
    end
  end
end
