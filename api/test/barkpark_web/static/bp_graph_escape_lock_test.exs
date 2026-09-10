defmodule BarkparkWeb.Static.BpGraphEscapeLockTest do
  @moduledoc """
  The bp-graph.js HTML-sink escape lock, asserted from the REQUIRED Elixir gate.

  WHY THIS TEST EXISTS (task-e3cf9937e4762bb0)
  --------------------------------------------
  `api/priv/static/assets/bp-graph.js` writes server-derived strings into
  `innerHTML`. Two of those interpolations carry document data straight from
  the API — the hover tooltip's type line and the legend row's type name — and
  both are `esc()`-wrapped today. Before #12324 the tooltip line was stored XSS
  that fired at page load for an anonymous visitor of the search-starter
  landing page (`templates/search-starter/components/graph-view.tsx` defaults
  `fullColor=true`, and the tooltip needs no toggle at all).

  Those `esc()` wraps had two locks, and BOTH are advisory:

    * `web/__tests__/graph-xss.test.ts` — reads ONE copy (`../public/bp-graph.js`)
      and runs under a workflow that is not in `.github/required-checks.json`.
    * `scripts/check-bp-graph-drift.sh` via `.github/workflows/bp-graph-drift.yml`
      — enforces the four-copy byte identity, also not required.

  `.github/required-checks.json` requires only `Cloud gate`, `Console gate`,
  `Elixir gate` and `PR references an active task`. So a PR that strips `esc()`
  from the canonical copy and propagates it to the three mirrors reds two
  advisory checks and merges. This test moves the lock to the side that blocks.

  WHAT IT ASSERTS
  ---------------
    1. The canonical file reads non-empty (an empty/missing read REFUSES rather
       than passing vacuously — a scan over "" finds zero sinks and would
       otherwise be green).
    2. Every `innerHTML =` / `insertAdjacentHTML(` sink in the file is resolved
       through its accumulator variables, and every operand of the resulting
       HTML expression is either a string literal, an `esc(...)` call, a
       documented presentational value, or resolves (via JS `var` scoping) to
       one of those. Anything else — a raw `node.type`, a raw loop variable —
       is a VIOLATION. The scan is DENY-BY-DEFAULT: a new unescaped operand
       reds this required gate, and a new presentational helper has to be
       declared in `@presentational` with a rationale.
    3. A positive control: the scan must actually SEE the two known
       server-string sinks and must observe `esc(node.type)` and `esc(ty)` as
       the wrapping at those sinks. Deleting either `esc(` therefore reds this
       test twice over (the operand becomes a violation AND the control loses
       its named argument).
    4. The four copies of bp-graph.js are byte-identical, refusing on any
       missing copy — so the mirrors cannot drift behind the canonical file
       with only an advisory check watching.

  Read-path note: the three mirror copies are cross-tree reads out of `api/`
  and are therefore declared in `scripts/elixir-path-escape-check.sh`'s
  `ELIXIR_TEST_ONLY_PATHS`, which is BOTH what keeps that ratchet honest and
  what puts the mirrors into the Elixir dispatcher's path set — a PR that edits
  only a mirror now runs this suite instead of skipping it.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @canonical "api/priv/static/assets/bp-graph.js"
  @mirrors [
    "web/public/bp-graph.js",
    "templates/search-starter/public/bp-graph.js",
    "templates/astro-search-starter/public/bp-graph.js"
  ]

  # A real bp-graph.js is ~3400 lines. Anything this small is a truncated or
  # replaced read, not a widget: refuse rather than scan it.
  @min_bytes 20_000

  # Operands that are presentational by construction: they cannot carry
  # document text into the DOM, so they need no esc(). Each entry is a full
  # match against a single concatenation operand, with the ground for it.
  @presentational [
    {~r/^rgba\(.*\)$/s, "rgba(hex, alpha) — in-file colour helper, emits numerics"},
    {~r/^shiftL\(.*\)$/s, "shiftL(hex, dl) — in-file lightness shift, emits a #hex"},
    {~r/^chromeC\(\)$/, "chromeC() — in-file theme palette object of literal colours"},
    {~r/^TYPE_HEX\[[^\]]*\]$/, "TYPE_HEX[...] — literal #hex map (asserted literal below)"},
    {~r/^-?\d+(\.\d+)?$/, "numeric literal"},
    {~r/\.length$/, "a .length — a number, never text"}
  ]

  # Cycle/blowup guard for the assignment-resolution recursion.
  @max_resolve_depth 6

  describe "canonical bp-graph.js" do
    test "every HTML sink escapes server-derived operands" do
      src = read_or_refuse!(Path.join(@repo_root, @canonical))
      lines = String.split(src, "\n")
      owners = function_owners(lines)

      sinks = find_sinks(lines)

      # REFUSAL, not a vacuous pass: a scan that sees no sink has measured
      # nothing. The file is known to carry at least the tooltip and the legend.
      assert length(sinks) >= 2,
             """
             bp-graph.js HTML-sink scan found #{length(sinks)} sink(s) — expected at least 2.
             Either the widget changed shape or this scanner stopped matching it.
             Fix the scanner; do not lower the floor.
             """

      results = Enum.map(sinks, &analyse_sink(&1, lines, owners))

      violations = Enum.flat_map(results, & &1.violations)

      assert violations == [],
             """
             Unescaped server-derived operand(s) reaching innerHTML in #{@canonical}:

             #{Enum.map_join(violations, "\n", &format_violation/1)}

             Every operand concatenated into an HTML sink must be a string
             literal, an esc(...) call, or a documented presentational value.
             If one of the above is presentational, add it to @presentational
             in #{Path.relative_to(__ENV__.file, @repo_root)} WITH its ground.
             """

      # ---- positive control: the scan reached the two known sinks ------------
      tooltip = Enum.find(results, &String.contains?(&1.text, "tooltip.innerHTML = html"))
      legend = Enum.find(results, &String.contains?(&1.text, "row.innerHTML ="))

      assert tooltip,
             "scan did not reach the tooltip sink (tooltip.innerHTML = html); sinks seen: " <>
               Enum.map_join(results, " | ", &short(&1.text))

      assert legend,
             "scan did not reach the legend row sink (row.innerHTML = ...); sinks seen: " <>
               Enum.map_join(results, " | ", &short(&1.text))

      assert "node.type" in tooltip.esc_args,
             """
             The tooltip sink no longer wraps node.type in esc().
             esc() arguments observed at that sink: #{inspect(tooltip.esc_args)}
             This is the pre-#12324 stored-XSS line (bp-graph.js tooltip type row).
             """

      assert "ty" in legend.esc_args,
             """
             The legend row sink no longer wraps the type name (ty) in esc().
             esc() arguments observed at that sink: #{inspect(legend.esc_args)}
             """
    end

    test "TYPE_HEX is a literal colour map, which is what makes it presentational" do
      src = read_or_refuse!(Path.join(@repo_root, @canonical))

      [_, body] = Regex.run(~r/var TYPE_HEX = \{(.*?)\n  \};/s, src)

      values =
        body
        |> String.split("\n")
        |> Enum.map(&strip_line_comment/1)
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/:\s*(.+?),?\s*$/, line) do
            [_, v] -> [String.trim(v)]
            _ -> []
          end
        end)

      assert length(values) > 0, "TYPE_HEX parsed to zero entries — the scanner lost its shape"

      # A value is presentational when it is a #hex literal, or an identifier
      # whose own top-level declaration is a #hex literal (the map's fallback
      # entries name SLATE rather than repeating its hex).
      bad =
        Enum.reject(values, fn v ->
          Regex.match?(~r/^"#[0-9A-Fa-f]{3,8}"$/, v) or
            (Regex.match?(~r/^[A-Za-z_$][A-Za-z0-9_$]*$/, v) and
               Regex.match?(~r/\bvar\s+#{Regex.escape(v)}\s*=\s*"#[0-9A-Fa-f]{3,8}"\s*;/, src))
        end)

      assert bad == [],
             "TYPE_HEX carries a non-literal value; it is no longer presentational by " <>
               "construction and must leave @presentational: " <> inspect(bad)
    end
  end

  describe "mirror copies" do
    test "all four copies of bp-graph.js are byte-identical" do
      canonical = read_or_refuse!(Path.join(@repo_root, @canonical))
      canonical_hash = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)

      for mirror <- @mirrors do
        body = read_or_refuse!(Path.join(@repo_root, mirror))
        hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

        assert hash == canonical_hash,
               """
               #{mirror} has drifted from #{@canonical}.
                 #{@canonical}: #{canonical_hash}
                 #{mirror}: #{hash}
               The escape lock is only worth what the mirror serving the page
               carries. Re-run scripts/check-bp-graph-drift.sh.
               """
      end
    end
  end

  # ── reading ────────────────────────────────────────────────────────────────

  defp read_or_refuse!(path) do
    case File.read(path) do
      {:ok, body} ->
        if byte_size(body) < @min_bytes do
          flunk("""
          #{Path.relative_to(path, @repo_root)} read back #{byte_size(body)} bytes
          (< #{@min_bytes}). A short or empty read makes every scan below vacuous,
          so this REFUSES instead of passing.
          """)
        end

        body

      {:error, reason} ->
        flunk("""
        could not read #{path}: #{:file.format_error(reason)}
        Expected repo root #{@repo_root} (derived from __DIR__).
        """)
    end
  end

  # ── sinks ──────────────────────────────────────────────────────────────────

  @sink_rx ~r/(\.innerHTML\s*\+?=(?!=))|(insertAdjacentHTML\s*\()/

  defp find_sinks(lines) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _i} -> Regex.match?(@sink_rx, strip_line_comment(line)) end)
    |> Enum.map(fn {_line, i} -> %{index: i, text: statement_at(lines, i)} end)
  end

  defp analyse_sink(%{index: i, text: text}, lines, owners) do
    exprs =
      if String.contains?(text, "insertAdjacentHTML") do
        # drop the first argument (the position keyword), keep the HTML args
        text
        |> call_args("insertAdjacentHTML")
        |> Enum.drop(1)
      else
        [rhs_of(text)]
      end

    {violations, esc_args} =
      Enum.reduce(exprs, {[], []}, fn expr, {vs, as} ->
        {v, a} = classify(expr, i, lines, owners, 0, MapSet.new())
        {vs ++ v, as ++ a}
      end)

    %{index: i, text: text, violations: violations, esc_args: Enum.uniq(esc_args)}
  end

  # ── classification ─────────────────────────────────────────────────────────
  #
  # Returns {violations, esc_args}. An expression is split into its top-level
  # concatenation operands; a ternary contributes only its BRANCHES (the
  # condition never reaches the DOM); `||` / `&&` contribute all sides.

  defp classify(expr, line_idx, lines, owners, depth, seen) do
    expr
    |> operands()
    |> Enum.reduce({[], []}, fn op, {vs, as} ->
      {v, a} = classify_operand(op, line_idx, lines, owners, depth, seen)
      {vs ++ v, as ++ a}
    end)
  end

  defp classify_operand(op, line_idx, lines, owners, depth, seen) do
    cond do
      op == "" ->
        {[], []}

      literal_only?(op) ->
        {[], []}

      esc_call?(op) ->
        {[], [esc_arg(op)]}

      presentational?(op) ->
        {[], []}

      depth >= @max_resolve_depth ->
        {[violation(op, line_idx, lines, "resolution depth exceeded")], []}

      true ->
        base = base_identifier(op)

        cond do
          is_nil(base) ->
            {[violation(op, line_idx, lines, "not a literal, not esc()-wrapped, not declared presentational")], []}

          MapSet.member?(seen, base) ->
            {[], []}

          true ->
            case resolve(base, line_idx, lines, owners) do
              [] ->
                {[
                   violation(
                     op,
                     line_idx,
                     lines,
                     "`#{base}` has no visible assignment (a parameter or an import) and is not esc()-wrapped"
                   )
                 ], []}

              assignments ->
                seen = MapSet.put(seen, base)

                Enum.reduce(assignments, {[], []}, fn {idx, rhs}, {vs, as} ->
                  {v, a} = classify(rhs, idx, lines, owners, depth + 1, seen)
                  {vs ++ Enum.map(v, &via(&1, op)), as ++ a}
                end)
            end
        end
    end
  end

  defp violation(op, line_idx, lines, why) do
    %{
      operand: op,
      line: line_idx + 1,
      source: String.trim(Enum.at(lines, line_idx) || ""),
      why: why,
      via: []
    }
  end

  # Records the operand at the SINK that led here, so a violation found in a
  # resolved assignment still names the expression the browser renders.
  defp via(v, op), do: %{v | via: [op | v.via]}

  defp format_violation(v) do
    trail =
      case v.via do
        [] -> ""
        ops -> " (reached from the sink via " <> Enum.map_join(ops, " -> ", &"`#{&1}`") <> ")"
      end

    "  #{@canonical}:#{v.line}  operand `#{v.operand}`#{trail} — #{v.why}\n      #{short(v.source)}"
  end

  defp short(s) do
    s = s |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(s) > 140, do: String.slice(s, 0, 140) <> "…", else: s
  end

  # An operand is a literal when removing every string literal leaves nothing
  # but separators.
  defp literal_only?(op) do
    op
    |> blank_strings()
    |> String.replace(~r/[\s"'`]/, "")
    |> Kernel.==("")
  end

  defp esc_call?(op) do
    String.starts_with?(op, "esc(") and String.ends_with?(op, ")") and balanced?(op)
  end

  defp esc_arg(op), do: op |> String.slice(4..-2//1) |> String.trim()

  defp presentational?(op), do: Enum.any?(@presentational, fn {rx, _why} -> Regex.match?(rx, op) end)

  # `node.type` -> "node"; `swHex` -> "swHex"; `f(x)` -> nil (a call is not a
  # variable we can resolve, so it must be declared presentational).
  defp base_identifier(op) do
    case Regex.run(~r/^([A-Za-z_$][A-Za-z0-9_$]*)((\.[A-Za-z_$][A-Za-z0-9_$]*)*)$/, op) do
      [_, base | _] -> base
      _ -> nil
    end
  end

  # ── JS `var` scoping ───────────────────────────────────────────────────────
  #
  # Assignments visible from `line_idx` are those to the same name, earlier in
  # the file, whose innermost enclosing FUNCTION is one of line_idx's enclosing
  # functions (innermost first). Block nesting does not scope `var`, sibling
  # functions do — which is what keeps the legend's `ty` from resolving to
  # updateTooltip's numeric `ty`.

  defp resolve(name, line_idx, lines, owners) do
    {:ok, rx} =
      Regex.compile("(?<![A-Za-z0-9_$.])(?:var\\s+)?" <> Regex.escape(name) <> "\\s*\\+?=(?!=)")

    chain = Map.get(owners.chain, line_idx, [])

    candidates =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, i} ->
        i < line_idx and Regex.match?(rx, strip_line_comment(line))
      end)

    Enum.find_value(chain, [], fn owner ->
      hits =
        candidates
        |> Enum.filter(fn {_line, i} -> Map.get(owners.owner, i) == owner end)
        |> Enum.map(fn {_line, i} -> {i, rhs_of(statement_at(lines, i))} end)

      if hits == [], do: nil, else: hits
    end)
  end

  # ── statements ─────────────────────────────────────────────────────────────

  defp statement_at(lines, idx) do
    last = min(idx + 11, length(lines) - 1)

    Enum.reduce_while(idx..last//1, "", fn i, acc ->
      acc = String.trim_trailing(acc <> " " <> strip_line_comment(Enum.at(lines, i)))

      if balanced?(acc) and top_level_semicolon?(acc) do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end

  defp rhs_of(stmt) do
    toks = tokens(stmt)

    idx =
      Enum.find_value(toks, fn {i, ch, depth, mode, prev, nxt} ->
        if mode == :code and depth == 0 and ch == ?= and nxt != ?= and prev not in [?=, ?!, ?<, ?>],
          do: i,
          else: nil
      end)

    case idx do
      nil ->
        String.trim(stmt)

      i ->
        stmt
        |> String.slice((i + 1)..-1//1)
        |> String.trim()
        |> String.trim_trailing(";")
        |> String.trim()
    end
  end

  defp call_args(stmt, fun) do
    case String.split(stmt, fun <> "(", parts: 2) do
      [_, rest] ->
        rest
        |> take_until_close()
        |> split_top(?,)
        |> Enum.map(&String.trim/1)

      _ ->
        []
    end
  end

  defp take_until_close(s) do
    tokens(s)
    |> Enum.find_value(s, fn {i, ch, depth, mode, _p, _n} ->
      if mode == :code and depth == -1 and ch == ?), do: String.slice(s, 0, i), else: nil
    end)
  end

  # ── operand splitting ──────────────────────────────────────────────────────

  defp operands(expr) do
    expr
    |> String.trim()
    |> unwrap_parens()
    |> split_top(?+)
    |> Enum.flat_map(&expand_operand/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&unwrap_parens/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Ternaries contribute only their branches; `||`/`&&` contribute every side.
  defp expand_operand(op) do
    op = op |> String.trim() |> unwrap_parens()

    ternary = split_top(op, ?\?)
    ors = split_top_pair(op, "||")
    ands = split_top_pair(op, "&&")
    plus = split_top(op, ?+)

    cond do
      length(ternary) > 1 ->
        ternary
        |> Enum.drop(1)
        |> Enum.join("?")
        |> split_top(?:)
        |> Enum.flat_map(&expand_operand/1)

      length(ors) > 1 -> Enum.flat_map(ors, &expand_operand/1)
      length(ands) > 1 -> Enum.flat_map(ands, &expand_operand/1)
      length(plus) > 1 -> Enum.flat_map(plus, &expand_operand/1)
      true -> [op]
    end
  end

  defp unwrap_parens(s) do
    s = String.trim(s)

    if String.starts_with?(s, "(") and String.ends_with?(s, ")") and balanced?(String.slice(s, 1..-2//1)) do
      unwrap_parens(String.slice(s, 1..-2//1))
    else
      s
    end
  end

  defp split_top(s, ch) do
    idxs =
      tokens(s)
      |> Enum.filter(fn {_i, c, depth, mode, _p, _n} -> mode == :code and depth == 0 and c == ch end)
      |> Enum.map(fn {i, _c, _d, _m, _p, _n} -> i end)

    slice_at(s, idxs, 1)
  end

  defp split_top_pair(s, <<a::utf8, b::utf8>>) do
    idxs =
      tokens(s)
      |> Enum.filter(fn {_i, c, depth, mode, _p, n} ->
        mode == :code and depth == 0 and c == a and n == b
      end)
      |> Enum.map(fn {i, _c, _d, _m, _p, _n} -> i end)
      |> dedupe_adjacent()

    slice_at(s, idxs, 2)
  end

  defp dedupe_adjacent(idxs) do
    Enum.reduce(idxs, [], fn i, acc ->
      if acc != [] and hd(acc) == i - 1, do: acc, else: [i | acc]
    end)
    |> Enum.reverse()
  end

  defp slice_at(s, [], _w), do: [s]

  defp slice_at(s, idxs, w) do
    {parts, last} =
      Enum.reduce(idxs, {[], 0}, fn i, {acc, from} ->
        {[String.slice(s, from, i - from) | acc], i + w}
      end)

    Enum.reverse([String.slice(s, last..-1//1) | parts])
  end

  defp balanced?(s) do
    tokens(s)
    |> Enum.reduce(0, fn {_i, ch, _depth, mode, _p, _n}, acc ->
      cond do
        mode != :code -> acc
        ch in [?(, ?[, ?{] -> acc + 1
        ch in [?), ?], ?}] -> acc - 1
        true -> acc
      end
    end)
    |> Kernel.==(0)
  end

  defp top_level_semicolon?(s) do
    tokens(s)
    |> Enum.any?(fn {_i, ch, depth, mode, _p, _n} -> mode == :code and depth == 0 and ch == ?; end)
  end

  defp blank_strings(s) do
    tokens(s)
    |> Enum.reduce([], fn {_i, ch, _d, mode, _p, _n}, acc ->
      if mode == :code, do: [ch | acc], else: acc
    end)
    |> Enum.reverse()
    |> List.to_string()
  end

  # ── the tokenizer ──────────────────────────────────────────────────────────
  #
  # Emits {byte_index, char, depth_before, mode, prev_code_char, next_char} for
  # every character. `mode` is :code outside string and regex literals. Depth
  # counts (), [] and {} in code. Strings never span a line, and the input is
  # always a single logical statement or line, so state is re-derived per call.
  #
  # Regex literals matter: bp-graph.js:2044 is
  #   .replace(/[&<>"']/g, function (c) {
  # whose regex class carries an unbalanced quote AND is followed by a real
  # function brace. Treating that `"` as a string opener loses the brace and
  # every scope after it.

  defp tokens(s) do
    chars = String.to_charlist(s)
    do_tokens(chars, 0, 0, :code, nil, [])
  end

  defp do_tokens([], _i, _depth, _mode, _prev, acc), do: Enum.reverse(acc)

  defp do_tokens([?/, ?/ | _rest], _i, _depth, :code, _prev, acc), do: Enum.reverse(acc)

  defp do_tokens([ch | rest], i, depth, :code, prev, acc) do
    nxt = List.first(rest)
    tok = {i, ch, depth, :code, prev, nxt}

    cond do
      ch in [?", ?', ?`] ->
        do_tokens(rest, i + 1, depth, {:str, ch}, prev, [tok | acc])

      ch == ?/ and regex_start?(prev) ->
        do_tokens(rest, i + 1, depth, {:re, false}, prev, [tok | acc])

      ch in [?(, ?[, ?{] ->
        do_tokens(rest, i + 1, depth + 1, :code, ch, [tok | acc])

      ch in [?), ?], ?}] ->
        do_tokens(rest, i + 1, depth - 1, :code, ch, [{i, ch, depth - 1, :code, prev, nxt} | acc])

      ch in [?\s, ?\t] ->
        do_tokens(rest, i + 1, depth, :code, prev, [tok | acc])

      true ->
        do_tokens(rest, i + 1, depth, :code, ch, [tok | acc])
    end
  end

  defp do_tokens([?\\, _esc | rest], i, depth, {:str, q}, prev, acc) do
    do_tokens(rest, i + 2, depth, {:str, q}, prev, [
      {i + 1, ?x, depth, {:str, q}, prev, nil},
      {i, ?\\, depth, {:str, q}, prev, nil} | acc
    ])
  end

  defp do_tokens([ch | rest], i, depth, {:str, q}, prev, acc) when ch == q do
    do_tokens(rest, i + 1, depth, :code, q, [{i, ch, depth, {:str, q}, prev, nil} | acc])
  end

  defp do_tokens([ch | rest], i, depth, {:str, q}, prev, acc) do
    do_tokens(rest, i + 1, depth, {:str, q}, prev, [{i, ch, depth, {:str, q}, prev, nil} | acc])
  end

  defp do_tokens([?\\, _esc | rest], i, depth, {:re, cls}, prev, acc) do
    do_tokens(rest, i + 2, depth, {:re, cls}, prev, [
      {i + 1, ?x, depth, {:re, cls}, prev, nil},
      {i, ?\\, depth, {:re, cls}, prev, nil} | acc
    ])
  end

  defp do_tokens([?[ | rest], i, depth, {:re, _}, prev, acc) do
    do_tokens(rest, i + 1, depth, {:re, true}, prev, [{i, ?[, depth, {:re, true}, prev, nil} | acc])
  end

  defp do_tokens([?] | rest], i, depth, {:re, _}, prev, acc) do
    do_tokens(rest, i + 1, depth, {:re, false}, prev, [{i, ?], depth, {:re, false}, prev, nil} | acc])
  end

  defp do_tokens([?/ | rest], i, depth, {:re, false}, _prev, acc) do
    do_tokens(rest, i + 1, depth, :code, ?/, [{i, ?/, depth, {:re, false}, nil, nil} | acc])
  end

  defp do_tokens([ch | rest], i, depth, {:re, cls}, prev, acc) do
    do_tokens(rest, i + 1, depth, {:re, cls}, prev, [{i, ch, depth, {:re, cls}, prev, nil} | acc])
  end

  defp regex_start?(nil), do: true

  defp regex_start?(prev),
    do: prev in [?(, ?,, ?=, ?:, ?[, ?!, ?&, ?|, ??, ?{, ?}, ?;, ?+, ?-, ?*, ?%, ?~, ?^, ?<, ?>]

  defp strip_line_comment(nil), do: ""

  defp strip_line_comment(line) do
    case tokens(line) do
      [] -> ""
      toks -> String.slice(line, 0, length(toks))
    end
  end

  # ── function scoping map ───────────────────────────────────────────────────
  #
  # For each line: `owner` = the line that opened its innermost enclosing
  # function body, `chain` = every enclosing function opener, innermost first.

  defp function_owners(lines) do
    {owner, chain, _stack} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}, []}, fn {line, i}, {owner, chain, stack} ->
        fns = for {:function, o} <- stack, do: o
        owner = Map.put(owner, i, List.first(fns))
        chain = Map.put(chain, i, fns ++ [nil])
        {owner, chain, scan_blocks(line, i, stack)}
      end)

    %{owner: owner, chain: chain}
  end

  defp scan_blocks(line, i, stack) do
    line
    |> strip_line_comment()
    |> tokens()
    |> Enum.reduce({stack, false}, fn {idx, ch, _d, mode, _p, _n}, {stack, pending} ->
      cond do
        mode != :code ->
          {stack, pending}

        ch == ?f and function_kw_at?(line, idx) ->
          {stack, true}

        ch == ?{ ->
          {[{if(pending, do: :function, else: :block), i} | stack], false}

        ch == ?} ->
          {tl_or_empty(stack), pending}

        true ->
          {stack, pending}
      end
    end)
    |> elem(0)
  end

  defp function_kw_at?(line, idx) do
    String.slice(line, idx, 8) == "function"
  end

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_ | t]), do: t
end
