defmodule Barkpark.Quiz.RoomCursorTest do
  @moduledoc """
  P2 hq-p2-tick tests: cursor slot assignment, the 15Hz batched delta broadcast
  on the distinct cursor topic, and leave/no-op cleanup. Uses the real ~15Hz
  tick (waits ≤500ms for a frame) rather than poking internals.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz
  alias Barkpark.Quiz.CursorFrame

  setup do
    pin = "TC" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  test "join assigns a distinct cursor slot per player", %{pin: pin} do
    {:ok, _} = Quiz.join(pin, "p1", "Alice")
    {:ok, snap} = Quiz.join(pin, "p2", "Bob")
    slots = snap.players |> Enum.map(& &1.slot)
    assert Enum.all?(slots, &is_integer/1)
    assert length(Enum.uniq(slots)) == 2
  end

  test "move + tick broadcasts a delta cursor frame on the cursor topic", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.cursor_topic(pin))
    {:ok, snap} = Quiz.join(pin, "p1", "Alice")
    slot = Enum.find(snap.players, &(&1.id == "p1")).slot

    Quiz.move(pin, "p1", 0.5, 0.25)
    assert_receive {:quiz_cursors, ^pin, frame}, 500

    decoded = CursorFrame.decode(frame)
    assert Map.has_key?(decoded, slot)
    {qx, qy} = decoded[slot]
    assert_in_delta CursorFrame.dequantize(qx), 0.5, 1.0e-3
    assert_in_delta CursorFrame.dequantize(qy), 0.25, 1.0e-3
  end

  test "a still cursor produces no further frame (delta is empty)", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.cursor_topic(pin))
    Quiz.join(pin, "p1", "Alice")
    Quiz.move(pin, "p1", 0.5, 0.5)
    assert_receive {:quiz_cursors, ^pin, _}, 500
    refute_receive {:quiz_cursors, ^pin, _}, 200
  end

  test "move from a non-joined player is ignored", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.cursor_topic(pin))
    {:ok, _} = Quiz.ensure_room(pin)
    Quiz.move(pin, "ghost", 0.5, 0.5)
    refute_receive {:quiz_cursors, ^pin, _}, 200
  end

  test "move on a missing room is a no-op and never starts one", %{pin: pin} do
    assert :ok = Quiz.move(pin, "p1", 0.1, 0.1)
    assert Barkpark.Quiz.Room.whereis(pin) == nil
  end
end
