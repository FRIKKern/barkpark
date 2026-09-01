defmodule Barkpark.Plugins.Indx.Persistence do
  @moduledoc """
  Durable per-INDEX key_map storage — the closure of P4b Hardening B.

  The live pointer + key_map have always lived in `:persistent_term`,
  which Erlang wipes on every Barkpark restart. The original delete
  path papered over the gap with a "bare-hash fallback" — when the
  in-memory map didn't know about an `_id`, the delete used the raw
  SHA-256-derived key and accepted a `~2^-63` per-pair mis-target risk
  on a true hash collision plus a missing map.

  Persisted per INDEX — keyed by `Indexer.index_key/2`, so co-tenants sharing
  one dataset string never overwrite each other — so `Recovery` re-seats the
  EXACT state and `delete_target_keys` never needs the bare-hash branch.

  ## File format

  One file per index at `<dir>/<safe_key>.term`, the body is
  `:erlang.term_to_binary(%{dataset, key_map})`. Writes are atomic via
  the temp-file + rename dance: a crash mid-write leaves the previous
  file intact, never a partial blob.

  ## Configuration

      config :barkpark, Barkpark.Plugins.Indx.Persistence,
        dir: "/var/lib/barkpark/indx-state"

  Default in dev/test: `Application.app_dir(:barkpark, "priv/indx_state")`.
  The directory is created lazily on the first `save/2`.

  ## When it writes

  Called from the three key_map mutation points in `Indx.Indexer`:
    * `swap/2` after a full rebuild (fresh dataset + fresh key_map)
    * `merge_key_map/3` after an incremental upsert (one new key)
    * `restore_pointer/2` after boot recovery (with the LOADED key_map,
      not the previously-empty one)

  Sync I/O is fine in practice — upserts are 5s-debounced by the
  `IndexerWorker` Oban job, so the per-index write rate is at most
  one every five seconds.

  ## Safety / scope sanitization

  The key segment is `URI.encode_www_form/1`'d so an exotic key string
  never escapes the `dir` boundary. A key of `"../etc/passwd"` becomes
  `..%2Fetc%2Fpasswd.term` — same dir, no path-traversal.
  """

  require Logger

  # Sobelow reads `@sobelow_skip` from source; register it so the compiler
  # counts it as used (else `--warnings-as-errors` reds on "set but never used").
  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true, persist: true)

  @type scope :: String.t()
  @type entry :: %{dataset: String.t() | nil, key_map: %{optional(integer()) => String.t()}}

  @doc """
  Persist `%{dataset, key_map}` for `scope`. Writes atomically; returns
  `:ok` on success or `{:error, reason}`. Failures are LOGGED so a
  misconfigured persistence dir is visible in the boot logs, but never
  crashes the caller — the live pointer in `:persistent_term` is still
  authoritative for the running process.
  """
  @spec save(scope(), entry()) :: :ok | {:error, term()}
  def save(scope, %{} = entry) when is_binary(scope) do
    path = path_for(scope)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, :erlang.term_to_binary(entry)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Indx.Persistence: save failed for scope=#{scope} path=#{path}: #{inspect(reason)}"
        )

        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @doc """
  Load `%{dataset, key_map}` for `scope`, or `:error` if the file is
  missing / unreadable / not-a-binary-term. A corrupt file is logged
  and treated as missing — Recovery will rebuild from the live engine's
  dataset list.
  """
  # The bytes come from `save/2`'s own `term_to_binary` (trusted, self-written).
  # We still decode with `[:safe]` as defense-in-depth: a tampered/corrupt file
  # can neither mint atoms (atom-table exhaustion) nor materialize unsafe terms
  # — the `rescue ArgumentError` below folds any such input into `:error`
  # ("treated as missing"). Sobelow flags every `binary_to_term` regardless of
  # `[:safe]`, so this justified use is annotated rather than left as a finding.
  @sobelow_skip ["Misc.BinToTerm"]
  @spec load(scope()) :: {:ok, entry()} | :error
  def load(scope) when is_binary(scope) do
    path = path_for(scope)

    case File.read(path) do
      {:ok, binary} ->
        try do
          case :erlang.binary_to_term(binary, [:safe]) do
            %{dataset: _, key_map: km} = entry when is_map(km) -> {:ok, entry}
            _ -> :error
          end
        rescue
          ArgumentError ->
            Logger.warning("Indx.Persistence: corrupt term file scope=#{scope} path=#{path}")
            :error
        end

      {:error, :enoent} ->
        :error

      {:error, reason} ->
        Logger.warning("Indx.Persistence: read failed scope=#{scope}: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Load every persisted index from `dir`. Returns `%{index_key => entry}` —
  unreadable / corrupt files are skipped (logged). Used by `Recovery`
  to seed the in-memory pointer table at boot before the live engine
  is queried.
  """
  @spec load_all() :: %{scope() => entry()}
  def load_all do
    case File.ls(dir()) do
      {:ok, files} ->
        # Reject the `:error` branch BEFORE it reaches the map collector: a
        # bare `nil` element would flow into `:maps.from_list/1` mid-collect and
        # raise ArgumentError (a corrupt file would take the whole recovery down
        # with it). The `{:ok, entry} <- [...]` filter-generator drops any scope
        # whose `load/1` returned `:error` (already logged) so only valid scopes
        # collect — honoring the "corrupt files are skipped (logged)" contract.
        for file <- files,
            String.ends_with?(file, ".term"),
            scope = file |> String.trim_trailing(".term") |> URI.decode_www_form(),
            {:ok, entry} <- [load(scope)],
            into: %{} do
          {scope, entry}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("Indx.Persistence: ls failed dir=#{dir()}: #{inspect(reason)}")
        %{}
    end
  end

  @doc "Path the file for `scope` is stored at. Public for tests and diagnostics."
  @spec path_for(scope()) :: Path.t()
  def path_for(scope) when is_binary(scope) do
    Path.join(dir(), URI.encode_www_form(scope) <> ".term")
  end

  @doc "Persistence dir; honors `:barkpark, #{inspect(__MODULE__)}, :dir` config."
  @spec dir() :: Path.t()
  def dir do
    case Application.get_env(:barkpark, __MODULE__, []) do
      opts when is_list(opts) ->
        Keyword.get(opts, :dir) || default_dir()

      _ ->
        default_dir()
    end
  end

  defp default_dir, do: Application.app_dir(:barkpark, "priv/indx_state")
end
