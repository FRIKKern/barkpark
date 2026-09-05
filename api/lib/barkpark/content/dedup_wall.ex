defmodule Barkpark.Content.DedupWall do
  @moduledoc """
  E4 near-duplicate gate at the publish wall (authoring-excellence).

  When a document is published, refuse it if it near-duplicates an
  ALREADY-PUBLISHED document, and advise (never block) on the gray zone. This is
  the fail-closed complement of the label-spine and tag-registry gates: excellent
  labeling is worthless if the corpus is full of duplicates.

  ## Reuses the Tasks.Similarity SHAPE, not its scoring

  The thresholds are copied verbatim from `Barkpark.Tasks.Similarity`
  (tasks/similarity.ex:33-34, :41) so the two dedup surfaces speak one calibrated
  vocabulary:

      sim >= @refuse (0.55)  AND shared >= @min_refuse_shared (3)  → refuse (409)
      @advise (0.30) .. @refuse                                    → advise (warn)
      sim <  @advise                                               → ignore

  But the task-specific machinery does NOT apply to published content:

    * No labels-Jaccard weighting — papers carry weighted `tags`, not the task
      `labels` array; a tag's *name* is the label signal.
    * No parent/sibling/chain structural exclusion — that models an epic
      decomposed into slices (87% of lexically-similar TASK pairs are benign
      structure). Published papers have no such structural relation, so every
      lexical near-match is a real duplication signal.

  So a document scores purely on **title + tag-name token overlap** (Jaccard over
  the combined token set), and the trgm `similarity()` idiom
  (search/documents_retriever.ex) fetches the candidate set cheaply.

  ## When the gate cannot run: it SAYS SO (it does not silently pass)

  This used to fail OPEN and silently — the publish-side twin of the bug
  `Barkpark.Tasks.Dedup` closed: any candidate-fetch error yielded an empty
  candidate set, so publish answered `200 OK` having never checked for a
  duplicate. Same lie, same ledger: a verb reporting success on a claim ("this
  document is not a near-duplicate") it never computed.

  It now fails LOUD, mirroring `Tasks.Dedup`:

    * the candidate fetch carries an explicit `@query_timeout_ms` budget on BOTH
      the transaction and the queries inside it, so it fails fast and named
      instead of inheriting Ecto's 15 s default and eating the request's whole
      DB-checkout budget;
    * `catch :exit` sits beside the `rescue` — under pool-checkout death the
      failure arrives as an exit, not an exception, and a rescue-only clause
      lets it escape as a 500;
    * a degraded fetch returns `{:error, {:dedup_unavailable, message}}` whose
      message names what could not be done and how to proceed.

  Escape hatches, both live: a document in the grandfather exemption ledger
  never reaches E4 at all (`AuthoringWall.dedup_gate/5`), and
  **`content.dedup_bypass: true`** publishes unchecked, deliberately, with the
  flag persisting on the document as the trail (same shape as `Tasks.Dedup`).

  Fail-CLOSED on the verdict is unchanged: only a definitively-computed refusal
  blocks.

  ## Same-id republish never trips

  The incumbent published id is excluded from the candidate set (both at the
  query and defensively in `assess/3`), so republishing a document never flags
  itself as its own duplicate.

  ## Declared supersession: `content.supersedes` exempts exactly ONE pair

  A superseding document (a correction that REPLACES a published row) is BY
  DEFINITION a near-duplicate of the row it replaces — that similarity is the
  point, not an accident. Before this exemption the gate structurally blocked
  corrections: both escapes it offered ("extend it" / "differentiate the
  title/tags") meant either merging contradictory instructions or falsifying
  the gated artifact's identity (measured on a live p0 security packet,
  task-ccc1e5573598b91b).

  So a document carrying **`content.supersedes: "<doc_id>"`** is never scored
  against THAT ONE published document — the declared predecessor is excluded
  from the candidate set exactly like the doc's own published id. Every OTHER
  published row still refuses at full strength: a supersession claim against X
  buys no pass against Y. `Content.Lifecycle` stamps the predecessor with
  `superseded_by` after the successor publishes, so the pointer is visible
  from the row being replaced.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Barkpark.Content.{Document, DraftId, Scope}
  alias Barkpark.Repo

  # ── Tunable thresholds (copied from Tasks.Similarity — one calibrated scale) ─
  #
  # @refuse is deliberately high — on a clean corpus nothing reaches it, so the
  # wall hard-refuses only a true near-duplicate. The gray band is advisory.
  @refuse 0.55
  @advise 0.30

  # A hard REFUSE additionally requires this many shared title+tag tokens.
  # Jaccard over ultra-thin text over-fires: two docs titled "API a" / "API b"
  # share the single token "api" and score 1.0, which is not duplication. A real
  # duplicate shares many words. Below this floor a high score drops to ADVISE.
  @min_refuse_shared 3

  # Coarse trgm pre-filter for the candidate FETCH only (documents_retriever.ex
  # `similarity()` idiom). A cheap net over the title; the precise token-Jaccard
  # below is the real decision. Low on purpose — over-fetch, then score down.
  @candidate_trgm_floor 0.1
  @candidate_limit 500

  # The candidate scan's own budget, on the transaction AND every query inside
  # it. Without it the fetch inherits Ecto's 15 s default — the exact window the
  # pool-saturation incident blew, with the publish INSERT still to pay for.
  @query_timeout_ms 5_000

  # Compact function-word set — a subset of Tasks.Similarity's stopwords, enough
  # for title + tag-name text. Tokens of length <= 2 are also dropped.
  @stopwords MapSet.new(~w(a an the of to for and or in on at by with from is are be this that
                  these those it its as into per via not no yes we our you your they their
                  can will should must add fix use make build run new when then than also
                  each any all one two both only same onto over under out off up down how))

  @type ref :: %{
          optional(:supersedes) => String.t() | nil,
          id: String.t(),
          title: String.t(),
          tags: [String.t()]
        }
  @type match :: %{
          id: String.t(),
          sim: float(),
          shared: non_neg_integer(),
          verdict: :refuse | :advise
        }

  @doc "Default thresholds, exposed so callers/tests share one source of truth."
  @spec thresholds() :: %{refuse: float(), advise: float(), min_refuse_shared: non_neg_integer()}
  def thresholds, do: %{refuse: @refuse, advise: @advise, min_refuse_shared: @min_refuse_shared}

  @doc """
  The blocking guard mounted in `Content.Lifecycle.publish_document/4`. Refuses a
  near-duplicate publish; advise-band matches pass (they surface as warnings via
  `check/4`, not by blocking).

  Returns `:ok`, `{:error, {:duplicate_of, payload}}` (→ 409 via `Errors`), or
  `{:error, {:dedup_unavailable, message}}` when the gate could not run.
  """
  @spec guard(map(), String.t(), String.t(), keyword()) ::
          :ok | {:error, {:duplicate_of, map()}} | {:error, {:dedup_unavailable, String.t()}}
  def guard(doc, type, dataset, opts \\ []) do
    case check(doc, type, dataset, opts) do
      {:error, _} = err -> err
      # :ok OR {:ok, warnings} — the advise band never blocks a publish.
      _ -> :ok
    end
  end

  @doc """
  Full publish-dedup decision against the live published corpus.

    * `:ok` — no near-duplicate.
    * `{:ok, warnings}` — gray-zone match(es); `warnings` is a
      `[{code, severity, message}]`-shaped list for the mutate success channel.
    * `{:error, {:duplicate_of, payload}}` — a hard duplicate; `payload` carries
      the incumbent published id (`:duplicate_of`) plus the full `:similar` list.
    * `{:error, {:dedup_unavailable, message}}` — the candidate scan could not
      run (timeout / pool death); the publish is REFUSED rather than passed
      unchecked. `content.dedup_bypass: true` is the deliberate escape.

  Fail-loud: a candidate-fetch error is never silently an empty candidate set.
  """
  @spec check(map(), String.t(), String.t(), keyword()) ::
          :ok
          | {:ok, [map()]}
          | {:error, {:duplicate_of, map()}}
          | {:error, {:dedup_unavailable, String.t()}}
  def check(doc, type, dataset, opts \\ []) do
    ref = to_ref(doc)

    cond do
      # A document with no textual signal (empty title AND no tags) can't be
      # judged — let it through rather than compare empty token sets.
      MapSet.size(doc_tokens(ref)) == 0 ->
        :ok

      # The owner's escape hatch, same shape as Tasks.Dedup: publish unchecked,
      # deliberately, with the flag persisting on the document as the trail.
      bypass?(doc) ->
        :ok

      true ->
        gate(ref, type, dataset, opts)
    end
  end

  defp gate(ref, type, dataset, opts) do
    case fetch_candidates(ref, type, dataset, opts) do
      {:degraded, reason} ->
        {:error, {:dedup_unavailable, degraded_message(reason)}}

      {:ok, candidates} ->
        verdict(ref, candidates, opts)
    end
  end

  defp verdict(ref, candidates, opts) do
    assessment = assess(ref, candidates, opts)

    cond do
      assessment.refuse != [] ->
        incumbent = hd(assessment.refuse)
        incumbent_pid = DraftId.published_id(incumbent.id)

        {:error,
         {:duplicate_of,
          %{
            message: refusal_message(incumbent_pid, supersedes_of(ref)),
            duplicate_of: incumbent_pid,
            similar: Enum.map(assessment.refuse, &present/1),
            advise: Enum.map(assessment.advise, &present/1)
          }}}

      assessment.advise != [] ->
        {:ok, Enum.map(assessment.advise, &warning/1)}

      true ->
        :ok
    end
  end

  # The escape hatch reads the doc AS SUBMITTED (a Document struct or an attrs
  # map), so it works on both the publish and the birth path.
  defp bypass?(%Document{content: content}), do: truthy_bypass?(content)

  defp bypass?(%{} = doc) do
    case field(doc, :content) do
      %{} = content -> truthy_bypass?(content)
      _ -> truthy_bypass?(doc)
    end
  end

  defp bypass?(_), do: false

  defp truthy_bypass?(%{} = content) do
    case Map.get(content, "dedup_bypass") || Map.get(content, :dedup_bypass) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp truthy_bypass?(_), do: false

  # The refusal must never recommend falsifying the gated artifact ("edit the
  # title/tags until the guard stops seeing it"). The two honest escapes are:
  # extend the incumbent, or declare the supersession first-class. When a
  # supersedes link IS declared but names a different document than the one
  # refusing, say so — the exemption is pairwise on purpose.
  defp refusal_message(incumbent_pid, declared_supersedes) do
    base =
      "this document near-duplicates the already-published #{incumbent_pid} — " <>
        "extend that document instead, or, if this one REPLACES it, declare " <>
        "content.supersedes: \"#{incumbent_pid}\" and republish (the wall exempts " <>
        "exactly the declared pair; any other near-duplicate still refuses)"

    case declared_supersedes do
      nil ->
        base

      ^incumbent_pid ->
        base

      other ->
        base <>
          " — note: this document declares supersedes: \"#{other}\", but the " <>
          "refusal is against #{incumbent_pid}, a different document"
    end
  end

  defp degraded_message(reason) do
    "publish dedup wall could not complete: #{reason}. The publish was REFUSED " <>
      "rather than passed unchecked — no duplicate check ran, so nothing here " <>
      "claims this document is new. Retry, or resend with content.dedup_bypass: " <>
      "true to publish it deliberately without the duplicate check."
  end

  @doc """
  PURE assessment of a normalized doc `%{id, title, tags}` against normalized
  candidates. Returns `%{refuse: [match], advise: [match]}`, each sorted by
  descending similarity. `opts` accepts `:refuse` / `:advise` threshold overrides.
  """
  @spec assess(ref(), [ref()], keyword()) :: %{refuse: [match()], advise: [match()]}
  def assess(doc, candidates, opts \\ []) do
    refuse_at = Keyword.get(opts, :refuse, @refuse)
    advise_at = Keyword.get(opts, :advise, @advise)

    new_tokens = doc_tokens(doc)
    new_pid = DraftId.published_id(field_str(doc, :id))
    superseded_pid = supersedes_of(doc)

    matches =
      candidates
      # Two pairwise exclusions, same mechanism: a doc never duplicates ITSELF
      # (same-id republish), and never duplicates the ONE document it DECLARES
      # it supersedes (content.supersedes) — that similarity is the point of a
      # correction. Everything else is scored at full strength.
      |> Enum.reject(fn c ->
        cand_pid = DraftId.published_id(field_str(c, :id))
        cand_pid == new_pid or (superseded_pid != nil and cand_pid == superseded_pid)
      end)
      |> Enum.map(fn c -> score(new_tokens, c, refuse_at, advise_at) end)
      |> Enum.reject(&is_nil/1)

    grouped = Enum.group_by(matches, & &1.verdict)

    %{
      refuse: sort(Map.get(grouped, :refuse, [])),
      advise: sort(Map.get(grouped, :advise, []))
    }
  end

  # ── scoring ─────────────────────────────────────────────────────────────────

  defp score(new_tokens, cand, refuse_at, advise_at) do
    ct = doc_tokens(cand)
    shared = MapSet.size(MapSet.intersection(new_tokens, ct))
    sim = jaccard(new_tokens, ct)

    cond do
      sim >= refuse_at and shared >= @min_refuse_shared ->
        match(cand, sim, shared, :refuse)

      sim >= advise_at ->
        match(cand, sim, shared, :advise)

      true ->
        nil
    end
  end

  defp match(cand, sim, shared, verdict) do
    %{id: field_str(cand, :id), sim: Float.round(sim, 4), shared: shared, verdict: verdict}
  end

  defp sort(list), do: Enum.sort_by(list, & &1.sim, :desc)

  # A document's token bag = title tokens ∪ tag-name tokens.
  defp doc_tokens(ref) do
    title = field_str(ref, :title)
    tag_text = ref |> tags_of() |> Enum.join(" ")
    tokens("#{title} #{tag_text}")
  end

  @doc false
  def tokens(text) do
    (text || "")
    |> String.downcase()
    |> then(&Regex.scan(~r/[a-z0-9]+/, &1))
    |> List.flatten()
    |> Enum.reject(fn t -> String.length(t) <= 2 or MapSet.member?(@stopwords, t) end)
    |> MapSet.new()
  end

  @doc false
  def jaccard(a, b) do
    if MapSet.size(a) == 0 or MapSet.size(b) == 0 do
      0.0
    else
      inter = MapSet.size(MapSet.intersection(a, b))
      union = MapSet.size(MapSet.union(a, b))
      inter / union
    end
  end

  # ── candidate fetch (bounded, fail-LOUD) ─────────────────────────────────────

  # `{:ok, candidates}` or `{:degraded, reason}` — NEVER a silently-empty list.
  #
  # The select projects ONLY the tag array out of `content` instead of hauling
  # the whole JSONB for up to @candidate_limit rows. Detection is UNCHANGED:
  # scoring reads title + tag NAMES and nothing else, so the rest of the blob
  # (body, blocks, acceptance criteria …) was pure transfer cost. The trgm
  # predicate and its ordering are untouched — both run on the `title` COLUMN,
  # not on the projection, so the GIN index is still the one doing the work.
  defp fetch_candidates(ref, type, dataset, opts) do
    title = field_str(ref, :title)
    timeout = Keyword.get(opts, :dedup_timeout_ms, @query_timeout_ms)
    incumbent = DraftId.published_id(field_str(ref, :id))

    if timeout <= 0 do
      # A NON-POSITIVE BUDGET IS A DECISION, NOT A RACE. Handed straight to
      # `Repo.transaction(timeout: 0)` this is a coin-flip: DBConnection raises
      # only if the checkout actually queues, so a warm pool returns `{:ok,
      # rows}` and the scan reports a clean corpus it was never given time to
      # read. That is the exact failure this module exists to stop — a wall
      # that answers "no duplicates" when it means "I could not look".
      #
      # Zero milliseconds of budget can only ever mean the scan did not happen,
      # so say so before touching the pool. This also makes the two fail-LOUD
      # legs deterministic: they drive `dedup_timeout_ms: 0` and were passing
      # or failing on connection-checkout scheduling.
      Logger.warning("Content.DedupWall degraded: non-positive scan budget (#{timeout}ms)")
      {:degraded, "the duplicate scan was given no time to run (#{timeout}ms budget)"}
    else
      do_fetch_candidates(type, dataset, title, timeout, incumbent, opts)
    end
  end

  defp do_fetch_candidates(type, dataset, title, timeout, incumbent, opts) do
    query =
      from(d in Document,
        as: :doc,
        where: d.type == ^type,
        where: d.status == "published",
        # Same-id republish never trips — the incumbent can't duplicate itself.
        where: d.doc_id != ^incumbent,
        # Coarse trgm net over the title. The `%` operator engages the GIN
        # `documents_title_trgm_idx` (unlike `similarity() > x`, which can only
        # seq-scan) — the precise token-Jaccard in `assess/3` scores below.
        where: fragment("? % ?", d.title, ^title),
        # Deterministic keep: the top-500-BY-SIMILARITY survive the @candidate_limit
        # cap, so a plan change can never reorder which 500 pass to the scorer. `%`
        # is `>=` (a safe superset of the old strict `>`) — re-scored downstream.
        order_by: [desc: fragment("similarity(?, ?)", d.title, ^title)],
        select: %{doc_id: d.doc_id, title: d.title, tags: fragment("?->'tags'", d.content)},
        limit: @candidate_limit
      )
      |> maybe_filter_dataset(dataset)
      # TENANCY: scope the near-dup scan to the actor's workspace/project. The
      # `dataset` STRING is NOT globally unique — documents uniqueness is
      # [:doc_id, :type, :dataset_id] (migration 20260527134000), so two
      # workspaces can share one dataset string. Filtering by the raw string
      # alone let workspace-A's publish 409 against workspace-B's near-dup
      # title, leaking B's title + published_id in the {:duplicate_of, _}
      # payload. Byte-mirrors the already-scoped sibling reads
      # (plugins/github/relations.ex, query_controller.ex, tasks/query.ex): a
      # real workspace_id scopes fail-closed to its own rows; a nil one
      # (flat/Default legacy-global publish) leaves the scan pooled, so
      # Default publishes keep comparing across the shared corpus.
      # global-read: the dedup wall deliberately reads workspace-OR-global — global/nil-workspace docs are the shared Default back-compat corpus (proven benign-shared by the content-plane object-authz wave, governed by the pdf-bl-anon ruling), so a scoped publish dedups against its own rows PLUS the shared surface and a flat/Default publish dedups against that shared corpus; a fail-closed scope_to_workspace/3 would silently stop matching the shared global duplicates. This closes the cross-tenant leak (workspace-A no longer sees workspace-B's PRIVATE rows) while keeping the intended shared-corpus comparison.
      |> Scope.scope_to_workspace_or_global(
        Keyword.get(opts, :workspace_id),
        Keyword.get(opts, :project_id)
      )

    # CLIFF A: `SET LOCAL` only takes effect INSIDE a transaction — outside one it
    # is a silent no-op, leaving pg_trgm.similarity_threshold at its 0.3 default,
    # which would tighten `%` and drop every 0.1–0.3 gray-zone near-duplicate. So
    # wrap the fetch in an explicit txn and set the threshold FIRST. The literal is
    # interpolated because SET takes no bind params; @candidate_trgm_floor stays the
    # single source of truth.
    result =
      Repo.transaction(
        fn ->
          Repo.query!(
            "SET LOCAL pg_trgm.similarity_threshold = #{@candidate_trgm_floor}",
            [],
            timeout: timeout
          )

          Repo.all(query, timeout: timeout)
        end,
        timeout: timeout
      )

    case result do
      {:ok, rows} ->
        {:ok, Enum.map(rows, &row_to_ref/1)}

      # A rolled-back txn is a degraded scan, not an empty corpus. Matching
      # `{:ok, _}` alone would have shaped this as a MatchError — the right
      # verdict by accident, with a message that names the wrong failure.
      {:error, reason} ->
        Logger.warning(
          "Content.DedupWall degraded: candidate txn rolled back: #{inspect(reason)}"
        )

        {:degraded, rollback_phrase(reason, timeout)}
    end
  rescue
    # CLIFF B, now fail-LOUD: this wraps the WHOLE Repo.transaction — a
    # DBConnection error is reported, never disguised as "no duplicates found".
    #
    # CLIFF C — a DEFECT is not an OUTAGE. This one rescue answers two unrelated
    # failures, and it used to answer them identically: a database outage and a
    # bug in this very module both became `{:degraded, …}`. Right for the
    # outage, wrong for the bug — see @code_error_modules for the FunctionClauseError
    # that hid here, green, for months.
    e ->
      if code_error?(e) and raise_on_code_errors?() do
        reraise e, __STACKTRACE__
      end

      Logger.warning("Content.DedupWall degraded: candidate fetch failed: #{inspect(e)}")
      {:degraded, reason_phrase(e, Keyword.get(opts, :dedup_timeout_ms, @query_timeout_ms))}
  catch
    # Pool-checkout death arrives as an EXIT, not an exception — a rescue-only
    # clause lets it through as a 500. This is the clause Tasks.Dedup needed.
    :exit, reason ->
      Logger.warning("Content.DedupWall degraded: candidate fetch exited: #{inspect(reason)}")
      {:degraded, "the duplicate scan was cut off by the database"}
  end

  # A rollback carries a caller-shaped reason (often a bare atom), so it gets its
  # own phrasing — "failed" alone would say less than the transaction knows.
  defp rollback_phrase(%{__struct__: _} = reason, timeout), do: reason_phrase(reason, timeout)

  defp rollback_phrase(_reason, timeout),
    do: "the duplicate scan was rolled back inside its #{timeout}ms budget"

  defp reason_phrase(%DBConnection.ConnectionError{}, timeout),
    do: "the duplicate scan did not finish inside its #{timeout}ms budget"

  defp reason_phrase(%{__struct__: mod}, _timeout),
    do: "the duplicate scan failed (#{inspect(mod)})"

  defp reason_phrase(_, _timeout), do: "the duplicate scan failed"

  defp maybe_filter_dataset(query, nil), do: query

  defp maybe_filter_dataset(query, dataset) when is_binary(dataset) do
    from([doc: d] in query, where: d.dataset == ^dataset)
  end

  # NAME the bad input. `dataset` is `String.t() | nil` on every public entry
  # (`check/4`, `guard/4`, and `AuthoringWall.validate_all/5` above them), so
  # anything else is a caller contract violation — but the bare
  # FunctionClauseError this used to raise logged as
  # `%FunctionClauseError{function: :maybe_filter_dataset, args: nil}`: Elixir
  # redacts the arguments, so the log named the function that broke and never
  # the value that broke it. That is the difference between "the dedup wall
  # degraded again" and a one-line fix.
  defp maybe_filter_dataset(_query, dataset) do
    raise ArgumentError,
          "Content.DedupWall: dataset must be a String or nil, got: #{inspect(dataset)}"
  end

  # ── code defect vs infra outage (the candidate-fetch tripwire) ───────────────
  #
  # An exception whose module names a CODE defect is re-raised where a human is
  # watching; an infra failure (DBConnection / Postgrex / the `catch :exit`)
  # stays `{:degraded, …}`. The split exists because it was measured, not
  # imagined: `maybe_filter_dataset/2` raised FunctionClauseError on TWO tests in
  # `dedup_wall_test.exs`, on every run, for months — and the suite was 25 tests,
  # 0 failures, because the rescue laundered the module's own contract violation
  # into "the duplicate scan failed", the same sentence a Postgres outage
  # produces. Nothing user-visible broke (degraded is fail-CLOSED — the publish
  # is refused, never waved through), which is exactly why nobody looked: the
  # wall was refusing publishes on that path while the log blamed the database.
  #
  # PROD BEHAVIOUR IS UNCHANGED, deliberately. Raising in prod would turn a
  # fail-closed refusal into a 500 and lose the actionable message the caller
  # gets today, so `raise_on_code_errors?` defaults OFF and `config/test.exs`
  # turns it ON. The tripwire's job is to stop a defect from SHIPPING, not to
  # change what a shipped defect does.
  @code_error_modules [
    ArgumentError,
    ArithmeticError,
    BadArityError,
    BadBooleanError,
    BadFunctionError,
    BadMapError,
    BadStructError,
    CaseClauseError,
    CondClauseError,
    FunctionClauseError,
    KeyError,
    MatchError,
    Protocol.UndefinedError,
    TryClauseError,
    UndefinedFunctionError,
    WithClauseError
  ]

  defp code_error?(%{__struct__: mod}), do: mod in @code_error_modules
  defp code_error?(_), do: false

  defp raise_on_code_errors?,
    do: Application.get_env(:barkpark, :dedup_raise_on_code_errors, false)

  # ── shaping ──────────────────────────────────────────────────────────────────

  # Normalize the doc-being-published (a Document struct or a plain attrs/ref
  # map) into `%{id, title, tags(list of strings), supersedes}`.
  defp to_ref(%Document{doc_id: id, title: title, content: content}) do
    %{
      id: to_string(id || ""),
      title: to_string(title || ""),
      tags: tags_from_content(content),
      supersedes: supersedes_from_content(content)
    }
  end

  defp to_ref(%{} = m) do
    content = field(m, :content)

    tags =
      cond do
        is_map(content) -> tags_from_content(content)
        true -> field(m, :tags)
      end

    %{
      id: field_str(m, :id) |> fallback(field_str(m, :doc_id)),
      title: field_str(m, :title),
      tags: tag_names(tags),
      supersedes: supersedes_from_content(content) || normalize_supersedes(field(m, :supersedes))
    }
  end

  # The declared-supersession pointer, read from the doc AS SUBMITTED (content
  # map, or top-level on an already-normalized ref), `drafts.`-stripped so it
  # keys the same published-id space as the candidate exclusion.
  defp supersedes_of(ref), do: normalize_supersedes(field(ref, :supersedes))

  defp supersedes_from_content(content) when is_map(content),
    do: normalize_supersedes(Map.get(content, "supersedes") || Map.get(content, :supersedes))

  defp supersedes_from_content(_), do: nil

  defp normalize_supersedes(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      id -> DraftId.published_id(id)
    end
  end

  defp normalize_supersedes(_), do: nil

  # The projected row IS the scored shape — the only JSONB left is the `tags`
  # array the select pulled out.
  defp row_to_ref(%{doc_id: id, title: title, tags: tags}) do
    %{id: to_string(id || ""), title: to_string(title || ""), tags: tag_names(tags)}
  end

  defp tags_from_content(content) when is_map(content),
    do: tag_names(Map.get(content, "tags") || Map.get(content, :tags))

  defp tags_from_content(_), do: []

  # A normalized ref's tags are already a list of strings; be tolerant.
  defp tags_of(ref), do: tag_names(field(ref, :tags))

  # Accept the weighted-tag shape (`[%{"tag" => name, ...}]`) OR a plain list of
  # tag-name strings, and yield the tag NAMES.
  defp tag_names(nil), do: []

  defp tag_names(tags) when is_list(tags) do
    tags
    |> Enum.map(fn
      %{} = t -> to_string(Map.get(t, "tag") || Map.get(t, :tag) || "")
      t when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp tag_names(_), do: []

  defp present(%{id: id, sim: sim, shared: shared}) do
    %{id: DraftId.published_id(id), similarity: sim, shared_tokens: shared}
  end

  # Advise-band → a warning for the mutate success channel (D5 shape).
  defp warning(%{id: id, sim: sim}) do
    pid = DraftId.published_id(id)

    %{
      code: "possible_duplicate",
      severity: "warning",
      message: "this document may duplicate the already-published #{pid} (similarity #{sim})"
    }
  end

  # ── field access ─────────────────────────────────────────────────────────────

  defp field(m, key) when is_map(m), do: Map.get(m, key) || Map.get(m, to_string(key))
  defp field(_, _), do: nil

  defp field_str(m, key), do: to_string(field(m, key) || "")

  defp fallback("", other), do: other
  defp fallback(value, _other), do: value
end
