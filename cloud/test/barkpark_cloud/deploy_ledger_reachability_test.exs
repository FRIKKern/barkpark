defmodule BarkparkCloud.DeployLedgerReachability.Census do
  @moduledoc """
  The reachability census: every PUBLIC `def` in a module, and the call sites
  that reach it from inside `cloud/lib`, read off the Elixir AST
  (`Code.string_to_quoted!/1`) — never off a regex.

  ## Why not a regex (D264, measured, not predicted)

  A grep sweep run during wave 16 scored `deferred?/1` and `not_attempted?/1` at
  ZERO callers and would have had the wave delete two live functions. The sweep
  built its pattern as `grep -E "<name>\\("`, so for `deferred?` the `?` stopped
  being a character and became a REGEX QUANTIFIER: the pattern matched
  `deferre` + an optional `d` + `(`, which appears nowhere, while the real call
  `deferred?(class)` was invisible. Every Elixir name ending `?` or `!` — i.e.
  every predicate and every bang — is under-counted, and under-counted SILENTLY.

  An AST walk cannot have that bug: a function name is an atom, and atoms are
  compared, not matched. `naive_grep_callers/2` keeps the broken sweep alive on
  purpose so the test can assert that it lies and that this walker does not.

  ## What it counts as a caller, and what it refuses to

    * EXTERNAL — a qualified call `DeployLedger.fun(args)` (or a capture
      `&DeployLedger.fun/2`) in any `.ex` file under `cloud/lib` OTHER than the
      module's own file. This is the only bucket that means "an operator can
      get here".
    * INTERNAL — a call inside the module's own file, qualified or local. It
      keeps the function alive but says nothing about reachability from outside;
      an internally-used function that is `def` rather than `defp` is
      over-public, which is a different (smaller) finding than dead.
    * NEITHER — `def`/`defp` HEADS are skipped (a definition is not a call to
      itself) and `@` attribute bodies are skipped entirely, because `@spec
      classes() :: [class()]` parses as a call to `classes/0` and would score
      every specced function as its own caller.

  Default arguments are folded: `def census(from, to, opts \\\\ [])` is declared
  as `census/3` and a two-argument call site counts, because the compiler
  generates the shorter head.

  ## The limit of the claim — read this before trusting a green

  This proves a CALLER EXISTS IN `cloud/lib`. It does NOT prove any route
  returns 200, that a caller is on a reachable branch, or that any deployed
  binary ever executes the line. A function can be REACHABLE here and still be
  unreachable in production behind a 403, a feature flag, or a dead route —
  the census route 403s for every account today (wave 16, D262). Route-level
  reachability is a different instrument and a different slice.
  """

  @type entry :: %{
          name: atom(),
          arity: non_neg_integer(),
          min_arity: non_neg_integer(),
          line: pos_integer()
        }

  @type site :: %{file: binary(), line: pos_integer(), arity: non_neg_integer()}

  @doc "Every public `def` in `path`, folded over clauses, as name/arity entries."
  @spec publics(binary()) :: [entry()]
  def publics(path) do
    path
    |> ast()
    |> collect_defs()
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn {_name, clauses} -> fold_clauses(clauses) end)
    |> Enum.sort_by(&{&1.name, &1.arity})
  end

  @doc """
  Call sites for `entries` across every `.ex` file under `root`, split into
  `:external` (another file) and `:internal` (the defining file itself).

  `opts[:walker] == :broken` reproduces a walker that matches no call shape at
  all — what a future syntax this module does not know looks like — so the
  anti-vacuity floor can be shown to LOSE.
  """
  @spec callers([entry()], binary(), binary(), keyword()) :: %{
          {atom(), non_neg_integer()} => %{external: [site()], internal: [site()]}
        }
  def callers(entries, root, own_file, opts \\ []) do
    own = Path.expand(own_file)
    names = MapSet.new(entries, & &1.name)

    empty =
      Map.new(entries, fn e -> {{e.name, e.arity}, %{external: [], internal: []}} end)

    root
    |> ex_files()
    |> Enum.reduce(empty, fn file, acc ->
      bucket = if Path.expand(file) == own, do: :internal, else: :external

      file
      |> calls(names, Keyword.put(opts, :locals, bucket == :internal))
      |> Enum.reduce(acc, fn {name, arity, line}, acc ->
        case entry_for(entries, name, arity) do
          nil ->
            acc

          entry ->
            site = %{file: relative(file, root), line: line, arity: arity}
            update_in(acc, [{entry.name, entry.arity}, bucket], &[site | &1])
        end
      end)
    end)
    |> Map.new(fn {k, v} ->
      {k,
       %{
         external: Enum.sort_by(v.external, &{&1.file, &1.line}),
         internal: Enum.sort_by(v.internal, &{&1.file, &1.line})
       }}
    end)
  end

  @doc """
  The BROKEN sweep from D264, preserved verbatim so the test can prove it lies:
  an unescaped `<name>\\(` regex over the source. For any name ending `?` or
  `!` the suffix is a quantifier and the count silently collapses to zero.
  """
  @spec naive_grep_callers(atom(), binary()) :: non_neg_integer()
  def naive_grep_callers(name, root) do
    grep_count(Regex.compile!("#{name}\\("), root)
  end

  @doc "The same sweep with the name escaped — what the grep SHOULD have been."
  @spec escaped_grep_callers(atom(), binary()) :: non_neg_integer()
  def escaped_grep_callers(name, root) do
    grep_count(Regex.compile!("#{Regex.escape(to_string(name))}\\("), root)
  end

  defp grep_count(regex, root) do
    root
    |> ex_files()
    |> Enum.reduce(0, fn file, acc ->
      acc + (file |> File.read!() |> String.split("\n") |> Enum.count(&Regex.match?(regex, &1)))
    end)
  end

  @doc "Every `.ex` file under `root`, sorted."
  @spec ex_files(binary()) :: [binary()]
  def ex_files(root) do
    root |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort()
  end

  # ---------------------------------------------------------------------------

  defp ast(path), do: path |> File.read!() |> Code.string_to_quoted!(columns: false)

  defp collect_defs(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:@, _, _}, acc ->
          {nil, acc}

        {:def, meta, [head | _body]}, acc ->
          case head_sig(head) do
            nil -> {nil, acc}
            {name, args} -> {nil, [%{name: name, args: args, line: meta[:line]} | acc]}
          end

        {:defp, _, _}, acc ->
          {nil, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # A guarded head is `{:when, _, [head, guard]}`; unwrapping it is the blind
  # spot the payload census measured at 14 lost keys, so it is unwrapped here.
  defp head_sig({:when, _, [head | _]}), do: head_sig(head)
  defp head_sig({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp head_sig({name, _, nil}) when is_atom(name), do: {name, []}
  defp head_sig(_), do: nil

  # Clauses of one name collapse to one entry per max arity, carrying the
  # smallest arity its default arguments can be called at.
  defp fold_clauses(clauses) do
    clauses
    |> Enum.map(fn c ->
      arity = length(c.args)
      defaults = Enum.count(c.args, &default_arg?/1)
      %{name: c.name, arity: arity, min_arity: arity - defaults, line: c.line}
    end)
    |> Enum.group_by(& &1.arity)
    |> Enum.map(fn {_arity, [first | rest]} ->
      Enum.reduce(rest, first, fn e, acc ->
        %{acc | min_arity: min(acc.min_arity, e.min_arity), line: min(acc.line, e.line)}
      end)
    end)
  end

  defp default_arg?({:\\, _, _}), do: true
  defp default_arg?(_), do: false

  defp entry_for(entries, name, arity) do
    Enum.find(entries, fn e -> e.name == name and arity >= e.min_arity and arity <= e.arity end)
  end

  defp calls(file, names, opts) do
    if opts[:walker] == :broken do
      []
    else
      locals? = Keyword.get(opts, :locals, false)

      {_, acc} =
        file
        |> ast()
        |> Macro.prewalk([], fn node, acc -> record(node, names, locals?, acc) end)

      Enum.reverse(acc)
    end
  end

  # `@spec classes() :: [class()]` is a call node. Attribute bodies are not code.
  defp record({:@, _, _}, _names, _locals?, acc), do: {nil, acc}

  # A definition head is not a call to itself; its body still is.
  defp record({op, _, [_head | body]}, _names, _locals?, acc)
       when op in [:def, :defp, :defmacro, :defmacrop] and is_list(body) do
    {body, acc}
  end

  # `&Mod.fun/2` — recorded whole, because its inner node carries `[]` args and
  # would otherwise be counted as a zero-arity call.
  defp record(
         {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, mods}, name]}, meta, []}, arity]}]},
         names,
         _locals?,
         acc
       )
       when is_atom(name) and is_integer(arity) do
    if List.last(mods) == :DeployLedger and name in names do
      {nil, [{name, arity, meta[:line]} | acc]}
    else
      {nil, acc}
    end
  end

  # `&fun/2` — a local capture, only meaningful inside the defining module.
  defp record({:&, _, [{:/, _, [{name, meta, ctx}, arity]}]}, names, locals?, acc)
       when is_atom(name) and is_integer(arity) and (is_atom(ctx) or is_nil(ctx)) do
    if locals? and name in names, do: {nil, [{name, arity, meta[:line]} | acc]}, else: {nil, acc}
  end

  # `Mod.fun(args)`
  defp record({{:., _, [{:__aliases__, _, mods}, name]}, meta, args} = node, names, _locals?, acc)
       when is_atom(name) and is_list(args) do
    if List.last(mods) == :DeployLedger and name in names do
      {node, [{name, length(args), meta[:line]} | acc]}
    else
      {node, acc}
    end
  end

  # `fun(args)` — an UNQUALIFIED call. Counted only while walking the defining
  # file. Elsewhere it is a different module's function that happens to share a
  # name, and this codebase forks names on purpose. The measured precedent was
  # `PublishClock`, which declared its OWN `census/3`, `min_sample/0` and
  # `rate/2`: counting bare `census(...)` in publish_clock.ex as a caller of the
  # LEDGER's `census/3` was the exact false-GREEN this census exists to not
  # produce — measured, then fixed. That module was DELETED as reader-less
  # (dr-w26-s6), so the example is history; the rule it proved is not, and the
  # next forked name will arrive without warning.
  defp record({name, meta, args} = node, names, locals?, acc)
       when is_atom(name) and is_list(args) do
    if locals? and name in names,
      do: {node, [{name, length(args), meta[:line]} | acc]},
      else: {node, acc}
  end

  defp record(node, _names, _locals?, acc), do: {node, acc}

  defp relative(file, root) do
    Path.relative_to(Path.expand(file), Path.expand(Path.join(root, "../..")))
  end
