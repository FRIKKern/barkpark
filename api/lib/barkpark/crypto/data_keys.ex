defmodule Barkpark.Crypto.DataKeys do
  @moduledoc """
  Get-or-create and rotate per-scope Data Encryption Keys (DEKs).

  A DEK is 32 random bytes used to encrypt content fields for one *scope*
  (e.g. `"dataset:<uuid>"`). The DEK is stored only in wrapped form (sealed by
  the master KEK via `Barkpark.Crypto.KeyProvider`); the plaintext DEK is
  unwrapped on demand and cached in an ETS table so the KEK round-trip happens
  once per (scope, version), not per field.

  ## Public surface

    * `active_dek/1`        — `{version, dek}` for new encryptions; creates the
      scope's first DEK on demand.
    * `dek_for_version/2`   — `{:ok, dek}` for decrypting older ciphertext.
    * `rotate_dek/1`        — start a new active DEK version for a scope (old
      versions stay decryptable; re-encryption is lazy).
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
  Return `{version, dek}` for the scope's active DEK, creating it if absent.
  The `dek` is the raw 32-byte key (cached in memory after the first unwrap).
  """
  @spec active_dek(String.t()) :: {pos_integer(), binary()}
  def active_dek(scope) when is_binary(scope) do
    case Repo.one(from d in DataKey, where: d.scope == ^scope and d.active == true) do
      %DataKey{version: v} = dk ->
        {v, unwrap_cached(dk)}

      nil ->
        create_active(scope)
    end
  end

  @doc "Return `{:ok, dek}` for a specific (scope, version), or `:error`."
  @spec dek_for_version(String.t(), pos_integer()) :: {:ok, binary()} | :error
  def dek_for_version(scope, version) when is_binary(scope) and is_integer(version) do
    case cache_get(scope, version) do
      {:ok, dek} ->
        {:ok, dek}

      :miss ->
        case Repo.one(from d in DataKey, where: d.scope == ^scope and d.version == ^version) do
          %DataKey{} = dk -> {:ok, unwrap_cached(dk)}
          nil -> :error
        end
    end
  end

  @doc """
  Start a new active DEK version for `scope`. The previous version is
  deactivated but remains in the table so existing ciphertext stays decryptable;
  re-encryption to the new version is lazy (on next write of each field).
  """
  @spec rotate_dek(String.t()) :: {pos_integer(), binary()}
  def rotate_dek(scope) when is_binary(scope) do
    Repo.transaction(fn ->
      next = (max_version(scope) || 0) + 1
      from(d in DataKey, where: d.scope == ^scope) |> Repo.update_all(set: [active: false])
      insert_version!(scope, next)
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

  defp create_active(scope) do
    Repo.transaction(fn ->
      # Re-check inside the transaction in case a concurrent caller won the race.
      case Repo.one(from d in DataKey, where: d.scope == ^scope and d.active == true) do
        %DataKey{} = dk -> dk
        nil -> insert_version!(scope, (max_version(scope) || 0) + 1)
      end
    end)
    |> case do
      {:ok, dk} -> {dk.version, unwrap_cached(dk)}
    end
  rescue
    # Lost the unique-index race against a concurrent creator — re-read.
    Ecto.ConstraintError ->
      %DataKey{version: v} =
        dk = Repo.one!(from d in DataKey, where: d.scope == ^scope and d.active == true)

      {v, unwrap_cached(dk)}
  end

  defp insert_version!(scope, version) do
    dek = :crypto.strong_rand_bytes(@dek_bytes)

    %DataKey{}
    |> DataKey.changeset(%{
      scope: scope,
      version: version,
      wrapped_key: KeyProvider.wrap(dek),
      kek_version: KeyProvider.kek_version(),
      active: true
    })
    |> Repo.insert!()
    |> tap(&cache_put(&1.scope, &1.version, dek))
  end

  defp max_version(scope) do
    Repo.one(from d in DataKey, where: d.scope == ^scope, select: max(d.version))
  end

  defp unwrap_cached(%DataKey{scope: scope, version: version} = dk) do
    case cache_get(scope, version) do
      {:ok, dek} ->
        dek

      :miss ->
        {:ok, dek} = KeyProvider.unwrap(dk.wrapped_key)
        cache_put(scope, version, dek)
        dek
    end
  end

  # ── ETS cache of UNWRAPPED DEKs (process-shared; lazily created) ───────────

  defp cache_get(scope, version) do
    ensure_cache()

    case :ets.lookup(@cache, {scope, version}) do
      [{_, dek}] -> {:ok, dek}
      [] -> :miss
    end
  end

  defp cache_put(scope, version, dek) do
    ensure_cache()
    # Clear-on-full memory bound (see @max_cached_deks). Safe: an evicted DEK is
    # re-derived on the next cache_get miss via the same cold path callers
    # already take, so nothing about correctness, rotation, or access changes.
    if :ets.info(@cache, :size) >= @max_cached_deks do
      :ets.delete_all_objects(@cache)
    end

    :ets.insert(@cache, {{scope, version}, dek})
    dek
  end

  @doc false
  # Test seam: exercise the cache_put memory bound without real DEK derivation
  # (which needs the KEK + a stored wrapped DEK). Not part of the public API.
  def __cache_put_for_test__(scope, version, dek), do: cache_put(scope, version, dek)

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
