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
  """

  import Ecto.Query, warn: false

  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Registry.Site
  alias BarkparkCloud.Repo

  @typedoc "A failure class name — one of `classes/0` (or `not_attempted_classes/0`)."
  @type class :: String.t()

  # The taxonomy, ORDERED most-frequent-first on the 2026-08-05 corpus. Order is
  # presentation only; `classify/2`'s own arms are ordered by specificity.
  @classes [
    "BOX_BUSY_409",
    "DOC_ID_EMPTY",
    "BOX_500",
    "FORBIDDEN_403",
    "BUILD_FAILED",
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
    "DOC_ID_EMPTY" => "HEALTH gate: the bp-doc-id marker was empty",
    "BOX_500" => "the box errored on the deploy (HTTP 500)",
    "FORBIDDEN_403" => "the build could not read its content (403)",
    "BUILD_FAILED" => "the site build exited non-zero",
    "BOX_UNAVAILABLE_503" => "the box was unavailable (HTTP 503)",
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

  # Below this many ATTEMPTED rows a percentage is noise, not a measurement: at
  # the 2026-08-05 daily volume (n=332, and n≈70 in a 24h slice of the quiet
  # sites) a single row moves the rate more than a percentage point.
  @min_sample 200

  @doc "The named failure classes, most-frequent-first on the corpus that motivated them."
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc "Classes that were never a deploy ATTEMPT and never enter a rate denominator."
  @spec not_attempted_classes() :: [class()]
  def not_attempted_classes, do: @not_attempted_classes

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
        refusal_class(code)

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
  @refusal ~r/^the instance refused the deploy \((?:HTTP )?(\d{3})\)/

  defp refusal_code(reason) do
    case Regex.run(@refusal, reason) do
      [_, code] -> code
      nil -> nil
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
  @deferral_prefix ~r/^the instance refused the deploy \((?:HTTP )?409\):\s*(.+)$/s

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
  """
  @spec census(DateTime.t(), DateTime.t(), keyword()) :: map()
  def census(%DateTime{} = from, %DateTime{} = to, opts \\ []) do
    site_limit = Keyword.get(opts, :site_limit, 50)

    groups =
      Repo.all(
        from(d in Deployment,
          where: d.inserted_at >= ^from and d.inserted_at < ^to,
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

    %{
      window: %{from: from, to: to},
      volume: volume,
      failed: failed,
      failure_rate: rate(failed, volume),
      classes: class_rows(failed_rows, failed),
      deferred: class_rows(deferred, volume),
      not_attempted: class_rows(not_attempted, total(not_attempted)),
      sites: site_rows(attempted, site_limit),
      min_sample: @min_sample
    }
  end

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
  A rate node: the percentage, its denominator, and — below `min_sample/0` — a
  refusal instead of a number.

  The denominator rides IN the node so no caller can print a percentage without
  the volume that produced it.
  """
  @spec rate(non_neg_integer(), non_neg_integer()) :: map()
  def rate(numerator, denominator) when denominator < @min_sample do
    %{
      sample: denominator,
      pct: nil,
      numerator: numerator,
      min_sample: @min_sample,
      refused: true,
      reason: "sample #{denominator} below min_sample #{@min_sample}"
    }
  end

  def rate(numerator, denominator) do
    %{
      sample: denominator,
      pct: Float.round(numerator * 100 / denominator, 2),
      numerator: numerator,
      min_sample: @min_sample,
      refused: false,
      reason: nil
    }
  end

  defp total(groups), do: Enum.reduce(groups, 0, &(&1.count + &2))

  defp class_rows(groups, denominator) do
    groups
    |> Enum.filter(& &1.class)
    |> Enum.group_by(& &1.class)
    |> Enum.map(fn {class, rows} ->
      count = total(rows)

      %{
        class: class,
        label: label(class),
        count: count,
        share: rate(count, denominator)
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp site_rows(groups, site_limit) do
    groups
    |> Enum.group_by(& &1.site_id)
    |> Enum.map(fn {site_id, rows} ->
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
        failure_rate: rate(failed, volume),
        top_class: top_class(failed_rows)
      }
    end)
    |> Enum.sort_by(& &1.volume, :desc)
    |> Enum.take(site_limit)
  end

  defp top_class([]), do: nil

  defp top_class(rows) do
    rows
    |> Enum.group_by(& &1.class)
    |> Enum.map(fn {class, group} -> {class, total(group)} end)
    |> Enum.max_by(fn {_class, count} -> count end)
    |> elem(0)
  end

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
