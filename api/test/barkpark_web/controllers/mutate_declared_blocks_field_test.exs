defmodule BarkparkWeb.MutateDeclaredBlocksFieldTest do
  @moduledoc """
  task-380edc7a76a18cb0: a type whose schema declares its own top-level field
  named `blocks` (an ordinary arrayOf, like a page builder's) keeps that array
  as sent. Before, the Writer treated every `content["blocks"]` list as the
  PortableDoc block list: each item gained `id: "block-N"`, and the document
  gained a `body` ({blocks, html}) and a `preview` its schema does not declare.
  A type without such a field, a type that declares `blocks` as the PortableDoc
  body (editor "blocks", portableDocument, portableDocument members) and a
  schemaless document all keep the block model unchanged.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "test"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    token = "declared-blocks-#{System.unique_integer([:positive])}"
    Auth.create_token(token, "dev", @dataset, ["read", "write", "admin"], ws.id)

    for {name, extra} <- [
          {"pageBuilt",
           [
             %{
               "name" => "blocks",
               "type" => "arrayOf",
               "of" => %{
                 "type" => "composite",
                 "fields" => [
                   %{"name" => "kind", "type" => "string"},
                   %{"name" => "heading", "type" => "string"}
                 ]
               }
             }
           ]},
          {"tagged", [%{"name" => "blocks", "type" => "arrayOf", "of" => %{"type" => "string"}}]},
          {"freeform", []},
          {"pdRichText", [%{"name" => "blocks", "type" => "richText", "editor" => "blocks"}]},
          {"pdDocument", [%{"name" => "blocks", "type" => "portableDocument"}]},
          {"pdMembers",
           [%{"name" => "blocks", "type" => "arrayOf", "of" => %{"type" => "portableDocument"}}]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => name,
            "visibility" => "public",
            "fields" => [%{"name" => "title", "type" => "string"} | extra]
          },
          @dataset,
          scope
        )
    end

    %{token: token, scope: scope, id: "blk-#{System.unique_integer([:positive])}"}
  end

  defp mutate(token, mutations) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp stored(id, type, scope) do
    {:ok, doc} = Content.get_document("drafts." <> id, type, @dataset, scope)
    doc.content
  end

  @items [%{"_key" => "k1", "kind" => "hero", "heading" => "x"}]

  test "a declared blocks array is stored as sent on create, createOrReplace and patch",
       %{token: token, scope: scope, id: id} do
    create = %{
      "create" => %{"_id" => id, "_type" => "pageBuilt", "title" => "T", "blocks" => @items}
    }

    assert mutate(token, [create]).status == 200
    assert stored(id, "pageBuilt", scope) == %{"blocks" => @items}

    two = @items ++ [%{"_key" => "k2", "kind" => "quote", "heading" => "y"}]

    replace = %{
      "createOrReplace" => %{"_id" => id, "_type" => "pageBuilt", "title" => "T", "blocks" => two}
    }

    assert mutate(token, [replace]).status == 200
    assert stored(id, "pageBuilt", scope) == %{"blocks" => two}

    patch = %{"patch" => %{"id" => id, "type" => "pageBuilt", "set" => %{"blocks" => @items}}}
    assert mutate(token, [patch]).status == 200
    assert stored(id, "pageBuilt", scope) == %{"blocks" => @items}
  end

  test "a declared blocks array of strings is not refused as block elements",
       %{token: token, scope: scope, id: id} do
    create = %{
      "create" => %{"_id" => id, "_type" => "tagged", "title" => "T", "blocks" => ["a", "b"]}
    }

    assert mutate(token, [create]).status == 200
    assert stored(id, "tagged", scope) == %{"blocks" => ["a", "b"]}
  end

  # The block model: ids, a projected body with html, and a preview.
  defp assert_block_model(token, scope, id, type) do
    paragraph = %{"type" => "paragraph", "text" => "Hei"}

    create = %{
      "create" => %{"_id" => id, "_type" => type, "title" => "T", "blocks" => [paragraph]}
    }

    conn = mutate(token, [create])
    assert conn.status == 200, "#{type}: #{conn.resp_body}"

    content = stored(id, type, scope)
    assert [%{"id" => "block-0"}] = content["blocks"]
    assert is_binary(content["body"]["html"]), type
    assert is_map(content["preview"]), type
  end

  test "a type that declares no blocks field keeps the block model", %{
    token: token,
    scope: scope,
    id: id
  } do
    assert_block_model(token, scope, id, "freeform")
  end

  test "a blocks field declared as the PortableDoc body keeps the block model",
       %{token: token, scope: scope, id: id} do
    for type <- ~w(pdRichText pdDocument pdMembers),
        do: assert_block_model(token, scope, "#{id}-#{type}", type)
  end

  test "a schemaless document keeps the block model", %{token: token, scope: scope, id: id} do
    assert_block_model(token, scope, id, "noSchemaHere")
  end
end
