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
  def source(dir), do: dir |> paths() |> Enum.map_join("\n", &File.read!/1)

  @doc """
  The basenames of the non-test Go sources `source/1` concatenates.

  Same `paths/1` as `source/1` on purpose: the SITE arm pins this list, so the
  thing pinned and the thing scanned cannot drift apart.
  """
  @spec sources(binary) :: [binary]
  def sources(dir), do: dir |> paths() |> Enum.map(&Path.basename/1)

  defp paths(dir) do
    dir
    |> Path.join("*.go")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, "_test.go"))
    |> Enum.sort()
  end

  @doc """
  The Go FIELD names of one struct that carry a real json tag, or nil when the
  struct does not exist.

  Field names, not tag names, because the RENDER arm below scans the reader for
  `d.PreviousSHA` — Go source refers to the field, never to the wire key.
  `json:"-"` fields (DeployCensus.Raw, DeliveriesPage.Raw) are excluded for the
  same reason `tags/1` excludes them: they are an explicit do-not-decode.
  """
  @spec struct_fields(binary, binary) :: MapSet.t() | nil
  def struct_fields(src, name) do
    case Regex.run(~r/^type #{name} struct \{\n(.*?)\n\}$/ms, src, capture: :all_but_first) do
      [body] ->
        ~r/^\s*([A-Z][A-Za-z0-9_]*)\s+[^\s]+\s+`json:"([^",]*)/m
        |> Regex.scan(body, capture: :all_but_first)
        |> Enum.reject(fn [_f, tag] -> tag in ["", "-"] end)
        |> Enum.map(fn [f, _tag] -> f end)
        |> MapSet.new()

      _ ->
        nil
    end
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

  @doc """
  Every json tag SITE in the package: tag NAME => how many times it is declared.

  `all_tags/1` is this map with the multiplicities thrown away — and throwing
  them away is precisely what made the go-tag floor unable to lose a site. It
  is the SAME `tag_list/1`: same regex, same rejects, same reach, so the site
  scan cannot grow a blind region the name scan does not already have. Any
  divergence between the two is a broken scanner, and the SITE arm asserts
  their key sets are equal for exactly that reason.
  """
  @spec tag_sites(binary) :: %{binary => pos_integer}
  def tag_sites(src), do: src |> tag_list() |> Enum.frequencies()

  defp tags(text), do: text |> tag_list() |> MapSet.new()

  defp tag_list(text) do
    ~r/json:"([^"]*)"/
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [t] -> t |> String.split(",") |> List.first() end)
    # `json:"-"` is an explicit DO-NOT-DECODE (DeployCensus.Raw), not a key.
    |> Enum.reject(&(&1 in ["", "-"]))
  end
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

  ## The three arms

    * UNREAD  — a key `cloud/` emits that matches NO `json:` tag anywhere in
      `internal/cloudclient/**`. Taken against the PACKAGE-WIDE union, not the
      paired struct, because "read by nobody" is the honest claim; a key decoded
      by a neighbouring struct is read.
    * OFF-STRUCT — a key `cloud/` emits that SOME struct in the package declares
      but its OWN paired struct does not (dr-w23-s6). This is the gap the UNREAD
      arm creates by design: the union answers "does anything read this name",
      and `json.Unmarshal` answers "does THIS struct read it" — so a name shared
      with an unrelated struct greened four keys on `SiteDeployment` while the
      wide deploy page could not print one of them. Disjoint from UNREAD by
      construction (`UNREAD = emitted - all`; `OFF-STRUCT = (emitted AND all) -
      own`), so one defect never reds both arms.
    * PHANTOM — a tag the PAIRED decoder declares that its own emitter never
      emits. Per-struct on purpose: a phantom is a decoder lying about ONE
      payload, and a union would launder it away.

  Both arms are pinned by a committed allowlist split into RULED RECONCILED and
  KNOWN OPEN, with a reason per entry. The split is not cosmetic: blessing
  today's divergence wholesale as "reconciled" is how a census becomes a
  changelog. Set EQUALITY is asserted in both directions, so a new divergence
  reds AND an allowlist entry that stopped diverging reds.

  ## WHAT THIS CENSUS ACTUALLY BLOCKS — measured, not assumed

  This file lives under `cloud/**`, so it runs in the Cloud gate, which is one
  of the four REQUIRED contexts. The interesting question is which PRs it can
  stop, and the honest answer is wider than this slice's own brief believed.

  RE-DERIVED on this tree (dr-w23-s6), because the brief asserted the opposite
  and a coverage claim nobody re-measures is how a census starts flattering
  itself. The Cloud gate's dispatcher resolves its path verdict through
  `scripts/cloud-path-escape-check.sh --match cloud`, whose `CLOUD_PATHS`
  carries `internal/**` — not merely `internal/cloudclient/**`. Run against that
  script directly:

      internal/cli/cloud_site_cmd.go  -> cloud=true
      cloud/lib/foo.ex                -> cloud=true
      docs/INDEX.md                   -> cloud=false   (the discriminating control)

  So an `internal/cli`-ONLY PR DOES dispatch the Cloud suite and this census
  DOES block it. The brief's premise — "a PR that adds a dark instrument ONLY
  under `internal/cli/**` trips ZERO required gates (D391)" — was true when D391
  was measured and is STALE today; `CLOUD_PATHS` was widened to `internal/**`
  since. The docs-only control is quoted beside the other two on purpose: a
  matcher that answered `true` for everything would satisfy the first two lines
  and prove nothing.

  WHAT IT STILL DOES NOT COVER, stated so the paragraph above is not read as a
  bigger claim than it is: a change that touches NEITHER `internal/**` NOR
  `cloud/**` — a pure `js/`, `web/` or `docs/` PR — dispatches `cloud=false`,
  and nothing here runs. This census's subject matter is the Elixir/Go wire, so
  that is the correct scope rather than a hole; it is written down because the
  difference between "does not apply" and "silently skipped" is the whole
  business of this file.

  ## SCOPE (dr-w27-s2)

  The `PlatformDelivery.to_json/1` pair and the RENDER arm below own
  **PlatformDelivery ONLY**.

  `dr-w23-s6-register-per-struct-unread` has since LANDED, and took the
  per-struct arm as the OFF-STRUCT arm above — generalised across every pair
  rather than added as a second SiteDeployment-shaped special case, which is why
  it replaced the two hardcoded D260 spot-guards instead of joining them.

  Its render half is a GO test (`TestSiteStatusRendersTheBuildIdentity` in
  `internal/cli/cloud_site_cmd_test.go`), asserted on rendered bytes, NOT an
  entry in the RENDER arm below — deliberately. That arm scans one reader file
  for `d.<Field>`, and its honesty is asymmetric; the four keys it would have
  covered are better served by a test that drives real wire bytes through the
  real decoder into the real renderer. The wider decoded-but-unrendered
  population for `SiteDeployment` (measured at 65, not the 18 a name-matching
  probe reports) is filed separately and is NOT closed here.

  ## The RENDER arm's BOUND, stated up front rather than discovered later

  DECODING IS NOT RENDERING. A field can be declared, decoded and never printed,
  and every arm above would stay green — the census's own subject matter one hop
  further along. The arm below therefore scans
  `internal/cli/cloud_deliveries_cmd.go` for `d.<Field>` / `page.<Field>` and
  reports what is decoded but never reaches a human.

  IT IS A TEXT SCAN, and its honesty is ASYMMETRIC: reliable about ABSENCE (no
  mention at all means the field truly cannot reach the render), OPTIMISTIC
  about PRESENCE. A mention inside a dead branch, behind a receiver bound to
  another variable name, or in a comment counts as "rendered". It is a tripwire
  for silence, never a proof of output — the proof of output is a rendered-BYTES
  assertion in Go (`TestCloudDeliveriesRollbackVerdictReachesTheHuman`), which
  is what actually holds what a human reads.

  What it finds TODAY, declared and not repaired here: `PlatformDelivery.SHA`,
  `DeliveriesPage.SHA` and `DeliveriesPage.Limit` are decoded and never printed.
  The row's own `SHA` is the interesting one — the render prints the sha the
  CALLER ASKED FOR in its header and never the sha each row carries, so it never
  demonstrates that the rows it printed are the sha you asked for. Repairing
  that is a reader change with its own render decisions and is filed, not
  smuggled in here.

  It reads `internal/cloudclient/` through a `"../../../internal/cloudclient"`
  literal, which `scripts/cloud-path-escape-check.sh` resolves as a repo-root
  read of the Cloud suite. That ratchet FAILS unless `internal/cloudclient/**`
  is in `CLOUD_PATHS` — so a Go-only edit to `client.go` cannot skip the gate
  that checks it.
  """

  use ExUnit.Case, async: true

  alias BarkparkCloud.PayloadKeySetCensus.Extract
  alias BarkparkCloud.PayloadKeySetCensus.Go

  @router Path.expand("../../lib/barkpark_cloud/web/router.ex", __DIR__)
  @ledger Path.expand("../../lib/barkpark_cloud/deploy_ledger.ex", __DIR__)
  @platform_delivery Path.expand("../../lib/barkpark_cloud/platform_delivery.ex", __DIR__)
  @cloudclient Path.expand("../../../internal/cloudclient", __DIR__)
  @deliveries_reader Path.expand("../../../internal/cli/cloud_deliveries_cmd.go", __DIR__)

  # The censused pairs: one Elixir serializer, one Go decoder. `nested` selects a
  # nested literal map inside the entry's payload (`pressure`, `window`), which
  # is its own contract with its own struct.
  @pairs [
    %{name: "barkpark_json/4", file: @router, entry: {:barkpark_json, 4}, go: "Barkpark"},
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
      go: "SiteDeployment"
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
    },
    # dr-w34-s1, and the D260 blind spot is at its structural MAXIMUM here: every
    # name on this row — `site_id`, `name`, `slug`, `environment`,
    # `never_covered` — ALREADY exists as a json tag somewhere in
    # internal/cloudclient. So the file-global UNREAD arm and the exact
    # `@go_tag_floor` would BOTH stay green with `DeployCoverageSite` declared
    # carrying no fields at all: the control plane would emit the full named
    # tail, `encoding/json` would drop every name on the floor, and nothing in
    # this file could say so. The pair is what makes the PHANTOM arm bite the
    # struct itself; `coverage_site_row/1` is a named single-clause producer for
    # the same reason `site_row/2` is one — an inline fn in the fold above it is
    # a wire shape this census cannot walk.
    %{
      name: "DeployLedger.coverage_site_row/1",
      file: @ledger,
      entry: {:coverage_site_row, 1},
      go: "DeployCoverageSite"
    },
    # dr-w27-s2. The CROWN's own wire, and the pair that was missing while this
    # epic's flagship record drifted: `to_json/1` emitted FIFTEEN keys and
    # `cloudclient.PlatformDelivery` pinned THIRTEEN, so `previous_sha` and
    # `transition` — the rollback verdict — were dropped by `json.Unmarshal` in
    # silence. Two exact pins existed and both stayed green because neither
    # crossed the language boundary: Elixir pinned 15 against a hand-written
    # literal, Go pinned 13 against a fixture. This row is the only assertion in
    # the tree that reads BOTH ends, and it types no key list at all.
    %{
      name: "PlatformDelivery.to_json/1",
      file: @platform_delivery,
      entry: {:to_json, 1},
      go: "PlatformDelivery"
    }
  ]

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
     "EMITTED, outside Side A's scope by design. /v1/barkparks Map.put's `team` onto the row in its all_teams? arm (router.ex:2077), i.e. in the ROUTE, not in the base serializer this census walks. The same one-level bound that stops the walk over-collecting a helper's private shapes also makes this key invisible — and `Barkpark.Team` is decoded and read (client_test.go:208), so the read lands."}
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
    # THE THREE FLEET ROWS SAID SOMETHING FALSE (corrected by hand, dr-w27-s2).
    # They read as "decoded by NOBODY", and all three are decoded today by
    # `internal/cli/cloud_support_cmd.go:1460-1462`, which declares
    # json:"fleet_role" / "fleet_parent_id" / "fleet_token_id" on its own support
    # row. What is true is narrower: no CLIENT struct decodes them, because this
    # arm's union root is `internal/cloudclient` ONLY.
    #
    # WIDENING THE ROOT TO internal/cli WAS CONSIDERED AND REFUSED, MEASURED on
    # this branch (2 non-test files -> 103): the union grows 245 -> 457 tag
    # names, +212 exactly, and buys precisely THESE THREE allowlist flips. Every
    # one of those 212 unrelated names multiplies charter D260's collision blind
    # spot, which is not theoretical here — the UNREAD arm greens a key the
    # moment ANY name in the union matches it, on a struct that need not decode
    # the payload at all. And it would NOT have greened the finding this slice
    # exists for: no non-test file under internal/cli declares json:"previous_sha"
    # or json:"transition" either (`grep -rn 'json:"previous_sha"' internal/cli`
    # returns nothing), so the rollback verdict stays newly-unread under the
    # widened union too. Three correct sentences cost less than 212 blind spots.
    {"barkpark_json/4", :unread, "fleet_role",
     "dr-w11-payload-divergence-close — Personal Dev Fleet group record (PDF-D61). No CLIENT struct decodes it; `bp` DOES, at internal/cli/cloud_support_cmd.go:1460 (json:\"fleet_role\"), which is outside this arm's internal/cloudclient union root."},
    {"barkpark_json/4", :unread, "fleet_parent_id",
     "dr-w11-payload-divergence-close — the main this box binds to. No CLIENT struct decodes it; `bp` DOES, at internal/cli/cloud_support_cmd.go:1461 (json:\"fleet_parent_id\"), outside this arm's union root."},
    {"barkpark_json/4", :unread, "fleet_token_id",
     "dr-w11-payload-divergence-close — the opaque revocation-token id (not a secret). No CLIENT struct decodes it; `bp` DOES, at internal/cli/cloud_support_cmd.go:1462 (json:\"fleet_token_id\"), outside this arm's union root."},
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
  # W26 S3 (the deliveries reader lands, decoding main's REAL 13-key wire shape):
  # the go-tag floor moves 228 -> 243, MEASURED by the 999-technique on THIS
  # merged tree — both floors set to 999 and the refusal printed "243 json tag(s)
  # found in internal/cloudclient, floor is EXACTLY 999". It was NOT computed as
  # 228 + 12, and that guess would have been wrong: the guess is off by three
  # BOTH ways at once. `Go.all_tags/1` is a file-GLOBAL union of tag NAMES over
  # internal/cloudclient/*.go, so `sha`, `count`, `scope`, `limit`, `target` and
  # friends were already declared by unrelated structs and ride free, while
  # deliveries.go contributes two structs' worth of genuinely new names
  # (delivering_run_id, first_seen_at, merged_at, queued_seconds and the three
  # queued_*_seconds, build_seconds, serving_since, carried, recorded_at,
  # deliveries). Which names ride free is not the set a reader would guess, which
  # is the whole reason this number is measured and never derived. The emitted
  # floor does NOT move: this slice writes no serializer, it reads one.
  # MERGE HAZARD, unchanged: these floors are `==`, so any other PR that also
  # moves them must be re-measured after this one lands, never summed with it.
  # W27 S2 (the CROWN's own wire joins the census): the emitted floor moves
  # 126 -> 141 and the go-tag floor 243 -> 245, BOTH re-measured by the
  # 999-technique on this branch — floors set to 999, the two refusals printed
  # "141 emitted key(s) collected" and "245 json tag(s) found in
  # internal/cloudclient" — and neither is arithmetic. The emitted number is the
  # one a reader would get wrong: `to_json/1` emits fifteen keys, but eleven of
  # them (`sha`, `target`, `carried`, `merged_at`, the four queued_*/build
  # clocks, `serving_since`, `first_seen_at`, `recorded_at`) are names the other
  # censused serializers ALREADY emit — and the floor is a SUM OF PER-PAIR SET
  # SIZES, not a union, so the whole fifteen counts here while the go-tag union
  # gains only the two names that are new package-wide. That the go-tag delta
  # happens to equal the two fields added is a coincidence of `previous_sha` and
  # `transition` being new EVERYWHERE in internal/cloudclient; `team` and
  # `scope` rode free in W19 S1 and `sha`/`count`/`limit` rode free in W26 S3.
  # MERGE HAZARD, unchanged: these floors are `==`, so any other PR that also
  # moves them must be re-measured after this one lands, never summed with it.
  #
  # W28 S4 (`deferral_wait` joins the census, and internal/cloudclient DECODES
  # it): the emitted floor moves 141 -> 142 and the go-tag floor 245 -> 255,
  # BOTH re-measured by the 999-technique on this branch — floors set to 999,
  # the two refusals printed "142 emitted key(s) collected" and "255 json tag(s)
  # found in internal/cloudclient". Neither is arithmetic. The emitted delta is
  # ONE because `census/3` gained a single top-level key; the node's inner keys
  # live in `deferral_wait/2`, which is not a censused serializer entry point.
  # The go-tag delta is TEN because `DeployDeferralWait` and its three
  # companions declare `deferral_wait`, `covered`, `pending`, `unreadable`,
  # `outcome`, `outcomes`, `population`, `unresolved`, `unresolved_fraction` and
  # `oldest_pending_seconds` as names new PACKAGE-WIDE; the sixteen other tags on
  # those structs (`clock`, `basis`, `as_of`, `label`, `count`, `quantile`,
  # `seconds`, `sample`, `headroom`, `min_sample`, `refused`, `reason`, `p50`,
  # `p95`, `max`, `deferred`) ride free on the delivery census's union. The
  # decoder is the POINT and not an afterthought: a wait number no reader decodes
  # is a number nobody reads, which is the disease this epic exists to cure.
  #
  # dr-w34-s1 (the coverage envelope names its sites, and states its covering
  # bound): the emitted floor moves 144 -> 149 and the go-tag floor 264 -> 268,
  # BOTH re-measured by the 999-technique ON THIS BRANCH — floors set to 999, the
  # two refusals printed "149 emitted key(s) collected, floor is EXACTLY 999" and
  # "268 json tag(s) found in internal/cloudclient, floor is EXACTLY 999".
  # NEITHER was computed by adding a delta to 144 or to 264, and the two deltas
  # are different numbers for structural reasons: the emitted floor gains the
  # NEW PAIR'S WHOLE ROW WIDTH (five keys — `site_id`, `name`, `slug`,
  # `environment`, `never_covered`) because `total_emitted/1` is a SUM of
  # per-pair set sizes and not a union, while the go-tag union gains only the
  # FOUR names that are new package-wide (`covering_bound`,
  # `never_covered_sites`, `never_covered_sites_total`,
  # `never_covered_sites_truncated`) — every field on `DeployCoverageSite`
  # itself already existed as a tag elsewhere, which is precisely why that
  # struct needed the pair and its own per-struct assertions in
  # internal/cli/cloud_deploy_census_cmd_test.go. `census/3`'s own top-level key
  # set is UNCHANGED: the new keys are inside `coverage_cohorts/2`, which is not
  # a censused entry point.
  #
  # MERGE HAZARD, restated because three open PRs (#10811, #10129 and #10086 —
  # the last adds one tag, `details`, and is CCH-owned) also touch
  # internal/cloudclient: whichever of them lands second must RE-MEASURE both
  # floors by this same technique. Summing deltas is how an `==` pin ships wrong.
  #
  # RE-MEASURED on the wave-35 rebase (this branch merged with main at
  # 4b5d802a1d): the 999-technique printed "149 emitted key(s) collected, floor
  # is EXACTLY 999" and "268 json tag(s) found in internal/cloudclient, floor is
  # EXACTLY 999" — both floors HOLD across the merge, measured, not derived.
  #
  # #10086's re-land (the typed CloudRefusal decoder) is the PR the merge hazard
  # above named, and it landed second: the go-tag floor moves 268 -> 269 and the
  # emitted floor HOLDS at 149. Re-measured on this branch merged with main, with
  # the scanner this file defines run against internal/cloudclient — 269 tags,
  # and the set difference against origin/main's own package is exactly ONE name,
  # `details`. Not summed, not predicted: the comment above forecast one tag and
  # the measurement agreed, which is a check on the forecast and not a substitute
  # for it. The delta is one and not four because `CloudRefusal` decodes
  # `reason`, `required` and `scope` under names already declared elsewhere in
  # internal/cloudclient, so only `details` is new PACKAGE-WIDE. The emitted
  # floor does not move because this slice writes no Elixir serializer — it reads
  # a refusal `cloud/` already emits, which is the whole point of the pair.
  #
  # D863 (`bp cloud site create` renders the readable-types menu) moves the
  # go-tag floor 269 -> 271; the emitted floor HOLDS at 149. Measured the same
  # way as the `details` delta above, and with the same nuance: the diff adds
  # THREE tag lines to internal/cloudclient (`type`, `count,omitempty`,
  # `readable_types`) but the set difference against origin/main's own package is
  # exactly TWO names — `readable_types` and `type` — because `count` is already
  # declared elsewhere in the package. Removals: none (main 269, branch 271, no
  # name lost). The emitted floor does not move because this slice writes no new
  # Elixir serializer: it renders a menu `cloud/` already emits, which is again
  # the point of the pair.
  #
  # dr-w23-s4 (the deploy census renders its coalesced-attempt gauge) is the PR
  # the merge hazard above named by number, and it landed after every delta
  # listed here. The go-tag floor moves 271 -> 273 and the emitted floor HOLDS
  # at 149 — BOTH re-measured by the 999-technique on this branch merged with
  # main, never summed with the 225 -> 227 figure this slice measured against its
  # own older base. That older number is stale by construction: it was taken
  # before `deferral_wait`, the coverage envelope, `details` and `readable_types`
  # moved the same union, which is precisely the failure mode the hazard note
  # warns about. The slice declares SIX new json tag lines —
  # `coalesced_attempts` on `DeployCensus` plus `value`, `refused`, `reason`,
  # `since` and `basis` on the new `DeployCoalescedAttempts` — and the union
  # grows by TWO (the 999-technique printed "273 json tag(s) found in
  # internal/cloudclient, floor is EXACTLY 999" and "149 emitted key(s)
  # collected"), because the refusal shape is deliberately the same shape a
  # `DeployRate` refusal already declares. The emitted floor does not move: this
  # slice writes no Elixir serializer, it DECODES one `cloud/` already emits.
  #
  # THE CO-EDIT IS NOT OPTIONAL. `coalesced_attempts` was a KNOWN OPEN :unread
  # row above; the moment a Go field declares it, the census's "no longer unread
  # — DELETE the allowlist row" arm reds. That arm is DESIGNED to force this
  # co-edit in the same commit, and a Go-only PR never runs the Cloud job, so
  # deferring it would have merged green and reddened main.
  @emitted_floor 149
  @go_tag_floor 273

  # ---------------------------------------------------------------------------
  # THE SITE ARM (dr-w26-bl-go-tag-arm-is-36-percent-blind)
  #
  # `@go_tag_floor` counts NAMES, so it is a census of VOCABULARY and not of
  # coverage: a name declared at twelve sites can lose eleven of them and the
  # count never moves. MUTATION-PROVED on this tree, not predicted — turning
  # `SiteDeleteResult.Status` (`internal/cloudclient/client.go`, `json:"status"`,
  # a name declared at TWELVE sites) into `json:"-"` stops the CLI decoding the
  # `status` key of the live `DELETE /v1/sites/:id` envelope that
  # `renderSiteDeleted` prints, and left this file at 23 tests / 0 failures with
  # `go test ./internal/cloudclient/...` green. Deleting a UNIQUE name reds three
  # arms at once, which is the whole shape of the hole: the guard could only lose
  # when the LAST site of a name died.
  #
  # THE REGISTER BELOW CLOSES IT, and the closure is a PARTITION, not a
  # sampling. Every tag site in internal/cloudclient falls in exactly one class:
  #
  #   * a site of a name declared ONCE (175 of them) — deleting it deletes the
  #     NAME, so `@go_tag_floor`'s `==` already reds. Not registered here.
  #   * a site of a name declared MORE THAN ONCE (98 names, 341 sites) — this is
  #     the blind class, and each row pins the exact multiplicity, so losing ONE
  #     of twelve `status` sites reds BY NAME.
  #
  # 175 + 341 = 516, and the two classes are asserted to reconstruct exactly
  # that total from `@go_tag_floor` and this register, so a register edited
  # without the floor (or the reverse) reds rather than drifting. No tag site in
  # the package can be deleted without a red — that is the claim, and the
  # partition test is what makes it checkable rather than aspirational.
  #
  # MERGE HAZARD, the same one the floors already carry: these are `==`. A PR
  # that declares a tag whose NAME already exists in internal/cloudclient does
  # NOT move `@go_tag_floor` (it rides free on the union) but DOES move a row
  # here — `team` and `scope` rode free in W19 S1, `sha`/`count`/`limit` in
  # W26 S3. Re-measure by the 999-technique after the other PR lands; never sum.
  @go_tag_sites %{
    "artifact_url" => 2,
    "as_of" => 5,
    "at" => 2,
    "barkpark_id" => 4,
    "basis" => 6,
    "became_live_at" => 2,
    "build_log_url" => 2,
    "bytes" => 2,
    "censored" => 3,
    "clock" => 3,
    "code" => 3,
    "content_rev" => 2,
    "count" => 5,
    "covered" => 2,
    "current_deployment_id" => 2,
    "dataset" => 2,
    "deferred" => 3,
    "delivered" => 2,
    "deployment" => 3,
    "deployments" => 2,
    "detail" => 8,
    "doc_type" => 2,
    "domains" => 3,
    "email" => 3,
    "environment" => 4,
    "error" => 8,
    "evidence" => 2,
    "failed" => 2,
    "failure_class" => 2,
    "failure_rate" => 2,
    "failure_reason" => 2,
    "framework" => 4,
    "from" => 2,
    "git_ref" => 2,
    "headroom" => 2,
    "host" => 6,
    "id" => 13,
    "image_tag" => 2,
    "in_flight" => 2,
    "inserted_at" => 8,
    "instance" => 3,
    "instances" => 2,
    "kind" => 4,
    "label" => 6,
    "last_seen_at" => 2,
    "live" => 2,
    "max" => 2,
    "measured_at" => 2,
    "meters" => 2,
    "min_sample" => 6,
    "name" => 11,
    "never_covered" => 3,
    "next_cursor" => 2,
    "ok" => 8,
    "oldest_pending_seconds" => 2,
    "p50" => 2,
    "p95" => 2,
    "pending" => 2,
    "pinned_release" => 3,
    "population" => 2,
    "port" => 4,
    "project" => 2,
    "provider" => 3,
    "quantile" => 2,
    "reachable" => 3,
    "reason" => 8,
    "refused" => 4,
    "required" => 2,
    "role" => 4,
    "runtime_target" => 3,
    "sample" => 6,
    "scale_mode" => 2,
    "scope" => 4,
    "seconds" => 2,
    "series" => 2,
    "sha" => 2,
    "site" => 7,
    "site_id" => 5,
    "sites" => 3,
    "slug" => 7,
    "source" => 2,
    "stage" => 3,
    "stages" => 2,
    "status" => 13,
    "team" => 4,
    "team_id" => 6,
    "template" => 2,
    "theme" => 2,
    "to" => 2,
    "token" => 2,
    "trigger" => 3,
    "unmetered" => 2,
    "unreadable" => 2,
    "unresolved" => 2,
    "updated_at" => 5,
    "url" => 5,
    "usage" => 2,
    "value" => 4,
    "volume" => 2,
    "window" => 2,
    "workspace" => 2
  }

  # The SITE arm's corpus, pinned. `Go.source/1` globs `*.go` and drops
  # `_test.go`, so its reach is whatever the directory happens to contain — and
  # the multiplicities above are exact only for THIS file set. A new non-test
  # source silently widens every count; pinning the list makes that a red with a
  # name on it instead of a floor that quietly means something else. (This also
  # corrects a fact in circulation: `client.go` has NOT been the whole corpus
  # since `deliveries.go` landed in W26 S3.)
  @cloudclient_sources ~w(client.go deliveries.go)
  # ---------------------------------------------------------------------------

  # The barkpark_json family specifically, because it is where blind spot (1) was
  # measured: 59 keys with the :when unwrap, 45 without (the :when unwrap is
  # still worth exactly the same 14 vitals — the three new keys are in the base
  # literal, so they are visible to both walkers).
  @barkpark_family_keys 60
  @barkpark_family_keys_blind 46

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
    Enum.reduce(@pairs, 0, fn pair, acc -> acc + MapSet.size(emitted(pair, opts).keys) end)
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
    assert MapSet.size(p.top) == 46

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
             "the EXTRACTOR is broken, not the payload shrunk. Check Extract.clauses/4 " <>
             "(a new def syntax it does not match) before touching the floor."

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

    for %{go: name} <- @pairs do
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

  # THE PER-STRUCT UNREAD ARM (dr-w23-s6) — the generalisation of charter D260.
  #
  # `Go.all_tags/1` is FILE-GLOBAL: it unions every json tag in
  # internal/cloudclient, so a key whose name collides with ANY unrelated
  # struct's tag passes the UNREAD arm without a single line being added to the
  # struct that actually decodes it. `json.Unmarshal` then drops the key on the
  # floor and nothing in this file can say so.
  #
  # This arm was TWO HARDCODED SPOT-GUARDS until dr-w23-s6 — one pinning
  # `census/3`'s cohort keys to `DeployCensus`, one pinning `site_row/2`'s `live`
  # to `DeployCensusSite`. Each was written the day its own bug was found, and
  # NEITHER covered the pair that was actually laundering. Measured across all
  # NINE pairs at the time this arm landed (the slice's own brief said seven —
  # two pairs were added between filing and build, which is why the arm reads
  # `@pairs` and never a typed count):
  #
  #   site_deployment_json/3 -> SiteDeployment: emitted=31 own=25 LAUNDERED=4
  #     artifact_url  (declared only by: Deployment)
  #     detail        (declared only by: SiteStage, WebhookProxyError)
  #     git_ref       (declared only by: Deployment)
  #     image_tag     (declared only by: Deployment)
  #   every other pair: LAUNDERED=0
  #
  # MECHANISM: `site_deployment_json/3` pipes the narrow producer
  # `deployment_json/1`, so the WIDE wire carries the NARROW payload's fields.
  # The narrow struct `Deployment` declares them, the wide `SiteDeployment` did
  # not, and the file-global union greened it. The human consequence was two
  # deploy readers on one platform, one silently poorer: `bp sites` printed
  # image/git_ref/artifact and `bp cloud site status` could not.
  #
  # `detail` is the sharpest of the four and the reason a NAME-based union can
  # never be trusted here: the top-level `detail` (the DEPLOYMENT's own caption,
  # router.ex `deployment_json/1`) and `SiteStage.Detail` (the PER-STAGE caption,
  # `Sites.Deploy.stages/1`) are different values that happen to share a name.
  # The union cannot tell them apart. This arm does not have to — it asks only
  # whether the struct that decodes THIS payload declares the key.
  #
  # SCOPE, stated rather than implied: this asks whether the key is DECLARED on
  # its own struct, not whether anything RENDERS it. That is the RENDER arm's
  # question, and it covers PlatformDelivery only today.
  test "OFF-STRUCT: every emitted key the package decodes is declared on ITS OWN paired struct" do
    src = Go.source(@cloudclient)
    all = Go.all_tags(src)

    # EVERY pair is measured before anything is asserted, and the report below
    # prints ALL of them — including the ones with nothing to report. A per-pair
    # `assert` inside the loop aborts at the first offender, which would leave a
    # reader unable to tell "the other pairs are clean" from "the other pairs
    # were never reached" — the same absence-vs-silence confusion this whole
    # census exists to refuse.
    rows =
      for pair <- @pairs do
        own = Go.struct_tags(src, pair.go)

        assert own,
               "#{pair.name}: internal/cloudclient declares no `type #{pair.go} struct` — the " <>
                 "pair names a decoder that does not exist, so this arm is measuring nothing."

        # DELIBERATELY intersected with the file-global union first. A key nothing
        # in the package declares is the UNREAD arm's business, and reporting it
        # here too would make one defect red two arms and invite a reader to
        # allowlist it in the wrong one. The two arms are disjoint by construction:
        # UNREAD = emitted - all; OFF-STRUCT = (emitted AND all) - own.
        actual =
          pair
          |> emitted()
          |> Map.fetch!(:keys)
          |> MapSet.intersection(all)
          |> MapSet.difference(own)

        %{pair: pair, actual: actual, expected: allowed(pair.name, :off_struct)}
      end

    moved = Enum.reject(rows, &(&1.actual == &1.expected))

    report =
      Enum.map_join(rows, "\n", fn %{pair: pair, actual: a, expected: e} ->
        newly = MapSet.difference(a, e)
        gone = MapSet.difference(e, a)

        status =
          cond do
            MapSet.size(newly) == 0 and MapSet.size(gone) == 0 -> "ok"
            true -> "MOVED  newly laundered: #{fmt(newly)}  no longer laundered: #{fmt(gone)}"
          end

        "  #{String.pad_trailing(pair.name, 34)} -> #{String.pad_trailing(pair.go, 20)} #{status}"
      end)

    assert moved == [], """
    the OFF-STRUCT set moved.

    NEWLY LAUNDERED means: emitted, decoded by SOME struct in the package but NOT
    by its own paired struct. The file-global UNREAD arm greens it while
    `json.Unmarshal` drops it on the floor. Declare the tag on the paired struct,
    or allowlist it with a reason.

    NO LONGER LAUNDERED means: allowlisted, but the paired struct now declares it
    — DELETE the allowlist row.

    All #{length(rows)} pairs, including the clean ones:

    #{report}
    """
  end

  # ANTI-VACUITY FOR THE ARM ABOVE, and the preserved substance of the two D260
  # spot-guards it replaced. The arm is only worth running if the file-global
  # union is genuinely blind — if no emitted key were ever declared by a second
  # struct, `all` and `own` would agree and the arm could never bite anything.
  #
  # Both collisions below are the ORIGINAL D260 findings, kept as measurements
  # rather than as prose. If either stops holding, the blind spot has MOVED and
  # the arm above needs re-deriving before it is trusted.
  test "the file-global union is genuinely blind — the collisions this arm exists for are REAL" do
    src = Go.source(@cloudclient)

    # D260 as first measured: `census/3` emits `in_flight`, and an unrelated
    # struct declares that name, so the union would have greened DeployCensus
    # carrying no such field at all.
    assert "in_flight" in Go.struct_tags(src, "RolloutState"),
           "RolloutState no longer declares in_flight — re-derive D260's blind spot before " <>
             "trusting the union on any cohort key."

    # D260 one struct over (dr-w19-s7): the FLEET struct declares `live`, which
    # is what blinded the union to `DeployCensusSite` carrying no Live at all.
    assert "live" in Go.struct_tags(src, "DeployCensus"),
           "DeployCensus no longer declares `live` — re-derive this blind spot before trusting " <>
             "the union on any per-site key."

    # And the general property, measured rather than argued: at least one pair
    # emits a key that a DIFFERENT struct also declares. That is the whole
    # premise of this arm, and a tree where it stopped being true would make the
    # arm a green that proves nothing.
    all = Go.all_tags(src)

    collisions =
      for pair <- @pairs,
          own = Go.struct_tags(src, pair.go),
          own != nil,
          key <- MapSet.intersection(emitted(pair).keys, all),
          key in own,
          Enum.count(struct_owners(src, key)) > 1,
          do: {pair.go, key}

    assert collisions != [],
           "no emitted key is declared by more than one struct anywhere in internal/cloudclient. " <>
             "The file-global union is no longer blind, so the OFF-STRUCT arm cannot bite — " <>
             "re-derive its premise before believing its green."
  end

  # ---------------------------------------------------------------------------
  # THE SITE ARM: the census can lose a SITE, not only the LAST site of a name
  # ---------------------------------------------------------------------------

  test "SITE: the arm's corpus is EXACTLY the declared non-test sources" do
    assert Go.sources(@cloudclient) == @cloudclient_sources, """
    the SITE arm's corpus moved: internal/cloudclient now compiles a different set of
    non-test sources than `@cloudclient_sources` declares.

      declared: #{Enum.join(@cloudclient_sources, ", ")}
      on disk:  #{Enum.join(Go.sources(@cloudclient), ", ")}

    Every multiplicity in `@go_tag_sites` is exact only for the pinned set. Re-measure
    the register and `@go_tag_floor` against the new corpus before pinning it here —
    a widened corpus that keeps the old numbers is an arm measuring something else.
    """
  end

  test "SITE: every tag name declared more than once is registered at its EXACT multiplicity" do
    src = Go.source(@cloudclient)
    sites = Go.tag_sites(src)

    # ANTI-VACUITY, both failure modes of a scanner that stopped scanning. A
    # broken site regex reports an empty (or narrower) map and every row below
    # would then red as "gone" rather than passing — but a map that is merely
    # SHAPED right proves nothing, so pin the two properties that only a working
    # frequency scan can have:
    #   1. it sees the same vocabulary the name scanner does, and
    #   2. it actually carries multiplicity rather than collapsing to a set.
    assert MapSet.new(Map.keys(sites)) == Go.all_tags(src),
           "the SITE scanner and the NAME scanner disagree about the vocabulary — the " <>
             "SCANNER is broken, not the corpus."

    assert Enum.sum(Map.values(sites)) > map_size(sites),
           "every tag name counts exactly once — `tag_sites/1` has collapsed to a set and " <>
             "the SITE arm is measuring vocabulary again."

    actual = sites |> Enum.filter(fn {_name, count} -> count > 1 end) |> Map.new()

    assert actual == @go_tag_sites, """
    the tag SITE register moved.

      sites LOST (a decoder stopped declaring a name it still declares elsewhere —
      this is the blindness the arm exists for, and the name floor CANNOT see it):
        #{fmt_sites(moved(@go_tag_sites, actual, &>/2))}

      sites GAINED (a new declaration of an existing name — it rides free on the
      NAME union, so `@go_tag_floor` does not move; bump the row here):
        #{fmt_sites(moved(@go_tag_sites, actual, &</2))}

      newly duplicated (a name that was declared once and now is not):
        #{fmt_sites(Map.drop(actual, Map.keys(@go_tag_sites)))}

      no longer duplicated (down to a single site — DELETE the row; the name
      floor covers it from here):
        #{fmt_sites(Map.drop(@go_tag_sites, Map.keys(actual)))}
    """
  end

  test "SITE: the name floor and the multiplicity register PARTITION every tag site" do
    # The totality claim, made checkable. Sites of once-declared names are
    # covered by `@go_tag_floor`; sites of repeatedly-declared names by
    # `@go_tag_sites`. If those two classes reconstruct the measured site total,
    # nothing in the package is outside both — so no tag site can be deleted
    # without one of the two arms reddening. If they do not, one of the two
    # numbers was edited without the other and the coverage claim is void.
    singles = @go_tag_floor - map_size(@go_tag_sites)
    expected = singles + Enum.sum(Map.values(@go_tag_sites))
    actual = Enum.sum(Map.values(Go.tag_sites(Go.source(@cloudclient))))

    assert actual == expected, """
    #{actual} tag site(s) found in internal/cloudclient, but `@go_tag_floor` (#{@go_tag_floor} names)
    and `@go_tag_sites` (#{map_size(@go_tag_sites)} duplicated names, #{Enum.sum(Map.values(@go_tag_sites))} sites)
    together account for #{expected}.

    The floor and the register have drifted apart: one was bumped and the other was not,
    and until they agree the "no site can be deleted silently" claim is NOT in force.
    Re-measure BOTH by the 999-technique on this tree; never by arithmetic.
    """

    # The register's own definition, or the partition is not a partition: a row
    # of 1 would be a site claimed by BOTH classes and counted twice above.
    assert Enum.filter(@go_tag_sites, fn {_name, count} -> count < 2 end) == [],
           "`@go_tag_sites` registers a name at fewer than 2 sites — that site belongs to " <>
             "`@go_tag_floor`'s class, and registering it here double-counts the partition."
  end

  # ---------------------------------------------------------------------------
  # The two arms
  # ---------------------------------------------------------------------------

  test "UNREAD: every emitted key is decoded somewhere in internal/cloudclient, or allowlisted" do
    all = Go.all_tags(Go.source(@cloudclient))

    for pair <- @pairs do
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

  # THE THIRD ARM: DECODED, BUT NEVER RENDERED (dr-w27-s2, PlatformDelivery
  # only — SiteDeployment is dr-w23-s6's).
  #
  # The UNREAD arm asks whether Go declares the key. That is one hop short of the
  # thing an operator actually experiences: `transition` could have been declared
  # tomorrow, decoded correctly, and still never printed — and every assertion in
  # this file would have stayed green while the rollback verdict remained
  # invisible on the only surface anybody uses.
  #
  # The scan's bound is in the moduledoc and is not restated here: honest about
  # ABSENCE, optimistic about PRESENCE. The declared set below is a REPORT of
  # today's tree, not a blessing — each entry names what a reader cannot see.
  @never_rendered %{
    "PlatformDelivery" => {"d", ["SHA"]},
    "DeliveriesPage" => {"page", ["Limit", "SHA"]}
  }

  test "RENDER: every decoded delivery field reaches the human render, or is DECLARED unrendered" do
    src = Go.source(@cloudclient)
    reader = File.read!(@deliveries_reader)

    for {struct, {var, declared}} <- @never_rendered do
      fields = Go.struct_fields(src, struct)
      assert fields, "internal/cloudclient declares no `type #{struct} struct`"

      rendered = Enum.filter(fields, &Regex.match?(~r/\b#{var}\.#{&1}\b/, reader))
      unrendered = MapSet.difference(fields, MapSet.new(rendered))

      # ANTI-VACUITY: a regex that stopped matching reports EVERY field as
      # unrendered, and a `reader` that failed to load would report the same. Two
      # fields whose render is asserted in Go bytes must be found, or the scanner
      # is what broke, not the reader.
      for anchor <- ~w(Deliveries Count), anchor in fields do
        assert anchor in rendered,
               "the render scan lost `#{var}.#{anchor}` — the SCANNER is broken, not the reader"
      end

      assert unrendered == MapSet.new(declared), """
      #{struct}: the DECODED-BUT-NEVER-RENDERED set moved.

        newly unrendered (decoded and no longer printed — an operator cannot see it):
          #{fmt(MapSet.difference(unrendered, MapSet.new(declared)))}
        now rendered (declared unrendered but the reader prints it — DELETE the declaration):
          #{fmt(MapSet.difference(MapSet.new(declared), unrendered))}
      """
    end
  end

  test "PHANTOM: every decoded key is emitted by its paired serializer, or allowlisted" do
    src = Go.source(@cloudclient)

    for pair <- @pairs do
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

  # Rows present in BOTH maps whose count moved in the direction `cmp` says,
  # carrying BOTH numbers: "which way and by how much" is the whole message.
  defp moved(before, now, cmp) do
    for {name, was} <- before,
        is = now[name],
        is != nil,
        cmp.(was, is),
        into: %{},
        do: {name, {was, is}}
  end

  defp fmt_sites(map) when map_size(map) == 0, do: "(none)"

  defp fmt_sites(map) do
    map
    |> Enum.sort()
    |> Enum.map_join(", ", fn
      {name, {was, is}} -> "#{name}: #{was} site(s) -> #{is}"
      {name, count} -> "#{name} x#{count}"
    end)
  end

  defp barkpark, do: Enum.find(@pairs, &(&1.name == "barkpark_json/4"))
  defp pressure, do: Enum.find(@pairs, &(&1.name == "barkpark_json/4 pressure"))

  # Every struct in internal/cloudclient that declares `key` as a json tag. Used
  # only by the anti-vacuity test above, to show a name is claimed by more than
  # one struct — which is what makes the file-global union blind in the first
  # place.
  defp struct_owners(src, key) do
    ~r/^type (\w+) struct \{\n(.*?)\n\}$/ms
    |> Regex.scan(src, capture: :all_but_first)
    |> Enum.filter(fn [_name, body] -> key in Go.all_tags(body) end)
    |> Enum.map(fn [name, _body] -> name end)
  end

  defp fmt(set) do
    case Enum.sort(set) do
      [] -> "(none)"
      keys -> Enum.join(keys, ", ")
    end
  end
end

# =============================================================================
# THE WORKER-SEAM CALLER CENSUS — dr-w26-s4
# =============================================================================

defmodule BarkparkCloud.WorkerSeamCallerCensus do
  @moduledoc """
  Side C of the same wire: a write route the control plane SHIPS that nothing in
  this tree ever calls.

  The payload census above proves the two ends of a payload agree. It cannot see
  the failure one level up — a producer that merged, is correct, and is joined to
  NOTHING. `POST /v1/internal/platform-deliveries` has been live for two waves
  with zero callers: the recorder was never wired, so the table it writes stays
  empty, every read off it is honestly zero, and no test in this tree could tell
  that from "nothing was delivered".

  ## The corpus is POSITIVELY declared, and that is the whole ruling

  A SUBTRACTIVE corpus ("everything except router.ex, cloud/test and
  internal/cli") is vacuous here, measurably and on the day it lands:
  `tooling/grip/ledger/crown-writer-seam-live-2026-08-08.md` carries the crown's
  path twice, in curl RECIPES. Prose describing a route is not a caller. Under a
  subtractive corpus this arm would have scored the crown CALLED and shipped
  green — an instrument that certifies the exact hole it was built to find.

  So the corpus is a positive declaration: five `@roots`, an `@extensions`
  allowlist, and `@refused` by name. The `*.md` refusal is the LOAD-BEARING one
  — `tooling/**` alone is a no-op (no tooling file with an allowlisted extension
  carries the literal), and the suite asserts that rather than assuming it.

  `internal/cli/**` STAYS IN. `scripts/cloud-path-escape-check.sh` refuses to
  DISPATCH on it, and that is a CI-cost decision about which PRs pay for a
  Postgres-backed suite. Borrowing it as a decision about what counts as a caller
  is a category error: `internal/cli` is where `bp cloud` calls the worker seam,
  and a corpus that could not see it would report caller-less about routes that
  are called.

  ## The predicate, and what it cannot see

  Fixed string, never a regex: a route's literal PREFIX (up to its first
  `:param`) and its literal TAIL (after its last `:param`) must appear on the
  SAME LINE.

  A CALL-SHAPED predicate — one that also demands `curl` / `http.NewRequest` / a
  verb on that line — is REFUTED, not merely unused: measured on this tree it
  scores 21 of 23 routes caller-less, because Go builds the path and issues the
  request on different lines. A predicate that reds 21 true positives is not
  stricter, it is broken.

  What it cannot see is a path assembled across lines or shell variables
  (`BASE="$CP/v1/internal"` … `"$BASE/platform-deliveries"`). That direction is
  SAFE — an unseen caller scores caller-less, i.e. a FALSE RED a human resolves
  by adding an allowlist row — and it is pinned as a unit test rather than left
  as a hope.
  """

  # Anchored on this file's own directory: cloud/test/barkpark_cloud → repo root.
  @default_repo_root Path.expand("../../..", __DIR__)

  # The five roots. `.github/workflows` and `deploy` are where a CI recorder
  # would live; `internal` and `scripts` are where the workers and the proof
  # scripts live; `cloud/lib` is the plane calling its own seam.
  @roots [".github/workflows", "cloud/lib", "deploy", "internal", "scripts"]

  # Positive extension allowlist. Anything else is not a caller: `.json`, `.txt`,
  # `.golden` and `.service` are data and fixtures, and `.md` is prose.
  @extensions ~w(.go .sh .ex .exs .yml .yaml .py .mjs)

  # Refused BY NAME, each for a measured reason:
  #   tooling/**   ledger prose; not under @roots today, so this is belt-and-braces
  #   *.md         prose. THE load-bearing refusal — see @moduledoc
  #   router.ex    the producer itself. All 23 routes self-hit >= 2 (the route
  #                line plus its own doc block), so including it scores 23/23 CALLED
  #   *_test.go    two Go tests carry a contiguous deprovision literal
  #   *_test.exs   the same shape on the Elixir side
  @refused ["tooling/**", "*.md", "router.ex", "*_test.go", "*_test.exs"]

  @doc "The five declared roots."
  def roots, do: @roots

  @doc "The declared extension allowlist."
  def extensions, do: @extensions

  @doc "The by-name refusals, as declared."
  def refused, do: @refused

  @doc """
  The repo root, or a raise. NEVER a clean tree: a wrong root would walk nothing,
  find no callers, and report all 23 routes caller-less — or, worse, parse no
  routes at all and report a perfectly clean census over an empty population.
  """
  def repo_root!(root \\ @default_repo_root) do
    sentinels = ["scripts/cloud-path-escape-check.sh", "cloud/lib/barkpark_cloud/web/router.ex"]
    missing = Enum.reject(sentinels, &File.regular?(Path.join(root, &1)))

    if missing != [] do
      raise "worker-seam caller census: #{root} is not this repo root " <>
              "(missing #{Enum.join(missing, ", ")})"
    end

    root
  end

  @doc """
  The caller corpus: repo-relative paths, sorted. `roots` / `exts` / `refusals`
  are parameters so the suite can MUTATE the declaration and prove each guard is
  load-bearing, rather than asserting that today's list is today's list.
  """
  def corpus(root, roots \\ @roots, exts \\ @extensions, refusals \\ @refused) do
    roots
    |> Enum.flat_map(&walk(Path.join(root, &1), root))
    |> Enum.filter(&(Path.extname(&1) in exts))
    |> Enum.reject(&refused?(&1, refusals))
    |> Enum.sort()
  end

  @doc "Corpus entries a refusal should have kept out. Empty, or the guard is gone."
  def prose_in_corpus(files) do
    Enum.filter(files, fn rel ->
      String.ends_with?(rel, ".md") or String.starts_with?(rel, "tooling/") or
        Path.basename(rel) == "router.ex" or String.ends_with?(rel, "_test.go") or
        String.ends_with?(rel, "_test.exs")
    end)
  end

  @doc "Every `/v1/internal/**` WRITE route in the router, as `{verb, path}`."
  def write_routes(router_path) do
    routes =
      router_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\s*(post|put|patch|delete)\s+"(\/v1\/internal[^"]*)"\s+do\s*$/, line) do
          [_, verb, path] -> [{String.upcase(verb), path}]
          nil -> []
        end
      end)

    if routes == [] do
      raise "worker-seam caller census: no write routes parsed from #{router_path}"
    end

    routes
  end

  @doc "A route's fixed-string `{prefix, tail}`; both must land on ONE line."
  def split(path) do
    segs = String.split(path, "/")
    params = for {s, i} <- Enum.with_index(segs), String.starts_with?(s, ":"), do: i

    case params do
      [] ->
        {path, ""}

      _ ->
        prefix = segs |> Enum.take(List.first(params)) |> Enum.join("/") |> Kernel.<>("/")

        tail =
          case Enum.drop(segs, List.last(params) + 1) do
            [] -> ""
            rest -> "/" <> Enum.join(rest, "/")
          end

        {prefix, tail}
    end
  end

  @doc "Does ONE line call this route?"
  def line_calls?(line, {prefix, tail}) do
    String.contains?(line, prefix) and (tail == "" or String.contains?(line, tail))
  end

  @doc """
  `%{route => [{file, line}, …]}` over the corpus. One pass per file, every route
  tested per line.
  """
  def callers(root, routes, files) do
    splits = Map.new(routes, fn r -> {r, split(elem(r, 1))} end)
    empty = Map.new(routes, &{&1, []})

    Enum.reduce(files, empty, fn rel, acc ->
      root
      |> Path.join(rel)
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce(acc, fn {line, n}, acc ->
        Enum.reduce(routes, acc, fn route, acc ->
          if line_calls?(line, splits[route]),
            do: Map.update!(acc, route, &[{rel, n} | &1]),
            else: acc
        end)
      end)
    end)
  end

  @doc """
  A route's NAMESPACE — everything above its own last segment.

  `/v1/internal/platform-deliveries` -> `/v1/internal`. This is the conjunct
  `loose_mentions/3` takes a loose spelling against.
  """
  def namespace(path) do
    path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
  end

  @doc """
  The LOOSE spellings of a route's own last segment: kebab (the URL spelling),
  spaced prose, UpperCamel and lowerCamel.
  """
  def loose_spellings(path) do
    seg = path |> String.split("/") |> List.last()
    upper = seg |> String.replace("-", "_") |> Macro.camelize()
    lower = String.downcase(String.at(upper, 0)) <> String.slice(upper, 1..-1//1)
    [seg, String.replace(seg, "-", " "), upper, lower]
  end

  @doc "The snake_case spelling of a route's own last segment — the Postgres table name."
  def snake_spelling(path) do
    path |> String.split("/") |> List.last() |> String.replace("-", "_")
  end

  @doc """
  Loose-spelling mentions of each route's own name in `bodies`, as
  `{file, spelling}`. `spellings` supplies the spellings per path, so the loose
  arm and the snake arm share ONE predicate.

  THE NAMESPACE CONJUNCT, and why it is not a loosening. A loose spelling on its
  own is not evidence of a caller. The last segment of
  `/v1/internal/platform-deliveries` camelizes to `PlatformDeliveries`, which is
  ALSO the Go client method for the unrelated READ route `GET /v1/deliveries`
  (internal/cloudclient/deliveries.go:164), and its snake spelling
  `platform_deliveries` is the Postgres table name. Both collide by substring
  containment of a camelized noun, not by calling anything: `grep -c "/v1/internal"`
  returns 0 in both colliding Go files. So a mention counts only when the SAME
  FILE also types the route's namespace somewhere. A genuine split-across-lines
  caller does type it — the trap shape pinned by "THE INTERPOLATION TRAP" is
  `BASE="$CP/v1/internal"` followed by `curl -X POST "$BASE/platform-deliveries"`,
  and its first line carries the namespace.

  THE HONEST NARROWING: a caller that splits the NAMESPACE ITSELF across lines
  escapes this arm and degrades to caller-less, which arm 1 covers with an
  allowlist row. This arm no longer claims "no mention in ANY spelling"; it
  claims "no mention in any spelling, by a file that also names the seam's
  namespace" — and the wider claim is exactly what fired on a non-caller.
  """
  def loose_mentions(routes, bodies, spellings) do
    for {_verb, path} <- routes,
        ns = namespace(path),
        {rel, body} <- bodies,
        String.contains?(body, ns),
        spelling <- spellings.(path),
        String.contains?(body, spelling),
        do: {rel, spelling}
  end

  @doc "The routes with zero callers in `files`, sorted."
  def caller_less(root, routes, files) do
    root
    |> callers(routes, files)
    |> Enum.filter(fn {_route, hits} -> hits == [] end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp walk(path, root) do
    cond do
      File.regular?(path) -> [Path.relative_to(path, root)]
      File.dir?(path) -> path |> File.ls!() |> Enum.flat_map(&walk(Path.join(path, &1), root))
      true -> []
    end
  end

  defp refused?(rel, refusals) do
    base = Path.basename(rel)

    Enum.any?(refusals, fn
      "tooling/**" -> String.starts_with?(rel, "tooling/")
      "*" <> suffix -> String.ends_with?(base, suffix)
      exact -> base == exact
    end)
  end
end

defmodule BarkparkCloud.WorkerSeamCallerCensusTest do
  @moduledoc """
  Four arms, each able to lose:

    1. NO NEW CALLER-LESS ROUTE — a write route shipped without a caller reds.
    2. THE ALLOWLIST CANNOT ROT — a route that GAINED a caller reds, forcing the
       row to be deleted. Without this the allowlist becomes a graveyard and arm
       1 quietly stops covering every route in it.
    3. THE CORPUS IS DECLARED — a floor on its size (a walk that silently
       stopped recursing would otherwise report a clean tree) and an explicit
       "prose entered the corpus" guard.
    4. THE PREDICATE IS NOT THE PRODUCER — all 23 routes self-hit router.ex at
       least twice, so including the producer would score them all called; and
       the crown's LOOSE spellings are absent from the corpus, so its caller-less
       verdict is not an artefact of predicate strictness.

  Plus the SELF-DECLARATION: `cloud-path-escape-check.sh` is structurally blind
  to this arm's reads, so the arm asserts its own dispatch coverage.
  """

  use ExUnit.Case, async: true

  alias BarkparkCloud.WorkerSeamCallerCensus, as: Seam

  @router Path.expand("../../lib/barkpark_cloud/web/router.ex", __DIR__)
  @escape_check "scripts/cloud-path-escape-check.sh"

  # Measured 2026-08-09: 634 files. The floor is a LOWER BOUND on the walk's
  # liveness, not a headcount — a `File.ls!` that stopped recursing would report
  # every route caller-less, which is at least loud; a filter that swallowed the
  # corpus entirely would report a clean tree, which is not.
  @corpus_floor 550

  # RULED: write routes that ship with no caller in this tree. One row, one
  # reason, and arm 2 deletes it the moment the route gains a caller.
  #
  # EMPTY, and that is the point. dr-w26-s4's single row ruled
  # `POST /v1/internal/platform-deliveries` — the crown's writer seam, merged and
  # correct for two waves and wired to nothing. dr-w26-s5 landed the recorder in
  # `.github/workflows/deploy.yml`, so arm 2 (the anti-rot arm) would RED on the
  # stale row: the route now has a caller. The row is deleted here rather than
  # kept, which is exactly the lifecycle the arm exists to force.
  @caller_less_allowlist []

  setup_all do
    root = Seam.repo_root!()
    files = Seam.corpus(root)
    routes = Seam.write_routes(@router)

    {:ok,
     root: root, files: files, routes: routes, caller_less: Seam.caller_less(root, routes, files)}
  end

  # ---------------------------------------------------------------------------
  # arm 1 — a write route with no caller
  # ---------------------------------------------------------------------------

  test "NO NEW CALLER-LESS ROUTE: every /v1/internal write route is called, or ruled", ctx do
    allowlisted = MapSet.new(@caller_less_allowlist, &elem(&1, 0))
    new = MapSet.difference(MapSet.new(ctx.caller_less), allowlisted)

    assert MapSet.equal?(new, MapSet.new()), """
    write route(s) shipped with NO caller anywhere in the declared corpus
    (#{length(ctx.files)} files over #{Enum.join(Seam.roots(), ", ")}):

    #{fmt_routes(new)}

    A route nothing calls is a producer joined to nothing: it is correct, it is
    merged, and the table behind it stays empty forever. Wire a caller, or add a
    row to @caller_less_allowlist naming WHY it ships unwired and what closes it.
    """
  end

  # ---------------------------------------------------------------------------
  # arm 2 — the allowlist cannot rot
  # ---------------------------------------------------------------------------

  test "THE ALLOWLIST CANNOT ROT: a ruled route that gained a caller reds", ctx do
    allowlisted = MapSet.new(@caller_less_allowlist, &elem(&1, 0))
    stale = MapSet.difference(allowlisted, MapSet.new(ctx.caller_less))

    assert MapSet.equal?(stale, MapSet.new()), """
    allowlisted route(s) now HAVE a caller — delete its allowlist row:

    #{fmt_routes(stale)}

    Keeping the row is how an allowlist becomes a graveyard: arm 1 stops covering
    these routes, and a LATER caller-less regression on the same route ships
    green.
    """

    for {route, reason} <- @caller_less_allowlist do
      assert route in ctx.routes, "#{inspect(route)}: not a write route in #{@router}"
      assert byte_size(reason) > 40, "#{inspect(route)}: a reason this short is not a ruling"

      assert reason =~ ~r/dr-w\d+-[a-z0-9-]+|PR #\d+/,
             "#{inspect(route)}: a ruled row must name the task or PR that closes it"
    end
  end

  # ---------------------------------------------------------------------------
  # arm 3 — the corpus is DECLARED, and prose stays out of it
  # ---------------------------------------------------------------------------

  test "THE CORPUS IS DECLARED: five roots, an extension allowlist, and no prose", ctx do
    # MEASURED first, PINNED second. The order is load-bearing: if the literal
    # pins ran first, every mutation of the declaration would red on "the list is
    # not the list" and the guards below would never be REACHED — which is how a
    # guard quietly stops being provable by mutation.
    assert length(ctx.files) >= @corpus_floor,
           "the corpus walk collapsed to #{length(ctx.files)} files (floor #{@corpus_floor}) — " <>
             "a shrunken corpus reports caller-less about routes that ARE called"

    prose = Seam.prose_in_corpus(ctx.files)

    assert prose == [],
           "prose entered the corpus: #{length(prose)} entries, e.g. " <>
             "#{inspect(Enum.take(prose, 5))}. A file that DESCRIBES a route is not a caller — " <>
             "one curl recipe in a ledger is enough to score this whole census green."

    for rel <- ctx.files do
      assert Path.extname(rel) in Seam.extensions(), "#{rel}: outside the extension allowlist"
    end

    assert Seam.roots() == [".github/workflows", "cloud/lib", "deploy", "internal", "scripts"]
    assert Seam.extensions() == ~w(.go .sh .ex .exs .yml .yaml .py .mjs)
    assert Seam.refused() == ["tooling/**", "*.md", "router.ex", "*_test.go", "*_test.exs"]

    # internal/cli STAYS IN. The dispatcher's refusal to RUN on it is a CI-cost
    # decision; borrowing it as a ruling about what counts as a caller would make
    # the corpus lie, because internal/cli is where `bp cloud` calls the seam.
    assert Enum.any?(ctx.files, &String.starts_with?(&1, "internal/cli/"))
  end

  test "MUTATION D: prose is refused TWICE, and the *.md refusal is the load-bearing one", ctx do
    # tooling/ ALONE is a no-op: no tooling file with an allowlisted extension
    # carries a route literal, so the verdict does not move.
    with_tooling = Seam.corpus(ctx.root, Seam.roots() ++ ["tooling"])
    assert Seam.caller_less(ctx.root, ctx.routes, with_tooling) == ctx.caller_less

    # Dropping ONLY the extension allowlist still keeps prose out — the by-name
    # refusal is the second layer.
    ext_only = Seam.corpus(ctx.root, Seam.roots() ++ ["tooling"], Seam.extensions() ++ [".md"])
    assert Seam.prose_in_corpus(ext_only) == []

    # Dropping BOTH is D441's subtractive corpus, and it is VACUOUS: the crown
    # scores CALLED off ledger prose that describes it in a curl recipe.
    vacuous =
      Seam.corpus(
        ctx.root,
        Seam.roots() ++ ["tooling"],
        Seam.extensions() ++ [".md"],
        Seam.refused() -- ["*.md", "tooling/**"]
      )

    offenders = Seam.prose_in_corpus(vacuous)
    assert offenders != [], "the prose guard cannot fire — it is not a guard"
    assert Enum.any?(offenders, &String.ends_with?(&1, ".md"))

    assert Seam.caller_less(ctx.root, ctx.routes, vacuous) == [],
           "prose in the corpus is supposed to LAUNDER the crown into 'called' — if it no " <>
             "longer does, this mutation has stopped reproducing the vacuity it pins"
  end

  test "FAIL CLOSED: a wrong repo root RAISES rather than reporting a clean tree" do
    assert_raise RuntimeError, ~r/is not this repo root/, fn ->
      Seam.repo_root!(Path.join(System.tmp_dir!(), "definitely-not-the-barkpark-repo"))
    end

    assert_raise RuntimeError, ~r/no write routes parsed/, fn ->
      Seam.write_routes(Path.expand("../../mix.exs", __DIR__))
    end
  end

  # ---------------------------------------------------------------------------
  # arm 4 — the predicate is not the producer, and not merely strict
  # ---------------------------------------------------------------------------

  test "THE PRODUCER SELF-HITS: every one of the 23 routes hits router.ex >= 2 times", ctx do
    lines = @router |> File.read!() |> String.split("\n")

    self_hits =
      Map.new(ctx.routes, fn route ->
        s = Seam.split(elem(route, 1))
        {route, Enum.count(lines, &Seam.line_calls?(&1, s))}
      end)

    assert map_size(self_hits) == 23, "expected 23 write routes, saw #{map_size(self_hits)}"

    {min_route, min_hits} = Enum.min_by(self_hits, &elem(&1, 1))

    assert min_hits >= 2,
           "#{inspect(min_route)} self-hits router.ex only #{min_hits}x — the by-name refusal " <>
             "of router.ex is justified by the MINIMUM over all 23, never by a sample"

    # LOOSE spellings of every CALLER-LESS route's own segment: zero in the
    # corpus. That is what rules out the alternative explanation for arm 1's
    # verdict — that the route IS called and the fixed-string predicate is simply
    # too strict to see it. Nothing in the corpus mentions the seam at all, in
    # any spelling, so strictness is not what made it caller-less.
    #
    # Scoped to the caller-less set on purpose, so it RETIRES itself: the moment
    # a recorder lands, the route leaves this set and the assertion stops asking.
    # Pinning the crown's spellings literally would have turned this into a
    # permanent red on the very PR that fixes the hole.
    bodies = Map.new(ctx.files, &{&1, File.read!(Path.join(ctx.root, &1))})

    loose_hits = Seam.loose_mentions(ctx.caller_less, bodies, &Seam.loose_spellings/1)

    assert loose_hits == [], """
    a caller-less route's name appears in the corpus in a LOOSE spelling, in a
    file that ALSO names the route's namespace:
    #{inspect(loose_hits)}

    Either that IS a caller the fixed-string predicate could not see (split
    across lines — fix the caller to build the path as one literal), or the
    mention is prose that does not belong in a caller root.
    """

    # The snake_case spelling is the Postgres table name the PRODUCER uses, so
    # asserting zero on it tree-wide would measure the producer rather than a
    # caller. It is asserted zero OUTSIDE cloud/lib — where a caller would live.
    outside_producer =
      Enum.reject(bodies, fn {rel, _} -> String.starts_with?(rel, "cloud/lib/") end)

    # The SAME namespace conjunct. Repairing the loose arm alone leaves this one
    # red on the identical collision, `platform_deliveries` in the two Go files.
    snake = Seam.loose_mentions(ctx.caller_less, outside_producer, &[Seam.snake_spelling(&1)])

    assert snake == [],
           "a caller-less seam's snake_case name is outside the producer: #{inspect(snake)}"
  end

  test "THE NAMESPACE CONJUNCT can lose: the spelling alone is not a mention", ctx do
    route = {:post, "/v1/internal/platform-deliveries"}
    assert Seam.namespace("/v1/internal/platform-deliveries") == "/v1/internal"
    assert Seam.snake_spelling("/v1/internal/platform-deliveries") == "platform_deliveries"
    assert "PlatformDeliveries" in Seam.loose_spellings("/v1/internal/platform-deliveries")

    # the collider: the camelized noun, no namespace anywhere in the file
    collider = [{"internal/cloudclient/deliveries.go", ~s|func (c *Client) PlatformDeliveries()|}]
    assert Seam.loose_mentions([route], collider, &Seam.loose_spellings/1) == []

    # the caller: same noun, and the namespace typed on the LINE ABOVE
    caller = [
      {"scripts/x.sh", ~s|BASE="$CP/v1/internal"\ncurl -X POST "$BASE/platform-deliveries"|}
    ]

    assert [{"scripts/x.sh", _} | _] =
             Seam.loose_mentions([route], caller, &Seam.loose_spellings/1)

    # and the real corpus is clean under it, which is what arm 4 asserts.
    #
    # This line used to read `assert ctx.caller_less != []`, pinning a NON-EMPTY
    # caller-less population. dr-w26-s5 emptied that population by wiring the
    # recorder, so the pin would have RED on the very PR that fixed the hole —
    # the same self-defeating shape arm 4's own loose-spelling assertion avoids
    # by scoping itself to the caller-less set. What this arm actually needs is
    # the POSITIVE fact, which is still able to lose: the crown is CALLED, by one
    # contiguous literal on one line of .github/workflows/deploy.yml. Delete the
    # recorder's POST, or split its path across lines, and this reds.
    refute {"POST", "/v1/internal/platform-deliveries"} in ctx.caller_less,
           "the crown is caller-less again — deploy.yml's record-delivery job lost its POST, " <>
             "or the route path stopped being one contiguous literal on one line"
  end

  test "THE INTERPOLATION TRAP: a path split across shell variables scores caller-less" do
    s = Seam.split("/v1/internal/platform-deliveries")

    # positive control — one contiguous literal on one line IS a caller
    assert Seam.line_calls?(~s|curl -X POST "$CP/v1/internal/platform-deliveries"|, s)

    # the trap: the same recorder, assembled across two lines. NOT seen.
    refute Seam.line_calls?(~s|BASE="$CP/v1/internal"|, s)
    refute Seam.line_calls?(~s|curl -X POST "$BASE/platform-deliveries"|, s)

    # The direction is SAFE: an unseen caller scores CALLER-LESS (a false red a
    # human resolves with an allowlist row), never CALLED. This is the honest
    # bound of a fixed-string predicate, pinned rather than hoped for.
  end

  # ---------------------------------------------------------------------------
  # SELF-DECLARATION — the corpus declares itself into the dispatcher
  # ---------------------------------------------------------------------------

  test "SELF-DECLARATION: every root this arm walks is declared in CLOUD_PATHS", ctx do
    body = ctx.root |> Path.join(@escape_check) |> File.read!()
    [_, block] = Regex.run(~r/\nCLOUD_PATHS='([^']*)'/, body)
    declared = block |> String.split("\n") |> Enum.reject(&(&1 == ""))

    assert length(declared) >= 10, "CLOUD_PATHS collapsed to #{length(declared)} entries"

    # cloud-path-escape-check.sh resolves `"../…"` literals out of cloud/lib and
    # cloud/test. This arm has none that escape — it computes a repo root ONCE
    # and joins plain relative names onto it — so the ratchet is structurally
    # blind to every file it reads: it reported the same 10 repo-root reads
    # before this arm existed and after it walked 634 files. The declaration is
    # therefore VOLUNTARY, and a voluntary declaration nothing asserts is a
    # comment. This is the assertion that makes it able to lose.
    for root <- Seam.roots() do
      assert Enum.any?(declared, &(&1 == root or String.starts_with?(&1, root <> "/"))),
             "root #{root} is walked by this arm but nothing in CLOUD_PATHS covers it — " <>
               "a PR editing it would SKIP the Cloud gate that runs this census"
    end

    # The four entries dr-w26-s4 added, by name. `.github/workflows/deploy.yml`
    # is the one that matters most: before it, a deploy.yml-only PR dispatched
    # NOTHING in this set, so the recorder could land — or vanish — with no code
    # gate at all.
    for entry <- ["cloud/lib/**", "deploy/**", "internal/**", ".github/workflows/deploy.yml"] do
      assert entry in declared, "CLOUD_PATHS lost #{entry} — dr-w26-s4's declaration"
    end
  end

  defp fmt_routes(set) do
    case Enum.sort(set) do
      [] -> "(none)"
      rs -> Enum.map_join(rs, "\n", fn {verb, path} -> "  #{verb} #{path}" end)
    end
  end
end
