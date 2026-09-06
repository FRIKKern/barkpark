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
  #
  # BOTH ends must be alphanumeric, because this slug IS a DNS label on the
  # clean-first path: `Registry.insert_with_url_reservation/4` hands an
  # unreserved slug straight to `clean_url/1`, which interpolates it VERBATIM
  # into `https://<slug>.<base>` and persists that url — and
  # `subdomain_from_url/1` mints the worker's `dns_label` back out of it. The
  # older `^[a-z0-9][a-z0-9-]*$` guarded only the LEADING hyphen, so `"acme-"`
  # was accepted and `https://acme-.barkpark.cloud` reached Postgres: a
  # trailing hyphen is an invalid RFC-1035 label (unlike the suffixed path,
  # `clean_url/1` has no assembly step that could trim it). Reachability was
  # bounded — `slugify/1` on go-live/launch already trims — but the only
  # raw-slug writer is the worker route, and any future caller-supplied slug on
  # go-live (the shape `POST /v1/sites` already has) would have made it
  # immediate. Validate-on-change only: existing rows are untouched.
  @slug_format ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/

  # The public zone every managed Barkpark lives under. The off-box Go warm-pool
  # provisioner turns the claim payload's subdomain label into `<label>.<base>`
  # (the DNS record + the Hetzner box name), so this MUST match the worker's own
  # base domain. Kept here so the control-plane-computed customer-facing FQDN
  # (`provisioning_fqdn/1`) is identical to what the worker provisions.
  #
  # This is the DEFAULT, not the value: it used to be a compile-time module
  # attribute read directly at every site, which a release BUILD freezes — so a
  # self-hosted control plane issued every site URL, every provisioning
  # subdomain and every custom-host verdict under OUR zone, and its
  # `custom_host_changeset/2` REJECTED the operator's own domain shape
  # (gh-9531 residual, task-eeabfd9bf3ed8371). Read `base_domain/0` instead,
  # which resolves `config :barkpark_cloud, :base_domain` (PLATFORM_BASE_DOMAIN)
  # at CALL time and falls back to this literal, so nothing moves for an
  # unconfigured deployment.
  @default_base_domain "barkpark.cloud"

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

  # cch-w58 — the reasons `update_state` reads "unknown". `update_states/0` says
  # WHAT the row shows; this says WHY, so the five worlds behind that one rung
  # stop being one word. `identity_refused` (401) is the only REFUTATION of the
  # stored admin token; `no_self_update_route` (404) is a PRE-FEATURE box and is
  # deliberately its own rung — folding a 404 into "refused" is the exact
  # conflation that made `verify_reachable` useless (charter D684). NULL (absent
  # from this list) is the un-enumerated state: no refusal on file.
  #
  # EVERY rung here has a writer in `Registry.refresh_update_status/1` — a word
  # in this vocabulary that nothing can persist would be a small lie of its own.
  @update_unavailable_reasons ~w(identity_refused forbidden no_self_update_route unreachable bad_shape instance_error no_admin_token decrypt_failed not_live)

  # The box's ONE-CLICK-APPLY ARMING, mirrored from the top-level `apply_enabled`
  # key of `GET /v1/admin/self-update` (#12995). TWO words, because the THIRD
  # world is NULL and must stay NULL:
  #
  #     "armed"    the body said apply_enabled: true
  #     "unarmed"  the body said apply_enabled: false   <- the retro-arm worklist
  #     NULL       the body carried no such key (a PRE-#12995 box), or we have
  #                never read a body for this row at all
  #
  # A pre-#12995 box that is genuinely armed sends no such key, so mapping the
  # ABSENT key to "unarmed" would make it indistinguishable from a MEASURED
  # unarmed box and put correctly-armed boxes on the worklist. That collapse is
  # the one thing this column exists to prevent, so absence is never a value —
  # it is the absence of one. Same posture as the 404 rung above: a box that has
  # never heard of the question has refused nothing.
  #
  # Deliberately NOT a value of `update_unavailable_reason`: on this path the box
  # ANSWERED, nothing is unavailable, and overloading that column would re-merge
  # two worlds cch-w58 spent a wave separating.
  @apply_armings ~w(armed unarmed)

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
  # zone, so the attach worker can stand the record up unassisted. The label
  # regex is the whole gate: anything it rejects never reaches a Caddyfile or a
  # shell.
  #
  # It matches the LABEL alone (the zone suffix is checked separately against
  # `base_domain/0`) because it used to spell `\.barkpark\.cloud$` inline — a
  # NINTH frozen read of the platform zone the filing missed, and the one that
  # made the changeset reject a self-hoster's own zone even once every other
  # site honoured the configured value.
  @custom_host_label_format ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/

  # Attach-domain V2 — the EXTERNAL customer-domain shape: an arbitrary
  # customer-owned FQDN (`barkpark.jarl.no`), TWO OR MORE well-formed lowercase
  # RFC labels. Same defensive posture as the platform regex: the value is
  # interpolated into a Caddyfile and a shell script on the box, so ONLY dots,
  # hyphens, and alphanumerics are admitted — every shell/Caddy metacharacter
  # dies here. The 253-char FQDN cap and the numeric-TLD (bare-IP) reject ride
  # alongside in `custom_host_changeset/2`. A host UNDER the platform zone never
  # takes this path — it must match the strict single-label platform shape.
  @external_host_format ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/

  # The accepted shape of a CONFIGURED platform zone (`base_domain/0`): two or
  # more lowercase RFC-1035 labels. Same defensive posture as the host regexes
  # above — this value is interpolated into every FQDN, DNS label and Caddyfile
  # the platform mints, so a scheme, a port, a path or a space is refused rather
  # than carried.
  @base_domain_format ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/

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

    # dr-w22-bl WHEN the box started serving `git_commit` — the materialised
    # first appearance of the sha the row currently carries, stamped by
    # `Registry.record_agent_report/2` the first time a beat reports a sha
    # DIFFERENT from the one already stored.
    #
    # The fact was already on disk and unreachable. Every 60 s beat lands in
    # `agent_events` with the full report (`git_commit` included) and
    # `AgentRetentionWorker` keeps 14 days (MEASURED on prod 2026-09-01:
    # 132,120 rows spanning 2026-08-18T03:30:20Z -> 2026-09-01T23:19:22Z). But
    # the ONLY reader of that history is `GET /v1/barkparks/:id/events`, which
    # is `Auth.require_user` and caps a page at 200 rows — about three hours of
    # a fourteen-day record, on a NARROWER surface than the fleet list every
    # PAT holder already reads. This column puts the answer on the row.
    #
    # NULL IS UNMEASURED, NEVER "NOW" — the same contract `commit_distance`
    # below carries, and the reason this column is not backfilled. Two distinct
    # populations read NULL and both are honest:
    #
    #   * a box that has not changed sha since this column shipped — we never
    #     OBSERVED the transition, and stamping the deploy instant would report
    #     a box as freshly-changed when it has served the same commit for weeks;
    #   * a box whose stored sha was empty (agent offline / pre-`git_commit`
    #     agent) when a sha first arrived — that sha may have been running long
    #     before we could see it, so the transition is not dated either.
    #
    # Renderers must show NULL as unmetered and must NOT sort it as fresh.
    field :git_commit_first_seen_at, :utc_datetime_usec
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

    # cch-w58 — WHY the mirror above says "unknown". `update_state: "unknown"` is
    # the one rung that collapses five different worlds: the box refused OUR
    # credential (401), refused the principal (403), has no such route at all
    # (404 — a pre-feature box), was unreachable, or answered something we could
    # not read. Only the first is a refutation of the stored admin token, and
    # before this column the discriminating byte was read once an hour and
    # thrown away. NULL means "no refusal on file" — every row before this
    # column's first write, and every row whose last check was a clean 200
    # (`persist_update_check/2` CLEARS it, so a stale refusal cannot survive a
    # recovery). Whitelisted against `update_unavailable_reasons/0`.
    #
    # READ-ONLY VERDICT: nothing refuses on this column yet. It is the evidence
    # a later slice needs, not the guard.
    field :update_unavailable_reason, :string

    # THE ARMING MIRROR — whether ONE-CLICK APPLY is armed on the box, read from
    # the `apply_enabled` sibling of `"check"` in the same hourly 200
    # (`Registry.refresh_update_status/1`, written through
    # `update_status_changeset/2`). Whitelisted against `apply_armings/0`; NULL
    # is the THIRD state and means "not measured" — a pre-#12995 box that sends
    # no such key, or a row no body has been read for yet. NEVER read NULL as
    # false: an unmeasured box is not an unarmed box, and conflating them is
    # what would put armed boxes on the retro-arm worklist.
    #
    # WHY IT MATTERS OPERATIONALLY: `false` here is precisely the input the
    # box's one-click-apply POST decides its 503 `feature_not_configured` from,
    # and that 503 is what `AutoupdateRolloutWorker` answers with
    # `Registry.pause_autoupdate/1` — a pause no code path clears. So an
    # `"unarmed"` row is a box the rollout will pause the moment it reaches it.
    #
    # A FAILED check does NOT clear this: `persist_update_unknown/2` never
    # writes these two columns, so a measurement stands until a newer body
    # replaces it. `apply_arming_checked_at` is how stale it is, and — unlike
    # `update_checked_at`, which is stamped on six rungs that read no body at
    # all — it is stamped ONLY when a body was actually decoded, so
    # (checked_at set, arming NULL) reads "asked, and the box reported no
    # arming" while (both NULL) reads "never asked".
    #
    # READ-ONLY ROSTER: nothing refuses on these columns. This is the evidence
    # the human-gated retro-arm movement needs, not the guard.
    field :apply_arming, :string
    field :apply_arming_checked_at, :utc_datetime_usec

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
  def update_unavailable_reasons, do: @update_unavailable_reasons
  def apply_armings, do: @apply_armings
  def channels, do: @channels
  def providers, do: @providers
  def fleet_roles, do: @fleet_roles

  @doc """
  The public zone managed Barkparks live under — every provisioning subdomain,
  site URL, custom-host verdict and DNS-label derivation on this control plane
  hangs off it.

  Read at CALL time from `config :barkpark_cloud, :base_domain`
  (`PLATFORM_BASE_DOMAIN` in `config/runtime.exs`), defaulting to the historical
  `barkpark.cloud` — an unconfigured deployment is byte-identical to before.

  FAILS CLOSED: a configured-but-malformed zone raises rather than falling back
  to ours. A silent fallback is the original defect in a new costume — the
  operator would believe their zone was set while the box kept minting
  `*.barkpark.cloud` FQDNs and rejecting their own domains.
  `BarkparkCloud.Application.start/2` resolves it once at boot, so a typo
  refuses the node instead of first surfacing as a customer's wrong site URL.

  The off-box Go warm-pool worker carries its own base domain: configuring this
  moves the control plane's half only, so the two MUST be set to the same zone.
  """
  @spec base_domain() :: String.t()
  def base_domain do
    case Application.get_env(:barkpark_cloud, :base_domain) do
      nil -> @default_base_domain
      configured -> validate_base_domain!(configured)
    end
  end

  @doc """
  The compile-time fallback zone, for tests and for callers that need to state
  what "unconfigured" means without reproducing the literal.
  """
  @spec default_base_domain() :: String.t()
  def default_base_domain, do: @default_base_domain

  # A base domain is interpolated into FQDNs, DNS labels, Caddyfiles and the
  # claim payload the worker executes, so the accepted shape is the strict one:
  # two or more lowercase RFC-1035 labels, nothing else. That rejects a scheme
  # (`https://barkpark.cloud`), a space, a path, an uppercase host, a port, a
  # leading/trailing dot and a bare single label — every spelling an operator
  # plausibly types that would otherwise mint hosts nothing can resolve.
  defp validate_base_domain!(value) when is_binary(value) do
    if String.length(value) <= 253 and Regex.match?(@base_domain_format, value) do
      value
    else
      bad_base_domain!(value)
    end
  end

  defp validate_base_domain!(other), do: bad_base_domain!(other)

  defp bad_base_domain!(value) do
    raise ArgumentError, """
    invalid platform base domain: #{inspect(value)}.

    Expected a bare lowercase domain of two or more labels, e.g. "example.com" —
    no scheme, no port, no path, no whitespace, no trailing dot.

    Set PLATFORM_BASE_DOMAIN to the zone this control plane owns (and point the
    warm-pool worker at the SAME zone), or leave it unset to keep the
    #{@default_base_domain} default.
    """
  end

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
    do: provisioning_subdomain(barkpark_or_pair) <> "." <> base_domain()

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
  def clean_url(slug) when is_binary(slug), do: "https://" <> slug <> "." <> base_domain()

  @doc """
  The provisioning subdomain LABEL extracted from a stored Barkpark `url` — the
  host's first label (everything before `.<base_domain>`). This is the source of
  truth for the DNS label the worker stands up, so a clean `url`
  (`gyldendal.barkpark.cloud`) and a suffixed one
  (`gyldendal-71069eaa.barkpark.cloud`) each yield the correct label. Falls back
  to `provisioning_subdomain/1` when `url` is missing (pre-reservation rows).

  Self-normalises `trim |> downcase` before stripping (aligned with the write-side
  `normalize_url` fold, cch-w69-bl / D865): this output mints the worker's
  `dns_label`, the claim slug it turns into the DNS record + Hetzner box name, and
  the deprovision label — so it must NOT depend on upstream cleanliness. Without
  the fold a leading space defeats the case-sensitive `replace_prefix`, and an
  uppercase scheme or mixed-case host passes through untouched, minting a wrong
  DNS label for old rows, the pre-`normalize_url` write window, and any
  changeset-bypassing write.
  """
  @spec subdomain_from_url(t()) :: String.t()
  def subdomain_from_url(%__MODULE__{url: url}) when is_binary(url) do
    url
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
    |> String.replace_suffix("." <> base_domain(), "")
  end

  def subdomain_from_url(%__MODULE__{} = bp), do: provisioning_subdomain(bp)

  @doc """
  The platform DNS label of the attached custom host — `"gyldendal"` for
  `gyldendal.barkpark.cloud`. A platform custom host is exactly one label under
  the platform zone (`base_domain/0`, default `#{@default_base_domain}`, enforced
  by `custom_host_changeset/2`), so stripping the zone suffix is the whole
  derivation. `nil` when no custom host is attached
  OR when the attached host is an EXTERNAL customer FQDN (attach-domain V2) —
  the customer owns that DNS, so there is no platform label to upsert.
  """
  @spec custom_host_label(t()) :: String.t() | nil
  def custom_host_label(%__MODULE__{custom_host: host}) when is_binary(host) do
    if platform_custom_host?(host),
      do: String.replace_suffix(host, "." <> base_domain(), ""),
      else: nil
  end

  def custom_host_label(%__MODULE__{}), do: nil

  @doc """
  Is `host` a platform-zone custom host (any host under `base_domain/0`), as
  opposed to an external customer FQDN (attach-domain V2)? Splits the claim
  payload: platform hosts carry `dns_label`/`dns_zone` for the worker's
  A-record upsert; external hosts carry nil halves and the worker verifies
  resolution instead of writing platform DNS.
  """
  @spec platform_custom_host?(String.t() | nil) :: boolean()
  def platform_custom_host?(host) when is_binary(host),
    do: String.ends_with?(host, "." <> base_domain())

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
    # Normalise-on-write at the single chokepoint every writer shares
    # (register/upsert/adopt all flow through `Registry.register_barkpark/2` →
    # here). The worker route `POST /v1/internal/barkparks` stores the body `url`
    # VERBATIM (Auth.require_worker, no validate_format), and
    # `barkparks_url_unique_idx` is on the RAW column — so ` https://h` and
    # `https://h` were two distinct rows for one hostname, and every other reader
    # (`subdomain_from_url/1`, DomainStatus.platform_host/1) had to re-derive the
    # trim or diverge (cch-w69 D852). Folding the hostile spelling out here
    # NARROWS what the index admits — it does not make the index canonical. The
    # fold closes whitespace, case, and the trailing slash; it leaves trailing
    # dot, scheme variance, port and path alone, so `barkparks_url_unique_idx`
    # still admits six distinct rows for one claim host (enumerated in
    # `normalize_url/1`). NEW-WRITES-ONLY — see `normalize_url/1`.
    |> update_change(:url, &normalize_url/1)
    # Scheme guard AFTER the normalise fold, so it judges the DERIVED value
    # (an uppercase `HTTPS://` spelling is downcased first and legally passes;
    # a guard on the raw request field would miss what the fold manufactures).
    # This is the single chokepoint that casts `:url`: every server-derived url
    # is `"https://" <> fqdn` by construction (`clean_url/1`,
    # `provisioning_url/1`), and the ONLY caller-supplied path is
    # `Registry.adopt_barkpark/3` via `POST /v1/internal/barkparks` — without
    # this line that route persisted `http://` (and `not-a-url`, `ftp://`)
    # verbatim, and the hourly UpdateStatusWorker sweep would have carried the
    # DECRYPTED admin bearer to it over cleartext: `Billing.HttpClient`'s
    # `verify_peer` ssl opts are attached unconditionally and are silently
    # inert on an `http://` url (cch-w58-bl-barkparks-url-has-no-scheme-guard).
    # Validate-on-change only — existing rows are untouched (prod population
    # measured 2026-08-23: 9 rows, 0 non-https).
    |> validate_format(:url, ~r{^https://}, message: "must be an https:// URL")
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
    # cch-w37-bl — see `TeamInvitation.changeset/2`. Opening the list with the
    # `belongs_to` key made POST /v1/fleet/supports answer "team id already has
    # a Barkpark with this slug" for a duplicate support name.
    |> unique_constraint([:slug, :team_id],
      name: :barkparks_team_slug_unique_idx,
      message: "is already taken by another Barkpark on this team"
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

  `git_commit_first_seen_at` (dr-w22-bl) is castable here and is the one field
  in this set an agent MUST NOT be able to choose. It is SERVER-COMPUTED:
  `Registry.record_agent_report/2` DROPS any incoming value (atom and string
  key both) and re-derives it from the sha already on the row versus the sha in
  this beat. It is castable rather than written through its own changeset so
  the stamp lands in the SAME update as the `git_commit` it dates — a second
  `Repo.update` could interleave with a concurrent beat and date the wrong sha.
  """
  def health_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [
      :host,
      :health_status,
      :version,
      :git_commit,
      :git_commit_first_seen_at,
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
  Narrow changeset for a self-update status refresh (isu-6) — only the seven
  update-status cache columns are castable, so mirroring the instance's verdict
  can never rename a Barkpark or reassign its Team (the same containment posture
  as `health_changeset/2` / `suspend_changeset/2`). `update_state` is whitelisted
  against `update_states/0`; the caller (`Registry.refresh_update_status/1`)
  maps anything else to `"unknown"` before it gets here.

  The fifth column, `update_unavailable_reason` (cch-w58), is whitelisted against
  `update_unavailable_reasons/0` and is the WHY behind an "unknown" state. `nil`
  is a legal value and means "no refusal on file" — `validate_inclusion` skips a
  nil change, which is exactly how `persist_update_check/2` CLEARS a stale
  refusal on a recovered box.

  Columns six and seven are the ARMING MIRROR (`apply_arming`,
  `apply_arming_checked_at`). This @doc used to end "five columns, no more", and
  the widening is deliberate and narrow in the sense that clause actually meant:
  the boundary it guards is the WRITER, not the arity. Both new columns are read
  out of the SAME hourly 200 body by the SAME caller, in the SAME single write —
  splitting them into a second changeset would buy nothing but a second
  `Repo.update` that can half-land, leaving a fresh state beside a stale arming.
  The containment property is unchanged and still pinned: nothing outside these
  seven is castable here, so a status refresh still cannot touch a name, a team,
  or a freshness verdict. `apply_arming` is whitelisted against `apply_armings/0`
  and `nil` is a legal value meaning UNMEASURED — never "false".
  """
  def update_status_changeset(barkpark, attrs) do
    barkpark
    |> cast(attrs, [
      :update_state,
      :update_running_release,
      :update_latest_release,
      :update_checked_at,
      :update_unavailable_reason,
      :apply_arming,
      :apply_arming_checked_at
    ])
    |> validate_inclusion(:update_state, @update_states)
    |> validate_inclusion(:update_unavailable_reason, @update_unavailable_reasons)
    |> validate_inclusion(:apply_arming, @apply_armings)
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

    * under the platform zone (`base_domain/0`) → the strict one-label platform
      format (we own the zone; deeper nesting is never claimable)
    * that zone's apex itself → always rejected
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
    # ONE read of the configured zone per validation, so the apex reject, the
    # zone split and the error message can never describe different zones.
    zone = base_domain()

    validate_change(changeset, :custom_host, fn :custom_host, host ->
      cond do
        host == zone ->
          [custom_host: {"the platform apex itself cannot be attached", []}]

        String.ends_with?(host, "." <> zone) ->
          label = String.replace_suffix(host, "." <> zone, "")

          if Regex.match?(@custom_host_label_format, label),
            do: [],
            else: [custom_host: {"must be a single label under #{zone}", []}]

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

  # Fold a hostile `:url` spelling to its canonical origin form (cch-w69 D852):
  # strip leading/trailing whitespace (Elixir `String.trim/1` covers space, tab,
  # NBSP, and CR/LF), downcase (scheme + host are case-insensitive; a managed
  # `clean_url/1` value is already all-lowercase so it passes through
  # byte-identical), and drop the trailing slash so `https://h/` and `https://h`
  # collapse to one row under `barkparks_url_unique_idx`.
  #
  # THE SCHEME SEPARATOR IS NOT A TRAILING SLASH. This fold is a THIRD
  # normaliser standing beside the claim-walk twins that #11785 built a census
  # for, so it owes them the composition property
  # `normalize_claim_host(normalize_url(x)) == normalize_claim_host(x)` — a fold
  # that changes a claim-walk answer re-opens the `:free`-for-a-live-host hole by
  # spelling. Stripping trailing slashes from the WHOLE string breaks it:
  # `"https://"` would fold to `"https:"`, and the read side's scheme regex is
  # ANCHORED on `://`, so it would stop recognising the scheme, fall through to
  # its "cut at the first non-hostname character" step, and answer with the
  # SCHEME LABEL as the hostname (`""` before the fold, `"https"` after). So the
  # separator is preserved and only the part after it is trimmed.
  # `barkpark_url_normalisation_test.exs` drives the composition property over
  # the corpus rather than trusting this paragraph.
  #
  # WHAT THIS DOES NOT CLOSE. Whitespace, case and the trailing slash, and
  # nothing else — trailing dot, scheme variance, port and path all survive the
  # fold, so `barkparks_url_unique_idx` still admits SIX distinct rows that the
  # read side maps onto the one claim host `gyldendal.barkpark.cloud`:
  #
  #     https://gyldendal.barkpark.cloud       https://gyldendal.barkpark.cloud.
  #     http://gyldendal.barkpark.cloud        https://gyldendal.barkpark.cloud/studio
  #     https://gyldendal.barkpark.cloud:4000  gyldendal.barkpark.cloud
  #
  # The claim walk is safe across all six (it normalises them together); the
  # index is NARROWED, not made canonical, and the defense-in-depth backstop
  # stays bypassable by those spellings.
  #
  # HONESTY CLAUSE (durable, carried by the merge): this is NEW-WRITES-ONLY. It
  # does NOT backfill existing rows and does NOT strengthen the raw-column unique
  # index into an expression index — a pre-existing ` https://h` row and a fresh
  # `https://h` write can still coexist until the backfill lands. The backfill is
  # owned by `cch-w70-bl-worker-url-backfill-gated-on-prod-dup-scan`, gated on
  # this prod dup-scan first (rows that would COLLIDE on normalisation must be
  # reconciled by hand before a unique backfill, or the UPDATE fails). The
  # expression mirrors the fold below, separator-preservation included:
  #
  #     SELECT lower(regexp_replace(btrim(url), '(://)?/*$', '\1')) AS normalised,
  #            count(*), array_agg(url)
  #       FROM barkparks
  #      WHERE url IS NOT NULL
  #      GROUP BY 1
  #     HAVING count(*) > 1;
  #
  # A collision the scan misses is not a 500: `unique_constraint(:url, name:
  # :barkparks_url_unique_idx)` is already declared on this changeset, so a write
  # whose normalised url lands on an existing row degrades to
  # `{:error, changeset}` and the worker route renders a clean 422 — never a
  # raised `Postgrex.Error`. That is the reason the fold is safe to ship ahead of
  # the backfill, not any claim that a collision cannot happen.
  defp normalize_url(url) when is_binary(url) do
    case fold_url(url) do
      # A slash-only url (`"/"`, `"//"`) folds to `""`, and `""` IS indexed:
      # `barkparks_url_unique_idx` is partial on `WHERE url IS NOT NULL`, and
      # `''` is not NULL. Letting the fold manufacture that value would hand the
      # first junk write a GLOBAL claim on `''`, and the next team's write the
      # 422 "is already provisioned" — a row `provisioning_fqdn_claim/2` has no
      # empty-`norm` guard against either. Pre-fold those inputs stored as
      # themselves and stayed distinct; they still do. (Whitespace-only input
      # never reaches here — Ecto's `cast/3` treats it as an empty value and
      # drops the change, so `:url` stays nil.)
      "" when url != "" -> url
      folded -> folded
    end
  end

  defp normalize_url(other), do: other

  defp fold_url(url) do
    trimmed = url |> String.trim() |> String.downcase()

    case String.split(trimmed, "://", parts: 2) do
      [scheme, rest] -> scheme <> "://" <> String.trim_trailing(rest, "/")
      [bare] -> String.trim_trailing(bare, "/")
    end
  end

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
