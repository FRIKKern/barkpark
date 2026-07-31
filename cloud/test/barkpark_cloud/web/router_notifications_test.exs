defmodule BarkparkCloud.Web.RouterNotificationsTest do
  @moduledoc """
  Drives the notifications-email JSON routes directly via Plug.Test:
  GET/PUT /v1/notifications/settings and POST /v1/notifications/test — auth,
  masking, 422 validation, and the 429 rate limit.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Notifications.EmailSettings
  alias BarkparkCloud.Notifications.EventEmail
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # Insert a durable delivery row straight into notification_deliveries (the route
  # is pure read-only, so tests seed the table directly rather than via a send).
  defp insert_delivery(team, attrs) do
    Repo.insert!(
      struct(
        %Delivery{
          team_id: team.id,
          recipient: "ops@example.com",
          event: "provision_failed",
          channel: "email",
          kind: "alert",
          status: "sent",
          attempts: 1
        },
        attrs
      )
    )
  end

  # GET the delivery log with `query` appended, asserting a 200 — the filter
  # tests are about WHICH rows come back, never about the status code.
  defp filtered(token, query) do
    conn = call(:get, "/v1/notifications/deliveries?" <> query, nil, token)
    assert conn.status == 200
    body(conn)["deliveries"]
  end

  # A fresh user joined to `team` at `role`, plus a live session token.
  defp token_for(team, role) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  test "GET settings requires auth" do
    conn = call(:get, "/v1/notifications/settings")
    assert conn.status == 401
  end

  test "GET settings returns a masked view and auto-creates the row" do
    {_user, _team, token} = user_with_team()
    conn = call(:get, "/v1/notifications/settings", nil, token)
    assert conn.status == 200
    settings = body(conn)["settings"]
    assert settings["transport"] == "instance"
    # An unset secret is nil (not the ciphertext).
    assert settings["smtp_password"] == nil
    # A default-on failure toggle is present.
    assert settings["provision_failed"] == true
  end

  test "PUT settings stores secrets masked and never echoes plaintext" do
    {_user, _team, token} = user_with_team()

    conn =
      call(
        :put,
        "/v1/notifications/settings",
        %{
          "transport" => "smtp",
          "smtp_host" => "smtp.example.com",
          "smtp_password" => "s3cr3t",
          "smtp_port" => 587,
          "smtp_encryption" => "starttls"
        },
        token
      )

    assert conn.status == 200
    settings = body(conn)["settings"]
    assert settings["transport"] == "smtp"
    assert settings["smtp_password"] == "********"
    refute conn.resp_body =~ "s3cr3t"
  end

  test "PUT settings 422s on an invalid port" do
    {_user, _team, token} = user_with_team()

    conn =
      call(
        :put,
        "/v1/notifications/settings",
        %{"transport" => "smtp", "smtp_port" => 99_999},
        token
      )

    assert conn.status == 422
    assert body(conn)["error"] == "invalid"
    assert is_map(body(conn)["details"])
  end

  test "POST test sends once then 429s on the immediate retry" do
    {user, _team, token} = user_with_team()

    conn1 = call(:post, "/v1/notifications/test", %{"to" => user.email}, token)
    assert conn1.status == 200
    assert body(conn1)["ok"] == true

    conn2 = call(:post, "/v1/notifications/test", %{"to" => user.email}, token)
    assert conn2.status == 429
    assert body(conn2)["error"] == "rate_limited"
    assert is_integer(body(conn2)["retry_after"])
  end

  test "M1: PUT settings is admin-gated — a plain member is 403" do
    {_owner, team, _owner_token} = user_with_team()
    member_token = token_for(team, "member")

    conn =
      call(:put, "/v1/notifications/settings", %{"transport" => "instance"}, member_token)

    assert conn.status == 403
    assert body(conn)["error"] == "forbidden"
  end

  test "M1: POST test to a NON-member recipient is 403 (the mailer is not an open relay)" do
    {_owner, _team, owner_token} = user_with_team()

    conn =
      call(:post, "/v1/notifications/test", %{"to" => "attacker@evil.example"}, owner_token)

    assert conn.status == 403
    assert body(conn)["error"] == "recipient_not_member"
  end

  describe "GET /v1/notifications/deliveries" do
    test "requires auth (401 with no session)" do
      conn = call(:get, "/v1/notifications/deliveries")
      assert conn.status == 401
    end

    test "is admin-gated — a plain member is 403" do
      {_owner, team, _owner_token} = user_with_team()
      member_token = token_for(team, "member")

      conn = call(:get, "/v1/notifications/deliveries", nil, member_token)
      assert conn.status == 403
      assert body(conn)["error"] == "forbidden"
    end

    test "an admin with no deliveries gets an empty list (200)" do
      {_user, _team, token} = user_with_team()

      conn = call(:get, "/v1/notifications/deliveries", nil, token)
      assert conn.status == 200
      assert body(conn)["deliveries"] == []
    end

    test "returns the team's deliveries newest-first with the full field set" do
      {_user, team, token} = user_with_team()
      t0 = DateTime.utc_now()

      insert_delivery(team, %{
        recipient: "old@example.com",
        event: "provision_failed",
        channel: "email",
        kind: "alert",
        status: "sent",
        attempts: 1,
        inserted_at: DateTime.add(t0, -60, :second)
      })

      insert_delivery(team, %{
        recipient: "new@example.com",
        event: "health_flip",
        channel: "discord",
        kind: "transactional",
        status: "failed",
        attempts: 3,
        last_error: "timeout",
        http_status: 500,
        inserted_at: t0
      })

      conn = call(:get, "/v1/notifications/deliveries", nil, token)
      assert conn.status == 200
      [first, second] = body(conn)["deliveries"]

      # newest first
      assert first["recipient"] == "new@example.com"
      assert second["recipient"] == "old@example.com"

      # the full field set on the newest row (mirrors audit_json/1's shape)
      assert first["event"] == "health_flip"
      assert first["channel"] == "discord"
      assert first["kind"] == "transactional"
      assert first["status"] == "failed"
      assert first["attempts"] == 3
      assert first["last_error"] == "timeout"
      assert first["http_status"] == 500
      assert is_binary(first["id"])
      assert is_binary(first["inserted_at"])
    end

    test "?limit caps the page size" do
      {_user, team, token} = user_with_team()
      t0 = DateTime.utc_now()

      for i <- 1..3 do
        insert_delivery(team, %{
          recipient: "r#{i}@example.com",
          inserted_at: DateTime.add(t0, -i, :second)
        })
      end

      conn = call(:get, "/v1/notifications/deliveries?limit=2", nil, token)
      assert conn.status == 200
      assert length(body(conn)["deliveries"]) == 2
    end

    test "?limit is hard-capped at 200 — an absurd limit cannot pull the whole table" do
      {_user, team, token} = user_with_team()
      t0 = DateTime.utc_now()

      rows =
        for i <- 1..205 do
          %{
            id: Ecto.UUID.generate(),
            team_id: team.id,
            recipient: "r#{i}@example.com",
            event: "provision_failed",
            channel: "email",
            kind: "alert",
            status: "sent",
            attempts: 1,
            inserted_at: DateTime.add(t0, -i, :second),
            updated_at: t0
          }
        end

      Repo.insert_all(Delivery, rows)

      conn = call(:get, "/v1/notifications/deliveries?limit=100000", nil, token)
      assert conn.status == 200
      assert length(body(conn)["deliveries"]) == 200
    end

    test "?channel / ?status / ?event narrow the log, and compose" do
      {_user, team, token} = user_with_team()
      t0 = DateTime.utc_now()

      insert_delivery(team, %{
        channel: "email",
        status: "sent",
        event: "provision_failed",
        inserted_at: DateTime.add(t0, -1, :second)
      })

      insert_delivery(team, %{
        channel: "discord",
        status: "failed",
        event: "provision_failed",
        inserted_at: DateTime.add(t0, -2, :second)
      })

      insert_delivery(team, %{
        channel: "discord",
        status: "failed",
        event: "test",
        inserted_at: DateTime.add(t0, -3, :second)
      })

      assert [%{"channel" => "discord"}, %{"channel" => "discord"}] =
               filtered(token, "channel=discord")

      assert [%{"status" => "sent"}] = filtered(token, "status=sent")
      assert [%{"event" => "test"}] = filtered(token, "event=test")

      # Composed: the discord FAILURE for provision_failed, and nothing else.
      assert [%{"event" => "provision_failed", "channel" => "discord"}] =
               filtered(token, "channel=discord&status=failed&event=provision_failed")
    end

    test "a filter value outside the vocabulary matches nothing (never silently dropped)" do
      {_user, team, token} = user_with_team()
      insert_delivery(team, %{channel: "email", status: "sent"})

      # Dropping an unrecognised filter would show the caller MORE rows than
      # they asked for — the one failure mode a delivery log must not have.
      assert filtered(token, "status=bogus") == []
      assert filtered(token, "channel=carrier-pigeon") == []
      # An EMPTY value is absent, not "match the empty string".
      assert length(filtered(token, "status=&channel=&event=")) == 1
    end

    test "?before keysets to the next page, and filters survive the cursor" do
      {_user, team, token} = user_with_team()
      t0 = DateTime.utc_now()

      for i <- 1..3 do
        insert_delivery(team, %{
          recipient: "r#{i}@example.com",
          status: "failed",
          inserted_at: DateTime.add(t0, -i, :second)
        })
      end

      # A row that must never appear on a status-filtered page, however deep.
      insert_delivery(team, %{
        recipient: "sent@example.com",
        status: "sent",
        inserted_at: DateTime.add(t0, -10, :second)
      })

      page1 = filtered(token, "status=failed&limit=2")
      assert length(page1) == 2

      cursor = page1 |> List.last() |> Map.fetch!("inserted_at") |> URI.encode_www_form()
      page2 = filtered(token, "status=failed&limit=2&before=" <> cursor)

      assert [%{"recipient" => "r3@example.com"}] = page2
    end

    test "an admin only ever sees their OWN team's deliveries (no cross-team leak)" do
      {_user, _team, token} = user_with_team()
      {_other_user, other_team, _other_token} = user_with_team()
      insert_delivery(other_team, %{recipient: "leak@evil.example"})

      conn = call(:get, "/v1/notifications/deliveries", nil, token)
      assert conn.status == 200
      assert body(conn)["deliveries"] == []
    end
  end

  # wave 13 S2. `EventEmail.detail/1` is the SOLE reader of the event's free-text
  # detail in the email channel, and for provision_failed / deployment_failed /
  # agent_unreachable that string is the RAW failure reason. An email leaves our
  # boundary for good, so it is scrubbed on the way out.
  describe "EventEmail — the alert body is scrubbed before it leaves the boundary" do
    @email_secret "sk-live-9aB3xQ7zLmNpR4tV6wY2"
    @email_capture "ssh: remote said Authorization: Bearer sk-live-9aB3xQ7zLmNpR4tV6wY2"

    for event <- [:provision_failed, :deployment_failed, :agent_unreachable] do
      test "#{event}: the secret never reaches the inbox" do
        email =
          EventEmail.build(
            %EmailSettings{},
            unquote(event),
            %{name: "My Barkpark", detail: @email_capture},
            "owner@example.com"
          )

        refute email.text_body =~ @email_secret
        assert email.text_body =~ "Authorization: Bearer [redacted]"

        # The surrounding sentence is intact — a scrubbed alert is still an
        # actionable alert.
        assert email.text_body =~ "My Barkpark"
      end
    end

    test "a git SHA in the alert body survives — the commit is still readable" do
      email =
        EventEmail.build(
          %EmailSettings{},
          :deployment_failed,
          %{
            name: "My Barkpark",
            detail: "build of 0f28d541e9a1b2c3d4e5f60718293a4b5c6d7e8f failed"
          },
          "owner@example.com"
        )

      assert email.text_body =~ "build of 0f28d541e9a1b2c3d4e5f60718293a4b5c6d7e8f failed"
    end
  end
end
