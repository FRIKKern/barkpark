defmodule BarkparkCloud.Notifications.ChatTest do
  @moduledoc """
  notifications-chat: the CHAT half folded into the merged Notifications context —
  channel sealing, the SAVE-TIME SSRF guard, `channels_for_event/2` selection, the
  redacted view, and the fan-out that rides main's `dispatch_event/3` and enqueues
  one Oban job per routed channel.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.EmailSettings
  alias BarkparkCloud.Notifications.FakeHttpClient
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Workers.ChatNotificationWorker

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # cch-w32-bl: BOTH legs of the test endpoint now spend one per-team stamp, so
  # any test that presses twice inside the 10s window must age it out on
  # purpose. Same manoeuvre `notifications_test.exs` already uses for the email
  # leg — the point is that the second press is DELIBERATE, not accidental.
  defp age_test_stamp(team) do
    old = DateTime.add(DateTime.utc_now(), -11, :second) |> DateTime.truncate(:microsecond)

    team
    |> Notifications.get_or_create_settings()
    |> EmailSettings.changeset(%{last_test_sent_at: old})
    |> Repo.update!()
  end

  defp team_with_member do
    team = team_fixture()

    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _} = Accounts.add_member(team, user, "owner")
    team
  end

  describe "put_channel/4 sealing" do
    test "seals plaintext credentials — the ciphertext is never the plaintext" do
      team = team_fixture()
      creds = %{"url" => "https://discord.com/api/webhooks/1/abc"}

      assert {:ok, settings} = Notifications.put_channel(team, "discord", true, creds)
      [chan] = settings.channels
      assert chan.type == "discord"
      assert chan.enabled

      # Stored value is ciphertext, not the plaintext URL.
      refute chan.credentials_encrypted =~ "discord.com"
      assert {:ok, json} = Vault.decrypt(chan.credentials_encrypted)
      assert Jason.decode!(json) == creds
    end

    test "a toggle (creds: nil) keeps the previously-sealed credentials" do
      team = team_fixture()
      creds = %{"url" => "https://discord.com/api/webhooks/1/abc"}
      {:ok, s1} = Notifications.put_channel(team, "discord", true, creds)
      [c1] = s1.channels

      {:ok, s2} = Notifications.put_channel(team, "discord", false, nil)
      [c2] = s2.channels
      refute c2.enabled
      assert c2.credentials_encrypted == c1.credentials_encrypted
    end

    test "an enabled channel with no sealed credentials is rejected" do
      team = team_fixture()
      assert {:error, changeset} = Notifications.put_channel(team, "slack", true, nil)
      refute changeset.valid?
    end
  end

  describe "put_channel/4 SAVE-TIME SSRF guard (the fixed hole)" do
    test "a webhook URL that resolves to a private/metadata address is REJECTED at save" do
      team = team_fixture()

      for url <- [
            "http://169.254.169.254/latest/meta-data",
            "http://127.0.0.1/hook",
            "http://10.0.0.5/hook",
            "http://localhost/hook",
            "http://[::1]/hook"
          ] do
        assert {:error, changeset} =
                 Notifications.put_channel(team, "webhook", true, %{"url" => url}),
               "expected #{url} rejected at save time"

        refute changeset.valid?
        # And nothing was persisted for the blocked URL.
        assert Notifications.get_or_create_settings(team).channels == []
      end
    end

    test "a public webhook URL is accepted" do
      team = team_fixture()

      assert {:ok, settings} =
               Notifications.put_channel(team, "webhook", true, %{"url" => "https://1.1.1.1/hook"})

      assert [%{type: "webhook"}] = settings.channels
    end
  end

  describe "channels_for_event/2 selection" do
    setup do
      team = team_fixture()

      {:ok, _} =
        Notifications.put_channel(team, "discord", true, %{"url" => "https://discord.com/x"})

      {:ok, _} =
        Notifications.put_channel(team, "slack", false, %{"url" => "https://hooks.slack.com/x"})

      %{team: team}
    end

    test "a default-on failure event fans to every ENABLED channel", %{team: team} do
      s = Notifications.get_or_create_settings(team)
      selected = Notifications.channels_for_event(s, "provision_failed")
      assert Enum.map(selected, & &1.type) == ["discord"]
    end

    test "a default-off success event fans to nothing without an explicit route", %{team: team} do
      s = Notifications.get_or_create_settings(team)
      assert Notifications.channels_for_event(s, "provision_succeeded") == []
    end

    test "an explicit route selects exactly the routed enabled channels", %{team: team} do
      {:ok, _} = Notifications.set_event_route(team, "provision_succeeded", ["discord"])
      s = Notifications.get_or_create_settings(team)

      assert Enum.map(Notifications.channels_for_event(s, "provision_succeeded"), & &1.type) ==
               ["discord"]
    end

    test "the always-send test event bypasses routing and fans to every enabled channel", %{
      team: team
    } do
      s = Notifications.get_or_create_settings(team)
      assert Enum.map(Notifications.channels_for_event(s, "test"), & &1.type) == ["discord"]
    end

    test "a disabled channel is never selected, even when routed", %{team: team} do
      {:ok, _} = Notifications.set_event_route(team, "provision_failed", ["slack"])
      s = Notifications.get_or_create_settings(team)
      # slack is routed but disabled → nothing.
      assert Notifications.channels_for_event(s, "provision_failed") == []
    end
  end

  describe "settings_view/1 credential no-leak" do
    test "the view reports configured/enabled but NEVER the ciphertext" do
      team = team_fixture()
      creds = %{"url" => "https://discord.com/api/webhooks/1/secret"}
      {:ok, _} = Notifications.put_channel(team, "discord", true, creds)

      view = Notifications.settings_view(Notifications.get_or_create_settings(team))
      [chan] = view.channels
      assert chan == %{type: "discord", enabled: true, configured: true}
      refute Map.has_key?(chan, :credentials_encrypted)

      # No ciphertext / plaintext anywhere in the serialized view.
      serialized = Jason.encode!(view)
      refute serialized =~ "secret"
      refute serialized =~ "credentials_encrypted"
    end
  end

  describe "dispatch_event/3 chat fan-out on a REAL event" do
    test "a routed failure event enqueues one Oban job per routed chat channel" do
      team = team_with_member()

      {:ok, _} =
        Notifications.put_channel(team, "discord", true, %{"url" => "https://discord.com/x"})

      # provision_failed is default-on → discord is selected.
      :ok = Notifications.dispatch_event(team, :provision_failed, %{name: "acme"})

      assert_enqueued(
        worker: ChatNotificationWorker,
        args: %{channel_type: "discord", event: "provision_failed"}
      )
    end

    test "no chat job is enqueued for a success event with no route" do
      team = team_with_member()

      {:ok, _} =
        Notifications.put_channel(team, "discord", true, %{"url" => "https://discord.com/x"})

      :ok = Notifications.dispatch_event(team, :provision_succeeded, %{name: "acme"})

      refute_enqueued(worker: ChatNotificationWorker)
    end

    test "the master alerts_enabled switch mutes chat fan-out too" do
      team = team_with_member()

      {:ok, _} =
        Notifications.put_channel(team, "discord", true, %{"url" => "https://discord.com/x"})

      {:ok, _} = Notifications.update_settings(team, %{"alerts_enabled" => false})

      :ok = Notifications.dispatch_event(team, :provision_failed, %{name: "acme"})

      refute_enqueued(worker: ChatNotificationWorker)
    end

    # cch-w32-s1 (charter D364): the SIBLING of the assertion above, not a
    # rewrite of it. That one pins the DISPATCH path; this one pins the TEST
    # path, which deliberately does not go through `enqueue_chat/3` at all. Both
    # facts are true at once and neither implies the other: a muted team gets no
    # alerts and still gets its test, because the test is a transport probe.
    test "the test button still fires for a muted team — it probes transport, not policy" do
      team = team_with_member()

      {:ok, _} =
        Notifications.put_channel(team, "slack", true, %{"url" => "https://hooks.slack.com/x"})

      {:ok, _} = Notifications.update_settings(team, %{"alerts_enabled" => false})

      assert {:ok, 1} = Notifications.send_test_chat(team)

      assert_enqueued(
        worker: ChatNotificationWorker,
        args: %{channel_type: "slack", event: "test"}
      )
    end
  end

  # ── cch-w32-s1: the trial teardown reaches a Slack-only team ────────────────
  #
  # `TrialExpiryWorker` has dispatched `:trial_expiring` hourly since dwb-13 and
  # the EMAIL arm worked, but `channels_for_event/2` selected ZERO chat channels
  # for it: a team that runs on Slack was never told its trial ends and its
  # instance is torn down. The routing lives in `@chat_always_send` ALONE
  # (charter D359) — the three tests here are what that decision means.
  describe "trial_expiring reaches chat (charter D359)" do
    test "a Slack-only team on a FRESH account is told its trial ends" do
      team = team_with_member()

      {:ok, _} =
        Notifications.put_channel(team, "slack", true, %{"url" => "https://hooks.slack.com/x"})

      # No route written, no matrix touched, nothing default-on: a fresh account.
      :ok = Notifications.dispatch_event(team, :trial_expiring, %{days: 3, name: "acme"})

      assert_enqueued(
        worker: ChatNotificationWorker,
        args: %{channel_type: "slack", event: "trial_expiring"}
      )

      assert [%{args: %{"payload" => %{"days" => 3}}}] =
               all_enqueued(worker: ChatNotificationWorker)
    end

    test "it still honours the master switch — a muted team gets nothing" do
      team = team_with_member()

      {:ok, _} =
        Notifications.put_channel(team, "slack", true, %{"url" => "https://hooks.slack.com/x"})

      {:ok, _} = Notifications.update_settings(team, %{"alerts_enabled" => false})

      :ok = Notifications.dispatch_event(team, :trial_expiring, %{days: 1, name: "acme"})

      refute_enqueued(worker: ChatNotificationWorker)
    end

    test "and it REFUSES a per-event opt-out — the route write is rejected, delivery continues" do
      team = team_with_member()

      {:ok, _} =
        Notifications.put_channel(team, "slack", true, %{"url" => "https://hooks.slack.com/x"})

      # This is the property that chose `@chat_always_send` over
      # `@chat_default_on`: an event routed through the matrix would accept an
      # empty channel list as a per-event MUTE with no checkbox behind it — the
      # column charter D342(d) forbids. Here the write is refused outright…
      assert {:error, %Ecto.Changeset{}} =
               Notifications.set_event_route(team, "trial_expiring", [])

      # …and the event is delivered anyway, because the route was never consulted.
      :ok = Notifications.dispatch_event(team, :trial_expiring, %{days: 3, name: "acme"})

      assert_enqueued(
        worker: ChatNotificationWorker,
        args: %{channel_type: "slack", event: "trial_expiring"}
      )
    end
  end

  # ── cch-w32-s1: the test button answers honestly ───────────────────────────
  describe "send_test_chat/2 reports what it actually reached" do
    test "three ways to reach ZERO channels, all of them visible" do
      # (1) no channels at all
      team = team_with_member()
      assert {:ok, 0} = Notifications.send_test_chat(team)

      # (2) only a DISABLED channel
      {:ok, _} =
        Notifications.put_channel(team, "discord", false, %{"url" => "https://discord.com/x"})

      assert {:ok, 0} = Notifications.send_test_chat(team)

      # (3) a channel_type filter that matches nothing
      {:ok, _} =
        Notifications.put_channel(team, "slack", true, %{"url" => "https://hooks.slack.com/x"})

      assert {:ok, 0} = Notifications.send_test_chat(team, "telegram")

      refute_enqueued(worker: ChatNotificationWorker)

      # …and the reachable case is the same function returning a real count.
      assert {:ok, 1} = Notifications.send_test_chat(team, "slack")
    end

    test "the muted flag travels IN THE PAYLOAD, so the message itself can disclose it" do
      team = team_with_member()

      {:ok, _} =
        Notifications.put_channel(team, "slack", true, %{"url" => "https://hooks.slack.com/x"})

      assert {:ok, 1} = Notifications.send_test_chat(team)
      assert [%{args: %{"payload" => %{"alerts_muted" => false}}}] = all_enqueued()

      {:ok, _} = Notifications.update_settings(team, %{"alerts_enabled" => false})
      # cch-w32-bl: the first press above burned the shared per-team window.
      _ = age_test_stamp(team)
      assert {:ok, 1} = Notifications.send_test_chat(team)

      assert Enum.any?(all_enqueued(), fn job ->
               job.args["payload"]["alerts_muted"] == true
             end)
    end
  end

  # ── cch-w32-s1: the mute reaches THE WIRE, not just the payload ────────────
  #
  # The payload assertion above proves the flag is carried; this proves it is
  # SAID. Drives the same Oban args a worker would through `deliver_chat/4` into
  # the fake transport and reads the bytes Slack would have received.
  # WAVE 32 REVIEW: this describe block opened with a `setup` that did
  # `Application.put_env(:barkpark_cloud, :notifications_http_client,
  # FakeHttpClient)` inside an `async: true` module. That write is node-global,
  # so `async_global_seam_guard_test.exs` — a standing ratchet over both trees —
  # reds on it, and the Cloud gate would have caught what a four-file slice gate
  # could not see. It was also pure redundancy: `config/test.exs:25` already
  # points the seam at `FakeHttpClient` for the whole test env, and the fake
  # keeps its programmed responses in the CALLING PROCESS's dictionary, so it is
  # parallel-safe with no swap at all. Removed rather than annotated.
  describe "a muted team's test discloses the mute on the wire" do
    test "the old 'the channel works' sentence is NOT what a muted team receives" do
      team = team_with_member()

      {:ok, _} =
        Notifications.put_channel(team, "slack", true, %{"url" => "https://hooks.slack.com/x"})

      {:ok, _} = Notifications.update_settings(team, %{"alerts_enabled" => false})

      FakeHttpClient.program([{:ok, %{status: 200, body: ""}}])
      assert {:ok, 1} = Notifications.send_test_chat(team)

      [%{args: %{"payload" => payload}}] = all_enqueued(worker: ChatNotificationWorker)
      assert :ok = Notifications.deliver_chat(team.id, "slack", "test", payload)

      [%{body: body}] = FakeHttpClient.requests()

      assert body =~ "The channel works"
      assert body =~ "alerts are currently OFF for this team"

      refute body =~ "If you can read this, the channel works.",
             "the unqualified sentence is the lie this slice removed for a muted team"
    end

    test "an UNMUTED team still gets the plain transport confirmation" do
      team = team_with_member()

      {:ok, _} =
        Notifications.put_channel(team, "slack", true, %{"url" => "https://hooks.slack.com/x"})

      FakeHttpClient.program([{:ok, %{status: 200, body: ""}}])
      assert {:ok, 1} = Notifications.send_test_chat(team)

      [%{args: %{"payload" => payload}}] = all_enqueued(worker: ChatNotificationWorker)
      assert :ok = Notifications.deliver_chat(team.id, "slack", "test", payload)

      [%{body: body}] = FakeHttpClient.requests()
      assert body =~ "If you can read this, the channel works."
      refute body =~ "alerts are currently OFF"
    end
  end

  # ── cch-w32-s1: an enqueue failure is no longer silent ─────────────────────
  #
  # `enqueue_channel/4` used to end `|> Oban.insert()` inside a bare `for` with
  # the result DISCARDED, so a decided-but-never-enqueued notification reached
  # nobody with no row and no log. It now returns `{:ok, job} | {:error, reason}`,
  # logs each failure with team/channel/event, and `enqueue_chat/3` states the
  # shape of the fan-out when any leg fails.
  #
  # HONEST LIMIT, stated rather than papered over: `Oban.insert/1` returns
  # `{:error, changeset}` only for a job that is changeset-INVALID (measured:
  # only `max_attempts`/option-level errors produce it), and this call path
  # cannot construct one — a DB-level failure RAISES instead. So the failure
  # branch is asserted by SHAPE (the count is computed from insert results, and
  # a reverted `Enum.each` cannot produce a count at all) rather than by a forced
  # insert error. The reachable half — every returned count matching the jobs
  # that actually exist — is what these assertions pin.
  describe "enqueue accounting" do
    test "the returned count is the jobs that actually exist, never the channels selected" do
      team = team_with_member()

      {:ok, _} =
        Notifications.put_channel(team, "slack", true, %{"url" => "https://hooks.slack.com/x"})

      {:ok, _} =
        Notifications.put_channel(team, "discord", true, %{"url" => "https://discord.com/x"})

      # A disabled third channel is SELECTED by nothing and must not be counted.
      {:ok, _} =
        Notifications.put_channel(team, "telegram", false, %{"token" => "t", "chat_id" => "1"})

      assert {:ok, n} = Notifications.send_test_chat(team)
      assert n == length(all_enqueued(worker: ChatNotificationWorker))
      assert n == 2
    end
  end
end
