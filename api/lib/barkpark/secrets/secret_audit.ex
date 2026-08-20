defmodule Barkpark.Secrets.SecretAudit do
  @moduledoc """
  Audit-log row for run-secret access — one `secrets_audit` record per
  `set` / `reveal` / `delete` action on a (encrypted) secret, stamped with the
  acting `actor`, `inserted_at`, and the acting `workspace_id` (connectors
  D195 — NULL for global-tier actions; the 3-value action vocabulary stays
  closed, NULL vs non-NULL workspace_id already carries the tier distinction).
  `changeset/2` enforces the action vocabulary.
  Mirrors `Barkpark.Plugins.SettingsAudit`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "secrets_audit" do
    field :name, :string
    field :action, :string
    field :actor, :string
    field :workspace_id, :binary_id
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(rec, attrs) do
    rec
    |> cast(attrs, [:name, :action, :actor, :workspace_id, :inserted_at])
    |> validate_required([:name, :action, :inserted_at])
    |> validate_inclusion(:action, ~w(set reveal delete))
  end
end
