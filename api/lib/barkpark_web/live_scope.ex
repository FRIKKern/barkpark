defmodule BarkparkWeb.LiveScope do
  @moduledoc """
  URL-scope resolution + re-authorization for the scoped Studio
  (`/w/:workspace_slug/p/:project_slug/d/:dataset/studio/...` — P1 of the
  Scoped-by-URL arc, design: `/papers/studio-url-architecture`).

  ## Why params, not the session

  The `:scoped_browser` conn pipeline (ResolveWorkspace/ResolveProject)
  gates the DEAD render only — plugs never run for live navigation, and a
  `live_session`'s session MFA is computed once at dead-render time
  (see `BarkparkWeb.PluginScopeSession`), so it goes stale the moment a
  `push_patch` moves the socket to another `/w/:ws`. URL params are the
  only truth that travels with live navigation. This hook therefore:

    * `on_mount(:resolve)` — resolves the workspace/project structs from
      the mount params, authorizes the socket's token (`:read`,
      membership-gated; anonymous fails closed), assigns
      `current_workspace` / `current_project` (full structs — StudioLive
      reads `.slug` and feeds `Tenancy.list_projects/1`) plus
      `scope_prefix` (`"/w/<ws>/p/<proj>"`, consumed by `studio_path`).

    * attaches a `handle_params` hook that RE-resolves and
      RE-authorizes whenever a patch lands with different scope slugs —
      the cross-tenant seam the conn pipeline cannot see. The hook runs
      before the LiveView's own `handle_params`, so StudioLive's
      `ensure_tenancy_scope` (leave-if-set) always finds the
      URL-resolved scope already in place.

  Fail-closed: unknown slugs, project not under the workspace, no token,
  or a token without membership+read all redirect to `/login` (full HTTP
  navigation — never a silent in-socket fallback to another tenant).
  The anonymous-Default allowance (public demo / dev no-login) arrives
  with the P3 cutover; the share-grant arm (read-only shared Studio)
  with P4.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  import Phoenix.LiveView,
    only: [attach_hook: 4, redirect: 2, put_flash: 3, get_connect_info: 2]

  alias Barkpark.Access
  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.ReturnTo

  def on_mount(:resolve, params, _session, socket) do
    case resolve_and_authorize(socket, params) do
      {:ok, socket} ->
        {:cont, attach_hook(socket, :live_scope_reauth, :handle_params, &reauthorize/3)}

      {:halt, socket} ->
        {:halt, socket}
    end
  end

  # handle_params hook — only re-resolves when the URL's scope slugs differ
  # from the socket's current scope (same-scope patches are the hot path:
  # pane navigation, desk chips — zero extra queries for them).
  #
  # The DATASET is part of the scope, not just the workspace+project: shares and
  # access grants are dataset-SPECIFIC (`Sharing.shared?/4` matches `s.dataset`
  # exactly; `Access.admits_desk?/3` compares `dataset`), and `switch-dataset`
  # is an allowed `@readonly_event`, so a `:share_read` (or dataset-scoped grant)
  # socket can push_patch to an unshared sibling dataset in the SAME ws+proj.
  # Comparing only ws+proj here let that flip skip re-authorization and read the
  # unshared dataset (arpss-lv-dataset-switch-reauth). Including the dataset forces
  # `resolve_and_authorize/2` to re-derive the grade against the NEW dataset — the
  # unshared sibling is not shared → `deny/1` → /login, fail-closed. The extra
  # comparison is a map lookup, not a query, so the hot path (pane nav within one
  # dataset) still short-circuits; re-authorization fires ONLY on a real dataset
  # change.
  defp reauthorize(params, _uri, socket) do
    ws = socket.assigns[:current_workspace]
    proj = socket.assigns[:current_project]

    same_scope? =
      is_map(ws) and is_map(proj) and
        Map.get(ws, :slug) == params["workspace_slug"] and
        Map.get(proj, :slug) == params["project_slug"] and
        socket.assigns[:dataset] == params["dataset"]

    if same_scope? do
      {:cont, socket}
    else
      case resolve_and_authorize(socket, params) do
        {:ok, socket} -> {:cont, socket}
        {:halt, socket} -> {:halt, socket}
      end
    end
  end

  defp resolve_and_authorize(
         socket,
         %{"workspace_slug" => ws_slug, "project_slug" => proj_slug} = params
       )
       when is_binary(ws_slug) and is_binary(proj_slug) do
    with %{} = ws <- Tenancy.get_workspace_by_slug(ws_slug),
         %{} = proj <- Tenancy.get_project(ws_slug, proj_slug),
         {:ok, grade} <- authorize_read(socket, ws, proj, params["dataset"]) do
      socket =
        socket
        |> assign(
          current_workspace: ws,
          current_project: proj,
          scope_prefix: "/w/#{ws.slug}/p/#{proj.slug}",
          share_access: if(grade == :share_read, do: :read, else: nil)
        )
        |> assign_grant_scope(grade)

      {:ok, maybe_attach_readonly_gate(socket, grade)}
    else
      _ -> deny(socket)
    end
  end

  defp resolve_and_authorize(socket, _params), do: deny(socket)

  # Membership + read permission via the canonical gate. Anonymous (nil
  # token) is allowed into: (a) the seeded Default workspace — the
  # socket-side mirror of ResolveWorkspace's :allow_anonymous_default
  # (P3, flat-parity demo/dev posture); or (b) a `:docs`-SHARED scope
  # (P4) — READ-ONLY, enforced by the handle_event gate this grade
  # attaches. Any other anonymous scope fails closed, and this arm is
  # what stops a LIVE patch from an authorized scope into a foreign one.
  defp authorize_read(socket, ws, proj, dataset) do
    case socket.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token ->
        case Tenancy.Auth.authorize(token, ws.id, :read) do
          :ok -> {:ok, :member}
          err -> err
        end

      _ ->
        # Access-grant admission (airdrop-grants ag-enforcement) — the socket
        # twin of ResolveWorkspace's grant path. Computed ONCE here (a DB load
        # of the user's active grants) and offered as the LAST cond clause.
        # Validated against the MOUNTED DESK scope (workspace + project +
        # dataset from the URL), NOT bare workspace — so a project/dataset/type/
        # doc-scoped grantee can mount the desk AT OR UNDER its grant, and
        # `scope_to_grants` narrows the rows to the grant (ag-…-subscope).
        grant_ctx = grant_read_ctx(socket.assigns[:current_user], desk_scope(ws, proj, dataset))

        cond do
          # studio-user-login: an account session (:current_user, set by
          # LiveAuth.:fetch_api_token) is a User principal — same authorize/3
          # chokepoint, the membership role is the grant. A signed-in user
          # WITHOUT a membership falls through to the anonymous allowances
          # below (signed in never grants less than anonymous).
          match?(%Barkpark.Accounts.User{}, socket.assigns[:current_user]) and
              Tenancy.Auth.authorize(socket.assigns[:current_user], ws.id, :read) == :ok ->
            {:ok, :member}

          # The Default demo allowance only while the public-demo flag is on
          # (studio-anonymous-default-lockdown — prod requires a sign-in;
          # flag-off falls through to the share arm, then deny → /login).
          Application.get_env(:barkpark, :public_demo_studio, false) and
              match?(%{id: id} when id == ws.id, Tenancy.get_default_workspace()) ->
            {:ok, :anonymous_default}

          Barkpark.Sharing.shared?(ws.slug, proj.slug, dataset || "production", :docs) ->
            {:ok, :share_read}

          # Grant arm, LAST before forbidden. ONLY a non-member signed-in USER
          # with an ACTIVE grant authorizing :read here (fail-closed nil ⇒ skip).
          # Ordered after the member / anonymous-default / share arms so a
          # grantee who ALSO qualifies for broader public access keeps it
          # UNNARROWED — grants only ADD access, never REMOVE it. The
          # grant-bearing ctx rides the grade → `scope_to_grants` narrows reads
          # to the grant ladder (via the :grant_scoped_read flag) and the write
          # gate is decided in `resolve_and_authorize`.
          not is_nil(grant_ctx) ->
            {:ok, {:grant, grant_ctx}}

          true ->
            {:error, :forbidden}
        end
    end
  end

  # Build a grant-bearing CallerContext for `user` and admit it ONLY if some
  # ACTIVE grant admits the MOUNTED DESK scope for :read. Returns the ctx (to
  # ride the grade) or nil. Twin of ResolveWorkspace.grant_read_ctx/2 —
  # `from_user/2` loads active grants in-query; `Access.admits_desk?/3` applies
  # scope+capability+expiry at desk granularity (type/doc narrowed later by
  # `scope_to_grants`). Fail-closed: no admitting grant → nil.
  defp grant_read_ctx(%Barkpark.Accounts.User{id: uid}, desk_scope)
       when is_binary(uid) and is_map(desk_scope) do
    ctx = CallerContext.from_user(uid)

    if Enum.any?(ctx.grants, &(Access.admits_desk?(&1, :read, desk_scope) == true)) do
      ctx
    end
  end

  defp grant_read_ctx(_user, _desk_scope), do: nil

  # The mounted desk scope (workspace/project/dataset granularity) — the URL the
  # grantee is mounting. `proj` is always a resolved struct here (the caller's
  # `with` matched it); `dataset` is the `/d/:dataset` segment. Fed to
  # `Access.admits_desk?/3`, which compares it against each grant.
  defp desk_scope(ws, proj, dataset) do
    scope = %{workspace_id: ws.id, project_id: Map.get(proj, :id)}
    if is_binary(dataset), do: Map.put(scope, :dataset, dataset), else: scope
  end

  # Read-only shared Studio (P4): a `:docs` read share opens the FULL
  # Studio UI to an anonymous viewer, so the write boundary must be the
  # SERVER's event handler, not hidden buttons. Deny-by-default: only
  # navigation/inspection events pass; everything else (autosave, save,
  # publish, delete, create, uploads, array ops, share admin, …) is
  # halted with a flash. The gate attaches once per mount of a
  # share-graded socket; member and anonymous-Default sockets never get it.
  @readonly_events ~w(
    select select-group select-desk select-pane
    switch-workspace switch-project switch-dataset
    scope-menu-toggle scope-menu-close scope-menu-ws scope-menu-proj scope-open
    jump-to-user show-profile preview-profile close-profile
    toggle-content-preview toggle-diff toggle-category
    editor-set-mode search ref-search validate-upload
  )

  defp maybe_attach_readonly_gate(socket, :share_read),
    do: attach_readonly_gate(socket, "This workspace is shared read-only")

  # Grant write-containment (airdrop-grants ag-enforcement). `scope_to_grants`
  # narrows READS only — Studio write handlers do not gate on :write. Three
  # dispositions for a grant-admitted socket, decided ONCE here per workspace:
  #
  #   * NO write-capable grant in this workspace → read-only: the deny-by-default
  #     `@readonly_events` allowlist halts every mutating event (unchanged).
  #   * SOME write-capable grant (workspace-wide OR sub-scoped) → the per-event
  #     write-narrowing gate: each mutating event's TARGET scope must be ⊆ one of
  #     the ctx's write grants, reusing `Access.validate/3` (the same containment
  #     the read narrowing uses — no parallel ladder). This is the follow-on to
  #     #1353: it both NARROWS a write-capable grantee to its sub-scope (the
  #     reported residual — writing OUTSIDE the grant is now denied) and, for a
  #     PURELY sub-scoped write grant (e.g. project-scoped), lets it write WITHIN
  #     that grant — the completeness case that previously fell to the read-only
  #     gate and could not write anywhere.
  #
  # `has_write_grant?` is deliberately BROADER than `authorize(ctx, ws, :write)`
  # (which only sees workspace-WIDE write): the difference is exactly the
  # sub-scoped-write completeness case. A workspace-WIDE write grant still admits
  # every in-workspace target (its ladder halts at the workspace level) → the
  # narrowing gate is a byte-identical no-op for it.
  defp maybe_attach_readonly_gate(socket, {:grant, ctx}) do
    ws = socket.assigns[:current_workspace]

    if has_write_grant?(ctx, ws.id) do
      attach_write_gate(socket, ctx)
    else
      attach_readonly_gate(socket, "Your access grant is read-only")
    end
  end

  defp maybe_attach_readonly_gate(socket, _grade), do: socket

  # True when `ctx` holds at least one ACTIVE grant conferring :write SOMEWHERE
  # within `ws_id` — workspace-wide OR any sub-scope. Reuses `Access.validate/3`
  # against each grant's OWN full scope (trivially contained), so revoked /
  # expired / non-write grants are excluded by the same fail-closed logic the
  # per-event gate uses.
  defp has_write_grant?(%{grants: grants}, ws_id) when is_binary(ws_id) and is_list(grants) do
    Enum.any?(grants, fn grant ->
      grant.workspace_id == ws_id and
        Access.validate(grant, :write, grant_scope(grant)) == :ok
    end)
  end

  defp has_write_grant?(_ctx, _ws_id), do: false

  defp grant_scope(grant) do
    %{
      workspace_id: grant.workspace_id,
      project_id: grant.project_id,
      dataset: grant.dataset,
      type: grant.type,
      doc_id: grant.doc_id
    }
  end

  # Deny-by-default write-narrowing gate for a write-conferring grant ctx.
  # Navigation/inspection events (@readonly_events) always pass. Every MUTATING
  # event's TARGET scope must be ⊆ some write grant's ladder via `Access.validate/3`.
  # Fail-closed: an unresolved target halts. Idempotent across re-resolves
  # (a live patch re-runs this; attach_hook raises on a duplicate name). Like the
  # read-only gate, a stale gate that later patches into a broader scope only
  # over-restricts — never under-restricts — so we keep it once attached (the
  # target is read from LIVE socket assigns, so same-user cross-scope patches are
  # re-checked against the current mount; only the captured grant set is stale).
  defp attach_write_gate(socket, ctx) do
    if socket.assigns[:write_gate?] do
      socket
    else
      socket
      |> assign(:write_gate?, true)
      |> attach_hook(:live_scope_write_scope, :handle_event, fn event, params, socket ->
        cond do
          event in @readonly_events ->
            {:cont, socket}

          write_target_permitted?(ctx, event, params, socket) ->
            {:cont, socket}

          true ->
            {:halt, put_flash(socket, :error, "That action is outside your access grant's scope")}
        end
      end)
    end
  end

  defp write_target_permitted?(ctx, event, params, socket) do
    case write_target(event, params, socket) do
      {:ok, target} ->
        Enum.any?(ctx.grants, &(Access.validate(&1, :write, target) == :ok))

      :error ->
        false
    end
  end

  # Resolve the TARGET scope a mutating `event` writes to, from the current mount
  # + event params + the loaded editor doc. Broad→narrow ladder keys, fed straight
  # into `Access.validate/3`. Fail-closed: an unresolvable mount → :error → HALT.
  #
  #   * create-workspace / create-project mint SIBLING tenancy — a workspace-level
  #     target (no project) so ONLY a workspace-wide write grant admits them
  #     (byte-identical to the old un-gated pass); any sub-scoped grant denies.
  #   * new-document creates a doc of `params["type"]` in the current
  #     project/dataset — type from params, doc_id nil (a type/project/dataset
  #     grant admits; a doc-scoped grant can't create).
  #   * every other mutating event acts on the CURRENTLY LOADED doc — its type +
  #     canonical doc_id refine the target so a doc-scoped write grant admits its
  #     own doc. With no doc loaded (bulk / schema / profile ops) the target stays
  #     at project/dataset granularity.
  defp write_target(event, params, socket) do
    ws = socket.assigns[:current_workspace]
    proj = socket.assigns[:current_project]
    dataset = socket.assigns[:dataset]

    cond do
      not (is_map(ws) and is_binary(Map.get(ws, :id))) ->
        :error

      event in ~w(create-workspace create-project) ->
        {:ok, %{workspace_id: ws.id}}

      not (is_map(proj) and is_binary(Map.get(proj, :id)) and is_binary(dataset)) ->
        :error

      true ->
        base = %{workspace_id: ws.id, project_id: proj.id, dataset: dataset}
        {:ok, Map.merge(base, doc_scope(event, params, socket))}
    end
  end

  # type/doc_id refinement of the target scope.
  defp doc_scope("new-document", %{"type" => type}, _socket) when is_binary(type),
    do: %{type: type}

  defp doc_scope(_event, _params, socket) do
    case socket.assigns do
      %{editor_type: type, editor_doc: %{doc_id: doc_id}}
      when is_binary(type) and is_binary(doc_id) ->
        %{type: type, doc_id: Content.published_id(doc_id)}

      _ ->
        %{}
    end
  end

  # Deny-by-default write gate: only @readonly_events pass; every mutating
  # event is halted with a flash. Idempotent across re-resolves (a live patch
  # re-runs this; attach_hook raises on a duplicate name). A stale gate that
  # later patches into a broader scope only over-restricts — never
  # under-restricts — so we keep it once attached.
  defp attach_readonly_gate(socket, message) do
    if socket.assigns[:readonly_gate?] do
      socket
    else
      socket
      |> assign(:readonly_gate?, true)
      |> attach_hook(:live_scope_readonly, :handle_event, fn event, _params, socket ->
        if event in @readonly_events do
          {:cont, socket}
        else
          {:halt, put_flash(socket, :error, message)}
        end
      end)
    end
  end

  # Assign the grant-bearing ctx + the row-narrowing flag for a grant-admitted
  # socket. `ScopeHelpers.scope_opts/1` reads both → threads `grant_scoped: true`
  # + the ctx into every read → `Content.Scope.scope_to_grants/3` narrows to the
  # grant ladder. Members / anonymous / share sockets are untouched (no flag,
  # no narrowing — byte-identical to today).
  defp assign_grant_scope(socket, {:grant, ctx}) do
    socket
    |> assign(:caller_context, ctx)
    |> assign(:grant_scoped_read, true)
  end

  defp assign_grant_scope(socket, _grade), do: socket

  defp deny(socket) do
    {:halt,
     socket
     |> put_flash(:error, "Not authorized for that workspace")
     |> redirect(to: login_target(socket))}
  end

  # D69 — carry the requested scoped Studio URL as a validated `return_to` so a
  # dead-render denial round-trips back after sign-in (the same funnel the
  # anonymous ResolveWorkspace plug already builds, extended to the socket gate).
  # A connected re-auth denial has no request URI → bare `/login`, unchanged.
  defp login_target(socket) do
    with %URI{path: path} = uri when is_binary(path) <- requested_uri(socket),
         dest when is_binary(dest) <- ReturnTo.sanitize_dest(path <> query_suffix(uri.query)) do
      ReturnTo.with_return_to("/login", dest)
    else
      _ -> "/login"
    end
  end

  defp requested_uri(socket) do
    get_connect_info(socket, :uri)
  rescue
    _ -> nil
  end

  defp query_suffix(query) when is_binary(query) and query != "", do: "?" <> query
  defp query_suffix(_query), do: ""
end
