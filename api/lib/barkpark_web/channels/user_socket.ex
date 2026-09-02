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

  KEYS, and an honest gap. The bucket is keyed on the token row's id, and
  ADDITIONALLY on the peer IP when the transport hands one over. Today it does
  not: `socket "/socket", BarkparkWeb.UserSocket, websocket: true`
  (endpoint.ex) declares no `connect_info`, so `connect/3` receives an empty
  map and only the per-token key is live. Per-token is a real cap — it is the
  key the flagship's published credential collapses onto — but it is a SHARED
  bucket for every visitor of a given site, so it bounds aggregate load rather
  than isolating one abuser. Declaring
  `websocket: [connect_info: [:peer_data, :x_headers]]` on that socket turns
  the per-IP key on with no change here. Until then the per-IP half is dark,
  and that is stated rather than assumed.

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

  # `connect_info` is `%{}` unless the endpoint asks for `:peer_data` — see the
  # moduledoc. Deliberately NOT reading `x-forwarded-for` by hand: the trust
  # boundary for a forwarded chain lives in `RateLimiter.client_ip/1` and
  # believing a raw header here would let a caller choose its own bucket key,
  # which is the exact hole that function exists to close.
  defp peer_ip(%{peer_data: %{address: address}}) when is_tuple(address) do
    case :inet.ntoa(address) do
      {:error, _} -> nil
      chars -> List.to_string(chars)
    end
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
