defmodule Barkpark.IncrementalJobWorkspaceReadTest do
  @moduledoc """
  task-56910177b7e359ca: the Indx and EdgeProjector incremental upsert jobs
  carry the document's workspace_id/project_id, but read the document with
  `Content.get_document(id, type, scope)` and no opts. With no workspace the
  dataset resolves to the Default workspace's, so for a non-Default workspace
  the job picked up Default's same-id document (indexing Default's title into
  the workspace's search index, or writing Default's references as the
  workspace's edges), or cancelled as :doc_gone. Both jobs now read in the
  job's scope. Real `Content`; only the indexer and projector are faked.
  """
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.EdgeProjector.ProjectorWorker
  alias Barkpark.Plugins.Indx.IndexerWorker

  @dataset "production"
  @indexer "Barkpark.IncrementalJobWorkspaceReadTest.FakeIndexer"
  @projector "Barkpark.IncrementalJobWorkspaceReadTest.FakeProjector"

  defmodule FakeIndexer do
    @moduledoc false
    def upsert_record(_key, doc) do
      send(self(), {:upserted, doc})
      :ok
    end
  end

  defmodule FakeProjector do
    @moduledoc false
    def upsert_record(doc, _opts) do
      send(self(), {:projected, doc})
      {:ok, %{added: 0, removed: 0}}
    end
  end

  defp title_of(%{title: t}), do: t
  defp title_of(%{"title" => t}), do: t
  defp title_of(other), do: inspect(other)

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]
    type = "jobpost_#{System.unique_integer([:positive])}"
    default = [workspace_id: default_workspace_id!()]

    for s <- [scope, default] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
          @dataset,
          s
        )
    end

    for {s, title} <- [{default, "Default title"}, {scope, "Own title"}] do
      {:ok, _} =
        Content.create_document(type, %{"_id" => "doc-1", "title" => title}, @dataset, s)

      {:ok, _} = Content.publish_document("doc-1", type, @dataset, s)
    end

    %{ws: ws, proj: proj, type: type}
  end

  test "Indx incremental upsert indexes the workspace's own document", ctx do
    assert :ok =
             perform_job(IndexerWorker, %{
               "op" => "upsert",
               "scope" => @dataset,
               "_id" => "doc-1",
               "types" => [ctx.type],
               "workspace_id" => ctx.ws.id,
               "project_id" => ctx.proj.id,
               "indexer" => @indexer
             })

    assert_receive {:upserted, doc}
    assert title_of(doc) == "Own title"
  end

  test "EdgeProjector incremental upsert projects the workspace's own document", ctx do
    assert :ok =
             perform_job(ProjectorWorker, %{
               "op" => "upsert",
               "scope" => @dataset,
               "_id" => "doc-1",
               "types" => [ctx.type],
               "workspace_id" => ctx.ws.id,
               "project_id" => ctx.proj.id,
               "projector" => @projector
             })

    assert_receive {:projected, doc}
    assert title_of(doc) == "Own title"
  end
end
