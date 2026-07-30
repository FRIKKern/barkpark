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
    %{site_id: site_id}
    |> new(schedule_in: schedule_in(), unique: @unique)
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
      {:ok, _cancelled} ->
        Logger.info(
          "auto-deploy refused for site #{site.id}: live release is prebuilt — cancelled row minted"
        )

      {:error, reason} ->
        # The row is the courtesy; the REFUSAL is the contract. A row we could not
        # write must never degrade into a box rebuild, and must not retry either
        # (the retry would rebuild nothing and re-fail the same way).
        Logger.warning(
          "auto-deploy refusal row failed for site #{site.id}: #{inspect(reason)} — refusing anyway"
        )
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
