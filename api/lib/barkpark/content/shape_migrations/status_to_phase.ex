defmodule Barkpark.Content.ShapeMigrations.StatusToPhase do
  @moduledoc """
  Moves a project's old `status` choice into `content.phase` (owner ruling
  #45, task-e427940a663dc687). Dry run by default; never runs on its own.

  The demo `project` schema used to declare a `status` select
  (planning/active/completed/archived). Studio wrote that select to the
  document's ROW status column, so a project marked "active" in Studio has
  row status `active`, and the choice was lost the next time it was
  published. The field is now `phase`, a content field. This task finds rows
  whose row status is one of the non-lifecycle words and, with `apply: true`,
  copies the word into `content.<field>` (unless the document already has
  one) and sets the row status back to `draft` (for a `drafts.` row) or
  `published`.

  Run on a box (release, no Mix):

      bin/barkpark eval 'IO.inspect(Barkpark.Content.ShapeMigrations.StatusToPhase.census())'
      bin/barkpark eval 'Barkpark.Content.ShapeMigrations.StatusToPhase.run() |> IO.inspect()'
      bin/barkpark eval 'Barkpark.Content.ShapeMigrations.StatusToPhase.run(apply: true) |> IO.inspect()'

  Or from a checkout: `mix barkpark.shape.status_to_phase [--apply]`.

  Census SQL (read-only):

      SELECT type, status, count(*) FROM documents
      WHERE status IN ('planning', 'active', 'completed') GROUP BY 1, 2;
  """

  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @non_lifecycle ~w(planning active completed)

  @doc "Row counts by `{type, status}` for the non-lifecycle row statuses."
  @spec census() :: [%{type: String.t(), status: String.t(), count: non_neg_integer()}]
  def census do
    from(d in Document,
      where: d.status in ^@non_lifecycle,
      group_by: [d.type, d.status],
      select: %{type: d.type, status: d.status, count: count(d.id)},
      order_by: [d.type, d.status]
    )
    |> Repo.all()
  end

  @doc """
  Options: `apply:` (default `false`), `type:` (default `"project"`),
  `field:` (default `"phase"`). Returns `%{scanned, changed, kept_existing,
  applied?, rows}` where `rows` lists `{doc_id, old_status, new_status}`.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)
    type = Keyword.get(opts, :type, "project")
    field = Keyword.get(opts, :field, "phase")

    docs =
      from(d in Document, where: d.type == ^type and d.status in ^@non_lifecycle, order_by: d.id)
      |> Repo.all()

    rows =
      Enum.map(docs, fn doc ->
        content = doc.content || %{}
        kept? = Map.has_key?(content, field)
        new_status = if String.starts_with?(doc.doc_id, "drafts."), do: "draft", else: "published"
        new_content = if kept?, do: content, else: Map.put(content, field, doc.status)

        if apply? do
          doc
          |> Ecto.Changeset.change(status: new_status, content: new_content)
          |> Repo.update!()
        end

        %{
          doc_id: doc.doc_id,
          old_status: doc.status,
          new_status: new_status,
          kept_existing: kept?
        }
      end)

    %{
      scanned: length(docs),
      changed: length(rows),
      kept_existing: Enum.count(rows, & &1.kept_existing),
      applied?: apply?,
      rows: rows
    }
  end
end
