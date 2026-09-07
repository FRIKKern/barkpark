defmodule BarkparkCloud.Web.RouterOperatorBillingResumeTest do
  @moduledoc """
  task-75decf22069ee083 — THE OPERATOR LIFT for a billing suspension, and the
  stranding it exists to end.

  ## The defect, restated as a sequence

  Entry into billing suspension is automatic and FLEET-WIDE: one
  `Registry.suspend_team_barkparks/2` bulk UPDATE disables every managed box a
  team owns. The exit was a webhook and nothing else — and one exit is MISSING.
  A Stripe-side reactivation of the SAME `canceled` subscription arrives as
  `customer.subscription.updated{status: "active"}`, whose object carries no
  `metadata.team_id`/`plan`, so `activate_from_metadata/1` refuses it;
  `subscription_by_customer/1` cannot rescue it either, because it filters
  `status in ["active", "past_due"]` and the row is `canceled`. The team pays,
  Stripe agrees, and the whole fleet stays dark.

  Before this suite, grepping `router.ex` for `resume_billing_suspended` /
  `resume_team_barkparks` / `unsuspend` returned NOTHING: no route at ANY tier
  (`require_team_admin`, `require_worker`, `require_platform_operator`) could
  lift it. The only remedy was a hand-written DB write or an `iex` session.

  ## What this suite refuses to let the fix become

  A resume that lifts any suspension on request is a BILLING BYPASS. So §2 pins
  the refusal as hard as §1 pins the lift: the decision is made against the
  PAYMENT GATEWAY's live answer, and a team the gateway does not report as
  `active`/`trialing` gets a 409 carrying that status and its remedy — never a
  silent 200 no-op. §3 pins the reason-scoping: an operator lift cannot clear a
  `"quota_exceeded"` flag the billing axis never set.

  `async: false` — both the operator allowlist (`:platform_admin_emails`) and
  the billing gateway are process-global Application config, so these tests
  must not run concurrently against a shared key (mirrors RouterOperatorTest).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Billing.{StubGateway, Subscription}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## ── Gateway doubles ────────────────────────────────────────────────────────
  #
  # The refusal arm needs the gateway to SAY "not paid", and `StubGateway` has
  # no state to hold that (its world is a paid world, by documented design). So
  # each answer gets its own tiny `Gateway` module, swapped in over the same
  # call-time `Billing.gateway/0` seam prod uses. Everything except the one
  # answer under test delegates to `StubGateway`, so nothing else about the
  # billing path changes shape between these tests and every other suite.

  defmodule PaidGateway do
    @moduledoc false
    @behaviour BarkparkCloud.Billing.Gateway
    alias BarkparkCloud.Billing.StubGateway

    @impl true
    def retrieve_subscription(id), do: {:ok, %{"id" => id, "status" => "active"}}

    @impl true
    def create_customer(a), do: StubGateway.create_customer(a)
    @impl true
    def update_customer(a, b), do: StubGateway.update_customer(a, b)
    @impl true
    def charge(a, b, c, d), do: StubGateway.charge(a, b, c, d)
    @impl true
    def create_subscription(a, b), do: StubGateway.create_subscription(a, b)
    @impl true
    def create_checkout_session(a, b, c), do: StubGateway.create_checkout_session(a, b, c)
    @impl true
    def create_billing_portal_session(a, b), do: StubGateway.create_billing_portal_session(a, b)
    @impl true
    def cancel_subscription(a, b), do: StubGateway.cancel_subscription(a, b)
    @impl true
    def verify_webhook(a, b), do: StubGateway.verify_webhook(a, b)
  end

  defmodule UnpaidGateway do
    @moduledoc false
    @behaviour BarkparkCloud.Billing.Gateway
    alias BarkparkCloud.Billing.StubGateway

    @impl true
    def retrieve_subscription(id), do: {:ok, %{"id" => id, "status" => "canceled"}}

    @impl true
    def create_customer(a), do: StubGateway.create_customer(a)
    @impl true
    def update_customer(a, b), do: StubGateway.update_customer(a, b)
    @impl true
    def charge(a, b, c, d), do: StubGateway.charge(a, b, c, d)
    @impl true
    def create_subscription(a, b), do: StubGateway.create_subscription(a, b)
    @impl true
    def create_checkout_session(a, b, c), do: StubGateway.create_checkout_session(a, b, c)
    @impl true
    def create_billing_portal_session(a, b), do: StubGateway.create_billing_portal_session(a, b)
    @impl true
    def cancel_subscription(a, b), do: StubGateway.cancel_subscription(a, b)
    @impl true
    def verify_webhook(a, b), do: StubGateway.verify_webhook(a, b)
  end

  defmodule DownGateway do
    @moduledoc false
    @behaviour BarkparkCloud.Billing.Gateway
    alias BarkparkCloud.Billing.StubGateway

    @impl true
    def retrieve_subscription(_id), do: {:error, {:stripe_http_error, 503, "cus_secret_echo"}}

    @impl true
    def create_customer(a), do: StubGateway.create_customer(a)
    @impl true
    def update_customer(a, b), do: StubGateway.update_customer(a, b)
    @impl true
    def charge(a, b, c, d), do: StubGateway.charge(a, b, c, d)
    @impl true
    def create_subscription(a, b), do: StubGateway.create_subscription(a, b)
    @impl true
    def create_checkout_session(a, b, c), do: StubGateway.create_checkout_session(a, b, c)
    @impl true
    def create_billing_portal_session(a, b), do: StubGateway.create_billing_portal_session(a, b)
    @impl true
    def cancel_subscription(a, b), do: StubGateway.cancel_subscription(a, b)
    @impl true
    def verify_webhook(a, b), do: StubGateway.verify_webhook(a, b)
  end

  setup do
    prior_ops = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    prior_billing = Application.get_env(:barkpark_cloud, Billing, [])

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, :platform_admin_emails, prior_ops)
      Application.put_env(:barkpark_cloud, Billing, prior_billing)
    end)

    :ok
  end

  ## ── Fixtures ───────────────────────────────────────────────────────────────

  defp set_gateway(mod) do
    prior = Application.get_env(:barkpark_cloud, Billing, [])
    Application.put_env(:barkpark_cloud, Billing, Keyword.put(prior, :gateway, mod))
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

  # A registered user whose email IS on the platform-operator allowlist.
  defp operator_fixture do
    user = user_fixture()

    {:ok, team} =
      Accounts.create_team(%{name: "Ops", slug: "ops-#{System.unique_integer([:positive])}"})

    {:ok, _} = Accounts.add_member(team, user, "owner")
    Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
    user
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp event(type, customer_id, extra \\ %{}) do
    Jason.encode!(%{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => type,
      "data" => %{"object" => Map.merge(%{"customer" => customer_id}, extra)}
    })
  end

  defp sig, do: StubGateway.test_signature()

  defp reload_bp(%Barkpark{id: id}), do: Repo.get!(Barkpark, id)
  defp reload_sub(%Subscription{id: id}), do: Repo.get!(Subscription, id)

  defp call(method, path, token) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # A team whose subscription Stripe has cancelled: the fleet is suspended
  # `"billing_lapsed"`, exactly as `cancel_subscription/1` leaves it.
  defp lapsed_team do
    team = team_fixture()
    {:ok, sub} = Billing.subscribe(team, "supporter")
    raw = event("customer.subscription.deleted", sub.gateway_customer_id)
    assert {:ok, %Subscription{status: "canceled"}} = Billing.handle_webhook(raw, sig())
    {team, sub}
  end

  ## ── 1. The stranding, and the lift ─────────────────────────────────────────

  test "a Stripe-side reactivation strands the fleet; the operator lift is what brings it back" do
    operator = operator_fixture()
    token = session_token(operator)

    team = team_fixture()
    {:ok, sub} = Billing.subscribe(team, "supporter")
    bp = barkpark_fixture(team)

    # (a) Stripe cancels — one bulk UPDATE takes the whole managed fleet down.
    assert {:ok, %Subscription{status: "canceled"}} =
             Billing.handle_webhook(
               event("customer.subscription.deleted", sub.gateway_customer_id),
               sig()
             )

    assert %Barkpark{suspended: true, suspended_reason: "billing_lapsed"} = reload_bp(bp)

    # (b) THE STRANDING. The customer pays again on Stripe's side; Stripe posts
    #     `customer.subscription.updated{status: "active"}` for the SAME
    #     subscription. That object carries no `metadata.team_id`/`plan`, and the
    #     `canceled` row is invisible to `subscription_by_customer/1`, so nothing
    #     activates. This is the row's headline claim, reproduced.
    reactivation =
      event("customer.subscription.updated", sub.gateway_customer_id, %{"status" => "active"})

    assert {:error, :missing_metadata} = Billing.handle_webhook(reactivation, sig())
    assert reload_sub(sub).status == "canceled"
    assert reload_bp(bp).suspended, "the reactivation left the box suspended — THE STRANDING"
    refute Billing.entitled?(team)

    # (c) THE LIFT. The gateway is asked, says the payer is current, and the
    #     ordinary recovery runs.
    set_gateway(PaidGateway)
    conn = call(:post, "/v1/operator/teams/#{team.id}/billing/resume", token)

    assert conn.status == 200
    body = json_body(conn)
    assert body["resumed"] == true
    assert body["gateway_status"] == "active"
    assert body["team_id"] == team.id
    assert body["reason_scope"] == ["billing_lapsed", "billing_past_due"]

    assert %Barkpark{suspended: false, suspended_reason: nil, suspended_at: nil} = reload_bp(bp)
    assert reload_sub(sub).status == "active"
    assert Billing.entitled?(team)
  end

  test "the lift also rescues a box a failed unsuspend stranded (no cron, no retry)" do
    # The second stranding on the same column: `unsuspend_one/2` logs and returns
    # nil on a changeset error and `reconcile_plan_limit/1` only re-runs on the
    # NEXT plan-change webhook (charter D657 declined a reconciler cron). The row
    # here is already `active` — the box is suspended and the payer is current —
    # and the lift is idempotent over that state.
    operator = operator_fixture()
    token = session_token(operator)

    team = team_fixture()
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    bp = barkpark_fixture(team)
    {:ok, _} = Registry.suspend_barkpark(bp, "billing_past_due")
    assert reload_bp(bp).suspended

    set_gateway(PaidGateway)
    conn = call(:post, "/v1/operator/teams/#{team.id}/billing/resume", token)

    assert conn.status == 200
    refute reload_bp(bp).suspended
  end

  ## ── 2. The refusal — the half that keeps this from being a billing bypass ──

  test "the lift REFUSES a genuinely unpaid team, carrying the gateway's status and a remedy" do
    operator = operator_fixture()
    token = session_token(operator)

    {team, sub} = lapsed_team()
    bp = barkpark_fixture(team)
    {:ok, _} = Registry.suspend_barkpark(bp, "billing_lapsed")

    set_gateway(UnpaidGateway)
    conn = call(:post, "/v1/operator/teams/#{team.id}/billing/resume", token)

    assert conn.status == 409
    body = json_body(conn)
    assert body["error"] == "subscription_unpaid"
    assert body["gateway_status"] == "canceled"

    assert body["remedy"] =~ "does not report this subscription as active",
           "the refusal must carry its remedy, not just a code: #{inspect(body)}"

    # A REFUSAL, not a silent no-op 200: nothing moved.
    assert reload_bp(bp).suspended
    assert reload_bp(bp).suspended_reason == "billing_lapsed"
    assert reload_sub(sub).status == "canceled"
    refute Billing.entitled?(team)
  end

  test "a team with no subscription at all is refused with its own remedy, not granted" do
    operator = operator_fixture()
    token = session_token(operator)

    team = team_fixture()
    bp = barkpark_fixture(team)
    {:ok, _} = Registry.suspend_barkpark(bp, "billing_lapsed")

    set_gateway(PaidGateway)
    conn = call(:post, "/v1/operator/teams/#{team.id}/billing/resume", token)

    assert conn.status == 409
    assert json_body(conn)["error"] == "no_subscription"
    assert json_body(conn)["remedy"] =~ "no gateway-side subscription"
    assert reload_bp(bp).suspended
  end

  test "a gateway that cannot answer is a 502 with a REDACTED reason — never a lift" do
    operator = operator_fixture()
    token = session_token(operator)

    {team, _sub} = lapsed_team()
    bp = barkpark_fixture(team)
    {:ok, _} = Registry.suspend_barkpark(bp, "billing_lapsed")

    set_gateway(DownGateway)
    conn = call(:post, "/v1/operator/teams/#{team.id}/billing/resume", token)

    assert conn.status == 502
    body = json_body(conn)
    assert body["error"] == "resume_failed"
    assert body["reason"] == "billing provider returned an error (HTTP 503)"

    refute conn.resp_body =~ "cus_secret_echo",
           "the raw Stripe body must never reach the client"

    assert reload_bp(bp).suspended
  end

  ## ── 3. Reason-scoping — the lift owns the billing axis and only that ───────

  test "a quota_exceeded box is untouched while the billing-suspended box comes back" do
    operator = operator_fixture()
    token = session_token(operator)

    team = team_fixture()
    {:ok, sub} = Billing.subscribe(team, "supporter")

    # Suspended by the QUOTA axis FIRST — `suspend_team_barkparks/2` guards on
    # `suspended == false`, so the billing cancel below cannot re-stamp it.
    quota_bp = barkpark_fixture(team)
    {:ok, _} = Registry.suspend_barkpark(quota_bp, Billing.quota_suspended_reason())

    billing_bp = barkpark_fixture(team)

    assert {:ok, %Subscription{status: "canceled"}} =
             Billing.handle_webhook(
               event("customer.subscription.deleted", sub.gateway_customer_id),
               sig()
             )

    assert reload_bp(billing_bp).suspended_reason == "billing_lapsed"
    assert reload_bp(quota_bp).suspended_reason == Billing.quota_suspended_reason()

    set_gateway(PaidGateway)
    conn = call(:post, "/v1/operator/teams/#{team.id}/billing/resume", token)
    assert conn.status == 200

    refute reload_bp(billing_bp).suspended

    assert %Barkpark{suspended: true, suspended_reason: "quota_exceeded"} = reload_bp(quota_bp),
           "the operator lift cleared a flag the billing axis never set — a free-capacity grant"
  end

  test "a self_hosted box is not revived either — the lift is mode-scoped too" do
    operator = operator_fixture()
    token = session_token(operator)

    team = team_fixture()
    {:ok, sub} = Billing.subscribe(team, "supporter")
    byo = barkpark_fixture(team)
    {:ok, byo} = byo |> Ecto.Changeset.change(mode: "self_hosted") |> Repo.update()
    {:ok, _} = Registry.suspend_barkpark(byo, "billing_lapsed")

    assert {:ok, %Subscription{status: "canceled"}} =
             Billing.handle_webhook(
               event("customer.subscription.deleted", sub.gateway_customer_id),
               sig()
             )

    set_gateway(PaidGateway)
    assert call(:post, "/v1/operator/teams/#{team.id}/billing/resume", token).status == 200

    assert reload_bp(byo).suspended,
           "a self_hosted row `suspend_team_barkparks/2` refuses to touch must not be revived"
  end

  ## ── 4. The door — fail-closed, and an unknown team is not a lift ───────────

  test "no token → 401; a non-operator session → 403; neither moves a suspension" do
    {team, _sub} = lapsed_team()
    bp = barkpark_fixture(team)
    {:ok, _} = Registry.suspend_barkpark(bp, "billing_lapsed")
    path = "/v1/operator/teams/#{team.id}/billing/resume"

    set_gateway(PaidGateway)

    anon = call(:post, path, nil)
    assert anon.status == 401
    assert json_body(anon)["error"] == "unauthorized"

    plain = session_token(user_fixture())
    forbidden = call(:post, path, plain)
    assert forbidden.status == 403
    assert json_body(forbidden)["error"] == "forbidden"

    assert reload_bp(bp).suspended, "a refused call must not have lifted anything"
  end

  test "an unknown team id is a 404, not a lift" do
    operator = operator_fixture()
    token = session_token(operator)

    set_gateway(PaidGateway)
    conn = call(:post, "/v1/operator/teams/#{Ecto.UUID.generate()}/billing/resume", token)

    assert conn.status == 404
    assert json_body(conn)["error"] == "not_found"
  end
end
