defmodule BarkparkCloud.Push.HTTP.Mint do
  @moduledoc """
  The real `BarkparkCloud.Push.HTTP` transport: one Mint connection per request,
  HTTP/2-capable (APNs is HTTP/2-only), TLS verified against the OS trust store.

  ONE CONNECTION PER REQUEST on purpose, for now. A pooled, multiplexed APNs
  connection is the throughput answer (HTTP/2 lets one connection carry the
  whole fan-out), but a pool is a supervised process with its own failure modes,
  and the relay's real traffic is one notification per blocked session per
  debounce window — single-digit sends per minute at the fleet's current size.
  Correctness first; the pool is a named follow-up, not a silent debt.

  TLS: `:public_key.cacerts_get/0` (the OS trust store, OTP 25+). Explicit
  rather than relying on Mint's default CA discovery, so a missing `castore`
  dependency can never silently downgrade verification.

  MAILBOX SAFETY: the receive loop runs in the CALLER's process (an Oban job),
  whose mailbox is not ours. Messages Mint does not recognise are stashed and
  re-delivered to the process once the request completes instead of being
  swallowed — see `collect/5`'s `:unknown` arm and `redeliver/1`.
  """

  @behaviour BarkparkCloud.Push.HTTP

  @default_timeout_ms 10_000

  @impl true
  def request(%{method: method, url: url, headers: headers, body: body} = req) do
    timeout = Map.get(req, :timeout_ms, @default_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, scheme, host, port, path} <- parse_url(url),
         {:ok, conn} <- connect(scheme, host, port, req, timeout) do
      send_and_collect(conn, method, path, headers, body, deadline)
    end
  end

  defp connect(scheme, host, port, req, timeout) do
    # The connect timeout rides `transport_opts[:timeout]` (both transports set
    # it below). `Mint.HTTP.connect/4` has NO top-level `:timeout` option — a key
    # here would be silently ignored, so it is not passed (it used to be, and it
    # read as if the connect had a second, working deadline).
    opts =
      [transport_opts: transport_opts(scheme, timeout)]
      |> maybe_put_protocols(Map.get(req, :protocols))

    case Mint.HTTP.connect(scheme, host, port, opts) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, {:connect_failed, reason}}
    end
  end

  defp maybe_put_protocols(opts, nil), do: opts
  defp maybe_put_protocols(opts, protocols), do: Keyword.put(opts, :protocols, protocols)

  defp transport_opts(:https, timeout) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      timeout: timeout
    ]
  end

  defp transport_opts(:http, timeout), do: [timeout: timeout]

  defp send_and_collect(conn, method, path, headers, body, deadline) do
    method_string = method |> Atom.to_string() |> String.upcase()

    case Mint.HTTP.request(conn, method_string, path, headers, body) do
      {:ok, conn, ref} ->
        {conn_after, outcome, stash} =
          collect(conn, ref, %{status: nil, headers: [], body: ""}, deadline, [])

        _ = Mint.HTTP.close(conn_after)
        redeliver(stash)
        outcome

      {:error, conn, reason} ->
        _ = Mint.HTTP.close(conn)
        {:error, {:request_failed, reason}}
    end
  end

  # Drive Mint's message loop until :done (or the deadline). Returns
  # {conn, outcome, stash} so the caller always gets a connection to close, even
  # on the error paths — a leaked TLS socket per failed send would be a slow
  # drain — and always gets the foreign mailbox messages back to re-deliver
  # (`stash`, newest-first; see the `:unknown` arm).
  defp collect(conn, ref, acc, deadline, stash) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {conn, {:error, :timeout}, stash}
    else
      receive do
        message ->
          case Mint.HTTP.stream(conn, message) do
            {:ok, conn, responses} ->
              case apply_responses(responses, ref, acc) do
                {:done, acc} -> {conn, {:ok, finish(acc)}, stash}
                {:cont, acc} -> collect(conn, ref, acc, deadline, stash)
                {:failed, reason} -> {conn, {:error, {:stream_error, reason}}, stash}
              end

            {:error, conn, reason, _responses} ->
              {conn, {:error, {:transport_error, reason}}, stash}

            :unknown ->
              # NOT ours (Mint says so). This loop runs inside an Oban job
              # process whose mailbox is shared with everything else that may
              # message it — a late GenServer reply, a `:DOWN`, DBConnection /
              # Ecto-sandbox traffic under test. `receive do message ->` CONSUMES
              # such a message, so simply looping would DESTROY it.
              #
              # Stash it instead and re-mail it to ourselves once the request is
              # finished (`redeliver/1`): the message survives, keeps its relative
              # order, and cannot re-enter this receive because the re-mail
              # happens strictly after the loop has returned.
              collect(conn, ref, acc, deadline, [message | stash])
          end
      after
        remaining -> {conn, {:error, :timeout}, stash}
      end
    end
  end

  # Put the foreign messages back, oldest first (the stash is newest-first). They
  # land at the back of the mailbox rather than their original position — the best
  # a non-owner process can do, and enough for the receivers that matter (all of
  # them select by pattern, not by position).
  defp redeliver([]), do: :ok

  defp redeliver(stash) do
    me = self()
    Enum.each(Enum.reverse(stash), &send(me, &1))
  end

  defp apply_responses([], _ref, acc), do: {:cont, acc}

  defp apply_responses([{:status, ref, status} | rest], ref, acc),
    do: apply_responses(rest, ref, %{acc | status: status})

  defp apply_responses([{:headers, ref, headers} | rest], ref, acc),
    do: apply_responses(rest, ref, %{acc | headers: acc.headers ++ headers})

  defp apply_responses([{:data, ref, data} | rest], ref, acc),
    do: apply_responses(rest, ref, %{acc | body: acc.body <> data})

  defp apply_responses([{:done, ref} | _rest], ref, acc), do: {:done, acc}

  defp apply_responses([{:error, ref, reason} | _rest], ref, _acc), do: {:failed, reason}

  # A response for a different request ref on the same connection cannot happen
  # here (one request per connection), but ignoring it is the safe reading.
  defp apply_responses([_other | rest], ref, acc), do: apply_responses(rest, ref, acc)

  defp finish(acc), do: %{status: acc.status || 0, headers: acc.headers, body: acc.body}

  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: port} = uri when is_binary(host) and host != "" ->
        {:ok, :https, host, port || 443, path_of(uri)}

      %URI{scheme: "http", host: host, port: port} = uri when is_binary(host) and host != "" ->
        {:ok, :http, host, port || 80, path_of(uri)}

      _ ->
        {:error, {:invalid_url, url}}
    end
  end

  defp path_of(%URI{} = uri) do
    base = uri.path || "/"
    if uri.query, do: base <> "?" <> uri.query, else: base
  end
end
