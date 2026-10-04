defmodule BarkparkCloud.MemberRemovalInstanceDeprovisionTest do
  @moduledoc """
  Owner ruling #26 (2026-10-03, "Match role, revoke"): removing a person from
  a team takes them OFF the team's instances, not just off Cloud.

  Before: `Accounts.remove_member/2` evicted Cloud sessions and PATs only, so a
  removed member kept their Studio login and every token they had minted on the
  box. After: the removal enqueues ONE `InstanceMemberDeprovisionWorker` job in
  the same transaction, and the job asks every live box to deprovision them.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, Registry, Repo, StudioLinkFakeHttpClient}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Workers.InstanceMemberDeprovisionWorker

  @password "correct-horse-battery"
  @admin_token "stored-instance-admin-token"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_with(owner) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, owner, "owner")
    team
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "https://bp-#{n}.barkpark.cloud",
      host: "203.0.113.#{rem(n, 200) + 10}",
      admin_token_encrypted: Vault.encrypt(@admin_token)
    )
    |> Repo.update!()
  end

  describe "Accounts.remove_member/2" do
    test "enqueues ONE instance-deprovision job naming the removed person — and only them" do
      owner = user_fixture()
      team = team_with(owner)
      gone = user_fixture()
      stays = user_fixture()
      {:ok, _} = Accounts.add_member(team, gone, "member")
      {:ok, _} = Accounts.add_member(team, stays, "member")

      assert {:ok, :removed} = Accounts.remove_member(team, gone)

      assert_enqueued(
        worker: InstanceMemberDeprovisionWorker,
        args: %{team_id: team.id, email: gone.email}
      )

      assert [_one] = all_enqueued(worker: InstanceMemberDeprovisionWorker)
      refute_enqueued(worker: InstanceMemberDeprovisionWorker, args: %{email: stays.email})
    end

    test "a refused removal (the last owner) enqueues nothing" do
      owner = user_fixture()
      team = team_with(owner)

      assert {:error, :last_owner} = Accounts.remove_member(team, owner)
      refute_enqueued(worker: InstanceMemberDeprovisionWorker)
    end
  end

  describe "InstanceMemberDeprovisionWorker" do
    test "asks each live box to deprovision the email, with the stored admin bearer" do
      owner = user_fixture()
      team = team_with(owner)
      bp = live_barkpark(team)
      # A row with no url yet (still provisioning) is skipped, not called.
      {:ok, _pending} =
        Registry.register_barkpark(team, %{
          name: "Pending",
          slug: "pending-#{System.unique_integer([:positive])}"
        })

      StudioLinkFakeHttpClient.program([
        {:ok,
         %{
           status: 200,
           body:
             ~s({"found":true,"sessions_revoked":1,"memberships_dropped":1,"tokens_revoked":2})
         }}
      ])

      assert :ok =
               perform_job(InstanceMemberDeprovisionWorker, %{
                 team_id: team.id,
                 email: "gone@example.com"
               })

      assert [req] = StudioLinkFakeHttpClient.requests()
      assert req.method == :post
      assert req.url == bp.url <> "/v1/auth/cloud-users/deprovision"
      assert Jason.decode!(req.body) == %{"email" => "gone@example.com"}

      assert {"Authorization", "Bearer " <> @admin_token} =
               List.keyfind(req.headers, "Authorization", 0)
    end

    test "a box that predates the route still gets the app-token revoke" do
      owner = user_fixture()
      team = team_with(owner)
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 404, body: "Not Found"}},
        {:ok, %{status: 200, body: ~s({"revoked":true,"revoked_count":1})}}
      ])

      assert {:ok, %{"fallback" => "app_tokens_only", "revoked_count" => 1}} =
               Registry.deprovision_instance_user(bp, "gone@example.com")

      assert [_, revoke] = StudioLinkFakeHttpClient.requests()
      assert revoke.method == :delete
      assert revoke.url == bp.url <> "/v1/auth/app-tokens"
      assert Jason.decode!(revoke.body) == %{"email" => "gone@example.com"}
    end

    test "a box that does not answer fails the job so Oban retries it" do
      owner = user_fixture()
      team = team_with(owner)
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([{:error, :econnrefused}])

      assert {:error, {:unreachable, [slug]}} =
               perform_job(InstanceMemberDeprovisionWorker, %{
                 team_id: team.id,
                 email: "gone@example.com"
               })

      assert slug == bp.slug
    end
  end
end
