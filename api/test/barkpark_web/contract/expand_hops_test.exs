defmodule BarkparkWeb.Contract.ExpandHopsTest do
  @moduledoc """
  task-053249d91d178353 — `expand=` takes nested paths
  (`sections.cards.product.contributors`): each segment expands on the
  documents the previous one resolved, at most four deep, with drafts and
  field visibility applied at every hop and a cap on documents resolved below
  the first hop. gyldendal.no's link and image fragments reach two to five
  hops (page → section → card → product → contributor).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @ds "test"

  defp ref(name, to), do: %{"name" => name, "type" => "reference", "refType" => to}

  defp refs(name, to),
    do: %{"name" => name, "type" => "arrayOf", "of" => %{"type" => "reference", "refType" => to}}

  defp doc(type, id, content, publish? \\ true) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, content), @ds)

    if publish?, do: {:ok, _} = Content.publish_document(id, type, @ds)
  end

  setup do
    for {name, fields} <- [
          {"hpage", [refs("sections", "hsection")]},
          {"hsection", [refs("cards", "hcard")]},
          {"hcard", [ref("product", "hproduct")]},
          {"hproduct",
           [
             refs("contributors", "hcontrib"),
             %{"name" => "secret", "type" => "string", "private" => true}
           ]},
          {"hcontrib", [%{"name" => "name", "type" => "string"}]}
        ] do
      Content.upsert_schema(
        %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
        @ds
      )
    end

    doc("hcontrib", "k1", %{"name" => "Ada"})
    doc("hproduct", "pr1", %{"contributors" => [%{"_ref" => "k1"}], "secret" => "s"})
    # Never published: an anonymous read must not reach it at any hop.
    doc("hproduct", "pr2", %{"contributors" => [%{"_ref" => "k1"}]}, false)
    doc("hcard", "c1", %{"product" => %{"_ref" => "pr1"}})
    doc("hcard", "c2", %{"product" => %{"_ref" => "pr2"}})
    doc("hsection", "s1", %{"cards" => [%{"_ref" => "c1"}, %{"_ref" => "c2"}]})
    doc("hpage", "p1", %{"sections" => [%{"_ref" => "s1"}]})
    :ok
  end

  defp page(conn, expand) do
    conn |> get("/v1/data/doc/#{@ds}/hpage/p1?expand=" <> expand) |> json_response(200)
  end

  defp list(conn, expand) do
    conn
    |> get("/v1/data/query/#{@ds}/hpage?expand=" <> expand)
    |> json_response(200)
    |> get_in(["result", "documents"])
    |> hd()
  end

  test "a path expands every hop, on the doc and the list doors", %{conn: conn} do
    for p <- [
          page(conn, "sections.cards.product.contributors"),
          list(conn, "sections.cards.product.contributors")
        ] do
      p = Map.get(p, "result", p)
      [s1] = p["sections"]
      [c1, c2] = s1["cards"]
      assert [%{"_id" => "k1", "name" => "Ada"}] = c1["product"]["contributors"]
      # Drafts at every hop: the unpublished product stays a reference.
      assert c2["product"] == %{"_ref" => "pr2"}
      # Field visibility at every hop: the private field is redacted.
      refute Map.has_key?(c1["product"], "secret")
    end
  end

  test "a shorter path stops where it ends", %{conn: conn} do
    [s1] = list(conn, "sections.cards")["sections"]
    assert [%{"_id" => "c1", "product" => %{"_ref" => "pr1"}}, _] = s1["cards"]
  end

  test "more than four segments, or a segment that is no reference, is a 400", %{conn: conn} do
    body =
      conn
      |> get("/v1/data/query/#{@ds}/hpage?expand=sections.cards.product.contributors.name")
      |> json_response(400)

    assert body["error"]["details"]["max_depth"] == 4

    body = conn |> get("/v1/data/query/#{@ds}/hpage?expand=sections.bogus") |> json_response(400)
    assert body["error"]["details"]["unknown"] == "bogus"
  end

  test "past the cap on documents below the first hop, a 400", %{conn: conn} do
    Application.put_env(:barkpark, :expand_max_nested_docs, 2)
    on_exit(fn -> Application.delete_env(:barkpark, :expand_max_nested_docs) end)

    body =
      conn
      |> get("/v1/data/query/#{@ds}/hpage?expand=sections.cards.product")
      |> json_response(400)

    assert body["error"]["details"]["max_nested_documents"] == 2
    assert list(conn, "sections.cards") |> Map.has_key?("sections")
  end
end
