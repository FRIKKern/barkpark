defmodule Barkpark.PreviewToken do
  @moduledoc """
  Short-lived HS256 preview JWTs for fetching unpublished drafts.

  Revocation-backed via the `preview_token_jti` table — no Redis.
  """

  import Ecto.Query
  alias Barkpark.Repo

  @default_ttl_seconds 600
  @grace_seconds 3600
  # Upper bound on rows one `sweep_batch/1` statement removes.
  @default_sweep_batch_limit 5_000
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
      # The SIGNER owns the lifetime ceiling: a caller-supplied `:exp` may only
      # SHORTEN the token (tests mint already-expired ones), never extend it past
      # `now + ttl`. Was `Map.put_new(:exp, ...)`, i.e. caller-wins outright — an
      # arbitrarily far-future absolute expiry signed with the real key.
      |> Map.put(:exp, min(Map.get(claims, :exp, now + ttl), now + ttl))
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

  @doc """
  Records the JTI of a preview token as used.

  Returns `{:ok, claims}` on first use and `{:error, :already_used}` when the JTI was
  previously recorded — this is the replay-protection signal consumed by the
  validation plug. Returns `{:error, :invalid}` when the claims are structurally
  unusable (missing/non-string `jti` or `dataset`) — a token minted by an external
  integrator without a dataset claim is rejected, never inserted with a nil dataset.
  Entries are bounded by `expires_at` (= the token's `exp` claim); `sweep/1` reaps
  rows past the grace period so the table does not grow unbounded.
  """
  def record_jti(claims, _opts \\ []) when is_map(claims) do
    now = DateTime.utc_now()

    with jti when is_binary(jti) <- Map.get(claims, "jti"),
         ds when is_binary(ds) <- Map.get(claims, "dataset") do
      row = %{
        jti: jti,
        token_id: Map.get(claims, "token_id"),
        dataset: ds,
        doc_ids: Map.get(claims, "doc_ids", []),
        issued_at: from_unix(Map.get(claims, "iat"), now),
        expires_at: from_unix(Map.get(claims, "exp"), now)
      }

      case Repo.insert_all("preview_token_jti", [row],
             on_conflict: :nothing,
             conflict_target: :jti
           ) do
        {1, _} -> {:ok, claims}
        {0, _} -> {:error, :already_used}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  @doc """
  Combines `verify/2` and `record_jti/1` in one call for the preview-token plug path.

  Returns:
    * `{:ok, claims}` — signature valid, not expired, not revoked, first use
    * `{:error, :already_used}` — signature valid but JTI was already recorded (replay)
    * `{:error, :invalid | :expired | :revoked | :bad_signature}` — from verify
  """
  @spec verify_and_record(binary(), binary()) ::
          {:ok, map()}
          | {:error, :invalid | :expired | :revoked | :bad_signature | :already_used}
  def verify_and_record(raw, secret) when is_binary(raw) and is_binary(secret) do
    case verify(raw, secret) do
      {:ok, claims} -> record_jti(claims)
      {:error, _} = err -> err
    end
  end

  def revoke(jti) when is_binary(jti) do
    {n, _} =
      from(j in "preview_token_jti", where: j.jti == ^jti)
      |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])

    if n == 0, do: {:error, :not_found}, else: :ok
  end

  @doc """
  True only when the JTI row exists AND has a non-null `revoked_at`.

  Unknown JTIs are NOT treated as revoked — replay protection is handled separately
  via `record_jti/1` returning `{:error, :already_used}` on duplicate insert. Fresh
  tokens that have never hit the validation path are valid; only explicit revocations
  (via `revoke/1`) flip this to true.
  """
  def revoked?(jti) when is_binary(jti) do
    case Repo.one(
           from j in "preview_token_jti",
             where: j.jti == ^jti,
             select: {j.jti, j.revoked_at}
         ) do
      nil -> false
      {_, nil} -> false
      {_, %DateTime{}} -> true
      {_, %NaiveDateTime{}} -> true
    end
  end

  def sweep(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@grace_seconds, :second)
    {n, _} = from(j in "preview_token_jti", where: j.expires_at < ^cutoff) |> Repo.delete_all()
    {:ok, n}
  end

  @doc """
  ONE BOUNDED PASS of `sweep/1` — deletes at most `sweep_batch_limit` rows past
  the grace period, OLDEST first, and returns how many it removed.

  `sweep/1` is a single unbounded DELETE. That is fine for a table swept
  regularly; it is not fine for the first pass over a table that has never been
  swept at all, which is exactly the state `preview_token_jti` was in
  (`Barkpark.PreviewToken.Sweeper` explains why). The subquery picks the oldest
  `limit` eligible JTIs and the outer DELETE removes just those, so one
  statement is bounded no matter how deep the backlog is. Returning 0 means
  "nothing left past the grace period" and is the loop's terminator.

  Same cutoff as `sweep/1` — `expires_at < now - #{@grace_seconds}s` — so the
  bounded and unbounded forms are never eligible for different rows.
  """
  @spec sweep_batch(DateTime.t()) :: non_neg_integer()
  def sweep_batch(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@grace_seconds, :second)

    victims =
      from(j in "preview_token_jti",
        where: j.expires_at < ^cutoff,
        order_by: [asc: j.expires_at],
        limit: ^sweep_batch_limit(),
        select: j.jti
      )

    {n, _} =
      from(j in "preview_token_jti", where: j.jti in subquery(victims))
      |> Repo.delete_all()

    n
  end

  defp sweep_batch_limit do
    Application.get_env(:barkpark, :preview_token, [])
    |> Keyword.get(:sweep_batch_limit, @default_sweep_batch_limit)
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

  defp from_unix(secs, default) when is_integer(secs) do
    case DateTime.from_unix(secs, :second) do
      {:ok, dt} -> dt
      _ -> default
    end
  end

  defp from_unix(_, default), do: default
end
