defmodule Barkpark.Sharing.Links do
  @moduledoc """
  ITEM sharing (P7) — Google-Docs-style direct links to ONE document or media
  file, independent of `Barkpark.Sharing` SECTION shares.

  A link is an opaque, revocable secret (`/s/<token>`) bound to a single item +
  its tenant scope + an access level (`read`/`edit`). `resolve/1` enforces
  revocation + expiry in the query, so a dead link looks identical to a missing
  one.

  THE RAW TOKEN IS STORED, unlike `Barkpark.Auth.ApiToken`: `create/1` writes
  BOTH `token_hash` and the PLAINTEXT `token`, because P7's stable re-copyable
  link needs a later read to re-emit `/s/<token>` (see
  `Barkpark.Sharing.ShareLink`). A ShareLink row is therefore a LIVE CREDENTIAL
  at rest and every read path that serialises one must be AUTHORISED BEFORE it
  serialises — arpss-w8 closed exactly that hole in
  `BarkparkWeb.ShareLinkController.list/2`. The older "returned once, only the
  SHA256 is stored" wording that stood here was false, and believing it is what
  made the leak look harmless.

  This context is storage + token mechanics only; the CONTROLLER owns existence
  validation at mint, TENANCY CONFINEMENT on every admin action, and the
  per-kind read/write dispatch at resolve.
  """
  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Sharing.ShareLink

  # Cap the TTL at one year — mirrors Barkpark.Auth @share_token_max_ttl / the
  # share_controller "cap 1y" contract. A JSON-decoded bignum ttl would otherwise
  # drive DateTime.add into a runaway bignum date computation (request hang) or
  # mint an effectively never-expiring link, defeating expiry/revocation.
  @max_ttl 365 * 24 * 3600

  @doc "Hash a raw link token for storage/lookup (SHA256, like ApiToken)."
  @spec hash_token(binary()) :: binary()
  def hash_token(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  @doc """
  Create an item link. `attrs` must carry `:workspace_id`, `:project_id`,
  `:dataset`, `:kind` (`"doc"`/`"media"`), `:ref_id`, `:access`; `:ref_type`
  for docs; optional `:label`, `:ttl` (seconds — omit / nil for no expiry).
  Returns `{:ok, {raw_token, %ShareLink{}}}`. The raw token is ALSO persisted on
  the row (see the moduledoc), so this is not a show-once secret.
  """
  @spec create(map()) :: {:ok, {binary(), ShareLink.t()}} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    raw = generate_token()

    expires_at =
      case attrs[:ttl] || attrs["ttl"] do
        ttl when is_integer(ttl) and ttl > 0 ->
          DateTime.utc_now()
          |> DateTime.add(min(ttl, @max_ttl), :second)
          |> DateTime.truncate(:second)

        _ ->
          nil
      end

    row_attrs =
      attrs
      |> Map.drop([:ttl, "ttl"])
      |> Map.put(:token_hash, hash_token(raw))
      |> Map.put(:token, raw)
      |> Map.put(:expires_at, expires_at)

    %ShareLink{}
    |> ShareLink.changeset(row_attrs)
    |> Repo.insert()
    |> case do
      {:ok, link} -> {:ok, {raw, link}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Resolve a raw token to its ACTIVE link (not revoked, not expired). Returns
  `{:ok, %ShareLink{}}` or `{:error, :not_found}` — no existence leak between
  missing / revoked / expired.
  """
  @spec resolve(term()) :: {:ok, ShareLink.t()} | {:error, :not_found}
  def resolve(raw) when is_binary(raw) and raw != "" do
    hash = hash_token(raw)
    now = DateTime.utc_now()

    ShareLink
    |> where([l], l.token_hash == ^hash)
    |> where([l], is_nil(l.revoked_at))
    |> where([l], is_nil(l.expires_at) or l.expires_at > ^now)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      link -> {:ok, link}
    end
  end

  def resolve(_), do: {:error, :not_found}

  @doc "Revoke (stamp `revoked_at`) one link by id. Idempotent."
  @spec revoke(binary()) :: {:ok, ShareLink.t()} | {:error, :not_found}
  def revoke(id) when is_binary(id) do
    # Guard the :binary_id cast — a non-UUID id (from `DELETE /v1/shares/links/
    # garbage`) would raise Ecto.CastError → 500; treat it as not_found instead.
    case Repo.uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      uuid ->
        case Repo.get(ShareLink, uuid) do
          nil ->
            {:error, :not_found}

          link ->
            link
            |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
            |> Repo.update()
        end
    end
  end

  @doc """
  List the links for ONE item (newest first). RETURNS LIVE CREDENTIALS: each row
  carries the PLAINTEXT `token` (and its hash), so a caller must be authorised
  against `workspace_id` BEFORE it serialises anything this returns — the raw is
  NOT unrecoverable. `ref_type` may be nil (media).
  """
  @spec list_for(binary(), binary(), binary() | nil, binary()) :: [ShareLink.t()]
  def list_for(workspace_id, kind, ref_type, ref_id) do
    ShareLink
    |> where([l], l.workspace_id == ^workspace_id and l.kind == ^kind and l.ref_id == ^ref_id)
    |> ref_type_filter(ref_type)
    |> order_by([l], desc: l.inserted_at)
    |> Repo.all()
  end

  defp ref_type_filter(query, nil), do: where(query, [l], is_nil(l.ref_type))
  defp ref_type_filter(query, ref_type), do: where(query, [l], l.ref_type == ^ref_type)

  # 24 bytes → 32 url-safe chars. Opaque; the link is the only authorization.
  defp generate_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
end
