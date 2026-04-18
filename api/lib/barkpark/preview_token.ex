defmodule Barkpark.PreviewToken do
  @moduledoc """
  Short-lived HS256 preview JWTs for fetching unpublished drafts.

  Revocation-backed via the `preview_token_jti` table — no Redis.
  """

  import Ecto.Query
  alias Barkpark.Repo

  @default_ttl_seconds 600
  @grace_seconds 3600
  @header_json ~s({"alg":"HS256","typ":"JWT"})

  @spec sign(map(), binary()) :: {binary(), map()}
  def sign(claims, secret) when is_map(claims) and is_binary(secret) do
    now = System.system_time(:second)
    ttl = Map.get(claims, :ttl_seconds, @default_ttl_seconds)

    full_claims =
      claims
      |> Map.drop([:ttl_seconds])
      |> Map.put_new(:iss, Map.get(claims, :iss, "barkpark"))
      |> Map.put_new(:iat, now)
      |> Map.put_new(:exp, now + ttl)
      |> Map.put_new(:jti, Ecto.UUID.generate())
      |> Map.put_new(:doc_ids, [])

    header_b64 = b64url(@header_json)
    payload_b64 = b64url(Jason.encode!(full_claims))
    signing_input = header_b64 <> "." <> payload_b64
    sig = :crypto.mac(:hmac, :sha256, secret, signing_input) |> b64url()

    {signing_input <> "." <> sig, full_claims}
  end

  @spec verify(binary(), binary()) ::
          {:ok, map()} | {:error, :invalid | :expired | :revoked | :bad_signature}
  def verify(raw, secret) when is_binary(raw) and is_binary(secret) do
    with [header_b64, payload_b64, sig_b64] <- String.split(raw, ".", parts: 3),
         {:ok, sig} <- b64url_decode(sig_b64),
         expected = :crypto.mac(:hmac, :sha256, secret, header_b64 <> "." <> payload_b64),
         true <- Plug.Crypto.secure_compare(sig, expected) || :bad_signature,
         {:ok, payload_json} <- b64url_decode(payload_b64),
         {:ok, claims} <- Jason.decode(payload_json),
         :ok <- check_expiry(claims),
         :ok <- check_revocation(claims) do
      {:ok, claims}
    else
      :bad_signature -> {:error, :bad_signature}
      {:error, reason} when reason in [:expired, :revoked, :bad_signature] -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  def verify(_, _), do: {:error, :invalid}

  def record_jti(claims, _opts \\ []) when is_map(claims) do
    now = DateTime.utc_now()

    row = %{
      jti: Map.fetch!(claims, "jti"),
      token_id: Map.get(claims, "token_id"),
      dataset: Map.fetch!(claims, "dataset"),
      doc_ids: Map.get(claims, "doc_ids", []),
      issued_at: from_unix(Map.get(claims, "iat"), now),
      expires_at: from_unix(Map.get(claims, "exp"), now)
    }

    Repo.insert_all("preview_token_jti", [row], on_conflict: :nothing, conflict_target: :jti)
    :ok
  end

  def revoke(jti) when is_binary(jti) do
    {n, _} =
      from(j in "preview_token_jti", where: j.jti == ^jti)
      |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])

    if n == 0, do: {:error, :not_found}, else: :ok
  end

  def revoked?(jti) when is_binary(jti) do
    case Repo.one(
           from j in "preview_token_jti",
             where: j.jti == ^jti,
             select: {j.jti, j.revoked_at}
         ) do
      nil -> true
      {_, nil} -> false
      {_, %DateTime{}} -> true
    end
  end

  def sweep(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@grace_seconds, :second)
    {n, _} = from(j in "preview_token_jti", where: j.expires_at < ^cutoff) |> Repo.delete_all()
    {:ok, n}
  end

  defp check_expiry(%{"exp" => exp}) when is_integer(exp) do
    if System.system_time(:second) < exp, do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_), do: {:error, :invalid}

  defp check_revocation(%{"jti" => jti}) when is_binary(jti) do
    if revoked?(jti), do: {:error, :revoked}, else: :ok
  end

  defp check_revocation(_), do: {:error, :invalid}

  defp b64url(bin), do: Base.url_encode64(bin, padding: false)
  defp b64url_decode(str), do: Base.url_decode64(str, padding: false)

  defp from_unix(nil, default), do: default
  defp from_unix(secs, _) when is_integer(secs), do: DateTime.from_unix!(secs, :second)
end
