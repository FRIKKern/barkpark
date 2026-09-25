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

    * `Barkpark.Content.Codelists.register/3` — the codelist replacement
      transaction both OnixEdit boot seeders (`Codelists.EDItEUR.seed_bundled/0`
      and `seed_thema/0`) and the WI3 import task run. `replace_values!` is one
      cascading DELETE plus chunked INSERTs over ~3,000 Thema nodes; on
      guerrilla 2026-09-02, under campaign load, the boot-time Thema seed was
      CANCELLED by the role's 60 s wall (57014) — a slot that cannot finish
      booting on a busy box. It issues `set_local_statement_timeout!(:infinity)`
      as its first statement.

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

    * `Barkpark.Release.migrate/0` overrides it to `"0"` for the release path,
      by merging the parameter into the repo's app env around `with_repo/3`
      (ecto_sql 3.13.5's `with_repo/3` ignores a `parameters:` option).
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

  # How many times the statement_timeout LIFT may be re-issued when the wall it
  # is lifting cancels the lift itself. See `retry_on_query_canceled/2`.
  @lift_attempts 4

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

    retry_on_query_canceled(fn ->
      query!("SET LOCAL statement_timeout = '#{value}'", [], mode: :savepoint)
    end)

    :ok
  end

  @doc """
  Run `fun`, retrying it when Postgres cancels its statement on the
  `statement_timeout` already in force (SQLSTATE 57014, `query_canceled`).

  ## Why the lift needs this

  `SET LOCAL statement_timeout = …` is itself a statement, and Postgres arms
  the wall in force at the START of every statement — including the one whose
  whole job is to remove that wall. So the lift is cancellable BY THE VALUE IT
  IS LIFTING. Measured on push:main run 33967719694 (sha 1600379b9,
  2026-09-05T13:02Z): with a 1 ms wall in force,
  `Barkpark.Content.Codelists.register/3` died with

      ** (Postgrex.Error) ERROR 57014 (query_canceled) canceling statement due to statement timeout
        (barkpark 0.1.0) lib/barkpark/repo.ex:160: Barkpark.Repo.set_local_statement_timeout!/1

  — the raise is at the `SET LOCAL` line, not at the ~3,000-row INSERT the lift
  exists to protect. No SQL path is exempt from `statement_timeout` (a plain
  `SET`, a `RESET`, `set_config(…)` are all statements and all arm the same
  timer), so "cannot be cancelled" is not reachable by choosing a different
  statement. What IS reachable is that a cancelled lift cannot FAIL the caller:
  run it inside a SAVEPOINT so the cancellation is confined, then issue it
  again. The lift is idempotent and takes microseconds of server time, so a
  bounded retry converges; only a wall that cancels EVERY attempt gives up, and
  it gives up by re-raising the original error rather than by silently running
  the caller's work under the wall it asked to remove.

  `mode: :savepoint` is what makes the retry reachable at all, and it is NOT
  optional: without it DBConnection marks the whole transaction `:aborted` the
  moment the statement errors, and the retry raises
  `DBConnection.TransactionError` ("transaction is aborted") instead of
  running. Run-proven both ways by the pair of tests in
  `test/barkpark/content/codelists_register_statement_timeout_test.exs`.

  The sandbox does NOT supply the option for us. `Ecto.Adapters.SQL.Sandbox`'s
  `maybe_savepoint/2` appends `mode: :savepoint` only when `not
  in_transaction?`, and this lift always runs inside the caller's transaction —
  so deleting the option here goes RED in the suite, not just in prod
  (run-proven: without it the retry's own statement reaches the server and
  comes back `Postgrex.Error` 25P02 `in_failed_sql_transaction` instead of
  being refused locally as `DBConnection.TransactionError`).
  """
  @spec retry_on_query_canceled((-> result), pos_integer()) :: result when result: var
  def retry_on_query_canceled(fun, attempts \\ @lift_attempts)
      when is_function(fun, 0) and is_integer(attempts) and attempts >= 1 do
    fun.()
  rescue
    error in Postgrex.Error ->
      if attempts > 1 and query_canceled?(error) do
        retry_on_query_canceled(fun, attempts - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp query_canceled?(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: true
  defp query_canceled?(%Postgrex.Error{}), do: false

  @doc """
  Cast a caller-supplied id to a `:binary_id` UUID string, or `nil`.

  The one shared guard for every `Repo.get`/`where` keyed on a `:binary_id`
  primary key fed a raw path param: `Ecto.UUID.cast` on a non-UUID string
  returns `:error`, so binding it to a `:binary_id` column would raise
  `Ecto.Query.CastError`. phoenix_ecto carries a `Plug.Exception` impl for it
  (`{Ecto.Query.CastError, 400}` in `phoenix_ecto/lib/phoenix_ecto/plug.ex`), so
  an unguarded fetch answers an opaque **400** `internal_error` — NOT the 500
  this docstring used to claim, and never the clean 404 the caller wanted. 500
  is Plug's `Any` fallback, which covers the nil / non-binary `FunctionClauseError`
  class instead.

  THE STRUCT NAME IS LOAD-BEARING (corrected arpss-w8). This docstring used to
  say `Ecto.CastError`. That is a DIFFERENT struct, and it is not the one this
  guard prevents: an `assert_raise Ecto.CastError, fn -> ... end` written from
  the old wording could never match the real raise, so it would look like a
  guard test and pin nothing. Measured, not read — a `Repo.one` binding
  `"not-a-uuid"` to a `:binary_id` column raises `%Ecto.Query.CastError{}`,
  pinned at
  `test/barkpark_web/live/studio/caps_non_uuid_workspace_denies_test.exs`.

  A malformed id can't identify any row, so callers fold `nil` into their
  existing not_found/`nil` branch. Returns the CAST string on success (callers
  bind the returned value, not the original).
  """
  # @canonical capability:uuid-guarded-fetch aka:CastError,binary_id,uuid,Ecto.UUID.cast doc:docs/contracts/tenancy.md
  def uuid_or_nil(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  def uuid_or_nil(_), do: nil

  @doc """
  Start a dedicated, short-lived connection pool for ONE workspace export, and
  return the dynamic-repo name to run its `COPY … TO STDOUT` streams on.

  ## Why the export needs its own connections (pds-bl-export-pool-starvation)

  `Tenancy.WorkspaceBundle.run_copy_out/3` holds ONE pool member for the whole
  of one `COPY … TO STDOUT` — measured at 9.34 s (`mutation_events`, 478 MB)
  and 8.04 s (`revisions`, 385 MB) on a WARM cache, longer cold, and with
  `statement_timeout` deliberately lifted to `0` so nothing cancels it. In prod
  that member comes out of the SAME `POOL_SIZE` (default 10) that 29 Oban queue
  slots and all HTTP traffic share (see the note above `repo_opts` in
  `config/runtime.exs`). A checkout that queues behind it is charged the wait
  against its own budget, which is how a dev-profile export produced, six
  seconds after it finished:

      Postgrex.Protocol disconnected: (DBConnection.ConnectionError) client
      (Barkpark.EdgeProjector.ProjectorWorker) timed out because it queued and
      checked out the connection for longer than 15000ms

  The export was not the victim and was not slow — it was simply holding a
  member of a pool that had none to spare.

  ## Why a pool, and why this shape

  Three remedies were on the table; only one removes the coupling.

    * An export-path CHECKOUT TIMEOUT re-prices the wrong side. The export is
      not the client that times out; capping its own wait fails exports without
      returning a single connection to the starved worker any sooner.
    * A BOUNDED COPY HOLD is not implementable without changing what the bundle
      is. `COPY (SELECT …) TO STDOUT` cannot be suspended and resumed — bounding
      it means keyset-paginating each member into many statements, multiplying
      the statement count and giving up the single-statement snapshot each
      member is dumped under. That is a bundle-fidelity change wearing a
      pool-pressure costume.
    * ISOLATION removes the coupling itself: if the COPY never draws on the
      shared pool, no unrelated checkout can queue behind it, whatever the
      export's duration — and the duration is exactly the quantity that is NOT
      stable (the same dev export measured 1.345 s and 7.110 s across runs).

  It is started PER EXPORT and stopped in the export's `after`, not held
  permanently in the supervision tree, because the charter refuses to pay for
  idle connections on a 2-vCPU box already deep in swap
  (`bp-deploy-reliability-charter.md` D75). Between exports the box carries
  exactly the connections it carries today.

  `pool_size` defaults to **1**, which is the whole demand: the COPY loop is a
  sequential `Enum.reduce` over the member tables and never has two streams in
  flight. So an export in progress costs POOL_SIZE + 1 connections while the
  shared pool keeps all of its own — strictly better than today, where the
  export takes one of the shared ten and holds it for seconds at a time.

  The name is unique per call (`System.unique_integer/1`), so two concurrent
  exports never contend for one another's pool and neither can stop the other's.

  Returns `{:ok, pid}` (the pool is UNNAMED — the pid is the handle, so no
  atom is created per export), `:disabled` when `:export_pool_size` is `0` or
  less (the config/test.exs default — the SQL sandbox owns the connection there
  and a second real pool would not see the test's uncommitted rows), or
  `{:error, reason}`. A caller that does not get a pool MUST fall back to the
  default repo: this is a contention remedy, never a correctness precondition.
  """
  @spec start_export_pool(keyword()) :: {:ok, pid()} | :disabled | {:error, term()}
  def start_export_pool(opts \\ []) do
    size = Keyword.get(opts, :pool_size, export_pool_size())

    if is_integer(size) and size > 0 do
      repo_opts =
        config()
        |> Keyword.drop([:name, :pool, :pool_size, :pool_count])
        |> Keyword.merge(
          # UNNAMED, and the PID is the handle (Ecto's documented form for a
          # repo started dynamically: `MyApp.Repo.start_link(name: nil, …)`;
          # `put_dynamic_repo/1` and `Ecto.Adapter.lookup_meta/1` both take a
          # pid). A per-export ATOM would be a new atom on every export, and
          # atoms are never garbage collected — an unbounded allocation on a
          # request-reachable admin path, which is exactly what Sobelow's
          # DOS.BinToAtom names. A pid also removes the `{:already_started, _}`
          # case entirely: there is no name left to collide on.
          name: nil,
          # NEVER inherit `pool:` from config: in :test that is
          # `Ecto.Adapters.SQL.Sandbox`, and a second sandbox pool is not a
          # second pool at all. This one is always a real pool.
          pool: DBConnection.ConnectionPool,
          pool_size: size
        )

      case start_link(repo_opts) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    else
      :disabled
    end
  end

  @doc """
  Stop a pool started by `start_export_pool/1`. Best-effort: a pool that has
  already died, or that exits `:shutdown` on its way out, is not an error the
  export should care about.
  """
  @spec stop_export_pool(pid()) :: :ok
  def stop_export_pool(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        Supervisor.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Run `fun` with `pid` as the dynamic repo, restoring the previous one after.

  `nil` means "no dedicated pool" and runs `fun` unchanged on whatever repo the
  caller already had — the fallback every caller of `start_export_pool/1` needs.

  NOTE FOR CALLERS THAT STREAM: the generated `Repo.*` functions resolve the
  dynamic repo for you, but `Ecto.Adapters.SQL.stream/4` does NOT — it calls
  `Ecto.Adapter.lookup_meta/1` on whatever it is handed. Hand it
  `get_dynamic_repo()`, not the bare module, or the stream keys its adapter meta
  on the DEFAULT pool while the surrounding transaction checked out of this one
  and `Ecto.Adapters.SQL.reduce/6` raises "cannot reduce stream outside of
  transaction".
  """
  @spec with_export_repo(pid() | nil, (-> result)) :: result when result: var
  def with_export_repo(nil, fun) when is_function(fun, 0), do: fun.()

  def with_export_repo(pid, fun) when is_pid(pid) and is_function(fun, 0) do
    previous = get_dynamic_repo()
    put_dynamic_repo(pid)

    try do
      fun.()
    after
      put_dynamic_repo(previous)
    end
  end

  @doc """
  How many connections one export's dedicated pool gets. `0` disables the
  dedicated pool entirely (config/test.exs).
  """
  @spec export_pool_size() :: integer()
  def export_pool_size, do: Application.get_env(:barkpark, :export_pool_size, 1)

  # ── The Oban job pool (jpf-bl-oban-pool-partition) ─────────────────────────

  @job_pool Barkpark.Repo.Jobs
  @job_pool_handler_id "barkpark-oban-job-pool-router"

  @doc """
  The registered name of the second `Barkpark.Repo` instance that Oban job
  bodies run on. A NAME, not a module: it is this repo, started twice.
  """
  @spec job_pool_name() :: atom()
  def job_pool_name, do: @job_pool

  @doc """
  How many connections the Oban job pool gets. `0` disables it (config/test.exs:
  the SQL sandbox owns the connection there, and a second real pool would not
  see a test's uncommitted rows) and every job runs on the shared pool, exactly
  as before this pool existed.
  """
  @spec job_pool_size() :: non_neg_integer()
  # `|| 0`, not a get_env default: a key PRESENT with value nil (a test restoring
  # an unset key with put_env/3) must read as "no pool", not as nil.
  def job_pool_size, do: Application.get_env(:barkpark, :oban_pool_size) || 0

  @doc """
  The child spec list for the Oban job pool: `[spec]`, or `[]` when
  `job_pool_size/0` is `0`.

  ## Why a partition and not a cap (the decision, with its numbers)

  Every Oban job body used to check out of the ONE `POOL_SIZE` pool (prod
  default 10) that every HTTP request uses, and `config/config.exs` declares 29
  queue slots across 9 queues. Saturated background work could therefore take
  all ten connections and leave HTTP none. Measured locally with
  `scripts/mutate-load` (200 create+publish rounds x 25) while 29 slots of
  `pg_sleep(3 s)` jobs ran: on the shared pool 1/200 and 18/200 rounds landed,
  the rest `503` pool drops; on this partition 200/200 both times, create p95
  under 0.52 s. The numbers and the POOL_SIZE arithmetic are in the note above
  `repo_opts` in `config/runtime.exs`.

  Capping the aggregate cannot fix that on this queue set: OSS Oban has no
  global limit, so the floor is one slot per queue, i.e. 9 of 10 connections,
  leaving HTTP one. Raising `POOL_SIZE` alone moves the contention into
  Postgres and still lets Oban take every new connection. A partition does
  what neither can: job bodies draw from THIS pool, so however many slots are
  busy and however long they hold, the web pool keeps all `POOL_SIZE` members.

  What still uses the shared pool, and why that is safe: Oban's own
  producer / stager / cron / pruner queries (millisecond checkouts, never a
  job body), an HTTP request that ENQUEUES a job (it stays on the request's
  pool; its insert is one short statement), and any process a job body spawns
  (the dynamic repo is per-process — no worker spawns one today).

  ## Queue timing

  29 slots share these few connections, so jobs WAIT for one. A job has no
  caller waiting on it, so waiting is the right answer and failing is the wrong
  one (it burns an attempt). On this pool only: `queue_target` / `queue_interval`
  10 s / 60 s and a 60 s client `:timeout` (which counts the queue wait). With
  Ecto's 15 s default, 87 back-to-back 3 s jobs on 4 connections lost 39 to
  `57014 canceling statement due to user request`; at 60 s all 87 completed in
  67 s. The waiters are bounded by the declared slots, and `statement_timeout`
  (30 s in prod) still bounds each statement server-side. The web pool keeps
  DBConnection's 50 ms / 1 s and Ecto's 15 s on purpose — see the note above
  `repo_opts` in `config/runtime.exs`.
  """
  @spec job_pool_child_specs() :: [Supervisor.child_spec()]
  def job_pool_child_specs do
    case job_pool_size() do
      size when is_integer(size) and size > 0 ->
        opts =
          config()
          |> Keyword.drop([
            :name,
            :pool,
            :pool_size,
            :pool_count,
            :queue_target,
            :queue_interval,
            :timeout
          ])
          |> Keyword.merge(
            name: @job_pool,
            # NEVER inherit `pool:` from config (in :test it is the SQL
            # sandbox); this is always a real pool.
            pool: DBConnection.ConnectionPool,
            pool_size: size,
            queue_target: 10_000,
            queue_interval: 60_000,
            timeout: 60_000
          )

        [Supervisor.child_spec({__MODULE__, opts}, id: @job_pool)]

      _ ->
        []
    end
  end

  @doc """
  Attach the `[:oban, :job, :start]` handler that routes a job body onto the
  job pool. Oban emits that event from the job's own Task process, before
  `perform/1`, so `put_dynamic_repo/1` there covers the whole body AND Oban's
  ack of the job, and dies with the process. Idempotent.
  """
  @spec attach_job_pool_router() :: :ok
  def attach_job_pool_router do
    _ = :telemetry.detach(@job_pool_handler_id)

    :ok =
      :telemetry.attach(
        @job_pool_handler_id,
        [:oban, :job, :start],
        &__MODULE__.route_job_to_job_pool/4,
        nil
      )
  end

  @doc false
  # A contention remedy, never a correctness precondition: when the job pool is
  # not running (disabled, one-shot/seed boot, or mid-restart) the job stays on
  # the shared pool rather than failing. `Oban.Testing.perform_job/3` runs the
  # executor in the TEST process; with the pool disabled in :test this is a
  # no-op there, so a test's sandbox connection is never swapped away.
  def route_job_to_job_pool(_event, _measurements, _meta, _config) do
    if Process.whereis(@job_pool), do: put_dynamic_repo(@job_pool)
    :ok
  end
end
