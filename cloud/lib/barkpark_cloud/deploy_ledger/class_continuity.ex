defmodule BarkparkCloud.DeployLedger.ClassContinuity do
  @moduledoc """
  THE CLASS-CONTINUITY GAUGE: did a cause class DIE, or was it RENAMED?
  Deploy-reliability W18, charter **D265** — replacing the W12/D179 gauge that
  stood here.

  ## The event this exists for

  Between 2026-08-01 and 2026-08-06 guerrilla's published failure rate fell from
  87% of attempts to ~1%. Roughly sixty percent of that collapse is a RENAME.
  HTTP-409 box contention used to settle `status='failed'` and be classified
  `BOX_BUSY_409`; from `2026-08-05 21:27:11.41321` the same physical refusal
  settles `status='deferred'` and classifies `BOX_AT_CAPACITY_DEFERRED`. The
  rows never stopped arriving. Only their name changed.

  On the daily shape either side of that (08-01 `2217/284/1933/0`, 08-06
  `2205/566/866/773` as volume/live/failed/deferred) the mass that vanished from
  `BOX_BUSY_409` — **76.68% of all attempts** — did not go to zero. 35.06% of
  attempts reappeared in a DIFFERENT COHORT as deferrals, and the rest moved to
  sibling failure classes. An instrument that cannot say that out loud will
  report every future taxonomy change as a fix.

  ## Why the D179 gauge could not say it, and what changed

  The gauge that stood here read COUNTS inside ONE cohort — `census.deferred` or
  `census.classes`, one at a time — and its verdict vocabulary was
  `:renamed | :went_quiet | :cohort_drained | :below_floor`. Three consequences,
  all fatal for the event above:

    * **The successor lives in the other cohort.** On specimen (a) the D179 gauge
      does fire `:renamed` on `BOX_BUSY_409`, but its `absorbed_by` can only name
      failure classes — it never sees the 773 deferrals that are the actual
      successor, because they are not in the cohort it was handed.
    * **A cohort-relative reading is not commensurable.** Turned into a share
      against its own cohort the same event reads `87.95% of failures`; against
      attempts it reads `76.68% of attempts`. Only the second can be compared
      with a deferred-cohort birth, and that comparison IS the
      `:renamed`-vs-`:repaired` judgement.
    * **It cannot print `:repaired`.** A gauge whose vocabulary has no word for
      "this class genuinely went away and nothing wears its name" is a gauge that
      cannot lose.

  ## The contract (charter D265, clauses i–ix)

    * **(i)** the denominator is `census.volume` — ATTEMPTS — for every class in
      every cohort, so a failed-cohort death and a deferred-cohort birth are
      measured on one ruler;
    * **(ii)** there is **NO volume tolerance anywhere**. Of the seven daily
      volumes since 08-01 (2217, 2042, 1050, 527, 878, 2205, 1638) exactly one
      adjacent pair survives a ±10% gate, so any "volume holds" clause is
      unusable on this corpus and would mute the gauge on six days in seven;
    * **(iii)** the only floor is `census.min_sample` (200), applied to BOTH
      windows, returning this module's own refusal shape — same key set, no
      percentage anywhere;
    * **(iv)** the basis is the immediately-prior EQUAL-LENGTH window, derived by
      `DeployLedger.census/3` itself (`DeployLedger.class_continuity/3`). No
      store, no committed baseline, nothing that can go stale;
    * **(v)** it iterates the UNION of classes PRESENT in the two censuses, never
      `@classes`/`deferred_classes()`. Reading the code's enum makes every
      minted-but-unseen class a 0 → 0 death forever and turns adding a class NAME
      into an alarm generator;
    * **(vi)** a material death (≥ #{1.0}% of attempts) is `:renamed` when
      ≥ 75% of its lost share was absorbed elsewhere, and `:repaired` otherwise
      — that is the arm that lets this gauge LOSE;
    * **(vii)** a birth is `:new_cause`, never `:renamed`, so nobody is told a
      brand-new cause was a relabel;
    * **(viii)** a class absent from BOTH windows is SILENT;
    * **(ix)** deaths and births are PAIRED by absorbed share and the UNPAIRED
      remainder is reported on BOTH sides. The W12 probe suppressed every birth
      whenever any death existed; that hole is not copied here.

  ## What it does NOT claim

  A finding is "this class's share moved to other classes", never "the code was
  renamed". A genuine cause change produces the identical signature and SHOULD:
  the instrument keyed on the old class is equally blind either way, and that is
  the harm being detected. `counterparts` names the suspects by share so a reader
  settles which it was in one look.

  ## Cohorts read

  `census.classes` (the failure cohort) and `census.deferred` (the deferral
  cohort) TOGETHER — both are populations inside `volume`, which is what makes
  one denominator legitimate for both. `not_attempted` is deliberately excluded:
  those rows are DISJOINT from `volume` by construction (D19 tombstones), so a
  share of attempts is not defined for them.
  """

  # Below this share of attempts a death is noise: a class of a dozen rows on a
  # 2,000-attempt day dies and is reborn constantly. Expressed in SHARE and not
  # in rows on purpose — a row floor means something different on a 300-attempt
  # day than on a 2,700-attempt one, and the corpus spans exactly that range.
  @material_share 1.0

  # How much of a dead class's lost share must have turned up elsewhere before
  # "it was relabelled" beats "it was fixed". Not a tolerance on volume — this
  # is a ratio between two shares of the SAME denominator, which is the only
  # comparison D265 permits.
  @absorption_floor 0.75

  # How many counterparts a finding carries. Enough to see the successor and see
  # that it IS the successor; not a dump of every class that moved a row.
  @suspects 5

  @basis "share of ATTEMPTS (`census.volume`) for every class in every cohort — a failure-cohort death and a deferral-cohort birth are measured on ONE denominator, which is what makes them comparable (D265 i)"

  @type verdict :: :renamed | :repaired | :new_cause

  @typedoc "One class's continuity reading across the two windows."
  @type finding :: %{
          class: String.t(),
          kind: :death | :birth,
          verdict: verdict(),
          share_before: float(),
          share_after: float(),
          moved_share: float(),
          absorbed_share: float(),
          unpaired_share: float(),
          counterparts: [%{class: String.t(), share: float()}]
        }

  @typedoc """
  The gauge's envelope. The key set is IDENTICAL in the measured and the refused
  arm — a refusal a reader has to pattern-match differently is a wire-shape
  change, which is the mistake `refuse_class_rows/2` in `DeployLedger` was
  rewritten to stop making.
  """
  @type envelope :: %{
          basis: String.t(),
          min_sample: pos_integer(),
          attempts_before: non_neg_integer(),
          attempts_after: non_neg_integer(),
          refused: boolean(),
          reason: String.t() | nil,
          findings: [finding()],
          classes_read: [String.t()]
        }

  @doc """
  The gauge, over two `DeployLedger.census/3` envelopes of EQUAL LENGTH, the
  second immediately following the first.

  Returns every material death and every material birth with its verdict, or
  this module's refusal when either window is below `census.min_sample`.

  @canonical capability:deploy-class-continuity-gauge aka:class_continuity,rename_vs_repair,cause-class-rename doc:.claude/workflows/bp-deploy-reliability-charter.md#D265
  """
  @spec gauge(map(), map()) :: envelope()
  def gauge(before_census, after_census) do
    attempts_before = Map.fetch!(before_census, :volume)
    attempts_after = Map.fetch!(after_census, :volume)
    min_sample = Map.fetch!(after_census, :min_sample)

    # CLAUSE (iii). BOTH windows, and the refusal names both samples and the
    # floor — an operator must not have to guess which side was thin. Nothing
    # below this line runs when it fires, so no percentage can be printed off a
    # sample too small to carry one.
    if attempts_before < min_sample or attempts_after < min_sample do
      %{
        basis: @basis,
        min_sample: min_sample,
        attempts_before: attempts_before,
        attempts_after: attempts_after,
        refused: true,
        reason: "attempts #{attempts_before}/#{attempts_after} below min_sample #{min_sample}",
        findings: [],
        classes_read: []
      }
    else
      measure(before_census, after_census, attempts_before, attempts_after, min_sample)
    end
  end

  defp measure(before_census, after_census, attempts_before, attempts_after, min_sample) do
    before_shares = shares(before_census, attempts_before)
    after_shares = shares(after_census, attempts_after)

    # CLAUSE (v) AND (viii) IN ONE LINE. The universe is what the two windows
    # OBSERVED, never `DeployLedger.classes()`/`deferred_classes()`: a class
    # nobody wrote rows for is absent from both maps and therefore has no reading
    # at all, rather than a 0 → 0 death that alarms forever.
    classes_read =
      before_shares
      |> Map.keys()
      |> Enum.concat(Map.keys(after_shares))
      |> Enum.uniq()
      |> Enum.sort()

    deaths =
      classes_read
      |> Enum.map(fn class ->
        {class, share(before_shares, class), share(after_shares, class)}
      end)
      |> Enum.filter(fn {_c, b, a} -> a == 0.0 and b >= @material_share end)
      |> Enum.map(fn {c, b, _a} -> {c, b} end)

    births =
      classes_read
      |> Enum.map(fn class ->
        {class, share(before_shares, class), share(after_shares, class)}
      end)
      |> Enum.filter(fn {_c, b, a} -> b == 0.0 and a >= @material_share end)
      |> Enum.map(fn {c, _b, a} -> {c, a} end)

    # WHERE THE SHARE WENT — every class that GAINED share, birth or survivor
    # alike. "Absorbed elsewhere" is not "absorbed by a new name": on specimen
    # (a) part of the vanished 409 mass reappears as deferrals (a birth) and part
    # as growth in sibling failure classes, and a pool that counted only births
    # would call that event a repair.
    gains =
      classes_read
      |> Enum.map(fn class ->
        {class, share(after_shares, class) - share(before_shares, class)}
      end)
      |> Enum.filter(fn {_c, delta} -> delta > 0.0 end)

    lost_total = deaths |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    gained_total = gains |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    # CLAUSE (ix). The paired pool is the share that BOTH sides can account for;
    # what each side is left holding is its unpaired remainder, reported on that
    # side rather than silently dropped.
    paired = min(lost_total, gained_total)

    death_findings =
      Enum.map(deaths, fn {class, lost} ->
        absorbed = allocate(lost, lost_total, paired)

        %{
          class: class,
          kind: :death,
          verdict: if(absorbed >= @absorption_floor * lost, do: :renamed, else: :repaired),
          share_before: round2(lost),
          share_after: 0.0,
          moved_share: round2(lost),
          absorbed_share: round2(absorbed),
          unpaired_share: round2(lost - absorbed),
          counterparts: counterparts(gains, gained_total, absorbed)
        }
      end)

    birth_findings =
      Enum.map(births, fn {class, gained} ->
        # CLAUSE (vii): the verdict is `:new_cause` unconditionally. How much of
        # it a death explains is a NUMBER beside the verdict, never a promotion
        # to `:renamed` — an operator must not be told a brand-new cause is a
        # relabel because some unrelated class happened to die in the same window.
        explained = allocate(gained, gained_total, paired)

        %{
          class: class,
          kind: :birth,
          verdict: :new_cause,
          share_before: 0.0,
          share_after: round2(gained),
          moved_share: round2(gained),
          absorbed_share: round2(explained),
          unpaired_share: round2(gained - explained),
          counterparts: counterparts(deaths, lost_total, explained)
        }
      end)

    %{
      basis: @basis,
      min_sample: min_sample,
      attempts_before: attempts_before,
      attempts_after: attempts_after,
      refused: false,
      reason: nil,
      findings: Enum.sort_by(death_findings ++ birth_findings, & &1.moved_share, :desc),
      classes_read: classes_read
    }
  end

  # Each side's proportional cut of the paired pool. A death that lost half of
  # everything that died is credited with half of what was absorbed.
  defp allocate(_share, total, _paired) when total == 0, do: 0.0
  defp allocate(share, total, paired), do: share / total * paired

  # THE SUSPECTS, SCALED TO THIS FINDING'S OWN PAIRED AMOUNT — never to the
  # global pool. A birth explained by 35.06 points must not carry a counterpart
  # labelled 63.82: a counterpart share larger than the finding it sits on reads
  # as an arithmetic error and is one, at the level a human uses it.
  defp counterparts(entries, total, paired) do
    entries
    |> Enum.map(fn {class, share} ->
      %{class: class, share: round2(allocate(share, total, paired))}
    end)
    |> Enum.reject(&(&1.share == 0.0))
    |> Enum.sort_by(& &1.share, :desc)
    |> Enum.take(@suspects)
  end

  # CLAUSE (i). BOTH attempted cohorts, folded onto ONE denominator. The census's
  # own `share` node is NOT read: `classes[].share` is denominated on `failed`
  # and `deferred[].share` on `volume`, so reading them would put two different
  # rulers in one comparison — and `classes[].share` is additionally REFUSED
  # (pct: nil) across the vocabulary boundary, which is precisely the window this
  # gauge exists to read.
  defp shares(census, attempts) do
    (Map.fetch!(census, :classes) ++ Map.fetch!(census, :deferred))
    |> Enum.reduce(%{}, fn %{class: class, count: count}, acc ->
      Map.update(acc, class, count, &(&1 + count))
    end)
    |> Map.new(fn {class, count} -> {class, count * 100 / attempts} end)
  end

  defp share(shares, class), do: Map.get(shares, class, 0.0)

  defp round2(x), do: Float.round(x * 1.0, 2)
end
