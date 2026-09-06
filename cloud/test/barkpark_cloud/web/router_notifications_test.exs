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
  defp token_for(team, role), do: team |> member_of(role) |> elem(1)

  # The same, but keeping the USER too — the self-scoped delivery reads assert on
  # the caller's own address, so the token alone is not enough.
  defp member_of(team, role) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, token}
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

    # dr-w26. `status: "sent"` is the mail transport's ACCEPTANCE — Barkpark has
    # no delivery receipt for email and `http_status` is NULL on every email row
    # — and reading the word as "arrived" is what made the 2026-08-08 outage
    # alerts look audited when their only evidence (the maillog) had been
    # destroyed by a deploy. The caveat therefore travels IN THE PAYLOAD, beside
    # the word, so no reader can pick up one without the other. Delete
    # `status_meaning` from `delivery_json/1` and this goes red.
    test "every delivery row carries status_meaning beside status, and it says sent is NOT delivered" do
      {_owner, team, token} = user_with_team()

      for {status, recipient} <- [
            {"sent", "a@example.com"},
            {"failed", "b@example.com"},
            {"pending", "c@example.com"},
            {"suppressed", "d@example.com"}
          ] do
        insert_delivery(team, %{status: status, recipient: recipient})
      end

      conn = call(:get, "/v1/notifications/deliveries", nil, token)
      assert conn.status == 200
      rows = body(conn)["deliveries"]
      assert length(rows) == 4

      # Every row, not just the interesting one: a payload that carries the
      # sentence for `sent` alone still lets `failed` be misread.
      for row <- rows do
        assert row["status_meaning"] == Delivery.status_meaning(row["status"]),
               "row #{row["status"]} carried #{inspect(row["status_meaning"])}"

        refute row["status_meaning"] in [nil, ""]
      end

      sent = Enum.find(rows, &(&1["status"] == "sent"))
      assert sent["status_meaning"] =~ "Accepted"
      assert sent["status_meaning"] =~ "NOT confirmed delivered"

      # THE NEGATIVE ARM. The sentence must not be a generic banner glued onto
      # every row — then it would say nothing. `failed` and `sent` must differ.
      failed = Enum.find(rows, &(&1["status"] == "failed"))
      refute failed["status_meaning"] == sent["status_meaning"]
    end

    # A word this version does not know must still get a sentence. A `nil`
    # caveat renders as a blank, and a blank caveat is indistinguishable from a
    # confident claim — which is the whole defect being fixed.
    test "status_meaning is total: an unknown status word still gets a sentence, never nil" do
      assert Delivery.status_meaning("not_a_status") == Delivery.status_meaning(nil)
      refute Delivery.status_meaning("not_a_status") in [nil, ""]

      for status <- Delivery.statuses() do
        assert Delivery.status_meaning(status) != Delivery.status_meaning(nil),
               "#{status} fell through to the unknown-word sentence"
      end
    end

    # cch-w31-s8. THE PIN THIS REPLACED asserted "a plain member is 403", and it
    # was TRUE — this route was the one surface built to answer "was I notified?"
    # and it 403'd the people it notifies. The pin is REWRITTEN, never deleted:
    # the member now gets 200, and the guard that can still LOSE is the recipient
    # fence. Drop `recipient:` from the router's opts and this test goes red by
    # showing a colleague's row, which is exactly the failure it exists to catch.
    test "a plain member gets 200 containing ONLY their own rows, and ZERO rows belonging to any other member" do
      {owner, team, _owner_token} = user_with_team()
      {member, member_token} = member_of(team, "member")
      {other, _other_token} = member_of(team, "member")

      t0 = DateTime.utc_now()

      for {email, offset} <- [{member.email, -1}, {other.email, -2}, {owner.email, -3}] do
        insert_delivery(team, %{
          recipient: email,
          inserted_at: DateTime.add(t0, offset, :second)
        })
      end

      conn = call(:get, "/v1/notifications/deliveries", nil, member_token)
      assert conn.status == 200

      recipients = Enum.map(body(conn)["deliveries"], & &1["recipient"])
      assert recipients == [member.email]
      refute other.email in recipients
      refute owner.email in recipients
    end

    # The hole `require_user/2` leaves and `gate_role/2` closes: a user holding no
    # membership ANYWHERE resolves to `current_team = nil`. 403 (they ARE
    # authenticated, they simply hold no grant) — never a query on a nil team_id.
    test "a user with no membership anywhere is 403, not a query on a nil team" do
      {:ok, stray} =
        Accounts.register_user(%{
          email: "stray-#{System.unique_integer([:positive])}@example.com",
          password: @password
        })

      {:ok, token} = Accounts.create_user_session_token(stray)

      conn = call(:get, "/v1/notifications/deliveries", nil, token)
      assert conn.status == 403
      assert body(conn)["error"] == "forbidden"
    end

    # REVIEW (wave 33): the self-scope fence rides an OPTIONAL filter, and an
    # optional filter's failure mode is to VANISH. `maybe_delivery_recipient/2`
    # only fences on a non-empty binary, so a member whose stored address is
    # blank used to fall through to the UNFENCED query and be handed the whole
    # team's log — the widening this slice exists to bound, failing open. The
    # router now refuses the read instead. This test writes the blank address
    # straight to the column (registration validates the field, which is exactly
    # why the hole was invisible) and asserts BOTH halves: the member is 403, and
    # the colleague's row is not in the response.
    test "a member whose address cannot be fenced on is 403 — the self-scope fence fails CLOSED" do
      {owner, team, _owner_token} = user_with_team()
      {member, member_token} = member_of(team, "member")

      insert_delivery(team, %{recipient: owner.email, event: "deployment_failed"})

      {1, _} =
        Repo.update_all(
          from(u in BarkparkCloud.Accounts.User, where: u.id == ^member.id),
          set: [email: "   "]
        )

      conn = call(:get, "/v1/notifications/deliveries", nil, member_token)
      assert conn.status == 403
      assert body(conn)["error"] == "forbidden"
      refute conn.resp_body =~ owner.email
    end

    # `notification_deliveries.recipient` is plain varchar, not citext, and
    # `record_delivery(Map.get(invite, :team_id), invite[:to], "invite", ...)`
    # persists the RAW invite address. A lower-cased equality self-filter returns
    # ZERO here — the silently short page this slice exists to kill.
    test "the self-filter is case-insensitive — a MiXeD-case recipient still comes back" do
      {_owner, team, _owner_token} = user_with_team()
      {member, member_token} = member_of(team, "member")

      shouty = member.email |> String.replace("@", "@Example-Host.") |> String.upcase()
      insert_delivery(team, %{recipient: String.upcase(member.email), event: "invite"})
      insert_delivery(team, %{recipient: shouty, event: "invite"})

      conn = call(:get, "/v1/notifications/deliveries", nil, member_token)
      assert conn.status == 200

      recipients = Enum.map(body(conn)["deliveries"], & &1["recipient"])
      # The row addressed to THIS member in shouting case is theirs; the
      # different-host shouty address is not.
      assert recipients == [String.upcase(member.email)]
    end

    # cch-w32-s2 made a withheld alert a real `suppressed` ROW, fanned out at one
    # row per member carrying that member's own address — the only grain at which
    # a self-scoped read can ever show a member their own suppression. Confirmed,
    # not assumed.
    test "a member CAN see a suppressed row that was fanned out to them" do
      {_owner, team, _owner_token} = user_with_team()
      {member, member_token} = member_of(team, "member")

      insert_delivery(team, %{
        recipient: member.email,
        status: "suppressed",
        event: "deployment_failed",
        attempts: 0
      })

      conn = call(:get, "/v1/notifications/deliveries", nil, member_token)
      assert conn.status == 200

      assert [%{"status" => "suppressed", "event" => "deployment_failed"}] =
               body(conn)["deliveries"]
    end

    # The structural bonus, pinned so nobody has to take the copy's word for it:
    # `log_chat_delivery/6` stores the channel TYPE as the recipient, so a
    # recipient-scoped read excludes every chat row (and every chat last_error)
    # by construction. This is WHY the member-facing copy must say it can answer
    # "was I emailed?" and never "did the team's Slack get it?".
    test "a member's self-scoped log structurally excludes chat rows" do
      {_owner, team, _owner_token} = user_with_team()
      {member, member_token} = member_of(team, "member")

      insert_delivery(team, %{recipient: member.email, channel: "email"})
      insert_delivery(team, %{recipient: "slack", channel: "slack", status: "failed"})
      insert_delivery(team, %{recipient: "discord", channel: "discord", status: "failed"})

      conn = call(:get, "/v1/notifications/deliveries", nil, member_token)
      assert conn.status == 200
      assert [%{"channel" => "email"}] = body(conn)["deliveries"]
    end

    test "an ADMIN still reads the whole team's log, every recipient" do
      {owner, team, owner_token} = user_with_team()
      {member, _member_token} = member_of(team, "member")

      t0 = DateTime.utc_now()

      insert_delivery(team, %{recipient: member.email, inserted_at: DateTime.add(t0, -1, :second)})

      insert_delivery(team, %{recipient: owner.email, inserted_at: DateTime.add(t0, -2, :second)})

      conn = call(:get, "/v1/notifications/deliveries", nil, owner_token)
      assert conn.status == 200

      assert Enum.map(body(conn)["deliveries"], & &1["recipient"]) == [
               member.email,
               owner.email
             ]
    end

    # The self-scope fence is a FENCE, not a filter the caller can widen: a
    # member cannot page past it, and it composes with every other filter.
    test "a member cannot escape the fence with filters or a deep keyset page" do
      {_owner, team, _owner_token} = user_with_team()
      {member, member_token} = member_of(team, "member")
      {other, _other_token} = member_of(team, "member")

      t0 = DateTime.utc_now()

      for i <- 1..3 do
        insert_delivery(team, %{
          recipient: other.email,
          status: "failed",
          inserted_at: DateTime.add(t0, -i, :second)
        })
      end

      insert_delivery(team, %{
        recipient: member.email,
        status: "failed",
        inserted_at: DateTime.add(t0, -10, :second)
      })

      assert [%{"recipient" => own}] = filtered(member_token, "status=failed")
      assert own == member.email

      cursor = DateTime.utc_now() |> DateTime.to_iso8601() |> URI.encode_www_form()
      assert [%{"recipient" => ^own}] = filtered(member_token, "limit=200&before=" <> cursor)
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
