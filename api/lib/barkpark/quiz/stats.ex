defmodule Barkpark.Quiz.Stats do
  @moduledoc """
  P6 observability for the hyperquiz layer. Cheap, read-only metrics for ops /
  a dashboard: how many rooms are live and, per room, players/cursors/phase.
  Rooms also emit a `[:barkpark, :quiz, :tick]` `:telemetry` event each ~15Hz
  tick (measurement `%{cursors: n}`, metadata `%{pin: pin}`).
  """

  alias Barkpark.Quiz

  @registry Barkpark.Quiz.RoomRegistry

  @doc "Number of live room processes."
  @spec live_room_count() :: non_neg_integer()
  def live_room_count, do: Registry.count(@registry)

  @doc "Per-room snapshot metrics: players, cursors, phase."
  @spec room_stats(String.t()) :: %{
          players: non_neg_integer(),
          cursors: non_neg_integer(),
          phase: atom()
        }
  def room_stats(pin) do
    s = Quiz.state(pin)
    %{players: s.player_count, cursors: Map.get(s, :cursor_count, 0), phase: s.phase}
  end
end
