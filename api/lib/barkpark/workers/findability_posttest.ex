defmodule Barkpark.Workers.FindabilityPosttest do
  @moduledoc """
  E5 post-publish findability self-test (authoring-excellence charter D9 + D29).

  After a **walled-type** document (`paper` / `task`) publishes, this worker
  runs a golden self-query against the REAL search pipeline and asserts the
  freshly published document ranks itself into the top-N results
  (`expect_ids == [self]`). A self-miss is a *findability finding*: the document
  is published but its own labels/title do not retrieve it — the north-star
  inverse ("a document is well-labeled iff search finds it"). A miss emits a
  `Logger.warning` + a `[:barkpark, :authoring, :findability_miss]` telemetry
  event carrying rank diagnostics.

  ## NEVER blocking — by construction

  This is a *post*-publish observability probe, never a gate. The charter is
  explicit (D9): pre-commit the document is invisible to
  `perspective_filter(:published)`, so hand-unioning the candidate into the
  pipeline would test a fake pipeline. Instead the check runs **after** the
  publish transaction has committed and the response has been sent:

    * It is enqueued from the `WriteScope.fire_after` seam
      (`write_scope.ex`, the exact `EdgeProjector.Lifecycle.enqueue_rebuild`
      precedent) — NEVER inline in the hook chain (that would add search
      latency to every publish) and NEVER via the `Warnings` channel (that is
      process-dict, request-scoped; the response is sent before any job runs,
      so an async result is structurally undeliverable there).
    * `enqueue_after/1` can never crash the publish path: it is fully rescued
      and always returns `:ok`. The publish outcome and latency are unaffected
      by both the enqueue and the async run — a raising `perform/1` is isolated
      by Oban and never touches the publish.

  ## Queue + attempts

  Runs on the existing shared `:default` Oban queue (the same queue the webhook
  stuck-delivery sweeper and other core best-effort jobs use — no dedicated
  queue is warranted for an advisory probe). `max_attempts: 1`: a findability
  miss is a fact about the current published corpus, not a transient failure —
  re-running the identical search would return the identical ranking, so a
  retry could never change the outcome and would only waste queue capacity.
  A single attempt also means an unexpected exception is discarded (logged by
  Oban), never retry-stormed.

  ## The self-query

  Scoring reuses `Barkpark.Search.GoldenEval`'s shape (`missing = expect_ids --
  ranked`) through `Content.search_documents/3` with `perspective: :published`
  — the SAME facade GoldenEval proves, one call above
  `QueryPipeline.search/4`. Papers default to `visibility: public`, so the
  query runs anonymously (no `caller_context` construction), exactly like
  GoldenEval.

  ### Query seed derivation

  The seed is built at enqueue time (`build_seed/1`) from the published
  document's own labels + title, so the probe asks the question a searcher
  would: *"given what this doc says it is about, does search return it?"*

    1. its denormalized `content["main_tag"]` (the unique-max weighted tag,
       stamped at the publish chokepoint — charter D7), if present; then
    2. the first 6 whitespace tokens of its `title` (`@title_token_count`).

  Deduped, blank/nil-dropped, space-joined. A document that carries neither a
  main_tag nor a title yields an empty seed — the worker no-ops (`:ok`), since
  there is nothing to search for and a blank query is not a findability signal.

  ### top-N

  `top_n` bounds BOTH the search `limit` and the self-membership window. It
  defaults to `10` (`@default_top_n`) and is overridable per-enqueue via the
  `:top_n` option (threaded into the job's `"top_n"` arg). A doc that publishes
  but ranks outside the top 10 for its own labels is treated as a miss —
  findability is a *first-page* guarantee, not merely "present somewhere in
  the long tail".

  ## Deleted / unreadable before the run

  The probe is async, so the document may have been unpublished, deleted, or be
  non-anonymously-readable by the time the job runs. On a self-miss the worker
  first confirms the document is still publicly retrievable via
  `Content.get_document/4` (anonymous scope, mirroring the search's visibility):

    * gone / not anonymously readable → `{:cancel, :doc_gone}` — a clean no-op,
      NO finding emitted (a deleted or private doc is not a labeling failure),
      NO retry (`:cancel` is terminal).
    * still present → a genuine findability miss → warning + telemetry.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document

  # Walled types — mirrors `Barkpark.Content.Lifecycle` `@walled_types`. Only
  # paper/task publishes pass the wall, so only they carry the findability
  # promise the self-test verifies.
  @walled_types ~w(paper task)

  # Default top-N (both the search limit and the self-membership window).
  @default_top_n 10

  # How many leading title tokens feed the query seed alongside the main_tag.
  @title_token_count 6

  @telemetry_event [:barkpark, :authoring, :findability_miss]

  @doc """
  Enqueue the post-publish findability self-test from the `after_publish`
  lifecycle payload. Gated to walled types (paper/task); everything else is a
  no-op. ALWAYS returns `:ok` and NEVER raises — a job-insert failure must not
  crash the publish that just committed. The optional `:top_n` overrides the
  default self-membership window.
  """
  @spec enqueue_after(map(), keyword()) :: :ok
  def enqueue_after(payload, opts \\ [])

  def enqueue_after(%{event: :after_publish, doc: %Document{type: type} = doc}, opts)
      when type in @walled_types do
    args =
      %{
        "doc_id" => doc.doc_id,
        "type" => type,
        "dataset" => doc.dataset,
        "query" => build_seed(doc),
        "top_n" => Keyword.get(opts, :top_n, @default_top_n)
      }

    _ =
      try do
        args |> new() |> Oban.insert()
      rescue
        # An enqueue failure is advisory-only: the publish has already
        # committed and its response is on the wire. Swallow so the self-test
        # can never become a publish-blocking side effect.
        error ->
          Logger.warning(
            "FindabilityPosttest: enqueue failed for #{doc.type}/#{doc.doc_id} — " <>
              "#{Exception.message(error)}"
          )

          {:error, :enqueue_failed}
      end

    :ok
  end

  def enqueue_after(_payload, _opts), do: :ok

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    doc_id = Map.get(args, "doc_id")
    type = Map.get(args, "type")
    dataset = Map.get(args, "dataset")
    query = Map.get(args, "query")
    top_n = Map.get(args, "top_n", @default_top_n)

    # Test seams (mirrors ProjectorWorker): string module names (JSON-safe Oban
    # args) let a unit test drive the search/existence outcomes deterministically
    # without standing up the full FTS corpus. Default to the real facade.
    search_mod = resolve_mod(Map.get(args, "search"), Content)
    content_mod = resolve_mod(Map.get(args, "content"), Content)

    cond do
      not is_binary(doc_id) or doc_id == "" ->
        {:cancel, :missing_doc_id}

      not is_binary(dataset) or dataset == "" ->
        {:cancel, :missing_dataset}

      not is_binary(query) or query == "" ->
        # No seed → nothing to search for; a blank query is not a findability
        # signal. Clean no-op.
        :ok

      true ->
        run_self_test(search_mod, content_mod, doc_id, type, dataset, query, top_n)
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp run_self_test(search_mod, content_mod, doc_id, type, dataset, query, top_n) do
    {docs, total, _meta} =
      search_mod.search_documents(query, dataset, perspective: :published, limit: top_n)

    ranked =
      docs
      |> Enum.map(& &1.doc_id)
      |> Enum.take(top_n)

    if doc_id in ranked do
      # Hit — the document finds itself. Nothing to report.
      :ok
    else
      handle_miss(content_mod, doc_id, type, dataset, query, ranked, total, top_n)
    end
  end

  # A self-miss: confirm the doc is still publicly retrievable before treating
  # the miss as a finding. A doc deleted/unpublished/private since enqueue is a
  # clean no-op, not a labeling failure.
  defp handle_miss(content_mod, doc_id, type, dataset, query, ranked, total, top_n) do
    case content_mod.get_document(doc_id, type, dataset, []) do
      {:ok, _doc} ->
        emit_miss(doc_id, type, dataset, query, ranked, total, top_n)
        :ok

      _ ->
        {:cancel, :doc_gone}
    end
  end

  defp emit_miss(doc_id, type, dataset, query, ranked, total, top_n) do
    rank_diagnostics = %{ranked: ranked, top_n: top_n, total: total}

    Logger.warning(
      "authoring.findability_miss: #{type}/#{doc_id} published but not self-retrieved " <>
        "in top-#{top_n} for its own labels (query=#{inspect(query)}, ranked=#{inspect(ranked)})"
    )

    :telemetry.execute(
      @telemetry_event,
      %{count: 1},
      %{
        doc_id: doc_id,
        type: type,
        dataset: dataset,
        query: query,
        rank_diagnostics: rank_diagnostics
      }
    )
  end

  # Seed = main_tag (charter D7 denorm) + leading title tokens, deduped and
  # blank-dropped. See the moduledoc "Query seed derivation" section.
  defp build_seed(%Document{title: title, content: content}) do
    main_tag = content |> ensure_map() |> Map.get("main_tag")

    title_tokens =
      title
      |> to_string()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.take(@title_token_count)

    [main_tag | title_tokens]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp ensure_map(m) when is_map(m), do: m
  defp ensure_map(_), do: %{}

  # Resolve a TEST-ONLY seam module named as a string arg (mirrors
  # ProjectorWorker). `nil` (the production default) → the real facade module.
  defp resolve_mod(nil, default), do: default
  defp resolve_mod(mod, _default) when is_atom(mod), do: mod

  defp resolve_mod(mod, _default) when is_binary(mod),
    do: String.to_existing_atom("Elixir." <> mod)

  @doc "The telemetry event a findability miss emits — exposed for handler attach."
  def telemetry_event, do: @telemetry_event

  @doc "The default top-N self-membership window."
  def default_top_n, do: @default_top_n
end
