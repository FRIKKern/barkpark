defmodule BarkparkWeb.ExportDeliveryEdgeTest do
  @moduledoc """
  The DELIVERY EDGE of `GET /api/workspaces/:workspace_slug/export`
  (pds-backlog-export-edge-idle-timeout).

  `WorkspaceController.deliver_bundle/3` is driven here over a REAL TCP socket
  — `Plug.Test`'s conn has none, so none of the properties below were provable
  in this suite before. Everything is measured against an INJECTED timeout and
  a deliberately throttled reader, never against wall-clock on a loaded box:
  each verdict is a function of the configured value, so a fast machine and a
  slow one agree.

  ## What this establishes

  1. **The app applies no clock to an export response.** Thousand Island's
     `send_timeout` is the only per-write timeout on the path (Bandit's
     `t:Bandit.http_1_options/0` offers no response-side timeout, and
     `read_timeout` waits for CLIENT data, which a response never reads).
     Injecting a 400 ms `send_timeout` with `send_timeout_close: true` and
     stalling the reader for 3 s — 7.5x the timeout — still delivers every
     byte, because TI issues one `:file.sendfile/5` for the whole file and
     `:file.sendfile/5` does not honour the socket's send_timeout.

     Therefore an export cut after N minutes was cut by an INTERMEDIARY (the
     deployed Caddy reverse proxy, or a hop in front of it) and NOT by this
     application. "Raise the app timeout" is not an available remedy; there is
     no app timeout.

  2. **The archive arrives byte-complete.** Asserted on sha256 over the whole
     body against the sha256 of the file on disk, plus Content-Length — not on
     an HTTP 200, which is put on the wire before the first body byte and
     therefore proves nothing about the transfer.

  3. **The temp bundle is deleted on BOTH exits** — a completed send, and a
     client that hangs up mid-transfer.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.ExportDeliveryEdgeTest.Harness

  # Large enough that no loopback socket buffer swallows it whole (a 4 MB
  # payload did, and silently made the stall control vacuous), small enough to
  # stay a couple of seconds.
  @payload_bytes 64 * 1024 * 1024

  # Deliberately hostile: an order of magnitude under TI's 30_000 ms default,
  # so a send_timeout that DID bound this write would cut the transfer at once.
  @injected_send_timeout_ms 400
  @stall_ms 3_000

  defmodule Harness do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      %{path: path, owner: owner} = :persistent_term.get({__MODULE__, :state})

      # The notification rides an `after`, NOT the success path: on the
      # disconnect test `deliver_bundle/3` re-raises Bandit.TransportError and a
      # trailing `send/2` would never run — the test would then time out on a
      # cleanup that DID happen, reporting the wrong defect.
      try do
        BarkparkWeb.ExportDeliveryEdgeTest.Harness.deliver(conn, path)
      after
        send(owner, {:delivered, path})
      end
    end

    # The shipped code path, not a copy of it.
    def deliver(conn, path),
      do: BarkparkWeb.WorkspaceController.deliver_bundle(conn, path, "bundle.tar")
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "bp-export-edge-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "a stall 7.5x the injected send_timeout does NOT cut the export — no app-side clock exists",
       %{dir: dir} do
    {port, path, digest} = start_server(dir, @injected_send_timeout_ms)

    sock = connect_and_request(port)
    {head, buffered} = read_headers(sock)
    length = content_length(head)
    assert length == @payload_bytes

    # The whole point: go quiet for far longer than the only timeout that
    # could bound this write, then resume.
    Process.sleep(@stall_ms)

    assert {:complete, ^length, got} = drain(sock, buffered, length)

    assert got == digest,
           "the export was truncated or corrupted by a #{@injected_send_timeout_ms}ms send_timeout"

    assert_receive {:delivered, ^path}, 10_000
    refute File.exists?(path), "the temp bundle survived a completed send_file"
  end

  test "a client that hangs up mid-transfer still gets the temp bundle deleted", %{dir: dir} do
    {port, path, _digest} = start_server(dir, @injected_send_timeout_ms)

    sock = connect_and_request(port)
    # Take the headers and a first body chunk, then hard-close. Bandit raises a
    # catchable Bandit.TransportError; `deliver_bundle/3`'s `after` must fire.
    {_head, _buffered} = read_headers(sock)
    :ok = :gen_tcp.close(sock)

    assert_receive {:delivered, ^path}, 15_000
    refute File.exists?(path), "an injected client disconnect stranded the temp bundle"
    refute File.exists?(path <> ".owner"), "the janitor ownership sidecar was not disowned"
  end

  # ── harness ────────────────────────────────────────────────────────────────

  defp start_server(dir, send_timeout) do
    path = Path.join(dir, "bp-ws-bundle-#{System.unique_integer([:positive])}.tar")
    payload = :crypto.strong_rand_bytes(@payload_bytes)
    File.write!(path, payload)
    digest = :crypto.hash(:sha256, payload)

    :persistent_term.put({Harness, :state}, %{path: path, owner: self()})

    {:ok, pid} =
      Bandit.start_link(
        plug: Harness,
        scheme: :http,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false,
        thousand_island_options: [
          transport_options: [
            # A small send buffer keeps the kernel from absorbing the payload,
            # so the throttled/stalled reader really is what the server waits on.
            sndbuf: 16_384,
            send_timeout: send_timeout,
            send_timeout_close: true
          ]
        ]
      )

    on_exit(fn ->
      # The listener is torn down while a sendfile may still be in flight, so a
      # graceful stop can itself exit :shutdown. Killing is the honest teardown.
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {:ok, {_addr, port}} = ThousandIsland.listener_info(pid)
    {port, path, digest}
  end

  defp connect_and_request(port) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [
        :binary,
        active: false,
        packet: :raw,
        recbuf: 16_384,
        buffer: 16_384
      ])

    :ok =
      :gen_tcp.send(sock, "GET /export HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

    sock
  end

  defp read_headers(sock, acc \\ "") do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      _ ->
        {:ok, more} = :gen_tcp.recv(sock, 0, 15_000)
        read_headers(sock, acc <> more)
    end
  end

  defp content_length(head) do
    [_, len] = Regex.run(~r/content-length:\s*(\d+)/i, head)
    String.to_integer(len)
  end

  # Returns {:complete, bytes_read, sha256} once Content-Length bytes arrived,
  # or {:truncated, bytes_read, sha256} when the server closed first.
  defp drain(sock, buffered, expected) do
    hash = :crypto.hash_update(:crypto.hash_init(:sha256), buffered)
    do_drain(sock, byte_size(buffered), expected, hash)
  end

  defp do_drain(_sock, read, expected, hash) when read >= expected,
    do: {:complete, read, :crypto.hash_final(hash)}

  defp do_drain(sock, read, expected, hash) do
    case :gen_tcp.recv(sock, 0, 15_000) do
      {:ok, chunk} ->
        do_drain(sock, read + byte_size(chunk), expected, :crypto.hash_update(hash, chunk))

      {:error, reason} when reason in [:closed, :timeout] ->
        {:truncated, read, :crypto.hash_final(hash)}
    end
  end
end
