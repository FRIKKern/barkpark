defmodule Barkpark.Quiz.RoomLoadTest do
  @moduledoc """
  P2 hq-p2-load: ~200 players join one room and stream cursor moves. Asserts the
  room stays responsive, every broadcast frame is correctly sized (2 + 6·N), and
  the union of the ~15Hz delta frames covers all players. This is the
  individual-cursor path's target scale (the heatmap path for 10k+ is P5).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz
  alias Barkpark.Quiz.CursorFrame

  @players 200

  setup do
    pin = "TL" <> Integer.to_string(System.unique_integer([:positive]))
    # Joins never start rooms (Decision N) - the host (ensure) is the sole creator.
    {:ok, _pid} = Quiz.ensure_room(pin)
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  test "#{@players} players join, move, and frames are correctly sized + complete", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.cursor_topic(pin))

    for i <- 1..@players, do: assert({:ok, _} = Quiz.join(pin, "p#{i}", "P#{i}"))
    assert Quiz.state(pin).player_count == @players

    for i <- 1..@players do
      Quiz.move(pin, "p#{i}", rem(i, 100) / 100, rem(i * 7, 100) / 100)
    end

    # Union the delta frames over a short window: each frame must be exactly
    # 2 + 6·(its cursor count) bytes, and together they cover all players.
    seen = drain_frames(%{})
    assert map_size(seen) == @players

    # Room is still responsive after the burst.
    assert Quiz.state(pin).player_count == @players
  end

  test "hover at #{@players} players aggregates correctly", %{pin: pin} do
    for i <- 1..@players, do: Quiz.join(pin, "p#{i}", "P#{i}")
    for i <- 1..@players, do: Quiz.hover(pin, "p#{i}", Enum.at(~w(a b c d), rem(i, 4)))

    counts = Quiz.state(pin).hover_counts
    assert Enum.sum(Map.values(counts)) == @players
    assert counts["a"] == div(@players, 4)
  end

  defp drain_frames(acc) do
    receive do
      {:quiz_cursors, _pin, frame} ->
        decoded = CursorFrame.decode(frame)
        assert byte_size(frame) == CursorFrame.byte_size_for(map_size(decoded))
        drain_frames(Map.merge(acc, decoded))
    after
      400 -> acc
    end
  end
end
