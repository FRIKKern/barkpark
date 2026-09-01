defmodule BarkparkWeb.Studio.PdsW42ChatLiveFlatLifecycleGlobalTest do
  @moduledoc """
  pds-w42-bl-chatlive-routed-clauses-ungated — RUN the flat `/studio/chat`
  lifecycle clauses and read the persisted result back.

  ## What the row claimed, and what the source actually says

  The row claimed ChatLive's routed `handle_event` clauses sit behind "no
  deny-gate whatsoever" on the flat route. That is NOT what the router says:
  `:admin_studio` carries `{BarkparkWeb.LiveAuth, :admin}`, which HALTS a
  principal holding no `admin` grant. A socket that never mounts never reaches
  a `handle_event` clause, so "ungated" is too strong.

  The real, narrower defect this module proves by run is a TENANCY one, and it
  is on the CLAUSES, not the mount:

    * `LiveAuth.on_mount(:admin)` is a FLAT, GLOBAL-permission gate. It asks
      `Auth.has_permission?(token, "admin")` and never looks at the token's
      `workspace_id`. A token BOUND to workspace B therefore mounts
      `/studio/chat`.
    * Four routed clauses then take a CLIENT-SUPPLIED session id and drive it
      at hard-coded `:global` scope — `StudioChat.archive_session(id, :global)`,
      `unarchive_session(id, :global)`, `delete_session(id, :global)`, and
      `StudioChat.rename(id, title)` (whose `scope` argument DEFAULTS to
      `:global`, so it cannot even be narrowed at the call site).

  `StudioChat` already has the scoping facility these calls decline to use:
  `get_session/2` is fail-closed for a workspace scope, so passing
  `{:workspace, ws}` would return `nil` for a foreign row and the mutation
  would become a `:noop`. `:global` opts out of that.

  The consequence proven below: a workspace-B-bound admin token renames,
  archives and DELETES a chat session owned by a DIFFERENT workspace, by id.

  ## Non-vacuity — both directions, without a source change

  This is a WITNESS suite: it asserts the CURRENT behaviour, so it is green on
  `main`. That makes "it passed" worthless on its own, and every assertion here
  is therefore built to fail loudly if the fixture, the principal, or the mount
  is not real:

    * Every assertion is on PRESENCE — the mutation LANDED, read back from
      Postgres by primary key. Nothing here concludes anything from an absence
      or from a quiet log.
    * The target row is asserted to EXIST and to be owned by the OTHER
      workspace before the event is sent. A delete "succeeding" against a row
      that was never created, or a row that happened to be B's own, would be
      vacuous.
    * The mount is asserted to have SUCCEEDED as `{:ok, view, _}`. A mount
      bounced by the auth gate — or by the missing-runtime refusal, which is
      why `enable_fake_chat/0` runs in every test — would make a "nothing
      changed" reading meaningless.
    * `test/4` is the OPPOSING arm: the SAME principal is REFUSED at mount of
      the workspace-scoped route for the very workspace whose row it just
      deleted flat. That is the row's "a principal the epic's gates would deny
      elsewhere", demonstrated rather than asserted — and it rules out the
      innocent explanation that this token is simply a legitimate instance-wide
      superuser.

  The mutation run required by the row's acceptance criteria is recorded in the
  PR body: the guard that would close this lives in
  `BarkparkWeb.Studio.ChatLive`, a file this builder was fenced out of, so the
  RED arm was produced by patching the four `:global` call sites to the
  socket's own workspace scope and re-running this module.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Session, as: StudioChatSession
  alias Barkpark.Tenancy

  @flat_path "/studio/chat"

  setup %{conn: conn} do
    {ws_a, proj_a} = ensure_default!()

    {:ok, ws_b} =
      Tenancy.create_workspace(%{
        slug: "pdsw42-b-#{System.unique_integer([:positive])}",
        name: "PDS W42 B"
      })

    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    enable_fake_chat()

    # The PRINCIPAL: an admin token BOUND to workspace B. `on_mount(:admin)`
    # reads only `permissions`, so the binding is invisible to the flat gate.
    raw = "pdsw42-bound-b-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(
        raw,
        "pds w42 ws-b admin",
        "production",
        ["read", "write", "admin"],
        ws_b.id
      )

    # The TARGET: a chat session owned by workspace A. Created through the store
    # with an explicit `{:workspace, …}` scope so `owner_workspace_id` is real
    # and not a Default-pinned accident.
    {:ok, victim} =
      StudioChat.create_session(
        %{id: Ecto.UUID.generate(), title: "ws-A private chat", title_source: "human"},
        {:workspace, ws_a.id}
      )

    # Fixture guard: the row exists AND belongs to the OTHER tenant. Without
    # this, every mutation assertion below could pass against a row that was
    # never A's to begin with.
    assert %StudioChatSession{} = reloaded = Repo.get(StudioChatSession, victim.id)

    assert reloaded.owner_workspace_id == ws_a.id,
           "fixture did not produce a workspace-A-owned session (got " <>
             "#{inspect(reloaded.owner_workspace_id)}) — every assertion below would be vacuous"

    refute reloaded.owner_workspace_id == ws_b.id,
           "fixture handed the acting principal its OWN row — that is not a cross-tenant probe"

    %{
      conn: init_test_session(conn, %{"api_token" => raw}),
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      victim: victim
    }
  end

  describe "the flat :admin_studio route — a ws-B-bound admin token drives ws-A's rows" do
    test "session-rename REWRITES a foreign workspace's session title", %{
      conn: conn,
      victim: victim
    } do
      view = mount_flat!(conn)

      marker = "OWNED-BY-WS-B-#{System.unique_integer([:positive])}"
      render_click(view, "session-rename", %{"id" => victim.id, "value" => marker})

      after_row = Repo.get(StudioChatSession, victim.id)

      assert %StudioChatSession{} = after_row,
             "the rename probe lost its target row — the read-back is unsound"

      # PRESENCE: the foreign title now carries a value only this socket could
      # have supplied.
      assert after_row.title == marker,
             "expected the ws-B principal's rename to LAND on ws-A's session " <>
               "(that is the defect); title is #{inspect(after_row.title)}"

      assert after_row.title_source == "human",
             "rename/2 pins title_source — a changed title with an unchanged source " <>
               "would mean something other than this clause wrote it"
    end

    test "session-archive STAMPS archived_at on a foreign workspace's session", %{
      conn: conn,
      victim: victim
    } do
      assert is_nil(Repo.get(StudioChatSession, victim.id).archived_at),
             "the fixture row is already archived — the probe cannot observe the stamp"

      view = mount_flat!(conn)
      render_click(view, "session-archive", %{"id" => victim.id})

      after_row = Repo.get(StudioChatSession, victim.id)

      assert %StudioChatSession{} = after_row

      # PRESENCE: a timestamp appeared where there was none.
      assert after_row.archived_at,
             "expected the ws-B principal's archive to LAND on ws-A's session " <>
               "(that is the defect); archived_at is still nil"
    end

    test "session-delete REMOVES a foreign workspace's session outright", %{
      conn: conn,
      victim: victim
    } do
      view = mount_flat!(conn)

      # State the pre-condition on the SAME connection the assertion reads, so a
      # sandbox/ownership surprise cannot masquerade as a successful delete.
      assert %StudioChatSession{} = Repo.get(StudioChatSession, victim.id),
             "the target row vanished before the event — a later `nil` would prove nothing"

      render_click(view, "session-delete", %{"id" => victim.id})

      # The row is gone. This is the one assertion in the module that reads an
      # absence, and it is admissible ONLY because the line above proved the
      # same query returned a row moments earlier on the same connection.
      refute Repo.get(StudioChatSession, victim.id),
             "expected the ws-B principal's delete to LAND on ws-A's session (that is the defect)"
    end

    test "the same principal is REFUSED at the scoped route for that very workspace", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      scoped = "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/chat"

      # `:scoped_admin` resolves workspace A from the URL and demands a grant
      # THERE. A ws-B-bound token has none, so the mount halts.
      assert {:error, {kind, _}} = live(conn, scoped),
             "the ws-B principal MOUNTED #{scoped} — if the scoped gate also lets it " <>
               "through, this token is effectively global and the flat finding needs re-framing"

      assert kind in [:redirect, :live_redirect],
             "expected a redirect halt from the scoped mount gate, got #{inspect(kind)}"

      # And the opposing direction, on the SAME conn in the SAME test: the flat
      # route admits it. One principal, two doors, two answers — that asymmetry
      # IS the finding.
      assert {:ok, _view, _html} = live(conn, @flat_path),
             "the flat route refused the principal too — then there is no asymmetry to report"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Mount the flat route and PROVE it mounted. A bounced mount (auth halt, or
  # the missing-runtime refusal in `ChatLive.mount/3`) must never be mistaken
  # for a quiet success.
  defp mount_flat!(conn) do
    assert {:ok, view, _html} = live(conn, @flat_path),
           "the ws-B-bound admin token failed to mount the flat #{@flat_path} — " <>
             "every clause assertion in this test would be vacuous"

    view
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

  # ChatLive.mount refuses when no provider is enabled. Without this every mount
  # assertion above would fail for a reason that has nothing to do with authz.
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
