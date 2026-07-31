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
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Barkpark.Content.{Document, DraftId}
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

  @type ref :: %{id: String.t(), title: String.t(), tags: [String.t()]}
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

        {:error,
         {:duplicate_of,
          %{
            message:
              "this document near-duplicates an already-published one — extend it, " <>
                "or differentiate this one's title/tags before publishing",
            duplicate_of: DraftId.published_id(incumbent.id),
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

    matches =
      candidates
      |> Enum.reject(fn c -> DraftId.published_id(field_str(c, :id)) == new_pid end)
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
    e ->
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

  # ── shaping ──────────────────────────────────────────────────────────────────

  # Normalize the doc-being-published (a Document struct or a plain attrs/ref
  # map) into `%{id, title, tags(list of strings)}`.
  defp to_ref(%Document{doc_id: id, title: title, content: content}) do
    %{id: to_string(id || ""), title: to_string(title || ""), tags: tags_from_content(content)}
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
      tags: tag_names(tags)
    }
  end

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
