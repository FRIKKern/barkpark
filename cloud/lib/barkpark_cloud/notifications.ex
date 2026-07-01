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
  alias BarkparkCloud.Workers.ChatNotificationWorker

  alias BarkparkCloud.Notifications.{
    ChannelConfig,
    Channels,
    Delivery,
    EmailSettings,
    EventEmail,
    SafeUrl,
    Transactional
  }

  # Events that bypass the per-event toggle (Coolify's `$alwaysSendEvents`) — but
  # still respect `alerts_enabled`. Pruned from Coolify's PaaS set (no
  # ssl_certificate_renewal / server_force_* — those are out of scope here).
  @always_send ~w(test general)a

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
  @chat_always_send ~w(test)

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
        last_test_sent_at: s.last_test_sent_at,
        # notifications-chat: the chat half. Credentials are NEVER serialized —
        # each channel reports only type, enabled, and whether creds are configured.
        channels: chat_channels_view(s.channels),
        event_routes: s.event_routes || %{},
        chat_events: @chat_events,
        channel_types: chat_channel_types(),
        chat_default_on: @chat_default_on
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

  @doc "Deliver a team-invite email over the PLATFORM transport. See `Transactional`."
  def deliver_invite(invite), do: Transactional.deliver_invite(invite)

  @doc "Deliver a password-reset email over the PLATFORM transport."
  def deliver_password_reset(to, url), do: Transactional.deliver_password_reset(to, url)

  @doc "Deliver an email-verification email over the PLATFORM transport."
  def deliver_email_verification(to, url), do: Transactional.deliver_email_verification(to, url)

  @doc "Deliver a verified-email-change 6-digit code over the PLATFORM transport."
  def deliver_email_change_code(to, code), do: Transactional.deliver_email_change_code(to, code)

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
    |> Ecto.Changeset.add_error(:channels, "unsafe webhook url", reason: reason)
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
  testable. The `@chat_always_send` events (`test`) fan to every enabled channel;
  otherwise a channel is selected only when enabled AND routed (explicit route, or
  the default-on fallback for failure events).
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
  channel. Enqueues one Oban job per selected channel; returns `:ok`.
  """
  @spec send_test_chat(Team.t() | binary(), String.t() | nil) :: :ok
  def send_test_chat(team, channel_type \\ nil) do
    settings = get_or_create_settings(team)

    settings
    |> channels_for_event("test")
    |> Enum.filter(fn cfg -> is_nil(channel_type) or cfg.type == channel_type end)
    |> Enum.each(&enqueue_channel(settings.team_id, &1, "test", %{}))

    :ok
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
        log_chat_delivery(team_id, type, event, "failed", nil, inspect(reason))
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
        log_chat_delivery(team_id, type, event, "failed", status, "http #{status}")
        {:cancel, {:http_4xx, status}}

      {:ok, %{status: status}} ->
        log_chat_delivery(team_id, type, event, "failed", status, "http #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        log_chat_delivery(team_id, type, event, "failed", nil, inspect(reason))
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
    for cfg <- channels_for_event(settings, event) do
      enqueue_channel(settings.team_id, cfg, event, payload)
    end

    :ok
  end

  # Enqueue one channel's delivery. Args are JSON-safe (no plaintext creds — the
  # worker reloads + decrypts the channel by type at perform time).
  defp enqueue_channel(team_id, %ChannelConfig{type: type}, event, payload) do
    %{team_id: team_id, channel_type: type, event: event, payload: json_safe(payload)}
    |> ChatNotificationWorker.new()
    |> Oban.insert()
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
  defp log_chat_delivery(team_id, type, event, status, http_status, last_error) do
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
