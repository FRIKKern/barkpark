defmodule BarkparkWeb.NestedPrivateFieldTest do
  @moduledoc """
  task-777b7903d79fb32e — a field declared `private` INSIDE another field.

  `SchemaDefinition.parse_field/2` copies `private` onto every kid of a
  composite/object field, and an `arrayOf` field declares its item shape in
  `of`. `Content.Envelope` used to judge visibility on TOP-level keys only:
  `redact_by_field_visibility/4` dropped a private top-level key but passed a
  visible parent's private kids through, and `field_readable?/3` resolved a
  dotted filter/order path by its first segment alone. Measured on main before
  the fix, with NO token:

    * GET /v1/data/doc and /v1/data/query returned `meta.secret`;
    * `?filter[meta.secret]=…` was accepted and its count (1 vs 0) was a value
      oracle; `?order=meta.secret:asc` sorted by the hidden value;
    * an array item's private kid rode the response too;
    * `?expand=` and `?fields=` (which project AFTER the render) carried the
      same leak from a referenced document.

  Every arm also has its control: a public nested kid stays visible and
  filterable, and an admin (or a reader on the kid's `readable_by`) still sees
  the private kid — the fix must not over-redact.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}

  @ds "nested_private_field"
  @admin "npf-admin-#{System.unique_integer([:positive])}"
  @reader "npf-reader-#{System.unique_integer([:positive])}"

  setup do
    ws = Tenancy.get_default_workspace()
    project = Tenancy.get_default_project()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} = Auth.create_token(@admin, "npf admin", @ds, ["admin"])
    {:ok, reader} = Auth.create_token(@reader, "npf reader", @ds, ["read"])

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "npdoc",
          "title" => "Nested",
          "visibility" => "public",
          "fields" => [
            %{"name" => "name", "type" => "string"},
            %{
              "name" => "meta",
              "type" => "composite",
              "fields" => [
                %{"name" => "open", "type" => "string"},
                %{"name" => "secret", "type" => "string", "private" => true},
                %{"name" => "granted", "type" => "string", "readable_by" => [reader.id]}
              ]
            },
            %{
              "name" => "items",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "fields" => [
                  %{"name" => "label", "type" => "string"},
                  %{"name" => "cost", "type" => "string", "private" => true}
                ]
              }
            },
            %{"name" => "rel", "type" => "reference", "refType" => "npdoc"}
          ]
        },
        @ds
      )

    content = %{
      "name" => "x",
      "meta" => %{"open" => "o", "secret" => "NESTEDSECRET", "granted" => "FORREADER"},
      "items" => [%{"label" => "a", "cost" => "COSTA"}, %{"label" => "b", "cost" => "COSTB"}]
    }

    {:ok, _} =
      Content.create_document(
        "npdoc",
        %{"_id" => "np-1", "title" => "T", "content" => content},
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document("np-1", "npdoc", @ds, scope)

    {:ok, _} =
      Content.create_document(
        "npdoc",
        %{
          "_id" => "np-2",
          "title" => "Pointer",
          "content" => %{"name" => "p", "rel" => %{"_ref" => "np-1"}}
        },
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document("np-2", "npdoc", @ds, scope)
    :ok
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
  defp doc(conn, id), do: conn |> get("/v1/data/doc/#{@ds}/npdoc/#{id}") |> json_response(200)
  defp query(conn, qs), do: get(conn, "/v1/data/query/#{@ds}/npdoc?" <> qs)
  defp first(body), do: hd(body["result"]["documents"])

  describe "an anonymous reader" do
    test "doc get drops the private kid and keeps the public one", %{conn: conn} do
      meta = doc(conn, "np-1")["result"]["meta"]
      assert meta["open"] == "o"
      refute Map.has_key?(meta, "secret")
      refute Map.has_key?(meta, "granted")
    end

    test "query drops the private kid", %{conn: conn} do
      body = conn |> query("filter[_id]=np-1") |> json_response(200)
      meta = first(body)["meta"]
      assert meta["open"] == "o"
      refute Map.has_key?(meta, "secret")
    end

    test "an array item's private kid is dropped from every item", %{conn: conn} do
      items = doc(conn, "np-1")["result"]["items"]
      assert Enum.map(items, & &1["label"]) == ["a", "b"]
      assert Enum.all?(items, &(not Map.has_key?(&1, "cost")))
    end

    test "a filter on the private kid is refused, not answered as a count oracle", %{conn: conn} do
      resp = query(conn, "filter[meta.secret]=NESTEDSECRET")
      assert resp.status == 422
      assert json_response(resp, 422)["error"]["code"] == "forbidden_field"

      resp = query(conn, "filter[items.cost]=COSTA")
      assert resp.status == 422
    end

    test "ordering by the private kid is refused", %{conn: conn} do
      assert query(conn, "order=meta.secret:asc").status == 422
    end

    test "CONTROL: a filter on the public kid still works", %{conn: conn} do
      body = conn |> query("filter[meta.open]=o") |> json_response(200)
      assert body["result"]["count"] == 1
    end

    test "?fields= projecting the parent does not resurrect the kid", %{conn: conn} do
      body = conn |> query("filter[_id]=np-1&fields=meta,meta.secret") |> json_response(200)
      meta = first(body)["meta"]
      assert meta["open"] == "o"
      refute Map.has_key?(meta, "secret")
    end

    test "?expand= of a reference does not leak the target's private kid", %{conn: conn} do
      body = conn |> query("filter[_id]=np-2&expand=rel") |> json_response(200)
      rel = first(body)["rel"]

      assert is_map(rel) and rel["meta"]["open"] == "o",
             "expected the expanded target, got #{inspect(rel)}"

      refute Map.has_key?(rel["meta"], "secret")
    end
  end

  describe "the walk is bounded" do
    test "a 60-level schema renders without error and still redacts near the top" do
      # level n is a composite whose kids are a private `s` and the next level.
      deep_field =
        Enum.reduce(60..1//-1, %{"name" => "leaf", "type" => "string"}, fn n, inner ->
          %{
            "name" => "l#{n}",
            "type" => "composite",
            "fields" => [%{"name" => "s", "type" => "string", "private" => true}, inner]
          }
        end)

      deep_value =
        Enum.reduce(60..1//-1, "LEAF", fn n, inner ->
          %{"s" => "S#{n}", if(n == 60, do: "leaf", else: "l#{n + 1}") => inner}
        end)

      schema = %Barkpark.Content.SchemaDefinition{name: "deep", fields: [deep_field]}

      doc = %Barkpark.Content.Document{
        doc_id: "d1",
        type: "deep",
        title: "t",
        content: %{"l1" => deep_value}
      }

      rendered = Barkpark.Content.Envelope.render(doc, schema, nil)
      refute Map.has_key?(rendered["l1"], "s")
      refute Map.has_key?(rendered["l1"]["l2"], "s")
    end
  end

  describe "callers who may see the kid still see it (no over-redaction)" do
    test "an admin token sees and filters the private kid", %{conn: conn} do
      meta = conn |> bearer(@admin) |> doc("np-1") |> get_in(["result", "meta"])
      assert meta["secret"] == "NESTEDSECRET"

      body =
        scoped_conn()
        |> bearer(@admin)
        |> query("filter[meta.secret]=NESTEDSECRET")
        |> json_response(200)

      assert body["result"]["count"] == 1
    end

    test "a reader on the kid's readable_by sees that kid and not the private one", %{conn: conn} do
      meta = conn |> bearer(@reader) |> doc("np-1") |> get_in(["result", "meta"])
      assert meta["granted"] == "FORREADER"
      refute Map.has_key?(meta, "secret")
    end
  end
end
