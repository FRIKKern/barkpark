defmodule Barkpark.Content.FormsClassicRenderScopeTest do
  @moduledoc """
  task-af1a7cc9cd523586: a Classic save of a document whose blocks live only in
  `content["body"]["blocks"]` re-renders the body HTML with
  `Labels.render_opts(dataset)`, which carries no scope. Reference titles then
  resolved through the Default workspace's dataset: a non-Default workspace's
  saved HTML showed Default's title for a same-id document, and its own
  reference fell back to the raw id. The save now renders in its own scope.
  """
  use Barkpark.DataCase, async: true
  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @dataset "production"

  defp publish!(type, id, title, scope) do
    {:ok, _} = Content.create_document(type, %{"_id" => id, "title" => title}, @dataset, scope)
    {:ok, _} = Content.publish_document(id, type, @dataset, scope)
  end

  test "Classic save renders a historical body's reference titles from its own workspace" do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]
    n = System.unique_integer([:positive])
    author_type = "author_#{n}"
    doc_type = "hist_post_#{n}"

    for s <- [scope, [workspace_id: default_workspace_id!()]] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => author_type, "title" => "Author", "fields" => []},
          @dataset,
          s
        )
    end

    publish!(author_type, "ref1", "Alice in A", scope)
    publish!(author_type, "ref1", "Dora in Default", workspace_id: default_workspace_id!())

    {:ok, schema} =
      Content.upsert_schema(
        %{
          "name" => doc_type,
          "title" => "Historical post",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "author_ref", "type" => "reference", "refType" => author_type},
            %{"name" => "body", "type" => "richText"}
          ]
        },
        @dataset,
        scope
      )

    blocks = [
      %{
        "id" => "r1",
        "type" => "field-reference",
        "value" => "ref1",
        "refType" => author_type
      },
      %{
        "id" => "p1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Body text."}]
      }
    ]

    {:ok, base} =
      Content.upsert_document(
        doc_type,
        %{
          "doc_id" => "hist-1",
          "title" => "Hist",
          "content" => %{"body" => %{"blocks" => blocks}}
        },
        @dataset,
        scope
      )

    {:ok, saved, _errors} =
      Content.upsert_draft(
        base,
        doc_type,
        schema,
        %{
          "title" => "Hist",
          "author_ref" => "ref1",
          "body" => Content.doc_to_form(base, schema)["body"],
          "status" => "draft"
        },
        @dataset,
        scope
      )

    html = get_in(saved.content, ["body", "html"]) || ""

    refute html =~ "Dora in Default", "the save rendered Default's title: #{html}"
    assert html =~ "Alice in A", "the save did not render the workspace's own title: #{html}"
  end
end
