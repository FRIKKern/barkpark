defmodule Barkpark.Quiz.RoomScoreTest do
  @moduledoc """
  P3 hq-p3-score: speed-based scoring on reveal — correct answers score, wrong
  ones don't; streaks track consecutive correct; the leaderboard sorts desc.
  (Default question's answer is "a".)
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz

  setup do
    pin = "TS" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  defp score_for(pin, id), do: Enum.find(Quiz.state(pin).scores, &(&1.id == id))

  test "correct answer scores; wrong answer scores nothing", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.join(pin, "p2", "Bob")
    Quiz.submit_answer(pin, "p1", "a")
    Quiz.submit_answer(pin, "p2", "b")
    Quiz.reveal(pin)

    assert score_for(pin, "p1").score == 1000
    # p2 never scored → absent from the leaderboard
    assert score_for(pin, "p2") == nil
  end

  test "streak increments on consecutive correct, resets on wrong", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")

    Quiz.start_question(pin, 10)
    Quiz.submit_answer(pin, "p1", "a")
    Quiz.reveal(pin)
    assert score_for(pin, "p1").streak == 1

    Quiz.start_question(pin, 10)
    Quiz.submit_answer(pin, "p1", "a")
    Quiz.reveal(pin)
    p1 = score_for(pin, "p1")
    assert p1.streak == 2
    assert p1.score > 0

    Quiz.start_question(pin, 10)
    Quiz.submit_answer(pin, "p1", "b")
    Quiz.reveal(pin)
    after_wrong = score_for(pin, "p1")
    assert after_wrong.streak == 0
    assert after_wrong.score == p1.score
  end

  test "leaderboard is sorted highest-first", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.join(pin, "p2", "Bob")

    Quiz.submit_answer(pin, "p1", "a")
    Quiz.submit_answer(pin, "p2", "a")
    Quiz.reveal(pin)

    Quiz.start_question(pin)
    Quiz.submit_answer(pin, "p1", "a")
    Quiz.reveal(pin)

    scores = Quiz.state(pin).scores
    assert scores == Enum.sort_by(scores, & &1.score, :desc)
    assert hd(scores).id == "p1"
  end

  test "reveal broadcasts scores in the payload", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    Quiz.join(pin, "p1", "Alice")
    Quiz.submit_answer(pin, "p1", "a")
    Quiz.reveal(pin)
    assert_receive {:quiz, ^pin, {:phase, :reveal, %{scores: [%{id: "p1", score: 1000} | _]}}}
  end
end
