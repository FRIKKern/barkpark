defmodule BarkparkCloud.SerializerUnknownCensus.Extract do
  @moduledoc """
  The scanner behind `BarkparkCloud.SerializerUnknownExpressibilityCensusTest`.

  ## The predicate, and why it is NOT the JS one

  `__app.test.mjs`'s cch-w34-s1 census is a CONSUMER-FOLD parser: it looks for a
  reader that collapses a three-valued fact into two (`.ok` swallowed by a
  coalescing default). This one runs the other way and never reads a consumer at
  all:

      A serializer is a FINDING when it serializes a schema that HAS an
      unknown-capable column and puts NONE of that schema's unknown-capable
      columns on the wire.

  Such a payload announces a subject's state while structurally withholding the
  one axis on which "we do not know" can be said, so no consumer — JS, Go, or a
  human reading curl output — can ever express it. That is the exact shape wave
  34 measured live: `barkpark_json` shipped `health_status`/`agent_status`/
  `last_seen_at` and not `unreachable_count`, so the console could not say "we
  have missed N heartbeats" (closed by `cch-w34-s2`).

  Both sides are DERIVED from source, never enumerated:

    * SIDE A (schema): every `use Ecto.Schema` module under the declared tree.
      Its columns come from the `schema "table" do … end` block (`field`,
      `belongs_to`). A column is UNKNOWN-CAPABLE when the source itself says it
      can hold an unknown token — either its `validate_inclusion/2,3` vocabulary
      contains one (`~w()` module attribute or an inline list), or its `field`
      declaration carries `default: "<unknown token>"`. The token set is
      `#{inspect(~w(unknown unmeasured unreported undetermined))}` — a VOCABULARY
      TEST on the declared values, not a list of blessed field names.

    * SIDE B (serializer): every `def`/`defp` whose name ends in `_json` under
      the declared tree, and, within each clause, the payload-shaped map literals
      it builds. The subject schema is inferred from the struct-field reads those
      maps perform (`bp.health_status`), scored against each schema's column set.

  ## Bounds, stated so they are not mistaken for coverage

    * PAYLOAD-SHAPED means a map literal with at least `#{5}` keys. Small helper
      maps inside a serializer (a 2-key `Map.merge` argument, a nested
      `%{ok: …}`) are not payloads and folding them in would let a helper's
      private shape answer for the wire.
    * Keys whose value is a VARIABLE key (`%{status_key => status}`) are not
      literal and contribute nothing. That direction is safe here: the census
      asks whether an unknown-capable column REACHED the wire, and an invisible
      key can only ever produce a FALSE FINDING (a red to investigate), never a
      false green.
    * SUBJECT INFERENCE requires at least `#{4}` matched columns and a strict
      winner. A serializer under the floor is UNBOUND, and unbound serializers
      are COUNTED AND PRINTED, never silently dropped.
    * The read is literal source. A column put on the wire by a macro, by
      `Map.from_struct/1`, or by a route body outside a `_json` function is
      invisible to it. `payload_key_set_census_test.exs` owns the route-body
      surface; this census does not duplicate it.
  """

  @unknown_tokens ~w(unknown unmeasured unreported undetermined)
  @payload_min_keys 5
  @subject_floor 4

  @doc "The unknown tokens a declared vocabulary or default must contain."
  def unknown_tokens, do: @unknown_tokens
  def payload_min_keys, do: @payload_min_keys
  def subject_floor, do: @subject_floor

  # ── Tree declaration (criterion 4) ──────────────────────────────────────────

  @doc """
  Resolve and VALIDATE the tree this census reads. Raises — loudly, naming the
  tree and the anchor — when the tree is absent or is not the tree we mean.

  Wave 34 measured 15 `__app.test.mjs` censuses going red under a partial
  checkout because they reached sibling trees by relative path and interpreted
  "no files" as "no findings". A census that cannot see its subject must say so
  in those words; it must never report a green.
  """
  def tree_root!(root) do
    unless is_binary(root) and File.dir?(root) do
      raise """
      SERIALIZER-UNKNOWN CENSUS CANNOT READ ITS TREE.
      declared tree: #{inspect(root)}
      This census reads Elixir source under that directory. It is absent or is
      not a directory, so the census has measured NOTHING. This is a PARTIAL
      CHECKOUT (or a moved tree), not a green.
      """
    end

    anchor = Path.join(root, "web/router.ex")

    unless File.regular?(anchor) do
      raise """
      SERIALIZER-UNKNOWN CENSUS TREE IS NOT THE TREE IT DECLARES.
      declared tree: #{root}
      missing anchor: #{anchor}
      The anchor is the file that holds the serializer family this census
      exists to guard. Without it the scan would return an empty population and
      an empty population is not a green.
      """
    end

    root
  end

  defp sources(root) do
    Path.wildcard(Path.join(root, "**/*.ex")) |> Enum.sort()
  end

  defp ast(path) do
    path |> File.read!() |> Code.string_to_quoted!(columns: true)
  end

  # ── Side A: schemas and their unknown-capable columns ───────────────────────

  @doc "Every Ecto schema under `root`, with its columns and unknown-capable subset."
  def schemas(root) do
    root = tree_root!(root)

    for path <- sources(root),
        tree = ast(path),
        cols = schema_columns(tree),
        cols != [] do
      vocab = inclusion_vocab(tree, attr_vocabs(tree))
      defaults = field_defaults(tree)

      unknown =
        cols
        |> Enum.filter(fn c ->
          vocab_has_unknown?(Map.get(vocab, c, [])) or
            unknown_token?(Map.get(defaults, c))
        end)
        |> MapSet.new()

      %{
        file: Path.relative_to(path, root),
        table: schema_table(tree),
        columns: MapSet.new(cols),
        unknown_capable: unknown
      }
    end
  end

  defp vocab_has_unknown?(values), do: Enum.any?(values, &unknown_token?/1)

  defp unknown_token?(v) when is_binary(v), do: v in @unknown_tokens

  defp unknown_token?(v) when is_atom(v) and not is_nil(v),
    do: Atom.to_string(v) in @unknown_tokens

  defp unknown_token?(_), do: false

  defp schema_block(tree) do
    {_, acc} =
      Macro.prewalk(tree, nil, fn
        {:schema, _, [table, [{{:__block__, _, [:do]}, body}]]} = n, _ -> {n, {table, body}}
        {:schema, _, [table, [do: body]]} = n, _ -> {n, {table, body}}
        n, acc -> {n, acc}
      end)

    acc
  end

  defp schema_table(tree) do
    case schema_block(tree) do
      {table, _} when is_binary(table) -> table
      _ -> nil
    end
  end

  defp schema_columns(tree) do
    case schema_block(tree) do
      nil ->
        []

      {_table, body} ->
        {_, cols} =
          Macro.prewalk(body, [], fn
            {:field, _, [name | _]} = n, acc when is_atom(name) ->
              {n, [name | acc]}

            {:belongs_to, _, [name | rest]} = n, acc when is_atom(name) ->
              {n, [belongs_to_key(name, rest) | acc]}

            n, acc ->
              {n, acc}
          end)

        Enum.uniq(cols)
    end
  end

  defp belongs_to_key(name, rest) do
    opts = Enum.find(rest, &Keyword.keyword?/1) || []
    Keyword.get(opts, :foreign_key, :"#{name}_id")
  end

  # `@statuses ~w(unknown up down)` -> %{statuses: ["unknown", "up", "down"]}
  defp attr_vocabs(tree) do
    {_, acc} =
      Macro.prewalk(tree, %{}, fn
        {:@, _, [{name, _, [value]}]} = n, acc when is_atom(name) ->
          case literal_list(value) do
            [] -> {n, acc}
            vals -> {n, Map.put(acc, name, vals)}
          end

        n, acc ->
          {n, acc}
      end)

    acc
  end

  defp field_defaults(tree) do
    case schema_block(tree) do
      nil ->
        %{}

      {_table, body} ->
        {_, acc} =
          Macro.prewalk(body, %{}, fn
            {:field, _, [name | rest]} = n, acc when is_atom(name) ->
              opts = Enum.find(rest, &Keyword.keyword?/1) || []

              case Keyword.fetch(opts, :default) do
                {:ok, d} -> {n, Map.put(acc, name, d)}
                :error -> {n, acc}
              end

            n, acc ->
              {n, acc}
          end)

        acc
    end
  end

  # validate_inclusion(:field, @attr | ["a", "b"]) — piped (2 args) or explicit (3).
  defp inclusion_vocab(tree, attrs) do
    {_, acc} =
      Macro.prewalk(tree, %{}, fn
        {:validate_inclusion, _, args} = n, acc when is_list(args) and length(args) >= 2 ->
          [field, vocab | _] = Enum.take(args, -2) |> then(fn [f, v] -> [f, v] end)

          values =
            case vocab do
              {:@, _, [{a, _, _}]} -> Map.get(attrs, a, [])
              other -> literal_list(other)
            end

          if is_atom(field) and values != [] do
            {n, Map.update(acc, field, values, &Enum.uniq(&1 ++ values))}
          else
            {n, acc}
          end

        n, acc ->
          {n, acc}
      end)

    acc
  end

  # ~w(a b), ~w(a b)a, or a plain list of literals.
  defp literal_list({:sigil_w, _, [{:<<>>, _, parts}, mods]}) do
    if Enum.all?(parts, &is_binary/1) do
      words = parts |> Enum.join(" ") |> String.split(~r/\s+/, trim: true)
      if mods == ~c"a", do: Enum.map(words, &String.to_atom/1), else: words
    else
      []
    end
  end

  defp literal_list(list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) or is_atom(&1))), do: list, else: []
  end

  defp literal_list(_), do: []

  # ── Side B: serializers and the columns they put on the wire ────────────────

  @doc """
  Every `*_json` serializer under `root`, with the struct fields its
  payload-shaped map literals READ onto the wire.

  Read fields, not key names, on purpose: what a consumer can express is decided
  by whether the COLUMN reaches the wire, and a serializer is free to rename it
  (`last_deployment_json` emits `d.status` as `status`). Keying the check on the
  read field makes a rename invisible and an omission loud, which is the right
  way round for an omission census.
  """
  def serializers(root) do
    root = tree_root!(root)

    for path <- sources(root),
        tree = ast(path),
        {name, arity, line, body} <- json_clauses(tree) do
      %{
        name: "#{name}/#{arity}",
        file: Path.relative_to(path, root),
        line: line,
        payload_keys: payload_keys(body),
        reads: payload_reads(body)
      }
    end
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  defp json_clauses(tree) do
    {_, acc} =
      Macro.prewalk(tree, [], fn
        {kind, _, [head, [{{:__block__, _, [:do]}, body}]]} = n, acc
        when kind in [:def, :defp] ->
          {n, collect_clause(head, body, acc)}

        {kind, _, [head, [do: body]]} = n, acc when kind in [:def, :defp] ->
          {n, collect_clause(head, body, acc)}

        n, acc ->
          {n, acc}
      end)

    Enum.reverse(acc)
  end

  defp collect_clause(head, body, acc) do
    case fn_head(head) do
      {name, arity, line} ->
        if String.ends_with?(Atom.to_string(name), "_json"),
          do: [{name, arity, line, body} | acc],
          else: acc

      nil ->
        acc
    end
  end

  # Unwrap `when` guards — an AST match that does not is silently blind to every
  # guarded clause (the blind spot payload_key_set_census_test measured at 14
  # keys on this same tree).
  defp fn_head({:when, _, [head, _guard]}), do: fn_head(head)

  defp fn_head({name, meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args), Keyword.get(meta, :line, 0)}

  defp fn_head({name, meta, nil}) when is_atom(name), do: {name, 0, Keyword.get(meta, :line, 0)}
  defp fn_head(_), do: nil

  defp payload_maps(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {:%{}, _, pairs} = n, acc when is_list(pairs) ->
          if length(pairs) >= @payload_min_keys, do: {n, [pairs | acc]}, else: {n, acc}

        n, acc ->
          {n, acc}
      end)

    acc
  end

  defp payload_keys(body) do
    for pairs <- payload_maps(body), {k, _v} <- pairs, is_atom(k), into: MapSet.new(), do: k
  end

  defp payload_reads(body) do
    for pairs <- payload_maps(body),
        {k, v} <- pairs,
        is_atom(k),
        field = struct_read(v),
        field != nil,
        into: MapSet.new(),
        do: field
  end

  # `bp.health_status` -> :health_status. Anything else (a call, a literal, a
  # nested map) reads as "no column reached the wire through this key".
  defp struct_read({{:., _, [{var, _, ctx}, field]}, _, []})
       when is_atom(var) and is_atom(field) and (is_atom(ctx) or is_list(ctx)),
       do: field

  defp struct_read(_), do: nil

  # ── The predicate ───────────────────────────────────────────────────────────

  @doc """
  Bind each serializer to the schema it serializes, then apply the predicate.

  Returns `%{findings:, green:, unbound:, subjectless:}` — every serializer lands
  in exactly one bucket, so a shrinking findings list can never hide in a
  growing "we did not look at it" list.
  """
  def census(root) do
    schemas = schemas(root)
    serializers = serializers(root)

    Enum.reduce(serializers, %{findings: [], green: [], unbound: [], subjectless: []}, fn s,
                                                                                          acc ->
      case subject(s, schemas) do
        nil ->
          %{acc | unbound: [s.name | acc.unbound]}

        subject ->
          cond do
            MapSet.size(subject.unknown_capable) == 0 ->
              %{acc | subjectless: [{s.name, subject.file} | acc.subjectless]}

            MapSet.disjoint?(s.reads, subject.unknown_capable) ->
              %{
                acc
                | findings: [
                    %{
                      serializer: s.name,
                      at: "#{s.file}:#{s.line}",
                      subject: subject.file,
                      withheld: subject.unknown_capable |> MapSet.to_list() |> Enum.sort()
                    }
                    | acc.findings
                  ]
              }

            true ->
              %{
                acc
                | green: [
                    {s.name, subject.file,
                     MapSet.intersection(s.reads, subject.unknown_capable)
                     |> MapSet.to_list()
                     |> Enum.sort()}
                    | acc.green
                  ]
              }
          end
      end
    end)
  end

  @doc "The schema a serializer serializes: argmax matched columns, strict, floored."
  def subject(serializer, schemas) do
    scored =
      schemas
      |> Enum.map(fn sc ->
        {MapSet.size(MapSet.intersection(serializer.reads, sc.columns)), sc}
      end)
      |> Enum.sort_by(fn {n, _} -> -n end)

    case scored do
      [{n, sc} | rest] when n >= @subject_floor ->
        case rest do
          [{m, _} | _] when m == n -> nil
          _ -> sc
        end

      _ ->
        nil
    end
  end
