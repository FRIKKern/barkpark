defmodule BarkparkCloud.Notifications do
  @moduledoc """
  The email-notification context — the Cloud adaptation of Coolify's notification
  layer (`app/Notifications/*`, `app/Traits/HasNotificationSettings.php`,
  `app/Models/EmailNotificationSettings.php`).

  Three responsibilities:

    * **Settings** — one `EmailSettings` row per Team (auto-created on signup,
      lazily backstopped). The encryption boundary lives here: `update_settings/2`
      runs each plaintext secret (SMTP password, API key, …) through
      `Registry.Vault.encrypt/1` BEFORE the changeset, exactly like
      `Registry.connect_provider/3`. `settings_view/1` returns a MASKED map for
      the API — a ciphertext column is never serialized.

    * **Transactional** — invite / password-reset / verification / test email.
      These ALWAYS ride the platform `BarkparkCloud.Mailer` (never a per-team
      transport), so onboarding works before a team has configured any SMTP.
      Delegated to `Notifications.Transactional`.

    * **Alert dispatch** — `dispatch_event/3` is the
      `HasNotificationSettings.getEnabledChannels` analogue: an `@always_send`
      allowlist + the per-event toggle decide whether to send, recipients are
      ALWAYS team members (Coolify's `EmailChannel.php` data-exfiltration guard),
      and every send is recorded as a `Delivery` row (status / attempts /
      last_error). Synchronous for v1 — cloud/ has no Oban — but the `Delivery`
      row is the retry seam for when it does. `dispatch_event/3` NEVER raises into
      its caller's broadcast path.
  """
  import Ecto.Query, warn: false
  require Logger

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Mailer
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Site
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Workers.ChatNotificationWorker

  alias BarkparkCloud.Notifications.{
    ChannelConfig,
    Channels,
    Delivery,
    DeliveryReason,
    DigestEmail,
    EmailSettings,
    EventEmail,
    SafeUrl,
    Transactional,
    Withhold
  }

  # Events that bypass the per-event toggle (Coolify's `$alwaysSendEvents`) — but
  # still respect `alerts_enabled`. Pruned from Coolify's PaaS set (no
  # ssl_certificate_renewal / server_force_* — those are out of scope here).
  # `trial_expiring` (dwb-13) is on the allowlist: a trial-ending heads-up is
  # important enough to bypass the per-event opt-in toggle, but it still honours
  # `alerts_enabled` (a team that muted everything won't get it).
  #
  # cch-w32-s1 (charter D360): `general` is GONE. It had zero producers, zero
  # render arms and zero console rows — a name on an allowlist is not a
  # mechanism, and wave 30's migration 20260804123000 set the precedent that a
  # producerless event name is DELETED, never wired. Wiring it would have
  # manufactured exactly the promise-with-no-mechanism this epic exists to kill.
  @always_send ~w(test trial_expiring)a

  # Seconds a team must wait between "send test" presses (Coolify's 10s/team).
  @test_rate_limit_seconds 10

  # notifications-chat: the chat-routing event vocabulary — main's per-event alert
  # set rendered as strings (`EmailSettings.events/0`) plus the always-send `test`.
  # These are the keys allowed in `event_routes` and the events chat fans on.
  @chat_events Enum.map(EmailSettings.events(), &Atom.to_string/1) ++ ["test"]

  # Failure events that fan to EVERY enabled chat channel by default until the team
  # customizes the matrix (failures opt-out, successes opt-in — Coolify's rule).
  @chat_default_on ~w(provision_failed deployment_failed agent_unreachable
                      subscription_past_due)

  # Events that ignore `event_routes` and always fan to every enabled chat channel.
  #
  # cch-w32-s1 (charter D359): `trial_expiring` is routed to chat HERE and
  # nowhere else. A Slack-only team was never told its trial ends and its
  # instance is torn down: the worker really dispatches the event hourly and the
  # EMAIL arm works, but `channels_for_event/2` selected zero chat channels.
  # Settled by a four-variant run:
  #
  #   * widening `@chat_events` alone delivers ZERO jobs (`routed_types/3`
  #     returns [] for an event that is neither routed nor `@chat_default_on`)
  #     and newly accepts a per-event route WRITE that did not exist before;
  #   * `@chat_default_on` delivers, but it creates an API-reachable per-event
  #     mute with no checkbox behind it — the column charter D342(d) forbids
  #     ("DISCLOSE, never column-ise");
  #   * `@chat_always_send` short-circuits BEFORE `routed_types/3`, so it needs
  #     no vocabulary change, it refuses the opt-out route write, and it still
  #     honours `alerts_enabled` (the false clause precedes it at
  #     `should_send?/2` and `enqueue_chat/3`).
  @chat_always_send ~w(test trial_expiring)

  ## ── Settings ─────────────────────────────────────────────────────────────

  @doc """
  Fetch a Team's settings, creating the row on first read. The lazy backstop for
  teams that predate the migration / the signup auto-create — read-time create,
  mirroring how Coolify's `Team.php:59` guarantees the row but without a
  back-fill pass. Race-safe: a concurrent insert (unique on team_id) is caught
  and the existing row re-read.
  """
  @spec get_or_create_settings(Team.t() | binary()) :: EmailSettings.t()
  def get_or_create_settings(team) do
    tid = team_id(team)

    case Repo.get_by(EmailSettings, team_id: tid) do
      %EmailSettings{} = settings ->
        settings

      nil ->
        case insert_settings(tid) do
          {:ok, settings} ->
            settings

          # Lost the insert race (or any other constraint) — re-read the row the
          # winner created. Falls back to a bare struct only if it's truly gone.
          {:error, _changeset} ->
            Repo.get_by(EmailSettings, team_id: tid) || %EmailSettings{team_id: tid}
        end
    end
  end

  @doc """
  Ensure a Team has a settings row — called INSIDE the signup `Repo.transaction`
  right after `Accounts.add_member`, mirroring Coolify's auto-create on team
  create. Returns `{:ok, settings}` / `{:error, changeset}` so it composes in the
  `with` chain. The team is brand-new here, so there is no race to defend.
  """
  @spec ensure_settings(Team.t() | binary()) ::
          {:ok, EmailSettings.t()} | {:error, Ecto.Changeset.t()}
  def ensure_settings(team), do: insert_settings(team_id(team))

  defp insert_settings(team_id) do
    %EmailSettings{}
    |> EmailSettings.changeset(%{team_id: team_id})
    |> Repo.insert()
  end

  @doc """
  Update a Team's settings from request `attrs`. THE ENCRYPTION BOUNDARY: plaintext
  secret keys (`smtp_host` / `smtp_username` / `smtp_password`) are run
  through `Registry.Vault.encrypt/1` into the `*_encrypted` columns before the
  changeset — exactly `Registry.connect_provider/3`. A blank/absent secret is
  DROPPED so a PUT that doesn't resend a password keeps the stored one.

  Accepts string- or atom-keyed maps (the router hands it `conn.body_params`).
  """
  @spec update_settings(Team.t() | binary(), map()) ::
          {:ok, EmailSettings.t()} | {:error, Ecto.Changeset.t()}
  def update_settings(team, attrs) do
    settings = get_or_create_settings(team)

    changeset_attrs =
      attrs
      |> normalize_keys()
      |> Map.take([
        "transport",
        "alerts_enabled",
        "smtp_port",
        "smtp_encryption",
        "from_address",
        "from_name"
        | Enum.map(EmailSettings.events(), &Atom.to_string/1)
      ])
      |> put_encrypted("smtp_host", :smtp_host_encrypted, attrs)
      |> put_encrypted("smtp_username", :smtp_username_encrypted, attrs)
      |> put_encrypted("smtp_password", :smtp_password_encrypted, attrs)
      |> Map.put("team_id", settings.team_id)

    settings
    |> EmailSettings.changeset(changeset_attrs)
    |> Repo.update()
  end

  # Encrypt one plaintext secret into its ciphertext column, but only when the
  # caller actually sent a non-blank value (so an unchanged secret is left as-is).
  defp put_encrypted(changeset_attrs, plain_key, encrypted_field, source_attrs) do
    source = normalize_keys(source_attrs)

    case Map.get(source, plain_key) do
      v when is_binary(v) and v != "" ->
        Map.put(changeset_attrs, Atom.to_string(encrypted_field), Vault.encrypt(v))

      _ ->
        changeset_attrs
    end
  end

  @doc """
  The API-safe view of a settings row — secrets MASKED, never the ciphertext nor
  the clear value. A configured secret shows as `"********"`, an unset one as
  `nil`, so a client can tell "set" from "unset" without learning the value.
  """
  @spec settings_view(EmailSettings.t()) :: map()
  def settings_view(%EmailSettings{} = s) do
    event_view = Map.new(EmailSettings.events(), fn ev -> {ev, Map.fetch!(s, ev)} end)

    Map.merge(
      %{
        transport: s.transport,
        alerts_enabled: s.alerts_enabled,
        smtp_host: mask(s.smtp_host_encrypted),
        smtp_username: mask(s.smtp_username_encrypted),
        smtp_password: mask(s.smtp_password_encrypted),
        smtp_port: s.smtp_port,
        smtp_encryption: s.smtp_encryption,
        from_address: s.from_address,
        from_name: s.from_name,
        last_test_sent_at: s.last_test_sent_at,
        # notifications-chat: the chat half. Credentials are NEVER serialized —
        # each channel reports only type, enabled, and whether creds are configured.
        channels: chat_channels_view(s.channels),
        event_routes: s.event_routes || %{},
        chat_events: @chat_events,
        channel_types: chat_channel_types(),
        chat_default_on: @chat_default_on,
        # cch-w32-s1: the always-send half of the chat vocabulary. Without it an
        # SDK/CLI/agent reading this view sees `chat_events` only and cannot
        # learn that `trial_expiring` reaches chat at all — the event is
        # deliberately absent from `chat_events` (it takes no route), so the
        # view has to state it separately or the vocabulary reads as smaller
        # than it is.
        chat_always_send: @chat_always_send
      },
      event_view
    )
  end

  # The redacted chat-channel view — never the ciphertext, only a "configured" flag.
  defp chat_channels_view(channels) do
    Enum.map(channels || [], fn c ->
      %{
        type: c.type,
        enabled: c.enabled,
        configured: not (is_nil(c.credentials_encrypted) or c.credentials_encrypted == "")
      }
    end)
  end

  defp mask(nil), do: nil
  defp mask(""), do: nil
  defp mask(_ciphertext), do: "********"

  ## ── Transactional (the beta blocker) ─────────────────────────────────────

  # transactional-delivery-observability: every identity/transactional send now
  # writes ONE Delivery row (kind "transactional") capturing the ok/failed
  # outcome — the same observability + retry seam `alert`/`test` already have, so
  # a failed must-arrive email is visible instead of silent. INVITE is team-scoped
  # (the `team_id` in the invite map sets the row's team); password-reset / verify
  # / email-change-code are USER-scoped (team_id nil — those rows don't surface in
  # any team's log). Recording never changes the returned send result.

  @doc "Deliver a team-invite email over the PLATFORM transport. See `Transactional`."
  def deliver_invite(invite) do
    result = Transactional.deliver_invite(invite)
    record_delivery(Map.get(invite, :team_id), invite[:to], "invite", "transactional", result)
    result
  end

  @doc "Deliver a password-reset email over the PLATFORM transport."
  def deliver_password_reset(to, url) do
    result = Transactional.deliver_password_reset(to, url)
    record_delivery(nil, to, "password_reset", "transactional", result)
    result
  end

  @doc "Deliver an email-verification email over the PLATFORM transport."
  def deliver_email_verification(to, url) do
    result = Transactional.deliver_email_verification(to, url)
    record_delivery(nil, to, "email_verification", "transactional", result)
    result
  end

  @doc "Deliver a verified-email-change 6-digit code over the PLATFORM transport."
  def deliver_email_change_code(to, code) do
    result = Transactional.deliver_email_change_code(to, code)
    record_delivery(nil, to, "email_change_code", "transactional", result)
    result
  end

  @doc """
  Send the settings page's test email, rate-limited to one per
  `#{@test_rate_limit_seconds}`s per team (Coolify `Email.php`'s 10s guard,
  enforced here via `last_test_sent_at`).

  `to` defaults to nil → the first team member's email. A caller-supplied `to`
  MUST be a team member — the platform mailer is not an authenticated open relay
  to arbitrary internet addresses (Coolify's `EmailChannel` data-exfiltration
  guard). Returns `{:ok, term}`, `{:error, {:rate_limited, seconds_remaining}}`,
  `{:error, :no_recipient}`, or `{:error, :recipient_not_member}`.
  """
  @spec deliver_test(Team.t() | binary(), String.t() | nil) ::
          {:ok, term()}
          | {:error,
             {:rate_limited, non_neg_integer()} | :no_recipient | :recipient_not_member | term()}
  def deliver_test(team, to \\ nil) do
    settings = get_or_create_settings(team)

    case test_rate_limit_remaining(settings) do
      0 ->
        members = team_member_emails(settings.team_id)
        recipient = normalize_recipient(to) || List.first(members)

        cond do
          not is_binary(recipient) ->
            {:error, :no_recipient}

          # The recipient must be a team member — validate BEFORE stamping the
          # rate-limit / recording a delivery, so a probe never burns the window
          # or leaves an audit row for a non-member address.
          recipient not in members ->
            {:error, :recipient_not_member}

          true ->
            result = Transactional.deliver_test(recipient)
            _ = stamp_test_sent(settings)
            record_delivery(settings.team_id, recipient, "test", "transactional", result)
            result
        end

      remaining ->
        {:error, {:rate_limited, remaining}}
    end
  end

  # Member emails are stored lower-cased (citext registration), so normalize a
  # caller-supplied recipient the same way before the membership check.
  defp normalize_recipient(to) when is_binary(to), do: String.downcase(to)
  defp normalize_recipient(_), do: nil

  # Seconds left on the per-team test rate limit (0 = may send now).
  defp test_rate_limit_remaining(%EmailSettings{last_test_sent_at: nil}), do: 0

  defp test_rate_limit_remaining(%EmailSettings{last_test_sent_at: last}) do
    elapsed = DateTime.diff(DateTime.utc_now(), last, :second)
    max(@test_rate_limit_seconds - elapsed, 0)
  end

  defp stamp_test_sent(%EmailSettings{} = settings) do
    settings
    |> EmailSettings.changeset(%{
      last_test_sent_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    })
    |> Repo.update()
  end

  ## ── Fleet digest (isu-w5, the operator push) ─────────────────────────────

  @doc """
  Deliver the daily FLEET-UPDATE digest — the "from nag to product" push that
  lands the release curator's daily judgment in a human inbox instead of only a
  draft Release + a run log.

  `barkparks` is the whole fleet (the caller, `DailyDigestWorker`, hands it
  `Registry.all_barkparks/0`). It is PARTITIONED BY TEAM here, and each team's
  members are mailed a digest over THEIR OWN instances: recipients come from
  `team_member_emails/1` -> `Accounts.list_team_member_emails/1`, the same
  exfiltration guard the alert fan-out uses. A fleet with no team that has a
  member is a COUNTED no-op — never a crash and never a send.

  The send rides the PLATFORM `Mailer` (like the transactional path); each
  recipient's send is recorded as a `Delivery` row (kind `"transactional"`) with
  the REAL `team_id` it was sent for, so the row is returnable by the team it
  concerns instead of belonging to nobody. Returns `{:ok, :no_admins}` or
  `{:ok, %{sent: n, recipients: [...]}}` — the `:no_admins` atom is kept verbatim
  because `DailyDigestWorker.perform/1` matches on it; the LOG reason carries the
  honest new wording (`no_team_recipients`).

  ## dr-w19-s5 — THE ADDRESS, not just the count

  This used to resolve `platform_admin_emails/0`, whose only source is the
  `:platform_admin_emails` config allowlist. `PLATFORM_ADMIN_EMAILS` is unset on
  prod, `config.exs` hard-defaults the key to `[]`, no User field carries
  operator-ness and no route, console action or mix task writes it — so the
  population was EMPTY BY CONSTRUCTION and the only push channel for fleet
  health had been succeeding at sending nothing for its whole recorded life.
  Measured (dr-w18-s3): 5 of 5 digest jobs `completed`, zero `fleet_digest` rows
  in `notification_deliveries` across 37 unpruned days. That slice made the zero
  VISIBLE and deliberately left the address alone; this one moves the address.

  THE TENANCY RULING, stated because the guard cannot make it. A fleet-wide
  digest fanned to every team's members would be a CROSS-TEAM DISCLOSURE: the
  body renders one line per instance, by NAME, so a fleet-wide blast would tell
  every member of every team what every other team runs. So the digest is
  PER-TEAM — `Enum.group_by/2` on `team_id`, one summary per team, recipients
  strictly that team's membership rows. Nobody learns of an instance they could
  not already read through the team-scoped instance list. The empty-audience
  census (`deploy_signal_audience_census_test.exs`) would have gone green on the
  fleet-wide shape just as readily as on this one — it reads the resolver's
  source text and judges the POPULATION, never who may see which row.

  What the accounting is NOT: the zero-recipient arm still writes no `Delivery`
  row and invents no recipient — charter D362 names this digest verbatim as a
  consented recipient-less withhold, and `Delivery.changeset/2` requires a
  recipient. It is also not a new alert PRODUCER (D14): it is one counted record
  on an existing rail, at WARNING when the rail lost, so `journalctl -u
  barkpark-cloud | grep fleet_digest` answers "did anyone get today's digest?"
  without a metrics pipeline.

  Scope, as of dr-w28-s5: dr-w19-s5 fixed the ADDRESS and this rail now also
  carries the PAYLOAD. `DigestEmail.summary/2` takes a `:deploy` reading from
  `DigestEmail.deploy_health/1`, so the delivered body names deploy doors, their
  deferral mass and their post-door failure rate — or the word UNMEASURED.
  Before that, a digest that arrived said nothing whatsoever about deploy
  failures (`dr-w10-bl-digest-email-calls-a-sick-fleet-healthy`).

  AND THE PAYLOAD OBEYS THE SAME TENANCY RULING AS THE ADDRESS. The reading is
  taken PER TEAM, over that team's OWN site ids — not once, fleet-wide, and
  threaded into everyone's email. Deploy volume is platform information: the
  first send that ever reached a human reached three teams and TWO of them own
  zero sites, so a fleet-wide total would have told them how much the platform
  deploys and how often it fails — an instance-count-shaped disclosure through
  the back door, in the same email whose per-instance list is partitioned
  precisely to prevent one. Half a rule is not a rule.
  """
  @spec deliver_fleet_digest([term()]) ::
          {:ok, :no_admins} | {:ok, %{sent: non_neg_integer(), recipients: [String.t()]}}
  def deliver_fleet_digest(barkparks) when is_list(barkparks) do
    fleet = DigestEmail.summary(barkparks)

    # WHO gets what, resolved before anything is sent. Two reasons this is a
    # separate pass and not one fused comprehension:
    #
    #   * the empty-audience census derives this function's audience from the
    #     `*_emails` call in THIS body, so the resolution must stay here rather
    #     than move behind a helper;
    #   * the withhold census (`withhold_test.exs`) reads a trace call in a
    #     PREFIX statement as covering every path after it. Sending inside this
    #     comprehension would put `record_delivery/5` ahead of the `[]` arm and
    #     silently absolve the zero-recipient withhold — on that arm the
    #     comprehension ran zero times and traced nothing. Resolve first, send
    #     inside the branch, and the consented withhold stays derivable.
    targets =
      for {team_id, rows} <- Enum.group_by(barkparks, & &1.team_id),
          is_binary(team_id),
          recipients = team_member_emails(team_id),
          recipients != [],
          # THE PAYLOAD READING, TAKEN HERE AND SCOPED TO THIS TEAM'S OWN SITES
          # (dr-w28-s5). Inside the comprehension and not above it: one reading
          # per recipient TEAM is the whole point — a reading hoisted out of the
          # loop is a fleet reading by construction, whatever it is named.
          #
          # Cost is not the reason to hoist it: a scoped census scan measured
          # 3.4ms against 26.9ms fleet-wide, so this is a handful of cheaper
          # queries twice a day rather than two expensive ones. `deploy_health/1`
          # never raises — an unreadable ledger renders as UNMEASURED inside the
          # email instead of failing the send.
          deploy = DigestEmail.deploy_health(site_ids: team_site_ids(team_id)),
          summary = DigestEmail.summary(rows, deploy: deploy),
          recipient <- Enum.uniq(recipients),
          do: {team_id, summary, recipient}

    # HOW MUCH OF THE FLEET THIS DIGEST ACTUALLY SPEAKS FOR (review fix, w20).
    #
    # `instances` is the WHOLE fleet, and partitioning by team means it is no
    # longer the same thing as "instances someone was told about": an instance
    # whose `team_id` is nil, or whose team has no membership row, is in
    # `instances` and in nobody's mail. Reporting only the fleet total would
    # make `recipients=3 sent=3 instances=50` read as fifty instances reported
    # on when it can mean twelve — an overstatement of reach, which is the exact
    # failure mode this epic exists to remove. `covered` is the honest
    # denominator: instances belonging to a team that a digest was built for.
    covered_teams = MapSet.new(targets, fn {team_id, _summary, _recipient} -> team_id end)
    covered = Enum.count(barkparks, &MapSet.member?(covered_teams, &1.team_id))

    case targets do
      # cch-w32-r2 / dr-w19-s5: NAMED CONSENTED — recipient-less by construction,
      # one level up. `Delivery.changeset/2` requires a recipient (delivery.ex:78)
      # and this arm has none; charter D362 forbids a synthetic one. This is not
      # the system deciding against a person, it is the absence of a person.
      #
      # dr-w18-s3: consented is not the same as UNCOUNTED. The `Logger.info` that
      # used to stand here was the entire record of a digest that never left, and
      # nothing — not Oban, not the delivery log, not a metric — could tell this
      # day apart from a day the fleet was mailed. The row stays forbidden; the
      # COUNT does not need a recipient.
      [] ->
        # dr-w18-s3-fu: and the count comes from the SHARED vocabulary, not from
        # this branch's own arithmetic. `Withhold.record/4` is the one funnel
        # through which a withheld notification becomes visible, and its
        # moduledoc has named THIS branch as a consented zero since wave 32 — but
        # the module could not actually be called from here until it grew
        # `:no_recipient_by_construction`, because a digest has no `team_id` and
        # every call landed in the catch-all's `refused an unrecordable withhold`
        # error. A funnel every branch routes through EXCEPT the one its own
        # documentation names is not a funnel.
        #
        # It returns `0`, and `0` is the assertion: a non-zero here would mean a
        # row was written for a branch D362 forbids one on. The count is carried
        # into the accounting below rather than dropped, so it is observable on
        # the same WARNING line an operator already greps for.
        withheld = Withhold.record(nil, "fleet_digest", :no_recipient_by_construction)

        account_fleet_digest(
          %{recipients: 0, sent: 0},
          %{
            instances: fleet.total,
            covered: 0,
            reason: "no_team_recipients",
            withheld: withheld
          }
        )

        {:ok, :no_admins}

      targets ->
        results =
          for {team_id, summary, recipient} <- targets do
            email = DigestEmail.build(summary, recipient)
            result = Mailer.deliver(email)
            record_delivery(team_id, recipient, "fleet_digest", "transactional", result)
            {recipient, result}
          end

        # `{:ok, _}` is `record_delivery/5`'s own "sent" classification, reused so
        # the count and the Delivery rows can never disagree. A digest that failed
        # for two of three recipients used to return `sent: 3`.
        sent = Enum.count(results, fn {_to, result} -> match?({:ok, _}, result) end)
        recipients = Enum.map(results, fn {to, _result} -> to end)
        reason = if sent < length(recipients), do: "partial_send"

        account_fleet_digest(
          %{recipients: length(recipients), sent: sent},
          %{instances: fleet.total, covered: covered, reason: reason}
        )

        {:ok, %{sent: sent, recipients: recipients}}
    end
  end

  # THE SITE IDS ONE TEAM OWNS — the narrowing the digest's deploy reading is
  # taken through (dr-w28-s5). `Registry.list_sites_for_team/1` accepts a bare
  # team_id binary; `Web.Router`'s team-scoped census route reads the same list
  # for the same reason.
  #
  # A LOOKUP FAILURE RETURNS `{:error, …}` AND NEVER `nil`, because `nil` is
  # `census/3`'s word for UNSCOPED: swallowing a DB failure into `nil` would
  # silently promote this team's reading to a fleet-wide one, which is precisely
  # the disclosure the scoping exists to close. `{:error, …}` renders as
  # UNMEASURED with the failure's own words, and the digest still goes out — the
  # ledger read is a side path on a best-effort operator email and must never be
  # able to break the send it describes.
  defp team_site_ids(team_id) do
    team_id
    |> Registry.list_sites_for_team()
    |> Enum.map(& &1.id)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  # THE ACCOUNTING RECORD for one digest run — transposed from the webhook
  # fan-out's settled record (`Barkpark.Webhooks.Dispatcher.account/3`), which
  # solved this exact shape for a different zero-audience event.
  #
  # Two observable seams, neither of which needs a read route or a metrics
  # pipeline: a `:telemetry` event (a test, or a future reporter, can attach) and
  # one key=value line that `grep fleet_digest` finds in journald. WARNING when
  # the run lost anyone — `recipients=0` is the loss this slice exists to make
  # visible, and a partial send is the same class one degree softer.
  #
  # `safely/1`: accounting is a side path on a best-effort operator email. It
  # must never be able to break the send it is counting.
  defp account_fleet_digest(measurements, metadata) do
    metadata = Map.put(metadata, :phase, :settled)

    safely(fn ->
      :telemetry.execute(
        [:barkpark_cloud, :notifications, :fleet_digest, :settled],
        measurements,
        metadata
      )
    end)

    safely(fn -> log_fleet_digest(measurements, metadata) end)

    :ok
  end

  defp log_fleet_digest(m, meta) do
    line =
      "fleet_digest phase=#{meta.phase} recipients=#{m.recipients} sent=#{m.sent} " <>
        "instances=#{meta.instances} covered=#{Map.get(meta, :covered, 0)}" <>
        if(is_nil(meta.reason), do: "", else: " reason=#{meta.reason}") <>
        case Map.fetch(meta, :withheld) do
          # `Withhold.record/4`'s returned count, on the line an operator reads.
          # Only the branches that funnel through it carry the key at all, so its
          # absence is not silently rendered as a zero.
          {:ok, n} -> " withheld=#{n}"
          :error -> ""
        end

    if m.sent < m.recipients or m.recipients == 0 do
      # THE LOSS CLASS: nobody was mailed, or somebody was not. Warning, because
      # the whole defect was that this outcome read as a success everywhere.
      Logger.warning(line)
    else
      Logger.info(line)
    end
  end

  # A trace must not be able to break the branch it is tracing (the same
  # discipline `Withhold.record/4` rescues into).
  defp safely(fun) do
    fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  The platform-operator recipient set — the canonical stored emails of the
  configured admin account(s).

  There is NO platform-admin flag on a User today (roles are strictly per-team —
  owner/admin/member), so the operator names the admin account(s)
  `mix barkpark_cloud.create_admin` minted via the `:platform_admin_emails`
  config allowlist. Each configured address is resolved to a REGISTERED user (a
  typo or a gone account is dropped, never mailed) and de-duped; the canonical
  stored email is returned. Empty/unconfigured → `[]`, which callers treat as a
  no-op — and which the `/v1/me` `platform_operator` boolean reads as
  fail-closed `false`.

  Public because `GET /v1/me` derives its `platform_operator` boolean from this
  allowlist (membership by email, never a team role — the Authz law keeps
  authority per-membership-row). This is the DECLARED interim operator principal
  per charter GR9: `isu-backlog-operator-principal` inherits/reconciles this
  boolean when a first-class platform-operator principal lands.
  """
  def platform_admin_emails do
    :barkpark_cloud
    |> Application.get_env(:platform_admin_emails, [])
    |> List.wrap()
    |> Enum.map(&normalize_recipient/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Accounts.get_user_by_email/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.email)
    |> Enum.uniq()
  end

  ## ── Alert dispatch (the softer half) ─────────────────────────────────────

  @doc """
  Dispatch an alert `event` for `team` with `payload` — the additive call at a
  trigger site (provision result, agent health flip, subscription past_due).

  The `getEnabledChannels` analogue: send iff the event is in the `@always_send`
  allowlist OR the team's per-event toggle is on (and `alerts_enabled` holds).
  Recipients are ALWAYS team members — the data-exfiltration guard from Coolify's
  `EmailChannel.php`. Each recipient gets one `Delivery` row (status sent/failed).

  Synchronous for v1 (cloud/ has no Oban); always returns `:ok` and NEVER raises
  into the caller's broadcast path — a send failure lands as a `failed` Delivery
  row, not an exception.
  """
  @spec dispatch_event(Team.t() | binary(), atom(), map()) :: :ok
  def dispatch_event(team, event, payload \\ %{}) when is_atom(event) do
    settings = get_or_create_settings(team)

    if should_send?(settings, event) do
      # cch-w32-r2 (census row `dispatch_event/3 c1 do if(should_send?)>then>
      # for(...)>empty`): a team whose member list is EMPTY sends nothing and
      # writes nothing. NAMED CONSENTED, not funnelled: `Delivery.changeset/2`
      # runs `validate_required([:recipient, :event])` (delivery.ex:78), so a
      # withhold row here has no recipient by construction — and charter D362
      # forbids inventing one (a synthetic address is a row claiming a person
      # was involved who was not). There is nobody the alert was withheld FROM.

      # cch-w42-s6: the ROLE rides alongside the address so the body can name who
      # may act. The recipient LIST is untouched — every member is still mailed.
      roles = team_member_roles(settings.team_id)

      for recipient <- team_member_emails(settings.team_id) do
        email =
          EventEmail.build(settings, event, payload, %{
            email: recipient,
            role: Map.get(roles, recipient)
          })

        result = deliver_alert(settings, email)
        record_delivery(settings.team_id, recipient, Atom.to_string(event), "alert", result)
      end
    end

    # notifications-chat: the SAME trigger also fans out to the team's enabled +
    # routed CHAT channels. Independent of the per-event EMAIL toggle (a team can
    # route an event to Slack without also emailing it) but still gated by the
    # master `alerts_enabled` switch. Enqueues one Oban job per selected channel —
    # egress is off the request path, with native retry/backoff.
    enqueue_chat(settings, Atom.to_string(event), payload)

    :ok
  rescue
    # The dispatcher is wired into broadcast paths that must never fail because
    # email did. Log and swallow — the SSE signal still goes out.
    #
    # cch-w32-r2: the SWALLOW is deliberate; the SILENCE was not. This arm eats
    # any crash in the whole email fan-out AND the chat enqueue while returning
    # `:ok` to the producer, so a team read a delivery log byte-identical to "no
    # alert was ever triggered". The withhold now becomes a row per member.
    error ->
      Logger.error("Notifications.dispatch_event/3 crashed: #{Exception.message(error)}")

      Withhold.record(withholdable_team_id(team), Atom.to_string(event), :dispatch_crashed)

      :ok
  end

  # The rescue arm above runs on ANY crash — including one raised before
  # `settings` was ever bound — so the team id must be recovered from the
  # ARGUMENT, and recovering it must not itself raise inside a rescue. An
  # unrecognisable `team` yields `nil`, which `Withhold.record/4` refuses out
  # loud rather than writing a row about a team nobody can name.
  defp withholdable_team_id(%Team{id: id}), do: id
  defp withholdable_team_id(id) when is_binary(id), do: id
  defp withholdable_team_id(_other), do: nil

  @doc """
  Dispatch an alert `event` keyed by a **Site** — the deployment-side twin of the
  router's barkpark-keyed helper (charter D333).

  Deployment carries only `belongs_to :site`, and `Site` carries `belongs_to
  :team`, so a deployment-failure trigger has no team in hand. This resolves the
  owning team through the site and puts the SITE's name into the payload, so the
  alert names the thing that failed instead of falling back to EventEmail's
  generic "Your Barkpark".

  It lives HERE and not in the router on purpose: the producers are
  `Registry.transition_deployment_fenced/4`, `Registry.reap_stale_deployments/0`
  (a cron worker, no request at all) and `Registry.create_failed_deployment/3` —
  none of which can reach a private router helper.

  A since-deleted or non-UUID site id is a silent `:ok`; `dispatch_event/3`
  itself never raises.
  """
  @spec dispatch_site_event(binary() | nil, atom(), map()) :: :ok
  def dispatch_site_event(site_id, event, payload \\ %{}) when is_atom(event) do
    with id when is_binary(id) <- Repo.uuid_or_nil(site_id),
         %Site{team_id: team_id, name: name} when is_binary(team_id) <- Repo.get(Site, id) do
      dispatch_event(team_id, event, Map.put_new(payload, :name, name))
    else
      # cch-w32-r2 (census row `dispatch_site_event/3 c1 do with>else>_`): NAMED
      # CONSENTED under charter D349(b). A since-deleted or non-UUID site has no
      # team, so a row written here is returnable by NOBODY — "a Logger line in
      # a Delivery costume". Re-filing it as a withhold is the mistake this
      # comment exists to prevent.
      _ -> :ok
    end
  end

  # always_send bypasses the per-event toggle but still honours alerts_enabled.
  defp should_send?(%EmailSettings{alerts_enabled: false}, _event), do: false
  defp should_send?(_settings, event) when event in @always_send, do: true
  defp should_send?(settings, event), do: EmailSettings.event_enabled?(settings, event)

  # Deliver an ALERT email over the team's transport: "instance" → platform
  # adapter (no override); "smtp" → per-call gen_smtp config from the team's
  # decrypted secrets.
  #
  # cch-w52-s1: the catch-all below is the "instance" arm and NOTHING ELSE.
  # `EmailSettings.transports/0` is now exactly the set of clause heads here,
  # and `transport_manifest_test.exs` reds — in BOTH directions — if a third
  # option is ever offered without a clause, or a clause ever answers to a
  # transport nobody can select.
  defp deliver_alert(%EmailSettings{transport: "smtp"} = settings, email) do
    case smtp_override(settings) do
      {:ok, override} -> Mailer.deliver(email, override)
      :error -> Mailer.deliver(email)
    end
  end

  defp deliver_alert(_settings, email), do: Mailer.deliver(email)

  # Build the per-call Swoosh SMTP config from a team's decrypted secrets. Any
  # decrypt failure (tampered ciphertext) → :error, and the caller rides the
  # platform transport instead of leaking a half-built config.
  defp smtp_override(%EmailSettings{} = s) do
    with {:ok, relay} <- decrypt(s.smtp_host_encrypted),
         {:ok, username} <- decrypt(s.smtp_username_encrypted),
         {:ok, password} <- decrypt(s.smtp_password_encrypted) do
      {:ok,
       [
         adapter: Swoosh.Adapters.SMTP,
         relay: relay,
         username: username,
         password: password,
         port: s.smtp_port || 587,
         ssl: s.smtp_encryption == "tls",
         tls: if(s.smtp_encryption == "starttls", do: :always, else: :never),
         # VERIFY the relay certificate — gen_smtp does NOT verify unless
         # tls_options carries verify: :verify_peer + a trust store, so without
         # this an on-path attacker could terminate STARTTLS and capture the
         # team's SMTP username/password. SNI is the (dynamic) per-team relay host.
         tls_options: smtp_tls_options(relay),
         auth: :always
       ]}
    else
      _ -> :error
    end
  end

  # gen_smtp TLS options that actually VERIFY the relay's certificate chain
  # against the OS trust store (depth must be raised — gen_smtp defaults to 0 —
  # and SNI/hostname-check pinned to the relay host).
  defp smtp_tls_options(relay) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 9,
      server_name_indication: String.to_charlist(relay),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp decrypt(nil), do: :error
  defp decrypt(ciphertext) when is_binary(ciphertext), do: Vault.decrypt(ciphertext)

  @doc """
  A Team's notification deliveries, newest first (the delivery log surface).

  The second argument is a keyword list (a bare integer is still accepted and
  means `limit:`, so every pre-filter caller keeps working):

    * `:limit`   — page size, default 50. The ROUTER owns the hard cap; the
                   context stays honest about what it was asked for.
    * `:channel` — one egress channel (`"email"`, `"discord"`, …).
    * `:status`  — one send outcome (`"pending"` | `"sent"` | `"failed"`).
    * `:event`   — one event name (`"test"`, `"deploy.failed"`, …).
    * `:before`  — a `DateTime` cursor; only rows strictly older are returned
                   (keyset pagination on `inserted_at`, the `/v1/audit`
                   precedent — the log outgrew "a bounded backlog" the moment
                   filters made deep reads worth walking).
    * `:before_id` — the SECOND half of that cursor (the id of the same row the
                   `:before` stamp came from). Supplied together they page on
                   the full `(inserted_at, id)` sort key; supplied alone,
                   `:before` keeps its historical stamp-only meaning.
    * `:recipient` — the SELF-SCOPE fence: only rows addressed to this address,
                   compared CASE-INSENSITIVELY. This is what lets a plain team
                   member read the log for the sends they were actually a
                   recipient of, without seeing a colleague's. See
                   `maybe_delivery_recipient/2` for why the comparison cannot be
                   a plain `==`.

  A filter value outside the closed vocabulary is NOT rewritten or ignored: it
  is matched literally and therefore returns nothing. Silently DROPPING an
  unrecognised filter would widen the result set behind the caller's back, which
  is the one failure mode a delivery log must not have.
  """
  @spec list_deliveries(Team.t() | binary(), keyword() | pos_integer()) :: [Delivery.t()]
  def list_deliveries(team, opts \\ [])

  def list_deliveries(team, limit) when is_integer(limit),
    do: list_deliveries(team, limit: limit)

  def list_deliveries(team, opts) when is_list(opts) do
    tid = team_id(team)
    limit = opts |> Keyword.get(:limit, 50) |> max(1)

    Delivery
    |> where([d], d.team_id == ^tid)
    |> maybe_delivery_eq(:channel, opts[:channel])
    |> maybe_delivery_eq(:status, opts[:status])
    |> maybe_delivery_eq(:event, opts[:event])
    |> maybe_delivery_recipient(opts[:recipient])
    |> maybe_delivery_before(opts[:before], opts[:before_id])
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_delivery_eq(query, field, value) when is_binary(value) and value != "",
    do: where(query, [d], field(d, ^field) == ^value)

  defp maybe_delivery_eq(query, _field, _value), do: query

  # The SELF-SCOPE fence, and it is deliberately NOT `maybe_delivery_eq/3`.
  #
  # `notification_deliveries.recipient` is plain `character varying`, NOT citext.
  # The alert fan-out writes addresses that came back from `team_member_emails/1`
  # (already lowered by the citext `users.email` column), but `record_delivery/5`
  # also persists the RAW invite address straight off `invite[:to]` with no
  # downcase. A plain `d.recipient == ^user.email` therefore matches the fan-out
  # rows and silently MISSES the invite row for the same human — a short page
  # that looks exactly like "you were never emailed". Comparing on
  # `lower(recipient)` is the only version of this filter that cannot lie.
  #
  # It is a filter, not a scan risk: the `(team_id, inserted_at)` index still
  # bounds the read to one team and carries the ORDER BY; `lower(?)` is applied
  # to the rows that survive the team fence, never to the whole table.
  defp maybe_delivery_recipient(query, email) when is_binary(email) and email != "" do
    needle = String.downcase(email)
    where(query, [d], fragment("lower(?)", d.recipient) == ^needle)
  end

  defp maybe_delivery_recipient(query, _email), do: query

  # The keyset cursor, lexicographic on the SAME compound key the log is ordered
  # by — `(inserted_at DESC, id DESC)`. A stamp-only `<` is not a real page cut:
  # one fan-out writes one row per recipient in the same instant, so a boundary
  # landing mid-tie drops every tied row on the far side permanently and without
  # a trace. The tiebreak arm engages ONLY when both halves of the cursor arrive,
  # so an existing `?before=<stamp>` caller keeps byte-identical behaviour. `id`
  # is a `:binary_id`: a non-UUID from a query string is cast first (a raw binary
  # in that comparison raises Ecto.Query.CastError) and degrades to stamp-only.
  #
  # The tiebreak arm is a ROW comparator, not the equivalent OR-decomposition.
  # The two forms select the same rows; only the ROW form can SEEK. Measured on a
  # 250k-row corpus against the EXISTING `(team_id, inserted_at)` index, the OR
  # form lands in `Filter:` — `Index Cond:` carries `team_id` alone — and removes
  # ~19,380 rows to return a 50-row page (542 buffers / 4.284 ms). The ROW form
  # lets the planner lift `inserted_at <= $2` into the Index Cond and keep the id
  # half as a cheap residual: 14 buffers / 0.104 ms, on the same index, with NO
  # migration. (Adding `(team_id, inserted_at, id)` makes the OR form WORSE — 641
  # buffers — so the index is not the fix; the spelling is.) Production is only
  # ~2k rows today, so this is PROPHYLACTIC: it buys a cursor shape that stays
  # correct-and-cheap as the log grows.
  #
  # THE SPELLING IS LOAD-BEARING. `type(^ts, :utc_datetime_usec)` (and
  # `type(^ts, d.inserted_at)`) render `$2::timestamp` — a NAIVE timestamp
  # against a `timestamptz` column, which Postgres coerces through the SESSION
  # TimeZone and silently slips the boundary by the server's UTC offset. Leaving
  # `$2` UNCAST makes Postgres infer `timestamptz` from the ROW's left operand.
  # The uuid half must be `type(^uuid, Ecto.UUID)`: untyped, Ecto never dumps the
  # string and Postgrex raises "expected a binary of 16 bytes"; a `?::uuid` text
  # cast does not help, because the cast does not make Ecto dump the value. The
  # rendered SQL is `((n0."inserted_at",n0."id") < ($2,$3::uuid))`.
  #
  # NULL semantics are not a concern here even though ROW comparison differs from
  # the OR form on NULLs: `notification_deliveries.id` is the primary key and
  # `inserted_at` comes from `timestamps(type: :utc_datetime_usec)` — both NOT
  # NULL in the DDL — and both params are non-nil by the clause head (`%DateTime{}
  # = ts`) and the successful `Ecto.UUID.cast`. No NULL is reachable on either side.
  defp maybe_delivery_before(query, %DateTime{} = ts, before_id) when is_binary(before_id) do
    case Ecto.UUID.cast(before_id) do
      {:ok, uuid} ->
        where(
          query,
          [d],
          fragment("(?,?) < (?,?)", d.inserted_at, d.id, ^ts, type(^uuid, Ecto.UUID))
        )

      :error ->
        where(query, [d], d.inserted_at < ^ts)
    end
  end

  defp maybe_delivery_before(query, %DateTime{} = ts, _before_id),
    do: where(query, [d], d.inserted_at < ^ts)

  defp maybe_delivery_before(query, _before, _before_id), do: query

  @doc """
  The platform-wide FLEET-DIGEST delivery log — the Operator-console analogue of
  `list_deliveries/2`, newest first, limit-capped.

  RETRACTED (cch-w56-s3). This doc used to say fleet-digest sends are "recorded
  team-agnostic (`team_id: nil` … a platform-operator email belongs to no team)".
  That was FALSE about this module's OWN writer 420 lines above: since dr-w19-s5
  moved the audience onto team-membership rows, `deliver_fleet_digest/1` builds
  its targets under an `is_binary(team_id)` guard and the single
  `record_delivery(team_id, recipient, "fleet_digest", …)` call always stamps a
  REAL `team_id`. The nil-team fleet_digest shape is unreachable BY
  CONSTRUCTION, not merely unwritten — so the old `is_nil(d.team_id) and …`
  predicate here could never intersect the writer, and this log was empty
  forever on a fleet that mails a digest every morning (measured by dispatch:
  one real `deliver_fleet_digest/1` run wrote rows=1, this reader returned 0).

  The filter is therefore the EVENT alone. That makes this surface CROSS-TEAM:
  every team's digest receipts — including member email addresses — land on one
  page. That is the seam's existing shape (`require_platform_operator`, and
  `/v1/operator/fleet` is cross-team by name), but it is a DIFFERENT disclosure
  from the per-team tenancy ruling `deliver_fleet_digest/1`'s own doc makes
  above, so it is stated here rather than assumed.

  The `event` filter is load-bearing, not cosmetic: it is now the ONLY filter.
  Team-scoped alert rows (`past_due`, …) and user-scoped identity emails
  (password-reset / verify) share this table, and only `event == "fleet_digest"`
  keeps them out. No team-scoping arg: the route gates on
  `require_platform_operator` instead. The team-scoped `list_deliveries/2` reads
  the same rows for a team's own admins — it always could; these receipts are
  not invisible to it.
  """
  @spec list_fleet_deliveries(pos_integer()) :: [Delivery.t()]
  def list_fleet_deliveries(limit \\ 50) do
    Delivery
    |> where([d], d.event == "fleet_digest")
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> limit(^limit)
    |> Repo.all()
  end

  # Persist one send outcome. status/attempts/last_error follow the webhook
  # delivery precedent. A failed INSERT here is itself logged (never raised).
  #
  # `last_error` carries a CLASSIFIED label from `DeliveryReason`'s closed
  # vocabulary, never the raw transport term: gen_smtp's `host_failure()` names
  # the SMTP relay host in every arm, and this column is published verbatim to
  # every team admin (`Web.Router.delivery_json/1` → `app.js`) while the relay
  # host itself is Vault-sealed and masked even from the owner. The raw term
  # still goes to the operator log below — publication is what we take away,
  # not debuggability.
  defp record_delivery(team_id, recipient, event, kind, result) do
    {status, last_error} =
      case result do
        {:ok, _} ->
          {"sent", nil}

        {:error, why} ->
          Logger.warning(
            "Notifications: #{kind} #{event} send failed: #{inspect(why, limit: :infinity)}"
          )

          {"failed", DeliveryReason.summarize(why)}
      end

    %Delivery{}
    |> Delivery.changeset(%{
      team_id: team_id,
      recipient: recipient,
      event: event,
      kind: kind,
      status: status,
      attempts: 1,
      last_error: last_error
    })
    |> Repo.insert()
    |> case do
      {:ok, delivery} ->
        delivery

      # cch-w32-r2, RECEIPT LOSS — a DIFFERENT class, adjudicated here so it is
      # not mistaken for a withhold: the send above already happened, and a
      # `suppressed` row would assert the opposite of what occurred. What is
      # lost is the RECEIPT, not the notification. It is NOT routed through
      # `Withhold` and it is NOT absorbed by this row; it keeps its own filed
      # backlog task `cch-w32-bl-receipt-loss-branches-have-no-trace`, which
      # needs a trace of its own class (the same species as
      # `cch-w31-bl-auto-deploy-refusal-row-failure-leaves-no-trace`).
      {:error, changeset} ->
        Logger.error("Notifications: failed to record delivery: #{inspect(changeset.errors)}")
        nil
    end
  end

  ## ── Chat channels (notifications-chat) ───────────────────────────────────

  @doc "The chat-routing event names (strings). Drives the UI matrix + validation."
  def chat_events, do: @chat_events

  @doc "The known chat channel kinds (delegates to ChannelConfig)."
  def chat_channel_types, do: ChannelConfig.types()

  @doc "Chat events ON by default (failures). Surfaced so the UI can pre-check them."
  def chat_default_on, do: @chat_default_on

  @doc "A team's configured chat channels (credentials stay redacted, never decrypted)."
  @spec list_channels(Team.t() | binary()) :: [ChannelConfig.t()]
  def list_channels(team), do: get_or_create_settings(team).channels

  @doc """
  Upsert one chat channel's config for `team`. `creds` is a PLAINTEXT map
  (e.g. `%{"url" => "https://…"}`) sealed via `Vault.encrypt(Jason.encode!/1)`
  BEFORE it touches the changeset — the `Registry.connect_provider/3` pattern.
  Passing `creds: nil` keeps any previously-sealed credentials (a pure toggle).

  THE SSRF BOUNDARY IS HERE, at SAVE time: a `webhook` channel whose URL resolves
  to a private / loopback / link-local / cloud-metadata address is REJECTED before
  it is ever stored (`SafeUrl.check/1`), not merely at send time. `Channels.Webhook`
  re-checks at send for DNS-rebind defense in depth, but a save-time reject means a
  poisoned URL never persists in the first place.
  """
  @spec put_channel(Team.t() | binary(), String.t(), boolean(), map() | nil) ::
          {:ok, EmailSettings.t()} | {:error, Ecto.Changeset.t()}
  def put_channel(team, type, enabled, creds \\ nil) do
    settings = get_or_create_settings(team)

    with :ok <- validate_channel_url(type, creds) do
      sealed = if is_map(creds), do: Vault.encrypt(Jason.encode!(creds)), else: nil
      channels = upsert_channel(settings.channels, type, enabled, sealed)

      settings
      |> EmailSettings.chat_changeset(%{channels: channels}, @chat_events, chat_channel_types())
      |> Repo.update()
    end
  end

  # Save-time SSRF guard for the generic webhook channel. The first-party channels
  # post to known provider domains and are not user-URL-controlled, so they skip.
  defp validate_channel_url("webhook", %{"url" => url}) when is_binary(url) do
    case SafeUrl.check(url) do
      :ok -> :ok
      {:error, reason} -> {:error, channel_url_error(reason)}
    end
  end

  defp validate_channel_url(_type, _creds), do: :ok

  # An invalid changeset the router renders as 422 — a save-time SSRF/URL reject
  # never persists a poisoned webhook channel.
  defp channel_url_error(reason) do
    %EmailSettings{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:channels, "include an unsafe webhook url", reason: reason)
  end

  @doc """
  Set which channel types receive `event` for `team` (the event×channel matrix
  toggle). `channel_types` is a list of known channel-type strings.
  """
  @spec set_event_route(Team.t() | binary(), String.t(), [String.t()]) ::
          {:ok, EmailSettings.t()} | {:error, Ecto.Changeset.t()}
  def set_event_route(team, event, channel_types) when is_list(channel_types) do
    settings = get_or_create_settings(team)
    routes = Map.put(settings.event_routes || %{}, event, channel_types)

    settings
    |> EmailSettings.chat_changeset(%{event_routes: routes}, @chat_events, chat_channel_types())
    |> Repo.update()
  end

  @doc """
  The enabled chat channels that should receive `event` for this `settings` row —
  the port of Coolify's `getEnabledChannels`. Public so selection is directly
  testable. The `@chat_always_send` events (`test`, `trial_expiring`) fan to
  every enabled channel; otherwise a channel is selected only when enabled AND
  routed (explicit route, or the default-on fallback for failure events).
  """
  @spec channels_for_event(EmailSettings.t(), String.t()) :: [ChannelConfig.t()]
  def channels_for_event(%EmailSettings{channels: channels} = settings, event) do
    enabled = Enum.filter(channels || [], & &1.enabled)

    if event in @chat_always_send do
      enabled
    else
      routed_types = routed_types(settings, event, enabled)
      Enum.filter(enabled, &(&1.type in routed_types))
    end
  end

  @doc """
  Fire the always-send `test` chat event. With no `channel_type`, fans to every
  enabled chat channel (the "Send test" button); with one, targets exactly that
  channel. Enqueues one Oban job per selected channel and returns `{:ok, n}`
  where `n` is the number of channels it actually reached.

  cch-w32-s1 — TWO THINGS THIS USED TO GET WRONG.

  It returned a bare `:ok` having reached ZERO channels in three measured ways
  (no channels at all; only a disabled channel; a `channel_type` matching
  nothing), and its only caller rendered an unconditional `202 {ok: true}` — so
  a fan-out to nobody reported as accepted to the console, to `bp`, to curl.
  The count is the honest answer, and a `queued: 0` is a visible one.

  And it deliberately BYPASSES `enqueue_chat/3`'s `alerts_enabled: false`
  clause, which is correct and stays: this is a TRANSPORT probe (does the
  credential/URL work), not a POLICY probe. Refusing while muted would destroy
  the only instrument separating "my webhook URL is wrong" from "I muted alerts
  three weeks ago", and would read as "your channel is broken" — a new lie for
  an old one. `deliver_test/2`, the EMAIL test, bypasses `alerts_enabled` the
  same way. So the mute is not a refusal here; it TRAVELS WITH THE MESSAGE:
  the payload carries `alerts_muted`, and `Render.render/2`'s `test` arm
  discloses it on the wire.
  """
  @spec send_test_chat(Team.t() | binary(), String.t() | nil) ::
          {:ok, non_neg_integer()}
  def send_test_chat(team, channel_type \\ nil) do
    settings = get_or_create_settings(team)
    payload = %{alerts_muted: settings.alerts_enabled == false}

    queued =
      settings
      |> channels_for_event("test")
      |> Enum.filter(fn cfg -> is_nil(channel_type) or cfg.type == channel_type end)
      |> Enum.count(fn cfg ->
        match?({:ok, _}, enqueue_channel(settings.team_id, cfg, "test", payload))
      end)

    {:ok, queued}
  end

  @doc """
  Deliver ONE chat notification synchronously — the body of the Oban worker's
  `perform/1`. Reloads the team's channel of `type`, reveals its sealed
  credentials in-process, shapes the provider envelope, and POSTs via the
  verified-TLS `Billing.HttpClient` (no autoredirect — 3xx is not followed).

  Returns `:ok` on a 2xx (delivery logged), `{:cancel, reason}` on a terminal
  failure that must NOT retry (4xx, bad credentials, SSRF block, missing channel),
  or `{:error, reason}` on a retryable failure (5xx / transport) so Oban re-drives
  with the worker's fixed backoff. A gone channel is a terminal no-op.
  """
  @spec deliver_chat(binary(), String.t(), String.t(), map()) ::
          :ok | {:cancel, term()} | {:error, term()}
  def deliver_chat(team_id, type, event, payload) do
    settings = get_or_create_settings(team_id)

    case Enum.find(settings.channels || [], &(&1.type == type and &1.enabled)) do
      nil ->
        # cch-w32-r2: the purest silent withhold in the rail — the job existed,
        # ran, and vanished with neither a row nor a log. The channel was
        # removed or switched off AFTER this alert was already queued for it, so
        # the alert was decided and then dropped; that is the system's decision,
        # not the team's toggle, and it is now readable per member.
        Withhold.record(team_id, event, :chat_channel_gone, channel: type)

        {:cancel, :channel_gone}

      %ChannelConfig{} = cfg ->
        do_deliver_chat(team_id, cfg, event, payload)
    end
  end

  defp do_deliver_chat(team_id, %ChannelConfig{type: type} = cfg, event, payload) do
    with {:ok, creds} <- reveal_credentials(cfg),
         {:ok, url, body, headers} <- shape(type, creds, event, payload, team_id: team_id) do
      post_chat(team_id, type, event, url, body, headers)
    else
      {:error, reason} ->
        log_chat_delivery(team_id, type, event, "failed", nil, reason)
        {:cancel, reason}
    end
  end

  # PURE envelope builder — dispatch on channel `type` to the right shaper. The
  # generic `webhook` type is the only one routed through `SafeUrl` (send-time
  # DNS-rebind defense, inside `Channels.Webhook`).
  defp shape(type, creds, event, payload, opts) do
    case type do
      "discord" -> Channels.Discord.shape(creds, event, payload)
      "slack" -> Channels.Slack.shape(creds, event, payload)
      "telegram" -> Channels.Telegram.shape(creds, event, payload)
      "pushover" -> Channels.Pushover.shape(creds, event, payload)
      "webhook" -> Channels.Webhook.shape(creds, event, payload, opts)
      other -> {:error, {:unknown_channel, other}}
    end
  end

  defp post_chat(team_id, type, event, url, body, headers) do
    req = %{method: :post, url: url, headers: headers, body: to_string(body)}

    case chat_http_client().request(req) do
      {:ok, %{status: status}} when status in 200..299 ->
        log_chat_delivery(team_id, type, event, "sent", status, nil)
        :ok

      {:ok, %{status: status}} when status in 400..499 ->
        # 4xx is terminal — a bad URL / revoked token won't fix itself on retry.
        log_chat_delivery(team_id, type, event, "failed", status, {:http_status, status})
        {:cancel, {:http_4xx, status}}

      {:ok, %{status: status}} ->
        log_chat_delivery(team_id, type, event, "failed", status, {:http_status, status})
        {:error, {:http_status, status}}

      {:error, reason} ->
        log_chat_delivery(team_id, type, event, "failed", nil, reason)
        {:error, reason}
    end
  end

  # Decrypt a channel's sealed credentials on demand — never a stored plaintext.
  defp reveal_credentials(%ChannelConfig{credentials_encrypted: ct})
       when is_binary(ct) and ct != "" do
    with {:ok, json} <- Vault.decrypt(ct),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :bad_credentials}
    end
  end

  defp reveal_credentials(_), do: {:error, :missing_credentials}

  # Select + enqueue one Oban job per routed chat channel. Best-effort: never
  # raises into dispatch_event's caller (the rescue there is the final backstop).
  defp enqueue_chat(%EmailSettings{alerts_enabled: false}, _event, _payload), do: :ok

  defp enqueue_chat(%EmailSettings{} = settings, event, payload) do
    selected = channels_for_event(settings, event)

    withheld =
      selected
      |> Enum.reject(fn cfg ->
        match?({:ok, _}, enqueue_channel(settings.team_id, cfg, event, payload))
      end)
      |> Enum.map(& &1.type)

    # cch-w32-s1: a decided-but-never-enqueued notification reaches nobody, with
    # no delivery row and (until now) no log at all — the enqueue result was
    # discarded inside a bare `for`. `enqueue_channel/4` logs each failure with
    # its team/channel/event; this second line states the SHAPE of the fan-out,
    # so "3 channels selected, 1 never enqueued" is readable as one fact rather
    # than reconstructed from three scattered lines.
    #
    # cch-w32-r2: s1 stopped the result being DISCARDED, but the failure was
    # still only a LOG — a chat alert that was decided, selected and never
    # enqueued produced zero `Delivery` rows, so the person it was for read a
    # delivery log byte-identical to "no alert was ever triggered". One
    # suppressed row per member per never-enqueued channel is the fix; the log
    # stays for the operator, the row is for the team.
    if withheld != [] do
      Logger.error(
        "Notifications: chat fan-out for #{event} enqueued " <>
          "#{length(selected) - length(withheld)}/#{length(selected)} channels " <>
          "(team #{settings.team_id})"
      )

      Enum.each(withheld, fn type ->
        Withhold.record(settings.team_id, event, :chat_enqueue_failed, channel: type)
      end)
    end

    :ok
  end

  # Enqueue one channel's delivery. Args are JSON-safe (no plaintext creds — the
  # worker reloads + decrypts the channel by type at perform time).
  #
  # Returns `{:ok, job}` / `{:error, reason}` so every caller can ACCOUNT for the
  # insert. It used to end `|> Oban.insert()` inside a bare `for` with the result
  # dropped on the floor, which made a failed insert indistinguishable from a
  # delivered notification at every level above it.
  defp enqueue_channel(team_id, %ChannelConfig{type: type}, event, payload) do
    %{team_id: team_id, channel_type: type, event: event, payload: json_safe(payload)}
    |> ChatNotificationWorker.new()
    |> insert_job()
    |> case do
      {:ok, %Oban.Job{}} = ok ->
        ok

      other ->
        reason =
          case other do
            {:error, reason} -> reason
            other -> other
          end

        Logger.error(
          "Notifications: chat enqueue FAILED for team #{team_id} channel #{type} " <>
            "event #{event}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # The JOB-QUEUE seam, the twin of `chat_http_client/0` below. `Oban.insert/1`
  # stays literal on the real path; a test may substitute a client through
  # `config :barkpark_cloud, :notifications_job_client`.
  #
  # cch-w32-r2: this exists because the enqueue-FAILED withhold cannot otherwise
  # be driven. Every in-sandbox way to make this insert fail RAISES (a
  # non-JSON-encodable arg, a stopped Oban) rather than returning `{:error, _}`,
  # and a raise is `dispatch_event/3`'s rescue arm — a DIFFERENT branch with a
  # different row. Without the seam the `{:error, _}` arm would be asserted only
  # by reading it, which is exactly the vacuous green this epic exists to refuse.
  defp insert_job(changeset) do
    case Application.get_env(:barkpark_cloud, :notifications_job_client) do
      nil -> Oban.insert(changeset)
      client -> client.insert(changeset)
    end
  end

  # dispatch_event payloads carry atom keys/values; Oban args must be JSON-safe.
  defp json_safe(payload) when is_map(payload) do
    Map.new(payload, fn {k, v} -> {to_string_key(k), json_safe_value(v)} end)
  end

  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_key(k), do: to_string(k)

  defp json_safe_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp json_safe_value(v) when is_map(v), do: json_safe(v)
  defp json_safe_value(v), do: v

  # Best-effort chat delivery log into the shared notification_deliveries table.
  # A failed insert here is swallowed — a delivery LOG must never break a delivery.
  #
  # `reason` is the RAW transport term (or nil on success); the classification to
  # `DeliveryReason`'s closed vocabulary happens HERE, at the write seam, so no
  # caller can route around it. `:httpc`'s `{:failed_connect, [{:to_address,
  # {host, port}}, …]}` names the destination host and port — that term goes to
  # the operator log, never to the published row.
  defp log_chat_delivery(team_id, type, event, status, http_status, reason) do
    if reason != nil do
      Logger.warning(
        "Notifications: chat #{type} #{event} failed: #{inspect(reason, limit: :infinity)}"
      )
    end

    last_error = DeliveryReason.summarize(reason)

    %Delivery{}
    |> Delivery.changeset(%{
      team_id: team_id,
      recipient: type,
      channel: type,
      event: event,
      kind: "alert",
      status: status,
      http_status: http_status,
      attempts: 1,
      last_error: last_error
    })
    |> Repo.insert()
    |> case do
      {:ok, delivery} ->
        delivery

      # cch-w32-r2, RECEIPT LOSS — the chat twin of `record_delivery/5`'s arm
      # above, and adjudicated identically: the POST already returned, so this
      # is a lost receipt, not a withheld notification. Not routed through
      # `Withhold`; still owned by `cch-w32-bl-receipt-loss-branches-have-no-trace`.
      {:error, changeset} ->
        Logger.error(
          "Notifications: failed to record chat delivery: #{inspect(changeset.errors)}"
        )

        nil
    end
  end

  # Which channel TYPES are routed for `event`: an explicit route wins; otherwise
  # default-on events fan to every enabled channel, default-off events to none.
  defp routed_types(%EmailSettings{event_routes: routes}, event, enabled) do
    case Map.fetch(routes || %{}, event) do
      {:ok, list} when is_list(list) -> list
      _ -> if event in @chat_default_on, do: Enum.map(enabled, & &1.type), else: []
    end
  end

  # Replace the channel of `type` (preserving prior ciphertext when no new creds),
  # or append a new one. Returns attr maps ready for cast_embed.
  defp upsert_channel(channels, type, enabled, sealed) do
    existing = Enum.map(channels || [], &channel_to_attrs/1)

    if Enum.any?(existing, &(&1.type == type)) do
      Enum.map(existing, fn attrs ->
        if attrs.type == type do
          %{
            attrs
            | enabled: enabled,
              credentials_encrypted: sealed || attrs.credentials_encrypted
          }
        else
          attrs
        end
      end)
    else
      existing ++ [%{type: type, enabled: enabled, credentials_encrypted: sealed}]
    end
  end

  defp channel_to_attrs(%ChannelConfig{} = c) do
    %{type: c.type, enabled: c.enabled, credentials_encrypted: c.credentials_encrypted}
  end

  # Transport seam — swappable in tests via
  # `config :barkpark_cloud, :notifications_http_client, FakeClient`.
  defp chat_http_client do
    Application.get_env(
      :barkpark_cloud,
      :notifications_http_client,
      BarkparkCloud.Billing.HttpClient
    )
  end

  ## ── Recipients ───────────────────────────────────────────────────────────

  # Recipients are ALWAYS the team's members — the exfiltration guard. Reads
  # through Accounts so the membership join stays in the identity context.
  defp team_member_emails(team_id), do: Accounts.list_team_member_emails(team_id)

  # cch-w42-s6: what each of those addresses may DO on the team, as
  # `%{email => role}`. Deliberately a SEPARATE read from the recipient list
  # above: the audience is still exactly `list_team_member_emails/1` with no role
  # predicate, so nothing here can narrow who is told. It only lets the renderer
  # stop prescribing an owner-only remedy to someone the door would refuse.
  #
  # `Accounts.list_team_members/1` already selects the role — no new query shape,
  # no migration. An address missing from this map (impossible today; both reads
  # are the same join) renders as NOT an owner, which is the honest direction.
  defp team_member_roles(team_id) do
    team_id
    |> Accounts.list_team_members()
    |> Map.new(fn %{user: user, role: role} -> {user.email, role} end)
  end

  ## ── Helpers ──────────────────────────────────────────────────────────────

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id

  # Stringify atom keys so a handler can pass either an atom-keyed map (tests) or
  # a string-keyed `conn.body_params` (the router) without ceremony.
  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
