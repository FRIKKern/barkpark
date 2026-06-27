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

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
