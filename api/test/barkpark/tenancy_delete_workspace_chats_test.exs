defmodule Barkpark.TenancyDeleteWorkspaceChatsTest do
  @moduledoc """
  Owner ruling #32 item 6 (2026-10-03): Studio chats are deleted with their
  workspace. `chat_sessions.owner_workspace_id` carries no FK, so before this
  `Tenancy.delete_workspace/1` left the deleted workspace's sessions and their
  messages behind. NULL-owned chats are no workspace's and stay; another
  workspace's chats stay.

  The ledger-pinned arm (a session pinned by the workspace's own runtime
  attempt) is proven in `studio_chat/runtime_usage_test.exs`'s "workspace
  teardown removes only its runtime attempt".
  """
  use Barkpark.DataCase, async: false

  # Seeds `chat_sessions` (studio_chat-owned) — excluded from the
  # core-without-owned-tables differential run.
  @moduletag :owned_tables

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{Repo, StudioChat, Tenancy}
  alias Barkpark.StudioChat.{Message, Session}

  defp chat!(scope) do
    {:ok, session} = StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: "/tmp/x"}, scope)
    {:ok, _} = StudioChat.append_message(session, %{role: "user", source_markdown: "hello"})
    {:ok, _} = StudioChat.append_message(session, %{role: "assistant", source_markdown: "hi"})
    session
  end

  defp message_count(%Session{id: id}),
    do: Repo.aggregate(from(m in Message, where: m.session_id == ^id), :count)

  test "deleting a workspace deletes its chat sessions and their messages" do
    doomed = create_workspace!()
    survivor = create_workspace!()

    doomed_a = chat!({:workspace, doomed.id})
    doomed_b = chat!({:workspace, doomed.id})
    survivor_chat = chat!({:workspace, survivor.id})
    global_chat = chat!(:global)

    assert {:ok, _} = Tenancy.delete_workspace(doomed)

    refute Repo.get(Session, doomed_a.id)
    refute Repo.get(Session, doomed_b.id)
    assert message_count(doomed_a) == 0
    assert message_count(doomed_b) == 0

    assert Repo.get(Session, survivor_chat.id)
    assert message_count(survivor_chat) == 2

    assert %Session{owner_workspace_id: nil} = Repo.get(Session, global_chat.id)
    assert message_count(global_chat) == 2
  end

  test "a workspace with no chats still deletes" do
    ws = create_workspace!()
    other = chat!(:global)

    assert {:ok, _} = Tenancy.delete_workspace(ws)
    assert Repo.get(Session, other.id)
  end
end
