defmodule BarkparkWeb.Plugs.ResolveWorkspace do
  @moduledoc """
  Resolves the `:workspace_slug` path param into `conn.assigns[:current_workspace]`
  and enforces the hard tenant boundary at the routing layer.

  Flow:

    1. read `:workspace_slug` from `conn.path_params`,
    2. `Barkpark.Tenancy.get_workspace_by_slug/1` — 404 (envelope) if unknown,
    3. `Barkpark.Tenancy.Auth.authorize(api_token, workspace.id, :read)` —
       403 (envelope) on refusal — `{:error, :forbidden_membership}`, whose
       message/hint name MEMBERSHIP rather than a permission tier (the
       `forbidden` code and the 403 status are unchanged).

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

  ## Studio demo flag (studio-anonymous-default-lockdown)

  `allow_anonymous_default: :studio_demo` is the STUDIO pipelines' spelling:
  the allowance only applies while `config :barkpark, :public_demo_studio` is
  true (dev/test default; prod opt-in via BARKPARK_PUBLIC_DEMO_STUDIO). With
  the flag off, an anonymous HTML request for the Default workspace redirects
  to `/login` (return_to preserved) instead of 403ing — production Studio
  requires a sign-in. The paper reader keeps the literal `true` (published
  papers are world-readable by design).
  """

  import Plug.Conn

  alias Barkpark.Access
  alias Barkpark.Content.CallerContext
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

    # MEMBERSHIP first, unchanged — a member's decision (token OR user role) is
    # byte-identical to before, and NEVER carries the grant flag. Only a
    # non-member user is offered the grant path below (grants only ADD access).
    member? =
      TenancyAuth.authorize(token, workspace.id, :read) == :ok or
        (not is_nil(user) and TenancyAuth.authorize(user, workspace.id, :read) == :ok)

    # Grant path (airdrop-grants ag-enforcement, Layer 1). ONLY a non-member USER
    # with an ACTIVE grant that authorizes :read here is admitted — as a
    # GRANT-DERIVED caller: we assign the grant-bearing CallerContext + the
    # `:grant_scoped_read` flag so `ScopeHelpers` threads Layer-2 row narrowing
    # into every Content read. Reuses `Access.validate/3` (scope/capability/
    # expiry truth); no membership decision is altered.
    grant_admit =
      if not member? and not is_nil(user),
        do: grant_read_ctx(user, desk_scope(conn, workspace))

    cond do
      member? ->
        assign(conn, :current_workspace, workspace)

      # The Default-workspace public allowance keys on NO TOKEN (P3 posture).
      # A signed-in user without a Default membership still gets it — being
      # signed in never grants less than anonymous. Ordered ABOVE the grant arm
      # so a grantee who ALSO qualifies for this broad demo access keeps it
      # UNNARROWED (grants only ADD access — the grant must never REMOVE the
      # public-demo visibility a plain anonymous visitor already has).
      is_nil(token) and anonymous_default_allowed?(opts) and
          default_workspace?(workspace) ->
        conn
        |> assign(:current_workspace, workspace)
        |> assign(:anonymous_default_read, true)

      not is_nil(grant_admit) ->
        conn
        |> assign(:current_workspace, workspace)
        |> assign(:caller_context, grant_admit)
        |> assign(:grant_scoped_read, true)

      # Flag-off Studio: the anonymous browser isn't forbidden, it's just not
      # signed in — send it to the sign-in page rather than a 403 envelope.
      is_nil(token) and is_nil(user) and studio_demo_opt?(opts) and
          default_workspace?(workspace) ->
        conn
        |> Phoenix.Controller.redirect(
          to: "/login?return_to=#{URI.encode_www_form(conn.request_path)}"
        )
        |> halt()

      # Not a member (and no share / demo / grant admitted it). The reason is
      # MEMBERSHIP, never a permission tier — `:forbidden_membership` says so in
      # the envelope. Same 403 status and same "forbidden" code as before; only
      # the message/hint/reason changed (gyldendal #15).
      true ->
        halt_envelope(conn, {:error, :forbidden_membership})
    end
  end

  # Build a grant-bearing CallerContext for `user` and admit it ONLY if some
  # ACTIVE grant admits the MOUNTED DESK scope for :read. Returns the ctx (to
  # assign) or nil. `from_user/2` loads the user's active grants in-query;
  # `Access.admits_desk?/3` applies scope+capability+expiry at desk granularity
  # (type/doc narrowed later by `scope_to_grants`). Fail-closed: no admitting
  # grant → nil.
  defp grant_read_ctx(%Barkpark.Accounts.User{id: uid}, desk_scope)
       when is_binary(uid) and is_map(desk_scope) do
    ctx = CallerContext.from_user(uid)

    if Enum.any?(ctx.grants, &(Access.admits_desk?(&1, :read, desk_scope) == true)) do
      ctx
    end
  end

  defp grant_read_ctx(_user, _desk_scope), do: nil

  # The mounted desk scope from the URL path params — workspace (resolved) +
  # project (`:project_slug` → id, one extra read only on this non-member grant
  # path) + `:dataset`. A route WITHOUT those params (a project-less scoped
  # route) yields `%{workspace_id}` only → byte-identical to the old
  # bare-workspace admission (a ws-wide grant still admits; a sub-scoped grant
  # still denies). Fed to `Access.admits_desk?/3`.
  defp desk_scope(conn, workspace) do
    scope = %{workspace_id: workspace.id}

    scope =
      case conn.path_params["project_slug"] do
        slug when is_binary(slug) ->
          case Tenancy.get_project(workspace.slug, slug) do
            %{id: pid} -> Map.put(scope, :project_id, pid)
            _ -> scope
          end

        _ ->
          scope
      end

    case conn.path_params["dataset"] do
      ds when is_binary(ds) -> Map.put(scope, :dataset, ds)
      _ -> scope
    end
  end

  # `true` → unconditional (paper reader); `:studio_demo` → only while the
  # public-demo flag is on; absent/false → never.
  defp anonymous_default_allowed?(opts) do
    case Keyword.get(opts, :allow_anonymous_default, false) do
      true -> true
      :studio_demo -> Application.get_env(:barkpark, :public_demo_studio, false)
      _ -> false
    end
  end

  defp studio_demo_opt?(opts),
    do: Keyword.get(opts, :allow_anonymous_default, false) == :studio_demo

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
