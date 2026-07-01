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
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Workers.ChatNotificationWorker

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
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
  end
end
