defmodule Barkpark.Content.NonMapBlockElementTest do
  @moduledoc """
  task-f8c7b0387f50534e — a non-map ELEMENT inside a block list crashed the
  write path.

  `Render.render_blocks/2` is `when is_list(blocks)` and maps `render_block/2`
  (`when is_map(block)`) over every element with nothing in between, so
  `{"body":{"blocks":["notamap"]}}` cleared the outer guard and raised
  FunctionClauseError inside the write projection — an uncaught 500 whose body
  was an HTML debug page, with no `request_id` for the caller to correlate.

  MEASURED with `refuse_non_map_block_elements/1` NEUTERED (a total early clause
  returning `:ok`, inserted at writer.ex:1202): **13 tests, 8 failures** — four
  raising

      ** (FunctionClauseError) no function clause matching in
         Barkpark.PortableDoc.Render.render_block/2   # arg 1 was "notamap"
        render.ex:243  render_block/2
        render.ex:367  render_blocks/2
        projection.ex     project_body/2
        projection.ex:162  project/4
        writer.ex:Writer.scaffold_expectation/3      (create / createOrReplace)
        writer.ex:Writer.maybe_project_document_content/2  (upsert)
        mutations.ex:155 · mutate_controller.ex:22

  and four answering **200**: the NESTED cases never crashed —
  `Compose.block_to_html/2` carries a non-map catch-all that renders `""`, and a
  create's `content["blocks"]` is replaced wholesale by the scaffold — so the
  author's element was silently dropped behind a success. Both shapes are refused
  at the same door: a crash is a 500, and a silent drop is a lie.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @dataset "test"

  setup do
    Barkpark.Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    # A schema with a STORED, non-empty layout is what routes a create through
    # `Writer.scaffold_expectation/3` → `Projection.project/4` → the renderer.
    # A layout-less schema never projects on create and so never reached the
    # crash — that is why the row could only reproduce it against a real
    # instance whose `post` schema declares an Expectation.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "blockcrash",
          "title" => "Block Crash",
          "visibility" => "public",
          "fields" => [],
          "layout" => [%{"kind" => "region", "name" => "body"}]
        },
        @dataset
      )

    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  defp mutate(conn, mutations) do
    conn
    |> authed()
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp uid(suffix), do: "nonmap-#{System.unique_integer([:positive])}-#{suffix}"

  # ── the table: one non-map element at EVERY level the walk descends ────────

  # {label, body value, expected details.blocks path}
  @levels [
    {"top-level blocks[0]", %{"blocks" => ["notamap"]}, "blocks[0]"},
    {"top-level blocks[1] (a later element)", %{"blocks" => [%{"type" => "paragraph"}, 42]},
     "blocks[1]"},
    {"nested blocks[0].blocks[0]",
     %{"blocks" => [%{"id" => "s1", "type" => "section", "blocks" => ["notamap"]}]},
     "blocks[0].blocks[0]"},
    {"nested blocks[0].children[0]",
     %{"blocks" => [%{"id" => "c1", "type" => "callout", "children" => [123]}]},
     "blocks[0].children[0]"},
    {"deep blocks[0].blocks[0].children[0]",
     %{
       "blocks" => [
         %{
           "id" => "s1",
           "type" => "section",
           "blocks" => [%{"id" => "c1", "type" => "callout", "children" => [["inline"]]}]
         }
       ]
     }, "blocks[0].blocks[0].children[0]"}
  ]

  describe "create — a non-map element at any level answers the JSON error envelope" do
    for {label, body, path} <- @levels do
      test "#{label}", %{conn: conn} do
        id = uid("create")

        resp =
          mutate(conn, [
            %{
              "create" => %{
                "_type" => "blockcrash",
                "_id" => id,
                "title" => "t",
                "body" => unquote(Macro.escape(body))
              }
            }
          ])

        assert resp.status == 400
        assert ["application/json" <> _] = get_resp_header(resp, "content-type")

        assert %{"error" => error} = Jason.decode!(resp.resp_body)
        assert error["code"] == "malformed"
        assert error["message"] == "block list contains an element that is not an object"
        assert is_binary(error["request_id"]) and error["request_id"] != ""
        assert (unquote(path) <> " must be an object") in error["details"]["blocks"]

        # The refusal is side-effect-free: nothing landed.
        assert {:error, :not_found} =
                 Content.get_document("drafts.#{id}", "blockcrash", @dataset)
      end
    end
  end

  describe "the other create-family verbs and the upsert door" do
    test "createOrReplace is refused the same way", %{conn: conn} do
      id = uid("cor")

      resp =
        mutate(conn, [
          %{
            "createOrReplace" => %{
              "_type" => "blockcrash",
              "_id" => id,
              "title" => "t",
              "body" => %{"blocks" => ["notamap"]}
            }
          }
        ])

      assert resp.status == 400
      assert %{"error" => %{"code" => "malformed"}} = Jason.decode!(resp.resp_body)
    end

    test "a content[\"blocks\"] root is refused too (the projected write root)", %{conn: conn} do
      id = uid("blocksroot")

      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_type" => "blockcrash",
              "_id" => id,
              "title" => "t",
              "content" => %{"blocks" => ["notamap"]}
            }
          }
        ])

      assert resp.status == 400

      assert %{"error" => %{"code" => "malformed", "details" => %{"blocks" => paths}}} =
               Jason.decode!(resp.resp_body)

      assert "blocks[0] must be an object" in paths
    end

    test "Writer.upsert_document/4 refuses it at its own door", %{conn: _conn} do
      id = uid("upsert")

      assert {:error, {:malformed_blocks, %{"blocks" => paths}}} =
               Barkpark.Content.Writer.upsert_document(
                 "blockcrash",
                 %{"doc_id" => id, "title" => "t", "content" => %{"blocks" => ["notamap"]}},
                 @dataset
               )

      assert "blocks[0] must be an object" in paths
    end
  end

  describe "the guard does not over-fire (shapes that write 200 today keep writing 200)" do
    test "a well-formed block body still writes and projects", %{conn: conn} do
      id = uid("ok")

      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_type" => "blockcrash",
              "_id" => id,
              "title" => "t",
              "body" => %{
                "blocks" => [
                  %{
                    "id" => "p1",
                    "type" => "paragraph",
                    "content" => [%{"type" => "text", "value" => "hello"}]
                  }
                ]
              }
            }
          }
        ])

      assert resp.status == 200
      assert {:ok, doc} = Content.get_document("drafts.#{id}", "blockcrash", @dataset)
      assert doc.content["body"]["html"] =~ "hello"
    end

    test "a plain array FIELD (slug) is not a block list and is untouched", %{conn: conn} do
      id = uid("slug")

      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_type" => "blockcrash",
              "_id" => id,
              "title" => "t",
              "slug" => ["a", "b"]
            }
          }
        ])

      assert resp.status == 200
      assert {:ok, doc} = Content.get_document("drafts.#{id}", "blockcrash", @dataset)
      assert doc.content["slug"] == ["a", "b"]
    end

    test "a non-LIST body root is untouched (the renderer's own list guard holds)", %{conn: conn} do
      id = uid("strbody")

      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_type" => "blockcrash",
              "_id" => id,
              "title" => "t",
              "body" => "just a string"
            }
          }
        ])

      assert resp.status == 200
    end
  end

  describe "the unit contract" do
    alias Barkpark.Content.Papers.BlockOps

    test "validate_block_elements/1 is :ok on a clean list and on a non-list" do
      assert :ok = BlockOps.validate_block_elements([%{"type" => "paragraph"}])
      assert :ok = BlockOps.validate_block_elements([])
      assert :ok = BlockOps.validate_block_elements("not a list")
      assert :ok = BlockOps.validate_block_elements(nil)
    end

    test "it reports EVERY offending path, not just the first" do
      assert {:error, {:malformed_blocks, %{"blocks" => paths}}} =
               BlockOps.validate_block_elements([
                 "a",
                 %{"type" => "section", "blocks" => ["b", %{"type" => "p"}]},
                 3
               ])

      assert paths == [
               "blocks[0] must be an object",
               "blocks[1].blocks[0] must be an object",
               "blocks[2] must be an object"
             ]
    end
  end
end
