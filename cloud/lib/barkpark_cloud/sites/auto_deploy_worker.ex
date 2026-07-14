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

  The build itself runs the SAME way a manual deploy does — `Deploy.start/1`
  spawns the supervised, claim-fenced, reaper-recoverable driver — so a crashed
  auto-rebuild is swept exactly like a crashed manual one. The `:site_deploy`
  queue is concurrency-1 so the enqueue+start step is serial per box, and the box
  itself flock-serializes the build.
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
  @unique [keys: [:site_id], states: [:available, :scheduled], period: 60]

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.{Barkpark, Site}
  alias BarkparkCloud.Sites.Deploy

  require Logger

  # The debounce window (seconds). A burst of publishes within this window before
  # the job starts all collapse onto the single :scheduled job.
  @schedule_in 5

  @doc """
  Enqueue (or coalesce onto) the debounced auto-deploy for `site_id`. Returns
  whatever `Oban.insert/1` returns — on a unique conflict that is `{:ok, job}`
  with the EXISTING scheduled job, so N calls in the window yield ONE job.
  """
  @spec enqueue(binary()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(site_id) when is_binary(site_id) do
    %{site_id: site_id}
    |> new(schedule_in: @schedule_in, unique: @unique)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"site_id" => site_id}}) do
    with %Site{} = site <- Registry.get_site(site_id),
         %Barkpark{} = bp <- Registry.get_barkpark(site.barkpark_id) do
      drive(site, bp)
    else
      # The site (or its box) was deleted between the publish and this run — there
      # is nothing to rebuild. Cancel, not retry: a retry would never find it.
      _ -> {:cancel, :site_or_box_gone}
    end
  end

  defp drive(site, bp) do
    # charter D48: force: true + trigger: content-auto. The debounce guarantees
    # single-fire, so force minting a genuinely-new build is safe (and belt-and-
    # suspenders against a republish whose content_rev happened not to change).
    case Deploy.enqueue(site, bp, true, "content-auto") do
      {:ok, deployment} ->
        :ok = Deploy.start(deployment)
        :ok

      # force should never dedup (fresh nonce every run) — but if it somehow does,
      # re-drive the existing row rather than dropping the rebuild.
      {:duplicate, deployment} ->
        :ok = Deploy.start(deployment)
        :ok

      # A transient enqueue failure (e.g. the box's content-rev read) — let Oban
      # retry within max_attempts rather than silently swallow the publish.
      {:error, reason} ->
        Logger.warning(
          "auto-deploy enqueue failed for site #{site.id}: #{inspect(reason)} — retrying"
        )

        {:error, reason}
    end
  end
end
