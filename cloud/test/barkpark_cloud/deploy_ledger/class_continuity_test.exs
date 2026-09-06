defmodule BarkparkCloud.DeployLedger.ClassContinuityTest do
  @moduledoc """
  The cause-class continuity check — deploy-reliability W12, charter D179.

  The check has to discriminate BOTH ways or it is worthless, so both halves are
  real tests here and neither is a comment:

    * cohort total HOLDS while one class goes to zero → FIRE (a rename: the rows
      are still being written, under another name)
    * the cohort itself DRAINS → SILENT (a quiet fleet is not a rename)

  The DB half drives the real `DeployLedger.census/3` over rows carrying the
  VERBATIM box refusal strings, so the check is proven against the census's own
  output shape rather than against a hand-built map that could drift from it.
  Every census call is scoped with `:site_ids` to this test's own site: the
  fleet-wide default would read every other agent's rows out of the one shared
  test database and the fixture would stop being a fixture.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, DeployLedger, Registry, Repo}
  alias BarkparkCloud.DeployLedger.ClassContinuity
  alias BarkparkCloud.Registry.Deployment

  @password "correct-horse-battery"

  # ── The 2026-08-06 instant, and the two windows around it ─────────────────
  #
  # 22:19:52Z is when guerrilla took ef77af274 (#9827, the typed
  # box_at_capacity door). Both windows sit AFTER the deferred-settle-status
  # vocabulary boundary (2026-08-05 21:13:50Z), so nothing here straddles it —
  # the swap being detected is a CLASS swap inside one settled vocabulary,
  # which is the point.
  @swap ~U[2026-08-06 22:19:52Z]
  @before_from ~U[2026-08-06 20:00:00Z]
  @before_to ~U[2026-08-06 22:19:52Z]
  @after_from ~U[2026-08-06 22:19:52Z]
  @after_to ~U[2026-08-07 00:40:00Z]

  # VERBATIM refusal strings — the same corpus samples `deploy_ledger_test.exs`
  # keys on. `classify_deferred/2` reads the anchored 409 prefix and the box's
  # own code word out of these; an invented string would classify to
  # DEFERRED_UNCLASSIFIED and the fixture would test nothing.
  @requeued " — deferred: a rebuild carrying this content has been re-queued and will run once the in-flight deploy finishes"
  @d_busy "the instance refused the deploy (HTTP 409): already_running — a deploy is already in flight" <>
            @requeued
  @d_capacity "the instance refused the deploy (HTTP 409): box_at_capacity — the box is at its build capacity (1 of 1 build slots in use) — site 'other-site' is building; retry when it finishes" <>
                @requeued

  describe "the rule, both directions" do
    test "FIRES: a class goes to zero while its cohort total holds" do
      before_rows = [row("BOX_BUSY_DEFERRED", 698), row("BOX_AT_CAPACITY_DEFERRED", 12)]
      after_rows = [row("BOX_AT_CAPACITY_DEFERRED", 705)]

      assert [finding] = ClassContinuity.check(before_rows, after_rows)
      assert finding.class == "BOX_BUSY_DEFERRED"
      assert finding.verdict == :renamed
      assert finding.count_before == 698
      assert finding.count_after == 0
      # The cohort kept 693 of the 698 rows the vanished class used to own.
      assert finding.cohort_before == 710
      assert finding.cohort_after == 705
      assert finding.retained == 693
    end

    test "SILENT: the cohort itself drains to zero" do
      before_rows = [row("BOX_BUSY_DEFERRED", 698), row("BOX_AT_CAPACITY_DEFERRED", 12)]

      assert ClassContinuity.check(before_rows, []) == []

      # And the silence is REASONED, not an accident of an empty list: both
      # classes are read, and both are read as the cohort draining.
      verdicts = ClassContinuity.verdicts(before_rows, [])
      assert Enum.map(verdicts, & &1.class) == ["BOX_BUSY_DEFERRED", "BOX_AT_CAPACITY_DEFERRED"]
      assert Enum.all?(verdicts, &(&1.verdict == :cohort_drained))
    end

    test "SILENT: the cohort sheds exactly the vanished class's population" do
      # 698 rows stopped being written and the cohort is 698 rows smaller. The
      # class went quiet; nothing wears its name.
      before_rows = [row("BOX_BUSY_DEFERRED", 698), row("BOX_AT_CAPACITY_DEFERRED", 12)]
      after_rows = [row("BOX_AT_CAPACITY_DEFERRED", 12)]

      assert ClassContinuity.check(before_rows, after_rows) == []

      assert [%{verdict: :went_quiet, retained: 0}] =
               ClassContinuity.verdicts(before_rows, after_rows)
    end

    test "SILENT below the floor: a handful of rows going to zero is noise" do
      before_rows = [row("DEFERRED_UNCLASSIFIED", 4), row("BOX_AT_CAPACITY_DEFERRED", 700)]
      after_rows = [row("BOX_AT_CAPACITY_DEFERRED", 704)]

      assert ClassContinuity.check(before_rows, after_rows) == []

      assert [%{class: "DEFERRED_UNCLASSIFIED", verdict: :below_floor}] =
               ClassContinuity.verdicts(before_rows, after_rows)

      # …and the floor is a FLOOR, not a mute: the same shape at 10 rows fires.
      assert [%{class: "DEFERRED_UNCLASSIFIED", verdict: :renamed}] =
               ClassContinuity.verdicts(
                 [row("DEFERRED_UNCLASSIFIED", 10), row("BOX_AT_CAPACITY_DEFERRED", 700)],
                 [row("BOX_AT_CAPACITY_DEFERRED", 710)]
               )
    end

    test "a class still present is not a continuity question at all" do
      before_rows = [row("BOX_BUSY_DEFERRED", 698)]
      after_rows = [row("BOX_BUSY_DEFERRED", 1)]

      assert ClassContinuity.check(before_rows, after_rows) == []
      assert ClassContinuity.verdicts(before_rows, after_rows) == []
    end

    test "the tolerance keeps a near-total shed quiet, and a partial one loud" do
      before_rows = [row("BOX_BUSY_DEFERRED", 100), row("BOX_AT_CAPACITY_DEFERRED", 50)]

      # Cohort shed 95 of the 100 — within 10%. Quiet.
      assert ClassContinuity.check(before_rows, [row("BOX_AT_CAPACITY_DEFERRED", 55)]) == []

      # Cohort shed 50 of the 100 — half those rows are still being written.
      assert [%{verdict: :renamed, retained: 50}] =
               ClassContinuity.check(before_rows, [row("BOX_AT_CAPACITY_DEFERRED", 100)])
    end

    test "the successor is NAMED, biggest gain first" do
      before_rows = [row("BOX_BUSY_DEFERRED", 698), row("DEFERRED_UNCLASSIFIED", 2)]
      after_rows = [row("BOX_AT_CAPACITY_DEFERRED", 690), row("DEFERRED_UNCLASSIFIED", 12)]

      assert [finding] = ClassContinuity.check(before_rows, after_rows)

      assert finding.absorbed_by == [
               %{class: "BOX_AT_CAPACITY_DEFERRED", gain: 690},
               %{class: "DEFERRED_UNCLASSIFIED", gain: 10}
             ]
    end
  end

  describe "the 2026-08-06 22:19:52Z fixture, through the real census" do
    setup do
      {_user, team} = user_team()
      %{site: site_fixture(team)}
    end

    test "the swap FIRES: BOX_BUSY_DEFERRED to zero, the deferred cohort holds", %{site: site} do
      # BEFORE the swap the box answered `already_running`; AFTER it the same
      # physical refusal came back `box_at_capacity`. Same cohort, same volume,
      # different name.
      defer!(site, @d_busy, 40, @before_from)
      defer!(site, @d_capacity, 2, @before_from)
      defer!(site, @d_capacity, 42, @after_from)

      before_census = census(site, @before_from, @before_to)
      after_census = census(site, @after_from, @after_to)

      # The published number DID NOT MOVE — which is the whole reason this check
      # had to be built. Both windows: 42 deferrals, zero failures.
      assert before_census.deferred_total == 42
      assert after_census.deferred_total == 42
      assert before_census.failed == 0
      assert after_census.failed == 0

      assert class_count(before_census, "BOX_BUSY_DEFERRED") == 40
      assert class_count(after_census, "BOX_BUSY_DEFERRED") == 0

      assert [finding] =
               ClassContinuity.check_census(before_census, after_census, :deferred)

      assert finding.class == "BOX_BUSY_DEFERRED"
      assert finding.verdict == :renamed
      assert finding.count_before == 40
      assert finding.cohort_before == 42
      assert finding.cohort_after == 42
      assert finding.retained == 40
      assert [%{class: "BOX_AT_CAPACITY_DEFERRED", gain: 40} | _] = finding.absorbed_by
    end

    test "the same fixture with the cohort DRAINED stays silent", %{site: site} do
      # Identical before window. The after window has no deferrals at all — the
      # fleet went quiet, nothing was renamed.
      defer!(site, @d_busy, 40, @before_from)
      defer!(site, @d_capacity, 2, @before_from)

      before_census = census(site, @before_from, @before_to)
      after_census = census(site, @after_from, @after_to)

      assert after_census.deferred_total == 0
      assert ClassContinuity.check_census(before_census, after_census, :deferred) == []

      assert Enum.all?(
               ClassContinuity.verdicts(before_census.deferred, after_census.deferred),
               &(&1.verdict in [:cohort_drained, :below_floor])
             )
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp row(class, count), do: %{class: class, count: count}

  defp class_count(census, class) do
    case Enum.find(census.deferred, &(&1.class == class)) do
      nil -> 0
      found -> found.count
    end
  end

  defp census(site, from, to), do: DeployLedger.census(from, to, site_ids: [site.id])

  defp user_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "cc-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "CC #{n}", slug: "cc-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp site_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Deferred rows, inserted as structs: `Deployment.changeset/2` refuses to cast
  # `status`, and the census needs each row pinned inside an exact window. Every
  # row is spread by a second so nothing lands on the exclusive `to` bound.
  defp defer!(site, reason, n, from) do
    entries =
      for i <- 1..n do
        at = from |> DateTime.add(i, :second) |> usec()

        %{
          id: Ecto.UUID.generate(),
          site_id: site.id,
          status: "deferred",
          environment: "production",
          stage: "PLAN",
          failure_reason: reason,
          inserted_at: at,
          updated_at: at
        }
      end

    {^n, _} = Repo.insert_all(Deployment, entries)
    :ok
  end

  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  # The instant this whole file exists for, asserted so a future edit that moves
  # the windows off it has to say so out loud.
  test "the fixture windows bracket the 2026-08-06 22:19:52Z swap" do
    assert DateTime.compare(@before_to, @swap) == :eq
    assert DateTime.compare(@after_from, @swap) == :eq
    assert DateTime.compare(@before_from, @swap) == :lt
    assert DateTime.compare(@after_to, @swap) == :gt
  end
end
