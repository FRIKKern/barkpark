defmodule BarkparkCloud.Web.RouterHeadFenceCensusTest do
  @moduledoc """
  A DRIFT CEILING over the side-effecting-GET fence: the shape of the router's
  GET surface, re-derived from source on every run and pinned to committed
  integers, plus the fence's deny-clause set pinned verbatim.

  WHY A CENSUS AND NOT A "FIND THE MUTATING GET" CHECK. The obvious guard —
  enumerate GET clauses whose bodies reach a `Repo` write and fail when one is
  missing from `side_effecting_get?/1` — was BUILT AND MEASURED, and its
  population is EMPTY: 0 of the 62 GET routes reach a `Repo.` write at depth 0
  or 1. The whole 10k-line router holds FIVE textual `Repo.` references, none of
  them a write a GET reaches:

    * `:885`  — a prose comment ("runs inside ONE Repo.transaction")
    * `:6700` — `Repo.preload(site, :barkpark)` — a READ
    * `:7198` — `Repo.transaction` in `register/4`, reached only by POST /v1/auth/register
    * `:7218` — `Repo.rollback` in that same transaction
    * `:9851` — `Repo.get_by_uuid(...)` in `safe_get_job/1` — a READ

  Every write in this app goes through a context module (the 62 GET blocks reach
  103 distinct callees across 29 modules at depth 1). A check written to that
  shape would enumerate NOTHING and pass forever — the exact vacuous green this
  epic exists to delete. Do not rebuild it. This file replaces it.

  D40 COVERAGE BOUNDARY — what this does and does NOT do.

    DOES: pin four integers (total GET routes, and their split into
    session-authenticated / agent-or-worker / public) and the exact set of
    `side_effecting_get?/1` clauses, both re-derived from `router.ex` source on
    every run. Any change to either has to be made DELIBERATELY, in this file,
    next to the reason.

    DOES NOT: prove any route is correctly authorized. The classifier is a
    SYNTACTIC auth-SHAPE detector — it looks for a wrapper NAME in the route
    body — not a semantic authorization prover. A route that calls
    `Auth.require_user/2` and then ignores the halt still counts as
    "authenticated" here.

    DOES NOT: prove the deny-list is COMPLETE. It is a deny-list by decision
    (D13), and it fails OPEN. Nothing syntactic can close that; this file only
    makes the boundary MOVE LOUDLY.

  HONEST MARGINAL VALUE (D57), measured, not asserted. Two mutations:

    * plant a new authenticated side-effecting GET → this file reds AND
      `router_moduledoc_table_test.exs` reds (that tripwire is already paid for
      on main);
    * silently drop an auth wrapper from an existing route → this file reds AND
      `router_audit_test.exs` reds behaviourally.

    So the coverage UNIQUE to this file is the narrow case where a new GET is
    added, dutifully documented in the moduledoc route table, and nobody ever
    rules on `side_effecting_get?/1` for it. Real, and narrow. It is NOT "the
    deny-list can no longer fail open".

  METHOD NOTES (each one is a bug that was measured, not a preference):

    * The route regex is `^\\s*get[\\s(]+"..."` — the same one
      `router_moduledoc_table_test.exs` uses. `^  get "` sees only 56 routes;
      six more are parenthesized one-liners (`get("/", do: send_dashboard(conn))`)
      and a regex blind to that form would be blind to a future side-effecting
      GET written that way. Both 56 and 62 are correct populations of different
      shapes; this file pins the WIDER one on purpose.
    * The block end-matcher is the STRICT `^  end`. `^\\s*end$` truncates 44 of
      the bodies at the first nested `end`; "scan to the next route macro"
      overshoots ALL of them and swallows the following route's doc comment,
      which is how an earlier probe mis-read `/v1/me` and `/v1/audit`.
    * Auth classification is by wrapper NAME, ONE CALL DEEP. The three local
      wrappers (`with_team_role`, `with_team_site`, `require_user_sse`) and
      `proxy_instance_webhook` all call an `Auth.require_*` themselves, so
      counting only the `Auth.*` names at depth 0 misses 9 authenticated routes.
    * An AST census (`Code.string_to_quoted!` + `Macro.prewalk`) was also built
      and is ROUTE-FOR-ROUTE IDENTICAL to this regex (D45). Regex it is: no new
      dependency, DB-free, and the same house style as the moduledoc tripwire.
  """
  use ExUnit.Case, async: true

  @router_source Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__)

  # A GET declaration in either form: `get "/path" do` and `get("/path", do: …)`.
  @route_re ~r/^\s*get[\s(]+"([^"]+)"/

  # The block terminator at ROUTE indentation. Strict on purpose — see the
  # moduledoc.
  @block_end_re ~r/^  end\s*$/

  # Every wrapper that establishes a HUMAN/session-token identity, directly or
  # one call deep. `with_team_role` → `Auth.require_team_role`; `with_team_site`
  # → `Auth.require_user` (or `require_user_or_pat` + `require_ability`);
  # `require_user_sse` → `verify_user_session_token` / `consume_sse_ticket`;
  # `proxy_instance_webhook` → `Auth.require_user`.
  @session_wrappers [
    "Auth.require_user",
    "Auth.require_user_or_pat",
    "Auth.require_team_admin",
    "Auth.require_team_role",
    "Auth.require_current_team_admin",
    "Auth.require_current_team_owner",
    "Auth.require_platform_operator",
    "Auth.require_ability",
    "with_team_role",
    "with_team_site",
    "require_user_sse",
    "proxy_instance_webhook"
  ]

  # Machine identities: an agent token or the internal worker shared secret.
  # Checked FIRST, so a route carrying both classifies as machine.
  #
  # `Auth.require_user_or_pat_or_worker` is listed here DELIBERATELY even though
  # it also admits a human: it is a route a MACHINE can reach, and the whole
  # point of checking this list first is that "carries both" resolves to machine.
  # Leaving it out would have been the quiet option — the substring
  # `Auth.require_user` matches it, so the census would have stayed 68/49/7/12
  # and a route that became worker-reachable would have moved no number at all.
  @machine_wrappers [
    "Auth.require_agent",
    "Auth.require_worker",
    "Auth.require_user_or_pat_or_worker"
  ]

  # THE BASELINE. Four integers, re-derived from source above, changed only
  # DELIBERATELY and with a reason written next to them.
  #
  # 2026-07-21 (cch-bl-head-denylist-tripwire): 62 / 45 / 5 / 12, re-derived on
  # main after the SSE-ticket and HEAD-fence slices merged. The 45 does NOT drop
  # when the SSE ticket lands: `require_user_sse` tries the Bearer header FIRST
  # and still reaches `verify_user_session_token` → `touch_last_used`; the ticket
  # is an ADDITIONAL fallback branch, not a replacement (D47).
  # 2026-07-30: 64 / 45 / 7 / 12. #8182 added two agent/worker GET routes,
  # `/v1/agent/sites/:id/env` and `/v1/builder/sites/:id/env`, and did not move
  # this baseline — main went red and stayed red, because until the Cloud gate
  # aggregator landed (#8202) the cloud suite was advisory and nothing surfaced
  # it. RULED NOT SIDE-EFFECTING, by reading the whole path rather than the
  # route name: the handler is `site_env_response/2` → `Registry.reveal_site_env/1`,
  # which is `Vault.decrypt` + `Jason.decode` and writes nothing; and the auth
  # wrapper `Auth.require_agent/2` → `Registry.verify_agent_token/1` is a
  # `Repo.one` + `Repo.get` with no update — no row minted, no credential burned,
  # no nonce spent. So a bare HEAD of either is inert and no `side_effecting_get?/1`
  # clause is owed. Session and public are unchanged, which is the reassuring
  # half: no existing route silently changed auth class.
  # 2026-08-05: 65 / 46 / 7 / 12. deploy-reliability W1 S2 added ONE
  # session-authenticated GET, `/v1/operator/deploy-ledger/census`. RULED NOT
  # SIDE-EFFECTING by reading the whole path: `Auth.require_platform_operator/2`
  # only reads the session and the operator allowlist, and the handler is
  # `DeployLedger.parse_window/2` (pure string parsing) then
  # `DeployLedger.census/3`, which is a single grouped `Repo.all` and an
  # in-memory fold — no row minted, no credential burned, no nonce spent. So a
  # bare HEAD of it is inert and no `side_effecting_get?/1` clause is owed.
  # agent_or_worker and public are unchanged: no existing route changed class.
  # 2026-08-07: 66 / 47 / 7 / 12. deploy-reliability dr-w16-s6 added ONE
  # session-or-PAT GET, `/v1/deploy-ledger/census` — the team-scoped twin of the
  # operator route above, added because that operator route 403s for every real
  # account (PLATFORM_ADMIN_EMAILS is unset in production), so the correct number
  # this epic spent sixteen waves building was unreadable by anyone. It counts as
  # SESSION because `Auth.require_user_or_pat` is a session wrapper here; the
  # `Auth.require_ability("read")` beside it narrows a PAT, it does not reclassify
  # the route. RULED NOT SIDE-EFFECTING by reading the whole path:
  # `require_ability/2` is a pure map lookup, and the handler is
  # `Registry.list_sites_for_team/1` (a `Repo.all`), an in-Elixir list
  # intersection, `DeployLedger.parse_window/2` (string parsing) and
  # `DeployLedger.census/3` (one grouped `Repo.all` + an in-memory fold) — no row
  # minted, no credential burned, no nonce spent. The one write anywhere on the
  # path is the throttled `last_used` bookkeeping `require_user_or_pat/2` defers,
  # which is not a state change a HEAD could exploit and which every one of the
  # session GETs already inside this baseline shares. So a bare HEAD is inert and
  # no `side_effecting_get?/1` clause is owed. machine and public are unchanged:
  # no existing route changed class.
  # 2026-08-08: 67 / 48 / 7 / 12. deploy-reliability dr-w23-s2 added ONE
  # session-or-PAT GET, `/v1/deliveries` — the read half of the platform's own
  # per-sha delivery record (the write half is a POST, so it does not move this
  # GET census at all). It counts as SESSION for the same reason the row above
  # does: `Auth.require_user_or_pat` is a session wrapper here and the
  # `require_ability("read")` beside it narrows a PAT rather than reclassifying
  # the route. RULED NOT SIDE-EFFECTING: the handler is
  # `PlatformDelivery.normalize_sha/1` + `clamp_limit/1` (pure) and
  # `PlatformDelivery.list/1` (one `Repo.all`) — no row minted, no credential
  # burned, no nonce spent; the only write on the path is the same throttled
  # `last_used` bookkeeping every session GET in this baseline already shares. So
  # a bare HEAD is inert and no `side_effecting_get?/1` clause is owed. machine
  # and public are unchanged: no existing route changed class.
  # 2026-08-23: 68 / 49 / 7 / 12. pdf-bl-console-key-custody (PDF-D94) added ONE
  # session-or-PAT GET, `/v1/barkparks/:id/agent-key` — the console's delivery-
  # status poll for the paste-a-key path (the write half is the POST twin, which
  # does not move this GET census). SESSION for the standard reason:
  # `Auth.require_user_or_pat` is a session wrapper and the `require_ability
  # ("deploy")` beside it narrows a PAT rather than reclassifying the route.
  # RULED NOT SIDE-EFFECTING by reading the whole path: the team-admin check is
  # a pure membership read, the handler is `Registry.get_barkpark/1` (Repo.get)
  # + `Registry.latest_agent_key_job/1` (one Repo.one) — no row minted, no
  # credential burned, no nonce spent, and pointedly NO stash read: the one-time
  # key pop lives on the worker CLAIM route, so a bare HEAD here can never
  # consume a key in transit. The only write on the path is the same throttled
  # `last_used` bookkeeping every session GET in this baseline shares. machine
  # and public are unchanged: no existing route changed class.
  # 2026-09-02: 68 / 48 / 8 / 12. NO ROUTE WAS ADDED OR REMOVED — one existing
  # route CHANGED CLASS, which this file's own failure message calls "the more
  # dangerous of the two", so it is spelled out here rather than nudged.
  # `GET /v1/deliveries` moved session -> machine: its guard became
  # `Auth.require_user_or_pat_or_worker`, so the WORKER principal that WRITES the
  # platform delivery record (POST /v1/internal/platform-deliveries, deploy.yml's
  # crown step) can now READ it back (task-e2acb66e9ed0da09). It is still
  # session- and PAT-reachable — D385/D412 preserved — but the honest class for a
  # route a machine can reach is machine, per the "carries both" rule above.
  # RULED NOT SIDE-EFFECTING, unchanged from the 2026-08-08 entry: the handler is
  # still `PlatformDelivery.normalize_sha/1` + `clamp_limit/1` (pure) and
  # `PlatformDelivery.list/1` (one `Repo.all`). The new principal makes a bare
  # HEAD *less* stateful, not more — the worker branch assigns two conn fields and
  # does no lookup at all, so it does not even reach the throttled `last_used`
  # bookkeeping the session branch defers. No `side_effecting_get?/1` clause is
  # owed. agent_or_worker gains exactly the route session loses; public unchanged.
  # 2026-09-02 (second move of the day): 67 / 47 / 8 / 12. ONE ROUTE WAS REMOVED,
  # which is the benign half of this file's two cases. `GET /v1/env-vars` went
  # with the team env-var feature — Option A, ruled by main after cch-w53-bl's
  # measurement that prod `env_vars` held ZERO rows ever. `total` and `session`
  # each fall by exactly one and nothing changed class; machine and public are
  # untouched. No `side_effecting_get?/1` clause is owed or released: the deleted
  # route was a pure `Registry.list_env_vars/1` read.
  # 2026-09-03: 68 / 48 / 8 / 12. ONE ROUTE WAS ADDED — `GET /v1/teams/:id/tokens`,
  # the team-admin PAT list (cch-w30-followup-team-pat-visibility). RULED NOT
  # SIDE-EFFECTING: the handler is `with_team_role/3` (a membership read) plus
  # `Accounts.list_team_personal_access_tokens/1`, one `Repo.all` with a preload —
  # a bare HEAD mints nothing, burns nothing and spends no nonce, so no
  # `side_effecting_get?/1` clause is owed. It is session-gated like every other
  # `/v1/teams/:id/*` route, so `total` and `session` each rise by exactly one;
  # machine and public are untouched.
  # 2026-09-06: 69 / 49 / 8 / 12. ONE ROUTE WAS ADDED — `GET
  # /v1/account/security-audit`, the member self-read over account-security audit
  # rows (task-ddaeea4356664b7a, the owner's ruling of 2026-08-23). RULED NOT
  # SIDE-EFFECTING: the handler is `Auth.require_user/2` plus
  # `Accounts.list_self_security_audit_events/2`, one `Repo.all` with a preload —
  # a bare HEAD mints nothing, burns nothing and spends no nonce, so no
  # `side_effecting_get?/1` clause is owed. It is session-gated like its
  # `/v1/account/*` siblings, so `total` and `session` each rise by exactly one;
  # machine and public are untouched.
  # 2026-09-06: 70 / 50 / 8 / 12. ONE ROUTE WAS ADDED — `GET
  # /v1/operator/barkparks/without-agent-token`, the DISARMED-BOX CENSUS
  # (task-5cc3689cb0ab6637): which barkparks hold no live agent token, the read
  # that separates a box that was DISARMED from one that is DOWN. RULED NOT
  # SIDE-EFFECTING: the handler is `Auth.require_platform_operator/2` plus
  # `Registry.barkparks_without_live_agent_token/0`, one grouped `Repo.all` — a
  # bare HEAD mints nothing, burns nothing and spends no nonce, so no
  # `side_effecting_get?/1` clause is owed. It is session-gated like every other
  # `/v1/operator/*` route, so `total` and `session` each rise by exactly one;
  # machine and public are untouched.
  @baseline_total 70
  @baseline_session 50
  @baseline_machine 8
  @baseline_public 12

  # THE FENCE. Every `side_effecting_get?/1` clause, as {path_segments, verdict}.
  # The catch-all is excluded (it is the default, not a ruling).
  #
  # `/v1/auth/oauth/providers` => false is LOAD-BEARING and must stay FIRST: it
  # shares the initiator's segment arity and would otherwise be 405'd (D14).
  #
  # `/v1/auth/oauth/exchange` => false (cch-w10) is the SAME shape and must
  # likewise stay ahead of `_provider`. It is a POST-only path with no GET handler
  # of its own; without the clause the fence would 405 it with `allow: GET`, which
  # is a lie about a route that does not exist. It is not side-effecting under a
  # GET either — `OAuth.authorize_url/1` resolves the provider BEFORE
  # `mint_state/1`, so "exchange" falls through to a 404 `provider_not_enabled`
  # having written nothing. Behavioural test: router_oauth_test.exs, "the exchange
  # path has no GET handler".
  @deny_clauses [
    {~s(["v1", "auth", "oauth", "providers"]), "false"},
    {~s(["v1", "auth", "oauth", "exchange"]), "false"},
    {~s(["v1", "auth", "oauth", _provider]), "true"},
    {~s(["v1", "auth", "oauth", _provider, "callback"]), "true"},
    {~s(["v1", "events"]), "true"}
  ]

  ## Derivation

  defp source, do: File.read!(@router_source)

  # Every GET route as {path, body}. A parenthesized one-liner is its own body;
  # a block form runs to the next line that is exactly `  end`.
  defp get_routes do
    lines = source() |> String.split("\n")

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, i} ->
      case Regex.run(@route_re, line) do
        [_, path] -> [{path, route_body(line, lines, i)}]
        _ -> []
      end
    end)
  end

  defp route_body(line, lines, i) do
    if String.contains?(line, "do:") do
      line
    else
      lines
      |> Enum.drop(i + 1)
      |> Enum.take_while(&(not Regex.match?(@block_end_re, &1)))
      |> then(&Enum.join([line | &1], "\n"))
    end
  end

  defp classify(body) do
    cond do
      Enum.any?(@machine_wrappers, &String.contains?(body, &1)) -> :agent_or_worker
      Enum.any?(@session_wrappers, &String.contains?(body, &1)) -> :session
      true -> :public
    end
  end

  defp census do
    routes = get_routes()
    by_class = Enum.group_by(routes, fn {_p, b} -> classify(b) end, fn {p, _b} -> p end)

    %{
      total: length(routes),
      session: length(Map.get(by_class, :session, [])),
      agent_or_worker: length(Map.get(by_class, :agent_or_worker, [])),
      public: length(Map.get(by_class, :public, [])),
      by_class: by_class
    }
  end

  defp declared_clauses do
    Regex.scan(
      ~r/^\s*defp side_effecting_get\?\((\[[^\]]*\])\), do: (true|false)/m,
      source()
    )
    |> Enum.map(fn [_, pattern, verdict] -> {pattern, verdict} end)
  end

  defp fmt(paths), do: paths |> Enum.sort() |> Enum.map_join("\n", &("  " <> &1))

  ## The pins

  test "the extractor still reads the source (guard against a vacuous green)" do
    # If the regex stopped matching, every count below would be 0 and every
    # comparison would still be a comparison — of nothing.
    c = census()

    assert c.total > 50,
           "expected >50 GET routes; @route_re has stopped matching router.ex"

    assert c.session > 0 and c.public > 0,
           "expected a mixed population; the auth classifier has stopped matching"

    assert c.total == c.session + c.agent_or_worker + c.public,
           "the classes must partition the population exactly once"

    # The block-form subset must stay a strict SUBSET of what @route_re sees —
    # i.e. the parenthesized one-liners are still being caught. If these ever
    # equalize, the wider regex has silently narrowed.
    block_form =
      source() |> String.split("\n") |> Enum.count(&Regex.match?(~r/^  get "/, &1))

    assert block_form < c.total,
           "expected parenthesized one-liner GET routes to exist beyond the #{block_form} block-form ones"
  end

  test "the GET census matches the committed baseline" do
    c = census()

    assert {c.total, c.session, c.agent_or_worker, c.public} ==
             {@baseline_total, @baseline_session, @baseline_machine, @baseline_public},
           """
           The router's GET surface changed shape.

             total            #{@baseline_total} -> #{c.total}
             session          #{@baseline_session} -> #{c.session}
             agent_or_worker  #{@baseline_machine} -> #{c.agent_or_worker}
             public           #{@baseline_public} -> #{c.public}

           If you ADDED a GET route: rule on it explicitly. Does a bare HEAD of
           it MUTATE anything (mint a row, burn a single-use credential, spend a
           nonce)? If yes, add a `side_effecting_get?/1` clause in router.ex and
           a behavioural test beside `router_sse_ticket_head_burn_test.exs`. If
           no, just move the baseline here and say why in one line.

           If a count moved WITHOUT a route being added or removed, an auth
           wrapper was added to or dropped from an existing route — check that
           first; it is the more dangerous of the two.

           Current session-authenticated routes:
           #{fmt(Map.get(c.by_class, :session, []))}

           Current agent/worker routes:
           #{fmt(Map.get(c.by_class, :agent_or_worker, []))}

           Current public routes:
           #{fmt(Map.get(c.by_class, :public, []))}
           """
  end

  test "the side-effecting-GET deny clauses are exactly the committed set, in order" do
    assert declared_clauses() == @deny_clauses, """
    The `side_effecting_get?/1` clause set changed.

      committed: #{inspect(@deny_clauses)}
      in source: #{inspect(declared_clauses())}

    Order matters: `["v1", "auth", "oauth", "providers"] => false` shares the
    initiator's segment arity and MUST stay ahead of the `_provider` clause, or a
    read-only route starts answering 405 (D14).

    Adding a clause is the normal case — update this list and add its behavioural
    test. REMOVING one re-opens a measured hole: /v1/events burns a live SSE
    ticket, and the oauth pair spends a state nonce and can mint a session.
    """
  end

  test "the fence's coverage-boundary comment still states the true clause count" do
    # D41: this comment went stale the moment the /v1/events clause landed — the
    # prose said TWO. Prose next to a list is a fact with no gate on it, so this
    # is that gate: the spelled-out number must equal the true-verdict clause
    # count.
    true_clauses = Enum.count(declared_clauses(), fn {_p, v} -> v == "true" end)
    spelled = %{2 => "TWO", 3 => "THREE", 4 => "FOUR", 5 => "FIVE", 6 => "SIX"}

    expected = Map.fetch!(spelled, true_clauses)

    assert source() =~ "this list fences exactly #{expected} routes", """
    The fence has #{true_clauses} side-effecting clauses, but its COVERAGE
    BOUNDARY comment in router.ex does not say "#{expected}". Fix the prose in
    the same commit that changed the list.
    """
  end
end
