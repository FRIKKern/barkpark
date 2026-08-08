defmodule BarkparkCloud.PayloadKeySetCensus.Extract do
  @moduledoc """
  The Side-A extractor: the LITERAL map keys a serializer emits, read off the
  Elixir AST (`Code.string_to_quoted!/1`), never off a regex.

  Why not a regex: a regex over `barkpark_json/4`'s base map literal sees 35
  keys. The function's actual payload is 56 — the other 21 are added by the
  `merge_*` pipeline it pipes the base through. A regex is 38% blind to the very
  thing this census exists to check, and blind SILENTLY.

  ## What it walks, and what it refuses to walk

  Bounded on purpose, in both directions:

    * a clause's RESULT expression only — either a map literal, or a pipe. The
      other statements are ignored, because `census/3` builds a `select: %{…}`
      Ecto fragment on the way to its result and folding that in would put
      four query-shape keys into a WIRE census.
    * a pipe's steps go ONE level deep. A transitive walk that follows every
      local call over-collects a helper's private shapes (`console`, `payload`,
      `status`, `steps`, `error` all leak in from `scrub_entry/2` and friends)
      and the allowlist becomes a junk drawer that hides a real divergence.

  A piped local call contributes either as a PRODUCER (its own clause result is
  a map literal — `deployment_json/1`) or as a MERGER (it `Map.put`/`Map.merge`s
  onto its first parameter — `merge_pressure/2`). Nothing else.

  ## The two measured blind spots this exists to NOT have

  1. GUARDED CLAUSES. An AST match on `{:def | :defp, _, [{name, _, args} | _]}`
     silently drops every clause whose head is `{:when, _, [head, guard]}`.
     Measured on this tree: 42 keys instead of 56 for the `barkpark_json`
     family — a 14-key loss with no error and no warning, and the 14 are every
     pressure vital, i.e. exactly the keys the census exists to check.
     `head_sig/2` unwraps `:when`; `unwrap_when: false` reproduces the blind
     version so the test can quote both counts.

  2. VARIABLE KEYS. `merge_job_status/4` writes
     `Map.merge(map, %{status_key => …, error_key => …})` where both keys are
     PARAMETERS. A literal extractor cannot see them, and four real payload keys
     (`provision_status`, `provision_error`, and their deprovision twins) would
     surface as FALSE "decoded but never emitted". So the pipe binds the call
     site's literal arguments to the callee's parameter names, and a key that is
     STILL not literal after that binding is reported as an unresolvable refusal
     citing `<file>:<line>` — never dropped.
  """

  @type payload :: %{top: MapSet.t(), nested: %{binary => MapSet.t()}, unresolvable: [binary]}

  @doc "The payload a serializer emits: top-level keys, nested literal maps, refusals."
  @spec payload(binary, {atom, non_neg_integer}, keyword) :: payload
  def payload(path, {name, arity}, opts \\ []) do
    ast = ast(path, opts)

    case clauses(ast, name, arity, opts) do
      [] ->
        %{empty() | unresolvable: ["#{path}: no clause matched #{name}/#{arity}"]}

      cs ->
        cs |> Enum.map(&clause_payload(&1, ast, path, opts)) |> merge_payloads()
    end
  end

  @doc """
  The accumulator writes of a MERGER helper, extracted with an explicit binding
  environment. Used by the test to prove the unresolvable-key refusal against
  `merge_job_status/4` itself rather than a synthetic fixture: call it with `%{}`
  and the two variable keys must be REFUSED by name and line.
  """
  @spec merger_writes(binary, {atom, non_neg_integer}, map, keyword) :: payload
  def merger_writes(path, {name, arity}, bindings, opts \\ []) do
    ast = ast(path, opts)

    case clauses(ast, name, arity, opts) do
      [] ->
        %{empty() | unresolvable: ["#{path}: no clause matched #{name}/#{arity}"]}

      cs ->
        cs
        |> Enum.map(fn {params, body} ->
          collect_acc_writes(body, path, bindings, acc_var(params))
        end)
        |> merge_payloads()
    end
  end

  @doc "The literal map keys of a module attribute defined as `@name %{…}`."
  @spec attribute_map_keys(binary, atom) :: MapSet.t()
  def attribute_map_keys(path, attr) do
    {_, acc} =
      Macro.prewalk(ast(path, []), [], fn
        {:@, _, [{^attr, _, [{:%{}, _, _} = m]}]} = node, acc -> {node, [m | acc]}
        node, acc -> {node, acc}
      end)

    case acc do
      [m] -> map_literal(m, path, %{}).top
      _ -> MapSet.new()
    end
  end

  # `walker: :broken` neuters the walker on purpose. It is the mutation the
  # anti-vacuity floor exists to catch, kept IN the extractor so the floor can be
  # proven able to lose by the suite itself rather than by a manual edit nobody
  # reruns.
  defp ast(path, opts) do
    if Keyword.get(opts, :walker, :ok) == :broken do
      Code.string_to_quoted!("nil")
    else
      path |> File.read!() |> Code.string_to_quoted!()
    end
  end

  defp clauses(ast, name, arity, opts) do
    unwrap? = Keyword.get(opts, :unwrap_when, true)

    {_, acc} =
      Macro.prewalk(ast, [], fn
        {kw, _, [head, body]} = node, acc when kw in [:def, :defp] and is_list(body) ->
          case head_sig(head, unwrap?) do
            {^name, args} ->
              if length(args) == arity, do: {node, [{args, body} | acc]}, else: {node, acc}

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # THE :when UNWRAP. Blind spot (1) in the moduledoc lives and dies here.
  defp head_sig({:when, _, [inner | _]}, true), do: head_sig(inner, true)
  defp head_sig({:when, _, _}, false), do: :no_match
  defp head_sig({name, _, args}, _) when is_atom(name) and is_list(args), do: {name, args}
  defp head_sig({name, _, nil}, _) when is_atom(name), do: {name, []}
  defp head_sig(_, _), do: :no_match

  defp clause_payload({_args, body}, ast, path, opts) do
    stmts = statements(body)
    resolve_result(List.last(stmts), assignments(stmts), ast, path, opts)
  end

  defp resolve_result({:%{}, _, _} = m, _assigns, _ast, path, _opts),
    do: map_literal(m, path, %{})

  defp resolve_result({:|>, _, _} = pipe, assigns, ast, path, opts) do
    [seed | steps] = flatten_pipe(pipe)

    seed_payload =
      case seed do
        {:%{}, _, _} = m ->
          map_literal(m, path, %{})

        {v, _, c} when is_atom(v) and is_atom(c) ->
          # A pipe seeded from a local binding (`base = %{…}` then `base |> …`).
          # A seed that is a bare PARAMETER contributes nothing on its own — the
          # first step is a producer in that shape (`d |> deployment_json()`).
          case Map.fetch(assigns, v) do
            {:ok, {:%{}, _, _} = m} -> map_literal(m, path, %{})
            _ -> empty()
          end

        _ ->
          empty()
      end

    merge_payloads([seed_payload | Enum.map(steps, &pipe_step(&1, ast, path, opts))])
  end

  defp resolve_result(other, _assigns, _ast, path, _opts) do
    %{
      empty()
      | unresolvable: [
          "#{path}:#{line_of(other)} clause result is neither a map literal nor a pipe"
        ]
    }
  end

  # `|> Map.put(:k, v)` / `|> Map.merge(%{…})` — the accumulator is the implicit
  # first argument, so the step carries only the write.
  defp pipe_step(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, meta, [key, value]},
         _ast,
         path,
         _o
       ),
       do: put_payload(key, value, meta, path, %{})

  defp pipe_step(
         {{:., _, [{:__aliases__, _, [:Map]}, :merge]}, _m, [{:%{}, _, _} = lit]},
         _a,
         p,
         _o
       ),
       do: map_literal(lit, p, %{})

  defp pipe_step({fname, meta, call_args}, ast, path, opts)
       when is_atom(fname) and is_list(call_args) do
    arity = length(call_args) + 1

    case clauses(ast, fname, arity, opts) do
      [] ->
        %{
          empty()
          | unresolvable: ["#{path}:#{meta[:line]} piped call #{fname}/#{arity} has no clause"]
        }

      cs ->
        cs
        |> Enum.map(fn {params, body} ->
          # THE BINDING that makes blind spot (2) resolvable: the call site's
          # literal atoms are bound to the callee's parameter names, so
          # `%{status_key => …}` resolves to `:provision_status`.
          bindings = literal_bindings(params, call_args)

          case List.last(statements(body)) do
            {:%{}, _, _} = m -> map_literal(m, path, bindings)
            _ -> collect_acc_writes(body, path, bindings, acc_var(params))
          end
        end)
        |> merge_payloads()
    end
  end

  defp pipe_step(other, _ast, path, _opts),
    do: %{empty() | unresolvable: ["#{path}:#{line_of(other)} pipe step is not a call"]}

  defp collect_acc_writes(body, path, bindings, acc) do
    {_, payloads} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:Map]}, :put]}, meta, [a, key, value]} = node, list ->
          if var_name(a) == acc,
            do: {node, [put_payload(key, value, meta, path, bindings) | list]},
            else: {node, list}

        {{:., _, [{:__aliases__, _, [:Map]}, :merge]}, _meta, [a, {:%{}, _, _} = m]} = node,
        list ->
          if var_name(a) == acc,
            do: {node, [map_literal(m, path, bindings) | list]},
            else: {node, list}

        node, list ->
          {node, list}
      end)

    merge_payloads(payloads)
  end

  defp put_payload(key, value, meta, path, bindings) do
    case literal_key(key, bindings) do
      {:ok, k} ->
        nested =
          case value do
            {:%{}, _, _} = m -> %{k => map_literal(m, path, bindings).top}
            _ -> %{}
          end

        %{top: MapSet.new([k]), nested: nested, unresolvable: []}

      :error ->
        %{
          empty()
          | unresolvable: [
              "#{path}:#{meta[:line]} unresolvable key in Map.put/3: #{Macro.to_string(key)}"
            ]
        }
    end
  end

  defp map_literal({:%{}, _meta, pairs}, path, bindings) do
    Enum.reduce(pairs, empty(), fn
      {k, v}, acc ->
        case literal_key(k, bindings) do
          {:ok, key} ->
            nested =
              case v do
                # A nested map literal is its OWN payload (`pressure`, `window`),
                # censused against its own Go struct. It is deliberately not
                # flattened into the parent: `pressure` the KEY and the pressure
                # BLOCK are two different contracts.
                {:%{}, _, _} = m -> Map.put(acc.nested, key, map_literal(m, path, bindings).top)
                _ -> acc.nested
              end

            %{acc | top: MapSet.put(acc.top, key), nested: nested}

          :error ->
            %{
              acc
              | unresolvable: [
                  "#{path}:#{line_of(k)} unresolvable key in map literal: #{Macro.to_string(k)}"
                  | acc.unresolvable
                ]
            }
        end

      other, acc ->
        %{
          acc
          | unresolvable: ["#{path}:#{line_of(other)} unresolvable map entry" | acc.unresolvable]
        }
    end)
  end

  defp literal_key(k, _bindings) when is_atom(k), do: {:ok, Atom.to_string(k)}
  defp literal_key(k, _bindings) when is_binary(k), do: {:ok, k}

  defp literal_key({v, _, c}, bindings) when is_atom(v) and is_atom(c) do
    case Map.fetch(bindings, v) do
      {:ok, a} when is_atom(a) -> {:ok, Atom.to_string(a)}
      {:ok, b} when is_binary(b) -> {:ok, b}
      _ -> :error
    end
  end

  defp literal_key(_, _), do: :error

  defp statements([{:do, {:__block__, _, stmts}}]), do: stmts
  defp statements([{:do, expr}]), do: [expr]
  defp statements(kw) when is_list(kw), do: [Keyword.get(kw, :do)]

  defp assignments(stmts) do
    Enum.reduce(stmts, %{}, fn
      {:=, _, [{v, _, c}, rhs]}, acc when is_atom(v) and is_atom(c) -> Map.put(acc, v, rhs)
      _, acc -> acc
    end)
  end

  defp flatten_pipe({:|>, _, [l, r]}), do: flatten_pipe(l) ++ [r]
  defp flatten_pipe(other), do: [other]

  defp literal_bindings(params, call_args) do
    params
    |> Enum.drop(1)
    |> Enum.zip(call_args)
    |> Enum.reduce(%{}, fn {p, a}, acc ->
      case {var_name(p), a} do
        {nil, _} -> acc
        {name, lit} when is_atom(lit) or is_binary(lit) -> Map.put(acc, name, lit)
        _ -> acc
      end
    end)
  end

  defp acc_var(params), do: params |> List.first() |> var_name()

  defp var_name({v, _, c}) when is_atom(v) and is_atom(c), do: v
  defp var_name(_), do: nil

  defp line_of({_, meta, _}) when is_list(meta), do: meta[:line] || 0
  defp line_of(_), do: 0

  defp empty, do: %{top: MapSet.new(), nested: %{}, unresolvable: []}

  defp merge_payloads(list) do
    Enum.reduce(list, empty(), fn p, acc ->
      %{
        top: MapSet.union(acc.top, p.top),
        nested: Map.merge(acc.nested, p.nested, fn _k, a, b -> MapSet.union(a, b) end),
        unresolvable: acc.unresolvable ++ p.unresolvable
      }
    end)
  end
