defmodule BarkparkWeb.PaperViewer do
  @moduledoc """
  `on_mount` hook for the paper reader (`BarkparkWeb.BulldocsLive`): the
  reader learns WHO is viewing, so a later slice can decide WHAT they may do
  on the page (epic task-a19eeb215f653529, "Edit on the link"; this is slice
  1, task-0c242c8dc61f6b13).

  ## What it does

  Reads the signed LiveView session and resolves every credential a browser
  can arrive with, then assigns:

    * `:current_user` — the `%Barkpark.Accounts.User{}` behind a
      `session["user_session"]` cookie, or `nil`;
    * `:api_token` — the verified `%Barkpark.Auth.ApiToken{}` behind
      `session["api_token"]` (or, in dev only, the seeded
      `:dev_browser_token`), or `nil`;
    * `:api_token_raw` — the RAW string behind that verified token, or `""`.
      Mirrors `BarkparkWeb.LiveAuth.on_mount(:fetch_api_token, …)`: the
      client-side editor bridges (`data-token=…`) need the raw credential the
      browser already presented, and slice 2's editor passes it straight to
      `paper_block_editor/1`. Only ever set for a token that VERIFIED, so an
      unverifiable string is `""`, never echoed back;
    * `:viewer` — a small scalar summary of the principal the page should
      treat as "you": `%{kind: :user | :token | :share | :anonymous, ...}`
      (see `viewer/3`);
    * `:paper_share_grant` — the independently resolved, live item-share grant
      (including project and dataset confinement), or the read-only section
      fallback. This stays separate from `:viewer`, so an authenticated human
      keeps user attribution while a link may still grant this paper edit;
    * `:can_edit?` — ALWAYS `false` here. The paper's workspace is not known
      until `BulldocsLive.mount/3` resolves the paper, so the LiveView calls
      `can_edit?/3` itself once it has the paper scope and slug.

  ## What it never does

  It never halts. Anonymous mounts pass through with `viewer: %{kind:
  :anonymous}` and every other assign `nil`/`false`, so the public reader's
  anonymous render is byte-identical to before this hook existed (the
  `LiveViewMountAuthzCensusTest` public-tier row stays true). Denials are the
  business of `BarkparkWeb.PluginScopeSession` (item-share confinement) and,
  later, of the edit-mode event allowlist — not of this hook.

  ## Precedence

  Mirrors `BarkparkWeb.LiveAuth.on_mount(:fetch_api_token, …)`: the account
  session and the api-token session are resolved INDEPENDENTLY and both
  assigned. For the `:viewer` summary the account wins (a human identity is
  the one attribution wants); for `can_edit?/2` EITHER credential authorizing
  `:write` on the paper's workspace suffices, because each is an independently
  valid credential the browser legitimately presented.

  The dev fallback is the same idiom as LiveAuth: the CONFIG KEY is the
  switch, never `Mix.env()` (gh-8461 — `Mix` is absent in a release).
  `:dev_browser_token` is set only in `config/dev.exs`, so test stays
  fail-closed and prod never carries it.

  ## Share grants

  A mount whose session records an anonymous share grant
  (`PluginScopeSession.build/1` wrote `scoped_share_public`) resolves to
  `%{kind: :share, grant: :item | :section, id:, access:, ref_id:,
  workspace_id:}` for attribution and independently stores the full grant,
  including project and dataset, in `:paper_share_grant`. The item arm carries
  the LINK's own access level and resource scope, read off the LIVE row every
  mount and every liveness tick. A user or token remains the attributed viewer
  when both credentials are present; the share capability is still evaluated.

  `can_edit?/2` stays credential-only and is `false` for EVERY share viewer:
  it knows the paper's workspace but not its slug, and an item link that
  binds a sibling paper in the same workspace must never grade writable.
  Slice 3 (task-8ac4f3918da1c433) adds `can_edit?/3`, which takes the mounted
  SLUG as well and grants an item share exactly one extra way: access `:edit`
  AND `ref_id == slug` AND the link's workspace/project/dataset match the
  mounted paper scope. That is an EXTENSION of this hook, not a bypass — the
  credential arm is unchanged, and a share grant never reaches `Tenancy.Auth`.

  ## What a share-edit grant is NOT

  It is not write permission. No membership row is created, no `%ApiToken{}`
  exists, and `Tenancy.Auth.permits?/2` never learns about share-edit (the
  June ruling behind `share-edit` tokens). The ONLY thing an item edit link
  opens is the reader's own LiveView op path for the ONE slug it binds:
  `POST /v1/data/mutate/:dataset` rejects the raw link token outright (it is
  not an api token), and Studio never sees it as a credential.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Barkpark.Accounts
  alias Barkpark.Accounts.User
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Sharing.Links
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # The same keys `BarkparkWeb.PluginScopeSession.build/1` writes. Read here,
  # never written.
  @session_share_public "scoped_share_public"
  @session_share_token "scoped_share_token"
  @session_share_access "scoped_share_access"

  @anonymous %{kind: :anonymous}

  # A share grant that is NOT a resolvable item link: the section-share arm,
  # which grants the whole scope for READS and never edits.
  @section_viewer %{
    kind: :share,
    grant: :section,
    id: nil,
    access: :read,
    ref_id: nil,
    workspace_id: nil
  }

  @typedoc "The scalar principal summary the reader carries as `@viewer`."
  @type viewer ::
          %{kind: :anonymous}
          | %{kind: :user, id: binary(), label: String.t() | nil}
          | %{kind: :token, id: binary(), label: String.t() | nil}
          | %{
              kind: :share,
              grant: :item | :section,
              id: binary() | nil,
              access: :read | :edit,
              ref_id: binary() | nil,
              workspace_id: binary() | nil
            }

  @doc "The anonymous viewer — what a mount without this hook should assume."
  @spec anonymous() :: viewer()
  def anonymous, do: @anonymous

  def on_mount(:viewer, _params, session, socket) do
    user = user_from_session(session)
    {token, raw} = token_from_session(session)
    share_grant = resolve_share_grant(session)

    {:cont,
     socket
     |> assign(:current_user, user)
     |> assign(:api_token, token)
     |> assign(:api_token_raw, raw)
     |> assign(:viewer, principal_viewer(user, token, share_grant))
     |> assign(:paper_share_grant, share_grant)
     |> assign(:can_edit?, false)}
  end

  # ── Scoped reader admission, re-run on every socket mount (r4a) ───────────
  #
  # The router pipeline (`ResolveWorkspace`, allow_anonymous_default: true)
  # admits a scoped-reader dead render for a member, an anonymous visitor of
  # the Default workspace, or a non-member user holding an active read grant.
  # A socket mounts again on live_redirect, reconnect, or a join replaying the
  # signed session (~14 days), and none of those run the pipeline — so a
  # member REMOVED from the workspace kept reading its papers. This hook re-asks
  # the same three questions on every mount. Share-granted sessions are left to
  # `PluginScopeSession`, which re-checks item links and section shares itself.
  # Runs AFTER `:viewer` (it reads that hook's `:current_user` / `:api_token`).
  #
  # Skipped on the DEAD render: the pipeline has just admitted that exact
  # request (possibly by an `Authorization: Bearer` header this session-only
  # hook cannot see). Skipped too when the URL names another workspace than
  # the session: `PluginScopeSession` then sends the browser back through HTTP
  # for that URL, which is the stronger answer.
  def on_mount(:scoped_admission, params, session, socket) do
    case socket.assigns[:current_workspace] do
      %{id: ws_id} = ws when is_binary(ws_id) ->
        if not Phoenix.LiveView.connected?(socket) or
             url_names_other_workspace?(params, ws) or
             session[@session_share_public] == true or
             scoped_read_admitted?(socket.assigns, ws_id, session["scoped_project_id"]) do
          {:cont, socket}
        else
          {:halt,
           socket
           |> Phoenix.LiveView.put_flash(:error, "You no longer have access to this workspace")
           |> Phoenix.LiveView.redirect(to: "/login")}
        end

      _ ->
        {:cont, socket}
    end
  end

  defp url_names_other_workspace?(%{"workspace_slug" => slug}, %{slug: ws_slug})
       when is_binary(slug) and is_binary(ws_slug),
       do: slug != ws_slug

  defp url_names_other_workspace?(_params, _ws), do: false

  defp scoped_read_admitted?(assigns, ws_id, project_id) do
    token = assigns[:api_token]
    user = assigns[:current_user]

    TenancyAuth.authorize(token, ws_id, :read) == :ok or
      (match?(%User{}, user) and TenancyAuth.authorize(user, ws_id, :read) == :ok) or
      (is_nil(token) and default_workspace_id?(ws_id)) or
      grant_admits_read?(user, ws_id, project_id)
  end

  defp default_workspace_id?(ws_id) do
    match?(%{id: ^ws_id}, Barkpark.Tenancy.get_default_workspace())
  end

  # Same admission as `ResolveWorkspace.grant_read_ctx/2`: an ACTIVE grant that
  # admits the mounted desk (workspace + project; the reader route has no
  # dataset segment) for :read.
  defp grant_admits_read?(%User{id: uid}, ws_id, project_id) when is_binary(uid) do
    desk =
      if is_binary(project_id),
        do: %{workspace_id: ws_id, project_id: project_id},
        else: %{workspace_id: ws_id}

    uid
    |> Barkpark.Access.list_active_grants_for_grantee()
    |> Enum.any?(&(Barkpark.Access.admits_desk?(&1, :read, desk) == true))
  end

  defp grant_admits_read?(_user, _ws_id, _project_id), do: false

  @doc """
  Whether the mounted viewer may EDIT a paper owned by `workspace_id`.

  Takes the socket assigns (so a LiveView mounted WITHOUT the hook degrades to
  `false` rather than crashing) and the paper's workspace id. Fail-closed on
  every unknown shape. The decision is `Barkpark.Tenancy.Auth.authorize/3` with
  action `:write` — the single chokepoint that requires BOTH a membership row
  and (for tokens) the `write` permission — and nothing else.
  """
  @spec can_edit?(map(), binary() | nil) :: boolean()
  def can_edit?(assigns, workspace_id) when is_map(assigns) and is_binary(workspace_id) do
    principals =
      [Map.get(assigns, :current_user), Map.get(assigns, :api_token)]
      |> Enum.filter(&match?(%{__struct__: s} when s in [User, ApiToken], &1))

    Enum.any?(principals, &(TenancyAuth.authorize(&1, workspace_id, :write) == :ok))
  end

  def can_edit?(_assigns, _workspace_id), do: false

  @doc """
  Whether the mounted viewer may EDIT the paper `slug` owned by `workspace_id`.

  The 3-arity the reader actually calls. It is `can_edit?/2` (the credential
  arm, unchanged) OR the ONE extra grant slice 3 adds: an ITEM share link whose
  live row carries `access: "edit"`, binds exactly THIS slug, and belongs to
  THIS paper's workspace, project, and dataset. Every bound dimension must
  hold; a link bound to a sibling paper in the same workspace grades false,
  which is why the slug has to reach here at all.

  Nothing about this arm touches `Barkpark.Tenancy.Auth`: a share grant has no
  membership row and no permission list, and gaining one would make the flat
  `POST /v1/data/mutate/:dataset` reachable. The grant is confined to the
  reader's own op path by construction.
  """
  @spec can_edit?(map(), binary() | nil, binary() | nil) :: boolean()
  def can_edit?(assigns, workspace_id, slug) do
    can_edit?(assigns, workspace_id) or share_can_edit?(assigns, workspace_id, slug)
  end

  defp share_can_edit?(assigns, workspace_id, slug)
       when is_map(assigns) and is_binary(workspace_id) and is_binary(slug) do
    case Map.get(assigns, :paper_share_grant) do
      %{
        grant: :item,
        access: :edit,
        ref_id: ref_id,
        workspace_id: link_ws,
        project_id: link_project,
        dataset: link_dataset
      } ->
        ref_id == slug and
          link_ws == workspace_id and
          scope_id(Map.get(assigns, :current_project)) == link_project and
          Map.get(assigns, :dataset) == link_dataset

      _ ->
        false
    end
  end

  defp share_can_edit?(_assigns, _workspace_id, _slug), do: false

  @doc false
  @spec viewer(User.t() | nil, ApiToken.t() | nil, map()) :: viewer()
  def viewer(user, token, session),
    do: principal_viewer(user, token, resolve_share_grant(session))

  defp principal_viewer(%User{id: id} = user, _token, _share_grant),
    do: %{kind: :user, id: id, label: Map.get(user, :email)}

  defp principal_viewer(nil, %ApiToken{id: id} = token, _share_grant),
    do: %{kind: :token, id: id, label: token.name || token.label}

  defp principal_viewer(nil, nil, %{kind: :share} = share_grant),
    do: viewer_share_grant(share_grant)

  defp principal_viewer(_user, _token, _share_grant), do: @anonymous

  @doc false
  def resolve_share_grant(session) when is_map(session) do
    if session[@session_share_public] == true do
      share_grant(session[@session_share_token], session[@session_share_access])
    else
      nil
    end
  end

  def resolve_share_grant(_session), do: nil

  @doc false
  def refresh_share_capability(socket, session) do
    grant = resolve_share_grant(session)
    was_writable? = Map.get(socket.assigns, :can_edit?) == true

    socket =
      socket
      |> assign(:paper_share_grant, grant)
      |> refresh_share_viewer(grant)

    with %{id: workspace_id} when is_binary(workspace_id) <-
           Map.get(socket.assigns, :current_workspace),
         slug when is_binary(slug) <- Map.get(socket.assigns, :slug),
         true <- Map.has_key?(socket.assigns, :can_edit?) do
      socket = assign(socket, :can_edit?, can_edit?(socket.assigns, workspace_id, slug))
      maybe_restore_reader(socket, was_writable?)
    else
      _ -> socket
    end
  end

  defp maybe_restore_reader(socket, true) do
    if socket.assigns[:can_edit?] == false and socket.assigns[:editing?] == true do
      socket
      |> assign(:editing?, false)
      |> BarkparkWeb.BulldocsLive.refetch()
    else
      socket
    end
  end

  defp maybe_restore_reader(socket, _was_writable?), do: socket

  defp refresh_share_viewer(socket, grant) do
    case Map.get(socket.assigns, :viewer) do
      %{kind: :share} -> assign(socket, :viewer, viewer_share_grant(grant))
      _ -> socket
    end
  end

  defp viewer_share_grant(%{kind: :share} = grant) do
    Map.take(grant, [:kind, :grant, :id, :access, :ref_id, :workspace_id])
  end

  defp viewer_share_grant(_grant), do: @anonymous

  # The item arm reads the LIVE row every mount (`Links.resolve/1` filters
  # revoked + expired), so a revoked edit link resolves to nothing and falls to
  # the section arm, which is read-only.
  defp share_grant(raw, session_access) when is_binary(raw) and raw != "" do
    case Links.resolve(raw) do
      {:ok, link} ->
        %{
          kind: :share,
          grant: :item,
          id: link.id,
          access: effective_access(link.access, session_access),
          ref_id: link.ref_id,
          workspace_id: link.workspace_id,
          project_id: link.project_id,
          dataset: link.dataset
        }

      _ ->
        @section_viewer
    end
  end

  defp share_grant(_raw, _session_access), do: @section_viewer

  defp scope_id(%{id: id}) when is_binary(id), do: id
  defp scope_id(_scope), do: nil

  # An INTERSECTION, not a lookup: the grant is `:edit` only when the LIVE row
  # says edit AND the dead render that signed this session recorded edit. Either
  # half alone is enough to fall back to `:read`, which is the fail-closed
  # answer for a session minted before an access change or for a row edited
  # underneath an open socket.
  defp effective_access("edit", "edit"), do: :edit
  defp effective_access(_link_access, _session_access), do: :read

  defp user_from_session(session) do
    case session["user_session"] do
      raw when is_binary(raw) and raw != "" ->
        case Accounts.verify_user_session(String.trim(raw)) do
          {%User{} = user, _} -> user
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # `{token, raw}` — the verified struct and the raw string it verified from.
  # `{nil, ""}` for every absent / unverifiable credential, so the raw value is
  # never echoed back for a token the server did not accept.
  defp token_from_session(session) do
    raw =
      case session["api_token"] do
        raw when is_binary(raw) and raw != "" -> raw
        _ -> dev_browser_token_fallback()
      end

    with raw when is_binary(raw) <- raw,
         {:ok, %ApiToken{} = token} <- Auth.verify_token(raw) do
      {token, raw}
    else
      _ -> {nil, ""}
    end
  end

  defp dev_browser_token_fallback do
    case Application.get_env(:barkpark, :dev_browser_token) do
      raw when is_binary(raw) and raw != "" -> raw
      _ -> nil
    end
  end
end
