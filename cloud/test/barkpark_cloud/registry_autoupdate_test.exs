defmodule BarkparkCloud.RegistryAutoupdateTest do
  @moduledoc """
  isu-w4 — the fleet-autoupdate POLICY + queries `Registry` exposes to the
  `AutoupdateRolloutWorker`. Proves eligibility (`next_autoupdate_candidate/0`)
  honours every gate, the in-flight query + markers behave, and the narrow
  policy setter can touch nothing but its three fields.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Barkpark

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # A live, `behind`, autoupdate-eligible instance unless `overrides` say otherwise.
  defp behind_barkpark(overrides \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          host: "203.0.113.#{rem(n, 250) + 1}",
          url: "https://bp-#{n}.barkpark.cloud",
          suspended: false,
          update_state: "behind",
          update_checked_at: DateTime.utc_now(),
          autoupdate_enabled: true,
          autoupdate_paused: false,
          pinned_release: nil,
          autoupdate_triggered_at: nil
        },
        overrides
      )
    )
    |> Repo.update!()
  end

  describe "next_autoupdate_candidate/0" do
    test "returns a live, behind, enabled, unpaused, unpinned, not-in-flight instance" do
      bp = behind_barkpark()
      assert %Barkpark{id: id} = Registry.next_autoupdate_candidate()
      assert id == bp.id
    end

    test "excludes instances that are not behind" do
      behind_barkpark(%{update_state: "current"})
      behind_barkpark(%{update_state: "unknown"})
      assert Registry.next_autoupdate_candidate() == nil
    end

    test "excludes disabled, paused, and pinned instances" do
      behind_barkpark(%{autoupdate_enabled: false})
      behind_barkpark(%{autoupdate_paused: true})
      behind_barkpark(%{pinned_release: "v0.2.24"})
      assert Registry.next_autoupdate_candidate() == nil
    end

    test "excludes in-flight, suspended, and hostless instances" do
      behind_barkpark(%{autoupdate_triggered_at: DateTime.utc_now()})
      behind_barkpark(%{suspended: true})
      behind_barkpark(%{host: ""})
      assert Registry.next_autoupdate_candidate() == nil
    end

    test "picks the most-stale first (oldest update_checked_at)" do
      _newer = behind_barkpark(%{update_checked_at: ~U[2026-07-06 12:00:00.000000Z]})
      older = behind_barkpark(%{update_checked_at: ~U[2026-07-01 12:00:00.000000Z]})
      assert %Barkpark{id: id} = Registry.next_autoupdate_candidate()
      assert id == older.id
    end
  end

  describe "in-flight markers" do
    test "mark/clear toggle autoupdate_in_flight/0 membership" do
      bp = behind_barkpark()
      assert Registry.autoupdate_in_flight() == []

      {:ok, marked} = Registry.mark_autoupdate_triggered(bp)
      assert marked.autoupdate_triggered_at
      assert [%Barkpark{id: id}] = Registry.autoupdate_in_flight()
      assert id == bp.id

      {:ok, _} = Registry.clear_autoupdate_triggered(marked)
      assert Registry.autoupdate_in_flight() == []
    end
  end

  describe "set_autoupdate/2 (narrow policy)" do
    test "sets the three policy fields and normalizes a blank pin to nil" do
      bp = behind_barkpark()

      {:ok, updated} =
        Registry.set_autoupdate(bp, %{
          autoupdate_enabled: false,
          autoupdate_paused: true,
          pinned_release: "  "
        })

      assert updated.autoupdate_enabled == false
      assert updated.autoupdate_paused == true
      assert updated.pinned_release == nil
    end

    test "cannot touch identity or the in-flight marker" do
      bp = behind_barkpark()
      stamp = DateTime.utc_now()

      {:ok, updated} =
        Registry.set_autoupdate(bp, %{
          slug: "hijacked",
          team_id: Ecto.UUID.generate(),
          autoupdate_triggered_at: stamp,
          pinned_release: "v0.3.0"
        })

      assert updated.slug == bp.slug
      assert updated.team_id == bp.team_id
      assert updated.autoupdate_triggered_at == nil
      assert updated.pinned_release == "v0.3.0"
    end

    test "pause_autoupdate/1 sets the paused flag" do
      bp = behind_barkpark()
      {:ok, paused} = Registry.pause_autoupdate(bp)
      assert paused.autoupdate_paused == true
    end
  end
end
