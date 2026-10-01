defmodule BarkparkWeb.QuizHostRebindTest do
  @moduledoc """
  A live Quiz room's quiz can be swapped only by the host browser that bound it
  (task-680f88266f783346).

  `/quiz/host/:pin?quiz=<id>` called `Quiz.bind_quiz(pin, id)` for ANY visitor
  (the route is anonymous, `:public_root`), and a rebind replaces the room's
  quiz for everyone. Players read the PIN off the projector, so any of them could
  open the host URL with another quiz id and hijack the game. The host surface
  now binds as its browser session (`Bridge.bind_as_host/4`): the first host
  owns the PIN for the room's lifetime, a refresh or a new `?quiz=` from that
  same session still rebinds, and another session is refused.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the quiz plugin (Barkpark.Quiz.RoomRegistry and its /quiz routes)
  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.Quiz

  setup do
    pin = "QR#{System.unique_integer([:positive])}"
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  # Two browsers = two sessions, each with its own (validly shaped) CSRF token.
  defp session_token, do: Base.url_encode64(:crypto.strong_rand_bytes(18))

  defp browser(token),
    do: scoped_conn() |> Plug.Test.init_test_session(%{"_csrf_token" => token})

  defp bound_quiz(pin) do
    Quiz.Bridge.bindings()
    |> Enum.find_value(fn {quiz_id, pins} -> if Map.has_key?(pins, pin), do: quiz_id end)
  end

  test "another browser cannot swap a live room's quiz; the host can", %{pin: pin} do
    host = session_token()
    {:ok, _host, _} = live(browser(host), "/quiz/host/#{pin}?quiz=quiz-host-a")
    assert bound_quiz(pin) == "quiz-host-a"

    {:ok, _player, _} = live(browser(session_token()), "/quiz/host/#{pin}?quiz=quiz-hijack")
    assert bound_quiz(pin) == "quiz-host-a", "a second browser swapped the live room's quiz"

    {:ok, _host_again, _} = live(browser(host), "/quiz/host/#{pin}?quiz=quiz-host-b")
    assert bound_quiz(pin) == "quiz-host-b", "the host itself must still be able to rebind"
  end
end