end

defmodule BarkparkCloud.SerializerUnknownExpressibilityCensusTest do
  @moduledoc """
  cch-w34-bl-serializer-side-unknown-census — the ELIXIR half of the unknown
  census, and deliberately not a port of the JS half.

  The JS census parses a CONSUMER and looks for a fold. This one parses the
  SERIALIZER and looks for an OMISSION: a payload that serializes a schema whose
  source declares an unknown-capable column, and puts none of those columns on
  the wire. The shape the predicate was cut from is live history —
  `barkpark_json` once shipped `health_status` with no `unreachable_count`.

  ## THE CLAUSE-4 TRAP, and the answer

  The wave that deferred this row named the trap in advance: *unknown is
  fixture-authorable iff the serializer emits a field that CAN hold it, so a
  serializer-side census aimed only at fields that already exist is green by
  construction.* Every one of the tests below exists because of that sentence:

    * the predicate keys on the SCHEMA's unknown-capable columns, which exist
      whether or not any serializer emits them — the emitted key set is the
      thing under test, never the thing that defines the test;
    * `"NEGATIVE CONTROL"` runs the real extractor over a fixture tree whose
      serializer emits five real columns and no unknown-capable one, and asserts
      it is REPORTED. A census that could not see that case would be green by
      construction and this test would fail;
    * `"MUTATION"` proves both directions on that same fixture — remove the
      unknown-capable read and it is a finding, add it back and it is not;
    * serializers bound to a schema with NO unknown-capable column at all are
      counted in their own `subjectless` bucket and PRINTED, so the population
      that the predicate structurally cannot judge is visible rather than
      silently folded into the green.

  ## Mutation proof on the REAL tree (criterion 2)

  Deleting `health_status: bp.health_status` from `barkpark_json` in
  `cloud/lib/barkpark_cloud/web/router.ex` turns `barkpark_json/6` into a
  finding and reds `"the live tree has no serializer that withholds…"`;
  restoring it greens. Run pasted on the task row.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.SerializerUnknownCensus.Extract

  # ── The declared tree (criterion 4) ─────────────────────────────────────────
  @tree Path.expand("../../lib/barkpark_cloud", __DIR__)

  # Anti-vacuous floors. Growth only raises them; a drop means the scan stopped
  # seeing the surface and must be investigated, never re-baselined downward.
  @schema_floor 25
  @serializer_floor 20
  @unknown_capable_schema_floor 1

  # Serializers bound to a schema whose source declares an unknown-capable column
  # and which DO put one on the wire. Asserted non-empty: if this went to zero the
  # green verdict below would be vacuous.
  @green_floor 1

  describe "tree declaration" do
    test "the declared tree resolves and carries its anchor" do
      assert File.dir?(@tree), "declared tree absent: #{@tree}"
      assert File.regular?(Path.join(@tree, "web/router.ex"))
      assert Extract.tree_root!(@tree) == @tree
    end

    test "PARTIAL CHECKOUT: an absent tree raises loudly, never returns an empty green" do
      missing =
        Path.join(System.tmp_dir!(), "cch-w34-absent-#{System.unique_integer([:positive])}")

      refute File.exists?(missing)

      err = assert_raise RuntimeError, fn -> Extract.census(missing) end
      assert err.message =~ "CANNOT READ ITS TREE"
      assert err.message =~ missing
      assert err.message =~ "not a green"
    end

    test "PARTIAL CHECKOUT: a tree present but missing the anchor raises, naming the anchor" do
      dir = Path.join(System.tmp_dir!(), "cch-w34-partial-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "registry"))
      # A real-looking, non-empty tree — it just lost web/router.ex, exactly what
      # a sparse/partial checkout produces.
      File.write!(Path.join(dir, "registry/barkpark.ex"), "defmodule X do\nend\n")
      on_exit(fn -> File.rm_rf!(dir) end)

      err = assert_raise RuntimeError, fn -> Extract.census(dir) end
      assert err.message =~ "NOT THE TREE IT DECLARES"
      assert err.message =~ "web/router.ex"
      assert err.message =~ "an empty population is not a green"
    end
  end

  describe "positive control: the scan sees what it guards" do
    test "POPULATION: schemas, unknown-capable columns, and serializers are all non-zero" do
      schemas = Extract.schemas(@tree)
      serializers = Extract.serializers(@tree)

      with_unknown = Enum.filter(schemas, &(MapSet.size(&1.unknown_capable) > 0))

      assert length(schemas) >= @schema_floor,
             "expected >= #{@schema_floor} Ecto schemas under #{@tree}, saw #{length(schemas)}"

      assert length(serializers) >= @serializer_floor,
             "expected >= #{@serializer_floor} *_json serializers, saw #{length(serializers)}"

      assert length(with_unknown) >= @unknown_capable_schema_floor,
             "no schema in the tree declares an unknown-capable column — the predicate " <>
               "would be vacuous. Derived vocabulary tokens: " <>
               inspect(Extract.unknown_tokens())

      IO.puts("""

      ── serializer-side unknown-expressibility census: population ────────────
      declared tree ......................... #{Path.relative_to_cwd(@tree)}
      ecto schemas enumerated ............... #{length(schemas)}
      schemas w/ unknown-capable column(s) .. #{length(with_unknown)}
      *_json serializers enumerated ......... #{length(serializers)}
      unknown tokens (derivation rule) ...... #{inspect(Extract.unknown_tokens())}
      payload-shaped map floor .............. #{Extract.payload_min_keys()} keys
      subject-binding floor ................. #{Extract.subject_floor()} columns
      ─────────────────────────────────────────────────────────────────────────
      """)

      for sc <- with_unknown do
        IO.puts(
          "  unknown-capable: #{sc.file} (#{sc.table}) -> " <>
            inspect(sc.unknown_capable |> MapSet.to_list() |> Enum.sort())
        )
      end
    end

    test "POPULATION: the named serializers this row was cut from are actually seen" do
      names = Extract.serializers(@tree) |> MapSet.new(& &1.name)

      for expected <- ["barkpark_json/6", "internal_barkpark_json/3", "operator_fleet_json/1"] do
        assert MapSet.member?(names, expected),
               "the scan lost #{expected}; it is the serializer family this row exists for. " <>
                 "Saw: #{inspect(Enum.sort(MapSet.to_list(names)))}"
      end
    end
  end

  describe "the predicate on the live tree" do
    test "no serializer withholds every unknown-capable column of the schema it serializes" do
      c = Extract.census(@tree)

      assert length(c.green) >= @green_floor,
             "ZERO serializers were judged green — the verdict below would be vacuous. " <>
               "unbound=#{length(c.unbound)} subjectless=#{length(c.subjectless)}"

      IO.puts("""

      ── serializer-side unknown-expressibility census: verdict ───────────────
      findings (state on the wire, unknown withheld) .. #{length(c.findings)}
      green (an unknown-capable column reaches the wire) #{length(c.green)}
      subjectless (schema declares no unknown axis) ... #{length(c.subjectless)}
      unbound (under the #{Extract.subject_floor()}-column subject floor) ..... #{length(c.unbound)}
      ─────────────────────────────────────────────────────────────────────────
      """)

      for {name, file, carried} <- Enum.sort(c.green) do
        IO.puts("  green: #{name} (#{file}) carries #{inspect(carried)}")
      end

      assert c.findings == [],
             "serializers that put a schema's state on the wire with NO field able to " <>
               "carry unknown:\n" <> Enum.map_join(c.findings, "\n", &inspect/1)
    end

    test "the buckets partition the population (no serializer is silently dropped)" do
      c = Extract.census(@tree)
      total = Extract.serializers(@tree) |> length()

      assert length(c.findings) + length(c.green) + length(c.subjectless) + length(c.unbound) ==
               total
    end
  end

  # ── Fixture-driven controls (criteria 2 and 3) ──────────────────────────────

  @schema_fixture """
  defmodule Fx.Widget do
    use Ecto.Schema
    import Ecto.Changeset

    @health_statuses ~w(unknown up down)

    schema "widgets" do
      field :name, :string
      field :slug, :string
      field :url, :string
      field :host, :string
      field :health_status, :string, default: "unknown"
      field :last_seen_at, :utc_datetime
      belongs_to :team, Fx.Team
    end

    def changeset(w, attrs) do
      w
      |> cast(attrs, [:name, :health_status])
      |> validate_inclusion(:health_status, @health_statuses)
    end
  end
  """

  # Five real columns, ZERO unknown-capable ones. This is the clause-4 case: a
  # serializer aimed only at fields that already exist.
  @blind_serializer """
  defmodule Fx.Router do
    defp widget_json(w) do
      %{
        id: w.id,
        name: w.name,
        slug: w.slug,
        url: w.url,
        host: w.host,
        team_id: w.team_id
      }
    end
  end
  """

  @seeing_serializer """
  defmodule Fx.Router do
    defp widget_json(w) do
      %{
        id: w.id,
        name: w.name,
        slug: w.slug,
        url: w.url,
        host: w.host,
        team_id: w.team_id,
        health_status: w.health_status
      }
    end
  end
  """

  defp fixture_tree(serializer_source) do
    dir = Path.join(System.tmp_dir!(), "cch-w34-fx-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "web"))
    File.write!(Path.join(dir, "widget.ex"), @schema_fixture)
    File.write!(Path.join(dir, "web/router.ex"), serializer_source)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "clause-4 trap" do
    test "NEGATIVE CONTROL: the census is NOT vacuously green on a serializer that emits no unknown-capable field" do
      dir = fixture_tree(@blind_serializer)

      # The fixture schema really does declare an unknown axis, derived two ways.
      [sc] = Extract.schemas(dir)
      assert MapSet.member?(sc.unknown_capable, :health_status)

      c = Extract.census(dir)

      assert [finding] = c.findings,
             "the clause-4 case went UNREPORTED: #{inspect(c)}"

      assert finding.serializer == "widget_json/1"
      assert finding.withheld == [:health_status]
      assert c.green == []
    end

    test "NEGATIVE CONTROL: the vocabulary derivation, not a field-name list, is what fires" do
      # Same serializer, same columns — only the DECLARED vocabulary loses its
      # unknown token. The census must go quiet, proving it keys on the schema's
      # declared values and not on the name `health_status`.
      dir = fixture_tree(@blind_serializer)
      src = Path.join(dir, "widget.ex")

      File.write!(
        src,
        @schema_fixture
        |> String.replace("~w(unknown up down)", "~w(up down)")
        |> String.replace(~s(default: "unknown"), ~s(default: "up"))
      )

      [sc] = Extract.schemas(dir)
      assert MapSet.size(sc.unknown_capable) == 0

      c = Extract.census(dir)
      assert c.findings == []
      assert c.subjectless == [{"widget_json/1", "widget.ex"}]
    end
  end

  describe "mutation: the census can LOSE" do
    test "MUTATION: removing the unknown-capable read reds it; adding one greens it" do
      blind = Extract.census(fixture_tree(@blind_serializer))
      seeing = Extract.census(fixture_tree(@seeing_serializer))

      # Remove -> finding.
      assert [%{serializer: "widget_json/1", withheld: [:health_status]}] = blind.findings

      # Add -> no finding, and the green is EARNED by the field, not by an empty
      # population (the same serializer, the same subject, one key different).
      assert seeing.findings == []
      assert [{"widget_json/1", "widget.ex", [:health_status]}] = seeing.green
    end

    test "MUTATION: a rename of the KEY does not green it — the read is what counts" do
      renamed =
        String.replace(
          @seeing_serializer,
          "health_status: w.health_status",
          "health: w.health_status"
        )

      c = Extract.census(fixture_tree(renamed))

      assert c.findings == [],
             "a serializer that puts health_status on the wire under another key still lets a " <>
               "consumer express unknown; reporting it would be a false finding"
    end

    test "MUTATION: the subject floor refuses to guess, and says so in its own bucket" do
      thin = """
      defmodule Fx.Router do
        defp widget_json(w) do
          %{a: w.name, b: 1, c: 2, d: 3, e: 4}
        end
      end
      """

      c = Extract.census(fixture_tree(thin))
      assert c.findings == []
      assert c.unbound == ["widget_json/1"]
    end
  end
end
