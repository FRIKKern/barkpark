defmodule Barkpark.Quiz.RoomSecurityTest do
  @moduledoc """
  Pre-merge hardening (ultracode review): the correct answer must never reach
  players before :reveal, and a malformed live-edit must not be able to crash a
  room.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz

  setup do
    pin = "TSEC" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  test "the room snapshot's question does NOT carry the answer", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    q = Quiz.state(pin).question
    refute Map.has_key?(q, :answer)
    # but the choices are still there to render
    assert is_list(q.choices)
  end

  test "the start_question phase broadcast omits the answer (players can't cheat)", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    Quiz.join(pin, "p1", "Alice")
    Quiz.start_question(pin, 10)

    assert_receive {:quiz, ^pin, {:phase, :question, payload}}, 500
    refute Map.has_key?(payload.question, :answer)
  end

  test "the answer IS disclosed at :reveal (and only then)", %{pin: pin} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
    Quiz.join(pin, "p1", "Alice")
    Quiz.reveal(pin)

    assert_receive {:quiz, ^pin, {:phase, :reveal, %{answer: answer}}}, 500
    assert answer == "a"
  end

  test "apply_question rejects a malformed question without crashing the room", %{pin: pin} do
    Quiz.join(pin, "p1", "Alice")
    # No choices list — would crash compute_tally/hover_counts if stored.
    assert {:error, :invalid_question} = Quiz.apply_question(pin, %{prompt: "broken"})
    # Room is alive and still serving the previous (valid) question.
    assert is_list(Quiz.state(pin).question.choices)
  end
end
