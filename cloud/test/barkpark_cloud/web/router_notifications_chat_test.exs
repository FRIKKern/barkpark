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

  test "chat channel writes are admin-gated (a plain member is 403)" do
    {team, _owner_token} = owner_with_team()
    token = member_token(team)

    conn =
      call(:put, "/v1/notifications/channels", %{"type" => "discord", "enabled" => false}, token)

    assert conn.status == 403
  end
end
