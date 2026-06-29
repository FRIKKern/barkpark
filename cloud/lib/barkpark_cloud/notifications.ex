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
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo

  alias BarkparkCloud.Notifications.{Delivery, EmailSettings, EventEmail, Transactional}

  # Events that bypass the per-event toggle (Coolify's `$alwaysSendEvents`) — but
  # still respect `alerts_enabled`. Pruned from Coolify's PaaS set (no
  # ssl_certificate_renewal / server_force_* — those are out of scope here).
  @always_send ~w(test general)a

  # Seconds a team must wait between "send test" presses (Coolify's 10s/team).
  @test_rate_limit_seconds 10

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
  secret keys (`smtp_host` / `smtp_username` / `smtp_password` / `api_key`) are run
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
      |> put_encrypted("api_key", :api_key_encrypted, attrs)
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
        api_key: mask(s.api_key_encrypted),
        from_address: s.from_address,
        from_name: s.from_name,
        last_test_sent_at: s.last_test_sent_at
      },
      event_view
    )
  end

  defp mask(nil), do: nil
  defp mask(""), do: nil
  defp mask(_ciphertext), do: "********"

  ## ── Transactional (the beta blocker) ─────────────────────────────────────

  @doc "Deliver a team-invite email over the PLATFORM transport. See `Transactional`."
  def deliver_invite(invite), do: Transactional.deliver_invite(invite)

  @doc "Deliver a password-reset email over the PLATFORM transport."
  def deliver_password_reset(to, url), do: Transactional.deliver_password_reset(to, url)

  @doc "Deliver an email-verification email over the PLATFORM transport."
  def deliver_email_verification(to, url), do: Transactional.deliver_email_verification(to, url)

  @doc """
  Send the settings page's test email, rate-limited to one per
  `#{@test_rate_limit_seconds}`s per team (Coolify `Email.php`'s 10s guard,
  enforced here via `last_test_sent_at`).

  `to` defaults to nil → the first team member's email. Returns `{:ok, term}`,
  `{:error, {:rate_limited, seconds_remaining}}`, or `{:error, :no_recipient}`.
  """
  @spec deliver_test(Team.t() | binary(), String.t() | nil) ::
          {:ok, term()} | {:error, {:rate_limited, non_neg_integer()} | :no_recipient | term()}
  def deliver_test(team, to \\ nil) do
    settings = get_or_create_settings(team)

    case test_rate_limit_remaining(settings) do
      0 ->
        recipient = to || first_member_email(settings.team_id)

        if is_binary(recipient) do
          result = Transactional.deliver_test(recipient)
          _ = stamp_test_sent(settings)
          record_delivery(settings.team_id, recipient, "test", "transactional", result)
          result
        else
          {:error, :no_recipient}
        end

      remaining ->
        {:error, {:rate_limited, remaining}}
    end
  end

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
      for recipient <- team_member_emails(settings.team_id) do
        email = EventEmail.build(settings, event, payload, recipient)
        result = deliver_alert(settings, email)
        record_delivery(settings.team_id, recipient, Atom.to_string(event), "alert", result)
      end
    end

    :ok
  rescue
    # The dispatcher is wired into broadcast paths that must never fail because
    # email did. Log and swallow — the SSE signal still goes out.
    error ->
      Logger.error("Notifications.dispatch_event/3 crashed: #{Exception.message(error)}")
      :ok
  end

  # always_send bypasses the per-event toggle but still honours alerts_enabled.
  defp should_send?(%EmailSettings{alerts_enabled: false}, _event), do: false
  defp should_send?(_settings, event) when event in @always_send, do: true
  defp should_send?(settings, event), do: EmailSettings.event_enabled?(settings, event)

  # Deliver an ALERT email over the team's transport: "instance" → platform
  # adapter (no override); "smtp" → per-call gen_smtp config from the team's
  # decrypted secrets; "api" → deferred, falls back to the platform transport so
  # the alert still goes out rather than silently dropping.
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
         auth: :always
       ]}
    else
      _ -> :error
    end
  end

  defp decrypt(nil), do: :error
  defp decrypt(ciphertext) when is_binary(ciphertext), do: Vault.decrypt(ciphertext)

  @doc "A Team's notification deliveries, newest first (the delivery log surface)."
  @spec list_deliveries(Team.t() | binary(), pos_integer()) :: [Delivery.t()]
  def list_deliveries(team, limit \\ 50) do
    tid = team_id(team)

    Delivery
    |> where([d], d.team_id == ^tid)
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> limit(^limit)
    |> Repo.all()
  end

  # Persist one send outcome. status/attempts/last_error follow the webhook
  # delivery precedent. A failed INSERT here is itself logged (never raised).
  defp record_delivery(team_id, recipient, event, kind, result) do
    {status, last_error} =
      case result do
        {:ok, _} -> {"sent", nil}
        {:error, why} -> {"failed", inspect(why)}
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

      {:error, changeset} ->
        Logger.error("Notifications: failed to record delivery: #{inspect(changeset.errors)}")
        nil
    end
  end

  ## ── Recipients ───────────────────────────────────────────────────────────

  # Recipients are ALWAYS the team's members — the exfiltration guard. Reads
  # through Accounts so the membership join stays in the identity context.
  defp team_member_emails(team_id), do: Accounts.list_team_member_emails(team_id)

  defp first_member_email(team_id), do: team_id |> team_member_emails() |> List.first()

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
