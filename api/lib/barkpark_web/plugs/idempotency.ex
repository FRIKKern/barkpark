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
    env = Errors.to_envelope({:error, :unauthorized}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
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
