defmodule BarkparkCloud.Web.RouterNotificationsChatTest do
  @moduledoc """
  notifications-chat: drives the chat JSON routes via Plug.Test — PUT
  /v1/notifications/channels + /events, the chat branch of POST
  /v1/notifications/test, the save-time SSRF 422, admin-gating, and the
  credential no-leak in GET /v1/notifications/settings.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Web.Router
  alias BarkparkCloud.Workers.ChatNotificationWorker

  @opts Router.init([])
  @password "correct-horse-battery"

  defp owner_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {team, token}
  end

  defp member_token(team) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "m-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    {:ok, _} = Accounts.add_member(team, user, "member")
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token) do
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

  test "PUT channels seals creds and GET settings shows it configured, never leaked" do
    {_team, token} = owner_with_team()

    conn =
      call(
        :put,
        "/v1/notifications/channels",
        %{
          "type" => "discord",
          "enabled" => true,
          "credentials" => %{"url" => "https://discord.com/api/webhooks/1/topsecret"}
        },
        token
      )

    assert conn.status == 200
    refute conn.resp_body =~ "topsecret"

    conn = call(:get, "/v1/notifications/settings", nil, token)
    assert conn.status == 200
    channels = body(conn)["settings"]["channels"]
    assert channels == [%{"type" => "discord", "enabled" => true, "configured" => true}]
    refute conn.resp_body =~ "topsecret"
    refute conn.resp_body =~ "credentials_encrypted"
  end

  test "PUT channels rejects a private-resolving webhook URL at save (422)" do
    {_team, token} = owner_with_team()

    conn =
      call(
        :put,
        "/v1/notifications/channels",
        %{
          "type" => "webhook",
          "enabled" => true,
          "credentials" => %{"url" => "http://169.254.169.254/latest/meta-data"}
        },
        token
      )

    assert conn.status == 422
  end

  test "PUT events sets a route" do
    {_team, token} = owner_with_team()

    _ =
      call(
        :put,
        "/v1/notifications/channels",
        %{
          "type" => "slack",
          "enabled" => true,
          "credentials" => %{"url" => "https://hooks.slack.com/x"}
        },
        token
      )

    conn =
      call(
        :put,
        "/v1/notifications/events",
        %{
          "event" => "provision_succeeded",
          "channels" => ["slack"]
        },
        token
      )

    assert conn.status == 200
    assert body(conn)["settings"]["event_routes"]["provision_succeeded"] == ["slack"]
  end

  test "POST test with a channel fires the chat test (202) and enqueues a job" do
    {_team, token} = owner_with_team()

    _ =
      call(
        :put,
        "/v1/notifications/channels",
        %{
          "type" => "discord",
          "enabled" => true,
          "credentials" => %{"url" => "https://discord.com/x"}
        },
        token
      )

    conn = call(:post, "/v1/notifications/test", %{"channel" => "discord"}, token)
    assert conn.status == 202
    # cch-w32-s1: the response now carries WHAT IT QUEUED, not just that it was
    # accepted. `ok: true` still means "the request was accepted".
    assert body(conn) == %{"ok" => true, "queued" => 1}

    assert_enqueued(
      worker: ChatNotificationWorker,
      args: %{channel_type: "discord", event: "test"}
    )
  end

  # ── cch-w32-s1: a fan-out to nobody is not an accepted delivery ────────────
  #
  # This route pattern-matched `:ok = send_test_chat(...)` and rendered an
  # unconditional `202 {ok: true}`. `send_test_chat/2` returns `:ok` having
  # reached ZERO channels in three measured ways, so "the test was sent" was
  # reported to the console, to `bp` and to curl alike over a fan-out that
  # reached nobody. `queued` is the number of channels actually reached.
  test "POST test reports queued: 0 when the fan-out reaches nobody — three ways" do
    {_team, token} = owner_with_team()

    # (1) no channels at all
    conn = call(:post, "/v1/notifications/test", %{"target" => "chat"}, token)
    assert conn.status == 202
    assert body(conn) == %{"ok" => true, "queued" => 0}

    # (2) only a DISABLED channel
    _ =
      call(
        :put,
        "/v1/notifications/channels",
        %{
          "type" => "discord",
          "enabled" => false,
          "credentials" => %{"url" => "https://discord.com/x"}
        },
        token
      )

    conn = call(:post, "/v1/notifications/test", %{"target" => "chat"}, token)
    assert conn.status == 202
    assert body(conn)["queued"] == 0

    # (3) a channel that matches nothing enabled
    conn = call(:post, "/v1/notifications/test", %{"channel" => "telegram"}, token)
    assert conn.status == 202
    assert body(conn)["queued"] == 0

    refute_enqueued(worker: ChatNotificationWorker)
  end

  test "POST test still FIRES for a muted team, and the queued count says so" do
    {_team, token} = owner_with_team()

    _ =
      call(
        :put,
        "/v1/notifications/channels",
        %{
          "type" => "slack",
          "enabled" => true,
          "credentials" => %{"url" => "https://hooks.slack.com/x"}
        },
        token
      )

    _ = call(:put, "/v1/notifications/settings", %{"alerts_enabled" => false}, token)

    # A transport probe, not a policy probe — it fires, and the message it sends
    # carries the mute (pinned on the wire in chat_test.exs / render_test.exs).
    conn = call(:post, "/v1/notifications/test", %{"channel" => "slack"}, token)
    assert conn.status == 202
    assert body(conn) == %{"ok" => true, "queued" => 1}

    assert_enqueued(
      worker: ChatNotificationWorker,
      args: %{channel_type: "slack", event: "test", payload: %{"alerts_muted" => true}}
    )
  end

  test "GET settings publishes the always-send half of the chat vocabulary" do
    {_team, token} = owner_with_team()

    conn = call(:get, "/v1/notifications/settings", nil, token)
    assert conn.status == 200
    settings = body(conn)["settings"]

    # cch-w32-s1: without this, an SDK/CLI/agent reading the view sees
    # `chat_events` only and cannot learn that `trial_expiring` reaches chat at
    # all — it takes no route, so it is deliberately absent from `chat_events`.
    assert "trial_expiring" in settings["chat_always_send"]
    assert "test" in settings["chat_always_send"]
    refute "trial_expiring" in settings["chat_events"]
  end

  ## ── cch-w32-bl: the chat leg's rate limit IS the email leg's ──────────────
  ##
  ## This endpoint's `cond` reaches the `chat_test?` branch BEFORE `test_email`,
  ## so the chat half jumped past the only guard on the route: three rapid
  ## presses enqueued THREE ChatNotificationWorker jobs and stamped nothing. A
  ## webhook URL is caller-chosen, so that is an authenticated way to aim
  ## unbounded outbound POSTs from Barkpark's IP at a third party.

  defp enable_discord(token) do
    call(
      :put,
      "/v1/notifications/channels",
      %{
        "type" => "discord",
        "enabled" => true,
        "credentials" => %{"url" => "https://discord.com/x"}
      },
      token
    )
  end

  test "three rapid chat presses enqueue ONE job; 2nd and 3rd are refused readably" do
    {_team, token} = owner_with_team()
    _ = enable_discord(token)

    conn = call(:post, "/v1/notifications/test", %{"channel" => "discord"}, token)
    assert conn.status == 202
    assert body(conn) == %{"ok" => true, "queued" => 1}

    for press <- 2..3 do
      conn = call(:post, "/v1/notifications/test", %{"channel" => "discord"}, token)

      assert conn.status == 429, "press #{press} was not refused"
      # The SAME refusal the email leg renders — one endpoint, one vocabulary.
      assert body(conn)["error"] == "rate_limited"
      assert is_integer(body(conn)["retry_after"])
    end

    assert length(all_enqueued(worker: ChatNotificationWorker)) == 1
  end

  # THE ANTI-DRIFT GUARD (criterion 2). It reds if EITHER leg loses its limit,
  # because it asserts the two halves share ONE persisted per-team window: a
  # send on either leg refuses the other. A second, differently-shaped limiter
  # bolted onto the chat leg would pass the test above and RED here — which is
  # the point, since two limiters is how the halves drifted apart to begin with.
  test "ONE guard, not two: a send on either leg closes the window for the OTHER" do
    # (1) a CHAT send must refuse the EMAIL leg — reds if the chat leg stops
    #     stamping the shared window.
    {_team1, token1} = owner_with_team()
    _ = enable_discord(token1)

    conn = call(:post, "/v1/notifications/test", %{"channel" => "discord"}, token1)
    assert conn.status == 202

    conn = call(:post, "/v1/notifications/test", %{}, token1)
    assert conn.status == 429, "the chat send did not close the EMAIL leg's window"
    assert body(conn)["error"] == "rate_limited"

    # (2) an EMAIL send must refuse the CHAT leg — reds if the chat leg stops
    #     reading the shared window, or if the email leg stops writing it.
    {_team2, token2} = owner_with_team()
    _ = enable_discord(token2)

    conn = call(:post, "/v1/notifications/test", %{}, token2)
    assert conn.status == 200

    queued_before_refusal = length(all_enqueued(worker: ChatNotificationWorker))

    conn = call(:post, "/v1/notifications/test", %{"channel" => "discord"}, token2)
    assert conn.status == 429, "the email send did not close the CHAT leg's window"
    assert body(conn)["error"] == "rate_limited"

    # ...and the refused chat press queued NOTHING. Measured as a DELTA, not as
    # an empty queue: part (1) of this same test legitimately enqueued a job for
    # team1, so a global `== []` here asserts something the test itself made
    # false. What this pins is the only thing that matters — a 429 adds no job.
    assert length(all_enqueued(worker: ChatNotificationWorker)) == queued_before_refusal
  end

  # A fan-out that reached NOBODY sends no outbound POST, so it must not cost
  # the team its next real test. (Also keeps the three-presses-queued-0 test
  # above honest — it presses this route three times in one window.)
  test "a queued: 0 chat press does NOT burn the shared window" do
    {_team, token} = owner_with_team()

    conn = call(:post, "/v1/notifications/test", %{"target" => "chat"}, token)
    assert conn.status == 202
    assert body(conn)["queued"] == 0

    _ = enable_discord(token)
    conn = call(:post, "/v1/notifications/test", %{"channel" => "discord"}, token)
    assert conn.status == 202
    assert body(conn) == %{"ok" => true, "queued" => 1}
  end

  test "chat channel writes are admin-gated (a plain member is 403)" do
    {team, _owner_token} = owner_with_team()
    token = member_token(team)

    conn =
      call(:put, "/v1/notifications/channels", %{"type" => "discord", "enabled" => false}, token)

    assert conn.status == 403
  end
end
