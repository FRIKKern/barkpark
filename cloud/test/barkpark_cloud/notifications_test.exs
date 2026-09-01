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
  alias BarkparkCloud.Notifications.{Delivery, EmailSettings, Transactional}
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

    # wave 26 S3 (charter D310). Before this, the body was the RAW scrubbed
    # capture and nothing else: the dashboard said "Hetzner ran out of server
    # capacity for this size" while the same person's inbox, for the same event
    # in the same minute, said `create "…" failed on all 5 candidate
    # type/locations:`. The fixture is the real producer's format
    # (`internal/cli/cloud/provider.go:579`) — five candidates, four voting
    # capacity and one mentioning DNS, so it also exercises the plurality fold —
    # and it carries a credential-shaped `hcloud_…` token so the scrub has
    # something to bite.
    test "provision_failed leads with the humanized cause and keeps the raw capture below it" do
      {team, _emails} = team_with_members(1)
      {:ok, _} = Notifications.ensure_settings(team)

      aggregate =
        ~s(create "acme-site-ac4e1f2a" failed on all 5 candidate type/locations:) <>
          "\n  - cx22/fsn1: server type cx22 unavailable in fsn1 (resource_unavailable)" <>
          "\n  - cx32/fsn1: server type cx32 unavailable in fsn1 (resource_unavailable)" <>
          "\n  - cx22/nbg1: server type cx22 unavailable in nbg1 (resource_unavailable)" <>
          "\n  - cx32/hel1: hetzner dns upsert \"acme.example.com\": resource_unavailable" <>
          "\n  - cx42/hel1: hcloud_9f2a1c7bE4d3Qz rejected: resource_unavailable"

      assert :ok =
               Notifications.dispatch_event(team, :provision_failed, %{
                 name: "acme-site",
                 detail: aggregate
               })

      assert_received {:email, email}
      body = email.text_body

      # THE CAUSE, in words a person can act on.
      cause =
        "A capacity or quota limit was reached at the hosting provider — it may be servers, addresses, DNS zones or another resource. Try again shortly, or check your account's limits with the provider."

      assert body =~ cause

      # THE RAW CAPTURE, RETAINED — not removed, not truncated. The header line
      # and a distinctive sub-line that only the raw aggregate carries.
      assert body =~ ~s(create "acme-site-ac4e1f2a" failed on all 5 candidate type/locations:)
      assert body =~ "- cx22/nbg1: server type cx22 unavailable in nbg1 (resource_unavailable)"

      # ORDER: the cause is above the capture, not appended after it.
      {cause_at, _} = :binary.match(body, cause)
      {capture_at, _} = :binary.match(body, "failed on all 5 candidate")
      assert cause_at < capture_at

      # THE SCRUB STILL BITES on the retained capture — `humanize/1` is
      # `classify |> scrub`, so the secret boundary is unchanged.
      refute body =~ "hcloud_9f2a1c7bE4d3Qz"
      assert body =~ "[redacted] rejected: resource_unavailable"
    end

    # REVIEW (wave 26): the slice's own builder named this branch as the one
    # honest hole in their guard — `cause_then_capture/1` collapses to the bare
    # capture when `humanize/1` classifies nothing, which is correct BY
    # CONSTRUCTION today (`humanize = classify |> scrub`, so the two strings are
    # equal) and therefore guarded by nothing but that construction. A refactor
    # that made `humanize/1` do anything else after the scrub would silently
    # start printing the same paragraph twice, with a heading between the copies,
    # to a customer. That is a sentence with a `defp`, and this wave refuses
    # those. Pinned here.
    test "provision_failed with an UNCLASSIFIABLE reason prints the capture once, with no heading" do
      {team, _emails} = team_with_members(1)
      {:ok, _} = Notifications.ensure_settings(team)

      # Deliberately matches no class token in FailureCopy: no capacity, auth,
      # dns or network vocabulary, and no builder-subset string.
      reason = "the widget lathe reported schedule 7 with token sk_live_QQ11ZZ99aa"

      assert :ok =
               Notifications.dispatch_event(team, :provision_failed, %{
                 name: "acme-site",
                 detail: reason
               })

      assert_received {:email, email}
      body = email.text_body

      scrubbed = BarkparkCloud.FailureCopy.scrub(reason)
      # PREMISE: this reason really is unclassified. Without it the test drifts
      # into the classified path and asserts nothing about the branch it names.
      assert BarkparkCloud.FailureCopy.humanize(reason) == scrubbed

      assert body =~ scrubbed
      refute body =~ "What the provider reported:"
      # ONCE, not twice — the whole point of the branch.
      assert length(String.split(body, scrubbed)) == 2
      refute body =~ "sk_live_QQ11ZZ99aa"
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

  ## The daily fleet digest — dr-w19-s5, THE ADDRESS
  ##
  ## `deliver_fleet_digest/1` used to resolve `platform_admin_emails/0`, whose
  ## only source is a config allowlist that is unset on prod and hard-defaults to
  ## `[]`: the one push channel for fleet health succeeded at sending nothing,
  ## every day, for its whole recorded life. It now partitions the fleet by team
  ## and mails each team's own members. These tests pin the two things a SOURCE
  ## census structurally cannot: that the population is REAL (a registered
  ## membership row, never a synthetic address), and that the tenancy ruling
  ## holds — a team's digest carries that team's instances and nobody else's.

  describe "deliver_fleet_digest/1 — the audience" do
    # Fleet rows are read, never persisted, by the digest (`DigestEmail.summary/1`
    # and `body/1` are pure over the update columns), so a struct is the honest
    # fixture — no Registry insert, no migration coupling.
    defp barkpark_row(team, name, attrs \\ %{}) do
      Map.merge(
        %BarkparkCloud.Registry.Barkpark{
          id: Ecto.UUID.generate(),
          team_id: team.id,
          name: name,
          slug: name,
          update_state: "behind",
          update_running_release: "v1.0.0",
          update_latest_release: "v1.1.0",
          autoupdate_enabled: true,
          autoupdate_paused: false
        },
        attrs
      )
    end

    # Every email the Swoosh test adapter delivered to this process, drained in
    # order. `assert_email_sent/1` consumes exactly one message and asserts on
    # its return value, which cannot express "no email anywhere says X".
    defp sent_emails(acc \\ []) do
      receive do
        {:email, email} -> sent_emails([email | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp recipient_of(email) do
      [{_name, address}] = email.to
      address
    end

    test "recipients are the REAL team members — one mail per member, per team" do
      {team_a, [a1, a2]} = team_with_members(2)
      {team_b, [b1]} = team_with_members(1)

      fleet = [
        barkpark_row(team_a, "alpha-one"),
        barkpark_row(team_a, "alpha-two"),
        barkpark_row(team_b, "bravo-one")
      ]

      assert {:ok, %{sent: 3, recipients: recipients}} = Notifications.deliver_fleet_digest(fleet)

      assert Enum.sort(recipients) == Enum.sort([a1, a2, b1])
      assert Enum.sort(Enum.map(sent_emails(), &recipient_of/1)) == Enum.sort([a1, a2, b1])

      # REAL, not synthetic: every address is a registered user's stored email.
      for email <- recipients do
        assert Accounts.get_user_by_email(email),
               "#{email} must be a registered account, not an address the digest invented"
      end
    end

    test "TENANCY: a team's digest carries that team's instances and no other team's" do
      {team_a, [a1]} = team_with_members(1)
      {team_b, [b1]} = team_with_members(1)

      fleet = [barkpark_row(team_a, "alpha-only"), barkpark_row(team_b, "bravo-only")]

      assert {:ok, %{sent: 2}} = Notifications.deliver_fleet_digest(fleet)

      bodies = Map.new(sent_emails(), &{recipient_of(&1), &1.text_body})

      assert bodies[a1] =~ "alpha-only"
      refute bodies[a1] =~ "bravo-only"
      assert bodies[a1] =~ "Fleet: 1 instance"

      assert bodies[b1] =~ "bravo-only"
      refute bodies[b1] =~ "alpha-only"
    end

    test "each send is a Delivery row carrying the REAL team_id it was sent for" do
      {team, [member]} = team_with_members(1)

      assert {:ok, %{sent: 1}} = Notifications.deliver_fleet_digest([barkpark_row(team, "solo")])

      assert [row] = Delivery |> Repo.all() |> Enum.filter(&(&1.event == "fleet_digest"))
      assert row.recipient == member
      assert row.team_id == team.id, "a fleet_digest row with team_id nil is returnable by nobody"
      assert row.status == "sent"
      assert row.kind == "transactional"
    end

    test "a team with instances but ZERO members is skipped, not mailed and not invented" do
      memberless = team_fixture()
      {team, [member]} = team_with_members(1)

      fleet = [barkpark_row(memberless, "orphan"), barkpark_row(team, "owned")]

      assert {:ok, %{sent: 1, recipients: [^member]}} = Notifications.deliver_fleet_digest(fleet)

      emails = sent_emails()
      assert length(emails) == 1
      refute hd(emails).text_body =~ "orphan"
    end

    # REVIEW FIX (w20): `instances` is the WHOLE fleet, and under per-team
    # partitioning that stopped meaning "instances someone was told about" — an
    # instance with a nil team_id, or one whose team has no members, is counted
    # in `instances` and reaches nobody. `instances=3` beside `sent=1` would
    # read as a digest that spoke for three instances when it spoke for one.
    # `covered` is the honest denominator, and this test pins the GAP: the two
    # numbers must be allowed to disagree, and the log must show both.
    test "the accounting states how much of the fleet the digest actually spoke for" do
      {team, [_member]} = team_with_members(1)
      memberless = team_fixture()

      fleet = [
        barkpark_row(team, "owned"),
        barkpark_row(memberless, "no-members"),
        barkpark_row(memberless, "no-members-2")
      ]

      # Read off TELEMETRY, not the log line: this is the SUCCESS arm, which
      # logs at :info, and config/test.exs pins the Logger to :warning — a
      # capture_log assertion here would read "" and pass vacuously against any
      # value of `covered` whatsoever. The telemetry metadata is the same map
      # the log line renders from.
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "covered-#{inspect(ref)}",
        [:barkpark_cloud, :notifications, :fleet_digest, :settled],
        fn _event, measurements, metadata, _cfg ->
          send(test_pid, {ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("covered-#{inspect(ref)}") end)

      assert {:ok, %{sent: 1}} = Notifications.deliver_fleet_digest(fleet)

      assert_receive {^ref, %{recipients: 1, sent: 1}, metadata}

      # The whole fleet is still reported as the fleet — that number is not a lie,
      # it is just not the reach.
      assert metadata.instances == 3
      # …and exactly ONE of those three instances belongs to a team that was
      # actually mailed. A `covered: 3` here would be the overstatement.
      assert metadata.covered == 1
    end

    test "an empty fleet is a COUNTED loss: recipients=0 at WARNING, and nothing is sent" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :no_admins} = Notifications.deliver_fleet_digest([])
        end)

      assert log =~ "fleet_digest phase=settled"
      assert log =~ "recipients=0 sent=0"
      assert log =~ "reason=no_team_recipients"
      assert log =~ "[warning]"

      assert sent_emails() == []
    end

    # "the digest no longer reads the platform allowlist AT ALL" is NOT tested
    # here on purpose. Proving it requires a REGISTERED allowlisted address that
    # is in no team, and `:platform_admin_emails` is node-global Application
    # config — writing it from this `async: true` module is exactly the seam
    # `async_global_seam_guard_test.exs` reds on, and it would put the swap in
    # force for every other async module running at that instant. The claim is
    # pinned in `workers/daily_digest_worker_test.exs` (`async: false`), which
    # owns that key already: "an allowlisted address that is in no team is
    # dropped, never mailed".
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

  ## cch-w40-bl — the test send stops asserting a success it cannot know.
  ##
  ## The mail rides `Mailer.deliver/1` with NO override, so it can only ever
  ## exercise the PLATFORM transport. It nevertheless said "your notification
  ## email is working": a team on `transport: "smtp"` pointing at a dead relay
  ## passed 100% of the time, and every real alert then silently fell back to
  ## the platform transport too (`deliver_alert/2` branches; the test send did
  ## not). The remedy is DISCLOSURE, not routing.

  describe "test-send honesty (cch-w40-bl)" do
    test "the body names the transport it exercised instead of an unqualified success" do
      body = Transactional.test_email("someone@example.com").text_body

      assert body =~ "sent over the Barkpark platform mail transport",
             "the mail must name the carrier the send actually used"

      refute body =~ "your notification email is working",
             "the unqualified claim IS the defect — this send never touches a team relay"
    end

    test "a team on smtp is told, in the same breath, that its own relay was not proved" do
      body =
        Transactional.test_email("someone@example.com", selected_transport: "smtp").text_body

      assert body =~ "sent over the Barkpark platform mail transport"
      assert body =~ "own SMTP relay"

      assert body =~ "did NOT use your relay",
             "silence here is exactly what let a dead relay pass this test"

      assert body =~ "it does not prove your SMTP settings",
             "the consequence is stated, not left to be inferred"
    end

    test "the disclosure can LOSE — an instance team has nothing outstanding" do
      inst =
        Transactional.test_email("someone@example.com", selected_transport: "instance").text_body

      # "instance" IS the platform transport: the team's own selection was
      # exercised. A caveat that fires here is noise, and noise is how a real
      # one stops being read.
      refute inst =~ "SMTP"
      refute inst =~ "did NOT use your relay"

      # An absent selection is UNKNOWN, and unknown is not a mismatch —
      # inventing one is the same crime pointing the other way.
      refute Transactional.test_email("someone@example.com").text_body =~ "did NOT use your relay"
    end

    test "deliver_test/1 is UNCHANGED in arity and still rides the platform Mailer" do
      Code.ensure_loaded!(Transactional)

      assert function_exported?(Transactional, :deliver_test, 1),
             "the probe is deliberately NOT routed over an unverified team relay: " <>
               "that can hang the request path. Arity 1 — build, then Mailer.deliver/1 " <>
               "with no override — must survive."

      assert {:ok, _} = Transactional.deliver_test("someone@example.com")
      assert_email_sent(subject: "Barkpark Cloud test email")
    end

    test "the mail Notifications.deliver_test/2 actually sends carries the disclosure" do
      {team, [email]} = team_with_members(1)
      {:ok, settings} = Notifications.ensure_settings(team)

      {:ok, _} =
        settings |> EmailSettings.changeset(%{transport: "smtp"}) |> Repo.update()

      assert {:ok, _} = Notifications.deliver_test(team, email)

      assert_email_sent(fn sent ->
        assert sent.text_body =~ "sent over the Barkpark platform mail transport"

        assert sent.text_body =~ "did NOT use your relay",
               "the context must hand the SELECTED transport through, or the " <>
                 "honest body never reaches the person who pressed the button"
      end)
    end

    test "an instance team's real send stays clean of a caveat it does not need" do
      {team, [email]} = team_with_members(1)
      {:ok, settings} = Notifications.ensure_settings(team)
      assert settings.transport == "instance", "the default selection is the platform transport"

      assert {:ok, _} = Notifications.deliver_test(team, email)

      assert_email_sent(fn sent ->
        assert sent.text_body =~ "sent over the Barkpark platform mail transport"
        refute sent.text_body =~ "did NOT use your relay"
        # `assert_email_sent/1` asserts on the fun's RETURN value, and `refute`
        # returns false — so the clean case must hand back a truthy value or the
        # assertion that the caveat is ABSENT reads as a failed send.
        true
      end)
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
