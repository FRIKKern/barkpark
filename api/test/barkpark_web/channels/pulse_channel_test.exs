defmodule BarkparkWeb.PulseChannelTest do
  @moduledoc """
  Shared Storm realtime — the anonymous PulseSocket/PulseChannel feed:
  configured-channel join (with the durable total in the reply), unknown
  channel refused, and the controller's POST → broadcast → subscriber push
  loop, including the optional `chg` field defaulting for older clients.
  """

  use BarkparkWeb.ChannelCase, async: false

  alias Barkpark.Pulse

  @valid %{"hue" => 200, "x" => 0.5, "y" => 0.25, "mega" => false, "chg" => 0.8}

  defp join!(name) do
    {:ok, reply, socket} =
      BarkparkWeb.PulseSocket
      |> socket(nil, %{})
      |> subscribe_and_join(BarkparkWeb.PulseChannel, "pulse:" <> name)

    {reply, socket}
  end

  test "join on a configured channel replies with the durable total" do
    {:ok, _} = Pulse.record_event("test-storm", Map.delete(@valid, "chg"))
    total = Pulse.total("test-storm")
    {reply, _socket} = join!("test-storm")
    assert reply == %{total: total}
  end

  test "join on an unknown channel fails closed" do
    assert {:error, %{reason: "unknown pulse channel"}} =
             BarkparkWeb.PulseSocket
             |> socket(nil, %{})
             |> subscribe_and_join(BarkparkWeb.PulseChannel, "pulse:nope")
  end

  test "anonymous socket connects without params" do
    assert {:ok, _socket} = connect(BarkparkWeb.PulseSocket, %{})
  end

  test "HTTP POST broadcasts the strike to subscribers, chg carried through" do
    {_reply, _socket} = join!("test-storm")

    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:remote_ip, {203, 0, 113, 99})
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.dispatch(
        BarkparkWeb.Endpoint,
        :post,
        "/v1/plugins/pulse/test-storm/events",
        Jason.encode!(@valid)
      )

    assert %{"ok" => true, "id" => id, "total" => total} =
             Phoenix.ConnTest.json_response(conn, 200)

    assert_broadcast "strike", %{id: ^id, total: ^total, payload: payload}
    assert payload["chg"] == 0.8
    assert payload["hue"] == 200
  end

  test "a client omitting the optional chg field still validates — default 0" do
    {:ok, cfg} = Pulse.channel("test-storm")
    assert {:ok, clean} = Pulse.validate_payload(cfg, Map.delete(@valid, "chg"))
    assert clean["chg"] == 0
  end
end
