defmodule BarkparkWeb.QuizChannelTest do
  @moduledoc """
  P1 tests for the anonymous player channel: join flow, answer submit (reply +
  validation), and live tally fan-out from one player's answer to another
  player's socket. Each test uses a unique PIN so they stay independent.
  """
  use Barkpark.DataCase, async: false

  import Phoenix.ChannelTest

  alias Barkpark.Quiz
  alias BarkparkWeb.{QuizChannel, QuizSocket}

  @endpoint BarkparkWeb.Endpoint

  setup do
    pin = "T" <> Integer.to_string(System.unique_integer([:positive]))
    # Joins never start rooms (Decision N) — mirror production: the host mount
    # creates the room, then players/observers join it.
    {:ok, _pid} = Quiz.ensure_room(pin)
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  defp join_player(pin, player_id, name) do
    {:ok, reply, socket} =
      QuizSocket
      |> socket(player_id, %{player_id: player_id})
      |> subscribe_and_join(QuizChannel, "quiz:room:" <> pin, %{"name" => name})

    {reply, socket}
  end

  test "join returns the room snapshot and registers the player", %{pin: pin} do
    {reply, _socket} = join_player(pin, "p1", "Alice")
    assert reply.pin == pin
    assert reply.player_count == 1
    assert [%{id: "p1", name: "Alice"}] = reply.players
  end

  test "an empty/missing nickname falls back to a default", %{pin: pin} do
    {:ok, reply, _socket} =
      QuizSocket
      |> socket("p1", %{player_id: "p1"})
      |> subscribe_and_join(QuizChannel, "quiz:room:" <> pin, %{"name" => "   "})

    assert [%{name: "Player"}] = reply.players
  end

  test "a malformed topic is rejected", %{pin: _pin} do
    assert {:error, %{reason: "bad_topic"}} =
             QuizSocket
             |> socket("p1", %{player_id: "p1"})
             |> subscribe_and_join(QuizChannel, "quiz:room:")
  end

  test "submit_answer replies with the live tally", %{pin: pin} do
    {_reply, socket} = join_player(pin, "p1", "Alice")
    ref = push(socket, "submit_answer", %{"choice" => "a"})
    assert_reply ref, :ok, %{tally: %{"a" => 1}}
  end

  test "submit_answer rejects an invalid choice", %{pin: pin} do
    {_reply, socket} = join_player(pin, "p1", "Alice")
    ref = push(socket, "submit_answer", %{"choice" => "zzz"})
    assert_reply ref, :error, %{reason: "invalid_choice"}
  end

  test "submit_answer rejects a malformed payload", %{pin: pin} do
    {_reply, socket} = join_player(pin, "p1", "Alice")
    ref = push(socket, "submit_answer", %{"nope" => true})
    assert_reply ref, :error, %{reason: "invalid_payload"}
  end

  test "one player's answer pushes a live tally to another", %{pin: pin} do
    {_r1, _s1} = join_player(pin, "p1", "Alice")
    {_r2, s2} = join_player(pin, "p2", "Bob")

    push(s2, "submit_answer", %{"choice" => "a"})
    # p1's channel is subscribed to the room events topic and forwards the tally.
    assert_push "tally", %{tally: %{"a" => 1}}
  end

  test "joining pushes presence_state including the joining player", %{pin: pin} do
    {_reply, _socket} = join_player(pin, "p1", "Alice")
    assert_push "presence_state", payload
    assert Map.has_key?(payload, "p1")
  end

  test "a player leaving broadcasts player_left to the others", %{pin: pin} do
    {_r1, _s1} = join_player(pin, "p1", "Alice")
    {_r2, s2} = join_player(pin, "p2", "Bob")

    Process.unlink(s2.channel_pid)
    ref = leave(s2)
    assert_reply ref, :ok

    assert_push "player_left", %{id: "p2", player_count: 1}
  end

  test "a client 'cursor' event drives a room cursor frame on the cursor topic", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.cursor_topic(pin))
    {_r, socket} = join_player(pin, "p1", "Alice")

    push(socket, "cursor", %{"x" => 0.5, "y" => 0.5})
    assert_receive {:quiz_cursors, ^pin, frame}, 500
    assert is_binary(frame)
  end

  test "the channel forwards a room cursor frame to the client", %{pin: pin} do
    {_r, _socket} = join_player(pin, "p1", "Alice")
    frame = Barkpark.Quiz.CursorFrame.encode(%{0 => {100, 200}})
    Phoenix.PubSub.broadcast(Barkpark.PubSub, Quiz.cursor_topic(pin), {:quiz_cursors, pin, frame})

    assert_push "cursors", _payload
  end

  test "a 'hover' event updates the room hover counts", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    {_r, socket} = join_player(pin, "p1", "Alice")

    push(socket, "hover", %{"choice" => "a"})
    assert_receive {:quiz, ^pin, {:hover_counts, %{"a" => 1}}}, 500
  end

  test "connect honors a validly-signed player token (stable reconnect identity)" do
    token = QuizSocket.sign("known-player")
    assert {:ok, socket} = connect(QuizSocket, %{"token" => token})
    assert socket.assigns.player_id == "known-player"
  end

  test "connect rejects a forged token and mints a fresh server-side id (no spoofing)" do
    assert {:ok, socket} = connect(QuizSocket, %{"token" => "forged.not.a.token"})
    assert socket.assigns.player_id != "forged.not.a.token"
    assert is_binary(socket.assigns.player_id)

    assert {:ok, anon} = connect(QuizSocket, %{})
    assert is_binary(anon.assigns.player_id)
  end

  test "join hands back a signed player_token that verifies to the player id", %{pin: pin} do
    {reply, _socket} = join_player(pin, "p1", "Alice")
    assert is_binary(reply.player_token)
    assert {:ok, "p1"} = QuizSocket.verify_token(reply.player_token)
  end

  test "rapid cursor pushes are throttled — the 2nd within the window is dropped", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.cursor_topic(pin))
    {_r, socket} = join_player(pin, "p1", "Alice")

    push(socket, "cursor", %{"x" => 0.1, "y" => 0.1})
    push(socket, "cursor", %{"x" => 0.9, "y" => 0.9})

    assert_receive {:quiz_cursors, ^pin, frame}, 500
    [{_idx, {qx, _qy}}] = frame |> Barkpark.Quiz.CursorFrame.decode() |> Map.to_list()
    # The accepted position is the first (~0.1); the rapid second (~0.9) was dropped.
    assert Barkpark.Quiz.CursorFrame.dequantize(qx) < 0.5
  end

  test "nicknames are moderated: control chars stripped, whitespace collapsed, capped", %{
    pin: pin
  } do
    join_player(pin, "p1", "  Alice\0\a  ")
    join_player(pin, "p2", "Bob   Smith")
    join_player(pin, "p3", "")
    join_player(pin, "p4", String.duplicate("z", 50))

    names = Quiz.state(pin).players |> Map.new(&{&1.id, &1.name})
    assert names["p1"] == "Alice"
    assert names["p2"] == "Bob Smith"
    assert names["p3"] == "Player"
    assert String.length(names["p4"]) == 24
  end

  test "rapid submit_answer is rate-limited", %{pin: pin} do
    {_r, socket} = join_player(pin, "p1", "Alice")

    ref1 = push(socket, "submit_answer", %{"choice" => "a"})
    assert_reply ref1, :ok, %{tally: _}

    ref2 = push(socket, "submit_answer", %{"choice" => "b"})
    assert_reply ref2, :error, %{reason: "rate_limited"}
  end

  test "an observer (host/projector) join is NOT counted as a player", %{pin: pin} do
    join_player(pin, "p1", "Alice")
    assert Quiz.state(pin).player_count == 1

    {:ok, reply, _obs} =
      QuizSocket
      |> socket("obs", %{player_id: "obs"})
      |> subscribe_and_join(QuizChannel, "quiz:room:" <> pin, %{"observe" => true})

    assert reply == %{observer: true}
    # The projector receives frames but must never inflate the count.
    assert Quiz.state(pin).player_count == 1
  end

  # ── Ghost-room guard (Decision N): joins never create rooms ───────────────

  test "a player join to a pin nobody hosts is rejected without spawning a room" do
    bogus = "TGHOSTP" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:error, %{reason: "room_unavailable"}} =
             QuizSocket
             |> socket("p1", %{player_id: "p1"})
             |> subscribe_and_join(QuizChannel, "quiz:room:" <> bogus, %{"name" => "Alice"})

    assert Barkpark.Quiz.Room.whereis(bogus) == nil
  end

  test "an observer join to a pin nobody hosts is rejected without spawning a room" do
    bogus = "TGHOSTO" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:error, %{reason: "room_unavailable"}} =
             QuizSocket
             |> socket("obs", %{player_id: "obs"})
             |> subscribe_and_join(QuizChannel, "quiz:room:" <> bogus, %{"observe" => true})

    assert Barkpark.Quiz.Room.whereis(bogus) == nil
  end

  test "scanned bogus pins leave the room Registry untouched (no ghost rooms)" do
    count_before = Registry.count(Barkpark.Quiz.RoomRegistry)

    for i <- 1..3 do
      bogus = "TSCAN#{System.unique_integer([:positive])}x#{i}"

      assert {:error, %{reason: "room_unavailable"}} =
               QuizSocket
               |> socket("p#{i}", %{player_id: "p#{i}"})
               |> subscribe_and_join(QuizChannel, "quiz:room:" <> bogus, %{"name" => "Scan"})

      assert {:error, %{reason: "room_unavailable"}} =
               QuizSocket
               |> socket("o#{i}", %{player_id: "o#{i}"})
               |> subscribe_and_join(QuizChannel, "quiz:room:" <> bogus, %{"observe" => true})

      assert Barkpark.Quiz.Room.whereis(bogus) == nil
    end

    assert Registry.count(Barkpark.Quiz.RoomRegistry) == count_before
  end

  test "a player's cursor socket re-joining with the same id does not double-count", %{pin: pin} do
    # First "join" = the LiveView identity; the second = the cursor canvas socket
    # presenting the same signed id. One human → one player.
    join_player(pin, "p1", "Alice")
    join_player(pin, "p1", "Player")
    assert Quiz.state(pin).player_count == 1
  end
end
