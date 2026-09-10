defmodule BarkparkCloud.DeployLedgerDoorDenominatorTest do
  @moduledoc """
  `DeployLedger.census/3`'s `box_door` term — the box door's OWN denominator
  (dr-w22-s5, charter D379).

  THE DEFECT, measured on the live corpus 2026-08-07: six box-capacity refusals
  settled `failed` rather than `deferred` (01:20:14 -> 03:41:33). They carry the
  409 marker in `failure_reason` and `deferral_cause IS NULL`, because that
  column is written in exactly ONE place — `Sites.Deploy.defer/3`. Every reader
  that counted the door as
  `status='deferred' AND deferral_cause='BOX_AT_CAPACITY_DEFERRED'` therefore
  counted 1,804 where the door had refused 1,810.

  So the honest predicate is the PROSE MARKER, across ALL statuses, and these
  are the properties this file holds:

    1. THE ALL-STATUSES ARM IS LOAD-BEARING. A `failed` 409 row with a NULL
       cause is counted by `refusals` and NOT by `cause_keyed`. Narrow the term
       to `status='deferred'` and this file goes red — which is the mutation
       run recorded in the PR body.
    2. THE GAP IS COUNTED, NEVER SUBTRACTED. `unkeyed` is its own query over the
       marked rows the cause-keyed predicate misses, so it cannot go negative
       when a cause-keyed row's `failure_reason` does not carry the marker — a
       shape this file seeds deliberately.
    3. THE DEFERRAL COHORT IS UNCHANGED. The term is ADDITIVE: the existing
       per-cause `deferred` rows are byte-identical beside it, because they are
       the correct answer to a different question (how much the door RE-QUEUED).
    4. THE TERM SURVIVES A STRADDLING WINDOW. The vocabulary boundary at
       2026-08-05T21:13:50Z is exactly where the same refusal stopped being
       written `failed` and started being written `deferred`; a status-keyed
       quantity blends two taxonomies across it, and this one — keyed on a field
       BOTH vocabularies write identically — does not.

  EVERY read here is SCOPED with `:site_ids`. The test database is shared, and a
  fleet-wide census over a fixed window would fold another suite's rows into
  these counts.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{DeployLedger, Registry, Repo}
  alias BarkparkCloud.Registry.Deployment

  # PINNED, like every window in this ledger, and deliberately WHOLLY AFTER the
  # 2026-08-05T21:13:50Z vocabulary boundary in the default case so property 3's
  # deferral rows are not refused for a reason that has nothing to do with this
  # term. Property 4 gets its own straddling window.
  @from ~U[2026-08-06 22:29:27Z]
  @to ~U[2026-08-08 00:00:00Z]
  @inside ~U[2026-08-07 01:20:14Z]

  # The box's own words, as `failure_reason` records them on both sides of the
  # boundary. Kept as literals rather than built from the module attribute they
  # must match — a fixture that derives its input from the code under test
  # cannot fail when that code changes.
  @capex "the instance refused the deploy (HTTP 409): box_at_capacity [box request_id: F9tPXq2A]"
  @unrelated_409 "the instance refused the deploy (HTTP 409): already_running"
  @build_failed "BUILD failed (exit 1)"

  defp site_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} =
      BarkparkCloud.Accounts.register_user(%{
        email: "door-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, team} = BarkparkCloud.Accounts.create_team(%{name: "T #{n}", slug: "t-door-#{n}"})
    {:ok, _} = BarkparkCloud.Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-door-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-door-#{n}"})
    site
  end

  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp rows!(site, specs) do
    entries =
      Enum.flat_map(specs, fn {status, reason, cause, n, at} ->
        for _ <- 1..n do
          t = usec(at)

          %{
            id: Ecto.UUID.generate(),
            site_id: site.id,
            status: status,
            stage: "deploy",
            failure_reason: reason,
            deferral_cause: cause,
            environment: "production",
            inserted_at: t,
            updated_at: t
          }
        end
      end)

    {n, nil} = Repo.insert_all(Deployment, entries)
    n
  end

  defp door(site, opts \\ []) do
    from = Keyword.get(opts, :from, @from)
    to = Keyword.get(opts, :to, @to)
    DeployLedger.census(from, to, site_ids: [site.id])
  end

  describe "the door term counts REFUSALS, not RE-QUEUES" do
    # THE CRITERION'S OWN SHAPE, seeded to the row: one `failed` 409 with a NULL
    # cause beside the cause-keyed deferrals. The term counts it; the cause-keyed
    # predicate does not. This is the assertion the mutation (narrowing the arm
    # to `status='deferred'`) turns red.
    test "a `failed` capacity 409 with a NULL cause is IN refusals and OUT of cause_keyed" do
      site = site_fixture()

      rows!(site, [
        {"deferred", @capex, "BOX_AT_CAPACITY_DEFERRED", 4, @inside},
        {"failed", @capex, nil, 1, @inside}
      ])

      %{box_door: d} = door(site)

      assert d.refusals == 5,
             "the honest predicate must see all five marked rows, saw #{d.refusals}"

      assert d.cause_keyed == 4,
             "the cause-keyed predicate sees only the re-queued rows, saw #{d.cause_keyed}"

      assert d.unkeyed == 1,
             "the `failed` NULL-cause row is exactly the row the old reader misses"
    end

    # THE CONTROL, and it is the arm that makes the assertion above mean
    # something. Without it, a term that counted EVERY row in the window would
    # pass every count above by coincidence.
    test "an unrelated 409 and a plain build failure are OUTSIDE the door entirely" do
      site = site_fixture()

      rows!(site, [
        {"deferred", @capex, "BOX_AT_CAPACITY_DEFERRED", 2, @inside},
        {"deferred", @unrelated_409, "BOX_BUSY_DEFERRED", 7, @inside},
        {"failed", @build_failed, nil, 9, @inside}
      ])

      %{box_door: d, volume: volume} = door(site)

      assert volume == 18, "the census still sees every row in the window"
      assert d.refusals == 2, "only the capacity-marked rows are the door's, saw #{d.refusals}"
      assert d.cause_keyed == 2
      assert d.unkeyed == 0
    end

    # PROPERTY 2. `unkeyed` is COUNTED, not subtracted. A cause-keyed row whose
    # `failure_reason` does not carry the marker is a real shape (the cause
    # column is written by the defer path, the marker by the box), and under a
    # `refusals - cause_keyed` derivation this fixture prints -1 missing rows.
    test "the gap never goes negative when a cause-keyed row carries no marker" do
      site = site_fixture()

      rows!(site, [
        {"deferred", @capex, "BOX_AT_CAPACITY_DEFERRED", 1, @inside},
        {"deferred", nil, "BOX_AT_CAPACITY_DEFERRED", 3, @inside}
      ])

      %{box_door: d} = door(site)

      assert d.refusals == 1
      assert d.cause_keyed == 4
      assert d.unkeyed == 0, "a direct count of the missed rows cannot be negative"
      assert d.refusals - d.cause_keyed == -3, "and the subtraction this replaces WOULD be"
    end

    # PROPERTY 3. ADDITIVE. The per-cause deferral rows are untouched — the term
    # discloses the gap beside them, it does not reconcile them away.
    test "the per-cause deferral rows are unchanged beside the new term" do
      site = site_fixture()

      rows!(site, [
        {"deferred", @capex, "BOX_AT_CAPACITY_DEFERRED", 4, @inside},
        {"failed", @capex, nil, 1, @inside}
      ])

      census = door(site)

      row = Enum.find(census.deferred, &(&1.class == "BOX_AT_CAPACITY_DEFERRED"))
      assert row, "the deferral cohort still carries its own BOX_AT_CAPACITY_DEFERRED row"

      assert row.count == 4,
             "the deferral row still counts RE-QUEUES (4), not refusals (#{census.box_door.refusals})"

      assert census.box_door.refusals == 5
    end

    # The term names its own population, in the producer's words, so the
    # rendered line can quote a predicate instead of asserting one.
    test "the term carries both predicates and its basis" do
      site = site_fixture()
      rows!(site, [{"deferred", @capex, "BOX_AT_CAPACITY_DEFERRED", 1, @inside}])

      %{box_door: d} = door(site)

      assert d.predicate =~ "box_at_capacity"
      assert d.predicate =~ "ALL statuses"
      assert d.cause_predicate =~ "BOX_AT_CAPACITY_DEFERRED"
      assert is_binary(d.basis) and d.basis != ""
    end

    # The status split is the EVIDENCE for the gap, carried on the wire rather
    # than left for the reader to infer.
    test "by_status splits the marked population by where it settled" do
      site = site_fixture()

      rows!(site, [
        {"deferred", @capex, "BOX_AT_CAPACITY_DEFERRED", 4, @inside},
        {"failed", @capex, nil, 1, @inside}
      ])

      %{box_door: d} = door(site)

      split = Map.new(d.by_status, &{&1.status, &1.count})
      assert split == %{"deferred" => 4, "failed" => 1}
    end
  end

  describe "the boundary" do
    # PROPERTY 4. A window that STRADDLES 2026-08-05T21:13:50Z refuses
    # `failure_rate` — the status vocabulary changed there. The door term keys on
    # `failure_reason`, which both vocabularies write identically, so it answers.
    test "a straddling window refuses the failure rate and still answers the door" do
      site = site_fixture()

      rows!(site, [
        {"failed", @capex, nil, 3, ~U[2026-08-05 12:00:00Z]},
        {"deferred", @capex, "BOX_AT_CAPACITY_DEFERRED", 2, ~U[2026-08-06 12:00:00Z]}
      ])

      census =
        door(site, from: ~U[2026-08-04 00:00:00Z], to: ~U[2026-08-08 00:00:00Z])

      assert census.failure_rate.refused, "the control: the window really does straddle"
      assert census.box_door.refusals == 5, "and the door still counts across it"
      assert census.box_door.cause_keyed == 2
      assert census.box_door.unkeyed == 3
    end

    # The window still BOUNDS the term: a marked row outside it is not the
    # window's row.
    test "a marked row outside the window is outside the term" do
      site = site_fixture()

      rows!(site, [
        {"deferred", @capex, "BOX_AT_CAPACITY_DEFERRED", 2, @inside},
        {"failed", @capex, nil, 5, ~U[2026-08-01 00:00:00Z]}
      ])

      %{box_door: d} = door(site)

      assert d.refusals == 2, "the five pre-window rows are not this window's refusals"
      assert d.unkeyed == 0
    end
  end

  describe "scoping" do
    # The term reads the SAME scoped source the rest of the census reads: a
    # team's door population and its census population can never be two
    # different sets of rows.
    test "site A's door never sees site B's refusals" do
      a = site_fixture()
      b = site_fixture()

      rows!(a, [{"deferred", @capex, "BOX_AT_CAPACITY_DEFERRED", 2, @inside}])
      rows!(b, [{"failed", @capex, nil, 11, @inside}])

      assert door(a).box_door.refusals == 2
      assert door(b).box_door.refusals == 11
      assert door(b).box_door.unkeyed == 11
    end
  end

  describe "an untouched door" do
    # A window in which the door never opened reports zeros — not a refusal, not
    # a nil. The renderer's own "print nothing" arm keys on exactly this shape.
    test "a window with no capacity rows reports a zeroed term, not an absent one" do
      site = site_fixture()
      rows!(site, [{"failed", @build_failed, nil, 3, @inside}])

      %{box_door: d} = door(site)

      assert d.refusals == 0
      assert d.cause_keyed == 0
      assert d.unkeyed == 0
      assert d.by_status == []
    end
  end
end
