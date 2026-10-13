defmodule BarkparkWeb.QuizHostFloodControlsTest do
  @moduledoc """
  Owner ruling #59: the host can lock a room and remove a player from the
  projector, and the phone says why it cannot join. A second browser on the
  host URL gets no controls, and sending the events does nothing.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.Quiz

  setup do
    pin = "QF#{System.unique_integer([:positive])}"
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  defp browser,
    do:
      scoped_conn()
      |> Plug.Test.init_test_session(%{
        "_csrf_token" => Base.url_encode64(:crypto.strong_rand_bytes(18))
      })

  test "the host locks the room; a new phone is told it is locked; unlock lets it in", %{pin: pin} do
    {:ok, host, _} = live(browser(), "/quiz/host/#{pin}")
    {:ok, _inside, _} = live(browser(), "/quiz/play/#{pin}")

    host |> element(~s{button[phx-value-action="lock"]}) |> render_click()
    assert Quiz.state(pin).locked
    assert render(host) =~ "The room is locked"

    {:ok, _late, html} = live(browser(), "/quiz/play/#{pin}")
    assert html =~ "The host has locked this room"
    assert Quiz.state(pin).player_count == 1

    host |> element(~s{button[phx-value-action="unlock"]}) |> render_click()
    refute Quiz.state(pin).locked
    {:ok, _late, html} = live(browser(), "/quiz/play/#{pin}")
    refute html =~ "locked this room"
    assert Quiz.state(pin).player_count == 2
  end

  test "the host removes a player; that phone says so and the count drops", %{pin: pin} do
    {:ok, host, _} = live(browser(), "/quiz/host/#{pin}")
    {:ok, phone, _} = live(browser(), "/quiz/play/#{pin}")
    assert Quiz.state(pin).player_count == 1

    [%{id: player_id}] = Quiz.state(pin).players

    host
    |> element(~s{button[phx-click="kick"][phx-value-player="#{player_id}"]})
    |> render_click()

    assert Quiz.state(pin).player_count == 0
    assert render(phone) =~ "The host removed you from this room"
    assert {:error, :kicked} = Quiz.join(pin, player_id, "again")
  end

  test "a second browser on the host URL cannot lock or kick", %{pin: pin} do
    {:ok, _host, _} = live(browser(), "/quiz/host/#{pin}")
    {:ok, _phone, _} = live(browser(), "/quiz/play/#{pin}")
    [%{id: player_id}] = Quiz.state(pin).players

    {:ok, other, html} = live(browser(), "/quiz/host/#{pin}")
    refute html =~ "Lock room"

    render_click(other, "host", %{"action" => "lock"})
    render_click(other, "kick", %{"player" => player_id})

    refute Quiz.state(pin).locked
    assert Quiz.state(pin).player_count == 1
  end
end
