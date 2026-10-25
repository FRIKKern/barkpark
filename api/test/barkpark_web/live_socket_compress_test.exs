defmodule BarkparkWeb.LiveSocketCompressTest do
  @moduledoc """
  The `/live` websocket accepts `permessage-deflate` (task-cca3c6d48e57097e).

  A Studio document join reply is 120 to 200 KB of JSON. Deflated it is about
  a sixth of that, which is fewer round trips on a fresh connection before the
  editor is live. Phoenix passes `compress: true` to the websocket upgrade, and
  Bandit then answers a browser's extension offer. A client that offers no
  extension still gets plain frames.
  """
  use ExUnit.Case, async: true

  test "the /live websocket transport enables per-message compression" do
    {"/live", Phoenix.LiveView.Socket, opts} =
      Enum.find(BarkparkWeb.Endpoint.__sockets__(), &(elem(&1, 0) == "/live"))

    websocket = Keyword.fetch!(opts, :websocket)

    assert Keyword.get(websocket, :compress) == true
    # The per-document size cap stays where it was.
    assert Keyword.get(websocket, :max_frame_size) == 10_000_000
  end
end
