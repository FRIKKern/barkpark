defmodule BarkparkWeb.Plugs.ResolveWorkspace do
  @moduledoc """
  Resolves the `:workspace_slug` path param into `conn.assigns[:current_workspace]`
  and enforces the hard tenant boundary at the routing layer.

  Flow:

    1. read `:workspace_slug` from `conn.path_params`,
    2. `Barkpark.Tenancy.get_workspace_by_slug/1` — 404 (envelope) if unknown,
    3. `Barkpark.Tenancy.Auth.authorize_with_reason(api_token, workspace.id,
       :read)` — 403 (envelope) on refusal, with the REFUSING ARM named:
       `{:error, :forbidden_membership}` (reason "not_a_member") when the
       principal holds no seat here, `{:error, :forbidden_capability}` (reason
       "missing_capability") when it IS a member whose permissions/role do not
       satisfy `:read`. The `forbidden` code and the 403 status are unchanged
       on both, and so is WHO is admitted — `authorize/3` is this same function
       collapsed, so the admitted set is identical by construction.

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
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.CallerContext
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  def init(opts), do: opts

  # A public share is admitted by `RequireShareScope`, which resolved the
  # workspace itself — so the archive refusal is applied here too, or a shared
  # link would keep serving an archived workspace to anonymous readers.
  def call(%{assigns: %{share_public: true}} = conn, _opts), do: refuse_if_archived(conn)

  # task-88e9094df76d31c6 — a VERIFIED, scope-matched Preview JWT has already
  # resolved + assigned `:current_workspace` itself
  # (`BarkparkWeb.Plugs.PreviewToken`'s `assign_claimed_scope/2`, reached
  # only after that plug's OWN `check_workspace_scope/2` confirmed the
  # claim's `workspace_id` equals THIS URL's `:workspace_slug`) — mirrors
  # the `share_public` bypass immediately above. Without this, running the
  # ordinary session/Bearer membership gate a second time here would refuse
  # a bare Preview-JWT caller as `not_a_member` (it carries no `:api_token`
  # and no `:current_user` at all), undoing the admission the Preview plug
  # just granted. `:preview_claims` is set ONLY by that plug, and only once
  # it has already verified signature, expiry, revocation AND the scope
  # match — never by caller input.
  def call(%{assigns: %{preview_claims: _}} = conn, _opts), do: refuse_if_archived(conn)

  def call(conn, opts) do
    slug = conn.path_params["workspace_slug"]

    case slug && Tenancy.get_workspace_by_slug(slug) do
      %Tenancy.Workspace{} = workspace ->
        conn
        |> authorize(workspace, opts)
        |> refuse_off_binding()
        |> refuse_if_archived()

      _ ->
        refuse(conn, opts, unknown_workspace(slug))
    end
  end

  # task-69cd78907b82abf6: an unknown slug used to answer the bare
  # `{:error, :not_found}`, whose envelope reads "document not found" with a
  # hint about document ids. No document was named. The 404 now names the
  # WORKSPACE slug the caller sent. That discloses nothing: it echoes the
  # caller's own input, and an existing workspace the caller may not enter
  # still answers 403, never this 404.
  defp unknown_workspace(slug) do
    {:error,
     {:not_found, "workspace #{inspect(slug)} not found",
      hint: "Check the workspace slug in the URL (/w/<workspace>/…) or the bp -w flag."}}
  end

  # ARCHIVED IS REFUSED AFTER ADMISSION, NEVER BEFORE (task-55474a106554e65a).
  #
  # The order is the disclosure rule. Only a caller this plug has ALREADY
  # admitted (member, public-demo Default, grantee, public share) learns the
  # workspace is archived — 409 `workspace_archived`. A caller the membership
  # gate refused keeps its 403 exactly as before, and an unknown slug keeps its
  # 404, so the three answers stay distinguishable (never-existed / forbidden /
  # archived) without telling a stranger anything about a workspace's state.
  #
  # One check here covers every `/w/:workspace_slug/...` route family — data,
  # media, plugins, Studio — instead of one per controller.
  defp refuse_if_archived(%Plug.Conn{halted: true} = conn), do: conn

  defp refuse_if_archived(
         %Plug.Conn{assigns: %{current_workspace: %Tenancy.Workspace{} = workspace}} = conn
       ) do
    if Tenancy.Workspace.archived?(workspace),
      do: halt_envelope(conn, {:error, {:workspace_archived, workspace.slug}}),
      else: conn
  end

  defp refuse_if_archived(conn), do: conn

  # DATASET-BOUND TOKENS (task-4418b517649a58ce). Every scoped pipeline
  # resolves its credential (`OptionalToken` or `OptionalSessionToken`, bearer
  # or session) before this plug. So the fence lives here once for all of
  # `/w/:workspace_slug/p/:project_slug/...`: a token minted with an explicit
  # `dataset` is refused on any other dataset. Unbound tokens (NULL — every
  # legacy row) pass untouched. The predicate is `RequireToken`'s, so both
  # doors refuse identically. It runs AFTER admission, like the archive check:
  # a caller the membership gate refused keeps its own 403 reason.
  defp refuse_off_binding(%Plug.Conn{halted: true} = conn), do: conn

  defp refuse_off_binding(conn) do
    if BarkparkWeb.Plugs.RequireToken.dataset_off_binding?(conn, conn.assigns[:api_token]),
      do: halt_envelope(conn, {:error, :forbidden_dataset}),
      else: conn
  end

  defp authorize(conn, workspace, opts) do
    token = conn.assigns[:api_token]
    user = conn.assigns[:current_user]

    # MEMBERSHIP first, unchanged — a member's decision (token OR user role) is
    # byte-identical to before, and NEVER carries the grant flag. Only a
    # non-member user is offered the grant path below (grants only ADD access).
    #
    # `authorize_with_reason/3`, NOT `authorize/3`. This is an ACCURACY change
    # and nothing else: `authorize/3` IS `authorize_with_reason/3` collapsed
    # (`case authorize_with_reason(...) do :ok -> :ok; {:error, _} ->
    # {:error, :forbidden} end`), so `decision == :ok` here is true for EXACTLY
    # the callers `authorize(...) == :ok` admitted before — the admitted set is
    # byte-identical by construction, not by inspection. What changes is only
    # what a REFUSAL is allowed to say about itself.
    decision = read_decision(token, user, workspace.id)
    member? = decision == :ok

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

      # Refused (and no share / demo / grant admitted it). WHICH ARM refused is
      # now carried through: a caller that IS a member but whose permissions /
      # role do not satisfy `:read` gets `:forbidden_capability`
      # (reason "missing_capability"), and everything else keeps the
      # `:forbidden_membership` envelope it had (reason "not_a_member"). The two
      # arms have OPPOSITE remedies — grant a seat vs. re-mint the credential —
      # so rendering the second as the first pointed an operator at widening
      # workspace membership, the more dangerous of the two fixes. Same 403 and
      # same "forbidden" code on both arms; only `reason`/message/hint differ.
      # An API token with no seat here: name the workspace and the remedy
      # (task-7d4d405e0ee4bcbf). Same 403 / `forbidden` / `not_a_member`.
      decision == {:error, :not_a_member} and match?(%ApiToken{}, token) ->
        refuse(conn, opts, {:error, {:token_not_a_member, workspace.slug}})

      true ->
        refuse(conn, opts, {:error, refusal_envelope(decision)})
    end
  end

  # The read decision for this conn, reason-carrying. Preserves the ORDER and
  # the SHORT-CIRCUIT of the boolean it replaced: the token arm is asked first,
  # the user arm only when the token arm refused and a user is present, so no
  # request issues a DB read it did not issue before.
  #
  # When BOTH arms refuse, `:missing_capability` wins: it is the strictly more
  # specific fact ("this principal is inside the workspace"), and a caller
  # holding a seat on either principal is not a stranger to the workspace.
  defp read_decision(token, user, workspace_id) do
    case TenancyAuth.authorize_with_reason(token, workspace_id, :read) do
      :ok ->
        :ok

      {:error, token_reason} when not is_nil(user) ->
        case TenancyAuth.authorize_with_reason(user, workspace_id, :read) do
          :ok -> :ok
          {:error, user_reason} -> {:error, more_specific(token_reason, user_reason)}
        end

      {:error, token_reason} ->
        {:error, token_reason}
    end
  end

  defp more_specific(:missing_capability, _), do: :missing_capability
  defp more_specific(_, :missing_capability), do: :missing_capability
  defp more_specific(:not_a_member, _), do: :not_a_member
  defp more_specific(_, :not_a_member), do: :not_a_member
  defp more_specific(reason, _), do: reason

  # ONLY the insider arm gets the new envelope. `:not_a_member` keeps the
  # envelope it always had, and so does the bare `:forbidden` that an ANONYMOUS
  # conn produces (no token and no user reach `authorize_with_reason/3`'s
  # catch-all, which is `{:error, :forbidden}` — NOT `:not_a_member`), so the
  # anonymous 403 body is unchanged.
  defp refusal_envelope({:error, :missing_capability}), do: :forbidden_capability
  defp refusal_envelope(_), do: :forbidden_membership

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

  # task-a0fcffbe8799abe5 — dispatch EVERY refusal this plug produces
  # (unknown workspace, not-a-member, missing-capability, a token with no
  # seat) through ONE door, so a signed-in browser visiting a Studio URL
  # never sees the raw `{"error":{...}}` envelope.
  #
  # ONLY on the Studio browser pipelines (keyed on `allow_anonymous_default:
  # :studio_demo` — the same flag `:scoped_browser` and `:shared_studio_browser`
  # already pass; the paper reader's `:shared_paper_browser` passes `true`
  # instead and is untouched), ONLY for an HTML request (`:accepts, ["html"]`
  # runs before this plug on both of those pipelines), and ONLY for a
  # SIGNED-IN user — an anonymous visitor keeps its existing behaviour
  # (the Default-workspace demo allowance, or the :studio_demo redirect to
  # `/login`, or the bare envelope on a non-Default anonymous request; none
  # of those are the bug this task fixes).
  #
  # EVERY reason renders the SAME generic page (NO EXISTENCE LEAK, owner
  # ruling): a workspace that does not exist and one the caller may not
  # enter must be indistinguishable to this caller, so the page never names
  # the workspace or the refusal reason — only the API envelope still
  # carries that detail, for a caller who already knows to parse it.
  defp refuse(conn, opts, reason) do
    if studio_html_refusal?(conn, opts),
      do: halt_studio_refusal_page(conn),
      else: halt_envelope(conn, reason)
  end

  defp studio_html_refusal?(conn, opts) do
    Keyword.get(opts, :allow_anonymous_default) == :studio_demo and
      Phoenix.Controller.get_format(conn) == "html" and
      not is_nil(conn.assigns[:current_user])
  end

  defp halt_studio_refusal_page(conn) do
    conn
    |> put_status(403)
    |> Phoenix.Controller.html(studio_refusal_page())
    |> halt()
  end

  # Self-contained, no layout, no external assets — the SAME visual
  # convention `BarkparkWeb.ErrorHTML` uses for a plug-level page with
  # nothing rendered yet to lay it out inside. Every interpolated value here
  # is a static string; nothing from the request (workspace slug, refusal
  # reason) ever reaches this page, which is the point. A PLAIN string, not
  # `Phoenix.HTML.raw/1` — that marker is for EEx template interpolation
  # context; `Phoenix.Controller.html/2` takes a plain binary body directly
  # and raises on the `{:safe, _}` tuple `raw/1` would have produced here.
  defp studio_refusal_page do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Studio · Not a member</title>
        <style>
          :root {
            --err-bg: #0f1115;
            --err-fg: #e6e6e6;
            --err-muted: #9aa0a6;
            --err-accent: #5b8def;
          }
          body {
            font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
            background: var(--err-bg);
            color: var(--err-fg);
            display: flex;
            min-height: 100vh;
            margin: 0;
            align-items: center;
            justify-content: center;
          }
          main { text-align: center; padding: 2rem; max-width: 28rem; }
          h1 { font-size: 1.75rem; margin: 0 0 0.75rem; font-weight: 700; letter-spacing: -0.01em; }
          p { color: var(--err-muted); margin: 0 0 1.5rem; line-height: 1.5; }
          .actions { display: flex; gap: 0.75rem; justify-content: center; flex-wrap: wrap; }
          a.btn {
            display: inline-block;
            padding: 0.5rem 1rem;
            border-radius: 0.375rem;
            text-decoration: none;
            font-weight: 600;
          }
          a.btn-primary { background: var(--err-accent); color: #fff; }
          a.btn-secondary { background: transparent; color: var(--err-fg); border: 1px solid var(--err-muted); }
        </style>
      </head>
      <body>
        <main>
          <h1>You're not a member of this workspace</h1>
          <p>
            You're signed in, but this account doesn't have access here.
            Go to one of your own workspaces, or sign in as someone else.
          </p>
          <div class="actions">
            <a class="btn btn-primary" href="/">Go to your workspace</a>
            <a class="btn btn-secondary" href="/login">Sign in as someone else</a>
          </div>
        </main>
      </body>
    </html>
    """
  end

  defp halt_envelope(conn, reason) do
    env = Barkpark.Content.Errors.to_envelope(reason, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
