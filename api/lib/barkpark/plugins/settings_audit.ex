defmodule Barkpark.Plugins.SettingsAudit do
  use Ecto.Schema
  import Ecto.Changeset

  schema "plugin_settings_audit" do
    field :plugin_name, :string
    field :action, :string
    field :user_id, :string
    field :occurred_at, :utc_datetime_usec
  end

  def changeset(rec, attrs) do
    rec
    |> cast(attrs, [:plugin_name, :action, :user_id, :occurred_at])
    |> validate_required([:plugin_name, :action, :occurred_at])
    |> validate_inclusion(:action, ~w(read write delete reveal))
  end
end
