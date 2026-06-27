defmodule BarkparkCloud.Registry.Barkpark do
  @moduledoc """
  A registered Barkpark instance — one row per live (or provisioning) server a
  Team owns. This is the metadata that makes "one dashboard of all your
  Barkparks" real, and the row the warm-pool (cloud-6) writes via
  `RegistryClient.Register` when it hands a fresh server to a Team.

  Belongs to exactly one Team (the control-plane boundary). The `(team_id, slug)`
  pair is unique — a Team names each of its Barkparks once. The slug is NOT the
  public provisioning identity: it is unique only per-team, so the GLOBALLY-unique
  provisioning subdomain (`provisioning_subdomain/1`) suffixes the team's short id
  (`<slug>-<team_short_id>`). The resolved customer-facing FQDN lands in `:url`
  and carries a GLOBAL unique index — the never-two-boxes-on-one-FQDN backstop.

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
  # (not globally): two Teams may both name a Barkpark "prod". The GLOBALLY-unique
  # provisioning identity is NOT the bare slug — see `provisioning_subdomain/1`.
  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/

  # The public zone every managed Barkpark lives under. The off-box Go warm-pool
  # provisioner turns the claim payload's subdomain label into `<label>.<base>`
  # (the DNS record + the Hetzner box name), so this MUST match the worker's own
  # hardcoded base domain. Kept here so the control-plane-computed customer-facing
  # FQDN (`provisioning_fqdn/1`) is identical to what the worker provisions.
  @base_domain "barkpark.cloud"

  # DNS label hard limit (RFC 1035). `<slug>-<team_short_id>` must never exceed it.
  @max_label_len 63

  # How many leading hex chars of the team UUID we fold into the subdomain. UUIDs
  # are uniformly random, so an 8-hex-char (32-bit) prefix gives ~4.3e9 distinct
  # team buckets — collision across any realistic customer base is negligible, and
  # the value is deterministic + stable (derived from the team's immutable PK).
  @team_short_id_len 8

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

  @doc "The public zone managed Barkparks live under (`barkpark.cloud`)."
  @spec base_domain() :: String.t()
  def base_domain, do: @base_domain

  @doc ~S"""
  The GLOBALLY-unique provisioning subdomain label for this Barkpark:
  `"<slug>-<team_short_id>"`.

  This is the single source of truth for the provisioning identity. The bare
  `slug` is unique only PER TEAM (two teams may both pick `"prod"`), so using it
  as the provisioning label collides cross-tenant — two boxes named `prod`, one
  `prod.barkpark.cloud` shared/overwritten between tenants. Suffixing the
  team's short id makes the label globally unique BY CONSTRUCTION: every team has
  a distinct `team_short_id`, so no two teams can ever resolve to the same label.

  `team_short_id` is the first #{@team_short_id_len} hex chars of the team's UUID
  (lowercase `0-9a-f` — already a valid DNS label charset; see
  `team_short_id/1`). The whole label is kept ≤ #{@max_label_len} chars (the DNS
  label limit) by truncating ONLY the slug part — the team_short_id always
  survives intact, so global uniqueness is preserved even for a long slug.

  Accepts a loaded `%Barkpark{}` (with `slug` + `team_id`) or an explicit
  `{slug, team_id}` pair.

  ## Examples

      iex> Barkpark.provisioning_subdomain({"prod", "ac4e1f2a-...-..."})
      "prod-ac4e1f2a"
  """
  @spec provisioning_subdomain(t() | {String.t(), binary()}) :: String.t()
  def provisioning_subdomain(%__MODULE__{slug: slug, team_id: team_id}),
    do: provisioning_subdomain({slug, team_id})

  def provisioning_subdomain({slug, team_id}) when is_binary(slug) and is_binary(team_id) do
    short = team_short_id(team_id)
    # Reserve room for the team_short_id + the joining hyphen; the slug fills the
    # rest, truncated and re-trimmed of trailing hyphens so the label is valid.
    slug_budget = @max_label_len - String.length(short) - 1

    label =
      slug
      |> String.slice(0, max(slug_budget, 0))
      |> String.trim_trailing("-")
      |> then(fn s -> s <> "-" <> short end)

    # Trim leading/trailing hyphens from the ASSEMBLED label: an empty (or
    # all-hyphen) slug would otherwise yield "-<short>", an invalid DNS label
    # (leading hyphen). team_short_id is hex (no hyphens), so trimming can only
    # ever shave the slug side — global uniqueness is preserved.
    String.trim(label, "-")
  end

  @doc """
  The customer-facing FQDN for this Barkpark —
  `"<provisioning_subdomain>.<base_domain>"`. This is IDENTICAL to what the Go
  warm-pool worker provisions (same label, same base domain), so the FQDN shown
  in the dashboard/API and the FQDN actually stood up can never diverge.
  """
  @spec provisioning_fqdn(t() | {String.t(), binary()}) :: String.t()
  def provisioning_fqdn(barkpark_or_pair),
    do: provisioning_subdomain(barkpark_or_pair) <> "." <> @base_domain

  @doc """
  The customer-facing URL (https) for this Barkpark's FQDN. The value stored in
  the `:url` column at go-live time.
  """
  @spec provisioning_url(t() | {String.t(), binary()}) :: String.t()
  def provisioning_url(barkpark_or_pair),
    do: "https://" <> provisioning_fqdn(barkpark_or_pair)

  @doc """
  A subdomain-safe, stable short id for a team UUID: the first
  #{@team_short_id_len} hex chars, hyphens stripped, lowercased. Hex is `0-9a-f`
  — already a valid DNS label charset — so no further sanitizing is needed. Stable
  because it derives from the team's immutable primary key.
  """
  @spec team_short_id(binary()) :: String.t()
  def team_short_id(team_id) when is_binary(team_id) do
    team_id
    |> String.replace("-", "")
    |> String.downcase()
    |> String.slice(0, @team_short_id_len)
  end

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
    # Defense in depth: the resolved customer-facing FQDN (`url`) is GLOBALLY
    # unique. `provisioning_subdomain/1` already makes the label collision-free by
    # construction; this index is the backstop so even a logic bug cannot stand up
    # two boxes on one FQDN (the cross-tenant DNS-overwrite security bug).
    |> unique_constraint(:url,
      name: :barkparks_url_unique_idx,
      message: "is already provisioned"
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
