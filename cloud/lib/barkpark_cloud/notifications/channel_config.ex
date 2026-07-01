defmodule BarkparkCloud.Notifications.ChannelConfig do
  @moduledoc """
  One enabled-or-not chat channel inside a team's `notification_settings.channels`
  jsonb array. Embedded (not a table) — the whole array is one column, so adding a
  channel kind is a code change, never a migration.

  ## The credentials never touch the DB in plaintext

  `credentials_encrypted` holds the Base64 of `BarkparkCloud.Registry.Vault.encrypt/1`
  over a `Jason`-encoded credentials map — NEVER the plaintext webhook URL / bot
  token / user key. The CONTEXT (`BarkparkCloud.Notifications.put_channel/4`) seals
  the plaintext before it ever reaches this changeset, exactly the way
  `Registry.connect_provider/3` seals a provider token. The field is `redact: true`
  so it stays out of logs / `inspect` (mirrors `Registry.Provider.encrypted_token`).

  Credential shape per type (the plaintext map, before sealing):

      discord  | slack | webhook : %{"url" => "https://…"}
      telegram                   : %{"token" => "…", "chat_id" => "…", "thread_id" => "…"?}
      pushover                   : %{"user_key" => "…", "api_token" => "…"}
  """
  use Ecto.Schema
  import Ecto.Changeset

  # The channel kinds we know how to shape an envelope for. A list (not a free
  # string) so a typo can't create a dead channel; grow it when a sixth shaper
  # actually lands.
  @types ~w(discord slack telegram pushover webhook)

  @primary_key false
  embedded_schema do
    field :type, :string
    field :enabled, :boolean, default: false
    # Ciphertext (Base64 of Vault.encrypt/1 output) — never the plaintext creds.
    field :credentials_encrypted, :string, redact: true
  end

  @type t :: %__MODULE__{}

  @doc "The channel kinds with a shaper. Used by the changeset and the context."
  def types, do: @types

  @doc """
  Changeset for one channel entry. `type` is required and must be a known kind;
  `credentials_encrypted` is expected to ALREADY be ciphertext (the context seals
  the plaintext first). A channel cannot be `enabled` until its credentials are
  sealed — otherwise the dispatcher would select a channel it can't deliver to.
  """
  def changeset(cfg, attrs) do
    cfg
    |> cast(attrs, [:type, :enabled, :credentials_encrypted])
    |> validate_required([:type])
    |> validate_inclusion(:type, @types)
    |> validate_enabled_has_credentials()
  end

  # An enabled channel with no sealed credentials is a misconfiguration: the
  # dispatcher would select it and then fail to build an envelope. Block it at the
  # changeset so the invalid state can never reach the DB.
  defp validate_enabled_has_credentials(changeset) do
    enabled? = get_field(changeset, :enabled)
    creds = get_field(changeset, :credentials_encrypted)

    if enabled? and (is_nil(creds) or creds == "") do
      add_error(changeset, :credentials_encrypted, "must be set before enabling the channel")
    else
      changeset
    end
  end
end
