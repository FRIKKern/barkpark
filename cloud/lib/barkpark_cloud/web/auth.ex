defmodule BarkparkCloud.Web.Auth do
  @moduledoc """
  Bearer-token authentication for the control-plane HTTP API (cloud-12a).

  Three principals share one `Authorization: Bearer <token>` header but resolve
  through different stores:

    * a USER session token (`Accounts.verify_user_session_token/1`) → the human
      behind "one login for all your Barkparks". Assigned as
      `conn.assigns.current_user` + `conn.assigns.current_team` (the user's
      primary team — a logged-in user acts within one team at a time).
    * an AGENT token (`Registry.verify_agent_token/1`) → an on-box agent
      reporting for one Barkpark. Assigned as `conn.assigns.current_barkpark`.
    * the WORKER token — a single shared secret (`:worker_token` config / the
      `WORKER_TOKEN` env) the off-box Go warm-pool provisioner presents to the
      `/v1/internal/*` job-queue endpoints. NOT a user session and NOT an agent
      token — a separate, unrelated principal, checked by constant-time compare.

  The user/agent token namespaces do not overlap (random 32-byte tokens,
  separate hashed tables), so a token is at most one of those principals. The
  worker token is a flat shared secret, so a user/agent token can never be it
  and the worker token resolves no user/agent (each pipeline does its OWN lookup
  against only its store). Three pipeline plugs gate routes:

    * `require_user/2`   — 401 unless a valid USER session token resolved.
    * `require_agent/2`  — 401 unless a valid AGENT token resolved.
    * `require_worker/2` — 401 unless the bearer equals the configured worker
      token. When no worker token is configured (e.g. dev with `WORKER_TOKEN`
      unset), it fails CLOSED — every request 401s rather than opening the
      internal endpoints to all.
  """
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.Authz
  alias BarkparkCloud.Accounts.TeamMembership
  alias BarkparkCloud.Registry

  @doc """
  Require a valid USER session token. On success assigns `:current_user` and
  `:current_team`; otherwise halts the conn with a 401 JSON body.
  """
  def require_user(conn, _opts) do
    with token when is_binary(token) <- bearer_token(conn),
         %{} = user <- Accounts.verify_user_session_token(token) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_team, Accounts.primary_team(user))
    else
      _ -> unauthorized(conn)
    end
  end

  @doc """
  Require a USER whose grant on `current_team` is `owner` or `admin`.

  Runs `require_user/2` first (idempotent if `current_user` is already assigned),
  then enforces the role via `Authz.team_admin?/2`. A drop-in replacement for the
  `require_user` line in a mutating route: 401 when unauthenticated, 403 when
  authenticated but under-privileged (or holding no team grant). Mirrors api/'s
  `BarkparkWeb.Plugs.RequireWorkspaceRole` (fail-closed on a missing assign → 403)
  in this `Plug.Router`'s inline style.
  """
  def require_team_admin(conn, opts), do: gate_role(conn, opts, &Authz.team_admin?/2)

  @doc """
  Require a USER who is the OWNER of `current_team` (the billing / delete-team
  gate). Same shape as `require_team_admin/2`, narrower check.
  """
  def require_team_owner(conn, opts), do: gate_role(conn, opts, &Authz.team_owner?/2)

  @doc """
  Require a valid USER credential — either a session token OR a Personal Access
  Token (PAT). The programmatic-API counterpart of `require_user/2`: external
  integrations authenticate with a PAT, the browser dashboard with a session.

  On success assigns `:current_user`, `:current_team`, and `:current_abilities`:

    * a SESSION credential implies the full user (a logged-in human is not
      ability-limited), so it carries `["root"]` — the browser dashboard is
      never gated by `require_ability/2`.
    * a PAT carries `:current_token` (the `%UserToken{}`) + its own
      `:current_abilities` array, and resolves `:current_team` from the team it
      was minted under (falling back to the user's primary team).

  Halts with a 401 JSON body when neither resolves.
  """
  def require_user_or_pat(conn, _opts) do
    case bearer_token(conn) do
      token when is_binary(token) ->
        cond do
          user = Accounts.verify_user_session_token(token) ->
            conn
            |> assign(:current_user, user)
            |> assign(:current_team, Accounts.primary_team(user))
            |> assign(:current_abilities, ["root"])

          result = Accounts.verify_personal_access_token(token) ->
            {user, pat} = result

            conn
            |> assign(:current_user, user)
            |> assign(
              :current_team,
              Accounts.get_team(pat.team_id) || Accounts.primary_team(user)
            )
            |> assign(:current_token, pat)
            |> assign(:current_abilities, pat.abilities)

          true ->
            unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  @doc """
  Require `ability` (or the superset `root`) on the resolved credential. Run
  AFTER `require_user_or_pat/2`. A session credential carries `["root"]` so the
  browser dashboard always passes; a PAT is gated by its `abilities` array.
  Halts with a 403 JSON body on a miss (and is a no-op pass-through if the conn
  is already halted, so it composes cleanly after the require step).
  """
  def require_ability(conn, ability) when is_binary(ability) do
    if conn.halted do
      conn
    else
      abilities = conn.assigns[:current_abilities] || []

      if "root" in abilities or ability in abilities do
        conn
      else
        forbidden(conn)
      end
    end
  end

  @doc """
  Require a valid AGENT token. On success assigns `:current_barkpark`; otherwise
  halts the conn with a 401 JSON body.
  """
  def require_agent(conn, _opts) do
    with token when is_binary(token) <- bearer_token(conn),
         %{} = barkpark <- Registry.verify_agent_token(token) do
      assign(conn, :current_barkpark, barkpark)
    else
      _ -> unauthorized(conn)
    end
  end

  @doc """
  Require the shared WORKER token (the off-box Go warm-pool provisioner). On a
  match the conn passes through unchanged (the worker is a faceless principal —
  there is no team/barkpark to assign); otherwise halts with a 401 JSON body.

  Fails CLOSED when no worker token is configured: an unset / blank
  `:worker_token` 401s every request, so the internal endpoints are never open
  by omission. The compare is constant-time to avoid leaking the secret by
  timing.
  """
  def require_worker(conn, _opts) do
    configured = worker_token()

    with token when is_binary(token) <- bearer_token(conn),
         true <- is_binary(configured) and configured != "",
         true <- Plug.Crypto.secure_compare(token, configured) do
      conn
    else
      _ -> unauthorized(conn)
    end
  end

  @doc """
  The configured shared worker token (`config :barkpark_cloud, :worker_token`,
  fed from `WORKER_TOKEN` in runtime.exs). `nil` when unset — `require_worker`
  treats that as "no worker may authenticate" (fail closed).
  """
  @spec worker_token() :: binary() | nil
  def worker_token, do: Application.get_env(:barkpark_cloud, :worker_token)

  @doc """
  Require that the authed user holds at least `min_role` ("member"|"admin") in
  the team named by `team_id`. The Cloud twin of api/'s `RequireWorkspaceRole`
  (copied, NOT reused — the api/ plug lives in another OTP app). On success
  assigns `:current_team_scoped` (the path team) and `:current_team_role`; on
  failure halts:

    * 401 if no/invalid user token (delegates to `require_user/2`).
    * 404 if the user is NOT a member of that team (no existence leak — a
      non-member learns nothing about whether the team exists).
    * 403 if a member but below `min_role`.
  """
  @spec require_team_role(Plug.Conn.t(), binary() | nil, String.t()) :: Plug.Conn.t()
  def require_team_role(conn, team_id, min_role) do
    conn = require_user(conn, [])

    if conn.halted do
      conn
    else
      user = conn.assigns.current_user

      case team_id && Accounts.get_team(team_id) do
        nil ->
          # No id, or no such team → 404 (same shape a non-member gets).
          not_found(conn)

        team ->
          role = Accounts.team_role(user, team)

          cond do
            # Not a member → 404, never a 403 (do not confirm the team exists).
            is_nil(role) ->
              not_found(conn)

            TeamMembership.rank(role) < TeamMembership.rank(min_role) ->
              forbidden(conn)

            true ->
              conn
              |> assign(:current_team_scoped, team)
              |> assign(:current_team_role, role)
          end
      end
    end
  end

  @doc """
  Require that the authed user is owner|admin of their PRIMARY team — the gate
  for privileged actions on routes that still resolve the team implicitly
  (billing/checkout, go-live, DELETE barkpark) rather than from a path `:id`.
  401 if unauthenticated; 422 `no_team` if the user has no team; 403 if a member
  but not admin. On success the conn passes through with `:current_team` already
  assigned by `require_user/2`.
  """
  @spec require_primary_team_admin(Plug.Conn.t()) :: Plug.Conn.t()
  def require_primary_team_admin(conn) do
    conn = require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns[:current_team]) ->
        json_halt(conn, 422, %{error: "no_team"})

      Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) ->
        conn

      true ->
        forbidden(conn)
    end
  end

  @doc """
  Extract the bearer token from the `Authorization` header, or `nil` when it is
  absent or not a `Bearer <token>` form. Public so the router can reuse it.
  """
  @spec bearer_token(Plug.Conn.t()) :: binary() | nil
  def bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      ["bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  # Ensure a user, then enforce `check.(user, team)`. A no-team authenticated
  # user is 403 (not 401) — they ARE authenticated, they simply hold no grant.
  defp gate_role(conn, opts, check) do
    conn = if conn.assigns[:current_user], do: conn, else: require_user(conn, opts)

    cond do
      # require_user already sent 401 — leave it.
      conn.halted -> conn
      is_nil(conn.assigns[:current_team]) -> forbidden(conn)
      check.(conn.assigns.current_user, conn.assigns.current_team) -> conn
      true -> forbidden(conn)
    end
  end

  defp unauthorized(conn), do: json_halt(conn, 401, %{error: "unauthorized"})
  defp forbidden(conn), do: json_halt(conn, 403, %{error: "forbidden"})
  defp not_found(conn), do: json_halt(conn, 404, %{error: "not_found"})

  defp json_halt(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
