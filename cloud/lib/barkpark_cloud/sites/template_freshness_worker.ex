defmodule BarkparkCloud.Sites.TemplateFreshnessWorker do
  @moduledoc """
  stw9 (charter D57b): the hourly, UNFORCED freshness sweep — the half of "a
  merged template change reaches live sites" that no human triggers.

  ## What it does

  Once an hour, for every deployed content-bound site (`static` | `node` with a
  bootstrap dataset and at least one deployment — `Registry.list_deployed_content_sites/0`):

      Deploy.enqueue(site, bp, false, "template-auto", probed_content_rev)

  and, only when that actually minted a NEW row, `Deploy.start_reported/1`.
  Nothing else.

  ## Why UNFORCED is the entire design (never force on a schedule)

  `force: true` folds a timestamp nonce into `build_id`, which is exactly what
  `AutoDeployWorker` wants (a debounced, human-caused, single-fire republish) and
  exactly what a TIMER must never do: a forced hourly sweep would mint a real
  build for every site every hour forever, and the search-template boxes are
  2-core machines where one site build takes 2-4 minutes (the D44 amendment
  measured builds queueing behind builds for hours). Unforced, `build_id =
  hash(code_rev + content_rev + config)` is stable across ticks, so the
  `(site_id, build_id)` unique index collapses an unchanged site to `{:duplicate,
  _}` — a pure no-op, no build, no driver start. The sweep costs one analytics
  read per site per hour when nothing moved.

  ## The content_rev SKIP (the build-storm tripwire)

  `Deploy.enqueue/5` computes `content_rev` FAIL-OPEN when it is not handed one:
  an unreadable revision
  degrades to a fresh random `"u…"` marker so a human-triggered deploy never
  serves stale content. On a schedule that fail-open inverts into a weapon — a
  box whose analytics read is failing would produce a DIFFERENT content_rev, and
  therefore a different `build_id`, on every single tick: a build storm generated
  by the very sickness that should suppress it.

  So this worker probes first with `Deploy.content_rev_probe/2` (the same read,
  without the fail-open) and SKIPS the site on `:error`. A box we cannot read is a
  box we do not schedule work onto. The next tick tries again; nothing is lost,
  because there is nothing to lose — an unreadable box could not have built either.

  ## Why the sweep only bites AFTER the CI filter fix (D57a is a prerequisite)

  `build_id` is template-digest-BLIND: it hashes the box's `code_rev` (the
  instance's own git commit), the content_rev, and the site config — never the
  contents of `templates/`. A templates-only merge therefore changes the build
  input ONLY once it has advanced the box's `code_rev`, i.e. once the box has
  been redeployed. That is precisely what D57a fixes in
  `.github/workflows/deploy.yml` (`templates/**` was listed in `on.push.paths`
  but matched NEITHER job regex, so a templates-only merge deployed nothing and
  reported green). With that landed, a template merge rolls the box → `code_rev`
  moves → this sweep's next unforced enqueue mints a genuinely new `build_id` →
  live sites pick the template up. Without it the sweep is a correct no-op, by
  design, not by accident.

  ## The per-box start cap (fan-out control)

  The `:site_deploy` queue's concurrency 1 serializes JOBS, not builds:
  `AutoDeployWorker` starts one build per job, so for it the queue really is a
  serial gate — but this worker visits the whole fleet in ONE job, and
  `Deploy.start_reported/1` hands each site to a supervised Task immediately. The box
  single-flights per SLUG only, so after any instance roll (`code_rev` is the
  box's git commit and advances on every `api/**`/`internal/**`/`deploy/**`/
  `templates/**` merge) an uncapped sweep would start K concurrent builds on a
  2-core box that is also serving the content API.

  So: at most ONE build start per box per tick (`@max_starts_per_box`).
  Sites past the cap are counted `deferred` and cost nothing — an unchanged site
  collapses to `duplicate` next tick anyway, and a changed one is picked up one
  tick later. A box with N stale sites converges over N hours instead of
  contending for one.

  ## Failure posture

  Per-site failures are isolated and logged; one unreachable box never aborts the
  sweep for the rest of the fleet. `perform/1` returns `{:ok, summary}` with the
  counts (`enqueued`, `duplicate`, `skipped`, `failed`, `deferred`, `refused`) so
  a run reads honestly in the Oban job record.

  ## The INERT-SWEEP counter (`code_rev_unknown`)

  `build_id` hashes the box's `code_rev`, and `Deploy.code_rev/1` falls back to
  the CONSTANT `"unknown"` when a box has reported neither `git_commit` nor
  `version`. A frozen `code_rev` means a code roll can never change `build_id`,
  so this sweep returns `:duplicate` for that site every tick, forever — a
  summary key-for-key IDENTICAL to a healthy quiet fleet's. It is latent today
  (all deployed sites ride a box reporting a moving `git_commit`) and lethal to
  observability the day it isn't.

  So the summary carries a SIXTH KEY, `code_rev_unknown`, plus a `Logger.warning`.
  It is a KEY, never a sixth OUTCOME atom: the reduce is `Map.update!(acc,
  outcome, …)` over a seeded map, so an unseeded atom raises `KeyError` at
  runtime. It is incremented ALONGSIDE the real outcome, not instead of it.

  ## The PREBUILT REFUSAL (charter D92/D105) — and its one-hour perishability

  A site whose CURRENT release was uploaded (`source = "prebuilt"`) is REFUSED,
  counted `refused`, and gets NO deployment row. Without the refusal this sweep
  is the unbidden overwrite: it enqueues an ordinary box build (`source`
  defaults to `"box-build"`), the box rebuilds from source, HEALTH passes
  honestly on the box's OWN bytes, SWITCH is provenance-blind — and the uploaded
  release is gone. RETIRE (keep newest 5) eventually DELETES it, so rollback
  cannot get it back either.

  PERISHABILITY, the reason this refusal is not optional: the unforced sweep
  no-ops only while an UNFORCED BOX-BUILD row already exists at the current
  `code_rev`/`content_rev`/config tuple, and a prebuilt `build_id` can NEVER be
  that row — the mint folds a `prebuilt_nonce` (`Deploy.maybe_prebuilt_nonce/2`),
  so it hashes outside the unforced tuple by construction. Therefore an
  unguarded sweep mints a real box build for a prebuilt-current site on its very
  next tick: any live prebuilt release has a ONE-HOUR ceiling (the 41-past cron)
  and a floor of the next tick.

  The guard keys on the CURRENT RELEASE'S `source`, NEVER on
  `sites.prebuilt_enabled`. The flag is an OPT-IN, not a provenance fact: a site
  can be enabled and still be serving a box build, and keying on the flag would
  freeze that site's template freshness FOREVER. Both directions are tested.

  NO deployment row is minted for a refusal, deliberately: 24 rows per day per
  site would bury the deployment stream, and no user intent stands behind a
  timer tick (the CONTENT path is the opposite case — a human published, and the
  webhook already answered 202, so `AutoDeployWorker` owes a visible row).

  `refused` is a SEEDED key in the zero map for the same reason
  `code_rev_unknown` is: the reduce is `Map.update!(acc, outcome, …)`, so an
  unseeded atom raises `KeyError` mid-reduce and aborts the sweep for the WHOLE
  FLEET asymmetrically — every site ordered after the offender gets nothing.

  ## One analytics read per site per tick

  The sweep probes with `Deploy.content_rev_probe/2` to decide whether to enqueue
  at all; it then hands that rev straight to `Deploy.enqueue/5` rather than
  letting it re-read the same endpoint. Two identical reads per site per tick,
  on BOTH tick kinds, collapse to one.
  """

  use Oban.Worker,
    queue: :site_deploy,
    max_attempts: 3,
    # Collapse a slow sweep + the next cron tick into one in-flight job. The
    # window must span ALL incomplete states or Oban warns that a job parked in
    # an omitted state slips the guard (the StaleDeploymentReaper precedent).
    # 3600s = the cron period: a sweep still running an hour later must not stack.
    unique: [
      period: 3600,
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.{Barkpark, Deployment, Site}
  alias BarkparkCloud.Sites.Deploy

  require Logger

  # See "The per-box start cap" in the moduledoc. One STARTED build per box per
  # tick; the rest of that box's sites defer to the next hourly tick.
  @max_starts_per_box 1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # SIX OUTCOME KEYS plus ONE OBSERVABILITY KEY. `code_rev_unknown` is
    # deliberately NOT a sixth outcome: the reduce below is `Map.update!(acc,
    # outcome, …)`, so a sixth ATOM returned from `sweep_site/1` would raise
    # KeyError at runtime. It is a key seeded here and incremented ALONGSIDE the
    # real outcome — a site is counted once as enqueued/duplicate/… and, when
    # its box has no code revision, once again here.
    # `refused` is an OUTCOME (a site is counted refused INSTEAD of
    # enqueued/duplicate/…), and it is seeded HERE in the same edit that returns
    # the atom — an unseeded atom raises KeyError inside the Map.update!/3 below
    # and aborts the sweep for the whole fleet. See "The PREBUILT REFUSAL".
    zero = %{
      enqueued: 0,
      duplicate: 0,
      skipped: 0,
      failed: 0,
      deferred: 0,
      refused: 0,
      code_rev_unknown: 0
    }

    {summary, _starts_per_box} =
      Registry.list_deployed_content_sites()
      |> Enum.reduce({zero, %{}}, fn site, {acc, starts} ->
        # Defer BEFORE probing: once this box has started a build this tick,
        # even the probe read would land on a box already busy building.
        if Map.get(starts, site.barkpark_id, 0) >= @max_starts_per_box do
          {Map.update!(acc, :deferred, &(&1 + 1)), starts}
        else
          {outcome, code_rev_known?} = sweep_site(site)

          starts =
            if outcome == :enqueued,
              do: Map.update(starts, site.barkpark_id, 1, &(&1 + 1)),
              else: starts

          acc = Map.update!(acc, outcome, &(&1 + 1))

          acc =
            if code_rev_known?,
              do: acc,
              else: Map.update!(acc, :code_rev_unknown, &(&1 + 1))

          {acc, starts}
        end
      end)

    if summary.deferred > 0 do
      Logger.info(
        "template-freshness: #{summary.deferred} site(s) deferred to the next tick " <>
          "(per-box start cap #{@max_starts_per_box})"
      )
    end

    # ONE log line for the whole tick, and NO deployment row — see "The PREBUILT
    # REFUSAL" in the moduledoc: 24 rows/day/site would bury the deployment
    # stream, and no user intent stands behind a timer tick.
    if summary.refused > 0 do
      Logger.info(
        "template-freshness: #{summary.refused} site(s) refused — their CURRENT release was " <>
          "uploaded (source=prebuilt), and a box build here would overwrite bytes this fleet " <>
          "cannot reproduce. Re-upload with `bp cloud site deploy <site> --prebuilt <dir>`."
      )
    end

    if summary.code_rev_unknown > 0 do
      Logger.warning(
        "template-freshness: #{summary.code_rev_unknown} site(s) ride a box reporting NO " <>
          "code revision (no git_commit, no version) — build_id's code half is frozen on the " <>
          "\"unknown\" constant, so this sweep can never mint a build for a code roll on those " <>
          "boxes and will report duplicate forever. Register the instance's git_commit/version."
      )
    end

    {:ok, summary}
  end

  # One site's sweep. Returns `{summary key its outcome counts under,
  # code_rev_known?}` — the second element is the observability half (residue 1)
  # and never replaces the outcome.
  defp sweep_site(%Site{} = site) do
    # The refusal comes FIRST — before the box is even read. A refused site costs
    # no analytics read, and it must not be diagnosed code-rev-unknown either:
    # one site, one outcome (the `skipped` arm reasons the same way).
    if prebuilt_release?(site) do
      {:refused, true}
    else
      sweep_box_built_site(site)
    end
  end

  # Does this site's CURRENT release carry uploaded bytes? Keys on the live
  # release's `source`, NEVER on `site.prebuilt_enabled` — the flag is an opt-in,
  # not a provenance fact, and keying on it would freeze an enabled-but-box-built
  # site's template freshness forever (proven both ways in the suite).
  #
  # A never-deployed site cannot reach here (`list_deployed_content_sites/0`
  # requires `current_deployment_id`), but nil-safety is still explicit: an
  # unreadable pointer must not be read as "not prebuilt" by accident.
  defp prebuilt_release?(%Site{current_deployment_id: nil}), do: false

  defp prebuilt_release?(%Site{current_deployment_id: id}) do
    case Registry.get_deployment(id) do
      %Deployment{} = deployment -> Deployment.prebuilt?(deployment)
      nil -> false
    end
  end

  defp sweep_box_built_site(%Site{} = site) do
    with %Barkpark{} = bp <- Registry.get_barkpark(site.barkpark_id),
         {:ok, rev} <- Deploy.content_rev_probe(site, bp) do
      # Hand the ALREADY-PROBED rev to enqueue (residue 2a). Without it
      # `Deploy.enqueue/4` re-reads the box's analytics endpoint, costing a
      # second identical read per site per tick — on both tick kinds.
      {enqueue_unforced(site, bp, rev), Deploy.code_rev_known?(bp)}
    else
      # The box is gone, or its content revision is unreadable. Skipping is the
      # POINT (see the moduledoc): enqueueing here would ride the fail-open and
      # mint a fresh build_id every hour for a box that cannot build anyway.
      # A box we could not even read is not ALSO reported as code-rev-unknown —
      # that would double-count one sick box as two distinct diagnoses.
      _ -> {:skipped, true}
    end
  end

  defp enqueue_unforced(%Site{} = site, %Barkpark{} = bp, content_rev) do
    # force: FALSE — the whole design. See the moduledoc.
    case Deploy.enqueue(site, bp, false, "template-auto", content_rev) do
      {:ok, deployment} ->
        # THE SWEEP IS ALLOWED TO LOSE. This used to be `:ok = Deploy.start(row)`
        # against a wrapper spec'd `:: :ok` — a match that could not fail — so a
        # tick whose every spawn was refused still reported `enqueued: N`. A row
        # minted but never driven is a build that did not happen; count it
        # `failed` and name the row a human can go look at.
        case Deploy.start_reported(deployment) do
          {:ok, _outcome} ->
            :enqueued

          {:error, reason} ->
            Logger.warning(
              "template-freshness could not start the driver for site #{site.id}: " <>
                "#{inspect(reason)} — deployment #{deployment.id} is left queued; next tick retries"
            )

            :failed
        end

      # Nothing changed since the last build: the (site_id, build_id) unique index
      # collapsed this into the existing row. The expected outcome on a quiet
      # fleet — emphatically NOT re-driven (that would rebuild an unchanged site
      # every hour, the exact storm this worker is shaped to avoid).
      {:duplicate, _deployment} ->
        :duplicate

      {:error, reason} ->
        Logger.warning(
          "template-freshness enqueue failed for site #{site.id}: #{inspect(reason)} — skipping this tick"
        )

        :failed
    end
  end
end
