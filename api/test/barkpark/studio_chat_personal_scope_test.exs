defmodule Barkpark.StudioChatPersonalScopeTest do
  use Barkpark.DataCase, async: false
  import Barkpark.TenancyFixtures
  alias Barkpark.{Accounts, Repo, StudioChat}
  alias Barkpark.StudioChat.{FleetHub, Recorder, Runtime}

  setup do
    ws = create_workspace!()

    {:ok, user} =
      Accounts.register_user(%{
        email: "chat-owner-#{System.unique_integer([:positive])}@example.com",
        password: "personal store test password"
      })

    scope = {:personal, ws.id, user.id}
    {:ok, row} = StudioChat.create_session(%{id: Ecto.UUID.generate(), title: "Private"}, scope)
    %{ws: ws, user: user, row: row, scope: scope}
  end

  test "the scope stamps both immutable owners and legacy creates cannot smuggle a personal owner",
       ctx do
    {:ok, row} =
      StudioChat.create_session(
        %{
          id: Ecto.UUID.generate(),
          owner_user_id: Ecto.UUID.generate(),
          owner_workspace_id: Ecto.UUID.generate()
        },
        ctx.scope
      )

    assert row.owner_user_id == ctx.user.id
    assert row.owner_workspace_id == ctx.ws.id

    {:ok, legacy} =
      StudioChat.create_session(
        %{id: Ecto.UUID.generate(), owner_user_id: ctx.user.id},
        ctx.ws.id
      )

    assert legacy.owner_user_id == nil
    assert StudioChat.get_session(ctx.row.id, ctx.ws.id) == nil
    assert StudioChat.get_session(legacy.id, ctx.scope) == nil
    assert StudioChat.get_session(ctx.row.id, {:personal, ctx.ws.id, Ecto.UUID.generate()}) == nil

    assert StudioChat.get_session(ctx.row.id, {:personal, Ecto.UUID.generate(), ctx.user.id}) ==
             nil
  end

  test "stored messages remain engine-owned and scope applies to full and limited history", ctx do
    {:ok, _} =
      StudioChat.append_message(ctx.row, %{role: "user", source_markdown: "Keep this constraint"})

    {:ok, _} =
      StudioChat.append_message(ctx.row, %{
        role: "assistant",
        source_markdown: "Fictional fixture"
      })

    assert Enum.map(StudioChat.list_messages(ctx.row.id, ctx.scope), & &1.seq) == [1, 2]
    assert Enum.map(StudioChat.list_messages(ctx.row.id, 1, ctx.scope), & &1.seq) == [2]

    assert {:error, :not_found} =
             StudioChat.personal_messages_since(
               ctx.row.id,
               0,
               {:personal, ctx.ws.id, Ecto.UUID.generate()}
             )

    assert StudioChat.list_messages(ctx.row.id, ctx.ws.id) == []
    assert StudioChat.list_messages(ctx.row.id, 1, ctx.ws.id) == []

    assert StudioChat.list_messages(ctx.row.id, {:personal, ctx.ws.id, Ecto.UUID.generate()}) ==
             []
  end

  test "archive and restore retain personal identity; wrong scopes cannot restore", ctx do
    assert {:ok, archived} = StudioChat.archive_session(ctx.row.id, ctx.scope)
    assert archived.owner_user_id == ctx.user.id
    assert :noop = StudioChat.unarchive_session(ctx.row.id, ctx.ws.id)
    assert {:ok, restored} = StudioChat.unarchive_session(ctx.row.id, ctx.scope)
    assert restored.owner_user_id == ctx.user.id
    assert restored.owner_workspace_id == ctx.ws.id
    assert restored.archived_at == nil
  end

  # Plugins-off: this assertion needs the studio_chat Recorder registry running.
  @tag :requires_plugins
  test "fresh and resumed provider starts are refused before adapter or host dispatch", ctx do
    for resume <- [false, true], target <- ["managed", "registered_host"] do
      assert {:error, :personal_chat_runtime_unavailable} =
               Runtime.open("codex", %{
                 session_id: ctx.row.id,
                 workspace_id: ctx.ws.id,
                 execution_target: target,
                 execution_host_id: Ecto.UUID.generate(),
                 resume: resume
               })

      assert {:error, :personal_chat_runtime_unavailable} =
               Recorder.ensure(%{
                 session_id: ctx.row.id,
                 workspace_id: ctx.ws.id,
                 mode: "plan",
                 resume: resume
               })
    end

    for operation <- [:start, :resume],
        target <- ["managed", "registered_host"],
        command_id <- [ctx.row.id, nil] do
      command = %Runtime.Command{
        operation: operation,
        provider: "codex",
        session_id: command_id,
        payload: %{session_id: ctx.row.id}
      }

      assert {:error, :personal_chat_runtime_unavailable} =
               Runtime.dispatch(target, "codex", command)
    end

    assert Recorder.whereis(ctx.row.id) == nil
  end

  test "fleet snapshot, ring replay and live title scope cannot treat a personal owner as a workspace",
       ctx do
    assert StudioChat.fleet_snapshot(ctx.ws.id) == []
    assert StudioChat.rollup(ctx.ws.id).counts.idle == 0
    owner = StudioChat.fleet_owner(ctx.row)
    refute StudioChat.scope_match?(owner, ctx.ws.id)
    refute StudioChat.scope_match?(owner, {:personal, ctx.ws.id, Ecto.UUID.generate()})
    assert StudioChat.scope_match?(owner, ctx.scope)
    hub = start_supervised!({FleetHub, name: nil})
    send(hub, {:chat_reported_state, ctx.row.id, %{agent_state: "working", owner_scope: owner}})
    state = :sys.get_state(hub)
    assert [%{owner_ws: ^owner}] = state.ring
    assert {:replay, _, _, []} = FleetHub.handshake(hub, {state.epoch, 0}, ctx.ws.id)
    send(hub, {:chat_title, ctx.row.id, "Private title"})
    assert :sys.get_state(hub).owners[ctx.row.id] == owner
  end

  test "subject export and erasure include only this user's personal conversations", ctx do
    {:ok, legacy} = StudioChat.create_session(%{id: Ecto.UUID.generate()}, ctx.ws.id)

    {:ok, _} =
      StudioChat.append_message(ctx.row, %{
        role: "user",
        source_markdown: "Private reader request"
      })

    export = Accounts.Privacy.export_subject(ctx.user)

    assert [%{id: id, messages: [%{source_markdown: "Private reader request"}]}] =
             export.personal_chats

    assert id == ctx.row.id
    assert {:ok, _} = Accounts.Privacy.erase_subject(ctx.user)
    assert StudioChat.get_session(ctx.row.id) == nil

    assert Repo.aggregate(
             from(m in StudioChat.Message, where: m.session_id == ^ctx.row.id),
             :count
           ) == 0

    assert StudioChat.get_session(legacy.id) != nil
  end
end
