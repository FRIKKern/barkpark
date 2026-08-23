defmodule BarkparkCloud.Registry.Deployment do
  @moduledoc """
  One build-and-release of a `Site`. The Deployment row IS the build job — the
  off-box builder (P2) atomically claims rows where `status = "queued"` and
  walks them through:

      queued → building → pushing → live      (happy path)
      queued → building → failed              (with failure_reason)

  Claim fencing mirrors the bp task substrate: `claim_worker` + `claimed_at` +
  `claim_epoch` are stamped on claim; the epoch bumps on every claim, and close
  is a CAS on the observed epoch (a stale-but-alive worker writing after its
  lease was swept fails the CAS).

  `image_tag` is the artifact identity once built. `build_log_url` is opaque to
  the control plane — the builder writes the log somewhere accessible (e.g. blob
  storage) and stores the URL.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # deploy-truth W1 (charter D9): `deferred` is a FIRST-CLASS COUNTED outcome, not
  # a quieter word for `failed`. The box refuses a second concurrent deploy for a
  # slug with a 409 `already_running`; before this status that refusal was written
  # `failed` — terminal, outside every recovery pass, and the single largest
  # failure class on the fleet (8,830 of 17,171 failed rows, 8,818 of them
  # content-auto). A `deferred` row says the same thing HONESTLY — this build did
  # not happen — while naming the reason as transient and carrying the promise
  # that a rebuild has been re-queued. It is terminal FOR THIS ROW (the retry is a
  # new row), which is why it is NOT in the active-deployment partial index: a
  # deferred row that blocked the very rebuild it promised would re-open the drop
  # it exists to close.
  @statuses ~w(queued building pushing live failed cancelled deferred)

  # gh-6: which slot this deployment targets. "production" (the default — every
  # pre-gh-6 row + every push to the connected branch) drives the Site's live
  # pointer; "preview" is a branch preview that answers on its own host/container
  # and NEVER touches `sites.current_deployment_id` / `sites.port`.
  @environments ~w(production preview)

  # site-spawner W5 (charter D49): the deploy's PROVENANCE. "manual" (a human ran
  # `bp cloud site deploy` — the pre-W5 default, so every existing row backfills to
  # it) or "content-auto" (a content publish on the bound dataset fired the per-site
  # content-publish receiver, which enqueued this build). The wish's "observable —
  # content-triggered, not manual" bar reads straight off this column; it rides
  # through `deployment_json/1` (the SOLE base serializer) to every deployment view.
  #
  # stw9 (charter D57) adds "template-auto": the hourly `TemplateFreshnessWorker`
  # sweep, which re-enqueues an UNFORCED build for every deployed content-bound
  # site so a merged TEMPLATE change reaches live sites without a human. It is a
  # THIRD provenance on purpose — a deploy stream that labelled a scheduled sweep
  # "manual" would lie about who asked, and one labelled "content-auto" would lie
  # about what changed. An unlisted value is REJECTED by
  # `validate_inclusion(:trigger, @triggers)`, so the worker's rows would never
  # insert without this entry.
  @triggers ~w(manual content-auto template-auto)

  # site-spawner W9 (charter D86): WHERE this build's bytes came from.
  # "box-build" (the pre-W9 default — `npm ci && npm run build` on the serving
  # box, so every existing row backfills to it) or "prebuilt" (the bytes were
  # built elsewhere and streamed up as a tarball; the box only stages,
  # health-gates and switches them).
  #
  # It is a THIRD provenance axis, orthogonal to `trigger`: trigger says WHO
  # asked, source says WHO BUILT. Collapsing them would make an unlabelled
  # deploy stream claim the control plane knows something it does not — and the
  # honest-gates half of this wave turns on being able to say, per row, whether
  # HEALTH certified bytes this fleet produced.
  @sources ~w(box-build prebuilt)

  # The legal from → to status graph the moduledoc promises. `live`, `failed`,
  # and `cancelled` are terminal (no outgoing edges). A same-status write is
  # always legal (see `legal_transition?/2`) so field-only updates — image_tag,
  # build_log_url, failure_reason — keep passing. This is the from-status guard
  # that `validate_inclusion(:status, …)` alone can't express; the fenced writers
  # in `BarkparkCloud.Registry` consult it before `Repo.update`.
  #
  # queued → failed is a legitimate edge: a queued row can fail *validation*
  # before any build claim — the reaper terminates a no-build-source row (no
  # artifact AND no connected repo) it can prove will never build.
  #
  # `deferred` (deploy-truth W1) is reachable from any pre-terminal status and is
  # itself terminal: the box said "busy", so THIS row never builds — the rebuild
  # it promises is a NEW row minted by the re-fired debounce job.
  @transitions %{
    "queued" => ["building", "failed", "cancelled", "deferred"],
    "building" => ["pushing", "failed", "cancelled", "deferred"],
    "pushing" => ["live", "failed", "cancelled", "deferred"],
    "live" => [],
    "failed" => [],
    "cancelled" => [],
    "deferred" => []
  }

  schema "deployments" do
    field :status, :string, default: "queued"
    field :git_ref, :string
    field :artifact_url, :string

    # site-spawner W1 (charter D3): the content-bound static-build identity.
    #
    #   * build_id     — hash(code_rev + content_rev + config). Names
    #     releases/<build_id>/ on disk AND is the PLAN idempotency key: a repeat
    #     build_id for the same site is an enforceable no-op (unique (site_id,
    #     build_id) index). Null for pre-W1 container deployments.
    #   * content_rev  — the Barkpark content revision baked into this build. Lets
    #     a content-only change (same code) mint a fresh build_id → a new build.
    #   * stage        — nullable STAGE telemetry: the current phase of the
    #     six-stage deploy pipeline (PLAN/BUILD/STAGE/HEALTH/SWITCH/RETIRE). Rides
    #     ALONGSIDE the coarse `status` enum (which is deliberately NOT widened);
    #     latest-wins, best-effort, overwritten by the builder at each phase.
    field :build_id, :string
    field :content_rev, :string
    field :stage, :string

    # dwb-18: GitHub's X-GitHub-Delivery header — unique per redelivery-chain.
    # Cast on CREATE only (never on a transition) and backed by a partial unique
    # index so a redelivered push mints at most one Deployment even under a race.
    field :delivery_id, :string
    field :image_tag, :string
    field :build_log_url, :string
    field :failure_reason, :string

    # gh-6: branch-preview identity. `environment` is "production" (default) or
    # "preview". For a preview: `branch` is the git branch it was cut from,
    # `preview_slug` is the sanitized+hashed DNS label, and `preview_host` is the
    # full `<preview_slug>.<base_domain>` it answers on (what the runtime keys its
    # Caddy block on and what `/v1/tls/ask` allowlists). Null on production rows.
    field :environment, :string, default: "production"
    field :branch, :string
    field :preview_slug, :string
    field :preview_host, :string

    # site-spawner W5 (charter D49): "manual" | "content-auto" — WHY this build
    # ran. Set at create; never mutated by a transition. Null-safe by column
    # default ("manual"), so a container/pre-W5 row reads as manual.
    field :trigger, :string, default: "manual"

    # site-spawner W9 (charter D86): "box-build" | "prebuilt" — WHERE the bytes
    # came from. Set at create; never mutated by a transition (a build cannot
    # change where it was built). Null-safe by column default, so every
    # pre-W9 row reads as box-build.
    field :source, :string, default: "box-build"

    # The sha256 of the uploaded tarball, recorded by the artifact route BEFORE
    # the driver is started — so a prebuilt deployment that reached the box can
    # always name the exact bytes it was asked to serve. Nil on a box-build.
    field :artifact_sha256, :string

    field :claim_worker, :string
    field :claimed_at, :utc_datetime_usec
    field :claim_epoch, :integer, default: 0

    # gh-5: append-only LIVE build console — the builder's claim → fetch source →
    # build → artifact → activate narration lines (already redacted worker-side).
    # Each element is %{"line", "at"}. Capped server-side (oldest dropped) so a
    # runaway build can't grow the row unbounded. Surfaced on the deployment JSON
    # (:console) so the site-detail deploy row renders a live console. Best-effort
    # telemetry — a missing/late line never blocks the build.
    field :console, {:array, :map}, default: []

    # dwb-19: the LIVE sub-caption under the deployment's status — the build-side
    # twin of a provision step's progress detail. A SINGLE latest-wins
    # plain-language string the builder overwrites at each real sub-boundary
    # (fetch source → build → save image → hand off). Surfaced on the deployment
    # JSON (:detail) and rendered under the status pill only while the deploy is
    # active. Best-effort telemetry — nil just means no sub-line.
    field :detail, :string

    field :became_live_at, :utc_datetime_usec

    # deploy-reliability W12 (S6): THE CHAIN, AS DATA. Until now a deferral's
    # position in its chain existed only as English inside `failure_reason`
    # ("refusal 3 of 12 in this site's current chain") and the Go CLI read it
    # back with a REGEX — producer and reader communicating through prose, so
    # any aggregate over chain depth was a regex over a sentence.
    #
    # These ride ALONGSIDE the sentence, which is PRESERVED (Vercel keeps
    # `readyStateReason` beside `readyState`): the prose is the operator's, the
    # columns are the aggregate's. Written by `Sites.Deploy.defer/3` on
    # `deferred` rows only — NULL on every other row and on pre-W12 deferrals,
    # which are honestly unknown rather than backfilled out of their own prose.
    #
    # `deferral_bound` is the CAUSE's own budget (12 for capacity, 6 for a busy
    # box), and `deferral_cause` is what makes the depth meaningful at all: two
    # deferrals of different causes are not one chain.
    field :deferral_depth, :integer
    field :deferral_bound, :integer
    field :deferral_cause, :string

    # deploy-reliability W12 (S6): THE ATTEMPTS THAT MINTED NO ROW.
    # `Sites.AutoDeployWorker.defer_behind_running_build/2` refuses a second
    # concurrent build in the control plane and writes NO deployment row — the
    # active-deployment index (correctly) refused to mint one, and the row in
    # flight is a real build that must not be relabelled a deferral. So the
    # attempt was invisible to every deployment-stream aggregate.
    #
    # It is counted HERE, on the in-flight row it coalesced ONTO, because that
    # is the truthful place: the attempt did not produce a build, it joined one.
    # Incremented by an atomic `UPDATE` (never a read-modify-write) so N
    # publishes racing one build all land. Not castable on any changeset for the
    # same reason.
    field :coalesced_attempts, :integer, default: 0
    field :coalesced_last_at, :utc_datetime_usec

    belongs_to :site, BarkparkCloud.Registry.Site

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def statuses, do: @statuses

  @doc "The valid deployment environments."
  def environments, do: @environments

  @doc "The valid deploy triggers (provenance): manual | content-auto (charter D49)."
  def triggers, do: @triggers

  @doc "The valid deploy sources (where the bytes were built): box-build | prebuilt (charter D86)."
  def sources, do: @sources

  @doc """
  Was this deployment's output built OFF the serving box (charter D86)?

  A SEAM, not a copy: `@sources` stays the single owner of the vocabulary, so a
  caller asking "do I need artifact bytes for this row?" never re-spells the
  literal. The payload builder and the artifact route both ask here.
  """
  @spec prebuilt?(t()) :: boolean()
  def prebuilt?(%__MODULE__{source: source}), do: source == "prebuilt"

  @doc "The legal from → to status transition graph."
  def transitions, do: @transitions

  @doc """
  Whether a Deployment may move from `from` to `to`. A same-status write is
  always legal (field-only updates), otherwise `to` must be an outgoing edge of
  `from` in `@transitions`.
  """
  def legal_transition?(from, to), do: to == from or to in Map.get(@transitions, from, [])

  @doc """
  Whether `deployment` targets the PRODUCTION slot — the promote/rollback
  eligibility gate (charter decision 7). Only a production deployment may be
  re-deployed (promoted); a branch preview answers on its own preview host and is
  NEVER a production rollback target, so the router 422s a preview promote. Keys
  on `environment` exactly like `find_active_deployment/2` and the production
  uniqueness index (every pre-gh-6 row is production).
  """
  @spec production?(t()) :: boolean()
  def production?(%__MODULE__{environment: environment}), do: environment == "production"

  @doc """
  Charter decision 7: rollback/redeploy is promote-by-NEW-deployment — never a
  `sites.current_deployment_id` pointer flip. Given a production `source`, build
  the attrs for a FRESH queued production deployment pinned to the source's
  already-built artifact (`git_ref` + `artifact_url`), so it rides the existing
  fenced builder pipeline and the on-box agent flips the live pointer only once
  the new row goes live (superseded deployments stay terminal-`live`).

  `delivery_id` is deliberately absent: a promote is an operator action, not a
  GitHub redelivery, so it must not borrow (and collide on) the delivery-id
  idempotency index. `environment` is left to the schema default ("production").
  """
  @spec promotion_attrs(t()) :: %{git_ref: String.t() | nil, artifact_url: String.t() | nil}
  def promotion_attrs(%__MODULE__{} = source),
    do: %{git_ref: source.git_ref, artifact_url: source.artifact_url}

  @doc """
  Changeset for creating a Deployment. `site_id` is required; `status` is not
  castable — creation always takes the schema default `queued`. The
  transition_changeset is the only status mutator. Fencing fields are not
  castable from public callers either.
  """
  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :git_ref,
      :artifact_url,
      :site_id,
      :delivery_id,
      :build_id,
      :content_rev,
      # site-spawner W5 (charter D49): provenance is set at create (manual by
      # default; the content-publish receiver stamps "content-auto"). Not a
      # transition field — a build never changes WHY it was created.
      :trigger,
      # site-spawner W9 (charter D86): WHERE the bytes come from, and the digest
      # of the uploaded ones. `source` is create-time provenance like `trigger`;
      # `artifact_sha256` is written by the artifact route on the already-minted
      # row (this changeset, never `transition_changeset/2` — a builder must not
      # be able to restate which bytes it was handed).
      :source,
      :artifact_sha256
    ])
    |> validate_required([:site_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:trigger, @triggers)
    |> validate_inclusion(:source, @sources)
    |> assoc_constraint(:site)
    # site-spawner W1: PLAN idempotency backstop. A repeat build_id for the same
    # site surfaces as a changeset error (the router can turn it into a 200
    # no-op) rather than a raised Ecto.ConstraintError.
    |> unique_constraint(:build_id,
      name: :deployments_site_build_id_index,
      message: "is already used by another deployment"
    )
    # dwb-18: the DB idempotency backstop. A lost race (concurrent redelivery, or
    # a second active build of the same commit) surfaces as a changeset error the
    # router turns into a 200 duplicate — never a raised Ecto.ConstraintError.
    |> unique_constraint(:delivery_id, name: :deployments_delivery_id_index)
    # deploy-truth W1 (charter D10): the RE-KEYED active index, which REPLACED
    # dwb-18's `deployments_active_site_ref_index`. That one keyed on `git_ref`,
    # which is NULL on 26,395 of 26,423 rows — and a btree unique treats NULLs as
    # DISTINCT, so it never once deduplicated a content-auto deploy.
    # `(site_id, environment)` keys on columns that are always present: at most
    # ONE active production build per site, which strictly implies the old
    # per-commit guarantee it retired. Without this declaration the losing INSERT
    # would raise Ecto.ConstraintError instead of returning a changeset the
    # caller can turn into a coalesce.
    #
    # Declared on `:git_ref` — the field dwb-18's index used — deliberately: the
    # callers that already turn "a build is in flight" into a 409 (the promote
    # route's `git_ref_conflict?/1`) keep working unchanged, and the message says
    # what the new key actually enforces.
    |> unique_constraint(:git_ref,
      name: :deployments_active_site_env_index,
      message: "is blocked — a build for this site is already in progress"
    )
  end

  @doc """
  gh-6: changeset for creating a branch-PREVIEW deployment. Same base shape as
  `changeset/2` plus the preview identity (`environment`, `branch`,
  `preview_slug`, `preview_host`) and the dwb-18 `delivery_id` idempotency key.
  `environment` is validated against `@environments`; `branch` is required (a
  preview is always cut from a branch). The preview columns are set by the
  control plane (`create_preview_deployment/4`), never accepted from a public
  request body.
  """
  def preview_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :git_ref,
      :artifact_url,
      :site_id,
      :delivery_id,
      :build_id,
      :content_rev,
      :environment,
      :branch,
      :preview_slug,
      :preview_host,
      # site-spawner W9 (charter D86): the preview path is an INDEPENDENT FORK of
      # `changeset/2`, not a delegation — a field added only there is silently
      # dropped on every preview deploy, which would answer 201 and then build
      # from the box. Both provenance fields are cast here for exactly that
      # reason.
      :source,
      :artifact_sha256
    ])
    |> validate_required([:site_id, :branch, :preview_slug, :preview_host])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:environment, @environments)
    |> validate_inclusion(:source, @sources)
    |> assoc_constraint(:site)
    # dwb-18 twins for the preview path: the same globally-unique delivery_id
    # index, plus at most one ACTIVE preview build per (site, branch) — the DB
    # backstop for replace-per-branch under concurrent pushes. A lost race
    # surfaces as a changeset error the router recovers into a 200 duplicate.
    |> unique_constraint(:delivery_id, name: :deployments_delivery_id_index)
    |> unique_constraint(:branch,
      name: :deployments_active_preview_branch_index,
      message: "already has an active preview"
    )
    # site-spawner W1: the same PLAN idempotency backstop on the preview path.
    |> unique_constraint(:build_id,
      name: :deployments_site_build_id_index,
      message: "is already used by another deployment"
    )
  end

  @doc """
  Narrow changeset for the builder's status transitions (image_tag, log url,
  failure reason, became_live_at) plus the gh-5 live-console append. Cannot move
  the deployment between sites.

  `source` and `artifact_sha256` are deliberately NOT castable here (charter
  D86): provenance is create-time. A builder that could restate WHERE its bytes
  came from — or WHICH bytes it was handed — could relabel an off-box artifact as
  a box build after the fact, and the ledger would agree with it.
  """
  def transition_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :status,
      :image_tag,
      :build_log_url,
      :failure_reason,
      :became_live_at,
      :console,
      :detail,
      # site-spawner W1: STAGE telemetry — the builder overwrites `stage` at each
      # phase of the six-stage pipeline (latest-wins). Distinct from the coarse
      # `status` lifecycle it rides alongside.
      :stage,
      # deploy-reliability W12 (S6): the chain, as data. Cast HERE and nowhere
      # else — a deferral is a TRANSITION (`queued|building|pushing → deferred`),
      # so the structured chain is written by the same fenced write that settles
      # the status and writes the prose sentence. Castable on create would let a
      # caller be born claiming a chain depth it never earned.
      #
      # `coalesced_attempts` / `coalesced_last_at` are deliberately NOT here:
      # they are incremented by an atomic UPDATE against the in-flight row from
      # a DIFFERENT process than the one holding that row's claim, and a
      # changeset write would be a read-modify-write that loses concurrent
      # attempts — which is the entire count.
      :deferral_depth,
      :deferral_bound,
      :deferral_cause,
      :claim_worker,
      :claimed_at,
      :claim_epoch
    ])
    |> validate_inclusion(:status, @statuses)
  end
end
