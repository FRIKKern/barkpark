defmodule BarkparkCloud.DeployLedger do
  @moduledoc """
  The fleet deploy ledger: a NAMED taxonomy over deploy failures, a failure rate
  that always carries its denominator, and a keyset cursor that can read past the
  200-row cap on `GET /v1/sites/:id/deployments`.

  This module exists because the control plane could count deploys and could
  render one deploy's prose, but could not answer "what is failing, how often,
  and is that better or worse than last week" without dumping the table.

  ## Why the classifier keys on the RAW column (deploy-reliability charter D1)

  `BarkparkCloud.Web.Router.deployment_json/1` HUMANIZES `failure_reason`
  (`FailureCopy.humanize/1`) and, since cch-w28-s5, also folds `detail` through
  `Sites.Deploy.stage_caption/2`. Both are display folds: they map many distinct
  raw causes onto ONE sentence a person can act on. Counting the rendered field
  therefore groups by prose, and prose collapses causes — two different box
  refusals become one bucket and the ledger reports a cause that does not exist.
  So `classify/2` reads `deployments.stage` and the RAW `deployments.failure_reason`
  and nothing else. The humanized string never enters this module.

  ## Why (stage, prefix) and not a bare LIKE

  `stage` is a near-perfect partition of the live corpus (re-derived 2026-08-05
  against `cloud-db-1`, 26,671 rows / 17,395 failed): every `HTTP 409` row is
  PLAN, every `bp-doc-id` row is HEALTH, every `403` row is BUILD. A bare
  substring match does not have that discipline — `%500%` also matches a build
  log that merely PRINTS 500, and `%403%` matches an Astro stack trace's byte
  offset. Every rule below anchors on the reason's PREFIX (the producer's own
  `fmt`/`fail/2` template) and, where the stage is a real corroborator, on the
  stage too.

  ## Why BOX_BUSY keys on "HTTP 409" and never on "already_running" (D7)

  3,814 of 8,970 409-rows (43%) carry the BARE pre-2026-07-30 string
  `the instance refused the deploy (HTTP 409)` with no machine-readable code,
  because `Sites.Deploy.refusal_detail/1` only grew its nested-envelope arm in
  commit `fe264a35b`. A classifier keyed on `already_running` silently drops 43%
  of the LARGEST class and reports an improvement nobody made.

  ## Why UNCLASSIFIED must be able to go UP (D8)

  Zero failed rows have a NULL `failure_reason`, so `UNCLASSIFIED` is a statement
  about THIS classifier, not about the data. When a new failure shape appears,
  the honest outcome is that UNCLASSIFIED rises — not that the new shape is
  quietly absorbed by the nearest bucket and the taxonomy keeps looking complete.
  `deploy_ledger_test.exs` pins that with an unrecognised reason. On the
  2026-08-05 corpus the tail is 8 rows (0.05%): nixpacks, `docker run` exit 125,
  an `HTTP 404`/`HTTP 400` refusal, and two em-dash `BUILD failed —` rows.

  ## …and its DEFERRED-side mirror, which is a DIFFERENT sentinel (D43/D44)

  A deferred row gets the same treatment — `classify/1` reads its stage and RAW
  reason, and an unrecognised cause answers `DEFERRED_UNCLASSIFIED` rather than
  being absorbed by the nearest bucket. The tail name is deliberately NOT
  `UNCLASSIFIED`: that class sits in `@classes`, and `@classes` rows are the
  failure NUMERATOR. A concurrent-build cap refusing a slot is the fleet working
  as designed, so counting it as a failure would inflate the very rate this epic
  exists to measure — vacuous RED. The deferred tail therefore rises inside the
  deferred cohort: inside `volume`, outside the numerator, on its own line.

  ## Why GITHUB_PUSH_UNBUILDABLE is out of the denominator (D19)

  Exactly 7 rows, born `failed` on purpose by `Registry.record_unbuildable_push`
  because `github_build_available?/1` is a hardcoded `false`. Only the
  human-gated gh-1 can ever move them, so counting them permanently inflates a
  rate this epic cannot touch. They are reported in their own `not_attempted`
  bucket — visible, but never in a denominator.

  ## Why a rate below n≈200 is REFUSED (D3, the standing law)

  Daily deploy volume fell 2,766 (07-30) to 332 (08-05). An absolute before/after
  would show a huge "improvement" produced by NOBODY DEPLOYING. So: every rate
  carries `sample` beside it, every window is PINNED by an explicit `inserted_at`
  bound (never a floating "now minus"), and below `min_sample/0` the census
  refuses to compute a percentage at all — as behaviour, not as a docstring.

  ## The vocabulary BOUNDARIES are a LIST, and the commit derivation is the one that ships

  A window can span an instant at which the ledger's own vocabulary changed, and
  a count taken across such an instant blends two taxonomies while looking like
  one number. There is not ONE such instant — there are two, each a SCHEMA
  EVENT trailing its own commit by a plain deploy lag, which is why
  `boundaries` on the census envelope is a LIST and not a scalar:

    * the `deferred` settle status — commit `2026-08-05T21:13:50Z` (#9615),
      first deferred row `21:27:11.413210` (+13m21s).
    * `deferral_cause` / `deferral_depth` / `deferral_bound` — commit
      `2026-08-07T10:01:00Z` (#10248), first such row `10:12:35.033826`
      (+11m35s).

  THE COMMIT INSTANT IS THE BOUNDARY (`method: "schema_commit"`). The `min()`
  over rows rides only as a corroborating twin, labelled
  `method: "first_observed_row"`, and it is an UPPER BOUND that a SITE DELETE
  CAN SLIDE: `deployments.site_id` is `references(:sites, on_delete: :delete_all)`
  and `Registry.delete_site/1` has already fired it (six `site.deleted` audit
  rows on 2026-07-18, all `proof-20260718-*` slugs). Measured on cloud-db-1:
  site `search` owns the boundary row and 444 of 2,206 deferred rows (20.1%) —
  delete it and the derived boundary jumps +28m15s to `21:55:26.382661` while a
  fifth of the cohort vanishes without a sound. A boundary a `DELETE` can move
  is not a boundary.

  Only the REFUSAL-VOCABULARY boundary (the `deferred` settle status) refuses
  anything, and only for a window that STRADDLES it: inside such a window the
  same physical box refusal is written `failed` on one side and `deferred` on
  the other, so every RATIO over that window is a blend of two taxonomies:
  `failure_rate` and every class row's `share` come back refused, carrying the
  boundary verbatim. The COUNTS do not — `volume`, `failed`, `live` and each
  class's `count` are real counts of real rows, and `classes` stays a LIST on
  every path (the shape must not switch: the reader declares a slice, and an
  object there is a decode error rather than a refusal). A window wholly on one
  side is internally consistent and is NOT refused — the boundary list is
  emitted so a reader can see the cross-window comparison hazard for themselves.

  `live_rate` NEVER refuses across a boundary (D229): it is the one quantity
  whose numerator and denominator are both label-independent — a deploy that
  switched is `status == "live"` on both sides of every vocabulary change — and
  a comparator that refuses everything is an outage a reader routes around.

  ## The COMPLETENESS audit, and the blind spot it does NOT close

  `census/3` folds exactly ONE `Repo.all` and derives every term from it. So the
  partition identity (`failed + deferred + live + in_flight + cancelled +
  residual == volume`) balances at ANY level of loss: injecting a spurious
  `where: d.environment == "production"` into the grouped query — the good-faith
  edit, since `delivery/3` one function away has exactly that predicate — leaves
  the partition guard 4/4 GREEN and the whole cloud suite green while the census
  silently under-reports. Disjointness was proved; COMPLETENESS was not.

  So `completeness` is a SECOND INDEPENDENT COUNT taken inside `census/3`:
  `Repo.aggregate(scoped, :count, :id)` — no `GROUP BY`, no classification fold
  — reconciled against `volume + sum(not_attempted.count)`. It is `volume` PLUS
  `not_attempted` and never `volume` alone, because the D19 tombstones sit
  outside `volume` on purpose (7 rows all-time) and reconciling against `volume`
  would be a permanent false red on the real corpus.

  IT LIVES IN THE CODE, NOT IN A TEST, because a test is only as good as its
  fixture: under the environment mutation the audit PASSES on every shipped
  fixture and reds only once a preview-environment row exists. In `census/3` it
  reds against whatever population the caller actually asked about.

  THE RESIDUAL BLIND SPOT, NAMED: both query shapes inherit `scoped`. A wrong
  `WHERE` in `scoped` itself — the window bound, the `:site_ids` narrowing — is
  invisible to BOTH counts, and this audit cannot see it.

  ## The coalesced-attempt gauge REFUSES below its own coverage floor

  `coalesced_attempts` counts the deploy attempts that minted NO ROW at all
  (`AutoDeployWorker.defer_behind_running_build/2` coalescing onto an in-flight
  build). It is emitted BESIDE `volume` and never folded into it: the two
  populations are disjoint by construction — a deferred row IS in `volume`, a
  coalesced attempt produced no row to count.

  THE PRE-MIGRATION ROWS ARE NOT HONESTLY-UNKNOWN NULL, measured on prod:
  `count(*) filter (where coalesced_attempts is null)` is ZERO across all 31,254
  rows and every pre-migration row reads exactly `0` (distinct=1, min=0, max=0)
  — PostgreSQL 11+ materialised the constant default logically, contradicting
  the migration's own moduledoc. So NO coverage signal is derivable from the
  data, and a bare `SUM` over 2026-08-06 returns a confident `0` for a day whose
  true coalesced volume was ~1,563. The floor is therefore a CODE CONSTANT — the
  migration's applied instant — and any window starting before it is REFUSED.
  """

  import Ecto.Query, warn: false

  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Registry.Site
  alias BarkparkCloud.Repo

  @typedoc "A failure class name — one of `classes/0` (or a never-attempted class, `not_attempted?/1`)."
  @type class :: String.t()

  # The taxonomy, ORDERED most-frequent-first on the 2026-08-05 corpus. Order is
  # presentation only; `classify/2`'s own arms are ordered by specificity.
  @classes [
    "BOX_BUSY_409",
    "ABANDONED_AT_CAPACITY",
    "ABANDONED_BOX_STUCK",
    "DOC_ID_EMPTY",
    "BOX_500",
    "FORBIDDEN_403",
    "BUILD_FAILED",
    "BOX_DEPLOY_DISABLED_503",
    "BOX_RUNNER_UNAVAILABLE_503",
    "BOX_UNAVAILABLE_503",
    "BOX_UNREACHABLE",
    "HEALTH_GATE_FAILED",
    "BOX_RATE_LIMITED_429",
    "DEPLOY_TIMEOUT",
    "SOURCE_UNFETCHABLE",
    "STALE_LEASE",
    "PROCESS_DIED",
    "UNCLASSIFIED"
  ]

  # Classes whose rows were never a real deploy ATTEMPT, and therefore never sit
  # in a rate denominator. Kept separate from `@classes` so a caller cannot fold
  # them in by iterating the taxonomy.
  @not_attempted_classes ["GITHUB_PUSH_UNBUILDABLE"]

  # Rows that WERE attempted and did not fail — and did not succeed either.
  #
  # THE CROSS-SLICE HOLE THIS CLOSES. deploy-reliability W1 S3 makes a box-busy
  # 409 settle as a first-class `deferred` row instead of a terminal `failed`
  # one. That is 8,830 of 17,171 failed rows — 51.4%, the largest class on the
  # fleet — changing status. Without an arm for it here, `classify/1` answers
  # `nil` (the "did not fail" default) and those rows become INVISIBLE to the
  # census: the failure rate would fall by half and the ledger would not be able
  # to say where they went. A number that improves because a row stopped being
  # counted is precisely the vacuous green this epic was chartered to refuse.
  #
  # So a deferral is COUNTED, in its own cohort: inside `volume` (it was a real
  # attempt against a real box), outside the failure numerator (the box's answer
  # was "not now", and a rebuild was re-queued), and reported as its own line so
  # the 409 mass is visibly RELOCATED rather than silently deleted.
  # THREE deferral classes, because there are three distinct answers a box can
  # give that are not failures, and a taxonomy that keys on `status` alone cannot
  # tell them apart (dr-w3 S3). `BOX_BUSY_DEFERRED` is the box already deploying
  # THIS slug; `BOX_AT_CAPACITY_DEFERRED` is the concurrent-build cap refusing a
  # slot on a box that is not busy with this site at all; `DEFERRED_UNCLASSIFIED`
  # is the honest tail — the deferred-side mirror of D8 (see below).
  @deferred_classes [
    "BOX_BUSY_DEFERRED",
    "BOX_AT_CAPACITY_DEFERRED",
    "DEFERRED_UNCLASSIFIED"
  ]

  @labels %{
    "BOX_BUSY_409" => "the box was already deploying (HTTP 409)",
    "ABANDONED_AT_CAPACITY" =>
      "the box stayed at its concurrent-build cap and the publish was given up on",
    "ABANDONED_BOX_STUCK" => "the box kept refusing this site and the publish was given up on",
    "DOC_ID_EMPTY" => "HEALTH gate: the bp-doc-id marker was empty",
    "BOX_500" => "the box errored on the deploy (HTTP 500)",
    "FORBIDDEN_403" => "the build could not read its content (403)",
    "BUILD_FAILED" => "the site build exited non-zero",
    "BOX_DEPLOY_DISABLED_503" => "site deploys are switched off on this instance",
    "BOX_RUNNER_UNAVAILABLE_503" => "the instance's deploy runner did not answer in time",
    "BOX_UNAVAILABLE_503" => "the box refused with a 503 it did not name a cause for",
    "BOX_UNREACHABLE" => "the instance could not be reached at all",
    "HEALTH_GATE_FAILED" => "HEALTH gate failed — not switched",
    "BOX_RATE_LIMITED_429" => "the box rate-limited the deploy (HTTP 429)",
    "DEPLOY_TIMEOUT" => "the build did not finish in time",
    "SOURCE_UNFETCHABLE" => "the build inputs could not be read",
    "STALE_LEASE" => "the builder lease went stale",
    "PROCESS_DIED" => "the deploy process died abnormally",
    "UNCLASSIFIED" => "not yet named by the ledger",
    "GITHUB_PUSH_UNBUILDABLE" => "GitHub push builds are not available yet",
    "BOX_BUSY_DEFERRED" => "the box was busy; the rebuild was re-queued, not lost",
    "BOX_AT_CAPACITY_DEFERRED" =>
      "the box was at its concurrent-build cap; the rebuild was re-queued, not lost",
    "DEFERRED_UNCLASSIFIED" => "deferred for a cause the ledger has not named"
  }

  # The statuses of a row that is attempted but NOT settled — the same literal
  # the partial unique index `deployments_active_site_env_index` is built on
  # (migration 20260805190000), so "in flight" means the same thing to the census
  # as it does to the database that refuses a second one.
  @in_flight_statuses ~w(queued building pushing)

  # Below this many ATTEMPTED rows a percentage is noise, not a measurement: at
  # the 2026-08-05 daily volume (n=332, and n≈70 in a 24h slice of the quiet
  # sites) a single row moves the rate more than a percentage point.
  @min_sample 200

  # ── The vocabulary boundaries ──────────────────────────────────────────────
  #
  # THE REFUSAL-VOCABULARY BOUNDARY. Before this instant the `deferred` settle
  # status did not exist, so a box-busy 409 was written `failed` and IS counted
  # in the failure numerator; after it the same physical refusal is `deferred`
  # and is not. Keyed on the COMMIT, never on `min(inserted_at)` — see the
  # moduledoc for why the row-derived twin is an upper bound a DELETE can slide.
  @deferred_status_boundary %{
    subject: "deferred settle status",
    instant: ~U[2026-08-05 21:13:50Z],
    method: "schema_commit",
    source: "#9615",
    voids:
      "before this instant no row could settle `deferred`: every box-busy refusal was written `failed`. A window that STRADDLES it counts the same physical event under two names, so every RATIO over it is refused — `failure_rate` and each class row's `share`. The COUNTS stay (they are real rows) and `classes` stays a list. `live_rate` is not refused — its numerator and denominator are both label-independent (D229)."
  }

  # The corroborating twin, and the two `deferral_cause` events. Emitted so a
  # reader can see the deploy lag and the derivation disagreement for
  # themselves; only `@deferred_status_boundary` refuses anything.
  @boundaries [
    @deferred_status_boundary,
    %{
      subject: "deferred settle status",
      instant: ~U[2026-08-05 21:27:11.413210Z],
      method: "first_observed_row",
      source: "min(inserted_at) where status = 'deferred'",
      voids:
        "corroborating twin of the schema_commit row above, +13m21s of deploy lag. AN UPPER BOUND, NOT THE BOUNDARY: `deployments.site_id` is `on_delete: :delete_all` and `Registry.delete_site/1` has already fired it — deleting site `search` slides this instant +28m15s to 21:55:26.382661 and takes 444 of 2,206 deferred rows with it. Never refuse on a number a DELETE can move."
    },
    %{
      subject: "deferral_cause / deferral_depth / deferral_bound",
      instant: ~U[2026-08-07 10:01:00Z],
      method: "schema_commit",
      source: "#10248",
      voids:
        "the deferral chain columns are NULL before this instant — every deferral is still prose in `failure_reason`. No count in this envelope reads them yet, so nothing refuses on it; a later wave that aggregates chain depth must."
    },
    %{
      subject: "deferral_cause / deferral_depth / deferral_bound",
      instant: ~U[2026-08-07 10:12:35.033826Z],
      method: "first_observed_row",
      source: "min(inserted_at) where deferral_cause is not null",
      voids:
        "corroborating twin of the row above, +11m35s of deploy lag. Same UPPER-BOUND caveat: a site delete cascade slides it."
    }
  ]

  # ── The coalesced-attempt coverage floor ───────────────────────────────────
  #
  # `20260807150000_add_deferral_structure_to_deployments` applied at this
  # instant. A CODE CONSTANT because prod carries ZERO NULLs in the column —
  # PostgreSQL materialised the `default 0` logically over all 31,254
  # pre-migration rows — so there is no coverage signal in the data to derive it
  # from, and a bare SUM reads a confident 0 for a day whose true value was
  # ~1,563. Overridable via config because the instant is per-control-plane: a
  # second CP applies the same migration at a different time, and a bare literal
  # would silently mis-state the floor there.
  @coalesced_counter_since ~U[2026-08-07 10:02:23Z]

  @coalesced_basis "attempts that minted NO deployment row (AutoDeployWorker coalesced them onto an in-flight build) — DISJOINT from `volume`, never folded into it"

  # What each rate's denominator COUNTS — the D34 convention label, emitted so no
  # percentage travels without saying what it is a percentage OF.
  @basis_attempted "attempted rows in the window: failed + deferred + live + in_flight + cancelled + residual (never-attempted tombstones excluded, D19)"
  @basis_failed "settled failed rows in the window — the failure numerator"

  @doc "The named failure classes, most-frequent-first on the corpus that motivated them."
  @spec classes() :: [class()]
  def classes, do: @classes

  # `not_attempted_classes/0` used to sit here: a public accessor for
  # `@not_attempted_classes`. Deleted by dr-w16-s3 after the reachability census
  # measured it at ZERO callers in cloud/lib AND zero references in cloud/test —
  # the only genuinely dead public on this module. The attribute stays; the
  # membership question is answered by `not_attempted?/1`, which is called.

  # No `in_flight_statuses/0` accessor. `@in_flight_statuses` is read by
  # `census/3` in this file and by nobody else, and a public accessor with zero
  # callers is exactly the dead-public shape dr-w16-s3's reachability census
  # exists to red on — born dead in the same wave that built the guard. Add the
  # accessor in the commit that adds its first caller, not before (dr-w16 review).

  @doc "The minimum ATTEMPTED sample below which a rate is refused rather than reported."
  @spec min_sample() :: pos_integer()
  def min_sample, do: @min_sample

  @doc "Human-facing one-liner for a class name."
  @spec label(class()) :: String.t()
  def label(class) when is_binary(class), do: Map.get(@labels, class, class)

  @doc "Whether `class` names rows that were never attempted (excluded from denominators)."
  @spec not_attempted?(class() | nil) :: boolean()
  def not_attempted?(class), do: class in @not_attempted_classes

  @doc "Classes for rows that were attempted, deferred, and re-queued — never in the failure numerator."
  @spec deferred_classes() :: [class()]
  def deferred_classes, do: @deferred_classes

  @doc "Whether `class` names a DEFERRAL: counted in volume, never counted as a failure."
  @spec deferred?(class() | nil) :: boolean()
  def deferred?(class), do: class in @deferred_classes

  @doc """
  The failure class of a deployment row, or `nil` when the row did not fail.

  Accepts a `Deployment` struct or any map carrying `status`, `stage` and
  `failure_reason` (the census folds over grouped maps, not structs).
  """
  @spec classify(Deployment.t() | map() | nil) :: class() | nil
  def classify(%{status: "failed"} = row),
    do: classify(Map.get(row, :stage), Map.get(row, :failure_reason))

  # A DEFERRAL is not a failure and not a nil — see `@deferred_classes`. It reads
  # the (stage, RAW reason) pair exactly like the failed arm above, and for the
  # same reason: this clause used to match `status` alone, so a capacity refusal,
  # a busy-slug refusal, a broken re-queue and a nil reason ALL answered
  # `BOX_BUSY_DEFERRED` — a taxonomy with one arm cannot be wrong, and was.
  def classify(%{status: "deferred"} = row),
    do: classify_deferred(Map.get(row, :stage), Map.get(row, :failure_reason))

  def classify(%{status: _other}), do: nil
  def classify(nil), do: nil

  @doc """
  Classify a FAILED row from its `stage` and its RAW `failure_reason`.

  Never pass `FailureCopy.humanize/1`'s output here — see the moduledoc. Anything
  this function does not recognise is `UNCLASSIFIED`, deliberately and loudly.
  """
  @spec classify(String.t() | nil, String.t() | nil) :: class()
  def classify(stage, reason)

  def classify(_stage, nil), do: "UNCLASSIFIED"

  def classify(stage, reason) when is_binary(reason) do
    cond do
      # Born-failed tombstone: never an attempt. First, because its text mentions
      # neither a stage nor a producer template the other arms could catch.
      String.starts_with?(reason, "github push builds require") ->
        "GITHUB_PUSH_UNBUILDABLE"

      # The box answered and said no, in its own words. `Sites.Deploy.box_refusal/2`
      # writes this prefix with the HTTP status IN it, so the status is read from
      # the anchored prefix — never from a substring search over the whole capture
      # (a build log that prints "500" is not a box 500).
      code = refusal_code(reason) ->
        refusal_class(code, reason)

      stage == "HEALTH" and String.contains?(reason, "bp-doc-id marker is empty") ->
        "DOC_ID_EMPTY"

      stage == "HEALTH" and health_gate?(reason) ->
        "HEALTH_GATE_FAILED"

      stage == "BUILD" and String.starts_with?(reason, "BUILD failed (exit") ->
        build_class(reason)

      source_unfetchable?(reason) ->
        "SOURCE_UNFETCHABLE"

      String.contains?(reason, "is unreachable") ->
        "BOX_UNREACHABLE"

      String.starts_with?(reason, "the build did not finish in time") ->
        "DEPLOY_TIMEOUT"

      String.starts_with?(reason, "exceeded max deploy claim attempts") ->
        "STALE_LEASE"

      String.starts_with?(reason, "deploy process died abnormally") ->
        "PROCESS_DIED"

      true ->
        "UNCLASSIFIED"
    end
  end

  def classify(_stage, _reason), do: "UNCLASSIFIED"

  # `the instance refused the deploy (HTTP 409): already_running` and the BARE
  # `the instance refused the deploy (HTTP 409)` must land in the same class —
  # the 43% of 409-rows written before `refusal_detail/1` grew its nested-envelope
  # arm carry no code at all (D7). Anchored at the start of the capture.
  #
  # BOTH PHASES, and that is charter D218. `Sites.Deploy.box_refusal/3` writes
  # two captions from one helper — `the instance refused the deploy (HTTP …)`
  # when the box refused the TRIGGER, and `the instance refused the build poll
  # (HTTP …)` when it refused a BEAT of a build it had already accepted. This
  # anchor read only the first, so the poll caption matched NEITHER this regex
  # nor `@deferral_prefix` below and every poll refusal fell into UNCLASSIFIED
  # with its status and its code word sitting unread in the string. That path is
  # live code: an untyped 5xx that never clears exhausts `site_deploy_poll_grace`
  # and falls out of the graced arm wearing exactly this caption
  # (`sites_deploy_test.exs` drives it end to end). Zero poll rows exist on
  # cloud-db-1 all-time against 14,753 start-phase refusals — so this is a
  # TRIPWIRE for the day the first one lands, not a claim that rows are
  # mis-reported today.
  @refusal ~r/^the instance refused the (?:deploy|build poll) \((?:HTTP )?(\d{3})\)/

  # The phase the caption names, kept READABLE rather than folded into the class:
  # a poll 500 and a start 500 are the same cause with different blast radii (the
  # start one never began a build; the poll one killed a build already running),
  # and the taxonomy deliberately does not split on it — 0 poll rows all-time is
  # not a corpus that earns two names. This is how a reader gets the phase back.
  @refusal_phases [
    {~r/^the instance refused the deploy \((?:HTTP )?\d{3}\)/, :start},
    {~r/^the instance refused the build poll \((?:HTTP )?\d{3}\)/, :poll}
  ]

  @doc """
  Which PHASE of the deploy the box refused, out of a RAW `failure_reason`.

  `:start` (the trigger), `:poll` (a beat of an accepted build), or `nil` when
  the reason is not a box refusal at all.
  """
  @spec refusal_phase(String.t() | nil) :: :start | :poll | nil
  def refusal_phase(reason) when is_binary(reason) do
    Enum.find_value(@refusal_phases, fn {re, phase} ->
      if Regex.match?(re, reason), do: phase
    end)
  end

  def refusal_phase(_reason), do: nil

  defp refusal_code(reason) do
    case Regex.run(@refusal, reason) do
      [_, code] -> code
      nil -> nil
    end
  end

  # A 409 the driver GAVE UP ON is not the transient 409 that class name promises.
  # `Sites.Deploy.defer/3` bounds a refusal chain — 6 rounds for a busy box, 12
  # for the concurrent-build cap — and the LAST round settles the row `failed`,
  # appending its own abandonment clause to the box's words. Those rows are the
  # most severe outcome the fleet produces (a publish that never happened and
  # never will), and every one of them classified as `BOX_BUSY_409`, whose label
  # reads "the box was already deploying (HTTP 409)". For a CAPACITY abandonment
  # that label is affirmatively false: the box was not deploying this site at
  # all, it had no free slot — which is the opposite operator instruction.
  #
  # So the terminal round gets its own name, split the way the DEFERRED arm
  # already splits, by the box's own code word and through the SAME
  # `deferral_code/1` reader: one parser for one code, so a chain, a deferral and
  # a census can never disagree about what refused.
  #
  # Only the ANCHORED terminal clause promotes. A 409 that is not chain-terminal
  # keeps its ordinary name (D8 — no catch-all), and a terminal 409 whose code
  # word the ledger has never named rises in `UNCLASSIFIED` rather than being
  # absorbed by whichever abandonment bucket it most resembles.
  defp refusal_class("409", reason) do
    if abandoned?(reason), do: abandoned_class(reason), else: "BOX_BUSY_409"
  end

  # The 503 splits the same way, and for a harder reason: `BOX_UNAVAILABLE_503`
  # had EXACTLY ONE distinct `failure_reason` in its entire life on cloud-db-1 —
  # 265 rows, all `feature_not_configured`, all written by a box that was UP (in
  # one hour, 15 deploys went LIVE on the same box while 44 were refused as "not
  # enabled", a live deploy and a refusal four seconds apart). "The box was
  # unavailable" was not mostly wrong; it was wrong of every row it ever named,
  # and it sent the operator to check a box's health instead of a feature flag.
  #
  # dr-w8-s2 then put a SECOND cause on the same status on purpose — a wedged
  # runner, kept on the 503 so it would not refile rows — so the class became a
  # UNION of two causes with OPPOSITE instructions ("you switched deploys off"
  # vs "your runner was slow") behind one name that fits neither. The status
  # alone cannot tell them apart. The box's own code word can, through the SAME
  # `deferral_code/1` reader the 409 arm uses.
  #
  # A 503 the ledger cannot read a NAMED code word out of keeps the status-only
  # name (D8, again): an unnamed cause must not be promoted into whichever of
  # the two it happens to sit next to.
  defp refusal_class("503", reason) do
    case deferral_code(reason) do
      {:code, "feature_not_configured"} -> "BOX_DEPLOY_DISABLED_503"
      {:code, "deploy_runner_unavailable"} -> "BOX_RUNNER_UNAVAILABLE_503"
      _unnamed -> "BOX_UNAVAILABLE_503"
    end
  end

  defp refusal_class(code, _reason), do: refusal_class(code)

  # `Sites.Deploy.abandonment_reason/3` writes this clause, and nothing else in
  # the tree does. It is PROSE, so it is anchored on the producer's own template
  # AND guarded from the producer side: `deploy_ledger_test.exs` builds the
  # sentence through that public producer, so rewording it reds at edit time
  # instead of silently degrading every abandoned row back to `BOX_BUSY_409` —
  # the exact disease this epic exists to refuse.
  @abandoned ~r/ — and it has now refused \d+ rebuilds in a row for this site,/

  defp abandoned?(reason), do: Regex.match?(@abandoned, reason)

  defp abandoned_class(reason) do
    case deferral_code(reason) do
      {:code, "box_at_capacity"} ->
        "ABANDONED_AT_CAPACITY"

      # `already_running` — and D7's codeless 409, which predates the cap
      # entirely and can therefore only be the busy slug, read exactly as the
      # deferred arm reads it.
      code when code in [:none, {:code, "already_running"}] ->
        "ABANDONED_BOX_STUCK"

      _unnamed ->
        "UNCLASSIFIED"
    end
  end

  defp refusal_class("409"), do: "BOX_BUSY_409"
  defp refusal_class("500"), do: "BOX_500"
  defp refusal_class("503"), do: "BOX_UNAVAILABLE_503"
  defp refusal_class("429"), do: "BOX_RATE_LIMITED_429"
  # A refusal status the ledger has never named (404, 400, …) is UNCLASSIFIED on
  # purpose: inventing a BOX_REFUSED_OTHER bucket would make the taxonomy look
  # complete while telling nobody a new refusal shape appeared.
  defp refusal_class(_other), do: "UNCLASSIFIED"

  ## ── The DEFERRED taxonomy ─────────────────────────────────────────────────
  #
  # Same discipline as `classify/2` — anchored prefix, the box's own code, the
  # RAW column — and one deliberate difference: the tail is `DEFERRED_UNCLASSIFIED`
  # and NEVER `UNCLASSIFIED`. `UNCLASSIFIED` lives in `@classes`, and `@classes`
  # rows ARE the failure numerator, so routing a healthy capacity refusal there
  # would inflate the deploy-failure rate with the fleet working exactly as
  # designed — vacuous RED, the mirror image of the vacuous green this epic
  # refuses. The honest tail rises INSIDE the deferred cohort: in `volume`, out
  # of the numerator, on its own reported line.
  defp classify_deferred(_stage, reason) when is_binary(reason) do
    cond do
      # A deferral whose re-queue BROKE is a lost publish, not a re-queue. Rows
      # written before dr-w3 S3 settled `deferred` with this text (the driver now
      # settles them `failed`), and calling them "re-queued, not lost" is the one
      # thing the ledger must not do — so they surface in the tail instead.
      String.contains?(reason, "could NOT be re-queued") ->
        "DEFERRED_UNCLASSIFIED"

      # `Sites.Deploy.defer/3` only ever fires behind the box's 409, so anything
      # that is not an anchored 409 refusal is a deferral shape this classifier
      # has never seen — which it says, rather than absorbing it.
      refusal_code(reason) != "409" ->
        "DEFERRED_UNCLASSIFIED"

      deferral_code(reason) == {:code, "box_at_capacity"} ->
        "BOX_AT_CAPACITY_DEFERRED"

      # `already_running` — and the BARE 409 with no code at all, which is D7's
      # 43%: a codeless 409 predates the concurrent-build cap entirely, so the
      # only thing it can be is the busy slug. `:none` is that codeless 409 and
      # NOT `:prose`: a box that sent unreadable words did say something, and
      # folding it in here would absorb an unnamed cause into the busy bucket.
      deferral_code(reason) in [:none, {:code, "already_running"}] ->
        "BOX_BUSY_DEFERRED"

      true ->
        "DEFERRED_UNCLASSIFIED"
    end
  end

  # A nil reason on a deferred row is the tail too: the driver always writes the
  # box's own words, so a deferral with no reason is a producer this module does
  # not know about.
  defp classify_deferred(_stage, _reason), do: "DEFERRED_UNCLASSIFIED"

  # The box's own refusal CODE out of a deferral reason: what follows the anchored
  # 409 prefix, up to the driver's own ` — ` suffix separator (the stored reason
  # carries `… — deferred: a rebuild carrying this content has been re-queued …`
  # after the box's words).
  #
  # THREE answers, not two, because "the box named no code" and "the box sent
  # words this module cannot read as a code" are different facts with opposite
  # consequences (dr-w4 S6):
  #
  #   `:none`         the anchored 409 carried no detail at all — D7's 43%, which
  #                   predates the cap and can only be the busy slug.
  #   `{:code, c}`    the box named a machine-readable code.
  #   `:prose`        there IS a detail, and its first segment is not a code —
  #                   an unnamed cause, which must rise in the tail rather than
  #                   inherit `:none`'s busy-slug fallback.
  #
  # The status capture is ANY three digits, not a pinned 409: the 503 arm reads
  # its cause through this same parser, and one parser for one code is the whole
  # point (a chain, a deferral, a refusal and a census must never disagree about
  # what the box said). Widening is safe because every caller is status-gated
  # UPSTREAM — `abandoned_class/1` only runs inside `refusal_class("409", _)`,
  # `refusal_class("503", _)` only sees a 503, and `classify_deferred/2` returns
  # the tail before it reads unless `refusal_code/1` already said "409" — and
  # that safety is pinned by mutation over BOTH 409 shapes in
  # `deploy_ledger_test.exs`, not by this comment.
  #
  # It accepts BOTH phase captions for the same reason `@refusal` does (D218):
  # a poll refusal carries the box's code word in exactly the same position, and
  # an anchor that reads only the start caption throws that word away.
  @deferral_prefix ~r/^the instance refused the (?:deploy|build poll) \((?:HTTP )?\d{3}\):\s*(.+)$/s

  # `Sites.Deploy.box_refusal/3` stamps the box's request id AFTER the detail —
  # `"#{base} [box request_id: #{rid}]"` — while `refusal_detail/1` returns the
  # BARE code when the envelope carries no message. On a code-only refusal the
  # stamp therefore lands INSIDE the first ` — ` segment, and the code read out
  # of it was `box_at_capacity [box request_id: F9tPXq2A]`, which matches
  # nothing. That break is not theoretical and not confined to the cap: it hits
  # `already_running` too, shipping since W1, where a DEFERRED_UNCLASSIFIED row
  # falls back to the generic chain bound and accuses a healthy runner of
  # "refusing this site persistently for a cause the ledger cannot name". So the
  # stamp comes off before the split — it is a provenance annotation, never part
  # of the box's words.
  @request_id_stamp ~r/\s*\[box request_id: [^\]]*\]/

  # A CODE is a bare snake_case token, exactly as `refusal_detail/1` emits one
  # (`err["code"]`, trimmed). Requiring the shape is what stops the opposite
  # spoof: a CODELESS envelope (`%{"error" => %{"message" => "…"}}`, no `code`
  # key) whose prose merely BEGINS with a code word used to be promoted to a
  # capacity refusal with no code involved anywhere — the classifier was reading
  # the first ` — `-delimited segment of arbitrary prose. This stays on the RAW
  # column (see the moduledoc); moving the taxonomy onto a structured field is a
  # design decision above a classifier's pay grade.
  #
  # It is a NARROW close, and honestly so: a codeless message that is byte-for-byte
  # `box_at_capacity — <prose>` is indistinguishable from `code — message` in the
  # persisted string, and no rule over that column can tell them apart.
  @code_token ~r/^[a-z][a-z0-9_]*$/

  @spec deferral_code(String.t()) :: {:code, String.t()} | :prose | :none
  defp deferral_code(reason) do
    case Regex.run(@deferral_prefix, reason) do
      [_, detail] ->
        detail
        |> String.replace(@request_id_stamp, "")
        |> String.split(" — ")
        |> hd()
        |> code_or_prose()

      nil ->
        :none
    end
  end

  defp code_or_prose(segment) do
    if Regex.match?(@code_token, segment), do: {:code, segment}, else: :prose
  end

  defp health_gate?(reason) do
    String.starts_with?(reason, "HEALTH gate failed") or
      String.starts_with?(reason, "HEALTH failed")
  end

  # Inside a BUILD-stage `BUILD failed (exit N)` capture the discriminating fact
  # is what the build could not READ. 1,082 of 1,362 exit-12 rows are the same
  # story: the site's build fetched its corpus from the Barkpark API and got a
  # 403. Matched as `fetch failed: 403`, not as a bare "403", because the rest of
  # the capture is an Astro stack trace full of numbers.
  @corpus_403 ~r/fetch failed:\s*403\b/

  defp build_class(reason) do
    if Regex.match?(@corpus_403, reason), do: "FORBIDDEN_403", else: "BUILD_FAILED"
  end

  defp source_unfetchable?(reason) do
    String.starts_with?(reason, "missing site source dir") or
      String.starts_with?(reason, "artifact: artifact_url is empty") or
      String.contains?(reason, "fetch failed")
  end

  ## ── The census ────────────────────────────────────────────────────────────

  @doc """
  The fleet census over a PINNED `inserted_at` window: counts per class, counts
  per site, and the failure rate WITH its denominator.

  Three cohorts, and the split is load-bearing: `classes` (settled failures, the
  numerator), `deferred` (attempted, refused by a busy box, re-queued — inside
  `volume`, outside the numerator, reported on its own line), and
  `not_attempted` (never a deploy at all, outside both).

  ## Every attempt lands in a NAMED state (D256)

  `volume` used to be the only place a deploy that WORKED appeared, and it shared
  that residue with every row still in flight and every row somebody cancelled.
  A census whose success count is "the part we did not name" cannot be checked by
  anyone, so the census now names the whole population:

    * `live` — the deploy switched. Counted POSITIVELY, off `status == "live"`
      over the SETTLED cohort, never as `volume` minus the failures (D257). A
      subtractive success count reports a repair every time a row changes status
      for an unrelated reason, and cannot ever be wrong out loud.
    * `in_flight` — `queued` / `building` / `pushing`: attempted, not settled.
      Its own cohort because "not failed yet" is not "succeeded".
    * `cancelled` — somebody stopped it. Neither a failure nor a success.
    * `residual` — attempted rows whose `status` this census does not name.
      `deployments.status` is a CHECK-less varchar, so the honest answer to a
      status nobody has taught the census about is a number that GOES UP —
      the D8 discipline applied to statuses instead of to failure reasons.

  `live_rate` is `live / volume` through the same `rate/2` node as
  `failure_rate`, with the same `@min_sample` refusal: a success percentage off
  n=10 is exactly as dishonest as a failure percentage off n=10.

  `failure_rate` and `volume` are UNCHANGED by all of this (D43): the new keys
  are read off the same `attempted`/`settled` split that already existed, and no
  row moves cohorts.

  Both bounds are required and explicit — a floating "now minus 24h" cannot be
  compared against itself a week later, and comparing two unpinned windows is
  how a volume collapse is read as a repair (D3). The window is half-open:
  `from <= inserted_at < to`.

  Returns counts, never rows: the fold is one grouped query
  (`site_id, stage, status, failure_reason`), which is ~1,400 groups over a
  26,000-row table, and the classification runs once per GROUP.

  Every rate node is the same shape and always carries its own denominator:

      %{sample: 18_541, pct: 85.19, min_sample: 200, refused: false, reason: nil}
      %{sample: 74,     pct: nil,   min_sample: 200, refused: true,
        reason: "sample 74 below min_sample 200"}

  ## Scoping the population: `:site_ids` (dr-w16-s6)

  `:site_ids` narrows the census to a list of site ids — how the team-scoped
  route (`GET /v1/deploy-ledger/census`) asks this same function for the caller's
  OWN number. Omit it (or pass `nil`) and the population is the whole fleet,
  which is what the operator route has always asked for.

  THE PREDICATE LIVES HERE, IN THE QUERY, and a post-filter over the rendered
  `sites` node is not the same thing — it is wrong twice. `site_rows/2` sorts by
  volume and takes `site_limit` BEFORE anything downstream could filter, so a
  quiet caller's own site falls off the end of the list entirely; and every
  fleet-wide total above it (`volume`, `failed`, `live`, both rates) would keep
  counting rows the caller may not see. Scoping the SOURCE is the only place the
  narrowing is total.

  `[]` is a legitimate value and means EMPTY, not "everything": a caller who owns
  no site — or who named only sites they do not own — gets `volume: 0`, which is
  the fail-closed answer. That collapse is why the caller must hand this option
  an INTERSECTION it computed itself, never a client-supplied list.

  The ids are interpolated into `d.site_id in ^site_ids`, a `binary_id` column,
  so every element must already be a well-formed UUID — a junk string raises
  `Ecto.Query.CastError` (a 500). The router therefore intersects the request's
  ids with the team's own site ids IN ELIXIR, which drops junk before it can
  reach this query at all.
  """
  @spec census(DateTime.t(), DateTime.t(), keyword()) :: map()
  def census(%DateTime{} = from, %DateTime{} = to, opts \\ []) do
    site_limit = Keyword.get(opts, :site_limit, 50)
    site_ids = Keyword.get(opts, :site_ids)

    scoped =
      from(d in Deployment,
        where: d.inserted_at >= ^from and d.inserted_at < ^to
      )
      |> scope_to_sites(site_ids)

    groups =
      Repo.all(
        from(d in scoped,
          group_by: [d.site_id, d.stage, d.status, d.failure_reason],
          select: %{
            site_id: d.site_id,
            stage: d.stage,
            status: d.status,
            failure_reason: d.failure_reason,
            count: count(d.id)
          }
        )
      )

    classified =
      Enum.map(groups, fn g -> Map.put(g, :class, classify(g)) end)

    {not_attempted, attempted} = Enum.split_with(classified, &not_attempted?(&1.class))

    # THREE cohorts, not two. `deferred` rows stay INSIDE volume — they were real
    # attempts against a real box — but outside the failure numerator, and they
    # get their own reported line so the 409 mass W1 S3 relocates is visibly
    # relocated rather than silently deleted (see `@deferred_classes`).
    {deferred, settled} = Enum.split_with(attempted, &deferred?(&1.class))
    failed_rows = Enum.filter(settled, & &1.class)

    volume = total(attempted)
    failed = total(failed_rows)

    # THE SUCCESS COUNT, READ POSITIVELY (D257). A FILTER over `settled`, never a
    # fourth `Enum.split_with` over `attempted`: the partition shape would move
    # rows out of `failed_rows`' source cohort and change `failure_rate`, which
    # D43 forbids. Read off `status` and not off the classifier, because
    # `classify/1` answers `nil` for a live row and for a queued row alike and
    # those are not the same fact.
    live = total(Enum.filter(settled, &(&1.status == "live")))
    in_flight = total(Enum.filter(settled, &(&1.status in @in_flight_statuses)))
    cancelled = total(Enum.filter(settled, &(&1.status == "cancelled")))

    # What is left when every named state has taken its rows. Zero on a corpus
    # the census fully names — and it must be able to RISE, because
    # `deployments.status` carries no CHECK constraint and a status nobody has
    # taught this census about must surface as an unnamed remainder rather than
    # be absorbed by `live`.
    residual = volume - (failed + total(deferred) + live + in_flight + cancelled)

    not_attempted_rows = class_rows(not_attempted, total(not_attempted), @basis_attempted)
    sites = site_rows(attempted)
    straddled = straddled_boundary(from, to)

    %{
      window: %{from: from, to: to},
      volume: volume,
      failed: failed,
      live: live,
      in_flight: in_flight,
      cancelled: cancelled,
      residual: residual,
      # REFUSED ACROSS THE VOCABULARY BOUNDARY, in place: the counts stay (they
      # are real rows), the PERCENTAGE goes away, because it is the ratio that
      # blends two taxonomies. `live_rate` is deliberately NOT refused (D229).
      failure_rate:
        refuse_across_boundary(rate_basis(failed, volume, @basis_attempted), straddled),
      live_rate: rate_basis(live, volume, @basis_attempted),
      classes: refuse_class_rows(class_rows(failed_rows, failed, @basis_failed), straddled),
      deferred: class_rows(deferred, volume, @basis_attempted),
      not_attempted: not_attempted_rows,
      sites: Enum.take(sites, site_limit),
      # THE TRUNCATION MARKER. `site_limit` has always defaulted to 50 and has
      # always cut silently; a reader who cannot tell a 50-site fleet from the
      # top 50 of a larger one is reading a number with no population.
      total_sites: length(sites),
      truncated: length(sites) > site_limit,
      # The counter that measures the attempts which minted NO row, with a
      # coverage floor that REFUSES rather than summing stored zeros.
      coalesced_attempts: coalesced_attempts(scoped, from),
      # THE SECOND INDEPENDENT COUNT, in the code and not in a test.
      completeness: completeness(scoped, volume, not_attempted_rows),
      boundaries: @boundaries,
      min_sample: @min_sample
    }
  end

  # A window STRADDLES a boundary when the boundary instant falls strictly
  # inside it. A window wholly on one side is internally consistent — every row
  # in it was labelled by the same vocabulary — and refusing it too would make
  # the census refuse most of its own history for no gain.
  defp straddled_boundary(from, to) do
    if DateTime.compare(from, @deferred_status_boundary.instant) == :lt and
         DateTime.compare(to, @deferred_status_boundary.instant) == :gt,
       do: @deferred_status_boundary,
       else: nil
  end

  defp boundary_reason(%{subject: subject, instant: instant, method: method, source: source}) do
    "the window STRADDLES the #{subject} boundary at #{DateTime.to_iso8601(instant)} " <>
      "(method: #{method}, source: #{source}) — the same box refusal is written `failed` " <>
      "before it and `deferred` after it, so this is a blend of two taxonomies, not a measurement"
  end

  defp refuse_across_boundary(node, nil), do: node

  defp refuse_across_boundary(node, boundary),
    do: %{node | pct: nil, refused: true, reason: boundary_reason(boundary)}

  # `classes` IS A LIST ON EVERY PATH, and the boundary refusal lands on each
  # row's SHARE — exactly where `failure_rate` takes it one level up.
  #
  # W18 REVIEW, CHANGED FROM A SHAPE-SWITCHING REFUSAL NODE. As first built this
  # returned `%{value: nil, refused: true, …}` — a MAP where the key is
  # otherwise a LIST. That is a wire-shape change, and the only reader of this
  # envelope declares `Classes []DeployCensusClass`
  # (internal/cloudclient/client.go). `encoding/json` cannot put an object into
  # a slice, so `FleetDeployCensus` would have returned
  # "decode deploy census response: json: cannot unmarshal object into Go struct
  # field DeployCensus.classes" — and `bp cloud deployments`' DEFAULT window is
  # the last 7 days, which straddles the 2026-08-05 boundary. The flagship human
  # reader this same wave repointed at a door that opens would have died on its
  # default invocation, with a decoder's error text, the moment both slices
  # merged. A refusal a reader cannot parse is not a refusal.
  #
  # SO THE COUNTS STAY AND THE RATIOS GO, which is also what this module already
  # does one level up: `volume`, `failed` and `live` survive a straddling window
  # and only `failure_rate` refuses. A class COUNT is a real count of real rows;
  # a class SHARE across the boundary is a ratio of two taxonomies, and it is the
  # ratio that lies. Each refused share carries the boundary reason verbatim, and
  # `failure_rate.reason` names it in the headline besides — so nothing here can
  # be read as "this population had no failures", the risk the refusal node was
  # reaching for.
  defp refuse_class_rows(rows, nil), do: rows

  defp refuse_class_rows(rows, boundary) do
    Enum.map(rows, &%{&1 | share: refuse_across_boundary(&1.share, boundary)})
  end

  # The migration's applied instant. Config-overridable because it is a fact
  # about THIS control plane's database, not about this source tree.
  defp coalesced_counter_since do
    Application.get_env(:barkpark_cloud, :coalesced_counter_since, @coalesced_counter_since)
  end

  defp coalesced_attempts(scoped, from) do
    since = coalesced_counter_since()

    if DateTime.compare(from, since) == :lt do
      %{
        value: nil,
        refused: true,
        since: since,
        basis: @coalesced_basis,
        reason:
          "the coalesced-attempt counter did not exist before #{DateTime.to_iso8601(since)} " <>
            "(migration 20260807150000). Every earlier row carries a materialised default of 0, " <>
            "not a NULL, so a SUM over this window would report a confident 0 — it read 0 for " <>
            "2026-08-06, a day whose true coalesced volume was ~1,563"
      }
    else
      %{
        value: Repo.aggregate(scoped, :sum, :coalesced_attempts) || 0,
        refused: false,
        since: since,
        basis: @coalesced_basis,
        reason: nil
      }
    end
  end

  # THE COMPLETENESS AUDIT. A second query SHAPE over the same `scoped` source:
  # a bare row count with no GROUP BY and no classification fold, reconciled
  # against the numbers this envelope actually reports. `volume` PLUS
  # `not_attempted` — never `volume` alone, or the 7 D19 tombstones make it a
  # permanent false red on the real corpus.
  defp completeness(scoped, volume, not_attempted_rows) do
    audited = Repo.aggregate(scoped, :count, :id)
    accounted = volume + Enum.reduce(not_attempted_rows, 0, &(&1.count + &2))

    %{
      audited: audited,
      accounted: accounted,
      unaccounted: audited - accounted,
      balanced: audited == accounted,
      method:
        "Repo.aggregate(scoped, :count, :id) — no GROUP BY, no classification fold — against volume + sum(not_attempted.count). BLIND SPOT: both shapes inherit `scoped`, so a wrong WHERE in `scoped` itself is invisible to either",
      reason:
        if(audited == accounted,
          do: nil,
          else:
            "the grouped fold reported #{accounted} of #{audited} rows in this window: #{audited - accounted} row(s) are in the population and in NO cohort. Do not read any count in this envelope as complete"
        )
    }
  end

  # The `:site_ids` narrowing, as a clause on the SOURCE query. `nil` is
  # "unscoped" (the fleet census) and an empty list is "no sites" — those are
  # different facts and must not collapse into each other, which is why the
  # absent case is matched on `nil` and never on `[]`.
  defp scope_to_sites(query, nil), do: query

  defp scope_to_sites(query, site_ids) when is_list(site_ids),
    do: from(d in query, where: d.site_id in ^site_ids)

  @doc """
  Parse the census window from raw query params.

  Both are REQUIRED — there is no default window on purpose (D3). Accepts an
  ISO-8601 instant (`2026-07-26T00:00:00Z`) or a bare date (`2026-07-26`, read as
  midnight UTC).
  """
  @spec parse_window(term(), term()) ::
          {:ok, DateTime.t(), DateTime.t()} | {:error, String.t()}
  def parse_window(raw_from, raw_to) do
    with {:ok, from} <- parse_instant(raw_from, "from"),
         {:ok, to} <- parse_instant(raw_to, "to") do
      if DateTime.compare(from, to) == :lt do
        {:ok, from, to}
      else
        {:error, "from must be earlier than to"}
      end
    end
  end

  defp parse_instant(nil, name),
    do: {:error, "#{name} is required — the census window is pinned, never floating"}

  defp parse_instant(raw, name) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        case Date.from_iso8601(raw) do
          {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
          _ -> {:error, "#{name} is not an ISO-8601 date or instant"}
        end
    end
  end

  defp parse_instant(_raw, name), do: {:error, "#{name} is not an ISO-8601 date or instant"}

  @doc """
  A rate node: the percentage, its denominator, WHAT that denominator counts,
  and — below `min_sample/0` — a refusal instead of a number.

  The denominator rides IN the node so no caller can print a percentage without
  the volume that produced it, and `basis` rides beside it so no caller can
  print a percentage without saying what it is a percentage OF (D34). The
  default basis is the attempted population; `rate_basis/3` threads a different
  one where the denominator is a different cohort (a failure class's share is
  taken over `failed`, not over `volume`).
  """
  @spec rate(non_neg_integer(), non_neg_integer()) :: map()
  def rate(numerator, denominator) when denominator < @min_sample do
    %{
      sample: denominator,
      pct: nil,
      numerator: numerator,
      min_sample: @min_sample,
      refused: true,
      reason: "sample #{denominator} below min_sample #{@min_sample}",
      basis: @basis_attempted
    }
  end

  def rate(numerator, denominator) do
    %{
      sample: denominator,
      pct: Float.round(numerator * 100 / denominator, 2),
      numerator: numerator,
      min_sample: @min_sample,
      refused: false,
      reason: nil,
      basis: @basis_attempted
    }
  end

  # The basis as a REAL argument, never a default one on `rate/2` (D199): a
  # default would let a caller emit a rate whose label says "attempted" over a
  # denominator that is nothing of the kind, and the payload census pairs
  # `rate/2` with the Go `DeployRate` struct on the assumption that every clause
  # of it names the same key set.
  defp rate_basis(numerator, denominator, basis),
    do: %{rate(numerator, denominator) | basis: basis}

  defp total(groups), do: Enum.reduce(groups, 0, &(&1.count + &2))

  # The basis rides in as a REAL argument for the same reason `rate_basis/3`
  # takes one: a class share is denominated on `failed`, a deferral share on
  # `volume`, and a single default would put the wrong sentence beside half the
  # percentages this module emits.
  defp class_rows(groups, denominator, basis) do
    groups
    |> Enum.filter(& &1.class)
    |> Enum.group_by(& &1.class)
    |> Enum.map(fn {class, rows} ->
      count = total(rows)

      %{
        class: class,
        label: label(class),
        count: count,
        share: rate_basis(count, denominator, basis)
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  # EVERY site, volume-sorted and UNCUT. The `site_limit` take moved up into
  # `census/3` so the cut and the marker that reports it are written next to
  # each other — a truncation applied here and a `total_sites` computed there
  # is exactly how a silent cut gets re-introduced.
  defp site_rows(groups) do
    groups
    |> Enum.group_by(& &1.site_id)
    |> Enum.map(fn {site_id, rows} -> site_row(site_id, rows) end)
    |> Enum.sort_by(& &1.volume, :desc)
  end

  # ONE site's row, as a NAMED single-clause producer rather than an inline
  # anonymous fn — the payload census can only walk a named `def`/`defp`, so an
  # inline map literal is a wire shape NOTHING checks against its Go decoder.
  # `{:site_row, 2}` is a censused pair; a key added here without a matching
  # `DeployCensusSite` tag now reds.
  defp site_row(site_id, rows) do
    volume = total(rows)
    # Same three-cohort split as the fleet totals: a deferral is in the site's
    # volume and out of its failure count, and is reported beside it so a site
    # whose 409s became deferrals does not read as a site that got healthy.
    {deferred, settled} = Enum.split_with(rows, &deferred?(&1.class))
    failed_rows = Enum.filter(settled, & &1.class)
    failed = total(failed_rows)

    %{
      site_id: site_id,
      volume: volume,
      failed: failed,
      deferred: total(deferred),
      # PER-SITE SUCCESS, READ POSITIVELY — the same one-liner the fleet total
      # uses (D257), never `volume - failed - deferred`. A subtraction would
      # fold in-flight and cancelled rows into `live` and report a site as
      # healthy on the strength of builds that never finished.
      live: total(Enum.filter(settled, &(&1.status == "live"))),
      failure_rate: rate_basis(failed, volume, @basis_attempted),
      top_class: top_class(failed_rows)
    }
  end

  defp top_class([]), do: nil

  defp top_class(rows) do
    rows
    |> Enum.group_by(& &1.class)
    |> Enum.map(fn {class, group} -> {class, total(group)} end)
    |> Enum.max_by(fn {_class, count} -> count end)
    |> elem(0)
  end

  ## ── The delivery clock ────────────────────────────────────────────────────

  # The clock's own name, carried IN the payload. A latency number whose t0 is
  # not printed beside it is a number nobody can audit, and this t0 is a proxy:
  # the attempt row, not the publish (dr-w11-s1 starts the true one).
  @delivery_clock "deployment row: inserted_at → became_live_at (row-keyed proxy; the publish-keyed clock lands with dr-w11-s1)"

  # What the value IS when it is a value: floored, never trimmed, never dropped.
  @delivery_basis "floored: a still-waiting row contributes its lower bound (as_of - inserted_at) and is never dropped; no trimming — the long waits are the signal"

  @doc """
  How long content WAITED to reach the web over a PINNED window — an estimator
  that REFUSES a percentile it cannot identify, plus the cohort that is STILL
  WAITING, named.

  Ten waves of this epic measured what FRACTION of attempt rows settle failed.
  Nobody measured how LONG. `census/3` groups by `[site_id, stage, status,
  failure_reason]` and carries no time dimension at all, so a fleet whose rate
  improves while every publish waits six hours reads as a fleet getting better.

  ## The clock, named honestly (D161/D162)

  This keys on the DEPLOYMENT ROW: `inserted_at` (the attempt was written) →
  `became_live_at` (bytes answered on the web). It is NOT the publish-keyed
  clock — slice dr-w11-s1 starts that one, and a later wave re-keys this
  estimator onto it. It is deliberately NOT keyed on `content_rev` either: that
  column is `sha256([doc_type, published_count, published_events])` over a
  DATASET-WIDE last-50 activity window, so it moves without a publish and 1,474
  of 3,106 `(site, rev)` groups repeat (one spanning 29.2h). Singleton rev groups
  read p50 108s — indistinguishable from the per-attempt distribution — while
  collapsed groups read 152s/693s, so 100% of the inflation revision-keying
  produces is its own collapse artefact.

  And it is not D142's run-keyed journey: there a failed row is TERMINAL and
  CLOSES a run, so consecutive failures become singleton runs of identically
  0.0s (393 of 647 live journeys). Site d8e9c2c7's 6h17m wait decomposes into 82
  such runs, 80 of them 0.0s. Here a row that did NOT reach live is resolved by
  the site's next live mark — so that outage stays ONE 22,638s wait.

  ## Censoring is FLOORED, never dropped

  A row with no live mark at or after it has not been delivered YET. Its wait is
  a LOWER BOUND (`as_of - inserted_at`), and it enters the sample carrying that
  bound. Dropping it is the failure mode this function exists to refuse: the
  dropped estimator sits flat at 94-150s at EVERY window width — structurally
  incapable of ever showing delay — while the floored one swings 829x.

  ## The identifiability refusal — NOT a width guard

  Narrowing the window is not the fix (p95 already diverges 11.0x at the
  narrowest width) and `min_sample` does not catch it either (a 6h window passes
  at n=217 with 36.9% censored). The predicate that discriminates is
  `censored_fraction > (1 - q)`: a quantile needs `1 - q` of the mass ABOVE it,
  and if more than that is still running the true value is unknowable. It agreed
  14/14 with the empirical test — whether the row AT `ceil(n*q)` is itself
  censored — which is applied as a third policy anyway.

  ON TODAY'S CORPUS p95 REFUSES AT EVERY WIDTH. That is the true answer, not a
  broken feature: 40%+ of rows in any window are still waiting, and no estimator
  can name a 95th percentile of a distribution whose top 40% has not finished.

  ## Scope (D163)

  `production` only — `census/3` applies no environment predicate at all while
  `list_page/2` one function away has `filter_environment/2`. The column is NOT
  NULL DEFAULT `production`, so every pre-gh-6 row is already in scope. Rows the clock
  CANNOT reach — a `live` row with no `became_live_at` — are reported as an
  explicit `unmetered` count, never a WHERE clause: jarl-website has 55 rows, 23
  live deliveries and ZERO non-null `content_rev`, so a naive key filter would
  silently omit an entire customer site.

  Every percentile is an INSEPARABLE node — the value cannot travel without its
  window width, its sample and its censored count:

      %{quantile: 0.95, label: "p95", seconds: nil, sample: 1000, censored: 400,
        censored_fraction: 0.4, headroom: 0.05, window_seconds: 86_400,
        min_sample: 200, refused: true, basis: "…",
        reason: "p95 is UNIDENTIFIABLE: 40.0% are still waiting, exceeding the 5.0% headroom p95 needs"}

  ## Scoping the population: `:site_ids` (dr-w21-s6)

  IDENTICAL IN MEANING TO `census/3`'s option, and it exists for the same
  reason: the TEAM route (`GET /v1/deploy-ledger/census`) asks this same
  function for the caller's OWN waits. Until this option existed the function
  had exactly two narrowing knobs — `:site_limit` and `:as_of` — and its query
  filtered `inserted_at` and `environment` and NOTHING ELSE, i.e. it was
  FLEET-WIDE by construction. `Map.put(:delivery, delivery(from, to))` on a
  team-scoped body would therefore have rendered OTHER TEAMS' `site_id`s inside
  the caller's own envelope: an IDOR on a latency number, and on the `sites`
  list under it by name.

  THE PREDICATE LIVES IN THE QUERY, exactly as it does in `census/3` and for a
  sharper reason here: the estimator is a QUANTILE over a pooled, sorted sample.
  A post-filter over the rendered `sites` node cannot repair `p50`/`p95`/`max`,
  `sample`, `delivered` or `censored` — every one of those is folded from
  foreign observations BEFORE any downstream filter could run — so a scoped
  reader would print a fleet-wide percentile under a team's name.

  `[]` means EMPTY, not "everything": a caller who owns no site gets `sample: 0`
  and a refusal, which is the fail-closed answer. `nil` (or omitting the option)
  is the whole fleet, which is what the operator route asks for. The ids reach
  a `binary_id` column, so the caller must hand this an intersection it computed
  itself — never a client-supplied list.

  Options: `:as_of` (the still-waiting clock, default now), `:site_limit`
  (default 50), `:site_ids` (default `nil` — the whole fleet).
  """
  @spec delivery(DateTime.t(), DateTime.t(), keyword()) :: map()
  def delivery(%DateTime{} = from, %DateTime{} = to, opts \\ []) do
    site_limit = Keyword.get(opts, :site_limit, 50)
    site_ids = Keyword.get(opts, :site_ids)
    as_of = opts |> Keyword.get(:as_of, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    scoped =
      from(d in Deployment,
        where: d.inserted_at >= ^from and d.inserted_at < ^to,
        # PRODUCTION only. Safe as a WHERE because the column is NOT NULL
        # DEFAULT 'production' (20260702170000_add_branch_previews) — every
        # pre-gh-6 row is already production, so nothing is silently dropped.
        # The rows that CANNOT be dropped by a predicate are the unkeyable
        # ones, and those are counted in `unmetered` below.
        where: d.environment == "production"
      )
      # THE SAME clause `census/3` uses, on the SAME source query — one
      # narrowing, one meaning, so a team's delivery population and its census
      # population can never be two different sets of rows.
      |> scope_to_sites(site_ids)

    rows =
      Repo.all(
        from(d in scoped,
          select: %{
            site_id: d.site_id,
            status: d.status,
            inserted_at: d.inserted_at,
            became_live_at: d.became_live_at
          }
        )
      )

    site_nodes =
      rows
      |> Enum.group_by(& &1.site_id)
      |> Enum.map(fn {site_id, site_rows} -> site_delivery(site_id, site_rows, as_of) end)

    # Sorted ONCE, ascending, over the FLOORED seconds — censored rows included,
    # carrying their lower bound. Every quantile below indexes into this list.
    observations =
      site_nodes |> Enum.flat_map(& &1.observations) |> Enum.sort_by(& &1.seconds)

    censored = Enum.filter(observations, & &1.censored)
    width = DateTime.diff(to, from)

    ranked =
      site_nodes
      |> Enum.map(&Map.delete(&1, :observations))
      |> Enum.sort_by(&{&1.sample, &1.site_id}, :desc)

    %{
      window: %{from: from, to: to, width_seconds: width},
      as_of: as_of,
      environment: "production",
      clock: @delivery_clock,
      sample: length(observations),
      delivered: length(observations) - length(censored),
      p50: delivery_quantile(observations, 0.5, "p50", width),
      p95: delivery_quantile(observations, 0.95, "p95", width),
      max: delivery_quantile(observations, 1.0, "max", width),
      censored: %{
        count: length(censored),
        as_of: as_of,
        still_waiting_at_least_seconds:
          censored |> Enum.map(& &1.seconds) |> Enum.max(fn -> nil end)
      },
      unmetered: Enum.reduce(site_nodes, 0, &(&1.unmetered + &2)),
      min_sample: @min_sample,
      sites: Enum.take(ranked, site_limit),
      # THE SAME TRUNCATION MARKER the census node carries. `site_limit` has
      # defaulted to 50 here too and cut just as silently; the Go side's own
      # marker is over its OWN 10-row clamp and is structurally blind to this
      # cut, so a reader could never tell a 50-site fleet from the top 50.
      total_sites: length(ranked),
      truncated: length(ranked) > site_limit
    }
  end

  # One site's rows folded into observations. `live_marks` is that site's ordered
  # list of "content answered on the web at" instants; a row that did not itself
  # reach live is DELIVERED by the first mark at or after it (that is when the
  # site's content did reach the web) and CENSORED when there is no such mark.
  defp site_delivery(site_id, rows, as_of) do
    live_marks =
      rows
      |> Enum.filter(&(&1.status == "live" and &1.became_live_at != nil))
      |> Enum.map(& &1.became_live_at)
      |> Enum.sort(DateTime)

    # UNMETERED, not filtered: a `live` row with no `became_live_at` reached the
    # web at a time this ledger cannot name. It is counted and reported; it is
    # never quietly deleted from the denominator.
    {unmetered, keyed} =
      Enum.split_with(rows, &(&1.status == "live" and is_nil(&1.became_live_at)))

    observations = Enum.map(keyed, &observe(&1, live_marks, as_of))
    still_waiting = Enum.filter(observations, & &1.censored)

    %{
      site_id: site_id,
      sample: length(observations),
      delivered: length(observations) - length(still_waiting),
      censored: length(still_waiting),
      unmetered: length(unmetered),
      still_waiting: still_waiting != [],
      oldest_waiting_seconds: still_waiting |> Enum.map(& &1.seconds) |> Enum.max(fn -> nil end),
      as_of: as_of,
      observations: observations
    }
  end

  defp observe(%{status: "live", became_live_at: %DateTime{} = live} = row, _marks, _as_of),
    do: %{site_id: row.site_id, seconds: waited(row.inserted_at, live), censored: false}

  defp observe(row, marks, as_of) do
    case Enum.find(marks, &(DateTime.compare(&1, row.inserted_at) != :lt)) do
      %DateTime{} = live ->
        %{site_id: row.site_id, seconds: waited(row.inserted_at, live), censored: false}

      nil ->
        %{site_id: row.site_id, seconds: waited(row.inserted_at, as_of), censored: true}
    end
  end

  defp waited(t0, t1), do: max(DateTime.diff(t1, t0, :millisecond), 0) / 1000

  # The estimator, with rate/2's refusal shape and rate/2's promise that the
  # denominator rides IN the node.
  #
  # NO TRIM. `Registry.stage_verdict/1` is the right refusal SHAPE but trims the
  # tails first; for time-to-web the long waits ARE the signal this epic exists
  # to expose, so trimming here would delete the finding.
  defp delivery_quantile(observations, q, label, window_seconds) do
    n = length(observations)
    censored = Enum.count(observations, & &1.censored)
    fraction = if n == 0, do: 0.0, else: censored / n
    headroom = 1.0 - q
    at = Enum.at(observations, quantile_index(n, q))

    node = %{
      quantile: q,
      label: label,
      sample: n,
      censored: censored,
      censored_fraction: Float.round(fraction, 4),
      headroom: Float.round(headroom, 4),
      window_seconds: window_seconds,
      min_sample: @min_sample,
      basis: @delivery_basis
    }

    cond do
      n < @min_sample ->
        refused(node, "sample #{n} below min_sample #{@min_sample}")

      fraction > headroom ->
        refused(
          node,
          "#{label} is UNIDENTIFIABLE: #{pct(fraction)}% are still waiting, " <>
            "exceeding the #{pct(headroom)}% headroom #{label} needs"
        )

      at.censored ->
        refused(
          node,
          "#{label} lands ON a still-waiting row (position #{quantile_index(n, q) + 1} of #{n}) — " <>
            "its true value is at least #{at.seconds}s and cannot be named"
        )

      true ->
        Map.merge(node, %{seconds: at.seconds, refused: false, reason: nil})
    end
  end

  # 1-based `ceil(n * q)`, expressed 0-based. q = 1.0 is the max.
  defp quantile_index(0, _q), do: 0

  defp quantile_index(n, q),
    do: n |> Kernel.*(q) |> Float.ceil() |> trunc() |> max(1) |> min(n) |> Kernel.-(1)

  defp refused(node, reason),
    do: Map.merge(node, %{seconds: nil, refused: true, reason: reason})

  defp pct(fraction), do: Float.round(fraction * 100, 1)

  ## ── The cursor ────────────────────────────────────────────────────────────

  @doc """
  One page of a site's deployments, newest first, with a keyset cursor.

  `Registry.list_deployments/3` has no offset clause at all, so `offset`,
  `page`, `cursor` and `before` were ALL silently ignored and the 200-row cap was
  a hard ceiling — on the five hot sites that is a 51-hour window, and nothing
  outside the database could audit the ledger's own numbers. This is the read
  that can reach past it. `Registry.latest_deployment_status_map/1` is left
  alone: bp-search-template D24 froze its four-key select as an honesty law.

  The cursor is a KEYSET, not an offset: `(inserted_at, id) < (cursor)` under the
  same `desc: inserted_at, desc: id` order. A row inserted mid-pagination cannot
  shift a later page (an offset would duplicate or skip one).

  Options: `:limit` (default 100, capped at 200), `:environment`, `:before` (an
  opaque cursor from a previous page's `next_cursor`).

  `next_cursor` is `nil` on the last page — and it is derived from a `limit + 1`
  probe, so a page that happens to be exactly `limit` long does not hand back a
  cursor to an empty page.
  """
  @spec list_page(Site.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, %{deployments: [Deployment.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor}
  def list_page(site, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> min(200) |> max(1)

    case decode_cursor(Keyword.get(opts, :before)) do
      {:ok, cursor} ->
        rows =
          site
          |> page_query(Keyword.get(opts, :environment, :all))
          |> apply_cursor(cursor)
          |> limit(^(limit + 1))
          |> Repo.all()

        {page, rest} = Enum.split(rows, limit)
        next = if rest == [], do: nil, else: encode_cursor(List.last(page))
        {:ok, %{deployments: page, next_cursor: next}}

      :error ->
        {:error, :invalid_cursor}
    end
  end

  defp page_query(site, environment) do
    site_id = site_id(site)

    Deployment
    |> where([d], d.site_id == ^site_id)
    |> filter_environment(environment)
    |> order_by([d], desc: d.inserted_at, desc: d.id)
  end

  defp site_id(%Site{id: id}), do: id
  defp site_id(id) when is_binary(id), do: id

  defp filter_environment(query, env) when env in ["production", "preview"],
    do: where(query, [d], d.environment == ^env)

  defp filter_environment(query, _), do: query

  defp apply_cursor(query, nil), do: query

  # A ROW comparator on the compound key the page is ordered by — same rows as the
  # equivalent `inserted_at < ^ts or (inserted_at == ^ts and id < ^id)`, but only
  # this form can SEEK: on the EXISTING `(site_id, inserted_at)` index the OR
  # decomposition leaves `Index Cond:` carrying `site_id` alone and filters the
  # stamp bound row-by-row, while the ROW form lifts `inserted_at <= $2` into the
  # Index Cond (measured 542 → 14 buffers for a 50-row page on a 250k-row corpus).
  # NO migration; the index is unchanged.
  #
  # THE SPELLING IS LOAD-BEARING. `type(^ts, :utc_datetime_usec)` renders
  # `$2::timestamp` — naive against a `timestamptz` column, coerced through the
  # SESSION TimeZone, slipping the boundary by the server's UTC offset — so `$2`
  # is left UNCAST and Postgres infers `timestamptz` from the ROW's left operand.
  # The id half needs `type(^id, Ecto.UUID)` or Ecto never dumps the string and
  # Postgrex raises "expected a binary of 16 bytes". `id` is already a validated
  # UUID here: `decode_cursor/1` only yields `{ts, id}` after `Ecto.UUID.cast`,
  # and anything malformed is still `:error` → `{:error, :invalid_cursor}`.
  #
  # Both operands are NOT NULL in the DDL (`id` is the primary key, `inserted_at`
  # comes from `timestamps(type: :utc_datetime_usec)`), so the ROW form's NULL
  # semantics are unreachable.
  defp apply_cursor(query, {ts, id}) do
    where(query, [d], fragment("(?,?) < (?,?)", d.inserted_at, d.id, ^ts, type(^id, Ecto.UUID)))
  end

  @doc "The opaque cursor that resumes AFTER `deployment`."
  @spec encode_cursor(Deployment.t()) :: String.t()
  def encode_cursor(%Deployment{inserted_at: ts, id: id}) do
    Base.url_encode64("#{DateTime.to_iso8601(ts)}|#{id}", padding: false)
  end

  @doc """
  Decode a cursor. `nil` is the first page; anything unparseable is `:error` so
  the route can answer 422 rather than silently serving page one again — which is
  exactly the failure the offset param had.
  """
  @spec decode_cursor(String.t() | nil) ::
          {:ok, nil} | {:ok, {DateTime.t(), Ecto.UUID.t()}} | :error
  def decode_cursor(nil), do: {:ok, nil}
  def decode_cursor(""), do: {:ok, nil}

  def decode_cursor(raw) when is_binary(raw) do
    with {:ok, decoded} <- Base.url_decode64(raw, padding: false),
         [ts_raw, id_raw] <- String.split(decoded, "|", parts: 2),
         {:ok, ts, _offset} <- DateTime.from_iso8601(ts_raw),
         {:ok, id} <- Ecto.UUID.cast(id_raw) do
      {:ok, {ts, id}}
    else
      _ -> :error
    end
  end

  def decode_cursor(_other), do: :error
end
