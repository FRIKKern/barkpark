defmodule BarkparkWeb.MutateBlockShapeTest do
  @moduledoc """
  A non-map ELEMENT inside a client-supplied block list must be REFUSED with the
  canonical JSON validation envelope — never crash the write path.

  `Render.render_blocks/2` (render.ex) guards its argument with `is_list/1` but
  NOT its elements, and `render_block/2` is `when is_map(block)`. A bare string
  in a block list therefore satisfies the list guard and then matches no
  `render_block/2` clause: `FunctionClauseError`, uncaught, HTTP 500 with an HTML
  body instead of the `{"error": {"code", "message", "request_id"}}` envelope
  `docs/api-v1.md` §9 promises.

  `Projection.bound?/1` fails SAFE on a non-map (`bound?(_block) -> false`), so
  the bad element is sorted into the FREE blocks and reaches `render_blocks/2`
  every time — there is no accidental filter upstream.

  ## The two writers

  The structural validation the walk needs was already written — `BlockOps.
  validate_render_shapes/1` emits exactly `"blocks[0] must be an object"` — but
  it was reachable from only the PAPER writers (`upsert_blocks_doc/3` via
  `validate_render_shapes_for_type/2`, and `Lifecycle.prepare_paper_render_shapes/2`).
  The generic document writers never called it, so both of these crashed:

    * CREATE of a LAYOUT-bearing type carrying a `body` region —
      `Writer.scaffold_expectation/3` reuses the caller's body blocks VERBATIM
      (`Synthesis.scaffold_body_blocks/2`) and projects them at writer.ex.
    * PATCH/upsert of ANY type carrying `content["blocks"]` —
      `Writer.maybe_project_document_content/2` projects them.

  Both are covered below at every level the walk descends: the top-level list and
  the nested `"blocks"` / `"children"` lists `render_block_errors/2` recurses into.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Repo

  setup do
    Barkpark.Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    # A LAYOUT-bearing type. `Writer.scaffold_or_initial_values/3` only routes to
    # `scaffold_expectation/3` — the branch that projects a caller-supplied body
    # region — when the schema's stored `layout` is a NON-EMPTY list. A schema
    # with `"fields" => []` and no layout takes the other branch and never
    # projects, so it cannot exercise the create-path crash at all.
    {:ok, _} =
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(%{
        "name" => "post",
        "title" => "Post",
        "dataset" => "test",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "body", "type" => "richText"}
        ],
        "layout" => [
          %{"kind" => "field", "name" => "title"},
          %{"kind" => "region", "name" => "body"}
        ]
      })
      |> Repo.insert()

    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  defp mutate(conn, mutations) do
    conn |> authed() |> post("/v1/data/mutate/test", Jason.encode!(%{"mutations" => mutations}))
  end

  # Every element shape that is NOT a map. Each must be refused identically —
  # the renderer's `is_map/1` guard does not distinguish them, so neither may the
  # validation.
  @non_map_elements [
    {"a bare string", "notamap"},
    {"an integer", 7},
    {"null", nil},
    {"a nested list", ["inner"]},
    {"a boolean", true}
  ]

  describe "create path — a LAYOUT-bearing type's body region (Writer.scaffold_expectation/3)" do
    for {label, element} <- @non_map_elements do
      test "#{label} at the top level of body.blocks is refused, not a 500", %{conn: conn} do
        element = unquote(Macro.escape(element))

        resp =
          mutate(conn, [
            %{
              "create" => %{
                "_type" => "post",
                "_id" => "shape-top-#{:erlang.phash2(element)}",
                "title" => "t",
                "body" => %{"blocks" => [element]}
              }
            }
          ])

        assert_refused(resp, "blocks[0]")
      end
    end

    test "a non-map nested under a block's \"children\" is refused", %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_type" => "post",
              "_id" => "shape-children",
              "title" => "t",
              "body" => %{
                "blocks" => [
                  %{"id" => "c1", "type" => "columns", "children" => ["notamap"]}
                ]
              }
            }
          }
        ])

      assert_refused(resp, "children[0]")
    end

    test "a non-map nested under a block's \"blocks\" is refused", %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_type" => "post",
              "_id" => "shape-nested-blocks",
              "title" => "t",
              "body" => %{
                "blocks" => [
                  %{"id" => "n1", "type" => "callout", "blocks" => [%{"id" => "n2", "type" => "group", "children" => [7]}]}
                ]
              }
            }
          }
        ])

      assert_refused(resp, "children[0]")
    end

    test "a well-formed body region still creates (the guard is not a blanket refusal)",
         %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_type" => "post",
              "_id" => "shape-ok",
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

      assert resp.status == 200, "well-formed create should still succeed, got #{resp.status}"
    end
  end

  describe "patch path — any type's content[\"blocks\"] (Writer.maybe_project_document_content/2)" do
    setup %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "create" => %{
              "_type" => "post",
              "_id" => "patch-target",
              "title" => "seed"
            }
          }
        ])

      assert resp.status == 200, "seed create failed: #{resp.status} #{resp.resp_body}"
      :ok
    end

    for {label, element} <- @non_map_elements do
      test "#{label} in content.blocks on a patch is refused, not a 500", %{conn: conn} do
        element = unquote(Macro.escape(element))

        resp =
          mutate(conn, [
            %{
              "createOrReplace" => %{
                "_type" => "post",
                "_id" => "patch-target",
                "title" => "seed",
                "content" => %{"blocks" => [element]}
              }
            }
          ])

        assert_refused(resp, "blocks[0]")
      end
    end

    test "a non-map nested under \"children\" on a patch is refused", %{conn: conn} do
      resp =
        mutate(conn, [
          %{
            "createOrReplace" => %{
              "_type" => "post",
              "_id" => "patch-target",
              "title" => "seed",
              "content" => %{
                "blocks" => [%{"id" => "c1", "type" => "columns", "children" => ["notamap"]}]
              }
            }
          }
        ])

      assert_refused(resp, "children[0]")
    end
  end

  # The whole contract in one place: a 4xx (never 5xx), the canonical JSON
  # envelope of docs/api-v1.md §9 (code + message + request_id), and a details
  # payload that NAMES the offending path so the caller can fix the right element
  # instead of bisecting their payload.
  defp assert_refused(resp, path_fragment) do
    assert resp.status == 422,
           "expected 422, got #{resp.status}. body: #{String.slice(resp.resp_body, 0, 400)}"

    body = Jason.decode!(resp.resp_body)
    err = body["error"]

    assert err["code"] == "validation_failed"
    assert is_binary(err["message"]) and err["message"] != ""
    assert is_binary(err["request_id"]) and err["request_id"] != ""

    flat = Jason.encode!(err["details"])

    assert String.contains?(flat, path_fragment),
           "details should name the offending path #{inspect(path_fragment)}, got: #{flat}"

    assert String.contains?(flat, "must be an object"),
           "details should say what the element must be, got: #{flat}"
  end
end
