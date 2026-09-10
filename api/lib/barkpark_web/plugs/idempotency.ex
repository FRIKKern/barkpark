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
  releases the claim so a retry can re-claim. Requires `RequireToken` to have
  assigned `:api_token` upstream.
  """

  import Plug.Conn
  require Logger

  alias Barkpark.Content.Errors
  alias Barkpark.Idempotency

  @methods ~w(POST PUT PATCH DELETE)

  def init(opts), do: Keyword.put_new(opts, :scope, "mutation")

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
        scope = Keyword.fetch!(opts, :scope)
        hash = Idempotency.hash_key(raw_key, token.id, conn.method, conn.request_path)

        case Idempotency.claim(hash, scope) do
          :claimed -> register_complete(conn, hash, scope)
          {:replay, cached} -> replay(conn, cached)
          :in_progress -> in_progress(conn)
        end
    end
  end

  defp unauthorized(conn) do
    BarkparkWeb.ErrorResponse.emit(conn, {:error, :unauthorized})
  end

  # A concurrent request already holds a fresh claim on this key. Return 409 so
  # the client retries (Stripe-style concurrent-request semantics) — the handler
  # NEVER runs, so the mutation cannot double-apply.
  defp in_progress(conn) do
    env = Errors.to_envelope({:error, :idempotency_key_in_use}, conn)

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
  defp register_complete(conn, hash, scope) do
    register_before_send(conn, fn sent ->
      cond do
        is_nil(sent.status) ->
          safe_release(hash)

        sent.state != :set ->
          refuse_bodyless_send(hash, sent)

        sent.status < 500 ->
          body = IO.iodata_to_binary(sent.resp_body || "")
          headers = sent.resp_headers || []
          cache_response(hash, scope, sent.status, body, headers)

        true ->
          safe_release(hash)
      end

      sent
    end)
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
  # NO SUCH ROUTE EXISTS TODAY: both Idempotency mounts are JSON mutate
  # pipelines and every `send_chunked/2` in the tree is a GET/SSE action. This
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
