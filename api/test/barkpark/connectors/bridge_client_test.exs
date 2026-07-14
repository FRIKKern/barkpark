defmodule Barkpark.Connectors.BridgeClientTest do
  @moduledoc """
  THE WIRE, over a real socket (Connectors D50/D51).

  Everything else in the Connectors suite drives a STUB bridge, so it proves the
  LiveView's logic and proves nothing whatever about the wire. This file is the
  other half: a real loopback listener that answers with the EXACT bytes
  `connectors/src/http/connect.ts` answers with — status code and body shape both,
  transcribed from it — driven through the REAL `BridgeClient` (Req, JSON
  encoding, status mapping, timeout).

  It catches the one class of bug no single-language gate can see. The two halves
  of this wave were built IN PARALLEL against a wire that existed only in the
  charter: a `{installKey}` where the reader wants `{install_key}`, or
  `/connect/validate` mounted under a different prefix, is green on both sides and
  broken in production. The golden vector (`connect_ticket_test.exs`) pins the
  ticket BYTES; this pins the REQUEST PATHS, the REQUEST KEYS and the RESPONSE
  SHAPES around it.

  Change a response literal in `connect.ts` and this file must red.
  """
  # Not async: it rewrites the `Barkpark.Connectors` application env.
  use ExUnit.Case, async: false

  alias Barkpark.Connectors.BridgeClient

  # ── A bridge made of bytes ────────────────────────────────────────────────
  #
  # Deliberately NOT a Plug: the thing under test is a byte-level contract with a
  # Node process, so the double answers with bytes rather than with another
  # Elixir web stack's idea of what those bytes should be.

  defp fake_bridge(status, body) do
    test = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 5_000)
      {head, rest} = read_until_headers(socket, "")
      [request_line | header_lines] = String.split(head, "\r\n")
      [_method, path | _] = String.split(request_line, " ")

      length =
        Enum.find_value(header_lines, 0, fn line ->
          case String.split(line, ":", parts: 2) do
            [name, value] ->
              if String.downcase(String.trim(name)) == "content-length",
                do: String.to_integer(String.trim(value))

            _ ->
              nil
          end
        end)

      raw = rest <> read_exactly(socket, length - byte_size(rest))
      send(test, {:bridge_request, path, Jason.decode!(raw)})

      payload = Jason.encode!(body)

      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} X\r\n",
        "content-type: application/json\r\n",
        "content-length: #{byte_size(payload)}\r\n",
        "connection: close\r\n\r\n",
        payload
      ])

      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp read_until_headers(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        {head, rest}

      _ ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
        read_until_headers(socket, acc <> chunk)
    end
  end

  defp read_exactly(_socket, size) when size <= 0, do: ""

  defp read_exactly(socket, size) do
    {:ok, chunk} = :gen_tcp.recv(socket, size, 5_000)
    chunk
  end

  defp point_at(port) do
    previous = Application.get_env(:barkpark, Barkpark.Connectors, [])

    Application.put_env(
      :barkpark,
      Barkpark.Connectors,
      Keyword.put(previous, :bridge_url, "http://127.0.0.1:#{port}/connectors")
    )

    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Connectors, previous) end)
  end

  # ── The three routes ──────────────────────────────────────────────────────

  test "VALIDATE posts {ticket, credential} to {prefix}/connect/validate and reads snake_case back" do
    # connect.ts: 200 {ok, provider, install_key, display_name}
    fake_bridge(200, %{
      ok: true,
      provider: "telegram",
      install_key: "77777777",
      display_name: "@acme_bot"
    })
    |> point_at()

    assert {:ok, %{install_key: "77777777", display_name: "@acme_bot"}} =
             BridgeClient.validate("tkt", "77777777:AA-token")

    # The PATH and the BODY KEYS are the contract, so they are asserted, not
    # assumed: `/connect/validate` under the bridge's OWN `/connectors` prefix
    # (Caddy does not strip it — getting this wrong 404s every connect), carrying
    # exactly the two keys `handleConnectRequest` reads.
    assert_receive {:bridge_request, "/connectors/connect/validate", body}
    assert body == %{"ticket" => "tkt", "credential" => "77777777:AA-token"}
  end

  test "CONNECT posts {ticket, credential, chat_token} and reads {ok, install_key, mounted}" do
    fake_bridge(200, %{
      ok: true,
      provider: "telegram",
      install_key: "77777777",
      workspace_id: "11111111-1111-4111-8111-111111111111",
      display_name: "@acme_bot",
      mounted: true
    })
    |> point_at()

    assert {:ok, %{install_key: "77777777", mounted: true}} =
             BridgeClient.connect("tkt", "77777777:AA-token", "bp_chat_raw")

    assert_receive {:bridge_request, "/connectors/connect", body}

    assert body == %{
             "ticket" => "tkt",
             "credential" => "77777777:AA-token",
             "chat_token" => "bp_chat_raw"
           }
  end

  test "DISCONNECT posts {ticket, install_key} and reads {ok, removed}" do
    fake_bridge(200, %{ok: true, provider: "telegram", install_key: "77777777", removed: true})
    |> point_at()

    assert {:ok, %{removed: true}} = BridgeClient.disconnect("tkt", "77777777")

    assert_receive {:bridge_request, "/connectors/disconnect", body}
    assert body == %{"ticket" => "tkt", "install_key" => "77777777"}
  end

  # ── The failure shapes ARE the product ────────────────────────────────────

  test "a 422 invalid_credential surfaces the PROVIDER's own words, not a status code" do
    # connect.ts: {status: 422, body: {error: "invalid_credential", reason}} —
    # `reason` is Telegram's/Discord's own message, and it is the whole point of
    # validate-first: the operator is told WHY at paste time.
    fake_bridge(422, %{error: "invalid_credential", reason: "Unauthorized"}) |> point_at()

    assert {:error, {:refused, "Unauthorized"}} = BridgeClient.validate("tkt", "bad")
  end

  test "a 502 mount_failed surfaces its REASON — a 5xx must not eat the one sentence that explains it" do
    fake_bridge(502, %{
      error: "mount_failed",
      reason:
        "the credential was accepted by the provider but the adapter refused to mount it. Nothing was installed."
    })
    |> point_at()

    assert {:error, {:refused, reason}} = BridgeClient.connect("tkt", "cred", "bp_chat_raw")
    assert reason =~ "Nothing was installed"
  end

  test "the seam's OPAQUE 404 becomes a sentence — never the machine token `not_found`" do
    # webhook-server.ts's single opaque failure, byte for byte: an unknown route,
    # an unmounted connect seam, an unconnectable provider and a CROSS-TENANT
    # disconnect all answer with THIS, on purpose (it must not be an
    # install-enumeration oracle). Which makes it a wire code — and a wire code
    # must never reach an operator's flash message as "Could not disconnect:
    # not_found".
    fake_bridge(404, %{error: "not_found"}) |> point_at()

    assert {:error, {:refused, reason}} = BridgeClient.disconnect("tkt", "77777777")
    refute reason == "not_found"
    assert reason =~ "did not recognise"
  end

  test "a 401 unauthorized ticket reads as an expired ticket, in words" do
    fake_bridge(401, %{error: "unauthorized"}) |> point_at()

    assert {:error, {:refused, reason}} = BridgeClient.validate("stale", "cred")
    assert reason =~ "ticket"
  end

  test "an unreachable bridge is :unreachable — never a success, never a crash" do
    # Port 1 on loopback: nothing listens and the connect is refused immediately.
    previous = Application.get_env(:barkpark, Barkpark.Connectors, [])

    Application.put_env(
      :barkpark,
      Barkpark.Connectors,
      Keyword.put(previous, :bridge_url, "http://127.0.0.1:1/connectors")
    )

    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Connectors, previous) end)

    assert {:error, :unreachable} = BridgeClient.validate("tkt", "cred")
  end
end
