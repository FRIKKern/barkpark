defmodule Barkpark.Repo.DocumentsReadIndexesTest do
  @moduledoc """
  The two migrations of task-cca3c6d48e57097e left the indexes the desk reads
  in the shape the queries need: a census index Postgres can answer
  `count(*)` per type from, and a bounded pending list on the GIN indexes the
  reference filters scan once per row.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Analytics

  defp reloptions(index) do
    %{rows: rows} =
      Repo.query!("SELECT coalesce(reloptions, '{}') FROM pg_class WHERE relname = $1", [index])

    rows
  end

  test "the reference GIN indexes keep a pending list of at most 128 kB" do
    for index <- ["documents_content_path_idx", "documents_content_refs_idx"] do
      case reloptions(index) do
        [] -> :ok
        [[opts]] -> assert "gin_pending_list_limit=128" in opts, "#{index}: #{inspect(opts)}"
      end
    end

    assert [[_]] = reloptions("documents_content_path_idx")
  end

  test "the census index leads with the workspace" do
    %{rows: [[indexdef]]} =
      Repo.query!(
        "SELECT pg_get_indexdef(oid) FROM pg_class WHERE relname = 'documents_workspace_dataset_type_index'"
      )

    assert indexdef =~ "(workspace_id, dataset, type)"
  end

  test "the census counts every row of a type, drafts included" do
    Content.upsert_schema(%{"name" => "note", "title" => "Note", "fields" => []}, "census-ix")

    for i <- 1..3,
        do: {:ok, _} = Content.create_document("note", %{"_id" => "n#{i}"}, "census-ix")

    {:ok, _} = Content.publish_document("n1", "note", "census-ix")
    {:ok, _} = Content.upsert_document("note", %{"_id" => "n1", "title" => "again"}, "census-ix")

    assert [%{type: "note", total: 4}] = Analytics.type_census("census-ix", [])
  end
end
