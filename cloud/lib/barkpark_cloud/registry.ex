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

  alias BarkparkCloud.Registry.{
    AgentEvent,
    AgentToken,
    Barkpark,
    Deployment,
    EnvVar,
    Provider,
    ProvisionJob,
    Site,
    Vault
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

  ## Barkparks

  @doc """
  Register a Barkpark for `team` from `attrs`. The Team is taken from the first
  argument (struct or id) — `attrs` need not (and should not) carry `:team_id`.

  Returns `{:ok, %Barkpark{}}` or `{:error, %Ecto.Changeset{}}` (e.g. the slug
  already exists in this team).
  """
  @spec register_barkpark(Team.t() | binary(), map()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def register_barkpark(team, attrs) do
    %Barkpark{}
    |> Barkpark.changeset(put_team_id(attrs, team))
    |> Repo.insert()
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
  """
  @spec register_managed_barkpark(Team.t() | binary(), String.t(), String.t()) ::
          {:ok, Barkpark.t()} | {:error, Ecto.Changeset.t()}
  def register_managed_barkpark(team, name, slug) do
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

    case register_barkpark(team, Map.put(attrs, :url, candidate)) do
      {:ok, barkpark} ->
        {:ok, barkpark}

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

  @doc "Fetch a Barkpark by id, or nil."
  @spec get_barkpark(binary()) :: Barkpark.t() | nil
  def get_barkpark(id), do: Repo.get(Barkpark, id)

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

  ## Provisioning jobs — the queue bridging this control plane and the Go worker

  @doc """
  Enqueue a `pending` provision job for `barkpark` — the async half of go-live.
  After the pay + registry write, this is what hands the work to the off-box Go
  warm-pool provisioner. Returns `{:ok, %ProvisionJob{}}`.
  """
  @spec enqueue_provision_job(Barkpark.t() | binary()) ::
          {:ok, ProvisionJob.t()} | {:error, Ecto.Changeset.t()}
  def enqueue_provision_job(barkpark) do
    %ProvisionJob{}
    |> ProvisionJob.changeset(%{barkpark_id: barkpark_id(barkpark), status: "pending"})
    |> Repo.insert()
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
    end
  end

  defp active_deprovision_job?(barkpark_id) do
    active_job_of_kind?(barkpark_id, "deprovision")
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
  """
  @spec succeed_job(binary(), String.t(), keyword()) ::
          {:ok, ProvisionJob.t()} | {:error, :not_found | :conflict | Ecto.Changeset.t()}
  def succeed_job(id, ip, opts \\ []) when is_binary(id) and is_binary(ip) and is_list(opts) do
    admin_token = Keyword.get(opts, :admin_token)

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
                 {:ok, _barkpark} <- upsert_succeeded_barkpark(job, ip, admin_token) do
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
  defp upsert_succeeded_barkpark(%ProvisionJob{barkpark_id: barkpark_id}, ip, admin_token) do
    case Repo.get(Barkpark, barkpark_id) do
      nil ->
        {:ok, nil}

      %Barkpark{} = barkpark ->
        %{health_status: "up", host: ip, agent_status: "offline"}
        |> maybe_put_admin_token(admin_token)
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
          binary() => %{status: String.t(), error: String.t() | nil}
        }
  def latest_provision_status_map([]), do: %{}

  def latest_provision_status_map(ids) when is_list(ids) do
    from(j in ProvisionJob,
      where: j.barkpark_id in ^ids and j.kind == "provision",
      order_by: [asc: j.barkpark_id, desc: j.inserted_at, desc: j.id],
      distinct: j.barkpark_id,
      select: {j.barkpark_id, j.status, j.error}
    )
    |> Repo.all()
    |> Map.new(fn {bp_id, status, error} -> {bp_id, %{status: status, error: error}} end)
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
          Repo.get_by(EnvVar, team_id: tid, key: key, barkpark_id: bid)

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

  @doc "Fetch a Site by id, or nil."
  @spec get_site(binary()) :: Site.t() | nil
  def get_site(id), do: Repo.get(Site, id)

  @doc """
  Fetch a Site by id only if it belongs to `team` — the team-scoped read for the
  user-facing API. Returns `nil` if the site exists but is owned by another
  team (an existence leak protection: callers cannot distinguish "wrong team"
  from "no such site").
  """
  @spec get_team_site(Team.t() | binary(), binary()) :: Site.t() | nil
  def get_team_site(team, id) do
    tid = team_id(team)

    Site
    |> where([s], s.id == ^id and s.team_id == ^tid)
    |> Repo.one()
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

  @doc "List a Site's deployments, newest first."
  @spec list_deployments(Site.t() | binary()) :: [Deployment.t()]
  def list_deployments(site) do
    site_id = site_id(site)

    Deployment
    |> where([d], d.site_id == ^site_id)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc "Fetch a Deployment by id, or nil."
  @spec get_deployment(binary()) :: Deployment.t() | nil
  def get_deployment(id), do: Repo.get(Deployment, id)

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
          case d |> Deployment.transition_changeset(attrs) |> Repo.update() do
            {:ok, updated} -> updated
            {:error, cs} -> Repo.rollback(cs)
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
          with {:ok, updated} <-
                 d |> Deployment.transition_changeset(deployment_attrs) |> Repo.update(),
               {:ok, _site} <-
                 d.site |> Site.runtime_changeset(site_attrs) |> Repo.update() do
            updated
          else
            {:error, cs} -> Repo.rollback(cs)
          end
      end
    end)
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

  ## Helpers

  # Guard a :binary_id PK lookup: a non-UUID id (a malformed path param) makes
  # Repo.get raise Ecto.Query.CastError → an HTTP 500. Returning nil here for a
  # non-castable id routes it to the {:error, :not_found} branch (→ 404), which is
  # what the API documents for an absent/invalid job id. A valid UUID passes
  # through unchanged.
  defp uuid_or_nil(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

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