end

defmodule BarkparkCloud.PayloadKeySetCensus.Go do
  @moduledoc """
  The Side-B extractor: the `json:"…"` struct tags of `internal/cloudclient/`,
  which is what actually DECODES the control plane's payloads for `bp`.

  `json.Unmarshal` drops an unmodelled key silently, so a decoder that never
  names a key cannot report it — the whole reason the UNREAD arm below is not
  observable from either side alone.
  """

  @doc "Every non-test Go source in the package, concatenated."
  @spec source(binary) :: binary
  def source(dir) do
    dir
    |> Path.join("*.go")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, "_test.go"))
    |> Enum.sort()
    |> Enum.map_join("\n", &File.read!/1)
  end

  @doc "The json tag names of one struct, or nil when the struct does not exist."
  @spec struct_tags(binary, binary) :: MapSet.t() | nil
  def struct_tags(src, name) do
    case Regex.run(~r/^type #{name} struct \{\n(.*?)\n\}$/ms, src, capture: :all_but_first) do
      [body] -> tags(body)
      _ -> nil
    end
  end

  @doc "Every json tag name in the package — the union the UNREAD arm is taken against."
  @spec all_tags(binary) :: MapSet.t()
  def all_tags(src), do: tags(src)

  defp tags(text) do
    ~r/json:"([^"]*)"/
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [t] -> t |> String.split(",") |> List.first() end)
    # `json:"-"` is an explicit DO-NOT-DECODE (DeployCensus.Raw), not a key.
    |> Enum.reject(&(&1 in ["", "-"]))
    |> MapSet.new()
  end
end

defmodule BarkparkCloud.PayloadKeySetCensus.Schema do
  @moduledoc """
  The Side-C extractor: the COLUMN names of one Ecto schema, read off the AST of
  the module that declares it — `schema "table" do … end` plus the module's
  `@primary_key` and `@timestamps_opts`.

  Side A (emitted keys) and Side B (Go json tags) share a coordinate system: a
  key is on the WIRE or it is not. A column that no serializer ever writes is in
  NEITHER set, so no arm built from those two inputs can address it. That is not
  a gap in the two arms — it is a class of hole outside their axes, and it is the
  shape of this epic's headline defect: `commit_distance`, `commit_ancestry` and
  `commit_distance_checked_at` were written hourly on prod by
  `UpdateStatusWorker` and read by nobody (dr-w24-s2 has since emitted them),
  and the census was `13 tests, 0 failures` the whole time.

  ## What it collects, and what it refuses

    * `field :name, …` — a column, by its literal atom name.
    * `belongs_to :assoc, Mod` — the FOREIGN KEY column, `foreign_key:` when the
      declaration names one, `<assoc>_id` otherwise. The association itself is
      not a column and is not collected.
    * `timestamps(…)` — expanded against `@timestamps_opts` merged with the
      call's own opts, so `updated_at: false` (PlatformDelivery is append-only)
      does NOT mint a column that does not exist, and a renamed stamp is
      collected under its real name.
    * `@primary_key` — `{:id, :binary_id, autogenerate: true}` yields `id`;
      `@primary_key false` yields none; an absent attribute yields Ecto's default
      `id`. The primary key is a column like any other and a serializer that
      omits it is omitting a column.

  `has_many` / `has_one` / `many_to_many` are IGNORED by name: they are
  associations, not columns, and collecting them would manufacture holes.

  ANYTHING ELSE inside the schema block is REFUSED by name and line rather than
  dropped. A schema whose fields are generated by a comprehension or a custom
  macro cannot be read off the AST, and the failure mode of dropping it silently
  is that the arm under-collects and reports a clean tree — the exact disease
  this file exists to not have. `schema_walker: :broken` neuters this extractor
  the same way `walker: :broken` neuters the Side-A one, so the SCHEMA-side
  anti-vacuity floor can be proven able to lose by the suite itself.
  """

  @type schema :: %{table: binary | nil, fields: MapSet.t(), unresolvable: [binary]}

  @doc "The columns one module's `schema` block declares."
  @spec fields(binary, keyword) :: schema
  def fields(path, opts \\ []) do
    ast = ast(path, opts)

    case blocks(ast) do
      [] ->
        %{table: nil, fields: MapSet.new(), unresolvable: ["#{path}: no `schema \"…\" do` block"]}

      [{table, body}] ->
        {fields, refusals} = declared(statements(body), path, ts_opts(ast))

        %{
          table: table,
          fields: MapSet.union(fields, pk_column(ast)),
          unresolvable: Enum.reverse(refusals)
        }

      many ->
        %{
          table: nil,
          fields: MapSet.new(),
          unresolvable: [
            "#{path}: #{length(many)} schema blocks in one module — the pair is ambiguous"
          ]
        }
    end
  end

  defp ast(path, opts) do
    if Keyword.get(opts, :schema_walker, :ok) == :broken do
      Code.string_to_quoted!("nil")
    else
      path |> File.read!() |> Code.string_to_quoted!()
    end
  end

  defp blocks(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:schema, _, [table, [{:do, body}]]} = node, acc when is_binary(table) ->
          {node, [{table, body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp declared(stmts, path, ts_opts) do
    Enum.reduce(stmts, {MapSet.new(), []}, fn stmt, {set, refusals} ->
      case stmt do
        {:field, _, [name | _]} when is_atom(name) ->
          {MapSet.put(set, Atom.to_string(name)), refusals}

        {:belongs_to, _, [assoc, _mod | rest]} when is_atom(assoc) ->
          {MapSet.put(set, foreign_key(assoc, rest)), refusals}

        {:timestamps, _, args} ->
          {MapSet.union(set, stamps(ts_opts, args)), refusals}

        {assoc, _, _} when assoc in [:has_many, :has_one, :many_to_many] ->
          {set, refusals}

        other ->
          {set,
           [
             "#{path}:#{line_of(other)} unreadable schema declaration: #{summary(other)}"
             | refusals
           ]}
      end
    end)
  end

  defp foreign_key(assoc, rest) do
    rest
    |> Enum.find_value(fn
      kw when is_list(kw) -> Keyword.get(kw, :foreign_key)
      _ -> nil
    end)
    |> case do
      nil -> "#{assoc}_id"
      fk when is_atom(fk) -> Atom.to_string(fk)
    end
  end

  defp stamps(ts_opts, args) do
    inline = Enum.find(args, &Keyword.keyword?/1) || []
    opts = Keyword.merge(ts_opts, inline)

    [inserted_at: :inserted_at, updated_at: :updated_at]
    |> Enum.flat_map(fn {key, default} ->
      case Keyword.get(opts, key, default) do
        false -> []
        name when is_atom(name) -> [Atom.to_string(name)]
      end
    end)
    |> MapSet.new()
  end

  defp ts_opts(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:timestamps_opts, _, [kw]}]} = node, acc when is_list(kw) -> {node, [kw | acc]}
        node, acc -> {node, acc}
      end)

    case acc do
      [kw] -> if Keyword.keyword?(kw), do: kw, else: []
      _ -> []
    end
  end

  defp pk_column(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:primary_key, _, [val]}]} = node, acc -> {node, [val | acc]}
        node, acc -> {node, acc}
      end)

    case acc do
      [false] -> MapSet.new()
      [{:{}, _, [name | _]}] when is_atom(name) -> MapSet.new([Atom.to_string(name)])
      # No `@primary_key` at all: Ecto's default is an `id` column.
      [] -> MapSet.new(["id"])
      _ -> MapSet.new(["id"])
    end
  end

  defp statements({:__block__, _, stmts}), do: stmts
  defp statements(expr), do: [expr]

  defp summary({name, _, _}) when is_atom(name), do: "#{name}/?"
  defp summary(other), do: Macro.to_string(other)

  defp line_of({_, meta, _}) when is_list(meta), do: meta[:line] || 0
  defp line_of(_), do: 0
