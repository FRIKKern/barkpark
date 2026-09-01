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
  agent reads to decide what a member may do. The census resolves four guard
  idioms — `Auth.require_*`, `with_team_role/3`, a helper the body delegates the
  whole conn to, and a post-guard `cond` that refuses a plain member BELOW the
  guard call — because the `Auth.require_*`-only regex reaches barely two thirds
  of the table and would be green by construction over the rest, and because the
  seventh-idiom rows were green over a LIE (the outer guard said `user`, the cell
  said `user`, and the body 403'd the member anyway).

  The refusal idiom is the load-bearing one and it is pinned by a FIXTURE PAIR of
  committed bodies, not just by the live router: a `team_admin?` that SCOPES a
  query must not be read as a tier, one whose false branch 403s must be. See
  "The refusal lens" and "The fixture pair" below.
  """
  use ExUnit.Case, async: true

  # The route-to-tier resolver lives in `test/support/router_tier_lens.ex` (dr-w18-s4)
  # so the deploy-signal audience census can share THIS resolver rather than
  # re-implement it. Everything below consumes it; nothing here re-derives a guard.
  alias BarkparkCloud.RouterTierLens, as: Lens

  # A route declaration: `get "/path" do`, `post("/path", do: ...)`, etc.
  # `[\s(]` after the verb matches both the space form and the parenthesized form.
  @route_re ~r/^\s*(get|post|put|patch|delete)[\s(]+"([^"]+)"/

  # A moduledoc table row: `      GET     /v1/me   user   ...`. Requires >=4 leading
  # spaces so it never collides with the 2-space `## GET ...` prose comments in the
  # body. The `*` catch-all row is documentation-only and excluded from the diff.
  @row_re ~r/^\s{4,}(GET|POST|PUT|PATCH|DELETE)\s+(\S+)/

  defp source, do: Lens.source()

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

  # The tier vocabulary and the guard->tier map moved to `RouterTierLens`
  # (dr-w18-s4). They are read from there, never re-declared here.
  defp tier_tokens, do: Lens.tier_tokens()
  defp guard_tier, do: Lens.guard_tier()

  # Routes whose post-guard `Auth.forbidden(required: …)` is NOT a tier and must
  # not be read as one — a NAMED consent list, exactly like @unresolved_consent,
  # asserted below in both directions so it cannot rot.
  @elevation_consent %{
    {"POST", "/v1/tokens"} =>
      "the 403 is PAYLOAD-conditional, not principal-conditional: any member may " <>
        "mint a `read` PAT, and `create_personal_access_token/3` refuses only when " <>
        "the requested abilities include deploy/root/write (anti-escalation). The " <>
        "row's `user` is correct — an `admin` cell here would tell every member " <>
        "they cannot mint the token they can in fact mint. `user` and not `user(s)`: " <>
        "the outer guard IS `Auth.require_user`, so PAT management is session-only, " <>
        "exactly as the comment above the route says."
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

  defp documented_tier(method, path) do
    moduledoc_block()
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(@tier_row_re, line) do
        [_, ^method, ^path, tier] -> if tier in tier_tokens(), do: tier, else: nil
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
          if tier in tier_tokens(), do: [{method, path, tier}], else: []

        _ ->
          []
      end
    end)
  end

  defp normalize_tier(tier), do: Lens.normalize_tier(tier)

  defp raw_route_guard(method, path), do: Lens.raw_route_guard(method, path)

  defp base_guard(guard), do: Lens.base_guard(guard)

  defp guard_in(body, defs, depth), do: Lens.guard_in(body, defs, depth)

  # The guard the row is censused against: the raw guard, minus any elevation the
  # consent list has ruled is not a tier (see @elevation_consent).
  defp route_guard(method, path) do
    guard = raw_route_guard(method, path)

    if Map.has_key?(@elevation_consent, {method, path}), do: base_guard(guard), else: guard
  end

  # {resolved, unresolved} — resolved carries {method, path, documented, enforced},
  # unresolved carries {method, path, documented, why}.
  defp census do
    Enum.reduce(tier_rows(), {[], []}, fn {method, path, tier}, {ok, no} ->
      case route_guard(method, path) do
        nil ->
          {ok, [{method, path, tier, :no_guard_found} | no]}

        guard ->
          case Map.fetch(guard_tier(), guard) do
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

    # (2b) The ELEVATION consent list cannot rot in either direction either: every
    # consented row must still exist AND its body must still perform the elevation
    # the entry excuses. If the refusal goes away, the excuse must go with it.
    for {{m, p}, reason} <- @elevation_consent do
      assert Enum.any?(rows, fn {rm, rp, _} -> {rm, rp} == {m, p} end),
             "@elevation_consent names #{m} #{p}, which is no longer a tier-bearing " <>
               "route-table row. Drop the consent entry."

      raw = raw_route_guard(m, p)

      assert raw != nil and raw != base_guard(raw),
             "@elevation_consent excuses #{m} #{p} (#{reason}) but its body no longer " <>
               "performs a post-guard elevation (raw guard: #{inspect(raw)}). Delete the " <>
               "consent entry so the row is censused on its guard alone."
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

  # ── The fixture pair: a guard that can LOSE ────────────────────────────────
  #
  # Every other assertion in this file runs against the LIVE router, so "the lens
  # discriminates" is asserted, never demonstrated — if `elevate/2` degenerated to
  # "always elevate" or "never elevate", the census would still be green the day
  # the table was edited to agree with it. These three bodies are COMMITTED BYTES,
  # trimmed copies of the real ones, and they pin the discrimination itself:
  #
  #   CLEAR  — a `team_admin?` that SCOPES a query must not elevate.
  #   FLAG   — a `team_admin?` whose false branch 403s must elevate to `admin`.
  #   FLAG-d — the require_user_or_pat DISJUNCTION must elevate to `admin(d)`, not
  #            to `admin` (a deploy-PAT holder needs no role).
  #
  # A fixture that drifts from the router it models is worse than none, so the
  # last assertion pins each fixture's verdict to the live route's verdict.

  @fixture_clear ~S'''
    get "/v1/notifications/deliveries" do
      conn = Auth.require_user(conn, [])

      cond do
        conn.halted -> conn
        is_nil(conn.assigns.current_team) -> json(conn, 403, %{error: "forbidden"})

        true ->
          user = conn.assigns.current_user
          admin? = Accounts.team_admin?(user, conn.assigns.current_team)
          json(conn, 200, %{deliveries: list(recipient: if(admin?, do: nil, else: user.email))})
      end
    end
  '''

  @fixture_flag ~S'''
    post "/v1/env-vars" do
      conn = Auth.require_user(conn, [])

      cond do
        conn.halted -> conn
        is_nil(conn.assigns.current_team) -> json(conn, 422, %{error: "no_team"})

        not Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) ->
          Auth.forbidden(conn, required: "admin", scope: "team")

        true -> json(conn, 201, %{env_var: %{}})
      end
    end
  '''

  @fixture_flag_deploy ~S'''
    post "/v1/fleet/supports" do
      conn = Auth.require_user_or_pat(conn, [])

      conn =
        cond do
          conn.halted -> conn
          conn.assigns[:current_token] -> Auth.require_ability(conn, "deploy")
          is_nil(conn.assigns[:current_team]) -> conn
          Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) -> conn
          true -> Auth.forbidden(conn, required: "admin", scope: "team")
        end

      conn
    end
  '''

  test "the refusal lens discriminates a scoping team_admin? from a refusing one" do
    # The must-CLEAR control. It mentions `team_admin?` twice — a naive mention
    # lens flags it — but nothing in it refuses, so it stays plain `user`.
    assert guard_in(@fixture_clear, %{}, 0) == "require_user",
           "the must-CLEAR fixture elevated: a team_admin? that only SCOPES a query " <>
             "must not be read as a tier (that would push a truthful `user` cell to " <>
             "a false `admin`)"

    assert guard_tier()[guard_in(@fixture_clear, %{}, 0)] == "user"

    # The must-FLAG control. Same outer guard as the CLEAR fixture — so the only
    # thing the lens can be keying on is the refusal.
    assert guard_in(@fixture_flag, %{}, 0) == "require_user+forbidden:admin",
           "the must-FLAG fixture did not elevate: a post-guard cond that 403s a " <>
             "plain member is the tier, not the outer Auth.require_user"

    assert guard_tier()[guard_in(@fixture_flag, %{}, 0)] == "admin"

    # The disjunction. `admin` here would be a NEW lie, so it must be `admin(d)`.
    assert guard_in(@fixture_flag_deploy, %{}, 0) ==
             "require_user_or_pat+ability:deploy+forbidden:admin"

    assert guard_tier()[guard_in(@fixture_flag_deploy, %{}, 0)] == "admin(d)",
           "the deploy DISJUNCTION must resolve to admin(d), never to admin"

    # …and `admin(d)` must survive normalization as its own tier.
    assert normalize_tier("admin(d)") == "admin(d)"

    # The fixtures must not drift from the routes they model.
    assert raw_route_guard("GET", "/v1/notifications/deliveries") ==
             guard_in(@fixture_clear, %{}, 0)

    assert raw_route_guard("POST", "/v1/env-vars") == guard_in(@fixture_flag, %{}, 0)

    assert raw_route_guard("POST", "/v1/fleet/supports") ==
             guard_in(@fixture_flag_deploy, %{}, 0)
  end

  test "a delegated helper resolves per CALL SITE, not by its first clause" do
    # `with_team_site/3` gates on a `case` over its `auth` argument: `:session`
    # takes `Auth.require_user`, `{:ability, ab}` takes `require_user_or_pat |>
    # require_ability(ab)`. The `:session` branch is textually FIRST, so a lens
    # that reads the joined helper body first-hit-wins hands `require_user` to
    # all ELEVEN delegating /v1/sites routes — and the one distinction this
    # family draws (a PAT reaches six of them, and is turned away from five)
    # becomes unsayable in the contract a CLI or SDK author reads.
    #
    # This is a GATE defect, never a live auth hole: every one of the eleven
    # enforces exactly what its own code says. What could not be stated was WHICH.
    session_only = [
      {"GET", "/v1/sites/:id/deployments"},
      {"GET", "/v1/sites/:id/previews"},
      {"POST", "/v1/sites/:id/env"},
      {"POST", "/v1/sites/:id/domains"},
      {"POST", "/v1/sites/:id/github"}
    ]

    pat_reachable = [
      {"PATCH", "/v1/sites/:id"},
      {"DELETE", "/v1/sites/:id"},
      {"POST", "/v1/sites/:id/deploy"},
      {"POST", "/v1/sites/:id/rollback"},
      {"POST", "/v1/sites/:id/deployments/:dep_id/artifact"},
      {"GET", "/v1/sites/:id/deployments/:dep_id"}
    ]

    # The count is load-bearing: if a route joins or leaves the family, this
    # enumeration is stale and the split has to be re-derived, not patched.
    assert length(session_only) + length(pat_reachable) == 11

    for {m, p} <- session_only do
      assert raw_route_guard(m, p) == "require_user",
             "#{m} #{p} passes NO mode to with_team_site, so it takes the helper's " <>
               "own default (`:session`) and enforces Auth.require_user"

      assert documented_tier(m, p) == "user",
             "#{m} #{p} is session-only; `user(s)` would tell a PAT holder they can reach it"
    end

    for {m, p} <- pat_reachable do
      assert raw_route_guard(m, p) == "require_user_or_pat",
             "#{m} #{p} passes {:ability, _}, so it enforces require_user_or_pat |> " <>
               "require_ability — a PAT carrying that ability reaches it"

      assert documented_tier(m, p) == "user(s)",
             "#{m} #{p} is PAT-reachable; a plain `user` cell hides the one distinction " <>
               "the /v1/sites family draws"
    end

    # THE DISCRIMINATION, stated as an inequality so it cannot pass vacuously:
    # two routes into the same helper, differing only in the mode they pass.
    assert raw_route_guard("POST", "/v1/sites/:id/env") !=
             raw_route_guard("PATCH", "/v1/sites/:id"),
           "POST /v1/sites/:id/env (:session) and PATCH /v1/sites/:id ({:ability, \"write\"}) " <>
             "collapsed to one guard key — the lens is back to first-clause-wins"

    assert guard_tier()[raw_route_guard("POST", "/v1/sites/:id/env")] == "user"
    assert guard_tier()[raw_route_guard("PATCH", "/v1/sites/:id")] == "user(s)"

    # …and `user(s)` must survive normalization as its own tier, or the census
    # folds it back into `user` and both halves agree again by construction.
    assert normalize_tier("user(s)") == "user(s)"
    assert normalize_tier("user*") == "user"
  end

  test "PAT management is session-only, and the /v1/tokens rows say so" do
    # The router's own comment above these routes states it outright ("Managing
    # PATs is SESSION-ONLY … the mint route 401s a PAT bearer"), while all three
    # rows advertised `user(s)`. `normalize_tier("user" <> _)` folded the cell to
    # `user` and the census agreed with a table that contradicted its own prose.
    for {m, p} <- [{"GET", "/v1/tokens"}, {"POST", "/v1/tokens"}, {"DELETE", "/v1/tokens/:id"}] do
      assert base_guard(raw_route_guard(m, p)) == "require_user",
             "#{m} #{p} enforces session-only Auth.require_user"

      assert documented_tier(m, p) == "user",
             "#{m} #{p} must document `user` (session-only). `user(s)` tells a PAT " <>
               "holder they may manage tokens with a PAT — the exact escalation the " <>
               "route exists to refuse."
    end

    # The contrast that proves `(s)` is not decoration: the SAME token on
    # /v1/deliveries sits over a guard that genuinely does accept a PAT.
    assert raw_route_guard("GET", "/v1/deliveries") == "require_user_or_pat"
    assert documented_tier("GET", "/v1/deliveries") == "user(s)"
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
