defmodule Barkpark.Sharing.PreviewLinks do
  @moduledoc """
  DRAFT-capable preview links (task-6812c3100d7aedbc) — minted and resolved
  WITHOUT a `Barkpark.Sharing` SECTION share, exactly like
  `Barkpark.Sharing.Links` (P7 item links), whose shape this module mirrors.

  A SIBLING of `Links`, not an extension: see `Barkpark.Sharing.PreviewLink`'s
  moduledoc for why `Links.create/1`'s unconditional `drafts.`-stripping rules
  it out for this feature. `doc_id` here is persisted exactly as minted.

  THE RAW TOKEN IS RETURNED ONCE AND NEVER STORED, the same invariant as
  `Links` / `Barkpark.Auth.ApiToken`: `create/1` persists only `token_hash`.
  Token generation and hashing are NOT re-derived — this module calls
  `Links.generate_token/0`'s equivalent inline (24 random bytes, url-safe
  base64) and `Links.hash_token/1` directly, so both link families hash the
  same way under one real implementation.

  `workspace_admin?/2` is ALSO reused directly from `Links` rather than
  re-derived: it already takes a generic principal (`%ApiToken{}`, `%User{}`,
  or a list) and a workspace id, with no dependency on which table the row
  came from — `arpss-w8-bl-links-context-boundary-predicate` built it to serve
  more than one door.

  `expires_at` is REQUIRED on every row (see the schema moduledoc for why);
  `create/1` defaults a missing/invalid `ttl` to `@default_ttl` and clamps any
  caller-supplied value to `@max_ttl` — never unbounded, never absent.
  """
  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Sharing.Links
  alias Barkpark.Sharing.PreviewLink

  # Default when the caller omits `ttl`: a full day, long enough for an async
  # review without being a standing credential.
  @default_ttl 24 * 3600
  # Hard cap, well under ShareLink's 1-year cap — previewing a DRAFT is more
  # sensitive than sharing published content, so the ceiling is a week, never
  # negotiable upward by a caller-supplied ttl.
  @max_ttl 7 * 24 * 3600

  @doc "Reuse ShareLink's generic workspace-admin predicate — see moduledoc."
  @spec workspace_admin?(term(), term()) :: boolean()
  def workspace_admin?(principal, workspace_id),
    do: Links.workspace_admin?(principal, workspace_id)

  @doc """
  Create a preview link. `attrs` must carry `:workspace_id`, `:project_id`,
  `:dataset`, `:doc_id` (raw — a `drafts.` prefix is kept verbatim), `:ref_type`;
  optional `:label`, `:ttl` (seconds — defaulted and clamped, see moduledoc).
  Returns `{:ok, {raw_token, %PreviewLink{}}}` — the ONLY place the raw token
  exists.
  """
  @spec create(map()) :: {:ok, {binary(), PreviewLink.t()}} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    raw = generate_token()

    ttl =
      case attrs[:ttl] || attrs["ttl"] do
        t when is_integer(t) and t > 0 -> min(t, @max_ttl)
        _ -> @default_ttl
      end

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(ttl, :second)
      |> DateTime.truncate(:second)

    row_attrs =
      attrs
      |> Map.drop([:ttl, "ttl"])
      |> Map.put(:token_hash, Links.hash_token(raw))
      |> Map.put(:expires_at, expires_at)

    %PreviewLink{}
    |> PreviewLink.changeset(row_attrs)
    |> Repo.insert()
    |> case do
      {:ok, link} -> {:ok, {raw, link}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Resolve a raw token to its ACTIVE link (not revoked, not expired, bound to a
  tenant scope). Returns `{:ok, %PreviewLink{}}` or `{:error, :not_found}` — no
  existence leak between missing / revoked / expired / unbound, mirroring
  `Links.resolve/1` exactly.
  """
  @spec resolve(term()) :: {:ok, PreviewLink.t()} | {:error, :not_found}
  def resolve(raw) when is_binary(raw) and raw != "" do
    hash = Links.hash_token(raw)
    now = DateTime.utc_now()

    PreviewLink
    |> where([l], l.token_hash == ^hash)
    |> where([l], not is_nil(l.workspace_id) and not is_nil(l.project_id))
    |> where([l], is_nil(l.revoked_at))
    |> where([l], l.expires_at > ^now)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      link -> {:ok, link}
    end
  end

  def resolve(_), do: {:error, :not_found}

  @doc "Revoke (stamp `revoked_at`) one link by id. Idempotent."
  @spec revoke(binary()) :: {:ok, PreviewLink.t()} | {:error, :not_found}
  def revoke(id) when is_binary(id) do
    case Repo.uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      uuid ->
        case Repo.get(PreviewLink, uuid) do
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
  Revoke a link only when `principal` administers the link ROW's OWN
  workspace — same denial shape as `Links.revoke_scoped/2`: a non-castable id,
  a missing row, a foreign row, and a row with a nil `workspace_id` all
  collapse to `{:error, :not_found}`.
  """
  @spec revoke_scoped(term(), term()) :: {:ok, PreviewLink.t()} | {:error, :not_found}
  def revoke_scoped(principal, id) do
    with row_id when is_binary(row_id) <- Repo.uuid_or_nil(id),
         %PreviewLink{workspace_id: ws_id} <- Repo.get(PreviewLink, row_id),
         true <- workspace_admin?(principal, ws_id) do
      revoke(row_id)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "List the preview links for one document (newest first), scoped to a project+dataset."
  @spec list_for(binary(), binary(), binary(), binary()) :: [PreviewLink.t()]
  def list_for(workspace_id, project_id, dataset, doc_id) do
    PreviewLink
    |> where(
      [l],
      l.workspace_id == ^workspace_id and l.project_id == ^project_id and
        l.dataset == ^dataset and l.doc_id == ^doc_id
    )
    |> order_by([l], desc: l.inserted_at)
    |> Repo.all()
  end

  # 24 bytes -> 32 url-safe chars. Opaque; the link is the only authorization.
  # Mirrors Links.generate_token/0's shape; not called through it because that
  # function is private to Links.
  defp generate_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
end
