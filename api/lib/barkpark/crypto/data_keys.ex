defmodule Barkpark.Crypto.DataKeys do
  @moduledoc """
  Get-or-create and rotate per-scope Data Encryption Keys (DEKs).

  A DEK is 32 random bytes used to encrypt content fields for one *scope*
  (e.g. `"dataset:<uuid>"`). The DEK is stored only in wrapped form (sealed by
  the master KEK via `Barkpark.Crypto.KeyProvider`); the plaintext DEK is
  unwrapped on demand and cached in an ETS table so the KEK round-trip happens
  once per (scope, version), not per field.

  ## Per-workspace attribution (charter D51-D54)

  A DEK is keyed by `(workspace_id, scope)`, not scope alone. Two workspaces
  that both own a `"production"` dataset each get their OWN DEK for the shared
  `"dataset:production"` scope — distinct rows, and neither can decrypt the
  other's ciphertext. `workspace_id` is NULLABLE: the FieldCipher direct path
  (no workspace) and legacy/dormant rows carry `nil`, which resolves the
  NULL-workspace DEK. The `workspace_id`-bearing rows are what the workspace
  bundle exports (E1 `WHERE workspace_id = $ws`) and a teardown FK-cascade
  sweeps.

  ## Public surface

    * `active_dek/1,2`      — `{version, dek}` for new encryptions; creates the
      (workspace, scope) DEK on demand. `active_dek/1` = the nil-workspace path.
    * `dek_for_version/2,3` — `{:ok, dek}` for decrypting older ciphertext.
    * `rotate_dek/1,2`      — start a new active DEK version for a (workspace,
      scope) (old versions stay decryptable; re-encryption is lazy).
    * `rewrap_all/0`        — KEK-rotation seam: re-wrap every DEK under the
      current KEK (no content touched).
  """
  import Ecto.Query, warn: false
  alias Barkpark.Repo
  alias Barkpark.Crypto.{DataKey, KeyProvider}

  @cache :barkpark_dek_cache
  @dek_bytes 32

  # Bound the unwrapped-DEK cache. Keyed by {scope, version}, it would otherwise
  # grow one entry per tenancy scope forever (unbounded at multi-tenant scale,
  # and more decrypted key material resident than necessary). See cache_put/3 —
  # clear-on-full is behaviour-preserving: an evicted DEK is re-derived on the
  # next miss via the exact cold path, with no change to derivation/rotation.
  @max_cached_deks 10_000

  # @canonical capability:envelope-dek aka:dek,data-key,envelope-encryption,key-rotation
  @doc """
  Return `{version, dek}` for the active DEK, creating it if absent (nil arity =
  the NULL-workspace path). The `dek` is the raw 32-byte key, cached after unwrap.
  """
  @spec active_dek(String.t()) :: {pos_integer(), binary()}
  def active_dek(scope) when is_binary(scope), do: active_dek(nil, scope)

  @doc """
  Return `{version, dek}` for the `(workspace_id, scope)` active DEK, creating it
  if absent. `workspace_id` may be `nil` (the NULL-workspace DEK). The `dek` is
  the raw 32-byte key (cached in memory after the first unwrap).
  """
  @spec active_dek(binary() | nil, String.t()) :: {pos_integer(), binary()}
  def active_dek(workspace_id, scope) when is_binary(scope) do
    case Repo.one(active_query(workspace_id, scope)) do
      %DataKey{version: v} = dk ->
        {v, unwrap_cached(dk)}

      nil ->
        create_active(workspace_id, scope)
    end
  end

  @doc "Return `{:ok, dek}` for a specific (scope, version) — nil workspace."
  @spec dek_for_version(String.t(), pos_integer()) :: {:ok, binary()} | :error
  def dek_for_version(scope, version) when is_binary(scope) and is_integer(version),
    do: dek_for_version(nil, scope, version)

  @doc "Return `{:ok, dek}` for a specific (workspace_id, scope, version), or `:error`."
  @spec dek_for_version(binary() | nil, String.t(), pos_integer()) :: {:ok, binary()} | :error
  def dek_for_version(workspace_id, scope, version)
      when is_binary(scope) and is_integer(version) do
    case cache_get(workspace_id, scope, version) do
      {:ok, dek} ->
        {:ok, dek}

      :miss ->
        case Repo.one(version_query(workspace_id, scope, version)) do
          %DataKey{} = dk -> {:ok, unwrap_cached(dk)}
          nil -> :error
        end
    end
  end

  @doc "Start a new active DEK version for `scope` — nil workspace."
  @spec rotate_dek(String.t()) :: {pos_integer(), binary()}
  def rotate_dek(scope) when is_binary(scope), do: rotate_dek(nil, scope)

  @doc """
  Start a new active DEK version for `(workspace_id, scope)`. The previous
  version is deactivated but remains in the table so existing ciphertext stays
  decryptable; re-encryption to the new version is lazy (on next write of each
  field).
  """
  @spec rotate_dek(binary() | nil, String.t()) :: {pos_integer(), binary()}
  def rotate_dek(workspace_id, scope) when is_binary(scope) do
    Repo.transaction(fn ->
      next = (max_version(workspace_id, scope) || 0) + 1
      Repo.update_all(scope_query(workspace_id, scope), set: [active: false])
      insert_version!(workspace_id, scope, next)
    end)
    |> case do
      {:ok, dk} -> {dk.version, unwrap_cached(dk)}
    end
  end

  @doc """
  KEK-rotation seam: re-wrap every stored DEK under the CURRENT KEK and update
  `kek_version`. No content is re-encrypted — only the small wrapped-DEK blobs.
  Requires the current provider to be able to `unwrap/1` the existing blobs
  (i.e. run while both old+new KEK are resolvable, per the provider's design).
  """
  @spec rewrap_all() :: {:ok, non_neg_integer()} | {:error, term()}
  def rewrap_all do
    Repo.transaction(fn ->
      DataKey
      |> Repo.all()
      |> Enum.reduce(0, fn dk, n ->
        case KeyProvider.unwrap(dk.wrapped_key) do
          {:ok, dek} ->
            dk
            |> DataKey.changeset(%{
              wrapped_key: KeyProvider.wrap(dek),
              kek_version: KeyProvider.kek_version()
            })
            |> Repo.update!()

            n + 1

          :error ->
            Repo.rollback({:unwrap_failed, dk.id})
        end
      end)
    end)
  end

  # ── internals ────────────────────────────────────────────────────────────

  # Scope + workspace query. `workspace_id == nil` matches the NULL-workspace
  # rows (`IS NULL`); a non-nil id matches that workspace exactly. Keeping the
  # NULL/non-NULL split explicit is what makes the two-partial-index D52 scheme
  # (LOW-18 for NULL rows, per-workspace for attributed rows) correct at read time.
  defp scope_query(nil, scope),
    do: from(d in DataKey, where: d.scope == ^scope and is_nil(d.workspace_id))

  defp scope_query(workspace_id, scope),
    do: from(d in DataKey, where: d.scope == ^scope and d.workspace_id == ^workspace_id)

  defp active_query(workspace_id, scope),
    do: from(d in scope_query(workspace_id, scope), where: d.active == true)

  defp version_query(workspace_id, scope, version),
    do: from(d in scope_query(workspace_id, scope), where: d.version == ^version)

  defp create_active(workspace_id, scope) do
    Repo.transaction(fn ->
      # Re-check inside the transaction in case a concurrent caller won the race.
      case Repo.one(active_query(workspace_id, scope)) do
        %DataKey{} = dk -> dk
        nil -> insert_version!(workspace_id, scope, (max_version(workspace_id, scope) || 0) + 1)
      end
    end)
    |> case do
      {:ok, dk} -> {dk.version, unwrap_cached(dk)}
    end
  rescue
    # Lost the unique-index race against a concurrent creator — re-read.
    Ecto.ConstraintError ->
      %DataKey{version: v} = dk = Repo.one!(active_query(workspace_id, scope))
      {v, unwrap_cached(dk)}
  end

  defp insert_version!(workspace_id, scope, version) do
    dek = :crypto.strong_rand_bytes(@dek_bytes)

    %DataKey{}
    |> DataKey.changeset(%{
      scope: scope,
      version: version,
      wrapped_key: KeyProvider.wrap(dek),
      kek_version: KeyProvider.kek_version(),
      active: true,
      workspace_id: workspace_id
    })
    |> Repo.insert!()
    |> tap(&cache_put(&1.workspace_id, &1.scope, &1.version, dek))
  end

  defp max_version(workspace_id, scope) do
    Repo.one(from d in scope_query(workspace_id, scope), select: max(d.version))
  end

  defp unwrap_cached(%DataKey{workspace_id: ws, scope: scope, version: version} = dk) do
    case cache_get(ws, scope, version) do
      {:ok, dek} ->
        dek

      :miss ->
        {:ok, dek} = KeyProvider.unwrap(dk.wrapped_key)
        cache_put(ws, scope, version, dek)
        dek
    end
  end

  # ── ETS cache of UNWRAPPED DEKs (process-shared; lazily created) ───────────

  defp cache_get(workspace_id, scope, version) do
    ensure_cache()

    case :ets.lookup(@cache, {workspace_id, scope, version}) do
      [{_, dek}] -> {:ok, dek}
      [] -> :miss
    end
  end

  defp cache_put(workspace_id, scope, version, dek) do
    ensure_cache()
    # Clear-on-full memory bound (see @max_cached_deks). Safe: an evicted DEK is
    # re-derived on the next cache_get miss via the same cold path callers
    # already take, so nothing about correctness, rotation, or access changes.
    if :ets.info(@cache, :size) >= @max_cached_deks do
      :ets.delete_all_objects(@cache)
    end

    :ets.insert(@cache, {{workspace_id, scope, version}, dek})
    dek
  end

  @doc false
  # Test seam: exercise the cache_put memory bound without real DEK derivation
  # (which needs the KEK + a stored wrapped DEK). Not part of the public API.
  def __cache_put_for_test__(workspace_id, scope, version, dek),
    do: cache_put(workspace_id, scope, version, dek)

  defp ensure_cache do
    case :ets.whereis(@cache) do
      :undefined ->
        try do
          :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end
end
