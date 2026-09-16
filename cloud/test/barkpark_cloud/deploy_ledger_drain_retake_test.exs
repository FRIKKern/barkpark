defmodule BarkparkCloud.DeployLedgerDrainRetakeTest do
  @moduledoc """
  THE RE-TAKE AT ITS MARKS, AND THE DOOR AN OPERATOR OPENS IT WITH
  (dr-w13-bl-waiting-alert-population-is-empty, charter D190/D211(b)).

  `DrainDistribution` landed able to measure and with NO caller in `cloud/lib`:
  reachable from its own suite and from nowhere else, which is the exact shape
  the deploy ledger's reachability census (`deploy_ledger_reachability_test.exs`)
  exists to refuse. A measurement nobody can invoke on the box holding the
  population cannot answer a criterion about that population, so the row's real
  remainder was never more arithmetic — it was a door.

  This file holds both halves to the same bar as the reader itself: every fact
  asserted has an arm that makes it FALSE.

      fact asserted                        the arm that can flip it
      ───────────────────────────────────  ──────────────────────────────────────
      "a mark not reached refuses"         the same call past the mark prints
                                           the figures it withheld
      "the 24h window is the FIRST 24h"    a chain seeded between 24h and 72h is
                                           ABSENT at "24h" and PRESENT at "72h"
      "rows and chains are recorded apart" one 2,500s wait: 40 rows, 1 head
      "the door runs the query"            the same door over an empty fleet
                                           reads NO SAMPLE, not wave 13's 1,110

  What this file does NOT claim: no reading here is a LIVE one. The 24h and 72h
  re-takes the row asks to be RECORDED need the production database, which this
  suite cannot reach and must not try to.
  """
  use BarkparkCloud.DataCase, async: true

  import ExUnit.CaptureIO

  alias BarkparkCloud.{Accounts, Registry, Release, Repo}
  alias BarkparkCloud.DeployLedger.DrainDistribution
  alias BarkparkCloud.Registry.Deployment

  @password "correct-horse-battery"
  @r409 "the instance refused the deploy (HTTP 409)"

  # D179 + 24h and D179 + 72h. Written out rather than computed, so a change to
  # the boundary or to an offset reds HERE instead of agreeing with itself.
  @mark_24h ~U[2026-08-07 22:19:52.000000Z]
  @mark_72h ~U[2026-08-09 22:19:52.000000Z]

  # A clock well past both marks: the "is the window pinned?" tests need a NOW
  # that would give the wrong answer if `retake/2` used it as the window's end.
  @long_after ~U[2026-09-16 00:00:00Z]

  describe "the marks" do
    test "both marks are the boundary plus their offset, and an unknown label refuses" do
      assert DrainDistribution.retake_at("24h") == {:ok, @mark_24h}
      assert DrainDistribution.retake_at("72h") == {:ok, @mark_72h}

      assert DateTime.diff(@mark_24h, DrainDistribution.regime_boundary(), :second) == 86_400
      assert DateTime.diff(@mark_72h, DrainDistribution.regime_boundary(), :second) == 259_200

      # THE ARM: a label that is not a mark does not silently become one.
      assert {:error, message} = DrainDistribution.retake_at("48h")
      assert message =~ ~s(unknown mark "48h")
      assert message =~ ~s("24h")
      assert message =~ ~s("72h")

      assert DrainDistribution.retake("48h") == [
               ~s(RE-TAKE REFUSED — unknown mark "48h"; this row asks for "24h" and "72h")
             ]
    end

    # Wave 13's whole defect from the other side: it printed figures off a window
    # 12h13m old and the row read them as the 24h answer.
    test "a mark the clock has not reached prints NO figures — and the same call past it does" do
      site = site_fixture()
      seed_chain(site, at: ~U[2026-08-07 06:00:00Z], rounds: 5, every: 60, served_after: 212)

      too_early =
        DrainDistribution.retake("72h", site_id: site.id, now: ~U[2026-08-08 00:00:00Z])
        |> Enum.join("\n")

      assert too_early =~ "RE-TAKE REFUSED — the 72h mark is 46h19m away. No figures."
      refute too_early =~ "RECORD"
      refute too_early =~ "ruling"

      # THE ARM: nothing about the fleet changed; only the clock did.
      reached =
        DrainDistribution.retake("72h", site_id: site.id, now: @long_after) |> Enum.join("\n")

      refute reached =~ "REFUSED"
      assert reached =~ "RECORD 72h rows    n=5"
      assert reached =~ "ruling"
    end
  end

  describe "the window is the MARK, not the moment of reading" do
    # If `retake/2` ended its window at `now`, both re-takes would cover the same
    # rows and the 24h answer would drift every time somebody ran it.
    test "a chain that arrived after 24h is ABSENT at 24h and PRESENT at 72h" do
      site = site_fixture()
      # Inside the first 24 hours.
      seed_chain(site, at: ~U[2026-08-07 06:00:00Z], rounds: 5, every: 60, served_after: 212)
      # Between the two marks — the rows that separate the readings.
      seed_chain(site, at: ~U[2026-08-08 12:00:00Z], rounds: 7, every: 60, served_after: 300)

      at_24h = DrainDistribution.retake("24h", site_id: site.id, now: @long_after)
      at_72h = DrainDistribution.retake("72h", site_id: site.id, now: @long_after)

      assert Enum.join(at_24h, "\n") =~ "RECORD 24h rows    n=5"
      assert Enum.join(at_24h, "\n") =~ "RECORD 24h chains  n=1"
      assert Enum.join(at_24h, "\n") =~ "mark #{DateTime.to_iso8601(@mark_24h)}"

      # THE ARM, same fleet, same clock, one label apart.
      assert Enum.join(at_72h, "\n") =~ "RECORD 72h rows    n=12"
      assert Enum.join(at_72h, "\n") =~ "RECORD 72h chains  n=2"
      assert Enum.join(at_72h, "\n") =~ "mark #{DateTime.to_iso8601(@mark_72h)}"
    end
  end

  describe "what the RECORD line records" do
    test "the five quantities the row names, once per UNIT, and the units differ" do
      site = site_fixture()
      # ~42 rows ride ONE 2,520-second wait. Row-keyed, that is 42 long waits;
      # chain-keyed it is one publish that waited.
      seed_chain(site, at: ~U[2026-08-07 06:00:00Z], rounds: 42, every: 60, served_after: 2_520)

      [rows_line] =
        DrainDistribution.retake("24h", site_id: site.id, now: @long_after)
        |> Enum.filter(&String.contains?(&1, "RECORD 24h rows"))

      [chains_line] =
        DrainDistribution.retake("24h", site_id: site.id, now: @long_after)
        |> Enum.filter(&String.contains?(&1, "RECORD 24h chains"))

      for line <- [rows_line, chains_line] do
        assert line =~ ~r/ n=\d+ /
        assert line =~ ~r/ p50=[\d.]+s /
        assert line =~ ~r/ p95=[\d.]+s /
        assert line =~ ~r/ max=[\d.]+s /
        assert line =~ ~r/ no_live_1h=\d+ /
        assert line =~ "uncensored population 42"
      end

      # THE ARM: the two units are NOT the same number, which is the whole
      # reason both are recorded.
      assert rows_line =~ "n=42"
      assert chains_line =~ "n=1"
      assert rows_line =~ "max=2520.0s"
    end

    # The ruling rides the re-take, both ways, off the same reader.
    test "a drain inside the hour records no_live_1h=0; one past it records a threshold" do
      quiet = site_fixture()
      seed_chain(quiet, at: ~U[2026-08-07 06:00:00Z], rounds: 5, every: 60, served_after: 212)

      loud = site_fixture()
      seed_chain(loud, at: ~U[2026-08-07 06:00:00Z], rounds: 5, every: 60, served_after: 9_000)

      quiet_text =
        DrainDistribution.retake("24h", site_id: quiet.id, now: @long_after) |> Enum.join("\n")

      loud_text =
        DrainDistribution.retake("24h", site_id: loud.id, now: @long_after) |> Enum.join("\n")

      assert quiet_text =~ "no_live_1h=0"
      assert quiet_text =~ "POPULATION EMPTY — 0 of 1 chain heads"

      assert loud_text =~ "RECORD 24h chains  n=1 p50=9000.0s"
      assert loud_text =~ "no_live_1h=1"
      assert loud_text =~ "THRESHOLD DERIVABLE — 1 of 1 chain heads"
      assert loud_text =~ "per CHAIN HEAD over"
      assert loud_text =~ "post-D179 regime only"
    end
  end

  describe "the door: Release.drain_distribution/1" do
    # The reader's ONE caller in cloud/lib, exercised end to end — the query runs
    # against the database and the bytes reach stdout. Nothing here is mocked;
    # remove the `IO.puts` and this reds.
    test "it runs the query and prints a re-take an operator can read" do
      site = site_fixture()
      seed_chain(site, at: ~U[2026-08-07 06:00:00Z], rounds: 5, every: 60, served_after: 212)

      printed = capture_io(fn -> Release.drain_distribution("24h") end)

      assert printed =~ "RE-TAKE 24h — mark #{DateTime.to_iso8601(@mark_24h)}"
      assert printed =~ "DRAIN DISTRIBUTION — post-regime deferral wait"
      assert printed =~ "RECORD 24h rows    n=5"
      assert printed =~ "RECORD 24h chains  n=1"
      assert printed =~ "POPULATION EMPTY"

      # THE ARM the whole module exists for: the door NEVER prints wave 13's
      # inherited reading as if it had just taken it.
      refute printed =~ "1110"
      refute printed =~ "inherited"
      assert DrainDistribution.inherited_reading().n == 1_110
    end

    test "it returns the same lines it printed, so a recorder need not scrape stdout" do
      site = site_fixture()
      seed_chain(site, at: ~U[2026-08-07 06:00:00Z], rounds: 3, every: 60, served_after: 212)

      lines = capture_io(fn -> send(self(), {:lines, Release.drain_distribution("72h")}) end)
      assert_received {:lines, returned}

      assert is_list(returned)
      assert Enum.join(returned, "\n") <> "\n" == lines
      assert Enum.any?(returned, &String.contains?(&1, "RECORD 72h chains"))
    end
  end

  # ── fixtures (same shape as deploy_ledger_drain_distribution_test.exs) ─────

  defp seed_chain(site, opts) do
    at = Keyword.fetch!(opts, :at)
    rounds = Keyword.fetch!(opts, :rounds)
    every = Keyword.fetch!(opts, :every)
    served = Keyword.fetch!(opts, :served_after)

    deferrals!(
      site,
      Enum.map(0..(rounds - 1), fn i ->
        {DateTime.add(at, i * every, :second), "box_at_capacity"}
      end)
    )

    lives!(site, [DateTime.add(at, served, :second)])
  end

  defp deferrals!(site, stamps) do
    insert_all!(
      site,
      Enum.map(stamps, fn {at, code} ->
        %{
          status: "deferred",
          inserted_at: at,
          failure_reason: @r409,
          box_refusal_code: code,
          became_live_at: nil
        }
      end)
    )
  end

  defp lives!(site, marks) do
    insert_all!(site, Enum.map(marks, &%{status: "live", inserted_at: &1, became_live_at: &1}))
  end

  defp insert_all!(site, rows) do
    entries =
      Enum.map(rows, fn r ->
        at = usec(Map.fetch!(r, :inserted_at))

        %{
          id: Ecto.UUID.generate(),
          site_id: site.id,
          status: Map.fetch!(r, :status),
          environment: "production",
          failure_reason: Map.get(r, :failure_reason),
          box_refusal_code: Map.get(r, :box_refusal_code),
          became_live_at: r |> Map.get(:became_live_at) |> maybe_usec(),
          inserted_at: at,
          updated_at: at
        }
      end)

    Repo.insert_all(Deployment, entries)
  end

  defp site_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} = Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  defp maybe_usec(nil), do: nil
  defp maybe_usec(dt), do: usec(dt)

  defp usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}
end
