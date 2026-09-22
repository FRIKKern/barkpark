defmodule BarkparkCloud.Web.RouterOperatorDigestSendTest do
  @moduledoc """
  gr-backlog-operator-digest-send — `POST /v1/operator/digest/send`, the route
  GR40 named when it cut the designed "Send one now" button because nothing
  outside the 06:00Z cron tick could call `deliver_fleet_digest/1`.

  THIS IS THE ONLY `/v1/operator/*` ROUTE THAT MAILS STRANGERS, so the arms here
  are not the read seam's 401/403/200 matrix repeated. Three of them are
  AUTHORITY and one is FAN-OUT, and each is paired with a control that would go
  green on a broken gate:

    * §1 401 (no session) / 403 (a real, registered non-operator session) / 403
      `allowlist: "unconfigured"` (the allowlist is EMPTY — the production state,
      where fail-closed means admit nobody, never admit everybody). Every refusal
      arm asserts the negative that matters: `refute_receive {:email, _}` and
      zero `digest_runs` rows. A 403 that still sent the mail is a spam cannon
      with a polite status line, and only the mailbox assertion can see it.
    * §2 the CONTROL — the same route, the same body, an operator session: 200,
      the mail actually lands, and the accounting row carries `trigger:
      "operator"` and the operator's own id. Without this arm every refusal above
      is satisfiable by a route that is simply broken for everyone.
    * §3 THE SCOPE REFUSAL. A bodyless POST, `{}`, `{"scope":"all"}`, a blank
      `team_id`, and scope+team_id together all 422 `scope_required` and mail
      NOBODY. The control is §2: the identical call WITH `{"scope":"fleet"}`
      mails the fleet, so the refusal is measuring the missing scope and not a
      dead route.
    * §4 the rate limit, §5 the receipt, §6 what the response may not carry.

  NO TEST HERE SENDS REAL MAIL. `config/test.exs` pins Swoosh's Test adapter, so
  every email lands in this process's mailbox; every address in this file is a
  synthetic `@example.com` fixture of a registered user this test created.

  `async: false` — the operator allowlist is process-global Application config
  and `DeviceAuth.RateLimiter` is a shared ETS table (mirrors
  RouterOperatorTest).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.DeviceAuth.RateLimiter
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.{Delivery, DigestRun}
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @path "/v1/operator/digest/send"

  setup do
    prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, :platform_admin_emails, prior)
      RateLimiter.reset()
    end)

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

  defp post_send(token, body) do
    conn =
      :post
      |> conn(@path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  # A bodyless POST — no content-type, no bytes. The shape a fat-fingered curl
  # or a half-built client actually produces, which is why it gets its own arm.
  defp post_bodyless(token) do
    conn = conn(:post, @path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp digest_runs, do: Repo.all(DigestRun)

  defp fleet_digest_deliveries do
    Delivery |> Repo.all() |> Enum.filter(&(&1.event == "fleet_digest"))
  end

  defp drain_emails(acc \\ []) do
    receive do
      {:email, email} -> drain_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  ## 1. AUTHORITY — three refusals, and none of them mails anybody

  test "no session → 401, and nothing is sent or recorded" do
    {_operator, team} = operator_fixture()
    barkpark_fixture(team)

    conn = post_send(nil, %{scope: "fleet"})

    assert conn.status == 401
    assert json_body(conn)["error"] == "unauthorized"

    refute_receive {:email, _}, 50
    assert digest_runs() == []
    assert fleet_digest_deliveries() == []
  end

  test "an authenticated NON-OPERATOR session → 403, and nothing is sent or recorded" do
    {_operator, op_team} = operator_fixture()
    barkpark_fixture(op_team)

    # A real, registered account with a real team and a real session — the
    # credential is VALID, it simply is not on the operator allowlist. That is
    # what makes this a 403 about authority and not a 401 about identity.
    {intruder, _team} = user_with_team()
    conn = post_send(session_token(intruder), %{scope: "fleet"})

    assert conn.status == 403
    assert json_body(conn)["error"] == "forbidden"
    assert json_body(conn)["required"] == "platform_operator"

    refute_receive {:email, _}, 50
    assert digest_runs() == []
    assert fleet_digest_deliveries() == []
  end

  test "an UNCONFIGURED allowlist fails CLOSED → 403, and nothing is sent or recorded" do
    {user, team} = user_with_team()
    barkpark_fixture(team)

    # The production state: PLATFORM_ADMIN_EMAILS unset. A gate that failed OPEN
    # here would make this route reachable by every signed-in account on the
    # platform — the spam cannon this arm exists to refuse.
    Application.put_env(:barkpark_cloud, :platform_admin_emails, [])
    assert Notifications.platform_admin_emails() == []

    conn = post_send(session_token(user), %{scope: "fleet"})

    assert conn.status == 403

    assert json_body(conn) == %{
             "error" => "forbidden",
             "required" => "platform_operator",
             "scope" => "platform",
             "allowlist" => "unconfigured"
           }

    refute_receive {:email, _}, 50
    assert digest_runs() == []
    assert fleet_digest_deliveries() == []
  end

  ## 2. THE CONTROL — the same call an operator makes actually sends

  test "an operator with an explicit fleet scope → 200, the mail lands, the run is recorded to HIM" do
    {operator, team} = operator_fixture()
    barkpark_fixture(team)

    conn = post_send(session_token(operator), %{scope: "fleet"})

    assert conn.status == 200
    body = json_body(conn)

    assert body["scope"] == "fleet"
    assert body["team_id"] == nil
    assert body["recipients"] == 1
    assert body["accepted"] == 1
    assert body["failed"] == 0
    assert body["instances"] == 1

    # The word is ACCEPTED, and the sentence beside it is the receipt's own —
    # which SAYS, in its own bytes, that acceptance is not delivery. The route
    # never manufactures this sentence; it reads `Delivery.status_meaning/1`, so
    # the console cannot claim more than the transport said.
    assert body["status_meaning"] == Delivery.status_meaning("sent")
    assert body["status_meaning"] =~ "NOT confirmed delivered"

    # It ARRIVED (Swoosh Test adapter — this process's mailbox, no network).
    assert [email] = drain_emails()
    assert [{_name, address}] = email.to
    assert address == operator.email

    # AND WHOSE HAND IT WAS, on the one sink a container recreate cannot delete.
    assert [run] = digest_runs()
    assert run.trigger == "operator"
    assert run.actor_user_id == operator.id
    assert run.event == "fleet_digest"
    assert run.recipients == 1
    assert run.sent == 1
  end

  test "the DAILY cron path still records `scheduled` and no actor (the trigger discriminates)" do
    # The non-vacuity control for the assertion above: if `trigger` were written
    # "operator" unconditionally, or `actor_user_id` came from somewhere other
    # than the route, this arm would go red. It is the same function, called the
    # way `DailyDigestWorker` calls it.
    {_operator, team} = operator_fixture()
    bp = barkpark_fixture(team)

    assert {:ok, %{sent: 1}} = Notifications.deliver_fleet_digest([bp])

    assert [run] = digest_runs()
    assert run.trigger == "scheduled"
    assert run.actor_user_id == nil
  end

  ## 3. NO FAN-OUT BY DEFAULT — the scope is required, and a refusal mails nobody

  test "a bodyless POST from an OPERATOR → 422 scope_required, and mails nobody" do
    {operator, team} = operator_fixture()
    barkpark_fixture(team)

    conn = post_bodyless(session_token(operator))

    assert conn.status == 422
    body = json_body(conn)
    assert body["error"] == "scope_required"
    assert body["accepts"] == ["scope", "team_id"]
    assert body["remedy"] =~ "no default"

    refute_receive {:email, _}, 50
    assert digest_runs() == []
    assert fleet_digest_deliveries() == []
  end

  test "every malformed scope refuses, and not one of them falls back to the whole fleet" do
    {operator, team} = operator_fixture()
    barkpark_fixture(team)
    token = session_token(operator)

    malformed = [
      %{},
      %{scope: "all"},
      %{scope: "everybody"},
      %{scope: nil},
      %{team_id: ""},
      %{team_id: 12_345},
      # BOTH keys: the caller said two different things, and guessing which they
      # meant is exactly the fan-out this refusal exists to prevent.
      %{scope: "fleet", team_id: team.id}
    ]

    for body <- malformed do
      RateLimiter.reset()
      conn = post_send(token, body)

      assert conn.status == 422, "#{inspect(body)} must REFUSE, never default to everybody"
      assert json_body(conn)["error"] == "scope_required"
    end

    refute_receive {:email, _}, 50
    assert digest_runs() == []
    assert fleet_digest_deliveries() == []
  end

  test "a team scope mails THAT team and no other, and names the team on the wire" do
    {operator, op_team} = operator_fixture()
    barkpark_fixture(op_team)

    {other, other_team} = user_with_team()
    barkpark_fixture(other_team)

    conn = post_send(session_token(operator), %{team_id: other_team.id})

    assert conn.status == 200
    body = json_body(conn)
    assert body["scope"] == "team"
    assert body["team_id"] == other_team.id
    assert body["instances"] == 1
    assert body["recipients"] == 1
    assert body["accepted"] == 1

    assert [email] = drain_emails()
    assert [{_name, address}] = email.to
    assert address == other.email
    refute address == operator.email
  end

  test "an unknown team_id → 404, and mails nobody" do
    {operator, team} = operator_fixture()
    barkpark_fixture(team)

    conn = post_send(session_token(operator), %{team_id: Ecto.UUID.generate()})

    assert conn.status == 404
    assert json_body(conn)["error"] == "not_found"

    refute_receive {:email, _}, 50
    assert digest_runs() == []
  end

  test "a scope whose teams have no members is a COUNTED ZERO, not a fake success" do
    {operator, _team} = operator_fixture()

    memberless =
      Accounts.create_team(%{
        name: "Memberless",
        slug: "memberless-#{System.unique_integer([:positive])}"
      })

    {:ok, memberless} = memberless
    barkpark_fixture(memberless)

    conn = post_send(session_token(operator), %{team_id: memberless.id})

    assert conn.status == 200
    body = json_body(conn)
    assert body["recipients"] == 0
    assert body["accepted"] == 0
    assert body["reason"] == "no_team_recipients"
    assert body["status_meaning"] =~ "Nothing was mailed"

    refute_receive {:email, _}, 50

    # The loss is COUNTED — the zero-recipient arm still writes its run row.
    assert [run] = digest_runs()
    assert run.recipients == 0
    assert run.trigger == "operator"
    assert run.actor_user_id == operator.id
  end

  ## 4. THE RATE LIMIT — 2/60s per operator

  test "the third send inside one window → 429, and the refused hit mails nobody" do
    {operator, team} = operator_fixture()
    barkpark_fixture(team)
    token = session_token(operator)

    assert post_send(token, %{scope: "fleet"}).status == 200
    assert post_send(token, %{scope: "fleet"}).status == 200

    before = length(drain_emails())
    assert before == 2, "the control: the two admitted sends really mailed"

    third = post_send(token, %{scope: "fleet"})
    assert third.status == 429
    assert json_body(third)["error"] == "rate_limited"

    refute_receive {:email, _}, 50
    assert length(digest_runs()) == 2, "a rate-limited call writes no run row"
  end

  test "the limiter is keyed PER OPERATOR — one operator's budget cannot starve another's" do
    {op_a, team} = operator_fixture()
    op_b = user_fixture()
    Application.put_env(:barkpark_cloud, :platform_admin_emails, [op_a.email, op_b.email])
    barkpark_fixture(team)

    token_a = session_token(op_a)
    assert post_send(token_a, %{scope: "fleet"}).status == 200
    assert post_send(token_a, %{scope: "fleet"}).status == 200
    assert post_send(token_a, %{scope: "fleet"}).status == 429

    # B's first call, in the same window, is unaffected.
    assert post_send(session_token(op_b), %{scope: "fleet"}).status == 200
  end

  ## 5. THE RECEIPT — a manual send is as provable as the cron send

  test "a manual send writes the SAME content-bearing receipt the cron send writes" do
    {operator, team} = operator_fixture()
    barkpark_fixture(team)

    assert post_send(session_token(operator), %{scope: "fleet"}).status == 200

    assert [row] = fleet_digest_deliveries()
    assert row.status == "sent"
    assert row.team_id == team.id
    assert row.recipient == operator.email

    # dr-w34 / dr-w29 — the three fields written from the email captured AT THE
    # TRANSPORT SEAM. A send that recorded none of these would be a send nobody
    # could prove said anything.
    assert is_binary(row.content_sha256)
    assert String.length(row.content_sha256) == 64
    assert is_binary(row.content_subject)
    assert row.content_counts != nil
  end

  ## 6. WHAT THE RESPONSE MAY NOT CARRY

  test "the 200 returns COUNTS and never a recipient address" do
    {operator, team} = operator_fixture()
    barkpark_fixture(team)

    {_other, other_team} = user_with_team()
    barkpark_fixture(other_team)

    conn = post_send(session_token(operator), %{scope: "fleet"})
    assert conn.status == 200

    # The response is cross-team by construction, so an address in it would be
    # the disclosure the digest's own per-team partitioning exists to prevent.
    refute conn.resp_body =~ "@example.com"
    refute conn.resp_body =~ operator.email

    body = json_body(conn)
    assert body["recipients"] == 2
    refute Map.has_key?(body, "recipient")
    refute Map.has_key?(body, "recipients_list")
  end
end
