defmodule Barkpark.Content.InsertOnly do
  @moduledoc """
  The insert-only write a history restore asks for with `ifAbsent: true`, "I
  saw no document" (task-e89ff0279fb83fc6). `Content.Writer.upsert_document/4`
  takes it as `opts[:insert_only]`: the write may birth the draft row and may
  never update one. Every way a row can already be there answers the same
  refusal, `{:error, {:rev_mismatch, %{expected: nil, actual: rev, id: id}}}`
  (412 `precondition_failed`), and writes nothing:

    1. the writer's own read finds the draft row (`refuse_existing/6`, the first
       pre-write fence, before any plugin fence or hook runs);
    2. inside the write's transaction, under a lock on the document's identity,
       a second read finds a draft or published row (`insert/4`). Two
       insert-only writes of one document take that lock in turn, so the second
       reads the first's row;
    3. the insert hits the documents unique index (a writer that took no lock
       got there first). The insert runs in its own savepoint so the
       transaction can still read the row that won.

  Without `:insert_only` nothing here changes a write: `insert/4` is the plain
  `Repo.insert/1`.

  Test seams. The sandbox runs one process on one connection, so a race is
  driven by order, not by time: `{site, fun}` under the same `:writer_fault`
  config `Content.Writer` and `Content.BatchFault` read runs `fun` at that site.
  The sites are `:restore_after_state_check` (in `Content.Revisions`, after the
  restore's own compare), `:insert_only_before_lock` and
  `:insert_only_before_insert`. `nil` outside tests: one `Application.get_env`.
  """

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId}

  @doc "Whether this write was asked to be insert-only."
  def requested?(opts), do: Keyword.get(opts, :insert_only) == true

  @doc """
  Refuses an insert-only write whose writer already read a row. It is the first of
  `Content.Writer.upsert_document/4`'s pre-write fences, so it takes their arguments
  and runs before any plugin fence or hook.
  """
  def refuse_existing(_type, _attrs, _dataset, _doc_id, %Document{} = existing, opts) do
    if requested?(opts), do: {:error, mismatch(existing)}, else: :ok
  end

  def refuse_existing(_type, _attrs, _dataset, _doc_id, _prev_doc, _opts), do: :ok

  @doc """
  Births the document row for `attrs`: the INSERT of `Content.Writer`'s upsert
  door. Insert-only, it first takes the identity lock and reads again; a row found
  there, or a unique-index conflict, is the refusal. Otherwise it is the plain
  `Repo.insert/1` of the changeset.
  """
  def insert(attrs, type, dataset, opts) do
    changeset = Document.changeset(%Document{}, attrs)
    doc_id = Map.get(attrs, "doc_id")

    if requested?(opts) and is_binary(doc_id) do
      seam!(:insert_only_before_lock)
      published = DraftId.published_id(doc_id)

      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "insert-only:#{dataset}:#{type}:#{published}"
      ])

      case current(published, type, dataset, opts) do
        %Document{} = existing -> {:error, mismatch(existing)}
        nil -> insert_or_refuse(changeset, published, type, dataset, opts)
      end
    else
      Repo.insert(changeset)
    end
  end

  @doc "Runs the test function configured for `site`, if any."
  def seam!(site) do
    case Application.get_env(:barkpark, :writer_fault) do
      {^site, fun} when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  defp insert_or_refuse(changeset, published, type, dataset, opts) do
    seam!(:insert_only_before_insert)

    case Repo.insert(changeset, mode: :savepoint) do
      {:ok, doc} ->
        {:ok, doc}

      {:error, %Ecto.Changeset{} = failed} = error ->
        with true <- taken?(failed),
             %Document{} = existing <- current(published, type, dataset, opts) do
          {:error, mismatch(existing)}
        else
          _ -> error
        end
    end
  end

  defp taken?(%Ecto.Changeset{errors: errors}),
    do: Enum.any?(errors, fn {_field, {_msg, meta}} -> meta[:constraint] == :unique end)

  defp current(published, type, dataset, opts) do
    Enum.find_value([DraftId.draft_id(published), published], fn id ->
      case Content.get_document(id, type, dataset, opts) do
        {:ok, doc} -> doc
        _ -> nil
      end
    end)
  end

  defp mismatch(%Document{rev: rev, doc_id: id}),
    do: {:rev_mismatch, %{expected: nil, actual: rev, id: id}}
end
