defmodule BarkparkWeb.Plugs.Idempotency do
  @moduledoc """
  Server-side Idempotency-Key dedup.

  When a mutating request (`POST`/`PUT`/`PATCH`/`DELETE`) carries an
  `Idempotency-Key` header, the cached response for the same
  `(raw_key, token_id, method, path)` tuple is replayed. First-time
  responses with status < 500 are stored via `register_before_send`.
  Requires `RequireToken` to have assigned `:api_token` upstream.
  """

  import Plug.Conn

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

        case Idempotency.lookup(hash) do
          {:ok, cached} -> replay(conn, cached)
          :miss -> register_store(conn, hash, scope)
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

  defp replay(conn, cached) do
    headers = cached.headers |> Map.to_list()

    conn
    |> merge_resp_headers(headers)
    |> put_resp_header("idempotency-replay", "true")
    |> send_resp(cached.status, cached.body)
    |> halt()
  end

  defp register_store(conn, hash, scope) do
    register_before_send(conn, fn sent ->
      if sent.status && sent.status < 500 do
        body = IO.iodata_to_binary(sent.resp_body || "")
        headers = sent.resp_headers || []

        try do
          Idempotency.store(hash, scope, sent.status, body, headers)
        rescue
          _ -> :ok
        end
      end

      sent
    end)
  end
end
