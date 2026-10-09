defmodule BarkparkWeb.PreviewTokenController do
  @moduledoc """
  Admin-only HTTP mint/revoke for `Barkpark.PreviewToken` JWTs
  (task-8f7cba7f65cb343c).

  Every `/v1/preview/*` read (QueryController, ListenController, piped
  through `:api_preview`) already verifies a signed preview JWT, but nothing
  minted one over HTTP — the only way to get a preview token was
  `PreviewToken.sign/2` called in-process (tests only). A real consumer site
  (or the Studio, handing a token to its preview frame) had no way to get one
  except reading with an editor's own bearer token server-side.

  ## Single-use stays the default (ruling, task-8f7cba7f65cb343c)

  A minted token is single-use — one `/v1/preview/*` read, or the whole
  `/v1/preview/listen/:dataset` SSE connection, then its `jti` is burned —
  UNLESS this mint sets a signed `multi_use: true` claim. That claim lives
  INSIDE the signed payload, so it can never be added to a token after
  minting; nothing else mints a preview token that could reasonably ask for
  it, so this is the one and only place `multi_use` can originate.

  A `multi_use` token's TTL defaults to 600s and is clamped to a hard max of
  3600s regardless of what the caller asks for — `BarkparkWeb.Plugs.PreviewToken`
  skips the
  replay-dedup `record_jti` call for a multi_use token on every read past the
  first (see that module), so TTL + revocation (`PreviewToken.revoke/1`,
  already wired to this controller's `revoke/2`) are the only things
  bounding a leaked multi_use token's blast radius — tighter than single-use,
  which self-destructs on first read regardless of TTL.

  A single-use token minted here gets no such cap: it behaves exactly like
  one minted by calling `PreviewToken.sign/2` directly, which nothing ever
  prevented.
  """

  use BarkparkWeb, :controller

  alias Barkpark.PreviewToken
  alias BarkparkWeb.ErrorResponse

  @default_ttl 600
  @multi_use_max_ttl 3600

  @doc "POST /v1/preview-tokens — mint a preview JWT. Raw token shown ONCE."
  def mint(conn, params) do
    with {:ok, dataset} <- fetch_dataset(params),
         {:ok, doc_ids} <- fetch_doc_ids(params),
         secret when is_binary(secret) and byte_size(secret) > 0 <- preview_secret() do
      multi_use = params["multi_use"] == true
      ttl = clamp_ttl(params["ttl_seconds"], multi_use)

      claims = %{dataset: dataset, doc_ids: doc_ids, ttl_seconds: ttl}
      claims = if multi_use, do: Map.put(claims, :multi_use, true), else: claims

      {raw, full_claims} = PreviewToken.sign(claims, secret)
      string_claims = Map.new(full_claims, fn {k, v} -> {to_string(k), v} end)

      # Register the jti NOW only for multi_use: the verify plug skips
      # record_jti per-request for a multi_use token (that is the whole
      # point — see the plug), so without this the row `revoke/1` and
      # `revoked?/1` look up, and `sweep`/`sweep_batch` GC, would never
      # exist. A single-use token must NOT be registered here — the first
      # real read is what registers it (unchanged), so a token that is
      # never read stays usable until it expires, exactly as today.
      if multi_use, do: PreviewToken.record_jti(string_claims)

      conn
      |> put_status(:created)
      |> json(%{
        token: raw,
        jti: string_claims["jti"],
        dataset: string_claims["dataset"],
        doc_ids: string_claims["doc_ids"],
        multi_use: multi_use,
        expires_at: unix_to_iso8601(string_claims["exp"])
      })
    else
      {:error, msg} when is_binary(msg) -> unprocessable(conn, msg)
      _ -> unprocessable(conn, "preview signing is not configured")
    end
  end

  @doc "DELETE /v1/preview-tokens/:jti — revoke one preview token immediately."
  def revoke(conn, %{"jti" => jti}) do
    case PreviewToken.revoke(jti) do
      :ok -> json(conn, %{revoked: true, jti: jti})
      {:error, :not_found} -> not_found(conn)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp fetch_dataset(%{"dataset" => ds}) when is_binary(ds) and ds != "", do: {:ok, ds}
  defp fetch_dataset(_), do: {:error, "dataset is required"}

  defp fetch_doc_ids(%{"doc_ids" => ids}) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1),
      do: {:ok, ids},
      else: {:error, "doc_ids must be a list of strings"}
  end

  defp fetch_doc_ids(%{"doc_ids" => _}), do: {:error, "doc_ids must be a list of strings"}
  defp fetch_doc_ids(_), do: {:ok, []}

  # A multi_use token's TTL is clamped to [1, @multi_use_max_ttl] regardless
  # of what is asked for — the hard ceiling IS the safety property, not an
  # input-validation nicety. A single-use token keeps the plain `sign/2`
  # default with no cap: one read burns it no matter how long its TTL says.
  defp clamp_ttl(nil, _multi_use), do: @default_ttl

  defp clamp_ttl(ttl, true) when is_integer(ttl), do: max(1, min(ttl, @multi_use_max_ttl))
  defp clamp_ttl(_ttl, true), do: @default_ttl
  defp clamp_ttl(ttl, false) when is_integer(ttl) and ttl > 0, do: ttl
  defp clamp_ttl(_ttl, false), do: @default_ttl

  defp preview_secret, do: Application.get_env(:barkpark, :preview, [])[:secret]

  defp unix_to_iso8601(secs) when is_integer(secs) do
    case DateTime.from_unix(secs, :second) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp unix_to_iso8601(_), do: nil

  defp unprocessable(conn, msg),
    do: ErrorResponse.emit_custom(conn, 422, "validation_failed", msg)

  defp not_found(conn),
    do: ErrorResponse.emit(conn, {:error, :not_found}, "preview token not found")
end
