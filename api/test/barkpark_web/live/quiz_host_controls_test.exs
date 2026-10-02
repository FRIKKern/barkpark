defmodule BarkparkWeb.QuizHostControlsTest do
  @moduledoc """
  The host screen drives the game (task-bcd33e6011241a4a).

  Found live (r4-lane-c dogfood, host + two players in Chrome): the host page
  showed the question and live tallies but had no controls at all. The room's
  phases (start with a countdown, reveal, scores, end) existed in
  `Barkpark.Quiz.Room` but nothing could reach them, so `time_limit` was never
  armed, the answer was never revealed and no score was ever shown.

  The owning host session (first host on the pin) now gets the controls, and
  every press is re-checked on the server. A second browser on the same host
  URL gets the projector without controls, cannot drive the room by sending the
  event, and never hears the host-only answer.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.Quiz

  setup do
    pin = "QC#{System.unique_integer([:positive])}"
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  defp session_token, do: Base.url_encode64(:crypto.strong_rand_bytes(18))

  defp browser(token \\ session_token()),
    do: scoped_conn() |> Plug.Test.init_test_session(%{"_csrf_token" => token})

  defp press(view, action),
    do: view |> element(~s{button[phx-value-action="#{action}"]}) |> render_click()

  test "the host starts the question with a countdown, reveals, shows scores and ends", %{
    pin: pin
  } do
    {:ok, host, html} = live(browser(), "/quiz/host/#{pin}")
    assert html =~ "Host controls"
    assert html =~ "Start question"

    {:ok, p1, _} = live(browser(), "/quiz/play/#{pin}")
    {:ok, p2, _} = live(browser(), "/quiz/play/#{pin}")

    press(host, "start")
    assert Quiz.state(pin).seconds_remaining > 0, "start arms the room's countdown"
    assert render(host) =~ ~r/\d+s left/

    # One player right, one wrong, on the room's default question.
    answer = Quiz.Room.default_question().answer
    wrong = Enum.find(Quiz.Room.default_question().choices, &(&1.id != answer)).id
    p1 |> element(~s{button[phx-value-choice="#{answer}"]}) |> render_click()
    p2 |> element(~s{button[phx-value-choice="#{wrong}"]}) |> render_click()

    press(host, "reveal")
    html = render(host)
    assert Quiz.state(pin).phase == :reveal
    assert html =~ "answers locked"
    assert render(host) =~ "✓", "the owner's screen marks the correct choice"
    assert render(p1) =~ "Answers are closed"

    press(host, "scores")
    html = render(host)
    assert html =~ "Scores"
    assert [%{score: top} | _] = Quiz.state(pin).scores
    assert top > 0
    assert html =~ Integer.to_string(top)

    press(host, "end")
    html = render(host)
    assert html =~ "Game over"
    assert Quiz.state(pin).phase == :ended
  end

  test "a second browser on the host URL gets no controls and cannot drive the room", %{
    pin: pin
  } do
    {:ok, _owner, _} = live(browser(), "/quiz/host/#{pin}")
    {:ok, other, html} = live(browser(), "/quiz/host/#{pin}")

    refute html =~ "Host controls"

    # The event is a public wire message: sending it must not move the room.
    render_hook(other, "host", %{"action" => "reveal"})
    assert Quiz.state(pin).phase == :question

    Quiz.reveal(pin)
    refute render(other) =~ "✓", "a non-owner never receives the host-only answer"
  end

  test "players are reopened when the host restarts the question", %{pin: pin} do
    {:ok, host, _} = live(browser(), "/quiz/host/#{pin}")
    {:ok, player, _} = live(browser(), "/quiz/play/#{pin}")

    press(host, "start")
    press(host, "reveal")
    assert render(player) =~ "Answers are closed"

    press(host, "start")
    html = render(host)
    assert html =~ "Restart question"
    refute render(player) =~ "Answers are closed"
    assert Quiz.state(pin).tally |> Map.values() |> Enum.sum() == 0
  end
end
