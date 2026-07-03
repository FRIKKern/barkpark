defmodule BarkparkCloud.Registry.AgentEvent do
  @moduledoc """
  One entry in a Barkpark's append-only agent event stream — the audit trail of
  what the on-box agent reported (a health beat, a status flip, a backup run, a
  TLS renewal). Belongs to one Barkpark.

  Append-only: there is `inserted_at` but NO `updated_at`. An event is a fact at
  a point in time; it is written once and never mutated. `payload` is a free map
  stored as jsonb, so each `type` can carry whatever shape it needs without a
  schema migration per event kind.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `content` is the onboarding signal: the on-box agent posts it once an
  # instance has ≥1 published document (payload carries `published_count`), so
  # the control plane can honestly derive the "published a doc" checklist step
  # without reading CMS content it can't see. See Accounts.onboarding_status/1.
  #
  # `verify` (C8/D53) is the on-demand readiness proof: `BarkparkCloud.Verify`
  # re-runs the golden-path probe suite over HTTPS and appends the full result
  # envelope (payload carries `ok`, `reachable`, `probes`) so "ready" becomes a
  # claim the operator can re-issue, and every run lands on the instance's event
  # timeline. Unlike the agent-posted types above, this one is control-plane
  # authored (no on-box coupling — D16 holds).
  @types ~w(health status backup tls content verify)

  # Append-only stream: stamp inserted_at, never updated_at.
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "agent_events" do
    field :type, :string
    field :payload, :map, default: %{}

    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark

    timestamps()
  end

  @type t :: %__MODULE__{}

  def types, do: @types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :payload, :barkpark_id])
    |> validate_required([:type, :barkpark_id])
    |> validate_inclusion(:type, @types)
    |> assoc_constraint(:barkpark)
  end
end
