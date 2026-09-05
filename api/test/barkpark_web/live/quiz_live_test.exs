defmodule BarkparkWeb.QuizLiveTest do
  @moduledoc """
  P1 tests for the host/projector + player LiveViews: render, answer, and a
  live cross-surface update (a player's answer moves the host's tally).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Quiz}

  setup do
    pin = "T" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  # Borrowed from bridge_test.exs: register the quiz schema, then create +
  # publish a quiz doc (load_question reads the published perspective).
  defp publish_quiz(qid, prompt, choices) do
    Content.upsert_schema(
      %{
        "name" => "quiz",
        "title" => "Quiz",
        "visibility" => "public",
        "fields" => Quiz.Content.schema().fields
      },
      "production"
    )

    {:ok, _} =
      Content.upsert_document(
        "quiz",
        %{"doc_id" => qid, "prompt" => prompt, "choices" => choices},
        "production"
      )

    {:ok, _} = Content.publish_document(qid, "quiz", "production")
  end

  test "host renders the question, join URL, and player count", %{conn: conn, pin: pin} do
    {:ok, _view, html} = live(conn, "/quiz/host/#{pin}")
    assert html =~ "Hyperquiz"
    assert html =~ "powers Barkpark"
    assert html =~ "players"
    assert html =~ "/quiz/play/#{pin}"
  end

  test "player renders choices and can lock in an answer", %{conn: conn, pin: pin} do
    # Joins never start rooms (Decision N) — the host is the sole creator.
    {:ok, _pid} = Quiz.ensure_room(pin)
    {:ok, view, html} = live(conn, "/quiz/play/#{pin}")
    assert html =~ "powers Barkpark"

    after_click = view |> element("button.c0") |> render_click()
    assert after_click =~ "Answer locked in"
  end

  test "a player's answer updates the host tally live", %{conn: conn, pin: pin} do
    {:ok, host, _} = live(conn, "/quiz/host/#{pin}")
    {:ok, player, _} = live(conn, "/quiz/play/#{pin}")

    player |> element("button.c0") |> render_click()

    assert render(host) =~ "1 answers in"
  end

  test "a connected mount on a pin nobody hosts shows the honest no-host state and never spawns a room",
       %{conn: conn, pin: pin} do
    # Decision N: the setup pin has no host — the join must be refused at the
    # primitive (no ghost room), and the player sees the quiet honest state.
    {:ok, _view, html} = live(conn, "/quiz/play/#{pin}")
    assert html =~ "Nobody is hosting this room right now"
    assert Barkpark.Quiz.Room.whereis(pin) == nil
  end

  test "a bare GET to the player page renders without starting a room", %{conn: conn, pin: pin} do
    conn = get(conn, "/quiz/play/#{pin}")
    assert html_response(conn, 200) =~ "Connecting to the room"
    assert Barkpark.Quiz.Room.whereis(pin) == nil
  end

  test "a bare GET to the host page renders without starting a room", %{conn: conn, pin: pin} do
    conn = get(conn, "/quiz/host/#{pin}")
    assert html_response(conn, 200) =~ "Hyperquiz"
    assert Barkpark.Quiz.Room.whereis(pin) == nil
  end

  test "host with ?quiz=<id> binds the room and renders the bound question", %{
    conn: conn,
    pin: pin
  } do
    qid = "quiz-#{System.unique_integer([:positive])}"
    publish_quiz(qid, "WHO HOSTS THE GAME?", [%{"id" => "a", "label" => "A", "correct" => true}])

    {:ok, _view, html} = live(conn, "/quiz/host/#{pin}?quiz=#{qid}")

    assert html =~ "WHO HOSTS THE GAME?"
    assert Quiz.state(pin).question.prompt == "WHO HOSTS THE GAME?"
  end

  test "host with a garbage ?quiz= degrades to the default question", %{conn: conn, pin: pin} do
    {:ok, _view, html} = live(conn, "/quiz/host/#{pin}?quiz=no-such-quiz-#{pin}")

    # bind_quiz silently no-ops on an unpublished id, so the room keeps its
    # hardcoded default question ("What powers Barkpark's realtime layer?").
    assert html =~ "powers Barkpark"
    assert Quiz.state(pin).question.prompt =~ "powers Barkpark"
  end

  test "a live question swap re-renders the host (P4 live-edit)", %{conn: conn, pin: pin} do
    {:ok, host, _} = live(conn, "/quiz/host/#{pin}")

    swapped = %{id: "q2", prompt: "SWAPPED LIVE", image: nil, choices: [%{id: "x", label: "X"}]}

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Barkpark.Quiz.room_topic(pin),
      {:quiz, pin, {:question_updated, swapped}}
    )

    assert render(host) =~ "SWAPPED LIVE"
  end

  describe "room capacity refusal on the host mount" do
    # `Room.ensure/1` returns `{:error, :max_children}` BY DESIGN once
    # `Quiz.RoomSupervisor` is at its cap (plugins/quiz.ex: max_children 10_000,
    # "a memory-DoS backstop"). Filling 10_000 rooms in a test is not the point —
    # the REFUSAL is. So the registered name `Barkpark.Quiz.RoomSupervisor` is
    # re-pointed for the duration of these tests at a DynamicSupervisor with
    # `max_children: 0`, which makes the REAL `Room.ensure/1` take its REAL
    # refusal branch through the REAL router and the REAL mount. The plugin's own
    # supervisor is never terminated — only the name is swapped and restored —
    # so nothing in the supervision tree restarts. Safe because this module is
    # `async: false` (ExUnit runs no other module concurrently with it).
    setup do
      real = Process.whereis(Barkpark.Quiz.RoomSupervisor)
      assert is_pid(real), "the quiz plugin must be running for this fixture to mean anything"

      Process.unregister(Barkpark.Quiz.RoomSupervisor)

      {:ok, full} =
        DynamicSupervisor.start_link(
          strategy: :one_for_one,
          max_children: 0,
          name: Barkpark.Quiz.RoomSupervisor
        )

      Process.unlink(full)

      on_exit(fn ->
        if Process.alive?(full), do: Supervisor.stop(full)
        Process.register(real, Barkpark.Quiz.RoomSupervisor)
      end)

      :ok
    end

    test "the fixture really does produce the refusal (non-vacuity)", %{pin: pin} do
      assert Quiz.ensure_room(pin) == {:error, :max_children}
    end

    test "the host mount degrades to an honest capacity state instead of MatchError-ing",
         %{conn: conn, pin: pin} do
      # Pre-fix this line RAISES: `{:ok, _pid} = Quiz.ensure_room(pin)` is a
      # MatchError inside the connected mount, so `live/2` never returns.
      {:ok, view, html} = live(conn, "/quiz/host/#{pin}")

      assert html =~ "at room capacity"
      assert html =~ "q-status"
      # The recovery path is REACHABLE, not just described in prose.
      assert html =~ ~s(href="/quiz/host/#{pin}")
      # And the room view is NOT rendered against an absent room. Refute on the
      # QUESTION text, not on a class name: the quiz root layout inlines the
      # whole stylesheet, so `refute html =~ "q-bar-track"` matches the CSS rule
      # and fails even when no bar is rendered.
      refute html =~ "powers Barkpark"
      # The view is a live, mounted process — not a crashed one the client
      # will reconnect-loop against.
      assert render(view) =~ "Hyperquiz"
    end
  end
end
