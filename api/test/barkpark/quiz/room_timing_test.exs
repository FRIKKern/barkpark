defmodule Barkpark.Quiz.RoomTimingTest do
  @moduledoc """
  P6 hq-p6-timing: scoring is fair via SERVER-recorded answer times — a player
  who answers earlier (more clock remaining) scores at least as high as a later
  one. Clients cannot influence this (timestamps are server-side, not trusted
  from the wire).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz

  setup do
    pin = "TM" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  defp score(pin, id), do: Enum.find(Quiz.state(pin).scores, &(&1.id == id)).score

  test "earlier answer scores >= later answer (server-timed)", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.join(pin, "p2", "Bob")
    Quiz.start_question(pin, 5)

    Quiz.submit_answer(pin, "p1", "a")
    Process.sleep(60)
    Quiz.submit_answer(pin, "p2", "a")
    Quiz.reveal(pin)

    assert score(pin, "p1") >= score(pin, "p2")
    assert score(pin, "p1") > 0
  end

  test "speed uses the ARMED round duration, not the question's time_limit", %{pin: pin} do
    # Default question time_limit is 20s; arm a SHORT 1s round. An immediate
    # answer must score near-full (~1000) — proving the denominator is the armed
    # 1s, not 20s (which would cap an instant answer at ~1000*remaining/20).
    Quiz.join(pin, "p1", "Alice")
    Quiz.start_question(pin, 1)
    Quiz.submit_answer(pin, "p1", "a")
    Quiz.reveal(pin)

    assert score(pin, "p1") >= 950
  end
end
