defmodule BarkparkCloud.Sites.AutoDeployWorker do
  @moduledoc """
  site-spawner W5 (charter D44/D48): the CP-side DEBOUNCE that turns a burst of
  content publishes into exactly ONE re-deploy of the bound static site — and
  still re-deploys after an in-flight build, so a publish that lands mid-build is
  never silently lost.

  ## The debounce is the whole point (charter D44)

  This is an Oban `unique` job keyed on `site_id`, in states `[:available,
  :scheduled]` — deliberately DROPPING `:executing` from the prior-art
  (`indx`/`edge_projector`) triple. That drop is load-bearing:

    * a BURST of publishes before any build starts all match the one `:scheduled`
      job → collapse to ONE trailing rebuild (a ~10s npm build must not run N
      times for N near-simultaneous publishes);
    * a publish that lands WHILE a build is `:executing` finds NO conflict (the
      running job is `:executing` ∉ the unique states) → it inserts a fresh job,
      which fires AFTER the in-flight build snapshotted its content. Keeping
      `:executing` in the states would swallow that publish (the running job
      already read the old content at build start) and serve STALE content — the
      exact failure the wish forbids.

  `schedule_in` a short window (~5s) so a rapid burst lands inside one
  `:scheduled` job's window before it starts. The box's own publish→notify path
  is UNDEBOUNCED (no box+CP double-debounce); all coalescing happens here.

  ## What perform does (charter D48)

  Load the site + its box, then `Sites.Deploy.enqueue(site, bp, force: true,
  trigger: "content-auto")` and hand the row to the driver. `force` folds a nonce
  into `build_id` so a byte-identical republish still mints a fresh
  `releases/<build_id>/` — safe HERE precisely because the debounce guarantees
  single-fire (`force` is the opposite of a dedup key; the `site_id` unique is
  what prevents the race, not the `(site_id, build_id)` index). Fail-closed HEALTH
  + the force nonce then inherit for free from the proven manual deploy path.

  The build itself runs the SAME way a manual deploy does — `Deploy.start_reported/1`
  spawns the supervised, claim-fenced, reaper-recoverable driver AND reports whether
  the spawn happened (the fire-and-forget `Deploy.start/1` that used to be named here
  was deleted in deploy-reliability W17: it laundered a refusal into `:ok`) — so a crashed
  auto-rebuild is swept exactly like a crashed manual one. The `:site_deploy`
  queue is concurrency-1 so the enqueue+start step is serial per box, and the box
  itself flock-serializes the build.

  ## The PREBUILT REFUSAL (charter D92/D105) — with a USER-VISIBLE row

  A site whose CURRENT release was uploaded (`source = "prebuilt"`) is REFUSED
  here. Unguarded, this worker is the FAST half of the unbidden overwrite: it
  enqueues with `source` at its `"box-build"` default, the box rebuilds from
  source, HEALTH passes honestly on the box's OWN bytes, SWITCH is
  provenance-blind — and the uploaded release is replaced by bytes this fleet
  invented, then eventually DELETED by RETIRE (keep newest 5) so rollback cannot
  recover it. It fires on the next content publish, i.e. within the debounce
  window; the hourly `TemplateFreshnessWorker` sweep is the slower half (a
  one-hour ceiling — see its moduledoc).

  The refusal MINTS A ROW (status `cancelled`, trigger `content-auto`, source
  `prebuilt`) and only then returns a cancel tuple. It owes that row because the
  content-publish webhook already answered `202 ok` BEFORE any guard could run:
  a silent Oban cancel would make the control plane's only trace of a refused
  promise a job record no user surface reads. No migration — `cancelled` is
  already in the status enum, and `detail`/`failure_reason` already exist.

  It MUST be `{:cancel, _}`, never `{:error, _}`: Oban maps an error tuple to a
  failure, retries to `max_attempts`, then DISCARDS — a permanent, correct
  refusal would then be indistinguishable from a box outage.

  The guard keys on the CURRENT RELEASE'S `source`, NEVER on
  `sites.prebuilt_enabled` — the flag is an opt-in, not a provenance fact.
  """

  use Oban.Worker,
    queue: :site_deploy,
    max_attempts: 3

  # charter D44: DROP :executing. A publish during a running build must NOT
  # conflict with the executing job (that job already snapshotted the old content)
  # — it must mint a trailing rebuild. A burst BEFORE the build starts still
  # collapses to the one :scheduled job. The unique is specified at INSERT time
  # (not on `use Oban.Worker`) on purpose: the macro form warns that dropping
  # :executing "may break uniqueness" — but here that drop IS the design, and the
  # cloud CI compiles --warnings-as-errors.
  # period must comfortably cover the debounce window (60s default) so a publish
  # near the window's end still finds the scheduled job — 300 is window-agnostic
  # headroom; the [:available, :scheduled] state filter is what actually gates.
  @unique [keys: [:site_id], states: [:available, :scheduled], period: 300]

  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.Withhold
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.{Barkpark, Deployment, Site}
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Sites.Deploy

  require Logger

  # The debounce window (seconds). A burst of publishes within this window before
  # the job starts all collapse onto the single :scheduled job.
  #
  # DEFAULT 60, was 5 (D44 amendment, measured 2026-07-18): on a 2-core box a
  # site build takes 2-4 MINUTES, and a steady publish stream (agents filing
  # tasks into the content dataset every minute or two) re-triggered faster than
  # builds completed — the box built CONTINUOUSLY for hours (observed 2-4
  # concurrent `astro build`s, search latency 600ms→3-5.6s before the builds
  # were niced). With builds queued behind builds, effective publish-to-live was
  # already minutes, so a 5s window bought no real freshness — it only minted
  # wasted intermediate builds. 60s coalesces a publishing session into ~one
  # build per site per minute; override per deployment with AUTODEPLOY_DEBOUNCE_S.
  @schedule_in_default 60

  @doc """
  The debounce window (seconds) a plain publish-triggered enqueue schedules at —
  `@schedule_in_default`, or `AUTODEPLOY_DEBOUNCE_S` when it parses and clears
  the floor. Public because `Sites.Deploy` derives the DEFER backoff from it
  (`Deploy.deferral_backoff_seconds/1`): the backoff is a MULTIPLE of the
  operator's own window, never a second, independently-tuned constant that could
  silently disagree with it.
  """
  @spec debounce_seconds() :: pos_integer()
  def debounce_seconds, do: schedule_in()

  defp schedule_in do
    case System.get_env("AUTODEPLOY_DEBOUNCE_S") do
      nil ->
        @schedule_in_default

      raw ->
        case Integer.parse(raw) do
          # Floor 5: the pre-amendment value — never LESS debounced than D44.
          {n, ""} when n >= 5 -> n
          _ -> @schedule_in_default
        end
    end
  end

  @doc """
  Enqueue (or coalesce onto) the debounced auto-deploy for `site_id`. Returns
  whatever `Oban.insert/1` returns — on a unique conflict that is `{:ok, job}`
  with the EXISTING scheduled job, so N calls in the window yield ONE job.
  """
  @spec enqueue(binary()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(site_id) when is_binary(site_id) do
    enqueue(site_id, schedule_in())
  end

  @doc """
  Enqueue at an EXPLICIT window (seconds) — the DEFER paths' form
  (deploy-reliability W20).

  Two callers pass a window: `defer_behind_running_build/2` here, and
  `Sites.Deploy`'s deferral arm via `requeue_rebuild/2`. Both derive it from
  `Deploy.deferral_backoff_seconds/1`, so a chain that is already six rounds deep
  stops re-firing on the same blind 60s clock that paced it there (measured: p50
  61.6s between consecutive deferrals of a site, 63.7% inside the 55-75s band —
  the clock, not the box, set the cadence).

  It is a SEPARATE ARITY, not a default argument, on purpose: the publish webhook
  and the manual/API trigger must keep the plain debounce, and a default argument
  would let a mis-edit hand them the backoff while every existing test stayed
  green. `auto_deploy_worker_test.exs` pins both untouched callers on arity 1.

  NO `replace:` OPTION IS PASSED, HERE OR ANYWHERE (charter W19 probe P6):
  `replace` has no max/min semantics, so with a 900s deferral pending an ordinary
  60s publish would drag it back to 59s — a publish-triggered reset of the very
  backoff this exists to hold, with all tests still green. Without it the defer
  insert is written VERBATIM, because the sibling it would have conflicted with is
  `:executing` (∉ `@unique` states) or already gone.
  """
  @spec enqueue(binary(), pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(site_id, schedule_in)
      when is_binary(site_id) and is_integer(schedule_in) and schedule_in > 0 do
    %{site_id: site_id}
    |> new(schedule_in: schedule_in, unique: @unique)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"site_id" => site_id}}) do
    with %Site{} = site <- Registry.get_site(site_id),
         %Barkpark{} = bp <- Registry.get_barkpark(site.barkpark_id) do
      if prebuilt_release?(site) do
        refuse(site)
      else
        drive(site, bp)
      end
    else
      # The site (or its box) was deleted between the publish and this run — there
      # is nothing to rebuild. Cancel, not retry: a retry would never find it.
      _ -> {:cancel, :site_or_box_gone}
    end
  end

  # Does this site's CURRENT release carry uploaded bytes? See the moduledoc: the
  # live release's `source` is the provenance fact; `site.prebuilt_enabled` is
  # only an opt-in and a site can be enabled while still serving a box build.
  defp prebuilt_release?(%Site{current_deployment_id: nil}), do: false

  defp prebuilt_release?(%Site{current_deployment_id: id}) do
    case Registry.get_deployment(id) do
      %Deployment{} = deployment -> Deployment.prebuilt?(deployment)
      nil -> false
    end
  end

  @refusal_detail "refused: this site's live release was uploaded (prebuilt), so a content publish must not trigger a box rebuild — it would replace bytes this fleet cannot reproduce. Ship new bytes with `bp cloud site deploy <site> --prebuilt <dir>`."

  @doc """
  The refusal sentence this worker writes into the `cancelled` deployment row's
  `detail` and `failure_reason` — the exact string the console renders.

  PUBLIC because the alert email must deliver THIS string rather than a re-typed
  twin (cch-w29-bl). `Notifications.EventEmail`'s `:deployment_refused` arm
  renders whatever the dispatch payload carries as `:detail`, and this is what
  `refuse/1` puts there, so the inbox and the console name the same remedy by
  construction. A second copy of the sentence is a second thing to forget to
  update, and the surface a person reads when they were NOT at the console is
  precisely the one that must not carry the stale copy.
  """
  @spec refusal_detail() :: String.t()
  def refusal_detail, do: @refusal_detail

  # The USER-VISIBLE refusal (charter D92/D105). The webhook already answered 202,
  # so the refusal owes a row in the deployment stream — not just a job record.
  #
  # `status` is not castable on create (the schema forbids it; transition_changeset
  # is the sole status mutator), so the row is born `queued` and moved
  # `queued → cancelled` (a legal edge) in the SAME transaction: there is no
  # window in which a claimer or the stale-deployment reaper can observe a
  # claimable row that was never meant to build.
  #
  # `source: "prebuilt"` labels WHAT was protected, not what was built — the row
  # is the record of a refusal to build, and reading it as a box build would
  # invert its meaning.
  defp refuse(%Site{} = site) do
    result =
      Repo.transaction(fn ->
        with {:ok, queued} <-
               Registry.create_deployment(site, %{
                 trigger: "content-auto",
                 source: "prebuilt"
               }),
             {:ok, cancelled} <-
               Registry.transition_deployment(queued, %{
                 status: "cancelled",
                 failure_reason: @refusal_detail,
                 detail: @refusal_detail
               }) do
          cancelled
        else
          {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
        end
      end)

    case result do
      {:ok, cancelled} ->
        Logger.info(
          "auto-deploy refused for site #{site.id}: live release is prebuilt — cancelled row minted"
        )

        # cch-w29-bl — THE REFUSAL LEAVES THE CONSOLE.
        #
        # The row above is a CONSOLE trace: it reaches the person who opens the
        # deployment stream and nobody else. The content-publish webhook already
        # answered `202 ok` before this guard could run, so a person who
        # published and walked away had been promised a deploy and told nothing
        # when it was refused. This is the first dispatch site this worker has
        # ever had.
        #
        # `dispatch_site_event/3` and not `dispatch_event/3`: this module holds a
        # Site, not a Team, and that helper owns the site → team hop (and puts
        # the site's NAME in the payload, so the alert names what was refused).
        # It is best-effort by contract — it never raises into a caller and a
        # since-deleted site is a silent `:ok` — so the refusal below cannot be
        # broken by the alert.
        #
        # OUTSIDE the transaction, deliberately: a send inside `Repo.transaction`
        # would mail about a row a later rollback could still erase.
        Notifications.dispatch_site_event(site.id, :deployment_refused, %{
          detail: @refusal_detail,
          deployment_id: cancelled.id
        })

      {:error, reason} ->
        # The row is the courtesy; the REFUSAL is the contract. A row we could not
        # write must never degrade into a box rebuild, and must not retry either
        # (the retry would rebuild nothing and re-fail the same way).
        Logger.warning(
          "auto-deploy refusal row failed for site #{site.id}: #{inspect(reason)} — refusing anyway"
        )

        # cch-w31-bl — AND THE PERSON STILL HEARS ABOUT IT.
        #
        # This arm used to end at the Logger line. The publish was refused, the
        # transaction rolled back, so there was NO deployment row, NO alert (the
        # `:ok` arm above is the only dispatch site) and nothing on any surface a
        # person can read: their content simply never went live, silently,
        # forever. An operator log is not a person-facing trace.
        #
        # It is routed through `Notifications.Withhold`, the funnel wave 32 built
        # for exactly this shape, rather than through a second mechanism invented
        # here: the system was positioned to send the `deployment_refused` alert,
        # did not send it (it would name a deployment row that does not exist),
        # and wrote nothing. That is this repo's definition of a silent withhold,
        # and the answer to it is one `suppressed` `Delivery` row per team member
        # carrying a CLOSED-VOCABULARY sentence — `Withhold.label/1`, no
        # interpolation, so the changeset error never reaches a page a team admin
        # reads.
        #
        # `record/4` never raises (it rescues to `0`) and its count is discarded
        # here for the same reason the row above is a courtesy: the REFUSAL is
        # the contract, and a trace must not be able to break the branch it
        # traces.
        Withhold.record(site.team_id, "deployment_refused", :deployment_refusal_unrecorded)
    end

    # NEVER {:error, _}: Oban would retry to max_attempts and then DISCARD, making
    # a permanent, correct refusal look exactly like a box outage.
    {:cancel, :prebuilt_release_protected}
  end

  defp drive(site, bp) do
    # charter D48: force: true + trigger: content-auto. The debounce guarantees
    # single-fire, so force minting a genuinely-new build is safe (and belt-and-
    # suspenders against a republish whose content_rev happened not to change).
    case Deploy.enqueue(site, bp, true, "content-auto") do
      {:ok, deployment} ->
        start_and_report(site, deployment)

      # force should never dedup on build_id (fresh nonce every run). What DOES
      # land here since the active-deployment re-key (deploy-truth W1, charter
      # D10) is the site's row already in flight: `(site_id, environment)` now
      # refuses a second concurrent production build, so this publish coalesces
      # onto it. Re-driving is right either way — a still-`queued` row reads the
      # NEW content when it starts, and an already-building one answers
      # `:not_queued`, which defers below instead of dropping the publish.
      {:duplicate, %Deployment{status: "queued"} = deployment} ->
        start_and_report(site, deployment)

      # The row it coalesced onto is ALREADY BUILDING (or settled). Driving it
      # again would either lose the claim race or re-run a finished build, and
      # the content this publish carries would never be read — so defer HERE,
      # where it is knowable. In production the starter is asynchronous, so a
      # claim failure discovered inside the spawned driver could never travel
      # back to this job; this is the arm that actually fires.
      {:duplicate, deployment} ->
        defer_behind_running_build(site, deployment)

      # A transient enqueue failure (e.g. the box's content-rev read) — let Oban
      # retry within max_attempts rather than silently swallow the publish.
      {:error, reason} ->
        Logger.warning(
          "auto-deploy enqueue failed for site #{site.id}: #{inspect(reason)} — retrying"
        )

        {:error, reason}
    end
  end

  # THE OUTCOME IS INSPECTED (deploy-truth W1, charter D9). This used to be
  # `:ok = Deploy.start(deployment); :ok` — a match against a starter that
  # returned a literal `:ok` no matter what happened, which is why production's
  # `site_deploy` queue holds 11,868 completed jobs and ZERO retryable ones while
  # 8,830 deploys were refused by a busy box.
  defp start_and_report(site, deployment) do
    case Deploy.start_reported(deployment) do
      # Production: the supervised driver is running. Its outcome settles on the
      # row (and a busy box defers + re-fires from inside the run).
      {:ok, :started} ->
        :ok

      # A synchronous driver ran to a settled state. `:failed` is RECORDED on the
      # row with the box's own reason — returning an Oban error would retry a
      # build that just failed for a reason a retry cannot change — but the value
      # travels so the job record says which it was.
      {:ok, outcome} when outcome in [:live, :failed, :deferred] ->
        {:ok, outcome}

      # The row is already claimed — the site is mid-build. THIS is the publish
      # that used to be lost: it minted a second row, the box answered 409, and
      # the row died terminal-`failed` with nothing to re-drive it. Re-fire the
      # debounce instead: the trailing job re-reads the site's CURRENT content
      # after the in-flight build finishes.
      {:error, :not_queued} ->
        defer_behind_running_build(site, deployment)

      # The driver never started and nothing recorded the build. The row is still
      # `queued`, so a retry (and, failing that, the stale-deployment reaper) can
      # still pick it up — never report success.
      {:error, reason} ->
        Logger.warning(
          "auto-deploy could not start the driver for site #{site.id}: #{inspect(reason)} — retrying"
        )

        {:error, reason}
    end
  end

  # A COUNTED, RE-FIRING deferral (charter D9) for the case where the control
  # plane refuses the second build itself rather than letting the box refuse it.
  #
  # There is no new row to mark `deferred` here — the active-deployment index
  # (correctly) refused to mint one, and the row in flight is a real build that
  # must not be relabelled. The promise is the re-queued job, so a re-queue that
  # FAILS must not be reported as success: it becomes an Oban error, which retries.
  #
  # NOT `{:snooze, n}`: snooze increments `attempt` against `max_attempts: 3`, so
  # three busy rounds would DISCARD the job. A fresh debounced job carries no
  # attempt history at all, and its `site_id` unique collapses repeats onto one.
  #
  # THE RE-FIRE IS NO LONGER BLIND (deploy-reliability W20). This path holds only
  # the site and the in-flight row — it has no `cause` and mints no row of its
  # own, so it cannot count its own chain. It asks `Sites.Deploy` for the depth
  # instead of inventing a second, differently-shaped backoff: one owner for the
  # window, so the two defer paths can never disagree about how long a chain of a
  # given depth waits.
  defp defer_behind_running_build(site, %Deployment{} = in_flight) do
    case enqueue(site.id, Deploy.deferral_backoff_seconds(site)) do
      {:ok, _job} ->
        # THE ATTEMPT THAT MINTS NO ROW NOW SPEAKS (deploy-reliability W12, S6).
        # Everything above this line stays true — no fake `deferred` row is
        # minted, and the real build in flight is not relabelled — but the
        # attempt is no longer INVISIBLE: it is counted on the row it coalesced
        # ONTO, which is the only truthful home for it. This attempt did not
        # produce a build; it joined one.
        record_coalesced_attempt(in_flight)

        Logger.info(
          "auto-deploy deferred for site #{site.id}: deployment #{in_flight.id} is already #{in_flight.status} — rebuild re-queued"
        )

        {:ok, :deferred}

      {:error, reason} ->
        Logger.warning(
          "auto-deploy could not re-queue the deferred rebuild for site #{site.id}: #{inspect(reason)} — retrying"
        )

        {:error, reason}
    end
  end

  # HOW MANY PUBLISHES THIS BUILD IS ANSWERING FOR — the count of attempts that
  # minted no row of their own, hung on the in-flight row they coalesced onto.
  #
  # WHY IT MATTERS EVEN THOUGH IT IS QUIET TODAY, measured from Oban rather than
  # guessed: in the twelve hours 2026-08-06 08:00-20:00Z there were 2,256
  # `AutoDeployWorker` jobs against 1,052 deployment rows — 1,204 ATTEMPTS THAT
  # MINTED NO ROW against 277 counted deferrals (4.35:1). Since 22:00Z the same
  # ratio is 0.086:1 and zero per minute. That is DORMANT, not fixed: the gap is
  # a function of publish load against build duration, so it returns precisely
  # when the number is worth having.
  #
  # "Attempts that minted no row", never "uncounted deferrals": the
  # `{:duplicate, %{status: "queued"}}` re-drive arm above has the same shape and
  # the two are indistinguishable once written down, so the honest name is the
  # one that describes what was observed rather than what it is assumed to mean.
  #
  # ATOMIC `UPDATE`, never a changeset: N publishes can race one build from N
  # processes, and a read-modify-write would drop every attempt but the last —
  # which is the whole count. `COALESCE` because the 30,633 rows that predate the
  # column are NULL (honestly unknown), and `NULL + 1` is NULL.
  #
  # Best-effort telemetry: the return value is discarded and a row that vanished
  # between the coalesce and this write updates zero rows without raising. The
  # DEFERRAL is the contract; the count is the record of it.
  defp record_coalesced_attempt(%Deployment{id: id}) do
    now = DateTime.utc_now()

    from(d in Deployment,
      where: d.id == ^id,
      update: [
        set: [
          coalesced_attempts: fragment("COALESCE(?, 0) + 1", d.coalesced_attempts),
          coalesced_last_at: ^now
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end
end
