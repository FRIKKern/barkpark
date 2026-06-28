defmodule Barkpark.Plugins.SettingsRecord do
  @moduledoc """
  The persisted plugin-settings row (`plugin_settings`, keyed by `plugin_name`).
  The `settings` map is encrypted at rest via `Barkpark.EncryptedMap`;
  `updated_by` records who last wrote it. Access is logged separately by
  `Barkpark.Plugins.SettingsAudit`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:plugin_name, :string, autogenerate: false}
  schema "plugin_settings" do
    field :settings, Barkpark.EncryptedMap
    field :updated_at, :utc_datetime_usec
    field :updated_by, :string
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:plugin_name, :settings, :updated_at, :updated_by])
    |> validate_required([:plugin_name, :settings, :updated_at])
  end
end
