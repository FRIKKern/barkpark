defmodule BarkparkWeb.Plugs.Idempotency do
  @moduledoc """
  Server-side Idempotency-Key dedup — CLAIM-FIRST.

  When a mutating request (`POST`/`PUT`/`PATCH`/`DELETE`) carries an
  `Idempotency-Key` header, the key row for `(raw_key, token_id, method, path)`
  is atomically CLAIMED before the handler runs (`Idempotency.claim/2`). This
  closes the concurrency gap: two in-flight duplicates can never both execute a
  non-idempotent mutation.

    * winner (`:claimed`)   → handler runs; response cached in `register_before_send`
    * completed row exists  → replayed (sequential retry, unchanged)
    * concurrent pending    → 409 `idempotency_key_in_use`, handler never runs

  First-time responses with status < 500 are cached; a 5xx or crashed request
  releases the claim so a retry can re-claim, unless the write already
  committed (`Barkpark.Idempotency`, "A write that committed and then answered
  a fault"): then the 5xx is cached and replayed, and it and every replay carry
  `Idempotency-Committed: true`. Requires `RequireToken` to have
  assigned `:api_token` upstream.

  Every mount binds the key to the request the action will read (the chat
  send in ChatController and the router's `:idempotent` and `:scoped_mutate`
  pipelines spell it `bind_request: true`; it is also the default), so the same
  key sent for another request is refused 422 `idempotency_key_reused` instead
  of replaying an answer to a request the client did not make:

    * the claim's scope gains a SHA-256 of the params the action reads: query
      string and body together, minus the path params (`conn.params` merges
      all three, and a value in the query string must not escape the binding);
    * the hashed path is the routed path: `path_info` joined (no trailing or
      doubled slash) with each UUID segment in its cast, lower-case form, so
      every spelling that reaches one session reaches one key.

  `init/1` refuses `bind_request: false`. An unbound mount stored the bare
  `:scope` string (`"mutation"`), and such a row now gets 422 like any other
  row of another scope (task-a87c7261c1aa63c2).
  """

  import Plug.Conn
  require Logger

  alias Barkpark.Content.Errors
  alias Barkpark.Idempotency

  @methods ~w(POST PUT PATCH DELETE)

  def init(opts) do
    if Keyword.get(opts, :bind_request, true) != true,
      do:
        raise(ArgumentError, "BarkparkWeb.Plugs.Idempotency: every mount sets bind_request: true")

    Keyword.put_new(opts, :scope, "mutation")
  end

  @doc """
  The claim scope for a request-bound mount: `scope` plus a SHA-256 of `params`.
  Map keys are sorted before hashing, so the key order a client happens to send
  does not change the fingerprint. Maps are tagged, so a map and a list of
  pairs never hash alike.
  """
  @spec bound_scope(String.t(), term()) :: String.t()
  def bound_scope(scope, params) when is_binary(scope) do
    digest =
      params
      |> canonical()
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    scope <> ":" <> digest
  end

  # Every map becomes `%{"m" => sorted pairs}` and nothing else becomes a map,
  # so an encoded object always marks a map: the form is one-to-one.
  defp canonical(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(%{} = map),
    do: %{"m" => map |> Enum.map(fn {k, v} -> [to_string(k), canonical(v)] end) |> Enum.sort()}

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other

  @doc """
  The path a request-bound mount hashes: `path_info` joined, with each segment
  that casts as a UUID in its cast (lower-case) form.
  """
  @spec bound_path([String.t()]) :: String.t()
  def bound_path(path_info) when is_list(path_info) do
    "/" <>
      Enum.map_join(path_info, "/", fn segment ->
        case Ecto.UUID.cast(segment) do
          {:ok, uuid} -> uuid
          :error -> segment
        end
      end)
  end

  def call(conn, opts) do
    with true <- conn.method in @methods,
         [raw_key | _] <- get_req_header(conn, "idempotency-key"),
         true <- is_binary(raw_key) and raw_key != "" do
      handle(conn, raw_key, opts)
    else
      _ -> conn
    end
  end

  defp handle(conn, raw_key, opts) do
    case conn.assigns[:api_token] do
      nil ->
        unauthorized(conn)

      token ->
        {scope, path} = claim_identity(conn, opts)
        hash = Idempotency.hash_key(raw_key, token.id, conn.method, path)

        case Idempotency.claim(hash, scope) do
          :claimed -> hold_and_register_complete(conn, hash, scope)
          {:replay, cached} -> replay(conn, cached)
          :in_progress -> refuse(conn, :idempotency_key_in_use)
          :mismatch -> refuse(conn, :idempotency_key_reused)
        end
    end
  end

  defp claim_identity(conn, opts) do
    params = Map.drop(conn.params, Map.keys(conn.path_params))
    {bound_scope(Keyword.fetch!(opts, :scope), params), bound_path(conn.path_info)}
  end

  defp unauthorized(conn) do
    BarkparkWeb.ErrorResponse.emit(conn, {:error, :unauthorized})
  end

  # The handler NEVER runs on either refusal. `:idempotency_key_in_use` (409): a
  # concurrent request holds a fresh claim on this key, so the client retries
  # (Stripe-style). `:idempotency_key_reused` (422): the key was first used with
  # a different request, so replaying that answer would describe another one.
  defp refuse(conn, reason) do
    env = Errors.to_envelope({:error, reason}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end

  # @sobelow_skip — XSS.SendResp (send_resp/3) is a false-positive: `cached.body`
  # is the EXACT byte stream this server produced on the ORIGINAL request (stored
  # by `register_complete/3` from `sent.body`) and replayed with its cached
  # content-type. It is not new request input — replaying it is byte-identical to
  # re-running the handler, whose own emitters already govern escaping.
  # sobelow_skip ["XSS.SendResp"]
  defp replay(conn, cached) do
    headers = cached.headers |> Map.to_list()

    conn
    |> merge_resp_headers(headers)
    |> put_resp_header("idempotency-replay", "true")
    |> send_resp(cached.status, cached.body)
    |> halt()
  end

  # We hold the claim. On the way out: cache the response (status < 500), or
  # release the reservation (5xx / no response) so a retry can re-claim. The
  # claim row is the dedup anchor — it already blocks concurrent duplicates — so
  # a failed cache write is surfaced to telemetry, never swallowed into a silent
  # dedup gap.
  # The claimed hash is held for this request so the write's transaction can
  # mark it committed; before_send forgets it on every send.
  defp hold_and_register_complete(conn, hash, scope) do
    Idempotency.hold(hash)
    register_complete(conn, hash, scope)
  end

  defp register_complete(conn, hash, scope) do
    register_before_send(conn, fn sent ->
      Idempotency.forget_held_key()

      cond do
        is_nil(sent.status) ->
          settle_fault(hash, scope, sent)

        sent.state != :set ->
          refuse_bodyless_send(hash, sent)
          sent

        sent.status < 500 ->
          body = IO.iodata_to_binary(sent.resp_body || "")
          headers = sent.resp_headers || []
          cache_response(hash, scope, sent.status, body, headers)
          sent

        true ->
          settle_fault(hash, scope, sent)
      end
    end)
  end

  @committed_header "idempotency-committed"

  # A 5xx (or no answer): released so the retry runs, unless the write
  # committed, in which case the answer is recorded and replayed. A recorded
  # fault says so: `Idempotency-Committed: true` on this answer AND on every
  # replay (the header is stored with it), so a client knows the write landed
  # even though the answer is an error (task-dbee0d3a56ab4459).
  defp settle_fault(hash, scope, sent) do
    body = IO.iodata_to_binary(sent.resp_body || "")
    headers = [{@committed_header, "true"} | sent.resp_headers || []]

    case Idempotency.settle_fault(hash, scope, sent.status, body, headers) do
      :recorded -> put_resp_header(sent, @committed_header, "true")
      :released -> sent
    end
  rescue
    error ->
      emit_store_error(hash, error)
      sent
  end

  # THE `:set` ALLOWLIST — an idempotency receipt is only meaningful when the
  # response body is a single term at before-send time.
  #
  # Plug runs `register_before_send/2` callbacks for FOUR distinct send shapes
  # and stamps a DIFFERENT `conn.state` on each (`deps/plug/lib/plug/conn.ex`):
  #
  #   * `send_resp/3`       → `:set`         — `resp_body` is the body. CACHEABLE.
  #   * `send_file/3..5`    → `:set_file`    — `resp_body` NIL'd first (:495)
  #   * `send_chunked/2`    → `:set_chunked` — `resp_body` NIL'd first (:525)
  #   * `upgrade_adapter/3` → `:set_upgrade` — status 101, no body (:1474)
  #
  # Under any of the last three the cache write below would store `""` against a
  # live key and REPLAY AN EMPTY 200 for the whole lifetime of that key — the
  # client's retry would receive a successful-looking empty response and never
  # learn the mutation's real result.
  #
  # An ALLOWLIST on `:set`, not a denylist of the three: `:set_upgrade` did not
  # exist in older Plug, and the next shape Plug adds would inherit the bug
  # silently. `BarkparkWeb.Plugs.ResponseWarnings` fences its own before_send
  # hook on exactly this predicate, for exactly this reason.
  #
  # NO SUCH ROUTE EXISTS TODAY: every Idempotency mount (the mutate pipelines
  # and the chat send) answers JSON with send_resp, and every `send_chunked/2`
  # in the tree is a GET/SSE action. This
  # is a TRIPWIRE for the first streaming or file-sending mutate route: it
  # releases the claim (so the key is never wedged), reports, and then RAISES —
  # a loud 500 in test beats a silently poisoned key in prod. Idempotency is a
  # safety guarantee; degrading it quietly on a mutating route is the worse
  # outcome.
  defp refuse_bodyless_send(hash, sent) do
    safe_release(hash)

    message =
      "Idempotency refused to cache a #{inspect(sent.state)} response for #{hash}: " <>
        "an Idempotency-Key request answered with send_chunked/send_file/upgrade has no " <>
        "single response body, so caching it would replay an EMPTY #{sent.status} for the " <>
        "lifetime of the key. The claim was released. Either do not mount " <>
        "BarkparkWeb.Plugs.Idempotency on this route, or answer it with send_resp/3."

    :telemetry.execute(
      [:barkpark, :idempotency, :store_error],
      %{count: 1},
      %{key_hash: hash, reason: {:uncacheable_response_state, sent.state}}
    )

    Logger.error(message)

    raise message
  end

  defp cache_response(hash, scope, status, body, headers) do
    case Idempotency.complete(hash, scope, status, body, headers) do
      {n, _} when n >= 1 ->
        :ok

      {0, _} ->
        # Reservation vanished (swept or reclaimed after a stale window). The
        # claim guarantee held; the cache just missed. Surface, don't swallow.
        emit_store_error(hash, :reservation_missing)
    end
  rescue
    error ->
      emit_store_error(hash, error)
  end

  defp safe_release(hash) do
    Idempotency.release(hash)
  rescue
    error -> emit_store_error(hash, error)
  end

  defp emit_store_error(hash, reason) do
    :telemetry.execute(
      [:barkpark, :idempotency, :store_error],
      %{count: 1},
      %{key_hash: hash, reason: reason}
    )

    Logger.warning("Idempotency store failed for #{hash}: #{inspect(reason)}")
    :ok
  end
end
