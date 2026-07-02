defmodule BarkparkCloud.RegistryUpdateStatusTest do
  @moduledoc """
  isu-6 — `Registry.refresh_update_status/1`: mirror the instance's OWN
  self-update verdict (`GET /v1/admin/self-update` → the `"check"` block) onto
  the barkparks row, server-side with the stored admin token. Proves:

    * happy path: a 200 with `check.state == "behind"` persists the state, the
      running/latest releases, and a fresh `update_checked_at`; the instance
      was called with the DECRYPTED admin bearer on the right endpoint
    * pre-feature instance (404) → `{:error, :instance_error}` AND the row is
      best-effort landed on `update_state: "unknown"` (releases cleared,
      checked_at stamped) — never a stale lie
    * no stored admin token → `{:error, :no_admin_token}`, same "unknown"
      landing, and the instance is never called
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

    test "pre-feature instance (404) → {:error, :instance_error} and the row lands on unknown" do
      bp = live_barkpark(team_fixture())

      # Seed a previous verdict so the failure landing provably CLEARS it.
      StudioLinkFakeHttpClient.program([{:ok, %{status: 200, body: check_body("behind")}}])
      {:ok, bp} = Registry.refresh_update_status(bp)
      assert bp.update_state == "behind"

      StudioLinkFakeHttpClient.program([{:ok, %{status: 404, body: ~s({"error":"not_found"})}}])
      assert {:error, :instance_error} = Registry.refresh_update_status(bp)

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
end
