defmodule Barkpark.Content.PapersReaderSourceTest do
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  test "anonymous reader schema is selected from the Paper tenant and redacted caches stay closed" do
    dataset = "reader-scope-#{System.unique_integer([:positive])}"
    {default_ws, default_project} = ensure_default_scope!()
    other_ws = create_workspace!("reader-schema-other")
    other_project = create_project!(other_ws, "reader-schema-other-project")

    public_blocks = %{
      "name" => "paper",
      "title" => "Paper",
      "fields" => [%{"name" => "blocks", "type" => "array"}]
    }

    private_blocks = put_in(public_blocks, ["fields", Access.at(0), "private"], true)

    {:ok, _} =
      Content.upsert_schema(public_blocks, dataset,
        workspace_id: other_ws.id,
        project_id: other_project.id
      )

    {:ok, _} =
      Content.upsert_schema(private_blocks, dataset,
        workspace_id: default_ws.id,
        project_id: default_project.id
      )

    {:ok, seed} =
      Content.create_document(
        "post",
        %{"doc_id" => "reader-schema-seed", "title" => "Seed"},
        dataset,
        workspace_id: default_ws.id,
        project_id: default_project.id
      )

    blocks = [%{"id" => "secret", "type" => "heading", "text" => "Tenant secret"}]

    paper = %{
      seed
      | type: "paper",
        content: %{
          "body" => %{"blocks" => blocks},
          "body_html" => "<h1>Tenant secret cached</h1>"
        }
    }

    # The foreign public schema must not override the Paper tenant's private
    # schema, and the derived HTML cache must not reopen the redacted prose.
    assert :empty = Content.Papers.reader_source(paper, dataset, [])

    {:ok, _} =
      Content.upsert_schema(public_blocks, dataset,
        workspace_id: default_ws.id,
        project_id: default_project.id
      )

    assert {:blocks, ^blocks} = Content.Papers.reader_source(paper, dataset, [])
  end
end
