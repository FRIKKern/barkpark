#!/usr/bin/env elixir
#
# pds-roster-callee-churn.exs — MEASURE, BEFORE ANY ARM CHANGE, WHAT A CALLEE-INCLUSIVE
# ROSTER FINGERPRINT WOULD COST.
#
# WHY IT EXISTS. ROSTER-VERDICT-FRESH (scripts/pds-elixir-receipt-census.exs) records
# `anchor_mfa` + `def_fp` for the def that ENCLOSES each @roster literal. Both granularities
# are SAME-FILE, and the arm PRINTS that blind shape: a repair confined to a CALLEE of the
# roster row's def moves no byte inside that def, so the arm prints PASS through a verdict
# that has just become false. PDS-D558 settled `def_fp` by MEASUREMENT — over 95 `api/lib`
# commits it would have fired TWICE, one of them the correct repair (fbc6b80a1, #8993), i.e.
# ONE UNRELATED FIRE PER 95 COMMITS — against the count-arm rate this epic already refuses
# (~1 per 11 commits, PDS-D524). The obvious widening (def_fp PLUS a fingerprint over the
# one-hop callee set) has to be priced on the SAME window before it is built, or the epic
# buys the noisy arm it spent two waves refusing.
#
# WHAT IT MEASURES. For every commit C in the window, and for each of the eight wave-39
# @roster rows, it re-derives at C and at C's first parent:
#
#   def_fp      = fp({head, body}) of the NARROWEST def enclosing the row's literal
#   anchor_mfa  = Module.name/arity of that def
#   callee_fp   = phash2 over the sorted {mfa, fp} of the ONE-HOP callees of that def
#
# A row FIRES at C when the value differs across C^ -> C. The def granularity is the
# CONTROL: this harness is only trustworthy if it reproduces PDS-D558's two fires, by sha.
#
# THE CALLEE RESOLVER MIRRORS THE CENSUS'S OWN, NOT A SIMPLER ONE. A churn rate measured
# over a NARROWER relation than the arm would ship is a floor, and a widening must never rest
# on a floor. So this harness reproduces `callees/2`'s edge set edge for edge: pipes expanded
# before the walk, `Macro.special_form?/2` + `Macro.operator?/2` as the non-call filter (never
# a hand-kept name list), capture edges (`&f/2`, `&Mod.f/2`), calls on a variable module head
# resolved against the SAME body's `Module.concat` bindings, module lookup EXACT-then-suffix,
# and default-aware arity acceptance (`req..arity`). `--show` prints the resolved and the
# unresolved edge of every roster def so the relation is read, not trusted.
#
# THE TWO OMISSIONS, NAMED: an `import`ed local call is not followed, and `defdelegate` is
# recorded as a def rather than followed to its target. Neither costs anything on this
# population — no roster file carries a literal `import` or a `defdelegate` at the window tip
# (`--show` leaves every resolved edge accounted for, and the unresolved remainder is Kernel,
# Plug.Conn and Phoenix.Controller, all outside `api/lib` and therefore outside any corpus
# fingerprint). Both can only SHRINK the set, so they bound the number from below.
#
# USAGE
#   elixir scripts/pds-roster-callee-churn.exs [--tip <sha>] [--count 95] [--repo <dir>]
#
# The default window is the one PDS-D558 priced: `git rev-list -95 9730f6931 -- api/lib`,
# the 95 api/lib commits ending at the commit that shipped ROSTER-VERDICT-FRESH (#9112).

