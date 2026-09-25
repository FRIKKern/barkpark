defmodule BarkparkWeb.Studio.ClaudeChatTurnHandoffTest do
  @moduledoc """
  A turn started while the PREVIOUS turn's provider Session is still in
  `terminate/2` must run (task-73e619c78bc9c5e0).

  The race: a turn ends, the Session tells its sink (the Recorder)
  `{:claude_chat_exit, …}` and stops, the Recorder stops too, and the Session
  then runs its teardown (reap wait, stderr rm, MCP token revoke). If the
  Session still holds its `Barkpark.StudioChat.SessionRegistry` name during
  that teardown, the next turn's `Recorder.init → Runtime.open` gets
  `{:error, {:already_started, dying}}`, adopts the dying Session, receives
  its `:DOWN` and stops. The user's turn never spawns a provider.

  The window is HELD, not slept into. The old Session's token revoke is a
  Repo query; a `[:barkpark, :repo, :query]` handler (it runs in the querying
  process) parks the FIRST provider-Session `api_tokens` query on a message
  this test sends. While it is parked, the Session is mid-`terminate/2`, and
  the test starts turn 2 and waits for turn 2's stub to run.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Provider.Claude.Session, as: ProviderSession
  alias Barkpark.StudioChat.Recorder

  @handler_id "claude-chat-turn-handoff-hold"

  setup do
    ensure_default_scope!()
    ws = create_workspace!("chat-handoff-ws-#{System.unique_integer([:positive])}")

    {:ok, minter} =
      Auth.create_token(
        "handoff-minter-#{System.unique_integer([:positive])}",
        "chat admin",
        "production",
        ["read", "write"],
        ws.id
      )

    prev_chat = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      :telemetry.detach(@handler_id)

      if prev_chat,
        do: Application.put_env(:barkpark, :claude_chat, prev_chat),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    %{ws: ws, minter: minter}
  end

  test "turn 2 runs its provider while turn 1's Session is parked inside terminate/2",
       %{ws: ws, minter: minter} do
    counter = tmp_path("counter")
    Application.put_env(:barkpark, :claude_chat, command: {counting_stub(counter), []})

    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"}, :global)
    :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

    # Park exactly ONE query: the first `api_tokens` query a provider Session
    # makes after the gate is armed. Turn 1's Session makes no api_tokens
    # query between its mint (in init, before the gate can matter — see below)
    # and its teardown revoke, and the once-flag keeps turn 2's Session out.
    once = :atomics.new(1, [])
    test_pid = self()

    :ok =
      :telemetry.attach(
        @handler_id,
        [:barkpark, :repo, :query],
        &__MODULE__.hold_revoke/4,
        %{once: once, test: test_pid}
      )

    # ── TURN 1 ──────────────────────────────────────────────────────────────
    {:ok, rec1} = Recorder.ensure(turn_opts(sid, ws, minter))
    rec1_ref = Process.monitor(rec1)

    # The stub printed turn-1's result and exited; the Session told the
    # Recorder, which stops. Then the Session enters terminate/2 and parks on
    # its token revoke.
    assert_receive {:claude_chat_event, %{"type" => "result", "result" => "turn-1"}}, 10_000
    assert_receive {:DOWN, ^rec1_ref, :process, ^rec1, _}, 10_000
    assert_receive {:held_in_terminate, dying}, 10_000
    dying_ref = Process.monitor(dying)
    assert Process.alive?(dying), "precondition: turn 1's Session is still in terminate/2"
    assert Recorder.whereis(sid) == nil

    # ── TURN 2, inside the window ───────────────────────────────────────────
    {:ok, rec2} = Recorder.ensure(turn_opts(sid, ws, minter))

    turn2_ran? =
      receive do
        {:claude_chat_event, %{"type" => "result", "result" => "turn-2"}} -> true
      after
        5_000 -> false
      end

    # The window was still open for the whole wait: the old Session had not
    # left terminate/2 (it cannot, until this test releases it).
    assert Process.alive?(dying), "precondition: the window stayed open during turn 2"

    send(dying, :release_revoke)
    assert_receive {:DOWN, ^dying_ref, :process, ^dying, _}, 10_000
    await_down(rec2)

    assert turn2_ran?,
           "turn 2's provider never ran: its Recorder adopted turn 1's dying Session " <>
             "(counter: #{inspect(read_lines(counter))})"

    assert read_lines(counter) == ["run", "run"]
  end

  @doc false
  # Runs in the QUERYING process. Parks the first provider-Session api_tokens
  # query until the test sends `:release_revoke` (bounded, so a broken test can
  # never wedge a Session forever).
  def hold_revoke(_event, _measurements, metadata, %{once: once, test: test}) do
    if metadata[:source] == "api_tokens" and provider_session?() and
         String.starts_with?(to_string(metadata[:query]), "UPDATE") and
         :atomics.compare_exchange(once, 1, 0, 1) == :ok do
      send(test, {:held_in_terminate, self()})

      receive do
        :release_revoke -> :ok
      after
        30_000 -> :ok
      end
    end

    :ok
  end

  defp provider_session? do
    match?({ProviderSession, :init, 1}, Process.get(:"$initial_call"))
  end

  defp turn_opts(sid, ws, minter) do
    %{
      session_id: sid,
      mode: "plan",
      execution_target: "managed",
      workspace_id: ws.id,
      minter: minter
    }
  end

  # Appends one line per run, prints one result frame naming the run, exits.
  defp counting_stub(counter) do
    path = tmp_path("stub") <> ".sh"

    File.write!(path, """
    #!/bin/sh
    echo run >> '#{counter}'
    n=$(wc -l < '#{counter}' | tr -d ' ')
    printf '{"type":"result","subtype":"success","is_error":false,"result":"turn-%s"}\\n' "$n"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp tmp_path(kind) do
    path =
      Path.join(
        System.tmp_dir!(),
        "claude_chat_handoff_#{kind}_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      _ -> []
    end
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
  end
end