end

defmodule BarkparkCloud.DeployLedgerReachabilityTest do
  @moduledoc """
  THE DEPLOY LEDGER'S PUBLIC SURFACE DECLARES ITS OWN REACHABILITY — and the
  declaration can lose in BOTH directions (deploy-reliability wave 16).

  ## What was wrong with the rule this replaces

  Charter D245 made a rule of a manual witness: rename the public function,
  recompile, and the compile MUST FAIL. Run this session on two trees, it
  carried ZERO bits:

    * on a tree with ZERO callers it returned RC=1 — a FALSE RED, because
      renaming the `def` orphans the `@spec` two lines above it and compilation
      aborts inside `deploy_ledger.ex` itself, never reaching any caller;
    * on a tree with TWO callers it returned RC=1 for the byte-identical wrong
      reason;
    * and with the `@spec` renamed too, so the module compiles, the tree WITH
      two callers returned RC=0, because `cloud/mix.exs` sets no
      `warnings_as_errors` and a cross-module undefined call is a WARNING.

  The corrected witness (D263) is `rename BOTH the def and its @spec, then
  MIX_ENV=dev mix compile --force --warnings-as-errors`, and it is re-derived
  in this slice's task evidence. But a witness a human has to remember to run
  is not a guard. This file is the guard: it computes the same fact on every
  test run and asserts it against a COMMITTED table, so the answer is in the
  diff of any PR that changes it.

  ## The three buckets

    * REACHABLE — at least one qualified call site in `cloud/lib` outside the
      module. Somebody can get here.
    * INTERNAL_ONLY — used only inside `deploy_ledger.ex`. Alive, but OVER-PUBLIC:
      `def` where `defp` would do. A smaller finding than dead, and a different
      one, so it gets its own bucket instead of being laundered into either.
    * UNREACHABLE — no caller in `cloud/lib` at all. Every row carries a reason
      and, where one exists, the PR or task that will give it a caller. TEST
      references do NOT count: `classes/0` has NINE of them and zero lib
      callers, which is the D245 disease verbatim — a function the suite keeps
      warm and no operator can reach.

  ## The limit of the claim

  A REACHABLE row proves A CALLER EXISTS IN `cloud/lib`. It does NOT prove any
  route returns 200, that the call site is on a live branch, or that any
  deployed binary executes it — the census route 403s for every account today
  (wave 16, D262). Route-level reachability is a different instrument.
  """

  use ExUnit.Case, async: true

  alias BarkparkCloud.DeployLedgerReachability.Census

  @ledger Path.expand("../../lib/barkpark_cloud/deploy_ledger.ex", __DIR__)
  @lib Path.expand("../../lib", __DIR__)
  @self __ENV__.file

  # ---------------------------------------------------------------------------
  # THE DECLARED TABLE — `{name, arity, bucket, reason}`, reason REQUIRED.
  # ---------------------------------------------------------------------------
  # Measured on this tree with the AST census below, not with grep. The grep
  # sweep this replaces got FOUR of these rows wrong: it scored `min_sample/0`
  # reachable off `router.ex:3534`, which is a COMMENT; it scored `classify/2`
  # reachable off bare `classify(` calls in `apns.ex` and `fcm.ex`, which are
  # those modules' OWN classify; it scored `label/1` reachable off
  # `delivery_reason.ex`, same collision; and it scored `deferred?/1` and
  # `not_attempted?/1` at zero because `?` is a regex quantifier (D264).
  @declared [
    # -- REACHABLE ------------------------------------------------------------
    {:census, 3, :reachable,
     "GET /v1/cloud/deployments/census — router.ex calls it with the parsed window. THE deploy-reliability headline read."},
    {:classify, 1, :reachable,
     "router.ex serialises `failure_class` off a row, and sites/deploy.ex classifies a deferral at re-queue time."},
    {:list_page, 2, :reachable,
     "router.ex's keyset deployment list — the paged read behind `bp cloud deployments`."},
    {:parse_window, 2, :reachable,
     "router.ex parses ?from/?to before census/3; the refusal arm is what stops an unbounded scan."},
    {:delivery, 3, :reachable,
     "THE D136 delivery estimator, ROUTED AT LAST. Its UNREACHABLE row said \"PR #10401 adds the caller; when it merges this row moves to :reachable and the move is the proof\" — this is that move. `Web.Router.deploy_census_json/2` (router.ex:9489) puts it on the operator census envelope, so `renderDeployDelivery`'s `d == nil` \"NOT MEASURED\" arm stops being the only arm that ever executes."},
    {:rate, 2, :reachable,
     "the D34 rate constructor. WAS :internal_only (three uses inside census/3 and delivery/3, public only because the payload census pairs it with the Go `DeployRate` struct); dr-w10-s1 gives it an external caller. `Web.Router`'s `no_deploy_surface/0` builds the all-nil `deploy_rate` sentinel with `DeployLedger.rate(0, 0)` rather than hand-writing a map, so the sentinel a consumer destructures is the SAME SHAPE as a real refusing rate BY CONSTRUCTION — hand-writing it is how a sentinel and its measured twin drift apart, which is the defect `@unmetered_pressure`'s own shape test exists to catch."},
    {:box_rates, 3, :reachable,
     "THE PER-BOX DEPLOY VITAL (dr-w10-s1). Its ONE caller is `Web.Router`'s GET /v1/barkparks handler, which prefetches it beside the pmap/dmap/hmap/qmap trio and threads it into `barkpark_json/6` — so the number that says a box is failing 46.28% of its terminal deploys reaches the fleet row instead of sitting one JOIN away in the same database, read by nothing. It is public for that route and for nothing else; its bucket is :reachable from the day it lands, which is the whole D136 point (server key + Go field + rendered column in ONE PR)."},
    {:min_sample, 0, :reachable,
     "THE REFUSAL FLOOR, CALLED AT LAST (dr-bl-rate-notice). Its UNREACHABLE row read \"TWO test references and ZERO lib callers; `census/3` reads the `@min_sample` ATTRIBUTE directly, and `router.ex:3534` names the function only in a COMMENT\" — this is the move that closes it. `Notifications.DeployRateAlert.body/2` interpolates `DeployLedger.min_sample()` into the sentence a human reads (\"A RATE REFUSES ITSELF BELOW n = 200\"), and `deploy_rate_alert_worker_test.exs` asserts the rate node's `min_sample` EQUALS this accessor — so the floor the email quotes and the floor the census enforces are one value, and a change to `@min_sample` cannot leave a stale number in an operator's inbox."},
    {:refusal_phase, 1, :reachable,
     "start-vs-poll refusal phase, ROUTED AT LAST — the same closer as delivery/3 above, landed by the same PR. `site_deployment_json/3` reads it off the RAW failure_reason, so start-vs-poll is legible over HTTP instead of living only in this suite."},

    # -- INTERNAL_ONLY — over-public, alive ------------------------------------
    {:classify, 2, :internal_only,
     "the (stage, reason) arm. `classify/1` delegates to it; no other module reaches it. `defp` plus a public wrapper would say the same thing more honestly."},
    {:label, 1, :internal_only,
     "class -> human one-liner, used once while building the census class table."},
    {:deferred?, 1, :internal_only,
     "the deferral predicate, used inside census/3's fold. THE `?`-TRAP ROW: the grep sweep scored this at zero and would have deleted a live function."},
    {:not_attempted?, 1, :internal_only,
     "the never-attempted predicate that keeps rows out of the rate DENOMINATOR. Same `?`-trap as deferred?/1, same false zero."},
    {:agency, 1, :internal_only,
     "WHO a failure class accuses (D148/D242). `class_rows/3` reads it while building the census class table, so the accusation rides the same row as the count and reaches an operator through `Web.Router.deploy_census_json/2`'s existing whole-map serialisation — no new route, and no edit to router.ex, which is a sibling fence. Over-public rather than `defp` because the assertion suite calls it directly on named classes."},
    {:encode_cursor, 1, :internal_only,
     "keyset cursor writer, used by list_page/2 when it hands back a next page."},
    {:decode_cursor, 1, :internal_only,
     "keyset cursor reader, used by list_page/2 on the way in. Public so the cursor SHAPE test can round-trip it."},

    # -- UNREACHABLE — the allowlist, reason + closer ---------------------------
    {:classes, 0, :unreachable,
     "the named-class list. NINE test references, ZERO lib callers — the D245 disease verbatim: a suite keeps it warm and no operator can reach it. No route exposes the class vocabulary; filed as wave-16 follow-up rather than deleted, because the class list is the thing a CLI needs to render a legend."},
    {:deferred_classes, 0, :unreachable,
     "the deferral vocabulary. THREE test references, ZERO lib callers; `deferred?/1` answers the membership question internally, so this accessor exists for no reader. Same follow-up as classes/0."},
    # ALLOWLISTED WITH A REASON, both of them, and the reason is the same one:
    # they exist so an ASSERTION can be keyed off the enums instead of a
    # hand-list. dr-w16-s3 deleted `not_attempted_classes/0` as the one
    # genuinely dead public and set equality kept it deleted — this is the
    # commit that re-adds it, and it is re-added WITH a stated reader rather
    # than smuggled back in.
    {:not_attempted_classes, 0, :unreachable,
     "the never-attempted vocabulary. ZERO lib callers; `not_attempted?/1` answers MEMBERSHIP inside census/3 and cannot ENUMERATE. Its reader is the agency-map exhaustiveness assertion (D242), which must cover `classes/0 ++ not_attempted_classes/0` — every value classify/2 can return — off the ENUMS, because a hand-listed set is a second place to forget and reproduces D224 with a green. Deleted by dr-w16-s3 when nothing at all read it; re-added by dr-w31-s3 with that reader named. CLOSER: the class vocabulary reaches an operator only when a route or the CLI renders a legend — the same follow-up as classes/0 and deferred_classes/0."},
    {:agency_map, 0, :unreachable,
     "the full class -> agency map. ZERO lib callers by design: `agency/1` is the READ path (census/3 uses it, see its :internal_only row) and answers per class, but it cannot list the map's KEYS, so the second direction of the exhaustiveness assertion — 'a key that is not a class' — is unprovable without this accessor. That direction is the one that catches an agency for a class somebody renamed, which is the failure that let an 18-class taxonomy and a 17-key map merge past each other. Allowlisted rather than deleted because deleting it deletes that direction. CLOSER: it stops being unreachable the day a lib caller needs the whole map (a legend, or an agency roll-up), not before."}
  ]

  # ---------------------------------------------------------------------------
  # ANTI-VACUITY FLOORS — a walker that quietly stopped matching reports a clean
  # tree and passes, which is the failure mode this whole file exists to not
  # have. Both floors are set EQUAL to the measured population, not comfortably
  # under it, and a legitimate change RAISES them in the same commit — where the
  # set-equality assertions red on that same change anyway, so a floor can never
  # be the only thing a change has to satisfy.
  @publics_floor 19
  @call_sites_floor 21

  # ---------------------------------------------------------------------------

  defp publics, do: Census.publics(@ledger)

  defp measured do
    entries = publics()
    {entries, Census.callers(entries, @lib, @ledger)}
  end

  defp bucket(%{external: [_ | _]}), do: :reachable
  defp bucket(%{internal: [_ | _]}), do: :internal_only
  defp bucket(_), do: :unreachable

  defp declared_set, do: MapSet.new(@declared, fn {n, a, _b, _r} -> {n, a} end)

  defp declared_bucket(name, arity) do
    Enum.find_value(@declared, fn {n, a, b, _r} -> if {n, a} == {name, arity}, do: b end)
  end

  defp declared_in(bucket) do
    @declared |> Enum.filter(&(elem(&1, 2) == bucket)) |> MapSet.new(&{elem(&1, 0), elem(&1, 1)})
  end

  defp measured_in(callers, bucket) do
    callers
    |> Enum.filter(fn {_key, sites} -> bucket(sites) == bucket end)
    |> MapSet.new(fn {key, _sites} -> key end)
  end

  defp fmt(set) do
    case Enum.sort(set) do
      [] -> "(none)"
      keys -> Enum.map_join(keys, ", ", fn {n, a} -> "#{n}/#{a}" end)
    end
  end

  defp source_line(file, line) do
    Path.expand(file, Path.join(@lib, "../.."))
    |> File.read!()
    |> String.split("\n")
    |> Enum.at(line - 1, "")
  end

  # ---------------------------------------------------------------------------
  # The declaration, both directions
  # ---------------------------------------------------------------------------

  test "the DECLARED table and the module's public surface are the SAME SET, both directions" do
    actual = MapSet.new(publics(), &{&1.name, &1.arity})

    assert actual == declared_set(), """
    the public surface of deploy_ledger.ex moved.

      new public, UNDECLARED (declare its bucket — a new public with no caller is
      DEAD ON ARRIVAL and must say so, not pass silently):
        #{fmt(MapSet.difference(actual, declared_set()))}
      declared but GONE (deleted or made private — delete its row):
        #{fmt(MapSet.difference(declared_set(), actual))}
    """
  end

  test "every declared row's BUCKET matches its measured callers" do
    {entries, callers} = measured()

    for e <- entries do
      sites = callers[{e.name, e.arity}]
      actual = bucket(sites)
      declared = declared_bucket(e.name, e.arity)

      assert actual == declared, """
      #{e.name}/#{e.arity}: declared #{inspect(declared)}, measured #{inspect(actual)}.

        external callers: #{sites_fmt(sites.external)}
        internal callers: #{sites_fmt(sites.internal)}

      #{move_hint(declared, actual)}
      """
    end
  end

  test "the UNREACHABLE set is equal in BOTH directions — a row that gained a caller REDS" do
    {_entries, callers} = measured()
    actual = measured_in(callers, :unreachable)
    expected = declared_in(:unreachable)

    assert actual == expected, """
    the UNREACHABLE set moved.

      newly unreachable (a public with NO caller in cloud/lib — give it a caller,
      make it private, delete it, or allowlist it WITH A REASON):
        #{fmt(MapSet.difference(actual, expected))}
      no longer unreachable (allowlisted as dead but now CALLED — DELETE the
      allowlist row and re-declare it :reachable or :internal_only):
        #{fmt(MapSet.difference(expected, actual))}
    """
  end

  test "the REACHABLE set is equal in BOTH directions, and every site is a QUALIFIED call" do
    {_entries, callers} = measured()

    assert measured_in(callers, :reachable) == declared_in(:reachable)

    # Every external site must literally name the module. This is the guard
    # against the collision that fooled the grep sweep: `PublishClock` HAD its
    # own `census/3`, `min_sample/0` and `rate/2` (deleted as reader-less by
    # dr-w26-s6), and `apns.ex`/`fcm.ex` still have their own `classify/2` —
    # a LIVE example, so this guard is not defending against history alone.
    # If this census ever starts counting bare local
    # calls in a foreign file again, this reds.
    for {{name, arity}, sites} <- callers, site <- sites.external do
      line = source_line(site.file, site.line)

      assert line =~ "DeployLedger",
             "#{name}/#{arity}: #{site.file}:#{site.line} was counted as an external caller, " <>
               "but the line does not name DeployLedger — a same-named function in another " <>
               "module was miscounted:\n  #{String.trim(line)}"
    end
  end

  # ---------------------------------------------------------------------------
  # THE `?`-QUANTIFIER TRAP (D264)
  # ---------------------------------------------------------------------------

  test "`?`-SUFFIXED NAMES: the AST census counts what the D264 grep sweep scores at ZERO" do
    root = Path.join(System.tmp_dir!(), "dl_reach_fixture_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "fixture.ex"), """
    defmodule ReachabilityFixture do
      alias BarkparkCloud.DeployLedger

      def a(class), do: DeployLedger.deferred?(class)
      def b(class), do: DeployLedger.not_attempted?(class)
      def c(row), do: DeployLedger.classify(row)
    end
    """)

    callers = Census.callers(publics(), root, @ledger)

    # The census sees all three, `?`-suffixed or not.
    assert length(callers[{:deferred?, 1}].external) == 1
    assert length(callers[{:not_attempted?, 1}].external) == 1
    assert length(callers[{:classify, 1}].external) == 1

    # The sweep it replaces sees the plain name and NOTHING ELSE, because in
    # `deferred?\\(` the `?` makes the preceding `d` optional: the pattern is
    # `deferre` + maybe `d` + `(`, which the real call site does not contain.
    assert Census.naive_grep_callers(:classify, root) == 1
    assert Census.naive_grep_callers(:deferred?, root) == 0
    assert Census.naive_grep_callers(:not_attempted?, root) == 0

    # And the difference is the quantifier and nothing else: escape the name and
    # the same sweep finds the same call.
    assert Census.escaped_grep_callers(:deferred?, root) == 1
    assert Census.escaped_grep_callers(:not_attempted?, root) == 1
  end

  test "`?`-SUFFIXED NAMES on the REAL tree: deferred?/1 and not_attempted?/1 are ALIVE" do
    {_entries, callers} = measured()

    for name <- [:deferred?, :not_attempted?] do
      sites = callers[{name, 1}].internal

      assert sites != [],
             "#{name}/1 measured ZERO callers — if that is a grep-shaped false zero this " <>
               "census has regrown D264's bug; check Census.record/4 before believing it"

      # Not just a count: the source at each site must contain the name with its
      # `?` intact, so a miscount cannot hide behind a plausible number.
      for site <- sites do
        assert source_line(site.file, site.line) =~ "#{name}("
      end
    end

    assert declared_bucket(:deferred?, 1) == :internal_only
    assert declared_bucket(:not_attempted?, 1) == :internal_only
  end

  # ---------------------------------------------------------------------------
  # The instrument can lose
  # ---------------------------------------------------------------------------

  test "ANTI-VACUITY FLOOR: a broken walker REFUSES rather than reporting a clean tree" do
    {entries, callers} = measured()

    assert length(entries) >= @publics_floor,
           "only #{length(entries)} public def(s) collected, floor is #{@publics_floor} — the " <>
             "EXTRACTOR is broken, not the module shrunk. Check Census.collect_defs/1 for a " <>
             "def syntax it does not match before touching the floor."

    assert total_sites(callers) >= @call_sites_floor,
           "only #{total_sites(callers)} call site(s) collected, floor is #{@call_sites_floor}"

    # And the floor can LOSE: the identical assertion against a walker that
    # matches no call shape — what a future syntax looks like from in here.
    broken = Census.callers(entries, @lib, @ledger, walker: :broken)
    assert total_sites(broken) == 0

    assert_raise ExUnit.AssertionError, fn ->
      assert total_sites(broken) >= @call_sites_floor
    end

    # With the walker dead, EVERY public reads unreachable — i.e. a silent
    # extractor failure surfaces as a loud table mismatch, not as a green.
    assert MapSet.size(measured_in(broken, :unreachable)) == length(entries)
  end

  test "the extractor is not fooled by @spec, by defp, or by a foreign same-named function" do
    names = MapSet.new(publics(), & &1.name)

    # `@spec deferral_code(...)` parses as a call to a function of that name and
    # `deferral_code` is DEFP — neither may surface as a public.
    refute :deferral_code in names
    refute :classify_deferred in names

    # Defaults fold: `def census(from, to, opts \\\\ [])` is census/3, and the
    # two-argument call site in router.ex is what makes it reachable.
    census = Enum.find(publics(), &(&1.name == :census))
    assert {census.arity, census.min_arity} == {3, 2}

    {_entries, callers} = measured()

    # THREE external call sites, and the multiset is PINNED — dr-w16-s6 widened
    # this from the single-element `[%{arity: 2}]` it was, because the operator
    # route (`census(from, to)`, arity 2) 403s for every real account and the
    # team-scoped route (`census(from, to, site_ids: …)`, arity 3) is the read a
    # non-operator can actually reach. dr-w28-s5 widened it again, ON PURPOSE,
    # for the THIRD site: `Notifications.DigestEmail.window_health/3` in
    # `notifications/digest_email.ex`, which reads
    # `census(from, to, site_ids: …, site_limit: 0)` — arity 3, `site_ids`
    # because the digest is delivered per team and a fleet-wide total inside a
    # per-team email is a cross-team disclosure, and `site_limit: 0` because the
    # email reports a RATE and never a per-site league table (counts and
    # percentages name nobody).
    #
    # Widened by naming the EXACT arity MULTISET, not by loosening the match:
    # `!= []` or a `>= 1` count would admit a fourth entry point silently, and
    # "exactly one census computation" is the property this row exists to hold.
    # A new caller must edit this line on purpose. Nor may a new consumer be
    # hidden behind a `DeployLedger` wrapper: `Census.callers/4` buckets a site
    # `:internal` iff the file IS deploy_ledger.ex, so a wrapper would hold this
    # list at `[2, 3]` and conceal the consumer permanently.
    arities = census_caller_arities(callers)
    assert arities == [2, 3, 3]

    # AND THE WIDENED FORM CAN STILL LOSE. The same assertion against the walker
    # that matches no call shape — a widening that survived a dead extractor
    # would be a vacuity, which is exactly what this file exists to refuse.
    broken = Census.callers(publics(), @lib, @ledger, walker: :broken)
    assert census_caller_arities(broken) == []

    assert_raise ExUnit.AssertionError, fn ->
      assert census_caller_arities(broken) == [2, 3, 3]
    end
  end

  defp census_caller_arities(callers) do
    callers
    |> Map.get({:census, 3}, %{external: []})
    |> Map.fetch!(:external)
    |> Enum.map(& &1.arity)
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------
  # The declaration itself
  # ---------------------------------------------------------------------------

  test "every declared row names a real bucket and carries a reason that is a RULING" do
    for {name, arity, bucket, reason} = row <- @declared do
      assert bucket in [:reachable, :internal_only, :unreachable],
             "#{inspect(row)}: unknown bucket"

      assert is_atom(name) and is_integer(arity)

      assert byte_size(reason) > 60,
             "#{name}/#{arity}: a reason this short is not a ruling"
    end

    assert length(Enum.uniq(@declared)) == length(@declared)
    assert MapSet.size(declared_set()) == length(@declared)

    # Every UNREACHABLE row must say what the evidence is or who closes it — a
    # bare "unused" turns the allowlist into a junk drawer.
    for {name, arity, :unreachable, reason} <- @declared do
      assert reason =~ ~r/ZERO lib callers|PR #\d+|follow-up/,
             "#{name}/#{arity}: an UNREACHABLE row must state its census evidence or its closer"
    end

    # If this ever reads zero the table has stopped being able to say "dead".
    assert MapSet.size(declared_in(:unreachable)) > 0
  end

  test "the moduledoc states the LIMIT of the claim" do
    src = File.read!(@self)

    assert src =~ "It does NOT prove any route returns 200"
    assert src =~ "proves A CALLER EXISTS IN `cloud/lib`"
  end

  # ---------------------------------------------------------------------------

  defp total_sites(callers) do
    Enum.reduce(callers, 0, fn {_k, s}, acc -> acc + length(s.external) + length(s.internal) end)
  end

  defp sites_fmt([]), do: "(none)"

  defp sites_fmt(sites),
    do: Enum.map_join(sites, ", ", fn s -> "#{s.file}:#{s.line}/#{s.arity}" end)

  defp move_hint(:unreachable, :reachable),
    do:
      "It GAINED a caller: delete its UNREACHABLE allowlist row and declare it :reachable. This is the good direction."

  defp move_hint(:reachable, :unreachable),
    do:
      "It LOST its last caller in cloud/lib. Either the caller moved (re-point this row) or the feature just became unreachable to every operator — which is the whole point of this file."

  defp move_hint(:internal_only, :unreachable),
    do:
      "Its last in-module use is gone. It is now dead code: delete it, or allowlist it WITH A REASON."

  defp move_hint(_declared, :internal_only),
    do:
      "It is used only inside deploy_ledger.ex now — over-public. Re-declare it :internal_only, or give it the caller it was supposed to have."

  defp move_hint(_declared, _actual), do: ""
end
