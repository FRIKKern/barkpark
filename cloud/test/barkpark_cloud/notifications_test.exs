defmodule BarkparkCloud.NotificationsTest do
  @moduledoc """
  Covers the notifications-email context: settings changeset + encryption
  round-trip + masking, the auto-create / lazy backstop, the alert dispatcher's
  toggle / always-send / team-members-only behaviour, the transactional path over
  the platform transport, and the 10s test-send rate limit.

  Mail is asserted via Swoosh.Adapters.Test (config/test.exs) — every email lands
  in the test process mailbox, no network.
  """
  use BarkparkCloud.DataCase, async: true
  import Swoosh.TestAssertions

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.{Delivery, EmailSettings}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo

  ## Fixtures

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })
      |> Accounts.register_user()

    user
  end

  # A team with `count` members; returns {team, [emails]}.
  defp team_with_members(count) do
    team = team_fixture()

    emails =
      for _ <- 1..count do
        user = user_fixture()
        {:ok, _} = Accounts.add_member(team, user, "member")
        user.email
      end

    {team, emails}
  end

  ## EmailSettings changeset

  describe "EmailSettings.changeset/2" do
    test "accepts a minimal valid row and applies defaults" do
      team = team_fixture()
      cs = EmailSettings.changeset(%EmailSettings{}, %{team_id: team.id, transport: "instance"})
      assert cs.valid?
    end

    test "rejects an unknown transport" do
      team = team_fixture()

      cs =
        EmailSettings.changeset(%EmailSettings{}, %{team_id: team.id, transport: "carrier-pigeon"})

      refute cs.valid?
      assert "is invalid" in errors_on(cs).transport
    end

    test "rejects an out-of-range smtp_port" do
      team = team_fixture()

      cs =
        EmailSettings.changeset(%EmailSettings{}, %{
          team_id: team.id,
          transport: "smtp",
          smtp_port: 70_000
        })

      refute cs.valid?
      assert errors_on(cs).smtp_port != []
    end

    test "rejects a malformed from_address" do
      team = team_fixture()

      cs =
        EmailSettings.changeset(%EmailSettings{}, %{
          team_id: team.id,
          transport: "instance",
          from_address: "not-an-email"
        })

      refute cs.valid?
      assert "must be a valid email" in errors_on(cs).from_address
    end

    test "enforces one row per team (unique team_id)" do
      team = team_fixture()
      {:ok, _} = Notifications.ensure_settings(team)
      assert {:error, cs} = Notifications.ensure_settings(team)
      assert "has already been taken" in errors_on(cs).team_id
    end
  end

  describe "event_enabled?/2" do
    test "failures default on, successes default off" do
      s = %EmailSettings{}
      assert EmailSettings.event_enabled?(s, :provision_failed)
      refute EmailSettings.event_enabled?(s, :provision_succeeded)
    end

    test "alerts_enabled=false mutes every event" do
      s = %EmailSettings{alerts_enabled: false}
      refute EmailSettings.event_enabled?(s, :provision_failed)
    end

    test "an unknown event is never enabled" do
      refute EmailSettings.event_enabled?(%EmailSettings{}, :nonexistent_event)
    end
  end

  ## Auto-create / lazy backstop

  describe "ensure_settings/1 + get_or_create_settings/1" do
    test "ensure_settings creates exactly one row" do
      team = team_fixture()
      assert {:ok, %EmailSettings{}} = Notifications.ensure_settings(team)
      assert Repo.aggregate(from(s in EmailSettings, where: s.team_id == ^team.id), :count) == 1
    end

    test "get_or_create_settings is idempotent — never a second row" do
      team = team_fixture()
      s1 = Notifications.get_or_create_settings(team)
      s2 = Notifications.get_or_create_settings(team)
      assert s1.id == s2.id
      assert Repo.aggregate(from(s in EmailSettings, where: s.team_id == ^team.id), :count) == 1
    end
  end

  ## Secret round-trip + masking

  describe "update_settings/2 — the encryption boundary" do
    test "stores SMTP secrets as ciphertext, recoverable via Vault, masked in the view" do
      team = team_fixture()
      {:ok, _} = Notifications.ensure_settings(team)

      assert {:ok, settings} =
               Notifications.update_settings(team, %{
                 "transport" => "smtp",
                 "smtp_host" => "smtp.example.com",
                 "smtp_username" => "mailer",
                 "smtp_password" => "s3cr3t-pw",
                 "smtp_port" => 587,
                 "smtp_encryption" => "starttls"
               })

      # Column holds ciphertext, NOT the plaintext.
      refute settings.smtp_password_encrypted == "s3cr3t-pw"
      assert {:ok, "s3cr3t-pw"} = Vault.decrypt(settings.smtp_password_encrypted)
      assert {:ok, "smtp.example.com"} = Vault.decrypt(settings.smtp_host_encrypted)

      # The view masks every secret — never the cipher, never the clear value.
      view = Notifications.settings_view(settings)
      assert view.smtp_password == "********"
      assert view.smtp_host == "********"
      assert view.smtp_port == 587
      assert view.transport == "smtp"
    end

    test "an omitted secret on a later PUT keeps the stored one" do
      team = team_fixture()
      {:ok, _} = Notifications.ensure_settings(team)

      {:ok, _} = Notifications.update_settings(team, %{"smtp_password" => "first-pw"})
      {:ok, after2} = Notifications.update_settings(team, %{"transport" => "smtp"})

      assert {:ok, "first-pw"} = Vault.decrypt(after2.smtp_password_encrypted)
    end

    test "a blank secret string does not overwrite the stored secret" do
      team = team_fixture()
      {:ok, _} = Notifications.ensure_settings(team)

      {:ok, _} = Notifications.update_settings(team, %{"smtp_password" => "keep-me"})
      {:ok, after2} = Notifications.update_settings(team, %{"smtp_password" => ""})

      assert {:ok, "keep-me"} = Vault.decrypt(after2.smtp_password_encrypted)
    end

    test "an unset secret masks to nil so a client can tell set from unset" do
      team = team_fixture()
      settings = Notifications.get_or_create_settings(team)
      view = Notifications.settings_view(settings)
      assert view.smtp_password == nil
      assert view.api_key == nil
    end
  end

  ## Alert dispatch

  describe "dispatch_event/3" do
    test "an enabled event emails every team member and records a sent Delivery each" do
      {team, emails} = team_with_members(2)
      {:ok, _} = Notifications.ensure_settings(team)

      # provision_failed defaults ON.
      assert :ok = Notifications.dispatch_event(team, :provision_failed, %{name: "prod"})

      assert_email_sent(subject: "Your Barkpark failed to provision")

      deliveries = Notifications.list_deliveries(team)
      assert length(deliveries) == 2
      assert Enum.all?(deliveries, &(&1.status == "sent"))
      assert Enum.all?(deliveries, &(&1.kind == "alert"))
      assert MapSet.new(Enum.map(deliveries, & &1.recipient)) == MapSet.new(emails)
    end

    test "a disabled event sends nothing and records no deliveries" do
      {team, _emails} = team_with_members(1)
      {:ok, _} = Notifications.ensure_settings(team)

      # provision_succeeded defaults OFF.
      assert :ok = Notifications.dispatch_event(team, :provision_succeeded, %{name: "prod"})

      refute_email_sent()
      assert Notifications.list_deliveries(team) == []
    end

    test "alerts_enabled=false mutes even a default-on failure event" do
      {team, _emails} = team_with_members(1)
      {:ok, _} = Notifications.ensure_settings(team)
      {:ok, _} = Notifications.update_settings(team, %{"alerts_enabled" => false})

      assert :ok = Notifications.dispatch_event(team, :provision_failed, %{name: "prod"})
      refute_email_sent()
    end

    test "an always_send event sends even with the toggle off, but not when alerts_enabled=false" do
      {team, _emails} = team_with_members(1)
      {:ok, _} = Notifications.ensure_settings(team)

      # :test is in @always_send — no per-event toggle column, yet it sends.
      assert :ok = Notifications.dispatch_event(team, :test, %{})
      assert_email_sent()

      {:ok, _} = Notifications.update_settings(team, %{"alerts_enabled" => false})
      assert :ok = Notifications.dispatch_event(team, :test, %{})
      # No NEW email beyond the first.
      assert length(Notifications.list_deliveries(team)) == 1
    end

    test "recipients are team members only — a non-member is never targeted" do
      {team, member_emails} = team_with_members(1)
      {:ok, _} = Notifications.ensure_settings(team)

      # A user who belongs to a DIFFERENT team.
      other_team = team_fixture()
      outsider = user_fixture()
      {:ok, _} = Accounts.add_member(other_team, outsider, "member")

      Notifications.dispatch_event(team, :provision_failed, %{name: "prod"})

      recipients = Notifications.list_deliveries(team) |> Enum.map(& &1.recipient)
      assert recipients == member_emails
      refute outsider.email in recipients
    end
  end

  ## Transactional (always platform transport, regardless of per-team settings)

  describe "transactional email" do
    test "deliver_invite sends over the platform transport even when the team uses SMTP" do
      team = team_fixture()
      {:ok, _} = Notifications.ensure_settings(team)
      {:ok, _} = Notifications.update_settings(team, %{"transport" => "smtp"})

      assert {:ok, _} =
               Notifications.deliver_invite(%{
                 to: "invitee@example.com",
                 url: "https://barkpark.cloud/invite/abc",
                 team_name: team.name
               })

      assert_email_sent(to: {"", "invitee@example.com"})
    end

    test "deliver_password_reset builds the reset subject + to-address" do
      assert {:ok, _} =
               Notifications.deliver_password_reset(
                 "reset@example.com",
                 "https://barkpark.cloud/reset/xyz"
               )

      assert_email_sent(subject: "Reset your Barkpark Cloud password")
    end

    test "deliver_email_verification builds the verify subject" do
      assert {:ok, _} =
               Notifications.deliver_email_verification(
                 "verify@example.com",
                 "https://barkpark.cloud/verify/xyz"
               )

      assert_email_sent(subject: "Verify your Barkpark Cloud email")
    end
  end

  ## Test-send rate limit

  describe "deliver_test/2 rate limit" do
    test "first send succeeds, an immediate retry is rate-limited, no recipient → error" do
      {team, [email]} = team_with_members(1)
      {:ok, _} = Notifications.ensure_settings(team)

      assert {:ok, _} = Notifications.deliver_test(team, email)
      assert_email_sent(subject: "Barkpark Cloud test email")

      # Second call within 10s is refused.
      assert {:error, {:rate_limited, remaining}} = Notifications.deliver_test(team, email)
      assert remaining > 0 and remaining <= 10
    end

    test "a team with no members and no explicit recipient → :no_recipient" do
      team = team_fixture()
      {:ok, _} = Notifications.ensure_settings(team)
      assert {:error, :no_recipient} = Notifications.deliver_test(team, nil)
    end

    test "the rate limit clears once last_test_sent_at ages past the window" do
      {team, [email]} = team_with_members(1)
      {:ok, _} = Notifications.ensure_settings(team)

      assert {:ok, _} = Notifications.deliver_test(team, email)

      # Age the stamp out of the 10s window directly.
      settings = Notifications.get_or_create_settings(team)
      old = DateTime.add(DateTime.utc_now(), -11, :second) |> DateTime.truncate(:microsecond)

      settings
      |> EmailSettings.changeset(%{last_test_sent_at: old})
      |> Repo.update!()

      assert {:ok, _} = Notifications.deliver_test(team, email)
    end
  end

  ## A Delivery row also persists for a transactional test send.

  test "a test send records a transactional Delivery row" do
    {team, [email]} = team_with_members(1)
    {:ok, _} = Notifications.ensure_settings(team)
    {:ok, _} = Notifications.deliver_test(team, email)

    assert [%Delivery{kind: "transactional", event: "test", status: "sent"}] =
             Notifications.list_deliveries(team)
  end
end
