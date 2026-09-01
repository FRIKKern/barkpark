defmodule Barkpark.Quiz.RoomFsmTest do
  @moduledoc """
  P3 hq-p3-fsm: game-phase state machine — default :question (legacy-compatible),
  transitions broadcast {:phase, _, payload}, and answers are gated to :question.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz

  setup do
    pin = "TF" <> Integer.to_string(System.unique_integer([:positive]))
    # Joins never start rooms (Decision N) - the host (ensure) is the sole creator.
    {:ok, _pid} = Quiz.ensure_room(pin)
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  test "a new room defaults to :question so legacy answer flow works", %{pin: pin} do
    {:ok, snap} = Quiz.join(pin, "p1", "Alice")
    assert snap.phase == :question
    assert {:ok, _} = Quiz.submit_answer(pin, "p1", "a")
  end

  test "transitions move the phase and broadcast", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    Quiz.join(pin, "p1", "Alice")

    assert :ok = Quiz.reveal(pin)
    # No `answer:` here — it moved to the host-only topic (task-ae30cd243c2a943d).
    assert_receive {:quiz, ^pin, {:phase, :reveal, %{tally: _, scores: _}}}
    assert Quiz.state(pin).phase == :reveal

    assert :ok = Quiz.leaderboard(pin)
    assert_receive {:quiz, ^pin, {:phase, :leaderboard, %{scores: scores}}}
    assert is_list(scores)
    assert Quiz.state(pin).phase == :leaderboard

    assert :ok = Quiz.end_game(pin)
    assert_receive {:quiz, ^pin, {:phase, :ended, _}}
    assert Quiz.state(pin).phase == :ended
  end

  test "answers are rejected outside :question", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    Quiz.reveal(pin)
    assert {:error, :wrong_phase} = Quiz.submit_answer(pin, "p1", "a")
  end

  test "start_question resets answers and reopens answering", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    Quiz.join(pin, "p1", "Alice")
    Quiz.submit_answer(pin, "p1", "a")
    Quiz.reveal(pin)

    assert :ok = Quiz.start_question(pin)
    assert_receive {:quiz, ^pin, {:phase, :question, %{question: _, tally: %{"a" => 0}}}}
    assert Quiz.state(pin).phase == :question
    assert {:ok, _} = Quiz.submit_answer(pin, "p1", "b")
  end

  test "to_lobby moves to :lobby and locks answers", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    assert :ok = Quiz.to_lobby(pin)
    assert Quiz.state(pin).phase == :lobby
    assert {:error, :wrong_phase} = Quiz.submit_answer(pin, "p1", "a")
  end
end
