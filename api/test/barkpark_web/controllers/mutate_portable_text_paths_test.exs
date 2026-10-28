defmodule BarkparkWeb.MutatePortableTextPathsTest do
  @moduledoc """
  Keyed patch paths on a stored Portable Text body, through the real
  `/v1/data/mutate` door (stage S1 of the Portable Text plan,
  task-9296af21cac3f813). Each patch changes only the node it names: every
  other block, span, mark definition and key keeps its stored bytes. The
  schema, text and keys are made up.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  @dataset "test"
  @token "barkpark-dev-token"

  @body [
    %{
      "_type" => "block",
      "_key" => "intro",
      "style" => "h2",
      "markDefs" => [],
      "children" => [
        %{"_type" => "span", "_key" => "intro0", "text" => "A made-up heading", "marks" => []}
      ]
    },
    %{
      "_type" => "block",
      "_key" => "b",
      "style" => "normal",
      "markDefs" => [
        %{"_type" => "link", "_key" => "m", "href" => "https://example.com/one"},
        %{"_type" => "link", "_key" => "m2", "href" => "https://example.com/two"}
      ],
      "children" => [
        %{"_type" => "span", "_key" => "s", "text" => "First words, ", "marks" => []},
        %{"_type" => "span", "_key" => "s2", "text" => "a link", "marks" => ["m"]},
        %{
          "_type" => "span",
          "_key" => "s3",
          "text" => " and another",
          "marks" => ["m2", "strong"]
        }
      ]
    },
    %{"_type" => "factBox", "_key" => "c", "heading" => "A made-up fact"},
    %{
      "_type" => "block",
      "_key" => "outro",
      "style" => "normal",
      "markDefs" => [],
      "children" => [
        %{"_type" => "span", "_key" => "outro0", "text" => "Closing words.", "marks" => []}
      ]
    }
  ]

  setup do
    Barkpark.Auth.create_token(
      @token,
      "dev",
      @dataset,
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "ptStory",
          "title" => "Story",
          "visibility" => "public",
          "fields" => [
            %{
              "name" => "body",
              "type" => "richText",
              "format" => "portableText",
              "blocks" => %{
                "of" => [
                  %{"name" => "factBox", "fields" => [%{"name" => "heading", "type" => "string"}]}
                ]
              }
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "ptStory",
        %{"doc_id" => "pts1", "title" => "Story", "content" => %{"body" => @body}},
        @dataset
      )

    :ok
  end

  defp mutate(conn, patch) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{
        "mutations" => [%{"patch" => Map.merge(%{"id" => "pts1", "type" => "ptStory"}, patch)}]
      })
    )
  end

  defp body do
    {:ok, doc} = Content.get_document("drafts.pts1", "ptStory", @dataset)
    doc.content["body"]
  end

  defp update_block(blocks, key, fun),
    do: Enum.map(blocks, fn b -> if b["_key"] == key, do: fun.(b), else: b end)

  test "the stored body is the Portable Text it was written as", %{conn: _conn} do
    assert body() == @body
  end

  test ~s(set body[_key=="b"].children[_key=="s"].text changes only that span's text), %{
    conn: conn
  } do
    resp =
      mutate(conn, %{"set" => %{~s(body[_key=="b"].children[_key=="s"].text) => "New words, "}})

    assert resp.status == 200

    want =
      update_block(@body, "b", fn b ->
        Map.update!(b, "children", fn kids ->
          Enum.map(kids, fn k ->
            if k["_key"] == "s", do: %{k | "text" => "New words, "}, else: k
          end)
        end)
      end)

    assert body() == want
  end

  test ~s(insert after body[_key=="b"] adds one block and moves nothing else), %{conn: conn} do
    new = %{
      "_type" => "block",
      "_key" => "added",
      "style" => "normal",
      "markDefs" => [],
      "children" => [
        %{"_type" => "span", "_key" => "added0", "text" => "Inserted.", "marks" => []}
      ]
    }

    resp = mutate(conn, %{"insert" => %{"after" => ~s(body[_key=="b"]), "items" => [new]}})
    assert resp.status == 200

    [intro, b, c, outro] = @body
    assert body() == [intro, b, new, c, outro]
  end

  test ~s(unset body[_key=="b"].markDefs[_key=="m"] removes only that mark definition), %{
    conn: conn
  } do
    resp = mutate(conn, %{"unset" => [~s(body[_key=="b"].markDefs[_key=="m"])]})
    assert resp.status == 200

    want =
      update_block(@body, "b", fn b ->
        Map.update!(b, "markDefs", fn defs -> Enum.reject(defs, &(&1["_key"] == "m")) end)
      end)

    assert body() == want
  end

  test ~s(unset body[_key=="c"] removes only the custom block), %{conn: conn} do
    resp = mutate(conn, %{"unset" => [~s(body[_key=="c"])]})
    assert resp.status == 200

    assert body() == Enum.reject(@body, &(&1["_key"] == "c"))
  end
end
