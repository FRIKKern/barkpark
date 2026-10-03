defmodule Barkpark.Content.DocScopedSchemaTest do
  @moduledoc """
  task-8a0056c52a002633: two document-driven paths looked the type's schema up
  with NO scope, which resolves the dataset to the Default workspace's:

    * `Papers.resolve_blocks_for_edit/3` synthesized a block-less document's
      blocks from Default's layout and field list, so another workspace's
      fields had no blocks in the editor, and the first block op saved that
      shape;
    * `Content.disconnect_references/3` stripped another workspace's
      referencer with Default's field list (or not at all), leaving the
      reference dangling after the target was deleted.

  Both now read the schema in the document's own scope.
  """
  use Barkpark.DataCase, async: true
  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Papers}

  @dataset "production"

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp register!(type, fields, scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => type, "title" => type, "visibility" => "public", "fields" => fields},
        @dataset,
        scope
      )
  end

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    %{ws: ws, proj: proj, scope: [workspace_id: ws.id, project_id: proj.id]}
  end

  test "block synthesis uses the document's workspace schema, not Default's", ctx do
    type = unique("article")

    register!(type, [%{"name" => "summary", "type" => "string"}],
      workspace_id: default_workspace_id!()
    )

    register!(type, [%{"name" => "lede", "type" => "string"}], ctx.scope)

    doc = %Document{
      doc_id: "a1",
      type: type,
      title: "t",
      workspace_id: ctx.ws.id,
      project_id: ctx.proj.id,
      content: %{"lede" => "own field"}
    }

    {blocks, true} = Papers.resolve_blocks_for_edit(doc, type, @dataset)
    bound = blocks |> Enum.map(& &1["fieldName"]) |> Enum.reject(&is_nil/1)

    assert "lede" in bound,
           "the workspace's own field got no bound block; bound fields: #{inspect(bound)}"
  end

  test "disconnect strips a non-Default workspace's reference by its own schema", ctx do
    target = unique("target")
    pointer = unique("pointer")
    register!(target, [], ctx.scope)

    register!(
      pointer,
      [%{"name" => "rel", "type" => "reference", "refType" => target}],
      ctx.scope
    )

    {:ok, _} =
      Content.create_document(target, %{"_id" => "tgt", "title" => "tgt"}, @dataset, ctx.scope)

    {:ok, _} =
      Content.create_document(
        pointer,
        %{"_id" => "ptr", "title" => "ptr", "rel" => "tgt"},
        @dataset,
        ctx.scope
      )

    {:ok, _} = Content.publish_document("tgt", target, @dataset, ctx.scope)
    {:ok, _} = Content.publish_document("ptr", pointer, @dataset, ctx.scope)

    {:ok, before} = Content.get_document("ptr", pointer, @dataset, ctx.scope)
    assert before.content["rel"] == "tgt", "fixture: the reference must be stored"

    Content.disconnect_references("tgt", @dataset, ctx.scope)

    {:ok, doc} = Content.get_document("ptr", pointer, @dataset, ctx.scope)

    refute Map.has_key?(doc.content || %{}, "rel"),
           "the reference was left dangling: #{inspect(doc.content)}"
  end
end
