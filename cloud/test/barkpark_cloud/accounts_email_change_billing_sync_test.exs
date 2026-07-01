defmodule BarkparkCloud.AccountsEmailChangeBillingSyncTest do
  @moduledoc """
  The verified email-change → billing customer email sync is FAIL-SOFT: a gateway
  error is logged but must NOT roll back the committed email swap. `async: false`
  because it swaps the process-global configured billing gateway (the same
  pattern as billing_trial_test.exs).
  """
  use BarkparkCloud.DataCase, async: false
  import ExUnit.CaptureLog

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.User
  alias BarkparkCloud.Billing.{StubGateway, Subscription}
  alias BarkparkCloud.Repo

  @password "correct-horse-battery"

  # A gateway whose update_customer FAILS; everything else defers to StubGateway
  # (unused on this path). Exercises the fail-soft branch of sync_billing_email/1.
  defmodule FailingUpdateGateway do
    @moduledoc false
    @behaviour BarkparkCloud.Billing.Gateway

    @impl true
    def update_customer(_customer_id, _attrs), do: {:error, :boom}

    @impl true
    def create_customer(attrs), do: StubGateway.create_customer(attrs)

    @impl true
    def create_subscription(customer_id, plan),
      do: StubGateway.create_subscription(customer_id, plan)

    @impl true
    def charge(customer_id, amount, currency, meta),
      do: StubGateway.charge(customer_id, amount, currency, meta)

    @impl true
    def create_checkout_session(team_id, plan, opts \\ []),
      do: StubGateway.create_checkout_session(team_id, plan, opts)

    @impl true
    def create_billing_portal_session(customer_id, opts \\ []),
      do: StubGateway.create_billing_portal_session(customer_id, opts)

    @impl true
    def cancel_subscription(subscription_id, opts \\ []),
      do: StubGateway.cancel_subscription(subscription_id, opts)

    @impl true
    def verify_webhook(payload, signature), do: StubGateway.verify_webhook(payload, signature)
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp active_subscription!(team, customer_id) do
    {:ok, sub} =
      %Subscription{}
      |> Subscription.changeset(%{
        team_id: team.id,
        plan: "supporter",
        status: "active",
        gateway_customer_id: customer_id
      })
      |> Repo.insert()

    sub
  end

  defp stage_change(user, new_email) do
    assert {:ok, _} = Accounts.deliver_user_update_email_instructions(user, new_email)
    assert_receive {:email, email}
    [code] = Regex.run(~r/\b\d{6}\b/, email.text_body)
    {Repo.get!(User, user.id), code}
  end

  setup do
    prev = Application.get_env(:barkpark_cloud, BarkparkCloud.Billing)

    Application.put_env(
      :barkpark_cloud,
      BarkparkCloud.Billing,
      Keyword.put(prev || [], :gateway, FailingUpdateGateway)
    )

    on_exit(fn -> Application.put_env(:barkpark_cloud, BarkparkCloud.Billing, prev) end)
    :ok
  end

  test "a Stripe update_customer error is logged but does NOT roll back the email swap" do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    active_subscription!(team, "cus_test_#{System.unique_integer([:positive])}")

    target = "synced-#{System.unique_integer([:positive])}@example.com"
    {user, code} = stage_change(user, target)

    log =
      capture_log(fn ->
        assert {:ok, %User{} = updated} = Accounts.update_user_email(user, code)
        # The swap COMMITTED despite the gateway failure.
        assert updated.email == target
        assert updated.pending_email == nil
      end)

    assert log =~ "stripe email sync failed"
    # And it really is persisted, not just returned.
    assert Repo.get!(User, user.id).email == target
  end
end
