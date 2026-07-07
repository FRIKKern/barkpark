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

  Returns `{:ok, %Document{}}` or `{:error, term}` (`:not_found` when the task
  doesn't exist).
  """
  @spec put(String.t(), String.t(), map(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def put(doc_id, dataset, github, opts \\ [])
      when is_binary(doc_id) and is_binary(dataset) and is_map(github) do
    with {:ok, existing} <- fetch_task(doc_id, dataset, opts) do
      prior = get(existing) || %{}
      merged_github = Map.merge(prior, stringify_keys(github))
      content = Map.put(existing.content || %{}, @content_key, merged_github)

      attrs = %{
        "doc_id" => Content.published_id(existing.doc_id),
        "title" => existing.title,
        "content" => content
      }

      Content.upsert_document(
        @task_type,
        attrs,
        dataset,
        Keyword.put_new(opts, :source, :github)
      )
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
