defmodule Barkpark.QueryCounter do
  @moduledoc """
  ONE lineage-scoped counter for every statement-budget test.

  ## Why this module exists

  `:telemetry.attach/4` is NODE-global. A handler on `[:barkpark, :repo, :query]`
  runs IN whichever process issued the statement, for EVERY statement the VM
  issues while it is attached — including statements from processes that were
  never part of the request under measurement.

  That is not hypothetical. It reddened main at sha 2c5b658d41 (run
  33830854180, attempt 1):

      [reader-query-baseline] dead leg (get/2): 19 statements
        (documents 6, datasets 4, schema_definitions 3, workspaces 2,
         chat_messages 1, content_edges 1, projects 1, task_edges 1)
      dead leg blew the budget: 19 > 18

  `chat_messages 1` is the whole defect. The anonymous paper reader never
  touches `chat_messages`; `Barkpark.StudioChat.BlockedSweeper` does — a
  GenServer child of `StudioChat.Supervisor` that boots with the app in EVERY
  env and re-arms `Process.send_after(self(), :sweep, 60_000)`, each sweep
  issuing one `Repo.all` over `chat_messages`. A measured window is a ~160ms
  slot; once per 60s a background sweep lands inside one. `gh run rerun
  --failed` on the SAME sha passed because the next sweep missed. Load widens
  the window; it does not create the bug.

  `async: false` does NOT protect against this — it fences sibling TEST
  processes, not the application supervision tree, which is running in the same
  VM the whole time. Every counter that reasoned "async: false, so nothing else
  runs concurrently" was reasoning about the wrong set of processes.

  ## Why not a pid filter

  The obvious fix — `if self() == test_pid` inside the handler — is WRONG for
  any measurement that spans a LiveView. `live/2`'s connected mount runs in the
  LiveView process, so a pid-filtered counter drops the entire connected leg
  (mutation-measured on the reader baseline: 44 -> 22).

  ## The shape: report unconditionally, decide ownership afterwards

  The handler reports from ANY process and tags each event with the issuing pid
  plus that process's spawn lineage (`$callers`, written by `Task` /
  `Task.Supervisor`; `$ancestors`, written by `proc_lib` and therefore every
  GenServer). Ownership is resolved AFTER the block has run, when the caller
  has finally been told which LiveView process served the connected mount and
  can name it with `own/1`.

  A statement counts when its issuing process is:

    * the calling test process, or
    * a process named via `own/1` during the block (the LiveView pid), or
    * a process spawned by either of those (`$callers` / `$ancestors`).

  A background sweeper started by the application supervisor at boot satisfies
  none of those, so it is excluded BY CONSTRUCTION — not by an allowlist of
  source names that would have to grow with every new sweeper.

  The exclusion is kept honest by a permanent leak-trap test
  (`Barkpark.QueryCounterTest`): a lineage-less `spawn/1` issues a real
  statement INSIDE a measured window and the census must not move, while a real
  LiveView connected mount inside the same window MUST be counted.

  ## What it is NOT

  Not a defence against foreign ROWS. Another agent writing to the shared test
  database moves nothing here: a statement census counts statements, and a
  well-keyed fixture makes row volume irrelevant to it. A foreign PROCESS is
  the hazard; a foreign row is not.

  ## Usage

      # plain count
      {result, n} = QueryCounter.count(fn -> do_the_thing() end)

      # one table only
      {result, n} = QueryCounter.count_source(fn -> ... end, "task_edges")

      # a LiveView leg — name the pid the leg returned, inside the block
      {_, n} =
        QueryCounter.count(fn ->
          {:ok, view, _html} = live(conn, "/papers/x")
          QueryCounter.own(view.pid)
          view
        end)

      # the full per-source census
      {result, {n, per_source}} = QueryCounter.census(fn -> ... end)

      # the SQL itself
      {result, sqls} = QueryCounter.sql(fn -> ... end)
  """

  @event [:barkpark, :repo, :query]
  @owned_key {__MODULE__, :owned}

  @typedoc "One owned statement: the Ecto source (table) and the SQL text."
  @type event :: %{source: String.t() | nil, query: String.t() | nil, pid: pid()}

  @doc """
  Runs `fun` with a lineage-scoped handler attached and returns
  `{fun_result, owned_events}` — the events in issue order.

  Everything else in this module is a projection of this.
  """
  @spec capture((-> result)) :: {result, [event()]} when result: term()
  def capture(fun) when is_function(fun, 0) do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}

    # Nested captures are legal: the inner one restores the outer owner list.
    outer_owned = Process.get(@owned_key)
    Process.put(@owned_key, [])

    :telemetry.attach(
      handler_id,
      @event,
      # NO pid filter here — see @moduledoc. The handler executes in the
      # query-issuing process and reports unconditionally, tagging the event
      # with that process and its spawn lineage so ownership can be decided
      # once the block has named every process that served it.
      fn _event, _measurements, meta, _cfg ->
        send(test_pid, {ref, :query, meta[:source], meta[:query], self(), process_lineage()})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    extra_pids = Process.get(@owned_key, [])
    if outer_owned, do: Process.put(@owned_key, outer_owned), else: Process.delete(@owned_key)

    {result, drain(ref, MapSet.new([test_pid | extra_pids]), [])}
  end

  @doc """
  Declares `pid` part of the measurement under way — call it from inside a
  `capture/1` block, in the calling test process, as soon as the block knows
  the pid (typically right after `live/2` returns its view).

  Outside a `capture/1` block this is a no-op, so a helper that names a pid
  unconditionally stays safe.
  """
  @spec own(pid()) :: :ok
  def own(pid) when is_pid(pid) do
    case Process.get(@owned_key) do
      nil -> :ok
      owned -> Process.put(@owned_key, [pid | owned])
    end

    :ok
  end

  @doc "`{fun_result, count}` — every statement owned by the measurement."
  @spec count((-> result)) :: {result, non_neg_integer()} when result: term()
  def count(fun) do
    {result, events} = capture(fun)
    {result, length(events)}
  end

  @doc "`{fun_result, count}` — owned statements against ONE Ecto source (table)."
  @spec count_source((-> result), String.t()) :: {result, non_neg_integer()} when result: term()
  def count_source(fun, source) when is_binary(source) do
    {result, events} = capture(fun)
    {result, Enum.count(events, &(&1.source == source))}
  end

  @doc """
  `{fun_result, {count, per_source}}` — the full census, `per_source` keyed by
  Ecto source with `"(no source)"` for statements Ecto did not attribute.
  """
  @spec census((-> result)) :: {result, {non_neg_integer(), %{String.t() => pos_integer()}}}
        when result: term()
  def census(fun) do
    {result, events} = capture(fun)

    per_source =
      Enum.reduce(events, %{}, fn e, acc ->
        Map.update(acc, e.source || "(no source)", 1, &(&1 + 1))
      end)

    {result, {length(events), per_source}}
  end

  @doc "`{fun_result, sqls}` — the SQL text of every owned statement, in issue order."
  @spec sql((-> result)) :: {result, [String.t()]} when result: term()
  def sql(fun) do
    {result, events} = capture(fun)
    {result, Enum.map(events, &to_string(&1.query || ""))}
  end

  # The chain a spawned worker records about who started it. `$callers` is set
  # by `Task`/`Task.Supervisor`, `$ancestors` by `proc_lib` (GenServer et al).
  # A process started by the application supervisor at boot — every background
  # sweeper — carries neither the test pid nor the LiveView pid here.
  defp process_lineage do
    case Process.info(self(), :dictionary) do
      {:dictionary, dict} ->
        Keyword.get(dict, :"$callers", []) ++ Keyword.get(dict, :"$ancestors", [])

      _ ->
        []
    end
  end

  defp drain(ref, owners, acc) do
    receive do
      {^ref, :query, source, query, pid, lineage} ->
        if MapSet.member?(owners, pid) or Enum.any?(lineage, &MapSet.member?(owners, &1)) do
          drain(ref, owners, [%{source: source, query: query, pid: pid} | acc])
        else
          drain(ref, owners, acc)
        end
    after
      0 -> Enum.reverse(acc)
    end
  end
end
