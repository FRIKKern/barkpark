defmodule BarkparkWeb.ResponseEnvelopeConventionTest do
  @moduledoc """
  THE ONE-ENVELOPE GATE (task-840853f7e84dfcb1).

  Response envelopes on the `/v1/data` read surface used to diverge per
  endpoint — `{doc}`, `{document}`, `{documents}`, `{asset}`, `{result: ...}` —
  with no rule written down and nothing stopping the next endpoint from
  inventing a sixth. Two external consumers wrote defensive clients because of
  it. The convention is now recorded in `docs/contracts/query-surface-limits.md`
  §Response envelope; this test is what keeps it true.

  ## The rule this enforces

  A **GET route under `/v1/data`** returns its payload under a top-level
  `result` key. Sibling envelope metadata (`syncTags`, `ms`, `etag`,
  `schemaHash`) rides *next to* `result`, never inside it. Non-GET routes are
  write verbs and use the `%{ok: true, ...}` receipt shape instead — the verb,
  not a hand-kept list, decides which rule applies.

  ## How the population is derived

  From `BarkparkWeb.Router.__routes__/0` — the compiled route table, not a
  regex over the router source and not a list maintained here. A new GET route
  added under `/v1/data` is in scope the moment it compiles. Each route's
  controller source is located through `module_info(:compile)[:source]`, so the
  file paths are code-derived too.

  ## Why it does not red on today's tree

  The divergence that already exists is grandfathered explicitly, by
  `{module, action}`, in `@grandfathered_reads` — never by line number, which
  drifts on any insertion. Each entry is a real defect with a named deprecation
  path in the doc. The list is asserted NON-EMPTY and asserted STALE-FREE: an
  entry naming a route that no longer exists fails, so the allowlist cannot
  quietly grow a tail of dead entries that stop discriminating.

  ## Why it cannot rot into a vacuous pass

  A checker that reads nothing passes everything — that is precisely how this
  class of divergence survived. So the test carries positive controls that must
  HIT: the population must be non-empty and contain known routes, every module
  in it must parse to at least one `json/2` call site, and the analyzer must
  report a floor of COMPLIANT sites (not merely an absence of violations). If
  the source parser breaks, those controls red before the rule does.

  A call site whose body is not a literal map cannot be checked by reading the
  source. Those are not ignored — they are enumerated in
  `@unverifiable_reads`, so a NEW indirect envelope also reds, with the verdict
  "unverifiable", which is the honest answer.
  """

  use ExUnit.Case, async: true

  @data_surface_prefix "/v1/data"

  # Envelope keys that mean "this is an error body", not a payload envelope.
  @error_keys ~w(error errors)

  # GET routes under /v1/data that do NOT wrap in `result` today. Each is a
  # known divergence with a deprecation paragraph in
  # docs/contracts/query-surface-limits.md. Keyed by {module, action} — NOT by
  # line, which drifts. Adding to this list is the review moment.
  @grandfathered_reads [
    # {ok, dataset, perspective, counts} — a READ emitting a write receipt.
    {BarkparkWeb.QueryController, :counts},
    # {revisions, count} / {revision} — the document-history surface predates
    # the `result` envelope and flattens.
    {BarkparkWeb.HistoryController, :index},
    {BarkparkWeb.HistoryController, :show},
    # {dataset, total_documents, types, recent_activity} — a flat stats shape.
    {BarkparkWeb.AnalyticsController, :index}
  ]

  # GET routes under /v1/data whose response body is built by a helper or a
  # pipeline rather than a literal map, so the source cannot be read for a
  # verdict. Listed so a NEW indirect envelope reds as unverifiable.
  @unverifiable_reads [
    # respond_json/6 -> envelope/5 or the bare `inner`, chosen by the
    # ?filterresponse=false opt-out. Serves :index and :show.
    {BarkparkWeb.QueryController, :respond_json},
    {BarkparkWeb.SearchController, :do_search},
    {BarkparkWeb.SearchController, :search_local}
  ]

  # Controllers on the /v1/data GET surface that legitimately emit no JSON body
  # at all. Listed with a staleness assertion: the moment one of these grows a
  # `json/2` call, its entry goes stale and this test reds, so the exemption
  # cannot silently start hiding a real envelope.
  @non_json_controllers [
    # Server-Sent Events stream; the body is text/event-stream, not JSON.
    BarkparkWeb.ListenController,
    # Streams NDJSON (application/x-ndjson) for the backup verb, not JSON.
    BarkparkWeb.ExportController
  ]

  # Positive-control floor: the analyzer must find at least this many call
  # sites that actually CARRY `result`. A parser that silently returns nothing
  # trips this before it trips the rule.
  @min_compliant_sites 5

  describe "the /v1/data read surface wraps in `result`" do
    test "no GET route under /v1/data emits an unwrapped envelope" do
      routes = data_surface_get_routes()

      violations =
        routes
        |> in_scope_sites()
        |> Enum.filter(&(&1.verdict in [:unwrapped, :unverifiable]))
        |> Enum.reject(&grandfathered?(&1.module, &1))

      assert violations == [],
             """
             A /v1/data GET route emits an envelope that is not `%{result: ...}`.

             #{Enum.map_join(violations, "\n", &describe_violation/1)}

             The convention is documented in
             docs/contracts/query-surface-limits.md, section "Response envelope".
             Wrap the payload in `result`, or — if the shape genuinely cannot
             change yet — add {Module, :action} to @grandfathered_reads in this
             file WITH a deprecation paragraph in that doc.
             """
    end
  end

  describe "the gate cannot pass vacuously" do
    test "the route population is non-empty and contains known /v1/data reads" do
      routes = data_surface_get_routes()

      refute routes == [],
             "no GET routes found under #{@data_surface_prefix} — the population " <>
               "derivation is broken, and an empty population passes everything"

      pairs = MapSet.new(routes, &{&1.plug, &1.plug_opts})

      for known <- [
            {BarkparkWeb.QueryController, :index},
            {BarkparkWeb.QueryController, :show},
            {BarkparkWeb.QueryController, :backlinks},
            {BarkparkWeb.QueryController, :tag_docs}
          ] do
        assert known in pairs,
               "positive control MISSED: #{inspect(known)} is a live /v1/data GET " <>
                 "route but the population derivation did not find it"
      end
    end

    test "every controller in the population parses to at least one json/2 call site" do
      for module <- data_surface_get_routes() |> Enum.map(& &1.plug) |> Enum.uniq(),
          module not in @non_json_controllers do
        sites = analyze_module(module)

        refute sites == [],
               "#{inspect(module)} parsed to ZERO json/2 call sites — either the " <>
                 "source parser is broken or the source file was not found; a " <>
                 "module that parses to nothing passes every rule"
      end
    end

    test "the non-JSON exemption list is free of stale entries" do
      modules = data_surface_get_routes() |> Enum.map(& &1.plug) |> Enum.uniq() |> MapSet.new()

      for module <- @non_json_controllers do
        assert module in modules,
               "stale non-JSON exemption #{inspect(module)}: it no longer serves " <>
                 "any /v1/data GET route"

        assert analyze_module(module) == [],
               "stale non-JSON exemption #{inspect(module)}: it now HAS json/2 call " <>
                 "sites, so it is no longer exempt. Remove the entry and let the " <>
                 "envelope rule judge it."
      end
    end

    test "the analyzer reports a floor of COMPLIANT sites, not just no violations" do
      compliant =
        data_surface_get_routes()
        |> in_scope_sites()
        |> Enum.filter(&(&1.verdict == :wrapped))

      assert length(compliant) >= @min_compliant_sites,
             "expected at least #{@min_compliant_sites} call sites carrying " <>
               "`result`, found #{length(compliant)}. The rule can only be " <>
               "trusted if the checker demonstrably SEES compliance."
    end

    test "the grandfather list is non-empty and free of stale entries" do
      refute @grandfathered_reads == [],
             "an empty grandfather list means the gate was never calibrated " <>
               "against the tree it guards"

      live = MapSet.new(data_surface_get_routes(), &{&1.plug, &1.plug_opts})

      for {module, action} <- @grandfathered_reads do
        assert {module, action} in live,
               "stale grandfather entry #{inspect({module, action})}: no such live " <>
                 "GET route under #{@data_surface_prefix}. Remove it — a waiver " <>
                 "list that accumulates dead entries stops discriminating."
      end
    end

    test "the unverifiable list is free of stale entries" do
      modules = data_surface_get_routes() |> Enum.map(& &1.plug) |> Enum.uniq() |> MapSet.new()

      for {module, fun} <- @unverifiable_reads do
        assert module in modules,
               "stale unverifiable entry #{inspect({module, fun})}: #{inspect(module)} " <>
                 "no longer serves any /v1/data GET route"

        assert Enum.any?(analyze_module(module), &(&1.function == fun)),
               "stale unverifiable entry #{inspect({module, fun})}: #{inspect(module)} " <>
                 "has no json/2 call site inside #{fun}/N any more"
      end
    end
  end

  describe "the analyzer itself" do
    test "flags a novel top-level key and names the function" do
      source = """
      defmodule Fake do
        def index(conn, _params) do
          json(conn, %{widgets: [], count: 0})
        end
      end
      """

      assert [site] = analyze_source(source, Fake)
      assert site.verdict == :unwrapped
      assert site.function == :index
      assert site.keys == ["widgets", "count"]
    end

    test "accepts a `result`-wrapped envelope with sibling metadata" do
      source = """
      defmodule Fake do
        def index(conn, _params) do
          json(conn, %{result: %{documents: [], count: 0}, syncTags: [], ms: 1})
        end
      end
      """

      assert [site] = analyze_source(source, Fake)
      assert site.verdict == :wrapped
    end

    test "ignores error bodies — they are a separate envelope" do
      source = """
      defmodule Fake do
        def index(conn, _params) do
          json(conn, %{error: "nope"})
        end
      end
      """

      assert [site] = analyze_source(source, Fake)
      assert site.verdict == :error_body
    end

    test "reports a non-literal body as unverifiable rather than passing it" do
      source = """
      defmodule Fake do
        def index(conn, _params) do
          json(conn, build_the_envelope(conn))
        end
      end
      """

      assert [site] = analyze_source(source, Fake)
      assert site.verdict == :unverifiable
    end

    test "does not read keys out of a comment" do
      source = """
      defmodule Fake do
        def index(conn, _params) do
          # historically this returned %{documents: []}
          json(conn, %{result: []})
        end
      end
      """

      assert [site] = analyze_source(source, Fake)
      assert site.verdict == :wrapped
      assert site.keys == ["result"]
    end
  end

  # ── population ────────────────────────────────────────────────────────────

  # The call sites the rule applies to.
  #
  # A LITERAL body is judged only when it sits inside a function that the
  # router actually reaches as a GET action — a POST action's `%{ok: true}`
  # receipt in the same module is not a read and is not governed here.
  #
  # A NON-LITERAL body is kept regardless of which function holds it. Building
  # the envelope through a helper is exactly how a novel shape hides from a
  # source reader, so indirection anywhere in a data-surface controller has to
  # be reviewed rather than waved through.
  defp in_scope_sites(routes) do
    routes
    |> Enum.group_by(& &1.plug, & &1.plug_opts)
    |> Enum.flat_map(fn {module, actions} ->
      get_actions = MapSet.new(actions)

      module
      |> analyze_module()
      |> Enum.filter(fn site ->
        site.verdict == :unverifiable or site.function in get_actions
      end)
    end)
  end

  defp data_surface_get_routes do
    BarkparkWeb.Router.__routes__()
    |> Enum.filter(fn route ->
      route.verb == :get and String.starts_with?(route.path, @data_surface_prefix) and
        is_atom(route.plug) and is_atom(route.plug_opts)
    end)
  end

  defp grandfathered?(module, site) do
    {module, site.function} in @grandfathered_reads or
      {module, site.function} in @unverifiable_reads
  end

  defp describe_violation(site) do
    detail =
      case site.verdict do
        :unwrapped -> "top-level keys #{inspect(site.keys)} — no `result`"
        :unverifiable -> "body is not a literal map (#{site.expression}) — cannot verify"
      end

    "  #{site.file}:#{site.line} in #{site.function}/N: #{detail}"
  end

  # ── source analysis ───────────────────────────────────────────────────────

  defp analyze_module(module) do
    case source_path(module) do
      nil ->
        flunk("cannot locate source for #{inspect(module)} — the gate cannot read it")

      path ->
        path
        |> File.read!()
        |> analyze_source(module, path)
    end
  end

  defp source_path(module) do
    with info when is_list(info) <- module.module_info(:compile),
         source when not is_nil(source) <- Keyword.get(info, :source),
         path = List.to_string(source),
         true <- File.exists?(path) do
      path
    else
      _ -> nil
    end
  end

  defp analyze_source(source, module, path \\ "(inline)") do
    stripped = strip_comments(source)
    lines = String.split(stripped, "\n")

    stripped
    |> call_sites()
    |> Enum.map(fn {offset, body} ->
      line = count_newlines(stripped, offset) + 1

      %{
        module: module,
        file: path,
        line: line,
        function: enclosing_function(lines, line),
        keys: literal_top_keys(body),
        expression: body |> String.replace(~r/\s+/, " ") |> String.slice(0, 60)
      }
    end)
    |> Enum.map(&Map.put(&1, :verdict, verdict(&1)))
  end

  defp verdict(%{keys: nil}), do: :unverifiable

  defp verdict(%{keys: keys}) do
    cond do
      Enum.any?(keys, &(&1 in @error_keys)) -> :error_body
      "result" in keys -> :wrapped
      true -> :unwrapped
    end
  end

  # Find every `json(` call and return {offset_of_open_paren, argument_source}
  # with the leading `conn,` stripped. Handles both `json(conn, x)` and the
  # piped `conn |> json(x)` form.
  defp call_sites(source) do
    ~r/\bjson\(/
    |> Regex.scan(source, return: :index)
    |> Enum.flat_map(fn [{start, len}] ->
      open = start + len - 1

      case balanced(source, open, ?(, ?)) do
        nil ->
          []

        close ->
          args = binary_part(source, open + 1, close - open - 2)

          body =
            case Regex.run(~r/\A\s*conn\s*,/, args, return: :index) do
              [{0, drop}] -> binary_part(args, drop, byte_size(args) - drop)
              _ -> args
            end

          [{start, String.trim(body)}]
      end
    end)
  end

  # Top-level keys of a literal `%{...}` that spans the WHOLE body. Anything
  # else (a helper call, a pipeline, a `Map.merge`) returns nil = unverifiable.
  defp literal_top_keys("%{" <> _ = body) do
    open = :binary.match(body, "{") |> elem(0)

    case balanced(body, open, ?{, ?}) do
      close when close == byte_size(body) ->
        body
        |> binary_part(open + 1, close - open - 2)
        |> split_top_level()
        |> Enum.map(&entry_key/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        nil
    end
  end

  defp literal_top_keys(_), do: nil

  defp entry_key(entry) do
    entry = String.trim(entry)

    cond do
      entry == "" -> nil
      match = Regex.run(~r/\A([a-z_][a-zA-Z0-9_?!]*):\s/, entry) -> Enum.at(match, 1)
      match = Regex.run(~r/\A"([^"]+)"\s*=>/, entry) -> Enum.at(match, 1)
      match = Regex.run(~r/\A:([a-z_][a-zA-Z0-9_?!]*)\s*=>/, entry) -> Enum.at(match, 1)
      # A spread (`| rest`) or a computed key: unknown, but not a claim of
      # compliance. Surface it as a key so the rule sees a non-`result` shape.
      true -> "<computed>"
    end
  end

  defp split_top_level(inner), do: split_top_level(inner, 0, [], [])

  defp split_top_level(<<>>, _depth, current, acc),
    do: Enum.reverse([IO.iodata_to_binary(Enum.reverse(current)) | acc])

  defp split_top_level(<<?", rest::binary>>, depth, current, acc) do
    {str, rest} = consume_string(rest, [?"])
    split_top_level(rest, depth, [str | current], acc)
  end

  defp split_top_level(<<c::utf8, rest::binary>>, depth, current, acc) do
    char = <<c::utf8>>

    cond do
      char in ["{", "[", "("] ->
        split_top_level(rest, depth + 1, [char | current], acc)

      char in ["}", "]", ")"] ->
        split_top_level(rest, depth - 1, [char | current], acc)

      char == "," and depth == 0 ->
        split_top_level(rest, depth, [], [
          IO.iodata_to_binary(Enum.reverse(current)) | acc
        ])

      true ->
        split_top_level(rest, depth, [char | current], acc)
    end
  end

  defp consume_string(<<?\\, c::utf8, rest::binary>>, acc),
    do: consume_string(rest, [<<c::utf8>>, "\\" | acc])

  defp consume_string(<<?", rest::binary>>, acc),
    do: {IO.iodata_to_binary(Enum.reverse(["\"" | acc])), rest}

  defp consume_string(<<c::utf8, rest::binary>>, acc),
    do: consume_string(rest, [<<c::utf8>> | acc])

  defp consume_string(<<>>, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), <<>>}

  # Byte offset just past the closer matching the opener at `at`, or nil.
  defp balanced(source, at, opener, closer) do
    do_balanced(source, at, opener, closer, 0)
  end

  defp do_balanced(source, i, opener, closer, depth) do
    if i >= byte_size(source) do
      nil
    else
      case :binary.at(source, i) do
        ?" ->
          do_balanced(source, skip_string(source, i + 1), opener, closer, depth)

        ^opener ->
          do_balanced(source, i + 1, opener, closer, depth + 1)

        ^closer ->
          if depth - 1 == 0,
            do: i + 1,
            else: do_balanced(source, i + 1, opener, closer, depth - 1)

        _ ->
          do_balanced(source, i + 1, opener, closer, depth)
      end
    end
  end

  defp skip_string(source, i) do
    cond do
      i >= byte_size(source) -> i
      :binary.at(source, i) == ?\\ -> skip_string(source, i + 2)
      :binary.at(source, i) == ?" -> i + 1
      true -> skip_string(source, i + 1)
    end
  end

  # Blank out `#` comments while preserving every byte offset, so the line
  # numbers this test reports stay the real ones. Skips `#{`, char literals
  # (`?#`) and both string forms.
  defp strip_comments(source), do: strip_comments(source, 0, [])

  defp strip_comments(source, i, acc) when i >= byte_size(source),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_comments(source, i, acc) do
    case :binary.at(source, i) do
      ?" ->
        if binary_part_safe(source, i, 3) == ~s(""") do
          case :binary.match(source, ~s("""), scope: {i + 3, byte_size(source) - i - 3}) do
            {at, _} ->
              strip_comments(source, at + 3, [binary_part(source, i, at + 3 - i) | acc])

            :nomatch ->
              strip_comments(source, byte_size(source), [
                binary_part(source, i, byte_size(source) - i) | acc
              ])
          end
        else
          j = skip_string(source, i + 1)
          strip_comments(source, j, [binary_part(source, i, j - i) | acc])
        end

      ?? ->
        strip_comments(source, i + 2, [binary_part_safe(source, i, 2) | acc])

      ?# ->
        if binary_part_safe(source, i + 1, 1) == "{" do
          strip_comments(source, i + 1, ["#" | acc])
        else
          j =
            case :binary.match(source, "\n", scope: {i, byte_size(source) - i}) do
              {at, _} -> at
              :nomatch -> byte_size(source)
            end

          strip_comments(source, j, [String.duplicate(" ", j - i) | acc])
        end

      c ->
        strip_comments(source, i + 1, [<<c>> | acc])
    end
  end

  defp binary_part_safe(source, at, len) do
    if at >= 0 and at + len <= byte_size(source), do: binary_part(source, at, len), else: ""
  end

  defp count_newlines(source, upto) do
    source
    |> binary_part(0, upto)
    |> :binary.matches("\n")
    |> length()
  end

  defp enclosing_function(lines, line) do
    lines
    |> Enum.take(line)
    |> Enum.reverse()
    |> Enum.find_value(:unknown, fn l ->
      case Regex.run(~r/\A\s*defp?\s+([a-zA-Z0-9_?!]+)/, l) do
        [_, name] -> String.to_atom(name)
        _ -> nil
      end
    end)
  end
end
