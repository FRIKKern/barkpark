defmodule BarkparkCloud.RegistryUpdateStatusTest do
  @moduledoc """
  isu-6 — `Registry.refresh_update_status/1`: mirror the instance's OWN
  self-update verdict (`GET /v1/admin/self-update` → the `"check"` block) onto
  the barkparks row, server-side with the stored admin token. Proves:

    * happy path: a 200 with `check.state == "behind"` persists the state, the
      running/latest releases, and a fresh `update_checked_at`; the instance
      was called with the DECRYPTED admin bearer on the right endpoint
    * pre-feature instance (404) → `{:error, :no_self_update_route}` AND the row
      is best-effort landed on `update_state: "unknown"` (releases cleared,
      checked_at stamped) — never a stale lie
    * no stored admin token → `{:error, :no_admin_token}`, same "unknown"
      landing, and the instance is never called

  cch-w58 adds the WHY: `update_state: "unknown"` collapses five worlds, so the
  verdict now lands in `update_unavailable_reason`. Proved here as a
  DISTINCTNESS property over four programmed upstream shapes (401 / 404 /
  transport failure / decodable 200) — four shapes must produce four different
  persisted verdicts — rather than as four literal equalities copied out of the
  implementation, which would pass just as happily against a table of constants.
  Plus: 404 (a pre-feature box that refused nothing) is NOT the 401 verdict, and
  a clean 200 CLEARS a previously-persisted refusal.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, Vault}
  alias BarkparkCloud.StudioLinkFakeHttpClient

  @instance_admin_token "instance-admin-token-plaintext"
  @instance_url "https://prod.barkpark.cloud"

  ## Fixtures (mirror RouterStudioLinkTest's)

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  # A LIVE instance: url + host set, encrypted admin token stored (what the
  # provision-succeed path writes).
  defp live_barkpark(team) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
  end

  defp check_body(state) do
    Jason.encode!(%{
      state: "idle",
      exit_code: nil,
      log: [],
      check: %{
        state: state,
        running_version: "0.9.0",
        running_release: "v0.9.0",
        latest_release: "v1.2.0",
        canonical_release: "v1.2.0",
        digest: [],
        checked_at: "2026-07-02T12:00:00Z"
      }
    })
  end

  # cch-w58: drive ONE programmed upstream shape through the real transport seam
  # and return what the ROW ends up saying. Deliberately reads the persisted
  # column, not the returned atom: the point of that slice is that the verdict
  # outlives the call.
  defp persisted_reason(response) do
    # A FRESH box per shape (`barkparks.url` is uniquely indexed, so the four
    # shapes cannot share the fixture's one url) — and each verdict is therefore
    # written by its own row, not overwritten on a shared one.
    bp =
      live_barkpark(team_fixture())
      |> Ecto.Changeset.change(url: "#{@instance_url}/#{System.unique_integer([:positive])}")
      |> Repo.update!()

    StudioLinkFakeHttpClient.program([response])
    _ = Registry.refresh_update_status(bp)
    Repo.get!(Barkpark, bp.id).update_unavailable_reason
  end

  describe "refresh_update_status/1" do
    test "200 with check.state=behind → {:ok, bp} with state + releases + checked_at persisted" do
      bp = live_barkpark(team_fixture())

      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("behind")}}])

      assert {:ok, %Barkpark{} = refreshed} = Registry.refresh_update_status(bp)
      assert refreshed.update_state == "behind"
      assert refreshed.update_running_release == "v0.9.0"
      assert refreshed.update_latest_release == "v1.2.0"
      assert %DateTime{} = refreshed.update_checked_at

      # Persisted, not just returned.
      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "behind"
      assert reloaded.update_latest_release == "v1.2.0"

      # The instance-side check was called correctly: GET on the admin
      # endpoint, the DECRYPTED admin token as bearer.
      assert [req] = StudioLinkFakeHttpClient.requests()
      assert req.method == :get
      assert req.url == @instance_url <> "/v1/admin/self-update"

      assert {"Authorization", "Bearer " <> @instance_admin_token} =
               List.keyfind(req.headers, "Authorization", 0)
    end

    test "pre-feature instance (404) → {:error, :no_self_update_route} and the row lands on unknown" do
      bp = live_barkpark(team_fixture())

      # Seed a previous verdict so the failure landing provably CLEARS it.
      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("behind")}}])
      {:ok, bp} = Registry.refresh_update_status(bp)
      assert bp.update_state == "behind"

      StudioLinkFakeHttpClient.program([{:ok, %{status: 404, body: ~s({"error":"not_found"})}}])
      assert {:error, :no_self_update_route} = Registry.refresh_update_status(bp)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "unknown"
      assert reloaded.update_running_release == nil
      assert reloaded.update_latest_release == nil
      assert %DateTime{} = reloaded.update_checked_at
    end

    test "live instance without a stored admin token → {:error, :no_admin_token}, unknown landed, instance never called" do
      bp =
        team_fixture()
        |> barkpark_fixture()
        |> Ecto.Changeset.change(url: @instance_url, host: "203.0.113.10")
        |> Repo.update!()

      StudioLinkFakeHttpClient.program([])

      assert {:error, :no_admin_token} = Registry.refresh_update_status(bp)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "unknown"
      assert %DateTime{} = reloaded.update_checked_at

      assert StudioLinkFakeHttpClient.requests() == []
    end
  end

  describe "refresh_update_status/1 persists WHY the state is unknown (cch-w58)" do
    test "a 401 and a 404 are NOT the same verdict — a pre-feature box refused nothing" do
      refused = persisted_reason({:ok, %{status: 401, body: ~s({"error":"unauthorized"})}})
      pre_feature = persisted_reason({:ok, %{status: 404, body: ~s({"error":"not_found"})}})

      # Both must actually be on file...
      refute is_nil(refused)
      refute is_nil(pre_feature)

      # ...and they must be DIFFERENT. A box that never heard of the route has
      # not refused our credential, and a later slice refusing on the 401 verdict
      # must not also cut off every merely-old box (charter D684).
      refute refused == pre_feature
    end

    test "four upstream shapes produce four distinct persisted verdicts" do
      reasons = [
        # the box refuses OUR credential
        persisted_reason({:ok, %{status: 401, body: ~s({"error":"unauthorized"})}}),
        # a pre-feature box: no such route
        persisted_reason({:ok, %{status: 404, body: ~s({"error":"not_found"})}}),
        # nothing answered at all
        persisted_reason({:error, :econnrefused}),
        # a healthy box with a readable verdict
        persisted_reason({:ok, %{status: 200, body: check_body("current")}})
      ]

      # A DISTINCTNESS property, not four equalities copied from the
      # implementation: four different worlds upstream must not read as the same
      # thing downstream. Four literal assertions would pass just as happily
      # against a lookup table of constants; this cannot.
      assert length(Enum.uniq(reasons)) == 4
    end

    test "a decodable 200 CLEARS a previously persisted refusal" do
      bp = live_barkpark(team_fixture())

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 401, body: ~s({"error":"unauthorized"})}}
      ])

      assert {:error, :identity_refused} = Registry.refresh_update_status(bp)
      assert Repo.get!(Barkpark, bp.id).update_unavailable_reason == "identity_refused"

      # The box recovers — the credential works again.
      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("current")}}])
      assert {:ok, _} = Registry.refresh_update_status(bp)

      reloaded = Repo.get!(Barkpark, bp.id)
      assert reloaded.update_state == "current"
      # A stale accusation must not outlive the recovery.
      assert is_nil(reloaded.update_unavailable_reason)
    end

    test "every reason the refresh can persist is inside the changeset whitelist" do
      # If a future arm hands persist_update_unknown/2 an atom outside
      # update_unavailable_reasons/0, validate_inclusion rejects it and the
      # best-effort write silently drops the verdict — leaving the row's OLD
      # reason on file, which is worse than none. This pins the vocabulary.
      for reason <- ~w(identity_refused forbidden no_self_update_route unreachable instance_error
                       no_admin_token decrypt_failed not_live) do
        assert reason in Barkpark.update_unavailable_reasons()
      end
    end
  end
end
