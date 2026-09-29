defmodule BarkparkCloud.DeployLedger.ClassContinuityTest do
  @moduledoc """
  THE CLASS-CONTINUITY GAUGE — deploy-reliability W18, charter **D265**.

  This suite replaces the W12/D179 suite that stood here. Its two real prod
  specimens are the point:

    * **(a)** the DAILY shape either side of the 2026-08-05 vocabulary boundary
      (08-01 `2217/284/1933/0`, 08-06 `2205/566/866/773` as
      volume/live/failed/deferred), where a failure class dies and its successor
      is born in a DIFFERENT COHORT;
    * **(b)** the 2026-08-06 22:xx INTRA-DEFERRED rename
      (`already_running` → `box_at_capacity`, D266's measured hourly series),
      where the deferred cohort QUADRUPLES across the very event being detected —
      the shape a cohort-total-keyed predicate is structurally blind to.

  And the arms that let it LOSE: a genuine repair prints `:repaired`, an unpaired
  arrival prints `:new_cause`, a class absent from both windows is silent, and a
  window below `min_sample` refuses with no percentage anywhere.

  The DB half drives the real `DeployLedger.class_continuity/3` over rows
  carrying the VERBATIM box refusal strings, so the gauge is proven against the
  census's own output shape and its own self-derived basis rather than against a
  hand-built map that could drift from both. Every call is scoped with
  `:site_ids` to this test's own site: the fleet-wide default would read every
  other agent's rows out of the one shared test database and the fixture would
  stop being a fixture.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, DeployLedger, Registry, Repo}
  alias BarkparkCloud.BoxCapacityRefusalFixture
  alias BarkparkCloud.DeployLedger.ClassContinuity
  alias BarkparkCloud.Registry.Deployment

  @password "correct-horse-battery"

  # ── The 2026-08-06 instant, and the two windows around it ─────────────────
  #
  # 22:19:52Z is when guerrilla took ef77af274 (#9827, the typed
  # box_at_capacity door). Both windows sit AFTER the deferred-settle-status
  # vocabulary boundary (2026-08-05 21:27:11Z), so nothing here straddles it —
  # the swap being detected is a CLASS swap inside one settled vocabulary.
  @swap ~U[2026-08-06 22:19:52Z]
  @before_from ~U[2026-08-06 20:00:00Z]
  @before_to ~U[2026-08-06 22:19:52Z]
  @after_from ~U[2026-08-06 22:19:52Z]
  @after_to ~U[2026-08-07 00:39:44Z]

  # Refusal strings from the same corpus `deploy_ledger_test.exs` keys on.
  # `classify_deferred/2` reads the anchored 409 prefix and the box's own code
  # word out of these; an invented string would classify to
  # DEFERRED_UNCLASSIFIED and the fixture would test nothing.
  @requeued " — deferred: a rebuild carrying this content has been re-queued and will run once the in-flight deploy finishes"
  @d_busy "the instance refused the deploy (HTTP 409): already_running — a deploy is already in flight" <>
            @requeued
  # THE BOX'S OWN CAPACITY REFUSAL — NOT retyped here. `BoxCapacityRefusalFixture`
  # reads the ONE shared copy (api/test/support/fixtures/box_capacity_refusal.json),
  # and BarkparkWeb.SiteDeployCapacityBodyConformanceTest asserts the REAL emitter
  # still produces it byte-for-byte. Do not paste the string back in — the mirror
  # guard (deploy_ledger/capacity_body_mirror_guard_test.exs) fails if you do.
  @d_capacity BoxCapacityRefusalFixture.deferred_detail() <> @requeued

  describe "SPECIMEN (a) — the 08-05 boundary, daily shape, the event D265 was filed for" do
    # 08-01: volume 2,217 / live 284 / failed 1,933 / deferred 0
    # 08-06: volume 2,205 / live 566 / failed   866 / deferred 773
    #
    # 1,700 of 08-01's failures are BOX_BUSY_409 — 76.68% OF ATTEMPTS, and
    # 87.95% of the failure cohort. That second number is the one a
    # cohort-relative gauge would print, and it cannot be compared with the
    # deferral birth on the other side of the boundary.
    setup do
      %{
        before:
          census(
            2217,
            [{"BOX_BUSY_409", 1700}, {"BOX_500", 133}, {"BOX_UNAVAILABLE_503", 100}],
            []
          ),
        after:
          census(2205, [{"BOX_500", 470}, {"BOX_UNAVAILABLE_503", 396}], [
            {"BOX_AT_CAPACITY_DEFERRED", 773}
          ])
      }
    end

    test "the death is reported as a share of ATTEMPTS, and the verdict is :renamed", ctx do
      %{before: before_c, after: after_c} = ctx
      gauge = ClassContinuity.gauge(before_c, after_c)

      refute gauge.refused
      assert gauge.attempts_before == 2217
      assert gauge.attempts_after == 2205

      death = find(gauge, "BOX_BUSY_409")

      assert death.kind == :death
      assert death.verdict == :renamed
      # THE NUMBER THE WHOLE FIX IS ABOUT. 1700/2217, never 1700/1933.
      assert death.share_before == 76.68
      assert death.share_after == 0.0
      assert death.absorbed_share == 63.82
      assert death.unpaired_share == 12.86

      # THE SUCCESSOR IS IN THE OTHER COHORT, and it is named FIRST. The D179
      # gauge was handed one cohort at a time and could not see this row at all.
      assert [%{class: "BOX_AT_CAPACITY_DEFERRED", share: 35.06} | _] = death.counterparts
    end

    test "the deferral birth is :new_cause and carries the death that explains it", ctx do
      %{before: before_c, after: after_c} = ctx
      birth = ClassContinuity.gauge(before_c, after_c) |> find("BOX_AT_CAPACITY_DEFERRED")

      assert birth.kind == :birth
      # CLAUSE (vii): a birth is NEVER `:renamed`, however well a death explains
      # it. The explanation is a number beside the verdict, not a promotion.
      assert birth.verdict == :new_cause
      assert birth.share_before == 0.0
      assert birth.share_after == 35.06
      assert birth.absorbed_share == 35.06
      assert birth.unpaired_share == 0.0
      assert birth.counterparts == [%{class: "BOX_BUSY_409", share: 35.06}]
    end

    test "CLAUSE (ix): the unpaired remainder is reported on BOTH sides, never suppressed", ctx do
      %{before: before_c, after: after_c} = ctx
      gauge = ClassContinuity.gauge(before_c, after_c)

      # Deaths lost 76.68 points, gains absorbed 63.82 of them: 12.86 points of
      # the 409 mass are genuinely gone (they became successes — `live` rose
      # 284 → 566). The gauge says BOTH halves out loud.
      assert find(gauge, "BOX_BUSY_409").unpaired_share == 12.86
      assert find(gauge, "BOX_AT_CAPACITY_DEFERRED").unpaired_share == 0.0

      # And the birth is REPORTED at all, which the W12 probe's hole would have
      # suppressed the moment any death existed in the window.
      assert Enum.any?(gauge.findings, &(&1.kind == :birth))
    end

    test "THE FILING'S OWN ARITHMETIC IS REFUTED: 35.06% absorbed of a 76.68% loss is :repaired",
         ctx do
      %{before: before_c} = ctx
      # D265 records specimen (a) as `share_before 76.68%, absorbed_elsewhere
      # 35.06%, verdict :renamed` AND, in clause (vi), an absorption floor of
      # 75%. Those cannot both hold: 35.06 / 76.68 = 45.7%.
      #
      # Here is the fixture that makes 35.06 the TOTAL absorbed share — the
      # surviving failure classes hold their ROW counts, so only the deferral
      # birth gains. Clause (vi), implemented verbatim, prints `:repaired`. The
      # 35.06% figure in the charter is the DEFERRAL ABSORBER ALONE, not the
      # total, and reading it as the total inverts the verdict.
      only_deferrals_absorb =
        census(2205, [{"BOX_500", 132}, {"BOX_UNAVAILABLE_503", 99}], [
          {"BOX_AT_CAPACITY_DEFERRED", 773}
        ])

      death = ClassContinuity.gauge(before_c, only_deferrals_absorb) |> find("BOX_BUSY_409")

      assert death.absorbed_share == 35.06
      assert death.verdict == :repaired
      assert death.unpaired_share == 41.62
    end

    test "CLAUSE (i) IS LOAD-BEARING: the same event read cohort-relative is a different number",
         ctx do
      %{before: before_c, after: after_c} = ctx
      # Not a mutation of the module — the arithmetic itself, stated so the
      # reviewer can see the two rulers side by side. 87.95% "of failures" and
      # 76.68% "of attempts" are the same 1,700 rows; only the second can be
      # compared with 773/2205 = 35.06% of attempts in the OTHER cohort.
      assert Float.round(1700 * 100 / 1933, 2) == 87.95
      assert Float.round(1700 * 100 / 2217, 2) == 76.68
      assert find(ClassContinuity.gauge(before_c, after_c), "BOX_BUSY_409").share_before == 76.68
    end
  end

  describe "SPECIMEN (b) — the 2026-08-06 22:xx intra-deferred rename" do
    # D266's measured hourly series across the boundary: `already_running`
    # 28 → 0/0/0/0/0 while `box_at_capacity` 0 → 63 → 137 → 154 → 171 → 144.
    # Summed over EQUAL 5-hour windows: 140 → 0 and 0 → 669.
    #
    # The volume/live/failed split around those deferral counts is the smallest
    # envelope consistent with them (a census needs a `volume`, and the charter
    # records none at hourly resolution). The DEFERRAL counts are measured; the
    # rest of each window's shape is scaffolding and is not asserted on.
    setup do
      %{
        before: census(462, [{"BOX_500", 88}], [{"BOX_BUSY_DEFERRED", 140}]),
        after: census(806, [{"BOX_500", 21}], [{"BOX_AT_CAPACITY_DEFERRED", 669}])
      }
    end

    test ":renamed EVEN THOUGH the deferred cohort quadruples across the event", ctx do
      %{before: before_c, after: after_c} = ctx
      # This is the arm no cohort-total predicate can reach. "A class goes to
      # zero while its cohort total HOLDS" is false here in the loudest possible
      # way — the cohort went 140 → 669, nearly five times — and the rename is
      # real anyway, because the gauge never reads the cohort total.
      assert 669 / 140 > 4.0

      gauge = ClassContinuity.gauge(before_c, after_c)
      death = find(gauge, "BOX_BUSY_DEFERRED")

      assert death.verdict == :renamed
      assert death.share_before == 30.3
      assert death.share_after == 0.0
      assert death.absorbed_share == 30.3
      assert death.counterparts == [%{class: "BOX_AT_CAPACITY_DEFERRED", share: 30.3}]

      birth = find(gauge, "BOX_AT_CAPACITY_DEFERRED")
      assert birth.verdict == :new_cause
      assert birth.share_after == 83.0
      # Most of the arrival is NOT explained by the death: the door opened and
      # the fleet started deferring far more than it used to. Saying so is the
      # difference between an instrument and a story.
      assert birth.unpaired_share == 52.7
    end

    test "a class present in BOTH windows is neither a death nor a birth", ctx do
      %{before: before_c, after: after_c} = ctx
      # BOX_500 shrinks 88 → 21 rows across specimen (b). It is still being
      # written, so it raises no continuity question and gets no finding.
      gauge = ClassContinuity.gauge(before_c, after_c)

      assert "BOX_500" in gauge.classes_read
      assert Enum.all?(gauge.findings, &(&1.class != "BOX_500"))
    end
  end

  describe "IT CAN LOSE" do
    test ":repaired — a class dies and NOTHING wears its name" do
      before_c = census(2000, [{"BOX_BUSY_409", 800}], [])
      after_c = census(2000, [], [])

      assert [death] = ClassContinuity.gauge(before_c, after_c).findings
      assert death.class == "BOX_BUSY_409"
      assert death.verdict == :repaired
      assert death.share_before == 40.0
      assert death.absorbed_share == 0.0
      assert death.unpaired_share == 40.0
      assert death.counterparts == []
    end

    test ":new_cause — an unpaired arrival, with nothing dying anywhere" do
      before_c = census(1000, [], [])
      after_c = census(1000, [{"BOX_ROUTE_UNKNOWN_404", 300}], [])

      assert [birth] = ClassContinuity.gauge(before_c, after_c).findings
      assert birth.class == "BOX_ROUTE_UNKNOWN_404"
      assert birth.verdict == :new_cause
      assert birth.share_after == 30.0
      assert birth.absorbed_share == 0.0
      assert birth.unpaired_share == 30.0
    end

    test "CLAUSE (viii): a class absent from BOTH windows is SILENT, not a 0 to 0 death" do
      # `BOX_UNAUTHORIZED_401` and `BOX_RATE_LIMITED_429` are minted classes in
      # `DeployLedger.classes/0` with no rows in either window. A gauge that
      # iterated the code's enum instead of the observed union would report both
      # as deaths forever, and adding a class NAME would generate alarms.
      before_c = census(2000, [{"BOX_500", 500}], [])
      after_c = census(2000, [{"BOX_500", 480}], [])

      gauge = ClassContinuity.gauge(before_c, after_c)

      assert gauge.classes_read == ["BOX_500"]
      assert gauge.findings == []

      minted = DeployLedger.classes()
      assert "BOX_UNAUTHORIZED_401" in minted
      assert "BOX_RATE_LIMITED_429" in minted
      refute Enum.any?(minted -- ["BOX_500"], &(&1 in gauge.classes_read))
    end

    test "CLAUSE (vi): a death below the material floor raises nothing" do
      # 0.9% of attempts. Real, and not worth an operator's attention — the
      # floor is on SHARE and not on rows, because 18 rows means something
      # different on a 527-attempt day than on a 2,205-attempt one.
      before_c = census(2000, [{"NOISE", 18}, {"BOX_500", 500}], [])
      after_c = census(2000, [{"BOX_500", 560}], [])

      gauge = ClassContinuity.gauge(before_c, after_c)

      assert "NOISE" in gauge.classes_read
      assert gauge.findings == []

      # …and the floor is a FLOOR, not a mute: 1.0% of attempts fires.
      loud = ClassContinuity.gauge(census(2000, [{"NOISE", 20}, {"BOX_500", 500}], []), after_c)
      assert [%{class: "NOISE", verdict: :renamed, share_before: 1.0}] = loud.findings
    end
  end

  describe "IT REFUSES, in this module's own shape" do
    test "below min_sample on EITHER window — and no percentage is printed" do
      thin = census(150, [{"BOX_BUSY_409", 120}], [])
      fat = census(2205, [{"BOX_500", 470}], [{"BOX_AT_CAPACITY_DEFERRED", 773}])

      for {b, a, reason} <- [
            {thin, thin, "attempts 150/150 below min_sample 200"},
            {thin, fat, "attempts 150/2205 below min_sample 200"},
            {fat, thin, "attempts 2205/150 below min_sample 200"}
          ] do
        gauge = ClassContinuity.gauge(b, a)

        assert gauge.refused
        assert gauge.reason == reason
        assert gauge.findings == []
        assert gauge.classes_read == []

        # THE REFUSAL IS THE SAME KEY SET AS THE MEASUREMENT (the wire-shape
        # lesson from `refuse_class_rows/2`), and it carries NO share of
        # anything — a percentage off a sample too small to carry one is the
        # thing being refused.
        assert Map.keys(gauge) == Map.keys(ClassContinuity.gauge(fat, fat))
        refute gauge |> Map.drop([:basis]) |> inspect() |> String.contains?("share")
      end
    end

    test "exactly at min_sample it MEASURES — the floor is inclusive" do
      before_c = census(200, [{"BOX_BUSY_409", 100}], [])
      after_c = census(200, [], [])

      gauge = ClassContinuity.gauge(before_c, after_c)

      refute gauge.refused
      assert gauge.reason == nil
      assert [%{class: "BOX_BUSY_409", verdict: :repaired}] = gauge.findings
    end
  end

  describe "THE D179 FIXTURE, through the real census and its self-derived basis" do
    setup do
      {_user, team} = user_team()
      %{site: site_fixture(team)}
    end

    test "the 2026-08-06 22:19:52Z swap, read by DeployLedger.class_continuity/3", %{site: site} do
      # THE W12 FIXTURE, KEPT — same instant, same two windows, same refusal
      # strings — and now read through the corrected verdicts. BEFORE the swap
      # the box answered `already_running`; AFTER it the same physical refusal
      # came back `box_at_capacity`.
      #
      # `class_continuity/3` is handed the AFTER window ONLY and derives the
      # before window itself (clause iv): equal length, immediately prior. The
      # windows are 2h19m52s, and volumes are lifted above `min_sample` on both
      # sides so the gauge measures rather than refuses.
      defer!(site, @d_busy, 210, @before_from)
      defer!(site, @d_capacity, 10, @before_from)
      defer!(site, @d_capacity, 260, @after_from)

      gauge = DeployLedger.class_continuity(@after_from, @after_to, site_ids: [site.id])

      refute gauge.refused
      assert gauge.attempts_before == 220
      assert gauge.attempts_after == 260

      death = find(gauge, "BOX_BUSY_DEFERRED")
      assert death.kind == :death
      assert death.verdict == :renamed
      # 210/220 of attempts before, zero after.
      assert death.share_before == 95.45
      assert death.share_after == 0.0
      assert [%{class: "BOX_AT_CAPACITY_DEFERRED"} | _] = death.counterparts

      # The published rate DID NOT MOVE across this — which is the whole reason
      # the gauge exists. Both windows: every attempt a deferral, zero failures.
      after_census = DeployLedger.census(@after_from, @after_to, site_ids: [site.id])
      assert after_census.failed == 0
      assert after_census.deferred_total == 260
    end

    test "the same fixture with the after window EMPTY refuses rather than alarming", %{
      site: site
    } do
      # 220 attempts before, 0 after. The D179 gauge would have called this
      # `:cohort_drained` and said something. The corrected one has no sample to
      # speak from and says so.
      defer!(site, @d_busy, 210, @before_from)
      defer!(site, @d_capacity, 10, @before_from)

      gauge = DeployLedger.class_continuity(@after_from, @after_to, site_ids: [site.id])

      assert gauge.refused
      assert gauge.reason == "attempts 220/0 below min_sample 200"
      assert gauge.findings == []
    end

    test "the basis is SELF-DERIVED and EQUAL-LENGTH — no store, nothing to go stale", %{
      site: site
    } do
      defer!(site, @d_busy, 210, @before_from)
      defer!(site, @d_capacity, 10, @before_from)
      defer!(site, @d_capacity, 260, @after_from)

      derived = DeployLedger.class_continuity(@after_from, @after_to, site_ids: [site.id])

      # The same reading, assembled by hand from two explicit `census/3` calls
      # over the two windows, is identical. Nothing is remembered between them.
      explicit =
        ClassContinuity.gauge(
          DeployLedger.census(@before_from, @before_to, site_ids: [site.id]),
          DeployLedger.census(@after_from, @after_to, site_ids: [site.id])
        )

      assert derived == explicit
      assert DateTime.diff(@before_to, @before_from) == DateTime.diff(@after_to, @after_from)
    end
  end

  test "the fixture windows bracket the 2026-08-06 22:19:52Z swap" do
    assert DateTime.compare(@before_to, @swap) == :eq
    assert DateTime.compare(@after_from, @swap) == :eq
    assert DateTime.compare(@before_from, @swap) == :lt
    assert DateTime.compare(@after_to, @swap) == :gt
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # A census-SHAPED envelope carrying only what the gauge reads. Built here
  # rather than by inserting thousands of rows because specimen (a) is a
  # 2,217-attempt DAY: the DB half above proves the gauge against the real
  # `census/3` output shape, and these fixtures carry the real prod NUMBERS.
  defp census(volume, classes, deferred) do
    %{
      volume: volume,
      min_sample: 200,
      classes: Enum.map(classes, fn {class, count} -> %{class: class, count: count} end),
      deferred: Enum.map(deferred, fn {class, count} -> %{class: class, count: count} end)
    }
  end

  defp find(gauge, class), do: Enum.find(gauge.findings, &(&1.class == class))

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
end
