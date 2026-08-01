#!/usr/bin/env elixir
# pds-elixir-receipt-census.exs — the FIRST census of the Elixir success surface.
#
# THE LAW (PDS wave 22): no Barkpark verb may report success on an exit code alone.
# THE OWNING DOC:        docs/decisions/success-claim-census.md (canonical-for: success-claim-census)
#
# WHAT THIS IS. A build-free AST census of every `ok: true` / `"ok" => true` success
# claim under api/lib. It runs under plain `elixir` with NO mix project and NO compile
# (`Code.string_to_quoted/2` only), so it never boots the app — deliberately, because
# `mix phx.server` OOMs on this host. `scripts/pds-*` is in NEITHER Elixir path set
# (scripts/elixir-path-escape-check.sh), so this file costs no Elixir gate minute.
#
# WHAT THIS IS NOT. It is NOT a gate. It ships no floor over the population, because
# the ruling stands (PDS-D454): Elixir stays honest-and-unguarded until the write-routed
# sites are bucketed. What it DOES fail on is its own integrity — a truncated corpus, a
# lens that loses occurrences, a partition that does not add up, or a delegate chain it
# can no longer follow. Those exit non-zero. A number that merely drifted prints DRIFT.
#
# THE LENS, STATED (PDS-D448a). This census is AST-based and depends on NO regex engine
# and, specifically, on NO word-boundary support: on this host Apple git 2.39.5's POSIX
# ERE has no `\b`, so `git grep -E '\bok: true'` returns 0 matches and exits 1 SILENTLY
# while `git grep -P`, BSD `grep -rE` and `rg` all return 97 on the identical corpus.
# Every textual count below is plain substring matching (`:binary.matches/2`).
#
# MEASURING ENGINE (printed again at runtime from the live VM):
#   Elixir 1.19.5 · Erlang/OTP 28 (erts 16.3.1) · darwin arm64 · git 2.39.5 (Apple)
#
# USAGE
#   elixir scripts/pds-elixir-receipt-census.exs            # full corpus census
#   elixir scripts/pds-elixir-receipt-census.exs --sites    # + every emitted site, one per line
#   elixir scripts/pds-elixir-receipt-census.exs --files-from FILE   # corpus-refusal rehearsal
#
# EXIT: 0 all integrity checks pass · 1 an integrity check failed · 2 corpus refused.

