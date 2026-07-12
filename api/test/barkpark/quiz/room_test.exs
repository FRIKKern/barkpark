defmodule Barkpark.Quiz.RoomTest do
  @moduledoc """
  P1 walking-skeleton tests for the per-room quiz GenServer: lifecycle (rooms
  start ONLY via ensure/1 — joins never spawn one, the ghost-room guard),
  join, answer tallying (last-write-wins), validation, and live PubSub fan-out.
  Each test uses a unique PIN so they stay independent under async.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz

  setup do
    pin = "T" <> Integer.to_string(System.unique_integer([:positive]))
    # Joins never start rooms (Decision N) — mirror production: the host mount
    # (ensure) creates the room, then players join it.
    {:ok, _pid} = Quiz.ensure_room(pin)
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  test "join on a live room returns a snapshot", %{pin: pin} do
    assert Quiz.room_topic(pin) == "quiz:events:" <> pin
    assert {:ok, snapshot} = Quiz.join(pin, "p1", "Alice")
    assert snapshot.pin == pin
    assert snapshot.player_count == 1
    assert [%{id: "p1", name: "Alice"}] = snapshot.players
    assert length(snapshot.question.choices) == 4
  end

  test "tally counts answers per choice", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.join(pin, "p2", "Bob")
    assert {:ok, _} = Quiz.submit_answer(pin, "p1", "a")
    assert {:ok, _} = Quiz.submit_answer(pin, "p2", "a")

    tally = Quiz.tally(pin)
    assert tally["a"] == 2
    assert tally["b"] == 0
  end

  test "last answer per player wins", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.submit_answer(pin, "p1", "a")
    Quiz.submit_answer(pin, "p1", "b")

    tally = Quiz.tally(pin)
    assert tally["a"] == 0
    assert tally["b"] == 1
  end

  test "rejects answer from a non-joined player", %{pin: pin} do
    assert {:error, :not_joined} = Quiz.submit_answer(pin, "ghost", "a")
  end

  test "rejects an invalid choice", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    assert {:error, :invalid_choice} = Quiz.submit_answer(pin, "p1", "zzz")
  end

  test "leave removes the player and their answer", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.submit_answer(pin, "p1", "a")
    assert :ok = Quiz.leave(pin, "p1")

    state = Quiz.state(pin)
    assert state.player_count == 0
    assert state.tally["a"] == 0
  end

  test "broadcasts join and tally over PubSub", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))

    Quiz.join(pin, "p1", "Alice")
    assert_receive {:quiz, ^pin, {:player_joined, %{id: "p1", name: "Alice"}, 1}}

    Quiz.submit_answer(pin, "p1", "a")
    assert_receive {:quiz, ^pin, {:tally, %{"a" => 1}}}
  end

  test "re-join of an existing player does not re-broadcast player_joined", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    Quiz.join(pin, "p1", "Alice")
    assert_receive {:quiz, ^pin, {:player_joined, %{id: "p1"}, 1}}
    Quiz.join(pin, "p1", "Alice Renamed")
    refute_receive {:quiz, ^pin, {:player_joined, _, _}}, 100
    # Idempotent: the same id re-joining (e.g. the cursor socket after the
    # LiveView) does not inflate the count — one human, one player.
    assert Quiz.state(pin).player_count == 1
  end

  test "leave broadcasts player_left with the authoritative count + cursor slot", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    Quiz.join(pin, "p1", "Alice")
    Quiz.join(pin, "p2", "Bob")
    Quiz.leave(pin, "p1")
    # 4-tuple: player_id, the freed cursor SLOT (for canvas eviction), count.
    assert_receive {:quiz, ^pin, {:player_left, "p1", slot, 1}}
    assert is_integer(slot)
  end

  test "a freed cursor slot is recycled by the next joiner (no u16 growth)", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.join(pin, "p2", "Bob")
    slot_p1 = Enum.find(Quiz.state(pin).players, &(&1.id == "p1")).slot
    Quiz.leave(pin, "p1")
    Quiz.join(pin, "p3", "Carol")
    assert Enum.find(Quiz.state(pin).players, &(&1.id == "p3")).slot == slot_p1
  end

  test "join/leave/tally/state/submit never start (or resurrect) a room" do
    # A pin nobody ever hosted — the setup pin is pre-ensured, so use our own.
    pin = "TNOROOM" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:error, :no_room} = Quiz.join(pin, "p1", "Alice")
    assert Barkpark.Quiz.Room.whereis(pin) == nil

    assert :ok = Quiz.leave(pin, "ghost")
    assert Barkpark.Quiz.Room.whereis(pin) == nil

    assert Quiz.tally(pin) == %{}
    assert %{player_count: 0, question: nil} = Quiz.state(pin)
    assert {:error, :no_room} = Quiz.submit_answer(pin, "p1", "a")
    assert Barkpark.Quiz.Room.whereis(pin) == nil
  end

  test "second ensure_room returns the same live pid", %{pin: pin} do
    assert {:ok, pid} = Quiz.ensure_room(pin)
    assert {:ok, ^pid} = Quiz.ensure_room(pin)
  end
end
