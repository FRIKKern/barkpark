defmodule BarkparkCloud.Web.Router do
  @moduledoc """
  The control-plane HTTP API (cloud-12a) — a minimal JSON `Plug.Router` over the
  Accounts / Registry / Billing contexts. Deliberately NOT Phoenix/LiveView: the
  dashboard is a later task, this is just the callable JSON surface the agent
  (cloud-10) already POSTs to and the Go CLI client (cloud-12b) will call.

  ## Route table

      METHOD  PATH                 AUTH      PURPOSE
      POST    /v1/auth/login       —         email+password → {token, team_id}
      POST    /v1/agent/report     agent     land a health report (health + events)
      GET     /v1/agent/commands   agent     approved-command queue (empty for now)
      POST    /v1/agent/results    agent     ack command results
      GET     /v1/barkparks        user      the team's registered Barkparks
      POST    /v1/providers        user      connect a cloud provider
      POST    /v1/launch           user      go-live (alias of /v1/go-live)
      POST    /v1/go-live          user      pay + create a provisioning Barkpark
      POST    /v1/internal/provision-jobs/claim       worker  claim oldest pending job
      POST    /v1/internal/provision-jobs/:id/succeed worker  flip barkpark up at {ip}
      POST    /v1/internal/provision-jobs/:id/fail    worker  mark job failed {error}
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

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Web.Auth

  # The pay-once go-live charge, in minor units (€49.00). A single value, not a
  # pricing engine — real prices are the human task cloud-17.
  @go_live_amount_cents 4900

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

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

  # GET /v1/barkparks → 200 {barkparks: [...]} for the user's team.
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

      json(conn, 200, %{barkparks: Enum.map(barkparks, &barkpark_json/1)})
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

  # POST /v1/launch {provider, name} and POST /v1/go-live {name, plan} — the
  # control-plane half of go-live: auth + pay (Billing.charge_go_live, StubGateway
  # in dev/test) + create the registry row in a provisioning state. The actual Go
  # warm-pool provisioning + reporting-back is cloud-12b/cloud-13. → 201
  # {barkpark} honestly carrying health_status:"unknown", agent_status:"offline".
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
  # and flip its Barkpark to up at {ip}. 200 {ok: true}; 422 when ip is missing;
  # 404 when no job has that id.
  post "/v1/internal/provision-jobs/:id/succeed" do
    conn = Auth.require_worker(conn, [])

    cond do
      conn.halted ->
        conn

      not (is_binary(conn.body_params["ip"]) and conn.body_params["ip"] != "") ->
        json(conn, 422, %{error: "ip_required"})

      true ->
        case Registry.succeed_job(id, conn.body_params["ip"]) do
          {:ok, _job} -> json(conn, 200, %{ok: true})
          {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
          {:error, _} -> json(conn, 422, %{error: "invalid"})
        end
    end
  end

  # POST /v1/internal/provision-jobs/:id/fail {error} → mark the job failed; the
  # Barkpark stays provisioning. 200 {ok: true}; 404 when no job has that id.
  post "/v1/internal/provision-jobs/:id/fail" do
    conn = Auth.require_worker(conn, [])

    if conn.halted do
      conn
    else
      reason = conn.body_params["error"]

      case Registry.fail_job(id, if(is_binary(reason), do: reason, else: "unspecified")) do
        {:ok, _job} -> json(conn, 200, %{ok: true})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        {:error, _} -> json(conn, 422, %{error: "invalid"})
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

      true ->
        team = conn.assigns.current_team
        name = conn.body_params["name"]

        with true <- is_binary(name) and name != "",
             {:ok, _charge_id} <- Billing.charge_go_live(team, @go_live_amount_cents),
             {:ok, barkpark} <-
               Registry.register_barkpark(team, %{
                 name: name,
                 slug: slugify(name),
                 mode: "managed",
                 health_status: "unknown",
                 agent_status: "offline"
               }) do
          # Async half: hand the provisioning work to the Go warm-pool worker
          # via a pending job. The customer is ALREADY charged and the barkpark
          # row ALREADY exists in a provisioning state by this point, so an
          # enqueue hiccup (a DB blip) must NOT 500 the request — that would be a
          # charged-but-failed go-live. A missed job is recoverable (the row
          # carries the provisioning state; re-enqueue is a separate concern), so
          # on error we LOG and still return the normal 201.
          case Registry.enqueue_provision_job(barkpark) do
            {:ok, _job} ->
              :ok

            {:error, reason} ->
              Logger.error(
                "go_live: failed to enqueue provision job for barkpark #{barkpark.id}: " <>
                  inspect(reason)
              )
          end

          json(conn, 201, %{barkpark: barkpark_json(barkpark)})
        else
          false ->
            json(conn, 422, %{error: "name_required"})

          {:error, %Ecto.Changeset{} = changeset} ->
            json(conn, 422, %{error: "invalid", details: errors(changeset)})

          {:error, reason} ->
            json(conn, 402, %{error: "payment_failed", reason: inspect(reason)})
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

  defp barkpark_json(bp) do
    %{
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
  # the job id to report back against, the Barkpark's name + slug, and the
  # region / server_type (warm-pool defaults — nbg1/cax11 — since the Barkpark
  # row doesn't pin them yet). Keys are EXACTLY what the Go worker expects.
  defp claim_json(job, barkpark) do
    %{
      job_id: job.id,
      name: barkpark.name,
      slug: barkpark.slug,
      region: Registry.default_region(),
      server_type: Registry.default_server_type()
    }
  end

  ## Helpers

  # The approved-command queue source. Empty by default; a configurable stub lets
  # a test (or cloud-13) inject commands without a queue backend.
  defp command_queue do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:command_queue, [])
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
end
