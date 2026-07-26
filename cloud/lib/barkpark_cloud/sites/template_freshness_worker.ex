defmodule BarkparkCloud.Sites.TemplateFreshnessWorker do
  @moduledoc """
  stw9 (charter D57b): the hourly, UNFORCED freshness sweep — the half of "a
  merged template change reaches live sites" that no human triggers.

  ## What it does

  Once an hour, for every deployed content-bound site (`static` | `node` with a
  bootstrap dataset and at least one deployment — `Registry.list_deployed_content_sites/0`):

      Deploy.enqueue(site, bp, false, "template-auto")

  and, only when that actually minted a NEW row, `Deploy.start/1`. Nothing else.

  ## Why UNFORCED is the entire design (never force on a schedule)

  `force: true` folds a timestamp nonce into `build_id`, which is exactly what
  `AutoDeployWorker` wants (a debounced, human-caused, single-fire republish) and
  exactly what a TIMER must never do: a forced hourly sweep would mint a real
  build for every site every hour forever, and the search-template boxes are
  2-core machines where one site build takes 2-4 minutes (the D44 amendment
  measured builds queueing behind builds for hours). Unforced, `build_id =
  hash(code_rev + content_rev + config)` is stable across ticks, so the
  `(site_id, build_id)` unique index collapses an unchanged site to `{:duplicate,
  _}` — a pure no-op, no build, no `Deploy.start/1`. The sweep costs one analytics
  read per site per hour when nothing moved.

  ## The content_rev SKIP (the build-storm tripwire)

  `Deploy.enqueue/4` computes `content_rev` FAIL-OPEN: an unreadable revision
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

  ## Failure posture

  Per-site failures are isolated and logged; one unreachable box never aborts the
  sweep for the rest of the fleet. `perform/1` returns `{:ok, summary}` with the
  counts (`enqueued`, `duplicate`, `skipped`, `failed`) so a run reads honestly in
  the Oban job record.
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
  alias BarkparkCloud.Registry.{Barkpark, Site}
  alias BarkparkCloud.Sites.Deploy

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    summary =
      Registry.list_deployed_content_sites()
      |> Enum.reduce(%{enqueued: 0, duplicate: 0, skipped: 0, failed: 0}, fn site, acc ->
        Map.update!(acc, sweep_site(site), &(&1 + 1))
      end)

    {:ok, summary}
  end

  # One site's sweep. Returns the summary key its outcome counts under.
  defp sweep_site(%Site{} = site) do
    with %Barkpark{} = bp <- Registry.get_barkpark(site.barkpark_id),
         {:ok, _rev} <- Deploy.content_rev_probe(site, bp) do
      enqueue_unforced(site, bp)
    else
      # The box is gone, or its content revision is unreadable. Skipping is the
      # POINT (see the moduledoc): enqueueing here would ride the fail-open and
      # mint a fresh build_id every hour for a box that cannot build anyway.
      _ -> :skipped
    end
  end

  defp enqueue_unforced(%Site{} = site, %Barkpark{} = bp) do
    # force: FALSE — the whole design. See the moduledoc.
    case Deploy.enqueue(site, bp, false, "template-auto") do
      {:ok, deployment} ->
        :ok = Deploy.start(deployment)
        :enqueued

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
