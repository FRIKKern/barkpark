defmodule BarkparkCloud.CredentialEgressReachabilityRefusalCensusTest do
  @moduledoc """
  THE THREE CREDENTIAL-EGRESS SITES CARRY NO REACHABILITY-DERIVED REFUSAL —
  and this file is the MEASUREMENT that decided it, not a preference.

  cch-w59-bl measured the THREE-STATE variant (refuse only on an explicit
  `false`, permit NULL) that D705 filed as unmeasured. Whole cloud suite, base
  sha 6744725c58d6657b0e90e4767ee17e938b87cf9e, private partition
  `MIX_TEST_PARTITION=_csw3`, command
  `MIX_ENV=test CC=/usr/bin/clang ../scripts/mix-test-strict.sh` from `cloud/`:

      arm                                   whole-suite result
      BASELINE                              5462 tests,   1 failure
      wire_site_url/2      three-state      5462 tests,   0 failures   (+0)
      wire_site_url/2      INVERTED         5462 tests,  22 failures
      provision_push_relay_webhook/2 three  5462 tests,   0 failures   (+0)
      provision_push_relay_webhook/2 INVERT 5462 tests,  13 failures
      relay_admin/4        three-state      5462 tests,   0 failures   (+0)
      relay_admin/4        INVERTED         5462 tests, 151 failures

  The one baseline failure (`notifications_test.exs:567`) is PRE-EXISTING and
  FLAKY — it did not reproduce in any of the six patched arms, so the effective
  baseline is 0 and every "+0" above is a true zero rather than a cancellation.

  THE INVERTED CONTROL IS WHY THE ZEROS MEAN SOMETHING. Flipping each predicate
  to refuse on NULL-or-true reds 22 / 13 / 151 tests across 5 / 3 / 14 files.
  So the three sites ARE live-covered and a three-state gate costs ZERO — the
  cost hypothesis D705 filed is CONFIRMED, and wave 59's cost bar ("within one
  test of refusing the entire tested population") is NOT the binding constraint
  on this variant.

  IT IS STILL REFUSED, ON A DIFFERENT AND STRONGER GROUND. The zero is a fact
  about the FIXTURE population, not about the fleet: `verify_reachable` is set
  by no fixture anywhere in the suite (every one of its occurrences is an
  ASSERTION), so a three-state gate ships COMPLETELY UNTESTED — the zero cost
  and the zero coverage are the same fact read twice. And D684 already refuted
  the column on LIVE evidence: `jarl` reads `verify_reachable: false` while
  beating right now, the persisted value is `Enum.any?` over three probes of
  which two are anonymous, and NOTHING schedules a verify run — the sole writer
  is the human-clicked `POST /v1/barkparks/:id/verify`. An explicit `false` is
  therefore a STALE CLICK, not a refutation, and a three-state gate here would
  refuse a live paying box at all three sites with no path back that the box or
  the plane can take on its own. Cheap and wrong is still wrong.

  So: D684 is UPHELD BY NAME rather than stepped around, and this census is the
  mechanical form of that decision — the next builder who reaches for the column
  at one of these sites reds here and reads the numbers.

  SCOPE, and it is narrow on purpose. This file pins THREE clause groups in
  `registry.ex` against the reachability vocabulary. It says nothing about any
  other guard at these sites — the SUSPENSION refusals already shipped at
  `wire_site_url/2` and `provision_push_relay_webhook/2` are legitimate and this
  census must never be read as forbidding them (they are keyed on `suspended`,
  which appears in no vocabulary here). It is the sibling of
  `verify_route_producer_exemption_test.exs`, which guards a DIFFERENT surface
  (the verify route and the decrypt seam) for a DIFFERENT reason (circularity).
  That file is untouched by this row and still reds on the `== false` shape.

  COMMENT HANDLING, stated because the sibling census learned it the hard way:
  a WHOLE-LINE comment (trimmed form starts with `#`) is dropped, so the right
  comment to write — "deliberately NOT keyed on verify_reachable (D684)" — does
  not red this file. A TRAILING comment on a code line is NOT stripped and will
  red. That is the conservative direction: loud and rewordable, never silently
  blind. No clause group here contains a heredoc (the `@doc` blocks sit outside
  every extracted group), so the whole-line rule cannot mis-read one.
  """
  use ExUnit.Case, async: true

  @registry_source Path.expand("../../lib/barkpark_cloud/registry.ex", __DIR__)

  @next_toplevel_re ~r/^  (@doc|@spec|@impl|def |defp )/

  # Exactly the vocabulary the sibling census calls D706's circularity set — the
  # two columns whose SOLE writer is the verify route — plus the helper shapes a
  # refusal would hide behind.
  @reachability_reads [
    "verify_reachable",
    "last_verified_at",
    "reachable?(",
    "require_reachable",
    "ensure_reachable",
    "verified_recently?",
    "reachability"
  ]

  @sites [
    {"wire_site_url/2", ~r/^  def wire_site_url\(/, "reveal_admin_token_or_error(bp)", 3},
    {"provision_push_relay_webhook/2", ~r/^  def provision_push_relay_webhook\(/,
     "find_push_relay_webhook(bp, scoped, receiver_url)", 3},
    {"relay_admin/4", ~r/^  def relay_admin\(/, "reveal_admin_token(bp)", 3}
  ]

  defp clause_group(head_re) do
    lines = String.split(File.read!(@registry_source), "\n")

    case Enum.find_index(lines, &Regex.match?(head_re, &1)) do
      nil ->
        []

      i ->
        body =
          lines
          |> Enum.drop(i + 1)
          |> Enum.take_while(fn line ->
            Regex.match?(head_re, line) or not Regex.match?(@next_toplevel_re, line)
          end)

        [Enum.at(lines, i) | body]
    end
  end

  defp code_lines(lines),
    do: Enum.reject(lines, &String.starts_with?(String.trim_leading(&1), "#"))

  defp offenders(lines) do
    lines
    |> code_lines()
    |> Enum.flat_map(fn line ->
      case Enum.filter(@reachability_reads, &String.contains?(line, &1)) do
        [] -> []
        hits -> [{String.trim(line), hits}]
      end
    end)
  end

  test "the extractor still reads registry.ex (guard against a vacuous green)" do
    for {name, head_re, anchor, min_heads} <- @sites do
      group = clause_group(head_re)
      heads = Enum.count(group, &Regex.match?(head_re, &1))

      assert heads >= min_heads,
             "#{name}: extracted #{heads} clause head(s), expected at least #{min_heads} — " <>
               "the head regex or @next_toplevel_re has stopped matching registry.ex"

      assert Enum.any?(code_lines(group), &String.contains?(&1, anchor)),
             "#{name}: the anchor `#{anchor}` is gone from the extracted group — re-derive this census"
    end
  end

  test "no credential-egress site refuses on reachability (D684 upheld, cch-w59-bl measured)" do
    found =
      for {name, head_re, _anchor, _min} <- @sites,
          {line, hits} <- offenders(clause_group(head_re)),
          do: {name, line, hits}

    assert found == [],
           """
           A REACHABILITY-DERIVED REFUSAL appeared at a credential-egress site.

           #{Enum.map_join(found, "\n", fn {name, line, hits} -> "  #{name} — #{Enum.join(hits, ", ")}\n    #{line}" end)}

           This was MEASURED, not assumed (cch-w59-bl, numbers in this file's
           moduledoc). The three-state shape — refuse on an explicit `false`,
           permit NULL — costs ZERO tests at all three sites, and that zero is
           exactly the problem: no fixture in the suite sets the column, so such
           a gate ships with no coverage at all. The inverted controls
           (22 / 13 / 151) prove the sites themselves ARE covered, which is what
           makes the zero readable.

           And the column does not carry the fact a refusal here would need.
           D684: `verify_reachable` is `Enum.any?` over three probes, two of them
           anonymous; nothing schedules a verify run; the SOLE writer is the
           human-clicked POST /v1/barkparks/:id/verify. An explicit `false` is a
           stale click, not a refutation — a live paying box reads `false` on the
           fleet today. A gate here refuses it with no path back.

           If you need to refuse at these sites, refuse on something that is not
           derived from reachability — `suspended` already ships at two of the
           three and is untouched by this census. If you genuinely intend to
           re-open D684, say so HERE, next to the change, with a fresh
           measurement.
           """
  end
end