end

defmodule BarkparkCloud.PayloadKeySetCensusTest do
  @moduledoc """
  THE PAYLOAD KEY-SET CENSUS — bidirectional, and able to lose in BOTH
  directions (deploy-reliability charter D165).

  Keys land on one side of the wire and are dropped by the other, repeatedly and
  undetectably, because neither side can see the other:

    * Elixir emits a key nobody decodes → `json.Unmarshal` drops it in silence.
    * Go declares a field nobody emits  → it decodes to its zero value forever.
      `internal/cli/cloud_deploy_census_cmd.go` branches on
      `census.TerminalFailureRate == nil`, and cloud/ emits `terminal_failure_rate`
      ZERO times — so the `bp cloud deployments` headline is PERMANENTLY on its
      "this control plane sends no terminal-row rate" arm, and no test can tell
      that from a genuinely older control plane.

  So this file reads BOTH trees and edits NEITHER. It reports; it does not
  repair. Widening a serializer to make it green would be the census fixing its
  own measurement — the shape that stops being an instrument.

  ## The two arms

    * UNREAD  — a key `cloud/` emits that matches NO `json:` tag anywhere in
      `internal/cloudclient/**`. Taken against the PACKAGE-WIDE union, not the
      paired struct, because "read by nobody" is the honest claim; a key decoded
      by a neighbouring struct is read.
    * PHANTOM — a tag the PAIRED decoder declares that its own emitter never
      emits. Per-struct on purpose: a phantom is a decoder lying about ONE
      payload, and a union would launder it away.

  ## The third arm (dr-w24-s4)

    * UNSERIALIZED — a COLUMN of the pair's declared Ecto schema that its own
      serializer never writes. Side A and Side B share one coordinate system (a
      key is on the wire or it is not), so a column no serializer emits is in
      NEITHER input set and no arm built from those two can address it. This
      epic's headline defect was exactly that shape: `commit_distance`,
      `commit_ancestry` and `commit_distance_checked_at` were written hourly on
      prod and read by nobody, and this file was `13 tests, 0 failures`
      throughout. Side C named all three — and then dr-w24-s2 EMITTED them in
      the same wave, so the arm refused until their allowlist rows were deleted
      and `@schema_unserialized_floor` fell 26 -> 23. The hole it was built to
      find is closed; 23 columns remain, `suspended_at` among them.

  A GREEN SCHEMA ARM DOES NOT MEAN THE WIRE IS CONNECTED. `PlatformDelivery`
  scores GREEN — it has a schema, a serializer that writes nine of its eleven
  columns, and two routes — and NOTHING CALLS ITS WRITER: `internal/` does not
  contain the string `platform_deliver` anywhere, so no `bp` command decodes it
  and the payload is a producer with no reader. That is a THIRD disease
  (a serialized payload nobody consumes) and none of these three arms can see
  it; the gauge for it is dr-w24-s7's `cloud/test` read of `deploy.yml`. Read a
  green Side C as "no column is stranded in the table", never as "the wire
  works".

  Both arms are pinned by a committed allowlist split into RULED RECONCILED and
  KNOWN OPEN, with a reason per entry. The split is not cosmetic: blessing
  today's divergence wholesale as "reconciled" is how a census becomes a
  changelog. Set EQUALITY is asserted in both directions, so a new divergence
  reds AND an allowlist entry that stopped diverging reds.

  ## Why this test is what enforces the dispatcher declaration

  It reads `internal/cloudclient/` through a `"../../../internal/cloudclient"`
  literal, which `scripts/cloud-path-escape-check.sh` resolves as a repo-root
  read of the Cloud suite. That ratchet FAILS unless `internal/cloudclient/**`
  is in `CLOUD_PATHS` — so a Go-only edit to `client.go` cannot skip the gate
  that checks it.
  """

  use ExUnit.Case, async: true

  alias BarkparkCloud.PayloadKeySetCensus.Extract
  alias BarkparkCloud.PayloadKeySetCensus.Go

  alias BarkparkCloud.PayloadKeySetCensus.Schema

  @router Path.expand("../../lib/barkpark_cloud/web/router.ex", __DIR__)
  @ledger Path.expand("../../lib/barkpark_cloud/deploy_ledger.ex", __DIR__)
  @cloudclient Path.expand("../../../internal/cloudclient", __DIR__)

  @barkpark_schema Path.expand("../../lib/barkpark_cloud/registry/barkpark.ex", __DIR__)
  @deployment_schema Path.expand("../../lib/barkpark_cloud/registry/deployment.ex", __DIR__)
  @platform_delivery Path.expand("../../lib/barkpark_cloud/platform_delivery.ex", __DIR__)

  # The censused pairs: one Elixir serializer, one Go decoder. `nested` selects a
  # nested literal map inside the entry's payload (`pressure`, `window`), which
  # is its own contract with its own struct.
  #
  # `schema:` is the SIDE-C declaration, and it is DECLARED PER PAIR, never
  # auto-discovered (charter D426). Pointed at the tree this would be 28 Ecto
  # schemas and 252 `field :` declarations, i.e. an allowlist nobody reads over
  # tables no wire was ever meant to carry. A pair without a `schema:` simply has
  # no Side C — `census/3`, `rate/2` and `site_row/2` are query PROJECTIONS, not
  # tables, and naming a table for them would be a guess.
  #
  # `go: nil` is likewise a declaration, not an omission: nothing in `internal/`
  # names `platform_deliveries` (measured: `grep -rn 'platform_deliver' internal/`
  # is empty), so the pair has a Side C and no Side B, and the Go-side arms skip
  # it through @wire_pairs below rather than reporting eleven false UNREAD keys.
  @pairs [
    %{
      name: "barkpark_json/4",
      file: @router,
      entry: {:barkpark_json, 4},
      schema: @barkpark_schema,
      go: "Barkpark"
    },
    %{
      name: "barkpark_json/4 pressure",
      file: @router,
      entry: {:barkpark_json, 4},
      nested: "pressure",
      go: "Pressure"
    },
    %{
      name: "site_deployment_json/3",
      file: @router,
      entry: {:site_deployment_json, 3},
      schema: @deployment_schema,
      go: "SiteDeployment"
    },
    # SIDE C ONLY. `PlatformDelivery.to_json/1` is the platform-delivery row's
    # real serializer — NOT `delivery_json/1`, which is the NOTIFICATIONS
    # delivery serializer one file over. See the MIS-PAIR tripwire below: pairing
    # this schema to that serializer manufactures ten holes out of eleven columns.
    %{
      name: "PlatformDelivery.to_json/1",
      file: @platform_delivery,
      entry: {:to_json, 1},
      schema: @platform_delivery,
      go: nil
    },
    # `also` names the OTHER emitters of one decoder's payload. The wire shape a
    # Go struct decodes is not always one function: W15 S3 emits `delivery` in
    # `Web.Router.deploy_census_json/2`, which wraps `census/3` at the ONLY place
    # the census escapes Elixir, because the delivery estimator is a second
    # grouped read and folding it into `census/3` would put a censoring policy
    # inside a counter. Without this, the census would call a key it can see on
    # the wire a PHANTOM — measuring its own bound rather than the payload.
    %{
      name: "DeployLedger.census/3",
      file: @ledger,
      entry: {:census, 3},
      also: [{@router, {:deploy_census_json, 2}}],
      go: "DeployCensus"
    },
    %{
      name: "DeployLedger.census/3 window",
      file: @ledger,
      entry: {:census, 3},
      nested: "window",
      go: "DeployCensusWindow"
    },
    %{name: "DeployLedger.rate/2", file: @ledger, entry: {:rate, 2}, go: "DeployRate"},
    # dr-w18-s2. The per-site row was an INLINE anonymous fn inside
    # `site_rows/2` — a wire shape this census structurally could not walk, so
    # `DeployCensusSite` was paired with NOTHING and a key added to (or dropped
    # from) the site row diverged from its decoder in silence. Extracting a
    # named single-clause `site_row/2` is what makes the pair possible at all.
    %{
      name: "DeployLedger.site_row/2",
      file: @ledger,
      entry: {:site_row, 2},
      go: "DeployCensusSite"
    }
  ]

  # The two WIRE arms (UNREAD, PHANTOM) and the emitted floor run over the pairs
  # that HAVE a Go decoder. This is the same set of seven pairs as before the
  # schema arm landed, so `@emitted_floor` below is untouched and still means
  # what it meant: the population the WIRE census walks.
  @wire_pairs Enum.filter(@pairs, &Map.get(&1, :go))

  # Side C runs over the pairs that declare a schema.
  @schema_pairs Enum.filter(@pairs, &Map.has_key?(&1, :schema))

  # ---------------------------------------------------------------------------
  # THE COMMITTED ALLOWLIST — `{payload, arm, key, reason}`, reason REQUIRED.
  # ---------------------------------------------------------------------------
  # RULED RECONCILED: the divergence is understood and intentional. The key has a
  # real consumer that simply is not a Go struct, or a real emitter that is not
  # one of the serializers Side A walks.
  @reconciled [
    {"barkpark_json/4", :unread, "provision_steps",
     "BROWSER-ONLY. The /new page's refresh-durable provisioning narration (dwb-14); app.js reads provision_steps/provision_console at 17 call sites. `bp` narrates provisioning off its own poll, so decoding a live step list into a Go struct would be a SECOND renderer of the same bytes."},
    {"barkpark_json/4", :unread, "provision_console",
     "BROWSER-ONLY, same reader as provision_steps above (dwb-16)."},
    {"site_deployment_json/3", :unread, "console",
     "BROWSER-ONLY. gh-5's live build console; the CLI streams its own lines from the deploy stream rather than re-rendering this list."},
    {"barkpark_json/4", :phantom, "team",
     "EMITTED, outside Side A's scope by design. /v1/barkparks Map.put's `team` onto the row in its all_teams? arm (router.ex:1941), i.e. in the ROUTE, not in the base serializer this census walks. The same one-level bound that stops the walk over-collecting a helper's private shapes also makes this key invisible — and `Barkpark.Team` is decoded and read (client_test.go:208), so the read lands."}
  ]

  # KNOWN OPEN: a real hole. Every reason names the tracker. Do NOT move a row up
  # to RECONCILED to make a red go away — the whole point of the split is that
  # "we decided this is fine" and "nobody has looked" are different sentences.
  @known_open [
    {"barkpark_json/4", :unread, "region",
     "dr-w11-payload-divergence-close — launch placement the fleet table cannot show."},
    {"barkpark_json/4", :unread, "server_type",
     "dr-w11-payload-divergence-close — launch size, same gap as region."},
    {"barkpark_json/4", :unread, "unreachable_count",
     "dr-w11-payload-divergence-close — the consecutive-miss counter behind health_status. `bp` prints the health VERDICT with none of its evidence."},
    {"barkpark_json/4", :unread, "unreachable_notification_sent",
     "dr-w11-payload-divergence-close — the once-per-outage alert latch, unread."},
    {"barkpark_json/4", :unread, "autoupdate_triggered_at",
     "dr-w11-payload-divergence-close — the in-flight rollout marker; without it a CLI status can print a stale cached verdict over a landing rollout."},
    {"barkpark_json/4", :unread, "custom_host",
     "dr-w11-payload-divergence-close — the attached platform-zone host."},
    {"barkpark_json/4", :unread, "fleet_role",
     "dr-w11-payload-divergence-close — Personal Dev Fleet group record (PDF-D61)."},
    {"barkpark_json/4", :unread, "fleet_parent_id",
     "dr-w11-payload-divergence-close — the main this box binds to."},
    {"barkpark_json/4", :unread, "fleet_token_id",
     "dr-w11-payload-divergence-close — the opaque revocation-token id (not a secret)."},
    {"barkpark_json/4 pressure", :unread, "p95_ms",
     "dr-w11-payload-divergence-close — charter D131's p95 vital. The Pressure struct's own doc comment asserts its tags are @unmetered_pressure VERBATIM; that sentence is now false by two keys."},
    {"barkpark_json/4 pressure", :unread, "req_per_s",
     "dr-w11-payload-divergence-close — charter D103's DENOMINATOR. It rides WITH err_5xx_per_s precisely so nobody prints an error share without the volume it came from — and err_5xx_per_s IS decoded while this is not, which is the exact shape D103 forbids."},
    {"site_deployment_json/3", :unread, "preview_host",
     "dr-w11-payload-divergence-close — gh-6 preview identity. SiteDeployment decodes Branch and Environment but neither preview key, so a CLI preview deploy cannot name the surface it just built."},
    {"site_deployment_json/3", :unread, "preview_url",
     "dr-w11-payload-divergence-close — the click-through target, same gap as preview_host."},
    {"site_deployment_json/3", :phantom, "port",
     "dr-w11-payload-divergence-close — declared on the deployment decoder; `port` is emitted on site_json (router.ex:10657), never on a deployment row. Decodes to 0 forever."},
    {"site_deployment_json/3", :phantom, "runtime_target",
     "dr-w11-payload-divergence-close — emitted on the box's deploy_payload (sites/deploy.ex:751), never on a deployment row. Decodes to \"\" forever."},
    {"DeployLedger.census/3", :phantom, "terminal_failure_rate",
     "dr-w16-bl-emit-terminal-failure-rate — THE EMITTER IS UNBUILT AND NOW OWNED. The row previously read \"PR #10014 carries the emitter\"; #10014 is CLOSED with mergedAt null, so that sentence pointed a reader at a dead branch and this hole had no owner at all. THE HEADLINE CASE: internal/cli/cloud_deploy_census_cmd.go:398 branches on nil here, so `bp cloud deployments` is permanently on its \"older control plane\" arm and cannot tell that from a genuinely older CP."},
    {"site_deployment_json/3", :unread, "refusal_phase",
     "dr-w15-s3-emit-the-two-corpses emits it; the Go reader is dr-w15-s3-followup-decode-refusal-phase. Start-vs-poll is legible over HTTP now and NOT yet in `bp cloud site status`. Deliberately not decoded in the same PR: this slice is fenced out of internal/cloudclient."},
    {"DeployLedger.census/3", :unread, "boundaries",
     "dr-w18-s5 — the vocabulary-boundary LIST. Emitted by census/3 as of dr-w18-s2; the Go decode and render ride the round-2 slice, which is fenced out of this file. Until then a reader of `bp cloud deployments` sees the refusal but not the instant that caused it."},
    {"DeployLedger.census/3", :unread, "coalesced_attempts",
     "dr-w18-s5 — the gauge for attempts that minted NO row, with its refusing coverage floor. Same round-2 fence as `boundaries`; the value is on the wire and in `-o json` (census.Raw is verbatim) before any struct field exists."},
    {"DeployLedger.census/3", :unread, "completeness",
     "dr-w18-s5 — the second independent count reconciled against volume + not_attempted. It reds IN THE ENVELOPE today; the Go reader must learn to print `unaccounted` rather than a balanced-looking number."},
    {"DeployLedger.census/3", :unread, "total_sites",
     "dr-w18-s5 — the population behind a site list the server cut at 50. The Go side's existing marker is over its OWN 10-row clamp and is structurally blind to the server cut."},
    {"DeployLedger.census/3", :unread, "truncated",
     "dr-w18-s5 — the server-side cut marker, twin of total_sites above."},
    {"DeployLedger.census/3", :phantom, "scope",
     "dr-w18-bl-route-added-keys-escape-the-census — A WALKER BLIND SPOT, NOT A DEAD KEY. `scope` IS emitted, but by the ROUTE (router.ex:3613 `Map.put(census, :scope, census_scope(team, scoped))`), not by `DeployLedger.census/3`, which this pair walks and which has ZERO `scope` hits. This is the SECOND instance of the identical shape (`barkpark_json/4`/`team`, blessed @reconciled at a time when it was the only one), and a second instance is the argument for fixing the walker rather than blessing the divergence again: filed as the CLOSER above. Deliberately KNOWN OPEN, not RECONCILED — nothing here is intentional divergence; the census simply cannot see where the key is written."}
  ]

  # MERGE RESOLUTION (wave-18 review, dr-w18-s2 rebased onto origin/main).
  # Two rows that existed on ONE side each are deliberately absent above, and
  # each absence is a deletion the merge OWES rather than a row lost in a
  # conflict:
  #
  #   - `{"DeployLedger.rate/2", :phantom, "basis"}` — s2 threads `basis`
  #     through `rate_basis/3` as a REAL argument, so the tag stopped
  #     diverging. Keeping the row would red the "no longer phantom" arm.
  #     s2's own commit deleted it; the rebase had to re-apply that deletion
  #     over main's copy of the row.
  #   - `{"DeployLedger.census/3", :phantom, "delivery"}` — main deleted it in
  #     W15 S3 when the census route began emitting `delivery`. s2 branched
  #     before that and still carried it. Main's deletion wins.
  #
  # `refusal_phase` (main, W15 S3) is KEPT and the five `census/3` `:unread`
  # rows (s2) are ADDED: the union, not either side.

  # MERGE-ORDER NOTE (wave-11 review, proved not predicted). Wave 11's slice
  # `dr-w11-s4-delivery-census-refuses` declares `Delivery *DeployDelivery
  # json:"delivery"` on `DeployCensus` while `census/3` — which this pair censuses
  # and which S4 is fenced out of — emits no `delivery` key, because nothing routes
  # `DeployLedger.delivery/3` yet (filed: dr-w11-s4-followup-emit-delivery-on-route).
  # That is a REAL phantom and this guard is right to catch it: verified by adding
  # the tag to `internal/cloudclient/client.go` on this branch, which reds the
  # PHANTOM arm naming `delivery`, and reverting, which greens it.
  #
  # SETTLED: the Go tag merges as PR #10192, and its `delivery` row is now in
  # @known_open above — added in that same PR, because set equality means the row
  # must not exist a moment earlier than the tag it allows. The reason string this
  # note originally scripted named only the follow-up task, which is NOT enough:
  # "every KNOWN OPEN row names its tracker" matches
  # ~r/dr-w11-payload-divergence-close|PR #\d+/, so the row's reason OPENS with
  # the PR number. A reason that greens one arm by redding another is not a fix.
  #
  # CLOSED, W15 S3. The route emits `delivery` (`Web.Router.deploy_census_json/2`),
  # so the row is DELETED — and it had to be deleted in the same commit as the
  # emit, because the "no longer phantom" arm reds on an allowlist row that
  # stopped diverging. That arm firing is what proved the deletion was owed
  # rather than optional: it is the only reason a reader ever learns that the
  # `d == nil` "NOT MEASURED" arm in `renderDeployDelivery` has stopped being the
  # only arm that executes.

  @allowlist @reconciled ++ @known_open

  # ---------------------------------------------------------------------------
  # THE ANTI-VACUITY FLOORS — the same device CLOUD_ESCAPE_MIN is for the path
  # ratchet, and for the same reason: a walker that silently stopped matching
  # reports "no divergence" and passes, which is clean-looking and completely
  # blind. Both floors are set EQUAL to the measured population, not comfortably
  # under it: the population is small enough that a slack floor would let most of
  # the extractor die unnoticed. A legitimate key change RAISES them in the same
  # commit — and the divergence assertions below red on that change anyway, so
  # the floor can never be the only thing a change has to satisfy.
  #
  # W13 S3: 100 -> 103 emitted, because `deployment_json/1` (which
  # `site_deployment_json/3` pipes through, so the walker follows it) now emits
  # the three deferral columns. The go-tag floor moves 197 -> 218: +3 for this
  # slice's decoder fields, and the other 18 are DRIFT — tags landed in
  # `internal/cloudclient` across earlier waves without the floor following
  # them, which is precisely the slack this comment forbids. Restored to
  # equality, measured, not guessed.
  # W16 S2: 103 -> 108 emitted (census/3 now names live, in_flight, cancelled,
  # residual and live_rate). The go-tag floor moves 218 -> 221, and the arithmetic
  # is the point: FIVE keys were added to DeployCensus, FOUR of them as new Go
  # fields, and the union only grew by THREE — because `in_flight` was already in
  # it, declared by the unrelated `RolloutState`. That one-tag gap IS charter
  # D260, measured on this tree rather than argued.
  #
  # W15 S3, landing AFTER W16 S2 (this branch rebased onto it): +1 `delivery`
  # (the census route's wrapper, walked through the census pair's `also`) and +1
  # `refusal_phase` on `deployment_json/1`. The post-union value is MEASURED on
  # the merged tree — floor raised to 999 and the failure's own count read back —
  # never the arithmetic 108+2, because the two slices touch the same walker and
  # only the walker can say whether their key sets overlap. The go-tag floor does
  # NOT move: this slice writes no Go, and `refusal_phase` is deliberately UNREAD
  # for now (allowlisted above) — but the go-tag floor DOES move, 221 -> 222, and
  # not because of this slice: `internal/cloudclient` is byte-identical to
  # origin/main on this branch (`git diff origin/main -- internal/cloudclient/`
  # is empty), so 222 is MAIN'S OWN population and 221 was one tag of slack that
  # landed without the floor following it. Restored to equality, measured.
  #
  # POST-UNION, measured on the rebased tree with both floors probed at 999:
  # "only 110 emitted key(s) collected" and "only 222 json tag(s) found".
  #
  # W18 S2: MEASURED by the 999-technique (set both to 999, read the two
  # refusal lines, commit the numbers they printed) — never derived from a field
  # count. The arithmetic guess is wrong in both directions here: this slice
  # adds SEVEN emitted census keys but the emitted total also gains the whole
  # `site_row/2` pair, and it adds ZERO go tags because it emits no Go at all
  # while `live`, `total_sites` and friends are either already declared or not
  # yet declared anywhere.
  #
  # AND BOTH ARE NOW `==`, NOT `>=`. origin/main committed 221 against a real
  # population of 222 — one tag of SLACK, minted by this epic's own #10474,
  # whose `json:"last_deployment"` was the one new name not already in the
  # union and passed silently because `>=` cannot see a population that GREW.
  # Equality turns "remember to bump the floor" from a convention into a red.
  #
  # W18 REVIEW, POST-REBASE: s2 measured 121 on ITS base (which predated main's
  # W15 S3 `refusal_phase` and `delivery` keys), so 121 is stale by
  # construction and under `==` it reds LOUDLY rather than passing — the
  # intended behaviour of the `>=` -> `==` change, and the reason the builder
  # stamped this as a merge hazard. RE-MEASURED here on the rebased tree by the
  # same 999-technique, never by adding s2's delta to main's number: both floors
  # set to 999, and the two refusal lines printed "123 emitted key(s)
  # collected" and "222 json tag(s) found". 123 is neither main's 110 + s2's
  # delta nor s2's 121 — the arithmetic guess would have been wrong in both
  # directions, which is exactly why the technique is measurement.
  #
  # W19 S1 (this branch merged with origin/main): the go-tag floor moves
  # 222 -> 225, MEASURED off the `==` refusal's own count ("225 json tag(s)
  # found in internal/cloudclient, floor is EXACTLY 222") on the merged tree,
  # never by arithmetic. The arithmetic guess is 222+5=227 and it is WRONG:
  # this branch declares FIVE new json tag names on the census decoders
  # (scope, team, site_ids, registered_sites, registered_sites_population),
  # but `Go.all_tags/1` is a file-GLOBAL union of NAMES, so a name already
  # declared anywhere in client.go adds nothing. Counted against
  # origin/main's copy of the file: `team` was already there (2 sites) and
  # `scope` was already there (1 site); `site_ids`, `registered_sites` and
  # `registered_sites_population` are new names. The union therefore grows by
  # THREE. Note which two rode free — it is NOT the pair a reader would
  # guess, which is the whole reason this number is measured and not derived.
  # The emitted floor does NOT move: this branch writes no serializer.
  # W24 S2 (commit distance reaches the CLI): `barkpark_json/4` gains THREE keys
  # (commit_distance, commit_ancestry, commit_distance_checked_at) and
  # `cloudclient.Barkpark` gains the three matching json tags. Every number below
  # RE-MEASURED by the 999-technique on this branch — the four refusals printed
  # "126 emitted key(s) collected", "228 json tag(s) found", "left: 45" and
  # "left: 59" — never by adding 3 to main's numbers. That the arithmetic happens
  # to agree here is a coincidence of these three names being new EVERYWHERE
  # (Go.all_tags/1 is a file-global union of NAMES, so a name already declared
  # anywhere in client.go would have ridden free, as `team` and `scope` did in
  # W19 S1). MERGE HAZARD, unchanged: these floors are `==`, so any other PR that
  # also moves them must be re-measured after this one lands, not summed with it.
  @emitted_floor 126
  @go_tag_floor 228

  # The barkpark_json family specifically, because it is where blind spot (1) was
  # measured: 59 keys with the :when unwrap, 45 without (the :when unwrap is
  # still worth exactly the same 14 vitals — the three new keys are in the base
  # literal, so they are visible to both walkers).
  @barkpark_family_keys 59
  @barkpark_family_keys_blind 45

  # ---------------------------------------------------------------------------

  defp emitted(%{file: file, entry: entry} = pair, opts \\ []) do
    payloads =
      [{file, entry} | Map.get(pair, :also, [])]
      |> Enum.map(fn {f, e} -> Extract.payload(f, e, opts) end)

    keys =
      payloads
      |> Enum.map(fn p ->
        case Map.get(pair, :nested) do
          nil -> p.top
          key -> Map.get(p.nested, key, MapSet.new())
        end
      end)
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    %{keys: keys, unresolvable: Enum.flat_map(payloads, & &1.unresolvable)}
  end

  defp total_emitted(opts) do
    Enum.reduce(@wire_pairs, 0, fn pair, acc -> acc + MapSet.size(emitted(pair, opts).keys) end)
  end

  defp allowed(payload, arm) do
    @allowlist
    |> Enum.filter(fn {p, a, _k, _r} -> p == payload and a == arm end)
    |> Enum.map(fn {_p, _a, k, _r} -> k end)
    |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # Side A can SEE what it claims to census
  # ---------------------------------------------------------------------------

  test "the extractor sees the merge_* PIPELINE, not just the base map literal" do
    p = Extract.payload(@router, {:barkpark_json, 4})

    assert p.unresolvable == []

    # The base literal is 38 keys — what a regex would report. The pipeline adds
    # the four job-status keys, the two list keys, and `pressure`.
    assert MapSet.size(p.top) == 45

    for key <- ~w(provision_status provision_error deprovision_status deprovision_error
                  provision_steps provision_console pressure) do
      assert key in p.top, "#{key} is added by the merge_* pipeline and was not collected"
    end
  end

  test "GUARDED-CLAUSE BLIND SPOT: unwrapping :when is worth 14 keys, and they are the vitals" do
    seeing = MapSet.size(emitted(barkpark()).keys) + MapSet.size(emitted(pressure()).keys)

    blind =
      MapSet.size(emitted(barkpark(), unwrap_when: false).keys) +
        MapSet.size(emitted(pressure(), unwrap_when: false).keys)

    assert seeing == @barkpark_family_keys
    assert blind == @barkpark_family_keys_blind

    # The loss is EXACTLY the pressure block: merge_pressure/2's measured clause
    # is `when is_map(payload)`, and its unguarded twin puts the attribute.
    assert "cpu_percent" in emitted(pressure()).keys
    refute "cpu_percent" in emitted(pressure(), unwrap_when: false).keys
  end

  test "ANTI-VACUITY FLOOR: a neutered walker REFUSES rather than reporting a clean tree" do
    assert total_emitted([]) == @emitted_floor,
           "#{total_emitted([])} emitted key(s) collected, floor is EXACTLY #{@emitted_floor} — " <>
             "FEWER means the EXTRACTOR is broken, not the payload shrunk: check " <>
             "Extract.clauses/4 (a new def syntax it does not match) before touching the floor. " <>
             "MORE means a serializer GREW, and if the UNREAD arm above is still green the new " <>
             "key's NAME was already in the file-global Go union (charter D260) — the key is " <>
             "LAUNDERED, not read. Find the struct that should decode it before raising this " <>
             "floor; the walker is fine."

    # And the floor can LOSE: run the identical assertion against a walker that
    # matches nothing, which is what a future unmatched syntax looks like.
    assert_raise ExUnit.AssertionError, fn ->
      broken = total_emitted(walker: :broken)

      assert broken == @emitted_floor,
             "#{broken} emitted key(s) collected, floor is EXACTLY #{@emitted_floor}"
    end

    assert total_emitted(walker: :broken) == 0
  end

  test "UNRESOLVABLE KEYS RED rather than drop — proven against merge_job_status/4 itself" do
    # WITHOUT the call site's bindings, both keys are parameters and cannot be
    # resolved. They must be REFUSED by name and line, never silently dropped —
    # dropping them is what makes four real keys look like Go phantoms.
    refusals = Extract.merger_writes(@router, {:merge_job_status, 4}, %{}).unresolvable

    assert length(refusals) >= 1
    joined = Enum.join(refusals, "\n")
    assert joined =~ "unresolvable key"
    assert joined =~ "status_key"
    assert joined =~ "router.ex:"

    # WITH them, the four real keys resolve and nothing is refused.
    bound =
      Extract.merger_writes(@router, {:merge_job_status, 4}, %{
        status_key: :provision_status,
        error_key: :provision_error
      })

    assert bound.unresolvable == []
    assert MapSet.new(["provision_status", "provision_error"]) == bound.top
  end

  test "no censused serializer carries an unresolvable key" do
    for pair <- @pairs do
      assert emitted(pair).unresolvable == [],
             "#{pair.name}: #{Enum.join(emitted(pair).unresolvable, "; ")}"
    end
  end

  test "@unmetered_pressure and merge_pressure/2's measured arm are the SAME shape" do
    # The "never beaten" arm and the "beaten" arm must be key-identical, or a
    # consumer that destructures the block crashes on exactly the boxes that have
    # not reported — the population this payload exists to describe honestly.
    assert Extract.attribute_map_keys(@router, :unmetered_pressure) == emitted(pressure()).keys
  end

  # ---------------------------------------------------------------------------
  # Side B can SEE what it claims to census
  # ---------------------------------------------------------------------------

  test "every paired Go decoder exists and carries tags" do
    src = Go.source(@cloudclient)

    for %{go: name} <- @wire_pairs do
      tags = Go.struct_tags(src, name)
      assert tags, "internal/cloudclient declares no `type #{name} struct` — the pair is dead"
      assert MapSet.size(tags) > 0, "#{name} carries no json tags"
    end

    assert MapSet.size(Go.all_tags(src)) == @go_tag_floor,
           "#{MapSet.size(Go.all_tags(src))} json tag(s) found in internal/cloudclient, " <>
             "floor is EXACTLY #{@go_tag_floor} — either the TAG SCANNER is broken (fewer) or " <>
             "a tag landed without the floor following it (more, which is how #10474 shipped " <>
             "one tag of slack under the old `>=`)."
  end

  # THE UNREAD ARM'S MEASURED BLIND SPOT (charter D260). `Go.all_tags/1` is
  # FILE-GLOBAL: it unions every json tag in internal/cloudclient, so a key whose
  # name collides with ANY unrelated struct's tag passes the UNREAD arm without a
  # single line being added to the struct that actually decodes it.
  #
  # Measured on this tree, not predicted: `RolloutState.InFlight` (client.go, the
  # autoupdate feature) already declares `json:"in_flight"`, so `census/3`
  # emitting `in_flight` would have gone GREEN through the UNREAD arm with
  # DeployCensus carrying no such field at all — the CLI would decode nothing and
  # nothing would say so. This test is the per-struct assertion the union cannot
  # make. It is deliberately NOT a general fix (that is dr-w16's own slice for
  # the collision-blind census); it pins THIS slice's keys to THIS struct.
  test "D260: the census's own cohort keys are declared on DeployCensus ITSELF, not merely somewhere in the package" do
    src = Go.source(@cloudclient)
    census_tags = Go.struct_tags(src, "DeployCensus")

    for key <- ~w(live live_rate in_flight cancelled residual) do
      assert key in census_tags,
             "`#{key}` is emitted by census/3 but is NOT a json tag on DeployCensus itself. " <>
               "The UNREAD arm cannot catch this: it compares against the FILE-GLOBAL tag " <>
               "union, so an unrelated struct declaring the same name greens it silently."
    end

    # And the collision this guard exists for is REAL, not hypothetical: prove
    # `in_flight` is declared by a second, unrelated struct too. If this ever
    # fails, the blind spot has moved and the comment above is stale.
    assert "in_flight" in Go.struct_tags(src, "RolloutState"),
           "RolloutState no longer declares in_flight — re-derive D260's blind spot before " <>
             "trusting the UNREAD arm on any cohort key."
  end

  # D260'S BLIND SPOT, ONE STRUCT OVER (dr-w19-s7). The guard above pins the
  # cohort keys to `DeployCensus` — the FLEET struct — and `site_row/2` emits its
  # own per-site `live`. Because `live` is already a tag on DeployCensus, the
  # FILE-GLOBAL union greened `DeployCensusSite` while it carried six fields and
  # no Live at all: the wire's per-site success decoded to nothing, and no test
  # in this file could say so. Measured, not predicted — a real 200 on a team
  # credential returned {"failed":1,"live":109,"deferred":325,"volume":435}.
  test "D260: site_row/2's `live` is declared on DeployCensusSite ITSELF, not merely on DeployCensus" do
    src = Go.source(@cloudclient)

    assert "live" in Go.struct_tags(src, "DeployCensusSite"),
           "`live` is emitted by site_row/2 but is NOT a json tag on DeployCensusSite itself. " <>
             "The UNREAD arm cannot catch this: `live` is already a tag on DeployCensus, so the " <>
             "FILE-GLOBAL union greens the per-site key while nothing decodes it."

    # The collision is REAL, not hypothetical: the fleet struct declares the same
    # name, which is exactly what makes the union blind here.
    assert "live" in Go.struct_tags(src, "DeployCensus"),
           "DeployCensus no longer declares `live` — re-derive this blind spot before trusting " <>
             "the UNREAD arm on any per-site key."
  end

  # ---------------------------------------------------------------------------
  # The two arms
  # ---------------------------------------------------------------------------

  test "UNREAD: every emitted key is decoded somewhere in internal/cloudclient, or allowlisted" do
    all = Go.all_tags(Go.source(@cloudclient))

    for pair <- @wire_pairs do
      actual = MapSet.difference(emitted(pair).keys, all)
      expected = allowed(pair.name, :unread)

      assert actual == expected, """
      #{pair.name}: the UNREAD set moved.

        newly unread (emitted, decoded by NOBODY — declare a json tag, or allowlist it):
          #{fmt(MapSet.difference(actual, expected))}
        no longer unread (allowlisted but now decoded — DELETE the allowlist row):
          #{fmt(MapSet.difference(expected, actual))}
      """
    end
  end

  test "PHANTOM: every decoded key is emitted by its paired serializer, or allowlisted" do
    src = Go.source(@cloudclient)

    for pair <- @wire_pairs do
      actual = MapSet.difference(Go.struct_tags(src, pair.go), emitted(pair).keys)
      expected = allowed(pair.name, :phantom)

      assert actual == expected, """
      #{pair.name} -> #{pair.go}: the PHANTOM set moved.

        new phantom (declared by Go, emitted by nobody — it decodes to a zero value forever):
          #{fmt(MapSet.difference(actual, expected))}
        no longer phantom (allowlisted but now emitted — DELETE the allowlist row):
          #{fmt(MapSet.difference(expected, actual))}
      """
    end
  end

  # ---------------------------------------------------------------------------
  # SIDE C — the third arm: a column no wire ever carries
  # ---------------------------------------------------------------------------
  # `{payload, key, reason}` — one arm, so no arm column. Reason REQUIRED and it
  # must name a tracker, exactly like @known_open above.
  #
  # THE *_encrypted CLASS IS ONE RULE, NOT FIVE ROWS (`credential_class/1`
  # below): a column whose name ends in `_encrypted` holds a credential and must
  # never reach a wire, and writing that ruling out once per column would be five
  # copies of one sentence that drift apart — and, worse, would make ADDING a
  # sixth encrypted column a red that a builder clears by pasting the sentence
  # again. The rule is applied over the schema's OWN fields, so if an
  # `*_encrypted` column ever becomes EMITTED the set-equality below reds
  # ("no longer unserialized") rather than blessing a credential onto the wire.
  #
  # THE THREE COMMIT_* ROWS THAT USED TO OPEN THIS LIST ARE GONE, and their
  # absence is the arm's first receipt. `commit_distance`, `commit_ancestry` and
  # `commit_distance_checked_at` were the headline hole this arm was built to
  # name; dr-w24-s2 wired all three into `barkpark_json/4` in the SAME WAVE, so
  # the rows died in the same commit as the emit, exactly as the arm's own
  # refusal text demands ("no longer unserialized … DELETE the allowlist row").
  # The arm closed a hole and then deleted its own paperwork; that is what it is
  # supposed to do.
  @schema_allowlist [
    {"barkpark_json/4", "template",
     "RULED — bootstrap custody. The schema comment states these ride the Vault encrypt-at-rest seam and are NEVER serialized in barkpark_json; they are revealed only through the team-admin-gated /bootstrap route."},
    {"barkpark_json/4", "bootstrap_workspace",
     "RULED — bootstrap custody, same /bootstrap route and same ruling as template above."},
    {"barkpark_json/4", "bootstrap_project",
     "RULED — bootstrap custody, same /bootstrap route and same ruling as template above."},
    {"barkpark_json/4", "bootstrap_dataset",
     "RULED — bootstrap custody, same /bootstrap route; its two token siblings need no row at all, they are carried by the *_encrypted class rule."},
    {"barkpark_json/4", "vercel_project_id",
     "RULED — zero-paste Vercel handoff (task-4e4a53b101a97051). The schema comment says plainly it is NEVER serialized in barkpark_json and is revealed through the team-admin-gated claim route instead."},
    {"barkpark_json/4", "vercel_deploy_url",
     "RULED — same custody as vercel_project_id above; display state for the claim page, not a fleet-row vital."},
    {"barkpark_json/4", "vercel_claim_minted_at",
     "RULED — the 24h-expiry stamp of the ENCRYPTED claim code. Emitting it without the code it dates would be a countdown to nothing."},
    {"barkpark_json/4", "suspended_at",
     "dr-w24-s4 KNOWN OPEN — the billing-suspension stamp. `suspended` and `suspended_reason` ARE emitted, so `bp` can say a box is suspended and why but never SINCE WHEN — the one field that separates a fresh suspension from a month-old one."},
    {"barkpark_json/4", "updated_at",
     "RULED — deliberately off the wire: it moves on every hourly status poll, so a renderer diffing it would report 'something changed' about a box nothing happened to. `inserted_at` IS emitted, under its wire name created_at."},
    {"site_deployment_json/3", "claim_worker",
     "dr-w24-s4 KNOWN OPEN — which builder claimed this deployment. Lease bookkeeping today; it becomes a wire vital the moment two builders can race, which is the failure mode this epic exists for."},
    {"site_deployment_json/3", "claimed_at",
     "dr-w24-s4 KNOWN OPEN — the lease stamp, twin of claim_worker. A build stuck in `building` cannot be told from a fresh one without it."},
    {"site_deployment_json/3", "claim_epoch",
     "dr-w24-s4 KNOWN OPEN — the CAS counter of the claim; same lease bookkeeping as its two twins above."},
    {"site_deployment_json/3", "coalesced_attempts",
     "dr-w18-s5 KNOWN OPEN, ONE ROW DOWN. The census AGGREGATE of this column is already an @known_open :unread row; the per-deployment COLUMN is unserialized as well, so a single site's row cannot show how many publishes joined the build it is looking at."},
    {"site_deployment_json/3", "coalesced_last_at",
     "dr-w18-s5 KNOWN OPEN — the last coalesced attempt's stamp, twin of coalesced_attempts."},
    {"site_deployment_json/3", "delivery_id",
     "RULED — GitHub's X-GitHub-Delivery header (dwb-18). A webhook idempotency key, never a fact about the build; it exists so a redelivered push mints at most one Deployment."},
    {"site_deployment_json/3", "preview_slug",
     "RULED — the sanitized DNS LABEL behind preview_host (gh-6). `preview_host` is the full name a reader can click, and it is on the wire (allowlisted UNREAD, one arm over); the label is the host minus the base domain and carries nothing the host does not."},
    {"PlatformDelivery.to_json/1", "id",
     "dr-w24-s4 KNOWN OPEN — the row's own identity, absent from to_json/1. Nothing can reference one specific delivery today; the slice that gives this payload a READER should give it an id."},
    {"PlatformDelivery.to_json/1", "inserted_at",
     "RULED — emitted under its wire name `recorded_at`. A rename, not a hole, exactly like barkpark_json's created_at; the census compares NAMES, so a rename must be ruled once rather than chased."}
  ]

  # THE SIDE-C FLOORS, MEASURED BY THE 999-TECHNIQUE (set both to 999, read the
  # two refusal lines, commit the numbers they printed) — never derived by
  # arithmetic. This file's moduledoc records four separate occasions where the
  # arithmetic guess was wrong in BOTH directions, and Side C is worse than the
  # wire arms for guessing: a pair's schema and its serializer overlap by an
  # amount no field count predicts.
  #
  #   * @schema_field_floor      — every column Side C COLLECTS, over the three
  #     schema-declaring pairs. It is the SCHEMA-side anti-vacuity floor, and it
  #     is the one the serializer-side `walker: :broken` device cannot provide:
  #     neutering the serializer makes the unserialized count EXPLODE (loud),
  #     while a schema whose fields stop being collected makes it COLLAPSE toward
  #     zero — a clean-looking green over a table nobody measured any more. A
  #     macro-generated schema is the live version of that mutation.
  #   * @schema_unserialized_floor — the columns with no emitted key, allowlist
  #     included. It moves DOWN when a hole is closed, which is the point: wiring
  #     one commit_* column into `barkpark_json/4` moves it and forces the
  #     allowlist row's deletion in the SAME commit.
  #
  # @schema_unserialized_floor MOVED 26 -> 23 when dr-w24-s2's three commit_*
  # keys landed in `barkpark_json/4` — DOWN, because a hole closed. Re-measured
  # by the file's own refusal line ("23 unserialized column(s), floor is EXACTLY
  # 26"), not by subtracting three.
  @schema_field_floor 95
  @schema_unserialized_floor 23

  # THE MIS-PAIR TRIPWIRE. Name-guessing a serializer is a live hazard:
  # `delivery_json/1` (router.ex:9809) is the NOTIFICATIONS delivery serializer,
  # not the platform-delivery one, and pairing it to `platform_deliveries`
  # manufactured TEN false holes out of ELEVEN columns — an allowlist of pure
  # noise that would then have to be maintained. A pair whose schema and
  # serializer barely intersect is a MIS-PAIR, not a wall of holes, and it must
  # say so. Measured on this tree: the three real pairs overlap by 35, 25 and 9
  # columns; the mis-pair overlaps by 2 (`id`, `inserted_at` — the two names
  # every Ecto row shares, which is exactly why a small floor is not enough).
  @mispair_min_overlap 5

  defp schema_fields(pair, opts), do: Schema.fields(pair.schema, opts)

  # `extra_emitted:` is the FIX-direction mutation: it runs the real assertion
  # against a payload that emits one more key, which is what landing the fix
  # looks like from Side C.
  defp emitted_keys(pair, opts) do
    MapSet.union(emitted(pair, opts).keys, MapSet.new(Keyword.get(opts, :extra_emitted, [])))
  end

  defp unserialized(pair, opts \\ []) do
    MapSet.difference(schema_fields(pair, opts).fields, emitted_keys(pair, opts))
  end

  defp total_unserialized(opts) do
    Enum.reduce(@schema_pairs, 0, fn p, acc -> acc + MapSet.size(unserialized(p, opts)) end)
  end

  defp total_schema_fields(opts) do
    Enum.reduce(@schema_pairs, 0, fn p, acc ->
      acc + MapSet.size(schema_fields(p, opts).fields)
    end)
  end

  defp credential_class(fields) do
    fields |> Enum.filter(&String.ends_with?(&1, "_encrypted")) |> MapSet.new()
  end

  defp allowed_unserialized(pair, fields) do
    explicit =
      @schema_allowlist
      |> Enum.filter(fn {p, _k, _r} -> p == pair.name end)
      |> Enum.map(fn {_p, k, _r} -> k end)
      |> MapSet.new()

    MapSet.union(explicit, credential_class(fields))
  end

  defp assert_paired!(pair, opts) do
    fields = schema_fields(pair, opts).fields
    shared = MapSet.intersection(fields, emitted_keys(pair, opts))

    assert MapSet.size(shared) >= @mispair_min_overlap, """
    #{pair.name} is MIS-PAIRED with #{pair.schema}.

      the schema declares #{MapSet.size(fields)} column(s); the serializer and the
      schema share only #{MapSet.size(shared)} name(s): #{fmt(shared)}

    Do NOT allowlist the difference — a pair this far apart is not a payload with
    holes, it is the wrong serializer. `delivery_json/1` is the NOTIFICATIONS
    serializer; `platform_deliveries` is written by `PlatformDelivery.to_json/1`.
    """
  end

  defp assert_schema_arm!(pair, opts) do
    assert_paired!(pair, opts)

    fields = schema_fields(pair, opts).fields
    actual = MapSet.difference(fields, emitted_keys(pair, opts))
    expected = allowed_unserialized(pair, fields)

    assert actual == expected, """
    #{pair.name} <- #{pair.schema}: the UNSERIALIZED set moved.

      newly unserialized (a column no serializer writes — emit it, or allowlist it
      with a reason that names its tracker):
        #{fmt(MapSet.difference(actual, expected))}
      no longer unserialized (allowlisted but now emitted — DELETE the allowlist
      row in the SAME commit as the emit):
        #{fmt(MapSet.difference(expected, actual))}
    """
  end

  test "UNSERIALIZED: every column of a paired schema is emitted by its serializer, or allowlisted" do
    for pair <- @schema_pairs, do: assert_schema_arm!(pair, [])
  end

  test "SIDE C's HEADLINE HOLE IS CLOSED — the three commit_* columns reach the wire" do
    # The arm was built to name `commit_distance`, `commit_ancestry` and
    # `commit_distance_checked_at`: written hourly on prod by UpdateStatusWorker,
    # read by nobody, and INVISIBLE to both wire arms (not emitted, so UNREAD
    # could not see them; not declared in Go, so PHANTOM could not either).
    # dr-w24-s2 emitted all three in this same wave. This test is the receipt,
    # and it is a TRIPWIRE, not a memorial: delete the emission and it reds.
    emitted_keys = emitted(barkpark()).keys
    unserialized_now = unserialized(barkpark())
    go_tags = Go.all_tags(Go.source(@cloudclient))

    for column <- ~w(commit_distance commit_ancestry commit_distance_checked_at) do
      assert column in emitted_keys,
             "`#{column}` left the wire. It is written hourly by UpdateStatusWorker and was " <>
               "unreadable by any operator until dr-w24-s2 emitted it; re-emit it, or " <>
               "re-open its @schema_allowlist row with a reason."

      refute column in unserialized_now
      assert column in go_tags, "`#{column}` is emitted but no Go struct decodes it any more"
    end
  end

  test "SIDE C STILL NAMES A HOLE THE WIRE ARMS STRUCTURALLY CANNOT SEE" do
    # The arm is only worth its floors if it is still measuring something. A
    # column no serializer writes is in NEITHER wire input set, so neither UNREAD
    # nor PHANTOM can address it — `suspended_at` is the live example: `bp` can
    # say a box is suspended and why, but never SINCE WHEN.
    column = "suspended_at"

    assert column in unserialized(barkpark()),
           "`#{column}` is no longer unserialized — DELETE its @schema_allowlist row, the hole " <>
             "closed. If Side C has run out of holes entirely, say so deliberately rather than " <>
             "letting this test rot into a tautology."

    refute column in emitted(barkpark()).keys
    refute column in Go.all_tags(Go.source(@cloudclient))
  end

  test "SCHEMA-SIDE ANTI-VACUITY FLOOR: an extractor that stops collecting columns REFUSES" do
    assert total_schema_fields([]) == @schema_field_floor,
           "#{total_schema_fields([])} schema column(s) collected, floor is EXACTLY " <>
             "#{@schema_field_floor} — the SCHEMA extractor is broken (fewer: a declaration " <>
             "shape it does not match, e.g. a macro-generated field) or a column landed " <>
             "without the floor following it (more). Check Schema.declared/3 before touching " <>
             "the floor."

    # The mutation this floor exists for. It is NOT the serializer-side
    # `walker: :broken`: that one makes the unserialized count EXPLODE, while a
    # schema that stops being collected makes every arm go quietly green.
    assert_raise ExUnit.AssertionError, fn ->
      blind = total_schema_fields(schema_walker: :broken)
      assert blind == @schema_field_floor, "#{blind} schema column(s) collected"
    end

    assert total_schema_fields(schema_walker: :broken) == 0

    # And the disease in full: with the schema side neutered, EVERY pair's arm
    # goes green over a table nobody measured any more.
    for pair <- @schema_pairs do
      assert MapSet.size(unserialized(pair, schema_walker: :broken)) == 0
    end
  end

  test "SERIALIZER-SIDE ANTI-VACUITY FLOOR: the unserialized count is `==`, and it can lose" do
    assert total_unserialized([]) == @schema_unserialized_floor,
           "#{total_unserialized([])} unserialized column(s), floor is EXACTLY " <>
             "#{@schema_unserialized_floor} — measure it with the 999-technique, never derive " <>
             "it. `==`, never `>=`: this file's own history records a `>=` floor shipping one " <>
             "tag of slack silently."

    assert_raise ExUnit.AssertionError, fn ->
      broken = total_unserialized(walker: :broken)
      assert broken == @schema_unserialized_floor, "#{broken} unserialized column(s)"
    end

    # A neutered serializer makes EVERY column unserialized — the floor moves to
    # the full schema population, loudly, in the opposite direction from the
    # schema-side mutation above.
    assert total_unserialized(walker: :broken) == @schema_field_floor
  end

  test "THE FIX DIRECTION REDS TOO: emitting an allowlisted column forces its row's deletion" do
    # Not hypothetical and not a synthetic fixture: this runs the REAL assertion
    # over the REAL payload plus one key, which is exactly what wiring
    # `suspended_at` into `barkpark_json/4` would look like from Side C. The
    # allowlist row must die in the same commit as the emit — and it already
    # happened for real once in this wave: dr-w24-s2 emitted the three commit_*
    # columns and this arm refused until their three rows were deleted.
    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_schema_arm!(barkpark(), extra_emitted: ["suspended_at"])
      end

    message = Exception.message(error)
    assert message =~ "no longer unserialized"
    assert message =~ "suspended_at"
    assert message =~ "DELETE the allowlist"
  end

  test "MIS-PAIR TRIPWIRE: a wrongly paired serializer reds as MIS-PAIRED, not as ten holes" do
    # `delivery_json/1` is the NOTIFICATIONS delivery serializer. Paired to
    # `platform_deliveries` it shares only `id` and `inserted_at` and would
    # manufacture ten allowlist rows out of eleven columns.
    mispaired = %{
      name: "MIS-PAIR PROBE",
      file: @router,
      entry: {:delivery_json, 1},
      schema: @platform_delivery,
      go: nil
    }

    error = assert_raise ExUnit.AssertionError, fn -> assert_paired!(mispaired, []) end
    message = Exception.message(error)
    assert message =~ "MIS-PAIRED"
    assert message =~ "wrong serializer"

    # The real pair, same schema, passes the tripwire — so the tripwire is
    # measuring the PAIRING and not the schema.
    assert_paired!(platform_delivery(), [])
  end

  test "no censused schema carries an unreadable declaration" do
    for pair <- @schema_pairs do
      read = schema_fields(pair, [])

      assert read.unresolvable == [],
             "#{pair.name}: #{Enum.join(read.unresolvable, "; ")}"

      assert read.table != nil
      assert MapSet.size(read.fields) > 0
    end
  end

  test "every @schema_allowlist row names a real schema pair, carries a tracker, and is not a class copy" do
    names = Enum.map(@schema_pairs, & &1.name)

    for {payload, key, reason} = row <- @schema_allowlist do
      assert payload in names, "#{inspect(row)}: unknown (or schema-less) payload"
      assert is_binary(key) and key != ""
      assert byte_size(reason) > 40, "#{payload}/#{key}: a reason this short is not a ruling"

      assert reason =~ ~r/dr-w\d+-[a-z0-9-]+|task-[0-9a-f]+|RULED/,
             "#{payload}/#{key}: a row must name its tracker, or say RULED and why"

      # THE CLASS RULE IS ONE RULE. An explicit row for an `*_encrypted` column
      # would be a copy of `credential_class/1`, and copies drift.
      refute String.ends_with?(key, "_encrypted"),
             "#{payload}/#{key}: the *_encrypted credential class is ONE rule, not a row"
    end

    assert length(Enum.uniq(@schema_allowlist)) == length(@schema_allowlist)

    # The class rule is not decoration: it is carrying real columns today.
    covered =
      @schema_pairs
      |> Enum.flat_map(&(&1 |> schema_fields([]) |> Map.fetch!(:fields) |> credential_class()))
      |> Enum.uniq()

    assert length(covered) >= 4,
           "the *_encrypted class rule covers #{length(covered)} column(s) — if it ever covers " <>
             "none, delete the rule rather than keeping a rule that measures nothing"
  end

  # ---------------------------------------------------------------------------
  # The allowlist itself
  # ---------------------------------------------------------------------------

  test "every allowlist row names a real pair, a real arm, and carries a reason" do
    names = Enum.map(@pairs, & &1.name)

    for {payload, arm, key, reason} = row <- @allowlist do
      assert payload in names, "#{inspect(row)}: unknown payload"
      assert arm in [:unread, :phantom], "#{inspect(row)}: unknown arm"
      assert is_binary(key) and key != ""
      assert byte_size(reason) > 40, "#{payload}/#{key}: a reason this short is not a ruling"
    end

    assert length(Enum.uniq(@allowlist)) == length(@allowlist)
  end

  test "every KNOWN OPEN row names its tracker, and the two halves are disjoint" do
    # A bp task slug is a first-class tracker, not a second-class one. The regex
    # used to accept ONLY `dr-w11-payload-divergence-close` or a PR number, and
    # that is precisely how three rows came to cite PR #10014: a PR number was
    # the only citable thing, and a PR number keeps matching after the PR is
    # CLOSED with mergedAt null — a dead pointer that still reads as an owner.
    # A `dr-w<n>-…` slug points at the ledger, which carries a lifecycle.
    for {payload, _arm, key, reason} <- @known_open do
      assert reason =~ ~r/dr-w\d+-[a-z0-9-]+|PR #\d+/,
             "#{payload}/#{key}: a KNOWN OPEN row must name the task or PR that closes it"
    end

    reconciled = MapSet.new(@reconciled, fn {p, a, k, _} -> {p, a, k} end)
    open = MapSet.new(@known_open, fn {p, a, k, _} -> {p, a, k} end)
    assert MapSet.disjoint?(reconciled, open)

    # Today's divergence is NOT blessed wholesale as reconciled. If this ever
    # reads zero, the split has stopped meaning anything.
    assert length(@known_open) > 0
  end

  defp barkpark, do: Enum.find(@pairs, &(&1.name == "barkpark_json/4"))
  defp pressure, do: Enum.find(@pairs, &(&1.name == "barkpark_json/4 pressure"))

  defp platform_delivery, do: Enum.find(@pairs, &(&1.name == "PlatformDelivery.to_json/1"))

  defp fmt(set) do
    case Enum.sort(set) do
      [] -> "(none)"
      keys -> Enum.join(keys, ", ")
    end
  end
end
