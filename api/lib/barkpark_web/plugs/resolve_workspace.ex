defmodule BarkparkWeb.Plugs.ResolveWorkspace do
  @moduledoc """
  Resolves the `:workspace_slug` path param into `conn.assigns[:current_workspace]`
  and enforces the hard tenant boundary at the routing layer.

  Flow:

    1. read `:workspace_slug` from `conn.path_params`,
    2. `Barkpark.Tenancy.get_workspace_by_slug/1` — 404 (envelope) if unknown,
    3. `Barkpark.Tenancy.Auth.authorize(api_token, workspace.id, :read)` —
       403 (envelope) on `{:error, :forbidden}`.

  Step 3 is the cross-dataset read-leak fix: even an authenticated token only
  reaches a workspace's content when it is a member with at least `:read`.
  Anonymous callers (no `:api_token` assign) fail authorize/3 closed → 403.

  Pipeline: must run AFTER `BarkparkWeb.Plugs.OptionalToken` so
  `conn.assigns[:api_token]` is populated when a Bearer token was sent. The
  WHERE-clause query scoping by `workspace_id` is a sibling CONTEXT task — this
  plug only resolves + assigns the workspace and gates membership.

  ## Public-share bypass

  When `conn.assigns[:share_public]` is `true`, the workspace has ALREADY been
  resolved + assigned by `BarkparkWeb.Plugs.RequireShareScope` (which verified
  the scope is shared for the route's surface via `Barkpark.Sharing`). In that
  case this plug is a pure pass-through: it does NOT re-resolve and does NOT run
  the membership-authorize gate — that is the entire point of a public share
  (anonymous read of a shared scope). The flag is set ONLY by RequireShareScope,
  ONLY on an exact shared-scope match; without it (the default everywhere) this
  plug runs its membership gate exactly as before.

  ## Anonymous-Default allowance (P3 of Scoped-by-URL)

  `plug ResolveWorkspace, allow_anonymous_default: true` lets an ANONYMOUS
  conn resolve the seeded **Default workspace only** — the posture the flat
  Studio always had (anonymous demo/dev access to Default), carried onto its
  scoped successor so the P3 flat→scoped 302 doesn't break the public demo
  link or tokenless dev. Strictly bounded: token-present requests still go
  through the membership gate unchanged, and an anonymous request for any
  NON-Default workspace still fails closed. Opt-in per pipeline — every
  pipeline that doesn't pass the option keeps the hard fail-closed gate. The
  pass-through is marked `assigns[:anonymous_default_read] = true` so
  downstream surfaces can tell it from a member resolve.
  """

  import Plug.Conn

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  def init(opts), do: opts

  def call(%{assigns: %{share_public: true}} = conn, _opts), do: conn

  def call(conn, opts) do
    slug = conn.path_params["workspace_slug"]

    case slug && Tenancy.get_workspace_by_slug(slug) do
      %Tenancy.Workspace{} = workspace ->
        authorize(conn, workspace, opts)

      _ ->
        halt_envelope(conn, {:error, :not_found})
    end
  end

  defp authorize(conn, workspace, opts) do
    token = conn.assigns[:api_token]
    user = conn.assigns[:current_user]

    cond do
      TenancyAuth.authorize(token, workspace.id, :read) == :ok ->
        assign(conn, :current_workspace, workspace)

      # studio-user-login: an account session is a User principal — same
      # chokepoint, the membership ROLE is the grant. Token keeps precedence
      # above; this arm only fires for cookie-only browser users.
      not is_nil(user) and TenancyAuth.authorize(user, workspace.id, :read) == :ok ->
        assign(conn, :current_workspace, workspace)

      # The Default-workspace public allowance keys on NO TOKEN (P3 posture).
      # A signed-in user without a Default membership still gets it — being
      # signed in never grants less than anonymous.
      is_nil(token) and Keyword.get(opts, :allow_anonymous_default, false) and
          default_workspace?(workspace) ->
        conn
        |> assign(:current_workspace, workspace)
        |> assign(:anonymous_default_read, true)

      true ->
        halt_envelope(conn, {:error, :forbidden})
    end
  end

  defp default_workspace?(workspace) do
    case Tenancy.get_default_workspace() do
      %{id: id} -> id == workspace.id
      _ -> false
    end
  end

  defp halt_envelope(conn, reason) do
    env = Barkpark.Content.Errors.to_envelope(reason, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
