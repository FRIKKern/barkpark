defmodule BarkparkCloud.Registry.Barkpark do
  @moduledoc """
  A registered Barkpark instance — one row per live (or provisioning) server a
  Team owns. This is the metadata that makes "one dashboard of all your
  Barkparks" real, and the row the warm-pool (cloud-6) writes via
  `RegistryClient.Register` when it hands a fresh server to a Team.

  Belongs to exactly one Team (the control-plane boundary). The `(team_id, slug)`
  pair is unique — a Team names each of its Barkparks once.

  Two status axes, kept separate on purpose:

    * `health_status` (`unknown` / `up` / `down`) — does the Barkpark answer?
    * `agent_status` (`online` / `offline`) — is the on-box agent phoning home?

  A server can be reachable while its agent is offline, or vice-versa; collapsing
  them would lose that signal. `last_seen_at` is the agent's last health report.

  `mode` records how the instance is operated:

    * `managed`     — Barkpark Cloud provisioned + runs it (warm-pool path).
    * `byo`         — bring-your-own cloud account; we provision into the Team's
                      connected `Provider`.
    * `self_hosted` — the Team runs it; we only hold metadata + the agent link.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Same slug shape as Team — lowercase alphanumeric + hyphens. Unique PER TEAM
  # (not globally): two Teams may both name a Barkpark "prod".
  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/

  @modes ~w(managed byo self_hosted)
  @health_statuses ~w(unknown up down)
  @agent_statuses ~w(online offline)

  # The worker-reported host lands here via succeed_job/2 — an IPv4/IPv6 address
  # or a DNS hostname. Permissive enough for all three (and the FakeProvider's
  # 10.0.0.1-style IPs), but rejects oversized junk and control chars: only
  # alphanumerics, dot, colon, underscore, hyphen.
  @host_format ~r/^[A-Za-z0-9.:_-]+$/

  schema "barkparks" do
    field :name, :string
    field :slug, :string
    field :url, :string
    field :host, :string
    field :mode, :string, default: "managed"
    field :health_status, :string, default: "unknown"
    field :version, :string
    field :git_commit, :string
    field :agent_status, :string, default: "offline"
    field :last_seen_at, :utc_datetime_usec

    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def modes, do: @modes
  def health_statuses, do: @health_statuses
  def agent_statuses, do: @agent_statuses

  @doc """
  Changeset for registering / updating a Barkpark. `name`, `slug`, and `team_id`
  are required; the status fields default and are validated against their
  enumerations.
  """
  def changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [
      :name,
      :slug,
      :url,
      :host,
      :mode,
      :health_status,
      :version,
      :git_commit,
      :agent_status,
      :last_seen_at,
      :team_id
    ])
    |> validate_required([:name, :slug, :team_id])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:health_status, @health_statuses)
    |> validate_inclusion(:agent_status, @agent_statuses)
    |> assoc_constraint(:team)
    |> unique_constraint([:team_id, :slug],
      name: :barkparks_team_slug_unique_idx,
      message: "a Barkpark with this slug already exists in this team"
    )
  end

  @doc """
  Changeset for an agent health report — narrow by design. Only the fields the
  agent reports (status axes, version/commit, last-seen) plus the `host` a
  successful provision stamps are castable here, so a health report can never
  rename a Barkpark or reassign its Team.

  `host` is in this narrow set on purpose: the provision-job success path
  (`Registry.succeed_job/2`) lands the provisioned IP here in the same write that
  flips `health_status` to `up`, without widening to the full registration
  changeset.
  """
  def health_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [:host, :health_status, :version, :git_commit, :agent_status, :last_seen_at])
    |> validate_length(:host, max: 255)
    |> validate_format(:host, @host_format)
    |> validate_inclusion(:health_status, @health_statuses)
    |> validate_inclusion(:agent_status, @agent_statuses)
  end
end
