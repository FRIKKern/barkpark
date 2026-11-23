defmodule BarkparkWeb.MutateLinkHrefNamedTest do
  @moduledoc """
  task-b923a915151d2038, r3 (#28393 review of r2): the fence's schema walk
  missed rich text in an array of a named object type, the page-builder
  shape (`sections: array of [hero, textBlock]`), because `get_schema` does
  not inline an `array`'s `of`. A multi-member row with no `_type`, a field
  the schema does not declare and a `string` field holding Portable Text
  escaped the same way.

  The walk fails closed: a named type is resolved at any depth, and a value
  it cannot type is read whole. Only a `json` field, or a scalar, is skipped.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Repo

  @dataset "production"
  @js "javascript:alert(1)"

  setup %{conn: conn} do
    ws = create_workspace!("hrefn-ws-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    scope = [workspace_id: ws.id, project_id: proj.id]
    rt = %{"name" => "rt", "type" => "richText"}
    label = %{"name" => "label", "type" => "string"}

    for schema <- [
          %{"name" => "callout", "kind" => "object", "fields" => [label, rt]},
          %{
            "name" => "outer",
            "kind" => "object",
            "fields" => [%{"name" => "inner", "type" => "callout"}]
          },
          %{"name" => "node", "kind" => "object", "fields" => [rt]},
          %{
            "name" => "pagebld",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{"name" => "cos", "type" => "array", "of" => [%{"type" => "callout"}]},
              %{
                "name" => "multi",
                "type" => "arrayOf",
                "of" => [
                  %{"name" => "a", "type" => "composite", "fields" => [rt]},
                  %{"name" => "b", "type" => "composite", "fields" => [label]}
                ]
              },
              %{"name" => "o", "type" => "outer"},
              %{"name" => "os", "type" => "array", "of" => [%{"type" => "outer"}]},
              %{"name" => "tree", "type" => "node"},
              %{"name" => "blob", "type" => "json"},
              %{"name" => "n", "type" => "number"}
            ]
          }
        ] do
      {:ok, _} = Content.upsert_schema(Map.put(schema, "title", schema["name"]), @dataset, scope)
    end

    # The store refuses a type that holds itself; one written before that
    # check, or straight into the row, still reaches the fence.
    {1, _} =
      Repo.update_all(
        from(s in SchemaDefinition, where: s.name == "node" and s.workspace_id == ^ws.id),
        set: [fields: [rt, %{"name" => "child", "type" => "node"}]]
      )

    raw = "hrefn-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "hrefn", @dataset, ["read", "write", "admin"], ws.id)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> raw)}
  end

  defp link(href) do
    [
      %{
        "_type" => "block",
        "_key" => "k1",
        "style" => "normal",
        "markDefs" => [%{"_type" => "link", "_key" => "m1", "href" => href}],
        "children" => [%{"_type" => "span", "_key" => "s1", "text" => "go", "marks" => ["m1"]}]
      }
    ]
  end

  defp create(conn, content) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{
        "mutations" => [
          %{
            "create" => %{
              "_type" => "pagebld",
              "doc_id" => "hrefn-#{System.unique_integer([:positive])}",
              "title" => "T",
              "content" => content
            }
          }
        ]
      })
    )
  end

  defp refused!(resp, path) do
    assert resp.status == 422, resp.resp_body
    body = Jason.decode!(resp.resp_body)
    assert [%{"code" => "pt_link_href_refused", "path" => ^path}] = body["error"]["findings"]
  end

  # The table's `:js` is a block linking to a javascript: address.
  defp fill(:js), do: link(@js)
  defp fill(%{} = map), do: Map.new(map, fn {k, v} -> {k, fill(v)} end)
  defp fill(list) when is_list(list), do: Enum.map(list, &fill/1)
  defp fill(value), do: value

  for {label, content, path} <- [
        {"an array of a named type, rows typed",
         %{"cos" => [%{"_type" => "callout", "_key" => "c", "rt" => :js}]},
         "/cos/0/rt/0/markDefs/0/href"},
        {"an array of a named type, rows not typed", %{"cos" => [%{"_key" => "c", "rt" => :js}]},
         "/cos/0/rt/0/markDefs/0/href"},
        {"a row typed as no member",
         %{"cos" => [%{"_type" => "zzz", "_key" => "c", "rt" => :js}]},
         "/cos/0/rt/0/markDefs/0/href"},
        {"a multi-member array row with no _type", %{"multi" => [%{"_key" => "c", "rt" => :js}]},
         "/multi/0/rt/0/markDefs/0/href"},
        {"a named type two deep", %{"o" => %{"inner" => %{"rt" => :js}}},
         "/o/inner/rt/0/markDefs/0/href"},
        {"a named type two deep in an array",
         %{"os" => [%{"_key" => "x", "inner" => %{"rt" => :js}}]},
         "/os/0/inner/rt/0/markDefs/0/href"},
        {"a recursive named type",
         %{"tree" => %{"child" => %{"child" => %{"child" => %{"child" => %{"rt" => :js}}}}}},
         "/tree/child/child/child/child/rt/0/markDefs/0/href"},
        {"a field the schema does not declare", %{"extra" => :js}, "/extra/0/markDefs/0/href"},
        {"a string field holding Portable Text", %{"title" => :js}, "/title/0/markDefs/0/href"},
        {"a number field holding Portable Text", %{"n" => :js}, "/n/0/markDefs/0/href"}
      ] do
    @content content
    @path path
    test "#{label}: a javascript: address is refused", %{conn: conn} do
      refused!(create(conn, fill(@content)), @path)
    end
  end

  test "control: a json field holding the same Portable Text is written", %{conn: conn} do
    assert create(conn, %{"blob" => link(@js)}).status == 200
  end

  test "control: a https address in each shape is written", %{conn: conn} do
    ok = link("https://x.example")

    resp =
      create(conn, %{
        "cos" => [%{"_type" => "callout", "_key" => "c", "rt" => ok}],
        "multi" => [%{"_key" => "c", "rt" => ok}],
        "os" => [%{"_key" => "x", "inner" => %{"rt" => ok}}],
        "tree" => %{"child" => %{"rt" => ok}},
        "extra" => ok
      })

    assert resp.status == 200, resp.resp_body
  end
end
