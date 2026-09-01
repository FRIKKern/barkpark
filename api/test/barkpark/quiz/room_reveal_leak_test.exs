defmodule Barkpark.Quiz.RoomRevealLeakTest do
  @moduledoc """
  task-ae30cd243c2a943d — the answer key must not ride the SHARED room events
  topic.

  `Room.topic/1` (`quiz:events:<pin>`) is subscribed by BOTH roles: the
  projector (`QuizChannel`'s `observe: true` join, and `QuizHostLive.mount/3`)
  and every anonymous player phone (`QuizChannel`'s player join, and
  `QuizPlayLive.mount/3`). There is no per-role filtering on it. So any
  answer-carrying term broadcast there is one `handle_info` clause away from
  every player socket — which is precisely the clause the paired row wires up.

  The projector legitimately needs the answer at `:reveal`. It therefore rides
  `Room.host_topic/1` (`quiz:host:<pin>`), which no player join subscribes to,
  instead of the shared events topic.

  Every assertion is scoped to this test's own PIN and its own marker answer id,
  so a failure here can never be another agent's fixture.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz

  # A distinctive id, so `refute inspect(payload) =~ @marker` is a REAL
  # assertion — "a"/"b" would collide with half the atoms in the payload.
  @marker "zq7-correct-marker"

  setup do
    pin = "TLEAK" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _pid} = Quiz.ensure_room(pin)
    on_exit(fn -> Quiz.stop_room(pin) end)

    :ok =
      Quiz.apply_question(pin, %{
        id: "q-leak",
        prompt: "Which choice is the marked one?",
        answer: @marker,
        time_limit: 20,
        choices: [
          %{id: @marker, label: "The correct one"},
          %{id: "zq7-wrong-1", label: "Not it"},
          %{id: "zq7-wrong-2", label: "Also not it"}
        ]
      })

    %{pin: pin}
  end

  describe "the shared events topic (every player phone is on it)" do
    test "the :reveal payload does NOT carry the answer", %{pin: pin} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
      Quiz.join(pin, "p1", "Alice")
      Quiz.start_question(pin, 20)
      assert_receive {:quiz, ^pin, {:phase, :question, _}}, 500

      Quiz.reveal(pin)
      assert_receive {:quiz, ^pin, {:phase, :reveal, payload}}, 500

      refute Map.has_key?(payload, :answer)

      # Whole-payload sweep, not just an :answer probe — but the marker is also
      # a CHOICE id, so it legitimately keys the tally. Drop that one carrier;
      # anything else mentioning the marker is an answer leak.
      refute inspect(Map.drop(payload, [:tally])) =~ @marker
    end

    test "the :reveal payload still carries tally + scores (the phone's reveal view)",
         %{pin: pin} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
      Quiz.join(pin, "p1", "Alice")
      Quiz.start_question(pin, 20)
      assert_receive {:quiz, ^pin, {:phase, :question, _}}, 500
      Quiz.submit_answer(pin, "p1", @marker)

      Quiz.reveal(pin)
      assert_receive {:quiz, ^pin, {:phase, :reveal, payload}}, 500

      # The strip removes ONLY :answer — the reveal is still renderable.
      assert Map.get(payload.tally, @marker) == 1
      assert [%{id: "p1"} | _] = payload.scores
    end

    test "NO term broadcast across a full phase cycle carries the marker", %{pin: pin} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
      Quiz.join(pin, "p1", "Alice")
      Quiz.start_question(pin, 20)
      Quiz.submit_answer(pin, "p1", @marker)
      Quiz.hover(pin, "p1", @marker)
      Quiz.reveal(pin)
      Quiz.leaderboard(pin)
      Quiz.end_game(pin)
      Quiz.to_lobby(pin)

      leaked = drain_leaked(pin, [])
      assert leaked == []
    end
  end

  describe "the host topic (the projector's reveal source)" do
    test "the projector still receives the answer at :reveal", %{pin: pin} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.host_topic(pin))
      Quiz.join(pin, "p1", "Alice")
      Quiz.start_question(pin, 20)

      Quiz.reveal(pin)

      assert_receive {:quiz, ^pin, {:reveal_answer, answer}}, 500
      assert answer == @marker
    end

    test "a player-topic subscriber is NOT on the host topic", %{pin: pin} do
      # Subscribing to the events topic must not deliver the host term — this is
      # what makes the split a boundary rather than a rename.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Quiz.room_topic(pin))
      Quiz.join(pin, "p1", "Alice")
      Quiz.reveal(pin)

      assert_receive {:quiz, ^pin, {:phase, :reveal, _}}, 500
      refute_receive {:quiz, ^pin, {:reveal_answer, _}}, 200
    end
  end

  # Collect every events-topic message whose inspected form contains the marker
  # ANYWHERE (key, value, or nested) — a whole-payload sweep, not a :answer probe.
  defp drain_leaked(pin, acc) do
    receive do
      {:quiz, ^pin, term} ->
        acc = if inspect(term) =~ @marker, do: [strip_choices(term) | acc], else: acc
        drain_leaked(pin, acc)
    after
      300 -> acc |> Enum.reject(&is_nil/1) |> Enum.reverse()
    end
  end

  # The marker is also a CHOICE id, which legitimately rides question payloads.
  # Drop the choices/tally/hover_counts carriers so only an ANSWER leak survives.
  defp strip_choices({:phase, phase, payload}) when is_map(payload),
    do: scrub({:phase, phase, scrub_payload(payload)})

  defp strip_choices({:question_updated, q}),
    do: scrub({:question_updated, Map.drop(q, [:choices])})

  defp strip_choices({:tally, _}), do: nil
  defp strip_choices({:hover_counts, _}), do: nil
  defp strip_choices(other), do: scrub(other)

  defp scrub_payload(payload) do
    payload
    |> Map.drop([:tally, :hover_counts])
    |> Map.replace_lazy(:question, &Map.drop(&1, [:choices]))
  end

  defp scrub(term), do: if(inspect(term) =~ @marker, do: term, else: nil)
end
