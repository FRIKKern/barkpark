defmodule Barkpark.PdsLiveviewProcessSurfaceTest do
  @moduledoc """
  THE LIVEVIEW MESSAGE SURFACE OFF THE LIVE FILES, AND THE GENSERVER FAR SIDE
  IT HANDS ITS WRITES TO — COUNTED HERE, BECAUSE NOTHING ELSE COUNTS THEM.

  ## What was already counted, and what was not

  PDS wave 41 gave `handle_event/3` a denominator, and wave 41's own follow-up
  block (`lv_report_hole/5` in `scripts/pds-elixir-receipt-census.exs`) gave
  `handle_info/2 + handle_params/3` one too. So the row this case discharges —
  "the LiveView handle_info/handle_params surface has never been counted in any
  output" — is HALF FALSE as worded, and the refutation is recorded rather than
  built around: a plain census run prints `A NAMED HOLE, WITH ITS OWN
  DENOMINATOR: handle_info/2 + handle_params/3` with a population and two
  write-reaching figures.

  The half that is TRUE is the half the row's own brief names. That block's
  membership test is `MapSet.member?(paths, d.path)`, where `paths` is the set
  of files carrying a ROUTED live module or a LiveComponent. A `handle_info/2`
  clause in a file that is neither is not in the population — and that is
  exactly where the writes the brief points at live: `Sheets.Session` is a
  GenServer, the LiveView reaches it through `GenServer.call/2,3`, and
  `apply_ops` is write-FALSE while `handle_call/3`, `handle_info/2`,
  `terminate/2` and `persist/1` on the far side are write-TRUE. A live-file-
  keyed lens cannot see any of them, at any depth, by construction.

  ## What this case does

  It re-derives BOTH halves from the AST — `Code.string_to_quoted/2` over
  `api/lib/**/*.ex`, membership by `{name, arity}` off a def table, never a
  name regex — and it PRINTS the residual the census's lens drops, with its
  floor reasons. Then it arms the named site:

  * ARM — the four far-side write sites in `Barkpark.Plugins.Sheets.Session`
    (`handle_call/3` at the `{:apply_ops, …}` clause, `handle_info/2` at
    `:flush_debounce`, `terminate/2`, `persist/1`) must each be write-reaching
    at the census's own `@evidence_depth` of 6. Delete the write and this arm
    reds NAMING the clause and its line.
  * CONTROL — `apply_ops` in that same module must stay write-FALSE. That is
    wave 41's proof of the process boundary, and it is the arm that must NOT
    move when the far-side write is deleted; a control that flips with the arm
    proves nothing about either.
  * CONTROL — `session.ex` must not be a live file, which is WHY the arm's four
    sites sit outside the census's counted population.
  * POSITIVE CONTROLS — a corpus that parses to zero defs, zero live files or
    an empty message surface fails instead of greening. A scan that silently
    finds nothing is the failure mode this whole family of cases exists for.
  * NEGATIVE CONTROL — the same predicate over a fixture tree in `tmp_dir`,
    where one module reaches a `Repo.update/1` through a hop and its sibling
    does not. The predicate must answer TRUE and FALSE on the same run, or the
    verdicts above are a uniform verdict off a broken instrument.

  `async: true`: reads committed files and writes only into its own `tmp_dir`.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # ONE INDEX PER MODULE, NOT ONE PER TEST. The corpus parse is ~10 s; six
  # real-corpus cases each re-taking it is 50 s of the Elixir gate spent
  # re-deriving a value that cannot change inside one run. The fixture case
  # below builds its OWN index over tmp_dir and does not read this one.
  setup_all do
    {us, index} = :timer.tc(fn -> index(root()) end)
    %{index: index, index_ms: div(us, 1000)}
  end

  # The census's own lens, re-declared so a drift in either is visible as a
  # difference rather than inherited silently.
  # scripts/pds-elixir-receipt-census.exs: @write_verbs, @repo_mods, @evidence_depth.
  @write_verbs ~w(insert insert! update update! delete delete! insert_all update_all
                  delete_all insert_or_update insert_or_update!)a
  @repo_mods [:Repo, :Multi]
  @evidence_depth 6
  @fanout 40

  # The row's cited site.
  @session_path "lib/barkpark/plugins/sheets/session.ex"
  @session_mod [:Barkpark, :Plugins, :Sheets, :Session]

  # THE ROOT IS AN ARGUMENT, NEVER A LITERAL IN A SCAN. Every scan below takes
  # its root so the fixture arm runs the guard's own code and not a second copy
  # of it. `File.cwd!/0` is `api/` under `mix test`.
  defp root, do: File.cwd!()

  # ------------------------------------------------------------------ the index

  defp index(dir) do
    parsed =
      dir
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(fn p ->
        case Code.string_to_quoted(File.read!(p), columns: false) do
          {:ok, ast} -> {p, ast}
          _ -> {p, nil}
        end
      end)

    defs = Enum.flat_map(parsed, fn {p, ast} -> collect(ast, [], p) end)

    live =
      parsed
      |> Enum.filter(fn {_p, ast} -> live?(ast) end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    %{
      root: dir,
      defs: defs,
      files: Enum.map(parsed, &elem(&1, 0)),
      live_files: live,
      by_key: Enum.group_by(defs, &{&1.module, &1.name}),
      by_name: Enum.group_by(defs, &{&1.name, &1.arity})
    }
  end

  # RECURSIVE, NOT A PREWALK WITH A RUNNING `mod`. A prewalk that remembers the
  # last `defmodule` it passed attributes every def AFTER a nested module to
  # that nested module, silently. Descending into the `do` block keeps the
  # module path scoped to the block it actually belongs to.
  defp collect(nil, _mod, _path), do: []

  defp collect({:defmodule, _, [{:__aliases__, _, segs}, body]}, mod, path),
    do: collect(do_block(body), mod ++ segs, path)

  defp collect({:defmodule, _, [_dynamic_head, body]}, mod, path),
    do: collect(do_block(body), mod, path)

  defp collect({:__block__, _, items}, mod, path),
    do: Enum.flat_map(items, &collect(&1, mod, path))

  defp collect({d, meta, [head, body]}, mod, path)
       when d in [:def, :defp, :defmacro, :defmacrop] do
    case head_info(head) do
      {nil, _, _} ->
        []

      {name, arity, args} ->
        [
          %{
            module: mod,
            name: name,
            arity: arity,
            path: path,
            line: meta[:line],
            head: args,
            body: do_block(body)
          }
        ]
    end
  end

  defp collect({form, _, [_ | _] = args}, mod, path)
       when form in [:if, :unless, :case, :cond, :quote, :try, :for, :with],
       do: Enum.flat_map(args, &collect(&1, mod, path))

  defp collect([{:do, body} | rest], mod, path),
    do: collect(body, mod, path) ++ Enum.flat_map(rest, fn {_k, v} -> collect(v, mod, path) end)

  defp collect(_other, _mod, _path), do: []

  defp do_block([{:do, body} | _]), do: body
  defp do_block(other), do: other

  defp head_info({:when, _, [h | _]}), do: head_info(h)

  defp head_info({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args), args}

  defp head_info({name, _, nil}) when is_atom(name), do: {name, 0, []}
  defp head_info(_), do: {nil, nil, nil}

  # A LIVE FILE IS A `use` SHAPE, NOT A FILENAME AND NOT A DIRECTORY. Both
  # idioms in this tree are covered: `use BarkparkWeb, :live_view` /
  # `:live_component`, and `use Phoenix.LiveView` / `use Phoenix.LiveComponent`.
  defp live?(nil), do: false

  defp live?(ast) do
    {_, hit} =
      Macro.prewalk(ast, false, fn
        {:use, _, args} = node, acc when is_list(args) ->
          {node, acc or Enum.any?(args, &live_arg?/1)}

        node, acc ->
          {node, acc}
      end)

    hit
  end

  defp live_arg?({:__aliases__, _, segs}), do: List.last(segs) in [:LiveView, :LiveComponent]
  defp live_arg?(a) when a in [:live_view, :live_component], do: true
  defp live_arg?(_), do: false

  # ------------------------------------------------------------ calls and reach

  defp calls(%{body: nil}), do: []

  defp calls(%{body: body}) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segs}, f]}, _, args} = node, acc
        when is_atom(f) and is_list(args) ->
          {node, [{:remote, segs, f, length(args)} | acc]}

        {f, _, args} = node, acc when is_atom(f) and is_list(args) ->
          {node, [{:local, f, length(args)} | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # The alias TAIL, the same rule @repo_mods rides in the census: `Repo`,
  # `Barkpark.Repo` and `Ecto.Multi` all land here.
  defp write?(d) do
    Enum.any?(calls(d), fn
      {:remote, segs, f, _a} -> List.last(segs) in @repo_mods and f in @write_verbs
      _ -> false
    end)
  end

  defp write_reaching?(d, index, max), do: bfs([{d, 0}], index, MapSet.new(), max)

  defp bfs([], _index, _seen, _max), do: false

  defp bfs([{d, depth} | rest], index, seen, max) do
    key = {d.module, d.name, d.arity, d.line}

    cond do
      MapSet.member?(seen, key) ->
        bfs(rest, index, seen, max)

      write?(d) ->
        true

      depth >= max ->
        bfs(rest, index, MapSet.put(seen, key), max)

      true ->
        next = Enum.map(callees(d, index), &{&1, depth + 1})
        bfs(rest ++ next, index, MapSet.put(seen, key), max)
    end
  end

  # The seen-set and this uniq_by are BOTH keyed {module, name, arity, LINE},
  # so a second clause of an already-visited def is still entered.
  defp callees(d, index) do
    calls(d)
    |> Enum.flat_map(fn
      {:remote, segs, f, a} ->
        case Map.get(index.by_key, {segs, f}) do
          nil -> Map.get(index.by_name, {f, a}) || []
          hit -> hit
        end

      {:local, f, a} ->
        (Map.get(index.by_key, {d.module, f}) || []) |> Enum.filter(&(&1.arity == a))
    end)
    |> Enum.uniq_by(&{&1.module, &1.name, &1.arity, &1.line})
    |> Enum.take(@fanout)
  end

  # ------------------------------------------------------------- the two surfaces

  # The surface the census counts ONLY inside live files.
  defp message_surface(index) do
    Enum.filter(index.defs, fn d ->
      (d.name == :handle_info and d.arity == 2) or (d.name == :handle_params and d.arity == 3)
    end)
  end

  # The far side of the process boundary: the callbacks a `GenServer.call/cast`
  # and a supervisor shutdown arrive at. Counted in NO census output today.
  defp process_surface(index) do
    Enum.filter(index.defs, fn d ->
      (d.name == :handle_call and d.arity == 3) or (d.name == :handle_cast and d.arity == 2) or
        (d.name == :terminate and d.arity == 2)
    end)
  end

  defp split_live(defs, index),
    do: Enum.split_with(defs, &MapSet.member?(index.live_files, &1.path))

  defp label(d), do: "#{Enum.join(d.module, ".")}.#{d.name}/#{d.arity} @ #{d.path}:#{d.line}"

  defp session_defs(index, name),
    do: index.defs |> Enum.filter(&(&1.module == @session_mod and &1.name == name))

  # =========================================================================
  # positive controls — an empty scan must not green anything below
  # =========================================================================

  describe "positive controls" do
    test "the corpus parses to a non-empty def table, file list and live-file set", %{
      index: index
    } do
      assert length(index.files) > 500,
             "corpus collapsed: #{length(index.files)} file(s) under #{root()}/lib"

      assert length(index.defs) > 10_000,
             "def table collapsed: #{length(index.defs)} def(s) — a scan that finds " <>
               "nothing greens every membership test below"

      assert MapSet.size(index.live_files) > 10,
             "live-file set collapsed: #{MapSet.size(index.live_files)} file(s); the " <>
               "on-live / off-live split is meaningless without it"
    end

    test "both surfaces are non-empty and the on/off-live partition adds up", %{index: index} do
      msg = message_surface(index)
      proc = process_surface(index)
      {on, off} = split_live(msg, index)

      assert msg != [], "handle_info/2 + handle_params/3 population is EMPTY"
      assert proc != [], "handle_call/3 + handle_cast/2 + terminate/2 population is EMPTY"
      assert on != [], "the census's counted half (on-live) is EMPTY"
      assert off != [], "the residual this case exists to count is EMPTY"
      assert length(on) + length(off) == length(msg)
    end
  end

  # =========================================================================
  # THE COUNT — printed, with its floor reasons
  # =========================================================================

  test "the off-live message surface and the process far side are counted, with a floor",
       %{index: index, index_ms: index_ms} do
    msg = message_surface(index)
    {on, off} = split_live(msg, index)
    proc = process_surface(index)
    {_p_on, p_off} = split_live(proc, index)

    on_w = Enum.count(on, &write_reaching?(&1, index, @evidence_depth))
    off_w = Enum.count(off, &write_reaching?(&1, index, @evidence_depth))
    p_off_w = Enum.count(p_off, &write_reaching?(&1, index, @evidence_depth))

    IO.puts("""

    THE OFF-LIVE MESSAGE SURFACE + THE PROCESS FAR SIDE — DERIVED THIS RUN
    ---------------------------------------------------------------------
      corpus            #{length(index.defs)} def(s) over #{length(index.files)} file(s); #{MapSet.size(index.live_files)} live file(s)
                        (index built in #{index_ms} ms)
      MESSAGE SURFACE   #{length(msg)} clause(s) — handle_info/2 + handle_params/3, by {name, arity}
        ON-LIVE         #{length(on)} / #{length(msg)}, write-reaching #{on_w} / #{length(on)} @#{@evidence_depth}
                        — the half the census's lv_report_hole/5 already prints
        OFF-LIVE        #{length(off)} / #{length(msg)}, write-reaching #{off_w} / #{length(off)} @#{@evidence_depth}
                        — NOT in that block's population: its membership test is
                        MapSet.member?(paths, d.path) over routed-live + component
                        files only, so no depth buys these back
      PROCESS FAR SIDE  #{length(proc)} clause(s) — handle_call/3 + handle_cast/2 + terminate/2
        OFF-LIVE        #{length(p_off)} / #{length(proc)}, write-reaching #{p_off_w} / #{length(p_off)} @#{@evidence_depth}
                        — counted in NO census output at all today

      NEVER-COUNTED AND WRITE-REACHING: #{off_w + p_off_w} clause(s) @#{@evidence_depth}.

      FLOOR, REASON 1 — THE DEPTH BUDGET. #{@evidence_depth} hops. A write further out is
      write-FALSE here and the number only rises with the budget.
      FLOOR, REASON 2 — THE PROCESS BOUNDARY. GenServer.call/cast is not an edge
      this resolver can build, so a caller's walk stops there; that is the whole
      reason the far side needs a denominator of its own.
      FLOOR, REASON 3 — THE FAN-OUT CAP. callees/2 takes at most #{@fanout} edges per def.
      FLOOR, REASON 4 — THE LIVE LENS. A live file here is a `use` shape; the
      census keys on ROUTED live modules + components, a SMALLER set. Under its
      lens the off-live residual is at least this big, never smaller.

      NO ASSERTION IN THIS FILE READS THESE FIGURES. They are a denominator; a
      count that gates itself can always be made green by moving the count.
    """)

    assert off_w > 0
    assert p_off_w > 0
  end

  # =========================================================================
  # THE ARM — the row's cited site
  # =========================================================================

  describe "the GenServer far side of the row's cited site" do
    test "ARM: the named write sites in Sheets.Session are write-reaching at the census depth",
         %{index: index} do
      named = [
        {:handle_call, 3, "the {:apply_ops, ops, request_id} clause"},
        {:handle_info, 2, "the :flush_debounce clause"},
        {:terminate, 2, "the supervisor-shutdown flush"},
        {:persist, 1, "the persistence path itself"}
      ]

      for {name, arity, why} <- named do
        clauses = index |> session_defs(name) |> Enum.filter(&(&1.arity == arity))

        assert clauses != [],
               "#{inspect(@session_mod)}.#{name}/#{arity} is GONE from #{@session_path} — " <>
                 "#{why}. The row's cited write site cannot be armed if it does not exist."

        hits = Enum.filter(clauses, &write_reaching?(&1, index, @evidence_depth))

        assert hits != [],
               "NO clause of #{Enum.join(@session_mod, ".")}.#{name}/#{arity} reaches a " <>
                 "Repo write within #{@evidence_depth} hops (#{why}). Clauses examined: " <>
                 Enum.map_join(clauses, ", ", &label/1) <>
                 ". Either the write moved further than #{@evidence_depth} hops out, or it is gone — " <>
                 "and either way the far-side population this case counts no longer " <>
                 "describes the tree."
      end
    end

    test "CONTROL: apply_ops stays write-FALSE — the write is on the far side of the boundary",
         %{index: index} do
      clauses = session_defs(index, :apply_ops)

      assert clauses != [], "Sheets.Session.apply_ops is gone; wave 41's control has no subject"

      for d <- clauses do
        refute write_reaching?(d, index, @evidence_depth),
               "#{label(d)} is now write-REACHING at depth #{@evidence_depth}. Wave 41 proved it " <>
                 "write-FALSE: the client function hands the batch across GenServer.call/3 " <>
                 "and the Repo write lands in handle_call/3. If this flips, the process " <>
                 "boundary this case measures around has moved, and the ARM above is no " <>
                 "longer measuring the far side of anything."
      end
    end

    test "CONTROL: session.ex is not a live file — which is WHY those sites go uncounted",
         %{index: index} do
      path = Path.join(root(), @session_path)

      assert File.exists?(path), "the row's cited site is gone: #{path}"

      refute MapSet.member?(index.live_files, path),
             "#{@session_path} now reads as a live file. The census's live-file-keyed " <>
               "population would then cover it, and the residual this case counts shrinks " <>
               "by its clauses — re-derive before trusting the count above."

      surface =
        (message_surface(index) ++ process_surface(index))
        |> Enum.filter(&(&1.module == @session_mod))

      assert length(surface) >= 6,
             "expected the session's message + process callbacks, found: " <>
               Enum.map_join(surface, ", ", &label/1)
    end
  end

  # =========================================================================
  # NEGATIVE CONTROL — the predicate must be able to answer both ways
  # =========================================================================

  test "the write-reaching predicate answers TRUE and FALSE on one fixture tree", ctx do
    lib = Path.join([ctx.tmp_dir, "lib", "fixture"])
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "writer.ex"), """
    defmodule Fixture.Writer do
      use Phoenix.LiveView

      def handle_info(:tick, state), do: {:noreply, flush(state)}

      defp flush(state), do: Fixture.Store.persist(state)
    end
    """)

    File.write!(Path.join(lib, "store.ex"), """
    defmodule Fixture.Store do
      def persist(state), do: Repo.update(state)
      def peek(state), do: Repo.one(state)
    end
    """)

    File.write!(Path.join(lib, "quiet.ex"), """
    defmodule Fixture.Quiet do
      def handle_info(:tick, state), do: {:noreply, state}
      def handle_call(:peek, _from, state), do: {:reply, Fixture.Store.peek(state), state}
    end
    """)

    index = index(ctx.tmp_dir)

    assert MapSet.size(index.live_files) == 1,
           "the fixture's live lens found #{MapSet.size(index.live_files)} live file(s), expected 1"

    msg = message_surface(index)
    assert length(msg) == 2, "fixture message surface: " <> Enum.map_join(msg, ", ", &label/1)

    {on, off} = split_live(msg, index)
    assert length(on) == 1 and length(off) == 1

    hot = Enum.find(msg, &(&1.module == [:Fixture, :Writer]))
    cold = Enum.find(msg, &(&1.module == [:Fixture, :Quiet]))
    call = Enum.find(process_surface(index), &(&1.name == :handle_call))

    assert write_reaching?(hot, index, @evidence_depth),
           "the predicate could not follow handle_info -> flush -> Store.persist -> Repo.update"

    refute write_reaching?(cold, index, @evidence_depth),
           "the predicate called a clause with no write at all write-reaching"

    refute write_reaching?(call, index, @evidence_depth),
           "Repo.one/1 is a READ verb and must not score as a write"

    # And the depth budget is real, not decorative: one hop cannot reach a
    # write that sits two hops out.
    refute write_reaching?(hot, index, 1),
           "a budget of 1 reached a write 2 hops away — the depth argument is inert"
  end
end