defmodule RosterCalleeChurn do
  @default_tip "9730f69316f67fd8044591bfcf2d8c9cc2e308e4"
  @default_count 95

  # The EIGHT wave-39 rows, copied from `git show 9730f6931:scripts/pds-elixir-receipt-census.exs`
  # — not from main's @roster, which has since grown two rows and re-anchored two more. The
  # measurement has to be over the population PDS-D558 priced or it is not the same window.
  # The verdict rides along because it is what makes a fire RELATED or UNRELATED, and that
  # split has to be MECHANICAL, not narrated. THE RULE, AND IT IS PDS-D558'S OWN: a fire on a
  # row carrying a JUDGED verdict (PROVEN / REFUTED) is a TRUE POSITIVE — a claim about a
  # shape that just moved, and the re-derivation the arm exists to demand. A fire on an
  # UNJUDGED row is UNRELATED: the row asserts nothing, so nothing of it went stale. Applied
  # to the def granularity this rule reproduces D558's sentence exactly — 2 fires, of which
  # fbc6b80a1 is "the correct repair" and the chat feature commit is the "one unrelated fire
  # per 95 commits". A classification rule that did not reproduce the control would be the
  # finding, and it is checked below rather than assumed.
  @roster [
    {"api/lib/barkpark_web/controllers/scim_groups_controller.ex", "Scim.delete_group(org, group)", "PROVEN"},
    {"api/lib/barkpark_web/controllers/scim_users_controller.ex", "Scim.deprovision_user(org, user, hard: true)", "PROVEN"},
    {"api/lib/barkpark_web/controllers/session_controller.ex", "Barkpark.Accounts.revoke_user_session_token(token)", "PROVEN"},
    {"api/lib/barkpark_web/controllers/chat_controller.ex", "StudioChat.update_approval_status(id, request_id, status)", "UNJUDGED"},
    {"api/lib/barkpark_web/controllers/chat_controller.ex", "persist_user_turn(id, content)", "UNJUDGED"},
    {"api/lib/barkpark_web/controllers/chat_controller.ex", "json(%{request_id: request_id})", "UNJUDGED"},
    {"api/lib/barkpark_web/controllers/chat_host_controller.ex", "{:ok, :accepted} -> conn |> put_status(:accepted) |> json(", "UNJUDGED"},
    {"api/lib/barkpark_web/controllers/pulse_controller.ex", "def preflight(conn, _params), do: send_resp(conn, 204,", "UNJUDGED"}
  ]

  # def-like heads are structure, never an edge; everything else is decided by
  # Macro.special_form?/2 and Macro.operator?/2, the same pair callees/2 asks.
  @def_forms ~w(def defp defmacro defmacrop defmodule defdelegate defstruct defexception defguard defguardp defoverridable)a

  def main(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: [tip: :string, count: :integer, repo: :string, show: :boolean])
    repo = opts[:repo] || File.cwd!()
    tip = opts[:tip] || @default_tip
    count = opts[:count] || @default_count

    commits = git!(repo, ["rev-list", "-#{count}", tip, "--", "api/lib"]) |> lines()

    if length(commits) != count do
      IO.puts("REFUSED: the window is #{length(commits)} commits, not #{count}. A rate quoted over a window that is not the one it names is not a rate.")
      System.halt(2)
    end

    IO.puts("PDS ROSTER CALLEE CHURN — the price of the callee-inclusive fingerprint")
    IO.puts("")
    IO.puts("  window       #{count} api/lib commits, `git rev-list -#{count} #{String.slice(tip, 0, 9)} -- api/lib`")
    IO.puts("  newest       #{stamp(repo, List.first(commits))}")
    IO.puts("  oldest       #{stamp(repo, List.last(commits))}")
    IO.puts("  roster       #{length(@roster)} rows, the wave-39 population (9730f6931)")
    IO.puts("  resolver     one-hop, mirroring the census callees/2 edge set: pipes expanded, captures")
    IO.puts("               and dynvar heads followed, module EXACT-then-suffix, arity req..arity")
    if opts[:show] do
      show_callees(repo, tip)
      System.halt(0)
    end

    IO.puts("")

    # oldest -> newest, so a reader can follow the history forward
    ordered = Enum.reverse(commits)

    results =
      Enum.map(ordered, fn c ->
        parent = parent_of(repo, c)
        before = signature(repo, parent)
        now = signature(repo, c)
        {c, diff(before, now)}
      end)

    report(repo, results, :def_fp, "DEF GRANULARITY (the CONTROL — PDS-D558 priced this at 2 fires)")
    report(repo, results, :mfa, "ANCHOR-MFA GRANULARITY")
    report(repo, results, :callee_fp, "CALLEE-INCLUSIVE GRANULARITY (def_fp + one-hop callee set)")

    def_fires = fires(results, :def_fp)
    callee_fires = fires(results, :callee_fp)
    union_fires = fires(results, :either)

    IO.puts("")
    IO.puts("THE PRICE, SIDE BY SIDE (a fire is a commit at which at least one roster row moves)")
    IO.puts("")
    def_unrel = unrelated(results, :def_fp)
    union_unrel = unrelated(results, :either)

    IO.puts("  granularity                      fires  unrelated   one UNRELATED fire per N")
    IO.puts("  def_fp (shipped)                 #{pad(length(def_fires))}    #{pad(length(def_unrel))}       #{rate(count, length(def_unrel))}")
    IO.puts("  callee set alone                 #{pad(length(callee_fires))}    #{pad(length(unrelated(results, :callee_fp)))}       #{rate(count, length(unrelated(results, :callee_fp)))}")
    IO.puts("  def_fp + callee set (the arm)    #{pad(length(union_fires))}    #{pad(length(union_unrel))}       #{rate(count, length(union_unrel))}")
    IO.puts("")
    IO.puts("  PDS-D524's refused count-arm rate, for scale: ~1 per 11 commits.")
    IO.puts("  The row's threshold: widen only if the widened arm produces FEWER THAN ONE")
    IO.puts("  UNRELATED fire per 50 commits.")
    IO.puts("")

    # THE CONTROL, ASSERTED RATHER THAN EYEBALLED. PDS-D558 priced the def granularity at
    # 2 fires over this window, of which exactly one is unrelated. If this harness does not
    # reproduce that, its callee number is not comparable to D558's and must not be quoted.
    control =
      length(def_fires) == 2 and length(def_unrel) == 1 and
        Enum.any?(def_fires, fn {c, _} -> String.starts_with?(c, "fbc6b80a1") end)

    IO.puts("  CONTROL (PDS-D558: 2 def_fp fires, one of them fbc6b80a1, one unrelated): #{if control, do: "REPRODUCED", else: "NOT REPRODUCED"}")

    unless control do
      IO.puts("")
      IO.puts("REFUSED: the control did not reproduce. A callee price that cannot re-derive the")
      IO.puts("def price PDS-D558 already settled is measuring a different window or a different")
      IO.puts("roster, and quoting it would be a number with no unit.")
      System.halt(1)
    end

    verdict =
      cond do
        length(union_unrel) == 0 -> "BELOW THRESHOLD"
        count / length(union_unrel) >= 50 -> "BELOW THRESHOLD"
        true -> "ABOVE THRESHOLD"
      end

    IO.puts("")
    IO.puts("  VERDICT: the callee-inclusive arm fires #{rate(count, length(union_fires))} in total and")
    IO.puts("  #{rate(count, length(union_unrel))} UNRELATED — #{verdict}.")
    IO.puts("")
    IO.puts("MEASUREMENT OK")
  end

  # THE RESOLVER, SHOWN RATHER THAN DESCRIBED. A churn number over a callee set nobody
  # printed is a number with no unit: run with --show to read the exact one-hop set each
  # roster row's def resolves to at the window tip, and to see what the resolver misses.
  defp show_callees(repo, tip) do
    corpus = corpus(repo, tip)
    by_module = Enum.group_by(Enum.flat_map(corpus, fn {_p, %{defs: d}} -> d end), & &1.module)

    Enum.with_index(@roster)
    |> Enum.each(fn {{path, literal, _v}, i} ->
      with %{src: src, defs: defs} <- Map.get(corpus, path),
           {:ok, line} <- anchor(src, literal),
           d when not is_nil(d) <- enclosing(defs, line) do
        resolved = d.calls |> Enum.flat_map(&resolve(&1, d.module, by_module, d.binds)) |> Enum.map(&mfa/1) |> Enum.uniq() |> Enum.sort()
        unresolved = d.calls |> Enum.reject(&(resolve(&1, d.module, by_module, d.binds) != [])) |> Enum.sort()
        IO.puts("##{i} #{mfa(d)}  (#{Path.basename(path)}:#{line})")
        IO.puts("   RESOLVED   #{length(resolved)}: #{Enum.join(resolved, " · ")}")
        IO.puts("   UNRESOLVED #{length(unresolved)}: #{Enum.map_join(unresolved, " · ", &call_label/1)}")
        IO.puts("")
      else
        _ -> IO.puts("##{i} #{path} — no enclosing def at this tip")
      end
    end)
  end

  defp call_label({:local, f, a}), do: "#{f}/#{a}"
  defp call_label({:remote, segs, f, a}), do: "#{Enum.join(segs, ".")}.#{f}/#{a}"
  defp call_label({:dynvar, v, f, a}), do: "#{v}.#{f}/#{a}"

  defp fires(results, :either) do
    for {c, rows} <- results, Enum.any?(rows, &(&1.def_moved or &1.callee_moved)), do: {c, rows}
  end

  # A fire is UNRELATED when EVERY row it moved is UNJUDGED. One judged row moving makes the
  # whole commit a true positive for that granularity.
  defp unrelated(results, kind) do
    for {c, rows} <- fires(results, kind),
        moved = Enum.filter(rows, &moved?(&1, kind)),
        Enum.all?(moved, &(&1.verdict == "UNJUDGED")),
        do: {c, rows}
  end

  defp moved?(r, :def_fp), do: r.def_moved
  defp moved?(r, :mfa), do: r.mfa_moved
  defp moved?(r, :callee_fp), do: r.callee_moved
  defp moved?(r, :either), do: r.def_moved or r.callee_moved

  defp fires(results, :def_fp), do: for({c, rows} <- results, Enum.any?(rows, & &1.def_moved), do: {c, rows})
  defp fires(results, :mfa), do: for({c, rows} <- results, Enum.any?(rows, & &1.mfa_moved), do: {c, rows})
  defp fires(results, :callee_fp), do: for({c, rows} <- results, Enum.any?(rows, & &1.callee_moved), do: {c, rows})

  defp report(repo, results, kind, title) do
    f = fires(results, kind)
    IO.puts("#{title}")
    IO.puts("  #{length(f)} fire(s) over the window")

    Enum.each(f, fn {c, rows} ->
      moved =
        rows
        |> Enum.filter(&moved?(&1, kind))
        |> Enum.map_join(", ", & &1.label)

      IO.puts("    #{stamp(repo, c)}")
      IO.puts("        #{moved}")
    end)

    IO.puts("")
  end

  defp diff(before, now) do
    Enum.zip(before, now)
    |> Enum.map(fn {b, n} ->
      %{
        label: n.label,
        verdict: n.verdict,
        def_moved: b.def_fp != n.def_fp,
        mfa_moved: b.mfa != n.mfa,
        callee_moved: b.callee_fp != n.callee_fp
      }
    end)
  end

  # ---------------------------------------------------------------- derivation

  defp signature(repo, sha) do
    key = {:sig, tree_of(repo, sha)}

    case :erlang.get(key) do
      :undefined ->
        v = compute_signature(repo, sha)
        :erlang.put(key, v)
        v

      v ->
        v
    end
  end

  defp compute_signature(repo, sha) do
    corpus = corpus(repo, sha)
    by_module = Enum.group_by(Enum.flat_map(corpus, fn {_p, %{defs: d}} -> d end), & &1.module)

    Enum.with_index(@roster)
    |> Enum.map(fn {{path, literal, verdict}, i} ->
      base = %{label: "##{i} #{Path.basename(path)} #{inspect(String.slice(literal, 0, 28))} [#{verdict}]", verdict: verdict}

      with %{src: src, defs: defs} <- Map.get(corpus, path),
           {:ok, line} <- anchor(src, literal),
           d when not is_nil(d) <- enclosing(defs, line) do
        Map.merge(base, %{def_fp: d.fp, mfa: mfa(d), callee_fp: callee_fp(d, by_module)})
      else
        _ -> Map.merge(base, %{def_fp: "-", mfa: "-", callee_fp: "-"})
      end
    end)
  end

  defp callee_fp(d, by_module) do
    d.calls
    |> Enum.flat_map(&resolve(&1, d.module, by_module, d.binds))
    |> Enum.map(&{mfa(&1), &1.fp})
    |> Enum.uniq()
    |> Enum.sort()
    |> :erlang.phash2()
    |> to_string()
  end

  defp resolve({:local, f, a}, mod, by_module, _binds),
    do: by_module |> Map.get(mod, []) |> Enum.filter(&(&1.name == f)) |> at_arity(a)

  defp resolve({:remote, segs, f, a}, _mod, by_module, _binds), do: by_segs(segs, f, a, by_module)

  # THE VARIABLE IS THE KEY (the census's words). An unbound module variable resolves to [],
  # never to "some module in this body".
  defp resolve({:dynvar, var, f, a}, _mod, by_module, binds) do
    case Map.fetch(binds, var) do
      {:ok, segs} -> by_segs(segs, f, a, by_module)
      :error -> []
    end
  end

  defp by_segs(segs, f, a, by_module) do
    exact = by_module |> Map.get(segs, []) |> Enum.filter(&(&1.name == f))

    cands =
      if exact == [] do
        by_module
        |> Enum.filter(fn {m, _} -> suffix?(m, segs) end)
        |> Enum.flat_map(fn {_, defs} -> defs end)
        |> Enum.filter(&(&1.name == f))
      else
        exact
      end

    at_arity(cands, a)
  end

  # DEFAULT-AWARE, because `render_user(conn, user, active \\ true)` is a real callee at
  # arity 2 AND 3, and an exact-arity filter drops it at one of them.
  defp at_arity(cands, nil), do: cands
  defp at_arity(cands, a), do: Enum.filter(cands, &(a >= &1.req and a <= &1.arity))

  defp suffix?(mod, segs), do: length(mod) >= length(segs) and Enum.take(mod, -length(segs)) == segs

  defp mfa(d), do: "#{Enum.join(d.module, ".")}.#{d.name}/#{d.arity}"

  defp anchor(src, literal) do
    case src |> String.split("\n") |> Enum.find_index(&String.contains?(&1, literal)) do
      nil -> :missing
      i -> {:ok, i + 1}
    end
  end

  defp enclosing(defs, line) do
    defs
    |> Enum.filter(&(&1.line <= line and line <= &1.last))
    |> Enum.min_by(&(&1.last - &1.line), fn -> nil end)
  end

  # ---------------------------------------------------------------- corpus

  defp corpus(repo, sha) do
    tree = tree_of(repo, sha)

    case :erlang.get({:corpus, tree}) do
      :undefined ->
        v =
          repo
          |> git!(["ls-tree", "-r", "-z", "--format=%(objectname) %(path)", sha, "--", "api/lib"])
          |> String.split(<<0>>, trim: true)
          |> Enum.map(fn row ->
            [blob, path] = String.split(row, " ", parts: 2)
            {path, blob}
          end)
          |> Enum.filter(fn {p, _} -> String.ends_with?(p, ".ex") end)
          |> Enum.map(fn {p, blob} -> {p, parsed(repo, blob)} end)
          |> Map.new()

        :erlang.put({:corpus, tree}, v)
        v

      v ->
        v
    end
  end

  defp tree_of(repo, sha), do: repo |> git!(["rev-parse", "#{sha}^{tree}"]) |> String.trim()

  defp parsed(repo, blob) do
    case :erlang.get({:blob, blob}) do
      :undefined ->
        src = git!(repo, ["cat-file", "blob", blob])
        v = %{src: src, defs: collect(src)}
        :erlang.put({:blob, blob}, v)
        v

      v ->
        v
    end
  end

  defp collect(src) do
    opts = [
      literal_encoder: &{:ok, {:__block__, &2, [&1]}},
      token_metadata: true,
      columns: true,
      emit_warnings: false,
      unescape: false
    ]

    case Code.string_to_quoted(src, opts) do
      {:ok, ast} -> defs(ast, [], [])
      {:error, _} -> []
    end
  end

  defp defs({:defmodule, _, [{:__aliases__, _, segs}, body]}, mod, acc),
    do: defs(body, mod ++ segs, acc)

  defp defs({form, meta, [head, body]}, mod, acc) when form in [:def, :defp] do
    {name, arity} = signature_of(head)

    if is_nil(name) do
      acc
    else
      [
        %{
          module: mod,
          name: name,
          arity: arity,
          line: meta[:line] || 0,
          last: last_line({form, meta, [head, body]}),
          req: required_arity(head),
          fp: fp({head, body}),
          binds: concat_bindings(body),
          calls: raw_calls(body)
        }
        | acc
      ]
    end
  end

  defp defs({_, _, args}, mod, acc) when is_list(args), do: Enum.reduce(args, acc, &defs(&1, mod, &2))
  defp defs([{:do, body}], mod, acc), do: defs(body, mod, acc)
  defp defs(list, mod, acc) when is_list(list), do: Enum.reduce(list, acc, &defs(&1, mod, &2))
  defp defs({a, b}, mod, acc), do: defs(b, mod, defs(a, mod, acc))
  defp defs(_, _, acc), do: acc

  # `req` is the arity with every defaulted argument dropped — callees/2's accepts?/2 takes
  # req..arity, so a default-carrying callee is reachable at more than one arity.
  defp required_arity({:when, _, [head | _]}), do: required_arity(head)

  defp required_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: Enum.count(args, fn
      {:\\, _, _} -> false
      _ -> true
    end)

  defp required_arity(_), do: 0

  # `mod = Module.concat(Barkpark.Plugins.Github, Intake)` -> %{mod: [:Barkpark, ...]}
  defp concat_bindings(nil), do: %{}

  defp concat_bindings(body) do
    {_, binds} =
      Macro.prewalk(body, %{}, fn
        {:=, _, [{var, _, ctx}, {{:., _, [{:__aliases__, _, [:Module]}, :concat]}, _, args}]} = n, acc
        when is_atom(var) and not is_list(ctx) ->
          segs = Enum.flat_map(args, fn
            {:__aliases__, _, s} -> s
            _ -> []
          end)

          {n, if(segs == [], do: acc, else: Map.put(acc, var, segs))}

        n, acc ->
          {n, acc}
      end)

    binds
  end

  defp signature_of({:when, _, [head | _]}), do: signature_of(head)
  defp signature_of({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp signature_of({name, _, nil}) when is_atom(name), do: {name, 0}
  defp signature_of(_), do: {nil, nil}

  defp last_line(node) do
    {_, max} =
      Macro.prewalk(node, 0, fn
        {_, meta, _} = n, acc when is_list(meta) ->
          l = Enum.max([meta[:line] || 0, get_in(meta, [:end, :line]) || 0, get_in(meta, [:closing, :line]) || 0])
          {n, max(acc, l)}

        n, acc ->
          {n, acc}
      end)

    max
  end

  defp raw_calls(nil), do: []

  defp raw_calls(body) do
    {_, calls} =
      body
      |> expand_pipes()
      |> Macro.prewalk([], fn
        # A CAPTURE IS AN EDGE. `&Mod.f/2` / `&f/2`. The node is REPLACED by an inert atom
        # because prewalk re-enters what it returns, and the inner dot-tuple would otherwise
        # be recorded a second time as a remote call of arity 0.
        {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, segs}, f]}, _, []}, a]}]}, acc when is_atom(f) ->
          case capture_arity(a) do
            nil -> {:__capture__, acc}
            ar -> {:__capture__, [{:remote, segs, f, ar} | acc]}
          end

        {:&, _, [{:/, _, [{f, _, ctx}, a]}]}, acc when is_atom(f) and not is_list(ctx) ->
          case capture_arity(a) do
            nil -> {:__capture__, acc}
            ar -> {:__capture__, [{:local, f, ar} | acc]}
          end

        # A call on a VARIABLE module head. `no_parens: true` separates the field access
        # `changeset.errors` from the call `mod.ingest(p, o)`; both quote the same shape.
        {{:., _, [{var, _, vctx}, f]}, meta, args}, acc
        when is_atom(var) and is_atom(f) and is_list(args) and not is_list(vctx) ->
          if Keyword.get(meta, :no_parens, false) do
            {{:__field__, f}, acc}
          else
            {{:__dyn__, f, args}, [{:dynvar, var, f, length(args)} | acc]}
          end

        {{:., _, [{:__aliases__, _, segs}, f]}, _, args} = n, acc when is_atom(f) and is_list(args) ->
          {n, [{:remote, segs, f, length(args)} | acc]}

        {f, _, args} = n, acc when is_atom(f) and is_list(args) ->
          if f in @def_forms or Macro.special_form?(f, length(args)) or Macro.operator?(f, length(args)) do
            {n, acc}
          else
            {n, [{:local, f, length(args)} | acc]}
          end

        n, acc ->
          {n, acc}
      end)

    Enum.uniq(calls)
  end

  # The arity literal of a capture, under BOTH spellings — `literal_encoder` wraps the 2 of
  # `&f/2` in a {:__block__, _, [2]}, so a bare `is_integer` guard here is a DEAD clause.
  defp capture_arity({:__block__, _, [n]}) when is_integer(n), do: n
  defp capture_arity(n) when is_integer(n), do: n
  defp capture_arity(_), do: nil

  defp expand_pipes(body) do
    Macro.prewalk(body, fn
      {:|>, _, [lhs, {{:., _, _} = dot, meta, args}]} when is_list(args) -> {dot, meta, [lhs | args]}
      {:|>, _, [lhs, {f, meta, args}]} when is_atom(f) and is_list(args) -> {f, meta, [lhs | args]}
      n -> n
    end)
  end

  defp fp(node), do: node |> drop_meta() |> :erlang.phash2() |> to_string()

  defp drop_meta(ast) do
    Macro.prewalk(ast, fn
      {f, meta, a} when is_list(meta) -> {f, [], a}
      n -> n
    end)
  end

  # ---------------------------------------------------------------- git + fmt

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {out, 0} -> out
      {out, rc} -> raise "git #{Enum.join(args, " ")} exited #{rc}: #{String.slice(out, 0, 400)}"
    end
  end

  defp parent_of(repo, sha), do: repo |> git!(["rev-parse", "#{sha}^1"]) |> String.trim()

  defp lines(s), do: s |> String.split("\n", trim: true)

  defp stamp(repo, sha) do
    repo |> git!(["show", "-s", "--format=%h %ad %s", "--date=short", sha]) |> String.trim()
  end

  defp pad(n), do: String.pad_leading(to_string(n), 3)

  defp rate(_window, 0), do: "never fires"
  defp rate(window, n), do: "1 per #{Float.round(window / n, 1)}"
end

RosterCalleeChurn.main(System.argv())
