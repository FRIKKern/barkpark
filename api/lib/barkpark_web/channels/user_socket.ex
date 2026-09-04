defmodule BarkparkWeb.UserSocket do
  @moduledoc """
  The public realtime socket. Today it carries one channel — `SearchChannel`
  ("search:<ws>:<proj>:<dataset>") — so a browser can run live, per-keystroke
  search over a single persistent connection instead of one HTTPS request (via
  Vercel) per keystroke.

  Auth is a Bearer-style READ token presented in the connect params
  (`{token: "<read token>"}`) — the same `Barkpark.Auth.verify_token/1` the HTTP
  `RequireToken` plug uses. The token is stashed in `socket.assigns.api_token`;
  the channel resolves the workspace/project scope on join and authorizes the
  token against it (the P0 leak guard). An unverifiable token fails the connect
  closed.

  ## The connect budget — capping SOCKETS, not just frames

  `SearchChannel` throttles `"query"` frames per socket, and that is not the
  whole cap: a channel process serialises its own frames, so the per-socket
  bucket bounds ONE socket's damage by its own round-trip. The genuinely
  unbounded quantity is the number of sockets — and the credential that opens
  them is published on purpose (the site spawner bakes a `public-read` token
  into every deployed flagship site's browser bundle, charter D38/D52), so
  "who can open one" is "anyone who viewed the page". A caller that opened a
  fresh socket per query would have walked straight around the frame throttle.

  So connect is metered too, through the SAME `Barkpark.RateLimiter` token
  bucket the HTTP plug uses — `@default_connects_per_minute` per key, with the
  budget spendable as one burst (a page reload legitimately reconnects, and
  browsers reconnect on network flaps). Full-refill-from-empty is 60s, which
  matches `Plugs.RateLimit`'s row in the `@stale_after_ms` census in
  `rate_limiter.ex` — this call site does NOT introduce a slower window, so
  that invariant is untouched.

  KEYS. Every key must have budget, and there are two. The token row's id is
  the one the flagship's published credential collapses onto — a real cap, but
  a bucket SHARED by every visitor of a given site, so on its own it bounds
  aggregate load rather than isolating one abuser. The second is the client IP,
  which is what actually separates one abuser from a site's other visitors.

  The IP key is resolved by `Barkpark.RateLimiter.client_ip/1` — the ONE owner
  of the trust boundary in this tree (`@canonical capability:
  rate-limit-client-ip`), the same resolver `Plugs.RateLimit` keys the HTTP
  buckets on. `x-forwarded-for` is client-supplied text until something decides
  whether the peer that sent it is one of our fronts, so this module hands the
  resolver the peer address and the forwarded chain and lets it decide: the
  header is ignored outright for an untrusted peer, and walked right-to-left
  for a trusted one. A caller reaching the box directly therefore cannot rotate
  its own bucket key by forging a header — the exact hole that resolver exists
  to close, not re-litigated here.

  Both values reach `connect/3` because `endpoint.ex` declares
  `websocket: [connect_info: [:peer_data, :x_headers]]` on this socket. Without
  that declaration `connect_info` is `%{}`, `peer_ip/1` returns nil and the
  budget silently degrades to token-only — so the endpoint line is load-bearing,
  not decoration.

  Tunable via `config :barkpark, :user_socket, connects_per_minute: _`.

  ## The socket id IS the revocation handle

  `connect/3` runs `verify_token/1` exactly ONCE. That function enforces
  revocation and expiry in its WHERE clause, so every HTTP request re-earns
  the decision — but a WebSocket verifies at connect and never again. Revoking
  the token therefore closed the HTTP door and left every already-open socket
  reading and streaming, indefinitely, for as long as the holder chose to stay
  connected. That is the post-compromise case revocation exists to answer.

  Nothing could force it, either. `id/1` returned `nil`, and a nil id is
  precisely the absence of a handle: Phoenix subscribes the transport process
  to the string `id/1` returns and closes the socket on a `"disconnect"`
  broadcast there, so with no id there is no topic to broadcast to and no
  mechanism to reach.

  So `id/1` now returns a token-derived topic (`disconnect_topic/1`), and
  `Barkpark.Auth.revoke_token/1` broadcasts `"disconnect"` on it. Teardown is
  CAUSED by the revocation and requires no action from the client. Every
  socket that verified the same token shares the topic, which is the intended
  blast radius: revoking a credential kills every connection holding it.

  The id deliberately carries the token ROW id, never the raw bearer or its
  hash — a topic string is not a place to put a credential.
  """
  use Phoenix.Socket

  alias Barkpark.RateLimiter

  channel "search:*", BarkparkWeb.SearchChannel

  @default_connects_per_minute 60

  @impl true
  def connect(%{"token" => raw}, socket, connect_info) when is_binary(raw) do
    with {:ok, token} <- Barkpark.Auth.verify_token(raw),
         :ok <- admit_connect(token, connect_info) do
      {:ok, assign(socket, :api_token, token)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Every key must have budget. Reduce, not Enum.all?, so a refusal short-
  # circuits and does not debit the remaining buckets for a connection that
  # was never admitted.
  defp admit_connect(token, connect_info) do
    per_minute = connects_per_minute()
    opts = [capacity: per_minute, refill_per_sec: per_minute / 60.0]

    token
    |> budget_keys(connect_info)
    |> Enum.map(&RateLimiter.scoped_key(connect_info, &1))
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case RateLimiter.check(key, opts) do
        :ok -> {:cont, :ok}
        :rate_limited -> {:halt, :rate_limited}
      end
    end)
  end

  defp budget_keys(token, connect_info) do
    token_key = "socket:connect:token:#{token.id}"

    case peer_ip(connect_info) do
      nil -> [token_key]
      ip -> [token_key, "socket:connect:ip:#{ip}"]
    end
  end

  # THE TRUST BOUNDARY IS NOT REIMPLEMENTED HERE. A bucket is only a limit if
  # the client cannot choose its own key, and `x-forwarded-for` is client-
  # supplied text until something decides whether the peer that sent it is one
  # of our fronts. That decision has exactly one owner in this tree —
  # `Barkpark.RateLimiter.client_ip/1` (@canonical capability:
  # rate-limit-client-ip), the same resolver `Plugs.RateLimit` keys the HTTP
  # buckets on. It ignores the header entirely for an untrusted peer, walks the
  # chain RIGHT-to-left for a trusted one (Caddy appends the address it actually
  # saw, so a caller-supplied prefix is discarded), falls back to the peer on
  # anything unparseable, and canonicalises the address so alternate spellings
  # of one IP collapse to one key.
  #
  # It reads a `%Plug.Conn{}`, and a socket connect has none — so we hand it the
  # two fields it actually reads rather than forking its logic. `:x_headers`
  # arrives lowercased from the transport, which is the shape
  # `get_req_header/2` expects.
  defp peer_ip(%{peer_data: %{address: address}} = connect_info) when is_tuple(address) do
    conn = %Plug.Conn{
      remote_ip: address,
      req_headers: Map.get(connect_info, :x_headers, [])
    }

    RateLimiter.client_ip(conn)
  end

  defp peer_ip(_), do: nil

  defp connects_per_minute do
    :barkpark
    |> Application.get_env(:user_socket, [])
    |> Keyword.get(:connects_per_minute, @default_connects_per_minute)
    |> max(1)
  end

  # No socket-wide id — disconnect targeting is per-token if ever needed, not
  # required for read-only search.
  @doc """
  The topic every socket that verified `token_id` listens on for a forced
  teardown — `id/1`'s return value, and the topic
  `Barkpark.Auth.revoke_token/1` broadcasts `"disconnect"` to.

  Public because the revocation side must build the SAME string; the two
  halves only meet if exactly one function owns its shape.
  `SearchChannel` subscribes to it too — see that module's moduledoc for why
  the channel does not rely on the transport alone.
  """
  @spec disconnect_topic(binary()) :: binary()
  def disconnect_topic(token_id) when is_binary(token_id),
    do: "user_socket:api_token:" <> token_id

  # A real, token-derived socket id: the handle Phoenix's own
  # `Endpoint.disconnect` mechanism needs. See the moduledoc — while this
  # returned nil, a revoked credential's open socket could not be reached by
  # anything.
  @impl true
  def id(%{assigns: %{api_token: %{id: token_id}}}) when is_binary(token_id),
    do: disconnect_topic(token_id)

  # No verified token on the socket (it never got past `connect/3`) — nothing
  # to target, and nothing that could be serving reads either.
  def id(_socket), do: nil
end
