defmodule Barkpark.Repo do
  @moduledoc """
  The Ecto repository — Barkpark's single Postgres connection pool. Every query,
  changeset, and migration in the app runs through it.

  ## The pool-wide `statement_timeout`, and how to opt out of it

  `config/runtime.exs` sends `parameters: [statement_timeout: "30s"]` as a
  Postgrex STARTUP parameter in `:prod`, so every connection in the pool — HTTP
  and all 29 Oban queue slots alike — carries a server-side wall on ONE
  statement. The reasoning (and the guerrilla measurement that forced it) lives
  in the comment above `statement_timeout =` in that file; the short version is
  that Ecto's `:timeout` is a CLIENT-side deadline that abandons the socket
  while the Postgres backend keeps running, and `statement_timeout` is the only
  half that actually cancels the backend and frees the pool member.

  A handful of statements are legitimately longer than 30 s. They opt out here,
  never by weakening the pool-wide value.

  ### The opt-out inventory (as of 2026-09-02)

    * `Barkpark.Tenancy.WorkspaceBundle.run_copy_out/2` — one
      `COPY (SELECT …) TO STDOUT` per table. Run-proven at 9.34 s / 478 MB
      (`mutation_events`) and 8.04 s / 385 MB (`revisions`) on a WARM cache and
      longer on a cold one; PDS-D42 already gave this transaction `:infinity`
      for exactly that reason. An export is admin-initiated, never on the
      request path, and its natural bound is "as long as the dump takes".
    * `Barkpark.Tenancy.WorkspaceBundle.run_import/4` — the import transaction:
      owner-privilege DDL plus one `COPY … FROM STDIN` per table, fed in 64 KiB
      chunks from disk. Same shape, same bound; it has carried
      `timeout: :infinity` since it was written.

  Nothing else on `main` needs it. Every Oban worker checked (EdgeProjector,
  the pulse/TTL/stuck-processing/stuck-delivery sweepers, the search
  crystallize/prune pair, `Tasks.Compactor`, the findability posttest, the
  audit export worker) either works row-at-a-time under an advisory lock or
  issues range `DELETE`s bounded by a TTL cutoff — no single statement
  approaches 30 s. `EdgeProjector.rebuild_scope/3` is the closest call and is
  deliberately NOT wrapped: its `timeout: 60_000` is a WHOLE-TRANSACTION budget
  spanning one endpoint-resolve query, a chunked `insert_all` and one reload,
  and no individual statement in it has been measured anywhere near 30 s.

  ### Migrations

  `Ecto.Migrator.with_repo/3` starts the repo with the SAME config, so a
  migration connection inherits the 30 s wall too. Two consequences:

    * `Barkpark.Release.migrate/0` overrides it to `"0"` for the release path.
    * `make deploy` migrates through `mix ecto.migrate` (see the Makefile), NOT
      through `Barkpark.Release`, so that override does not cover the live
      deploy. A migration that runs one long statement MUST disable the wall
      itself, or Postgres cancels it — and a cancelled `CREATE INDEX
      CONCURRENTLY` leaves an INVALID index behind:

          @disable_ddl_transaction true
          @disable_migration_lock true

          def up do
            repo().checkout(fn ->
              repo().query!("SET statement_timeout = 0")
              execute("CREATE INDEX CONCURRENTLY …")
            end)
          end

      Plain `SET` (not `SET LOCAL`) is correct here precisely because
      `CONCURRENTLY` cannot run inside a transaction, and `checkout/1` bounds
      the setting to that one connection.
      `priv/repo/migrations/20260901180000_add_ready_queue_task_indexes.exs`
      builds `CONCURRENTLY` on `documents` and does NOT yet carry this guard;
      it survives only because `documents` is ~10.6k rows. Any
      `CONCURRENTLY` build on `mutation_events` (2.2 GB) will NOT.
  """
  use Ecto.Repo,
    otp_app: :barkpark,
    adapter: Ecto.Adapters.Postgres

  # Postgres accepts a bare integer (milliseconds) or an integer plus a unit.
  # This is the ONLY thing standing between a caller-supplied value and a `SET`
  # statement — `SET` takes no bind parameters, so the value must be
  # interpolated and must therefore be proven to be digits-and-a-unit first.
  @timeout_shape ~r/^\d+(us|ms|s|min|h|d)?$/

  @doc """
  Run `fun` inside a transaction whose statements are bounded by `timeout`
  instead of the pool-wide `statement_timeout`.

  `timeout` is `0` / `:infinity` (no bound), a positive integer (milliseconds),
  or a Postgres interval string (`"90s"`). Returns whatever `transaction/2`
  returns.

  The transaction itself is `timeout: :infinity` — the whole point is that the
  caller has decided how long this work may take, so re-imposing Ecto's
  client-side 15 s default underneath would just move the failure.

  Use this when you are opening the transaction anyway. If the caller ALREADY
  owns a transaction whose own `:timeout` is load-bearing, call
  `set_local_statement_timeout!/1` as that transaction's first statement
  instead: nesting `transaction/2` makes the inner call a savepoint join and
  its `:timeout` option INERT, which is the exact trap
  `Tenancy.WorkspaceBundle`'s PDS-D42 comment documents.
  """
  @spec with_statement_timeout(0 | :infinity | pos_integer() | String.t(), (-> any())) ::
          {:ok, any()} | {:error, any()}
  def with_statement_timeout(timeout, fun) when is_function(fun, 0) do
    transaction(
      fn ->
        set_local_statement_timeout!(timeout)
        fun.()
      end,
      timeout: :infinity
    )
  end

  @doc """
  Issue `SET LOCAL statement_timeout` on the current transaction's connection.

  MUST be called from inside a transaction. `SET LOCAL` is scoped to the
  transaction — Postgres reverts it at `COMMIT`/`ROLLBACK` — which is the whole
  reason this is not a plain `SET`: a plain `SET` on a POOLED connection
  outlives the checkout and silently hands the next, unrelated caller a wall it
  never asked for (or, worse, no wall at all).

  Raises `ArgumentError` outside a transaction, or on a value Postgres could
  not parse.
  """
  @spec set_local_statement_timeout!(0 | :infinity | pos_integer() | String.t()) :: :ok
  def set_local_statement_timeout!(:infinity), do: set_local_statement_timeout!("0")
  def set_local_statement_timeout!(0), do: set_local_statement_timeout!("0")

  def set_local_statement_timeout!(ms) when is_integer(ms) and ms > 0,
    do: set_local_statement_timeout!("#{ms}ms")

  # The interpolation below is gated by @timeout_shape one line above it, so the
  # value reaching SQL is digits plus an optional unit keyword and nothing else.
  # `SET` accepts no bind parameters, so there is no parameterised form to use.
  # sobelow_skip ["SQL.Query"]
  def set_local_statement_timeout!(value) when is_binary(value) do
    unless Regex.match?(@timeout_shape, value) do
      raise ArgumentError,
            "invalid statement_timeout #{inspect(value)}: expected a bare integer " <>
              "(milliseconds) or an integer with a us|ms|s|min|h|d unit, e.g. \"90s\""
    end

    unless in_transaction?() do
      raise ArgumentError,
            "set_local_statement_timeout!/1 must run inside a transaction — SET LOCAL " <>
              "outside one is a no-op, so the caller would silently keep the pool-wide " <>
              "bound. Use Barkpark.Repo.with_statement_timeout/2 instead."
    end

    query!("SET LOCAL statement_timeout = '#{value}'")
    :ok
  end

  @doc """
  Cast a caller-supplied id to a `:binary_id` UUID string, or `nil`.

  The one shared guard for every `Repo.get`/`where` keyed on a `:binary_id`
  primary key fed a raw path param: `Ecto.UUID.cast` on a non-UUID string
  returns `:error`, so binding it to a `:binary_id` column would raise
  `Ecto.CastError` → 500. A malformed id can't identify any row, so callers
  fold `nil` into their existing not_found/`nil` branch. Returns the CAST
  string on success (callers bind the returned value, not the original).
  """
  # @canonical capability:uuid-guarded-fetch aka:CastError,binary_id,uuid,Ecto.UUID.cast doc:docs/contracts/tenancy.md
  def uuid_or_nil(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  def uuid_or_nil(_), do: nil
end
