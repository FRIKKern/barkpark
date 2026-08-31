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
  alias BarkparkCloud.Accounts.{Team, TeamMembership, User}
  alias BarkparkCloud.Billing
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.GitHub.CommitDistance
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.Withhold

  alias BarkparkCloud.Registry.{
    AgentEvent,
    AgentToken,
    Barkpark,
    Deployment,
    EnvVar,
    FleetSettings,
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

  # A barkpark row that has NEVER phoned home (last_seen_at nil) and is older
  # than this stops holding a name claim against custom-host attachment — see
  # provisioning_fqdn_taken?/2. Every live instance reports within a minute of
  # provisioning, so 7 days of silence-from-birth is unambiguous abandonment.
  #
  # SILENCE-FROM-BIRTH IS NOT ABANDONMENT ON ITS OWN. Measured 2026-08-08, this
  # clock alone was 0-for-3 on live data: all three rows it would have released
  # were on live subscriptions and one was still being polled every ~15 minutes
  # with its decrypted admin bearer token. `provisioning_fqdn_claim/2` therefore
  # guards it with three further legs; this constant is only the LAST of six.
  @abandoned_claim_after_days 7

  # A `usage_samples` row inside this window is proof of an IN-FLIGHT
  # platform→instance transmission (the sampler writes one row per checkable
  # instance every ~15 min, crontab 7,22,37,52), so it is a hard block on
  # releasing the row's name claim. Sized well above the sampler's own period so
  # a couple of missed sweeps cannot look like silence — see claim_leg/2.
  @recent_sample_window_hours 24

  # The four terminal reasons `reap_stale_deployments/0` stamps. Named so the
  # alert fan-out below can pair a reaped row with the reason it was just written
  # (a bulk `update_all` returns ids, not the row it wrote) without the two
  # drifting apart. `FailureCopy.classify/1` has a clause for each.
  @no_build_source_reason "no build source (upload an artifact via `bp deploy` or connect a GitHub repo)"
  @no_content_binding_reason "no content binding (create the site with `--dataset <workspace>/<project>/<dataset>`)"
  @stale_builder_reason "exceeded max deploy claim attempts (stale builder lease)"
  @instance_unreachable_reason "instance unreachable — deploy could not be delivered; check instance health"

  # BATCHING POLICY for a mass reap. `Notifications.dispatch_event/3` is
  # SYNCHRONOUS for email (cloud/ has no Oban for the mail path — only for chat),
  # and this sweep runs every minute on the `maintenance` queue. A cluster-wide
  # incident can fail hundreds of rows in one pass, which would become hundreds
  # of blocking `Mailer.deliver` calls inside one cron tick — enough to hold the
  # queue past the next tick and to trip any provider's rate limit.
  #
  # So the sweep alerts at most this many DEPLOYMENTS per tick and logs the
  # remainder. The choice is deliberate: past ~25 simultaneous failures the
  # person's problem is an incident, not N deployments, and the 26th email tells
  # them nothing the first 25 did not. Nothing is lost — every reaped row is
  # terminal in the console with its reason, which is the surface of record. The
  # correct fix is an Oban-backed mail queue; when that lands this cap should go.
  @reap_alert_cap 25

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

  # Support-provision stale-claim recovery (task-314de6aa36248bea). The
  # `provision_support` chain legitimately runs far past the generic threshold:
  # the Go worker's DefaultSupportProvisionTimeout is 30 minutes (the roster-verify
  # budget alone is 10, and the CLI's provisioning roster row carries the matching
  # ttl_s=1800 — internal/cli/cloud_support_cmd.go). Threshold = that 30-minute
  # worker budget + 5 minutes margin for teardown + the report round-trip, so a
  # HEALTHY support chain is never re-pended mid-flight (a re-pend double-claims:
  # two billed boxes for one add). Every OTHER kind keeps
  # @default_stale_after_seconds exactly. Overridable via
  # `config :barkpark_cloud, :support_provision_stale_after_seconds`.
  # Default: 35 minutes.
  @default_support_stale_after_seconds 35 * 60

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

  # Queued-age ALARM horizon (jpf-w1-queue-age-alarm) — how long a `queued`
  # container-site deployment may sit unclaimed before clients surface it as
  # `deploy_stalled`. One third of the reaper threshold above ON PURPOSE: the
  # reaper mutates builder LEASES (its passes are all claimed_at-gated — a row
  # no builder ever claimed has claimed_at nil and is invisible to it by
  # design), while this number judges exactly that never-claimed orphan class,
  # read-only, and must fire well before anyone would call a builder lease
  # abandoned. Default: 5 minutes.
  @default_queued_deploy_alarm_after_seconds 5 * 60

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

  # dwb-16: hard cap on a SINGLE console line. A longer line is TRUNCATED to this
  # many characters (never rejected — see `validate_console_line/1`), and the
  # entry then carries `"truncated_from" => <original length>` so the reader can
  # see that the line it is being shown is a prefix, not the whole line.
  @max_console_line_chars 2_000

  # Same append-only bound for a job's step-transition array (mirrors
  # @max_console_lines, oldest dropped). ~5 steps × 3 statuses + retries fits easily.
  @max_step_entries 100

  # stw9 (charter D56/D57): the site kinds that BIND to a content dataset and are
  # therefore eligible for publish-to-live (a minted content-publish secret) and
  # for the scheduled freshness sweep. `static` builds the content into files;
  # `node` fetches the same content and serves it via SSR — both go stale when the
  # content or the template moves. `container` binds no dataset and is excluded.
  @content_bound_kinds ~w(static node)

  ## Barkparks

  @doc """
  Register a Barkpark for `team` from `attrs`. The Team is taken from the first
  argument (struct or id) — `attrs` need not (and should not) carry `:team_id`.

  Returns `{:ok, %Barkpark{}}` or `{:error, %Ecto.Changeset{}}` (e.g. the slug
  already exists in this team).

  usage-limits-quotas: this is the MAIN-instance create path, so the per-plan
  instance quota is enforced here — the backstop for a MAIN (go-live / adopt /
  agent register). A team already AT its plan ceiling gets `{:error,
  :limit_reached}` (Coolify's `serverLimitReached`, the API altitude the UI can't
  route around). The friendly HTTP 403 in the router's `go_live/1` is the front
  door; this guard catches the agent/internal register path too.
  `upsert_barkpark/2` routes EXISTING `(team_id, slug)` rows to update before
  reaching here, so an idempotent re-register is never blocked — only a genuine
  new instance. Only a team with an ACTIVE subscription is quota-gated; an
  unsubscribed team is `false` here (the go-live 402 is what stops it).

  PDF-D86 (the ONE documented exception): a fleet SUPPORT insert does NOT flow
  through this guard — `register_support_barkpark/2` inserts via
  `insert_barkpark/2` directly, so a support can be added to a main that already
  saturates the ceiling. Supports are subordinate runners, not billable mains;
  the exception is role-scoped to support inserts and lives in exactly one place
  (that function), so a MAIN can never ride it.
  """
  @spec register_barkpark(Team.t() | binary(), map()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t() | :limit_reached}
  def register_barkpark(team, attrs) do
    # The transaction's VALUE carries the outcome; `Repo.rollback/1` is
    # deliberately not used. `adopt_barkpark/3` calls this from INSIDE its own
    # `Repo.transaction`, where a rollback would sink the caller's transaction
    # instead of returning it a decision — and that caller's `with/else` already
    # rolls back on `{:error, reason}` itself.
    case Repo.transaction(fn -> register_barkpark_txn(team, attrs) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # THE QUOTA CHECK AND THE INSERT ARE ONE ATOMIC ACT (acpc-bl-cloud-registry-
  # barkpark-limit-toctou). They used to be two uncoordinated calls:
  #
  #     if Billing.barkpark_limit_reached?(team), do: ..., else: insert_barkpark(...)
  #
  # Two registrations for the same team arriving at the ceiling both evaluated
  # `barkpark_limit_reached?/1` before either inserted, both read the same count,
  # both saw `false`, and both inserted — one box over the plan ceiling, per
  # racing pair. Not admin-gated: go-live, adopt and agent-register all reach it,
  # and unlike the api-side twin this one guards a PAID boundary, so the overshoot
  # is billable capacity given away.
  #
  # THE INVARIANT IS ENFORCED BY THE DATABASE, not by a wider application check —
  # an application-level check can never be atomic against another node. The team
  # row is taken `FOR UPDATE` first, so concurrent registrations for the SAME team
  # serialize: the second blocks until the first commits, then counts a table that
  # already includes the first's row.
  #
  # WHY A ROW LOCK AND NOT A CONSTRAINT. The rejected alternatives, recorded:
  #
  #   * CHECK constraint — cannot express this invariant. The ceiling is not a
  #     constant: it is `Billing.limits()[subscription.plan]`, read at call time
  #     from application config, and a CHECK may not read another table.
  #   * counter column on `teams` + CHECK — expressible, but it duplicates a fact
  #     the `barkparks` table already holds, and every writer that inserts or
  #     deletes a box (including the FK cascades) becomes responsible for keeping
  #     the mirror true. A denormalised counter that drifts is a worse failure
  #     than the race it fixes.
  #   * partial unique / exclusion constraint — has no rank to key on; the boxes
  #     are not numbered 1..N.
  #   * `pg_advisory_xact_lock(hashtext("team:" <> tid))` — equivalent
  #     serialization and the idiom `api/`'s task mutations use. Rejected only
  #     because the real team row exists and locking it is narrower: it takes no
  #     shared hash space, and it cannot collide with an unrelated advisory key.
  #
  # SCOPE: the lock is per-TEAM, so registrations for different teams do not
  # contend at all. It is NOT a global registration lock.
  defp register_barkpark_txn(team, attrs) do
    _ = lock_team_for_quota(team)

    if Billing.barkpark_limit_reached?(team) do
      {:error, :limit_reached}
    else
      insert_barkpark(team, attrs)
    end
  end

  # Take the team row `FOR UPDATE` so the count-then-insert below is serialized
  # per team. Held until the enclosing transaction commits — including an OUTER
  # one (`adopt_barkpark/3`), which is correct: the quota decision must not be
  # observable to a racing writer before the row that satisfies it is committed.
  #
  # A missing or non-UUID team returns nil rather than raising: the insert that
  # follows fails its `team_id` FK anyway, and the error a caller gets should be
  # the changeset it would have got before this lock existed, not a new
  # `Ecto.Query.CastError` from the lock. `Repo.uuid_or_nil/1` is the codebase's
  # one home for that guard.
  defp lock_team_for_quota(team) do
    case Repo.uuid_or_nil(team_id(team)) do
      nil ->
        nil

      tid ->
        Repo.one(from(t in Team, where: t.id == ^tid, select: t.id, lock: "FOR UPDATE"))
    end
  end

  # The bare create — changeset + insert, NO quota check. `register_barkpark/2`
  # gates it behind `barkpark_limit_reached?/1` for every MAIN insert; the ONLY
  # other caller is `register_support_barkpark/2`, which reaches it directly so a
  # SUPPORT insert is quota-exempt (PDF-D86). Keep this private: a new caller that
  # skips the quota must be a deliberate, documented exception, not an accident.
  defp insert_barkpark(team, attrs) do
    %Barkpark{}
    |> Barkpark.changeset(put_team_id(attrs, team))
    # `mode: :savepoint` because BOTH callers now run inside a transaction
    # (`register_barkpark/2` for the quota lock, `register_support_barkpark/2` for
    # the fleet write). Without it a unique-constraint violation aborts the whole
    # enclosing transaction, and `Repo.transaction` answers `{:error, :rollback}`
    # instead of the `{:error, %Ecto.Changeset{}}` every caller matches on —
    # which is exactly how `insert_with_url_reservation/4`'s clean-label retry
    # decides to fall back to the suffixed FQDN. The savepoint keeps the
    # constraint error a VALUE the caller can read, as it was before the lock.
    |> Repo.insert(mode: :savepoint)
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
  EVERY Barkpark row across ALL teams, newest first — the fleet-ops view behind
  `GET /v1/internal/barkparks` (worker-token only; never a user surface). The
  `bp cloud hetzner instance` admin verbs cross-check this against the live
  Hetzner servers and DNS zone, so it deliberately ignores team scoping.
  """
  @spec all_barkparks() :: [Barkpark.t()]
  def all_barkparks do
    Barkpark
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  @doc """
  ADOPT an already-running box as a managed row (the standalone → SaaS-tenant
  path, `bp cloud hetzner instance adopt`): one registered row with `host` and
  `health_status: "unknown"` in a single transaction, optionally landing the
  instance's admin token (Vault-encrypted here, like `succeed_job/3`).

  The health value is `"unknown"`, NOT `"up"`: adoption records an operator's
  intent, not a measurement — no agent report has arrived, so `last_seen_at`
  stays NULL and there is nothing to call healthy. The row goes green the first
  time `POST /v1/agent/report` lands (`record_agent_report/2`).

  Rides `register_barkpark/2`, so the per-plan instance quota and the
  slug/url unique constraints all apply — an adopted instance is a first-class
  tenant, not a side door around billing.
  """
  @spec adopt_barkpark(Team.t() | binary(), map(), keyword()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t() | :limit_reached}
  def adopt_barkpark(team, attrs, opts \\ []) do
    admin_token = Keyword.get(opts, :admin_token)

    Repo.transaction(fn ->
      with {:ok, bp} <- register_barkpark(team, attrs),
           live_attrs =
             %{host: Map.get(attrs, :host) || Map.get(attrs, "host"), health_status: "unknown"}
             |> maybe_put_admin_token(admin_token),
           {:ok, live} <- bp |> Barkpark.health_changeset(live_attrs) |> Repo.update() do
        live
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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

    # Provider-neutral launch config (charter Decision 9). `provider` is folded in
    # only when given (the schema default is hetzner, so a provider-less caller —
    # e.g. the adopt/self-host paths — stays Hetzner). `region`/`server_type` are
    # folded in only when a non-blank value was pinned, so a bare launch leaves
    # them NULL and the claim payload falls back to the warm-pool defaults.
    attrs =
      attrs
      |> maybe_put_launch_opt(:provider, Keyword.get(opts, :provider))
      |> maybe_put_launch_opt(:region, Keyword.get(opts, :region))
      |> maybe_put_launch_opt(:server_type, Keyword.get(opts, :server_type))

    insert_with_url_reservation(team, attrs, slug, &register_barkpark(team, &1))
  end

  # The ONE clean-first/suffix-on-collision url reservation dance, shared by
  # mains AND supports (a support's url is its reservation from birth, same as a
  # main's — `mint_studio_link/2` needs it, and the worker turns its first label
  # into the DNS record). `insert_fun` is the role-specific write (mains:
  # `register_barkpark/2` with the quota backstop; supports: the quota-exempt
  # fleet transaction) so the dance stays identical while the insert differs.
  # RACE-SAFE exactly as before: `barkparks_url_unique_idx` decides a concurrent
  # clean-claim and the loser retries with its suffixed url — unique by
  # construction, so it can never collide.
  defp insert_with_url_reservation(team, attrs, slug, insert_fun) when is_binary(slug) do
    tid = team_id(team)
    suffixed = Barkpark.provisioning_url({slug, tid})
    candidate = if Barkpark.reserved?(slug), do: suffixed, else: Barkpark.clean_url(slug)

    case insert_fun.(Map.put(attrs, :url, candidate)) do
      {:ok, barkpark} ->
        {:ok, barkpark}

      # usage-limits-quotas: the quota backstop fired in register_barkpark/2 — the
      # team is at its plan ceiling. Surface it unchanged so the router's go_live
      # `with/else` maps it to a 403 (never a 500 from an unmatched clause).
      # (Supports never produce it — PDF-D86 — so the clause simply never matches.)
      {:error, :limit_reached} = err ->
        err

      {:error, %Ecto.Changeset{} = cs} ->
        # Clean label was already claimed (by any team) → fall back to the
        # globally-unique suffixed FQDN. Only retry on a `url` uniqueness clash,
        # and only when we actually tried the clean form.
        if candidate != suffixed and url_conflict?(cs) do
          insert_fun.(Map.put(attrs, :url, suffixed))
        else
          {:error, cs}
        end
    end
  end

  # A non-binary slug can't derive a url candidate — hand the attrs straight to
  # the insert so ITS changeset names the real error (slug can't be blank),
  # instead of a FunctionClauseError out of provisioning_url/1.
  defp insert_with_url_reservation(_team, attrs, _slug, insert_fun), do: insert_fun.(attrs)

  @doc """
  Register a SUPPORT machine as a fleet group row bound to a main (Personal Dev
  Fleet Wave C, PDF-D61). The support is an ordinary `barkparks` row carrying the
  three fleet columns — `fleet_role: "support"`, `fleet_parent_id` = the main's
  id, and the opaque `fleet_token_id` (the minted ledger token id for later
  revocation, NEVER the secret).

  QUOTA-EXEMPT (PDF-D86 — the ONE documented exception to the create-time
  backstop): this inserts via `insert_barkpark/2` directly, NOT through
  `register_barkpark/2`, so `Billing.barkpark_limit_reached?/1` is deliberately
  skipped for support inserts. A trial team's ceiling (1) is saturated by its
  main, so gating supports on it would make add-support impossible — yet a support
  is a subordinate runner, not a billable main. The bypass is role-scoped by
  construction: it lives only here, and only a `fleet_role: "support"` row is
  written. A MAIN insert (go-live / adopt / agent register) still flows through
  `register_barkpark/2` and is still blocked at the ceiling. The slug/url unique
  constraints still apply. The fleet fields are stamped via `fleet_changeset/2`
  in the SAME transaction, so a support row can never exist half-bound
  (registered but role-less); any error rolls the whole thing back and is
  surfaced unchanged for the router to map.

  `attrs` is `%{name, slug, host, parent_id, token_id, server_type?}`. `host` is
  NIL for a CP-provisioned support (the row is written FIRST, then the
  `provision_support` job fills the box in — PDF-D83); a `server_type` folds the
  chosen size onto the row so the claim payload carries it. The CALLER (router)
  has already verified `parent_id` belongs to `team` — this is the write, not the
  authorization.

  FULL PUBLIC IDENTITY: the support's `url` is reserved HERE, at registration,
  through the exact clean-first/suffix-on-collision dance mains run
  (`insert_with_url_reservation/4`) — a support fronts the public internet like
  a main now, so `mint_studio_link/2` works and the claim payload's `slug`
  derives from the reserved url's first label (the DNS record the worker stands
  up). Both register modes get it: a support's url is its reservation from
  birth.
  """
  @spec register_support_barkpark(Team.t() | binary(), map()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def register_support_barkpark(team, attrs) do
    slug = Map.get(attrs, :slug)

    base =
      %{
        name: Map.get(attrs, :name),
        slug: slug
      }
      |> maybe_put_launch_opt(:host, Map.get(attrs, :host))
      |> maybe_put_launch_opt(:server_type, Map.get(attrs, :server_type))

    fleet = %{
      fleet_role: "support",
      fleet_parent_id: Map.get(attrs, :parent_id),
      fleet_token_id: Map.get(attrs, :token_id)
    }

    insert_with_url_reservation(team, base, slug, fn base_with_url ->
      Repo.transaction(fn ->
        # insert_barkpark/2 (NOT register_barkpark/2) — the PDF-D86 quota bypass:
        # support inserts skip barkpark_limit_reached?/1, mains do not.
        with {:ok, bp} <- insert_barkpark(team, base_with_url),
             {:ok, support} <- bp |> Barkpark.fleet_changeset(fleet) |> Repo.update() do
          support
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
  end

  defp url_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:url, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # Fold a launch-config value into the register attrs only when it is a non-blank
  # binary — a nil/blank opt leaves the column to its schema default / NULL (the
  # claim payload's warm-pool fallback), so a bare launch is byte-identical to the
  # pre-provider-neutral behavior.
  defp maybe_put_launch_opt(attrs, key, value) do
    case value do
      v when is_binary(v) and v != "" -> Map.put(attrs, key, v)
      _ -> attrs
    end
  end

  @doc """
  The decrypted 4-field Azure service-principal credentials for a barkpark's team,
  or `nil` when there is no connected Azure provider row for the team or the stored
  ciphertext won't decrypt/decode (fail-closed — the worker then resolves an
  incomplete-credentials provider and the job fails with an honest error, never a
  crash).

  Mirrors `resolved_env_for_barkpark/1`: resolved at CLAIM time so a ROTATED
  credential is always the one handed to the worker, and it is the single
  sanctioned plaintext crossing — sent ONLY over the worker-token internal channel
  (TLS in prod), never serialized to a user surface. Newest connected Azure
  provider wins (mirrors the router's `provider_of_kind/2`).
  """
  @spec resolved_azure_credentials_for_barkpark(Barkpark.t()) :: map() | nil
  def resolved_azure_credentials_for_barkpark(%Barkpark{team_id: tid}) do
    Provider
    |> where([p], p.team_id == ^tid and p.kind == "azure")
    |> order_by([p], desc: p.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      %Provider{encrypted_token: ciphertext} ->
        with {:ok, json} <- Vault.decrypt(ciphertext),
             {:ok, creds} when is_map(creds) <- Jason.decode(json) do
          creds
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  The decrypted Cloudflare credential for a `team` — `{:ok, %{token:,
  account_id:, zone_id:}}` from the newest connected `cloudflare` Provider, or
  `{:error, :no_cloudflare_provider}` when the team has connected none.

  This is the D52 per-team credential seam: the CF DNS writers thread `token`
  and `zone_id` in as ARGUMENTS, so a concurrent deploy for a DIFFERENT team can
  never race over a shared `Application.put_env`. The stored `encrypted_token`
  is `Vault.decrypt`'d then parsed — Cloudflare accepts EITHER a bare API-token
  string OR a JSON blob `{api_token, account_id?, zone_id?}` (Provider validates
  this at connect time), so both shapes decode here to the same map (`account_id`
  / `zone_id` are `nil` for a bare token). A present-but-undecryptable /
  unparseable ciphertext fails closed as `{:error, :cloudflare_credential_unreadable}`
  (never a crash, never a silent standalone-bypass).

  `team` is a `Team`, a team id binary, or anything `team_id/1` resolves.
  """
  @spec resolve_cloudflare_credential(Team.t() | binary()) ::
          {:ok, %{token: String.t(), account_id: String.t() | nil, zone_id: String.t() | nil}}
          | {:error, :no_cloudflare_provider | :cloudflare_credential_unreadable}
  def resolve_cloudflare_credential(team) do
    tid = team_id(team)

    Provider
    |> where([p], p.team_id == ^tid and p.kind == "cloudflare")
    |> order_by([p], desc: p.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      %Provider{encrypted_token: ciphertext} ->
        with {:ok, plaintext} <- Vault.decrypt(ciphertext),
             {:ok, creds} <- parse_cloudflare_credential(plaintext) do
          {:ok, creds}
        else
          _ -> {:error, :cloudflare_credential_unreadable}
        end

      _ ->
        {:error, :no_cloudflare_provider}
    end
  end

  # Cloudflare's stored credential is EITHER a JSON blob {api_token, account_id?,
  # zone_id?} or a bare token string (Provider.validate_credential_shape gates
  # both). A JSON object without a non-blank api_token is rejected (it can't
  # authenticate); a non-object / non-JSON string is a bare token.
  defp parse_cloudflare_credential(plaintext) when is_binary(plaintext) do
    case Jason.decode(plaintext) do
      {:ok, %{"api_token" => api_token} = blob} when is_binary(api_token) and api_token != "" ->
        {:ok,
         %{
           token: api_token,
           account_id: blank_to_nil(blob["account_id"]),
           zone_id: blank_to_nil(blob["zone_id"])
         }}

      {:ok, %{}} ->
        # A JSON object that carries no usable api_token can't authenticate.
        :error

      _ ->
        case String.trim(plaintext) do
          "" -> :error
          token -> {:ok, %{token: token, account_id: nil, zone_id: nil}}
        end
    end
  end

  defp parse_cloudflare_credential(_), do: :error

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  @doc "List a Team's Barkparks, newest first. Scoped — never crosses teams."
  @spec list_barkparks(Team.t() | binary()) :: [Barkpark.t()]
  def list_barkparks(team) do
    team_id = team_id(team)

    Barkpark
    |> where([b], b.team_id == ^team_id)
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  @doc "List Barkparks across every Team the user belongs to, newest first."
  @spec list_barkparks_for_user(User.t()) :: [{Barkpark.t(), binary()}]
  def list_barkparks_for_user(%User{} = user) do
    Barkpark
    |> join(:inner, [b], membership in TeamMembership,
      on: membership.team_id == b.team_id and membership.user_id == ^user.id
    )
    |> order_by([b], desc: b.inserted_at)
    |> preload([b], :team)
    |> select([b, membership], {b, membership.role})
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
  azh-w6 (S14c): the team's existing Barkpark with this exact `name`, or nil —
  the resurrect live-twin guard. Because Remove (deprovision) DELETES the
  registry row, a still-present row named the same as an archive you're trying to
  resurrect means a LIVE twin is running: resurrecting would stand up (and bill)
  a second box under the same identity, so the router 422s instead. Team-scoped —
  never crosses teams. Newest first so a (defensive) duplicate resolves
  deterministically.
  """
  @spec get_barkpark_by_name(Team.t() | binary(), binary()) :: Barkpark.t() | nil
  def get_barkpark_by_name(team, name) when is_binary(name) do
    tid = team_id(team)

    Barkpark
    |> where([b], b.team_id == ^tid and b.name == ^name)
    |> order_by([b], desc: b.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def get_barkpark_by_name(_team, _name), do: nil

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
  Delete a Site row — the CP half of a site delete. Cascades the site's
  deployments (`on_delete: :delete_all`). The BOX half (stop slots + disarm the
  Caddy route + delete the tree) is a separate `Sites.Deploy.teardown/2` the
  caller must run FIRST, or a still-serving box is orphaned by the deregister.

  stw9 (charter D56): the site's content-publish webhook is DEREGISTERED from the
  box first, best-effort. Skipping it is what produced guerrilla's 6 orphan
  `site-autodeploy-*` rows — endpoints whose every delivery 404s against a
  receiver that no longer resolves, until the box auto-disables them. A box that
  is down (or a webhook already gone) never blocks the delete: the CP row is the
  truth, and the by-name reconciler can reap the leftover later.

  ssw8 (charter D40, deferred then and paid here): the site's public-read CONTENT
  TOKEN is REVOKED on the box in the same breath, and for the same reason —
  except a live credential is not merely noisy, it is an access grant that
  outlives the thing it was minted for. Measured on guerrilla 2026-07-28: 18 live
  `site-read-*` rows against 12 sites, six of them credentials for sites that no
  longer exist. Every site ever spawned and deleted left one.

  ORDER IS LOAD-BEARING. The revoke runs BEFORE `Repo.delete/1` because the site
  row IS the pointer: `bootstrap_workspace`/`bootstrap_project` name the scope the
  revoke route lives under and `slug` names the label. Delete first and the
  credential is still live with nothing in this database left to find it by.

  WHAT A FAILED REVOKE DOES. It does NOT block the delete — a box that is down
  would otherwise make its sites undeletable, and the CP row is the truth. But it
  is never SILENT either, which is the whole difference from the webhook above: a
  webhook orphan is a failing delivery the box eventually disables by itself,
  while a token orphan is a working credential nothing expires. So the outcome
  travels back to the caller in the ok-tuple as a third element, and the router
  turns `:error` into a 200 that says so and NAMES the leftover (box slug +
  `site-read-<slug>` label) — the pointer the deleted row can no longer hold.

  Returns `{:ok, site, %{read_token: :ok | :noop | :error}}`:

    * `:ok`    — the box confirms no live token by this site's label remains
                 (revoked now, or already gone / never minted)
    * `:noop`  — this site has no content binding, so there is nothing to revoke
    * `:error` — the revoke could not be CONFIRMED; assume the credential is live
  """
  @spec delete_site(Site.t()) ::
          {:ok, Site.t(), %{read_token: :ok | :noop | :error}}
          | {:error, Ecto.Changeset.t()}
          | {:error, :foreign_key_constraint, String.t()}
  def delete_site(%Site{} = site) do
    _ = deregister_content_webhook(site)
    read_token = revoke_site_read_token(site)

    case Repo.delete(site) do
      {:ok, deleted} -> {:ok, deleted, %{read_token: read_token}}
      {:error, changeset} -> {:error, changeset}
    end
  rescue
    # W70 S2 (D848/D856) — the INVERSE ORPHAN made typed. This is a bare
    # `Repo.delete` on a struct with no declared constraint, so a child FK that
    # regressed from CASCADE to RESTRICT/NO ACTION does not surface as
    # `{:error, changeset}` — the DATABASE raises `Ecto.ConstraintError` here,
    # AFTER the caller already tore the box down. Rather than let that crash
    # become an untyped 500 `server_error`, catch the foreign_key case and hand
    # the caller a typed tuple naming the constraint. `ConstraintError.message`
    # is a ~12-line developer blob (SQL, the changeset hint, the whole struct) —
    # it MUST NOT reach a user, so we surface only the constraint NAME and let
    # the router compose the two-halves sentence. Any OTHER constraint type
    # (unique/check/exclusion) is not something this row can hit and is re-raised
    # untouched so a genuine bug still crashes loudly.
    e in Ecto.ConstraintError ->
      case e do
        %Ecto.ConstraintError{type: :foreign_key, constraint: constraint} ->
          {:error, :foreign_key_constraint, constraint}

        other ->
          reraise other, __STACKTRACE__
      end
  end

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
  scan. Two gates apply to EVERY row:

    * `mode ∈ managed/byo` — instances WE operate (a `self_hosted` box is the
      Team's own responsibility, never alerted on);
    * the team has an `active` Subscription — Coolify's `stripe_invoice_paid`
      gate; we don't monitor (or alert on) an unpaid fleet.

  On top of those, a row qualifies through exactly ONE of two arms:

    * WENT SILENT — `agent_status == "online"` and the last heartbeat is older
      than `threshold`. Once the worker flips the row `offline` it leaves this
      arm, which IS the natural backoff (never re-incremented, never re-alerted
      — Barkpark has no active-probe channel to re-test it; the agent re-arms it
      via the report path).
    * NEVER REPORTED — `last_seen_at IS NULL` and the row was created before
      `threshold`: a box we provisioned or adopted whose agent has never sent a
      byte. This arm deliberately does NOT require `agent_status == "online"`,
      because nothing in `cloud/lib` writes `"online"` without co-writing
      `last_seen_at` in the same changeset (the only producer is the
      `POST /v1/agent/report` handler) — requiring it made the arm unreachable
      and the promise in this docstring untrue. Its backoff is the alert latch
      instead of the status flip: once `unreachable_notification_sent` is set the
      row leaves the candidate set, exactly one alert per never-reported box.

  Returns full `%Barkpark{}` structs, longest-silent first — never-reported rows
  sort ahead of rows with a stale heartbeat (`asc_nulls_first`), since a box that
  has never answered has been silent since it was created.
  """
  @spec stale_online_barkparks(DateTime.t()) :: [Barkpark.t()]
  def stale_online_barkparks(%DateTime{} = threshold) do
    from(b in Barkpark,
      join: s in Subscription,
      on: s.team_id == b.team_id and s.status == "active",
      where: b.mode in ["managed", "byo"],
      where:
        (b.agent_status == "online" and not is_nil(b.last_seen_at) and
           b.last_seen_at < ^threshold) or
          (is_nil(b.last_seen_at) and b.inserted_at < ^threshold and
             b.unreachable_notification_sent == false),
      order_by: [asc_nulls_first: b.last_seen_at]
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
  Lift suspension on every Barkpark a `team` owns, WHATEVER suspended it. Bulk
  `UPDATE`, idempotent via the `suspended == true` guard (a second call clears
  nothing). Clears the reason + timestamp. Returns `{:ok, count}`.

  NOT THE BILLING PATH ANY MORE (cch-w55-s4). This used to read "billing
  recovered" and was called by both billing recovery sites; being reason- and
  mode-blind, it lifted `"quota_exceeded"` flags a downgrade had set and revived
  `self_hosted` rows `suspend_team_barkparks/2` refuses to touch. Billing now
  calls `resume_billing_suspended/1`. Nothing in `lib/` calls this function
  today — it is kept as the deliberate BLANKET lift (an operator-scale "clear
  every suspension for this team"), and a new caller must mean that, not
  "recover a payer". If you want the billing axis, you want the other one.
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

  @doc """
  cch-w55-s4: lift ONLY the suspensions a paid invoice is entitled to lift — the
  billing axis, on `mode == "managed"` rows. The reason-and-mode-scoped twin of
  `suspend_team_barkparks/2`, and the one the billing recovery paths call.

  WHY IT IS NOT `resume_team_barkparks/1`. That function's entire `where` is
  `team_id and suspended == true`: no reason scope and no mode scope, while its
  suspend twin has both. So a paid invoice used to clear a `"quota_exceeded"`
  flag the billing axis never set — a team downgraded from `support_plus` to
  `supporter` ended with FIVE live boxes on a three-box plan, with nothing
  scheduled to re-suspend them — and it revived a `self_hosted` row that
  `suspend_team_barkparks/2` had refused to touch (count 0).

  WHY BOTH REASONS, not just `"billing_lapsed"`. `Billing.maybe_enforce/1`
  stamps `"billing_past_due"` when a grace window elapses. A resume scoped to
  `"billing_lapsed"` alone would strand those boxes FOREVER — trading an
  over-grant for a permanent under-restore (it reds
  `billing_lifecycle_test.exs`'s dunning-recovery arms). The billing axis owns
  exactly these two reasons, and this function lifts exactly them.

  One bulk `UPDATE`; idempotent (a second call clears nothing, count 0).
  Returns `{:ok, count}`.
  """
  @spec resume_billing_suspended(Team.t() | binary()) :: {:ok, non_neg_integer()}
  def resume_billing_suspended(team) do
    tid = team_id(team)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    {count, _} =
      Barkpark
      |> where(
        [b],
        b.team_id == ^tid and b.suspended == true and b.mode == "managed" and
          b.suspended_reason in ["billing_lapsed", "billing_past_due"]
      )
      |> Repo.update_all(
        set: [suspended: false, suspended_reason: nil, suspended_at: nil, updated_at: now]
      )

    {:ok, count}
  end

  ## Quota reconciler suspension — the reversible plan-ceiling enforcement.
  #
  # A SEPARATE axis from the bulk billing-lapse suspend above: these single-row
  # helpers stamp/clear the `"quota_exceeded"` reason (driven by
  # `Billing.reconcile_plan_limit/1`).
  #
  # HOW FAR THE INDEPENDENCE ACTUALLY GOES (cch-w55-s4 retraction). This comment
  # used to assert that "a downgrade suspend and a billing-lapse suspend never
  # restore each other." That holds in the SUSPEND direction only: each side
  # stamps its own reason and neither clears the other's. In the RESTORE
  # direction it was FALSE — `resume_team_barkparks/1` is reason-blind and did
  # clear `"quota_exceeded"` rows whenever a billing recovery ran. The billing
  # recovery paths now call `resume_billing_suspended/1` above, which IS
  # reason-scoped, so the independence holds both ways for those callers; a
  # direct `resume_team_barkparks/1` call remains blanket by design and is not
  # the billing axis. All three helpers below reuse main's `suspend_changeset`
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
  # TestCatalogCarriesTheShippedTemplates locks that side to this exact SET); an
  # unknown slug must be rejected HERE, at launch (a 4xx), never discovered on a
  # burned box mid-provision. One slug per line: new templates insert at the
  # head (scaffy add-site-template), and the Go lock compares as a set.
  @known_templates [
    # new content-template slugs land here (head of list)
    "astro-search-starter",
    "blog-starter",
    "place-directory",
    "search-starter",
    "website-starter"
  ]

  @doc """
  The valid content-template slugs a launch may carry (dwb-4), mirroring
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

  @doc """
  Enqueue a `pending` ATTACH-DOMAIN job for `barkpark` — the custom-domain
  attach path (instance custom domains). The Go worker drains it, upserts the
  platform DNS A record (platform-zone hosts) or re-verifies the customer's own
  DNS already points at the box (external FQDNs, attach-domain V2), wires the
  box (extra origin + Caddy vhost + restarts), and reports back; the
  `custom_host` itself was already persisted by
  `set_custom_host/2` before this enqueue, so the job's success just flips the
  job row.

  Guarded against a duplicate concurrent attach: if an ACTIVE (pending/claimed)
  attach-domain job already exists for this barkpark, returns `{:error,
  :already_attaching}` rather than enqueuing a second one (the partial unique
  index is the atomic race backstop, exactly as for deprovision).
  """
  @spec enqueue_attach_domain_job(Barkpark.t() | binary()) ::
          {:ok, ProvisionJob.t()} | {:error, :already_attaching | Ecto.Changeset.t()}
  def enqueue_attach_domain_job(barkpark) do
    bp_id = barkpark_id(barkpark)

    if active_job_of_kind?(bp_id, "attach_domain") do
      {:error, :already_attaching}
    else
      %ProvisionJob{}
      |> ProvisionJob.changeset(%{barkpark_id: bp_id, kind: "attach_domain", status: "pending"})
      |> Repo.insert()
      |> translate_active_job_conflict(:already_attaching)
    end
  end

  @doc """
  azh-w6 (S14c): enqueue a `pending` RESURRECT job for `barkpark` — the
  portable-archive restore path. `bundle_ref` names the object-storage archive
  the Go worker pulls + rehydrates onto the fresh box; it rides the job (not the
  barkpark row) and is threaded into the worker's resurrect claim payload.

  Same one-active-per-kind guard as provision/deprovision: an ACTIVE
  (pending/claimed) resurrect job already in flight for this barkpark returns
  `{:error, :already_resurrecting}` rather than enqueuing a second restore (the
  partial unique index is the atomic race backstop, as elsewhere).
  """
  @spec enqueue_resurrect_job(Barkpark.t() | binary(), String.t()) ::
          {:ok, ProvisionJob.t()} | {:error, :already_resurrecting | Ecto.Changeset.t()}
  def enqueue_resurrect_job(barkpark, bundle_ref) when is_binary(bundle_ref) do
    bp_id = barkpark_id(barkpark)

    if active_job_of_kind?(bp_id, "resurrect") do
      {:error, :already_resurrecting}
    else
      %ProvisionJob{}
      |> ProvisionJob.changeset(%{
        barkpark_id: bp_id,
        kind: "resurrect",
        status: "pending",
        bundle_ref: bundle_ref
      })
      |> Repo.insert()
      |> translate_active_job_conflict(:already_resurrecting)
    end
  end

  @doc """
  PDF-D83 (Personal Dev Fleet MVP-0): enqueue a `pending` PROVISION_SUPPORT job
  for `barkpark` — the CP-side inversion of add-support. The support row is
  written FIRST (host nil), then this enqueues the job the Go provisioner drains
  to stand up the box server-side (no local Hetzner token). The support's parent
  main and the parent's admin token travel in the CLAIM payload, not on this row.

  Same one-active-per-kind guard as provision/deprovision/resurrect: an ACTIVE
  (pending/claimed) `provision_support` job already in flight for this barkpark
  returns `{:error, :already_provisioning}` rather than enqueuing a second box
  (the partial unique index is the atomic race backstop, as elsewhere).
  """
  @spec enqueue_support_provision_job(Barkpark.t() | binary()) ::
          {:ok, ProvisionJob.t()} | {:error, :already_provisioning | Ecto.Changeset.t()}
  def enqueue_support_provision_job(barkpark) do
    bp_id = barkpark_id(barkpark)

    if active_job_of_kind?(bp_id, "provision_support") do
      {:error, :already_provisioning}
    else
      %ProvisionJob{}
      |> ProvisionJob.changeset(%{
        barkpark_id: bp_id,
        kind: "provision_support",
        status: "pending"
      })
      |> Repo.insert()
      |> translate_active_job_conflict(:already_provisioning)
    end
  end

  @doc """
  PDF-D94 (`pdf-bl-console-key-custody`): enqueue a `pending` PUSH_AGENT_KEY job
  for `barkpark` — the console paste-a-key path. The job row carries ONLY the
  routing fact (barkpark_id + kind); the key itself is stashed in-memory by the
  ROUTER (`AgentKeyStash.put/3`, keyed by the job id this returns) so nothing
  durable ever holds key material (D62 amended: NEVER KEEPS).

  Same one-active-per-kind guard as the other kinds: an ACTIVE (pending/claimed)
  `push_agent_key` job already in flight for this barkpark returns
  `{:error, :already_delivering}` — one key in transit per box at a time.
  """
  @spec enqueue_agent_key_push_job(Barkpark.t() | binary()) ::
          {:ok, ProvisionJob.t()} | {:error, :already_delivering | Ecto.Changeset.t()}
  def enqueue_agent_key_push_job(barkpark) do
    bp_id = barkpark_id(barkpark)

    if active_job_of_kind?(bp_id, "push_agent_key") do
      {:error, :already_delivering}
    else
      %ProvisionJob{}
      |> ProvisionJob.changeset(%{
        barkpark_id: bp_id,
        kind: "push_agent_key",
        status: "pending"
      })
      |> Repo.insert()
      |> translate_active_job_conflict(:already_delivering)
    end
  end

  @doc """
  isu-w5 (task-509f5fd02bc48f9c): enqueue a `pending` ENABLE_APPLY job for
  `barkpark` — the retro-arm rail that flips `BARKPARK_SELF_UPDATE_APPLY=1` on a
  live managed box (+ app restart) so its one-click/autoupdate executor works.
  New boxes provision with the flag; this repairs the pre-flag cohort instead of
  leaving them silently skipped by the rollout.

  Same one-active-per-kind guard as the other kinds: an ACTIVE (pending/claimed)
  `enable_apply` job already in flight for this barkpark returns
  `{:error, :already_arming}` — one arming in transit per box at a time, so the
  hourly unarmed re-measurement never piles up duplicate jobs.
  """
  @spec enqueue_enable_apply_job(Barkpark.t() | binary()) ::
          {:ok, ProvisionJob.t()} | {:error, :already_arming | Ecto.Changeset.t()}
  def enqueue_enable_apply_job(barkpark) do
    bp_id = barkpark_id(barkpark)

    if active_job_of_kind?(bp_id, "enable_apply") do
      {:error, :already_arming}
    else
      %ProvisionJob{}
      |> ProvisionJob.changeset(%{
        barkpark_id: bp_id,
        kind: "enable_apply",
        status: "pending"
      })
      |> Repo.insert()
      |> translate_active_job_conflict(:already_arming)
    end
  end

  @doc """
  THE AUTO-ENQUEUE (task-509f5fd02bc48f9c criterion 2): file an enable-apply job
  for a box that was just MEASURED unarmed — but only when the repair is
  actually consented and deliverable. The admin's autoupdate opt-in IS the
  consent (a managed box is cloud-operated by definition), so the gate is:

    * `autoupdate_enabled` — the team asked for unattended updates; arming is
      what makes that ask real. A box opted OUT is never touched.
    * not `suspended` — never SSH into a suspended customer's box.
    * a non-blank `host` — nowhere to deliver otherwise.

  Best-effort AND quiet on dedup: `{:error, :already_arming}` means the rail is
  already carrying this box (the hourly sweep re-reports unarmed until the job
  lands) and is returned as `:ok`-shaped `{:ok, :already_arming}` so callers on
  measurement paths never treat it as a failure. A box outside the gate returns
  `{:ok, :skipped}`.
  """
  @spec maybe_enqueue_enable_apply_job(Barkpark.t()) ::
          {:ok, ProvisionJob.t() | :already_arming | :skipped} | {:error, Ecto.Changeset.t()}
  def maybe_enqueue_enable_apply_job(%Barkpark{} = bp) do
    eligible? =
      bp.autoupdate_enabled == true and bp.suspended == false and
        is_binary(bp.host) and bp.host != ""

    if eligible? do
      case enqueue_enable_apply_job(bp) do
        {:ok, job} -> {:ok, job}
        {:error, :already_arming} -> {:ok, :already_arming}
        {:error, cs} -> {:error, cs}
      end
    else
      {:ok, :skipped}
    end
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

  @doc """
  True when `barkpark` has ANY job in flight (pending or claimed) whose
  completion would touch infrastructure only this row still names — the guard
  every "refuse to delete the row mid-flight" site wants (task-688ebffc4b0aa50a).

  A DENYLIST, NOT AN ALLOWLIST, and that is the entire point. This guard has now
  been wrong TWICE for the same reason: it named the kinds its author knew and
  silently failed to cover the rest. First `"provision"` alone missed
  `"provision_support"` — a support is never enqueued under `"provision"`
  (PDF-D83) — and both of its call sites accept support rows, since
  `DELETE /v1/barkparks/:id` matches on team alone with no `fleet_role` filter and
  `POST /v1/internal/barkparks/:id/deprovision` takes any row at all. Then
  `["provision", "provision_support"]` missed `"resurrect"`, which
  `ProvisionJob`'s own moduledoc describes as recreating a machine as a
  provision. Six kinds exist today; there will be a seventh, and an allowlist
  fails it silently the same way.

  So the set is inverted: everything blocks EXCEPT the kinds proven safe. A newly
  added kind is covered by default and has to be argued OUT, not remembered IN.
  This is the discipline `reap_stale_provision_jobs/0` already uses with its
  `j.kind != "provision_support"` catch-all arm.

  EXCLUDED, each because completing it strands nothing this row names:

    * `"deprovision"` — it IS the teardown. Blocking on it would refuse the very
      operation that cleans up, and `enqueue_deprovision_job/1`'s own dedup guard
      already prevents a second one.
    * `"push_agent_key"` — writes a key to a box that already exists and is
      already named. It creates no infrastructure, so it can strand none.

  Everything else blocks: `provision`, `provision_support`, `resurrect`, and
  `attach_domain`. `attach_domain` is in the set deliberately — its worker upserts
  an A record (`AttachDomainWith`), so a row deleted mid-flight strands DNS
  pointing at a box nothing can see. That narrows, but does not close, the race
  filed as task-c1014bb6c82298c2: a job already CLAIMED when the delete lands is
  past any check the control plane can make.

  NOTE ON REACH: every call site consults this only on the NOT-YET-LIVE arm (a
  live `host` routes to a deprovision job first), so the kind that actually bites
  today is `resurrect` — the one kind that can be in flight while `host` is still
  nil. The wider set is future-proofing, and is the reason a seventh kind will not
  need this doc rewritten.
  """
  @spec active_job_blocking_delete?(Barkpark.t() | binary()) :: boolean()
  def active_job_blocking_delete?(barkpark),
    do: active_job_except_kinds?(barkpark_id(barkpark), ["deprovision", "push_agent_key"])

  # Both predicates below differ only in how they constrain `kind`, so the whole
  # WHERE is composed as one dynamic and interpolated at the TOP LEVEL — Ecto
  # rejects a dynamic nested inside an `and`, which is what a first cut here did.
  defp active_job_of_kind?(barkpark_id, kind) do
    active_job?(dynamic([j], j.barkpark_id == ^barkpark_id and j.kind == ^kind))
  end

  defp active_job_except_kinds?(barkpark_id, kinds) do
    active_job?(dynamic([j], j.barkpark_id == ^barkpark_id and j.kind not in ^kinds))
  end

  defp active_job?(kind_scope) do
    from(j in ProvisionJob,
      where: ^kind_scope,
      where: j.status in ["pending", "claimed"],
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
      (`stale_after_seconds/1` — PER-KIND: `provision_support` uses the
      35-minute support budget, every other kind the generic worker provision
      timeout + margin).
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
    stale_before = DateTime.add(now, -stale_after_seconds(kind), :second)
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

  @doc """
  Atomically claim the next claimable ATTACH-DOMAIN job — the custom-domain
  attach path's worker pull. Same machinery as `claim_next_job/2`, filtered to
  `kind: "attach_domain"`.
  """
  @spec claim_next_attach_domain_job(String.t()) :: {ProvisionJob.t(), Barkpark.t()} | nil
  def claim_next_attach_domain_job(claim_token) when is_binary(claim_token),
    do: claim_next_job(claim_token, "attach_domain")

  @doc """
  azh-w6 (S14c): atomically claim the next claimable RESURRECT job — the
  portable-archive restore worker's pull. Same machinery as `claim_next_job/2`,
  filtered to `kind: "resurrect"` (so a resurrect job is never handed to a
  provision worker and vice-versa).
  """
  @spec claim_next_resurrect_job(String.t()) :: {ProvisionJob.t(), Barkpark.t()} | nil
  def claim_next_resurrect_job(claim_token) when is_binary(claim_token),
    do: claim_next_job(claim_token, "resurrect")

  @doc """
  PDF-D83: atomically claim the next claimable PROVISION_SUPPORT job — the fleet
  support provisioner's pull. Same machinery as `claim_next_job/2`, filtered to
  `kind: "provision_support"` (so a support job is never handed to a main-provision
  worker and vice-versa). The router folds the pinned support map — parent url +
  admin token, dataset, workspace, name — onto the claim payload.
  """
  @spec claim_next_support_provision_job(String.t()) :: {ProvisionJob.t(), Barkpark.t()} | nil
  def claim_next_support_provision_job(claim_token) when is_binary(claim_token),
    do: claim_next_job(claim_token, "provision_support")

  @doc """
  PDF-D94: atomically claim the next claimable PUSH_AGENT_KEY job — the agent-key
  delivery worker's pull. Same machinery as `claim_next_job/2`, filtered to
  `kind: "push_agent_key"`. The ROUTER pops the in-memory key for the claimed job
  id (`AgentKeyStash.take/1` — delete-on-read) and folds it onto the claim
  payload; a missing stash entry (CP restart, expiry, second hand-out) fails the
  job honestly at the route instead of delivering nothing.
  """
  @spec claim_next_agent_key_job(String.t()) :: {ProvisionJob.t(), Barkpark.t()} | nil
  def claim_next_agent_key_job(claim_token) when is_binary(claim_token),
    do: claim_next_job(claim_token, "push_agent_key")

  @doc """
  isu-w5: atomically claim the next claimable ENABLE_APPLY job — the retro-arm
  worker's pull. Same machinery as `claim_next_job/2`, filtered to
  `kind: "enable_apply"` so no other drain grabs it.
  """
  @spec claim_next_enable_apply_job(String.t()) :: {ProvisionJob.t(), Barkpark.t()} | nil
  def claim_next_enable_apply_job(claim_token) when is_binary(claim_token),
    do: claim_next_job(claim_token, "enable_apply")

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

  # claim-fence (bp-c55): read a provision job FOR UPDATE so the guard + write in
  # succeed_job / fail_job / release_job / succeed_deprovision_job run under a row
  # lock, exactly like do_transition_deployment_fenced. A swept-and-re-claimed
  # job's stale worker then serializes behind (and is fenced out by) the live one.
  defp lock_provision_job(id) do
    from(j in ProvisionJob, where: j.id == ^id, lock: "FOR UPDATE") |> Repo.one()
  end

  # claim-fence (bp-c55): when the worker supplied the claim_token it is holding,
  # a transition whose token no longer matches the row's is a stale ghost — the
  # job was swept and re-claimed by another worker, so this caller must be fenced
  # out. A nil/blank token (today's deployed Go fleet, which doesn't echo it yet)
  # skips the check: the status-only behavior is unchanged — the Stage 1 compat
  # window. Only after Stage 2 (the Go worker echoes the token) does the server
  # effectively require it.
  defp stale_claim?(%ProvisionJob{claim_token: row_token}, supplied)
       when is_binary(supplied) and supplied != "",
       do: row_token != supplied

  defp stale_claim?(_job, _supplied), do: false

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

  `opts` may also carry `:token_id` (task-5866ec745efcd7f7) — the OPAQUE id of
  the ledger token a provision_support worker minted on the parent main. It
  persists as `fleet_token_id` on the SUPPORT row (mirroring how the CLI
  register path sets it via `register_support_barkpark/2`) so `bp cloud support
  remove` can later revoke the token — the CP row is the sole durable token-id
  holder (PDF-D68). Persisted ONLY when the owning row is `fleet_role:
  "support"`; on any other row the value is ignored (a main never carries a
  token id). Absent → the column stays nil (older workers, back-compat).
  """
  @spec succeed_job(binary(), String.t(), keyword()) ::
          {:ok, ProvisionJob.t()}
          | {:error, :not_found | :conflict | :stale_claim | Ecto.Changeset.t()}
  def succeed_job(id, ip, opts \\ []) when is_binary(id) and is_binary(ip) and is_list(opts) do
    admin_token = Keyword.get(opts, :admin_token)
    bootstrap = Keyword.get(opts, :bootstrap)
    token_id = Keyword.get(opts, :token_id)
    claim_token = Keyword.get(opts, :claim_token)

    case uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      _uuid ->
        # claim-fence (bp-c55): the read + guard + write run in ONE transaction
        # with a FOR UPDATE row lock (mirrors do_transition_deployment_fenced) so
        # a swept-and-re-claimed job's stale worker can't flip the row under the
        # live claimant. The idempotent/terminal short-circuits run BEFORE the
        # token check — an already-succeeded job re-POSTed by its own (now-stale)
        # worker must still get its 200.
        result =
          Repo.transaction(fn ->
            case lock_provision_job(id) do
              nil ->
                Repo.rollback(:not_found)

              # IDEMPOTENT: an already-succeeded job. Return it unchanged — NO
              # re-upsert of the barkpark, no error. A dropped response + worker
              # re-POST lands here and gets a 200, so the worker keeps the box.
              %ProvisionJob{status: "succeeded"} = job ->
                job

              # STATUS GUARD: a job in a terminal NON-succeeded state ("failed").
              # Terminal is terminal — don't resurrect it, don't touch the barkpark.
              %ProvisionJob{status: "failed"} ->
                Repo.rollback(:conflict)

              %ProvisionJob{} = job ->
                if stale_claim?(job, claim_token) do
                  Repo.rollback(:stale_claim)
                else
                  # ONE transaction: the job-status flip AND the barkpark
                  # health/host upsert commit or roll back together. Before this,
                  # the flip ran first and the health upsert's result was DISCARDED
                  # — so a failing upsert (e.g. the global :url unique index, or a
                  # validation) left the job "succeeded" but the barkpark still
                  # provisioning/host=nil: a silent split-brain where the customer
                  # is billed for a box the dashboard never shows. Now either both
                  # land or neither does, and the upsert failure surfaces (logged +
                  # the whole call returns {:error, changeset}).
                  with {:ok, job} <-
                         job
                         |> ProvisionJob.changeset(%{status: "succeeded", result_ip: ip})
                         |> Repo.update(),
                       {:ok, _barkpark} <-
                         upsert_succeeded_barkpark(job, ip, admin_token, bootstrap, token_id) do
                    job
                  else
                    {:error, reason} -> Repo.rollback(reason)
                  end
                end
            end
          end)

        case result do
          {:ok, job} ->
            {:ok, job}

          {:error, reason} when reason in [:not_found, :conflict, :stale_claim] ->
            {:error, reason}

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
  # transaction: land the provisioned `ip` on the owning barkpark. The health
  # value is "unknown", NOT "up": a successful provision means the machine was
  # created, not that anything answered — no agent report has arrived and
  # `last_seen_at` is still NULL. The row goes green on the first
  # `POST /v1/agent/report` (`record_agent_report/2`). A missing barkpark row
  # (the FK is on_delete: :delete_all, so this is the deleted-mid-provision edge)
  # is treated as a no-op success — there is nothing to flip and the job flip
  # should still stand.
  defp upsert_succeeded_barkpark(
         %ProvisionJob{barkpark_id: barkpark_id},
         ip,
         admin_token,
         bootstrap,
         token_id
       ) do
    case Repo.get(Barkpark, barkpark_id) do
      nil ->
        {:ok, nil}

      %Barkpark{} = barkpark ->
        %{health_status: "unknown", host: ip, agent_status: "offline"}
        |> maybe_put_admin_token(admin_token)
        |> maybe_put_bootstrap(bootstrap)
        |> maybe_put_fleet_token_id(barkpark, token_id)
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

  # task-5866ec745efcd7f7: fold the provision_support worker's reported ledger
  # token id into the provision-success write — but ONLY onto a SUPPORT row
  # (mirroring register_support_barkpark/2's custody: a main never carries a
  # token id, and the value is an OPAQUE revocation handle, never a secret).
  # A missing/blank id, or a non-support row, leaves the attrs untouched so the
  # ip-only succeed path is unchanged (back-compat with pre-fix workers).
  defp maybe_put_fleet_token_id(attrs, %Barkpark{fleet_role: "support"}, token_id)
       when is_binary(token_id) and token_id != "" do
    Map.put(attrs, :fleet_token_id, token_id)
  end

  defp maybe_put_fleet_token_id(attrs, _barkpark, _token_id), do: attrs

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
  @spec fail_job(binary(), String.t(), keyword()) ::
          {:ok, ProvisionJob.t()}
          | {:error, :not_found | :conflict | :stale_claim | Ecto.Changeset.t()}
  def fail_job(id, error, opts \\ []) when is_binary(id) and is_list(opts) do
    claim_token = Keyword.get(opts, :claim_token)

    case uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      _uuid ->
        # claim-fence (bp-c55): FOR UPDATE read + guard + write in one transaction.
        # The idempotent/terminal short-circuits run BEFORE the token check.
        Repo.transaction(fn ->
          case lock_provision_job(id) do
            nil ->
              Repo.rollback(:not_found)

            # IDEMPOTENT: an already-failed job. Return it unchanged — no re-write,
            # so a retried/duplicate fail (lost response) self-heals to 200.
            %ProvisionJob{status: "failed"} = job ->
              job

            # STATUS GUARD: never un-succeed a live box. A straggler fail for a job
            # that already succeeded is a 409, and the barkpark is left up.
            %ProvisionJob{status: "succeeded"} ->
              Repo.rollback(:conflict)

            %ProvisionJob{} = job ->
              if stale_claim?(job, claim_token) do
                Repo.rollback(:stale_claim)
              else
                case job
                     |> ProvisionJob.changeset(%{status: "failed", error: error})
                     |> Repo.update() do
                  {:ok, updated} -> updated
                  {:error, cs} -> Repo.rollback(cs)
                end
              end
          end
        end)
    end
  end

  @doc """
  dwb-14: record one worker-reported step transition on a provision job's
  narration array. `step` ∈ create|secure|configure|content|verify|ready,
  `status` ∈ started|progress|done|failed; `detail` is an optional short string
  (a failure reason, a `verify` probe result like "verify.login: 401 in 182ms",
  or — for `progress` — the live human caption). The `at` timestamp is
  stamped HERE (server clock — the single source of truth for elapsed-time
  rendering), never trusted from the worker.

  Two shapes (dwb-19):

    * `started`/`done`/`failed` — APPEND a new entry (one entry per real
      transition). Append-only + CAPPED at `@max_step_entries` (oldest dropped)
      so a chatty/looping worker can't grow the row unbounded.
    * `progress` — the LIVE sub-caption. It does NOT append; it UPDATES the
      matching in-flight `started` entry's `detail` IN PLACE, so `steps` stays
      one entry per transition while the active step narrates the current
      sub-boundary. A `progress` for a step with no in-flight `started` entry
      (never started, or already done/failed → terminal) is a NO-OP `{:ok,
      job}` — refresh-safe telemetry, never a resurrection.

  Best-effort telemetry, NOT control flow: it records regardless of the job's
  current status (a late report after a job already succeeded/failed is still a
  truthful record). Returns `{:ok, job}`, `{:error, :not_found}` for an unknown
  id, or `{:error, :invalid_step}` for an unknown step/status pair. Never raises
  on a normal report.
  """
  @spec append_provision_step(binary(), term(), term(), term()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | :invalid_step}
  def append_provision_step(id, step, status, detail \\ nil) when is_binary(id) do
    with {:ok, {step, status}} <- ProvisionJob.validate_step(step, status),
         %ProvisionJob{} = job <- uuid_or_nil(id) && Repo.get(ProvisionJob, id) do
      steps = job.steps || []

      new_steps =
        cond do
          # C8 (D53): the `verify` gate narrates ONE probe per `progress` report
          # (verify.api → verify.login → verify.studio), and each is a DISCRETE
          # fact worth keeping — not a single caption overwriting the last. Persist
          # them as their own `progress` entries so `provision_steps` carries one
          # row per probe and C3's `.bp-tl-probes` checklist populates (the /new +
          # instance-detail renderer already folds `progress` entries into probe
          # rows — no app.js change). Every OTHER step keeps the dwb-19 in-place
          # caption semantics byte-identical (progress UPDATES the in-flight
          # `started` entry, never grows the array).
          status == "progress" and step == "verify" ->
            append_verify_probe(steps, norm_step_detail(detail))

          status == "progress" ->
            update_inflight_detail(steps, step, norm_step_detail(detail))

          true ->
            entry = %{
              "step" => step,
              "status" => status,
              "detail" => norm_step_detail(detail),
              "at" => DateTime.to_iso8601(DateTime.utc_now())
            }

            cap_steps(steps ++ [entry])
        end

      job
      |> ProvisionJob.changeset(%{steps: new_steps})
      |> Repo.update()
    else
      :error -> {:error, :invalid_step}
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # C8 (D53): a `verify` probe report persists as its OWN `progress` entry
  # (step "verify", status "progress", the probe caption as `detail`, server
  # stamp) so each probe is a durable row the timeline renderer turns into a
  # checklist item. A blank/nil probe caption is dropped (no empty rows). Capped
  # like every other append so a chatty gate can't grow the array unbounded.
  defp append_verify_probe(steps, nil), do: steps

  defp append_verify_probe(steps, detail) do
    entry = %{
      "step" => "verify",
      "status" => "progress",
      "detail" => detail,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    cap_steps(steps ++ [entry])
  end

  # dwb-19: a `progress` caption updates the LATEST in-flight `started` entry for
  # `step`, in place — never a new array entry. If that step's latest entry is
  # not `started` (already done/failed, or the step never started) the caption is
  # dropped (return the array unchanged) so a stray/late progress can't grow the
  # array or resurrect a finished step. Walks from the end so the most recent
  # `started` for the step wins.
  defp update_inflight_detail(steps, _step, nil), do: steps

  defp update_inflight_detail(steps, step, detail) do
    last =
      steps
      |> Enum.with_index()
      |> Enum.filter(fn {e, _i} -> Map.get(e, "step") == step end)
      |> List.last()

    case last do
      {%{"status" => "started"} = entry, i} ->
        List.replace_at(steps, i, Map.put(entry, "detail", detail))

      _ ->
        steps
    end
  end

  # A step detail is a non-empty binary or nil — blank/non-binary collapses to nil
  # so the narration array never carries "" or garbage.
  defp norm_step_detail(detail) when is_binary(detail) do
    if String.trim(detail) == "", do: nil, else: detail
  end

  defp norm_step_detail(_), do: nil

  @doc """
  dwb-16: APPEND one worker-reported LIVE console line to a provision job. Like
  `append_provision_step/4` this is best-effort telemetry — it records what the
  worker narrated regardless of the job's current status (a late line after a job
  succeeded/failed is still a truthful record), and NEVER raises on a normal
  report. The array is APPEND-ONLY and CAPPED at `@max_console_lines` (oldest
  dropped) so a chatty/looping worker can't grow the row unbounded. Each element
  is `%{"line" => line, "at" => iso8601}`.

  BOTH BOUNDS DISCLOSE THEMSELVES rather than discarding silently, because a
  console that hides what it dropped reads as a complete log when it is a tail:

    * an oversized line is TRUNCATED to `@max_console_line_chars` (never
      rejected) and its entry carries `"truncated_from" => <original length>`;
    * past the line cap, the oldest SURVIVING entry carries
      `"dropped_before" => <cumulative count>`.

  Returns `{:ok, job}` with the appended array, `{:error, :not_found}` for an
  unknown id, or `{:error, :invalid}` for a missing/blank line (the router 422s
  it rather than persisting garbage). Length is NOT a rejection reason: the
  builder latches its console channel off after three non-2xx replies, so 422ing
  a long line would silence the rest of the build's narration too.
  """
  @spec append_provision_console(binary(), term()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | :invalid}
  def append_provision_console(id, raw_line) when is_binary(id) do
    with {:ok, line} <- validate_console_line(raw_line),
         %ProvisionJob{} = job <- uuid_or_nil(id) && Repo.get(ProvisionJob, id) do
      entry =
        %{"line" => line, "at" => DateTime.to_iso8601(DateTime.utc_now())}
        |> Map.merge(console_line_meta(raw_line))

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
  # and hard-capped at @max_console_line_chars so one pathological line can't
  # bloat the row. Anything else (nil, a number, a map) is rejected → 422.
  #
  # ARITY IS LOAD-BEARING: `set_deployment_detail/2` is a THIRD consumer whose
  # `detail` is a bare string column with nowhere to carry a marker, so the
  # {:ok, binary} return shape stays exactly as it was. The chop DISCLOSURE
  # rides alongside, in `console_line_meta/1` below, and only the two callers
  # that write a console *entry map* merge it in.
  defp validate_console_line(line) when is_binary(line) do
    trimmed = String.trim_trailing(line)

    cond do
      trimmed == "" ->
        :error

      String.length(trimmed) > @max_console_line_chars ->
        {:ok, String.slice(trimmed, 0, @max_console_line_chars)}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_console_line(_), do: :error

  # The chop, disclosed. Returns the EXTRA console-entry keys that describe what
  # `validate_console_line/1` just discarded — `%{"truncated_from" => original}`
  # when the line was actually chopped, and an EMPTY map otherwise, so an
  # untouched line (including one of exactly @max_console_line_chars) carries no
  # marker at all. Both console columns are schemaless {:array, :map} jsonb and
  # both serializer folds (`scrub_entry/2`, `caption_entry/3`) Map.put back only
  # the keys they fetched, so an extra key reaches the browser with no migration
  # and no serializer change.
  defp console_line_meta(line) when is_binary(line) do
    length = line |> String.trim_trailing() |> String.length()

    if length > @max_console_line_chars, do: %{"truncated_from" => length}, else: %{}
  end

  defp console_line_meta(_), do: %{}

  # Keep only the last @max_console_lines entries (oldest dropped) — the append-only
  # cap that bounds the row size — and DISCLOSE the drop: the oldest SURVIVING
  # entry carries `"dropped_before" => <cumulative count>`, so a reader can tell a
  # complete narration from the tail of one. The count is cumulative because the
  # entry being dropped is itself the previous oldest survivor and carries the
  # running total; below the cap nothing is dropped and no key is written (an
  # absent key reads as 0).
  defp cap_console(entries) when is_list(entries) do
    case length(entries) - @max_console_lines do
      drop when drop > 0 ->
        entries
        |> Enum.drop(drop)
        |> disclose_drop(dropped_before(entries) + drop)

      _ ->
        entries
    end
  end

  defp disclose_drop([%{} = oldest | rest], count),
    do: [Map.put(oldest, "dropped_before", count) | rest]

  defp disclose_drop(entries, _count), do: entries

  # The cumulative drop count already recorded on the oldest entry (0 on a
  # console that has never been capped, and on a non-map/absent head).
  defp dropped_before([%{"dropped_before" => count} | _]) when is_integer(count), do: count
  defp dropped_before(_), do: 0

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
  @spec release_job(binary(), keyword()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | :conflict | :stale_claim}
  def release_job(id, opts \\ []) when is_binary(id) and is_list(opts) do
    claim_token = Keyword.get(opts, :claim_token)

    case uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      _uuid ->
        # claim-fence (bp-c55): FOR UPDATE read + guard + write in one transaction.
        # The idempotent "pending" short-circuit runs BEFORE the token check.
        Repo.transaction(fn ->
          case lock_provision_job(id) do
            nil ->
              Repo.rollback(:not_found)

            %ProvisionJob{status: "pending"} = job ->
              job

            %ProvisionJob{status: "claimed"} = job ->
              if stale_claim?(job, claim_token) do
                Repo.rollback(:stale_claim)
              else
                case job
                     |> ProvisionJob.changeset(%{
                       status: "pending",
                       claim_token: nil,
                       claimed_at: nil,
                       attempts: max(0, job.attempts - 1)
                     })
                     |> Repo.update() do
                  {:ok, updated} -> updated
                  {:error, cs} -> Repo.rollback(cs)
                end
              end

            %ProvisionJob{} ->
              Repo.rollback(:conflict)
          end
        end)
    end
  end

  @doc """
  oban-substrate: proactively recover provision jobs wedged in `claimed` past the
  staleness threshold, instead of waiting for the next `claim_next_job/1` to do it
  lazily. This is what `BarkparkCloud.Workers.StaleProvisionJobReaper` calls every
  minute so a crashed worker's job is recovered on a fixed cadence rather than
  only when the next claim happens to arrive.

  Outcomes are IDENTICAL to the lazy path (`claim_loop/5`), reusing the same
  `stale_after_seconds/1` per-kind threshold and `max_provision_attempts/0`
  budget so the two can never diverge — it sweeps EVERY kind, but each row is
  measured against ITS kind's threshold (`provision_support` gets the 35-minute
  support budget, task-314de6aa36248bea; everything else the generic threshold):

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
    # Per-kind staleness (task-314de6aa36248bea): a healthy provision_support
    # chain runs to the Go worker's 30-minute budget — measuring it against the
    # generic ~12-minute threshold re-pended it mid-flight (double-claim, two
    # billed boxes). Same thresholds as stale_after_seconds/1.
    stale_before = DateTime.add(now, -stale_after_seconds(), :second)
    support_stale_before = DateTime.add(now, -support_stale_after_seconds(), :second)
    max_attempts = max_provision_attempts()

    stale =
      from(j in ProvisionJob,
        where:
          j.status == "claimed" and
            ((j.kind == "provision_support" and j.claimed_at < ^support_stale_before) or
               (j.kind != "provision_support" and j.claimed_at < ^stale_before))
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
  @spec succeed_deprovision_job(binary(), keyword()) ::
          {:ok, :deleted | :already_gone}
          | {:error, :conflict | :stale_claim | Ecto.Changeset.t()}
  def succeed_deprovision_job(id, opts \\ []) when is_binary(id) and is_list(opts) do
    claim_token = Keyword.get(opts, :claim_token)

    case uuid_or_nil(id) do
      nil ->
        {:ok, :already_gone}

      _uuid ->
        # claim-fence (bp-c55): FOR UPDATE read + guard + delete in one transaction.
        # The terminal "failed" short-circuit runs BEFORE the token check.
        Repo.transaction(fn ->
          case lock_provision_job(id) do
            nil ->
              :already_gone

            %ProvisionJob{status: "failed"} ->
              Repo.rollback(:conflict)

            %ProvisionJob{barkpark_id: bp_id} = job ->
              if stale_claim?(job, claim_token) do
                Repo.rollback(:stale_claim)
              else
                case Repo.get(Barkpark, bp_id) do
                  nil ->
                    :already_gone

                  %Barkpark{} = bp ->
                    case Repo.delete(bp) do
                      {:ok, _} -> :deleted
                      {:error, cs} -> Repo.rollback(cs)
                    end
                end
              end
          end
        end)
    end
  end

  @doc """
  Mark attach-domain job `id` succeeded — the DNS record + box wiring for the
  custom host landed. The `custom_host` was already persisted on the barkpark by
  `set_custom_host/2` at enqueue time, so success just flips the JOB row
  (stamping `result_ip` when the worker echoed the box ip it configured — nil
  keeps it unset). Same idempotency + fencing contract as `succeed_job/3`:

    * `"succeeded"` (a RETRIED/duplicate succeed) — `{:ok, job}` unchanged (→ 200).
    * `"failed"` (terminal) — `{:error, :conflict}` (→ 409), never resurrected.
    * mismatched `claim_token` — `{:error, :stale_claim}` (claim-fence, bp-c55).
  """
  @spec succeed_attach_domain_job(binary(), String.t() | nil, keyword()) ::
          {:ok, ProvisionJob.t()}
          | {:error, :not_found | :conflict | :stale_claim | Ecto.Changeset.t()}
  def succeed_attach_domain_job(id, ip \\ nil, opts \\ []) when is_binary(id) and is_list(opts),
    do: succeed_job_row_only(id, ip, opts)

  @doc """
  PDF-D94: mark push-agent-key job `id` succeeded — the key line landed on the
  box and the listener restarted. Flips the JOB ROW ONLY (`result_ip` when the
  worker echoed the box ip): a key push must NEVER run `succeed_job/3`'s
  barkpark upsert, which would clobber a LIVE support row back to
  health "unknown" / agent "offline". Same idempotency + claim-fence contract
  as `succeed_attach_domain_job/3`.
  """
  @spec succeed_agent_key_job(binary(), String.t() | nil, keyword()) ::
          {:ok, ProvisionJob.t()}
          | {:error, :not_found | :conflict | :stale_claim | Ecto.Changeset.t()}
  def succeed_agent_key_job(id, ip \\ nil, opts \\ []) when is_binary(id) and is_list(opts),
    do: succeed_job_row_only(id, ip, opts)

  @doc """
  PDF-D94: mark push-agent-key job `id` failed with `error`. The support row is
  untouched (it stays live — only the key delivery failed; re-paste is the
  recovery). Delegates to `fail_job/3`, exactly like the attach-domain fail.
  """
  @spec fail_agent_key_job(binary(), String.t(), keyword()) ::
          {:ok, ProvisionJob.t()}
          | {:error, :not_found | :conflict | :stale_claim | Ecto.Changeset.t()}
  def fail_agent_key_job(id, error, opts \\ []), do: fail_job(id, error, opts)

  @doc """
  isu-w5: mark enable-apply job `id` succeeded — the env flag landed on the box
  and the app restarted. Flips the JOB ROW ONLY (`result_ip` when the worker
  echoed the box ip): an arming push must NEVER run `succeed_job/3`'s barkpark
  upsert, which would clobber a LIVE row's health/host. The `apply_arming`
  column is deliberately NOT written here — it is a MEASUREMENT, and the
  now-armed box answers `apply_enabled: true` on the next probe/sweep, which is
  what re-enters it into the candidate set. Same idempotency + claim-fence
  contract as `succeed_agent_key_job/3`.
  """
  @spec succeed_enable_apply_job(binary(), String.t() | nil, keyword()) ::
          {:ok, ProvisionJob.t()}
          | {:error, :not_found | :conflict | :stale_claim | Ecto.Changeset.t()}
  def succeed_enable_apply_job(id, ip \\ nil, opts \\ []) when is_binary(id) and is_list(opts),
    do: succeed_job_row_only(id, ip, opts)

  @doc """
  isu-w5: mark enable-apply job `id` failed with `error`. The barkpark row is
  untouched (the box stays live and stays MEASURED-unarmed, so the next unarmed
  measurement re-enqueues — the retry loop). Delegates to `fail_job/3`, exactly
  like the agent-key fail.
  """
  @spec fail_enable_apply_job(binary(), String.t(), keyword()) ::
          {:ok, ProvisionJob.t()}
          | {:error, :not_found | :conflict | :stale_claim | Ecto.Changeset.t()}
  def fail_enable_apply_job(id, error, opts \\ []), do: fail_job(id, error, opts)

  # The shared job-row-only succeed (attach_domain + push_agent_key): flip the
  # job to succeeded WITHOUT touching the owning barkpark. Idempotent + fenced
  # exactly like succeed_job/3.
  defp succeed_job_row_only(id, ip, opts) do
    claim_token = Keyword.get(opts, :claim_token)

    case uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      _uuid ->
        # claim-fence (bp-c55): FOR UPDATE read + guard + write in one transaction.
        # The idempotent/terminal short-circuits run BEFORE the token check.
        Repo.transaction(fn ->
          case lock_provision_job(id) do
            nil ->
              Repo.rollback(:not_found)

            # IDEMPOTENT: an already-succeeded job. A dropped response + worker
            # re-POST lands here and gets a 200.
            %ProvisionJob{status: "succeeded"} = job ->
              job

            # STATUS GUARD: terminal is terminal — a straggler succeed must not
            # resurrect a failed attach.
            %ProvisionJob{status: "failed"} ->
              Repo.rollback(:conflict)

            %ProvisionJob{} = job ->
              if stale_claim?(job, claim_token) do
                Repo.rollback(:stale_claim)
              else
                attrs =
                  if is_binary(ip) and ip != "",
                    do: %{status: "succeeded", result_ip: ip},
                    else: %{status: "succeeded"}

                case job |> ProvisionJob.changeset(attrs) |> Repo.update() do
                  {:ok, updated} -> updated
                  {:error, cs} -> Repo.rollback(cs)
                end
              end
          end
        end)
    end
  end

  @doc """
  Mark attach-domain job `id` failed with `error`. The barkpark keeps its
  persisted `custom_host` (re-attach is the recovery path — the ask-gate
  already approving the host is harmless). Delegates to `fail_job/3` — the
  status machinery is kind-agnostic, exactly as the deprovision fail route uses
  it.
  """
  @spec fail_attach_domain_job(binary(), String.t(), keyword()) ::
          {:ok, ProvisionJob.t()}
          | {:error, :not_found | :conflict | :stale_claim | Ecto.Changeset.t()}
  def fail_attach_domain_job(id, error, opts \\ []), do: fail_job(id, error, opts)

  @doc """
  PDF-D94: the latest `push_agent_key` job for `barkpark`, or nil — the console's
  delivery-status read (`GET /v1/barkparks/:id/agent-key`). Status/error only;
  the job row never holds key material by construction.
  """
  @spec latest_agent_key_job(Barkpark.t() | binary()) :: ProvisionJob.t() | nil
  def latest_agent_key_job(barkpark) do
    bp_id = barkpark_id(barkpark)

    from(j in ProvisionJob,
      where: j.barkpark_id == ^bp_id and j.kind == "push_agent_key",
      order_by: [desc: j.inserted_at, desc: j.id],
      limit: 1
    )
    |> Repo.one()
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
      # PDF-D85: a CP-provisioned SUPPORT box reports its create→live steps on a
      # `provision_support` job, never a `provision` one — widen the filter so its
      # steps/console/status surface on GET /v1/barkparks (a main carries only
      # `provision`, a support only `provision_support`, so DISTINCT ON never
      # cross-contaminates the two).
      where: j.barkpark_id in ^ids and j.kind in ["provision", "provision_support"],
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
  The RAW payload of the latest `"health"` agent event per barkpark id, as
  `%{barkpark_id => %{payload: map(), reported_at: DateTime.t()}}` — the fleet
  list's host-pressure prefetch (dr-w4-s4).

  ONE query, modelled structurally on `latest_provision_status_map/1`: Postgres
  `DISTINCT ON (barkpark_id) ... ORDER BY barkpark_id, inserted_at DESC, id DESC`
  over `agent_events`, backed by the existing `(barkpark_id, inserted_at)` index
  (migration 20260626193200 — no migration needed). Mapping
  `recent_events/2` over the rows instead would be an N+1 — the same N+1 already
  found and fixed once in this domain (`Usage.latest_samples_by_barkpark/1`).

  RAW, NOT NORMALIZED, on purpose: `Telemetry.normalize/1` folds the beat into a
  fixed literal envelope that drops swap/beam, so the fleet row would inherit
  that fold's blind spots. The caller reads the agent-shaped jsonb keys itself
  and renders anything absent as UNMETERED — never a fabricated 0.

  Boxes with no health event are simply ABSENT from the map (nil-honest at the
  caller). Empty `ids` → empty map (no query).
  """
  @spec latest_health_payload_map([binary()]) :: %{
          binary() => %{payload: map(), reported_at: DateTime.t()}
        }
  def latest_health_payload_map([]), do: %{}

  def latest_health_payload_map(ids) when is_list(ids) do
    from(e in AgentEvent,
      where: e.barkpark_id in ^ids and e.type == "health",
      order_by: [asc: e.barkpark_id, desc: e.inserted_at, desc: e.id],
      distinct: e.barkpark_id,
      select: {e.barkpark_id, e.payload, e.inserted_at}
    )
    |> Repo.all()
    |> Map.new(fn {bp_id, payload, at} ->
      {bp_id, %{payload: (is_map(payload) && payload) || %{}, reported_at: at}}
    end)
  end

  @doc """
  The latest deployment per site id in `ids`, as a SLIM freshness map
  `%{site_id => %{status:, trigger:, inserted_at:, updated_at:}}`. One query via
  Postgres `DISTINCT ON (site_id) ... ORDER BY site_id, inserted_at DESC` (the
  `[:site_id, :inserted_at]` index already backs it — no migration) so the
  dashboard fleet list can render an at-a-glance freshness badge — amber while a
  content-auto rebuild is in flight, settled status/trigger/time otherwise —
  WITHOUT an N+1 per row.

  Mirrors `latest_provision_status_map/1` in shape and intent. HONESTY LAW
  (charter D24): only `status`, `trigger`, and the two timestamps ride along —
  NEVER `console`, `build_log_url`, `content_rev`, or any build internal. Sites
  with no deployment are simply absent (nil-honest at the caller). Empty `ids` →
  empty map (no query).

  PRODUCTION ONLY (cch-w14-s6). Branch previews are excluded — the badge names
  the site's PRODUCTION state, which is the only thing the fleet row claims.
  Without the predicate a torn-down preview outranked a live production deploy,
  so `GET /v1/sites` said "cancelled" at the same instant
  `GET /v1/sites/:id/deployments` (already `environment: "production"`) said
  "live". The embed deliberately carries NO environment key — widening it would
  break the HONESTY-LAW keyset above. One visible consequence: a site whose
  ONLY deployments are previews is absent from the map, so the console paints
  its neutral never-deployed pill.
  """
  @spec latest_deployment_status_map([binary()]) :: %{
          binary() => %{
            status: String.t(),
            trigger: String.t() | nil,
            inserted_at: DateTime.t(),
            updated_at: DateTime.t()
          }
        }
  def latest_deployment_status_map([]), do: %{}

  def latest_deployment_status_map(ids) when is_list(ids) do
    from(d in Deployment,
      where: d.site_id in ^ids,
      where: d.environment == "production",
      order_by: [asc: d.site_id, desc: d.inserted_at, desc: d.id],
      distinct: d.site_id,
      select: {d.site_id, d.status, d.trigger, d.inserted_at, d.updated_at}
    )
    |> Repo.all()
    |> Map.new(fn {site_id, status, trigger, inserted_at, updated_at} ->
      {site_id,
       %{status: status, trigger: trigger, inserted_at: inserted_at, updated_at: updated_at}}
    end)
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
  The per-KIND staleness threshold (task-314de6aa36248bea): `provision_support`
  claims get the longer support budget (`support_stale_after_seconds/0`); every
  other kind keeps `stale_after_seconds/0` exactly. Used by both staleness paths
  (`claim_next_job/2` and `reap_stale_provision_jobs/0`) so they can never
  diverge per kind.
  """
  @spec stale_after_seconds(String.t()) :: pos_integer()
  def stale_after_seconds("provision_support"), do: support_stale_after_seconds()
  def stale_after_seconds(_kind), do: stale_after_seconds()

  @doc """
  Seconds a claimed `provision_support` job may sit before it is treated as
  abandoned. Sized as the Go worker's DefaultSupportProvisionTimeout (30m —
  roster-verify budget alone is 10m) + 5m margin for teardown + the report
  round-trip (#{@default_support_stale_after_seconds}s), so a healthy support
  chain is never re-pended mid-flight and double-claimed. Overridable via
  `config :barkpark_cloud, :support_provision_stale_after_seconds`.
  """
  @spec support_stale_after_seconds() :: pos_integer()
  def support_stale_after_seconds do
    Application.get_env(
      :barkpark_cloud,
      :support_provision_stale_after_seconds,
      @default_support_stale_after_seconds
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
  Seconds a `queued` container-site deployment may sit UNCLAIMED before clients
  treat it as stalled (jpf-w1-queue-age-alarm, charter D6). Deliberately ONE
  THIRD of `deployment_stale_after_seconds` (#{@default_queued_deploy_alarm_after_seconds}s
  vs #{@default_deployment_stale_after_seconds}s): the reaper above is a MUTATING
  builder-lease mechanism whose passes are all `claimed_at`-gated — a
  never-claimed queued row has `claimed_at` nil and is invisible to it by
  design — while this threshold judges exactly that orphan class, read-only.
  The control plane only SERVES the raw age (`queued_deploy_age_seconds` on
  `barkpark_json`); the Go CLI and the SPA own the comparison, so this knob is
  the documented home of the 5min/15min relationship rather than a server-side
  gate. Overridable via `config :barkpark_cloud, :queued_deploy_alarm_after_seconds`.
  """
  @spec queued_deploy_alarm_after_seconds() :: pos_integer()
  def queued_deploy_alarm_after_seconds do
    Application.get_env(
      :barkpark_cloud,
      :queued_deploy_alarm_after_seconds,
      @default_queued_deploy_alarm_after_seconds
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

  @doc """
  How many `deployment_failed` alerts one reaper sweep may send. See
  `@reap_alert_cap` for why a cap exists at all. Public so the suppression
  branch can be DRIVEN by a test rather than asserted in a comment — a cap that
  no fixture crosses is a person-facing suppression nothing measures.
  """
  @spec reap_alert_cap() :: pos_integer()
  def reap_alert_cap, do: @reap_alert_cap

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
        # Self-clean: recover stale rows (crashed-mid-consume) so they don't
        # accumulate. Bookkeeping only — never touches a Hetzner box.
        reap_stale_warm_claims_txn(now)

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
  Atomically claim the STALEST ready warm box for a background REFRESH
  (ready → refreshing) — the self-refresh loop's lever for keeping idle pool
  boxes at origin/main so a claim almost never rebuilds (snapshot-management).

  Only picks a box whose `refreshed_at` is null (never refreshed) or older than
  `min_age_seconds` (so a just-refreshed box isn't re-picked — bounds SSH churn);
  among eligible boxes the stalest (nulls first, then oldest refreshed_at) wins.
  A refreshing box is OUT of the assignable set (assign claims `ready` only), so
  a go-live never grabs a box mid-rebuild. Returns `%WarmServer{}` or `nil` when
  no ready box is due a refresh. Race-safe via FOR UPDATE SKIP LOCKED.
  """
  @spec claim_warm_server_for_refresh(String.t(), non_neg_integer()) :: WarmServer.t() | nil
  def claim_warm_server_for_refresh(claim_token, min_age_seconds)
      when is_binary(claim_token) and is_integer(min_age_seconds) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    due_before = DateTime.add(now, -min_age_seconds, :second)

    result =
      Repo.transaction(fn ->
        reap_stale_warm_claims_txn(now)

        locked =
          from(w in WarmServer,
            where:
              w.status == "ready" and
                (is_nil(w.refreshed_at) or w.refreshed_at < ^due_before),
            # nulls first (Postgres sorts NULL last on ASC → force it first), then
            # oldest refreshed_at: the stalest box refreshes first.
            order_by: [asc_nulls_first: w.refreshed_at, asc: w.inserted_at, asc: w.id],
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
                status: "refreshing",
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
  Release a refreshing box BACK to `ready` after the self-refresh loop finished
  with it (refreshing → ready). claim-fenced on `claim_token` so a stale release
  (the box was reaped back to ready and re-claimed) is a `{:ok, 0}` no-op.

  `refreshed?` records the OUTCOME: on a successful refresh (`true`) the box's
  `refreshed_at` is stamped now, so it drops to the back of the refresh queue; on
  a failed/skipped refresh (`false`) `refreshed_at` is LEFT unchanged, so the box
  is retried on the next pass rather than waiting out the full min-interval. Both
  cases return the box to the assignable pool immediately — a refresh failure
  never removes a box (it still serves working, if slightly-behind, code).
  Returns `{:ok, count}` (rows updated).
  """
  @spec release_warm_server_after_refresh(String.t(), String.t(), boolean()) ::
          {:ok, non_neg_integer()}
  def release_warm_server_after_refresh(name, claim_token, refreshed?)
      when is_binary(name) and is_binary(claim_token) and is_boolean(refreshed?) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    sets =
      [status: "ready", claim_token: nil, claimed_at: nil] ++
        if refreshed?, do: [refreshed_at: now], else: []

    {count, _} =
      from(w in WarmServer,
        where: w.name == ^name and w.status == "refreshing" and w.claim_token == ^claim_token,
        update: [set: ^sets]
      )
      |> Repo.update_all([])

    {:ok, count}
  end

  @doc """
  Delete the warm row for `name` — called once a claimed box is consumed (assigned
  live, or torn down on a failed assign) or a retiring box is deleted. IDEMPOTENT:
  a missing row is a no-op. Returns `{:ok, rows_deleted}`.
  """
  @spec delete_warm_server(String.t(), String.t() | nil) :: {:ok, non_neg_integer()}
  def delete_warm_server(name, claim_token \\ nil) when is_binary(name) do
    # claim-fence (bp-c55): when the worker supplies the claim_token it is holding,
    # only delete the row when it still matches — a swept-and-re-registered/re-
    # claimed box under the same name is left standing for its live claimant (the
    # stale delete is a {:ok, 0} no-op). A nil/blank token keeps today's delete-by-
    # name (the Stage 1 compat window for the deployed Go fleet).
    query =
      if is_binary(claim_token) and claim_token != "" do
        from(w in WarmServer, where: w.name == ^name and w.claim_token == ^claim_token)
      else
        from(w in WarmServer, where: w.name == ^name)
      end

    {count, _} = Repo.delete_all(query)
    {:ok, count}
  end

  @doc """
  How many warm boxes are in the POOL — the reconciler's grow/shrink input. This
  counts `ready` PLUS `refreshing`: a refreshing box is transiently out of the
  assignable set but is still a pool member (it returns to ready), so counting it
  keeps the self-refresh loop from tricking the reconciler into growing a spurious
  replacement. `claimed`/`retiring` are LEAVING the pool (becoming an instance /
  being deleted), so they are excluded.
  """
  @spec count_ready_warm_servers() :: non_neg_integer()
  def count_ready_warm_servers do
    Repo.aggregate(from(w in WarmServer, where: w.status in ["ready", "refreshing"]), :count)
  end

  @doc """
  Recover warm rows stuck past the stale threshold (a worker crashed between
  claiming and consuming/releasing the row). `claimed`/`retiring` are DELETED
  (bookkeeping — the Go worker owns the box's lifecycle), while a stale
  `refreshing` box is put BACK to `ready` (it still serves working code, so it
  rejoins the pool rather than being lost). Returns the total count recovered.
  """
  @spec reap_stale_warm_claims() :: non_neg_integer()
  def reap_stale_warm_claims do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    Repo.transaction(fn -> reap_stale_warm_claims_txn(now) end)
    |> case do
      {:ok, count} -> count
      _ -> 0
    end
  end

  # The recovery, runnable INSIDE an enclosing claim transaction (so a claim
  # self-cleans atomically) or standalone. Returns the total rows recovered.
  defp reap_stale_warm_claims_txn(now) do
    stale_before = DateTime.add(now, -warm_stale_after_seconds(), :second)

    {deleted, _} =
      from(w in WarmServer,
        where: w.status in ["claimed", "retiring"] and w.claimed_at < ^stale_before
      )
      |> Repo.delete_all()

    # A crashed refresh: the box still serves working code — return it to the
    # assignable pool instead of deleting it. claim_token/claimed_at cleared;
    # refreshed_at left as-is so it is retried soon.
    {readied, _} =
      from(w in WarmServer,
        where: w.status == "refreshing" and w.claimed_at < ^stale_before,
        update: [set: [status: "ready", claim_token: nil, claimed_at: nil]]
      )
      |> Repo.update_all([])

    deleted + readied
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
  Append an event of `type` (`AgentEvent`'s allowlist: the agent-posted
  `health`/`status`/`backup`/`tls`/`content` plus the control-plane-authored
  `verify`) with `payload` (a map) to `barkpark`'s stream.
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

  @doc """
  Cache the on-demand VERIFY verdict onto the fleet row (BP-ONB-09 backend) — the
  headline `reachable` of the run plus the moment it ran, so the fleet list
  carries a queryable "last verified" fact without walking the `verify`
  agent_event stream. Best-effort by contract: the caller (`run_verify/3`) runs
  this beside `record_event/3` in the `{:ok, result}` arm, so a failed persist
  logs and NEVER fails the proof the operator just asked for. `verified_at` is
  the envelope's ISO-8601 stamp when parseable, else `now`.
  """
  @spec record_verify_result(Barkpark.t(), map()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def record_verify_result(%Barkpark{} = bp, %{reachable: reachable} = result) do
    verified_at =
      case result do
        %{verified_at: iso} when is_binary(iso) ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _offset} -> dt
            _ -> DateTime.utc_now()
          end

        _ ->
          DateTime.utc_now()
      end

    bp
    |> Barkpark.verify_changeset(%{
      last_verified_at: verified_at,
      verify_reachable: reachable
    })
    |> Repo.update()
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
  Most-recent `limit` events of ONE `type` for `barkpark`, newest first.

  The type-blind sibling above is the timeline read ("show me what happened");
  this one is the SERIES read ("give me N health beats"). They are different
  questions and the difference is the LIMIT: `recent_events/2` applies `limit`
  to the mixed stream, so once a box writes more than one type — `space` lands
  one row per 15 minutes beside the 60s health beat — asking for 200 rows to
  chart returns ~188 health beats and a chart silently loses its tail (D58 is
  enforced at WRITE and at FOLD; this is the FETCH). Filtering IN the query is
  what makes `limit` mean what the caller asked for.

  No migration: the existing `(barkpark_id, inserted_at)` index still backs the
  scan; `type` is an extra predicate on the same ordered rows.
  """
  @spec recent_events_of_type(Barkpark.t() | binary(), String.t(), pos_integer()) :: [
          AgentEvent.t()
        ]
  def recent_events_of_type(barkpark, type, limit \\ 50) when is_binary(type) do
    bp_id = barkpark_id(barkpark)

    AgentEvent
    |> where([e], e.barkpark_id == ^bp_id and e.type == ^type)
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
  Connect a cloud `Provider` of `kind` (`hetzner`/`azure`) for `team`, storing
  the account `credential` ENCRYPTED at rest (`Vault.encrypt/1`). The plaintext
  credential is never persisted — for `hetzner` it is the API token string, for
  `azure` the `{tenant_id, client_id, client_secret, subscription_id}` JSON
  blob. Its per-kind shape is validated by the changeset before insert. `opts`
  may carry `:label`.

  A team has AT MOST ONE provider per kind, so this is an UPSERT, not an append
  (charter GR44): reconnecting `hetzner` ROTATES the credential (and the label)
  on the existing row instead of stacking a second one behind it. The
  `unique_index(:providers, [:team_id, :kind])` from
  `20260719203000_unique_provider_per_team_kind` is the enforcement;
  `on_conflict` is how this write cooperates with it. Before both, every read
  papered over the duplicates with newest-wins ordering — correct output over a
  quietly growing table.

  `returning: true` is load-bearing: on the conflict branch the in-memory
  changeset carries the NEW credential but the row's ORIGINAL `id` /
  `inserted_at` are what Postgres kept, so without it callers would hold a
  half-invented struct.

  Returns `{:ok, %Provider{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec connect_provider(Team.t() | binary(), String.t(), binary(), keyword()) ::
          {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def connect_provider(team, kind, credential, opts \\ []) when is_binary(credential) do
    label = Keyword.get(opts, :label)

    # A reconnect that NAMES a label renames the row; a reconnect that names
    # none rotates the credential and LEAVES the existing label alone. The
    # difference is not academic: `POST /v1/providers` reads `label` straight
    # off the body and the SPA omits the key entirely when the field is blank
    # (`providerCredBody`), so an unconditional `:replace` of `:label` would
    # silently wipe a previously-named credential on every re-submit of a form
    # whose label box starts empty. Nothing in the product offers "clear the
    # label", so keeping it is the only reading that matches intent.
    replace =
      if is_nil(label),
        do: [:encrypted_token, :updated_at],
        else: [:label, :encrypted_token, :updated_at]

    %Provider{}
    |> Provider.changeset(%{
      team_id: team_id(team),
      kind: kind,
      label: label,
      # The virtual :credential drives the per-kind shape gate; :encrypted_token
      # is the single stored home (ciphertext of the same plaintext).
      credential: credential,
      encrypted_token: Vault.encrypt(credential)
    })
    |> Repo.insert(
      on_conflict: {:replace, replace},
      conflict_target: [:team_id, :kind],
      returning: true
    )
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
  Disconnect a team's connected provider(s) of `kind` — drops the row(s), and the
  encrypted credential goes with them (the plugin law: disconnecting a provider
  degrades gracefully back to standalone). Returns `:ok` when at least one row was
  removed, `{:error, :not_found}` when the team had none of that kind (no
  existence leak on the caller side). Team-scoped — never crosses teams.
  """
  @spec disconnect_provider(Team.t() | binary(), String.t()) :: :ok | {:error, :not_found}
  def disconnect_provider(team, kind) when is_binary(kind) do
    tid = team_id(team)

    {count, _} =
      Provider
      |> where([p], p.team_id == ^tid and p.kind == ^kind)
      |> Repo.delete_all()

    if count > 0, do: :ok, else: {:error, :not_found}
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
  Mint (or rotate) the per-barkpark push-relay shared secret — the key the
  INSTANCE will sign chat_blocked webhook deliveries with and Cloud's
  `/v1/relay/chat-blocked/:barkpark_id` receiver verifies against (push-relay
  spike, mobile charter D15b). Stored Vault-encrypted on the barkpark row,
  EXACTLY the admin-token custody (`admin_token_encrypted`'s sibling).

  Returns `{:ok, plaintext, barkpark}` — the plaintext exists to travel ONCE,
  server-to-instance, when wave 2 registers the chat_blocked webhook row on the
  box (the create_site content-publish idiom). It is never logged or audited by
  value. Rotation overwrites: the previous secret stops verifying immediately
  (an overlap window is a wave-2 concern; the verifier already accepts a secret
  LIST when that lands).
  """
  @spec mint_push_relay_secret(Barkpark.t()) ::
          {:ok, String.t(), Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def mint_push_relay_secret(%Barkpark{} = bp) do
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    bp
    |> Ecto.Changeset.change(push_relay_secret_encrypted: Vault.encrypt(secret))
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, secret, updated}
      {:error, _} = err -> err
    end
  end

  @doc """
  Decrypt a Barkpark's stored push-relay secret back to plaintext
  (`reveal_admin_token/1`'s sibling — push-relay spike, charter D15b). Returns
  `{:ok, secret}`, `{:ok, nil}` when no relay was ever configured for this
  instance (the receiver's silent-404 severability case), or `:error` on
  tampered ciphertext (fail-closed).
  """
  @spec reveal_push_relay_secret(Barkpark.t()) :: {:ok, binary() | nil} | :error
  def reveal_push_relay_secret(%Barkpark{push_relay_secret_encrypted: nil}), do: {:ok, nil}

  def reveal_push_relay_secret(%Barkpark{push_relay_secret_encrypted: ciphertext}),
    do: Vault.decrypt(ciphertext)

  # The public URL the INSTANCE posts a chat_blocked delivery to — the exact
  # sibling of `content_receiver_url/1`, per-barkpark instead of per-site
  # (mobile charter D15b: the ROUTE names the instance, the payload cannot).
  defp push_relay_receiver_url(%Barkpark{id: id}) do
    base =
      Application.get_env(:barkpark_cloud, :public_url, "https://api.barkpark.cloud")
      |> to_string()
      |> String.trim_trailing("/")

    base <> "/v1/relay/chat-blocked/#{id}"
  end

  @doc """
  Provision (or re-converge) the INSTANCE-side `chat_blocked` webhook row that
  drives Cloud's `/v1/relay/chat-blocked/:barkpark_id` receiver — the wave-2
  relay build's missing half. Until this runs, the receiver is a door nobody
  knocks on: Cloud holds a secret, the box has no row, and no notification can
  ever originate.

  Uses the stored admin token SERVER-SIDE (`relay_admin/4`, the
  `mint_public_read_token/5` prior art) against the box's **workspace-SCOPED**
  webhook route:

      POST /w/<workspace>/p/<project>/v1/webhooks/<dataset>
      {name, url: <cloud>/v1/relay/chat-blocked/<id>, secret, blocked_threshold_s}

  ## The scoped route is LOAD-BEARING, not stylistic

  A chat_blocked subscription is matched by `Webhooks.chat_blocked_webhooks_for/1`,
  which requires `w.workspace_id == ^workspace_id`. `Webhooks.create_webhook/2`
  stamps `workspace_id` from the SERVER-RESOLVED request scope and drops any
  client-supplied one. The FLAT `/v1/webhooks/:dataset` route carries no
  workspace in its path, so a row created there gets `workspace_id: nil` and can
  never match — the webhook would exist, look correct in Studio, and silently
  never fire. Hence the `/w/:ws/p/:proj` prefix.

  ## `blocked_threshold_s` IS the subscription

  A non-NULL `blocked_threshold_s` is simultaneously the "this is a chat_blocked
  hook" flag and the per-workspace debounce threshold (instance charter D59h).
  Omitting it produces an ordinary CONTENT webhook that fires on document
  publishes — the wrong events at the right URL.

  ## Convergence

  Idempotent by URL. If a row already points at this barkpark's receiver, it is
  RE-ENABLED (clearing any auto-disable stamped by consecutive delivery
  failures) and its secret is ROTATED box-side; the box returns the new
  plaintext and we adopt it, so Cloud and instance converge on a shared secret
  from ANY prior state — including "Cloud lost its copy". Otherwise a fresh
  secret is minted here and a new row is created.

  KNOWN LIMIT, stated rather than hidden: re-provisioning does NOT change an
  existing row's `blocked_threshold_s` (the update would need a PUT through the
  admin relay, which today accepts only :get/:post — widening a
  privilege-bearing helper is not worth one field). To change the threshold,
  delete the row in Studio and re-provision.

  Returns `{:ok, %{status: "created" | "converged", webhook_id: id, url: url,
  workspace: ws, project: proj, dataset: ds}}`, or `{:error, reason}` where
  reason is `:not_live` / `:no_admin_token` / `:decrypt_failed` /
  `:instance_error` (the relay's own vocabulary), `{:instance, status, body}`
  for a refusal the box explained, or an `Ecto.Changeset` if the secret could
  not be stored. The plaintext secret is never returned, logged or audited.

  Options: `:workspace`, `:project`, `:dataset` (default to the barkpark's
  `bootstrap_*`, then `"default"`/`"default"`/`"production"`) and
  `:blocked_threshold_s` (default 300 — five minutes of a human not answering).
  """
  @spec provision_push_relay_webhook(Barkpark.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def provision_push_relay_webhook(bp, opts \\ [])

  # cch-w58-bl — same refusal as `wire_site_url/2` above, same reason: this
  # creates/converges the box's `chat_blocked` webhook row over the admin relay,
  # a credentialed WRITE. The bodiless head above carries the `\\ []` default now
  # that the function has more than one clause. The route's result mapping ends
  # in a `{:error, _other} -> 500 provision_failed` catch-all, so it also grew an
  # explicit 409 clause for `:suspended` — otherwise a deliberate refusal would
  # surface to the operator as an internal error.
  def provision_push_relay_webhook(%Barkpark{suspended: true}, _opts), do: {:error, :suspended}

  def provision_push_relay_webhook(%Barkpark{} = bp, opts) do
    workspace = Keyword.get(opts, :workspace) || bp.bootstrap_workspace || "default"
    project = Keyword.get(opts, :project) || bp.bootstrap_project || "default"
    dataset = Keyword.get(opts, :dataset) || bp.bootstrap_dataset || "production"
    threshold = Keyword.get(opts, :blocked_threshold_s, 300)
    receiver_url = push_relay_receiver_url(bp)

    scoped =
      "/w/#{URI.encode(workspace)}/p/#{URI.encode(project)}/v1/webhooks/#{URI.encode(dataset)}"

    case find_push_relay_webhook(bp, scoped, receiver_url) do
      {:ok, nil} ->
        create_push_relay_webhook(bp, scoped, receiver_url, threshold, %{
          workspace: workspace,
          project: project,
          dataset: dataset
        })

      {:ok, existing_id} ->
        converge_push_relay_webhook(bp, scoped, existing_id, receiver_url, %{
          workspace: workspace,
          project: project,
          dataset: dataset
        })

      {:error, _} = error ->
        error
    end
  end

  # GET the scoped webhook list and return the id of the row already pointed at
  # THIS barkpark's relay receiver, if any. URL equality is the identity: the
  # receiver path embeds the barkpark id, so it cannot collide with another
  # instance's row or with a content webhook.
  defp find_push_relay_webhook(bp, scoped, receiver_url) do
    case relay_admin(bp, :get, scoped, nil) do
      {:ok, status, %{"webhooks" => hooks}} when status in 200..299 and is_list(hooks) ->
        match = Enum.find(hooks, fn hook -> is_map(hook) and hook["url"] == receiver_url end)
        {:ok, match && match["id"]}

      {:ok, status, body} ->
        {:error, {:instance, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_push_relay_webhook(bp, scoped, receiver_url, threshold, scope) do
    with {:ok, secret, bp} <- mint_push_relay_secret(bp) do
      body = %{
        name: "push-relay-#{bp.id}",
        url: receiver_url,
        secret: secret,
        blocked_threshold_s: threshold,
        # Explicitly EMPTY: content lifecycle events are the other channel.
        # `blocked_threshold_s` above is what makes this a chat_blocked row.
        events: []
      }

      case relay_admin(bp, :post, scoped, body) do
        {:ok, status, %{"webhook" => %{"id" => id}}} when status in 200..299 ->
          {:ok, Map.merge(scope, %{status: "created", webhook_id: id, url: receiver_url})}

        {:ok, status, decoded} ->
          {:error, {:instance, status, decoded}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # An existing row: clear any auto-disable, then rotate box-side and ADOPT the
  # secret the box generated. Adoption (rather than pushing ours) is what makes
  # this converge from a Cloud that lost its copy — `secret` is immutable on the
  # box's update path by design, so rotate is the only way to re-agree.
  defp converge_push_relay_webhook(bp, scoped, id, receiver_url, scope) do
    _ = relay_admin(bp, :post, "#{scoped}/#{id}/reenable", %{})

    case relay_admin(bp, :post, "#{scoped}/#{id}/rotate", %{}) do
      {:ok, status, %{"secret" => secret}} when status in 200..299 and is_binary(secret) ->
        with {:ok, _bp} <-
               bp
               |> Ecto.Changeset.change(push_relay_secret_encrypted: Vault.encrypt(secret))
               |> Repo.update() do
          {:ok, Map.merge(scope, %{status: "converged", webhook_id: id, url: receiver_url})}
        end

      {:ok, status, decoded} ->
        {:error, {:instance, status, decoded}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Mint a one-click Studio login URL for a live instance (dwb-7 "Studio
  one-click entry").

  Uses the stored per-instance admin token SERVER-SIDE to call the instance's
  `POST /v1/auth/login-tickets`, which returns a single-use, 60s opaque ticket
  bound to that token. The result is `{:ok, "<instance-url>/login/ticket/<t>"}` —
  the browser opens it once, the instance sets the session, Studio loads. The
  admin token itself NEVER leaves this function (not in the URL, not in the
  response, not logged) — only the short-lived ticket does.

  Errors: `:suspended` (the billing verdict — checked FIRST, before the admin
  token is decrypted), `:not_live` (no `url` yet — still provisioning/failed),
  `:no_admin_token` (row never got one; mirrors the `/credentials` 404),
  `:decrypt_failed` (tampered ciphertext, fail-closed), `:instance_error`
  (the instance call failed or returned a non-ticket).

  Transport is the swappable `:studio_link_http_client` module (default
  `BarkparkCloud.Billing.HttpClient` — verified TLS `:httpc`; tests wire
  `BarkparkCloud.StudioLinkFakeHttpClient`).

  A `user_email` (cloud-identity-studio-handoff) asks the instance for a
  USER-shaped ticket: consuming it signs the browser in AS that account
  (JIT-provisioned, Default-workspace owner) instead of an anonymous
  admin-token session — the "your cloud account works on your instance"
  handoff. An older instance ignores the extra field and mints the legacy
  token-shaped ticket: graceful degradation, never an error.
  """
  @spec mint_studio_link(Barkpark.t(), String.t() | nil) ::
          {:ok, String.t()}
          | {:error, :suspended | :not_live | :no_admin_token | :decrypt_failed | :instance_error}
  def mint_studio_link(bp, user_email \\ nil)

  # cch-w54-s2 — a SUSPENDED box mints nothing. `billing.ex`'s own
  # cancel_subscription/1 calls suspension "data retained, access revoked"; until
  # this clause existed no access was revoked — a suspended instance still handed
  # back a redeemable ticket. Keyed on the BOOLEAN, not the reason: both
  # producers set the same column, and the console paints one state from it
  # (lifecyclePillState "stopped", Open Studio hidden), so the server is now
  # congruent with the state the client already shows. It sits ABOVE the working
  # clause deliberately: the refusal fires BEFORE reveal_admin_token/1, so the
  # stored admin credential is never decrypted and no byte leaves the control
  # plane for a suspended box.
  def mint_studio_link(%Barkpark{suspended: true}, _user_email), do: {:error, :suspended}

  def mint_studio_link(%Barkpark{url: url} = bp, user_email)
      when is_binary(url) and url != "" do
    case reveal_admin_token(bp) do
      {:ok, nil} ->
        {:error, :no_admin_token}

      :error ->
        {:error, :decrypt_failed}

      {:ok, admin_token} ->
        base = String.trim_trailing(url, "/")

        body =
          case user_email do
            email when is_binary(email) and email != "" -> Jason.encode!(%{email: email})
            _ -> "{}"
          end

        request = %{
          method: :post,
          url: base <> "/v1/auth/login-tickets",
          headers: [
            {"Authorization", "Bearer " <> admin_token},
            {"Accept", "application/json"},
            {"Content-Type", "application/json"}
          ],
          body: body
        }

        case studio_link_http_client().request(request) do
          {:ok, %{status: 201, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"ticket" => ticket}} when is_binary(ticket) and ticket != "" ->
                # Mint over the provisioning FQDN (canonical control traffic),
                # LAND the user on the attached custom host when one exists —
                # the operator chose it as THE address, and the single-use
                # ticket redeems on any host the instance serves.
                {:ok, public_base(bp) <> "/login/ticket/" <> ticket}

              _ ->
                {:error, :instance_error}
            end

          _ ->
            {:error, :instance_error}
        end
    end
  end

  def mint_studio_link(_, _), do: {:error, :not_live}

  defp public_base(%Barkpark{custom_host: ch}) when is_binary(ch) and ch != "",
    do: "https://" <> ch

  defp public_base(%Barkpark{url: url}), do: String.trim_trailing(url, "/")

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

  # The one permission set the app-token exchange mints (mobile charter D6,
  # ratified R2). Deliberately admin-free: the instance derives the membership
  # role FROM the permissions, so this list is what keeps the minted credential
  # member-shaped.
  @app_token_permissions ["read", "write", "chat"]

  @doc """
  Mint a member-reachable, workspace-bound instance app token (mobile charter
  D4) — `mint_studio_link/2`'s sibling for the Barkpark Tasks mobile app.

  Uses the stored per-instance admin token SERVER-SIDE to call the instance's
  `POST /v1/auth/app-tokens`, which JIT-provisions `user_email`'s account and
  mints a `#{inspect(@app_token_permissions)}` api token bound to the
  instance's bootstrap workspace (or its Default workspace when none). The
  admin token itself NEVER leaves this function (not in the payload, not
  logged) — but unlike studio-link the PLAINTEXT minted app token IS the
  payload: `{:ok, %{token, workspace_id, permissions, expires_at}}`. The
  caller must never log or audit the token value.

  Errors: `:suspended` (the billing verdict — checked FIRST, before the admin
  token is decrypted), `:not_live` (no `url` yet — still provisioning/failed),
  `:no_admin_token` (row never got one; mirrors `/credentials`),
  `:decrypt_failed` (tampered ciphertext, fail-closed),
  `:app_token_unsupported` (the instance 404s the mint route — a pre-exchange
  server, charter D8; the client falls back to manual token paste),
  `:instance_error` (the instance call failed or returned a non-token).

  Transport is the same swappable `:studio_link_http_client` seam
  `mint_studio_link/2` uses (tests wire `StudioLinkFakeHttpClient`).
  """
  @spec mint_app_token(Barkpark.t(), String.t()) ::
          {:ok,
           %{
             token: String.t(),
             workspace_id: String.t() | nil,
             permissions: [String.t()],
             expires_at: String.t() | nil
           }}
          | {:error,
             :suspended
             | :not_live
             | :no_admin_token
             | :decrypt_failed
             | :app_token_unsupported
             | :instance_error}
  # cch-w54-s2 — the strictly-worse sibling of the studio-link hole, and the
  # reason gating studio-link alone was refused: this token is DURABLE
  # (read+write+chat, long expiry) and member-reachable, so one mint through a
  # suspended box outlives the suspension entirely. Same physics as the clause
  # above: boolean-keyed, above the working clause, so the refusal beats
  # reveal_admin_token/1 and the instance is never called.
  def mint_app_token(%Barkpark{suspended: true}, _user_email), do: {:error, :suspended}

  def mint_app_token(%Barkpark{url: url} = bp, user_email)
      when is_binary(url) and url != "" and is_binary(user_email) and user_email != "" do
    case reveal_admin_token(bp) do
      {:ok, nil} ->
        {:error, :no_admin_token}

      :error ->
        {:error, :decrypt_failed}

      {:ok, admin_token} ->
        base = String.trim_trailing(url, "/")

        body =
          Jason.encode!(%{
            email: user_email,
            workspace: bp.bootstrap_workspace,
            permissions: @app_token_permissions,
            label: "app:" <> user_email
          })

        request = %{
          method: :post,
          url: base <> "/v1/auth/app-tokens",
          headers: [
            {"Authorization", "Bearer " <> admin_token},
            {"Accept", "application/json"},
            {"Content-Type", "application/json"}
          ],
          body: body
        }

        case studio_link_http_client().request(request) do
          {:ok, %{status: 201, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"token" => token} = decoded} when is_binary(token) and token != "" ->
                {:ok,
                 %{
                   token: token,
                   workspace_id: decoded["workspace_id"],
                   permissions: decoded["permissions"] || @app_token_permissions,
                   expires_at: decoded["expires_at"]
                 }}

              _ ->
                {:error, :instance_error}
            end

          # A pre-exchange instance has no /v1/auth/app-tokens route: Phoenix
          # 404s. That is capability absence, not an outage (charter D8).
          {:ok, %{status: 404}} ->
            {:error, :app_token_unsupported}

          _ ->
            {:error, :instance_error}
        end
    end
  end

  def mint_app_token(_, _), do: {:error, :not_live}

  @doc """
  Revoke app token(s) on a live instance using the STORED admin credential —
  `mint_app_token/2`'s lifecycle twin (mobile wave 2, mob-w2-app-token-revoke).

  `mode` is either `{:token, raw}` — the phone presents the exact token it
  wants dead (relayed ONCE to the instance, never persisted, never logged) —
  or `{:email, email}` — logout-everywhere: the instance revokes every live
  `app:<email>`-labelled token. The DELETE goes to `/v1/auth/app-tokens` with
  the decrypted admin token as bearer; the admin credential never leaves this
  process.

  Instance-side 404s are split by BODY (the charter-D8 capability-vs-absence
  lesson): the canonical `{"error":{"code":"not_found"}}` envelope is a real
  token-not-found from the live revoke route; any other 404 shape is a
  pre-revoke instance with no such route yet → `:revoke_unsupported`.

  Instance-side 422 and 429 are DELIBERATE answers, not outages, and each keeps
  its own code (`:revoke_refused` / `:instance_rate_limited`) instead of
  collapsing into `:instance_error`. Only a genuine transport failure — or a
  status this route does not model — stays `:instance_error` (502 at the edge).

  `opts` accepts `:client_ip` — the ORIGINAL caller's address, relayed as
  `X-Forwarded-For` so the instance's own per-IP revoke bucket keys per phone
  rather than on the single Cloud egress address.
  """
  @spec revoke_app_token(Barkpark.t(), {:token, String.t()} | {:email, String.t()}, keyword()) ::
          {:ok, map()}
          | {:error,
             :not_live
             | :no_admin_token
             | :decrypt_failed
             | :not_found
             | :revoke_unsupported
             | :revoke_refused
             | :instance_rate_limited
             | :instance_error}
  def revoke_app_token(barkpark, mode, opts \\ [])

  def revoke_app_token(%Barkpark{url: url} = bp, {kind, value} = mode, opts)
      when is_binary(url) and url != "" and kind in [:token, :email] and is_binary(value) and
             value != "" do
    case reveal_admin_token(bp) do
      {:ok, nil} ->
        {:error, :no_admin_token}

      :error ->
        {:error, :decrypt_failed}

      {:ok, admin_token} ->
        base = String.trim_trailing(url, "/")

        body =
          case mode do
            {:token, raw} -> Jason.encode!(%{token: raw})
            {:email, email} -> Jason.encode!(%{email: email})
          end

        request = %{
          method: :delete,
          url: base <> "/v1/auth/app-tokens",
          headers:
            [
              {"Authorization", "Bearer " <> admin_token},
              {"Accept", "application/json"},
              {"Content-Type", "application/json"}
            ] ++ forwarded_for(opts),
          body: body
        }

        case studio_link_http_client().request(request) do
          {:ok, %{status: 200, body: resp}} ->
            case Jason.decode(resp) do
              {:ok, decoded} when is_map(decoded) ->
                {:ok, Map.take(decoded, ["revoked", "revoked_count"])}

              _ ->
                {:error, :instance_error}
            end

          {:ok, %{status: 404, body: resp}} ->
            case Jason.decode(resp) do
              # The live revoke route's canonical envelope → the token really
              # does not exist (or is out of this surface's reach).
              {:ok, %{"error" => %{"code" => "not_found"}}} -> {:error, :not_found}
              # Anything else 404-shaped (Phoenix no-route body) → the instance
              # predates the revoke route: capability absence, not an outage.
              _ -> {:error, :revoke_unsupported}
            end

          # The instance REFUSED this revoke on purpose: the presented raw token
          # resolves to an `admin`-carrying token, which the app-token path never
          # kills (the stored custody credential must not die by a member-shaped
          # call or a label collision). "Instance unreachable" would be a lie
          # that sends the phone into a retry loop against a settled answer.
          #
          # INFORMATION EXPOSURE — bounded on purpose (the reasoning, recorded):
          # separating 422 from 404 tells the caller "the token you presented
          # exists AND carries admin". Reaching this arm at all requires ALREADY
          # holding that admin token's plaintext, and a holder can confirm its own
          # liveness far more directly (any admin-authed instance call). A member
          # who does not hold it cannot distinguish this arm from `:not_found`, so
          # no new admin-token-liveness oracle is opened — strictly less than the
          # mint arm already exposes, which hands out live credentials.
          {:ok, %{status: 422}} ->
            {:error, :revoke_refused}

          # The instance's own per-IP revoke bucket tripped (the D7 sibling of the
          # proxy's window). Transport is healthy and the verdict is "slow down",
          # so it stays a 429 end-to-end rather than masquerading as an outage the
          # client would retry into.
          {:ok, %{status: 429}} ->
            {:error, :instance_rate_limited}

          _ ->
            {:error, :instance_error}
        end
    end
  end

  def revoke_app_token(_, _, _), do: {:error, :not_live}

  # Relay the ORIGINAL caller's address so the instance's `{:app_token_revoke,
  # ip}` bucket keys per phone. Without it every cloud-proxied revoke arrives
  # from the single Cloud egress IP and a whole TEAM shares one 10/min allowance
  # — which surfaced (before the split above) as a misleading 502.
  #
  # TRUST, RE-RECORDED — INHERITED, not introduced here (charter D43): the
  # instance reads the FIRST x-forwarded-for hop as the client ip, exactly as its
  # pre-existing pulse limiter already does. That is only sound because the
  # instance is fronted by its own proxy (which appends, so our hop stays first);
  # a caller reaching the instance directly could always pick its own bucket key,
  # and this relay neither widens nor narrows that. Redesigning the trust
  # boundary (a trusted-proxy allowlist on the limiter) is not this pass.
  defp forwarded_for(opts) do
    case Keyword.get(opts, :client_ip) do
      ip when is_binary(ip) and ip != "" -> [{"X-Forwarded-For", ip}]
      _ -> []
    end
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
    * `:suspended`       — the box is suspended; the control plane no longer
                           writes its configuration (see the clause below)
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
             | :suspended
             | :not_live
             | :no_admin_token
             | :decrypt_failed
             | :no_bootstrap
             | :no_webhook
             | :instance_error}
  # cch-w58-bl — a SUSPENDED box is not WRITTEN. Wiring a site URL is a
  # credentialed WRITE against the instance (LIST then PUT of its revalidation
  # webhook) with the DECRYPTED stored admin token; on a suspended row that is
  # the control plane still configuring a server its own console says it has
  # stopped managing. Keyed on the BOOLEAN, not the reason — both producers set
  # the same column and the console paints one state from it — and placed as a
  # LEADING clause (D685: the guard goes where the request is BUILT), so the
  # refusal fires BEFORE `reveal_admin_token_or_error/1` touches the ciphertext:
  # no credential is decrypted and no byte leaves the control plane. Prior art:
  # `mint_studio_link/2` above. Deliberately NOT keyed on reachability
  # (`verify_reachable` / `last_verified_at`) — D684 retracted that column, and a
  # never-verified box still wires (pinned by test).
  def wire_site_url(%Barkpark{suspended: true}, _site_url), do: {:error, :suspended}

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
  fleet). The `UpdateStatusWorker`'s hourly scan set + the usage sampler's
  fleet sweep. GLOBAL — deliberately ignores team scoping (a maintenance
  sweep). The team-scoped counterpart is `checkable_barkparks/1`.
  """
  @spec update_checkable_barkparks() :: [Barkpark.t()]
  def update_checkable_barkparks do
    Barkpark
    |> checkable_scope()
    |> order_by([b], asc: b.inserted_at)
    |> Repo.all()
  end

  @doc """
  A single Team's checkable Barkparks — the SAME "live + not billing-suspended"
  predicate `update_checkable_barkparks/0` sweeps globally, scoped to one team
  (`GET /v1/usage/summary`'s fleet strip is team-private). Owning the predicate
  in ONE place (`checkable_scope/1`) means a change to what "checkable" means
  can never drift between the maintenance sweep and the team read.
  """
  @spec checkable_barkparks(Team.t() | binary()) :: [Barkpark.t()]
  def checkable_barkparks(team) do
    tid = team_id(team)

    Barkpark
    |> where([b], b.team_id == ^tid)
    |> checkable_scope()
    |> order_by([b], desc: b.inserted_at)
    |> Repo.all()
  end

  # The lone definition of "checkable": a live box (`host` set) that isn't
  # billing-suspended. Both the global sweep and the team-scoped read compose it
  # so the fleet scope can never diverge between them.
  defp checkable_scope(query) do
    query
    |> where([b], not is_nil(b.host) and b.host != "")
    |> where([b], b.suspended == false)
  end

  @doc """
  Refresh a Barkpark's cached self-update status from the instance's OWN verdict:
  `GET <instance>/v1/admin/self-update` with the stored admin token (server-side,
  the token never leaves this function), read the `"check"` block, persist it via
  the narrow `Barkpark.update_status_changeset/2`.

  NEVER raises, and ALWAYS best-effort-persists on failure: any failure mode —
  not live, no/tampered admin token, transport error, non-200 (a pre-feature
  instance 404s the endpoint), undecodable body — lands `update_state:
  "unknown"` on the row and returns `{:error, reason}`. `update_checked_at` is
  refreshed only when a check was ACTUALLY made (cch-w65): the three rungs that
  return before a request is built — not live, no admin token, tampered token —
  leave the column exactly as they found it. A 200 with a `"check"` map
  persists its state (whitelisted
  against `Barkpark.update_states/0`, anything else → `"unknown"`), the
  running/latest releases, and the check time, returning `{:ok, bp}`.

  THE REASON IS PERSISTED (cch-w58). "unknown" alone collapses five different
  worlds, and this call is the one question per hour that CAN lose, so its
  answer lands in `update_unavailable_reason`:

    * `identity_refused` (401) — the box does not hold THIS row's admin token.
      A refutation of our stored credential, not a transient.
    * `forbidden` (403) — the box knows the credential and refuses the principal.
    * `no_self_update_route` (404) — a PRE-FEATURE box: no such route, nothing
      refused. Deliberately NOT folded into `identity_refused` (charter D684).
    * `unreachable` — no response at all (transport failure).
    * `bad_shape` — a 200 whose body we could not read as a check envelope.
    * `instance_error` — any other status.

  A clean 200 CLEARS the column, so a stale refusal can never outlive a
  recovery. Nothing REFUSES on this column yet — it is evidence, not a guard.

  THE ARMING IS PERSISTED TOO, off the SIBLING of `"check"`. The same 200 also
  carries `apply_enabled` (#12995) — the box's `Runner.enabled?/0`, the exact
  input its one-click-apply POST decides its 503 from — and it lands in
  `apply_arming` as a THREE-valued fact:

    * `"armed"` — the body said `true`.
    * `"unarmed"` — the body said `false`. This box will 503 the moment the
      rollout reaches it, and that 503 is what `AutoupdateRolloutWorker` answers
      with a `pause_autoupdate/1` no code path clears. It is the retro-arm
      worklist.
    * `nil` — NOT MEASURED: the body carried no such key (a pre-#12995 box, which
      may well be armed), or no body has ever been read for this row. Reading
      this as `false` would put correctly-armed boxes on the worklist, so the
      absent key is never coerced into a word.

  Only a decoded 200 writes those columns (with their own clock,
  `apply_arming_checked_at`); every failure rung leaves them exactly as it found
  them, because a box that stops answering has not become unmeasured — and
  wiping the roster on an outage is the opposite of what an operator needs. This
  is a READ: nothing here POSTs to a box, arms anything, or clears an
  `autoupdate_paused`.

  Transport is the same swappable seam `mint_studio_link/1` uses
  (`:studio_link_http_client`; tests wire `StudioLinkFakeHttpClient`).
  """
  @spec refresh_update_status(Barkpark.t()) ::
          {:ok, Barkpark.t()}
          | {:error,
             :not_live
             | :no_admin_token
             | :decrypt_failed
             | :identity_refused
             | :forbidden
             | :no_self_update_route
             | :unreachable
             | :bad_shape
             | :instance_error}
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
              # A 200 we cannot read is not the same world as a box that
              # errored: the box answered and believes it succeeded, and the
              # shape is what failed. Same word `Usage` already uses for it,
              # and it is the only writer of this rung (cch-w58 review).
              {:ok, %{"check" => %{} = check} = body} ->
                persist_update_check(bp, check, arming_of(body))

              _ ->
                persist_update_unknown(bp, :bad_shape)
            end

          # The box's OWN admin route answered, and its answer DISCRIMINATES —
          # each of these is a different world, and collapsing them is what made
          # "unknown" unreadable (cch-w58). 404 stays its own third outcome: a
          # pre-feature box has no such route and has refused nothing.
          {:ok, %{status: 401}} ->
            persist_update_unknown(bp, :identity_refused)

          {:ok, %{status: 403}} ->
            persist_update_unknown(bp, :forbidden)

          {:ok, %{status: 404}} ->
            persist_update_unknown(bp, :no_self_update_route)

          {:error, _} ->
            persist_update_unknown(bp, :unreachable)

          _ ->
            persist_update_unknown(bp, :instance_error)
        end
    end
  end

  def refresh_update_status(%Barkpark{} = bp), do: persist_update_unknown(bp, :not_live)

  # THE ARMING PROBE, read off the SIBLING of `"check"` (#12995). `apply_enabled`
  # reports the box's `Runner.enabled?/0` — the running BEAM's boot-frozen value,
  # which is the exact input its one-click-apply POST decides its 503
  # `feature_not_configured` from. Those bytes already arrived on every refresh;
  # the old match named only `"check"` and dropped them on the floor.
  #
  # THREE WORLDS, AND THE ABSENT KEY IS NOT `false`. A pre-#12995 box that is
  # genuinely armed sends no such key, so mapping absence to "unarmed" would make
  # it indistinguishable from a MEASURED unarmed box and put correctly-armed
  # boxes on the retro-arm worklist — the one outcome that would make this roster
  # worse than no roster. `nil` is the third state and the ONLY thing the last
  # clause can produce.
  #
  # FAIL-CLOSED ON SHAPE, like `check["state"]` above it: only the two literal
  # booleans are trusted into a word. A string "true", a 1, a null — anything a
  # weird instance might render — falls to `nil`/unmeasured rather than being
  # coerced into a verdict an operator would act on.
  defp arming_of(%{"apply_enabled" => true}), do: "armed"
  defp arming_of(%{"apply_enabled" => false}), do: "unarmed"
  defp arming_of(_body), do: nil

  # Mirror the instance's "check" verdict onto the row. A state outside the
  # whitelist is downgraded to "unknown" (fail-closed — never trust a weird
  # instance into a rendering state the SPA doesn't know).
  defp persist_update_check(bp, check, arming) do
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
      update_checked_at: DateTime.utc_now(),
      # The box answered us on its own admin route: whatever it refused an hour
      # ago, it does not refuse now. A stale refusal must not survive a recovery.
      update_unavailable_reason: nil,
      # THE ARMING MEASUREMENT, and its OWN clock. `update_checked_at` above is
      # stamped on six unknown rungs that never read a body at all, so it cannot
      # say when the arming question was last actually ANSWERED. This one is
      # written on exactly one path — a decoded 200 — which is the only place an
      # answer exists (cch-w65: the clock records a check that was actually
      # made). Stamped even when `arming` is nil, because "we read a body and it
      # carried no arming" is itself a measurement (a pre-#12995 box) and is a
      # different fact from "we have never read one".
      apply_arming: arming,
      apply_arming_checked_at: DateTime.utc_now()
    })
    # FORCED, not cast: `cast` emits no change when the value already matches the
    # IN-MEMORY struct, and the caller may hold a struct read BEFORE the refusal
    # was persisted (the router's fire-and-forget kick, a retry on a struct
    # carried across calls). That would leave the accusation in the row while the
    # box is demonstrably answering. The clear is unconditional.
    |> Ecto.Changeset.force_change(:update_unavailable_reason, nil)
    # FORCED for the same reason, and honestly the same status: INSURANCE, not a
    # live path (charter D717 measured that all three callers hand this function
    # a freshly-read struct). The shape it covers is a struct whose in-memory
    # arming is already `nil` while the ROW still says "unarmed" — `cast` emits
    # no change there, so the UPDATE would omit the column and leave the stale
    # word standing on the roster while the box has stopped reporting arming at
    # all. Deleting this line reds exactly one test, and that test says in its
    # own body that it pins the insurance rather than a shape production
    # produces today.
    |> Ecto.Changeset.force_change(:apply_arming, arming)
    |> Repo.update()
    |> auto_enqueue_on_unarmed(arming)
  end

  # isu-w5 (task-509f5fd02bc48f9c): a box that just MEASURED unarmed gets its
  # repair filed, not just recorded — `maybe_enqueue_enable_apply_job/1` gates on
  # consent (autoupdate_enabled, not suspended, has a host) and dedups via the
  # one-active-per-kind index, so the hourly sweep re-reporting the same box is
  # a no-op while a job is in flight. Best-effort: an enqueue failure must never
  # mask the measurement that was successfully persisted (same posture as the
  # rollout worker's 503 branch — a control-plane fault is retried next
  # measurement, not escalated). Return value passes through untouched, so every
  # `refresh_update_status/1` caller keeps its exact contract.
  defp auto_enqueue_on_unarmed({:ok, %Barkpark{} = bp} = ok, "unarmed") do
    case maybe_enqueue_enable_apply_job(bp) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "enable-apply: #{bp.slug} measured unarmed but the auto-enqueue FAILED " <>
            "(#{inspect(reason)}) — will retry on the next unarmed measurement"
        )
    end

    ok
  end

  defp auto_enqueue_on_unarmed(result, _arming), do: result

  # Best-effort "unknown" landing for every failure mode — the row always
  # reflects that we asked and got no usable verdict, AND (cch-w58) WHICH
  # no-usable-verdict it was. The write itself is best-effort too (a
  # changeset/DB failure never masks the original reason), and every atom that
  # reaches here is in `Barkpark.update_unavailable_reasons/0`.
  #
  # THE CLOCK RECORDS A CHECK THAT WAS ACTUALLY MADE (cch-w65). Three of the
  # nine rungs return BEFORE any request is built — `:no_admin_token`,
  # `:decrypt_failed` and `:not_live` — so no bytes ever left this plane and
  # there is no check whose time could be recorded. Stamping one there is the
  # control plane inventing evidence about a box it never spoke to, and the
  # console shipped a client-side apology (`UPDATE_REFUSAL_UNCLOCKED`) to teach
  # the browser which three of nine server rungs to disbelieve.
  @unclocked_reasons [:no_admin_token, :decrypt_failed, :not_live]

  defp persist_update_unknown(bp, reason) do
    _ =
      bp
      |> Barkpark.update_status_changeset(update_unknown_attrs(reason))
      |> Repo.update()

    {:error, reason}
  end

  defp update_unknown_attrs(reason) do
    attrs = %{
      update_state: "unknown",
      update_running_release: nil,
      update_latest_release: nil,
      update_unavailable_reason: Atom.to_string(reason)
    }

    # OMITTED, never an explicit `nil` (charter D789). A box that answered
    # honestly an hour ago and has since lost its `url` still HAS a true
    # last-checked time; writing nil would erase it and trade one lie for
    # another. A never-checked row simply stays NULL, which every reader
    # already renders honestly (`digest_email.format_ts(nil) -> "never"`).
    if reason in @unclocked_reasons,
      do: attrs,
      else: Map.put(attrs, :update_checked_at, DateTime.utc_now())
  end

  defp string_field(v) when is_binary(v) and v != "", do: v
  defp string_field(_), do: nil

  @doc """
  Grade how far behind `main` the commit this box actually SERVES is, and
  persist the verdict into its own three columns (deploy-reliability W21).

  This is the control plane's OWN measurement, and it is deliberately not
  `update_state`: that column mirrors the box's release-tag self-grade, which
  reads `current` on a box 2,468 commits behind. The verdict comes from ONE
  unauthenticated GitHub compare call
  (`BarkparkCloud.GitHub.CommitDistance.verdict/2`).

  NEVER raises and ALWAYS writes: every failure mode — an empty/NULL
  `git_commit` (the agent is offline), an unknown sha (404), a rate-limit
  refusal (403), a transport error, an unconfigured client — lands
  `commit_ancestry: "unknown"` with `commit_distance: NULL`, never 0, plus a
  fresh `commit_distance_checked_at` so the row honestly says "we asked and got
  no usable answer". Returns `{:ok, bp}` on a persisted verdict of any rung, or
  `{:error, reason}` if the write itself failed.

  `update_state`, `update_checked_at` and every other column are untouched: the
  write goes through the narrow `Barkpark.commit_distance_changeset/2`.
  """
  @spec refresh_commit_distance(Barkpark.t(), keyword()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def refresh_commit_distance(%Barkpark{} = bp, opts \\ []) do
    %{ancestry: ancestry, distance: distance} = CommitDistance.verdict(bp.git_commit, opts)

    bp
    |> Barkpark.commit_distance_changeset(%{
      commit_ancestry: ancestry,
      commit_distance: distance,
      commit_distance_checked_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

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

  PIN HONESTY (isu-w5.2): a pinned instance (`pinned_release` set) is FROZEN on
  its version, so an unforced trigger returns `{:error, :pinned}` — the router
  relays that as 409 to the console Update button, telling the operator the box
  is pinned. `force: true` overrides (an explicit "yes, update the pinned box").
  The rollout worker never hits this — it already excludes pinned rows from its
  candidate query — but the interactive relay must not silently no-op a pin.

  IDENTITY REFUSAL (cch-w60-s4): a box whose last probe was refused
  (`update_unavailable_reason == "identity_refused"` — it answered our stored
  admin credential 401) returns `{:error, :identity_refused}` BEFORE the token
  is decrypted and before anything reaches the wire. A pinned AND refused box
  still returns `:pinned` on an unforced trigger (the pin clause matches
  above); `force: true` reaches the refusal. Both are terminal, and the wire is
  empty either way — only the word differs.
  """
  @spec trigger_self_update(Barkpark.t(), keyword()) ::
          {:ok, non_neg_integer(), map()}
          | {:error,
             :not_live
             | :no_admin_token
             | :decrypt_failed
             | :instance_error
             | :pinned
             | :identity_refused}
  def trigger_self_update(bp, opts \\ [])

  def trigger_self_update(%Barkpark{pinned_release: pin} = bp, opts)
      when is_binary(pin) and pin != "" do
    if Keyword.get(opts, :force, false) do
      do_trigger_self_update(bp)
    else
      {:error, :pinned}
    end
  end

  def trigger_self_update(bp, _opts), do: do_trigger_self_update(bp)

  defp do_trigger_self_update(bp), do: relay_admin_post(bp, "/v1/admin/self-update")

  @doc """
  Trigger a blue/green ROLLBACK run on a live instance: `POST
  <instance>/v1/admin/rollback` server-side with the stored admin token — the
  exact `trigger_self_update/2` relay seam (isu-w6).

  Returns `{:ok, http_status, decoded_body_map}` on ANY instance response —
  the instance's semantics travel intact to the router, which relays them
  (202 `{status:"started",target_sha}` | 409 no_previous_slot /
  already_running / not_supported | 503 feature_not_configured). Errors
  mirror `trigger_self_update/2`'s atoms: `:not_live`, `:no_admin_token`,
  `:decrypt_failed`, `:instance_error`.

  NO PIN PRECONDITION (isu-w6 D16) — the one deliberate difference from the
  update trigger: a pinned instance is NOT refused. Rollback RE-PINS by
  design (the router atomically writes `pinned_release = <instance-reported
  target_sha>` on 202), so the operator's explicit rollback wins over the
  stale pin. An unpinned rollback would be undone within one rollout tick —
  a lie.

  IDENTITY REFUSAL (cch-w60-s4): rollback rides the same shared POST seam, so a
  box that refuted our stored admin credential returns `{:error,
  :identity_refused}` with nothing on the wire — there is no pin clause above
  this trigger, so the refusal is the only verdict.
  """
  @spec trigger_rollback(Barkpark.t(), keyword()) ::
          {:ok, non_neg_integer(), map()}
          | {:error,
             :not_live
             | :no_admin_token
             | :decrypt_failed
             | :instance_error
             | :identity_refused}
  def trigger_rollback(bp, _opts \\ []), do: relay_admin_post(bp, "/v1/admin/rollback")

  # The shared instance-admin relay: reveal the stored admin token, POST `body`
  # (default: an empty object) to <instance_url><path>, hand back the instance's
  # verdict with its semantics intact (undecodable body degrades to %{} — the
  # status alone is the verdict). Both admin triggers ride this one seam.
  #
  # cch-w60-s4 — THE PLANE STOPS ASKING A REFUTED BOX TO EXECUTE. When the last
  # update probe was refused by the box itself (`update_unavailable_reason ==
  # "identity_refused"` — the box answered our stored admin credential 401), an
  # EXECUTE ask is spending a decrypted secret at an address that has already
  # told us the secret is wrong. Refuse here, ABOVE `relay_admin/4` — so the
  # refusal fires BEFORE `reveal_admin_token/1` and nothing reaches the wire.
  #
  # The guard sits on this shared POST seam (exactly two callers repo-wide, both
  # admin triggers, and it is `defp`) rather than on either trigger, so a third
  # admin trigger added later INHERITS the refusal instead of escaping it. It is
  # deliberately NOT on `relay_admin/4`: that seam also carries token mints, site
  # deploys and READS, and refusing a read because a WRITE credential was refuted
  # is a different doctrine call.
  #
  # ONE RUNG ONLY. The column is `:string` (`Barkpark` :224) with a nine-rung
  # whitelist, so the pattern is the literal STRING — an atom pattern would ship
  # a refusal that can never fire. `"forbidden"` (the box knows our token but
  # denies the route) is a DIFFERENT fact and is deliberately not matched here.
  defp relay_admin_post(bp, path, body \\ %{})

  defp relay_admin_post(%Barkpark{update_unavailable_reason: "identity_refused"}, _path, _body),
    do: {:error, :identity_refused}

  defp relay_admin_post(bp, path, body), do: relay_admin(bp, :post, path, body)

  @doc """
  The PUBLIC instance-admin relay (site-spawner D22/D29): reveal `bp`'s stored
  admin token and issue `method` `path` against it, carrying `body` (a map,
  JSON-encoded; `nil` sends no body).

  This is `relay_admin_post/2`'s generalization — the self-update / rollback
  triggers hard-coded `method: :post, body: "{}"`, which is precisely the shape
  that CANNOT mint a token or start a site deploy (both need argv). Same
  semantics, same transport seam (`:studio_link_http_client`, faked in test), so
  the instance's verdict travels intact: `{:ok, status, decoded_body}` on ANY
  instance response, or `{:error, :not_live | :no_admin_token | :decrypt_failed |
  :instance_error}`.

  Callers: `mint_public_read_token/5` (the scoped `/w/:ws/p/:proj/v1/tokens`
  mint) and `BarkparkCloud.Sites.BoxRelay.HTTP` (the `/v1/admin/site-deploy`
  drive + poll + rollback).
  """
  @spec relay_admin(Barkpark.t(), :get | :post | :put | :delete, String.t(), map() | nil) ::
          {:ok, non_neg_integer(), map()}
          | {:error, :not_live | :no_admin_token | :decrypt_failed | :instance_error}
  def relay_admin(bp, method, path, body \\ nil)

  # stw9 (charter D56): `:put` and `:delete` join the allowed verbs so webhook
  # HYGIENE is reachable at all — the box exposes `PUT /v1/webhooks/:dataset/:id`
  # and `DELETE /v1/webhooks/:dataset/:id` on the UNSCOPED admin block
  # (api/lib/barkpark_web/router.ex:1996-1997 — the scoped `/w/:ws/p/:proj` mirror
  # near :2373 declares the same verbs, but the CP calls the unscoped paths),
  # and without them the control plane could only ever CREATE rows: re-registration
  # duplicates (webhooks.name has no unique constraint) and a deleted site leaves an
  # ORPHAN endpoint that 404s every delivery until the box auto-disables it. The
  # transport already maps both (`BarkparkCloud.Billing.HttpClient.to_httpc/1` has
  # :put and :delete clauses), so this widens only the guard, not the seam.
  def relay_admin(%Barkpark{url: url} = bp, method, path, body)
      when is_binary(url) and url != "" and method in [:get, :post, :put, :delete] do
    case reveal_admin_token(bp) do
      {:ok, nil} ->
        {:error, :no_admin_token}

      :error ->
        {:error, :decrypt_failed}

      {:ok, admin_token} ->
        relay_with(url, method, path, body, admin_token)
    end
  end

  def relay_admin(_bp, _method, _path, _body), do: {:error, :not_live}

  @doc """
  site-spawner W8 (charter D74): relay a scoped instance READ with a
  CALLER-SUPPLIED bearer — the sibling of `relay_admin/4` for a credential the
  control plane is holding in hand rather than reading out of the row.

  Same transport, same `{:ok, status, decoded_body}` / `{:error, reason}`
  contract; the ONLY difference is whose token goes on the wire. There is no
  `:no_admin_token` / `:decrypt_failed` outcome here — the caller already has the
  plaintext — so a non-live box (or a blank bearer) is the single `:not_live`.

  WHY it cannot just be `relay_admin/4`: the site's own public-read token is
  CLAMPED (published + public-visibility, `Plugs.PublicRead` admits exactly
  `query/:ds/:type` and `doc/:ds/:type/:id`). An admin relay reports content the
  build's token cannot see, so a "verified" binding read over the admin token
  would be a NEW false green — a green preflight followed by an empty site. The
  only credential that can answer "what will the SITE see" is the site's own.

  Caller: the `POST /v1/sites` binding verification, which probes the just-minted
  read token over the SAME scoped route the build later fetches with
  (`Sites.Deploy` `scoped_api_url/2` + `BARKPARK_TOKEN`).
  """
  @spec relay_as(Barkpark.t(), :get | :post | :put | :delete, String.t(), String.t()) ::
          {:ok, non_neg_integer(), map()} | {:error, :not_live | :instance_error}
  def relay_as(bp, method, path, bearer)

  def relay_as(%Barkpark{url: url}, method, path, bearer)
      when is_binary(url) and url != "" and method in [:get, :post, :put, :delete] and
             is_binary(bearer) and bearer != "" do
    relay_with(url, method, path, nil, bearer)
  end

  def relay_as(_bp, _method, _path, _bearer), do: {:error, :not_live}

  # The shared body of `relay_admin/4` and `relay_as/4`: build the request against
  # the instance's base URL, send it over the `studio_link_http_client()` seam, and
  # keep the instance's own verdict intact. A body that is not a JSON OBJECT (or
  # not JSON at all) collapses to `%{}` — the status still travels, so a caller can
  # tell "the box answered 200 with something I cannot read" from "I never reached
  # the box".
  defp relay_with(url, method, path, body, bearer) do
    request = %{
      method: method,
      url: String.trim_trailing(url, "/") <> path,
      headers: instance_headers(bearer),
      body: encode_relay_body(body)
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

  defp encode_relay_body(nil), do: ""
  defp encode_relay_body(body) when is_map(body), do: Jason.encode!(body)
  defp encode_relay_body(body) when is_binary(body), do: body

  @doc """
  site-spawner D29: mint a `public-read` content token on `bp` for the
  `workspace`/`project`/`dataset` triple a static site is bound to, over the
  instance's SCOPED token route (`POST /w/:ws/p/:proj/v1/tokens`) — the UNSCOPED
  `/v1/tokens` 404s, and scoping is what pins the token to one workspace's
  membership. The prod-proven precedent is `vercelMintReadToken`
  (internal/cli/vercel_cmd.go).

  The instance answers `{"token": "..."}`; the plaintext is returned to the
  caller, which hands it straight to `create_site/2` (Vault-encrypted at rest as
  `read_token_encrypted`, never persisted in the clear, never serialized back).
  It is a READ credential clamped to published + public-visibility content by the
  instance's `PublicRead` plug (charter D6) — the site build is the only consumer.

  `{:error, {:instance, status, body}}` on a non-2xx / token-less instance reply
  so the router can answer honestly (which box, which status) instead of minting
  a 201 ghost with no content binding.
  """
  @spec mint_public_read_token(Barkpark.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error,
             :not_live
             | :no_admin_token
             | :decrypt_failed
             | :instance_error
             | {:instance, non_neg_integer(), map()}}
  def mint_public_read_token(%Barkpark{} = bp, workspace, project, dataset, label)
      when is_binary(workspace) and is_binary(project) and is_binary(dataset) do
    path = "/w/#{URI.encode(workspace)}/p/#{URI.encode(project)}/v1/tokens"
    body = %{label: label, permissions: ["public-read"], dataset: dataset}

    case relay_admin(bp, :post, path, body) do
      {:ok, status, %{"token" => token}}
      when status in 200..299 and is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, status, decoded} ->
        {:error, {:instance, status, decoded}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Fleet autoupdate (isu-w4) — the control plane's OPT-OUT auto-rollout. The
  ## isu-6 machinery above already (a) mirrors each instance's own `behind`
  ## verdict onto its row and (b) relays a self-update trigger server-side. W4
  ## adds the POLICY (who is eligible) and the CANDIDATE/IN-FLIGHT queries the
  ## AutoupdateRolloutWorker uses to walk the fleet ONE health-gated instance at
  ## a time: trigger a `behind` instance, wait until it settles `current` (or
  ## times out → contain), then advance. Autonomous by design — no human step —
  ## because a blessed release is what feeds it (release-curator, autonomous).

  @doc """
  Set an instance's autoupdate POLICY (team-facing): `autoupdate_enabled`
  (opt-out master, default true), `autoupdate_paused` (temporary hold),
  `pinned_release` (freeze on version). Narrow — can touch nothing else.
  """
  @spec set_autoupdate(Barkpark.t(), map()) :: {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def set_autoupdate(%Barkpark{} = bp, attrs) do
    bp |> Barkpark.autoupdate_changeset(attrs) |> Repo.update()
  end

  @doc """
  Set an instance's rollout CHANNEL ("prod" | "staging") — a PLATFORM-OPERATOR
  action (isu-w5.2), never team-facing: a tenant who could self-assign staging
  (then pause or sit behind) would hold `staging_gate_open?/0` closed and brake
  every prod-channel advancement fleet-wide. Narrow — can touch nothing else.
  """
  @spec set_channel(Barkpark.t(), binary()) :: {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def set_channel(%Barkpark{} = bp, channel) do
    bp |> Barkpark.channel_changeset(%{channel: channel}) |> Repo.update()
  end

  @doc """
  Contain an instance: pause its autoupdate (e.g. the rollout worker gave up on
  a wave that never settled). Idempotent; never raises on a normal row.
  """
  @spec pause_autoupdate(Barkpark.t()) :: {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def pause_autoupdate(%Barkpark{} = bp), do: set_autoupdate(bp, %{autoupdate_paused: true})

  @doc """
  Record — from the rollout's OWN 503 — that this box has not armed one-click
  apply, so `next_autoupdate_candidate/1` stops picking it.

  THIS IS THE NON-LATCHING TWIN OF `pause_autoupdate/1`, and the difference is
  the whole reason it exists. `autoupdate_paused` is a POLICY flag whose only
  `false` writer is a human PATCH; writing it from a machine-observed 503 turns
  a recoverable box condition into a permanent, human-gated one. `apply_arming`
  is a MEASUREMENT, and the hourly `UpdateStatusWorker` sweep re-measures it: the
  moment the operator sets `BARKPARK_SELF_UPDATE_APPLY=1` and restarts the box,
  its admin route answers `apply_enabled: true`, `refresh_update_status/1` writes
  `"armed"`, and the box re-enters the candidate set with nobody clearing
  anything.

  The 503 is an authoritative reading of the SAME fact the arming probe reads —
  the box's `Runner.enabled?/0`, which is what its one-click-apply handler
  decides its `feature_not_configured` 503 from — so writing `"unarmed"` here is
  a measurement, not an inference. It carries `apply_arming_checked_at` for the
  same reason the probe does: an operator needs to know WHEN the fact was last
  established, and this writer establishes it off a POST rather than the GET.

  Deliberately writes ONLY the two arming columns — it must not touch
  `update_state` (the box's `behind` verdict is unchanged by its refusal to
  apply) and it must not touch any autoupdate policy column.

  isu-w5 (task-509f5fd02bc48f9c): recording is no longer the end of the story —
  the same unarmed measurement auto-files the repair
  (`maybe_enqueue_enable_apply_job/1`, consent-gated + deduped), so a box on
  autoupdate that answers 503 gets ARMED by the provisioner instead of sitting
  on the retro-arm worklist waiting for a human. Best-effort: an enqueue failure
  never masks the successfully-persisted measurement.
  """
  @spec record_apply_unarmed(Barkpark.t()) :: {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def record_apply_unarmed(%Barkpark{} = bp) do
    bp
    |> Barkpark.update_status_changeset(%{
      apply_arming: "unarmed",
      apply_arming_checked_at: DateTime.utc_now()
    })
    |> Repo.update()
    |> auto_enqueue_on_unarmed("unarmed")
  end

  @doc """
  The RETRO-ARM WORKLIST: every box that autoupdate is supposed to reach and that
  has been MEASURED unarmed. Slug order (stable, so an operator can diff two runs).

  This is the pre-bless readiness read. Blessing a release while this list is
  non-empty means the rollout will walk straight into a 503 on each named box —
  which before `record_apply_unarmed/1` latched them off autoupdate for good, and
  which even now means the release simply cannot land there until somebody arms
  them. A caller that gates a bless on this SHOULD refuse, or at minimum name
  every row, rather than reporting a count.

  MEASURED-unarmed ONLY. A `nil` (unmeasured) box is NOT on this list — it may
  well be armed, and padding a readiness refusal with boxes nobody has asked
  would make the list unactionable, which is worse than no list.

  `autoupdate_paused` is deliberately NOT filtered out. A box already paused is
  the WORST case, not an excluded one: it is both unarmed and latched off, so it
  needs the arming AND the human resume, and an operator reading this list to
  prepare a bless must see it.
  """
  @spec unarmed_autoupdate_boxes() :: [Barkpark.t()]
  def unarmed_autoupdate_boxes do
    from(b in Barkpark,
      where: not is_nil(b.host) and b.host != "",
      where: b.suspended == false,
      where: b.autoupdate_enabled == true,
      where: is_nil(b.pinned_release),
      where: b.apply_arming == "unarmed",
      order_by: [asc: b.slug]
    )
    |> Repo.all()
  end

  @doc """
  Instances with a self-update currently IN FLIGHT — the rollout worker stamped
  `autoupdate_triggered_at` and is waiting for them to settle `current`. The
  staged rollout refuses to start a new instance while this list is non-empty
  (serial, health-gated). Oldest trigger first.
  """
  @spec autoupdate_in_flight() :: [Barkpark.t()]
  def autoupdate_in_flight do
    from(b in Barkpark,
      where: not is_nil(b.autoupdate_triggered_at),
      order_by: [asc: b.autoupdate_triggered_at]
    )
    |> Repo.all()
  end

  @doc """
  The NEXT instance eligible for an autoupdate, or nil. Eligible = live (`host`
  set) · not billing-suspended · reporting `behind` · `autoupdate_enabled` · not
  paused · not pinned · not already in flight · not MEASURED-unarmed. Oldest-behind
  first (a stable, fair order), so the rollout drains the most-stale instances
  first.

  With a `channel` ("prod" | "staging") the pick is confined to that channel —
  the canary-gated rollout (isu-w5.2) advances staging boxes before prod. With
  the default `nil`, the pick spans all channels.

  THE ARMING DISQUALIFICATION, AND WHY IT IS A DISQUALIFICATION AND NOT A PAUSE.
  A box whose `apply_arming` reads `"unarmed"` will answer the rollout's trigger
  POST with a 503 — that is the same `Runner.enabled?/0` false the arming probe
  already measured. Before this clause the worker's only answer to that 503 was
  `pause_autoupdate/1`, a flag NO code path clears (its sole `false` writer is a
  human PATCH on `/v1/barkparks/:id/autoupdate`), so a fleet-wide rollout against
  unarmed boxes latched every one of them off autoupdate permanently.

  The clause cannot simply be dropped from the 503 branch, because
  `order_by: update_checked_at` would re-pick the same unarmed box every tick
  forever and nothing else would ever advance. DISQUALIFYING it here is what
  makes a non-pausing 503 branch safe: the box leaves the candidate set without
  any flag a human must later clear, and it RE-ENTERS on its own the moment the
  hourly `UpdateStatusWorker` sweep reads `apply_enabled: true` off its admin
  route and `refresh_update_status/1` writes `apply_arming: "armed"` back. Entry
  and exit are both automatic; that is the whole point.

  `nil` IS NOT `"unarmed"`. The unmeasured third state (a pre-#12995 box, or one
  no sweep has read yet) stays ELIGIBLE — those boxes may well be armed, and
  disqualifying them would wedge the rollout for exactly the fleet this feature
  was built to serve. Note the explicit `is_nil/1` arm: SQL's `!=` is NULL, not
  true, on a NULL column, so `b.apply_arming != "unarmed"` ALONE would silently
  exclude every unmeasured box — the wedge this clause exists to avoid.
  """
  @spec next_autoupdate_candidate(nil | binary()) :: Barkpark.t() | nil
  def next_autoupdate_candidate(channel \\ nil) do
    base =
      from(b in Barkpark,
        where: not is_nil(b.host) and b.host != "",
        where: b.suspended == false,
        where: b.update_state == "behind",
        where: b.autoupdate_enabled == true,
        where: b.autoupdate_paused == false,
        where: is_nil(b.pinned_release),
        where: is_nil(b.autoupdate_triggered_at),
        where: is_nil(b.apply_arming) or b.apply_arming != "unarmed",
        order_by: [asc: b.update_checked_at],
        limit: 1
      )

    base
    |> maybe_filter_channel(channel)
    |> Repo.one()
  end

  defp maybe_filter_channel(query, nil), do: query
  defp maybe_filter_channel(query, channel), do: where(query, [b], b.channel == ^channel)

  @doc """
  Is the canary staging gate GREEN — i.e. may prod-channel boxes advance?
  (isu-w5.2). Fails OPEN: when NO staging-channel box is registered
  (staging.barkpark.cloud does not exist yet), prod advances normally. When
  staging boxes DO exist, the gate opens only once at least one of them has
  settled `current` on the latest release (`update_state == "current"` and
  `update_running_release == update_latest_release`). A staging box that is
  behind, in-flight, or paused-after-failure leaves the gate closed — it blocks
  every prod advancement until the canary proves the release clean.
  """
  @spec staging_gate_open?() :: boolean()
  def staging_gate_open? do
    staging = from(b in Barkpark, where: b.channel == "staging") |> Repo.all()

    case staging do
      [] ->
        true

      boxes ->
        Enum.any?(boxes, fn b ->
          b.update_state == "current" and not is_nil(b.update_running_release) and
            b.update_running_release == b.update_latest_release
        end)
    end
  end

  @doc """
  Is the fleet-wide autoupdate kill switch engaged? (isu-w5.2). When `true` the
  rollout worker performs settle bookkeeping but ADVANCES no new instance until
  an operator resumes. Reads-or-defaults the single `fleet_settings` row — an
  unseeded fleet is NOT halted.
  """
  @spec autoupdate_halted?() :: boolean()
  def autoupdate_halted? do
    fleet_settings().autoupdate_halted
  end

  @doc """
  Set (persist) the fleet-wide autoupdate kill switch. Upserts the single
  `fleet_settings` row; returns the persisted row.
  """
  @spec set_autoupdate_halted(boolean()) ::
          {:ok, FleetSettings.t()} | {:error, Ecto.Changeset.t()}
  def set_autoupdate_halted(halted) when is_boolean(halted) do
    fleet_settings()
    |> FleetSettings.changeset(%{autoupdate_halted: halted})
    |> Repo.insert_or_update()
  end

  # The single fleet_settings row, or an unpersisted default (autoupdate_halted
  # false) when the fleet has never toggled it — so reads never need a seed.
  defp fleet_settings do
    Repo.one(from(f in FleetSettings, limit: 1)) || %FleetSettings{autoupdate_halted: false}
  end

  @doc "Stamp an instance as in-flight (a self-update was just triggered for it)."
  @spec mark_autoupdate_triggered(Barkpark.t()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def mark_autoupdate_triggered(%Barkpark{} = bp) do
    bp
    |> Barkpark.autoupdate_trigger_changeset(%{autoupdate_triggered_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc "Clear the in-flight marker (the instance settled, or the wave was reaped)."
  @spec clear_autoupdate_triggered(Barkpark.t()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def clear_autoupdate_triggered(%Barkpark{} = bp) do
    bp
    |> Barkpark.autoupdate_trigger_changeset(%{autoupdate_triggered_at: nil})
    |> Repo.update()
  end

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
        # TOCTOU NOTE (intentional, fails closed): the ownership gate above
        # (`barkpark_in_team?`) reads the barkpark row, then this branch writes —
        # a concurrent `delete_barkpark/1` landing in that narrow check-to-write
        # window would insert against a now-missing FK target. This is NOT locked
        # or wrapped in a txn on purpose (improvement-only; no live defect): the
        # `assoc_constraint(:barkpark)` net on EnvVar.changeset (env_var.ex:95 —
        # the repo-wide convention agent_event/agent_token/provision_job/site all
        # carry) turns that lost race into `{:error, %Ecto.Changeset{}}` at
        # `Repo.insert_or_update` below. The cross-tenant/dangling write never
        # lands; the caller gets a changeset error, not a 500.
        #
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

  # A per-row reveal helper lived here and refused an `is_shown_once` row with
  # `{:error, :write_once}`. It was DELETED in wave 56 — not because write-once is
  # wrong, but because no production caller could ever reach the guard: it had zero
  # non-test callers, and the env-var HTTP surface is exactly three routes
  # (`GET /v1/env-vars`, which never returns values; POST; DELETE) with no reveal
  # route at all. The only thing that could make the refusal fire was the test that
  # asserted it. A guard that cannot lose is worse than no guard — it reads as
  # protection the system does not actually provide, and it makes the write-once
  # posture look enforced on a read path that does not exist. Write-once is still
  # enforced where a caller can actually hit it: `put_env_var/2` refuses a rewrite
  # of an `is_shown_once` row. If a reveal path is ever wanted, it arrives with the
  # route that needs it, and the guard becomes losable again.

  @doc """
  The resolved, DECRYPTED env map for a provisioned `barkpark`: its Team's
  team-scoped vars, with the instance's own `barkpark`-scoped vars layered on top
  (most-specific-wins). Keys are env var names, values are plaintext.

  Called at provision-claim time and folded into the Go worker's `claim_json`
  under the `env` key.

  RETRACTED ON REVIEW (wave 56): this paragraph used to open "This is the
  injection payload" and end "so the values reach the box's runtime env". It is
  not an injection payload and the values reach nothing.
  `internal/provisioner.JobSpec` declares no `env` field and every claim decode
  is a bare `json.Unmarshal`, so the key is silently dropped by the only process
  that could act on it. The console retracted the same claim in cch-w53-s1
  ("Values are not delivered to any instance yet"); `lib` was still asserting the
  opposite in two places, of which this was one. Building delivery is filed
  separately — until it exists, this function resolves a map nobody consumes.

  ALWAYS
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

  Single-active-token-per-scope invariant: minting SUPERSEDES the barkpark's
  prior live tokens of the SAME `scope`, revoking them in the SAME transaction as
  the new insert. S12c re-mints a `"report"` token on EVERY provision claim /
  stale-reclaim (web/router.ex `put_agent_token`), so without this the
  `agent_tokens` table grows an unbounded trail of never-revoked rows per box and
  a superseded credential stays valid. Revoke-then-insert is atomic: a crash can
  never leave the box with zero live tokens (old revoked, new never written) nor
  two (both live).

  `opts`:
    * `:expires_at` — a `DateTime` after which the token is invalid (default: no
      expiry).

  RULING (task-940e49f7300a8d1b, recorded after an independent review of PR
  #13251): `scope` is NOT an authorization boundary today — see the ruling on
  `verify_agent_token/1` below for why, and read that doc before minting a
  scope you intend to be narrower than the box's full agent surface. It WILL
  NOT be.

  Accumulation, decided in writing: minting a NEW scope for a barkpark does
  NOT revoke that barkpark's LIVE tokens of OTHER scopes (only same-scope
  supersession is atomic here) — `router_agent_runtime_test.exs` pins this as
  deliberate ("DISTINCT scope — mint_agent_token now supersedes a box's prior
  same-scope [token only]"), so two live differently-scoped tokens coexisting
  is intended, not a bug. It is ACCEPTABLE to leave as-is because, as of this
  ruling, exactly ONE scope ("report") is ever minted by production code
  (`web/router.ex`'s `put_agent_token`/`claim_json`) — there is no live
  accumulation happening today, only a latent risk. A future caller that mints
  a genuinely distinct scope for a box that already holds a live "report"
  token is RESPONSIBLE for one of: reusing "report", explicitly revoking the
  token(s) it means to replace via `revoke_agent_token/1`, or accepting that
  the box now presents multiple live credentials and designing for it
  on purpose. `AgentRetentionWorker` already bounds every DEAD token's
  lifetime (30-day grace past `revoked_at`/`expires_at`) — the open edge is
  LIVE, never-revoked, never-expired tokens of a scope nothing mints anymore,
  which today can only arise by hand (there is no such production caller).
  """
  @spec mint_agent_token(Barkpark.t() | binary(), String.t(), keyword()) ::
          {:ok, binary(), AgentToken.t()} | {:error, Ecto.Changeset.t()}
  def mint_agent_token(barkpark, scope, opts \\ []) do
    plaintext = generate_token()
    bp_id = barkpark_id(barkpark)
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    attrs = %{
      barkpark_id: bp_id,
      scope: scope,
      token_hash: AgentToken.hash_token(plaintext),
      expires_at: Keyword.get(opts, :expires_at)
    }

    Repo.transaction(fn ->
      # Revoke the barkpark's prior LIVE (never-revoked) same-scope tokens before
      # the new one lands, so exactly one active token of this scope survives.
      from(t in AgentToken,
        where: t.barkpark_id == ^bp_id and t.scope == ^scope and is_nil(t.revoked_at)
      )
      |> Repo.update_all(set: [revoked_at: now, updated_at: now])

      case %AgentToken{} |> AgentToken.changeset(attrs) |> Repo.insert() do
        {:ok, token} -> token
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, token} -> {:ok, plaintext, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Verify a presented `plaintext` agent token. Returns the owning `%Barkpark{}`
  when the token exists, is not revoked, and is not past `expires_at`; otherwise
  `nil`. Lookup is by hash — the plaintext is never stored to compare against.

  RULING (task-940e49f7300a8d1b, recorded after an independent review of PR
  #13251): this check is DELIBERATELY scope-blind — it filters hash, revoked,
  and expiry, and NEVER reads `scope`. Any live token for `barkpark` opens
  EVERY route behind `Auth.require_agent/2` for that box, regardless of the
  scope it was minted with. That is unchanged by this ruling; it is the
  finding this ruling accepts.

  Why NOT enforced: as of this ruling, `require_agent` gates
  `/v1/agent/*` (beat/space/commands/results), `/v1/builder/*`
  (jpf-w1-builder-identity), and `/v1/builder/sites/:id/env` — and every one
  of those routes is opened, in production, by the SAME single "report"-scope
  token the box mints at claim time and keeps on disk
  (`/etc/barkpark/agent.token`). There is no existing route→scope requirement
  matrix anywhere in this codebase to enforce; test suites mint whatever scope
  string is convenient ("runtime", "deploy", "report:health", …) because
  nothing reads it. Inventing a scoping scheme now, with no route that has
  ever needed one, would inject an untested authorization model rather than
  close a real gap — and could silently break the one production path (a
  "report" token failing a builder or agent-runtime check it has always
  passed) for zero measured benefit.

  Why ACCEPTABLE to leave scope-blind: `barkpark_id` is still the real
  boundary — every route re-derives `conn.assigns.current_barkpark` from the
  verified token and scopes its query to that barkpark alone
  (jpf-w1-builder-identity's box-scoping tests), so the worst case of this
  gap is intra-box privilege flattening (one box's own live token can reach
  every route that box's disk already has secrets for), never cross-tenant.

  The loaded-gun edge, stated plainly for the next person who reaches for
  `scope` as a control: a future mint of a WEAKER scope — intended to open
  fewer routes than the box's full agent surface — will NOT be narrowed by
  this function. If that need arrives, it must be built here (a route-level
  or plug-level allow-list checked against `scope`), not assumed to already
  exist. Until then, `scope` is descriptive metadata (which flow minted this
  token, for audit/debugging), not an authorization control — treat it as
  the former in any UI or log that surfaces it, never claim it as the latter.
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

  RULING (one-way-state census; template PR #13474 / #13551, the
  `autoupdate_paused` latch): REVOKING AN AGENT TOKEN IS UNRECOVERABLE WITHOUT
  RE-PROVISIONING THE BOX. Nothing in this repository clears `revoked_at` on an
  `AgentToken` — the only way a box gets a live one is `mint_agent_token/3` via
  `put_agent_token/2` inside a provision, resurrect, or support claim, and every
  one of those routes sits behind `Auth.require_worker` (the shared platform
  WORKER_TOKEN). There is no rotate route and no re-mint route at any auth level.
  The recovery cannot be automated even in principle: the only channel able to
  deliver a fresh token is the provision claim, and the box's own live channel is
  authenticated by the very token being revoked. The box keeps retrying the dead
  token forever, and after `AgentRetentionWorker`'s 30-day grace the row is
  deleted, erasing the evidence.

  So this is deliberately the ONLY agent-token revoker, and it is deliberately
  SINGULAR. A bulk sibling — `revoke_all_agent_tokens_for_user/1`, wired into
  `Accounts.update_user_password/4` and `reset_password_by_token/2` — used to
  exist and was removed: a routine password rotation by ANY member of ANY team
  (a role-blind join over `list_user_teams/1`) silently killed the agent token of
  every box those teams owned, taking down the health beat, `/v1/agent/*` and
  every `/v1/builder/*` route, with no surface saying why and no way back short
  of a re-provision. It also protected nothing — an agent-token plaintext is
  emitted to exactly one audience (a WORKER_TOKEN holder), never through a
  user-authenticated route, so an attacker holding the user's password never had
  it to lose.

  Before wiring this function to ANY automatic trigger, answer the question that
  matters for a one-way state: what clears it, and can that clearer run without a
  human? Here the answer is "a re-provision, and no." Reach for it only for a
  genuine single-box compromise, where destroying the box's credential is the
  point and the re-provision is accepted cost.
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

  ## Sites — hosted websites running co-located with a Barkpark.

  @doc """
  Create a Site under `barkpark`. The Site's `team_id` is taken from the
  Barkpark — sites can never belong to a different team than their box.

  site-spawner W1: a plaintext `:read_token` (the public-read-scoped content
  token a static build fetches with) is Vault-encrypted here and stored ONLY as
  `read_token_encrypted` ciphertext — the plaintext never touches the DB, exactly
  like the env blob. `kind` + the `bootstrap_*` dataset triple pass straight
  through the changeset.

  THE CREATE DOOR IS A CLAIM DOOR. `attrs.domains` goes straight into the
  changeset, so this path never calls `add_site_domain/2` and therefore ran NO
  collision test at all until `first_claimed_domain/2` was added below — not the
  site-vs-site one, and never the `custom_host` one. It now runs the same
  `hostname_claimed?/2` leaf the attach door runs; a domain already claimed
  anywhere in the hostname namespace fails the whole create with
  `{:error, :domain_taken}` (→ 409) and writes no row.

  Returns `{:ok, %Site{}}`, `{:error, :domain_taken}`, or
  `{:error, %Ecto.Changeset{}}`.
  """
  @spec create_site(Barkpark.t(), map()) ::
          {:ok, Site.t()} | {:error, :domain_taken} | {:error, Ecto.Changeset.t()}
  def create_site(%Barkpark{} = barkpark, attrs) do
    # site-spawner W5 (charter D47): mint the per-site content-publish webhook
    # secret BEFORE the insert so its ciphertext lands on the row; the plaintext is
    # carried out here to register on the box AFTER the row exists (the receiver URL
    # needs the site id). A container / unbound site mints nothing.
    {content_secret, attrs} = maybe_mint_content_secret(attrs)

    # AUTHORITATIVE tenant identity: a Site's box (`barkpark_id`) and team
    # (`team_id`) are derived from the `%Barkpark{}` argument, NEVER from caller
    # attrs. Map.put (not put_new) so a client-supplied `:barkpark_id`/`:team_id`
    # in attrs can never win — the safety lives in THIS context fn, not in the
    # router's fixed-allowlist. Mirrors put_team_id/2 (:5328) and
    # create_deployment's `Map.put(attrs, :site_id, ...)`. String-key variants are
    # dropped first so a stray `"barkpark_id"` cannot both survive and collide with
    # the atom key (a mixed-key changeset cast would raise).
    prepared =
      attrs
      |> put_site_read_token()
      |> Map.drop(["barkpark_id", "team_id"])
      |> Map.put(:barkpark_id, barkpark.id)
      |> Map.put(:team_id, barkpark.team_id)

    # THE SECOND CLAIM DOOR. `POST /v1/sites` writes `domains` straight through,
    # so fixing `add_site_domain/2` alone would be theatre — an attacker would
    # simply CREATE the site with the stolen hostname instead of attaching it
    # afterwards. Same leaf, same verdict, before any row exists.
    case first_claimed_domain(prepared, barkpark) do
      nil ->
        case %Site{} |> Site.changeset(prepared) |> Repo.insert() do
          {:ok, site} ->
            # Best-effort: register the dataset-scoped webhook on the box so a publish
            # fires the CP receiver. NEVER fails the create — the site row is the truth;
            # a box that is not yet live (or refuses) just means auto-rebuild is wired
            # on the next successful registration path. Fires only for a live static
            # site with a bootstrap_dataset (charter D42/D47).
            _ = maybe_register_content_webhook(barkpark, site, content_secret)
            {:ok, site}

          {:error, _cs} = error ->
            error
        end

      _taken ->
        {:error, :domain_taken}
    end
  end

  # The first domain in a create's attrs already claimed elsewhere in the
  # hostname namespace, or nil. NO self-exclusions are passed: the site does not
  # exist yet (nothing to exclude on the site side), and its own box's
  # `custom_host` / provisioning FQDN is still a SECOND upstream that one
  # hostname cannot also route to — exactly the rule `add_site_domain/2` applies.
  # Accepts atom or string keys (the router sends atoms, the HTTP-mutate path
  # strings) and normalises with the ONE `normalize_domain/1` the guard and the
  # ask-gate share, so `Example.com` in a create body collides just as it does on
  # attach.
  defp first_claimed_domain(attrs, %Barkpark{team_id: team_id}) do
    (Map.get(attrs, :domains) || Map.get(attrs, "domains") || [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_domain/1)
    |> Enum.find(&hostname_claimed?(&1, team_id: team_id))
  end

  # Mint + Vault-encrypt the content-publish secret when this is a content-bound
  # site. Returns `{plaintext | nil, attrs}` — the plaintext travels to the
  # box registration; only the ciphertext is folded into the insert attrs. Accepts
  # atom or string keys (the router sends atoms, the HTTP-mutate path strings).
  #
  # stw9 (charter D56): `kind` widened from `"static"` ONLY to `static | node`. A
  # node site (the Next.js search demo) fetches its content from the box exactly
  # like a static one and just serves it via SSR — the content BINDING, not the
  # serving mode, is what makes publish-to-live meaningful. While this read
  # `kind == "static"`, every node site minted NO secret, so its per-site receiver
  # 404'd every delivery (indistinguishable from an unknown site) and content-auto
  # was structurally impossible for the flagship demo. A `container` site is still
  # excluded: it has no content binding at all.
  defp maybe_mint_content_secret(attrs) do
    kind = Map.get(attrs, :kind) || Map.get(attrs, "kind")
    dataset = Map.get(attrs, :bootstrap_dataset) || Map.get(attrs, "bootstrap_dataset")

    if kind in @content_bound_kinds and is_binary(dataset) and dataset != "" do
      secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      {secret, Map.put(attrs, :content_webhook_secret_encrypted, Vault.encrypt(secret))}
    else
      {nil, attrs}
    end
  end

  # Register ONE dataset-scoped webhook on the box (via the admin-token relay — the
  # `wire_site_url` prior art) pointed at THIS site's content-publish receiver, so
  # a publish on the bound dataset fires the CP auto-deploy. events =
  # {publish,unpublish,delete} (charter D43 — the three lifecycle actions that
  # touch the PUBLISHED row). Best-effort by contract; the caller ignores the
  # result. Skips a nil secret (container/unbound) and a non-live box.
  defp maybe_register_content_webhook(_barkpark, _site, nil), do: :noop

  defp maybe_register_content_webhook(%Barkpark{} = barkpark, %Site{} = site, secret)
       when is_binary(secret),
       do: do_ensure_content_webhook(barkpark, site, secret, :create)

  @doc """
  IDEMPOTENTLY ensure `site`'s content-publish webhook exists on its box, pointed
  at this site's per-site receiver, ACTIVE, and — when the row is freshly created —
  carrying this site's own secret.

  This is the backfill/repair entry point (`create_site/2` calls the same code
  path inline for a fresh site). Safe to call any number of times: it LISTS the
  box's webhooks for the bound dataset first and matches
  `site-autodeploy-<site.id>` BY NAME —

    * found    → `PUT /v1/webhooks/<dataset>/<id>` (re-point url/events and set
      `active: true` — the box folds FULL re-enable semantics into that write:
      zeroed failure streak, cleared auto-disable stamps. The box deliberately
      DROPS `secret` on update — rotation goes only through its rotate verb — so
      an existing row keeps its stored secret, which this same reconciler minted),
    * absent   → `POST /v1/webhooks/<dataset>` (create, with the secret),
    * unknown  → (the list read failed) on the BACKFILL path this is `:error`,
      never a write: "I could not look" must not authorize a possibly-duplicating
      POST (the law at `find_content_webhook/3`). Only the CREATE path — a fresh
      site whose name cannot exist on any box yet — still falls back to `POST`,
      where duplication is impossible and best-effort beats a site that never
      rebuilds on publish.

  `webhooks.name` has NO unique constraint on the box, so a blind re-POST — what
  this used to be — silently DUPLICATES the row on every backfill run, and every
  duplicate delivers the same payload again. List-then-create-by-name is what
  makes registration repeatable.

  Re-enable tradeoff, made deliberately: the PUT overrides a human who disabled
  the hook by hand. This runs only on site create and EXPLICIT backfill — never
  on any schedule — so a repair run asserting "this site's auto-deploy hook is
  live" is the operator's intent.

  Returns `:ok` (registered/updated), `:noop` (nothing to register — no secret,
  no dataset, box not live) or `:error` (the box refused, or the backfill could
  not read the list; logged). NEVER raises and never touches the Site row — the
  row is the truth, this is reconciliation.
  """
  @spec ensure_content_webhook(Barkpark.t(), Site.t()) :: :ok | :noop | :error
  def ensure_content_webhook(%Barkpark{} = barkpark, %Site{} = site) do
    case reveal_site_content_secret(site) do
      {:ok, secret} when is_binary(secret) ->
        do_ensure_content_webhook(barkpark, site, secret, :backfill)

      _ ->
        :noop
    end
  end

  defp do_ensure_content_webhook(%Barkpark{} = barkpark, %Site{} = site, secret, mode)
       when is_binary(secret) and mode in [:create, :backfill] do
    with box_url when is_binary(box_url) and box_url != "" <- barkpark.url,
         dataset when is_binary(dataset) and dataset != "" <- site.bootstrap_dataset,
         url when is_binary(url) <- content_receiver_url(site) do
      # The box's webhook changeset validate_required([:name, :url]) — omitting
      # `name` 422s ("name can't be blank") and the registration silently fails,
      # so the site never auto-rebuilds on publish. Name it after the site — the
      # name is ALSO this reconciler's only identity key (see the moduledoc).
      name = content_webhook_name(site)

      # `active: true` is the REPAIR half of reconciliation: guerrilla's rows were
      # all auto-disabled, and a PUT without it returns 200 while content-auto
      # stays dead — the reconciler reporting :ok on the exact state it was built
      # to fix. On POST the box defaults to active anyway; on PUT false→true it
      # zeroes the failure streak and clears the auto-disable stamps in the same
      # write. `secret` rides along for the POST branch; the box drops it on PUT.
      #
      # `types` is the DOC-TYPE FILTER the box already honours and nobody set
      # (Webhooks.active_webhooks_for/4 matches `types = '{}' OR types @> [type]`
      # — an EMPTY array means MATCH EVERYTHING). Every site-autodeploy row on
      # guerrilla carried `{}`, so all five sites rebuilt on EVERY mutation in a
      # shared dataset: of 75,922 deliveries since 2026-07-26, 68,523 (90.3%)
      # were `task` writes — this repo's own bp ledger rebuilding five demo
      # websites — against 7,109 (9.4%) papers. Sending the site's OWN doc_type
      # (the type its build actually reads, baked into BARKPARK_DOC_TYPE) cuts
      # enqueues ~80-88%, which is also the 409 fix: build p90 is 15.0s under
      # 20 deploys/hr but 144.8s over 120/hr against a 60s debounce, so the
      # collision is a self-inflicted congestion collapse fuelled by task noise.
      #
      # It lives in the SHARED body, not just the POST branch, deliberately:
      # `Webhooks.update_webhook/2` casts only the keys PRESENT in the body, so
      # a types omitted from the PUT survives untouched — which would leave a
      # site whose doc_type LATER CHANGES filtered on its old type forever.
      # Reconciliation must repair the array, not just seed it.
      #
      # The honest cost: the flagship templates also fetch /v1/graph for a
      # DECORATIVE all-types background, so `task` nodes really are part of that
      # corpus and it becomes eventually-stale (the hourly TemplateFreshnessWorker
      # covers the drift). The site's PRIMARY corpus — allDocs at env.docType and
      # the search seed — stays exactly as fresh.
      body = %{
        name: name,
        events: ["publish", "unpublish", "delete"],
        types: content_webhook_types(site),
        url: url,
        secret: secret,
        active: true
      }

      base = "/v1/webhooks/#{URI.encode(dataset)}"

      case find_content_webhook(barkpark, dataset, name) do
        {:ok, id} ->
          relay_webhook_write(barkpark, site, :put, base <> "/" <> URI.encode(id), body)

        :absent ->
          relay_webhook_write(barkpark, site, :post, base, body)

        :unknown when mode == :create ->
          # A fresh site's name cannot exist on the box yet, so POST-on-unknown
          # cannot duplicate here — and registration is best-effort on create.
          relay_webhook_write(barkpark, site, :post, base, body)

        :unknown ->
          Logger.warning(
            "content-publish webhook backfill for site #{site.id} aborted: " <>
              "box webhook list unreadable — refusing a possibly-duplicating POST"
          )

          :error
      end
    else
      _ -> :noop
    end
  end

  defp relay_webhook_write(%Barkpark{} = barkpark, %Site{} = site, method, path, body) do
    case relay_admin(barkpark, method, path, body) do
      {:ok, status, _resp} when status in 200..299 ->
        :ok

      other ->
        Logger.warning(
          "content-publish webhook registration for site #{site.id} did not take: #{inspect(other)}"
        )

        :error
    end
  end

  # Deregister `site`'s box webhook — the counterpart of the registration above,
  # called on delete. WITHOUT this, a deleted site leaves an ORPHAN endpoint whose
  # every delivery 404s against a receiver that no longer resolves; the box counts
  # consecutive failures and AUTO-DISABLES the endpoint. Observed on guerrilla:
  # 6 of 8 `site-autodeploy-*` rows were orphans of deleted sites, and they are the
  # failure generator that made content-auto look dead fleet-wide.
  #
  # Best-effort and never blocks the delete: the CP row is the truth, and a box
  # that is down simply keeps an orphan we can reap later (the same reconciler
  # above finds it by name).
  defp deregister_content_webhook(%Site{} = site) do
    with dataset when is_binary(dataset) and dataset != "" <- site.bootstrap_dataset,
         %Barkpark{} = barkpark <- get_barkpark(site.barkpark_id),
         {:ok, id} <- find_content_webhook(barkpark, dataset, content_webhook_name(site)) do
      path = "/v1/webhooks/#{URI.encode(dataset)}/#{URI.encode(id)}"

      case relay_admin(barkpark, :delete, path, nil) do
        {:ok, status, _resp} when status in 200..299 ->
          :ok

        other ->
          Logger.warning(
            "content-publish webhook deregistration for site #{site.id} did not take: #{inspect(other)}"
          )

          :error
      end
    else
      _ -> :noop
    end
  end

  # The box-side identity of a site's content-publish webhook. ONE definition —
  # registration, reconciliation and deregistration must agree byte-for-byte or
  # the "find by name" lookup silently misses and duplicates instead.
  defp content_webhook_name(%Site{id: id}), do: "site-autodeploy-#{id}"

  # The doc-type filter for this site's box webhook: exactly the ONE type its
  # build reads. A site with no doc_type (a row predating the column) falls back
  # to `[]` — the box's MATCH-EVERYTHING sentinel, i.e. today's behaviour — so a
  # missing binding can never silently filter a site's real content away.
  defp content_webhook_types(%Site{doc_type: type}) when is_binary(type) do
    case String.trim(type) do
      "" -> []
      t -> [t]
    end
  end

  defp content_webhook_types(%Site{}), do: []

  # Look `name` up in the box's webhook list for `dataset`.
  #
  #   {:ok, id}  — exactly this row exists
  #   :absent    — the box answered with a list and this name is not in it
  #   :unknown   — the list could not be read (box down / non-2xx / no `webhooks`
  #                key). DELIBERATELY distinct from :absent: callers must not
  #                treat "I could not look" as "it is not there" when the
  #                consequence is a destructive or duplicating write.
  defp find_content_webhook(%Barkpark{} = barkpark, dataset, name) do
    case relay_admin(barkpark, :get, "/v1/webhooks/#{URI.encode(dataset)}", nil) do
      {:ok, status, %{"webhooks" => hooks}} when status in 200..299 and is_list(hooks) ->
        case Enum.find(hooks, &(is_map(&1) and Map.get(&1, "name") == name)) do
          %{"id" => id} when is_binary(id) and id != "" -> {:ok, id}
          _ -> :absent
        end

      _ ->
        :unknown
    end
  end

  # The public URL the box POSTs a content-publish delivery to. Per-site receiver
  # (charter D45): `<control-plane public origin>/v1/sites/webhooks/content-publish/
  # <site_id>`. The origin is config-driven (`:public_url`, PUBLIC_URL /
  # CONTROL_PLANE_URL in prod) so it is a genuine cross-host public call
  # (guerrilla → barkpark.cloud), never loopback.
  defp content_receiver_url(%Site{id: id}) do
    base =
      Application.get_env(:barkpark_cloud, :public_url, "https://api.barkpark.cloud")
      |> to_string()
      |> String.trim_trailing("/")

    base <> "/v1/sites/webhooks/content-publish/#{id}"
  end

  # site-spawner W1: fold a plaintext read token into the changeset as its
  # Vault-encrypted ciphertext (the same at-rest seam as `set_site_env/2`).
  # Accepts either atom or string key; a blank/absent token leaves attrs
  # untouched (a container site has no content read token). The plaintext key is
  # dropped so it can never be cast onto the row.
  defp put_site_read_token(attrs) do
    token = Map.get(attrs, :read_token) || Map.get(attrs, "read_token")

    case token do
      t when is_binary(t) and t != "" ->
        attrs
        |> Map.drop([:read_token, "read_token"])
        |> Map.put(:read_token_encrypted, Vault.encrypt(t))

      _ ->
        attrs
    end
  end

  @doc """
  Decrypt a Site's public-read content token. `{:ok, token}` when set,
  `{:ok, nil}` when the site carries none (every container site), or `:error`
  when the ciphertext fails to decrypt (`Vault.decrypt/1` fails closed).
  """
  @spec reveal_site_read_token(Site.t()) :: {:ok, String.t() | nil} | :error
  def reveal_site_read_token(%Site{read_token_encrypted: nil}), do: {:ok, nil}

  def reveal_site_read_token(%Site{read_token_encrypted: ciphertext}),
    do: Vault.decrypt(ciphertext)

  ## ── The site read token's LIFECYCLE half (ssw8, charter D40) ───────────────
  ##
  ## `mint_public_read_token/5` above is the birth. Until this block there was no
  ## death: `grep -n revoke registry.ex` hit only the agent-token and app-token
  ## surfaces, and `delete_site/1` was exactly
  ## `_ = deregister_content_webhook(site); Repo.delete(site)`. The measured cost
  ## on guerrilla was six live `site-read-*` credentials for sites that no longer
  ## exist — never-expiring public-read grants into a live dataset.
  ##
  ## The substrate needs no new box route. The instance already exposes, on the
  ## SAME workspace-scoped block the mint uses:
  ##
  ##   GET    /w/:ws/p/:proj/v1/tokens       -> %{"tokens" => [%{"id","label","revoked_at",…}]}
  ##   DELETE /w/:ws/p/:proj/v1/tokens/:id   -> revoke (idempotent, cross-tenant railed)
  ##
  ## and labels are DETERMINISTIC (`site-read-<slug>`), so a site's credential is
  ## findable by label with no CP-side id mapping — which matters because the CP
  ## stores only the ciphertext, never the token's box-side id.

  @doc """
  The box-side identity of a site's public-read content token: `site-read-<slug>`.

  ONE definition. The mint (`POST /v1/sites` -> `mint_site_read_token/3`), the
  revoke on delete, and the orphan sweep must agree byte-for-byte or the
  find-by-label lookup silently misses — the same law `content_webhook_name/1`
  states for webhooks, and for the same reason.
  """
  @spec site_read_token_label(Site.t() | String.t()) :: String.t()
  def site_read_token_label(%Site{slug: slug}), do: site_read_token_label(slug)
  def site_read_token_label(slug) when is_binary(slug), do: "site-read-#{slug}"

  @doc """
  Revoke `site`'s public-read content token on its box — the counterpart of the
  mint at create, called by `delete_site/1` BEFORE the row (and with it the
  pointer to what to revoke) is gone.

    * `:noop`   — no content binding, so no credential was ever minted for it
    * `:ok`     — the box confirms no LIVE token by this site's label remains
    * `:error`  — the credential could NOT be confirmed dead; treat it as live

  `:absent` from the lookup collapses to `:ok` on purpose: a label the box does
  not list, or lists only as already-revoked, is a credential that cannot
  authenticate — the outcome this function exists to produce. What must NEVER
  collapse to `:ok` is `:unknown` (the box did not answer, or answered something
  we cannot read), because "I could not look" is not "it is not there".
  """
  @spec revoke_site_read_token(Site.t()) :: :ok | :noop | :error
  def revoke_site_read_token(%Site{} = site) do
    with ws when is_binary(ws) and ws != "" <- site.bootstrap_workspace,
         proj when is_binary(proj) and proj != "" <- site.bootstrap_project,
         %Barkpark{} = barkpark <- get_barkpark(site.barkpark_id) do
      label = site_read_token_label(site)

      case find_workspace_token(barkpark, ws, proj, label) do
        {:ok, id} ->
          revoke_workspace_token(barkpark, ws, proj, id, label)

        :absent ->
          :ok

        :unknown ->
          Logger.warning(
            "site read token revoke for site #{site.id}: could not read #{barkpark.slug}'s " <>
              "token inventory for #{ws}/#{proj} — #{label} may still be live"
          )

          :error
      end
    else
      _ -> :noop
    end
  end

  @doc """
  Revoke ONE workspace token on `barkpark` by its box-side id — the operator
  action behind the orphan sweep below. `:ok` only on a 2xx from the box.

  Deliberately NOT a bulk verb, and deliberately id-addressed: the sweep hands a
  human a list, the human names the row. See
  `Mix.Tasks.BarkparkCloud.SiteReadTokens`, which re-derives the orphan set at
  revoke time and refuses any id that is not in it — so that tool can never kill
  a LIVE site's credential.
  """
  @spec revoke_workspace_token(Barkpark.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | :error
  def revoke_workspace_token(%Barkpark{} = barkpark, workspace, project, token_id, label \\ "") do
    path =
      "/w/#{URI.encode(workspace)}/p/#{URI.encode(project)}/v1/tokens/#{URI.encode(token_id)}"

    case relay_admin(barkpark, :delete, path, nil) do
      {:ok, status, _resp} when status in 200..299 ->
        :ok

      other ->
        # A 404 is NOT read as "already gone". The box answers 404 both for a
        # token that holds no seat here AND from a box whose build predates the
        # revoke route entirely — and the second reading means the credential is
        # very much alive. Calling that `:ok` would be the exact false green this
        # row exists to remove.
        Logger.warning(
          "site read token revoke on #{barkpark.slug} did not take for #{label} " <>
            "(#{workspace}/#{project}, id #{token_id}): #{inspect(other)}"
        )

        :error
    end
  end

  @doc """
  THE CLEANUP PATH: every LIVE `site-read-*` credential on `barkpark` whose site
  no longer exists.

  A fix that only revokes on future deletes leaves today's orphans live forever —
  nothing on the box expires a `public-read` token and nothing in this repo ever
  listed them. This is the read that finds them.

  Method: collect every `(workspace, project)` pair this box is known to serve
  content under (its own bootstrap scope plus every live site's), list each
  scope's tokens, keep the ones that are LIVE (`revoked_at` null) and labelled
  `site-read-<slug>`, and report those whose `<slug>` names no site on this box.

  Returns `{:ok, orphans}` where each orphan is

      %{barkpark_slug:, workspace:, project:, id:, label:, site_slug:,
        inserted_at:, last_used_at:}

  or `{:error, :no_scope}` when the box has no workspace/project to look under,
  or `{:error, :unreadable}` when NO scope's inventory could be read — never an
  empty list, because "I could not look" must not render as "there are none".

  READ-ONLY BY CONSTRUCTION. It revokes nothing. Killing a live credential is an
  owner decision (a slug that names no CP site could still be a hand-minted token
  someone depends on), so this reports and `revoke_workspace_token/5` acts.
  """
  @spec orphan_site_read_tokens(Barkpark.t()) ::
          {:ok, [map()]} | {:error, :no_scope | :unreadable}
  def orphan_site_read_tokens(%Barkpark{} = barkpark) do
    sites = list_sites(barkpark)
    live_slugs = MapSet.new(sites, & &1.slug)

    scopes =
      [{barkpark.bootstrap_workspace, barkpark.bootstrap_project}]
      |> Enum.concat(Enum.map(sites, &{&1.bootstrap_workspace, &1.bootstrap_project}))
      |> Enum.filter(fn {ws, proj} ->
        is_binary(ws) and ws != "" and is_binary(proj) and proj != ""
      end)
      |> Enum.uniq()

    case scopes do
      [] ->
        {:error, :no_scope}

      scopes ->
        results =
          Enum.map(scopes, fn {ws, proj} ->
            {ws, proj, list_workspace_tokens(barkpark, ws, proj)}
          end)

        if Enum.all?(results, fn {_ws, _proj, r} -> r == :unknown end) do
          {:error, :unreadable}
        else
          orphans =
            for {ws, proj, {:ok, tokens}} <- results,
                token <- tokens,
                orphan = site_read_orphan(barkpark, ws, proj, token, live_slugs),
                orphan != nil,
                do: orphan

          {:ok, orphans}
        end
    end
  end

  # One box token row -> an orphan record, or nil when it is not one. Three
  # independent reasons a row is NOT an orphan, each of which has to be checked
  # or the sweep reports a credential that is fine (and a human revokes it): it
  # is already revoked; it is not a site-read label at all; its slug names a site
  # that still exists.
  defp site_read_orphan(%Barkpark{} = barkpark, ws, proj, token, live_slugs) when is_map(token) do
    id = Map.get(token, "id")
    label = Map.get(token, "label")

    with true <- is_binary(id) and id != "",
         true <- is_binary(label),
         true <- is_nil(Map.get(token, "revoked_at")),
         {:ok, slug} <- site_read_slug(label),
         false <- MapSet.member?(live_slugs, slug) do
      %{
        barkpark_slug: barkpark.slug,
        workspace: ws,
        project: proj,
        id: id,
        label: label,
        site_slug: slug,
        inserted_at: Map.get(token, "inserted_at"),
        last_used_at: Map.get(token, "last_used_at")
      }
    else
      _ -> nil
    end
  end

  defp site_read_orphan(_barkpark, _ws, _proj, _token, _live_slugs), do: nil

  # The INVERSE of `site_read_token_label/1`. Anchored at the front and requiring
  # a non-empty remainder, so a label that merely CONTAINS the prefix is not read
  # as a site credential.
  defp site_read_slug("site-read-" <> slug) when slug != "", do: {:ok, slug}
  defp site_read_slug(_), do: :error

  # Read `barkpark`'s token inventory for one workspace scope.
  #
  #   {:ok, tokens} — the box answered with a list (possibly empty)
  #   :unknown      — the box did not answer, or answered something unreadable
  #
  # The two are DELIBERATELY distinct, for the same reason `find_content_webhook/3`
  # separates them: every consumer here is one step away from a destructive write.
  defp list_workspace_tokens(%Barkpark{} = barkpark, workspace, project) do
    path = "/w/#{URI.encode(workspace)}/p/#{URI.encode(project)}/v1/tokens"

    case relay_admin(barkpark, :get, path, nil) do
      {:ok, status, %{"tokens" => tokens}} when status in 200..299 and is_list(tokens) ->
        {:ok, tokens}

      _ ->
        :unknown
    end
  end

  # Look one LABEL up in `barkpark`'s token inventory for a workspace scope.
  #
  #   {:ok, id}  — a LIVE (never-revoked) token carries this label
  #   :absent    — the box answered with a list and no live token carries it
  #   :unknown   — the inventory could not be read
  #
  # `revoked_at` is part of the predicate: an already-revoked row is not
  # something to revoke again, and reporting it as `{:ok, id}` would turn a
  # correctly-dead credential into a spurious box call whose 404 we would then
  # (correctly) refuse to call success.
  defp find_workspace_token(%Barkpark{} = barkpark, workspace, project, label) do
    case list_workspace_tokens(barkpark, workspace, project) do
      {:ok, tokens} ->
        match =
          Enum.find(tokens, fn t ->
            is_map(t) and Map.get(t, "label") == label and is_nil(Map.get(t, "revoked_at"))
          end)

        case match do
          %{"id" => id} when is_binary(id) and id != "" -> {:ok, id}
          _ -> :absent
        end

      :unknown ->
        :unknown
    end
  end

  @doc """
  site-spawner W6 (charter D51): persist the Cloudflare-in-front edge binding on
  `site` — the seam the DNS writer (S4) and the domain-status rung (S5) bind to.

  Writes through the NARROW `Site.cf_binding_changeset/2` (containment: only the
  CF columns move; it can never rename or re-team the site), inside a transaction
  so the multi-column edge binding (domain + zone + record + serving_mode +
  tls_mode) lands atomically or not at all — a half-persisted binding (e.g. a
  serving_mode flipped to `cf_proxied` without its `cf_record_id`) would leave
  the box's TLS render and the status rung reading an inconsistent row.

  `attrs` carries any subset of the CF fields; the two mode enums are
  inclusion-validated, so a bad value is `{:error, changeset}`, never a bad row.
  With no CF account connected NOTHING calls this, so the standalone path is
  untouched and the row keeps its `direct`/`on_demand` defaults (charter D58).

  Returns `{:ok, %Site{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  @spec set_cf_binding(Site.t(), map()) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def set_cf_binding(%Site{} = site, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      case site |> Site.cf_binding_changeset(attrs) |> Repo.update() do
        {:ok, updated} -> updated
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  site-spawner W6 (charter D51): read `site`'s Cloudflare edge binding as a plain
  map — the reader the DNS writer and the domain-status rung resolve mode from
  (never the resolved IP, charter D56). A pure-standalone site returns its
  `direct`/`on_demand` defaults with nil CF handles.
  """
  @spec cf_binding(Site.t()) :: %{
          cf_domain: String.t() | nil,
          cf_zone_id: String.t() | nil,
          cf_record_id: String.t() | nil,
          serving_mode: String.t(),
          tls_mode: String.t(),
          cf_cert_path: String.t() | nil,
          cf_key_path: String.t() | nil
        }
  def cf_binding(%Site{} = site) do
    %{
      cf_domain: site.cf_domain,
      cf_zone_id: site.cf_zone_id,
      cf_record_id: site.cf_record_id,
      serving_mode: site.serving_mode,
      tls_mode: site.tls_mode,
      cf_cert_path: site.cf_cert_path,
      cf_key_path: site.cf_key_path
    }
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

  @doc """
  Every content-bound site that has been deployed at least once — the population
  `BarkparkCloud.Sites.TemplateFreshnessWorker` sweeps.

  "Deployed at least once" (`current_deployment_id` is set) is deliberate: a site
  that has never gone live has nothing to keep FRESH, and enqueueing its first
  build from a cron would deploy sites nobody asked for. Ordered oldest-first so
  the sweep is stable across ticks (the `:site_deploy` queue is concurrency 1).
  """
  @spec list_deployed_content_sites() :: [Site.t()]
  def list_deployed_content_sites do
    Site
    |> where([s], s.kind in ^@content_bound_kinds)
    |> where([s], not is_nil(s.current_deployment_id))
    |> where([s], not is_nil(s.bootstrap_dataset) and s.bootstrap_dataset != "")
    |> order_by([s], asc: s.inserted_at)
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
  Add `domain` to a Site's `domains` array. Domains are normalized (lower-cased,
  trimmed, trailing-dot stripped) and deduplicated.

  A hostname resolves to exactly ONE owning surface fleet-wide. Adding a domain
  already claimed anywhere in that namespace is rejected with
  `{:error, :domain_taken}` (→ 409) BEFORE it can reach the on-demand-TLS
  ask-gate. This closes the cross-team domain collision / takeover vector:
  without it two teams could both register `example.com`, the ask-gate would
  answer 200 for both, and cert issuance / DNS pointing became ambiguous (team B
  could claim a domain team A points DNS at).

  The collision test is `hostname_claimed?/2` — the SAME leaf `set_custom_host/2`
  calls, so the two claim doors cannot drift apart again. It was site-vs-site
  ONLY until then, which is precisely how the asymmetry survived:
  `custom_host_taken?/2` consulted Site domains, but nothing consulted
  `barkparks.custom_host` from this side, so a plain member could attach another
  team's live hostname to a site they controlled.

  Legit edges preserved:

    * Idempotent — a site re-adding a domain it already owns is a no-op `{:ok, site}`.
    * Apex ≠ subdomain — `example.com` and `www.example.com` are distinct names and
      do not collide (normalization only case-folds/trims, it does not collapse labels).
    * Reclaimable — a domain freed via `remove_site_domain/2` can later be claimed
      by another site.

  Returns `{:ok, site}`, `{:error, :domain_taken}`, or a validation
  `{:error, changeset}` for a malformed domain.
  """
  @spec add_site_domain(Site.t(), String.t()) ::
          {:ok, Site.t()} | {:error, :domain_taken} | {:error, Ecto.Changeset.t()}
  def add_site_domain(%Site{domains: existing} = site, domain) when is_binary(domain) do
    norm = normalize_domain(domain)

    cond do
      # Idempotent: this site already owns the normalized domain.
      norm in existing ->
        {:ok, site}

      # Claimed anywhere else in the ONE hostname namespace — another site
      # (any team), a barkpark's `custom_host`, a foreign team's parent domain,
      # or a live provisioning FQDN. Reject before the ask-gate can answer 200
      # for two owners. Until this called `hostname_claimed?/2` it tested SITES
      # ONLY, so a site could take a hostname another team already served as its
      # `custom_host` — and no route existed to take it back.
      hostname_claimed?(norm, except_site_id: site.id, team_id: site.team_id) ->
        {:error, :domain_taken}

      true ->
        new_domains = Enum.uniq(existing ++ [norm])

        # The DB-level uniqueness trigger (add_domain_cross_site_uniqueness
        # migration) is the race backstop between the check above and this write;
        # it raises a unique_violation, which we translate to the same friendly
        # {:error, :domain_taken} rather than a 500.
        try do
          site
          |> Site.changeset(%{domains: new_domains})
          |> Repo.update()
        rescue
          e in Postgrex.Error ->
            if e.postgres[:code] == :unique_violation do
              {:error, :domain_taken}
            else
              reraise e, __STACKTRACE__
            end
        end
    end
  end

  @doc "Remove `domain` from a Site's `domains` array. No-op if absent."
  @spec remove_site_domain(Site.t(), String.t()) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def remove_site_domain(%Site{domains: existing} = site, domain) when is_binary(domain) do
    norm = normalize_domain(domain)
    new_domains = Enum.reject(existing, &(&1 == norm))

    site
    |> Site.changeset(%{domains: new_domains})
    |> Repo.update()
  end

  # Case-folded, trimmed, trailing-dot-stripped — the ONE normalization used for
  # BOTH the cross-site uniqueness guard and the ask-gate lookup, so `Example.com`
  # and `example.com` collide. Mirrors Site.normalize_domain/1 (the stored form).
  defp normalize_domain(d) when is_binary(d) do
    d |> String.downcase() |> String.trim() |> String.trim_trailing(".")
  end

  # ── ONE hostname namespace, ONE predicate ──────────────────────────────
  #
  # A hostname answers on exactly ONE surface across our boxes. TWO doors can
  # claim one: a Site's `domains` array (`add_site_domain/2` on attach,
  # `create_site/2` on create) and a barkpark's `custom_host`
  # (`set_custom_host/2`). Until this leaf existed the two doors ran DIFFERENT
  # collision tests — four surfaces on the custom_host side, other-sites-only on
  # the site side — and every hardening commit widened ONE of them (#11708 added
  # the provisioning-FQDN leg, #11785 trimmed its SQL; neither touched the site
  # side). A second copy would drift the same way, so both doors now call DOWN
  # into this one. The merge is legal because both callers live in THIS module:
  # neither predicate has to depend on the other, and nothing calls upward.
  #
  # `opts` carry the SELF-EXCLUSIONS — the only thing the two doors legitimately
  # differ on:
  #
  #   * `:except_site_id`     — the site doing the claiming; its own array is not
  #     a conflict with itself. `nil` on the custom_host door: a barkpark is
  #     never a Site, so every site row there is somebody else's surface.
  #   * `:except_barkpark_id` — the barkpark doing the claiming; re-attaching the
  #     host you already answer on is an idempotent no-op, not a conflict. `nil`
  #     on the site door — deliberately: a Site and its own box are still two
  #     upstreams and one hostname cannot route to both. That is exactly the
  #     strictness the custom_host door has always applied in the other direction
  #     (its Site leg excludes no site, not even a sibling on the same box), so
  #     making the site door strict is symmetry, not a new rule.
  #   * `:team_id`            — whose parent domains you may nest under.
  #
  # Decode shared, render per surface: what each door DOES with a collision stays
  # its own (`{:error, :domain_taken}` here, `{:error, :taken}` there). Only the
  # DECODING — which surfaces count as a claim — is one implementation.
  defp hostname_claimed?(norm, opts) do
    except_site_id = Keyword.get(opts, :except_site_id)
    except_barkpark_id = Keyword.get(opts, :except_barkpark_id)
    team_id = Keyword.fetch!(opts, :team_id)

    site_domain_claimed?(norm, except_site_id) or
      barkpark_custom_host_claimed?(norm, except_barkpark_id) or
      foreign_custom_host_suffix?(norm, team_id) or
      provisioning_fqdn_taken?(norm, except_barkpark_id)
  end

  # Is `norm` registered to a Site? `except_site_id` drops ONE row from the walk;
  # `nil` drops none. The nil case CANNOT be an unconditional `s.id != ^nil` —
  # SQL `id != NULL` is never true, which would empty the walk and answer "free"
  # for every registered name (the same trap `exclude_self_claim/2` documents).
  defp site_domain_claimed?(norm, except_site_id) do
    Site
    |> where([s], fragment("? = ANY(?)", ^norm, s.domains))
    |> exclude_site(except_site_id)
    |> select([s], 1)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> false
      _ -> true
    end
  end

  defp exclude_site(query, nil), do: query
  defp exclude_site(query, site_id), do: where(query, [s], s.id != ^site_id)

  @doc """
  Resolve `domain` to its single owning Site, or `nil`. Case-folded lookup. With
  the cross-site uniqueness guard in `add_site_domain/2`, a registered domain
  belongs to exactly one site — this is the ask-gate's owner-resolution view of
  the normalized-uniqueness model (a 200 from `domain_registered?/1` maps to this
  one owner, never an ambiguous pair).
  """
  @spec domain_owner_site(String.t()) :: Site.t() | nil
  def domain_owner_site(domain) when is_binary(domain) do
    norm = normalize_domain(domain)

    Site
    |> where([s], fragment("? = ANY(?)", ^norm, s.domains))
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Shape-validate `domain` for `barkpark` WITHOUT persisting: `{:ok, normalized}`
  or `{:error, changeset}`. The router's attach flow runs this FIRST so the V2
  DNS-ownership pre-check (`BarkparkCloud.DomainOwnership`) sees the normalized
  host and runs only for well-formed EXTERNAL FQDNs — a malformed domain is a
  422 before any resolver call, and nothing is written on a failed ownership
  proof. `set_custom_host/2` re-runs the same changeset at persist time.
  """
  @spec validate_custom_host(Barkpark.t(), term()) ::
          {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def validate_custom_host(%Barkpark{} = barkpark, domain) do
    changeset = Barkpark.custom_host_changeset(barkpark, %{custom_host: domain})

    if changeset.valid? do
      {:ok, Ecto.Changeset.fetch_field!(changeset, :custom_host)}
    else
      {:error, %{changeset | action: :validate}}
    end
  end

  @doc """
  Attach custom domain `domain` — a platform-zone host
  (`gyldendal.barkpark.cloud`) or, since attach-domain V2, an arbitrary
  customer-owned FQDN (`barkpark.jarl.no`) — to `barkpark`: the persist half of
  the attach flow, run BEFORE `enqueue_attach_domain_job/1` so the worker's
  claim payload (and the TLS ask-gate) read the host off the row. The V2
  DNS-ownership proof for external FQDNs lives ABOVE this call (the router's
  pre-check + the worker's re-check), not here.

  Validation + normalization live in `Barkpark.custom_host_changeset/2` (one
  label under the platform zone, or a well-formed external FQDN). On top of
  that, the host must not already be claimed by ANY other surface that answers
  on our boxes — a Site domain, another barkpark's `custom_host` (exact, or as
  a PARENT domain owned by a different team: `sub.barkpark.jarl.no` is refused
  while `barkpark.jarl.no` belongs to someone else), or ANOTHER barkpark's
  provisioning FQDN (its `url` host, compared NORMALISED — a url-held FQDN and
  a custom_host are ONE namespace) — each of those would silently
  shadow or be shadowed by the attach. Taken → `{:error, :taken}`. The
  pre-check is check-then-write; the `barkparks_custom_host_unique_idx` unique
  constraint is the atomic backstop for a custom_host↔custom_host race
  (translated to the same `:taken`).

  Returns `{:ok, %Barkpark{}}`, `{:error, :taken}`, or a validation
  `{:error, %Ecto.Changeset{}}` for a malformed domain.
  """
  @spec set_custom_host(Barkpark.t(), term()) ::
          {:ok, Barkpark.t()} | {:error, :taken | Ecto.Changeset.t()}
  def set_custom_host(%Barkpark{} = barkpark, domain) do
    changeset = Barkpark.custom_host_changeset(barkpark, %{custom_host: domain})

    cond do
      not changeset.valid? ->
        {:error, %{changeset | action: :update}}

      custom_host_taken?(Ecto.Changeset.fetch_field!(changeset, :custom_host), barkpark) ->
        {:error, :taken}

      true ->
        changeset |> Repo.update() |> translate_custom_host_conflict()
    end
  end

  # Is `norm` (already normalized by the changeset) claimed anywhere else on
  # our boxes? Four surfaces, fail-closed OR: a Site's domains array, ANOTHER
  # barkpark's custom_host (self is excluded — re-attaching your own host is an
  # idempotent no-op, not a conflict), a DIFFERENT team's custom_host as a
  # PARENT of `norm` (attach-domain V2: you may nest under your own attached
  # domain, never under someone else's), or ANOTHER barkpark's provisioning
  # FQDN (`url` stores `https://<fqdn>`; self is excluded there too, so a row
  # may attach the host it already answers on).
  #
  # Those four legs ARE `hostname_claimed?/2`, which the Site claim doors call
  # too — this head only names the barkpark's self-exclusions. It is a thin
  # adapter ON PURPOSE: the four-leg list must exist in exactly one place, or the
  # next hardening commit widens one door and leaves the other where it was.
  defp custom_host_taken?(norm, %Barkpark{id: self_id, team_id: team_id}) do
    hostname_claimed?(norm, except_barkpark_id: self_id, team_id: team_id)
  end

  # Does `norm` sit UNDER a custom_host owned by a different team? The stored
  # custom_host is changeset-validated ([a-z0-9.-] only), so it is safe on the
  # right side of LIKE — it can never smuggle a wildcard.
  defp foreign_custom_host_suffix?(norm, team_id) do
    Barkpark
    |> where([b], not is_nil(b.custom_host) and b.team_id != ^team_id)
    |> where([b], fragment("? LIKE '%.' || ?", ^norm, b.custom_host))
    |> select([b], 1)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> false
      _ -> true
    end
  end

  # Does a barkpark hold `norm` as its `custom_host`? `except_barkpark_id` drops
  # ONE row (self); `nil` drops none — the same nil-trap as
  # `site_domain_claimed?/2`, so the exclusion is a conditional `where`, never
  # `b.id != ^nil`.
  defp barkpark_custom_host_claimed?(norm, except_barkpark_id) do
    Barkpark
    |> where([b], b.custom_host == ^norm)
    |> exclude_self_claim(except_barkpark_id)
    |> select([b], 1)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> false
      _ -> true
    end
  end

  # Does ANOTHER row already answer on `norm` as its provisioning FQDN? A
  # url-held FQDN and a custom_host occupy ONE hostname namespace — the two
  # partial unique indexes (`barkparks_url_unique_idx`,
  # `barkparks_custom_host_unique_idx`) are DISJOINT and structurally cannot
  # see across them, so this pre-check is the only guard there is.
  #
  # Self is EXCLUDED, exactly as `other_barkpark_custom_host?/2` does it: a row
  # attaching the host it ALREADY serves (its own provisioning FQDN — e.g.
  # re-attaching to re-run the DNS upsert after a repair) shadows nobody, so
  # refusing it would only block a legitimate re-attach. Excluding self cannot
  # widen the walk for anyone else: `claim_leg/2` is evaluated per OTHER row, so
  # every leg that would have held the name against a stranger still holds it.
  defp provisioning_fqdn_taken?(norm, self_id) do
    case provisioning_fqdn_claim(norm, self_id) do
      :free ->
        false

      {:held, leg, why} ->
        Logger.info("custom_host refused for #{norm}: leg=#{leg} — #{why}")
        true
    end
  end

  @doc """
  Does any row's provisioning FQDN still hold the name `host`, and if so WHICH
  leg holds it? `:free` (no row, or the only rows are genuinely abandoned) or
  `{:held, leg, why}` — `leg` is the atom naming the refusing leg and `why` is
  the operator-facing sentence.

  ABANDONED rows do not hold a name claim. A row whose agent NEVER phoned home
  (last_seen_at nil — every live instance reports within a minute of
  provisioning), that is older than `@abandoned_claim_after_days`, and that has
  no active job in flight is a provisioning ghost (seen live 2026-07-08: a
  June-29 pre-registry-era attempt squatted gyldendal.barkpark.cloud forever
  with no owner able to release it). Excluding it lets a legitimate attach
  reclaim the name; the ghost row itself stays untouched (it is dead weight,
  not a conflict).

  `last_seen_at IS NULL` alone is NOT abandonment — it means the AGENT never
  phoned home, which says nothing about whether the PLATFORM is still dialling
  the box. Measured 2026-08-08 on live data, the silence-only carve-out was
  0-for-3: every row it would have released was on a live subscription, and one
  of them was still being polled every ~15 minutes with its decrypted admin
  bearer token. So three independent AND-legs guard the release, any ONE of
  which keeps the claim:

    * `:admin_credential` — the row holds `admin_token_encrypted`. A row the
      platform can still decrypt a bearer token FOR is by definition not
      abandoned; releasing its name hands the next tenant a hostname the
      platform keeps dialling with someone else's live credential. HARD BLOCK,
      independent of `last_seen_at`.
    * `:recent_usage_sample` — a `usage_samples` row inside the last 24h. The
      sampler only writes for instances it actually reaches out to; a sample is
      proof of an in-flight platform→instance transmission. HARD BLOCK,
      independent of `last_seen_at`.
    * `:active_subscription` — the owning team has a live subscription
      (`active` or `past_due`; a past_due row is still a billed customer). We
      do not release the name of something a customer is paying for.

  Widening the carve-out means deleting a leg here, and the refusal names which
  leg refused so that cost is visible before anyone does.

  The stored `url` is matched NORMALISED, never string-equal to
  `"https://" <> host`: surrounding whitespace trimmed, scheme stripped,
  everything from the first character outside the hostname alphabet cut (port,
  path, query, fragment), trailing dot dropped, case folded. Matching one exact
  spelling of the origin reads only one of the ways the column is written and
  lets every other spelling of the SAME hostname through — that is the hole this
  walk closes.

  `self_id` (the /2 head; `/1` passes `nil` and excludes nobody) drops the
  asking row from the walk, so a row may attach the host it already answers on.
  Two things this walk deliberately does NOT do, both pre-existing and owned
  elsewhere: it adds no `custom_host IS NULL` gate, so a re-attach still
  overwrites an existing `custom_host` and orphans that host's A record — the
  class-level seam owned by
  `cch-w54-bl-re-attaching-a-domain-orphans-the-previous-record-on-a-live-box`;
  and a self-attach still runs the real persist-and-enqueue path
  (`persist_and_enqueue_domain`, `web/router.ex`), so it enqueues an
  attach_domain job and a DNS upsert — reasoned idempotent, not driven by a test
  here.
  """
  @spec provisioning_fqdn_claim(String.t()) :: :free | {:held, atom(), String.t()}
  def provisioning_fqdn_claim(host) when is_binary(host), do: provisioning_fqdn_claim(host, nil)

  @spec provisioning_fqdn_claim(String.t(), Ecto.UUID.t() | nil) ::
          :free | {:held, atom(), String.t()}
  def provisioning_fqdn_claim(host, self_id) when is_binary(host) do
    norm = normalize_claim_host(host)
    cutoff = DateTime.add(DateTime.utc_now(), -@abandoned_claim_after_days, :day)
    sample_cutoff = DateTime.add(DateTime.utc_now(), -@recent_sample_window_hours, :hour)

    Barkpark
    |> where(
      [b],
      # The `btrim` is load-bearing, not cosmetic: without it this fragment and
      # its Elixir twin `normalize_claim_host/1` DISAGREED on every
      # leading-whitespace spelling. The scheme regex is anchored, so ` https://h`
      # missed it, and the next step (`[^a-z0-9.-].*$`) then ate the string from
      # its first character — the whole stored url normalised to `""`, matched
      # nothing, and `provisioning_fqdn_claim/2` answered `:free` for a hostname
      # a LIVE box serves. The character set is exactly the 25 codepoints
      # `String.trim/1` strips (Unicode `White_Space`).
      #
      # Every C0 control in that set is spelled `\uXXXX`, never `\t`/`\v`/`\f`:
      # PostgreSQL 15 has no `\v` case in its escape-string lexer, so there
      # `E'\v'` is the LETTER v ("any other character following a backslash is
      # taken literally"), while 16+ reads it as U+000B. That one-character
      # difference broke the twins BOTH ways on 15 — U+000B was not trimmed (a
      # VT-led url normalised to `""` again), and the letter `v` WAS, so a
      # stored `https://host.tv` normalised to `host.t` and the claim answered
      # `:free` for a live `.tv` box. `\uXXXX` is documented and reads the same
      # on every supported server. The set's LENGTH is 25 under either
      # spelling, so only membership testing catches this;
      # `registry_claim_host_normaliser_test.exs` drives all 25 codepoints
      # through both twins for exactly that reason.
      fragment(
        "regexp_replace(regexp_replace(regexp_replace(btrim(lower(?), E'\\u0009\\u000a\\u000b\\u000c\\u000d\\u0020\\u0085\\u00a0\\u1680\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2007\\u2008\\u2009\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000'), '^[a-z][a-z0-9+.-]*://', ''), '[^a-z0-9.-].*$', ''), '\\.+$', '') = ?",
        b.url,
        ^norm
      )
    )
    |> exclude_self_claim(self_id)
    |> select([b], %{
      id: b.id,
      last_seen_at: b.last_seen_at,
      inserted_at: b.inserted_at,
      has_admin_token: not is_nil(b.admin_token_encrypted),
      active_job: b.id in subquery(active_job_barkpark_ids()),
      recent_sample:
        fragment(
          "EXISTS (SELECT 1 FROM usage_samples us WHERE us.barkpark_id = ? AND us.measured_at >= ?)",
          b.id,
          ^sample_cutoff
        ),
      live_subscription:
        fragment(
          "EXISTS (SELECT 1 FROM subscriptions s WHERE s.team_id = ? AND s.status IN ('active','past_due'))",
          b.team_id
        )
    })
    |> Repo.all()
    |> Enum.find_value(:free, &claim_leg(&1, cutoff))
  end

  # CONDITIONAL, and that is the whole point: an unconditional
  # `b.id != ^self_id` compiles to SQL `id != NULL` when `self_id` is nil, which
  # is never true — every row would drop out of the walk and EVERY name would
  # read `:free` through the /1 head. No id predicate is the only safe nil case.
  defp exclude_self_claim(query, nil), do: query
  defp exclude_self_claim(query, self_id), do: where(query, [b], b.id != ^self_id)

  # The url side of the comparison, in Elixir: the same shape the SQL fragment
  # above produces for `b.url` — case-folded, surrounding whitespace stripped
  # (`String.trim/1`, whose 25-codepoint Unicode `White_Space` set the
  # fragment's `btrim` mirrors character-for-character), scheme dropped,
  # everything from the first character outside the hostname alphabet cut,
  # trailing dots dropped. These two are TWINS: a step added to one and not the
  # other re-opens the `:free`-for-a-live-host hole by spelling, which is why
  # `registry_claim_host_normaliser_test.exs` drives both through one corpus
  # instead of trusting this comment. `normalize_domain/1` is NOT a drop-in — it
  # only case-folds and trims a trailing dot, so a caller passing an origin
  # (`https://host:4000/studio`) would compare a scheme-and-port-bearing string
  # against a bare hostname and match nothing.
  defp normalize_claim_host(host) when is_binary(host) do
    host
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r{^[a-z][a-z0-9+.-]*://}, "")
    |> String.replace(~r/[^a-z0-9.-].*$/, "")
    |> String.trim_trailing(".")
  end

  # Which leg (if any) keeps THIS row's name claim? nil = this row is a
  # genuine ghost and releases the name. The two hard-block legs are named
  # first: they are the ones a widening operator must consciously delete.
  defp claim_leg(row, cutoff) do
    cond do
      row.has_admin_token ->
        {:held, :admin_credential,
         "row #{row.id} still holds a decryptable admin token — the platform can dial this host with a live credential, so it is not abandoned"}

      row.recent_sample ->
        {:held, :recent_usage_sample,
         "row #{row.id} was sampled by the usage worker within the last #{@recent_sample_window_hours}h — the platform is still transmitting to this host"}

      row.live_subscription ->
        {:held, :active_subscription,
         "row #{row.id} belongs to a team with a live subscription (active or past_due) — a billed name is never released"}

      not is_nil(row.last_seen_at) ->
        {:held, :agent_reporting, "row #{row.id} phoned home at #{row.last_seen_at}"}

      row.active_job ->
        {:held, :active_job, "row #{row.id} has a provision job in flight"}

      DateTime.compare(row.inserted_at, cutoff) != :lt ->
        {:held, :within_grace,
         "row #{row.id} is younger than the #{@abandoned_claim_after_days}-day abandonment window"}

      true ->
        nil
    end
  end

  defp active_job_barkpark_ids do
    ProvisionJob
    |> where([j], j.status in ["pending", "claimed"])
    |> select([j], j.barkpark_id)
  end

  # Map a lost race on barkparks_custom_host_unique_idx to the same :taken the
  # pre-check returns; any other outcome passes through unchanged.
  defp translate_custom_host_conflict({:error, %Ecto.Changeset{errors: errors}} = err) do
    if Enum.any?(errors, fn {field, {_msg, opts}} ->
         field == :custom_host and Keyword.get(opts, :constraint) == :unique
       end) do
      {:error, :taken}
    else
      err
    end
  end

  defp translate_custom_host_conflict(other), do: other

  @doc """
  The on-demand TLS gate: is `domain` registered to ANY Site, live branch
  preview, or instance custom host? Returns true / false.

  Caddy's `on_demand_tls.ask` calls this — a 200 means "we own this hostname,
  go ahead and issue a cert"; a 404 means "stop, this is not our hostname"
  (prevents the box from being a cert-issuance DoS target).
  """
  @spec domain_registered?(String.t()) :: boolean()
  def domain_registered?(domain) when is_binary(domain) do
    norm = normalize_domain(domain)

    site_domain_claimed?(norm, nil) or registered_preview_host?(norm) or
      registered_custom_host?(norm)
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

  # Instance custom domains: a custom_host attached to any barkpark is
  # TLS-allowlisted so the instance box's on-demand issuance for it succeeds.
  # `custom_host` is stored normalized (custom_host_changeset), the SAME
  # normalization applied to `norm` above — an equality match, indexed by
  # barkparks_custom_host_unique_idx.
  defp registered_custom_host?(norm) do
    Barkpark
    |> where([b], b.custom_host == ^norm)
    |> select([b], 1)
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
  site-spawner W5 (charter D46/D47): decrypt a Site's content-publish webhook
  secret back to plaintext — the secret the CP verifies inbound
  `POST /v1/sites/webhooks/content-publish/:site_id` deliveries against.

  Returns `{:ok, plaintext}` when set, `{:ok, nil}` when never configured (every
  container site + any static site that predates W5 / had no live box at create),
  or `:error` when the stored ciphertext is tampered (fail closed). Mirrors
  `reveal_site_github_secret/1` exactly.
  """
  @spec reveal_site_content_secret(Site.t()) :: {:ok, binary() | nil} | :error
  def reveal_site_content_secret(%Site{content_webhook_secret_encrypted: nil}), do: {:ok, nil}

  def reveal_site_content_secret(%Site{content_webhook_secret_encrypted: ciphertext}) do
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
  dwb-webhook fail-fast interim: mint a Deployment that is born TERMINAL-`failed`
  in ONE transaction — a "this push happened but can't be built yet" tombstone.

  A GitHub push webhook currently has no artifact and no way to build from source
  (that needs the human-gated GitHub App, gh-1). Enqueuing it as `queued` conjures
  a zombie: the builder never claims a source-less row, so the console shows it as
  "running" forever. Instead we record the push HONESTLY as a `failed` row carrying
  `reason` — the console renders a calm blocked-tone with the `bp deploy` workaround.

  Mechanics (charter D1):

    1. Insert via the normal `Deployment.changeset/2` — `status` is NOT castable
       there (deployment.ex:147-150 forbids it; `transition_changeset` is the sole
       status mutator), so the row lands at the schema default `queued`.
    2. In the SAME transaction, `transition_changeset` it `queued → failed` (a
       documented-legal edge, deployment.ex:40-44) stamping `failure_reason: reason`.

  Because both writes are one transaction, `claim_next_deployment`'s
  `FOR UPDATE SKIP LOCKED WHERE status = "queued"` can NEVER observe the interim
  `queued` row — there is zero claimable window. The `delivery_id` rides through on
  the insert, so redelivery dedup (`find_deployment_by_delivery_id`, a
  non-status-scoped partial unique index) keeps pointing at this failed row, while
  `find_active_deployment/2` (queued/building/pushing only) ignores it so a later
  REAL deploy at the same sha is never blocked.

  A lost race (a concurrent redelivery won the `delivery_id` / active-ref unique
  index) rolls the whole transaction back and returns `{:error, %Ecto.Changeset{}}`,
  which the router recovers into a 200 duplicate — identical to `create_deployment/2`.
  """
  @spec create_failed_deployment(Site.t(), map(), String.t()) ::
          {:ok, Deployment.t()} | {:error, Ecto.Changeset.t()}
  def create_failed_deployment(%Site{} = site, attrs, reason) when is_binary(reason) do
    result =
      Repo.transaction(fn ->
        with {:ok, queued} <-
               %Deployment{}
               |> Deployment.changeset(Map.put(attrs, :site_id, site.id))
               |> Repo.insert(),
             {:ok, failed} <-
               queued
               |> Deployment.transition_changeset(%{status: "failed", failure_reason: reason})
               |> Repo.update() do
          failed
        else
          {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
        end
      end)

    # notifications (wave 28 S6): a born-failed row is exactly the person-facing
    # case — a push landed and can never build. POST-transaction, so a lost
    # redelivery race (rolled back) emails nobody. No edge guard is needed: the
    # row did not exist a moment ago, so this is always an edge.
    with {:ok, %Deployment{} = failed} <- result do
      dispatch_deployment_failed(failed)
    end

    result
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

  # The third `cap_console/1` call site. The line here is control-plane-authored
  # (a fixed cancellation notice), never builder input, so it is never truncated
  # and carries no `truncated_from`; the ring drop still discloses itself through
  # `cap_console/1` exactly as on the two append paths.
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

  ## Deploy-rail step estimates — MEASURED, or refused.
  ##
  ## The console's deploy rail used to pace itself off hardcoded literals
  ## (app.js `SERVER_STEP_EXPECTED_MS`), and they were wrong by an order of
  ## magnitude: the screen told a person BUILD takes 120000ms when the live
  ## control plane's 30-day cohort has a p50 of 14835ms over 8211 paired
  ## attempts. HEALTH advertised 18000ms against a measured 2098ms. This fold
  ## replaces the invented numbers with medians the rail can actually stand
  ## behind — and REFUSES to publish a number for any stage whose distribution
  ## turns out to be a sampling artifact rather than stage work.
  ##
  ## Four policy choices, each with the measurement that motivated it:
  ##
  ##   1. PER-ATTEMPT PAIRING (never min(running) → max(done) across a whole
  ##      console array). A retried stage re-opens inside one array, and the
  ##      naive fold produced a HEALTH minimum of -61637ms and a PLAN minimum of
  ##      -10282ms on real prod rows — durations that cannot exist. Each
  ##      `running` opens an attempt; the next `done` closes exactly that one; a
  ##      `failed` discards it (a died attempt is not a healthy duration); a
  ##      re-`running` supersedes an unclosed attempt. A pair that still comes
  ##      out negative (re-ordered stamps) is DROPPED, never clamped to zero.
  ##
  ##   2. OUTLIER TRIMMING. The same cohort holds a BUILD attempt of
  ##      111611410ms — 31 hours, a claim that outlived its build. The top and
  ##      bottom @estimate_trim_fraction of the sorted samples come off before
  ##      any percentile is read.
  ##
  ##   3. A MINIMUM SAMPLE COUNT of @estimate_min_samples. The stages we mean to
  ##      publish clear it by orders of magnitude (BUILD 8211, HEALTH 1468, PLAN
  ##      689 pairs); the floor exists so a quiet week never turns three
  ##      deployments into a "median".
  ##
  ##   4. A CADENCE REFUSAL. RETIRE/STAGE/SWITCH bottom out at 2035/2036/2036ms
  ##      with p50s of 2102/2099/2119 — three unrelated stages pinned to the
  ##      same ~2s value, which is the deploy driver's POLL CADENCE, not their
  ##      work. Publishing those would swap an invented number for a sampling
  ##      artifact, so a stage whose whole distribution collapses into one
  ##      sub-@estimate_cadence_ceiling_ms spike is refused and the client keeps
  ##      its constant. The rule is measured, not stage-hardcoded: a stage that
  ##      grows a real spread starts publishing, and one that collapses stops.
  ##
  ## SCOPE: the DEPLOY rail only. The provision rail keeps its constants — see
  ## the note on `deploy_stage_estimates/1` below.
  @deploy_estimate_stages ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE)
  @estimate_window_days 30
  # Newest-first cap on the cohort. 300 live deployments still yields hundreds
  # of BUILD pairs (far above the sample floor) while keeping the fold's cost a
  # bounded read instead of a 30-day table scan.
  @estimate_cohort_limit 300
  @estimate_min_samples 30
  @estimate_trim_fraction 0.05
  # Below this, a median is small enough to be a poll artifact and the spread
  # test applies. Above it (BUILD at 14835ms) the number is stage work whatever
  # its spread looks like.
  @estimate_cadence_ceiling_ms 5_000
  @estimate_cadence_spread_ratio 0.25
  # Sanity rails: an estimate the console would render as nonsense is refused
  # rather than shown.
  @estimate_floor_ms 500
  @estimate_ceiling_ms 1_800_000
  @estimate_cache_key {__MODULE__, :deploy_stage_estimates}
  @estimate_cache_ttl_ms 600_000

  @doc """
  The deploy rail's MEASURED per-stage estimates, shaped for the additive
  `step_estimates` key on `GET /v1/barkparks`:

      %{
        deploy: %{"BUILD" => 14835, "HEALTH" => 2098, "PLAN" => 2046},
        meta: %{
          window_days: 30,
          deployments: 300,
          samples: %{"BUILD" => 812, …},
          refused: %{"STAGE" => "cadence_quantized", …}
        }
      }

  `deploy` carries ONLY the stages that survived the policy above; every other
  stage is absent (and named in `meta.refused` with its reason), which the
  client reads as "keep the constant". Counts and stage names only — no site,
  team, user or deployment identity goes anywhere near this payload.

  THE PROVISION RAIL IS DELIBERATELY NOT HERE. Its steps keep their hardcoded
  constants because the evidence does not exist: the live control plane holds
  FOUR succeeded provision jobs with per-step complete pairs of 1-4 (one step at
  n=1), on a column that has only existed since migration 20260702140000. That
  is a sample, not a median, and @estimate_min_samples would refuse every one of
  them anyway.

  Memoized in `:persistent_term` for `opts[:ttl_ms]` (default 10 minutes) so a
  polling dashboard does not re-fold the cohort on every request. Pass
  `ttl_ms: 0` to force a recompute (what the tests do, so a warm entry from a
  neighbouring test can never answer for them).
  """
  @spec deploy_stage_estimates(keyword()) :: %{deploy: map(), meta: map()}
  def deploy_stage_estimates(opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, @estimate_cache_ttl_ms)
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@estimate_cache_key, nil) do
      {computed_at, payload} when is_integer(computed_at) and now - computed_at < ttl ->
        payload

      _ ->
        consoles = recent_live_deploy_consoles()
        payload = deploy_stage_estimates_from_consoles(consoles)
        :persistent_term.put(@estimate_cache_key, {now, payload})
        payload
    end
  end

  @doc """
  The pure fold behind `deploy_stage_estimates/1`: a list of deployment console
  arrays (`[%{"stage" =>, "status" =>, "at" =>}]`, exactly what
  `BarkparkCloud.Sites.Deploy.console_entry/1` appends) in, the published table
  out. Every policy decision documented above lives here, so the judgment is
  unit-testable without a database.
  """
  @spec deploy_stage_estimates_from_consoles([list()]) :: %{deploy: map(), meta: map()}
  def deploy_stage_estimates_from_consoles(consoles) when is_list(consoles) do
    samples =
      Enum.reduce(consoles, %{}, fn console, acc ->
        console
        |> paired_stage_durations()
        |> Enum.reduce(acc, fn {stage, ms}, inner ->
          Map.update(inner, stage, [ms], &[ms | &1])
        end)
      end)

    verdicts =
      Map.new(@deploy_estimate_stages, fn stage ->
        {stage, stage_verdict(Map.get(samples, stage, []))}
      end)

    %{
      deploy: for({stage, {:ok, ms}} <- verdicts, into: %{}, do: {stage, ms}),
      meta: %{
        window_days: @estimate_window_days,
        deployments: length(consoles),
        samples: Map.new(@deploy_estimate_stages, &{&1, length(Map.get(samples, &1, []))}),
        refused:
          for({stage, {:refused, why}} <- verdicts, into: %{}, do: {stage, Atom.to_string(why)})
      }
    }
  end

  # The cohort: the newest @estimate_cohort_limit deployments that actually
  # reached `live` inside the window. Successful runs only — a failed deploy's
  # stage durations describe how long it took to break, not how long the work
  # takes.
  defp recent_live_deploy_consoles do
    cutoff = DateTime.add(DateTime.utc_now(), -@estimate_window_days * 86_400, :second)

    from(d in Deployment,
      where: d.status == "live" and d.inserted_at >= ^cutoff,
      order_by: [desc: d.inserted_at],
      limit: @estimate_cohort_limit,
      select: d.console
    )
    |> Repo.all()
    |> Enum.map(&(&1 || []))
  end

  # Policy 1 — per-attempt pairing over ONE console array, in append order.
  # Returns `[{stage, duration_ms}]` for the attempts that opened and cleanly
  # closed; everything else is dropped rather than guessed.
  defp paired_stage_durations(console) when is_list(console) do
    {_open, pairs} =
      Enum.reduce(console, {%{}, []}, fn entry, {open, pairs} ->
        stage = console_value(entry, "stage")
        status = console_value(entry, "status")
        at = console_ms(console_value(entry, "at"))

        cond do
          stage not in @deploy_estimate_stages or is_nil(at) ->
            {open, pairs}

          status in ["running", "started"] ->
            # A re-open supersedes an unclosed attempt — that is the retry.
            {Map.put(open, stage, at), pairs}

          status == "done" ->
            case Map.pop(open, stage) do
              {nil, open} -> {open, pairs}
              {start, open} when at - start >= 0 -> {open, [{stage, at - start} | pairs]}
              {_start, open} -> {open, pairs}
            end

          status in ["failed", "skipped"] ->
            {Map.delete(open, stage), pairs}

          true ->
            {open, pairs}
        end
      end)

    pairs
  end

  defp paired_stage_durations(_), do: []

  defp console_value(entry, key) when is_map(entry) do
    case Map.fetch(entry, key) do
      {:ok, v} -> v
      :error -> Map.get(entry, safe_atom(key))
    end
  end

  defp console_value(_, _), do: nil

  defp safe_atom("stage"), do: :stage
  defp safe_atom("status"), do: :status
  defp safe_atom("at"), do: :at

  defp console_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  defp console_ms(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp console_ms(_), do: nil

  # Policies 2-4 — trim, floor the sample count, then decide whether the median
  # is a duration or an artifact.
  defp stage_verdict(durations) do
    n = length(durations)

    if n < @estimate_min_samples do
      {:refused, :insufficient_samples}
    else
      trimmed = trim_outliers(Enum.sort(durations))
      p50 = percentile(trimmed, 0.5)
      p10 = percentile(trimmed, 0.10)
      p90 = percentile(trimmed, 0.90)

      cond do
        p50 < @estimate_floor_ms ->
          {:refused, :below_floor}

        p50 > @estimate_ceiling_ms ->
          {:refused, :above_ceiling}

        p50 < @estimate_cadence_ceiling_ms and
            p90 - p10 < @estimate_cadence_spread_ratio * p50 ->
          {:refused, :cadence_quantized}

        true ->
          {:ok, p50}
      end
    end
  end

  defp trim_outliers(sorted) do
    n = length(sorted)
    cut = floor(n * @estimate_trim_fraction)

    case Enum.slice(sorted, cut, max(n - 2 * cut, 1)) do
      [] -> sorted
      kept -> kept
    end
  end

  defp percentile(sorted, p) do
    n = length(sorted)
    Enum.at(sorted, min(n - 1, max(trunc(p * n), 0)))
  end

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

  BOTH BOUNDS DISCLOSE THEMSELVES (identically to the provision twin): an
  oversized line is TRUNCATED to `@max_console_line_chars` and its entry carries
  `"truncated_from" => <original length>`; past the line cap the oldest
  SURVIVING entry carries `"dropped_before" => <cumulative count>`. A build
  console that silently drops is indistinguishable from a complete one, and the
  panel that renders it prints a bare line count as if it were the whole log.

  Returns `{:ok, deployment}` with the appended array, `{:error, :not_found}`
  for an unknown id, or `{:error, :invalid}` for a missing/blank line (the
  router 422s it rather than persisting garbage). Length is NOT a rejection
  reason — `internal/builder`'s console channel latches off after three non-2xx
  replies (and that latch is SHARED with the `detail` caption), so 422ing a long
  line would take the rest of the build's narration down with it.
  """
  @spec append_deployment_console(binary(), term()) ::
          {:ok, Deployment.t()} | {:error, :not_found | :invalid}
  def append_deployment_console(id, raw_line) when is_binary(id) do
    with {:ok, line} <- validate_console_line(raw_line),
         %Deployment{} = deployment <- uuid_or_nil(id) && Repo.get(Deployment, id) do
      entry =
        %{"line" => line, "at" => DateTime.to_iso8601(DateTime.utc_now())}
        |> Map.merge(console_line_meta(raw_line))

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
  dwb-19: SET a Deployment's live sub-caption (`detail`) — the build-side twin of
  a provision step's `progress`. Latest-wins (a single string, never appended),
  overwritten by the builder at each real sub-boundary (fetch source → build →
  save image → hand off). The site-detail deploy row renders it under the status
  pill while the deploy is active. Best-effort telemetry: it NEVER affects the
  build's outcome, and a blank caption is rejected rather than persisting
  garbage.

  Shares `validate_console_line/1` with the two console appenders, so an
  oversized caption is TRUNCATED to `@max_console_line_chars`, not rejected.
  Unlike a console entry it carries NO `truncated_from` marker: `detail` is a
  bare string column with nowhere to put one. That is precisely why
  `validate_console_line/1` keeps its `{:ok, binary}` return shape and the
  disclosure rides in the separate `console_line_meta/1` — changing the /1
  return shape would break this with-chain silently.

  cch-w34-s5: the column is now `:text`
  (`priv/repo/migrations/20260806110000_deployment_detail_to_text.exs`), so the
  2 KB validator is the ONLY bound and the "never affects the build's outcome"
  promise above holds for a caption of any length. It did not before: the column
  was varchar(255) while the shared cap was 2 KB, so a caption of 256..2_000
  characters raised `Postgrex.Error 22001` inside `Repo.update/1` — reachable
  from a long `git_ref`, whose builder caption runs +23 characters over the ref.

  Returns `{:ok, deployment}`, `{:error, :not_found}` for an unknown id, or
  `{:error, :invalid}` for a missing/blank line (the router 422s it).
  """
  @spec set_deployment_detail(binary(), term()) ::
          {:ok, Deployment.t()} | {:error, :not_found | :invalid}
  def set_deployment_detail(id, detail) when is_binary(id) do
    with {:ok, detail} <- validate_console_line(detail),
         %Deployment{} = deployment <- uuid_or_nil(id) && Repo.get(Deployment, id) do
      deployment
      |> Deployment.transition_changeset(%{detail: detail})
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
      # site-spawner D22: CONTAINER rows only. A static deploy runs ON the box
      # (site-deploy.sh, driven by the control plane over the admin relay) — the
      # off-box container builder has no way to build one, and a row it claimed
      # would be stuck `building` under a worker that will never finish it. The
      # kind guard is what keeps the two pipelines from stealing each other's work.
      #
      # A subquery, NOT a join: `FOR UPDATE` over a join locks the joined `sites`
      # row too, which would put the builder's claim in the lock path of every
      # ordinary site update. The filter only needs to READ the kind.
      container_sites = from(s in Site, where: s.kind == "container", select: s.id)

      query =
        from(d in Deployment,
          where: d.status == "queued" and d.site_id in subquery(container_sites),
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
  Atomically claim the oldest queued Deployment whose Site is a CONTAINER site
  on `barkpark`, for `worker_id` — the box-scoped twin of
  `claim_next_deployment/1`, and the only claim the builder route reaches
  (jpf-w1-builder-identity).

  WHY THIS EXISTS. `claim_next_deployment/1` selects FLEET-WIDE, so the route
  in front of it could only ever be gated by a fleet-wide principal — the shared
  `WORKER_TOKEN`, one secret that also opens `/v1/internal/*`. That secret now
  lives on customer boxes running untrusted nixpacks builds. Narrowing the QUERY
  to the caller's own box is what makes the per-box, hashed, revocable agent
  token a sufficient credential for the route; without it, a box-scoped identity
  in front of a fleet-wide query would still hand box A a build for box B.

  ALSO A CORRECTNESS FIX, not only a scope one: the builder and the runtime
  share one on-box cache directory and hand the built tarball over through the
  filesystem, so a build claimed by the wrong box was already broken at two or
  more planes — it just failed later and less legibly.

  SUBQUERY, NOT A JOIN — deliberately copied from `claim_next_deployment/1` and
  deliberately NOT from `claim_pending_deployment_for_barkpark/2`, which joins.
  `FOR UPDATE` over a join locks the joined `sites` row as well, which would put
  every builder claim in the lock path of every ordinary site update. Here the
  site is read for two filters (`kind` and `barkpark_id`) and never written, so
  a subquery is both sufficient and cheaper on the lock graph. The two filters
  ride the SAME subquery for the same reason.

  Returns `{:ok, deployment}` (status `queued → building`, epoch bumped), or
  `{:error, :no_queued}` when this box has nothing waiting. A deployment queued
  for ANOTHER box is not a distinguishable outcome — it is simply absent from
  this box's queue, exactly as in `claim_pending_deployment_for_barkpark/2`, so
  no caller can probe for the existence of another tenant's build.
  """
  @spec claim_queued_deployment_for_barkpark(Barkpark.t() | binary(), String.t()) ::
          {:ok, Deployment.t()} | {:error, :no_queued}
  def claim_queued_deployment_for_barkpark(barkpark, worker_id)
      when is_binary(worker_id) and worker_id != "" do
    bp_id = barkpark_id(barkpark)

    Repo.transaction(fn ->
      # site-spawner D22's CONTAINER guard, kept: a static deploy runs ON the
      # box via site-deploy.sh and the container builder cannot build one, so a
      # row it claimed would wedge `building` under a worker that never
      # finishes. Narrowing by box does not relax that guard, it ANDs with it.
      container_sites =
        from(s in Site,
          where: s.kind == "container" and s.barkpark_id == ^bp_id,
          select: s.id
        )

      query =
        from(d in Deployment,
          where: d.status == "queued" and d.site_id in subquery(container_sites),
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
  site-spawner D22: claim ONE specific Deployment for `worker_id` — the static
  driver's claim, the targeted twin of `claim_next_deployment/1`.

  A static deploy is DRIVEN (the control plane already knows which row it just
  minted); a container deploy is POLLED FOR (the off-box builder asks "what's
  next?"). Same fencing either way: the epoch bumps on every claim, `claimed_at`
  is stamped (so the stale reaper can sweep an abandoned lease), and every
  subsequent write CASes on the observed epoch via
  `transition_deployment_fenced/4`. Runs under `FOR UPDATE` so two drivers racing
  the same row (a retry crossing a reaper-resume) cannot both win.

  Returns `{:ok, deployment}` (status `queued → building`), `{:error, :not_queued}`
  when the row has already moved on, or `{:error, :not_found}`.
  """
  @spec claim_deployment(binary(), String.t()) ::
          {:ok, Deployment.t()} | {:error, :not_found | :not_queued}
  def claim_deployment(deployment_id, worker_id)
      when is_binary(deployment_id) and is_binary(worker_id) and worker_id != "" do
    case uuid_or_nil(deployment_id) do
      nil ->
        {:error, :not_found}

      uuid ->
        Repo.transaction(fn ->
          case Repo.one(from(d in Deployment, where: d.id == ^uuid, lock: "FOR UPDATE")) do
            nil ->
              Repo.rollback(:not_found)

            %Deployment{status: "queued"} = d ->
              {:ok, claimed} =
                d
                |> Deployment.transition_changeset(%{
                  status: "building",
                  stage: "PLAN",
                  claim_worker: worker_id,
                  claimed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
                  claim_epoch: d.claim_epoch + 1
                })
                |> Repo.update()

              claimed

            %Deployment{} ->
              Repo.rollback(:not_queued)
          end
        end)
    end
  end

  @doc """
  Find a Site's deployment by `build_id` — the PLAN idempotency lookup (a repeat
  build of unchanged code+content+config) and the rollback's "which row owns the
  build the box just flipped to?" resolution. Nil when nothing matches.
  """
  @spec find_deployment_by_build_id(binary(), String.t()) :: Deployment.t() | nil
  def find_deployment_by_build_id(site_id, build_id)
      when is_binary(site_id) and is_binary(build_id) do
    case uuid_or_nil(site_id) do
      nil ->
        nil

      uuid ->
        Deployment
        |> where([d], d.site_id == ^uuid and d.build_id == ^build_id)
        |> order_by([d], desc: d.inserted_at)
        |> limit(1)
        |> Repo.one()
    end
  end

  @doc """
  site-spawner D22 (+ search-template W6): the BOX-RELAY-DRIVEN deployments the
  reaper requeued — rows that were claimed at least once (`claim_epoch > 0`) and
  are back at `queued` because their driver died with the control plane (or the
  box restarted mid-build under it).

  Nothing else in the fleet claims these rows (`claim_next_deployment/1` is
  kind-scoped to container — the off-box builder), so without this the reaper's
  requeue would hand the row to nobody and it would sit `queued` forever — an
  eternal spinner wearing the reaper's own uniform. Originally static-only;
  live-caught twice in one evening that a NODE row strands identically (W7 made
  node ride the same box relay), so the sweep now covers both box-driven kinds.
  `Sites.Deploy.resume_orphaned/0` re-drives each.

  Content-bound only: an UNBOUND row is not an orphan, it is un-buildable, and
  the sweep's no-source pass terminates it with an honest reason.
  """
  @spec list_orphaned_static_deployments() :: [Deployment.t()]
  def list_orphaned_static_deployments do
    from(d in Deployment,
      join: s in Site,
      on: s.id == d.site_id,
      where:
        d.status == "queued" and d.claim_epoch > 0 and s.kind in ["static", "node"] and
          not is_nil(s.bootstrap_dataset),
      order_by: [asc: d.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Update a site's OPERATOR-MUTABLE settings — the narrow set that is safe to
  change between deploys: `theme` (the deploy-pinned palette; takes effect on
  the next build) and `doc_type` (the content type the build features). Name,
  slug, kind, framework and template stay immutable here — they index
  infrastructure (routes, port pairs, materialized source trees).

  search-template W8: theme pinning on live sites previously required psql on
  the CP db — an operator gap, not perfection.
  """
  @spec update_site_settings(Site.t(), map()) :: {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def update_site_settings(%Site{} = site, attrs) when is_map(attrs) do
    site
    |> Site.settings_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Repoint a Site's live deployment pointer — the static ROLLBACK's flip (charter
  D5). The box has already repointed its `current` symlink; this makes the control
  plane's view agree immediately, so `bp cloud site status` never reports the
  build it just rolled AWAY from.

  Deliberately narrow (`runtime_changeset`): it cannot rename or re-team a site.
  """
  @spec set_site_current_deployment(Site.t(), binary() | nil) ::
          {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def set_site_current_deployment(%Site{} = site, deployment_id) do
    site
    |> Site.runtime_changeset(%{current_deployment_id: deployment_id})
    |> Repo.update()
  end

  # NOTE: `set_cf_binding/2` (the D57 CF-in-front persist) is defined ONCE, above,
  # by the cf-edge-binding-schema slice — the charter D51 owner of the cf_* columns
  # and their narrow, inclusion-validated `Site.cf_binding_changeset/2`. The DNS
  # writer's earlier schema-tolerant stopgap was removed at review to avoid a
  # duplicate clause (`--warnings-as-errors` merge-gate failure); the canonical
  # validating+transactional version is call-compatible with the deploy handler.

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
        # notifications (wave 28 S6): the dispatch is POST-transaction on purpose.
        # `do_transition_deployment_fenced/4` runs the whole write inside
        # `Repo.transaction`, so a dispatch placed inside would email BEFORE
        # commit and phantom-email whenever a later clause rolls back. It is also
        # EDGE-triggered on the PRIOR status — `Sites.Deploy.record_stage/2`
        # re-drives this same writer on every stage report and
        # `status_for_stage/2` carries "failed" forward unchanged, so failed →
        # failed rewrites are routine and must not re-alert.
        case do_transition_deployment_fenced(deployment_id, worker_id, observed_epoch, attrs) do
          {:ok, {prior_status, %Deployment{} = updated}} ->
            maybe_dispatch_deployment_failed(prior_status, updated)
            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end
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
              # The PRIOR status rides out with the row so the public wrapper can
              # edge-trigger its alert. Unwrapped there — callers still see
              # `{:ok, %Deployment{}}`.
              {:ok, updated} -> {d.status, updated}
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
  Age (seconds) of the OLDEST `queued` container-site deployment per barkpark,
  for the given barkpark ids — `%{barkpark_id => seconds}`, no entry for a
  barkpark with nothing queued (jpf-w1-queue-age-alarm, charter D6).

  READ-ONLY on purpose, and deliberately NOT a reaper pass: the reaper below is
  a MUTATING builder-lease mechanism whose passes are all `claimed_at`-gated —
  a queued row no builder ever claimed has `claimed_at` nil and is invisible to
  it by design. This aggregate surfaces exactly that orphan class. ONE GROUP BY
  query for the whole fleet list (the same no-N+1 shape as
  `latest_health_payload_map/1`), joined Deployment→Site on `barkpark_id`.
  `s.kind == "container"` mirrors the builder's own claim scope
  (`claim_next_deployment`): only container-site rows wait on the off-box
  builder, so only they can stall in this sense. MAX(age) == the oldest
  `inserted_at`, so the row that has waited longest names the number.
  """
  @spec queued_deploy_age_map([Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => non_neg_integer()}
  def queued_deploy_age_map([]), do: %{}

  def queued_deploy_age_map(ids) when is_list(ids) do
    now = DateTime.utc_now()

    from(d in Deployment,
      join: s in Site,
      on: d.site_id == s.id,
      where: s.barkpark_id in ^ids and d.status == "queued" and s.kind == "container",
      group_by: s.barkpark_id,
      select: {s.barkpark_id, min(d.inserted_at)}
    )
    |> Repo.all()
    |> Map.new(fn {id, oldest} -> {id, max(DateTime.diff(now, oldest, :second), 0)} end)
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

    * (0) FAIL a `queued` row with NO build source. KIND-SCOPED (site-spawner
      D28): "no build source" means something DIFFERENT for each Site kind, so
      this is two status-guarded passes summed into one `no_source_failed` count.
      A CONTAINER row is un-buildable with no `artifact_url` AND a site with no
      `github_repo`. A STATIC row is content-bound, not artifact-bound: it is
      un-buildable exactly when its site has no `bootstrap_dataset` (nothing to
      read content from) — a legitimate static row (bound dataset, no artifact,
      no repo) matches the CONTAINER predicate exactly, so a single un-scoped
      pass would terminally fail every static deploy within 60s with a message
      about artifacts and GitHub repos that names neither the cause nor the cure.
      Kind-scoping the container pass ALONE is the other half of the trap: an
      UNBOUND static row would then match nothing and spin `queued` forever —
      the eternal spinner this sweep exists to kill. Hence: two passes, each with
      its own honest reason. Such a row can NEVER build regardless of fleet
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
    * (iii) FAIL a stale `pushing` row whose `claim_epoch` has reached
      `max_deploy_claims/0` — terminal, the on-box-delivery twin of pass (i).
      `claim_pending_deployment_for_barkpark/2` bumps `claim_epoch` on every
      re-claim, so a `pushing` row a permanently-down box keeps failing to accept
      exhausts its budget; without this it would be re-released every sweep and
      never fail (an eternal spinner). Run before the release pass so an exhausted
      row terminates instead of releasing.
    * (iv) RELEASE the remaining stale on-box agent claims on `pushing` rows
      (clear claim_worker / claimed_at only — status STAYS `pushing`) so
      `claim_pending_deployment_for_barkpark/2` re-matches them for a fresh agent
      (a transient blip is still retried).

  Each pass is a status-guarded `update_all`, so a race with a concurrent claim
  simply no-ops on rows the other path already moved. Returns
  `%{failed: n, requeued: n, released: n, pushing_failed: n, no_source_failed: n}`;
  an empty sweep returns all-zeros and never raises.
  """
  @spec reap_stale_deployments() :: %{
          failed: non_neg_integer(),
          requeued: non_neg_integer(),
          released: non_neg_integer(),
          pushing_failed: non_neg_integer(),
          no_source_failed: non_neg_integer()
        }
  def reap_stale_deployments do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    stale_before = DateTime.add(now, -deployment_stale_after_seconds(), :second)
    max_claims = max_deploy_claims()

    # (0) No build source — KIND-SCOPED (site-spawner D28). Two status-guarded
    # passes, summed into ONE `no_source_failed` count so the worker's asserted
    # return shape is unchanged. Both terminate a row that can NEVER build
    # (queued → failed) so the dashboard renders a real failure instead of an
    # eternal spinner. NOT staleness-gated — such a row is un-buildable the
    # instant it exists. Run FIRST so they only fail rows genuinely queued at
    # sweep start — never a row the requeue pass (ii) moves building → queued in
    # this same sweep.
    #
    # (0a) CONTAINER: no artifact_url AND a site with no connected github_repo.
    # `s.kind == "container"` is LOAD-BEARING, not cosmetic: a legitimate static
    # row (content-bound, artifact-less, repo-less) matches this predicate
    # exactly, so without the kind guard the sweep terminally fails every static
    # deploy within 60s — mislabelled with artifact/GitHub copy that names
    # neither its cause nor its cure.
    {container_failed, container_rows} =
      from(d in Deployment,
        join: s in Site,
        on: s.id == d.site_id,
        where:
          d.status == "queued" and s.kind == "container" and is_nil(d.artifact_url) and
            is_nil(s.github_repo),
        select: {d.id, d.site_id}
      )
      |> Repo.update_all(
        set: [
          status: "failed",
          failure_reason: @no_build_source_reason,
          updated_at: now
        ]
      )

    # (0b) STATIC: the twin, and the half a naive kind-scope forgets. A static
    # build reads its content from a Barkpark dataset, so its build source IS the
    # content binding — a site with no `bootstrap_dataset` has nothing to build
    # from and can never succeed. Without this pass an unbound static row matches
    # NOTHING (0a excludes it by kind) and spins `queued` forever: the exact
    # eternal-spinner disease the reaper exists to cure. The reason names the
    # cure the user can actually run.
    {static_failed, static_rows} =
      from(d in Deployment,
        join: s in Site,
        on: s.id == d.site_id,
        where: d.status == "queued" and s.kind == "static" and is_nil(s.bootstrap_dataset),
        select: {d.id, d.site_id}
      )
      |> Repo.update_all(
        set: [
          status: "failed",
          failure_reason: @no_content_binding_reason,
          updated_at: now
        ]
      )

    no_source_failed = container_failed + static_failed

    # (i) Over budget: fail it (don't requeue). Run before the requeue pass so an
    # exhausted row terminates — the requeue pass's status guard then skips it.
    {failed, failed_rows} =
      from(d in Deployment,
        where:
          d.status == "building" and d.claimed_at < ^stale_before and
            d.claim_epoch >= ^max_claims,
        select: {d.id, d.site_id}
      )
      |> Repo.update_all(
        set: [
          status: "failed",
          failure_reason: @stale_builder_reason,
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

    # (iii) Over budget: fail a stale `pushing` row whose `claim_epoch` has
    # reached `max_deploy_claims/0` — terminal, mirroring pass (i) for building.
    # `claim_pending_deployment_for_barkpark/2` bumps `claim_epoch` on every
    # re-claim, so a `pushing` row a permanently-down box keeps failing to accept
    # exhausts its budget; without this it would be re-released every sweep and
    # never fail (the eternal-spinner class this reaper exists to kill). Run
    # before the release pass so an exhausted row terminates instead of releasing.
    {pushing_failed, pushing_rows} =
      from(d in Deployment,
        where:
          d.status == "pushing" and not is_nil(d.claim_worker) and
            d.claimed_at < ^stale_before and d.claim_epoch >= ^max_claims,
        select: {d.id, d.site_id}
      )
      |> Repo.update_all(
        set: [
          status: "failed",
          failure_reason: @instance_unreachable_reason,
          claim_worker: nil,
          claimed_at: nil,
          updated_at: now
        ]
      )

    # (iv) Under budget: release a stale on-box agent claim — status stays
    # "pushing" so the agent's claim path re-matches it (a transient blip still
    # gets retried); only the claim is dropped. The status guard skips any row the
    # over-budget pass (iii) just failed.
    {released, _} =
      from(d in Deployment,
        where:
          d.status == "pushing" and not is_nil(d.claim_worker) and
            d.claimed_at < ^stale_before
      )
      |> Repo.update_all(set: [claim_worker: nil, claimed_at: nil, updated_at: now])

    # notifications (wave 28 S6): the reaper is the OTHER half of the covering
    # set. These four passes are bare `Repo.update_all` writes — no changeset, no
    # callback — so they never touch `transition_deployment_fenced/4`, and a
    # route-side-only dispatch would silently miss every reaped deployment. The
    # rows are named via `select:` in the query, NOT the `returning:` option: on
    # this Ecto (3.14.0) / Postgrex (0.22.2) pair `Repo.update_all(q, sets,
    # returning: [:id, :site_id])` returns `{n, nil}` — measured — while a `select`
    # in the query returns the rows for both the plain and the joined shapes.
    #
    # Fired after every pass has committed, so a row is already terminal on the
    # dashboard by the time its alert leaves.
    [
      {container_rows, @no_build_source_reason},
      {static_rows, @no_content_binding_reason},
      {failed_rows, @stale_builder_reason},
      {pushing_rows, @instance_unreachable_reason}
    ]
    |> Enum.flat_map(fn {rows, reason} ->
      Enum.map(rows || [], fn {id, site_id} -> {site_id, reason, %{deployment_id: id}} end)
    end)
    |> dispatch_reaped_deployment_alerts()

    %{
      failed: failed,
      requeued: requeued,
      released: released,
      pushing_failed: pushing_failed,
      no_source_failed: no_source_failed
    }
  end

  ## Helpers

  # notifications (wave 28 S6): fire `:deployment_failed` only on the EDGE into
  # `failed`. `Sites.Deploy.record_stage/2` re-drives the fenced writer on every
  # stage report and `status_for_stage/2` carries "failed" forward unchanged, so
  # a failed row is rewritten as `failed` routinely; without this guard one
  # broken deploy would email its owner once per stage report.
  defp maybe_dispatch_deployment_failed("failed", _updated), do: :ok

  defp maybe_dispatch_deployment_failed(_prior, %Deployment{status: "failed"} = updated),
    do: dispatch_deployment_failed(updated)

  defp maybe_dispatch_deployment_failed(_prior, _updated), do: :ok

  # wave 15 S4 (charter D248): the alert says WHICH deployment failed. Until now
  # the payload was exactly `%{detail: failure_reason}` plus the site name added
  # by `dispatch_site_event/3` — a cause with no subject, so three alerts in an
  # hour could not be told apart from three attempts at one push.
  defp dispatch_deployment_failed(%Deployment{} = deployment) do
    dispatch_deployment_failed(
      deployment.site_id,
      deployment.failure_reason,
      deployment_identity(deployment)
    )
  end

  # Site-keyed, because a Deployment only `belongs_to :site` and the alert's team
  # lives one hop further out. `Notifications.dispatch_site_event/3` resolves the
  # team through the site and names the site in the alert; it never raises.
  #
  # `identity` is whatever the call site actually HOLDS — the two struct-bearing
  # sites carry the full identity, the reaper carries the id its `select:`
  # already named. Nothing is synthesized to fill a gap.
  defp dispatch_deployment_failed(site_id, failure_reason, identity) when is_map(identity) do
    payload = Map.put(identity, :detail, failure_reason || "")

    Notifications.dispatch_site_event(site_id, :deployment_failed, payload)
  end

  # The deployment's own identity, and ONLY facts that are columns.
  #
  #   * `deployment_id` — actionable on its own: `GET
  #     /v1/sites/:id/deployments/:dep_id` is a real ability-gated read.
  #   * `stage` — nullable telemetry (PLAN/BUILD/STAGE/HEALTH/SWITCH/RETIRE);
  #     omitted when the row never reported one.
  #   * ONE code identity under its REAL column name — `git_ref` for a
  #     repo-driven build, else `content_rev` for a content-bound static one,
  #     else the `build_id` hash. There is no commit-sha column; a key named
  #     `commit` would be an invention.
  #
  # NO DURATION, deliberately. `deployments` has no started_at/finished_at,
  # `became_live_at` is NULL on every failed row, and `updated_at - inserted_at`
  # is not build time (`Sites.Deploy.record_stage/2` writes RETIRE-skipped
  # console entries onto rows that are already failed — measured median drift
  # 65s, max 2,270s). A fabricated number is worse than an absent one.
  defp deployment_identity(%Deployment{} = deployment) do
    %{deployment_id: deployment.id}
    |> put_present(:stage, deployment.stage)
    |> put_code_identity(deployment)
  end

  defp put_code_identity(identity, %Deployment{git_ref: ref}) when is_binary(ref) and ref != "",
    do: Map.put(identity, :git_ref, ref)

  defp put_code_identity(identity, %Deployment{content_rev: rev})
       when is_binary(rev) and rev != "",
       do: Map.put(identity, :content_rev, rev)

  defp put_code_identity(identity, %Deployment{build_id: id}) when is_binary(id) and id != "",
    do: Map.put(identity, :build_id, id)

  defp put_code_identity(identity, %Deployment{}), do: identity

  defp put_present(identity, _key, value) when value in [nil, ""], do: identity
  defp put_present(identity, key, value), do: Map.put(identity, key, value)

  # The capped fan-out described at `@reap_alert_cap`.
  defp dispatch_reaped_deployment_alerts([]), do: :ok

  defp dispatch_reaped_deployment_alerts(alerts) do
    {send_now, dropped} = Enum.split(alerts, @reap_alert_cap)

    Enum.each(send_now, fn {site_id, reason, identity} ->
      dispatch_deployment_failed(site_id, reason, identity)
    end)

    if dropped != [] do
      # The Logger line stays — operators read logs during an incident — but it is
      # no longer the ONLY trace. Wave 32 S2: the cap decided, on the owner's
      # behalf, that they would not hear about their own failed deployment, and
      # that decision is now a `suppressed` row on the delivery log they can read.
      Logger.warning(
        "reap_stale_deployments: #{length(dropped)} deployment_failed alerts suppressed " <>
          "(cap #{@reap_alert_cap}/sweep); the rows are terminal in the console"
      )

      record_withheld_reap_alerts(dropped)
    end

    :ok
  end

  # Site → team is OURS to resolve (a Deployment only `belongs_to :site`), so the
  # hop happens here and `Notifications.Withhold` receives an already-resolved
  # team_id. One batched lookup, not one per dropped alert — a mass reap is
  # exactly the moment not to fire N queries. A since-deleted site simply has no
  # team and drops out of the map.
  defp record_withheld_reap_alerts(dropped) do
    site_ids = dropped |> Enum.map(fn {site_id, _reason, _identity} -> site_id end) |> Enum.uniq()

    teams_by_site =
      from(s in Site, where: s.id in ^site_ids, select: {s.id, s.team_id})
      |> Repo.all()
      |> Map.new()

    Enum.each(dropped, fn {site_id, _reason, _identity} ->
      case Map.get(teams_by_site, site_id) do
        team_id when is_binary(team_id) ->
          Withhold.record(team_id, "deployment_failed", :reap_alert_cap)

        _absent ->
          :ok
      end
    end)
  end

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