defmodule PDS.Census do
  # ---------------------------------------------------------------- constants

  # Recorded by PDS-D448 (wave 33 survey). Printed as DRIFT lines, never enforced —
  # a number-shaped pin is the defect this epic keeps filing, not the guard.
  @recorded %{
    textual: 103,
    ast: 95,
    phantom: 8,
    consumer: 4,
    emitted: 91,
    write: 64,
    read: 17,
    unrouted: 10
  }

  # Route-bearing sentinels. A carriers-only corpus (the 27 files that literally hold an
  # `ok: true`) parses fine and reports write=0 with no error — PDS-D449a. These files
  # carry no `ok: true` themselves, so their absence PROVES the corpus is truncated.
  @sentinels [
    "api/lib/barkpark/tasks.ex",
    "api/lib/barkpark/tasks/close.ex",
    "api/lib/barkpark/repo.ex"
  ]
  @corpus_floor 600

  @write_verbs ~w(insert insert! update update! delete delete! insert_all update_all
                  delete_all insert_or_update insert_or_update! transaction)a
  @read_verbs ~w(all one one! get get! get_by get_by! aggregate exists? preload
                 stream reload reload!)a
  @repo_mods [:Repo, :Multi]
  @max_depth 3
  @sweep [1, 2, 3, 4, 5, 6]

  @shapes ~w(POST-READ CAS-CONFIRMED-ECHO PURE-ECHO UNREACHABLE-ERROR WRONG-ROW
             DISCARDED-POST-READ)

  # ---------------------------------------------------------------- entrypoint

  def main(argv) do
    t0 = System.monotonic_time(:millisecond)
    show_sites? = "--sites" in argv
    files = corpus(argv)

    banner()
    guard_corpus!(files)

    parsed = Enum.map(files, &parse_file/1)
    index = build_index(parsed)

    sites = Enum.flat_map(parsed, & &1.sites)
    textual = Enum.sum(Enum.map(parsed, & &1.textual_count))
    {ast_sites, phantoms} = split_phantoms(parsed, sites)
    {consumers, emitted} = Enum.split_with(ast_sites, & &1.pattern?)

    routed = Enum.map(emitted, &route(&1, index))
    classified = Enum.map(routed, &classify(&1, index))

    report_lens(textual, ast_sites, phantoms, consumers, emitted)
    report_split(classified)
    report_depth_sweep(emitted, index)
    report_shapes(classified)
    if show_sites?, do: report_each_site(classified)
    report_blind_spots(parsed)
    delegate = report_delegate_probe(index)

    ms = System.monotonic_time(:millisecond) - t0
    integrity(files, textual, ast_sites, phantoms, consumers, emitted, classified, delegate, ms)
  end

  defp corpus(argv) do
    case argv do
      ["--files-from", path | _] ->
        path |> File.read!() |> String.split("\n", trim: true)

      _ ->
        case Enum.find_index(argv, &(&1 == "--files-from")) do
          nil -> Path.wildcard("api/lib/**/*.ex") |> Enum.sort()
          i -> Enum.at(argv, i + 1) |> File.read!() |> String.split("\n", trim: true)
        end
    end
  end

  defp banner do
    {otp, erts} = {System.otp_release(), :erlang.system_info(:version)}

    p("PDS ELIXIR RECEIPT CENSUS — the api/lib success surface, first look")
    p(String.duplicate("=", 78))
    p("engine      Elixir #{System.version()} · Erlang/OTP #{otp} (erts #{erts}) · #{:erlang.system_info(:system_architecture)}")
    p("lens        AST (Code.string_to_quoted/2, literal_encoder) — no regex, NO \\b dependency")
    p("            PDS-D448a: git grep -E '\\bok: true' returns 0 and exits 1 SILENTLY on this host.")
    p("            Every textual count here is :binary.matches/2 substring matching.")
    p("law         no Barkpark verb may report success on an exit code alone (PDS wave 22)")
    p("gate        NONE. This prints a population; it does not police one (PDS-D454).")
    p("")
  end

  # ---------------------------------------------------------------- corpus guard

  defp guard_corpus!(files) do
    set = MapSet.new(files)
    missing = Enum.reject(@sentinels, &MapSet.member?(set, &1))

    cond do
      files == [] ->
        refuse(["corpus is EMPTY — nothing to census"])

      missing != [] or length(files) < @corpus_floor ->
        refuse(
          [
            "#{length(files)} file(s); the api/lib corpus is #{@corpus_floor}+ and MUST carry every route-bearing module"
          ] ++
            Enum.map(missing, &"MISSING route-bearing sentinel: #{&1}") ++
            [
              "A corpus holding only the files that CARRY `ok: true` parses cleanly and reports",
              "write=0 for every site, with no error and no warning (PDS-D449a). That green is a lie:",
              "the write verbs live in the callees, which such a corpus does not contain."
            ]
        )

      true ->
        p("corpus      #{length(files)} .ex files under api/lib · sentinels present: #{Enum.join(@sentinels, ", ")}")
        p("")
    end
  end

  defp refuse(lines) do
    p("")
    p("REFUSED: TRUNCATED CORPUS")
    Enum.each(lines, &p("  " <> &1))
    p("")
    p("The census does not report zeros it cannot stand behind. Exit 2.")
    System.halt(2)
  end

  # ---------------------------------------------------------------- parsing

  defp parse_file(path) do
    src = File.read!(path)
    lines = String.split(src, "\n")

    textual =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} ->
        List.duplicate({n, :atom}, count(line, "ok: true")) ++
          List.duplicate({n, :string}, count(line, "\"ok\" => true"))
      end)

    opts = [
      literal_encoder: &{:ok, {:__block__, &2, [&1]}},
      token_metadata: true,
      columns: true,
      emit_warnings: false,
      unescape: false
    ]

    ast =
      case Code.string_to_quoted(src, opts) do
        {:ok, ast} -> ast
        {:error, _} -> :parse_error
      end

    {defs, sites} =
      case ast do
        :parse_error -> {[], []}
        ast -> {collect_defs(ast, path), collect_sites(ast, path)}
      end

    %{
      path: path,
      src: src,
      textual: textual,
      textual_count: length(textual),
      parse_error?: ast == :parse_error,
      defs: attribute(defs, sites) |> elem(0),
      sites: attribute(defs, sites) |> elem(1)
    }
  end

  defp count(hay, needle), do: length(:binary.matches(hay, needle))

  # -- site collection (pairs, with pattern context) --------------------------

  defp collect_sites(ast, path) do
    {_, acc} = pairs(ast, false, [])

    acc
    |> Enum.map(fn {line, pat?, kind} ->
      %{path: path, line: line, pattern?: pat?, key: kind, def: nil}
    end)
    |> Enum.sort_by(& &1.line)
  end

  defp pairs(node, pat?, acc) do
    case node do
      {:=, _, [lhs, rhs]} ->
        acc = pairs(lhs, true, acc) |> elem(1)
        pairs(rhs, pat?, acc)

      {:<-, _, [lhs, rhs]} ->
        acc = pairs(lhs, true, acc) |> elem(1)
        pairs(rhs, pat?, acc)

      {:->, _, [heads, body]} ->
        acc = pairs(heads, true, acc) |> elem(1)
        pairs(body, false, acc)

      {op, _, [head, body]} when op in [:def, :defp, :defmacro, :defmacrop] ->
        acc = pairs(head, true, acc) |> elem(1)
        pairs(body, false, acc)

      {op, _, [head]} when op in [:def, :defp, :defmacro, :defmacrop] ->
        pairs(head, true, acc)

      {left, right} ->
        acc =
          case pair_site(left, right) do
            nil -> acc
            {line, kind} -> [{line, pat?, kind} | acc]
          end

        acc = pairs(left, pat?, acc) |> elem(1)
        pairs(right, pat?, acc)

      list when is_list(list) ->
        {node, Enum.reduce(list, acc, fn el, a -> pairs(el, pat?, a) |> elem(1) end)}

      {f, _, args} ->
        acc = pairs(f, pat?, acc) |> elem(1)
        {node, if(is_list(args), do: pairs(args, pat?, acc) |> elem(1), else: acc)}

      _ ->
        {node, acc}
    end
    |> case do
      {_, _} = ok -> ok
      acc when is_list(acc) -> {node, acc}
    end
  end

  defp pair_site(left, right) do
    with {:lit, key, meta} <- lit(left),
         {:lit, true, _} <- lit(right) do
      # A bare 2-tuple `{:ok, true}` and a keyword pair `ok: true` quote IDENTICALLY.
      # Only the key's metadata separates them: `format: :keyword` for `ok:`, `assoc:`
      # for `"ok" =>`. Without this, ~100 ordinary `{:ok, true}` tuples enter the census.
      case {key, meta[:format], meta[:assoc]} do
        {:ok, :keyword, _} -> {meta[:line], :atom}
        {"ok", _, [_ | _]} -> {meta[:line], :string}
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp lit({:__block__, meta, [v]}) when is_atom(v) or is_binary(v) or is_number(v),
    do: {:lit, v, meta}

  defp lit(_), do: :no

  # -- def collection ---------------------------------------------------------

  defp collect_defs(ast, path), do: defs(ast, [], path, [])

  defp defs(node, mod, path, acc) do
    case node do
      {:defmodule, _, [{:__aliases__, _, segs}, body]} ->
        defs(body, mod ++ segs, path, acc)

      {op, meta, [head | rest]} when op in [:def, :defp, :defmacro, :defmacrop] ->
        {name, arity, hmeta} = head_sig(head)
        body = List.first(rest)

        rec = %{
          module: mod,
          name: name,
          arity: arity,
          path: path,
          line: meta[:line] || hmeta[:line] || 0,
          last: max_line(node, meta[:line] || 0),
          delegate: nil,
          body: body,
          head: head
        }

        [rec | acc]

      {:defdelegate, meta, [head, opts]} ->
        {name, arity, _} = head_sig(head)
        target = kw(opts, :to)
        as = kw(opts, :as)

        rec = %{
          module: mod,
          name: name,
          arity: arity,
          path: path,
          line: meta[:line] || 0,
          last: meta[:line] || 0,
          delegate: {target, as || name},
          body: nil,
          head: head
        }

        [rec | acc]

      list when is_list(list) ->
        Enum.reduce(list, acc, &defs(&1, mod, path, &2))

      {a, b} ->
        acc |> then(&defs(a, mod, path, &1)) |> then(&defs(b, mod, path, &1))

      {_f, _, args} when is_list(args) ->
        Enum.reduce(args, acc, &defs(&1, mod, path, &2))

      _ ->
        acc
    end
  end

  defp head_sig({:when, _, [h | _]}), do: head_sig(h)
  defp head_sig({name, meta, args}) when is_atom(name) and is_list(args), do: {name, length(args), meta}
  defp head_sig({name, meta, _}) when is_atom(name), do: {name, 0, meta}
  defp head_sig(_), do: {:__unknown__, 0, []}

  defp kw(opts, key) do
    opts = if is_list(opts), do: opts, else: []

    Enum.find_value(opts, fn {k, v} ->
      case lit(k) do
        {:lit, ^key, _} -> alias_or_atom(v)
        _ -> nil
      end
    end)
  end

  defp alias_or_atom({:__aliases__, _, segs}), do: segs

  defp alias_or_atom(other) do
    case lit(other) do
      {:lit, v, _} when is_atom(v) -> v
      _ -> nil
    end
  end

  defp max_line(node, seed) do
    {_, m} =
      Macro.prewalk(node, seed, fn
        {_, meta, _} = n, acc when is_list(meta) ->
          l = Keyword.get(meta, :line, 0)
          e = get_in(meta, [:end, :line]) || get_in(meta, [:closing, :line]) || 0
          {n, Enum.max([acc, l, e])}

        n, acc ->
          {n, acc}
      end)

    m
  end

  # attribute each site to the innermost def containing its line
  defp attribute(defs, sites) do
    sites =
      Enum.map(sites, fn s ->
        owner =
          defs
          |> Enum.filter(&(&1.line <= s.line and s.line <= &1.last))
          |> Enum.sort_by(&(&1.last - &1.line))
          |> List.first()

        %{s | def: owner && {owner.module, owner.name, owner.arity}}
      end)

    {defs, sites}
  end

  # ---------------------------------------------------------------- index

  defp build_index(parsed) do
    all =
      parsed
      |> Enum.flat_map(& &1.defs)
      |> Enum.map(&Map.put(&1, :calls, raw_calls(&1)))

    by_key = Enum.group_by(all, fn d -> {d.module, d.name} end)
    by_module = Enum.group_by(all, & &1.module)

    # reverse edge, by called NAME — a receipt assembled in a helper is still a claim
    # about the caller's write (tasks_controller close/2 -> close_response/3).
    callers_by_name =
      all
      |> Enum.flat_map(fn d ->
        d.calls
        |> Enum.map(fn
          {:local, f} -> {f, d}
          {:remote, _segs, f} -> {f, d}
        end)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    %{
      defs: all,
      by_key: by_key,
      by_module: by_module,
      modules: Map.keys(by_module),
      callers_by_name: callers_by_name
    }
  end

  defp resolve(index, mod_segs, name) do
    Map.get(index.by_key, {mod_segs, name}) ||
      (index.modules
       |> Enum.filter(&suffix?(&1, mod_segs))
       |> Enum.flat_map(&Map.get(index.by_key, {&1, name}, [])))
      |> case do
        [] -> []
        list -> list
      end
  end

  defp suffix?(full, segs) do
    n = length(segs)
    length(full) >= n and Enum.take(full, -n) == segs
  end

  # ---------------------------------------------------------------- routing

  defp route(site, index, max \\ @max_depth) do
    start = site.def && resolve_exact(index, site.def)

    {verbs, depth, chain} =
      case start do
        nil -> {%{}, nil, []}
        d -> bfs([{d, 0, [label(d)]}], index, MapSet.new(), %{}, nil, [], max)
      end

    # UP ONE, THEN DOWN. A receipt assembled in a private helper claims the CALLER's
    # write (tasks_controller.ex:587 lives in close_response/3, which touches no Repo
    # verb — the write is Tasks.close/3 in close/2, one frame up). One hop up only:
    # expanding callers transitively would reach the whole tree and mean nothing.
    {via, via_verbs} =
      if start && not Map.has_key?(verbs, :write) do
        start
        |> callers(index)
        |> Enum.reduce_while({nil, %{}}, fn c, acc ->
          {v, _, _} = bfs([{c, 1, [label(c)]}], index, MapSet.new(), %{}, nil, [], max)
          if Map.has_key?(v, :write), do: {:halt, {label(c), v}}, else: {:cont, acc}
        end)
      else
        {nil, %{}}
      end

    verbs =
      Map.merge(via_verbs, verbs, fn
        :visited, a, b -> a ++ b
        _k, a, b -> a ++ b
      end)

    Map.merge(site, %{
      verbs: verbs,
      write?: Map.has_key?(verbs, :write),
      read?: Map.has_key?(verbs, :read),
      depth: depth,
      via_caller: via,
      chain: chain,
      owner: start
    })
  end

  # callers of a def, matched on the called NAME and (for remote calls) an alias whose
  # tail matches the owning module — the same suffix rule the downward resolver uses.
  defp callers(d, index) do
    index.callers_by_name
    |> Map.get(d.name, [])
    |> Enum.filter(fn c ->
      Enum.any?(c.calls, fn
        {:local, f} -> f == d.name and c.module == d.module
        {:remote, segs, f} -> f == d.name and suffix?(d.module, segs)
      end)
    end)
    |> Enum.reject(&(&1.module == d.module and &1.name == d.name))
    |> Enum.take(12)
  end

  defp resolve_exact(index, {mod, name, arity}) do
    (Map.get(index.by_key, {mod, name}) || [])
    |> Enum.find(&(&1.arity == arity))
    |> Kernel.||(List.first(Map.get(index.by_key, {mod, name}) || []))
  end

  defp bfs([], _index, _seen, verbs, depth, chain, _max), do: {verbs, depth, chain}

  defp bfs([{d, depth, path} | rest], index, seen, verbs, found_at, chain, max) do
    key = {d.module, d.name, d.arity}

    if MapSet.member?(seen, key) do
      bfs(rest, index, seen, verbs, found_at, chain, max)
    else
      seen = MapSet.put(seen, key)
      hits = verb_hits(d)
      # every function the route actually entered — the evidence the shape test reads
      verbs = Map.update(verbs, :visited, [d], &[d | &1])

      verbs =
        Enum.reduce(hits, verbs, fn {kind, verb, line}, acc ->
          Map.update(acc, kind, [{verb, line, d.path, depth}], &[{verb, line, d.path, depth} | &1])
        end)

      {found_at, chain} =
        if found_at == nil and Map.has_key?(verbs, :write),
          do: {depth, path},
          else: {found_at, chain}

      # A defdelegate is a RENAME, not a call: it holds no logic that could make the
      # claim true or false, so following one costs no depth. Charging it a hop is how
      # a 24-entry facade like Barkpark.Tasks eats the whole budget and reports false.
      step = if d.delegate, do: 0, else: 1

      next =
        if depth + step > max do
          []
        else
          d
          |> callees(index)
          |> Enum.map(&{&1, depth + step, path ++ [label(&1)]})
        end

      bfs(rest ++ next, index, seen, verbs, found_at, chain, max)
    end
  end

  defp label(d), do: "#{Enum.join(d.module, ".")}.#{d.name}/#{d.arity}"

  defp verb_hits(%{delegate: {_, _}}), do: []

  defp verb_hits(%{body: nil}), do: []

  defp verb_hits(%{body: body}) do
    {_, hits} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segs}, f]}, meta, args} = n, acc when is_list(args) ->
          last = List.last(segs)

          cond do
            last in @repo_mods and f in @write_verbs ->
              {n, [{:write, :"#{last}.#{f}", meta[:line]} | acc]}

            last in @repo_mods and f in @read_verbs ->
              {n, [{:read, :"#{last}.#{f}", meta[:line]} | acc]}

            last == :Repo and f in [:query, :query!] ->
              {n, [{:read, :"Repo.#{f}", meta[:line]} | acc]}

            true ->
              {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    hits
  end

  # callees: defdelegate target, or every local/remote call resolvable in the corpus
  defp callees(%{delegate: {target, as}}, index) when is_list(target),
    do: resolve(index, target, as)

  defp callees(%{delegate: {_, _}}, _index), do: []

  defp callees(%{body: nil}, _index), do: []

  defp callees(%{module: mod} = d, index) do
    (d[:calls] || raw_calls(d))
    |> Enum.flat_map(fn
      {:local, f} -> Map.get(index.by_key, {mod, f}, [])
      {:remote, segs, f} -> resolve(index, segs, f)
    end)
    |> Enum.uniq_by(&{&1.module, &1.name, &1.arity})
  end

  defp raw_calls(%{body: nil}), do: []

  defp raw_calls(%{body: body}) do
    {_, calls} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segs}, f]}, _, args} = n, acc
        when is_atom(f) and is_list(args) ->
          {n, [{:remote, segs, f} | acc]}

        {f, _, args} = n, acc when is_atom(f) and is_list(args) ->
          if Macro.special_form?(f, length(args)) or Macro.operator?(f, length(args)) do
            {n, acc}
          else
            {n, [{:local, f} | acc]}
          end

        n, acc ->
          {n, acc}
      end)

    Enum.uniq(calls)
  end

  # ---------------------------------------------------------------- classify

  defp classify(site, index) do
    owner = site.owner
    shape = shape_of(site, owner, index)
    Map.put(site, :shape, shape)
  end

  defp shape_of(_site, nil, _index), do: {"UNCLASSIFIED", "no enclosing function resolved"}

  defp shape_of(site, owner, _index) do
    # The shape lives in the ROUTE, not only in the emitting function: the write and the
    # post-read that would back it are usually three frames down from the receipt.
    visited = Map.get(site.verbs, :visited, [owner])
    hits = verb_hits(owner)
    local_writes = for {:write, v, l} <- hits, do: {v, l}
    local_reads = for {:read, v, l} <- hits, do: {v, l}

    # Only the functions that ACTUALLY WRITE (plus the one that prints the receipt) can
    # supply a post-read. Accepting evidence from any function the route touched would
    # let an unrelated read three modules away certify the claim — over-claiming
    # compliance is the disease this census exists to find.
    candidates = Enum.filter(visited, &writes?/1) ++ [owner]

    selecting = Enum.find(candidates, &has_select_in_update?(&1.body))
    reading_after = Enum.find(candidates, &post_read_in?/1)
    cas = Enum.find(candidates, &cas_confirmed?/1)

    cond do
      site.write? and selecting ->
        {"POST-READ",
         "#{label(selecting)} writes with `select:` INSIDE the update query — the row is measured after the change (`returning:` is silently ignored by update_all, auth.ex:139-141, and is NOT this)"}

      site.write? and reading_after ->
        {"POST-READ", "#{label(reading_after)} reads back after its own write"}

      site.write? and cas ->
        {"CAS-CONFIRMED-ECHO",
         "#{label(cas)} matches its update_all result against a literal row count — the claim dies if 0 rows moved"}

      not error_arm?(owner.body) ->
        {"UNREACHABLE-ERROR",
         "the emitting function carries no :error arm, no rescue and no raise — the failure this receipt implies cannot be expressed in it"}

      true ->
        {"UNCLASSIFIED", evidence(site, local_writes, local_reads)}
    end
  end

  defp writes?(d), do: Enum.any?(verb_hits(d), fn {k, _, _} -> k == :write end)

  defp post_read_in?(d) do
    hits = verb_hits(d)
    post_read?(for({:write, v, l} <- hits, do: {v, l}), for({:read, v, l} <- hits, do: {v, l}))
  end

  defp evidence(site, writes, reads) do
    parts =
      [
        if(site.write?, do: "write-routed at depth #{site.depth}", else: nil),
        if(site.read? and not site.write?, do: "read-routed only", else: nil),
        if(!site.write? and !site.read?, do: "no Repo verb within depth #{@max_depth}", else: nil),
        if(writes != [], do: "local writes: #{Enum.map_join(writes, ",", &elem(&1, 0))}", else: nil),
        if(reads != [], do: "local reads: #{Enum.map_join(reads, ",", &elem(&1, 0))}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "; ")
  end

  defp post_read?([], _), do: false
  defp post_read?(_, []), do: false

  defp post_read?(writes, reads) do
    w = writes |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)
    r = reads |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)
    w != [] and r != [] and Enum.max(r) > Enum.min(w)
  end

  # `returning:` is a BLIND lens — Ecto silently ignores it on update_all (auth.ex:139-141).
  # The honest idiom is `select:` INSIDE the update query.
  defp has_select_in_update?(nil), do: false

  defp has_select_in_update?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:from, _, args} = n, acc when is_list(args) ->
          {n, acc or kw_present?(args, :select)}

        n, acc ->
          {n, acc}
      end)

    found
  end

  defp kw_present?(args, key) do
    Enum.any?(List.flatten(args), fn
      {k, _} ->
        case lit(k) do
          {:lit, ^key, _} -> true
          _ -> false
        end

      _ ->
        false
    end)
  end

  defp cas_confirmed?(%{body: nil}), do: false

  defp cas_confirmed?(%{body: body} = d) do
    updates? = Enum.any?(verb_hits(d), fn {k, v, _} -> k == :write and v == :"Repo.update_all" end)
    updates? and int_tuple_match?(body)
  end

  defp int_tuple_match?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:{}, _, [a, _]} = n, acc -> {n, acc or int_lit?(a)}
        {a, _} = n, acc -> {n, acc or int_lit?(a)}
        n, acc -> {n, acc}
      end)

    found
  end

  defp int_lit?(node) do
    case lit(node) do
      {:lit, v, _} when is_integer(v) -> true
      _ -> false
    end
  end

  defp error_arm?(nil), do: false

  defp error_arm?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:__block__, _, [:error]} = n, _acc -> {n, true}
        {op, _, _} = n, _acc when op in [:rescue, :raise, :try] -> {n, true}
        n, acc -> {n, acc}
      end)

    found
  end

  # ---------------------------------------------------------------- reporting

  defp split_phantoms(parsed, sites) do
    ast_sites = sites

    ast_by_file =
      ast_sites
      |> Enum.group_by(& &1.path)
      |> Map.new(fn {p, l} -> {p, Enum.frequencies(Enum.map(l, & &1.line))} end)

    phantoms =
      Enum.flat_map(parsed, fn f ->
        seen = Map.get(ast_by_file, f.path, %{})

        f.textual
        |> Enum.frequencies()
        |> Enum.flat_map(fn {{line, _kind}, n} ->
          have = Map.get(seen, line, 0)
          extra = n - have

          if extra > 0 do
            List.duplicate(%{path: f.path, line: line, why: phantom_why(f, line)}, extra)
          else
            []
          end
        end)
      end)

    {ast_sites, phantoms}
  end

  # a textual `ok: true` the AST does not carry as an `:ok`/`"ok"` pair is either a
  # DIFFERENT KEY (`db_ok: true`) or prose inside a @doc/comment/string.
  defp phantom_why(f, line) do
    text = f.src |> String.split("\n") |> Enum.at(line - 1, "")

    cond do
      String.contains?(text, "_ok: true") ->
        key =
          text
          |> String.split("ok: true")
          |> List.first()
          |> String.split(~r/[^A-Za-z0-9_]/)
          |> List.last()

        "WRONG KEY — `#{key}ok: true` is not `ok: true`"

      String.contains?(text, "#") ->
        "prose in a comment"

      true ->
        "prose in a @doc/@moduledoc/string (no AST pair on this line)"
    end
  end

  defp report_lens(textual, ast_sites, phantoms, consumers, emitted) do
    p("THE POPULATION (derived here, not inherited)")
    p(String.duplicate("-", 78))
    row("textual occurrences", textual, nil, :textual)
    row("  AST-literal pairs", length(ast_sites), nil, :ast)
    row("  phantoms", length(phantoms), nil, :phantom)

    Enum.each(Enum.sort_by(phantoms, &{&1.path, &1.line}), fn ph ->
      p("      #{short(ph.path)}:#{ph.line} — #{ph.why}")
    end)

    row("  consumers (pattern position, NOT emitters)", length(consumers), nil, :consumer)

    Enum.each(Enum.sort_by(consumers, &{&1.path, &1.line}), fn c ->
      p("      #{short(c.path)}:#{c.line} — matches a REMOTE response, does not make a claim")
    end)

    row("EMITTED success claims", length(emitted), nil, :emitted)
    p("")
  end

  defp report_split(classified) do
    w = Enum.count(classified, & &1.write?)
    r = Enum.count(classified, &(not &1.write? and &1.read?))
    u = Enum.count(classified, &(not &1.write? and not &1.read?))

    p("WHAT EACH CLAIM IS ABOUT (route-following through defdelegate, depth #{@max_depth})")
    p(String.duplicate("-", 78))
    row("write-routed  (claims a state change)", w, nil, :write)
    row("read-routed   (claims a read)", r, nil, :read)
    row("unrouted      (no Repo verb reached)", u, nil, :unrouted)
    p("")
    p("  #{w} IS A FLOOR, NEVER A CEILING. The #{u} unrouted sites are unrouted because this")
    p("  lens gave up at depth #{@max_depth} or could not resolve an alias — not because they")
    p("  touch no state. PDS-D448 judged them almost certainly writes. Read the write count")
    p("  as \"at least #{w} success claims are about a state change\".")
    p("")
  end

  # WHY THE FLOOR IS A FLOOR, shown rather than asserted. The write count is a function
  # of the depth budget, not a property of the code: a controller that calls a context
  # that calls a query builder that calls Repo is 4 hops, and depth 3 cannot see it.
  defp report_depth_sweep(emitted, index) do
    p("THE FLOOR MOVES WITH THE LENS (depth sensitivity — the drift vs PDS-D448 explained)")
    p(String.duplicate("-", 78))

    Enum.each(@sweep, fn d ->
      routed = Enum.map(emitted, &route(&1, index, d))
      w = Enum.count(routed, & &1.write?)
      r = Enum.count(routed, &(not &1.write? and &1.read?))
      u = Enum.count(routed, &(not &1.write? and not &1.read?))
      mark = if d == @max_depth, do: "  <- the census depth", else: ""

      p("  depth #{d}   write #{String.pad_leading(to_string(w), 3)}   read #{String.pad_leading(to_string(r), 3)}   unrouted #{String.pad_leading(to_string(u), 3)}#{mark}")
    end)

    p("")
    p("  PDS-D448 recorded write=#{@recorded.write} read=#{@recorded.read} unrouted=#{@recorded.unrouted}. That is NOT this lens at")
    p("  depth #{@max_depth}; it is what a deeper (or hand-followed) route sees. Both are honest and")
    p("  neither is a ceiling — which is the point. A success-claim census reports the")
    p("  budget it measured with, or its integer means nothing.")
    p("")
  end

  defp report_shapes(classified) do
    counts = Enum.frequencies(Enum.map(classified, fn s -> elem(s.shape, 0) end))

    p("SHAPE (PDS-D453 taxonomy — six shapes, or UNCLASSIFIED; never a guess)")
    p(String.duplicate("-", 78))
    p("  READ THE POST-READ COUNT AS A CEILING, not a clean bill of health. Its evidence is")
    p("  line order — a Repo READ below a Repo WRITE inside the writing function — which is")
    p("  NECESSARY and NOT SUFFICIENT: this lens cannot prove the read is OF THE ROW that")
    p("  was written. `select:` inside the update query is the one spelling it CAN prove.")
    p("  Wave 34 confirms each one by hand; a POST-READ here is a candidate, not a verdict.")
    p("")

    Enum.each(@shapes, fn sh ->
      n = Map.get(counts, sh, 0)
      note = if n == 0, do: shape_zero_note(sh), else: ""
      p(String.pad_trailing("  " <> sh, 30) <> String.pad_leading(to_string(n), 4) <> "  " <> note)
    end)

    n = Map.get(counts, "UNCLASSIFIED", 0)
    p(String.pad_trailing("  UNCLASSIFIED", 30) <> String.pad_leading(to_string(n), 4) <>
        "  the lens holds evidence but no verdict — wave 34 buckets these by hand")
    p("")
  end

  defp shape_zero_note("WRONG-ROW"),
    do: "0 DETECTED — this lens cannot see it; it needs the row identity, not the verb"

  defp shape_zero_note("DISCARDED-POST-READ"),
    do: "0 DETECTED — needs dataflow from the read to the printed value"

  defp shape_zero_note("PURE-ECHO"),
    do: "0 DETECTED — not separable from UNCLASSIFIED without dataflow; not guessed"

  defp shape_zero_note(_), do: ""

  defp report_each_site(classified) do
    p("EVERY EMITTED SITE")
    p(String.duplicate("-", 78))

    classified
    |> Enum.sort_by(&{&1.path, &1.line})
    |> Enum.each(fn s ->
      {shape, why} = s.shape

      p("#{short(s.path)}:#{s.line}  [#{route_tag(s)}] #{shape}")
      p("    fn #{s.owner && label(s.owner) || "?"} — #{why}")
    end)

    p("")
  end

  defp route_tag(s) do
    cond do
      s.write? and s.via_caller -> "WRITE via caller #{s.via_caller}"
      s.write? -> "WRITE d#{s.depth}"
      s.read? -> "READ"
      true -> "UNROUTED"
    end
  end

  # ---------------------------------------------------------------- blind spots

  defp report_blind_spots(parsed) do
    json = sum_occ(parsed, "json(conn,")
    send_resp = sum_occ(parsed, "send_resp(conn, 2")

    put2xx =
      Enum.sum(
        for f <- parsed do
          Enum.sum(
            for pat <- ["put_status(:ok", "put_status(:created", "put_status(:accepted",
                        "put_status(:no_content", "put_status(20"],
                do: count(f.src, pat)
          )
        end
      )

    p("WHAT THIS LENS CANNOT SEE (a census that hides its blind spots is propaganda)")
    p(String.duplicate("-", 78))
    p("  #{json}  json(conn, ...) responses — a 200 with no `ok` key claims success by STATUS alone")
    p("  #{put2xx}  put_status(2xx) sites — same claim, wearing a status code")
    p("  #{send_resp}  send_resp(conn, 2xx) sites — same again, with no body to inspect")
    p("  ALSO INVISIBLE: `mix ecto.migrations` reporting `up` (PDS-D311) — it reads a")
    p("  bookkeeping row, never the object the migration claims to have produced.")
    p("  Re-derive these three without this script (plain substrings, no \\b needed):")
    p("    git grep -c 'json(conn,' -- 'api/lib/**/*.ex' | awk -F: '{s+=$2} END{print s}'")
    p("    git grep -c 'send_resp(conn, 2' -- 'api/lib/**/*.ex' | awk -F: '{s+=$2} END{print s}'")
    p("")
  end

  defp sum_occ(parsed, needle), do: Enum.sum(Enum.map(parsed, &count(&1.src, needle)))

  # ---------------------------------------------------------------- delegate probe

  # PDS-D449a trap 2: Barkpark.Tasks is a 24-entry defdelegate facade, and `defdelegate`
  # is not `def` — a naive write detector reports 24 of 25 sites false. This probe is the
  # ONLY thing in the script that can go red on a code change: it asserts the facade still
  # resolves through to a real write verb.
  defp report_delegate_probe(index) do
    facade = Map.get(index.by_module, [:Barkpark, :Tasks], [])
    delegates = Enum.filter(facade, & &1.delegate)
    close = Enum.find(delegates, &(&1.name == :close))

    {verbs, depth, chain} =
      case close do
        nil -> {%{}, nil, []}
        d -> bfs([{d, 0, [label(d)]}], index, MapSet.new(), %{}, nil, [], @max_depth)
      end

    write? = Map.has_key?(verbs, :write)

    p("DELEGATE PROBE — Barkpark.Tasks (the facade that makes naive detectors lie)")
    p(String.duplicate("-", 78))
    p("  defdelegate entries on Barkpark.Tasks: #{length(delegates)}")
    p("    (`git grep -c defdelegate api/lib/barkpark/tasks.ex` says 24 — three of those are")
    p("     the word `defdelegated` in comments. The AST counts declarations, not prose.)")

    if close do
      hops =
        case chain do
          [_ | rest] when rest != [] -> Enum.join(rest, " -> ")
          _ -> "(no write reached — the chain ends without one)"
        end

      p("  Barkpark.Tasks.close/#{close.arity} -> delegate -> #{hops}")

      verbs
      |> Map.get(:write, [])
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.each(fn {v, l, path, d} -> p("    write verb #{v} at #{short(path)}:#{l} (depth #{d})") end)
    end

    p("  reaches a write verb: #{write?}")
    p("")

    %{delegates: length(delegates), close_write?: write?, close_depth: depth}
  end

  # ---------------------------------------------------------------- integrity

  defp integrity(files, textual, ast_sites, phantoms, consumers, emitted, classified, delegate, ms) do
    classified_n = Enum.count(classified, fn s -> elem(s.shape, 0) != "UNCLASSIFIED" end)
    unclassified_n = Enum.count(classified, fn s -> elem(s.shape, 0) == "UNCLASSIFIED" end)

    checks = [
      {"CORPUS-INTACT", length(files) >= @corpus_floor,
       "#{length(files)} files >= #{@corpus_floor}"},
      {"LENS-LOSES-NOTHING", textual == length(ast_sites) + length(phantoms),
       "textual #{textual} == ast #{length(ast_sites)} + phantom #{length(phantoms)}"},
      {"EMITTERS-PARTITION", length(ast_sites) == length(consumers) + length(emitted),
       "ast #{length(ast_sites)} == consumer #{length(consumers)} + emitted #{length(emitted)}"},
      {"CLASSIFICATION-TOTAL", classified_n + unclassified_n == length(emitted),
       "classified #{classified_n} + unclassified #{unclassified_n} == emitted #{length(emitted)}"},
      {"DELEGATE-REACHES-WRITE", delegate.close_write?,
       # On FAIL close_depth is nil, and "at depth " with nothing after it reads
       # like a truncated line rather than a finding — say what actually happened.
       if delegate.close_write? do
         "Barkpark.Tasks.close (defdelegate, #{delegate.delegates} on the facade) reaches a write verb at depth #{delegate.close_depth}"
       else
         "Barkpark.Tasks.close (defdelegate, #{delegate.delegates} on the facade) reaches NO write verb within the route budget — the facade probe is blind"
       end}
    ]

    p("INTEGRITY (these can go RED — the population numbers cannot; they are not a gate)")
    p(String.duplicate("-", 78))

    Enum.each(checks, fn {name, ok?, why} ->
      p("  #{if ok?, do: "PASS", else: "FAIL"}  #{String.pad_trailing(name, 24)} #{why}")
    end)

    p("")
    p("DRIFT vs PDS-D448 (advisory — printed, never enforced)")
    p(String.duplicate("-", 78))
    drift("textual", textual, :textual)
    drift("ast-literal", length(ast_sites), :ast)
    drift("phantom", length(phantoms), :phantom)
    drift("consumer", length(consumers), :consumer)
    drift("emitted", length(emitted), :emitted)
    drift("write-routed", Enum.count(classified, & &1.write?), :write)
    drift("read-routed", Enum.count(classified, &(not &1.write? and &1.read?)), :read)
    drift("unrouted", Enum.count(classified, &(not &1.write? and not &1.read?)), :unrouted)
    p("")
    p("wall clock  #{ms} ms  (build-free: no mix project, no compile, no app boot)")

    if Enum.all?(checks, &elem(&1, 1)) do
      p("CENSUS OK")
      System.halt(0)
    else
      p("CENSUS FAILED — an integrity check went red. Read the FAIL line above.")
      System.halt(1)
    end
  end

  defp drift(label, got, key) do
    want = @recorded[key]
    tag = if got == want, do: "==", else: "DRIFT"
    p("  #{String.pad_trailing(label, 14)} recorded #{String.pad_leading(to_string(want), 4)}  derived #{String.pad_leading(to_string(got), 4)}  #{tag}")
  end

  defp row(label, got, _raw, key) do
    want = @recorded[key]
    tag = if got == want, do: "", else: "  (PDS-D448 recorded #{want})"
    p(String.pad_trailing("  " <> label, 48) <> String.pad_leading(to_string(got), 4) <> tag)
  end

  defp short(path), do: String.replace_prefix(path, "api/lib/", "")

  defp p(s), do: IO.puts(s)
end

PDS.Census.main(System.argv())
