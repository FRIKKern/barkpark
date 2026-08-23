defmodule BarkparkCloud.Web.BarkparksIdOwnershipCensusTest do
  @moduledoc """
  FORWARD-GUARD CENSUS over the object-level authorization (BOLA/IDOR) of every
  `/v1/barkparks/:id*` route, re-derived from `router.ex` source on every run.

  WHY THIS FILE EXISTS. The cloud IDOR wave (epic api-read-path-security-sweep)
  individually verified all 30 `/v1/barkparks/:id*` routes and found them
  IDOR-clean by construction: each one resolves the barkpark by `:id` through a
  team-scoped signal that returns `nil` (→ 404) when the resolved instance's
  `team_id` does not match the caller's current team, so an admin/member of team
  A cannot drive the route against a barkpark owned by team B. That invariant is
  today pinned only by the CODE SHAPE. A future refactor that adds a new
  `/v1/barkparks/:id` route resolving `:id` GLOBALLY — `Repo.get(Barkpark, id)`
  with no team assertion — would ship green and re-open the exact BOLA class the
  wave closed. This census makes that regression LOUD: it re-derives every
  `barkparks/:id` route head from source and asserts each body carries exactly
  ONE of the blessed team-scoped ownership signals; a route matching none is an
  offender and reds the suite, named by path.

  THE 3+1 BLESSED SIGNALS (a maintained allowlist — see candor below):

    * `resolve_team_barkpark(`    — `defp resolve_team_barkpark(team, id)`:
      `Repo.get(Barkpark, id)` matched against
      `%Barkpark{team_id: tid} = bp when tid == team.id -> bp ; _ -> nil`.
      The extracted inline guard; returns nil cross-team.
    * `proxy_instance_webhook(`   — `defp proxy_instance_webhook(conn, cap)`:
      require_user → current_team → `resolve_team_barkpark(team, id)` before
      proxying to the instance. The whole `/api/webhooks*` proxy family.
    * `recent_events_for_team(`   — `Registry.recent_events_for_team(team, id, n)`:
      `Repo.get(Barkpark, id)` matched against `%Barkpark{team_id: ^tid} = bp`,
      returns nil cross-team. The events/telemetry read pair.
    * inline `tid == team.id`     — the bodies that pattern-match the resolved
      `%Barkpark{team_id: tid}` against `conn.assigns.current_team` inline
      (`when tid == team.id`), the fail-closed scope-clamp the wave standardized.

  THE 30-ROUTE DISPOSITION TABLE (path, verb → signal). Re-derived on
  origin/main; offenders == []. Line numbers are NOT pinned (they drift) — the
  test reads them fresh every run; the table is the human-readable ledger.

    | verb   | path                                                        | signal                  |
    |--------|-------------------------------------------------------------|-------------------------|
    | delete | /v1/barkparks/:id                                           | inline tid == team.id   |
    | post   | /v1/barkparks/:id/retry                                     | inline tid == team.id   |
    | post   | /v1/barkparks/:id/verify                                    | resolve_team_barkpark   |
    | get    | /v1/barkparks/:id/credentials                              | inline tid == team.id   |
    | post   | /v1/barkparks/:id/studio-link                              | inline tid == team.id   |
    | post   | /v1/barkparks/:id/app-token                                | inline tid == team.id   |
    | delete | /v1/barkparks/:id/app-token                                | inline tid == team.id   |
    | post   | /v1/barkparks/:id/push-relay                               | inline tid == team.id   |
    | post   | /v1/barkparks/:id/site-url                                 | inline tid == team.id   |
    | post   | /v1/barkparks/:id/self-update                              | inline tid == team.id   |
    | post   | /v1/barkparks/:id/rollback                                 | inline tid == team.id   |
    | patch  | /v1/barkparks/:id/autoupdate                               | inline tid == team.id   |
    | post   | /v1/barkparks/:id/agent-key                                | inline tid == team.id   |
    | get    | /v1/barkparks/:id/agent-key                                | inline tid == team.id   |
    | post   | /v1/barkparks/:id/domain                                   | inline tid == team.id   |
    | get    | /v1/barkparks/:id/bootstrap                                | inline tid == team.id   |
    | post   | /v1/barkparks/:id/vercel-deploy                            | inline tid == team.id   |
    | get    | /v1/barkparks/:id/api/webhooks                             | proxy_instance_webhook  |
    | post   | /v1/barkparks/:id/api/webhooks                             | proxy_instance_webhook  |
    | get    | /v1/barkparks/:id/api/webhooks/:webhook_id                 | proxy_instance_webhook  |
    | put    | /v1/barkparks/:id/api/webhooks/:webhook_id                 | proxy_instance_webhook  |
    | delete | /v1/barkparks/:id/api/webhooks/:webhook_id                 | proxy_instance_webhook  |
    | post   | /v1/barkparks/:id/api/webhooks/:webhook_id/rotate          | proxy_instance_webhook  |
    | get    | /v1/barkparks/:id/api/webhooks/:webhook_id/deliveries      | proxy_instance_webhook  |
    | post   | /v1/barkparks/:id/api/webhooks/:webhook_id/deliveries/:event_id/replay | proxy_instance_webhook |
    | post   | /v1/barkparks/:id/api/webhooks/:webhook_id/test-send       | proxy_instance_webhook  |
    | get    | /v1/barkparks/:id/events                                   | recent_events_for_team  |
    | get    | /v1/barkparks/:id/telemetry                                | recent_events_for_team  |
    | get    | /v1/barkparks/:id/metrics                                  | resolve_team_barkpark   |
    | get    | /v1/barkparks/:id/usage                                    | resolve_team_barkpark   |
    | get    | /v1/barkparks/:id/usage/history                            | resolve_team_barkpark   |
    | get    | /v1/barkparks/:id/domain-status                            | resolve_team_barkpark   |

    Tally: inline tid==team.id 16 · resolve_team_barkpark 5 · proxy_instance_webhook 9 · recent_events_for_team 2 = 32.
    (PDF-D94 added the agent-key pair — both pattern-match the resolved row's team_id inline, fail-closed 404 cross-team.)

  CANDOR — what this proves and what it does NOT (D57 marginal value).

    * SYNTACTIC / NAME-BASED. This proves a blessed resolve NAME textually
      appears in the route body. It does NOT prove the route HONORS the nil
      return — a body that called `resolve_team_barkpark/2` and then ignored the
      `nil` and re-fetched the instance globally would still pass here. That
      guarantee is the job of the per-route cross-team-404 regression tests
      (`router_*_test.exs`), which this census PAIRS WITH and does NOT replace.
      An over-matching signal is the load-bearing failure mode: it would hide a
      real offender, so the signal set is kept minimal and exact.

    * MAINTAINED ALLOWLIST, FAILS CLOSED. The 3+1 signal set is a human-curated
      allowlist. A genuinely-new team-scoped resolver (say `scope_to_team/2`)
      REDS this census until a human adds it here next to the reason — that is
      the correct fail-closed behavior. New authorization vocabulary must be
      ruled on deliberately, not absorbed silently.

    * AUDIT-TEAM LATENT COUPLING. The audit/telemetry sinks these handlers write
      to key on `bp.team_id == team.id` only VIA these guards — the ownership
      assertion is what makes the resolved `%Barkpark{}` team-correct before any
      audit row is minted. Weakening a guard here silently mis-attributes those
      downstream audit rows; the coupling is latent (not visible in this file's
      output) but real.

  METHOD NOTES.

    * Route heads are matched with `^  (get|post|put|patch|delete) "/v1/barkparks/:id`
      — all thirty are the block form (`verb "..." do ... end`) at 2-space
      indentation; none is a parenthesized one-liner.
    * Block bodies are bounded by the STRICT `^  end` terminator at route
      indentation (the same discipline `router_head_fence_census_test.exs`
      uses). "Scan to the next route macro" overshoots into the following
      route's doc-comment and could misattribute a signal; strict `^  end` cuts
      each body exactly at its own close.
  """
  use ExUnit.Case, async: true

  @router_source Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__)

  # A `/v1/barkparks/:id*` route head in block form, capturing verb + path.
  @route_head_re ~r{^  (get|post|put|patch|delete) "(/v1/barkparks/:id[^"]*)" do\s*$}

  # The block terminator at ROUTE indentation. Strict on purpose — see METHOD.
  @block_end_re ~r/^  end\s*$/

  # THE 3+1 BLESSED TEAM-SCOPED OWNERSHIP SIGNALS. Ordered; a body is classified
  # by the FIRST it contains. This is a maintained allowlist — adding a signal is
  # a deliberate human ruling, documented in the @moduledoc.
  @signals [
    {"resolve_team_barkpark", "resolve_team_barkpark("},
    {"proxy_instance_webhook", "proxy_instance_webhook("},
    {"recent_events_for_team", "recent_events_for_team("},
    {"inline tid == team.id", "tid == team.id"}
  ]

  # Pinned population, re-derived on origin/main. A new barkparks/:id route moves
  # this and must be ruled on here.
  @expected_route_count 32

  defp source, do: File.read!(@router_source)

  # Re-derive [{verb, path, body}] for every /v1/barkparks/:id* route head.
  defp routes do
    lines = source() |> String.split("\n")

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, idx} ->
      case Regex.run(@route_head_re, line) do
        [_, verb, path] -> [{verb, path, extract_body(lines, idx)}]
        nil -> []
      end
    end)
  end

  # Body = every line strictly after the head up to (excluding) the first
  # route-indentation `end`.
  defp extract_body(lines, head_idx) do
    lines
    |> Enum.drop(head_idx + 1)
    |> Enum.take_while(fn l -> not Regex.match?(@block_end_re, l) end)
    |> Enum.join("\n")
  end

  defp classify(body) do
    Enum.find_value(@signals, fn {name, needle} ->
      if String.contains?(body, needle), do: name
    end)
  end

  test "every /v1/barkparks/:id route head is enumerated from source" do
    assert length(routes()) == @expected_route_count,
           "expected #{@expected_route_count} /v1/barkparks/:id* route heads, " <>
             "re-derived #{length(routes())}. A route was added or removed — " <>
             "update @expected_route_count and the disposition table next to the reason."
  end

  test "every /v1/barkparks/:id route carries exactly one blessed team-scoped ownership signal" do
    offenders =
      routes()
      |> Enum.filter(fn {_verb, _path, body} -> classify(body) == nil end)
      |> Enum.map(fn {verb, path, _body} -> "#{String.upcase(verb)} #{path}" end)

    assert offenders == [],
           "IDOR/BOLA forward-guard breached: #{length(offenders)} /v1/barkparks/:id " <>
             "route(s) resolve `:id` WITHOUT a blessed team-scoped ownership signal " <>
             "(#{@signals |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}). Each such route " <>
             "may let an actor in team A drive it against a barkpark owned by team B. " <>
             "Add the team-ownership assertion, or — if a genuinely-new team-scoped " <>
             "resolver was introduced — add its signal to @signals with the reason. " <>
             "Offenders:\n  " <> Enum.join(offenders, "\n  ")
  end

  test "the signal tally matches the pinned disposition (over-matching would hide an offender)" do
    tally =
      routes()
      |> Enum.map(fn {_verb, _path, body} -> classify(body) end)
      |> Enum.frequencies()

    assert tally == %{
             "inline tid == team.id" => 16,
             "resolve_team_barkpark" => 5,
             "proxy_instance_webhook" => 9,
             "recent_events_for_team" => 2
           },
           "signal tally drifted from the pinned disposition table: #{inspect(tally)}. " <>
             "A signal moving without a route being added/removed means a route " <>
             "changed its ownership vocabulary — re-derive and rule on it in the " <>
             "@moduledoc disposition table."
  end
end
