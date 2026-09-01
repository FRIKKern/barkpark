defmodule BarkparkWeb.Studio.PdsChatLiveGlobalReadsTest do
  @moduledoc """
  task-3ca8eed88d10f57e — ChatLive's LOADERS read `:global` while the write
  beside them threads the tenant.

  ## The defect

  `#14593` closed the WRITE side: `tenancy_permits?/2` refuses a cross-tenant
  rename/archive/unarchive/delete. Every READ beside those writes still said
  `:global`:

      chat_live.ex  StudioChat.list_sessions([archived: _], :global)  # the sidebar
                    StudioChat.get_session(sid, :global)              # the detail pane
                    StudioChat.get_session(store_id, :global)         # spawn + ring

  The carve-out comment that made those reads look intentional — "the sidebar
  sees every workspace's sessions, unchanged from today" — was written when this
  LiveView was mounted ONLY at flat `/studio/chat` under the instance-wide
  `{LiveAuth, :admin}`. The router now ALSO mounts it inside
  `live_session :scoped_admin_studio` at `/w/:ws/p/:proj/studio/chat` behind
  `{LiveAuth, :scoped_admin}`, a gate that proves owner/admin in the URL
  WORKSPACE and nothing more. A workspace-B admin is not an instance admin, and
  every loader still handed them workspace A's rows.

  ## Why the principal below is the honest one

  The ws-B admin's token is minted WITHOUT an explicit workspace, so
  `Auth.create_token/5` auto-binds it to the seeded DEFAULT workspace — which is
  workspace A here. That is the common shape, not an edge case, and it is what
  makes this suite discriminating in BOTH directions:

    * a fix that stayed on `:global` shows ws-A's session (the leak);
    * a fix that threaded `principal_workspace_id/1` (the TOKEN BINDING, which
      `tenancy_permits?/2` reads for the writes) would show ws-A's session and
      HIDE ws-B's own — the positive control catches that.

  Only the acting workspace of the SCOPED MOUNT (`:current_workspace`, pinned by
  `LiveScope` to the URL workspace) satisfies both arms.

  ## Why the NULL-owned row is asserted present

  `StudioChat`'s own workspace scope is a strict `owner_workspace_id == ^ws`
  equality, so simply handing the store a workspace binary would blank every
  pre-tenancy session. The legacy arm below is the guard against "fixing" the
  leak by deleting legacy rows from the sidebar; it is asserted in the SAME run
  as the refusal, never in a separate green.

  Every assertion is stated against a value READ BACK FROM THE STORE moments
  earlier in the same test — never a bare "the list is non-empty".

  The fake runtime is enabled in every test: `ChatLive.mount/3` refuses when no
  provider is enabled, and a mount refused for a MISSING RUNTIME would make
  every absence assertion below vacuously green.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Session, as: StudioChatSession
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup %{conn: conn} do
    # Workspace A IS the seeded Default — the tenant `Auth.create_token/5`
    # silently binds an omitted workspace to.
    {ws_a, _proj_a} = ensure_default!()

    {:ok, ws_b} =
      Tenancy.create_workspace(%{
        slug: "pds-chat-b-#{System.unique_integer([:positive])}",
        name: "PDS Chat B"
      })

    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    # THE PRINCIPAL: global `admin` permission (so the flat gate is not what is
    # under test) + an ADMIN membership in B (so `{LiveAuth, :scoped_admin}`
    # admits it at the scoped mount). No explicit workspace → bound to Default.
    raw = "pds-chat-admin-#{System.unique_integer([:positive])}"

    {:ok, token} =
      Auth.create_token(raw, "pds chat wsb admin", "production", ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws_b.id, token.id, "admin")

    unique = System.unique_integer([:positive])

    foreign_title = "WS-A-PRIVATE-CHAT-#{unique}"
    own_title = "WS-B-OWN-CHAT-#{unique}"
    legacy_title = "LEGACY-NULL-OWNED-CHAT-#{unique}"

    foreign = session_owned_by!({:workspace, ws_a.id}, foreign_title)
    own = session_owned_by!({:workspace, ws_b.id}, own_title)
    legacy = session_owned_by!(:global, legacy_title)

    # ── Fixture guards. Without these the refusal arm could pass against a row
    # that was never workspace A's, and the positive controls against rows whose
    # ownership is not what this suite claims.
    assert Repo.get(StudioChatSession, foreign.id).owner_workspace_id == ws_a.id,
           "fixture did not produce a workspace-A-owned session — the refusal arm is vacuous"

    assert Repo.get(StudioChatSession, own.id).owner_workspace_id == ws_b.id,
           "fixture did not produce a workspace-B-owned session — the LANDS arm is vacuous"

    assert is_nil(Repo.get(StudioChatSession, legacy.id).owner_workspace_id),
           "fixture did not produce a NULL-owned legacy session — the legacy arm is vacuous"

    assert token.workspace_id == ws_a.id,
           "the acting token is not bound to workspace A — the token-binding discriminator " <>
             "this suite depends on is gone (got #{inspect(token.workspace_id)})"

    refute ws_a.id == ws_b.id

    enable_fake_chat()

    %{
      conn: init_test_session(conn, %{"api_token" => raw}),
      scoped_path: "/w/#{ws_b.slug}/p/default/studio/chat",
      foreign: foreign,
      own: own,
      legacy: legacy,
      foreign_title: foreign_title,
      own_title: own_title,
      legacy_title: legacy_title
    }
  end

  describe "scoped /w/:ws/p/:proj/studio/chat — the sidebar list" do
    test "does not disclose another workspace's session, and still lists its own + NULL-owned",
         %{
           conn: conn,
           scoped_path: path,
           foreign: foreign,
           own: own,
           legacy: legacy,
           foreign_title: foreign_title,
           own_title: own_title,
           legacy_title: legacy_title
         } do
      # STORE FIRST: all three rows are really there, under the titles asserted
      # against below. An absence proven against a row that does not exist is
      # not a proof of scoping.
      assert Repo.get(StudioChatSession, foreign.id).title == foreign_title
      assert Repo.get(StudioChatSession, own.id).title == own_title
      assert Repo.get(StudioChatSession, legacy.id).title == legacy_title

      html = mount_scoped!(conn, path)

      # REFUSED — workspace A's session title is not rendered to a principal
      # whose only proof of authority is an admin membership in workspace B.
      refute html =~ foreign_title,
             "the scoped chat sidebar disclosed workspace A's session title to a " <>
               "workspace-B admin — StudioChat.list_sessions/2 is still reading :global"

      # LANDS — the same list, same socket, its OWN workspace's row. Proves the
      # clamp is a scope filter and not a dead sidebar.
      assert html =~ own_title,
             "the ws-B admin cannot see its OWN workspace's session — the read clamp is " <>
               "over-tight (a token-binding clamp would fail exactly here: this token is " <>
               "bound to workspace A)"

      # LEGACY — a NULL `owner_workspace_id` row is pre-tenancy, not foreign, and
      # must stay reachable. This is what a bare store-side workspace scope
      # (strict `owner_workspace_id == ^ws`) would have silently deleted.
      assert html =~ legacy_title,
             "a NULL-owned legacy session vanished from the sidebar — the clamp narrowed " <>
               "to a hard workspace equality instead of the write guard's permitted set"
    end
  end

  describe "scoped /w/:ws/p/:proj/studio/chat — the detail pane" do
    test "a foreign session id off the wire does not load, while its own and a legacy one do",
         %{
           conn: conn,
           scoped_path: path,
           foreign: foreign,
           own: own,
           legacy: legacy,
           foreign_title: foreign_title,
           own_title: own_title,
           legacy_title: legacy_title
         } do
      assert Repo.get(StudioChatSession, foreign.id).title == foreign_title,
             "the foreign row does not carry its seeded title — the refusal read-back is unsound"

      # REFUSED — addressing workspace A's session by id from the scoped mount.
      foreign_html = mount_scoped!(conn, "#{path}/#{foreign.id}")

      refute foreign_html =~ foreign_title,
             "the scoped chat detail pane loaded workspace A's session by id for a " <>
               "workspace-B admin — StudioChat.get_session/2 is still reading :global"

      # The clamped read is indistinguishable from a missing row, so the existing
      # "no longer available" branch is what runs.
      assert foreign_html =~ "no longer available",
             "the foreign id did not take handle_params/3's unknown-session branch — the " <>
               "refusal above may be an unrelated render failure"

      # LANDS — the same clause, same socket, its OWN row.
      own_html = mount_scoped!(conn, "#{path}/#{own.id}")

      assert own_html =~ own_title,
             "the ws-B admin could not open its OWN session — the read clamp is over-tight"

      refute own_html =~ "no longer available",
             "opening its own session took the unknown-session branch"

      # LEGACY — a NULL-owned row stays openable.
      legacy_html = mount_scoped!(conn, "#{path}/#{legacy.id}")

      assert legacy_html =~ legacy_title,
             "a NULL-owned legacy session could not be opened — the clamp is a hard " <>
               "workspace equality, not the write guard's permitted set"
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp session_owned_by!(scope, title) do
    {:ok, session} =
      StudioChat.create_session(
        %{id: Ecto.UUID.generate(), title: title, title_source: "human"},
        scope
      )

    session
  end

  defp mount_scoped!(conn, path) do
    result = live(conn, path)

    # `assert pattern = expr, msg` would make this message DEAD CODE: `assert/2`
    # is a function, so the match runs first and a mismatch raises MatchError
    # before the message is ever reached (scripts/unreachable-assert-message-check.sh).
    # Assert on `match?/2`, then destructure.
    assert match?({:ok, _view, _html}, result),
           "the ws-B admin failed to mount #{path} — every assertion in this test would be " <>
             "vacuous (got #{inspect(result)})"

    {:ok, view, _html} = result
    render(view)
  end

  defp ensure_default! do
    ws =
      case Tenancy.get_default_workspace() do
        nil ->
          {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default"})
          ws

        ws ->
          ws
      end

    proj =
      case Tenancy.get_default_project() do
        nil ->
          {:ok, p} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
          p

        p ->
          p
      end

    {ws, proj}
  end

  defp enable_fake_chat do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end
end
