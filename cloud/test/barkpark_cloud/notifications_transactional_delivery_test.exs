defmodule BarkparkCloud.NotificationsTransactionalDeliveryTest do
  @moduledoc """
  transactional-delivery-observability: every identity/transactional email
  (invite / password-reset / verify / email-change-code) writes exactly one
  Delivery row (kind "transactional") capturing the send outcome — so a
  must-arrive email is observable + gets the same retry seam alert/test sends
  have. Scope is per email type: password-reset / verify / email-change-code are
  USER-scoped (team_id nil); invite is TEAM-scoped (real team_id).

  `async: false` because the failed-send case swaps the module-global Mailer
  adapter (restored via `on_exit`).
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Repo

  # A Swoosh adapter that always fails delivery — stands in for a down mail relay.
  defmodule FailingAdapter do
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config), do: {:error, {:relay_down, :econnrefused}}
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp deliveries, do: Repo.all(Delivery)

  describe "user-scoped identity emails write a team_id-nil Delivery row" do
    test "deliver_password_reset records one sent, transactional, user-scoped row" do
      assert {:ok, _} =
               Notifications.deliver_password_reset(
                 "reset@example.com",
                 "https://barkpark.cloud/reset/xyz"
               )

      assert [%Delivery{} = d] = deliveries()
      assert d.kind == "transactional"
      assert d.event == "password_reset"
      assert d.status == "sent"
      assert d.recipient == "reset@example.com"
      assert is_nil(d.team_id)
      assert is_nil(d.last_error)
    end

    test "deliver_email_verification records a user-scoped verify row" do
      assert {:ok, _} =
               Notifications.deliver_email_verification(
                 "verify@example.com",
                 "https://barkpark.cloud/verify/xyz"
               )

      assert [%Delivery{event: "email_verification", team_id: nil, status: "sent"}] = deliveries()
    end

    test "deliver_email_change_code records a user-scoped change-code row" do
      assert {:ok, _} = Notifications.deliver_email_change_code("new@example.com", "123456")

      assert [%Delivery{event: "email_change_code", team_id: nil, status: "sent"} = d] =
               deliveries()

      assert d.recipient == "new@example.com"
    end
  end

  describe "invite email is team-scoped" do
    test "deliver_invite records a row carrying the real team_id" do
      team = team_fixture()

      assert {:ok, _} =
               Notifications.deliver_invite(%{
                 to: "invitee@example.com",
                 url: "https://barkpark.cloud/invite/abc",
                 team_name: team.name,
                 team_id: team.id
               })

      assert [%Delivery{} = d] = deliveries()
      assert d.event == "invite"
      assert d.kind == "transactional"
      assert d.status == "sent"
      assert d.recipient == "invitee@example.com"
      assert d.team_id == team.id
    end
  end

  describe "a failed send records an error-outcome row" do
    setup do
      prev = Application.get_env(:barkpark_cloud, BarkparkCloud.Mailer)
      Application.put_env(:barkpark_cloud, BarkparkCloud.Mailer, adapter: FailingAdapter)
      on_exit(fn -> Application.put_env(:barkpark_cloud, BarkparkCloud.Mailer, prev) end)
      :ok
    end

    test "a relay failure on a transactional send lands a failed Delivery row" do
      assert {:error, _} =
               Notifications.deliver_password_reset(
                 "reset@example.com",
                 "https://barkpark.cloud/reset/xyz"
               )

      assert [%Delivery{} = d] = deliveries()
      assert d.status == "failed"
      assert d.event == "password_reset"
      assert is_nil(d.team_id)
      assert d.last_error =~ "relay_down"
    end
  end
end
