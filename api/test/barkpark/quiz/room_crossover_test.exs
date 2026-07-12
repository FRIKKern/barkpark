defmodule Barkpark.Quiz.RoomCrossoverTest do
  @moduledoc """
  P5 hq-p5-crossover: the cursor tick emits individual frames at/below the
  threshold and a single aggregate heatmap above it.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz
  alias Barkpark.Quiz.Heatmap

  setup do
    pin = "TX" <> Integer.to_string(System.unique_integer([:positive]))
    # Joins never start rooms (Decision N) - the host (ensure) is the sole creator.
    {:ok, _pid} = Quiz.ensure_room(pin)
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  test "at/below the threshold: individual cursor frames", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.cursor_topic(pin))
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.heat_topic(pin))
    Quiz.join(pin, "p1", "Alice")
    Quiz.set_heatmap_threshold(pin, 10)

    Quiz.move(pin, "p1", 0.5, 0.5)
    assert_receive {:quiz_cursors, ^pin, _frame}, 500
    refute_received {:quiz_heat, ^pin, _}
  end

  test "above the threshold: one fixed-size aggregate heatmap (no individual frames)", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.cursor_topic(pin))
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.heat_topic(pin))
    for i <- 1..5, do: Quiz.join(pin, "p#{i}", "P#{i}")
    Quiz.set_heatmap_threshold(pin, 2)

    for i <- 1..5, do: Quiz.move(pin, "p#{i}", rem(i, 10) / 10, rem(i * 3, 10) / 10)

    assert_receive {:quiz_heat, ^pin, frame}, 500
    assert byte_size(frame) == Heatmap.byte_size_for(Heatmap.grid())
    assert frame |> Heatmap.decode() |> Enum.sum() > 0
    refute_received {:quiz_cursors, ^pin, _}
  end
end
