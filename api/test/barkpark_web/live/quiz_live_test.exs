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
end
