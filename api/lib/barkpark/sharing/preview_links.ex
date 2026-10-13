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
  The stable principal-ref `created_by` stamps and `list_for/5`/`revoke_scoped/2`
  compare against: `"api_token:<id>"` or `"user:<id>"` — the same shape
  `Tenancy.Members.invited_by` already uses (task-0548f06277c4712e). `nil` for
  anything else (no principal, or a shape neither clause names), so a caller
  that minted with no identifiable principal never collides with a later
  "mine" filter by coincidence.
  """
  @spec actor_ref(term()) :: String.t() | nil
  def actor_ref(%Barkpark.Auth.ApiToken{id: id}), do: "api_token:" <> id
  def actor_ref(%Barkpark.Accounts.User{id: id}), do: "user:" <> id
  def actor_ref(_), do: nil

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
            # task-de405d9ec590b7b0 — a second call used to overwrite
            # `revoked_at` with a FRESH `DateTime.utc_now()` every time,
            # which only LOOKED idempotent when both calls landed inside the
            # same second-truncated instant. Across a second boundary the
            # second write strictly advanced the timestamp, flaking the
            # "second revoke keeps the first timestamp" test under load.
            # `link.revoked_at || now` keeps whatever is ALREADY stamped —
            # true idempotency, not a coincidence of clock resolution.
            link
            |> Ecto.Changeset.change(
              revoked_at: link.revoked_at || DateTime.utc_now() |> DateTime.truncate(:second)
            )
            |> Repo.update()
        end
    end
  end

  @doc """
  Revoke a link when `principal` administers the link ROW's OWN workspace, OR
  (task-0548f06277c4712e) when `principal` is the link's own creator —
  `created_by == actor_ref(principal)`, never true for a NULL `created_by`
  (a link minted before this field existed stays admin-only-revocable, which
  is the existing behaviour, not a regression) — AND (task-4ad625842939ae8f)
  is not `dataset_bound` to some OTHER dataset than the row's own. BOTH must
  hold: dataset_bound is an absolute confinement on the token itself, so it
  applies whether the caller is revoking as admin or as the link's own
  creator. Same denial shape as `Links.revoke_scoped/2`, widened to cover
  both new cases: a non-castable id, a missing row, a foreign row (neither
  admin nor creator), a row with a nil `workspace_id`, and now a
  dataset_bound token's wrong-dataset row all collapse to
  `{:error, :not_found}`. The id is the only thing the request names, so
  neither a creator mismatch nor a dataset mismatch gets a distinguishable
  refusal — see `Links.revoke_scoped/2`'s docstring for why that would be an
  existence leak.
  """
  @spec revoke_scoped(term(), term()) :: {:ok, PreviewLink.t()} | {:error, :not_found}
  def revoke_scoped(principal, id) do
    with row_id when is_binary(row_id) <- Repo.uuid_or_nil(id),
         %PreviewLink{workspace_id: ws_id, dataset: row_dataset, created_by: owner} <-
           Repo.get(PreviewLink, row_id),
         true <- authorized_for_row?(principal, ws_id, owner),
         true <- dataset_in_bounds?(principal, row_dataset) do
      revoke(row_id)
    else
      _ -> {:error, :not_found}
    end
  end

  defp authorized_for_row?(principal, workspace_id, owner) do
    workspace_admin?(principal, workspace_id) or
      (not is_nil(owner) and actor_ref(principal) == owner)
  end

  defp dataset_in_bounds?(%{dataset_bound: true, dataset: bound}, row_dataset),
    do: bound == row_dataset

  defp dataset_in_bounds?(_principal, _row_dataset), do: true

  @doc """
  List the preview links for one document (newest first), scoped to a
  project+dataset. `scope:` (task-0548f06277c4712e) is the admin/member split:

    * `:all` (the default) — every link, unfiltered. The admin "list-all" view.
    * `{:mine, ref}` — only links whose `created_by == ref`. The non-admin
      member's "list my own" view. `ref: nil` (no identifiable principal)
      deliberately matches NOTHING rather than falling through to `:all` — a
      caller with no resolvable ref must never see every member's links by
      having that nil compared against other nils, so it short-circuits to an
      empty list before a query is even built.
  """
  @spec list_for(binary(), binary(), binary(), binary(), :all | {:mine, String.t() | nil}) ::
          [PreviewLink.t()]
  def list_for(workspace_id, project_id, dataset, doc_id, scope \\ :all)

  def list_for(_workspace_id, _project_id, _dataset, _doc_id, {:mine, nil}), do: []

  def list_for(workspace_id, project_id, dataset, doc_id, scope) do
    PreviewLink
    |> where(
      [l],
      l.workspace_id == ^workspace_id and l.project_id == ^project_id and
        l.dataset == ^dataset and l.doc_id == ^doc_id
    )
    |> scope_query(scope)
    |> order_by([l], desc: l.inserted_at)
    |> Repo.all()
  end

  defp scope_query(query, :all), do: query

  defp scope_query(query, {:mine, ref}) when is_binary(ref),
    do: where(query, [l], l.created_by == ^ref)

  # 24 bytes -> 32 url-safe chars. Opaque; the link is the only authorization.
  # Mirrors Links.generate_token/0's shape; not called through it because that
  # function is private to Links.
  defp generate_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
end
