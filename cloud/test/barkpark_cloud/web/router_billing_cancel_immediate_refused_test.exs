defmodule BarkparkCloud.Web.RouterBillingCancelImmediateRefusedTest do
  @moduledoc """
  task-527f2a101b99ebf9 — the immediate arm of `POST /v1/billing/cancel` is
  REMOVED from the API contract, and this file is the guard that reds if it
  comes back.

  The assertion that carries the weight is NOT the status code. A regression
  could plausibly restore the immediate cancel while still answering 422 (a
  cancel that fires and then reports a shape error), and a status-only guard
  would sit green through it. So the load-bearing arm counts calls at the
  GATEWAY SEAM: `RecordingGateway` forwards every call to the real
  `StubGateway` and reports each `cancel_subscription/2` to the test process.
  A refused immediate request must produce ZERO of them.

  The grace control is the other half. A guard that only proves "the route
  cancels nothing" is satisfied by a route that is broken outright, so the
  same file proves a plain `{password}` POST still reaches the gateway EXACTLY
  ONCE, with `at_period_end: true`.

  `async: false` because the gateway is swapped through application env, which
  is node-global (the precedent is `billing_trial_test.exs`, same reason).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defmodule RecordingGateway do
    @moduledoc false
    @behaviour BarkparkCloud.Billing.Gateway

    alias BarkparkCloud.Billing.StubGateway

    defp report(msg) do
      case Application.get_env(:barkpark_cloud, __MODULE__, [])[:report_to] do
        pid when is_pid(pid) -> send(pid, msg)
        _ -> :ok
      end
    end

    @impl true
    defdelegate create_customer(attrs), to: StubGateway

    @impl true
    defdelegate update_customer(customer_id, attrs), to: StubGateway

    @impl true
    defdelegate charge(customer_id, amount_cents, currency, meta), to: StubGateway

    @impl true
    defdelegate create_subscription(customer_id, plan), to: StubGateway

    @impl true
    defdelegate create_checkout_session(team_id, plan, opts), to: StubGateway

    @impl true
    defdelegate create_billing_portal_session(customer_id, opts), to: StubGateway

    @impl true
    defdelegate verify_webhook(payload, signature), to: StubGateway

    @impl true
    def cancel_subscription(subscription_id, opts) do
      report({:cancel_subscription, subscription_id, opts})
      StubGateway.cancel_subscription(subscription_id, opts)
    end
  end

  setup do
    prev = Application.get_env(:barkpark_cloud, Billing, [])
    Application.put_env(:barkpark_cloud, Billing, Keyword.put(prev, :gateway, RecordingGateway))
    Application.put_env(:barkpark_cloud, RecordingGateway, report_to: self())

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, Billing, prev)
      Application.delete_env(:barkpark_cloud, RecordingGateway)
    end)

    :ok
  end

  defp user_with_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  defp call(body, token) do
    :post
    |> conn("/v1/billing/cancel", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # The instrument's own control. If the recorder cannot see a call it DID
  # make, the zero-call assertion below proves nothing at all.
  test "the recorder sees a cancel_subscription call when one really happens" do
    {_user, team, _token} = user_with_team()
    {:ok, _sub} = Billing.subscribe(team, "supporter")

    {:ok, _} = Billing.request_cancel(team, true)

    assert_received {:cancel_subscription, _sid, _opts}
  end

  test "at_period_end:false from a verified owner with the correct password is refused 422 and reaches the gateway ZERO times" do
    {_user, team, token} = user_with_team()
    {:ok, _sub} = Billing.subscribe(team, "supporter")

    # Drain the subscribe-time gateway traffic so the count below is this
    # request's and nothing else's.
    flush_cancels()

    conn = call(%{password: @password, at_period_end: false}, token)

    assert conn.status == 422
    body = json_body(conn)
    assert body["error"] == "invalid"
    assert is_map(body["details"])
    assert [sentence] = body["details"]["at_period_end"]
    assert sentence =~ "immediate cancellation is not offered"

    assert flush_cancels() == [],
           "the route refused with 422 but the gateway was still told to cancel — the immediate " <>
             "arm is back and a status-only guard would not have seen it"

    # And nothing moved locally either: the subscription is untouched.
    assert %{status: "active", cancel_at_period_end: false} = Billing.live_subscription(team)
    assert Billing.entitled?(team)
  end

  test "the grace control: a plain {password} POST still cancels at period end, calling the gateway EXACTLY ONCE with at_period_end: true" do
    {_user, team, token} = user_with_team()
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    flush_cancels()

    conn = call(%{password: @password}, token)

    assert conn.status == 200
    assert json_body(conn)["cancel_at_period_end"] == true

    assert [{:cancel_subscription, _sid, opts}] = flush_cancels()
    assert Keyword.get(opts, :at_period_end) == true
    assert Billing.entitled?(team)
  end

  test "at_period_end:true is accepted (the refusal keys on `false`, not on the field's presence)" do
    {_user, team, token} = user_with_team()
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    flush_cancels()

    conn = call(%{password: @password, at_period_end: true}, token)

    assert conn.status == 200
    assert [{:cancel_subscription, _sid, _opts}] = flush_cancels()
  end

  defp flush_cancels(acc \\ []) do
    receive do
      {:cancel_subscription, _, _} = msg -> flush_cancels([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
