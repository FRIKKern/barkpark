defmodule BarkparkCloud.Web.RouterModuledocTableTest do
  @moduledoc """
  Tripwire: the `Router` `@moduledoc` "Route table" is a hand-maintained mirror of
  the `Plug.Router` match clauses, and it drifts silently the moment someone adds a
  route without touching the table (that is exactly how `/v1/onboarding`,
  `/v1/archives`, and the `/v1/admin/*` fleet routes ended up undocumented).

  This test re-derives BOTH sets from the router SOURCE — the `get|post|put|patch|
  delete "..."` (and `get("...")`) match macros on one side, the `METHOD  PATH`
  rows of the moduledoc table on the other — and fails if they disagree in either
  direction. It reads the file text (never the running router), so it is a pure,
  DB-free parse. Regex-over-source is the same render-from-data lever the
  `usage.go` noun-line mirror uses (#3973): the documented copy is checked against
  the code that is the source of truth, so it can never quietly rot.

  When this test fails: add the new route to the "## Route table" block in
  `router.ex` (or delete the row for the route you removed).

  It also runs a TIER CENSUS over every tier-bearing row (see the block below the
  method/path tripwire): the tier column a row advertises must match the guard the
  route body invokes, because that table is what a CLI, an SDK author or a cold
  agent reads to decide what a member may do. The census resolves three guard
  idioms — `Auth.require_*`, `with_team_role/3`, and a helper the body delegates
  the whole conn to — because the `Auth.require_*`-only regex reaches barely two
  thirds of the table and would be green by construction over the rest.
  """
  use ExUnit.Case, async: true

  @router_source Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__)

  # A route declaration: `get "/path" do`, `post("/path", do: ...)`, etc.
  # `[\s(]` after the verb matches both the space form and the parenthesized form.
  @route_re ~r/^\s*(get|post|put|patch|delete)[\s(]+"([^"]+)"/

  # A moduledoc table row: `      GET     /v1/me   user   ...`. Requires >=4 leading
  # spaces so it never collides with the 2-space `## GET ...` prose comments in the
  # body. The `*` catch-all row is documentation-only and excluded from the diff.
  @row_re ~r/^\s{4,}(GET|POST|PUT|PATCH|DELETE)\s+(\S+)/

  defp source, do: File.read!(@router_source)

  defp declared_routes do
    source()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(@route_re, line) do
        [_, method, path] -> [{String.upcase(method), path}]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp moduledoc_block do
    case Regex.run(~r/@moduledoc\s+"""(.*?)"""/s, source()) do
      [_, block] -> block
      _ -> flunk("could not locate the Router @moduledoc block")
    end
  end

  defp documented_routes do
    moduledoc_block()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(@row_re, line) do
        [_, method, path] -> [{method, path}]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp fmt(set) do
    set
    |> Enum.sort()
    |> Enum.map_join("\n", fn {m, p} -> "  #{String.pad_trailing(m, 7)} #{p}" end)
  end

  test "the router source actually parses (guard against a vacuous green)" do
    # If either extractor silently matched nothing, every diff below would be empty
    # and the tripwire would pass while measuring nothing. Pin a realistic floor.
    assert MapSet.size(declared_routes()) > 100,
           "expected >100 declared routes; the @route_re stopped matching the source"

    assert MapSet.size(documented_routes()) > 100,
           "expected >100 documented rows; the @row_re stopped matching the table"
  end

  test "every declared route appears in the moduledoc route table" do
    missing = MapSet.difference(declared_routes(), documented_routes())

    assert MapSet.size(missing) == 0, """
    #{MapSet.size(missing)} route(s) are declared in router.ex but MISSING from the
    "## Route table" in its @moduledoc. Add a row for each:

    #{fmt(missing)}
    """
  end

  # ── The tier census ────────────────────────────────────────────────────────
  #
  # THE LENS, stated so nobody over-reads a green: this census answers exactly one
  # question — "does the tier a route-table row advertises match the guard that
  # route's body actually invokes?" It does NOT answer "is that guard the right
  # guard": a row documenting `admin` over `Auth.require_team_admin` passes here
  # even if requiring admin is the wrong product call (that ruling lives in the
  # charter, not in a regex). The defect this catches is the DOC lying to an agent,
  # a CLI author or an SDK author about what a member may do.
  #
  # Regex over source, never AST (charter D45: AST buys zero accuracy here).

  # A moduledoc row WITH its tier column captured: `POST /path admin ...`. The
  # @row_re above deliberately stops at method+path, so it is structurally blind
  # to the tier prose — a row could claim the wrong tier and the method/path
  # tripwire would stay green. This re-derives the tier explicitly.
  @tier_row_re ~r/^\s{4,}(GET|POST|PUT|PATCH|DELETE)\s+(\S+)\s+(\S+)/

  # The tier vocabulary the table actually uses. `—` / `—*` rows are public and
  # carry no tier, so they are not part of this population. `user*` (ticket-or-
  # Bearer) and `user(s)` (session-or-PAT) are `user` with a footnote.
  @tier_tokens ~w[user user* user(s) admin owner worker operator agent]

  # Every guard idiom the router uses, mapped to the tier column it justifies. A
  # guard MISSING from this map is treated as UNRESOLVED, never as a pass — a new
  # guard therefore reds instead of quietly widening the census's blind spot.
  @guard_tier %{
    "require_user" => "user",
    "require_user_or_pat" => "user",
    "require_ability" => "user",
    "require_team_role" => "user",
    "require_team_admin" => "admin",
    "require_primary_team_admin" => "admin",
    "require_primary_team_owner" => "owner",
    "require_platform_operator" => "operator",
    "require_worker" => "worker",
    "require_agent" => "agent",
    "with_team_role:member" => "user",
    "with_team_role:admin" => "admin",
    "with_team_role:owner" => "owner"
  }

  # Rows whose guard this resolver CANNOT reach, each with the reason it cannot.
  # This is a NAMED consent list, not a silent skip: an unresolved row that is not
  # listed here fails the census, and a listed row that becomes resolvable fails it
  # too, so the list cannot rot in either direction.
  @unresolved_consent %{
    {"GET", "/v1/events"} =>
      "authenticates inline in `require_user_sse/1` — Bearer OR a single-use `?ticket=` — " <>
        "invoking neither `Auth.require_*` nor `with_team_role/3`. That bespoke dual path is " <>
        "exactly what the row's starred `user*` tier documents."
  }

  # The census must not shrink silently. If a refactor makes currently-resolvable
  # rows unresolvable, the split moves and this reds — lower it deliberately, in
  # the same commit as the routes you removed, or not at all.
  @resolved_floor 161

  @decl_re ~r/^\s*(get|post|put|patch|delete)[\s(]+"([^"]+)"/
  @def_re ~r/^\s*defp?\s+(\w+)\(/
  @block_end_re ~r/^  end\s*$/
  # `post("/v1/launch", do: go_live(conn))` — a one-line body, no `end` of its own.
  @inline_body_re ~r/\bdo:/

  # ONE pass over the source that slices it into blocks: route bodies keyed by
  # {METHOD, path}, and function bodies keyed by name (the helpers a route body
  # delegates its gate to). Cached per test process — the file is re-read once,
  # not once per row.
  defp blocks do
    case Process.get(:router_blocks) do
      nil ->
        result =
          source()
          |> String.split("\n")
          |> Enum.reduce({nil, [], %{}, %{}}, &scan_line/2)
          |> then(fn {_open, _acc, routes, defs} -> {routes, defs} end)

        Process.put(:router_blocks, result)
        result

      cached ->
        cached
    end
  end

  defp scan_line(line, {open, acc, routes, defs}) do
    cond do
      open != nil and Regex.match?(@block_end_re, line) ->
        {routes, defs} = close_block(open, Enum.reverse([line | acc]), routes, defs)
        {nil, [], routes, defs}

      open != nil ->
        {open, [line | acc], routes, defs}

      match = Regex.run(@decl_re, line) ->
        [_, verb, path] = match
        open_block({:route, {String.upcase(verb), path}}, line, routes, defs)

      match = Regex.run(@def_re, line) ->
        [_, name] = match
        open_block({:def, name}, line, routes, defs)

      true ->
        {nil, [], routes, defs}
    end
  end

  # A one-line `..., do: expr` block closes immediately; anything else stays open
  # until the module-level `  end` that closes it.
  defp open_block(key, line, routes, defs) do
    if Regex.match?(@inline_body_re, line) do
      {routes, defs} = close_block(key, [line], routes, defs)
      {nil, [], routes, defs}
    else
      {key, [line], routes, defs}
    end
  end

  defp close_block({:route, key}, lines, routes, defs),
    do: {Map.put_new(routes, key, Enum.join(lines, "\n")), defs}

  # ALL clauses of a multi-clause helper are joined, never just the first: a
  # `defp with_team_site(conn, nil, _fun), do: …` head would otherwise shadow the
  # clause that actually carries the gate, and every route delegating to it would
  # silently fall out of the census.
  defp close_block({:def, name}, lines, routes, defs),
    do:
      {routes,
       Map.update(defs, name, Enum.join(lines, "\n"), &(&1 <> "\n" <> Enum.join(lines, "\n")))}

  defp documented_tier(method, path) do
    moduledoc_block()
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(@tier_row_re, line) do
        [_, ^method, ^path, tier] -> if tier in @tier_tokens, do: tier, else: nil
        _ -> nil
      end
    end)
  end

  # Every tier-bearing row of the table: {METHOD, path, tier-as-written}.
  defp tier_rows do
    moduledoc_block()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(@tier_row_re, line) do
        [_, method, path, tier] when tier != nil ->
          if tier in @tier_tokens, do: [{method, path, tier}], else: []

        _ ->
          []
      end
    end)
  end

  # `user*` (ticket-or-Bearer) and `user(s)` (session-or-PAT) are footnoted `user`.
  defp normalize_tier("user" <> _), do: "user"
  defp normalize_tier(tier), do: tier

  # The guard a route body invokes, read from source. THE WHOLE POINT: the naive
  # "Auth.require_* on the next line" regex resolves barely two thirds of the
  # table — the rest gate through `with_team_role/3` (e.g. /v1/teams/:id/members)
  # or through a helper the body delegates the whole conn to (e.g. `with_team_site`,
  # `go_live`, `proxy_instance_webhook`). A resolver that saw only the first idiom
  # would be vacuously green over that remainder, so it walks all three.
  defp route_guard(method, path) do
    {routes, defs} = blocks()

    case Map.fetch(routes, {method, path}) do
      {:ok, body} -> guard_in(body, defs, 0)
      :error -> nil
    end
  end

  defp guard_in(body, defs, depth) do
    cond do
      match = Regex.run(~r/Auth\.(require_\w+)/, body) ->
        Enum.at(match, 1)

      match = Regex.run(~r/with_team_role\(conn,\s*"(\w+)"/, body) ->
        "with_team_role:" <> Enum.at(match, 1)

      depth < 2 ->
        ~r/(?<![\w.])(\w+)\(conn\b/
        |> Regex.scan(body)
        |> Enum.find_value(fn [_, name] ->
          case Map.fetch(defs, name) do
            {:ok, helper_body} -> guard_in(helper_body, defs, depth + 1)
            :error -> nil
          end
        end)

      true ->
        nil
    end
  end

  # {resolved, unresolved} — resolved carries {method, path, documented, enforced},
  # unresolved carries {method, path, documented, why}.
  defp census do
    Enum.reduce(tier_rows(), {[], []}, fn {method, path, tier}, {ok, no} ->
      case route_guard(method, path) do
        nil ->
          {ok, [{method, path, tier, :no_guard_found} | no]}

        guard ->
          case Map.fetch(@guard_tier, guard) do
            {:ok, enforced} -> {[{method, path, normalize_tier(tier), enforced} | ok], no}
            :error -> {ok, [{method, path, tier, {:unmapped_guard, guard}} | no]}
          end
      end
    end)
  end

  test "the tier census reaches (nearly) every tier-bearing row, and names what it cannot reach" do
    rows = tier_rows()
    {resolved, unresolved} = census()

    user_admin = Enum.count(rows, fn {_, _, t} -> normalize_tier(t) == "user" or t == "admin" end)

    IO.puts("""

    router @moduledoc tier census
      tier-bearing rows examined : #{length(rows)}  (user|admin subset: #{user_admin})
      guard RESOLVED             : #{length(resolved)}
      guard UNRESOLVED (consented): #{length(unresolved)}
    """)

    # (1) Not vacuously green: the census must actually reach nearly all of its
    # population, and every row it cannot reach must be NAMED with a reason.
    unnamed =
      Enum.reject(unresolved, fn {m, p, _, _} -> Map.has_key?(@unresolved_consent, {m, p}) end)

    assert unnamed == [], """
    #{length(unnamed)} tier-bearing row(s) have no resolvable guard AND no entry in
    @unresolved_consent. A row the resolver cannot reach is a row this census is
    green over BY CONSTRUCTION. Either teach `guard_in/3` the idiom, or add the row
    to @unresolved_consent WITH the reason it is unreachable:

    #{Enum.map_join(unnamed, "\n", fn {m, p, t, why} -> "  #{m} #{p} (doc: #{t}) — #{inspect(why)}" end)}
    """

    # (2) The consent list cannot rot: every consented row must still exist AND
    # still be genuinely unresolvable.
    for {{m, p}, reason} <- @unresolved_consent do
      assert Enum.any?(rows, fn {rm, rp, _} -> {rm, rp} == {m, p} end),
             "@unresolved_consent names #{m} #{p}, which is no longer a tier-bearing " <>
               "route-table row. Drop the consent entry."

      assert Enum.any?(unresolved, fn {rm, rp, _, _} -> {rm, rp} == {m, p} end),
             "@unresolved_consent excuses #{m} #{p} (#{reason}) but the resolver now " <>
               "RESOLVES it. Delete the consent entry so the row is censused."
    end

    # (3) Floor: the census cannot shrink silently.
    assert length(resolved) >= @resolved_floor, """
    the tier census resolved #{length(resolved)} rows; the floor is #{@resolved_floor}.
    Either a refactor made rows unresolvable (fix `guard_in/3`), or routes were
    deliberately removed — in which case lower @resolved_floor in the SAME commit.
    """
  end

  test "every tier-bearing route-table row documents the tier its route body enforces" do
    {resolved, _unresolved} = census()

    drifted = Enum.reject(resolved, fn {_, _, documented, enforced} -> documented == enforced end)

    assert drifted == [], """
    #{length(drifted)} route-table row(s) advertise a tier their route body does NOT
    enforce. The moduledoc is the agent/CLI/SDK-facing contract — a row saying `user`
    over an admin-only guard tells a member they may do something the code 403s. Fix
    the TIER COLUMN in the "## Route table" block (the guards are the source of truth):

    #{Enum.map_join(drifted, "\n", fn {m, p, doc, code} -> "  #{String.pad_trailing(m, 7)} #{String.pad_trailing(p, 48)} doc=#{doc}  code enforces=#{code}" end)}
    """
  end

  test "POST /v1/github/installations documents the team-admin tier (matches require_team_admin)" do
    # The route is guarded by Auth.require_team_admin (router.ex ~:3252); its
    # moduledoc row must say `admin`, not `user`. Assert BOTH the documented tier
    # and the live source guard so reverting the row to `user` — or dropping the
    # guard — fails this test. The method+path tripwire cannot catch this drift.
    assert route_guard("POST", "/v1/github/installations") == "require_team_admin",
           "expected the POST /v1/github/installations route body to call Auth.require_team_admin"

    assert documented_tier("POST", "/v1/github/installations") == "admin", """
    The moduledoc route-table row for POST /v1/github/installations must state the
    `admin` tier — the route is guarded by Auth.require_team_admin. Fix the tier
    column in the "## Route table" block.
    """
  end

  test "every moduledoc route-table row still maps to a declared route" do
    stale = MapSet.difference(documented_routes(), declared_routes())

    assert MapSet.size(stale) == 0, """
    #{MapSet.size(stale)} row(s) in the "## Route table" no longer match any route
    declared in router.ex. Delete the stale row (or fix the METHOD/PATH):

    #{fmt(stale)}
    """
  end
end
