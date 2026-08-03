defmodule BarkparkWeb.Studio.Caps do
  @moduledoc """
  Capability map + server-side event deny-gate for the Studio LiveView
  (airdrop-grants `ag-studio-capability-hide`).

  ## The `@caps` map

  `derive/1` computes `%{read: bool, write: bool, admin: bool}` for the mounted
  desk scope, from TWO arms unioned:

    * **membership** — `Tenancy.Auth`'s own decision for each principal the
      socket carries (`api_token` and/or `current_user`), read off ONE
      membership row loaded per principal and reused for `:read`/`:write`/
      `:admin` (pds-w43 — three byte-identical `Repo.one`s collapsed to one);
      nil-safe (no principal ⇒ that arm is false).
    * **grants** — each ACTIVE access-grant admitting the desk via
      `Access.admits_desk?(grant, action, desk)`. Grants are RELOADED FRESH
      (`Access.list_active_grants_for_grantee/1`, active-filtered in-query) on
      every `derive/1`, so a grant that expired mid-session drops its cap the
      next time the gate reads it — no stale mount-time assign.

  `admin` is deliberately NEVER grant-conferred (a grant confers working
  access, not tenant control — `Access` only ever mints read/write). Its arm is
  exactly `StudioChrome.admin?/2`: an `admin`-permissioned api_token OR an
  account with the `:admin` role on the workspace.

  ## The deny-gate (`attach/1`) — hidden ≠ denied

  Hiding an affordance is cosmetic; the SERVER gate is the enforcement. The gate
  attaches on EVERY StudioLive socket (in `StudioLive.mount`), classifies each
  event, and HALTs a forged event whose required cap the caller lacks —
  **default-DENY**: an unclassified event requires `admin` (fails closed),
  never passes. Caps are RE-DERIVED server-side inside the gate so mid-session
  grant expiry denies immediately.

  Tiers (`classify/1`):

    * `:none` — safe nav / read / local-UI events (explicit allowlist).
    * `:read` — held-cap-gated share flows (the airdrop sheet; the handler +
      `Access.mint/2` re-check no-escalation).
    * `:write` — every mutation (save/publish/delete/paper-ops/…), incl.
      `access-revoke` (the Access panel's one-click revoke; `Access.revoke/2`
      re-authorizes grantor-or-admin server-side regardless of this gate).
    * `:admin` — share / item-share (tenant-control) events.
    * `:deny` — the DEFAULT for any event not in a set above → require `admin`.

  Enforcement per tier:

    * `:admin` / `:deny` — enforced on ALL sockets: `caps.admin` required.
    * `:write` — a write-capable socket passes. Otherwise a RESTRICTED socket
      (share-read / grant grade) is denied AND a socket carrying a read-only
      PRINCIPAL (api_token and/or current_user) is denied — closing the hole
      where a read-only API-token member rode the `not restricted?`
      short-circuit. Only a principal-less socket falls through, i.e. the
      intentionally-open anonymous public-demo posture. Grant expiry truth
      still comes from the fresh `derive/1`.
    * `:none` / `:read` — pass.

  The per-handler `caps.admin` re-check in `Handlers.Shares`/`Handlers.ItemShare`
  stays as defense-in-depth (`admin?/1`).
  """

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  alias Barkpark.Access
  alias Barkpark.Tenancy

  # ── event classification (default-DENY: unclassified ⇒ :deny) ───────────────

  # Safe: navigation, read, and purely-local UI toggles. No capability required.
  @safe_events ~w(
    select select-group select-desk select-pane expand-pane
    switch-workspace switch-project switch-dataset toggle-create
    scope-menu-toggle scope-menu-close scope-menu-ws scope-menu-proj scope-open
    jump-to-user show-profile preview-profile close-profile
    toggle-content-preview toggle-diff toggle-category editor-set-mode
    width-bucket
    search ref-search validate-upload reload-remote-doc
    open-image-picker close-image-picker open-ref-picker close-ref-picker
    show-history close-history close-delete close-discard
    close-unpublish-guard close-confirm-modal
    open-secondary-picker close-secondary-picker secondary-search
    select-secondary close-secondary view-graph
    sidebar-toggle-panel sidebar-toggle-section
    backlinks-refresh open-backlink paper-wikilink-search paper-tag-search
    task-preview-refresh paper-valueref-inspect valueref-writeback-close
    paper-toggle-edit bulk-clear shares-close item-share-close
    airdrop-close airdrop-suggest
    access-open access-close
  )

  # Held-capability share flows — the handler + Access.mint/2 re-check
  # no-escalation, so the gate only requires the caller be able to read here.
  @read_events ~w(airdrop-open airdrop-create)

  # Admin (tenant-control): the network-shares panel + per-item share popover.
  @admin_events ~w(
    shares-open shares-add shares-remove
    item-share-open item-share-create item-share-revoke
  )

  # Mutations — every event that writes persisted state. Everything NOT listed
  # in a set above ALSO falls here-or-stricter via the :deny default, so a new
  # unclassified event fails closed (require admin) until explicitly classified.
  @write_events ~w(
    create-workspace create-project new-document save slug-generate autosave
    array_op select-media clear-image upload-image select-ref clear-ref
    restore-revision save-profile delete-doc confirm-delete
    discard-draft confirm-discard publish unpublish confirm-unpublish
    duplicate-doc toggle-doc-checkbox bulk-publish bulk-unpublish
    schema_action confirm-modal-dryrun confirm-modal-real
    paper-edit-block paper-block-autosave sidebar-slug-change
    paper-op paper-ops valueref-accept-baseline paper-add-block
    paper-materialize-slot paper-slash-insert paper-add-property
    paper-unbind-property paper-delete-block paper-move-block
    paper-move-block-to paper-callout-fold valueref-writeback-confirm
    access-revoke
  )

  @doc """
  Classify a Studio `phx` event into its required-capability tier. DEFAULT-DENY:
  any event not in an explicit set returns `:deny` (⇒ require admin). The
  comprehensiveness test asserts every live `handle_event` head classifies to a
  known tier (never `:deny`), so a new ungated privileged event trips CI.
  """
  @spec classify(String.t()) :: :none | :read | :write | :admin | :deny
  def classify(event) when is_binary(event) do
    cond do
      event in @safe_events -> :none
      event in @read_events -> :read
      event in @admin_events -> :admin
      event in @write_events -> :write
      true -> :deny
    end
  end

  def classify(_), do: :deny

  # ── capability derivation ───────────────────────────────────────────────────

  @doc """
  Compute `%{read, write, admin}` for the socket's mounted desk. Grants are
  reloaded fresh (expiry-truth). Safe when the workspace/desk is unresolved.

  ## ONE membership load, three actions (pds-w43, PDS-D634)

  This function used to ask `Tenancy.Auth.authorize/3` three times per
  principal — `:read`, `:write`, and `admin?/1`'s `:admin` — and each of those
  issues its own BYTE-IDENTICAL `Tenancy.Auth.membership/2` `Repo.one`. On the
  autosave path `derive/1` runs TWICE per event (the socket gate, then
  `Shared.Paper.write_denied?/1`), so a debounced keystroke cost 8 round-trips.
  The membership row is now loaded ONCE per principal and the three decisions
  are read off it — a USER-principal derive is 2 queries (was 4), an
  API-TOKEN one is 1 (was 2).

  What did NOT change: the grant `Repo.all` (`active_grants/1`) is still
  UNCONDITIONAL and still per-`derive/1` — it is the load that buys mid-session
  expiry truth, and there is deliberately NO TTL memo across ops. The decision
  logic is `Tenancy.Auth`'s own (`permits?/2` for tokens, `role_permits?/3` for
  users), read off the same row `authorize/3` would have loaded, so the answer
  is byte-identical — only the round-trips are gone.
  """
  @spec derive(Phoenix.LiveView.Socket.t()) :: %{read: boolean, write: boolean, admin: boolean}
  def derive(socket) do
    ws = socket.assigns[:current_workspace]
    ws_id = ws && Map.get(ws, :id)

    principals =
      Enum.reject([socket.assigns[:api_token], socket.assigns[:current_user]], &is_nil/1)

    desk = desk_scope(socket)
    grants = if is_map(desk), do: active_grants(socket), else: []

    memberships = load_memberships(principals, ws_id)

    member = fn action ->
      Enum.any?(memberships, fn {principal, membership} ->
        membership_authorizes?(principal, membership, ws_id, action)
      end)
    end

    granted = fn action ->
      is_map(desk) and Enum.any?(grants, &(Access.admits_desk?(&1, action, desk) == true))
    end

    %{
      read: member.(:read) or granted.(:read),
      write: member.(:write) or granted.(:write),
      admin: admin_from(socket, memberships, ws_id)
    }
  end

  # ONE `Repo.one` per principal, reused for :read/:write/:admin. Returns
  # `[{principal, membership_or_nil}]`. Mirrors `authorize/3`'s own totality:
  # an unresolved workspace, or a principal shape `authorize/3` would have hit
  # its catch-all `{:error, :forbidden}` clause with, contributes nothing.
  defp load_memberships(principals, ws_id) when is_binary(ws_id) do
    for principal <- principals, loadable_principal?(principal) do
      {principal, Tenancy.Auth.membership(principal, ws_id)}
    end
  end

  defp load_memberships(_principals, _ws_id), do: []

  defp loadable_principal?(%Barkpark.Auth.ApiToken{id: id}) when is_binary(id), do: true
  defp loadable_principal?(%Barkpark.Accounts.User{id: id}) when is_binary(id), do: true
  defp loadable_principal?(_other), do: false

  # The decision `Tenancy.Auth.authorize/3` makes, read off an ALREADY-LOADED
  # membership row instead of re-loading it. Token: member AND its permissions
  # array satisfies the action. User: the membership ROLE is the grant. A nil
  # membership is a non-member ⇒ denied, exactly as `authorize/3` denies it.
  defp membership_authorizes?(_principal, nil, _ws_id, _action), do: false

  defp membership_authorizes?(%Barkpark.Auth.ApiToken{} = token, %_{}, _ws_id, action),
    do: Tenancy.Auth.permits?(token, action)

  defp membership_authorizes?(%Barkpark.Accounts.User{}, %{role: role}, ws_id, action)
       when is_binary(role),
       do: Tenancy.Auth.role_permits?(role, ws_id, action)

  defp membership_authorizes?(_principal, _membership, _ws_id, _action), do: false

  @doc """
  Fresh admin predicate — an admin api_token OR an account with the `:admin`
  role on the mounted workspace. Grants never confer admin. Mirrors
  `StudioChrome.admin?/2`; the shares/item-share handlers re-check with this.
  """
  @spec admin?(Phoenix.LiveView.Socket.t()) :: boolean
  def admin?(socket) do
    token_admin?(socket.assigns[:api_token]) or
      account_admin?(socket.assigns[:current_user], socket.assigns[:current_workspace])
  end

  # `admin?/1`'s answer, read off the memberships `derive/1` already loaded.
  # The token arm is deliberately membership-FREE (an `admin`-permissioned
  # api_token is admin wherever it is), exactly as `admin?/1` has it — so it is
  # asked of the raw assign, not of the loaded rows, and still answers on a
  # socket whose workspace is unresolved.
  defp admin_from(socket, memberships, ws_id) do
    token_admin?(socket.assigns[:api_token]) or
      Enum.any?(memberships, fn {principal, membership} ->
        account_admin_from(principal, membership, ws_id)
      end)
  end

  defp account_admin_from(%Barkpark.Accounts.User{}, %{role: role}, ws_id)
       when is_binary(role) and is_binary(ws_id),
       do: Tenancy.Auth.role_permits?(role, ws_id, :admin)

  defp account_admin_from(_principal, _membership, _ws_id), do: false

  defp token_admin?(%_{} = token), do: Barkpark.Auth.has_permission?(token, "admin")
  defp token_admin?(_), do: false

  defp account_admin?(%Barkpark.Accounts.User{} = user, %{id: ws_id}) when is_binary(ws_id),
    do: Tenancy.Auth.authorize(user, ws_id, :admin) == :ok

  defp account_admin?(_user, _ws), do: false

  # Grants are bound to a grantee USER; only a current_user can hold any. Fresh,
  # active-filtered load — the source of mid-session expiry truth.
  defp active_grants(socket) do
    case socket.assigns[:current_user] do
      %{id: uid} when is_binary(uid) -> Access.list_active_grants_for_grantee(uid)
      _ -> []
    end
  end

  # (workspace, project, dataset) granularity — the desk a grant is validated
  # against by `Access.admits_desk?/3`. nil when the workspace is unresolved.
  defp desk_scope(socket) do
    ws = socket.assigns[:current_workspace]
    ws_id = ws && Map.get(ws, :id)

    if is_binary(ws_id) do
      proj = socket.assigns[:current_project]
      dataset = socket.assigns[:dataset]
      base = %{workspace_id: ws_id, project_id: proj && Map.get(proj, :id)}
      if is_binary(dataset), do: Map.put(base, :dataset, dataset), else: base
    end
  end

  # ── the deny-gate ───────────────────────────────────────────────────────────

  @doc """
  Attach the capability deny-gate to a Studio socket. Idempotent (a live patch
  re-mount would raise on a duplicate hook name — guarded). Attach once in
  `StudioLive.mount` so it covers every grade.
  """
  def attach(socket) do
    if socket.assigns[:caps_gate?] do
      socket
    else
      socket
      |> Phoenix.Component.assign(:caps_gate?, true)
      |> attach_hook(:studio_caps_gate, :handle_event, &gate/3)
    end
  end

  defp gate(event, _params, socket) do
    case classify(event) do
      tier when tier in [:none, :read] ->
        {:cont, socket}

      # :write enforcement. A write-capable socket always passes. Otherwise:
      #   * a RESTRICTED socket (share-read / grant / caller_context grade) is
      #     denied — unchanged from before;
      #   * a socket that carries a PRINCIPAL (api_token and/or current_user)
      #     but lacks write is now ALSO denied — this closes the hole where a
      #     read-only API-token MEMBER (or read-only user member) rode the
      #     non-restricted short-circuit;
      #   * only a principal-LESS socket falls through to pass, i.e. the
      #     intentionally-open anonymous public-demo posture (an anonymous
      #     non-demo socket never reaches a write event un-restricted).
      :write ->
        if write_capable?(socket.assigns, derive(socket)) do
          {:cont, socket}
        else
          {:halt, deny(socket)}
        end

      # :admin and :deny (default) both require admin, enforced on ALL sockets.
      _admin_or_deny ->
        if derive(socket).admin do
          {:cont, socket}
        else
          {:halt, deny(socket)}
        end
    end
  end

  defp deny(socket),
    do: put_flash(socket, :error, "You don't have access to do that.")

  @doc """
  THE `:write` TIER, AND THE ONLY COPY OF IT. Takes an assigns MAP plus an
  already-derived caps map, so both enforcement points read one rule:

    * the socket-level `gate/3` above, which passes `derive(socket)` — fresh,
      so mid-session grant expiry denies immediately;
    * a LiveComponent CALLSITE, which passes the render-time `@caps`. A
      `phx-target`ed event carries a component cid and LiveView runs the
      COMPONENT socket's lifecycle for it, so `gate/3` is structurally
      unreachable there and the capability must travel in as a prop
      (`grep -n 'read_only=' lib/barkpark_web/live/studio/studio_live/components.ex`).

  Order is load-bearing, TOP DOWN: a READ-ONLY POSTURE (`share_access: :read`
  or `readonly_gate?: true`) is denied FIRST — before `caps.write` gets a vote
  — because `derive/1` never reads posture, so a share-read socket holding a
  write GRANT otherwise short-circuited past its own restriction (pds-w43,
  PDS-D635). Then: write-capable passes; a RESTRICTED socket (grant grade /
  caller_context) does not; a socket carrying a PRINCIPAL that lacks write does
  not — that is the read-only api_token / read-only member hole; only a
  principal-LESS socket falls through, i.e. the intentionally-open anonymous
  public-demo posture. Forking this predicate is how the two points drift.
  """
  @spec write_capable?(map(), map()) :: boolean
  def write_capable?(assigns, caps) when is_map(assigns) and is_map(caps) do
    cond do
      readonly_posture?(assigns) -> false
      Map.get(caps, :write) == true -> true
      restricted?(assigns) -> false
      has_principal?(assigns) -> false
      true -> true
    end
  end

  # pds-w43 (PDS-D635) — THE READ-ONLY SHARE POSTURE, ABOVE `caps.write`.
  #
  # `derive/1` computes `write` from membership+grants ONLY; it never reads the
  # socket's POSTURE. So a socket that is BOTH read-only-posture AND carries a
  # write source used to short-circuit on the `caps.write` arm and pass —
  # making this predicate's own docstring ("a RESTRICTED socket does not
  # [pass]") false. Reachable without any admin step: `LiveScope.authorize_read/4`
  # offers the public-share arm BEFORE the grant arm (deliberately — grants only
  # ADD access), so a signed-in NON-MEMBER holding an ACTIVE WRITE GRANT who
  # mounts a `:docs`-shared desk lands on grade `:share_read` (`share_access:
  # :read`, `readonly_gate?: true`, NO `caller_context`, NO `write_gate?`) —
  # neither `Content.Scope.scope_to_grants/3`'s read-narrowing nor the per-event
  # `Access.validate/3` write-narrowing is armed, and the grant even escalated
  # doc-scoped: a grant naming ONE doc wrote a DIFFERENT paper on the same desk.
  #
  # DELIBERATELY NARROWER THAN `restricted?/1`. Hoisting `restricted?/1` whole
  # would also deny GRANT-graded sockets (`write_gate?` / `caller_context`),
  # whose narrowing IS armed — a real regression for legitimate grantees. This
  # arm names ONLY the two assigns that mean "this mount is read-only by
  # posture", and the `restricted?/1` arm below stays exactly where it was.
  defp readonly_posture?(assigns) do
    Map.get(assigns, :share_access) == :read or
      Map.get(assigns, :readonly_gate?) == true
  end

  # A capability-RESTRICTED socket is one LiveScope decided to gate (a share
  # read grade or a grant grade). These were ALWAYS write-gated by this hook;
  # kept unchanged so share-read/grant sockets keep their fresh expiry-truth.
  defp restricted?(assigns) do
    Map.get(assigns, :readonly_gate?) == true or
      Map.get(assigns, :write_gate?) == true or
      not is_nil(Map.get(assigns, :caller_context)) or
      Map.get(assigns, :share_access) == :read
  end

  # Does the socket carry an authenticated principal? A read-only such principal
  # must be write-denied (the hole this fix closes). A principal-LESS socket is
  # the anonymous public-demo posture, which stays intentionally open for write.
  defp has_principal?(assigns) do
    not is_nil(Map.get(assigns, :api_token)) or not is_nil(Map.get(assigns, :current_user))
  end
end
