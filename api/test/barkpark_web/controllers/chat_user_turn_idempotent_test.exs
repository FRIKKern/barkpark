defmodule BarkparkWeb.ChatUserTurnIdempotentTest do
  @moduledoc """
  Storing a sent turn's user row is idempotent on the turn
  (task-f2b66baab8a251f2).

  An insert can commit and still raise: the connection drops after COMMIT and
  before its reply. `persist_sent/5` then saw a failure. It retried and stored
  the row twice, or (when the retry failed too) withdrew a lease the client
  then sent again, with the row already stored. The row now carries the turn's
  `command_key` in its metadata, and after a failed store the server looks for
  it before the retry and before the withdraw.

  The ambiguous commit is played by the append function `persist_sent/5`
  takes: the real append, then a raise, as the driver raises when the reply
  is lost.
  """
  use Barkpark.DataCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease}
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.StudioChat.Session
  alias Barkpark.Tenancy
  alias BarkparkWeb.ChatUserTurn

  @metadata %{"origin" => "api"}

  test "an insert that commits and then raises leaves one user row for the turn and answers 202" do
    {:ok, session} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})
    key = Ecto.UUID.generate()

    assert :ok =
             ChatUserTurn.persist_sent(
               session,
               "once",
               @metadata,
               key,
               appends([:commit_then_raise])
             )

    assert [row] = user_rows(session.id)
    assert row.source_markdown == "once"
    assert row.metadata["command_key"] == key
  end

  test "a commit that raised and a retry that failed: 202, one row, the host's lease left to run" do
    %{session: session, key: key, lease_id: lease_id} = registered_host_turn()

    assert :ok =
             ChatUserTurn.persist_sent(
               session,
               "kept",
               @metadata,
               key,
               appends([:commit_then_raise, :raise])
             )

    assert [%{source_markdown: "kept"}] = user_rows(session.id)
    assert %ExecutionLease{status: "leased"} = Repo.get!(ExecutionLease, lease_id)
    assert Repo.all(from(e in ExecutionEvent, where: e.lease_id == ^lease_id)) == []
  end

  test "a store that never committed still withdraws the lease" do
    %{session: session, key: key, lease_id: lease_id} = registered_host_turn()

    assert {:error, :turn_not_stored} =
             ChatUserTurn.persist_sent(session, "gone", @metadata, key, appends([:raise, :raise]))

    assert user_rows(session.id) == []
    assert %ExecutionLease{status: "completed"} = Repo.get!(ExecutionLease, lease_id)
  end

  test "a stored row carries the turn's command_key" do
    {:ok, session} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})
    key = Ecto.UUID.generate()

    assert :ok = ChatUserTurn.persist_sent(session, "plain", @metadata, key)
    assert [%{metadata: %{"origin" => "api", "command_key" => ^key}}] = user_rows(session.id)
  end

  # An append function that plays `steps` in order, one per call, then the
  # real append for every call after them.
  defp appends(steps) do
    {:ok, agent} = Agent.start_link(fn -> steps end)

    fn session_id, attrs ->
      case Agent.get_and_update(agent, fn
             [step | rest] -> {step, rest}
             [] -> {:real, []}
           end) do
        :commit_then_raise ->
          {:ok, _} = StudioChat.append_message(session_id, attrs)
          raise DBConnection.ConnectionError, "ssl recv: closed (the reply to COMMIT was lost)"

        :raise ->
          raise DBConnection.ConnectionError, "connection not available"

        :real ->
          StudioChat.append_message(session_id, attrs)
      end
    end
  end

  defp user_rows(session_id),
    do: for(m <- StudioChat.list_messages(session_id, :global), m.role == "user", do: m)

  # A registered-host session with one live send_turn lease under `key`.
  defp registered_host_turn do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "cuti-#{suffix}", name: "CUTI #{suffix}"})
    {:ok, issued} = ChatHosts.issue_enrollment(ws.id, %{name: "laptop", approved_roots: ["/tmp"]})
    {:ok, enrolled} = ChatHosts.enroll(issued.enrollment_token)
    {:ok, host} = ChatHosts.authenticate(enrolled.credential)

    {:ok, session} =
      %Session{}
      |> Session.create_changeset(%{
        id: Ecto.UUID.generate(),
        owner_workspace_id: ws.id,
        provider: "claude",
        execution_target: "registered_host",
        execution_host_id: host.id
      })
      |> Repo.insert()

    key = Ecto.UUID.generate()

    command = %Command{
      operation: :send_turn,
      provider: "claude",
      session_id: session.id,
      idempotency_key: key,
      payload: %{cwd: "/tmp", content: "hello"}
    }

    {:ok, %{lease_id: lease_id}} = ChatHosts.lease_and_enqueue(host, command, [])
    %{session: session, key: key, lease_id: lease_id}
  end
end
