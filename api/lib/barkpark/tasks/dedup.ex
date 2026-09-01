defmodule Barkpark.Tasks.Dedup do
  @moduledoc """
  Find-or-create gate for NEW task births (task-obsession layer 1).

  The DB adapter around the pure `Barkpark.Tasks.Similarity` decision: on a new
  `kind:task` document, fetch the candidate backlog (scoped), score it, and
  REFUSE the create if a near-duplicate survives structural exclusion — unless
  the author declared it distinct.

  ## Escape hatches ride existing content fields (no new API/CLI surface)

    * **`content.parent_id`** — a task filed under a parent is automatically
      sibling-excluded from its epic peers (structural exclusion in Similarity).
      This subsumes a `--sibling-of` flag: epic seeding just sets `parent_id`.
    * **`content.distinct_from`** — a list of ids the author has consciously
      declared distinct (D1). It is BOTH the escape hatch AND the persisted,
      queryable rejection trail (acceptance criterion 3): it lives in the doc's
      content, so a `bp task get` / query shows exactly which matches were waved
      through and by whose decision.

  A bogus `distinct_from` id cannot bypass a real duplicate: it only removes the
  named candidate from consideration, so any OTHER refusing candidate still
  blocks. That is the D1 "must name a real candidate" property, enforced by
  construction rather than by a separate check.

  ## When the gate cannot run: it SAYS SO (it does not silently pass)

  This used to fail OPEN and silently: any candidate-fetch error yielded an empty
  candidate set, so the create returned `200 OK` having never actually checked
  for a duplicate. That is the exact lie this epic exists to kill — a verb
  reporting success on a claim ("this task is not a duplicate") it never
  computed, on the ledger the epic is audited on.

  It now fails LOUD. A candidate fetch that errors or times out returns
  `{:error, {:dedup_unavailable, msg}}` (503) whose message names precisely what
  could not be done and how to proceed. The owner's escape hatch is
  **`content.dedup_bypass: true`** — file it unchecked, deliberately, and the
  flag persists on the document as the trail (same shape as `distinct_from`).

  Two honest caveats, both live:

    * The code is `dedup_unavailable` (503), NOT the plugin-veto `{:halted, …}`.
      That distinction is load-bearing, not cosmetic: `halted` means a policy
      DELIBERATELY refused, so consumers treat it as deterministic and stop —
      `Plugins.Github.Intake` answers a clean 2xx on it precisely because
      "GitHub redelivery would only hit the same veto forever". A dedup outage
      is TRANSIENT and must be retried, so borrowing `halted` for it would turn
      a DB hiccup into a permanently dropped GitHub issue.
    * The dedup query is bounded (`@query_timeout_ms`) so it fails fast and named
      instead of eating the request's 15 s DB-checkout budget and poisoning the
      INSERT that follows. That closes dedup's share of the window in which the
      `bp` CLI abandons a request at 30 s while the server keeps executing it
      (measured up to 61 s); the rest of the write path is still unbounded, which
      is tracked as `pds-bl-cli-budget-window`.

      **That budget was never the whole cost, and saying it was is what let this
      module starve the fleet for weeks.** `@query_timeout_ms` bounds `Repo.all/2`.
      It does not bound `Similarity.assess/3`, the pure-Elixir scoring loop that
      runs after the rows come back — and once the corpus reached the candidate
      cap that loop WAS the cost: ~6.2 s of CPU, on the request, under no budget,
      measured 2026-08-24. A gated `bp task create` took 9.2–14.3 s against
      production while the same create with `dedup_bypass` took 0.18–0.47 s. The
      remedy is not another timeout — a timeout there would only convert a slow
      create into a refused one. It is to stop handing the scorer thousands of
      rows: `fetch_candidates/2` now pre-filters candidates with a trgm net
      modelled on `Content.DedupWall`'s (at its own measured floor — the two
      corpora do not share one), and that function's comment states exactly what
      the net can miss.
  """
  import Ecto.Query, only: [from: 2]

  require Logger

  alias Barkpark.Content.{Document, Scope}
  alias Barkpark.Repo
  alias Barkpark.Tasks.{Judge, Similarity}

  # Bound the worst-case scan. MEASURED 2026-07-30 (`bp doc ls task --all -o json`
  # against guerrilla, `production`): 3,793 published `type:task` rows, ~4.1k
  # counting draft twins — NOT the "hundreds" this cap was calibrated against in
  # #1210. The limit is therefore live, not theoretical: the corpus is inside one
  # order of magnitude of it. An FTS/trigram pre-filter is still the real answer
  # (tier-2); until then the cost is held down by projecting the candidate row
  # (below) instead of hauling full content JSONB, and by tokenizing the new task
  # once (Similarity.probe/1).
  #
  # RE-MEASURED 2026-08-24 (`bp export --type task`, guerrilla `production`,
  # the scan's own WHERE: kind == "task" AND lifecycle_status != "cancelled"):
  # 7,754 exported rows (602 of them draft twins) -> 7,220 eligible ->
  # **7,064 distinct canonical ids**. The corpus is no longer "inside one order
  # of magnitude of" the cap — it has CROSSED it. 2,064 ids (29.2%) sit past the
  # LIMIT and were invisible to every dedup scan, on every create.
  #
  # And the invisible set is not a random 29.2%. `LIMIT` applies AFTER
  # `DISTINCT ON`, whose ordering key is the canonical doc_id ASCENDING, so the
  # scan sees the alphabetically-first 5,000 ids and nothing after. The 2026-08-24
  # cut falls inside the `scaffy-w4-*` family, which means **all 1,093 `task-*`
  # ids — the shape `bp task create` mints whenever the author supplies no slug —
  # were 100% unscanned**, along with every `spd-*`, `stw*`, `tgw*` and `ssw*` row.
  # An id-prefix convention adopted late in the alphabet is invisible by
  # construction, permanently and reproducibly.
  #
  # THE VALUE IS DELIBERATELY UNCHANGED. Raising it re-arms the same trap a few
  # thousand rows later, just as quietly; the defect was never the number, it was
  # that the number could bind without anyone finding out. What changed is that
  # the scan now DETECTS its own truncation (see `fetch_candidates/2`) and says
  # so — a warning naming rows-returned and the limit, a telemetry event, and a
  # `scan` note on any duplicate payload it does manage to produce.
  #
  # THE VALUE MOVES NOW, because the ORDERING under it finally changed. 5,000 was
  # untouchable while the keep was alphabetical: any cut of an id-sorted list
  # drops an arbitrary — and, as measured above, a systematically biased — slice,
  # so the only safe cap was one nothing reached. The trgm pre-filter below sorts
  # candidates by DESCENDING TITLE SIMILARITY before the cap applies, so the rows
  # this number discards are now the ones LEAST like the new task. That inverts
  # the trade: 500-most-similar is a strictly better candidate set than
  # 5,000-alphabetically-first, and it is the cap `Content.DedupWall` already
  # runs on this same table, so the two dedup surfaces keep one calibrated
  # vocabulary.
  #
  # It is also what makes the gate affordable. MEASURED 2026-08-24 with the real
  # `Similarity.assess/3` over the real exported corpus (6,329 eligible rows):
  # N=500 -> 89 ms, N=1000 -> 811 ms, N=2000 -> 1,966 ms, N=5000 -> 6,217 ms.
  # That loop runs AFTER `Repo.all/2` has returned, so `@query_timeout_ms` never
  # bounded a millisecond of it — see `fetch_candidates/2`.
  #
  # In practice this cap is now a SAFETY NET, not the working limit: at
  # `@candidate_trgm_floor` the net admits single-digit candidate counts on the
  # measured corpus, so 500 is reached only by something pathological — which is
  # exactly the state the truncation tripwire should be reporting.
  @candidate_limit 500

  # Trgm net for the candidate FETCH only: over-fetch here, then let the precise
  # token-Jaccard in `Similarity.assess/3` score it down.
  #
  # IT IS 0.2, NOT `Content.DedupWall`'s 0.1, AND THE DIVERGENCE IS MEASURED.
  # Copying the sibling wall's floor was the first thing tried and it does not
  # survive contact with this corpus — the two surfaces read different tables'
  # worth of text, so one number cannot serve both. Rows admitted out of the 6,329
  # real exported task rows (2026-08-24), three probe titles:
  #
  #     floor   short/typical   long/real   generic
  #     0.10          1,467       1,887        501
  #     0.20              8           9         11
  #     0.30              0           0          0
  #
  # At 0.1 the net admits 23–30% of the backlog. That is not a pre-filter; it
  # would hand the scorer ~1,500 rows, bind the 500 cap on EVERY create, and fire
  # the truncation warning forever — trading a slow gate for a noisy one. The
  # distribution is sharply bimodal, so 0.2 sits in the empty valley between the
  # signal and the noise rather than on a slope.
  #
  # And it keeps the signal. Probed with the exact title of an existing row, that
  # row ranks #1 at similarity 1.000 while the runner-up scores 0.322 and third
  # place 0.248 — a real near-duplicate is nowhere near this floor. The 0.30 row
  # reading zero is not a warning sign: these probes have no duplicate in the
  # corpus, and answering "no candidates" is the correct result for them.
  #
  # It is still BELOW pg_trgm's 0.3 default, so the fetch must run inside a
  # transaction that sets the threshold first (see `fetch_rows/6`).
  @candidate_trgm_floor 0.2

  # The truncation tripwire: ask for ONE row more than the cap. If that extra row
  # comes back, the eligible corpus has outgrown @candidate_limit and this scan is
  # PARTIAL. It costs a single row, needs no second `COUNT` query against a corpus
  # this size, and cannot be wrong — `length(rows) > limit` is the same fact the
  # database used to decide to stop.
  @candidate_probe 1

  # The dedup scan gets its OWN budget, well inside the request's 15 s DB
  # checkout. Without it the scan raced that budget and the FOLLOW-UP insert was
  # the statement that blew up — so the owner saw `internal_error / unknown
  # error` from a write that had actually been starved by the read.
  @query_timeout_ms 5_000

  @doc """
  `:ok`, `{:error, {:duplicate_task, payload}}` when a new task duplicates an
  existing one, or `{:error, {:dedup_unavailable, message}}` when the gate could not run at
  all (the message names what could not be done — it never passes silently).
  Only fires for `type == "task"` with **no `prev_doc`** (a genuine birth —
  updates/autosaves/publishes are never gated). All other shapes → `:ok`.
  """
  @spec check_new_task(String.t(), map(), String.t(), Document.t() | nil, keyword()) ::
          :ok | {:error, {:duplicate_task, map()}} | {:error, {:dedup_unavailable, String.t()}}
  def check_new_task("task", attrs, dataset, nil, opts) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}
    new_task = to_task(attrs, content)

    cond do
      # A task with no textual signal (no title/description) can't be judged —
      # let it through rather than compare empty strings.
      String.trim("#{new_task.title} #{new_task.description}") == "" ->
        :ok

      # The author has consciously chosen to file without the gate. Unlike the
      # old silent fail-open this is the OWNER's claim, not the server's, and it
      # persists on the document as the trail.
      bypass?(content) ->
        :ok

      true ->
        gate(new_task, content, dataset, opts)
    end
  end

  def check_new_task(_type, _attrs, _dataset, _prev_doc, _opts), do: :ok

  defp gate(new_task, content, dataset, opts) do
    distinct =
      string_list(Map.get(content, "distinct_from") || Map.get(content, :distinct_from))

    # The new task's title IS the trgm probe. Passed as an opt rather than a
    # positional argument so a caller that already set `:probe_title` (tests
    # driving the empty-probe fallback) keeps control of it.
    opts = Keyword.put_new(opts, :probe_title, String.trim("#{new_task.title}"))

    case fetch_candidates(dataset, opts) do
      {:degraded, reason} ->
        {:error, {:dedup_unavailable, degraded_message(reason)}}

      {:ok, candidates, scan} ->
        assessment =
          Similarity.assess(new_task, candidates, distinct_from: distinct)

        # Tier-2 (task-obsession layer 2): the gray-zone `advise` matches are the
        # ones tier-1 is unsure about. When a judge is configured, ask it; a
        # confident duplicate/already_landed verdict escalates the match to a hard
        # refuse. Everything fails open — no judge, or a judge error, leaves the
        # tier-1 verdict untouched.
        {escalated, remaining_advise} = judge_escalate(new_task, candidates, assessment.advise)
        refuse = assessment.refuse ++ escalated

        case refuse do
          [] ->
            :ok

          _ ->
            {:error,
             {:duplicate_task,
              %{
                message: refusal_message(refuse),
                similar: Enum.map(refuse, &present/1),
                advise: Enum.map(remaining_advise, &present/1),
                scan: scan
              }}}
        end
    end
  end

  # ── the refusal must name an id the caller can actually ACT on ─────────────
  #
  # `"claim/extend it"` is a promise about the matched row, and against a
  # DRAFT-ONLY match the gate could keep neither half of it. `present/1` reports
  # the canonical (drafts-stripped) id — correct, because that is the id
  # `distinct_from` takes — but a row that exists only as `drafts.<id>` is not a
  # task yet: `bp task get <id>` 404s, `bp task ready` never lists it, and there
  # is nothing to claim. The refusal named a resource that does not exist.
  #
  # THAT IS NOT A CORNER CASE, IT IS THE FLEET'S OWN FAILURE LOOP. `bp task
  # create` sends no `doc_id`, so the server mints a fresh `task-<hex>` per
  # attempt, and `Content.Writer` stores every new doc as `drafts.<id>` — its
  # own `create_document/4` doc says "New docs are always created as drafts".
  # Under load a create can die on a connection checkout AFTER that draft row
  # has landed — the caller sees `unknown error
  # (DBConnection.ConnectionError)` and the draft survives. The retry mints a
  # DIFFERENT id, so `prev_doc` is nil, this gate runs, and `base_query/3`
  # fetches the orphan: nothing excludes a `drafts.` row, and `DISTINCT ON`
  # keeps it precisely because it has no published twin. A byte-identical retry
  # scores token-Jaccard 1.0 — `0.7 · 1.0 + 0.3 · 0.0 = 0.7` with no labels,
  # over `@refuse 0.55` — so **the caller is locked out by its own debris**, by
  # an id it cannot see, with a remedy it cannot perform.
  #
  # THE FIX IS HONESTY, NOT LENIENCY. Dropping draft-only rows from the
  # candidate set would be the other obvious move and it is the wrong one: a
  # task that exists ONLY as a draft is still work someone filed, the moduledoc
  # promises it is still detected, and unfetching it would re-open a real
  # duplicate hole to paper over a reporting one. Detection is untouched here.
  # What changes is that the payload distinguishes the two kinds of match and
  # the message carries the recovery the draft case actually needs — publish it,
  # discard it, or `distinct_from` it. `published` is ADDITIVE on the wire, so
  # `internal/apierr`'s `Candidate` (which decodes id/similarity/relation/
  # lifecycle_status) keeps parsing byte-identically and the note rides out on
  # `message`, which the CLI already prints.
  defp refusal_message(refuse) do
    base =
      "this task looks like an existing one — claim/extend it, or pass " <>
        "distinct_from: [\"<id>\"] to confirm it is different"

    case Enum.reject(refuse, fn m -> published?(Map.get(m, :id)) end) do
      [] ->
        base

      drafts ->
        named =
          drafts
          |> Enum.map(fn m -> Similarity.norm_id(Map.get(m, :id)) end)
          |> Enum.take(5)
          |> Enum.join(", ")

        base <>
          " · NOTE: #{length(drafts)} of these match(es) exist only as an UNPUBLISHED DRAFT " <>
          "(#{named}) — `bp task get` will 404 on those ids and they are not on the ready " <>
          "queue, so there is nothing there to claim or extend. A create that failed AFTER " <>
          "writing its draft is the usual cause, and the retry then matches its own debris. " <>
          "Inspect with `bp doc ls task --perspective drafts`, then publish the draft " <>
          "(`bp doc publish task <id>`) or discard it and retry."
    end
  end

  # A stored row is published unless it carries the `drafts.` prefix. The
  # DISTINCT ON in `base_query/3` prefers the PUBLISHED row of a twin pair, so a
  # kept row still wearing the prefix is a draft with no published counterpart —
  # exactly the unactionable case.
  defp published?("drafts." <> _), do: false
  defp published?(id) when is_binary(id), do: true
  defp published?(_), do: false

  # The refusal SAYS WHAT IT COULD NOT DO, in the response body, and names the
  # one action that gets the owner unstuck. Never `unknown error`.
  defp degraded_message(reason) do
    "task dedup gate could not complete: #{reason}. The create was REFUSED rather " <>
      "than filed unchecked — no duplicate check ran, so nothing here claims this " <>
      "task is new. Retry, or resend with content.dedup_bypass: true to file it " <>
      "deliberately without the duplicate check."
  end

  defp bypass?(content) do
    case Map.get(content, "dedup_bypass") || Map.get(content, :dedup_bypass) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  # ── tier-2 judge escalation (fail-open) ────────────────────────────────────

  # A judged `duplicate`/`already_landed` needs at least this confidence to
  # escalate an advise match to a hard refuse.
  @judge_confidence 0.7

  # Returns {escalated, remaining_advise}. No judge configured → escalate
  # nothing (tier-1 stands). The advise band is top-K-bounded, so this is a
  # handful of calls at most, only on the gray-zone matches.
  defp judge_escalate(_new_task, _candidates, []), do: {[], []}

  defp judge_escalate(new_task, candidates, advise) do
    if Judge.configured?() do
      by_id = Map.new(candidates, fn c -> {Similarity.norm_id(Map.get(c, :id)), c} end)

      Enum.split_with(advise, fn match ->
        escalate?(new_task, Map.get(by_id, Similarity.norm_id(match.id)))
      end)
    else
      {[], advise}
    end
  end

  defp escalate?(_new_task, nil), do: false

  defp escalate?(new_task, candidate) do
    case Judge.judge(new_task, candidate) do
      {:ok, %{relation: rel, confidence: conf}}
      when rel in ["duplicate", "already_landed"] and conf >= @judge_confidence ->
        true

      # distinct / expands / low confidence / ANY error → fail open, don't escalate.
      _ ->
        false
    end
  end

  # ── candidate fetch ────────────────────────────────────────────────────────

  # `{:ok, candidates, scan_report}` or `{:degraded, reason}` — never a silently
  # EMPTY candidate set, and never a silently TRUNCATED one either.
  #
  # WHAT THIS QUERY CHANGED, said out loud (no silent narrowing):
  #
  #   * It projects the five scored fields instead of the whole `content` JSONB.
  #     A task row's content carries `brief`, `acceptance_criteria`,
  #     `disposition_reason` … none of which is scored; hauling them for 4.1k
  #     rows was most of the cost. Detection is UNCHANGED — Similarity only ever
  #     read title/description/labels/parent_id/lifecycle_status.
  #   * `DISTINCT ON` the canonical (drafts-stripped) id collapses a
  #     draft/published TWIN pair to one row, preferring the published one.
  #     Detection is UNCHANGED here too: both rows normalize to the same id and
  #     scored identically, so the twin only ever bought a duplicate entry in
  #     `similar` and a second scoring pass. A task that exists ONLY as a draft
  #     still has exactly one row and is still detected.
  #   * **NEW: a trgm pre-filter on the title, so the scorer sees hundreds of
  #     candidates instead of thousands.** This one DOES narrow, and the
  #     narrowing is stated below rather than left to be discovered.
  #
  # ## Why the pre-filter had to exist (the cost was never in the query)
  #
  # `@query_timeout_ms` bounds `Repo.all/2` and nothing else. The scoring loop
  # that consumes these rows — `Similarity.assess/3`, pure Elixir — runs AFTER
  # the query returns, on the request's own scheduler, under no budget at all.
  # Once the corpus reached the old 5,000-row cap that loop became the entire
  # cost of a task birth.
  #
  # MEASURED 2026-08-24 against guerrilla `production`, draft-only `bp task
  # create`, 5 runs each arm:
  #
  #     content.dedup_bypass: true   ->  0.18 – 0.47 s   (gate skipped)
  #     the same create, gated       ->  9.2  – 14.3 s
  #
  # ~98% of a task birth was this gate, and ~6.2 s of it was the scoring loop
  # (bench numbers at `@candidate_limit`). The failure mode that produced was
  # NOT this module's honest 503: the request burned ten seconds of CPU and then
  # still had to check out a SECOND connection for the INSERT, which under fleet
  # load is dropped from the pool queue. That `DBConnection.ConnectionError` is
  # raised OUTSIDE this function, so the `rescue`/`catch` below never see it and
  # the caller gets `internal_error / "unknown error (DBConnection.ConnectionError)"`
  # — precisely the lie the moduledoc above says this module exists to kill. A
  # gate cannot report honestly about a failure it causes downstream of itself.
  #
  # ## What the trgm net can now MISS, said plainly
  #
  # The `%` operator matches on the TITLE only, because `documents_title_trgm_idx`
  # (GIN, migration 20260526181000) is a title index — the same index and the
  # same operator `Content.DedupWall` runs on this table. But `Similarity` scores
  # title AND description as one combined token bag. So a candidate whose title
  # is trigram-dissimilar to the new title, yet whose DESCRIPTION overlaps enough
  # to have crossed 0.55, is no longer fetched and no longer refused.
  #
  # That is a real loss, and it is still the better trade, because it REPLACES a
  # worse one. The old scan did not see the whole corpus either: `LIMIT` applied
  # after a `DISTINCT ON` keyed on ascending canonical id, so it read the
  # alphabetically-first 5,000 and nothing after — 2,064 ids (29.2%) invisible,
  # including 100% of the `task-*` ids `bp task create` mints by default. The
  # rows dropped then were chosen by ALPHABET. The rows dropped now are chosen by
  # DISSIMILARITY, which is the one criterion actually correlated with not being
  # a duplicate — and every id in the corpus is now reachable, because the index
  # is consulted over all of it instead of a sorted prefix.
  #
  # An empty probe title cannot be allowed to silently match nothing (that would
  # be a fail-OPEN gate wearing a green light), so it falls back to the
  # unfiltered scan — see `fetch_rows/6`.
  defp fetch_candidates(dataset, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    timeout = Keyword.get(opts, :dedup_timeout_ms, @query_timeout_ms)
    limit = Keyword.get(opts, :dedup_candidate_limit, @candidate_limit)
    probe_title = Keyword.get(opts, :probe_title) || ""

    rows = fetch_rows(dataset, workspace_id, project_id, timeout, limit, probe_title)

    # The probe row is the ONLY thing that distinguishes "the backlog happens to
    # be exactly `limit` rows" from "the backlog is larger than this scan saw".
    # It is dropped before scoring either way, so detection over the rows we DID
    # fetch is byte-identical to before.
    {kept, truncated?} =
      if length(rows) > limit, do: {Enum.take(rows, limit), true}, else: {rows, false}

    report_scan(truncated?, length(kept), limit, dataset)

    {:ok, to_tasks(kept), scan_report(truncated?, length(kept), limit)}
  rescue
    e ->
      Logger.warning("Tasks.Dedup degraded: candidate fetch failed: #{inspect(e)}")
      {:degraded, reason_phrase(e, Keyword.get(opts, :dedup_timeout_ms, @query_timeout_ms))}
  catch
    :exit, reason ->
      Logger.warning("Tasks.Dedup degraded: candidate fetch exited: #{inspect(reason)}")
      {:degraded, "the backlog scan was cut off by the database"}
  end

  # ── the cap CANNOT bind silently ───────────────────────────────────────────
  #
  # Three channels, because a bound that engages with nobody watching is the
  # defect this module exists to kill:
  #
  #   1. a `Logger.warning` naming rows-returned, the limit and the CONSEQUENCE
  #      (an `:ok` from this scan means "no duplicate among the rows I saw", not
  #      "no duplicate"),
  #   2. a `:telemetry` event so the bind is COUNTABLE over time rather than
  #      rediscovered by an audit twenty-three days late, and
  #   3. a `scan` note carried on the duplicate payload itself, so the answer a
  #      caller receives states the population it was computed over.
  #
  # What this deliberately does NOT do is refuse the create. The corpus is
  # already past the cap, so refusing on truncation would brick every task birth
  # on the ledger — trading a silent wrong answer for a total outage. The
  # remaining honest gap is stated out loud rather than papered over: the
  # NO-duplicate branch answers a bare `:ok`, which has no room for the caveat,
  # and widening that return shape reaches both `Content.Writer` call sites.
  # That is filed, not hidden.
  # ── the two fetch shapes ───────────────────────────────────────────────────
  #
  # A BLANK PROBE TITLE FALLS BACK TO THE UNFILTERED SCAN. `similarity(x, '')` is
  # 0 for every row, so `? % ?` against an empty probe matches NOTHING — the scan
  # would return zero candidates, `Similarity.assess/3` would find no refusals,
  # and the create would sail through reporting a duplicate check it never
  # performed. That is the fail-open shape this module exists to refuse, so the
  # empty case keeps the old whole-corpus behaviour (slow, but honest) instead.
  # `check_new_task/5` already short-circuits when title AND description are both
  # blank; this covers the title-blank-description-present remainder.
  defp fetch_rows(dataset, workspace_id, project_id, timeout, limit, "") do
    base_query(dataset, workspace_id, project_id)
    |> limited(limit)
    |> Repo.all(timeout: timeout)
  end

  defp fetch_rows(dataset, workspace_id, project_id, timeout, limit, probe_title) do
    inner =
      dataset
      |> base_query(workspace_id, project_id)
      |> trgm_filtered(probe_title)

    # TWO STAGES, and they cannot collapse into one. `DISTINCT ON` requires its
    # expression to lead the `ORDER BY`, so a single query can be ordered by
    # canonical id (to collapse twins) or by similarity (to make the cap keep the
    # right rows) — never both. The subquery collapses twins over the whole
    # trgm-matched set; the outer query then ranks the survivors by similarity
    # and applies the cap. Ordering the cap is the entire reason the cap is now
    # safe to lower.
    query =
      from(c in Ecto.Query.subquery(inner),
        order_by: [desc: c.sim, asc: c.doc_id],
        limit: ^(limit + @candidate_probe)
      )

    # `SET LOCAL` is a no-op outside a transaction, and @candidate_trgm_floor
    # (0.2) sits below pg_trgm's 0.3 default — so without the txn the `%` net
    # would silently TIGHTEN to 0.3 and drop exactly the gray-zone near-duplicates
    # the advise band exists to catch. Same cliff, same remedy, as
    # Content.DedupWall. SET takes no bind params, so the floor is interpolated;
    # the module attribute stays the single source of truth.
    case Repo.transaction(
           fn ->
             Repo.query!(
               "SET LOCAL pg_trgm.similarity_threshold = #{@candidate_trgm_floor}",
               [],
               timeout: timeout
             )

             Repo.all(query, timeout: timeout)
           end,
           timeout: timeout
         ) do
      {:ok, rows} ->
        rows

      # A rolled-back txn is a DEGRADED scan, not an empty corpus. Raising here
      # routes it into the `rescue` in `fetch_candidates/2`, which is what turns
      # it into the named 503 — matching `{:ok, _}` alone would have shaped this
      # as a MatchError with a message naming the wrong failure.
      {:error, reason} ->
        raise "dedup candidate transaction rolled back: #{inspect(reason)}"
    end
  rescue
    # FRESH-INSTALL FALLBACK, and ONLY this error. `pg_trgm` is optional —
    # `Application.check_pg_trgm/0` warns rather than crashes when it is absent,
    # so a legitimate Barkpark can be running without the `%` operator or
    # `similarity()`. On such a box every statement here fails with SQLSTATE
    # 42883, and without this clause that would turn into `{:degraded, …}` and
    # REFUSE every single task create — a fresh install unable to file its first
    # task, caused by a performance fix.
    #
    # The fallback is narrow on purpose. It matches the missing-function code and
    # nothing else, so a timeout, a pool death or any other Postgres error still
    # degrades LOUD into the named 503. Widening this to a bare `rescue` would
    # rebuild the silent fail-open this module was written to kill: an unfiltered
    # retry after a REAL failure would answer "no duplicate" from an empty set.
    e in Postgrex.Error ->
      if trgm_unavailable?(e) do
        Logger.warning(
          "Tasks.Dedup: pg_trgm is unavailable, falling back to the UNFILTERED backlog " <>
            "scan. Detection is unaffected; the scan is slow and the candidate cap is " <>
            "alphabetical again. Run `CREATE EXTENSION IF NOT EXISTS pg_trgm;` to restore " <>
            "the pre-filter."
        )

        fetch_rows(dataset, workspace_id, project_id, timeout, limit, "")
      else
        reraise e, __STACKTRACE__
      end
  end

  defp trgm_unavailable?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in [:undefined_function, :undefined_object, :undefined_table]

  defp trgm_unavailable?(_), do: false

  defp base_query(dataset, workspace_id, project_id) do
    from(d in Document,
      as: :doc,
      where: d.type == "task",
      where: fragment("?->>'kind'", d.content) == "task",
      # Cancelled/abandoned work must never block a legitimate re-attempt
      # (acceptance criterion 4). Done tasks stay in — a match against a done
      # task is a real "already landed" signal.
      where: fragment("COALESCE(?->>'lifecycle_status', '')", d.content) != "cancelled",
      distinct: [asc: fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id)],
      # Second key: `false` sorts before `true`, so the PUBLISHED row of a twin
      # pair wins the DISTINCT ON.
      order_by: [asc: fragment("? LIKE 'drafts.%'", d.doc_id)],
      select: %{
        doc_id: d.doc_id,
        title: d.title,
        description: fragment("?->>'description'", d.content),
        labels: fragment("?->'labels'", d.content),
        parent: fragment("?->>'parent_id'", d.content),
        lifecycle: fragment("?->>'lifecycle_status'", d.content)
      }
    )
    |> maybe_filter_dataset(dataset)
    |> Scope.scope_to_workspace(workspace_id, project_id)
  end

  # `? % ?` (not `similarity(?, ?) > x`) is the form that CAN use the GIN
  # `documents_title_trgm_idx`; the `similarity()` form can only seq-scan. Said
  # honestly, though: at this table size the planner still picks a seq scan, and
  # measured on the real corpus the pre-filtered query is not cheaper than the
  # unfiltered one — both make one pass over the same rows. THE SQL IS NOT WHERE
  # THE WIN IS, and this comment used to imply otherwise.
  #
  # The win is that the scorer's input shrinks. `Similarity.assess/3` is linear in
  # the candidate count and unbounded by any timeout: 6,217 ms at 5,000 rows,
  # 89 ms at 500. Bounding what reaches it is the whole fix; the operator choice
  # only keeps the index reachable for when the corpus makes it worth planning.
  # The score is also SELECTed so the outer query can rank by it without
  # recomputing.
  defp trgm_filtered(query, probe_title) do
    from([doc: d] in query,
      where: fragment("? % ?", d.title, ^probe_title),
      select_merge: %{sim: fragment("similarity(?, ?)", d.title, ^probe_title)}
    )
  end

  defp limited(query, limit), do: from(d in query, limit: ^(limit + @candidate_probe))

  defp report_scan(false, _returned, _limit, _dataset), do: :ok

  defp report_scan(true, returned, limit, dataset) do
    Logger.warning(
      "Tasks.Dedup scan TRUNCATED: returned #{returned} of a larger candidate set at " <>
        "limit #{limit} (dataset=#{inspect(dataset)}). The duplicate check ran over a " <>
        "PARTIAL candidate set — an :ok from this scan means 'no duplicate among the " <>
        "#{returned} rows scanned', not 'no duplicate'. This now means something " <>
        "DIFFERENT and much rarer than it used to: the rows kept are the #{limit} MOST " <>
        "TITLE-SIMILAR, not the alphabetically-first, so a bind here says the new title " <>
        "trigram-matches more than #{limit} existing tasks — a generic title, or a " <>
        "corpus that has outgrown the floor. Tighten @candidate_trgm_floor before you " <>
        "raise the limit."
    )

    :telemetry.execute(
      [:barkpark, :tasks, :dedup, :scan_truncated],
      %{returned: returned, limit: limit},
      %{dataset: dataset}
    )
  end

  defp scan_report(truncated?, returned, limit) do
    %{truncated: truncated?, candidates_scanned: returned, candidate_limit: limit}
  end

  defp reason_phrase(%DBConnection.ConnectionError{}, timeout),
    do: "the backlog scan did not finish inside its #{timeout}ms budget"

  defp reason_phrase(%{__struct__: mod}, _timeout),
    do: "the backlog scan failed (#{inspect(mod)})"

  defp reason_phrase(_, _timeout), do: "the backlog scan failed"

  defp maybe_filter_dataset(query, nil), do: query

  defp maybe_filter_dataset(query, dataset) when is_binary(dataset) do
    from([doc: d] in query, where: d.dataset == ^dataset)
  end

  # ── shaping ────────────────────────────────────────────────────────────────

  defp to_task(attrs, content) do
    %{
      id: Map.get(attrs, "doc_id") || Map.get(attrs, :doc_id) || "",
      title: Map.get(attrs, "title") || Map.get(attrs, :title) || "",
      description: get(content, "description"),
      labels: string_list(get(content, "labels")),
      parent: get(content, "parent_id"),
      lifecycle: get(content, "lifecycle_status")
    }
  end

  # ── the scan is TOTAL over its input (a poisoned row cannot take the gate down)
  #
  # `labels` is the ONE projected field read as RAW JSONB (`->`). Every other one
  # uses `->>`, which Postgres guarantees is text-or-NULL. So this is the only
  # place a stored row can hand the scan a term with no `String.Chars`
  # implementation — a map, or a list containing one.
  #
  # MEASURED LIVE 2026-08-01 (PDS wave 33): exactly that raised
  # `Protocol.UndefinedError` inside `fetch_candidates/2`. Because the rescue
  # there is FUNCTION-wide, one malformed row degraded the gate for EVERY caller
  # — and the documented way out, `content.dedup_bypass: true`, switches
  # duplicate detection off fleet-wide. A single bad row was therefore able to
  # disable the ledger's dedup property for everyone.
  #
  # The fix is totality, NOT a rescue. Wrapping the crash would turn a loud
  # failure into a silent blind spot; instead every branch of `stringify/1`
  # terminates for any term Postgrex can decode out of JSONB (null, boolean,
  # number, string, list, map) and, via the catch-all, for anything else.
  #
  # TOTAL IS NOT SILENT. An unusable label keeps its slot as a stable encoding —
  # so the row keeps its label CARDINALITY and stays scorable instead of quietly
  # shedding signal — and the rows are NAMED in a warning, so the poison gets
  # fixed at source rather than becoming a permanent blind spot in the scan.
  defp to_tasks(rows) do
    {tasks, malformed} = Enum.map_reduce(rows, [], &row_to_task/2)
    report_malformed(Enum.reverse(malformed))
    tasks
  end

  # The projected row IS the scored shape — no JSONB decoding left to do beyond
  # the `labels` array. Accumulates the rows whose labels had to be coerced.
  defp row_to_task(row, malformed) do
    {labels, unusable} = stringify_list(row.labels)

    task = %{
      id: row.doc_id,
      title: row.title || "",
      description: row.description,
      labels: labels,
      parent: row.parent,
      lifecycle: row.lifecycle
    }

    case unusable do
      [] -> {task, malformed}
      _ -> {task, [{row.doc_id, unusable} | malformed]}
    end
  end

  # ONE line per SCAN, not one per row. The scan reads up to `@candidate_limit`
  # rows on every single create, so a per-row warning would turn one bad
  # migration into thousands of log lines per create — a flood in exactly the
  # scenario this fix exists for. The count is the alarm; the named ids are the
  # thread to pull.
  defp report_malformed([]), do: :ok

  defp report_malformed(rows) do
    named = Enum.take(rows, 5)

    Logger.warning(
      "Tasks.Dedup: #{length(rows)} backlog row(s) carry unusable content.labels " <>
        "value(s) — a label set is a list of strings, and these are not. The scan " <>
        "COMPLETED and scored them with encoded stand-ins; fix them at source. " <>
        "First #{length(named)}: " <>
        Enum.map_join(named, "; ", fn {doc_id, unusable} ->
          "#{doc_id} #{inspect(unusable, limit: 3, printable_limit: 120)}"
        end)
    )
  end

  defp present(%{id: id, sim: sim, structural: rel, lifecycle: lc}) do
    # Report the canonical id (strip the `drafts.` prefix) so the author sees the
    # id they'd reference — and the one they'd pass back in `distinct_from`.
    #
    # `published` is what that stripping used to destroy: after `norm_id/1` a
    # draft-only match and a live task are byte-identical in this payload, so
    # the caller could not tell that "claim/extend it" was impossible for this
    # row. See `refusal_message/1`.
    %{
      id: Similarity.norm_id(id),
      similarity: sim,
      relation: to_string(rel),
      lifecycle_status: lc,
      published: published?(id)
    }
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, safe_atom(key))
  defp get(_map, _key), do: nil

  defp safe_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> :__missing__
  end

  # Total. Shared by the candidate rows above AND by `to_task/2` /
  # `distinct_from` on the caller's own content — where the same `to_string/1`
  # ran OUTSIDE any rescue, so a caller sending object-shaped labels crashed the
  # write with an unhandled 500 rather than a named refusal.
  defp string_list(value) do
    {strings, _unusable} = stringify_list(value)
    strings
  end

  # `{strings, unusable_originals}` — never raises, whatever `value` holds.
  defp stringify_list(value) do
    {strings, unusable} =
      value
      |> wrap_list()
      |> Enum.map_reduce([], fn element, acc ->
        case stringify(element) do
          {:ok, string} -> {string, acc}
          {:coerced, string} -> {string, [element | acc]}
        end
      end)

    {strings, Enum.reverse(unusable)}
  end

  defp wrap_list(nil), do: []
  defp wrap_list(list) when is_list(list), do: list
  defp wrap_list(other), do: [other]

  # `nil` is an atom, so `to_string(nil) == ""` — the pre-existing behaviour for
  # a null label entry is preserved exactly.
  defp stringify(value) when is_binary(value), do: {:ok, value}

  defp stringify(value) when is_atom(value) or is_integer(value) or is_float(value),
    do: {:ok, to_string(value)}

  # Maps, nested lists, tuples, pids, anything: encoded rather than converted.
  # `Jason.encode/1` RETURNS an error tuple (it does not raise) for a term it
  # cannot encode, and `inspect/1` is total, so this clause cannot fail.
  #
  # ONE BEHAVIOUR CHANGE, NAMED RATHER THAN LEFT TO BE DISCOVERED: a nested list
  # that happened to be valid chardata (`["a"]`) used to flatten to `"a"` through
  # `String.Chars.List`; it now encodes to the string `["a"]`. That is deliberate
  # — a nested list is not a label — and it is unreachable in practice: a census
  # of all 7,508 published `type:task` rows on guerrilla (2026-08-22) found 1,690
  # carrying `labels`, every one of them a flat list of strings.
  defp stringify(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:coerced, json}
      _ -> {:coerced, inspect(value)}
    end
  end
end
