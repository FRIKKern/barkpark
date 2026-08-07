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

  @router Path.expand("../../lib/barkpark_cloud/web/router.ex", __DIR__)
  @ledger Path.expand("../../lib/barkpark_cloud/deploy_ledger.ex", __DIR__)
  @cloudclient Path.expand("../../../internal/cloudclient", __DIR__)

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
    %{name: "DeployLedger.census/3", file: @ledger, entry: {:census, 3}, go: "DeployCensus"},
    %{
      name: "DeployLedger.census/3 window",
      file: @ledger,
      entry: {:census, 3},
      nested: "window",
      go: "DeployCensusWindow"
    },
    %{name: "DeployLedger.rate/2", file: @ledger, entry: {:rate, 2}, go: "DeployRate"}
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
    {"DeployLedger.rate/2", :phantom, "basis",
     "dr-w16-bl-emit-rate-basis — THE EMITTER IS UNBUILT AND NOW OWNED, same dead citation as the row above (#10014, CLOSED). This is the D34 convention label that says WHICH denominator a rate was taken over; until it is emitted every rate on the wire decodes basis as \"\". Thread it as a REAL argument, never the stranded branch's default arg (D199)."},
    {"DeployLedger.census/3", :phantom, "delivery",
     "PR #10192 ships the Go reader with the estimator (D136); the route that emits it is dr-w11-s4-followup-emit-delivery-on-route. Decodes to nil until that lands, which is exactly what the pointer type is for."}
  ]

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
  # Delete the row the moment the route emits the key — the "no longer phantom"
  # arm reds if you forget, which is the point.

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
  @emitted_floor 108
  @go_tag_floor 221

  # The barkpark_json family specifically, because it is where blind spot (1) was
  # measured: 56 keys with the :when unwrap, 42 without.
  @barkpark_family_keys 56
  @barkpark_family_keys_blind 42

  # ---------------------------------------------------------------------------

  defp emitted(%{file: file, entry: entry} = pair, opts \\ []) do
    p = Extract.payload(file, entry, opts)

    case Map.get(pair, :nested) do
      nil -> %{keys: p.top, unresolvable: p.unresolvable}
      key -> %{keys: Map.get(p.nested, key, MapSet.new()), unresolvable: p.unresolvable}
    end
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

    # The base literal is 35 keys — what a regex would report. The pipeline adds
    # the four job-status keys, the two list keys, and `pressure`.
    assert MapSet.size(p.top) == 42

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
    assert total_emitted([]) >= @emitted_floor,
           "only #{total_emitted([])} emitted key(s) collected, floor is #{@emitted_floor} — " <>
             "the EXTRACTOR is broken, not the payload shrunk. Check Extract.clauses/4 " <>
             "(a new def syntax it does not match) before touching the floor."

    # And the floor can LOSE: run the identical assertion against a walker that
    # matches nothing, which is what a future unmatched syntax looks like.
    assert_raise ExUnit.AssertionError, fn ->
      broken = total_emitted(walker: :broken)

      assert broken >= @emitted_floor,
             "only #{broken} emitted key(s) collected, floor is #{@emitted_floor}"
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

    assert MapSet.size(Go.all_tags(src)) >= @go_tag_floor,
           "only #{MapSet.size(Go.all_tags(src))} json tag(s) found in internal/cloudclient, " <>
             "floor is #{@go_tag_floor} — the TAG SCANNER is broken, not the package empty."
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

  defp barkpark, do: Enum.find(@pairs, &(&1.name == "barkpark_json/4"))
  defp pressure, do: Enum.find(@pairs, &(&1.name == "barkpark_json/4 pressure"))

  defp fmt(set) do
    case Enum.sort(set) do
      [] -> "(none)"
      keys -> Enum.join(keys, ", ")
    end
  end
end
