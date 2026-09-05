defmodule BarkparkCloud.Notifications.EmailSettings do
  @moduledoc """
  A Team's email-notification preferences — one row per Team. The Cloud analogue
  of Coolify's `EmailNotificationSettings` model
  (`app/Models/EmailNotificationSettings.php`), and a structural twin of
  `BarkparkCloud.Registry.Provider`: team-owned, secret columns hold CIPHERTEXT
  only (every `*_encrypted` field is `redact: true`), and the context encrypts
  the plaintext via `BarkparkCloud.Registry.Vault.encrypt/1` BEFORE this
  changeset ever sees it.

  ## Transport

  `transport` selects how this team's ALERT emails leave:

    * `"instance"` — ride the platform `BarkparkCloud.Mailer` (the default; no
      per-team SMTP needed).
    * `"smtp"`     — the per-team SMTP relay in the `smtp_*` columns.

  cch-w52-s1 — there is no third option. `"api"` was offered by this schema, by
  the console's segmented control and by a Vault-encrypted `api_key_encrypted`
  column for as long as they existed, and NOTHING carried it: `deliver_alert/2`
  has an `smtp` clause and a catch-all, there is no Swoosh adapter beyond
  Local/Test/SMTP, and `config.exs` sets `:swoosh, :api_client, false`. An
  "api" team's alert rode the platform mailer and was logged `sent`. The offer
  is deleted rather than disclosed (charter D589; live prod carried zero such
  rows). The schema FIELD goes now so the column drop can follow safely — Ecto
  selects the full field list, so the field must stop being selected BEFORE the
  column is dropped (D594; the migration is cch-w52-s3's).
  `transport_manifest_test.exs` reds if an option ever outruns its mechanism
  again.

  Transactional identity email (invite / reset / verify) NEVER consults this —
  it always rides the platform transport (see `Notifications.Transactional`).

  ## Event toggles

  Each `@events` column gates one alert. Failures default ON, successes default
  OFF (Coolify's alert-hygiene rule). `event_enabled?/2` is the gate the
  dispatcher consults — it also short-circuits to false when `alerts_enabled` is
  off, so a team can mute everything with one switch.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias BarkparkCloud.Notifications.ChannelConfig

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @transports ~w(instance smtp)
  @encryptions ~w(starttls tls none)

  # The per-event toggle columns, in one list so the dispatcher and the
  # changeset share a single source of truth.
  #
  # WAVE 30 S1 — SIX, NOT NINE. `deployment_succeeded`, `member_invited` and
  # `token_expiring` were toggles for events NOTHING in `cloud/lib` dispatches;
  # the console rendered all three as promises, and `token_expiring` defaulted
  # ON. They are dropped (migration
  # `20260804123000_drop_producerless_notification_events`) rather than wired:
  # `dispatch_event/3` fans to `team_member_emails/1`, so a token-expiry
  # producer would mail one user's credential schedule to the whole team. The
  # missing alerts are filed as feature work, not left standing as offers.
  # Every atom here MUST have a producer — `__app.test.mjs`'s bidirectional
  # notification census reds the Console gate otherwise.
  #
  # cch-w29-bl — SEVEN. `deployment_refused` is the auto-deploy PREBUILT refusal
  # (`Sites.AutoDeployWorker.refuse/1`). It lands in the SAME change as its
  # producer, its console row, its render arms and its migration, because a
  # toggle that reaches a person before its dispatcher does is exactly the
  # promise-with-no-mechanism wave 30 deleted three columns to kill. It defaults
  # ON: it is a FAILURE (a publish that did not deploy), and the moduledoc's
  # rule above is failures-on / successes-off.
  #
  # cch-w30-bl — EIGHT. `deployment_succeeded` comes BACK, and only because the
  # thing wave 30 said it lacked now exists: `Registry`'s
  # `dispatch_deployment_terminal/2` fires it on the EDGE into `live` from BOTH
  # writers that can land that terminal — the fenced one and the
  # `with_site_update` one `Sites.Deploy.settle_live/2` drives on every static
  # build. The comment above says "the deployment-success terminal is written by
  # `Sites.Deploy.settle_live/2`, which legally re-reports live"; that re-report
  # is handled, by an edge guard on the PRIOR status, not by leaving the toggle
  # deleted. It defaults OFF — it is a SUCCESS, and the rule above is
  # failures-on / successes-off.
  @events ~w(provision_succeeded provision_failed
             deployment_succeeded deployment_failed deployment_refused
             agent_reachable agent_unreachable
             subscription_past_due)a

  schema "email_notification_settings" do
    field :transport, :string, default: "instance"
    field :alerts_enabled, :boolean, default: true

    field :smtp_host_encrypted, :string, redact: true
    field :smtp_username_encrypted, :string, redact: true
    field :smtp_password_encrypted, :string, redact: true
    field :smtp_port, :integer
    field :smtp_encryption, :string
    field :from_address, :string
    field :from_name, :string

    field :provision_succeeded, :boolean, default: false
    field :provision_failed, :boolean, default: true
    field :deployment_succeeded, :boolean, default: false
    field :deployment_failed, :boolean, default: true
    field :deployment_refused, :boolean, default: true
    field :agent_reachable, :boolean, default: false
    field :agent_unreachable, :boolean, default: true
    field :subscription_past_due, :boolean, default: true

    field :last_test_sent_at, :utc_datetime_usec

    # notifications-chat: chat egress folded onto the same per-team row. `channels`
    # is a jsonb array of ChannelConfig embeds (type/enabled/sealed-creds);
    # `event_routes` is a jsonb map of event_name => [channel_type, …]. Selection
    # lives in `Notifications.channels_for_event/2`.
    embeds_many :channels, ChannelConfig, on_replace: :delete
    field :event_routes, :map, default: %{}

    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The list of per-event toggle columns (atoms)."
  def events, do: @events

  @doc "The accepted transport strings."
  def transports, do: @transports

  @doc """
  True iff the alert channel is on AND this event's per-event toggle is set.
  An unknown event is always false (never sends on a name nobody opted into).
  """
  @spec event_enabled?(t(), atom()) :: boolean()
  def event_enabled?(%__MODULE__{alerts_enabled: false}, _event), do: false

  def event_enabled?(%__MODULE__{} = settings, event) when event in @events,
    do: Map.fetch!(settings, event)

  def event_enabled?(_settings, _event), do: false

  @doc """
  Changeset for the settings ROW. Secret fields are expected ALREADY-ciphertext —
  the context (`Notifications.update_settings/2`) encrypts the plaintext before
  building this changeset, mirroring `Registry.connect_provider/3`.
  """
  def changeset(settings, attrs) do
    settings
    |> cast(
      attrs,
      [
        :team_id,
        :transport,
        :alerts_enabled,
        :smtp_host_encrypted,
        :smtp_username_encrypted,
        :smtp_password_encrypted,
        :smtp_port,
        :smtp_encryption,
        :from_address,
        :from_name,
        :last_test_sent_at
      ] ++ @events
    )
    |> validate_required([:team_id, :transport])
    |> validate_inclusion(:transport, @transports)
    |> validate_inclusion(:smtp_encryption, @encryptions)
    |> validate_number(:smtp_port, greater_than: 0, less_than: 65_536)
    |> validate_format(:from_address, ~r/^[^\s@]+@[^\s@]+$/u, message: "must be a valid email")
    |> assoc_constraint(:team)
    |> unique_constraint(:team_id)
  end

  @doc """
  notifications-chat: changeset for the CHAT half of the row — `channels`
  (embedded, each validated by `ChannelConfig.changeset/2`) and `event_routes`
  (validated so every key is a known event and every value a known channel type).
  Separate from `changeset/2` so an email settings PUT never has to carry chat
  fields and vice-versa. `valid_events` / `valid_channel_types` are passed in so
  the vocabulary stays owned by the `Notifications` context.
  """
  def chat_changeset(settings, attrs, valid_events, valid_channel_types) do
    settings
    |> cast(attrs, [:team_id, :event_routes])
    |> cast_embed(:channels)
    |> validate_required([:team_id])
    |> validate_event_routes(valid_events, valid_channel_types)
    |> assoc_constraint(:team)
    |> unique_constraint(:team_id)
  end

  # event_routes must be %{event => [channel_type, …]} where every key is a known
  # event and every listed channel type is known. Keeps the routing map honest so
  # the dispatcher never reads a route pointing at a phantom event/channel.
  defp validate_event_routes(changeset, valid_events, valid_channel_types) do
    case get_change(changeset, :event_routes) do
      nil ->
        changeset

      routes when is_map(routes) ->
        bad_event = Enum.find(Map.keys(routes), &(&1 not in valid_events))

        bad_channel =
          routes
          |> Map.values()
          |> List.flatten()
          |> Enum.find(&(&1 not in valid_channel_types))

        cond do
          bad_event ->
            add_error(changeset, :event_routes, "name an unknown event: #{inspect(bad_event)}")

          bad_channel ->
            add_error(
              changeset,
              :event_routes,
              "name an unknown channel: #{inspect(bad_channel)}"
            )

          true ->
            changeset
        end

      _ ->
        add_error(changeset, :event_routes, "must be a map of event => [channel_type]")
    end
  end
end
