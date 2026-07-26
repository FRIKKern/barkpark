defmodule BarkparkCloud.Push.HTTPMintTest do
  @moduledoc """
  `BarkparkCloud.Push.HTTP.Mint` against a REAL socket — the first coverage this
  transport has had (it was the zero-coverage debt named in the #6122 review).

  The claim under test (task-17f14a4557cf7fe2 AC0): the receive loop runs in the
  CALLER's process — an Oban job — and used to CONSUME any message Mint did not
  recognise. A late GenServer reply, a `:DOWN`, Ecto-sandbox traffic: all silently
  destroyed inside the up-to-10s window. It now stashes foreign messages and
  re-delivers them once the request is done.

  The server is a one-shot `:gen_tcp` HTTP/1.1 responder on 127.0.0.1 that
  DELAYS its final write, so a message mailed mid-flight really does arrive while
  `collect/5` is blocked in `receive`.

  async: false — the tests own the calling process's mailbox and assert on its
  exact contents.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Push.HTTP.Mint, as: MintClient

  # A one-shot HTTP/1.1 server. `respond` gets the accepted socket and writes the
  # response however the test needs (in pieces, with delays).
  defp start_server(respond) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        packet: :raw,
        active: false,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      _ = read_request_head(socket, "")
      respond.(socket)
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp read_request_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_request_head(socket, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  defp get(port, extra \\ %{}) do
    Map.merge(
      %{
        method: :get,
        url: "http://127.0.0.1:#{port}/probe",
        headers: [{"accept", "application/json"}],
        body: nil,
        protocols: [:http1]
      },
      extra
    )
  end

  describe "request/1" do
    test "drives a real socket to a complete response" do
      port =
        start_server(fn socket ->
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nContent-Length: 8\r\n\r\n" <>
              ~s({"ok":1})
          )
        end)

      assert {:ok, %{status: 200, body: body, headers: headers}} = MintClient.request(get(port))
      assert body == ~s({"ok":1})
      assert {"content-type", "application/json"} in headers
    end

    test "a foreign mailbox message queued before the send AND one arriving mid-stream both SURVIVE, in order" do
      port =
        start_server(fn socket ->
          # Head first, then stall: the request is in flight and `collect/5` is
          # parked in `receive` while the mid-stream message lands.
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")
          Process.sleep(150)
          :gen_tcp.send(socket, "hello")
        end)

      # (1) already in the mailbox when the receive loop starts...
      send(self(), {:foreign, :queued_before})
      # ...and (2) delivered while the loop is blocked waiting for the body.
      _ = Process.send_after(self(), {:foreign, :mid_stream}, 50)

      assert {:ok, %{status: 200, body: "hello"}} = MintClient.request(get(port))

      # Both survived — and the ONE pattern proves relative order (receive scans
      # the mailbox front to back, so the first match is the earlier message).
      assert_received {:foreign, first}
      assert_received {:foreign, second}
      assert {first, second} == {:queued_before, :mid_stream}
      refute_received {:foreign, _}
    end

    test "a foreign message survives even when the request TIMES OUT (the error path re-delivers too)" do
      port =
        start_server(fn socket ->
          # Headers, then never finish: the caller's deadline expires.
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")
          Process.sleep(1_000)
        end)

      send(self(), {:foreign, :must_not_die})

      assert {:error, :timeout} = MintClient.request(get(port, %{timeout_ms: 150}))
      assert_received {:foreign, :must_not_die}
    end

    test "an unparseable url fails before any socket work" do
      assert {:error, {:invalid_url, "not-a-url"}} =
               MintClient.request(%{method: :get, url: "not-a-url", headers: [], body: nil})
    end
  end
end
