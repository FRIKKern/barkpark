defmodule Barkpark.Plugins.Github.Link do
  @moduledoc """
  The flat `content.github` idempotency + de-loop anchor for the GitHub bridge
  (epic decision **D3**).

  A mirrored task carries a single flat CONTENT field:

      content.github = %{
        "repo"       => "FRIKKern/barkpark", # owner/name the issue lives in
        "issue"      => 42,                    # issue NUMBER (so replay is PATCH, not CREATE)
        "synced_rev" => "<task._rev>",         # the task rev last mirrored
        "state"      => "synced"               # bookkeeping: synced | detached | ...
      }

  This is plain task CONTENT (like `code_refs`), NEVER a declared task-schema
  field — the github plugin must never mutate the tasks plugin's schema. Reads
  and writes go through `Barkpark.Content.*` ONLY; touching `Barkpark.Repo`
  directly would bypass the draft/hook/broadcast path the plugin contract
  depends on.

  ## Why the write is stamped `source: :github`

  `put/4` writes through the normal Content upsert path, so it emits a
  `mutation_events` row. That row is stamped `source: "github"` (D4 cut #2):
  `Broadcast.save_event/6` does `to_string(source)`, and the wave-1 outbox
  reader EXCLUDES `source="github"` events — so this bookkeeping write can never
  echo back out as an outbound mirror. Combined with the `synced_rev`
  equality check (`synced?/1`, D4 cut #3), a no-op edit stays a no-op sync.

  ## The stamp never forks a twin (D12, loop-cut #2 — repaired)

  `Content.upsert_document/4` always writes the DRAFT row (it forces the id to
  `drafts.<id>` and coerces `status → draft`). The bookkeeping stamp used to go
  through it unconditionally and then collapse the fresh draft back into the
  published row with `Content.publish_document/4`. That collapse is REFUSABLE —
  the publish door's claim fence (`Content.Lifecycle.stale_claim?/2`) compares
  the whole claim map byte-for-byte, and `Tasks.Renew` moves it every ~90 s — so
  on a CLAIMED task the collapse was refused on every pass and the mirror left a
  permanent `drafts.<id>` twin behind, then merged its NEXT stamp into that
  frozen twin: the mirror chasing its own tail (measured 2026-09-06 on
  `drafts.task-49b5c183f10ad0fc`, eight draft revisions in 45 minutes each
  changing only `content.github.synced_rev` to the rev its own previous write
  produced).

  `put/4` is now PUBLISHED-FIRST, the same rule
  `Content.Mutations.@published_first_patch_types` applies to the `patch` door
  for type `task`: when a published row exists, the `github` block is merged
  into THAT row through `Tasks.Internal.fenced_content_write/4` — the rev-fenced
  `UPDATE … RETURNING` every task verb (claim/pulse/stamp/close) writes through.
  It preserves `content.claim` byte for byte (the claim is simply not in the
  patch), it cannot draft-prefix, and there is no publish to refuse. So the
  mirror STRUCTURALLY cannot fork a twin of a published task, and no collapse
  exists to swallow. The write still emits its `mutation_events` row stamped
  `source: "github"`, so the Outbox still excludes it (loop-cut #2).

  A task that has NEVER been published is LEFT a draft — the stamp goes through
  the ordinary upsert and `put/4` never force-publishes under a user.

  ## Nothing is swallowed

  Two anomalies on the published path are reported LOUDLY (`Logger.error` with
  the doc_id and the gate, plus a `[:barkpark, :github, :link, :stamp_anomaly]`
  telemetry count) instead of the old `Logger.warning` + `{:ok, _}`:

    * `draft_twin_present` — a pre-existing `drafts.<id>` twin sits beside the
      published row. The stamp lands on the PUBLISHED row anyway (that is the
      row every task reader serves) and the twin is left alone: publishing a
      twin whose provenance is unknown can destroy live published state, so the
      mirror names the fork rather than resolving it.
    * `rev_fence` — the fenced write lost its rev fence (the row moved under
      us). `put/4` returns `{:error, {:stamp_refused, …}}` so `MirrorJob.stamp/4`
      surfaces it and Oban retries; the retry re-reads and converges.

  ## The stamp does not chase its own tail

  `synced?/1` is `synced_rev == <task rev>`, and the stamp itself MOVES the rev.
  Stamping the rev the caller READ therefore guarantees `synced?/1` is false
  forever after — one mirror pass per pass, for ever. On the published path the
  write chooses its own `new_rev`, so when the caller's `synced_rev` is the rev
  it read, the stamp records the rev the write ITSELF produces: after the stamp
  `synced_rev == doc.rev` and the next pass is a no-op. And a merge that changes
  nothing (`merged == prior`) writes no revision at all.

  ## Absent, never fabricated

  When a task has never been mirrored, `content.github` is ABSENT and `get/1`
  returns `nil` — the helper never invents a repo/issue. Partial updates
  patch-MERGE into the existing `github` sub-map, so writing just a fresh
  `synced_rev` preserves the stored `repo`/`issue`.
  """

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Internal

  @content_key "github"
  @task_type "task"

  @typedoc "The stored `content.github` bookkeeping map (string keys)."
  @type github :: %{optional(String.t()) => term()}

  @doc """
  Read the `content.github` map off a task document, or `nil` when absent.

  Accepts a `%Content.Document{}` (the row the write path returns) or a plain
  content-bearing map (a `content` / `"content"` envelope). Never raises.
  """
  @spec get(Document.t() | map() | nil) :: github() | nil
  def get(%Document{content: content}), do: extract(content)
  def get(%{content: content}) when is_map(content), do: extract(content)
  def get(%{"content" => content}) when is_map(content), do: extract(content)
  def get(_), do: nil

  defp extract(content) when is_map(content) do
    case Map.get(content, @content_key) || Map.get(content, :github) do
      m when is_map(m) -> m
      _ -> nil
    end
  end

  defp extract(_), do: nil

  @doc """
  Patch-merge `github` bookkeeping into a task's `content.github` and persist it
  through the Content upsert path, stamped `source: :github`.

  `github` may use string OR atom keys (`:repo`/`:issue`/`:synced_rev`/`:state`);
  they are normalised to string keys and MERGED over any existing `content.github`
  so a partial write (e.g. just `synced_rev`) preserves the rest. The rest of the
  task's content is preserved untouched.

  `opts` is threaded to `Content.get_document/4` + `Content.upsert_document/4`
  (workspace/project scope, `:user_id`, …). `:source` defaults to `:github`
  (the D4 loop cut); an explicit `:source` in `opts` wins.

  The lookup is PUBLISHED-FIRST for type `task` (the rule
  `Content.Mutations.@published_first_patch_types` already applies at the patch
  door): when a published row exists the `github` block is merged into THAT row
  through `Tasks.Internal.fenced_content_write/4`, so no `drafts.<id>` twin is
  ever forked and `content.claim` survives byte for byte. A never-published task
  keeps the ordinary draft upsert — `put/4` never force-publishes under a user.

  Returns `{:ok, %Document{}}` or `{:error, term}` (`:not_found` when the task
  doesn't exist, `{:stamp_refused, %{doc_id:, gate:, …}}` when the fenced write
  lost its rev fence — LOGGED at error level and counted, never swallowed).
  """
  @spec put(String.t(), String.t(), map(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def put(doc_id, dataset, github, opts \\ [])
      when is_binary(doc_id) and is_binary(dataset) and is_map(github) do
    pid = Content.published_id(doc_id)
    source_opts = Keyword.put_new(opts, :source, :github)

    case Content.get_document(pid, @task_type, dataset, opts) do
      {:ok, %Document{} = published} ->
        put_on_published(published, dataset, github, opts)

      _ ->
        put_on_draft(doc_id, pid, dataset, github, source_opts)
    end
  end

  @doc """
  The PUBLISHED-FIRST arm of `put/4`, for a caller that already holds the
  published row (`MirrorJob` loads it before it mirrors). The write target IS
  the published row, so it goes through the rev-fenced task-write primitive
  `Tasks.Internal.fenced_content_write/4` rather than
  `Content.upsert_document/4` (which always draft-prefixes). Nothing but
  `content.github` moves, so the claim/criteria/lifecycle the row carries are
  preserved verbatim and there is no publish door to refuse.

  `published` is the row the write is FENCED on: a struct read before someone
  else moved the row yields `{:error, {:stamp_refused, %{gate: "rev_fence"}}}`.
  """
  @spec put_on_published(Document.t(), String.t(), map(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def put_on_published(%Document{} = published, dataset, github, opts \\ []) do
    pid = Content.published_id(published.doc_id)
    report_draft_twin(pid, dataset, opts)

    prior = get(published) || %{}
    merged = Map.merge(prior, stringify_keys(github))

    if merged == prior do
      # Nothing to record. Writing here would move the rev, which would make
      # `synced?/1` false again and buy the next pass another write: the tail
      # chase. A no-op stamp writes no revision.
      {:ok, published}
    else
      new_rev = Internal.generate_rev()

      write_stamp(
        published,
        pid,
        dataset,
        self_referential_rev(merged, published, new_rev),
        new_rev
      )
    end
  end

  # The caller stamps the rev it MIRRORED. When that is the rev this write is
  # about to replace, record the rev the write ITSELF produces instead — else
  # `synced_rev` is one revision behind for ever and every pass re-mirrors.
  defp self_referential_rev(merged, %Document{rev: rev}, new_rev) do
    if Map.get(merged, "synced_rev") == rev,
      do: Map.put(merged, "synced_rev", new_rev),
      else: merged
  end

  defp write_stamp(%Document{} = published, pid, _dataset, merged, new_rev) do
    observed_rev = published.rev
    content = Map.put(published.content || %{}, @content_key, merged)

    case Internal.fenced_content_write(published, observed_rev, content, new_rev) do
      {:ok, %Document{} = stored} ->
        # Same event contract as the old upsert path: stamped `source: "github"`,
        # so `Outbox.fetch/3` excludes it and the mirror cannot re-drain its own
        # bookkeeping write (loop-cut #2).
        ev = Internal.insert_mutation_event!(stored, "update", observed_rev, "github")

        Content.broadcast_document_mutation(stored, "update",
          event_id: ev.id,
          previous_rev: observed_rev
        )

        {:ok, stored}

      :stale ->
        detail = %{doc_id: pid, gate: "rev_fence", observed_rev: observed_rev}
        report_anomaly(detail)
        {:error, {:stamp_refused, detail}}
    end
  end

  # NEVER-PUBLISHED arm — byte for byte the pre-existing behaviour: the stamp
  # lands on the draft row and the task is left a draft.
  defp put_on_draft(doc_id, pid, dataset, github, source_opts) do
    with {:ok, existing} <- fetch_task(doc_id, dataset, source_opts) do
      prior = get(existing) || %{}
      merged_github = Map.merge(prior, stringify_keys(github))
      content = Map.put(existing.content || %{}, @content_key, merged_github)

      attrs = %{
        "doc_id" => pid,
        "title" => existing.title,
        "content" => content
      }

      Content.upsert_document(@task_type, attrs, dataset, source_opts)
    end
  end

  # A twin beside the published row is a FORK someone else minted (this module
  # can no longer make one). The stamp lands on the published row — the row every
  # task reader serves — and the twin is NAMED, never silently published over:
  # a twin whose provenance is unknown may hold state the published row does not.
  defp report_draft_twin(pid, dataset, opts) do
    case Content.get_document(Content.draft_id(pid), @task_type, dataset, opts) do
      {:ok, %Document{doc_id: twin_id}} ->
        report_anomaly(%{doc_id: pid, gate: "draft_twin_present", twin: twin_id})

      _ ->
        :ok
    end
  end

  # LOUD, always: error level with the doc_id and the refusing/tripped gate, plus
  # a telemetry count. The predecessor logged a warning and returned `{:ok, _}`,
  # so 45 minutes of refused collapses raised nothing at all.
  defp report_anomaly(%{doc_id: doc_id, gate: gate} = detail) do
    Logger.error("github link: bookkeeping stamp for #{doc_id} hit #{gate}: #{inspect(detail)}")

    :telemetry.execute([:barkpark, :github, :link, :stamp_anomaly], %{count: 1}, %{
      doc_id: doc_id,
      gate: gate
    })

    :ok
  end

  @doc """
  `true` when the task has been mirrored at its CURRENT rev — i.e.
  `content.github.synced_rev == <task rev>`. A task with no `content.github`,
  or whose stored `synced_rev` lags the live rev, is NOT synced (the MirrorJob
  should reconcile it). Never raises.

  Accepts a `%Document{}` or an envelope map (`_rev` / `rev`).
  """
  @spec synced?(Document.t() | map() | nil) :: boolean()
  def synced?(task_doc) do
    case get(task_doc) do
      %{"synced_rev" => synced_rev} when is_binary(synced_rev) ->
        case rev_of(task_doc) do
          rev when is_binary(rev) -> synced_rev == rev
          _ -> false
        end

      _ ->
        false
    end
  end

  # Draft-first lookup for the NEVER-PUBLISHED arm only (the published arm reads
  # the published row itself): the write target there is the draft row, so the
  # merge base must be the draft too.
  defp fetch_task(doc_id, dataset, opts) do
    case Content.get_document(Content.draft_id(doc_id), @task_type, dataset, opts) do
      {:ok, doc} -> {:ok, doc}
      _ -> Content.get_document(doc_id, @task_type, dataset, opts)
    end
  end

  defp rev_of(%Document{rev: rev}), do: rev
  defp rev_of(%{_rev: rev}), do: rev
  defp rev_of(%{"_rev" => rev}), do: rev
  defp rev_of(%{rev: rev}), do: rev
  defp rev_of(%{"rev" => rev}), do: rev
  defp rev_of(_), do: nil

  # Shallow string-key coercion — the github map is flat.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
