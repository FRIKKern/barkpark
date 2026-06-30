defmodule Barkpark.Secrets.SecretAudit do
  @moduledoc """
  Audit-log row for run-secret access — one `secrets_audit` record per
  `set` / `reveal` / `delete` action on a (encrypted) secret, stamped with the
  acting `actor` and `inserted_at`. `changeset/2` enforces the action vocabulary.
  Mirrors `Barkpark.Plugins.SettingsAudit`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "secrets_audit" do
    field :name, :string
    field :action, :string
    field :actor, :string
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(rec, attrs) do
    rec
    |> cast(attrs, [:name, :action, :actor, :inserted_at])
    |> validate_required([:name, :action, :inserted_at])
    |> validate_inclusion(:action, ~w(set reveal delete))
  end
end
