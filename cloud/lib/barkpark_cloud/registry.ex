defmodule BarkparkCloud.Registry do
  @moduledoc """
  The Barkparks registry context — the metadata store behind "one dashboard of
  all your Barkparks", and the seam the warm-pool (cloud-6) registers a new live
  server into.

  Everything here is Team-scoped: a Barkpark belongs to a Team, and the list /
  lookup functions take a Team so one Team can never see another's instances.

  Four moving parts:

    * `Barkpark`   — the registry row (one per instance). `register_barkpark/2`
      / `upsert_barkpark/2` create-or-update it (the warm-pool's write path);
      `upsert_health/2` lands the agent's health report.
    * `Provider`   — a connected cloud account. `connect_provider/3` encrypts the
      account token at rest (`Vault`) before storing it.
    * `AgentEvent` — the append-only agent event stream (`record_event/3`,
      `recent_events/2`).
    * `AgentToken` — revocable agent bearer tokens. `mint_agent_token/3` returns
      the plaintext ONCE and stores only its hash; `verify_agent_token/1` returns
      the Barkpark for a valid (unrevoked, unexpired) token; `revoke_agent_token/1`.
  """
  import Ecto.Query, warn: false
  require Logger

  alias BarkparkCloud.Repo
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Billing
  alias BarkparkCloud.Billing.Subscription

  alias BarkparkCloud.Registry.{
    AgentEvent,
    AgentToken,
    Barkpark,
    Deployment,
    EnvVar,
    Provider,
    ProvisionJob,
    Site,
    Vault,
    WarmServer
  }

  # The warm-pool defaults a provision job carries to the Go worker when the
  # Barkpark row doesn't pin a region / server_type of its own. These mirror the
  # warm-pool's own defaults (internal/cli/cloud) — Nuremberg, the cax11 ARM box.
  @default_region "nbg1"
  @default_server_type "cax11"

  # Stale-claim recovery. A claimed job whose `claimed_at` is older than this is
  # treated as abandoned (the worker crashed, or its succeed/fail report failed in
  # transit and — per the worker contract — it tore down its half-built box and
  # LEFT the row "claimed") and is re-claimable by claim_next_job. The threshold
  # is the Go worker's DefaultProvisionTimeout (8m — internal/provisioner) plus a
  # margin for the box teardown + the report round-trip, so a still-running job is
  # NEVER yanked out from under a live worker. Overridable via
  # `config :barkpark_cloud, :provision_stale_after_seconds` (e.g. to match a
  # non-default worker ProvisionTimeout). Default: 12 minutes.
  @default_stale_after_seconds 12 * 60

  # The attempt budget: claim_next_job bumps `attempts` on every (re)claim, and a
  # stale job whose attempts have already reached this cap is transitioned to
  # "failed" ("exceeded max provision attempts") instead of being handed out
  # again — so a permanently-failing job stops looping. Overridable via
  # `config :barkpark_cloud, :max_provision_attempts`.
  @default_max_provision_attempts 3

  # Deployment stale-claim recovery. A deployment claimed by an off-box builder
  # (status "building") whose `claimed_at` is older than this is treated as
  # abandoned (the builder crashed, or its success/failure report was lost in
  # transit) and requeued/failed by reap_stale_deployments. Sized above a typical
  # build+push so a still-running builder is NEVER yanked. Overridable via
  # `config :barkpark_cloud, :deployment_stale_after_seconds`. Default: 15 minutes.
  @default_deployment_stale_after_seconds 15 * 60

  # The deploy claim budget: claim_next_deployment bumps `claim_epoch` on every
  # (re)claim, and a stale "building" row whose epoch has already reached this cap
  # is transitioned to "failed" ("exceeded max deploy claim attempts") instead of
  # being requeued again — so a permanently-crashing build stops looping.
  # Overridable via `config :barkpark_cloud, :max_deploy_claims`.
  @default_max_deploy_claims 5

  # gh-6: max concurrent branch previews per site — bounded resource. When a push
  # to a NEW branch would exceed this, the oldest preview branch is evicted
  # (its deployments cancelled + host de-registered) before the new one is minted,
  # with an honest eviction line on the new preview's console. Overridable via
  # `config :barkpark_cloud, :max_previews_per_site`.
  @default_max_previews_per_site 5

  # Warm-pool (dwb-10) stale-claim threshold. A warm row that has been `claimed`
  # (an assign popped it) or `retiring` (the reconciler popped it) for longer than
  # this is treated as abandoned (the worker crashed between the claim and
  # consuming/deleting the row) and is DELETED by reap_stale_warm_claims — pure
  # bookkeeping, the Go worker owns the box's lifecycle. Sized like the provision
  # stale threshold: the worker's DefaultProvisionTimeout (8m) plus margin for the
  # assign chain (DNS/ACME/health poll) so a still-running assign is NEVER reaped.
  # Overridable via `config :barkpark_cloud, :warm_stale_after_seconds`.
  @default_warm_stale_after_seconds 12 * 60

  # Health / staleness detection knobs (the ServerManagerJob analog). The
  # push-only ingest cannot notice an agent going SILENT, so the StalenessWorker
  # scans for online rows whose last heartbeat is older than the staleness
  # threshold and flips them offline after a small debounce.
  #
  #   @default_health_stale_after_seconds — seconds since last_seen_at before a
  #     heartbeat counts as missed. 180s ≈ 3 agent ticks (the agent reports
  #     ~every 60s), the gap analysis's "sentinel_push_interval_seconds * 3"
  #     floor — absorbs a slow tick without false-alarming.
  #   @default_health_down_after_count — consecutive missed ticks before the
  #     offline flip + alert. Default 2 — a straight port of Coolify's
  #     `unreachable_count >= 2` gate (ServerConnectionCheckJob.php:155).
  @default_health_stale_after_seconds 180
  @default_health_down_after_count 2

  # dwb-16: hard cap on a job's live-console array. Append-only, oldest dropped —
  # so a chatty/looping worker can never grow the provision_jobs row unbounded.
  # 300 lines is generous for a single provision's narration while staying small.
  @max_console_lines 300

  # Same append-only bound for a job's step-transition array (mirrors
  # @max_console_lines, oldest dropped). ~5 steps × 3 statuses + retries fits easily.
  @max_step_entries 100

  ## Barkparks

  @doc """
  Register a Barkpark for `team` from `attrs`. The Team is taken from the first
  argument (struct or id) — `attrs` need not (and should not) carry `:team_id`.

  Returns `{:ok, %Barkpark{}}` or `{:error, %Ecto.Changeset{}}` (e.g. the slug
  already exists in this team).

  usage-limits-quotas: this is the SINGLE create path, so the per-plan instance
  quota is enforced here — the un-bypassable backstop. A team already AT its plan
  ceiling gets `{:error, :limit_reached}` (Coolify's `serverLimitReached`, the API
  altitude the UI can't route around). The friendly HTTP 403 in the router's
  `go_live/1` is the front door; this guard catches the agent/internal register
  path too. `upsert_barkpark/2` routes EXISTING `(team_id, slug)` rows to update
  before reaching here, so an idempotent re-register is never blocked — only a
  genuine new instance. Only a team with an ACTIVE subscription is quota-gated;
  an unsubscribed team is `false` here (the go-live 402 is what stops it).
  """
  @spec register_barkpark(Team.t() | binary(), map()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t() | :limit_reached}
  def register_barkpark(team, attrs) do
    if Billing.barkpark_limit_reached?(team) do
      {:error, :limit_reached}
    else
      %Barkpark{}
      |> Barkpark.changeset(put_team_id(attrs, team))
      |> Repo.insert()
    end
  end

  @doc """
  Create-or-update a Barkpark for `team`, keyed on `(team_id, slug)`. This is
  the warm-pool's idempotent write path: registering the same slug twice updates
  the existing row instead of failing the unique constraint.

  Requires a `:slug` in `attrs`.
  """
  @spec upsert_barkpark(Team.t() | binary(), map()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def upsert_barkpark(team, attrs) do
    attrs = put_team_id(attrs, team)
    team_id = attrs |> Map.get(:team_id) || Map.get(attrs, "team_id")
    slug = attrs |> Map.get(:slug) || Map.get(attrs, "slug")

    case team_id && slug && Repo.get_by(Barkpark, team_id: team_id, slug: slug) do
      %Barkpark{} = existing ->
        existing
        |> Barkpark.changeset(attrs)
        |> Repo.update()

      _ ->
        register_barkpark(team, attrs)
    end
  end

  @doc """
  Register a MANAGED (go-live) Barkpark for `team`, assigning a CLEAN
  `<slug>.barkpark.cloud` FQDN when the slug is neither reserved nor already
  claimed, and falling back to the globally-unique `<slug>-<team_short_id>` form
  otherwise.

  Clean-first, suffix-on-collision. The fallback is RACE-SAFE: the
  `barkparks_url_unique_idx` decides a concurrent clean-claim, and the loser
  retries with its suffixed url — which is unique by construction, so it can
  never collide. A reserved slug (e.g. `api`, `www`) skips the clean attempt
  entirely. Returns `{:ok, %Barkpark{}}` or `{:error, %Ecto.Changeset{}}`.

  `opts` may carry `template:` — the dwb-4 content-template slug (validated by
  the caller against `known_templates/0`) persisted on the row and folded into
  the provision-job claim payload so the worker bootstraps the instance content.
  """
  @spec register_managed_barkpark(Team.t() | binary(), String.t(), String.t(), keyword()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def register_managed_barkpark(team, name, slug, opts \\ []) do
    tid = team_id(team)
    suffixed = Barkpark.provisioning_url({slug, tid})
    candidate = if Barkpark.reserved?(slug), do: suffixed, else: Barkpark.clean_url(slug)

    attrs = %{
      name: name,
      slug: slug,
      mode: "managed",
      health_status: "unknown",
      agent_status: "offline"
    }

    attrs =
      case Keyword.get(opts, :template) do
        t when is_binary(t) and t != "" -> Map.put(attrs, :template, t)
        _ -> attrs
      end

    case register_barkpark(team, Map.put(attrs, :url, candidate)) do
      {:ok, barkpark} ->
        {:ok, barkpark}

      # usage-limits-quotas: the quota backstop fired in register_barkpark/2 — the
      # team is at its plan ceiling. Surface it unchanged so the router's go_live
      # `with/else` maps it to a 403 (never a 500 from an unmatched clause).
      {:error, :limit_reached} = err ->
        err

      {:error, %Ecto.Changeset{} = cs} ->
        # Clean label was already claimed (by any team) → fall back to the
        # globally-unique suffixed FQDN. Only retry on a `url` uniqueness clash,
        # and only when we actually tried the clean form.
        if candidate != suffixed and url_conflict?(cs) do
          register_barkpark(team, Map.put(attrs, :url, suffixed))
        else
          {:error, cs}
        end
    end
  end

  defp url_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:url, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  @doc "List a Team's Barkparks, newest first. Scoped — never crosses teams."
  @spec list_barkparks(Team.t() | binary()) :: [Barkpark.t()]
  def list_barkparks(team) do
    team_id = team_id(team)

    Barkpark
    |> where([b], b.team_id == ^team_id)
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  @doc """
  Fetch a Barkpark by id, or nil. Guards the UUID cast: the PK is `:binary_id`,
  so a raw non-UUID path param would otherwise raise `Ecto.Query.CastError` →
  HTTP 500. A malformed id can't identify any row, so it's a clean nil (→ 404).
  """
  @spec get_barkpark(binary()) :: Barkpark.t() | nil
  def get_barkpark(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Barkpark, uuid)
      :error -> nil
    end
  end

  def get_barkpark(_), do: nil

  @doc """
  usage-limits-quotas: the live count of a Team's registered instances — the
  quota numerator `Billing.barkpark_limit_reached?/1` compares against the plan
  ceiling. A cheap `SELECT count(*) WHERE team_id = $1` — no denormalised counter,
  so no drift (Coolify computes the same `count()` live). Counts ALL rows,
  including reconciler-suspended ones: a suspended overflow box is still "held"
  (re-enabled on re-upgrade), so a downgraded team can't create around its own
  suspended overflow.
  """
  @spec count_barkparks(Team.t() | binary()) :: non_neg_integer()
  def count_barkparks(team) do
    tid = team_id(team)

    Barkpark
    |> where([b], b.team_id == ^tid)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Delete a Barkpark row (the dashboard's "remove instance"). The FK cascade
  (`on_delete: :delete_all` on sites / provision_jobs / deployments-via-sites)
  removes its children in the same statement.

  CONTROL-PLANE SCOPE ONLY: this deregisters the instance from the dashboard —
  it does NOT tear down the underlying managed server (that needs the Go
  worker's deprovision path, a follow-up). The caller (router) gates this so a
  LIVE managed box is not silently stranded; failed / never-provisioned rows are
  safe to remove outright (a failed provision already tore its half-built box
  down per the worker contract).
  """
  @spec delete_barkpark(Barkpark.t()) :: {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def delete_barkpark(%Barkpark{} = barkpark), do: Repo.delete(barkpark)

  @doc """
  Land an agent health report onto `barkpark`. Accepts a subset of
  `%{health_status, version, git_commit, agent_status, last_seen_at}` — the
  narrow `health_changeset` means a health report can't rename the Barkpark or
  move it between Teams.
  """
  @spec upsert_health(Barkpark.t(), map()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def upsert_health(%Barkpark{} = barkpark, attrs) do
    barkpark
    |> Barkpark.health_changeset(attrs)
    |> Repo.update()
  end

  ## Health / staleness — the server-side detection of a SILENT agent (the
  ## ServerManagerJob analog). The push-only ingest above (upsert_health) only
  ## ever flips a row TOWARDS online; nothing notices when /v1/agent/report
  ## simply stops arriving. These functions back BarkparkCloud.Health.StalenessWorker.

  @doc """
  Barkparks that are CANDIDATES for a staleness flip — the worker's per-tick
  scan. A row qualifies when ALL hold:

    * `mode ∈ managed/byo` — instances WE operate (a `self_hosted` box is the
      Team's own responsibility, never alerted on);
    * `agent_status == "online"` — an already-flipped `offline` row is excluded,
      which IS the natural backoff (a silent box leaves the candidate set after
      one flip and is never re-incremented or re-alerted — Barkpark has no
      active-probe channel to re-test it; the agent re-arms it via the report
      path);
    * the team has an `active` Subscription — Coolify's `stripe_invoice_paid`
      gate; we don't monitor (or alert on) an unpaid fleet;
    * the last heartbeat is older than `threshold`, OR the row has NEVER reported
      (`last_seen_at IS NULL`) and was created before `threshold` (so a wedged
      never-online instance is still caught).

  Returns full `%Barkpark{}` structs, oldest-silent first.
  """
  @spec stale_online_barkparks(DateTime.t()) :: [Barkpark.t()]
  def stale_online_barkparks(%DateTime{} = threshold) do
    from(b in Barkpark,
      join: s in Subscription,
      on: s.team_id == b.team_id and s.status == "active",
      where: b.mode in ["managed", "byo"],
      where: b.agent_status == "online",
      where:
        (not is_nil(b.last_seen_at) and b.last_seen_at < ^threshold) or
          (is_nil(b.last_seen_at) and b.inserted_at < ^threshold),
      order_by: [asc: b.last_seen_at]
    )
    |> Repo.all()
  end

  @doc """
  Increment a Barkpark's consecutive missed-heartbeat counter. Returns the
  updated row. Narrow write via `staleness_changeset/2` — cannot touch identity.
  """
  @spec bump_unreachable(Barkpark.t()) :: {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def bump_unreachable(%Barkpark{} = bp) do
    bp
    |> Barkpark.staleness_changeset(%{unreachable_count: bp.unreachable_count + 1})
    |> Repo.update()
  end

  @doc """
  Flip a silent Barkpark to offline: `agent_status → "offline"`, `health_status
  → "unknown"` (NOT `"down"` — we cannot probe; the agent is simply silent, and
  `"unknown"` is the honest state), and LATCH `unreachable_notification_sent` so
  the outage is alerted exactly ONCE. The online-only scan filter then drops this
  row from future ticks (the natural backoff).
  """
  @spec mark_offline(Barkpark.t()) :: {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def mark_offline(%Barkpark{} = bp) do
    bp
    |> Barkpark.staleness_changeset(%{
      agent_status: "offline",
      health_status: "unknown",
      unreachable_notification_sent: true
    })
    |> Repo.update()
  end

  @doc """
  Land an agent report AND reset the reachability bookkeeping in one call — the
  ingest path's recovery hook. Wraps `upsert_health/2`, then zeroes
  `unreachable_count` and clears the alert latch.

  Returns `{:recovered, bp}` when this report ENDED a latched outage (the
  StalenessWorker had flipped the box offline + alerted), else `{:ok, bp}`. A
  failed health upsert short-circuits with its `{:error, cs}`. The router's
  `POST /v1/agent/report` handler calls this to re-arm the latch; the recovery
  EMAIL itself is emitted by the handler's existing `maybe_dispatch_health_flip`
  (unknown→up ⇒ `:agent_reachable`), so this function stays mail-free.
  """
  @spec record_agent_report(Barkpark.t(), map()) ::
          {:ok, Barkpark.t()} | {:recovered, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def record_agent_report(%Barkpark{} = bp, attrs) do
    was_latched = bp.unreachable_notification_sent

    with {:ok, bp} <- upsert_health(bp, attrs),
         {:ok, bp} <-
           bp
           |> Barkpark.staleness_changeset(%{
             unreachable_count: 0,
             unreachable_notification_sent: false
           })
           |> Repo.update() do
      if was_latched, do: {:recovered, bp}, else: {:ok, bp}
    end
  end

  @doc """
  Seconds since `last_seen_at` before a heartbeat counts as missed. Default
  #{@default_health_stale_after_seconds}s (≈3 agent ticks); overridable via
  `config :barkpark_cloud, :health_stale_after_seconds` (tests set it low).
  """
  @spec health_stale_after_seconds() :: pos_integer()
  def health_stale_after_seconds do
    Application.get_env(
      :barkpark_cloud,
      :health_stale_after_seconds,
      @default_health_stale_after_seconds
    )
  end

  @doc """
  Consecutive missed ticks before the offline flip + alert. Default
  #{@default_health_down_after_count} (Coolify's `unreachable_count >= 2`);
  overridable via `config :barkpark_cloud, :health_down_after_count`.
  """
  @spec health_down_after_count() :: pos_integer()
  def health_down_after_count do
    Application.get_env(
      :barkpark_cloud,
      :health_down_after_count,
      @default_health_down_after_count
    )
  end

  ## Billing suspension — the teeth behind a lapsed subscription.

  @doc """
  Suspend every MANAGED Barkpark a `team` owns — the billing-lapse enforcement
  (Coolify-anchor: `Team::subscriptionEnded()` walks `team->servers` and disables
  each). `reason` is `"billing_lapsed"` | `"billing_past_due"`.

  One bulk `UPDATE` (`Repo.update_all`), not a per-row changeset loop, so a fleet
  of N boxes is suspended in a single statement. IDEMPOTENT: the
  `suspended == false` guard means a second call suspends nothing (count 0) and
  never re-stamps `suspended_at`. Only `mode == "managed"` rows are touched —
  self-hosted / byo instances aren't ours to disable (Coolify-anchor: a
  self-hosted install is exempt from billing entirely).

  Returns `{:ok, count}` — the number of rows newly suspended.
  """
  @spec suspend_team_barkparks(Team.t() | binary(), String.t()) :: {:ok, non_neg_integer()}
  def suspend_team_barkparks(team, reason) when is_binary(reason) do
    tid = team_id(team)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    {count, _} =
      Barkpark
      |> where([b], b.team_id == ^tid and b.suspended == false and b.mode == "managed")
      |> Repo.update_all(
        set: [suspended: true, suspended_reason: reason, suspended_at: now, updated_at: now]
      )

    {:ok, count}
  end

  @doc """
  Lift suspension on every Barkpark a `team` owns — billing recovered. Bulk
  `UPDATE`, idempotent via the `suspended == true` guard (a second call clears
  nothing). Clears the reason + timestamp. Returns `{:ok, count}`.
  """
  @spec resume_team_barkparks(Team.t() | binary()) :: {:ok, non_neg_integer()}
  def resume_team_barkparks(team) do
    tid = team_id(team)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    {count, _} =
      Barkpark
      |> where([b], b.team_id == ^tid and b.suspended == true)
      |> Repo.update_all(
        set: [suspended: false, suspended_reason: nil, suspended_at: nil, updated_at: now]
      )

    {:ok, count}
  end

  ## Quota reconciler suspension — the reversible plan-ceiling enforcement.
  #
  # A SEPARATE axis from the bulk billing-lapse suspend above: these single-row
  # helpers stamp/clear the `"quota_exceeded"` reason (driven by
  # `Billing.reconcile_plan_limit/1`), so a downgrade suspend and a billing-lapse
  # suspend never restore each other. All three reuse main's `suspend_changeset`
  # and `suspended*` columns — no new schema.

  @doc """
  usage-limits-quotas: a Team's QUOTA-suspended instances (reason
  `"quota_exceeded"`), OLDEST first. The downgrade reconciler suspends
  NEWEST-first; the recovery sweep re-enables in this (oldest-first) order so the
  earliest-bought boxes come back first. Deliberately scoped to the quota reason
  so a billing-lapsed box is never listed here (and so never auto-restored).
  """
  @spec list_quota_suspended_barkparks(Team.t() | binary()) :: [Barkpark.t()]
  def list_quota_suspended_barkparks(team) do
    tid = team_id(team)

    Barkpark
    |> where([b], b.team_id == ^tid and b.suspended_reason == ^Billing.quota_suspended_reason())
    |> order_by([b], asc: b.inserted_at)
    |> Repo.all()
  end

  @doc """
  usage-limits-quotas: stamp `barkpark`'s reconciler-suspension marker with
  `reason` (Coolify's reversible force-disable). CONTROL-PLANE truth only — flips
  the flags the dashboard renders and the agent gate reads; physically pausing
  the on-box agent is a Go-worker follow-up (the same boundary
  `delete_barkpark/1` documents). Reuses the narrow `suspend_changeset`.
  """
  @spec suspend_barkpark(Barkpark.t(), String.t()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def suspend_barkpark(%Barkpark{} = barkpark, reason) when is_binary(reason) do
    barkpark
    |> Barkpark.suspend_changeset(%{
      suspended: true,
      suspended_reason: reason,
      suspended_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    })
    |> Repo.update()
  end

  @doc """
  usage-limits-quotas: clear `barkpark`'s suspension marker — the reversible
  recovery half (re-enable exactly what a downgrade suspended). Clears the reason
  and timestamp too, so a restored box carries no stale suspension state.
  """
  @spec unsuspend_barkpark(Barkpark.t()) :: {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def unsuspend_barkpark(%Barkpark{} = barkpark) do
    barkpark
    |> Barkpark.suspend_changeset(%{suspended: false, suspended_reason: nil, suspended_at: nil})
    |> Repo.update()
  end

  # dwb-4: the content-template catalog the go-live handler validates against.
  # MIRRORS the Go worker's embedded catalog (internal/provisioner/catalog —
  # TestCatalogCarriesTheThreeTemplates locks that side to this exact list); an
  # unknown slug must be rejected HERE, at launch (a 4xx), never discovered on a
  # burned box mid-provision.
  @known_templates ~w(blog-starter place-directory website-starter)

  @doc """
  The valid content-template slugs a launch may carry (dwb-4) — sorted, mirroring
  the Go worker's embedded catalog (`catalog.Names()`).
  """
  @spec known_templates() :: [String.t()]
  def known_templates, do: @known_templates

  @doc "Is `slug` a known content-template? (dwb-4 launch validation.)"
  @spec known_template?(String.t()) :: boolean()
  def known_template?(slug) when is_binary(slug), do: slug in @known_templates
  def known_template?(_), do: false

  ## Provisioning jobs — the queue bridging this control plane and the Go worker

  @doc """
  Enqueue a `pending` provision job for `barkpark` — the async half of go-live,
  and the target of the Retry path. After the pay + registry write, this is what
  hands the work to the off-box Go warm-pool provisioner.

  IDEMPOTENT under double-submit (dwb-11): if an ACTIVE (pending/claimed)
  provision job already exists for this barkpark, returns `{:error,
  :already_provisioning}` rather than enqueuing a second one — a double-click
  Retry can NEVER open a second concurrent provision (and bill a second box). The
  app-level `active_provision_job?/1` check is the friendly fast path; the partial
  unique index `provision_jobs_one_active_per_barkpark_kind_idx` is the atomic
  race backstop (two truly-concurrent enqueues that both pass the check collide on
  insert, and the loser's constraint error is translated to the same
  `:already_provisioning`). A terminal succeeded/failed job never blocks — a
  legitimate retry after a failure still enqueues.
  """
  @spec enqueue_provision_job(Barkpark.t() | binary()) ::
          {:ok, ProvisionJob.t()} | {:error, :already_provisioning | Ecto.Changeset.t()}
  def enqueue_provision_job(barkpark) do
    bp_id = barkpark_id(barkpark)

    if active_job_of_kind?(bp_id, "provision") do
      {:error, :already_provisioning}
    else
      %ProvisionJob{}
      |> ProvisionJob.changeset(%{barkpark_id: bp_id, status: "pending"})
      |> Repo.insert()
      |> translate_active_job_conflict(:already_provisioning)
    end
  end

  @doc """
  Enqueue a `pending` DEPROVISION job for `barkpark` — the Remove path. The Go
  worker drains it, deletes the Hetzner box (resolved by its `host` IP from the
  `barkpark-managed` label list) + the DNS record, and reports back; on success
  the control plane deletes the barkpark row (`succeed_deprovision_job/1`).

  Guarded against a duplicate concurrent removal: if an ACTIVE (pending/claimed)
  deprovision job already exists for this barkpark, returns `{:error,
  :already_deprovisioning}` rather than enqueuing a second one.
  """
  @spec enqueue_deprovision_job(Barkpark.t() | binary()) ::
          {:ok, ProvisionJob.t()} | {:error, :already_deprovisioning | Ecto.Changeset.t()}
  def enqueue_deprovision_job(barkpark) do
    bp_id = barkpark_id(barkpark)

    if active_deprovision_job?(bp_id) do
      {:error, :already_deprovisioning}
    else
      %ProvisionJob{}
      |> ProvisionJob.changeset(%{barkpark_id: bp_id, kind: "deprovision", status: "pending"})
      |> Repo.insert()
      # dwb-11: the app-level check above is check-then-insert; two concurrent
      # Removes can both pass it. The partial unique index is the atomic backstop
      # — translate the loser's constraint error to the same dedup signal so a
      # racing double-remove is idempotent, never two teardown jobs.
      |> translate_active_job_conflict(:already_deprovisioning)
    end
  end

  defp active_deprovision_job?(barkpark_id) do
    active_job_of_kind?(barkpark_id, "deprovision")
  end

  # dwb-11: map a lost race on the one-active-job-per-barkpark-kind partial unique
  # index to a clean dedup atom. Any OTHER changeset error (or the {:ok, _} happy
  # path) passes through unchanged — only the money-path collision is rewritten.
  defp translate_active_job_conflict({:ok, _} = ok, _atom), do: ok

  defp translate_active_job_conflict({:error, %Ecto.Changeset{errors: errors}} = err, atom) do
    if Enum.any?(errors, fn {_field, {_msg, opts}} ->
         Keyword.get(opts, :constraint_name) ==
           "provision_jobs_one_active_per_barkpark_kind_idx"
       end) do
      {:error, atom}
    else
      err
    end
  end

  @doc """
  Cancel every still-PENDING deprovision job for `team`'s barkparks — the
  money-path guard the trial→paid conversion calls (dwb-13). If the trial-expiry
  worker enqueued a teardown just before a team subscribed, this deletes those
  not-yet-claimed jobs so a now-paying team's boxes are never torn down. Only
  `pending` rows are deleted — a `claimed` job is already mid-teardown at the Go
  worker and is not ours to yank. Returns the count deleted.
  """
  @spec cancel_pending_deprovision_jobs(Team.t() | binary()) :: non_neg_integer()
  def cancel_pending_deprovision_jobs(team) do
    tid = team_id(team)

    {count, _} =
      from(j in ProvisionJob,
        join: b in Barkpark,
        on: b.id == j.barkpark_id,
        where: b.team_id == ^tid and j.kind == "deprovision" and j.status == "pending"
      )
      |> Repo.delete_all()

    count
  end

  @doc """
  True when `barkpark` has a PROVISION job still in flight (pending or claimed) —
  the guard the Remove path uses for a not-yet-live (host nil) instance: deleting
  the registry row mid-provision would let the worker bring a box up that the
  control plane then can't see (succeed_job no-ops on the missing barkpark),
  leaving a LIVE, BILLED box with no row and no deprovision job. The DELETE route
  refuses (409) while a provision is in flight.
  """
  @spec active_provision_job?(Barkpark.t() | binary()) :: boolean()
  def active_provision_job?(barkpark), do: active_job_of_kind?(barkpark_id(barkpark), "provision")

  defp active_job_of_kind?(barkpark_id, kind) do
    from(j in ProvisionJob,
      where:
        j.barkpark_id == ^barkpark_id and j.kind == ^kind and
          j.status in ["pending", "claimed"],
      limit: 1,
      select: 1
    )
    |> Repo.one()
    |> case do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Atomically claim the next claimable provision job for `claim_token`. This is
  the worker's pull, and it is the canonical Postgres job-claim: one transaction
  that SELECTs the oldest claimable row `FOR UPDATE SKIP LOCKED LIMIT 1` and
  UPDATEs that same locked row to `claimed`. The row-level lock makes the claim
  self-evidently race-safe — a second worker polling concurrently SKIPs the
  locked row and grabs the next claimable one, so two workers can never claim the
  same job (no CAS retry loop needed; the database serializes the contention).

  A row is *claimable* when it is either:

    * `pending` — never claimed, OR
    * `claimed` but STALE — `claimed_at` older than the staleness threshold
      (`stale_after_seconds/0`, default the worker's provision timeout + margin).
      A stale claim means the worker crashed or its succeed/fail report failed in
      transit and — per the worker contract — it tore down its box and LEFT the
      row "claimed"; re-claiming it runs a fresh attempt. A FRESH `claimed` row
      (within the threshold) is NOT re-claimable, so a live worker is never raced.

  Stale recovery is BOUNDED by `attempts`: every (re)claim bumps `attempts`. A
  stale row whose `attempts` have already reached `max_provision_attempts/0` is
  transitioned to `"failed"` ("exceeded max provision attempts") instead of being
  handed out again, and the claim moves on to the next claimable row — so a
  permanently-failing job stops looping forever.

  Returns `{job, barkpark}` for the claimed job, or `nil` when nothing is
  claimable (the worker's 204 / sleep path).
  """
  @spec claim_next_job(String.t(), String.t()) :: {ProvisionJob.t(), Barkpark.t()} | nil
  def claim_next_job(claim_token, kind \\ "provision")
      when is_binary(claim_token) and is_binary(kind) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    stale_before = DateTime.add(now, -stale_after_seconds(), :second)
    max_attempts = max_provision_attempts()

    result =
      Repo.transaction(fn ->
        claim_loop(claim_token, kind, now, stale_before, max_attempts)
      end)

    case result do
      {:ok, claim} -> claim
      {:error, _} -> nil
    end
  end

  @doc """
  Atomically claim the next claimable DEPROVISION job — the Remove path's worker
  pull. Same machinery as `claim_next_job/2`, filtered to `kind: "deprovision"`.
  """
  @spec claim_next_deprovision_job(String.t()) :: {ProvisionJob.t(), Barkpark.t()} | nil
  def claim_next_deprovision_job(claim_token) when is_binary(claim_token),
    do: claim_next_job(claim_token, "deprovision")

  # Lock the oldest claimable row (pending, or claimed-but-stale); concurrent
  # claimers SKIP LOCKED past it. If a stale row has burned through its attempt
  # budget, fail it and recurse to the next claimable row (so an over-budget job
  # never blocks a younger pending one); otherwise (re)claim it, bumping attempts.
  defp claim_loop(claim_token, kind, now, stale_before, max_attempts) do
    locked =
      from(j in ProvisionJob,
        where:
          j.kind == ^kind and
            (j.status == "pending" or
               (j.status == "claimed" and j.claimed_at < ^stale_before)),
        order_by: [asc: j.inserted_at, asc: j.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    case Repo.one(locked) do
      nil ->
        nil

      %ProvisionJob{status: "claimed", attempts: attempts} = job when attempts >= max_attempts ->
        # A stale claim that already exhausted its attempt budget: fail it (don't
        # hand it out again) and keep looking for another claimable job.
        {:ok, _failed} =
          job
          |> ProvisionJob.changeset(%{
            status: "failed",
            error: "exceeded max #{kind} attempts (#{max_attempts})"
          })
          |> Repo.update()

        claim_loop(claim_token, kind, now, stale_before, max_attempts)

      %ProvisionJob{} = job ->
        {:ok, claimed} =
          job
          |> ProvisionJob.changeset(%{
            status: "claimed",
            claim_token: claim_token,
            claimed_at: now,
            attempts: job.attempts + 1
          })
          |> Repo.update()

        {claimed, Repo.get(Barkpark, claimed.barkpark_id)}
    end
  end

  @doc """
  Mark provision job `id` succeeded with the provisioned host `ip`, and flip the
  owning Barkpark to live: `health_status: "up"`, `host: ip`, and
  `agent_status: "offline"` (the on-box agent hasn't phoned home yet — that's a
  separate signal the agent report later flips to online).

  IDEMPOTENT + status-guarded, keyed on the job's current status:

    * `"claimed"` (the normal path) — flip the job to `"succeeded"` AND upsert the
      barkpark to up, atomically (see the transaction below).
    * `"succeeded"` (a RETRIED/duplicate succeed) — return `{:ok, job}` WITHOUT
      re-running the barkpark health/host upsert or any other side-effect. This is
      what self-heals a LOST-RESPONSE split-brain: the box was already committed
      live, the worker's HTTP response was dropped, the worker re-POSTs, and this
      re-POST returns 200 so the worker KEEPS the box (no double work, no teardown
      of a box the control plane already holds live).
    * any other TERMINAL state (`"failed"` — from the attempt cap or an explicit
      fail) — return `{:error, :conflict}` (→ 409). "failed" is genuinely terminal:
      we do NOT flip it to "succeeded" and do NOT touch the barkpark. The Go worker
      treats the 4xx as "the control plane gave up on this job — tear down the
      orphan box", which is correct.

  Returns `{:ok, %ProvisionJob{}}`, `{:error, :not_found}` when no job has that id,
  or `{:error, :conflict}` for a succeed against a terminal non-succeeded job.

  `opts` may carry `:admin_token` — the per-instance admin bearer the worker
  minted on the box (instance-admin-token). When present (a non-empty binary) it
  is encrypted at rest (`Vault.encrypt/1`) and persisted on the barkpark row in
  the SAME transaction as the host/health flip, so the owner can later retrieve
  it from the product instead of SSHing in. Absent/blank → the ip-only path is
  unchanged (back-compat; the column stays nil).

  `opts` may also carry `:bootstrap` (dwb-4) — the content-bootstrap outputs map
  the worker reported (`%{"workspace" => …, "project" => …, "dataset" => …,
  "read_token" => …, "env" => %{…}}`). The plain slugs land as columns; the read
  token and the env map (which contains the read token) are Vault-encrypted in
  the SAME transaction. Absent → the columns stay nil.
  """
  @spec succeed_job(binary(), String.t(), keyword()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | :conflict | Ecto.Changeset.t()}
  def succeed_job(id, ip, opts \\ []) when is_binary(id) and is_binary(ip) and is_list(opts) do
    admin_token = Keyword.get(opts, :admin_token)
    bootstrap = Keyword.get(opts, :bootstrap)

    case uuid_or_nil(id) && Repo.get(ProvisionJob, id) do
      nil ->
        {:error, :not_found}

      # IDEMPOTENT: an already-succeeded job. Return it unchanged — NO re-upsert of
      # the barkpark, no error. A dropped response + worker re-POST lands here and
      # gets a 200, so the worker keeps the live box.
      %ProvisionJob{status: "succeeded"} = job ->
        {:ok, job}

      # STATUS GUARD: a job in a terminal NON-succeeded state ("failed"). Terminal
      # is terminal — don't resurrect it into "succeeded", don't touch the barkpark.
      %ProvisionJob{status: "failed"} ->
        {:error, :conflict}

      %ProvisionJob{} = job ->
        # ONE transaction: the job-status flip AND the barkpark health/host upsert
        # commit or roll back together. Before this, the flip ran first and the
        # health upsert's result was DISCARDED — so a failing upsert (e.g. the
        # global :url unique index, or a validation) left the job "succeeded" but
        # the barkpark still provisioning/host=nil: a silent split-brain where the
        # customer is billed for a box the dashboard never shows. Now either both
        # land or neither does, and the upsert failure surfaces (logged + the whole
        # call returns {:error, changeset}) instead of being swallowed.
        result =
          Repo.transaction(fn ->
            with {:ok, job} <-
                   job
                   |> ProvisionJob.changeset(%{status: "succeeded", result_ip: ip})
                   |> Repo.update(),
                 {:ok, _barkpark} <- upsert_succeeded_barkpark(job, ip, admin_token, bootstrap) do
              job
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        case result do
          {:ok, job} ->
            {:ok, job}

          {:error, reason} ->
            Logger.error(
              "succeed_job: rolled back job #{id} — barkpark health upsert failed: " <>
                inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  # The barkpark-side half of a successful provision, run INSIDE succeed_job's
  # transaction: flip the owning barkpark to up at `ip`. A missing barkpark row
  # (the FK is on_delete: :delete_all, so this is the deleted-mid-provision edge)
  # is treated as a no-op success — there is nothing to flip and the job flip
  # should still stand.
  defp upsert_succeeded_barkpark(
         %ProvisionJob{barkpark_id: barkpark_id},
         ip,
         admin_token,
         bootstrap
       ) do
    case Repo.get(Barkpark, barkpark_id) do
      nil ->
        {:ok, nil}

      %Barkpark{} = barkpark ->
        %{health_status: "up", host: ip, agent_status: "offline"}
        |> maybe_put_admin_token(admin_token)
        |> maybe_put_bootstrap(bootstrap)
        |> then(&upsert_health(barkpark, &1))
    end
  end

  # instance-admin-token: when the worker reported the minted admin token, encrypt
  # it (Vault — the same at-rest seam as the provider token) and fold it into the
  # provision-success write. A missing/blank token leaves the attrs untouched so
  # the ip-only succeed path is unchanged.
  defp maybe_put_admin_token(attrs, token) when is_binary(token) and token != "" do
    Map.put(attrs, :admin_token_encrypted, Vault.encrypt(token))
  end

  defp maybe_put_admin_token(attrs, _token), do: attrs

  # dwb-4: fold the worker-reported bootstrap outputs into the provision-success
  # write. Plain slugs land as columns; the read token — and the env map, which
  # CONTAINS the read token — are Vault-encrypted (the env map as one JSON blob).
  # A missing/blank/non-map payload leaves the attrs untouched (back-compat).
  defp maybe_put_bootstrap(attrs, %{} = boot) do
    attrs
    |> put_bootstrap_plain(:bootstrap_workspace, boot["workspace"])
    |> put_bootstrap_plain(:bootstrap_project, boot["project"])
    |> put_bootstrap_plain(:bootstrap_dataset, boot["dataset"])
    |> put_bootstrap_encrypted(:bootstrap_read_token_encrypted, boot["read_token"])
    |> put_bootstrap_env(boot["env"])
  end

  defp maybe_put_bootstrap(attrs, _), do: attrs

  defp put_bootstrap_plain(attrs, key, v) when is_binary(v) and v != "",
    do: Map.put(attrs, key, v)

  defp put_bootstrap_plain(attrs, _key, _v), do: attrs

  defp put_bootstrap_encrypted(attrs, key, v) when is_binary(v) and v != "",
    do: Map.put(attrs, key, Vault.encrypt(v))

  defp put_bootstrap_encrypted(attrs, _key, _v), do: attrs

  defp put_bootstrap_env(attrs, %{} = env) when map_size(env) > 0 do
    Map.put(attrs, :bootstrap_env_encrypted, Vault.encrypt(Jason.encode!(env)))
  end

  defp put_bootstrap_env(attrs, _), do: attrs

  @doc """
  Mark provision job `id` failed with `error`. The owning Barkpark stays in its
  provisioning state (health_status unchanged) — a fail is terminal here (no
  retries/backoff, YAGNI), and a human (or a re-launch) is the recovery path.

  IDEMPOTENT + status-guarded, keyed on the job's current status:

    * `"failed"` (a RETRIED/duplicate fail) — return `{:ok, job}` unchanged (→ 200),
      no re-write. A dropped fail-response + worker re-POST self-heals here.
    * `"succeeded"` — return `{:error, :conflict}` (→ 409). Do NOT un-succeed a job
      whose box is already live: a straggler fail must never tear down a live box.
    * `"claimed"` / `"pending"` (the normal path) — flip to `"failed"`.

  Returns `{:ok, %ProvisionJob{}}`, `{:error, :not_found}`, or `{:error, :conflict}`
  for a fail against an already-succeeded job.
  """
  @spec fail_job(binary(), String.t()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | :conflict | Ecto.Changeset.t()}
  def fail_job(id, error) when is_binary(id) do
    case uuid_or_nil(id) && Repo.get(ProvisionJob, id) do
      nil ->
        {:error, :not_found}

      # IDEMPOTENT: an already-failed job. Return it unchanged — no re-write, so a
      # retried/duplicate fail (lost response) self-heals to 200.
      %ProvisionJob{status: "failed"} = job ->
        {:ok, job}

      # STATUS GUARD: never un-succeed a live box. A straggler fail for a job that
      # already succeeded is a 409, and the barkpark is left up.
      %ProvisionJob{status: "succeeded"} ->
        {:error, :conflict}

      %ProvisionJob{} = job ->
        job
        |> ProvisionJob.changeset(%{status: "failed", error: error})
        |> Repo.update()
    end
  end

  @doc """
  dwb-14: APPEND one worker-reported step transition to a provision job's
  narration array. `step` ∈ create|secure|configure|content|ready, `status` ∈
  started|done|failed; `detail` is an optional short string (e.g. a failure
  reason). The `at` timestamp is stamped HERE (server clock — the single source
  of truth for elapsed-time rendering), never trusted from the worker.

  Best-effort telemetry, NOT control flow: it appends regardless of the job's
  current status (a late report after a job already succeeded/failed is still a
  truthful record of what happened) — the guards are that the job exists and the
  step/status pair is known. The array is APPEND-ONLY and CAPPED at
  `@max_step_entries` (oldest dropped) so a chatty/looping worker can't grow the
  provision_jobs row unbounded. Returns `{:ok, job}` with the appended array,
  `{:error, :not_found}` for an unknown id, or `{:error, :invalid_step}` for an
  unknown step/status pair. Never raises on a normal report.
  """
  @spec append_provision_step(binary(), term(), term(), term()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | :invalid_step}
  def append_provision_step(id, step, status, detail \\ nil) when is_binary(id) do
    with {:ok, {step, status}} <- ProvisionJob.validate_step(step, status),
         %ProvisionJob{} = job <- uuid_or_nil(id) && Repo.get(ProvisionJob, id) do
      entry = %{
        "step" => step,
        "status" => status,
        "detail" => if(is_binary(detail) and detail != "", do: detail, else: nil),
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      job
      |> ProvisionJob.changeset(%{steps: cap_steps((job.steps || []) ++ [entry])})
      |> Repo.update()
    else
      :error -> {:error, :invalid_step}
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  dwb-16: APPEND one worker-reported LIVE console line to a provision job. Like
  `append_provision_step/4` this is best-effort telemetry — it records what the
  worker narrated regardless of the job's current status (a late line after a job
  succeeded/failed is still a truthful record), and NEVER raises on a normal
  report. The array is APPEND-ONLY and CAPPED at `@max_console_lines` (oldest
  dropped) so a chatty/looping worker can't grow the row unbounded. Each element
  is `%{"line" => line, "at" => iso8601}`.

  Returns `{:ok, job}` with the appended array, `{:error, :not_found}` for an
  unknown id, or `{:error, :invalid}` for a missing/blank/oversized line (the
  router 422s it rather than persisting garbage).
  """
  @spec append_provision_console(binary(), term()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | :invalid}
  def append_provision_console(id, line) when is_binary(id) do
    with {:ok, line} <- validate_console_line(line),
         %ProvisionJob{} = job <- uuid_or_nil(id) && Repo.get(ProvisionJob, id) do
      entry = %{"line" => line, "at" => DateTime.to_iso8601(DateTime.utc_now())}
      console = cap_console((job.console || []) ++ [entry])

      job
      |> ProvisionJob.changeset(%{console: console})
      |> Repo.update()
    else
      :error -> {:error, :invalid}
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # A console line must be a non-blank binary; it is trimmed of a trailing newline
  # and hard-capped at 2 KB so one pathological line can't bloat the row. Anything
  # else (nil, a number, a map) is rejected → 422.
  defp validate_console_line(line) when is_binary(line) do
    trimmed = String.trim_trailing(line)

    cond do
      trimmed == "" -> :error
      String.length(trimmed) > 2_000 -> {:ok, String.slice(trimmed, 0, 2_000)}
      true -> {:ok, trimmed}
    end
  end

  defp validate_console_line(_), do: :error

  # Keep only the last @max_console_lines entries (oldest dropped) — the append-only
  # cap that bounds the row size.
  defp cap_console(entries) when is_list(entries) do
    case length(entries) - @max_console_lines do
      drop when drop > 0 -> Enum.drop(entries, drop)
      _ -> entries
    end
  end

  # Keep only the last @max_step_entries entries (oldest dropped) — the append-only
  # cap that bounds the step-transition array.
  defp cap_steps(entries) when is_list(entries) do
    case length(entries) - @max_step_entries do
      drop when drop > 0 -> Enum.drop(entries, drop)
      _ -> entries
    end
  end

  @doc """
  dwb-15: RELEASE a claimed provision job back to `pending` for graceful worker
  shutdown, WITHOUT consuming an attempt. The worker calls this on SIGTERM (at a
  safe boundary) so the next worker re-claims in seconds instead of waiting the
  full stale-claim reaper threshold (>12 min).

  Status-guarded + idempotent, keyed on the job's current status:

    * `"claimed"` — flip to `"pending"`, clear `claim_token` + `claimed_at`, and
      DECREMENT `attempts` by one (floored at 0) so the claim that is being undone
      does not burn an attempt: the graceful release + re-claim is attempt-neutral.
    * `"pending"` — already released (a duplicate/retried release). `{:ok, job}`
      no-op — no attempt change, so a double release can't drive attempts negative.
    * `"succeeded"` / `"failed"` — terminal. `{:error, :conflict}` (→ 409): never
      resurrect a live box or a decided failure into pending.

  Returns `{:ok, job}`, `{:error, :not_found}`, or `{:error, :conflict}`.
  """
  @spec release_job(binary()) :: {:ok, ProvisionJob.t()} | {:error, :not_found | :conflict}
  def release_job(id) when is_binary(id) do
    case uuid_or_nil(id) && Repo.get(ProvisionJob, id) do
      nil ->
        {:error, :not_found}

      %ProvisionJob{status: "pending"} = job ->
        {:ok, job}

      %ProvisionJob{status: "claimed"} = job ->
        job
        |> ProvisionJob.changeset(%{
          status: "pending",
          claim_token: nil,
          claimed_at: nil,
          attempts: max(0, job.attempts - 1)
        })
        |> Repo.update()

      %ProvisionJob{} ->
        {:error, :conflict}
    end
  end

  @doc """
  oban-substrate: proactively recover provision jobs wedged in `claimed` past the
  staleness threshold, instead of waiting for the next `claim_next_job/1` to do it
  lazily. This is what `BarkparkCloud.Workers.StaleProvisionJobReaper` calls every
  minute so a crashed worker's job is recovered on a fixed cadence rather than
  only when the next claim happens to arrive.

  Outcomes are IDENTICAL to the lazy path (`claim_loop/5`), reusing the same
  `stale_after_seconds/0` threshold and `max_provision_attempts/0` budget so the
  two can never diverge — kind-agnostic (sweeps stale `provision` AND
  `deprovision` claims):

    * a stale `claimed` job still UNDER its attempt budget is flipped back to
      `pending` (claim_token / claimed_at cleared) so a fresh worker re-claims it.
      `attempts` is NOT bumped here — the re-claim bumps it, keeping the budget
      counted per claim exactly as the lazy path does.
    * a stale `claimed` job AT/OVER the budget is `failed`
      ("exceeded max <kind> attempts (<n>)") — terminal, so a permanently-failing
      job stops looping.

  Each row is moved with a status-guarded `update_all` (CAS on
  `id AND status == "claimed"`), so a race with the lazy path simply no-ops on the
  row the other path already moved (the guard matches zero rows). Returns
  `%{reaped: n, failed: m}`; an empty sweep returns `%{reaped: 0, failed: 0}` and
  never raises.
  """
  @spec reap_stale_provision_jobs() :: %{reaped: non_neg_integer(), failed: non_neg_integer()}
  def reap_stale_provision_jobs do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    stale_before = DateTime.add(now, -stale_after_seconds(), :second)
    max_attempts = max_provision_attempts()

    stale =
      from(j in ProvisionJob,
        where: j.status == "claimed" and j.claimed_at < ^stale_before
      )
      |> Repo.all()

    Enum.reduce(stale, %{reaped: 0, failed: 0}, fn job, acc ->
      if job.attempts >= max_attempts do
        # Over budget: fail it (don't re-hand-it-out). Guard on status == "claimed"
        # so a concurrent lazy reclaim/fail makes this a no-op (rows == 0).
        {rows, _} =
          from(j in ProvisionJob, where: j.id == ^job.id and j.status == "claimed")
          |> Repo.update_all(
            set: [
              status: "failed",
              error: "exceeded max #{job.kind} attempts (#{max_attempts})",
              updated_at: now
            ]
          )

        %{acc | failed: acc.failed + min(rows, 1)}
      else
        # Under budget: re-pend so a fresh claim_next_job picks it up (and bumps
        # attempts then). Same status guard against a racing lazy reclaim.
        {rows, _} =
          from(j in ProvisionJob, where: j.id == ^job.id and j.status == "claimed")
          |> Repo.update_all(
            set: [status: "pending", claim_token: nil, claimed_at: nil, updated_at: now]
          )

        %{acc | reaped: acc.reaped + min(rows, 1)}
      end
    end)
  end

  @doc """
  Mark deprovision job `id` succeeded — the box + DNS are gone — by DELETING the
  owning Barkpark row (cascade removes its sites + provision jobs, incl. this one).
  IDEMPOTENT: {:ok, :deleted} normal; {:ok, :already_gone} if the job/barkpark are
  already gone (retried succeed); {:error, :conflict} if the job is terminally
  "failed".
  """
  @spec succeed_deprovision_job(binary()) ::
          {:ok, :deleted | :already_gone} | {:error, :not_found | :conflict | Ecto.Changeset.t()}
  def succeed_deprovision_job(id) when is_binary(id) do
    case uuid_or_nil(id) && Repo.get(ProvisionJob, id) do
      nil ->
        {:ok, :already_gone}

      %ProvisionJob{status: "failed"} ->
        {:error, :conflict}

      %ProvisionJob{barkpark_id: bp_id} ->
        case Repo.get(Barkpark, bp_id) do
          nil ->
            {:ok, :already_gone}

          %Barkpark{} = bp ->
            case Repo.delete(bp) do
              {:ok, _} -> {:ok, :deleted}
              {:error, cs} -> {:error, cs}
            end
        end
    end
  end

  @doc """
  The latest provision job for each barkpark id in `ids`, as a map
  `%{barkpark_id => %{status: status, error: error}}`. One query via Postgres
  `DISTINCT ON (barkpark_id) ... ORDER BY barkpark_id, inserted_at DESC` so the
  dashboard fleet list can surface a FAILED provision (the failure lives on the
  job row, not the barkpark — a failed job leaves the barkpark health "unknown"
  / host nil, indistinguishable from still-provisioning without this). Ids with
  no job are simply absent from the map. Empty `ids` → empty map (no query).
  """
  @spec latest_provision_status_map([binary()]) :: %{
          binary() => %{
            status: String.t(),
            error: String.t() | nil,
            steps: [map()],
            console: [map()]
          }
        }
  def latest_provision_status_map([]), do: %{}

  def latest_provision_status_map(ids) when is_list(ids) do
    from(j in ProvisionJob,
      where: j.barkpark_id in ^ids and j.kind == "provision",
      order_by: [asc: j.barkpark_id, desc: j.inserted_at, desc: j.id],
      distinct: j.barkpark_id,
      # dwb-14: steps ride along so the /new progress screen renders SERVER-reported
      # transitions (refresh-durable) instead of a pure client-side timer. dwb-16:
      # console rides along too so the /new live console recovers after a refresh.
      select: {j.barkpark_id, j.status, j.error, j.steps, j.console}
    )
    |> Repo.all()
    |> Map.new(fn {bp_id, status, error, steps, console} ->
      {bp_id, %{status: status, error: error, steps: steps || [], console: console || []}}
    end)
  end

  @doc """
  The latest DEPROVISION job per barkpark id, as `%{barkpark_id => %{status:,
  error:}}` — the dashboard shows "Removing…" (pending/claimed) or a failed
  removal. Filtered to `kind: "deprovision"`.
  """
  @spec latest_deprovision_status_map([binary()]) :: %{
          binary() => %{status: String.t(), error: String.t() | nil}
        }
  def latest_deprovision_status_map([]), do: %{}

  def latest_deprovision_status_map(ids) when is_list(ids) do
    from(j in ProvisionJob,
      where: j.barkpark_id in ^ids and j.kind == "deprovision",
      order_by: [asc: j.barkpark_id, desc: j.inserted_at, desc: j.id],
      distinct: j.barkpark_id,
      select: {j.barkpark_id, j.status, j.error}
    )
    |> Repo.all()
    |> Map.new(fn {bp_id, status, error} -> {bp_id, %{status: status, error: error}} end)
  end

  @doc """
  The most recent provision job for `barkpark`, or nil. Used by the retry path
  to gate re-enqueue on a genuinely FAILED last attempt (so a retry can't open a
  second concurrent provision — and a second billed box — while one is still
  pending/claimed/succeeded).
  """
  @spec latest_provision_job(Barkpark.t() | binary()) :: ProvisionJob.t() | nil
  def latest_provision_job(barkpark) do
    bp_id = barkpark_id(barkpark)

    from(j in ProvisionJob,
      where: j.barkpark_id == ^bp_id and j.kind == "provision",
      order_by: [desc: j.inserted_at, desc: j.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "The warm-pool default region a provision job carries when unset."
  @spec default_region() :: String.t()
  def default_region, do: @default_region

  @doc "The warm-pool default server_type a provision job carries when unset."
  @spec default_server_type() :: String.t()
  def default_server_type, do: @default_server_type

  @doc """
  Seconds a `claimed` job may sit before claim_next_job treats it as abandoned and
  re-claimable. Defaults to the worker provision timeout + margin
  (#{@default_stale_after_seconds}s); overridable via
  `config :barkpark_cloud, :provision_stale_after_seconds`.
  """
  @spec stale_after_seconds() :: pos_integer()
  def stale_after_seconds do
    Application.get_env(
      :barkpark_cloud,
      :provision_stale_after_seconds,
      @default_stale_after_seconds
    )
  end

  @doc """
  Max times a job may be (re)claimed before a stale claim is failed
  ("exceeded max provision attempts") instead of re-handed-out. Defaults to
  #{@default_max_provision_attempts}; overridable via
  `config :barkpark_cloud, :max_provision_attempts`.
  """
  @spec max_provision_attempts() :: pos_integer()
  def max_provision_attempts do
    Application.get_env(:barkpark_cloud, :max_provision_attempts, @default_max_provision_attempts)
  end

  @doc """
  Seconds a `building` deployment may sit before reap_stale_deployments treats its
  builder lease as abandoned (the builder crashed, or its success/failure report
  was lost in transit) and requeues/fails the row. Defaults to
  #{@default_deployment_stale_after_seconds}s; overridable via
  `config :barkpark_cloud, :deployment_stale_after_seconds`.
  """
  @spec deployment_stale_after_seconds() :: pos_integer()
  def deployment_stale_after_seconds do
    Application.get_env(
      :barkpark_cloud,
      :deployment_stale_after_seconds,
      @default_deployment_stale_after_seconds
    )
  end

  @doc """
  Max times a deployment may be (re)claimed before a stale `building` lease is
  `failed` ("exceeded max deploy claim attempts") instead of re-queued. Defaults
  to #{@default_max_deploy_claims}; overridable via
  `config :barkpark_cloud, :max_deploy_claims`.
  """
  @spec max_deploy_claims() :: pos_integer()
  def max_deploy_claims do
    Application.get_env(:barkpark_cloud, :max_deploy_claims, @default_max_deploy_claims)
  end

  ## Warm pool (dwb-10)

  @doc """
  Register a pre-baked warm box the worker just created. IDEMPOTENT on `name`
  (`on_conflict: :nothing`) so a retried register never inserts a duplicate pool
  row. Returns `{:ok, %WarmServer{}}` (the id may be nil on a conflict skip) or
  `{:error, changeset}` on a shape violation.
  """
  @spec register_warm_server(String.t(), String.t() | nil) ::
          {:ok, WarmServer.t()} | {:error, Ecto.Changeset.t()}
  def register_warm_server(name, ip) when is_binary(name) do
    %WarmServer{}
    |> WarmServer.changeset(%{name: name, ip: ip, status: "ready"})
    |> Repo.insert(on_conflict: :nothing, conflict_target: :name)
  end

  @doc """
  Atomically claim the oldest `ready` warm box for an ASSIGN (ready → claimed).
  Returns `%WarmServer{}` for the claimed box, or `nil` when the pool is empty
  (the go-live's fall-through-to-one-shot signal).

  Race-safe: the SELECT (`FOR UPDATE SKIP LOCKED LIMIT 1`) and the flip happen in
  ONE transaction, so concurrent claimers lock disjoint rows — at most one wins
  any row. Stale claimed/retiring rows are reaped first so the table self-cleans.
  """
  @spec claim_warm_server(String.t()) :: WarmServer.t() | nil
  def claim_warm_server(claim_token) when is_binary(claim_token),
    do: claim_warm(claim_token, "claimed")

  @doc """
  Atomically claim the oldest `ready` warm box for RETIREMENT (ready → retiring)
  — the pool-size reconciler's lever for deleting an EXCESS box. Separate status
  from an assign claim, so an assigned box is never simultaneously retired: both
  select `ready` under SKIP LOCKED, which hands each a DISTINCT row. Returns
  `%WarmServer{}` or `nil` when there is no ready box to retire.
  """
  @spec claim_warm_server_for_retire(String.t()) :: WarmServer.t() | nil
  def claim_warm_server_for_retire(claim_token) when is_binary(claim_token),
    do: claim_warm(claim_token, "retiring")

  defp claim_warm(claim_token, new_status) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    result =
      Repo.transaction(fn ->
        # Self-clean: drop stale claimed/retiring rows (crashed-mid-consume) so
        # they don't accumulate. Bookkeeping only — never touches a Hetzner box.
        reap_stale_warm_query(now) |> Repo.delete_all()

        locked =
          from(w in WarmServer,
            where: w.status == "ready",
            order_by: [asc: w.inserted_at, asc: w.id],
            limit: 1,
            lock: "FOR UPDATE SKIP LOCKED"
          )

        case Repo.one(locked) do
          nil ->
            nil

          %WarmServer{} = ws ->
            {:ok, claimed} =
              ws
              |> WarmServer.changeset(%{
                status: new_status,
                claim_token: claim_token,
                claimed_at: now
              })
              |> Repo.update()

            claimed
        end
      end)

    case result do
      {:ok, ws} -> ws
      {:error, _} -> nil
    end
  end

  @doc """
  Delete the warm row for `name` — called once a claimed box is consumed (assigned
  live, or torn down on a failed assign) or a retiring box is deleted. IDEMPOTENT:
  a missing row is a no-op. Returns `{:ok, rows_deleted}`.
  """
  @spec delete_warm_server(String.t()) :: {:ok, non_neg_integer()}
  def delete_warm_server(name) when is_binary(name) do
    {count, _} = from(w in WarmServer, where: w.name == ^name) |> Repo.delete_all()
    {:ok, count}
  end

  @doc "How many warm boxes are `ready` (unclaimed) — the reconciler's grow/shrink input."
  @spec count_ready_warm_servers() :: non_neg_integer()
  def count_ready_warm_servers do
    Repo.aggregate(from(w in WarmServer, where: w.status == "ready"), :count)
  end

  @doc """
  Delete warm rows stuck `claimed`/`retiring` past the stale threshold (a worker
  crashed between claiming and consuming/deleting the row). Bookkeeping only — the
  Go worker owns the Hetzner box's lifecycle; this never deletes a box. Returns the
  count reaped.
  """
  @spec reap_stale_warm_claims() :: non_neg_integer()
  def reap_stale_warm_claims do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    {count, _} = reap_stale_warm_query(now) |> Repo.delete_all()
    count
  end

  defp reap_stale_warm_query(now) do
    stale_before = DateTime.add(now, -warm_stale_after_seconds(), :second)

    from(w in WarmServer,
      where: w.status in ["claimed", "retiring"] and w.claimed_at < ^stale_before
    )
  end

  @doc """
  Seconds a `claimed`/`retiring` warm row may sit before reap_stale_warm_claims
  drops it. Overridable via `config :barkpark_cloud, :warm_stale_after_seconds`.
  """
  @spec warm_stale_after_seconds() :: pos_integer()
  def warm_stale_after_seconds do
    Application.get_env(
      :barkpark_cloud,
      :warm_stale_after_seconds,
      @default_warm_stale_after_seconds
    )
  end

  ## Agent events

  @doc """
  Append an event of `type` (`health`/`status`/`backup`/`tls`/`content`) with
  `payload` (a map) to `barkpark`'s stream.
  """
  @spec record_event(Barkpark.t() | binary(), String.t(), map()) ::
          {:ok, AgentEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_event(barkpark, type, payload \\ %{}) do
    %AgentEvent{}
    |> AgentEvent.changeset(%{
      barkpark_id: barkpark_id(barkpark),
      type: type,
      payload: payload
    })
    |> Repo.insert()
  end

  @doc "Most-recent `limit` events for `barkpark`, newest first."
  @spec recent_events(Barkpark.t() | binary(), pos_integer()) :: [AgentEvent.t()]
  def recent_events(barkpark, limit \\ 50) do
    bp_id = barkpark_id(barkpark)

    AgentEvent
    |> where([e], e.barkpark_id == ^bp_id)
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Most-recent `limit` events for `barkpark_id`, TEAM-SCOPED and 404-safe — the
  read behind `GET /v1/barkparks/:id/events`. Returns the events newest-first
  when the barkpark exists AND belongs to `team`; returns `nil` when the id is
  absent OR owned by another team (the SAME nil for both, so a caller cannot
  distinguish "wrong team" from "no such instance" — no existence leak, matching
  the `DELETE /v1/barkparks/:id` convention).
  """
  @spec recent_events_for_team(Team.t() | binary(), binary(), pos_integer()) ::
          [AgentEvent.t()] | nil
  def recent_events_for_team(team, barkpark_id, limit \\ 50) when is_binary(barkpark_id) do
    tid = team_id(team)

    case uuid_or_nil(barkpark_id) && Repo.get(Barkpark, barkpark_id) do
      %Barkpark{team_id: ^tid} = bp -> recent_events(bp, limit)
      _ -> nil
    end
  end

  ## Providers

  @doc """
  Connect a cloud `Provider` of `kind` (`hetzner`/etc.) for `team`, storing the
  account `token` ENCRYPTED at rest (`Vault.encrypt/1`). The plaintext token is
  never persisted. `opts` may carry `:label`.

  Returns `{:ok, %Provider{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec connect_provider(Team.t() | binary(), String.t(), binary(), keyword()) ::
          {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def connect_provider(team, kind, token, opts \\ []) when is_binary(token) do
    %Provider{}
    |> Provider.changeset(%{
      team_id: team_id(team),
      kind: kind,
      label: Keyword.get(opts, :label),
      encrypted_token: Vault.encrypt(token)
    })
    |> Repo.insert()
  end

  @doc "List a Team's connected providers, newest first. Scoped — never crosses teams."
  @spec list_providers(Team.t() | binary()) :: [Provider.t()]
  def list_providers(team) do
    tid = team_id(team)

    Provider
    |> where([p], p.team_id == ^tid)
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end

  @doc """
  Decrypt a stored provider token back to plaintext. Returns `{:ok, token}` or
  `:error` (tampered ciphertext fails closed). Call-site sugar over
  `Vault.decrypt/1` so consumers don't reach into the schema field directly.
  """
  @spec reveal_provider_token(Provider.t()) :: {:ok, binary()} | :error
  def reveal_provider_token(%Provider{encrypted_token: ciphertext}),
    do: Vault.decrypt(ciphertext)

  @doc """
  Decrypt a Barkpark's stored per-instance admin token back to plaintext
  (instance-admin-token). Returns `{:ok, token}` when one was reported + stored,
  `{:ok, nil}` when the row never got an admin token (the ip-only succeed path, or
  a pre-feature instance), or `:error` when the stored ciphertext is tampered
  (`Vault.decrypt/1` fails closed). The owner-facing `/credentials` route is the
  only caller — it is show-to-owner, team-admin-gated.
  """
  @spec reveal_admin_token(Barkpark.t()) :: {:ok, binary() | nil} | :error
  def reveal_admin_token(%Barkpark{admin_token_encrypted: nil}), do: {:ok, nil}

  def reveal_admin_token(%Barkpark{admin_token_encrypted: ciphertext}),
    do: Vault.decrypt(ciphertext)

  @doc """
  Mint a one-click Studio login URL for a live instance (dwb-7 "Studio
  one-click entry").

  Uses the stored per-instance admin token SERVER-SIDE to call the instance's
  `POST /v1/auth/login-tickets`, which returns a single-use, 60s opaque ticket
  bound to that token. The result is `{:ok, "<instance-url>/login/ticket/<t>"}` —
  the browser opens it once, the instance sets the session, Studio loads. The
  admin token itself NEVER leaves this function (not in the URL, not in the
  response, not logged) — only the short-lived ticket does.

  Errors: `:not_live` (no `url` yet — still provisioning/failed),
  `:no_admin_token` (row never got one; mirrors the `/credentials` 404),
  `:decrypt_failed` (tampered ciphertext, fail-closed), `:instance_error`
  (the instance call failed or returned a non-ticket).

  Transport is the swappable `:studio_link_http_client` module (default
  `BarkparkCloud.Billing.HttpClient` — verified TLS `:httpc`; tests wire
  `BarkparkCloud.StudioLinkFakeHttpClient`).
  """
  @spec mint_studio_link(Barkpark.t()) ::
          {:ok, String.t()}
          | {:error, :not_live | :no_admin_token | :decrypt_failed | :instance_error}
  def mint_studio_link(%Barkpark{url: url} = bp) when is_binary(url) and url != "" do
    case reveal_admin_token(bp) do
      {:ok, nil} ->
        {:error, :no_admin_token}

      :error ->
        {:error, :decrypt_failed}

      {:ok, admin_token} ->
        base = String.trim_trailing(url, "/")

        request = %{
          method: :post,
          url: base <> "/v1/auth/login-tickets",
          headers: [
            {"Authorization", "Bearer " <> admin_token},
            {"Accept", "application/json"},
            {"Content-Type", "application/json"}
          ],
          body: "{}"
        }

        case studio_link_http_client().request(request) do
          {:ok, %{status: 201, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"ticket" => ticket}} when is_binary(ticket) and ticket != "" ->
                {:ok, base <> "/login/ticket/" <> ticket}

              _ ->
                {:error, :instance_error}
            end

          _ ->
            {:error, :instance_error}
        end
    end
  end

  def mint_studio_link(_), do: {:error, :not_live}

  # Transport seam — swappable in tests via
  # `config :barkpark_cloud, :studio_link_http_client, FakeClient` (same shape as
  # the notifications seam; default is the verified-TLS :httpc client).
  defp studio_link_http_client do
    Application.get_env(
      :barkpark_cloud,
      :studio_link_http_client,
      BarkparkCloud.Billing.HttpClient
    )
  end

  @doc """
  Decrypt a Barkpark's stored content-bootstrap outputs (dwb-4) back to the map
  the dashboard/deploy step consumes:

      %{template:, workspace:, project:, dataset:, read_token:, env: %{…}}

  Returns `{:ok, nil}` when NO bootstrap ever ran for this instance (no
  workspace slug and no encrypted read token — the template-less launch path),
  `{:ok, map}` when stored, or `:error` when a stored ciphertext fails to
  decrypt/decode (`Vault.decrypt/1` fails closed on tampering). The owner-facing
  `/bootstrap` route is the only caller — show-to-owner, team-admin-gated.
  """
  @spec reveal_bootstrap(Barkpark.t()) :: {:ok, map() | nil} | :error
  def reveal_bootstrap(%Barkpark{bootstrap_workspace: nil, bootstrap_read_token_encrypted: nil}),
    do: {:ok, nil}

  def reveal_bootstrap(%Barkpark{} = bp) do
    with {:ok, read_token} <- decrypt_or_nil(bp.bootstrap_read_token_encrypted),
         {:ok, env} <- decrypt_env_or_empty(bp.bootstrap_env_encrypted) do
      {:ok,
       %{
         template: bp.template,
         workspace: bp.bootstrap_workspace,
         project: bp.bootstrap_project,
         dataset: bp.bootstrap_dataset,
         read_token: read_token,
         env: env
       }}
    end
  end

  defp decrypt_or_nil(nil), do: {:ok, nil}
  defp decrypt_or_nil(ciphertext), do: Vault.decrypt(ciphertext)

  defp decrypt_env_or_empty(nil), do: {:ok, %{}}

  defp decrypt_env_or_empty(ciphertext) do
    with {:ok, json} <- Vault.decrypt(ciphertext),
         {:ok, %{} = env} <- Jason.decode(json) do
      {:ok, env}
    else
      _ -> :error
    end
  end

  # The ISR-revalidation webhook the dwb-4/dwb-5 bootstrap registers on a fresh
  # instance — DISABLED, with a `.invalid` placeholder URL, under this
  # deterministic NAME. dwb-6's site-url step finds it by name and rewrites it.
  # MUST mirror `internal/bootstrap.WebhookName` / `WebhookPath` (bootstrap.go) —
  # they are the two ends of the same contract.
  @revalidation_webhook_name "bootstrap-revalidation"
  @revalidation_webhook_path "/api/barkpark/webhook"

  @doc """
  dwb-6 deferred-URL wiring: point the instance's bootstrap ISR-revalidation
  webhook at the just-deployed site and flip it ACTIVE — server-side, using the
  stored per-instance admin token (the client never sees it), mirroring
  `mint_studio_link/1`.

  The bootstrap (dwb-5) registered a DISABLED webhook named
  `#{@revalidation_webhook_name}` with a `.invalid` placeholder URL, because the
  deploy target is unknown until Vercel deploys after the handoff. Here we resolve
  its id off the instance, then `PUT` `{url: <site_url><path>, active: true}` — an
  idempotent converge (a re-PUT with the same URL is a no-op 200 on the instance).

  `site_url` is the site's ORIGIN (e.g. `https://acme.vercel.app`); the webhook
  target is `site_url <> "#{@revalidation_webhook_path}"` (where `@barkpark/nextjs`
  mounts its verifying handler).

  Returns `{:ok, %{site_url:, webhook_url:}}`, or:
    * `:invalid_url`     — `site_url` isn't an http(s) origin
    * `:not_live`        — the instance has no `url` yet (still provisioning)
    * `:no_admin_token`  — no stored admin token (pre-feature instance)
    * `:decrypt_failed`  — a stored ciphertext failed to decrypt (fail-closed)
    * `:no_bootstrap`    — no content bootstrap ran (template-less launch)
    * `:no_webhook`      — the bootstrap registered no revalidation webhook
                           (a template with no `webhook_secret` source)
    * `:instance_error`  — the instance list/update call failed

  Transport is the same swappable seam `mint_studio_link/1` uses
  (`:studio_link_http_client`; tests wire `StudioLinkFakeHttpClient`).
  """
  @spec wire_site_url(Barkpark.t(), String.t()) ::
          {:ok, %{site_url: String.t(), webhook_url: String.t()}}
          | {:error,
             :invalid_url
             | :not_live
             | :no_admin_token
             | :decrypt_failed
             | :no_bootstrap
             | :no_webhook
             | :instance_error}
  def wire_site_url(%Barkpark{url: url} = bp, site_url)
      when is_binary(url) and url != "" and is_binary(site_url) do
    with {:ok, origin} <- normalize_site_origin(site_url),
         {:ok, admin_token} <- reveal_admin_token_or_error(bp),
         {:ok, boot} when is_map(boot) <- reveal_bootstrap_or_error(bp),
         {:ok, id} <- find_revalidation_webhook(bp.url, admin_token, boot),
         webhook_url = origin <> @revalidation_webhook_path,
         :ok <- put_webhook_live(bp.url, admin_token, boot, id, webhook_url) do
      {:ok, %{site_url: origin, webhook_url: webhook_url}}
    end
  end

  def wire_site_url(%Barkpark{url: url}, _site_url) when is_binary(url) and url != "",
    do: {:error, :invalid_url}

  def wire_site_url(_, _), do: {:error, :not_live}

  # Accept only an http(s) origin; strip any trailing slash. Anything else fails
  # closed (a bad paste never wires a garbage webhook target).
  defp normalize_site_origin(site_url) do
    trimmed = String.trim(site_url)

    case URI.parse(trimmed) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" ->
        {:ok, String.trim_trailing(trimmed, "/")}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp reveal_admin_token_or_error(bp) do
    case reveal_admin_token(bp) do
      {:ok, nil} -> {:error, :no_admin_token}
      {:ok, token} -> {:ok, token}
      :error -> {:error, :decrypt_failed}
    end
  end

  defp reveal_bootstrap_or_error(bp) do
    case reveal_bootstrap(bp) do
      {:ok, nil} -> {:error, :no_bootstrap}
      {:ok, boot} -> {:ok, boot}
      :error -> {:error, :decrypt_failed}
    end
  end

  # The workspace-scoped admin base the bootstrap used: `<url>/w/<ws>/p/<project>`.
  defp scoped_base(url, boot) do
    String.trim_trailing(url, "/") <>
      "/w/" <> boot.workspace <> "/p/" <> (boot.project || "default")
  end

  # GET the dataset's webhooks, return the id of the bootstrap-owned endpoint.
  defp find_revalidation_webhook(url, admin_token, boot) do
    request = %{
      method: :get,
      url: scoped_base(url, boot) <> "/v1/webhooks/" <> boot.dataset,
      headers: instance_headers(admin_token),
      body: ""
    }

    case studio_link_http_client().request(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{"webhooks" => hooks}} when is_list(hooks) ->
            case Enum.find(hooks, &(&1["name"] == @revalidation_webhook_name)) do
              %{"id" => id} when is_binary(id) and id != "" -> {:ok, id}
              _ -> {:error, :no_webhook}
            end

          _ ->
            {:error, :instance_error}
        end

      _ ->
        {:error, :instance_error}
    end
  end

  # PUT the real URL + active:true onto the endpoint (idempotent converge).
  defp put_webhook_live(url, admin_token, boot, id, webhook_url) do
    body = Jason.encode!(%{url: webhook_url, active: true})

    request = %{
      method: :put,
      url: scoped_base(url, boot) <> "/v1/webhooks/" <> boot.dataset <> "/" <> id,
      headers: instance_headers(admin_token),
      body: body
    }

    case studio_link_http_client().request(request) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      _ -> {:error, :instance_error}
    end
  end

  defp instance_headers(admin_token) do
    [
      {"Authorization", "Bearer " <> admin_token},
      {"Accept", "application/json"},
      {"Content-Type", "application/json"}
    ]
  end

  ## Self-update status (isu-6) — the instance is the SOURCE OF TRUTH. Every
  ## managed instance exposes GET /v1/admin/self-update (admin bearer) whose
  ## "check" block is its own update-availability verdict (it knows its own
  ## upstream/fork). The control plane merely mirrors that verdict onto the
  ## barkparks row so the fleet dashboard renders without a live fan-out, and
  ## relays POST /v1/admin/self-update to trigger a run — both server-side with
  ## the stored admin token, exactly the mint_studio_link/1 pattern.

  @doc """
  Barkparks whose self-update status is worth refreshing: LIVE (`host` set —
  a box actually exists) and not billing-suspended (we don't poll an unpaid
  fleet). The `UpdateStatusWorker`'s hourly scan set.
  """
  @spec update_checkable_barkparks() :: [Barkpark.t()]
  def update_checkable_barkparks do
    from(b in Barkpark,
      where: not is_nil(b.host) and b.host != "",
      where: b.suspended == false,
      order_by: [asc: b.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Refresh a Barkpark's cached self-update status from the instance's OWN verdict:
  `GET <instance>/v1/admin/self-update` with the stored admin token (server-side,
  the token never leaves this function), read the `"check"` block, persist it via
  the narrow `Barkpark.update_status_changeset/2`.

  NEVER raises, and ALWAYS best-effort-persists on failure: any failure mode —
  not live, no/tampered admin token, transport error, non-200 (a pre-feature
  instance 404s the endpoint), undecodable body — lands `update_state:
  "unknown"` on the row (with a fresh `update_checked_at`) and returns
  `{:error, reason}`. A 200 with a `"check"` map persists its state (whitelisted
  against `Barkpark.update_states/0`, anything else → `"unknown"`), the
  running/latest releases, and the check time, returning `{:ok, bp}`.

  Transport is the same swappable seam `mint_studio_link/1` uses
  (`:studio_link_http_client`; tests wire `StudioLinkFakeHttpClient`).
  """
  @spec refresh_update_status(Barkpark.t()) ::
          {:ok, Barkpark.t()}
          | {:error, :not_live | :no_admin_token | :decrypt_failed | :instance_error}
  def refresh_update_status(%Barkpark{url: url} = bp) when is_binary(url) and url != "" do
    case reveal_admin_token(bp) do
      {:ok, nil} ->
        persist_update_unknown(bp, :no_admin_token)

      :error ->
        persist_update_unknown(bp, :decrypt_failed)

      {:ok, admin_token} ->
        request = %{
          method: :get,
          url: String.trim_trailing(url, "/") <> "/v1/admin/self-update",
          headers: instance_headers(admin_token),
          body: ""
        }

        case studio_link_http_client().request(request) do
          {:ok, %{status: 200, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"check" => %{} = check}} -> persist_update_check(bp, check)
              _ -> persist_update_unknown(bp, :instance_error)
            end

          _ ->
            persist_update_unknown(bp, :instance_error)
        end
    end
  end

  def refresh_update_status(%Barkpark{} = bp), do: persist_update_unknown(bp, :not_live)

  # Mirror the instance's "check" verdict onto the row. A state outside the
  # whitelist is downgraded to "unknown" (fail-closed — never trust a weird
  # instance into a rendering state the SPA doesn't know).
  defp persist_update_check(bp, check) do
    state =
      case check["state"] do
        s when is_binary(s) -> if s in Barkpark.update_states(), do: s, else: "unknown"
        _ -> "unknown"
      end

    bp
    |> Barkpark.update_status_changeset(%{
      update_state: state,
      update_running_release: string_field(check["running_release"]),
      update_latest_release: string_field(check["latest_release"]),
      update_checked_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  # Best-effort "unknown" landing for every failure mode — the row always
  # reflects that we asked and got no usable verdict. The write itself is
  # best-effort too (a changeset/DB failure never masks the original reason).
  defp persist_update_unknown(bp, reason) do
    _ =
      bp
      |> Barkpark.update_status_changeset(%{
        update_state: "unknown",
        update_running_release: nil,
        update_latest_release: nil,
        update_checked_at: DateTime.utc_now()
      })
      |> Repo.update()

    {:error, reason}
  end

  defp string_field(v) when is_binary(v) and v != "", do: v
  defp string_field(_), do: nil

  @doc """
  Trigger a self-update RUN on a live instance: `POST <instance>/v1/admin/self-update`
  server-side with the stored admin token (never sent to the client), mirroring
  `mint_studio_link/1`.

  Returns `{:ok, http_status, decoded_body_map}` on ANY instance response — the
  instance's semantics travel intact to the router, which relays them (202
  started | 409 already_running | 503 feature_not_configured | 500
  runner_start_failed; a pre-feature instance 404s). An undecodable response
  body degrades to `%{}` (the status alone is the verdict). Errors mirror
  `mint_studio_link/1`'s atoms: `:not_live` (no `url` yet), `:no_admin_token`,
  `:decrypt_failed`, `:instance_error` (transport failure — no response at all).
  """
  @spec trigger_self_update(Barkpark.t()) ::
          {:ok, non_neg_integer(), map()}
          | {:error, :not_live | :no_admin_token | :decrypt_failed | :instance_error}
  def trigger_self_update(%Barkpark{url: url} = bp) when is_binary(url) and url != "" do
    case reveal_admin_token(bp) do
      {:ok, nil} ->
        {:error, :no_admin_token}

      :error ->
        {:error, :decrypt_failed}

      {:ok, admin_token} ->
        request = %{
          method: :post,
          url: String.trim_trailing(url, "/") <> "/v1/admin/self-update",
          headers: instance_headers(admin_token),
          body: "{}"
        }

        case studio_link_http_client().request(request) do
          {:ok, %{status: status, body: body}} when is_integer(status) ->
            case Jason.decode(body) do
              {:ok, %{} = decoded} -> {:ok, status, decoded}
              _ -> {:ok, status, %{}}
            end

          _ ->
            {:error, :instance_error}
        end
    end
  end

  def trigger_self_update(_), do: {:error, :not_live}

  ## Env vars — shared / per-instance secrets injected into a Team's instances.
  ##
  ## All reads/writes are Team-scoped: an env var belongs to a Team, and a write
  ## can never touch another team's row. The resolve path is the injection seam —
  ## `resolved_env_for_barkpark/1` is folded into the provision claim payload so
  ## the decrypted values reach the box's runtime env.

  @doc """
  List a Team's env vars, newest first. Returns BOTH team-scoped and
  instance-scoped (barkpark) rows. Scoped — never crosses teams.
  """
  @spec list_env_vars(Team.t() | binary()) :: [EnvVar.t()]
  def list_env_vars(team) do
    tid = team_id(team)

    EnvVar
    |> where([e], e.team_id == ^tid)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  List the env vars in effect for one `barkpark`: its Team's team-scoped vars
  plus the instance's own `barkpark`-scoped overrides. Scoped — never crosses
  teams.
  """
  @spec list_env_vars(Team.t() | binary(), Barkpark.t() | binary()) :: [EnvVar.t()]
  def list_env_vars(team, barkpark) do
    tid = team_id(team)
    bid = barkpark_id(barkpark)

    EnvVar
    |> where([e], e.team_id == ^tid)
    |> where([e], is_nil(e.barkpark_id) or e.barkpark_id == ^bid)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  Create-or-update an env var for `team`. `attrs` carries `:key`, `:value`
  (PLAINTEXT — encrypted here via `Vault.encrypt/1`), `:scope` (`team`|`barkpark`),
  optional `:barkpark_id`, `:is_secret`, `:is_shown_once`, `:comment`. Both
  string- and atom-keyed attrs are accepted.

  Upsert key is `(key, scope-instance)`: writing the same key+scope twice updates
  the existing row in place rather than tripping the partial-unique index. A write
  to an existing `is_shown_once` var is REFUSED (`{:error, :write_once}`) — the
  only way to change a write-once secret is delete + recreate (Coolify's
  masked-bulk-update rule).

  ALWAYS filters by `team_id`, so a write can never touch another team's row.
  OWNERSHIP: a supplied `barkpark_id` MUST belong to `team` — the FK only enforces
  existence, not ownership, so a client that supplies another team's instance id
  is REJECTED (`{:error, :barkpark_not_in_team}`) BEFORE any write. Fail closed:
  the cross-tenant write never lands.
  """
  @spec put_env_var(Team.t() | binary(), map()) ::
          {:ok, EnvVar.t()}
          | {:error, :write_once | :barkpark_not_in_team | Ecto.Changeset.t()}
  def put_env_var(team, %{} = attrs) do
    tid = team_id(team)
    key = attrs[:key] || attrs["key"]
    scope = attrs[:scope] || attrs["scope"] || "team"
    bid = attrs[:barkpark_id] || attrs["barkpark_id"]
    plaintext = attrs[:value] || attrs["value"] || ""

    existing =
      case scope do
        # A barkpark-scoped write with NO barkpark_id is malformed — skip the
        # lookup (Ecto forbids `barkpark_id: nil` in get_by) and let the
        # changeset surface the scope-shape error.
        "barkpark" when is_nil(bid) ->
          nil

        "barkpark" ->
          # A non-UUID barkpark_id would make get_by raise Ecto.Query.CastError;
          # skip the lookup so the ownership gate below returns
          # `:barkpark_not_in_team` (no 500 on a malformed id).
          case uuid_or_nil(bid) do
            nil -> nil
            _ -> Repo.get_by(EnvVar, team_id: tid, key: key, barkpark_id: bid)
          end

        _ ->
          # is_nil/1, NOT `barkpark_id: nil` — Ecto forbids a nil comparison in a
          # keyword get_by (nil-safety), so the team-scope lookup must be explicit.
          EnvVar
          |> where([e], e.team_id == ^tid and e.key == ^key and is_nil(e.barkpark_id))
          |> Repo.one()
      end

    cond do
      # OWNERSHIP GATE (security): a supplied barkpark_id must be one of THIS
      # team's instances. Checked before any write so a caller cannot smuggle a
      # secret onto another team's box by guessing / harvesting its instance id.
      not is_nil(bid) and not barkpark_in_team?(tid, bid) ->
        {:error, :barkpark_not_in_team}

      match?(%EnvVar{is_shown_once: true}, existing) ->
        {:error, :write_once}

      true ->
        # Required/derived columns always set; the optional flags are carried
        # only when the caller actually supplied them (presence-checked, so an
        # explicit `is_secret: false` is honoured and isn't confused with absent),
        # leaving the schema defaults / existing row values intact otherwise.
        changeset_attrs =
          %{
            team_id: tid,
            key: key,
            scope: scope,
            barkpark_id: bid,
            value_encrypted: Vault.encrypt(plaintext)
          }
          |> put_if_present(attrs, :is_secret)
          |> put_if_present(attrs, :is_shown_once)
          |> put_if_present(attrs, :comment)

        (existing || %EnvVar{})
        |> EnvVar.changeset(changeset_attrs)
        |> Repo.insert_or_update()
    end
  end

  @doc """
  Delete an env var by id, Team-scoped. `{:ok, EnvVar} | {:error, :not_found}`.
  A non-existent id, an invalid (non-UUID) id, or a row owned by another team all
  return `{:error, :not_found}` (an existence-leak protection — the caller cannot
  distinguish "wrong team" from "no such var").
  """
  @spec delete_env_var(Team.t() | binary(), binary()) ::
          {:ok, EnvVar.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_env_var(team, id) do
    tid = team_id(team)

    case uuid_or_nil(id) && Repo.get_by(EnvVar, id: id, team_id: tid) do
      %EnvVar{} = ev -> Repo.delete(ev)
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Decrypt one env var's value. Returns `{:ok, plaintext}` or `:error` (tampered
  ciphertext fails closed). A `is_shown_once` var is `{:error, :write_once}` —
  write-once values are never revealed (compliance posture).
  """
  @spec reveal_env_var(EnvVar.t()) :: {:ok, binary()} | :error | {:error, :write_once}
  def reveal_env_var(%EnvVar{is_shown_once: true}), do: {:error, :write_once}
  def reveal_env_var(%EnvVar{value_encrypted: ciphertext}), do: Vault.decrypt(ciphertext)

  @doc """
  The resolved, DECRYPTED env map for a provisioned `barkpark`: its Team's
  team-scoped vars, with the instance's own `barkpark`-scoped vars layered on top
  (most-specific-wins). Keys are env var names, values are plaintext.

  This is the injection payload — called at provision-claim time and folded into
  the Go worker's `claim_json` so the values reach the box's runtime env. ALWAYS
  team-filtered (the never-leak-across-tenants invariant); a barkpark belongs to
  exactly one team, so resolution can only ever surface that team's secrets.

  Resolved at CLAIM time (not enqueue time), so a retry / stale-claim re-pick
  carries the latest values automatically — rotate once, the next provision
  carries the new value.

  A row whose ciphertext fails to decrypt (tampered / key-rotated-away) is
  SKIPPED with a logged warning rather than crashing the provision — fail-open on
  a single bad row, never hand the worker a half-map silently corrupted by a raise.
  """
  @spec resolved_env_for_barkpark(Barkpark.t()) :: %{String.t() => String.t()}
  def resolved_env_for_barkpark(%Barkpark{id: bid, team_id: tid}) do
    rows =
      EnvVar
      |> where([e], e.team_id == ^tid)
      |> where([e], is_nil(e.barkpark_id) or e.barkpark_id == ^bid)
      # team-scope first, instance-scope last → Map.put lets instance shadow team.
      |> order_by([e], asc: fragment("? IS NOT NULL", e.barkpark_id))
      |> Repo.all()

    Enum.reduce(rows, %{}, fn ev, acc ->
      case Vault.decrypt(ev.value_encrypted) do
        {:ok, plaintext} ->
          Map.put(acc, ev.key, plaintext)

        :error ->
          Logger.warning("resolved_env_for_barkpark: undecryptable env var #{ev.id}, skipped")

          acc
      end
    end)
  end

  # True when `bid` is one of `tid`'s Barkparks. Guards the env-var ownership
  # gate — a non-UUID, a non-existent, or another team's id all return false
  # (fail closed). Ownership is enforced here, NOT by the FK (which only checks
  # existence).
  defp barkpark_in_team?(tid, bid) do
    case uuid_or_nil(bid) && Repo.get(Barkpark, bid) do
      %Barkpark{team_id: ^tid} -> true
      _ -> false
    end
  end

  ## Agent tokens

  @doc """
  Mint a revocable agent token for `barkpark` with `scope`. Returns
  `{:ok, plaintext, %AgentToken{}}` — the PLAINTEXT is shown ONCE here and never
  stored; only its SHA-256 hash is persisted.

  `opts`:
    * `:expires_at` — a `DateTime` after which the token is invalid (default: no
      expiry).
  """
  @spec mint_agent_token(Barkpark.t() | binary(), String.t(), keyword()) ::
          {:ok, binary(), AgentToken.t()} | {:error, Ecto.Changeset.t()}
  def mint_agent_token(barkpark, scope, opts \\ []) do
    plaintext = generate_token()

    attrs = %{
      barkpark_id: barkpark_id(barkpark),
      scope: scope,
      token_hash: AgentToken.hash_token(plaintext),
      expires_at: Keyword.get(opts, :expires_at)
    }

    case %AgentToken{} |> AgentToken.changeset(attrs) |> Repo.insert() do
      {:ok, token} -> {:ok, plaintext, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Verify a presented `plaintext` agent token. Returns the owning `%Barkpark{}`
  when the token exists, is not revoked, and is not past `expires_at`; otherwise
  `nil`. Lookup is by hash — the plaintext is never stored to compare against.
  """
  @spec verify_agent_token(binary()) :: Barkpark.t() | nil
  def verify_agent_token(plaintext) when is_binary(plaintext) do
    hash = AgentToken.hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from t in AgentToken,
        where: t.token_hash == ^hash,
        where: is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now

    case Repo.one(query) do
      %AgentToken{barkpark_id: barkpark_id} -> Repo.get(Barkpark, barkpark_id)
      nil -> nil
    end
  end

  @doc """
  Revoke an agent token (idempotent). Accepts the `%AgentToken{}` struct or its
  plaintext. Stamps `revoked_at`; a revoked token never verifies again. Returns
  `{:ok, %AgentToken{}}`, or `{:error, :not_found}` when a plaintext matches no
  live token.
  """
  @spec revoke_agent_token(AgentToken.t() | binary()) ::
          {:ok, AgentToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke_agent_token(%AgentToken{} = token) do
    token
    |> Ecto.Changeset.change(revoked_at: DateTime.truncate(DateTime.utc_now(), :microsecond))
    |> Repo.update()
  end

  def revoke_agent_token(plaintext) when is_binary(plaintext) do
    hash = AgentToken.hash_token(plaintext)

    case Repo.get_by(AgentToken, token_hash: hash) do
      %AgentToken{} = token -> revoke_agent_token(token)
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Revoke every LIVE agent token across all Barkparks owned by any team `user`
  belongs to — the control-plane half of "change password ⇒ kill machine creds
  too" (Coolify's `RevokeUserTeamTokens::forUser`,
  app/Actions/User/RevokeUserTeamTokens.php:20). Agent tokens belong to a
  Barkpark, which belongs to a team; a user reaches them through their team
  memberships, so we scope by `barkparks.team_id ∈ user's team ids`.

  A password compromise should kill agent creds for EVERY team the user touches —
  the safe default. (A tighter "only boxes this user solely owns" rule can narrow
  the team set later.) Returns `:ok` (the count is irrelevant to the caller).
  """
  @spec revoke_all_agent_tokens_for_user(BarkparkCloud.Accounts.User.t() | binary()) :: :ok
  def revoke_all_agent_tokens_for_user(user) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    team_ids = Enum.map(BarkparkCloud.Accounts.list_user_teams(user), & &1.id)

    from(t in AgentToken,
      join: b in Barkpark,
      on: b.id == t.barkpark_id,
      where: b.team_id in ^team_ids,
      where: is_nil(t.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: now])

    :ok
  end

  ## Sites — hosted websites running co-located with a Barkpark.

  @doc """
  Create a Site under `barkpark`. The Site's `team_id` is taken from the
  Barkpark — sites can never belong to a different team than their box.

  Returns `{:ok, %Site{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec create_site(Barkpark.t(), map()) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def create_site(%Barkpark{} = barkpark, attrs) do
    %Site{}
    |> Site.changeset(
      attrs
      |> Map.put_new(:barkpark_id, barkpark.id)
      |> Map.put_new(:team_id, barkpark.team_id)
    )
    |> Repo.insert()
  end

  @doc "List a Team's sites across all of its barkparks, newest first."
  @spec list_sites_for_team(Team.t() | binary()) :: [Site.t()]
  def list_sites_for_team(team) do
    tid = team_id(team)

    Site
    |> where([s], s.team_id == ^tid)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  @doc "List sites running on `barkpark`, newest first."
  @spec list_sites(Barkpark.t() | binary()) :: [Site.t()]
  def list_sites(barkpark) do
    bp_id = barkpark_id(barkpark)

    Site
    |> where([s], s.barkpark_id == ^bp_id)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  @doc "Fetch a Site by id, or nil. A non-UUID id is nil (→ 404), never a 500."
  @spec get_site(binary()) :: Site.t() | nil
  def get_site(id) when is_binary(id) do
    case uuid_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(Site, uuid)
    end
  end

  @doc """
  Fetch a Site by id only if it belongs to `team` — the team-scoped read for the
  user-facing API. Returns `nil` if the site exists but is owned by another
  team (an existence leak protection: callers cannot distinguish "wrong team"
  from "no such site").
  """
  @spec get_team_site(Team.t() | binary(), binary()) :: Site.t() | nil
  def get_team_site(team, id) when is_binary(id) do
    case uuid_or_nil(id) do
      nil ->
        nil

      uuid ->
        tid = team_id(team)

        Site
        |> where([s], s.id == ^uuid and s.team_id == ^tid)
        |> Repo.one()
    end
  end

  @doc """
  Replace the Site's encrypted env blob with the JSON-encoded `env_map`. The
  plaintext is encrypted via `Vault.encrypt/1`; only ciphertext lands at rest.
  """
  @spec set_site_env(Site.t(), map()) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def set_site_env(%Site{} = site, env_map) when is_map(env_map) do
    json = Jason.encode!(env_map)

    site
    |> Site.changeset(%{env_encrypted: Vault.encrypt(json)})
    |> Repo.update()
  end

  @doc "Decrypt a Site's env blob back to a plaintext map. `{:ok, map} | :error | {:ok, %{}}` when unset."
  @spec reveal_site_env(Site.t()) :: {:ok, map()} | :error
  def reveal_site_env(%Site{env_encrypted: nil}), do: {:ok, %{}}

  def reveal_site_env(%Site{env_encrypted: ciphertext}) do
    with {:ok, json} <- Vault.decrypt(ciphertext),
         {:ok, map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  @doc """
  Add `domain` to a Site's `domains` array. Domains are stored lowercase and
  deduplicated. Returns `{:ok, site}` (already-present is a no-op) or a
  validation `{:error, changeset}` for malformed domains.
  """
  @spec add_site_domain(Site.t(), String.t()) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def add_site_domain(%Site{domains: existing} = site, domain) when is_binary(domain) do
    new_domains = Enum.uniq(existing ++ [domain])

    site
    |> Site.changeset(%{domains: new_domains})
    |> Repo.update()
  end

  @doc "Remove `domain` from a Site's `domains` array. No-op if absent."
  @spec remove_site_domain(Site.t(), String.t()) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def remove_site_domain(%Site{domains: existing} = site, domain) when is_binary(domain) do
    norm = domain |> String.downcase() |> String.trim() |> String.trim_trailing(".")
    new_domains = Enum.reject(existing, &(&1 == norm))

    site
    |> Site.changeset(%{domains: new_domains})
    |> Repo.update()
  end

  @doc """
  The on-demand TLS gate: is `domain` registered to ANY Site? Lookup is an
  indexed array-contains against `sites.domains` (GIN). Returns true / false.

  Caddy's `on_demand_tls.ask` calls this — a 200 means "we own this hostname,
  go ahead and issue a cert"; a 404 means "stop, this is not our hostname"
  (prevents the box from being a cert-issuance DoS target).
  """
  @spec domain_registered?(String.t()) :: boolean()
  def domain_registered?(domain) when is_binary(domain) do
    norm = domain |> String.downcase() |> String.trim() |> String.trim_trailing(".")

    registered_site_domain?(norm) or registered_preview_host?(norm)
  end

  defp registered_site_domain?(norm) do
    Site
    |> where([s], fragment("? = ANY(?)", ^norm, s.domains))
    |> select([s], 1)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> false
      _ -> true
    end
  end

  # gh-6: a branch-preview host is TLS-allowlisted for as long as a preview
  # deployment on that host is still meant to serve (queued/building/pushing/live).
  # A cancelled/failed preview — evicted, superseded, or torn down on branch
  # delete — is NOT (its cert need is gone), so a stale host stops issuing certs.
  defp registered_preview_host?(norm) do
    Deployment
    |> where(
      [d],
      d.environment == "preview" and d.preview_host == ^norm and
        d.status in ~w(queued building pushing live)
    )
    |> select([d], 1)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> false
      _ -> true
    end
  end

  ## Sites — GitHub webhook configuration (P7).

  @doc """
  Configure a Site's GitHub link: the `owner/repo` form, the branch to listen on
  (default "main"), and the webhook secret used to verify the HMAC on incoming
  pushes. `secret` is Vault-encrypted at rest — the plaintext is never persisted.

  Pass `secret` as `nil` to leave the existing secret in place (idempotent
  re-configure of repo/branch only). Pass a binary to replace it.

  Returns `{:ok, %Site{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec set_site_github(Site.t(), String.t(), String.t() | nil, binary() | nil) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def set_site_github(%Site{} = site, repo, branch, secret)
      when is_binary(repo) do
    branch = if is_binary(branch) and branch != "", do: branch, else: "main"

    attrs =
      %{
        github_repo: repo,
        github_branch: branch
      }
      |> maybe_put_encrypted_secret(secret)

    site
    |> Site.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_put_encrypted_secret(attrs, nil), do: attrs

  defp maybe_put_encrypted_secret(attrs, secret) when is_binary(secret) do
    Map.put(attrs, :github_webhook_secret_encrypted, Vault.encrypt(secret))
  end

  @doc """
  Decrypt a Site's GitHub webhook secret back to plaintext.

  Returns `{:ok, plaintext}` when set, `{:ok, nil}` when never configured, or
  `:error` when the stored ciphertext is tampered.
  """
  @spec reveal_site_github_secret(Site.t()) :: {:ok, binary() | nil} | :error
  def reveal_site_github_secret(%Site{github_webhook_secret_encrypted: nil}), do: {:ok, nil}

  def reveal_site_github_secret(%Site{github_webhook_secret_encrypted: ciphertext}) do
    case Vault.decrypt(ciphertext) do
      {:ok, plain} -> {:ok, plain}
      :error -> :error
    end
  end

  @doc """
  Clear a Site's GitHub link — drops the repo, branch, and encrypted webhook
  secret so inbound pushes stop deploying (the inbound handler 404s once the
  secret is gone). The webhook still lives on GitHub's side until removed there;
  its deliveries simply stop being honored. Returns `{:ok, %Site{}}`.
  """
  @spec clear_site_github(Site.t()) :: {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def clear_site_github(%Site{} = site) do
    site
    |> Ecto.Changeset.change(%{
      github_repo: nil,
      github_branch: nil,
      github_webhook_secret_encrypted: nil
    })
    |> Repo.update()
  end

  ## Deployments — the build-job queue.

  @doc """
  Create a Deployment for `site`, defaulting to `status: "queued"`. This is the
  enqueue half of `bp deploy`: the off-box builder polls for queued rows and
  walks them through building → pushing → live.
  """
  @spec create_deployment(Site.t(), map()) ::
          {:ok, Deployment.t()} | {:error, Ecto.Changeset.t()}
  def create_deployment(%Site{} = site, attrs \\ %{}) do
    %Deployment{}
    |> Deployment.changeset(Map.put(attrs, :site_id, site.id))
    |> Repo.insert()
  end

  @doc """
  Find the newest still-active Deployment for `site_id` at `git_ref`, or `nil`.

  Backs webhook redelivery dedup: GitHub redelivers on any non-2xx (and users
  can hand-redeliver from the UI), so before enqueueing a build the router asks
  whether a queued/building/pushing deployment already exists for this exact
  commit — if so it 200s the redelivery instead of minting a duplicate build.
  """
  @spec find_active_deployment(binary(), binary()) :: Deployment.t() | nil
  def find_active_deployment(site_id, git_ref) when is_binary(git_ref) do
    # PRODUCTION-scoped: a preview at the same sha (e.g. a branch cut from the
    # prod branch with no new commits) must NOT mask a real production deploy.
    Deployment
    |> where(
      [d],
      d.site_id == ^site_id and d.git_ref == ^git_ref and d.environment == "production" and
        d.status in ~w(queued building pushing)
    )
    |> order_by([d], desc: d.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  dwb-18: Fetch the Deployment minted for a given GitHub `X-GitHub-Delivery`, or
  `nil`. The idempotency lookup the webhook does BEFORE the active-build dedup: a
  redelivered push (same delivery id) points straight back at its own row. Nil or
  blank input (a push with no delivery header) is `nil`, never a query.
  """
  @spec find_deployment_by_delivery_id(binary() | nil) :: Deployment.t() | nil
  def find_deployment_by_delivery_id(delivery_id)
      when is_binary(delivery_id) and delivery_id != "" do
    Repo.get_by(Deployment, delivery_id: delivery_id)
  end

  def find_deployment_by_delivery_id(_), do: nil

  ## gh-6 — branch previews.

  @doc """
  Max concurrent branch previews per site (the cap the eviction path enforces).
  Defaults to #{@default_max_previews_per_site}; overridable via
  `config :barkpark_cloud, :max_previews_per_site`.
  """
  @spec max_previews_per_site() :: pos_integer()
  def max_previews_per_site do
    Application.get_env(:barkpark_cloud, :max_previews_per_site, @default_max_previews_per_site)
  end

  @doc """
  The DNS-safe preview subdomain label for `site_slug` + `branch`:
  `<site_slug>--<branch_slug>-<hash>`. The 6-hex-char hash is a deterministic
  digest of the RAW branch name — so the same branch always maps to the same
  label (a new push replaces the branch's preview in place, blue/green) while two
  branches that sanitize to the same slug (`feat/x` vs `feat-x`) stay distinct.
  Total length is clamped to 63 (the max DNS label), reserving room for the
  hash + separators.
  """
  @spec preview_slug_for(String.t(), String.t()) :: String.t()
  def preview_slug_for(site_slug, branch) when is_binary(site_slug) and is_binary(branch) do
    hash =
      :crypto.hash(:sha256, branch) |> Base.encode16(case: :lower) |> binary_part(0, 6)

    base = String.slice(site_slug, 0, 40)

    # 63 budget − base − "--" (2) − "-" (1) − hash (6). At least 1 so a very long
    # site slug still leaves a sliver for the branch part.
    branch_room = max(63 - String.length(base) - 9, 1)

    branch_slug =
      branch
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, branch_room)
      |> String.trim("-")

    branch_part = if branch_slug == "", do: hash, else: branch_slug <> "-" <> hash

    base <> "--" <> branch_part
  end

  @doc """
  The full preview host for `site_slug` + `branch`:
  `<preview_slug>.<base_domain>` (base_domain = `barkpark.cloud`). This is the
  hostname the runtime keys its per-preview Caddy block on and the one
  `/v1/tls/ask` allowlists.
  """
  @spec preview_host_for(String.t(), String.t()) :: String.t()
  def preview_host_for(site_slug, branch) do
    preview_slug_for(site_slug, branch) <> "." <> Barkpark.base_domain()
  end

  @doc """
  Find a still-active preview Deployment for `(site_id, branch)` at `git_ref`, or
  nil — the preview twin of `find_active_deployment/2`, used to 200 a webhook
  redelivery instead of minting a duplicate preview build.
  """
  @spec find_active_preview(binary(), String.t(), binary()) :: Deployment.t() | nil
  def find_active_preview(site_id, branch, git_ref)
      when is_binary(branch) and is_binary(git_ref) do
    Deployment
    |> where(
      [d],
      d.site_id == ^site_id and d.environment == "preview" and d.branch == ^branch and
        d.git_ref == ^git_ref and d.status in ~w(queued building pushing live)
    )
    |> order_by([d], desc: d.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  The newest still-building (queued/building/pushing) preview for `(site_id,
  branch)` at ANY sha, or nil — the lost-race recovery lookup: when a concurrent
  push to the same branch won the partial unique (site, branch) active-preview
  index, this finds the winner so the loser can 200 it as a duplicate.
  """
  @spec find_active_preview_for_branch(binary(), String.t()) :: Deployment.t() | nil
  def find_active_preview_for_branch(site_id, branch) when is_binary(branch) do
    Deployment
    |> where(
      [d],
      d.site_id == ^site_id and d.environment == "preview" and d.branch == ^branch and
        d.status in ~w(queued building pushing)
    )
    |> order_by([d], desc: d.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Enqueue a branch-PREVIEW deployment for `site` cut from `branch` at `sha`.

  Lifecycle (all in one transaction):

    1. **Replace-per-branch** — any still-active preview for THIS branch is
       superseded (cancelled, with an honest console line) so only the latest
       push to a branch has a live preview.
    2. **Cap + eviction** — if this is a NEW branch and the site is already at
       `max_previews_per_site/0` active preview branches, the OLDEST preview
       branch is evicted (its deployments cancelled + host de-registered) before
       the new one is minted.
    3. The fresh preview row is inserted (`environment: "preview"`, `branch`,
       `preview_slug`, `preview_host`, `git_ref: sha`, dwb-18 `delivery_id`) —
       status `queued`, so the off-box builder picks it up exactly like a
       production deploy.

  Idempotency (dwb-18): a lost race — a concurrent redelivery (same delivery_id)
  or a concurrent push to the same branch (the partial unique (site, branch)
  active-preview index) — rolls the WHOLE transaction back (including the
  supersede/evict cancels) and returns `{:error, changeset}`; the router recovers
  the winner and 200s it as a duplicate.

  Returns `{:ok, %Deployment{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec create_preview_deployment(Site.t(), String.t(), binary(), binary() | nil) ::
          {:ok, Deployment.t()} | {:error, Ecto.Changeset.t()}
  def create_preview_deployment(%Site{} = site, branch, sha, delivery_id \\ nil)
      when is_binary(branch) and is_binary(sha) do
    slug = preview_slug_for(site.slug, branch)
    host = preview_host_for(site.slug, branch)
    cap = max_previews_per_site()

    Repo.transaction(fn ->
      # 1. Replace this branch's existing preview (if any).
      superseded = supersede_active_previews(site.id, branch)

      # 2. Cap only bites when this is a genuinely NEW branch (nothing superseded).
      if superseded == 0 and active_preview_branch_count(site.id) >= cap do
        evict_oldest_preview_branch(site.id, cap)
      end

      attrs = %{
        site_id: site.id,
        environment: "preview",
        branch: branch,
        preview_slug: slug,
        preview_host: host,
        git_ref: sha,
        delivery_id: delivery_id
      }

      case %Deployment{} |> Deployment.preview_changeset(attrs) |> Repo.insert() do
        {:ok, dep} -> dep
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  The latest preview Deployment per branch for `site`, newest first — the
  dashboard's preview list. One row per branch (the most recent push), so a
  branch that has been pushed ten times shows its current preview, not ten rows.
  Cancelled/failed-only branches (torn down / evicted) are omitted.
  """
  @spec list_preview_deployments(Site.t() | binary()) :: [Deployment.t()]
  def list_preview_deployments(site) do
    sid = site_id(site)

    Deployment
    |> where([d], d.site_id == ^sid and d.environment == "preview")
    |> where([d], d.status in ~w(queued building pushing live))
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
    |> Enum.uniq_by(& &1.branch)
  end

  @doc """
  Tear down every active preview for `(site, branch)` — the branch-delete
  webhook path. Each still-serving preview deployment is cancelled (host
  de-registered from `/v1/tls/ask`) with an honest console line. Returns the
  count torn down.
  """
  @spec teardown_branch_previews(Site.t() | binary(), String.t()) :: non_neg_integer()
  def teardown_branch_previews(site, branch) when is_binary(branch) do
    sid = site_id(site)
    cancel_active_previews(sid, branch, "preview: branch #{branch} deleted — preview torn down")
  end

  # Cancel this branch's active previews as SUPERSEDED (a newer push arrived).
  defp supersede_active_previews(site_id, branch) do
    cancel_active_previews(
      site_id,
      branch,
      "preview: superseded by a newer push to #{branch}"
    )
  end

  # Cancel every active (queued/building/pushing/live) preview deployment for
  # (site_id, branch), stamping `line` on each console. Direct status write (not
  # the fenced transition graph) — teardown/eviction is a system operation, so it
  # may cancel even a `live` preview, which the builder transition graph forbids.
  # Returns the number cancelled.
  defp cancel_active_previews(site_id, branch, line) do
    Deployment
    |> where(
      [d],
      d.site_id == ^site_id and d.environment == "preview" and d.branch == ^branch and
        d.status in ~w(queued building pushing live)
    )
    |> Repo.all()
    |> Enum.map(fn dep -> cancel_preview(dep, line) end)
    |> length()
  end

  defp cancel_preview(%Deployment{} = dep, line) do
    entry = %{"line" => line, "at" => DateTime.to_iso8601(DateTime.utc_now())}
    console = cap_console((dep.console || []) ++ [entry])

    {:ok, updated} =
      dep
      |> Ecto.Changeset.change(status: "cancelled", console: console)
      |> Repo.update()

    updated
  end

  # How many DISTINCT branches currently have an active preview on this site.
  defp active_preview_branch_count(site_id) do
    Deployment
    |> where(
      [d],
      d.site_id == ^site_id and d.environment == "preview" and
        d.status in ~w(queued building pushing live)
    )
    |> select([d], d.branch)
    |> distinct(true)
    |> Repo.all()
    |> length()
  end

  # Evict the OLDEST active preview branch (by its earliest active deployment) —
  # bounded-resource enforcement. Cancels all that branch's active previews with
  # an honest cap line. Returns the evicted branch name or nil (nothing to evict).
  defp evict_oldest_preview_branch(site_id, cap) do
    oldest =
      Deployment
      |> where(
        [d],
        d.site_id == ^site_id and d.environment == "preview" and
          d.status in ~w(queued building pushing live)
      )
      |> group_by([d], d.branch)
      |> select([d], {d.branch, min(d.inserted_at)})
      |> order_by([d], asc: min(d.inserted_at))
      |> limit(1)
      |> Repo.one()

    case oldest do
      {branch, _at} when is_binary(branch) ->
        cancel_active_previews(
          site_id,
          branch,
          "preview: evicted — preview cap (#{cap}) reached, oldest branch removed"
        )

        branch

      _ ->
        nil
    end
  end

  @doc """
  List a Site's deployments, newest first, capped at `limit` (default 100).
  `opts[:environment]` filters by environment ("production" | "preview"); omit
  (or `:all`) for every deployment. The dashboard's production deploy list passes
  `environment: "production"` so branch previews render in their own section.
  """
  @spec list_deployments(Site.t() | binary(), pos_integer(), keyword()) :: [Deployment.t()]
  def list_deployments(site, limit \\ 100, opts \\ []) do
    site_id = site_id(site)

    Deployment
    |> where([d], d.site_id == ^site_id)
    |> filter_environment(Keyword.get(opts, :environment, :all))
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter_environment(query, env) when env in ["production", "preview"],
    do: where(query, [d], d.environment == ^env)

  defp filter_environment(query, _), do: query

  @doc "Fetch a Deployment by id, or nil. A non-UUID id is nil (→ 404), never a 500."
  @spec get_deployment(binary()) :: Deployment.t() | nil
  def get_deployment(id) when is_binary(id) do
    case uuid_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(Deployment, uuid)
    end
  end

  @doc """
  gh-5: APPEND one builder-reported LIVE console line to a deployment — the
  deploy-side twin of `append_provision_console/2`. Best-effort telemetry: it
  records what the builder narrated regardless of the deployment's current
  status (a late line after a build succeeded/failed is still a truthful
  record), and NEVER raises on a normal report. The array is APPEND-ONLY and
  CAPPED at `@max_console_lines` (oldest dropped) so a chatty/looping build
  can't grow the row unbounded. Each element is `%{"line" => line, "at" =>
  iso8601}`; the timestamp is stamped HERE (server clock), never trusted from
  the builder. Reuses `validate_console_line/1` + `cap_console/1`.

  Returns `{:ok, deployment}` with the appended array, `{:error, :not_found}`
  for an unknown id, or `{:error, :invalid}` for a missing/blank/oversized line
  (the router 422s it rather than persisting garbage).
  """
  @spec append_deployment_console(binary(), term()) ::
          {:ok, Deployment.t()} | {:error, :not_found | :invalid}
  def append_deployment_console(id, line) when is_binary(id) do
    with {:ok, line} <- validate_console_line(line),
         %Deployment{} = deployment <- uuid_or_nil(id) && Repo.get(Deployment, id) do
      entry = %{"line" => line, "at" => DateTime.to_iso8601(DateTime.utc_now())}
      console = cap_console((deployment.console || []) ++ [entry])

      deployment
      |> Deployment.transition_changeset(%{console: console})
      |> Repo.update()
    else
      :error -> {:error, :invalid}
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  Transition a Deployment to a new status, optionally stamping `image_tag`,
  `build_log_url`, `failure_reason`, or `became_live_at`. Used by the off-box
  builder (P2) and the box agent (P3). Narrow by design — cannot move a
  deployment between sites.
  """
  @spec transition_deployment(Deployment.t(), map()) ::
          {:ok, Deployment.t()} | {:error, Ecto.Changeset.t()}
  def transition_deployment(%Deployment{} = deployment, attrs) do
    deployment
    |> Deployment.transition_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Atomically claim the oldest queued Deployment for `worker_id`. Returns
  `{:ok, deployment}` carrying the bumped `claim_epoch`, or `{:error, :no_queued}`
  when the queue is empty.

  Concurrency: the SELECT uses `FOR UPDATE SKIP LOCKED` so two workers racing
  never collide — each picks a distinct row (or one finds no rows). The whole
  operation runs in one transaction, so the epoch bump + status flip + worker
  stamp are atomic with the row lock.

  Fencing: the `claim_epoch` increments on every successful claim; the builder
  passes the observed epoch into `transition_deployment_fenced/4`, which CASes
  on it — a stale-but-alive worker writing after its lease was swept fails the
  CAS instead of corrupting state.
  """
  @spec claim_next_deployment(String.t()) ::
          {:ok, Deployment.t()} | {:error, :no_queued}
  def claim_next_deployment(worker_id) when is_binary(worker_id) and worker_id != "" do
    Repo.transaction(fn ->
      query =
        from(d in Deployment,
          where: d.status == "queued",
          order_by: [asc: d.inserted_at],
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED"
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:no_queued)

        %Deployment{} = d ->
          {:ok, claimed} =
            d
            |> Deployment.transition_changeset(%{
              status: "building",
              claim_worker: worker_id,
              claimed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
              claim_epoch: d.claim_epoch + 1
            })
            |> Repo.update()

          claimed
      end
    end)
  end

  @doc """
  Transition a claimed Deployment, CASing on the worker's observed epoch. Returns
  `{:ok, deployment}` when the CAS holds; `{:error, :stale_epoch}` when the row's
  epoch has moved past `observed_epoch` (lease swept, re-claimed by another
  worker, or even the same worker after a re-claim); `{:error, :not_found}` when
  the deployment id doesn't exist.

  This is the fenced write the off-box builder uses for status updates — pushing,
  live, failed — without trampling a parallel re-claim.
  """
  @spec transition_deployment_fenced(binary(), String.t(), non_neg_integer(), map()) ::
          {:ok, Deployment.t()} | {:error, :stale_epoch | :not_found | Ecto.Changeset.t()}
  def transition_deployment_fenced(deployment_id, worker_id, observed_epoch, attrs)
      when is_binary(deployment_id) and is_binary(worker_id) and is_integer(observed_epoch) do
    # A non-UUID id would make the `d.id == ^deployment_id` query raise
    # Ecto.Query.CastError → HTTP 500; route it to the documented 404 branch.
    case uuid_or_nil(deployment_id) do
      nil ->
        {:error, :not_found}

      _uuid ->
        do_transition_deployment_fenced(deployment_id, worker_id, observed_epoch, attrs)
    end
  end

  defp do_transition_deployment_fenced(deployment_id, worker_id, observed_epoch, attrs) do
    Repo.transaction(fn ->
      query =
        from(d in Deployment,
          where: d.id == ^deployment_id,
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %Deployment{claim_epoch: e, claim_worker: w}
        when e != observed_epoch or w != worker_id ->
          Repo.rollback(:stale_epoch)

        %Deployment{} = d ->
          if illegal_deployment_transition?(d, attrs) do
            Repo.rollback(:illegal_transition)
          else
            case d |> Deployment.transition_changeset(attrs) |> Repo.update() do
              {:ok, updated} -> updated
              {:error, cs} -> Repo.rollback(cs)
            end
          end
      end
    end)
  end

  @doc """
  Like `transition_deployment_fenced/4`, but in the SAME transaction also updates
  the Deployment's Site with the `site_attrs` runtime-changeset map (allowed
  keys: `:port`, `:current_deployment_id`). This is how the on-box agent flips
  the live-pointer atomically with the deployment going `live` — no window where
  the deployment is `live` but the site still points at the old port, or vice
  versa.

  Returns the updated deployment on success; same `:stale_epoch` / `:not_found`
  / changeset errors as the simple variant.
  """
  @spec transition_deployment_with_site_update(
          binary(),
          String.t(),
          non_neg_integer(),
          map(),
          map()
        ) ::
          {:ok, Deployment.t()} | {:error, :stale_epoch | :not_found | Ecto.Changeset.t()}
  def transition_deployment_with_site_update(
        deployment_id,
        worker_id,
        observed_epoch,
        deployment_attrs,
        site_attrs
      )
      when is_binary(deployment_id) and is_binary(worker_id) and
             is_integer(observed_epoch) and is_map(site_attrs) do
    # A non-UUID id would make the `d.id == ^deployment_id` query raise
    # Ecto.Query.CastError → HTTP 500; route it to the documented 404 branch.
    case uuid_or_nil(deployment_id) do
      nil ->
        {:error, :not_found}

      _uuid ->
        do_transition_deployment_with_site_update(
          deployment_id,
          worker_id,
          observed_epoch,
          deployment_attrs,
          site_attrs
        )
    end
  end

  defp do_transition_deployment_with_site_update(
         deployment_id,
         worker_id,
         observed_epoch,
         deployment_attrs,
         site_attrs
       ) do
    Repo.transaction(fn ->
      query =
        from(d in Deployment,
          where: d.id == ^deployment_id,
          lock: "FOR UPDATE",
          preload: [:site]
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %Deployment{claim_epoch: e, claim_worker: w}
        when e != observed_epoch or w != worker_id ->
          Repo.rollback(:stale_epoch)

        %Deployment{} = d ->
          if illegal_deployment_transition?(d, deployment_attrs) do
            Repo.rollback(:illegal_transition)
          else
            with {:ok, updated} <-
                   d |> Deployment.transition_changeset(deployment_attrs) |> Repo.update(),
                 {:ok, _site} <-
                   d.site |> Site.runtime_changeset(site_attrs) |> Repo.update() do
              updated
            else
              {:error, cs} -> Repo.rollback(cs)
            end
          end
      end
    end)
  end

  # The fenced writers enforce the from-status transition graph here, where the
  # current row is locked and in hand — the changeset only knows the target
  # status is a valid enum, not that the edge from the current status is legal
  # (e.g. failed → live, live → building). A nil target means a field-only
  # update (image_tag / build_log_url / failure_reason) → always allowed.
  defp illegal_deployment_transition?(%Deployment{status: from}, attrs) do
    target = Map.get(attrs, :status) || Map.get(attrs, "status")
    target != nil and not Deployment.legal_transition?(from, target)
  end

  ## Agent (on-box runtime) — pending pickup + atomic claim, scoped to the
  ## agent's Barkpark. The runtime executor (P3) calls these to drive
  ## Deployments from `pushing` → `live` (or → `failed` on health-check fail).

  @doc """
  List Deployments in `pushing` status that belong to a Site on `barkpark` —
  the on-box agent's pending queue. Newest first so a fresh deploy claims first.
  """
  @spec list_pending_deployments_for_barkpark(Barkpark.t() | binary()) :: [Deployment.t()]
  def list_pending_deployments_for_barkpark(barkpark) do
    bp_id = barkpark_id(barkpark)

    from(d in Deployment,
      join: s in Site,
      on: s.id == d.site_id,
      where: d.status == "pushing" and s.barkpark_id == ^bp_id,
      order_by: [desc: d.inserted_at],
      # Preload the site in the SAME query so deployment_with_site_json/1 (which
      # bundles the site's slug + domains) never falls back to a per-row
      # Registry.get_site/1 — i.e. no N+1 when listing multiple pending deploys.
      preload: [site: s]
    )
    |> Repo.all()
  end

  @doc """
  Atomically claim the oldest pushing Deployment whose Site is on `barkpark`,
  for `worker_id`. The on-box agent's analogue of `claim_next_deployment/1` —
  same `FOR UPDATE SKIP LOCKED` discipline + epoch bump, narrower filter.

  Returns `{:ok, deployment}` with the bumped epoch, or `{:error, :no_pending}`
  when the agent has nothing waiting on this box. Returns `{:error, :wrong_box}`
  is NOT a case — a deployment whose site is on another box simply isn't in
  this barkpark's queue, indistinguishable from an empty queue, and that is
  intentional (no cross-box existence leak).
  """
  @spec claim_pending_deployment_for_barkpark(Barkpark.t() | binary(), String.t()) ::
          {:ok, Deployment.t()} | {:error, :no_pending}
  def claim_pending_deployment_for_barkpark(barkpark, worker_id)
      when is_binary(worker_id) and worker_id != "" do
    bp_id = barkpark_id(barkpark)

    Repo.transaction(fn ->
      query =
        from(d in Deployment,
          join: s in Site,
          on: s.id == d.site_id,
          where:
            d.status == "pushing" and s.barkpark_id == ^bp_id and
              is_nil(d.claim_worker),
          order_by: [asc: d.inserted_at],
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED",
          select: d
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:no_pending)

        %Deployment{} = d ->
          {:ok, claimed} =
            d
            |> Deployment.transition_changeset(%{
              claim_worker: worker_id,
              claimed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
              claim_epoch: d.claim_epoch + 1
            })
            |> Repo.update()

          claimed
      end
    end)
  end

  @doc """
  oban-substrate: proactively recover deployments wedged past the staleness
  threshold, the deploy-queue twin of `reap_stale_provision_jobs/0`. This is what
  `BarkparkCloud.Workers.StaleDeploymentReaper` calls every minute so a crashed
  builder or on-box agent is recovered on a fixed cadence instead of leaving the
  site's deploy queue stuck behind an eternal spinner.

  Neither claim path recovers a wedged row lazily: `claim_next_deployment/1` only
  matches `status == "queued"`, so a builder that crashes after the claim leaves
  the row "building" forever; `claim_pending_deployment_for_barkpark/2` requires
  `is_nil(claim_worker)`, so a crashed on-box agent wedges a "pushing" row
  forever. This sweep is the lease that fences both, in four status-guarded
  `update_all` passes (the first NOT staleness-gated) against
  `stale_before = now - deployment_stale_after_seconds`:

    * (0) FAIL a `queued` row with NO build source — no `artifact_url` AND a site
      with no `github_repo`. Such a row can NEVER build regardless of fleet
      (nothing to build from), so it would otherwise sit queued forever behind an
      eternal dashboard spinner. NOT staleness-gated (it is un-buildable the
      instant it exists). Repo-backed queued rows (a `github_repo` is set) are
      left untouched — they await the source-build path. Run FIRST so it only
      fails rows genuinely queued at sweep start, never a row the requeue pass
      moves building → queued in this same sweep.
    * (i) FAIL a stale `building` row whose `claim_epoch` has reached
      `max_deploy_claims/0` — terminal, so a permanently-crashing build stops
      looping. Run before the requeue pass so an exhausted row terminates
      instead of requeueing.
    * (ii) REQUEUE the remaining stale `building` rows → `queued` (claim_worker /
      claimed_at cleared). `claim_epoch` is deliberately NOT touched — the next
      `claim_next_deployment/1` bumps it, so a resurrected old builder's fenced
      write fails the existing `transition_deployment_fenced/4` CAS by design.
    * (iii) RELEASE a stale on-box agent claim on a `pushing` row (clear
      claim_worker / claimed_at only — status STAYS `pushing`) so
      `claim_pending_deployment_for_barkpark/2` re-matches it for a fresh agent.

  Each pass is a status-guarded `update_all`, so a race with a concurrent claim
  simply no-ops on rows the other path already moved. Returns
  `%{failed: n, requeued: n, released: n, no_source_failed: n}`; an empty sweep
  returns all-zeros and never raises.
  """
  @spec reap_stale_deployments() :: %{
          failed: non_neg_integer(),
          requeued: non_neg_integer(),
          released: non_neg_integer(),
          no_source_failed: non_neg_integer()
        }
  def reap_stale_deployments do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    stale_before = DateTime.add(now, -deployment_stale_after_seconds(), :second)
    max_claims = max_deploy_claims()

    # (0) No build source: a queued row with no artifact_url whose site has no
    # connected github_repo can never build regardless of fleet. Terminate it
    # (queued → failed) so the dashboard renders a real failure instead of an
    # eternal spinner. NOT staleness-gated — it is un-buildable the instant it
    # exists. Repo-backed queued rows are excluded by the join predicate. Run
    # FIRST so it only fails rows genuinely queued at sweep start — never a row
    # the requeue pass (ii) moves building → queued in this same sweep.
    {no_source_failed, _} =
      from(d in Deployment,
        join: s in Site,
        on: s.id == d.site_id,
        where: d.status == "queued" and is_nil(d.artifact_url) and is_nil(s.github_repo)
      )
      |> Repo.update_all(
        set: [
          status: "failed",
          failure_reason:
            "no build source (upload an artifact via `bp deploy` or connect a GitHub repo)",
          updated_at: now
        ]
      )

    # (i) Over budget: fail it (don't requeue). Run before the requeue pass so an
    # exhausted row terminates — the requeue pass's status guard then skips it.
    {failed, _} =
      from(d in Deployment,
        where:
          d.status == "building" and d.claimed_at < ^stale_before and
            d.claim_epoch >= ^max_claims
      )
      |> Repo.update_all(
        set: [
          status: "failed",
          failure_reason: "exceeded max deploy claim attempts (stale builder lease)",
          claim_worker: nil,
          claimed_at: nil,
          updated_at: now
        ]
      )

    # (ii) Under budget: requeue so a fresh claim_next_deployment picks it up (and
    # bumps claim_epoch then). claim_epoch is left untouched by design.
    {requeued, _} =
      from(d in Deployment,
        where: d.status == "building" and d.claimed_at < ^stale_before
      )
      |> Repo.update_all(
        set: [status: "queued", claim_worker: nil, claimed_at: nil, updated_at: now]
      )

    # (iii) Release a stale on-box agent claim — status stays "pushing" so the
    # agent's claim path re-matches it; only the claim is dropped.
    {released, _} =
      from(d in Deployment,
        where:
          d.status == "pushing" and not is_nil(d.claim_worker) and
            d.claimed_at < ^stale_before
      )
      |> Repo.update_all(set: [claim_worker: nil, claimed_at: nil, updated_at: now])

    %{failed: failed, requeued: requeued, released: released, no_source_failed: no_source_failed}
  end

  ## Helpers

  # Guard a :binary_id PK lookup: a non-UUID id (a malformed path param) makes
  # Repo.get raise Ecto.Query.CastError → an HTTP 500. Returning nil here for a
  # non-castable id routes it to the {:error, :not_found} branch (→ 404), which is
  # what the API documents for an absent/invalid job id. A valid UUID passes
  # through unchanged. Delegates to the shared BarkparkCloud.Repo.uuid_or_nil/1.
  defp uuid_or_nil(id), do: Repo.uuid_or_nil(id)

  defp generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  # Carry an optional attr (`field`) from a string- or atom-keyed source map into
  # `acc` ONLY when the source actually has it — so an explicit falsy value (e.g.
  # `is_secret: false`) survives while a genuinely-absent key falls through to the
  # schema default / existing row value. `nil` and `false` are distinct here.
  defp put_if_present(acc, source, field) do
    cond do
      Map.has_key?(source, field) ->
        Map.put(acc, field, Map.get(source, field))

      Map.has_key?(source, to_string(field)) ->
        Map.put(acc, field, Map.get(source, to_string(field)))

      true ->
        acc
    end
  end

  defp team_id(%Team{id: id}), do: id
  defp team_id(id) when is_binary(id), do: id

  defp barkpark_id(%Barkpark{id: id}), do: id
  defp barkpark_id(id) when is_binary(id), do: id

  defp site_id(%Site{id: id}), do: id
  defp site_id(id) when is_binary(id), do: id

  # Stamp the resolved team_id into attrs (string- or atom-keyed), so callers
  # pass the Team positionally and never have to thread :team_id themselves.
  defp put_team_id(attrs, team) when is_map(attrs) do
    tid = team_id(team)

    if Map.has_key?(attrs, "team_id") or
         (not Map.has_key?(attrs, :team_id) and string_keyed?(attrs)) do
      Map.put(attrs, "team_id", tid)
    else
      Map.put(attrs, :team_id, tid)
    end
  end

  defp string_keyed?(attrs) do
    Enum.any?(attrs, fn {k, _} -> is_binary(k) end)
  end
end
