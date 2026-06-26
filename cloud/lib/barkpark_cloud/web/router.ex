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
      *       (anything else)      —         404 JSON

  Every response is JSON. Errors are `{"error": "<reason>"}`. The agent routes
  authenticate with an AGENT token (`Registry.verify_agent_token`); the user
  routes with a USER session token (`Accounts.verify_user_session_token`) — both
  via `BarkparkCloud.Web.Auth`.
  """
  use Plug.Router

  alias BarkparkCloud.{Accounts, Billing, Registry}
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

  ## Helpers

  # The approved-command queue source. Empty by default; a configurable stub lets
  # a test (or cloud-13) inject commands without a queue backend.
  defp command_queue do
    Application.get_env(:barkpark_cloud, __MODULE__, [])
    |> Keyword.get(:command_queue, [])
  end

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
