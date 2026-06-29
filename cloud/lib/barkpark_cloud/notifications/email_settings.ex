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
    * `"api"`      — a hosted-provider key (the adapter itself is deferred).

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

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @transports ~w(instance smtp api)
  @encryptions ~w(starttls tls none)

  # The per-event toggle columns, in one list so the dispatcher and the
  # changeset share a single source of truth.
  @events ~w(provision_succeeded provision_failed deployment_succeeded
             deployment_failed agent_reachable agent_unreachable
             subscription_past_due member_invited token_expiring)a

  schema "email_notification_settings" do
    field :transport, :string, default: "instance"
    field :alerts_enabled, :boolean, default: true

    field :smtp_host_encrypted, :string, redact: true
    field :smtp_username_encrypted, :string, redact: true
    field :smtp_password_encrypted, :string, redact: true
    field :smtp_port, :integer
    field :smtp_encryption, :string
    field :api_key_encrypted, :string, redact: true
    field :from_address, :string
    field :from_name, :string

    field :provision_succeeded, :boolean, default: false
    field :provision_failed, :boolean, default: true
    field :deployment_succeeded, :boolean, default: false
    field :deployment_failed, :boolean, default: true
    field :agent_reachable, :boolean, default: false
    field :agent_unreachable, :boolean, default: true
    field :subscription_past_due, :boolean, default: true
    field :member_invited, :boolean, default: false
    field :token_expiring, :boolean, default: true

    field :last_test_sent_at, :utc_datetime_usec

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
        :api_key_encrypted,
        :from_address,
        :from_name,
        :last_test_sent_at
      ] ++ @events
    )
    |> validate_required([:team_id, :transport])
    |> validate_inclusion(:transport, @transports)
    |> validate_inclusion(:smtp_encryption, @encryptions)
    |> validate_number(:smtp_port, greater_than: 0, less_than: 65_536)
    |> validate_format(:from_address, ~r/^[^\s@]+@[^\s@]+$/, message: "must be a valid email")
    |> assoc_constraint(:team)
    |> unique_constraint(:team_id)
  end
end
