defmodule Barkpark.EcosystemPanel.Snapshot do
  @moduledoc """
  One workspace's latest ecosystem panel snapshot: the row
  `Barkpark.EcosystemPanel` overwrites on every push. Keyed by the workspace
  id alone, so a workspace holds at most one.
  """
  use Ecto.Schema

  @primary_key {:workspace_id, :binary_id, autogenerate: false}
  schema "ecosystem_panel_snapshots" do
    field :html, :string
    field :built_at, :utc_datetime_usec
    field :received_at, :utc_datetime_usec
    field :bytes, :integer
    field :sha256, :string
  end

  @type t :: %__MODULE__{}
end
