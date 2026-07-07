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

  ## Draft-twin collapse (D12, loop-cut #2)

  `Content.upsert_document/4` always writes the DRAFT row (it forces the id to
  `drafts.<id>` and coerces `status → draft`). So for a task that was already
  PUBLISHED, the bookkeeping stamp would otherwise leave a permanent unpublished
  draft twin next to the published row — a phantom "pending changes" doc in
  Studio that never came from a human edit.

  `put/4` closes that: it records whether a published row existed BEFORE the
  stamp, and if so collapses the draft back into the published row via
  `Content.publish_document/4` — threaded `source: :github`. Because
  `publish_document` passes `:source` → `tap_broadcast` → `save_event`
  (`to_string(source)`), that publish `mutation_events` row is stamped exactly
  `"github"`, so the wave-1 Outbox EXCLUDES it (loop-cut #2). Both writes the
  bookkeeping path emits — the draft stamp AND the collapse publish — carry
  `source="github"` and are un-drainable, so the mirror can never re-drain its
  own write.

  A task that has NEVER been published (draft-only) is LEFT a draft — `put/4`
  never force-publishes under a user. A failed collapse publish is a harmless
  leftover draft (the next reconcile converges it), not a correctness bug: it is
  ignored and `put/4` still returns `{:ok, %Document{}}`.

  ## Absent, never fabricated

  When a task has never been mirrored, `content.github` is ABSENT and `get/1`
  returns `nil` — the helper never invents a repo/issue. Partial updates
  patch-MERGE into the existing `github` sub-map, so writing just a fresh
  `synced_rev` preserves the stored `repo`/`issue`.
  """

  alias Barkpark.Content
  alias Barkpark.Content.Document

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

  If the task was already PUBLISHED, the draft twin the upsert writes is
  collapsed back into the published row via `Content.publish_document/4`
  (threaded `:source`), so no phantom unpublished draft is left behind. A
  never-published task is LEFT a draft — `put/4` never force-publishes under a
  user. The collapse publish's `mutation_events` row is stamped `source="github"`
  too, so the Outbox excludes it (loop-cut #2); see the moduledoc.

  Returns `{:ok, %Document{}}` or `{:error, term}` (`:not_found` when the task
  doesn't exist). A failed collapse publish is ignored — the leftover draft is
  harmless and `put/4` still returns the `{:ok, %Document{}}` upsert result.
  """
  @spec put(String.t(), String.t(), map(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def put(doc_id, dataset, github, opts \\ [])
      when is_binary(doc_id) and is_binary(dataset) and is_map(github) do
    with {:ok, existing} <- fetch_task(doc_id, dataset, opts) do
      prior = get(existing) || %{}
      merged_github = Map.merge(prior, stringify_keys(github))
      content = Map.put(existing.content || %{}, @content_key, merged_github)
      pid = Content.published_id(existing.doc_id)

      # Was this task already published? Capture BEFORE the upsert writes its
      # draft twin, so a genuine never-published task is never force-published.
      was_published? =
        match?({:ok, _}, Content.get_document(pid, @task_type, dataset, opts))

      attrs = %{
        "doc_id" => pid,
        "title" => existing.title,
        "content" => content
      }

      source_opts = Keyword.put_new(opts, :source, :github)

      with {:ok, upserted} <-
             Content.upsert_document(@task_type, attrs, dataset, source_opts) do
        {:ok, collapse_draft_twin(was_published?, upserted, pid, dataset, source_opts)}
      end
    end
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

  # Collapse the draft twin the upsert wrote (D12). Only when the task was
  # ALREADY published: publish the fresh draft back into the published row so no
  # phantom unpublished draft is left in Studio. The publish is threaded the same
  # `source: :github` as the stamp, so its `mutation_events` row is excluded from
  # the Outbox (loop-cut #2). A never-published task is left a draft (never
  # force-published under a user). A failed publish is a harmless leftover draft,
  # not a correctness bug — ignore it and return the upsert result unchanged so
  # `put/4`'s `{:ok, %Document{}}` contract holds.
  defp collapse_draft_twin(false, upserted, _pid, _dataset, _opts), do: upserted

  defp collapse_draft_twin(true, upserted, pid, dataset, opts) do
    case Content.publish_document(pid, @task_type, dataset, opts) do
      {:ok, published} -> published
      _ -> upserted
    end
  end

  # Draft-first lookup (mirror of Content.Mutations.get_patch_base/4): the write
  # target is always the draft row, so the merge base must be the draft too —
  # reading the published row would merge stale content and clobber a newer draft.
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
