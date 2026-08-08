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

  Three status axes, kept separate on purpose:

    * `health_status` (`unknown` / `up` / `down`) — does the Barkpark answer?
    * `agent_status` (`online` / `offline`) — is the on-box agent phoning home?
    * `suspended` (boolean) — a BILLING verdict: the owning team's subscription
      lapsed, so this managed instance is disabled. Distinct from health on
      purpose — a suspended box may still be perfectly reachable; suspension is
      "we are no longer serving you", not "you are down" (Coolify-anchor:
      `Team::subscriptionEnded()`). Set in bulk by
      `Registry.suspend_team_barkparks/2` on lapse, cleared by
      `Registry.resume_billing_suspended/1` on recovery (cch-w55-s4: it was the
      reason-blind `resume_team_barkparks/1`, which lifted flags the billing
      axis never set). `suspended_reason` on that axis is `"billing_lapsed"` |
      `"billing_past_due"` — but it is NOT only those two: the quota reconciler
      writes `"quota_exceeded"` through the single-row
      `Registry.suspend_barkpark/2` (`Billing.reconcile_plan_limit/1`), so any
      reader treating this column as a two-value billing enum is wrong.

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

  # The cloud providers a managed instance can be provisioned into (charter
  # Decision 9). Mirrors `Registry.Provider.kinds/0` — the connected-account kinds
  # — so a box's provider is always one we can actually host on.
  @providers ~w(hetzner azure)

  # The instance's self-update verdict states (isu-6), plus our own "unknown"
  # fallback for pre-feature instances (404) and failed/unreachable checks.
  @update_states ~w(unknown current behind disabled)

  # The rollout channels (isu-w5.2): "staging" boxes are the canary the rollout
  # worker advances first; "prod" is the fleet default and only advances once the
  # staging gate is green.
  @channels ~w(prod staging)

  # Personal Dev Fleet roles (Wave C, PDF-D61). A "main" is the developer's home
  # base; a "support" is a subordinate box bound to exactly one main. NULL (absent
  # from this list) is the third, un-enumerated state: "ungrouped" — every legacy
  # row, never validated against this set.
  @fleet_roles ~w(main support)

  # The worker-reported host lands here via succeed_job/2 — an IPv4/IPv6 address
  # or a DNS hostname. Permissive enough for all three (and the FakeProvider's
  # 10.0.0.1-style IPs), but rejects oversized junk and control chars: only
  # alphanumerics, dot, colon, underscore, hyphen.
  @host_format ~r/^[A-Za-z0-9.:_-]+$/

  # Instance custom domains — the PLATFORM shape: exactly ONE RFC-1035 label
  # under the platform zone (`gyldendal.barkpark.cloud`) — we own that DNS
  # zone, so the attach worker can stand the record up unassisted. The regex is
  # the whole gate: anything it rejects never reaches a Caddyfile or a shell.
  @custom_host_format ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.barkpark\.cloud$/

  # Attach-domain V2 — the EXTERNAL customer-domain shape: an arbitrary
  # customer-owned FQDN (`barkpark.jarl.no`), TWO OR MORE well-formed lowercase
  # RFC labels. Same defensive posture as the platform regex: the value is
  # interpolated into a Caddyfile and a shell script on the box, so ONLY dots,
  # hyphens, and alphanumerics are admitted — every shell/Caddy metacharacter
  # dies here. The 253-char FQDN cap and the numeric-TLD (bare-IP) reject ride
  # alongside in `custom_host_changeset/2`. A host UNDER the platform zone never
  # takes this path — it must match the strict single-label platform shape.
  @external_host_format ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/

  # An all-digit final label is the bare-IP shape (`203.0.113.9`) — no real TLD
  # is numeric, and an IP must never become an on-demand-ACME Caddy vhost.
  @numeric_tld_format ~r/\.[0-9]+$/

  schema "barkparks" do
    field :name, :string
    field :slug, :string
    field :url, :string
    field :host, :string
    field :mode, :string, default: "managed"

    # Provider-neutral hosting (charter Decision 9). `provider` is the cloud slug
    # the box lives on (`hetzner` | `azure`), defaulting to hetzner so a legacy row
    # and a provider-less launch are Hetzner by construction. `region` /
    # `server_type` pin the launch placement + size; NULL → the claim payload emits
    # nil (azh-w3) and the Go WORKER fills its own provider default (hetzner: the
    # env-derived FreshSpec, which is the warm pool's own truth, so an unpinned
    # launch stays warm-pool-compatible; azure: eastus/Standard_B1s). Stamping a
    # default into the claim here made every unpinned launch look pinned and skipped
    # the warm path. `provider` is surfaced in barkpark JSON (the SPA fleet
    # provider-chip); it never doubles as a status axis.
    field :provider, :string, default: "hetzner"
    field :region, :string
    field :server_type, :string
    field :health_status, :string, default: "unknown"
    field :version, :string
    field :git_commit, :string
    field :agent_status, :string, default: "offline"
    field :last_seen_at, :utc_datetime_usec

    # Server-side staleness bookkeeping (the StalenessWorker keys off these — see
    # Registry.stale_online_barkparks/1). Direct ports of Coolify's
    # servers.unreachable_count / servers.unreachable_notification_sent
    # (app/Models/Server.php:101). `unreachable_count` is the consecutive
    # missed-heartbeat tick count (the >= debounce); `unreachable_notification_sent`
    # is the one-alert-per-outage latch.
    field :unreachable_count, :integer, default: 0
    field :unreachable_notification_sent, :boolean, default: false

    # Billing-suspension axis (subscription-billing). Separate from health.
    field :suspended, :boolean, default: false
    field :suspended_reason, :string
    field :suspended_at, :utc_datetime_usec

    # instance-admin-token — the per-instance admin bearer the warm-pool minted on
    # the box, ENCRYPTED at rest (Registry.Vault, the same AES-256-GCM seam the
    # provider token uses). NEVER plaintext, and NEVER serialized in barkpark_json;
    # the owner retrieves it only through the team-admin-gated /credentials route.
    field :admin_token_encrypted, :string

    # push-relay spike (mobile charter D15b) — the per-barkpark shared secret the
    # instance signs chat_blocked webhook deliveries with and Cloud's
    # /v1/relay/chat-blocked/:barkpark_id receiver verifies against. SAME custody
    # as admin_token_encrypted (Registry.Vault AES-256-GCM, never plaintext,
    # never serialized in barkpark_json). Nil = no relay configured — the
    # receiver answers a silent 404 (severable by absence).
    field :push_relay_secret_encrypted, :string

    # dwb-4 content-template bootstrap. `template` is the deploy-template slug
    # picked at launch (validated in the go-live handler against
    # `Registry.known_templates/0`); the bootstrap_* columns are the outputs the
    # worker reported on /succeed. The read token — and the env map, which
    # CONTAINS the read token (env[].source=read_token) — ride the SAME Vault
    # encrypt-at-rest seam as admin_token_encrypted, are NEVER serialized in
    # barkpark_json, and are revealed only through the team-admin-gated
    # /bootstrap route.
    field :template, :string
    field :bootstrap_workspace, :string
    field :bootstrap_project, :string
    field :bootstrap_dataset, :string
    field :bootstrap_read_token_encrypted, :string
    field :bootstrap_env_encrypted, :string

    # isu-6 self-update status — the control plane's CACHE of the instance's own
    # update verdict (GET /v1/admin/self-update → "check"). The instance is the
    # source of truth; these columns only exist so the fleet dashboard renders
    # "update available" without a live per-row fan-out. Written ONLY through the
    # narrow `update_status_changeset/2`.
    field :update_state, :string, default: "unknown"
    field :update_running_release, :string
    field :update_latest_release, :string
    field :update_checked_at, :utc_datetime_usec

    # deploy-reliability W21 (S2) — the DERIVED freshness verdict, deliberately
    # NOT a fifth `update_state` rung (a fifth rung excludes the row from the
    # rollout that would fix it and can freeze the staging gate fail-CLOSED).
    # `update_state` above is the box's own release-tag self-grade; these three
    # are the control plane's own measurement of the commit it actually serves,
    # from ONE unauthenticated GitHub compare call
    # (`BarkparkCloud.GitHub.CommitDistance`), written hourly by
    # `UpdateStatusWorker` through the narrow `commit_distance_changeset/2`.
    #
    # `commit_distance` is "commits of `main` this box does NOT have", and NULL
    # means UNMEASURED — an empty `git_commit` (agent offline), a 404 on an
    # unknown sha, and a rate-limit refusal all land NULL, never 0. Renderers
    # must show NULL as unmetered and sort it to the TOP: a 0 there would be the
    # same unearned green in a fresh column.
    field :commit_distance, :integer
    field :commit_ancestry, :string
    field :commit_distance_checked_at, :utc_datetime_usec

    # isu-w4 fleet autoupdate policy — read by the AutoupdateRolloutWorker to
    # decide whether a `behind` instance may be auto-updated. OPT-OUT:
    # `autoupdate_enabled` defaults TRUE (ride new releases unless the team opts
    # out). `autoupdate_paused` is the temporary escape hatch; `pinned_release`
    # (any non-nil value) freezes the instance on its version. Policy fields are
    # written ONLY through `autoupdate_changeset/2`; `autoupdate_triggered_at`
    # (the in-flight marker the staged rollout health-gates on) ONLY through
    # `autoupdate_trigger_changeset/2`.
    field :autoupdate_enabled, :boolean, default: true
    field :autoupdate_paused, :boolean, default: false
    field :pinned_release, :string
    field :autoupdate_triggered_at, :utc_datetime_usec

    # isu-w5.2 rollout CHANNEL — "prod" (fleet default) or "staging" (the canary
    # boxes the AutoupdateRolloutWorker advances FIRST and health-gates prod
    # behind). Written through the same narrow `autoupdate_changeset/2`, validated
    # to exactly prod|staging. Every legacy row defaults "prod".
    field :channel, :string, default: "prod"

    # Zero-paste Vercel handoff (task-4e4a53b101a97051): the platform-deployed
    # project the user claims via vercel.com/claim-deployment. project id + url
    # are display state; the claim code is ENCRYPTED (it grants project
    # ownership) with its mint stamp for the 24h-expiry check. Written ONLY
    # through the narrow `vercel_changeset/2`; NEVER serialized in barkpark_json
    # (revealed via the team-admin-gated routes, same custody as bootstrap).
    field :vercel_project_id, :string
    field :vercel_deploy_url, :string
    field :vercel_claim_encrypted, :string
    field :vercel_claim_minted_at, :utc_datetime_usec

    # Instance custom domain (isu follow-up; arbitrary FQDNs since attach-domain
    # V2) — the platform-zone host (`gyldendal.barkpark.cloud`) OR external
    # customer FQDN (`barkpark.jarl.no`) attached to this managed instance. Written
    # ONLY through the narrow `custom_host_changeset/2` (via
    # `Registry.set_custom_host/2`, which also runs the cross-surface taken
    # check); globally unique via `barkparks_custom_host_unique_idx`.
    field :custom_host, :string

    # On-demand VERIFY verdict (BP-ONB-09 backend) — the cached headline of the
    # last golden-path probe run (`run_verify/3` → `Registry.record_verify_result/2`),
    # so the fleet list carries a queryable "last verified" fact without walking
    # the `verify` agent_event stream. Both NULL until the suite first runs;
    # `verify_reachable` is the run's envelope `reachable` (a real `false` is
    # distinct from the NULL "never verified"). Written ONLY through the narrow
    # `verify_changeset/2` (best-effort, via `Registry.record_verify_result/2`).
    field :last_verified_at, :utc_datetime_usec
    field :verify_reachable, :boolean

    # Personal Dev Fleet GROUP record (Wave C, PDF-D61). The two-tier main -> N
    # supports relationship lives on THIS machine row (no new table, no join):
    #   * `fleet_role` is "main" | "support" | nil (ungrouped — every legacy row).
    #   * `fleet_parent_id` is the SELF-referential FK to the main's id, set ONLY
    #     on support rows (`on_delete: :nilify_all` — a deleted main orphans, never
    #     cascade-deletes, its supports). Modelled as a self `belongs_to`.
    #   * `fleet_token_id` is the OPAQUE minted-token id (for later revocation),
    #     never the secret — distinct custody from `admin_token_encrypted`, so it
    #     IS serialized in barkpark_json. Written only through `fleet_changeset/2`.
    field :fleet_token_id, :string
    belongs_to :fleet_parent, __MODULE__, foreign_key: :fleet_parent_id, type: :binary_id
    field :fleet_role, :string

    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def modes, do: @modes
  def health_statuses, do: @health_statuses
  def agent_statuses, do: @agent_statuses
  def update_states, do: @update_states
  def channels, do: @channels
  def providers, do: @providers
  def fleet_roles, do: @fleet_roles

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

  # ── Clean-first subdomain reservation (cloud-clean-subdomains) ──────────────

  # System labels that may NEVER be claimed as a clean instance subdomain — they
  # collide with platform hostnames (the control plane is `api.barkpark.cloud`).
  # A go-live whose slug is reserved is forced onto the suffixed form. Lowercase.
  # Genuine PLATFORM/system labels only — not common user instance names like
  # `prod`/`staging`/`test` (those are legit and collision-handled by fallback).
  @reserved MapSet.new(~w(
    api www app apps dashboard control admin root console internal
    mail smtp ns ns1 ns2 mx ftp cdn assets static
    status billing docs help support blog cloud go barkpark
  ))

  @doc """
  Is `label` a reserved system subdomain (never claimable as a clean instance
  label)? Case-insensitive. A non-binary is treated as reserved (fail-closed).
  """
  @spec reserved?(String.t()) :: boolean()
  def reserved?(label) when is_binary(label),
    do: MapSet.member?(@reserved, String.downcase(label))

  def reserved?(_), do: true

  @doc """
  The reserved-label set (sorted), for docs/tests.
  """
  @spec reserved_labels() :: [String.t()]
  def reserved_labels, do: Enum.sort(MapSet.to_list(@reserved))

  @doc """
  The CLEAN customer-facing URL for a slug — `https://<slug>.<base_domain>`, no
  team suffix. The clean-first candidate at go-live; it is only persisted when the
  slug is not reserved AND the FQDN is not already claimed (the `url` global
  unique index decides the race, with `provisioning_url/1` as the guaranteed
  fallback).
  """
  @spec clean_url(String.t()) :: String.t()
  def clean_url(slug) when is_binary(slug), do: "https://" <> slug <> "." <> @base_domain

  @doc """
  The provisioning subdomain LABEL extracted from a stored Barkpark `url` — the
  host's first label (everything before `.<base_domain>`). This is the source of
  truth for the DNS label the worker stands up, so a clean `url`
  (`gyldendal.barkpark.cloud`) and a suffixed one
  (`gyldendal-71069eaa.barkpark.cloud`) each yield the correct label. Falls back
  to `provisioning_subdomain/1` when `url` is missing (pre-reservation rows).
  """
  @spec subdomain_from_url(t()) :: String.t()
  def subdomain_from_url(%__MODULE__{url: url}) when is_binary(url) do
    url
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
    |> String.replace_suffix("." <> @base_domain, "")
  end

  def subdomain_from_url(%__MODULE__{} = bp), do: provisioning_subdomain(bp)

  @doc """
  The platform DNS label of the attached custom host — `"gyldendal"` for
  `gyldendal.barkpark.cloud`. A platform custom host is exactly one label under
  `#{@base_domain}` (enforced by `custom_host_changeset/2`), so stripping the
  zone suffix is the whole derivation. `nil` when no custom host is attached
  OR when the attached host is an EXTERNAL customer FQDN (attach-domain V2) —
  the customer owns that DNS, so there is no platform label to upsert.
  """
  @spec custom_host_label(t()) :: String.t() | nil
  def custom_host_label(%__MODULE__{custom_host: host}) when is_binary(host) do
    if platform_custom_host?(host),
      do: String.replace_suffix(host, "." <> @base_domain, ""),
      else: nil
  end

  def custom_host_label(%__MODULE__{}), do: nil

  @doc """
  Is `host` a platform-zone custom host (any host under `#{@base_domain}`), as
  opposed to an external customer FQDN (attach-domain V2)? Splits the claim
  payload: platform hosts carry `dns_label`/`dns_zone` for the worker's
  A-record upsert; external hosts carry nil halves and the worker verifies
  resolution instead of writing platform DNS.
  """
  @spec platform_custom_host?(String.t() | nil) :: boolean()
  def platform_custom_host?(host) when is_binary(host),
    do: String.ends_with?(host, "." <> @base_domain)

  def platform_custom_host?(_), do: false

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
      :template,
      :provider,
      :region,
      :server_type,
      :team_id
    ])
    |> validate_required([:name, :slug, :team_id])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:template, max: 255)
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_length(:region, max: 255)
    |> validate_length(:server_type, max: 255)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:provider, @providers)
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
  (`Registry.succeed_job/3`) lands the provisioned IP here in the same write that
  flips `health_status` to `up`, without widening to the full registration
  changeset.

  `admin_token_encrypted` is castable here for the SAME provision-success write:
  the worker may report the minted admin token alongside the ip, and it is
  persisted (already encrypted by `Registry.Vault` at the call site) atomically
  with the host/health flip. The agent health-report route (`POST
  /v1/agent/report`) builds its own attrs map explicitly and never includes it,
  so an agent can NOT set it through this changeset.

  The `bootstrap_*` columns (dwb-4) are castable here for the same reason and
  under the same containment: they land ONLY in the provision-success write
  (`Registry.succeed_job/3`, secrets already Vault-encrypted at the call site),
  and the agent report path never builds them into its attrs.

  `fleet_token_id` (task-5866ec745efcd7f7) is castable here under the same
  containment: it lands ONLY in the provision-success write for a
  `provision_support` job (`Registry.succeed_job/3` guards it to
  `fleet_role: "support"` rows), the agent report path never builds it, and it
  is an OPAQUE revocation handle — never the token value itself.
  """
  def health_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [
      :host,
      :health_status,
      :version,
      :git_commit,
      :agent_status,
      :last_seen_at,
      :admin_token_encrypted,
      :bootstrap_workspace,
      :bootstrap_project,
      :bootstrap_dataset,
      :bootstrap_read_token_encrypted,
      :bootstrap_env_encrypted,
      :fleet_token_id
    ])
    |> validate_length(:host, max: 255)
    |> validate_format(:host, @host_format)
    |> validate_inclusion(:health_status, @health_statuses)
    |> validate_inclusion(:agent_status, @agent_statuses)
    |> validate_length(:fleet_token_id, max: 255)
  end

  @doc """
  Narrow changeset for a billing-suspension write — only the three suspension
  columns are castable, so a billing-triggered suspend/resume can never rename a
  Barkpark or reassign its Team (the same containment posture as
  `health_changeset/2`). Used by the SINGLE-ROW helpers —
  `Registry.suspend_barkpark/2` and `Registry.unsuspend_barkpark/1`, the quota
  reconciler's axis. The three BULK helpers
  (`suspend_team_barkparks/2`, `resume_team_barkparks/1`,
  `resume_billing_suspended/1`) never reach this changeset: they issue a
  `Repo.update_all` and so bypass every validation here. (cch-w55-s4 review:
  this doc named the two bulk functions as the single-row path, which is
  backwards — a reader trusting it would expect `validate_length/3` to run on a
  billing suspend, and it does not.)
  """
  def suspend_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [:suspended, :suspended_reason, :suspended_at])
    |> validate_length(:suspended_reason, max: 255)
  end

  @doc """
  Narrow changeset for a self-update status refresh (isu-6) — only the four
  update-status cache columns are castable, so mirroring the instance's verdict
  can never rename a Barkpark or reassign its Team (the same containment posture
  as `health_changeset/2` / `suspend_changeset/2`). `update_state` is whitelisted
  against `update_states/0`; the caller (`Registry.refresh_update_status/1`)
  maps anything else to `"unknown"` before it gets here.
  """
  def update_status_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [
      :update_state,
      :update_running_release,
      :update_latest_release,
      :update_checked_at
    ])
    |> validate_inclusion(:update_state, @update_states)
    |> validate_length(:update_running_release, max: 255)
    |> validate_length(:update_latest_release, max: 255)
  end

  @doc """
  Narrow changeset for the DERIVED commit-distance verdict (deploy-reliability
  W21) — only the three freshness columns are castable, so mirroring a compare
  result can never rename a Barkpark, reassign its Team, or (the point) touch
  `update_state`. Written only by `Registry.refresh_commit_distance/2`.

  Deliberately SEPARATE from `update_status_changeset/2` and
  `health_changeset/2`: neither of those casts these fields, so an agent health
  beat and the instance's own self-update mirror CANNOT write a freshness
  verdict by accident. The ancestry is whitelisted against
  `BarkparkCloud.GitHub.CommitDistance.ancestries/0` and the distance may never
  be negative — an out-of-range value is a changeset ERROR, not a silent 0.
  """
  def commit_distance_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [:commit_distance, :commit_ancestry, :commit_distance_checked_at])
    |> validate_inclusion(:commit_ancestry, BarkparkCloud.GitHub.CommitDistance.ancestries())
    |> validate_number(:commit_distance, greater_than_or_equal_to: 0)
  end

  @doc """
  Narrow changeset for the on-demand VERIFY verdict (BP-ONB-09) — only the two
  verify cache columns are castable, so persisting a probe run can never rename a
  Barkpark or reassign its Team (the same containment posture as
  `update_status_changeset/2` / `health_changeset/2`). Written only by
  `Registry.record_verify_result/2`, best-effort in `run_verify/3`.
  """
  def verify_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [:last_verified_at, :verify_reachable])
  end

  @doc """
  Narrow changeset for the Personal Dev Fleet GROUP record (Wave C, PDF-D61) —
  only the three fleet columns are castable, so binding a machine into (or out
  of) a fleet can never rename a Barkpark or reassign its Team (the same
  containment posture as `verify_changeset/2`). The relationship invariants:

    * `fleet_role` must be `main` or `support` when set. NULL is the un-enumerated
      "ungrouped" state and passes through untouched (legacy rows).
    * `fleet_parent_id` is REQUIRED when `fleet_role == "support"` (a support with
      no main is meaningless) and FORBIDDEN when `fleet_role == "main"` (a main IS
      the root — it has no parent). An ungrouped row constrains neither.
    * `assoc_constraint(:fleet_parent)` maps the self-FK so a parent id that names
      no row fails as a validation error, never a 500.

  Written only by `Registry.register_support_barkpark/2` (via the team-scoped
  `/v1/fleet/supports` endpoint).
  """
  def fleet_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [:fleet_role, :fleet_parent_id, :fleet_token_id])
    |> validate_inclusion(:fleet_role, @fleet_roles)
    |> validate_length(:fleet_token_id, max: 255)
    |> validate_fleet_parent()
    |> assoc_constraint(:fleet_parent)
  end

  # role=support ⇒ parent required; role=main ⇒ parent forbidden; nil role
  # (ungrouped) ⇒ no constraint. `get_field` reads the post-cast value so the
  # rule sees both the incoming change and any already-persisted value.
  defp validate_fleet_parent(changeset) do
    role = get_field(changeset, :fleet_role)
    parent = get_field(changeset, :fleet_parent_id)

    cond do
      role == "support" and is_nil(parent) ->
        add_error(changeset, :fleet_parent_id, "is required for a support")

      role == "main" and not is_nil(parent) ->
        add_error(changeset, :fleet_parent_id, "is forbidden for a main")

      true ->
        changeset
    end
  end

  @doc """
  Narrow changeset for the isu-w4 autoupdate POLICY — only the three team-facing
  policy fields are castable (never the in-flight marker, never `channel`), so
  setting a policy can never rename a Barkpark, reassign its Team, spoof an
  in-flight rollout, or move the box between rollout channels. A blank
  `pinned_release` is normalized to nil (unpinned) so "" and NULL can't diverge.
  Written only by `Registry.set_autoupdate/2`.
  """
  def autoupdate_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [:autoupdate_enabled, :autoupdate_paused, :pinned_release])
    |> update_change(:pinned_release, fn
      v when is_binary(v) -> if String.trim(v) == "", do: nil, else: String.trim(v)
      v -> v
    end)
    |> validate_length(:pinned_release, max: 255)
  end

  @doc """
  Narrow changeset for the rollout CHANNEL (isu-w5.2) — a PLATFORM-OPERATOR
  lever, deliberately NOT part of `autoupdate_changeset/2`. A staging box is
  the fleet-wide canary: whoever can write `channel` can close
  `Registry.staging_gate_open?/0` (register a staging box, leave it behind)
  and brake EVERY prod-channel advancement, or jump the update queue — so the
  write rides the worker-token surface, same posture as the halt/resume kill
  switch. `channel` is validated to exactly prod|staging — anything else
  invalidates the changeset (the route maps that to 422). Written only by
  `Registry.set_channel/2`; tenants see it read-only in the fleet JSON and
  the autoupdate PATCH echo.
  """
  def channel_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [:channel])
    |> validate_inclusion(:channel, @channels)
  end

  @doc """
  Narrow changeset for the isu-w4 in-flight marker — ONLY `autoupdate_triggered_at`
  is castable, so the rollout worker can stamp/clear "a self-update is in flight
  for this instance" without touching policy or identity. Written only by
  `Registry.mark_autoupdate_triggered/1` and `Registry.clear_autoupdate_triggered/1`.
  """
  def autoupdate_trigger_changeset(barkpark, attrs) do
    cast(barkpark, attrs, [:autoupdate_triggered_at])
  end

  @doc """
  Narrow changeset for the zero-paste Vercel handoff — only the four Vercel
  columns are castable, so recording a platform deploy can never rename a
  Barkpark or reassign its Team (the same containment posture as
  `update_status_changeset/2`). Written only by `BarkparkCloud.Vercel.deploy_for/1`.
  """
  def vercel_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [
      :vercel_project_id,
      :vercel_deploy_url,
      :vercel_claim_encrypted,
      :vercel_claim_minted_at
    ])
    |> validate_length(:vercel_project_id, max: 255)
    |> validate_length(:vercel_deploy_url, max: 255)
  end

  @doc """
  Narrow changeset for attaching a custom domain — only `custom_host` is
  castable, so a domain attach can never rename a Barkpark or reassign its Team
  (the same containment posture as `vercel_changeset/2`). The value is
  normalized (lowercased, trimmed, trailing dot stripped — the SAME
  normalization `Registry.domain_registered?/1` applies, so the stored host and
  the ask-gate lookup can never diverge) and shape-validated, split by zone
  (attach-domain V2):

    * under `#{@base_domain}` → the strict one-label platform format (we own
      the zone; deeper nesting is never claimable)
    * the `#{@base_domain}` apex itself → always rejected
    * anywhere else → a well-formed lowercase external FQDN (≥ 2 labels,
      ≤ 253 chars, dots/hyphens/alphanumerics only, non-numeric TLD)

  Written only by `Registry.set_custom_host/2`, which layers the cross-surface
  taken check (and, router-side, the DNS ownership proof) on top; the
  `barkparks_custom_host_unique_idx` unique constraint is the atomic race
  backstop.
  """
  def custom_host_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [:custom_host])
    |> update_change(:custom_host, &normalize_custom_host/1)
    |> validate_required([:custom_host])
    |> validate_length(:custom_host, max: 253)
    |> validate_custom_host_shape()
    |> unique_constraint(:custom_host,
      name: :barkparks_custom_host_unique_idx,
      message: "is already taken"
    )
  end

  # The zone-split shape gate (see `custom_host_changeset/2`). Runs on the
  # NORMALIZED value; anything it rejects never reaches a Caddyfile or a shell.
  defp validate_custom_host_shape(changeset) do
    validate_change(changeset, :custom_host, fn :custom_host, host ->
      cond do
        host == @base_domain ->
          [custom_host: {"the platform apex itself cannot be attached", []}]

        String.ends_with?(host, "." <> @base_domain) ->
          if Regex.match?(@custom_host_format, host),
            do: [],
            else: [custom_host: {"must be a single label under #{@base_domain}", []}]

        Regex.match?(@external_host_format, host) and
            not Regex.match?(@numeric_tld_format, host) ->
          []

        true ->
          [custom_host: {"must be a well-formed lowercase fully-qualified domain", []}]
      end
    end)
  end

  defp normalize_custom_host(host) when is_binary(host),
    do: host |> String.downcase() |> String.trim() |> String.trim_trailing(".")

  defp normalize_custom_host(other), do: other

  @doc """
  Changeset for the `StalenessWorker`'s offline flip and for the report path's
  recovery reset. Narrow BY DESIGN — only the two status axes plus the
  reachability bookkeeping (`unreachable_count` / `unreachable_notification_sent`)
  are castable here, never `name`/`slug`/`team_id`/`host`. The worker never
  renames or re-homes an instance; a recovery reset never re-registers one.

  This is the defense-in-depth companion to `health_changeset/2`: the agent's
  health report (`health_changeset`) still cannot touch the counters, and the
  worker's staleness write cannot touch identity — the two write paths are
  disjoint on purpose.
  """
  def staleness_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [
      :agent_status,
      :health_status,
      :unreachable_count,
      :unreachable_notification_sent
    ])
    |> validate_inclusion(:agent_status, @agent_statuses)
    |> validate_inclusion(:health_status, @health_statuses)
    |> validate_number(:unreachable_count, greater_than_or_equal_to: 0)
  end
end
