defmodule Barkpark.Audit.ExportSink do
  @moduledoc """
  A configured SIEM/webhook endpoint the audit log streams to. `workspace_id`
  nil = global (every event); set = only that workspace's events.
  `last_exported_id` is the tail-shipping high-water mark into `audit_events`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @formats ~w(generic splunk datadog)

  @type t :: %__MODULE__{}

  schema "audit_export_sinks" do
    field :workspace_id, Ecto.UUID
    field :name, :string
    field :url, :string
    field :secret, :string
    field :format, :string, default: "generic"
    field :active, :boolean, default: true
    field :last_exported_id, :integer, default: 0
    field :consecutive_failures, :integer, default: 0
    field :auto_disabled_at, :utc_datetime_usec
    field :disable_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  def formats, do: @formats

  def changeset(sink, attrs) do
    sink
    |> cast(attrs, [:workspace_id, :name, :url, :secret, :format, :active])
    |> validate_required([:name, :url])
    |> validate_inclusion(:format, @formats)
    |> validate_format(:url, ~r{^https?://}, message: "must be an http(s) URL")
  end
end
