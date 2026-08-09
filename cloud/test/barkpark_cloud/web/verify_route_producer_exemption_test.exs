defmodule BarkparkCloud.Web.VerifyRouteProducerExemptionTest do
  @moduledoc """
  THE PRODUCER EXEMPTION, as a test rather than a comment (cch-w58-bl, D706).

  SCOPE, and read this clause before reading anything else: this file exempts
  `POST /v1/barkparks/:id/verify` from REACHABILITY-DERIVED refusals ONLY —
  refusals computed from `verify_reachable` / `last_verified_at`. It says NOTHING
  about any other guard on this route. In particular it does NOT exempt the route
  from a SUSPENSION refusal (filed separately as
  `cch-w58-bl-verify-route-spends-the-credential-on-a-suspended-box`, GH #11092):
  suspension is not circular — nothing about un-suspending a box requires a
  verify run — so that refusal is legitimate here and this census must never be
  read as forbidding it. A blanket "this route refuses nothing" census would kill
  it, which is exactly the mistake this scoping clause exists to prevent.

  WHY THE EXEMPTION IS REAL. `verify_reachable` and `last_verified_at` have
  exactly ONE writer in the whole application — `Registry.record_verify_result/2`
  (registry.ex) — reached from exactly ONE call site: `run_verify/3` in this
  router, reached only from this route. Every changeset in
  `registry/barkpark.ex` was enumerated: only `verify_changeset/2` casts these
  two columns; `health_changeset/2` (the agent-report and provision-success path)
  does not; no `update_all` names them; the migration is add-only, no default and
  no backfill.

  So a reachability-derived refusal placed ON this route would permanently trap
  every never-verified box: the only way to become reachable is to run the route
  that the refusal blocks. Today the exemption holds by ACCIDENT —
  `Verify.run/1` calls `Registry.reveal_admin_token/1` DIRECTLY rather than going
  through the shared `relay_admin/4` seam — and nothing reds if a future edit
  routes it through a helper that has grown a reachability precondition. This
  file makes that edit LOUD.

  HOW IT WORKS. It re-derives two source blocks from `router.ex` on every run —
  the `POST /v1/barkparks/:id/verify` route block and `run_verify/3` — drops the
  ONE allowed producer line (`Registry.record_verify_result(`), and fails if any
  remaining line mentions a reachability symbol from `@forbidden_reads`.

  MEASURED MARGINAL VALUE (not asserted). A subtle
  `if bp.verify_reachable == false, do: 409` planted at the top of `run_verify/3`
  REDS this file — and is INVISIBLE to the entire existing `verify_test.exs`,
  which stays 20/20 because no fixture anywhere in the suite sets
  `verify_reachable` (every one of its six occurrences in the suite is an
  ASSERTION, never a fixture). That blindness is the coverage this file buys.

  THE ONE STANDING MAINTENANCE OBLIGATION. This guard is TEXTUAL and it fails
  OPEN one call deep: a refusal hidden inside a helper the route merely CALLS is
  invisible here. Therefore — any PR that mints a shared reachability helper
  (anything that reads `verify_reachable` or `last_verified_at` on behalf of a
  caller) adds that helper's NAME to `@forbidden_reads` IN THE SAME PR. That is
  the whole contract; it is cheap, and it is the only thing keeping this from
  decaying into decoration.

  METHOD NOTES (each one a measured bug, not a preference):

    * The route regex matches both declaration forms (`post "..." do` and
      `post("...", do: …)`). A first draft blind to the space form FAILED LOUDLY
      via the non-vacuity arm below, which is the behaviour you want.
    * The block terminator is the STRICT `^  end` — the same choice
      `router_head_fence_census_test.exs` documents. `^\\s*end$` truncates a body
      at its first nested `end`; scanning to the next route macro overshoots and
      swallows the following route's doc comment.
    * NON-VACUITY: a source-scanning test that extracts NOTHING passes trivially.
      Both blocks are therefore pinned to >10 lines and to a per-block anchor.
      The anchors differ by block because `Verify.run(bp)` textually exists only
      in `run_verify/3`; the route block's anchor is its delegation to
      `run_verify(conn, team, bp)`, which is what makes the pair the whole
      surface.
  """
  use ExUnit.Case, async: true

  @router_source Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__)

  @route_re ~r/^\s*post[\s(]+"\/v1\/barkparks\/:id\/verify"/
  @run_verify_re ~r/^\s*defp run_verify\(/
  @block_end_re ~r/^  end\s*$/

  # THE ONE PRODUCER LINE. This is the write that makes the exemption necessary
  # in the first place; it is allowed and nothing else is.
  @allowed_producer "Registry.record_verify_result("

  # Every symbol that would make this route's behaviour depend on a box's
  # reachability. Grow this list — see the standing obligation in the moduledoc —
  # whenever a shared reachability helper is minted anywhere in the app.
  @forbidden_reads [
    "verify_reachable",
    "last_verified_at",
    "reachable?(",
    "require_reachable",
    "ensure_reachable",
    "verified_recently?",
    "reachability"
  ]

  ## Derivation

  defp source, do: File.read!(@router_source)

  defp block(start_re) do
    lines = String.split(source(), "\n")

    case Enum.find_index(lines, &Regex.match?(start_re, &1)) do
      nil ->
        []

      i ->
        body =
          lines
          |> Enum.drop(i + 1)
          |> Enum.take_while(&(not Regex.match?(@block_end_re, &1)))

        [Enum.at(lines, i) | body]
    end
  end

  defp route_block, do: block(@route_re)
  defp run_verify_block, do: block(@run_verify_re)

  defp offending_lines(lines) do
    lines
    |> Enum.reject(&String.contains?(&1, @allowed_producer))
    |> Enum.flat_map(fn line ->
      case Enum.filter(@forbidden_reads, &String.contains?(line, &1)) do
        [] -> []
        hits -> [{String.trim(line), hits}]
      end
    end)
  end

  ## The pins

  test "the extractor still reads the source (guard against a vacuous green)" do
    route = route_block()
    run_verify = run_verify_block()

    assert length(route) > 10,
           "the POST /v1/barkparks/:id/verify block extracted #{length(route)} lines; " <>
             "@route_re or @block_end_re has stopped matching router.ex"

    assert length(run_verify) > 10,
           "run_verify/3 extracted #{length(run_verify)} lines; " <>
             "@run_verify_re or @block_end_re has stopped matching router.ex"

    # Per-block anchors: the route delegates to run_verify/3, and run_verify/3 is
    # where the suite actually runs. If either anchor disappears, the pair below
    # is no longer scanning the surface this file claims to cover.
    assert Enum.any?(route, &String.contains?(&1, "run_verify(conn, team, bp)")),
           "the verify route no longer delegates to run_verify/3 — re-derive this census"

    assert Enum.any?(run_verify, &String.contains?(&1, "Verify.run(bp)")),
           "run_verify/3 no longer calls Verify.run(bp) — re-derive this census"

    # The producer line must actually be present, or the allow-list below is
    # exempting nothing and the whole file is scanning a surface it misunderstands.
    assert Enum.count(run_verify, &String.contains?(&1, @allowed_producer)) == 1,
           "expected exactly one #{@allowed_producer} line inside run_verify/3"
  end

  test "the verify route reads no reachability state except through its one producer" do
    offenders = offending_lines(route_block() ++ run_verify_block())

    assert offenders == [],
           """
           A REACHABILITY READ appeared on POST /v1/barkparks/:id/verify.

           #{Enum.map_join(offenders, "\n", fn {line, hits} -> "  #{Enum.join(hits, ", ")}\n    #{line}" end)}

           This route is the ONLY writer of `verify_reachable` / `last_verified_at`
           (via Registry.record_verify_result/2 → verify_changeset/2). A refusal
           here that depends on those columns permanently traps every
           never-verified box: the only way to become reachable is to run the
           route the refusal blocks.

           If you need to refuse on this route, refuse on something that is NOT
           derived from reachability (suspension, for example, is fine and is
           filed separately — see this file's moduledoc). If you genuinely intend
           a reachability read, you are changing a decision (D684/D706): say so
           here, next to the change.
           """
  end
end
