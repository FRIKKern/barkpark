defmodule Barkpark.Plugins.Sheets.Session.ReplayRingSingleWriterTest do
  @moduledoc """
  The exactly-once guarantee's LOAD-BEARING INVARIANT, asserted instead of
  assumed.

  `ReplayRing.put/3` is a read-modify-write on a PUBLIC ETS table
  (`safe_lookup` -> reject/prepend/take -> unconditional `safe_insert`).
  Nothing in ETS makes that atomic. It is correct today only because the sole
  caller is `Session.handle_call({:apply_ops, ...})` and
  `Barkpark.Plugins.Sheets.SessionRegistry` is `keys: :unique`, so at most one
  live process exists per `{dataset, workspace_id, published_id}` — the same
  tuple as the ring key. The GenServer mailbox, not ETS, is the serializer.

  That safety is a REGISTRY property, invisible at the defect site, and until
  this file nothing in the tree tested or commented it. A refactor that moved
  the `put/3` call into a `Task`, or added any second writer to
  `:sheets_ops_replay`, would break exactly-once with a fully green suite:
  `session_idempotency_test.exs` has five tests and not one of them is
  concurrent. The originating task (`sp-ops-idempotency`, PR #1096) closed on
  three criteria and NONE cites the concurrency fence — the uniqueness claim
  entered the codebase unverified.

  Four independent detectors, because each one catches a different way to
  remove the fence:

    1. RUNTIME (`:erlang.trace`) — the pid that actually executes `put/3` IS
       the pid `Registry.lookup/2` returns for the ring key, and the ETS row
       lands under exactly that tuple. Catches "moved into a Task/spawn".
       Paired with a non-vacuity test that proves the instrument can SEE an
       off-session writer, so a green here is never a silent "nothing traced".
    2. STRUCTURAL (AST walk of `lib/`) — exactly ONE `ReplayRing.put/3` call
       site exists in the whole application, it is inside Session's
       `{:apply_ops, ...}` `handle_call` clause, and it is not nested in a
       spawn-like construct. Catches a SECOND writer added on a path this
       suite never exercises — which the runtime detector cannot see.
    3. TABLE OWNERSHIP — `:sheets_ops_replay` and `:ets.insert` into it are
       named in exactly one module. Catches a second writer that bypasses the
       `ReplayRing` API entirely and pokes the public table directly.
    4. REGISTRY FENCE, VERSION-SCOPED — the real `SessionRegistry` refuses a
       second registrant for a live key, and `Registry` LINKS a registrant to
       its partition so a partition crash KILLS its registrants (the
       "alive but unregistered" state that would admit a second writer cannot
       occur). That last one is a Registry IMPLEMENTATION property, not a
       documented guarantee, so it is re-derived on every run under whatever
       toolchain runs it rather than trusted from a comment.

  ## The measured lost-update shape (do not re-run it blind)

  32 barrier-released writers on ONE key over 200 rounds lost entries in
  200/200 rounds — 2249 entries lost in total, up to 13 in a single round.
  16 writers over the same harness returned a CLEAN GREEN. The harness only
  sees the race above a threshold, so a quiet 16-writer run is not evidence of
  safety; it is evidence the harness was too small. A lost `put` is not
  cosmetic: the next retry of that `request_id` reads `:miss` and re-applies a
  non-idempotent `insert_rows` — the double-apply the ring exists to stop.

  REPLICATED 2026-09-02 on a 10-core Apple Silicon box, Elixir 1.19.5 / OTP 28,
  running the harness below: **32 writers -> 173/200 rounds lossy, 2123 lost,
  worst round 22**. The lost-update behaviour reproduces. The "16 writers is
  clean" LEG DOES NOT — 16 writers lost on **74/200 rounds (290 entries, worst
  round 8)** here. The threshold is therefore a property of the MACHINE AND ITS
  LOAD, not of the writer count, which sharpens the original warning rather than
  softening it: a quiet run at ANY writer count says something about that box at
  that moment and nothing about correctness. Only the fence says anything about
  correctness.

  The harness itself is kept at the bottom of this file behind a compile gate,
  so the measurement is reproducible instead of folklore:

      SHEETS_REPLAY_RING_RACE=1 mix test test/barkpark/plugins/sheets/replay_ring_single_writer_test.exs

  It NEVER runs in CI. It is a documented measurement, not a gate, and a
  load-sensitive one — the same 32 writers on a busier or quieter box change
  the count.

  `async: false` — sessions are globally registered processes and the ring is
  a global ETS table.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Plugins.Sheets.Session.ReplayRing

  @registry Barkpark.Plugins.Sheets.SessionRegistry
  @table :sheets_ops_replay
  @dataset "sheets_single_writer_test"

  # Call names whose ARGUMENT is a body that runs somewhere else. A `put/3`
  # found underneath any of these is off the session pid by construction, which
  # is precisely the refactor this file exists to red.
  @spawn_like [
    :spawn,
    :spawn_link,
    :spawn_monitor,
    :spawn_opt,
    :async,
    :async_nolink,
    :async_stream,
    :async_stream_nolink,
    :start,
    :start_link,
    :start_child
  ]

  setup do
    stop_all_sessions()
    on_exit(&stop_all_sessions/0)

    if :ets.whereis(@table) == :undefined, do: start_supervised!(ReplayRing)
    :ok
  end

  # ── (1) RUNTIME: the writer IS the registered session pid ─────────────────

  describe "the writer identity" do
    test "put/3 executes IN the pid the SessionRegistry holds for the ring key" do
      create_sheet("sw-trace")

      # Start the session WITHOUT a request_id first: no ring write happens on
      # this call, so the trace below can only see the one we are asking about,
      # and we hold the registered pid before arming anything.
      {:ok, _} = Session.apply_ops("sw-trace", @dataset, [set_cell("A1", "1")])
      session_pid = Session.whereis("sw-trace", @dataset)
      assert is_pid(session_pid)

      arm_trace!()

      rid = "sw-trace-req"
      {:ok, _} = Session.apply_ops("sw-trace", @dataset, [set_cell("A1", "2")], rid)

      writer = await_put_writer(rid)

      assert writer == session_pid, """
      ReplayRing.put/3 ran in #{inspect(writer)}, but the SessionRegistry holds
      #{inspect(session_pid)} for this key.

      put/3 is a lookup-then-insert on a PUBLIC ETS table. It is atomic only
      while the registered session process is the one executing it — the
      unique SessionRegistry is the serializer, not ETS. If this call has moved
      into a Task, a spawn, or any other process, exactly-once is gone: two
      writers on one key lose entries (measured: 32 writers x 200 rounds lost
      in 200/200 rounds, 2249 entries), and a lost entry makes the next retry
      of that request_id re-apply a non-idempotent insert_rows.
      """

      # The fence only holds if the RING key and the REGISTRY key are the same
      # tuple. Read both back rather than trusting that they are.
      key = ring_key("sw-trace")
      assert [{^session_pid, _}] = Registry.lookup(@registry, key)

      # `assert pattern = expr, msg` would run the match FIRST and raise
      # MatchError before the message ever printed — match?/2 keeps it alive.
      assert match?([{^key, [{^rid, _reply, _ts} | _]}], :ets.lookup(@table, key)),
             "the ring row did not land under the registry key — the two keys have drifted"
    end

    # WITHOUT THIS the test above can go green by seeing NOTHING: a trace that
    # never fires and an assertion that never runs look identical from the
    # outside. This proves the instrument distinguishes an off-session writer,
    # so `await_put_writer/1` returning the session pid is a real measurement.
    test "the trace instrument SEES an off-session writer (non-vacuity)" do
      arm_trace!()

      rid = "sw-offsession-req"
      key = {@dataset, nil, "sw-no-such-session"}

      {:ok, task_pid} = Task.start(fn -> ReplayRing.put(key, rid, %{"ok" => true}) end)

      writer = await_put_writer(rid)

      assert writer == task_pid
      refute writer == self()

      # And no session was ever registered for that key: the write really did
      # happen outside the fence.
      assert Registry.lookup(@registry, key) == []

      :ets.delete(@table, key)
    end
  end

  # ── (2) STRUCTURAL: exactly one call site, in the right clause ────────────

  describe "the call sites" do
    test "ReplayRing.put/3 has exactly ONE call site in lib/, un-spawned" do
      sites = put_call_sites()

      assert length(sites) == 1,
             """
             Expected exactly one ReplayRing.put/3 call site in lib/, found #{length(sites)}:
             #{inspect(sites, pretty: true)}

             A second writer to the replay ring defeats the single-writer fence
             even if every existing test stays green — the two writers race only
             on the same key, under load, which no test in this suite creates.
             """

      [{path, ctx, _line}] = sites

      assert path == "lib/barkpark/plugins/sheets/session.ex"

      assert ctx == nil,
             "ReplayRing.put/3 is nested inside a #{inspect(ctx)} block — it no longer " <>
               "runs on the registered session pid, so the lookup-then-insert is unfenced."
    end

    test "the one call site is inside Session's {:apply_ops, ...} handle_call clause" do
      ast = parse!("lib/barkpark/plugins/sheets/session.ex")

      in_clause = apply_ops_clauses(ast) |> Enum.flat_map(&collect_put_sites(&1, nil))
      in_file = collect_put_sites(ast, nil)

      assert length(in_clause) == 1,
             "expected the single put/3 call inside handle_call({:apply_ops, ...}), " <>
               "found #{length(in_clause)}"

      assert length(in_file) == length(in_clause),
             "session.ex calls ReplayRing.put/3 from somewhere OTHER than the " <>
               "{:apply_ops, ...} handle_call clause — that path is not serialized by " <>
               "the session mailbox"
    end
  end

  # ── (3) TABLE OWNERSHIP: nobody else touches the public table ─────────────

  describe "the table" do
    test ":sheets_ops_replay is named in CODE by exactly one module in lib/" do
      # AST, not grep: `Code.string_to_quoted/1` drops `#` comments, so the
      # prose in session.ex that EXPLAINS the fence does not register as a
      # second writer. Only the atom appearing as a real term does.
      owners = Enum.filter(lib_files(), &names_table?(parse!(&1)))

      assert owners == ["lib/barkpark/plugins/sheets/session/replay_ring.ex"],
             """
             The replay table is `:public`, so ANY module that names it can write it
             and the SessionRegistry fence does not apply to that writer at all.
             Modules naming it: #{inspect(owners)}
             """
    end

    test "the table is public — which is exactly why the fence has to be asserted" do
      # Not a wish: this records WHY the invariant is load-bearing. A protected
      # table would make a second writer impossible; a public one makes it a
      # one-line refactor away, and only the fence stops it.
      assert :ets.info(@table, :protection) == :public
    end
  end

  # ── (4) THE REGISTRY FENCE, version-scoped ────────────────────────────────

  describe "the SessionRegistry fence" do
    test "a second registrant for a LIVE key is refused, pointing at the same pid" do
      create_sheet("sw-unique")
      {:ok, _} = Session.apply_ops("sw-unique", @dataset, [set_cell("A1", "1")])

      session_pid = Session.whereis("sw-unique", @dataset)
      assert is_pid(session_pid)

      key = ring_key("sw-unique")
      parent = self()

      spawn(fn ->
        send(parent, {:second, Registry.register(@registry, key, nil)})
        receive do: (:never -> :ok)
      end)

      assert_receive {:second, {:error, {:already_registered, ^session_pid}}}, 2_000
    end

    # THE VERSION-SCOPED LEG. The "registry restarts empty while old sessions
    # live on unregistered" overlap — the one state that would admit a second
    # writer for one key — is refuted by MECHANISM: Registry LINKS every
    # registrant to its partition process, so a partition crash kills its
    # registrants. That is a Registry IMPLEMENTATION property, not a documented
    # guarantee. It is verified HERE, on every run, under whatever toolchain
    # runs it, instead of asserted once in a comment:
    #
    #   * verified on Elixir 1.19.5 / OTP 28 (the dev box this was authored on);
    #   * and on the repo's declared toolchain — root `.tool-versions` says
    #     `erlang 27.3.4` / `elixir 1.18.4-otp-27`, and `.github/workflows/
    #     elixir.yml`'s test matrix pins `otp: 27.0` / `elixir: 1.18.1`.
    #
    # If a future version stops linking, THIS test goes red and the verdict on
    # the ring's safety flips with it. That is the whole point of writing it as
    # a test rather than a paragraph.
    #
    # It probes a THROWAWAY registry started with the same `keys: :unique`
    # options, never the live `SessionRegistry`: the property under test belongs
    # to Registry, and killing a real partition would take live sessions (and
    # any concurrent test's) down with it.
    test "Registry LINKS a registrant to its partition, so it cannot outlive it" do
      name = :"replay_ring_link_probe_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: name})

      parent = self()

      registrant =
        spawn(fn ->
          # `spawn`, not `spawn_link`: the ONLY link this process can have
          # afterwards is the one Registry itself creates.
          {:ok, _} = Registry.register(name, {"d", nil, "p"}, nil)
          send(parent, :registered)
          receive do: (:never -> :ok)
        end)

      assert_receive :registered, 2_000

      {:links, links} = Process.info(registrant, :links)

      assert match?([_partition], links),
             """
             Registry.register/3 did not link the registrant to its partition on
             Elixir #{System.version()} / OTP #{:erlang.system_info(:otp_release)}.

             The ReplayRing's single-writer fence rests on that link: without it a
             partition can die and restart EMPTY while the old session lives on
             unregistered, a second session starts for the same key, and two
             processes race the lookup-then-insert in put/3. Re-verify the fence
             before trusting exactly-once on this toolchain.

             Links found: #{inspect(links)}
             """

      [partition] = links

      ref = Process.monitor(registrant)
      Process.exit(partition, :kill)

      assert_receive {:DOWN, ^ref, :process, ^registrant, :killed}, 2_000
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp create_sheet(slug) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "content" => %{
            "locale" => "nb-NO",
            "tabs" => [%{"name" => "T0", "cells" => %{"A1" => %{"v" => "seed"}}}]
          }
        },
        @dataset
      )

    doc
  end

  defp set_cell(ref, raw), do: %{"op" => "set_cell", "tab" => 0, "ref" => ref, "raw" => raw}

  # The registry key an unscoped `apply_ops/4` resolves to: `key/3` normalizes a
  # nil workspace to the seeded Default workspace.
  defp ring_key(slug) do
    ws =
      case Barkpark.Tenancy.get_default_workspace() do
        %{id: id} when is_binary(id) -> id
        _ -> nil
      end

    {@dataset, ws, Content.published_id(slug)}
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ── the trace instrument ─────────────────────────────────────────────────

  defp arm_trace! do
    :erlang.trace_pattern({ReplayRing, :put, 3}, true, [:global])
    # `:all` covers processes that do not exist yet, which matters: a refactor
    # that moved the call into a freshly spawned Task must still be SEEN, or
    # this file would report "no writer" instead of "the wrong writer".
    :erlang.trace(:all, true, [:call])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({ReplayRing, :put, 3}, false, [:global])
    end)

    :ok
  end

  defp await_put_writer(rid, timeout \\ 5_000) do
    receive do
      {:trace, pid, :call, {ReplayRing, :put, [_key, ^rid, _reply]}} ->
        pid

      {:trace, _pid, :call, {ReplayRing, :put, _args}} ->
        # A concurrent, unrelated write. Keep waiting for OUR request_id.
        await_put_writer(rid, timeout)
    after
      timeout ->
        flunk("""
        No ReplayRing.put/3 call was traced for request_id #{inspect(rid)}.

        Either the ring write was REMOVED from the apply path — in which case a
        retried batch re-applies its ops and exactly-once is gone — or it now
        happens somewhere the global trace pattern cannot reach (a NIF, another
        node, a renamed function). Both are the failure this file guards.
        """)
    end
  end

  # ── the AST detectors ────────────────────────────────────────────────────

  defp lib_files do
    files = Path.wildcard("lib/**/*.ex")

    # Non-vacuity: a wrong cwd would make every scan below trivially pass.
    assert length(files) > 100,
           "expected to scan lib/ from api/, found #{length(files)} files in #{File.cwd!()}"

    files
  end

  defp names_table?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn node, acc -> {node, acc or node == @table} end)

    found?
  end

  defp parse!(path) do
    {:ok, ast} = Code.string_to_quoted(File.read!(path), columns: true)
    ast
  end

  defp put_call_sites do
    for path <- lib_files(),
        {ctx, line} <- collect_put_sites(parse!(path), nil),
        do: {path, ctx, line}
  end

  # Every `handle_call` clause whose first argument is a `{:apply_ops, ...}`
  # tuple pattern.
  defp apply_ops_clauses(ast) do
    {_, clauses} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:handle_call, _, [{:{}, _, [:apply_ops | _]} | _]}, _body]} = node, acc ->
          {node, [node | acc]}

        node, acc ->
          {node, acc}
      end)

    assert clauses != [], "no handle_call({:apply_ops, ...}) clause found in session.ex"
    clauses
  end

  # Walks the AST carrying the nearest enclosing spawn-like call name, so a
  # `put/3` that was moved into a Task is reported as `{:async, line}` rather
  # than being counted as a legitimate call site.
  defp collect_put_sites(ast, ctx), do: ast |> do_collect(ctx, []) |> Enum.reverse()

  defp do_collect({_, meta, args} = node, ctx, acc) when is_list(args) do
    acc = if put_call?(node), do: [{ctx, meta[:line]} | acc], else: acc
    inner = if name = spawn_like(node), do: name, else: ctx
    Enum.reduce(args, acc, &do_collect(&1, inner, &2))
  end

  defp do_collect({a, b}, ctx, acc), do: do_collect(b, ctx, do_collect(a, ctx, acc))

  defp do_collect(list, ctx, acc) when is_list(list),
    do: Enum.reduce(list, acc, &do_collect(&1, ctx, &2))

  defp do_collect(_leaf, _ctx, acc), do: acc

  # Matches both the aliased `ReplayRing.put/3` and the fully-qualified
  # `Barkpark.Plugins.Sheets.Session.ReplayRing.put/3` — the last alias segment
  # is what identifies the module either way.
  defp put_call?({{:., _, [{:__aliases__, _, segs}, :put]}, _, args})
       when is_list(segs) and is_list(args) do
    List.last(segs) == :ReplayRing and length(args) == 3
  end

  defp put_call?(_), do: false

  defp spawn_like({{:., _, [_mod, name]}, _, _args}) when is_atom(name) do
    if name in @spawn_like, do: name
  end

  defp spawn_like({name, _, args}) when is_atom(name) and is_list(args) do
    if name in @spawn_like, do: name
  end

  defp spawn_like(_), do: nil
end

# ── THE MEASUREMENT, not a gate ────────────────────────────────────────────
#
# The harness that produced the numbers quoted in the moduledoc and in the
# `put/3` fence comment. Compile-gated rather than tag-excluded so it costs
# the default lane nothing at all — not even a load:
#
#     SHEETS_REPLAY_RING_RACE=1 mix test \
#       test/barkpark/plugins/sheets/replay_ring_single_writer_test.exs
#
# It asserts NOTHING about a threshold — it PRINTS the shape. The count is a
# function of core count and machine load, so a pass/fail bar here would be a
# lying instrument. What it is for: letting the next reader reproduce the
# lost-update behaviour on their own box before they decide whether the fence
# still matters, instead of taking a comment's word for it.
if System.get_env("SHEETS_REPLAY_RING_RACE") == "1" do
  defmodule Barkpark.Plugins.Sheets.Session.ReplayRingRaceHarnessTest do
    use ExUnit.Case, async: false

    alias Barkpark.Plugins.Sheets.Session.ReplayRing

    @table :sheets_ops_replay
    @rounds 200

    setup do
      if :ets.whereis(@table) == :undefined, do: start_supervised!(ReplayRing)
      :ets.delete_all_objects(@table)
      on_exit(fn -> :ets.delete_all_objects(@table) end)
      :ok
    end

    test "32 barrier-released writers on ONE key lose entries" do
      report(race(32))
    end

    # Named for what the original measurement saw. On the replication box it was
    # NOT clean (74/200 rounds lossy) — kept as the control precisely because the
    # two runs disagree: the writer count is not the threshold, the box is.
    test "16 writers — the original's clean control, which did not replicate" do
      report(race(16))
    end

    # One round: N processes released by a single barrier message all call
    # put/3 on the SAME key. Every write carries a distinct request_id, so a
    # correct ring ends the round holding N entries; anything fewer is a
    # lost update — one writer's read-modify-write clobbered another's.
    defp race(writers) do
      lost =
        for round <- 1..@rounds do
          key = {"race", nil, "sheet-#{round}"}
          parent = self()

          pids =
            for w <- 1..writers do
              spawn(fn ->
                send(parent, {:ready, self()})
                receive do: (:go -> :ok)
                ReplayRing.put(key, "r#{round}-w#{w}", %{"ok" => true})
                send(parent, {:done, self()})
              end)
            end

          for _ <- pids, do: assert_receive({:ready, _}, 5_000)
          for p <- pids, do: send(p, :go)
          for _ <- pids, do: assert_receive({:done, _}, 5_000)

          [{^key, list}] = :ets.lookup(@table, key)
          writers - length(list)
        end

      %{
        writers: writers,
        rounds: @rounds,
        lossy_rounds: Enum.count(lost, &(&1 > 0)),
        total_lost: Enum.sum(lost),
        worst_round: Enum.max(lost)
      }
    end

    defp report(m) do
      IO.puts("""

      ReplayRing lost-update measurement
        writers per round : #{m.writers}
        rounds            : #{m.rounds}
        rounds that lost  : #{m.lossy_rounds}/#{m.rounds}
        entries lost      : #{m.total_lost}
        worst single round: #{m.worst_round}

      Recorded shapes to compare against:
        original  32 writers -> 200/200 rounds lossy, 2249 lost, worst round 13
        original  16 writers -> clean green
        replicated 32 writers -> 173/200 lossy, 2123 lost, worst round 22
        replicated 16 writers -> 74/200 lossy,  290 lost, worst round 8

      The counts move with the box and its load; only the DIRECTION is stable.
      A clean run here is not a safety result — see the moduledoc.
      """)
    end
  end
end
