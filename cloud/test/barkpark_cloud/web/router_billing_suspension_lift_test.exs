defmodule BarkparkCloud.Web.RouterBillingSuspensionLiftTest do
  @moduledoc """
  task-75decf22069ee083 — `POST /v1/operator/teams/:team_id/billing-suspension/lift`,
  the FIRST route at any auth level that can lift a billing suspension.

  ## The tier, and why it is a door and not a hole

  `Auth.require_platform_operator` — the same guard as the
  `/v1/operator/autoupdate*` trio, and the same
  `Notifications.platform_admin_emails/0` allowlist that feeds `/v1/me`'s
  `platform_operator` boolean. This is a HUMAN support action on one named
  customer's behalf, which is exactly the principal isu-backlog-operator-principal
  assigned to the operator rather than to the faceless shared `WORKER_TOKEN`.

  So this suite proves the negative half too: the worker secret is refused here
  (§1c), a team owner is refused on their OWN team (§1b), and no refused call
  moves a single `suspended` flag. Without that, "an operator can lift a billing
  suspension" is compatible with "and so can the customer".

  `async: false` — the operator allowlist is process-global Application config,
  exactly as `RouterOperatorTest` documents.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # config/test.exs pins this as `:worker_token`. Using the REAL configured
  # secret is what makes §1c mean something — a made-up string would 401 for
  # being wrong and would prove nothing about the principal boundary.
  @worker_token "worker-token-test-fixed"

  setup do
    prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prior) end)
    :ok
  end

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team(role \\ "owner") do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  defp operator_fixture do
    {user, team} = user_with_team()
    Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
    {user, team}
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp path(team), do: "/v1/operator/teams/#{team.id}/billing-suspension/lift"

  defp call(path, token) do
    conn = conn(:post, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)
  defp reload_bp(%Barkpark{id: id}), do: Repo.get!(Barkpark, id)

  # A team in good standing whose managed fleet is billing-suspended anyway —
  # the stranded shape the route exists to rescue.
  defp subscribed_stranded_team do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, %Subscription{status: "active"}} = Billing.subscribe(team, "supporter")
    bp = barkpark_fixture(team)
    {:ok, 1} = Registry.suspend_team_barkparks(team, "billing_lapsed")
    assert reload_bp(bp).suspended
    {team, bp}
  end

  ## ── 1. The auth matrix — fail-closed, in both directions ──

  test "1a. no credential → 401, and nothing moves" do
    {team, bp} = subscribed_stranded_team()

    conn = call(path(team), nil)
    assert conn.status == 401
    assert json_body(conn)["error"] == "unauthorized"
    assert reload_bp(bp).suspended, "a refused call must not lift anything"
  end

  test "1b. the team's OWN owner is refused (403) — the verdict is not the customer's" do
    {team, bp} = subscribed_stranded_team()
    owner = user_fixture()
    {:ok, _} = Accounts.add_member(team, owner, "owner")

    conn = call(path(team), session_token(owner))
    assert conn.status == 403
    body = json_body(conn)
    assert body["error"] == "forbidden"
    assert body["required"] == "platform_operator"
    assert reload_bp(bp).suspended
  end

  test "1c. the WORKER token is refused (401) — this is the operator's door, not the machine's" do
    {team, bp} = subscribed_stranded_team()

    conn = call(path(team), @worker_token)
    assert conn.status == 401
    assert reload_bp(bp).suspended

    # Non-vacuity: that same constant IS a working worker credential on a route
    # that is actually the worker's, so the 401 above is a boundary and not a
    # stale secret.
    admin = conn(:get, "/v1/admin/autoupdate") |> put_req_header("authorization", "Bearer #{@worker_token}")
    assert Router.call(admin, @opts).status == 200
  end

  ## ── 2. The lift itself ──

  test "2a. an operator lifts a stranded fleet → 200 with the count" do
    {operator, _} = operator_fixture()
    {team, bp} = subscribed_stranded_team()

    conn = call(path(team), session_token(operator))
    assert conn.status == 200
    body = json_body(conn)
    assert body["ok"] == true
    assert body["team_id"] == team.id
    assert body["lifted"] == 1
    assert body["reasons_lifted"] == ["billing_lapsed", "billing_past_due"]

    assert %Barkpark{suspended: false, suspended_reason: nil} = reload_bp(bp)
  end

  test "2b. REASON-SCOPED over HTTP: a quota_exceeded box survives the lift" do
    {operator, _} = operator_fixture()
    {team, billing_box} = subscribed_stranded_team()
    quota_box = barkpark_fixture(team)
    {:ok, _} = Registry.suspend_barkpark(quota_box, Billing.quota_suspended_reason())

    conn = call(path(team), session_token(operator))
    assert conn.status == 200
    assert json_body(conn)["lifted"] == 1

    refute reload_bp(billing_box).suspended

    assert %Barkpark{suspended: true, suspended_reason: "quota_exceeded"} = reload_bp(quota_box),
           "a billing lift over HTTP must not clear a flag the billing axis never set"
  end

  ## ── 3. The honest refusal ──

  test "3a. a genuinely unpaid team → 409 not_entitled carrying the remedy, NOT a 200 no-op" do
    {operator, _} = operator_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    bp = barkpark_fixture(team)
    {:ok, 1} = Registry.suspend_team_barkparks(team, "billing_lapsed")

    conn = call(path(team), session_token(operator))

    assert conn.status == 409, "a silent 200 over an unpaid team is the failure mode this route exists to avoid"
    body = json_body(conn)
    assert body["error"] == "not_entitled"
    assert body["team_id"] == team.id
    assert body["detail"] =~ "Remedy:"

    assert reload_bp(bp).suspended, "the refusal must be a refusal, not a lift with a scary message"
  end

  ## ── 4. Unknown team ──

  test "4a. an unknown or malformed team id → 404 (never a raise)" do
    {operator, _} = operator_fixture()
    token = session_token(operator)

    for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      conn = call("/v1/operator/teams/#{id}/billing-suspension/lift", token)
      assert conn.status == 404, "#{id} should 404"
      assert json_body(conn)["error"] == "not_found"
    end
  end
end
