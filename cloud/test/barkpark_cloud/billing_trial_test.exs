defmodule BarkparkCloud.BillingTrialTest do
  @moduledoc """
  Self-serve FREE TRIAL → PAID coverage (BILL-1 + BILL-3).

  `async: false` because the BILL-3 activation test swaps the configured billing
  gateway via `Application.put_env` to a fake that RAISES on the money-creating
  calls — the deterministic `StubGateway` would mask the bug (it happily returns
  ids whether or not the webhook path is supposed to call it). A sync test case
  never runs concurrently with another case, so the env swap is hermetic.
  """
  use BarkparkCloud.DataCase, async: false
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.{Accounts, Billing, Repo}
  alias BarkparkCloud.Billing.{StubGateway, Subscription}

  # A gateway that refuses to create a customer/subscription: if the webhook
  # activation path ever calls subscribe/2 (the BILL-3 bug), the test crashes
  # loudly instead of silently double-creating. verify_webhook mirrors the
  # StubGateway so handle_webhook/2 still verifies and dispatches.
  defmodule NoCreateGateway do
    @moduledoc false
    @behaviour BarkparkCloud.Billing.Gateway

    @impl true
    def create_customer(_attrs),
      do: raise("BILL-3 regression: create_customer called on the webhook activation path")

    @impl true
    def update_customer(_customer_id, _attrs), do: raise("unused in trial tests")

    @impl true
    def create_subscription(_customer_id, _plan),
      do: raise("BILL-3 regression: create_subscription called on the webhook activation path")

    @impl true
    def charge(_customer_id, _amount, _currency, _meta), do: raise("unused in trial tests")

    @impl true
    def create_checkout_session(_team_id, _plan, _opts \\ []),
      do: raise("unused in trial tests")

    @impl true
    def create_billing_portal_session(_customer_id, _opts \\ []),
      do: raise("unused in trial tests")

    @impl true
    def cancel_subscription(_subscription_id, _opts \\ []), do: raise("unused in trial tests")

    @impl true
    def verify_webhook(payload, signature) do
      if signature == StubGateway.test_signature() do
        {:ok, %{"verified" => true, "payload" => payload}}
      else
        {:error, :invalid_signature}
      end
    end
  end

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  describe "grant_trial/1 + trial entitlement (BILL-1)" do
    test "grants an active, no-gateway, 14-day trial → entitled immediately" do
      team = team_fixture()
      refute Billing.entitled?(team)

      assert {:ok, %Subscription{} = sub} = Billing.grant_trial(team)
      assert sub.plan == "trial"
      assert sub.status == "active"
      # No gateway ids — no Stripe lifecycle event keys onto it.
      assert is_nil(sub.gateway_customer_id)
      assert is_nil(sub.gateway_subscription_id)

      # A future period end ~14 days out, and entitled while it's in the future.
      assert sub.current_period_end
      assert DateTime.compare(sub.current_period_end, DateTime.utc_now()) == :gt
      assert DateTime.diff(sub.current_period_end, DateTime.utc_now(), :day) in 13..14
      assert Billing.entitled?(team)
    end

    test "an EXPIRED trial is NOT entitled (must subscribe)" do
      team = team_fixture()

      past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:microsecond)

      {:ok, _sub} =
        %Subscription{}
        |> Subscription.changeset(%{
          team_id: team.id,
          plan: "trial",
          status: "active",
          current_period_end: past
        })
        |> Repo.insert()

      # The row is still "active" and is the team's LIVE sub, but expiry wins.
      assert %Subscription{plan: "trial", status: "active"} = Billing.live_subscription(team)
      refute Billing.entitled?(team)
    end

    test "a trial with no period end is NOT entitled" do
      team = team_fixture()

      {:ok, _sub} =
        %Subscription{}
        |> Subscription.changeset(%{team_id: team.id, plan: "trial", status: "active"})
        |> Repo.insert()

      refute Billing.entitled?(team)
    end

    test "never downgrades an existing live subscription to a trial" do
      team = team_fixture()
      {:ok, %Subscription{plan: "supporter"}} = Billing.subscribe(team, "supporter")

      assert {:ok, %Subscription{plan: "supporter"}} = Billing.grant_trial(team)
      assert %Subscription{plan: "supporter"} = Billing.live_subscription(team)
      assert 1 == Repo.aggregate(from(s in Subscription, where: s.team_id == ^team.id), :count)
    end

    test "forever and active paid stay entitled (entitlement not weakened)" do
      forever_team = team_fixture()
      {:ok, _} = Billing.grant_forever(forever_team)
      assert Billing.entitled?(forever_team)

      paid_team = team_fixture()
      {:ok, _} = Billing.subscribe(paid_team, "supporter")
      assert Billing.entitled?(paid_team)
    end
  end

  describe "activate_from_metadata — paid activation writes from session ids (BILL-3)" do
    setup do
      prev = Application.get_env(:barkpark_cloud, BarkparkCloud.Billing)

      Application.put_env(
        :barkpark_cloud,
        BarkparkCloud.Billing,
        Keyword.put(prev, :gateway, NoCreateGateway)
      )

      on_exit(fn -> Application.put_env(:barkpark_cloud, BarkparkCloud.Billing, prev) end)
      :ok
    end

    defp completed_session_event(team_id, plan, customer_id, subscription_id) do
      Jason.encode!(%{
        "id" => "evt_session_1",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "customer" => customer_id,
            "subscription" => subscription_id,
            "metadata" => %{"team_id" => team_id, "plan" => plan}
          }
        }
      })
    end

    test "writes ONE active sub from the session's customer+subscription ids, WITHOUT create_subscription" do
      # Sanity: the swap is live — the bug path would crash through this gateway.
      assert Billing.gateway() == NoCreateGateway

      team = team_fixture()
      raw = completed_session_event(team.id, "supporter", "cus_live_123", "sub_live_456")

      assert {:ok, %Subscription{} = sub} =
               Billing.handle_webhook(raw, StubGateway.test_signature())

      assert sub.team_id == team.id
      assert sub.plan == "supporter"
      assert sub.status == "active"
      # The ids came straight off the SIGNED session — not a second gateway create.
      assert sub.gateway_customer_id == "cus_live_123"
      assert sub.gateway_subscription_id == "sub_live_456"

      assert Billing.entitled?(team)
      assert 1 == Repo.aggregate(from(s in Subscription, where: s.team_id == ^team.id), :count)
    end

    test "a trial team's checkout UPGRADES the same live row to paid (no second row)" do
      team = team_fixture()
      {:ok, trial} = Billing.grant_trial(team)
      assert trial.plan == "trial"

      raw = completed_session_event(team.id, "support_plus", "cus_up_1", "sub_up_1")

      assert {:ok, %Subscription{} = sub} =
               Billing.handle_webhook(raw, StubGateway.test_signature())

      # Same row, converted in place — no one-live-per-team collision.
      assert sub.id == trial.id
      assert sub.plan == "support_plus"
      assert sub.status == "active"
      assert sub.gateway_customer_id == "cus_up_1"
      assert sub.gateway_subscription_id == "sub_up_1"
      # The trial window is cleared on conversion to paid.
      assert is_nil(sub.current_period_end)

      assert Billing.entitled?(team)
      assert 1 == Repo.aggregate(from(s in Subscription, where: s.team_id == ^team.id), :count)
    end

    test "a repeated session event is idempotent → already_active, one row" do
      team = team_fixture()
      raw = completed_session_event(team.id, "supporter", "cus_live_123", "sub_live_456")
      sig = StubGateway.test_signature()

      assert {:ok, %Subscription{}} = Billing.handle_webhook(raw, sig)
      assert {:ok, :already_active} = Billing.handle_webhook(raw, sig)
      assert 1 == Repo.aggregate(from(s in Subscription, where: s.team_id == ^team.id), :count)
    end
  end

  describe "configured?/0 (BILL-2)" do
    test "the StubGateway is always configured (dev/test)" do
      assert Billing.gateway() == StubGateway
      assert Billing.configured?()
    end
  end
end
