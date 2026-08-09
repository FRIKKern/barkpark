defmodule BarkparkCloud.RegistryAutoupdateTest do
  @moduledoc """
  isu-w4 — the fleet-autoupdate POLICY + queries `Registry` exposes to the
  `AutoupdateRolloutWorker`. Proves eligibility (`next_autoupdate_candidate/0`)
  honours every gate, the in-flight query + markers behave, and the narrow
  policy setter can touch nothing but its three fields.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, Vault}
  alias BarkparkCloud.StudioLinkFakeHttpClient

  @admin_token "instance-admin-token-plaintext"

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

    test "channel defaults to prod and set_autoupdate IGNORES it (operator lever)" do
      bp = behind_barkpark()
      assert bp.channel == "prod"

      # the team-facing setter can NOT move a box between rollout channels —
      # a tenant staging box would close the fleet-wide canary gate
      {:ok, updated} = Registry.set_autoupdate(bp, %{channel: "staging"})
      assert updated.channel == "prod"
    end

    test "set_channel/2 (operator) accepts staging, rejects anything else" do
      bp = behind_barkpark()

      {:ok, updated} = Registry.set_channel(bp, "staging")
      assert updated.channel == "staging"

      assert {:error, %Ecto.Changeset{} = cs} = Registry.set_channel(updated, "canary")
      assert %{channel: _} = errors_on(cs)
      # the row is untouched by the rejected write
      assert Registry.get_barkpark(bp.id).channel == "staging"
    end
  end

  describe "next_autoupdate_candidate/1 (channel-confined)" do
    test "a channel argument confines the pick to that channel" do
      staging = behind_barkpark(%{channel: "staging"})
      prod = behind_barkpark(%{channel: "prod"})

      assert Registry.next_autoupdate_candidate("staging").id == staging.id
      assert Registry.next_autoupdate_candidate("prod").id == prod.id
    end

    test "no channel argument still spans all channels" do
      _staging = behind_barkpark(%{channel: "staging"})
      assert %Barkpark{} = Registry.next_autoupdate_candidate()
    end
  end

  describe "staging_gate_open?/0 (canary gate)" do
    test "fails OPEN when no staging box is registered" do
      behind_barkpark(%{channel: "prod"})
      assert Registry.staging_gate_open?() == true
    end

    test "closed while a staging box is behind (blocks prod)" do
      behind_barkpark(%{channel: "staging", update_state: "behind"})
      assert Registry.staging_gate_open?() == false
    end

    test "open once a staging box is current on the latest release" do
      behind_barkpark(%{
        channel: "staging",
        update_state: "current",
        update_running_release: "v0.3.0",
        update_latest_release: "v0.3.0"
      })

      assert Registry.staging_gate_open?() == true
    end

    test "closed when a current staging box is NOT on the latest release" do
      behind_barkpark(%{
        channel: "staging",
        update_state: "current",
        update_running_release: "v0.2.24",
        update_latest_release: "v0.3.0"
      })

      assert Registry.staging_gate_open?() == false
    end
  end

  describe "autoupdate kill switch (fleet_settings)" do
    test "defaults to NOT halted when the fleet has never toggled it" do
      assert Registry.autoupdate_halted?() == false
    end

    test "halt then resume round-trips through the persisted single row" do
      {:ok, _} = Registry.set_autoupdate_halted(true)
      assert Registry.autoupdate_halted?() == true

      {:ok, _} = Registry.set_autoupdate_halted(false)
      assert Registry.autoupdate_halted?() == false
    end

    test "repeated halt upserts the SAME single row (never a second)" do
      {:ok, _} = Registry.set_autoupdate_halted(true)
      {:ok, _} = Registry.set_autoupdate_halted(true)
      assert Repo.aggregate(BarkparkCloud.Registry.FleetSettings, :count) == 1
    end
  end

  describe "trigger_self_update/2 pin honesty (isu-w5.2)" do
    test "a pinned instance rejects an unforced trigger with :pinned" do
      bp = behind_barkpark(%{pinned_release: "v0.2.24"})
      assert Registry.trigger_self_update(bp) == {:error, :pinned}
    end

    test "force: true bypasses the pin gate (falls through to the transport)" do
      # Pinned but url-less: force clears the pin gate, so we reach the live
      # guard and get :not_live — proving force overrode the pin (not :pinned).
      bp = behind_barkpark(%{pinned_release: "v0.2.24"}) |> unset_url()
      assert Registry.trigger_self_update(bp, force: true) == {:error, :not_live}
    end

    test "force: true on a live pinned box actually triggers the update" do
      bp =
        behind_barkpark(%{
          pinned_release: "v0.2.24",
          admin_token_encrypted: Vault.encrypt(@admin_token)
        })

      StudioLinkFakeHttpClient.program([{:ok, %{status: 202, body: ~s({"ok":true})}}])

      assert {:ok, 202, _} = Registry.trigger_self_update(bp, force: true)
      [req] = StudioLinkFakeHttpClient.requests()
      assert req.url =~ "/v1/admin/self-update"
    end

    test "an UNpinned instance is unaffected by the pin gate" do
      bp = behind_barkpark() |> unset_url()
      # no pin → straight to the live guard (url-less → :not_live), never :pinned
      assert Registry.trigger_self_update(bp) == {:error, :not_live}
    end
  end

  describe "identity refusal on the shared admin-POST seam (cch-w60-s4)" do
    # A live box carrying a decryptable admin token AND a probe verdict. The
    # `update_state: "unknown"` mirrors the producer: `persist_update_unknown/2`
    # writes the reason and "unknown" in the SAME changeset.
    defp probed_barkpark(reason) do
      behind_barkpark(%{
        admin_token_encrypted: Vault.encrypt(@admin_token),
        update_state: "unknown",
        update_unavailable_reason: reason
      })
    end

    # Program the 202 the box WOULD have answered: a refusal that slipped BELOW
    # the relay would then return {:ok, 202, _} and the return-value assertion
    # alone would still look like a pass. The wire assertion is the real proof.
    defp program_the_202_it_would_have_answered do
      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 202, body: ~s({"ok":true,"status":"started"})}}
      ])
    end

    test "a REFUTED box refuses the self-update trigger and NOTHING reaches the wire" do
      bp = probed_barkpark("identity_refused")
      program_the_202_it_would_have_answered()

      result = Registry.trigger_self_update(bp)

      # THE WIRE FIRST: the stored credential was never decrypted, never spent.
      assert StudioLinkFakeHttpClient.requests() == []
      assert result == {:error, :identity_refused}
    end

    test "a REFUTED box refuses the ROLLBACK trigger and NOTHING reaches the wire" do
      bp = probed_barkpark("identity_refused")
      program_the_202_it_would_have_answered()

      result = Registry.trigger_rollback(bp)

      assert StudioLinkFakeHttpClient.requests() == []
      assert result == {:error, :identity_refused}
    end

    test "a NULL update_unavailable_reason PERMITS both triggers (the unprobed rung)" do
      bp = probed_barkpark(nil)

      program_the_202_it_would_have_answered()
      assert {:ok, 202, _} = Registry.trigger_self_update(bp)
      assert [%{url: url}] = StudioLinkFakeHttpClient.requests()
      assert url =~ "/v1/admin/self-update"

      program_the_202_it_would_have_answered()
      assert {:ok, 202, _} = Registry.trigger_rollback(bp)
      assert [%{url: rollback_url}] = StudioLinkFakeHttpClient.requests()
      assert rollback_url =~ "/v1/admin/rollback"
    end

    test "EVERY OTHER rung of update_unavailable_reasons/0 PERMITS — iterated, never hand-copied" do
      rungs = Barkpark.update_unavailable_reasons()

      # Anti-vacuity floor: if the whitelist ever shrinks to just the refusing
      # rung (or to nothing), this loop would iterate zero permitting rungs and
      # pass while proving nothing.
      assert "identity_refused" in rungs
      assert length(rungs) >= 9

      others = rungs -- ["identity_refused"]
      assert length(others) >= 8

      for reason <- others do
        bp = probed_barkpark(reason)
        program_the_202_it_would_have_answered()

        result = Registry.trigger_self_update(bp)
        wire = StudioLinkFakeHttpClient.requests()

        assert match?({:ok, 202, _}, result),
               "rung #{inspect(reason)} must PERMIT the trigger — only identity_refused refuses. " <>
                 "Got #{inspect(result)} with wire #{inspect(wire)}"

        assert length(wire) == 1,
               "rung #{inspect(reason)} must reach the wire — got #{inspect(wire)}"
      end
    end

    test "PIN PRECEDENCE: pinned+refused is :pinned unforced, :identity_refused forced, wire EMPTY both" do
      bp =
        behind_barkpark(%{
          admin_token_encrypted: Vault.encrypt(@admin_token),
          update_state: "unknown",
          update_unavailable_reason: "identity_refused",
          pinned_release: "v0.2.24"
        })

      # UNFORCED: the pin head-clause on trigger_self_update/2 matches above the
      # relay, so the operator is told about the pin. Both verdicts are terminal
      # and the wire is empty either way — only the WORD differs.
      program_the_202_it_would_have_answered()
      unforced = Registry.trigger_self_update(bp)
      assert StudioLinkFakeHttpClient.requests() == []
      assert unforced == {:error, :pinned}

      # FORCED: the pin is overridden, and the refusal underneath it holds.
      program_the_202_it_would_have_answered()
      forced = Registry.trigger_self_update(bp, force: true)
      assert StudioLinkFakeHttpClient.requests() == []
      assert forced == {:error, :identity_refused}
    end

    # REVIEW ADDITION (cch-w61 review): the seam choice — refuse on
    # `relay_admin_post/3`, NOT on `relay_admin/4` — was argued structurally
    # ("relay_admin/4 is untouched") but never measured. A future refactor that
    # hoisted the clause one seam up would silently refuse every READ at a
    # refuted box (webhook lists, dataset reads, token mints) and no test would
    # notice. This pins the scope: a READ still reaches the wire.
    test "SCOPE: a READ through relay_admin/4 at a REFUTED box still reaches the wire" do
      bp = probed_barkpark("identity_refused")

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: ~s({"ok":true})}}
      ])

      assert {:ok, 200, _} = Registry.relay_admin(bp, :get, "/v1/admin/health", nil)

      assert [%{url: url}] = StudioLinkFakeHttpClient.requests()
      assert url =~ "/v1/admin/health"
    end
  end

  defp unset_url(bp), do: bp |> Ecto.Changeset.change(url: nil, host: "") |> Repo.update!()
end
