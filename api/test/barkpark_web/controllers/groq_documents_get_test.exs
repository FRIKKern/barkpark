defmodule BarkparkWeb.GroqDocumentsGetTest do
  @moduledoc """
  task-13790b478beeee4d: `documents::get(gdr)` over the GROQ endpoint reads
  like `->` does. It answers only from the caller's own workspace, project and
  dataset, in the query's perspective, with the fields the caller may read.
  Sanity's shape (ecu57yeh/e2e-local, 26 Oct): the argument is an object whose
  `_ref` is `dataset:<project>.<dataset>:<id>`; a bare id string, a missing id
  or a non-object is null.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @ds "gdg_ds"

  defp tenant!(slug, name) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    for ds <- [@ds, "gdg_other"] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "author",
            "title" => "Author",
            "visibility" => "public",
            "fields" => [
              %{"name" => "name", "type" => "string"},
              %{"name" => "secret", "type" => "string", "private" => true}
            ]
          },
          ds,
          scope
        )
    end

    {:ok, _} =
      Content.create_document(
        "author",
        %{"_id" => "alan", "name" => name, "secret" => "s"},
        @ds,
        scope
      )

    {:ok, _} = Content.publish_document("alan", "author", @ds, scope)

    {:ok, _} =
      Content.create_document("author", %{"_id" => "bob", "name" => "Bob"}, "gdg_other", scope)

    {:ok, _} = Content.publish_document("bob", "author", "gdg_other", scope)

    token = "gdg-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "gdg", @ds, ["read"], ws.id)
    %{scope: scope, token: token, slug: slug}
  end

  setup do
    a = tenant!("gdg-a", "Alan Turing")
    b = tenant!("gdg-b", "Other tenant's Alan")

    # A draft over A's published Alan.
    {:ok, _} =
      Content.upsert_document(
        "author",
        %{"_id" => "alan", "name" => "Alan (draft)"},
        @ds,
        a.scope
      )

    {:ok, a: a, b: b}
  end

  defp q(t, query, perspective \\ "published") do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> t.token)
    |> get("/w/#{t.slug}/p/site/v2025-02-19/data/query/#{@ds}", %{
      "query" => query,
      "perspective" => perspective
    })
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp gdr(location), do: ~s|documents::get({"_ref": "dataset:#{location}"})|

  test "reads the caller's own document, never another tenant's", %{a: a, b: b} do
    assert q(a, gdr("site.#{@ds}:alan") <> ".name") == "Alan Turing"
    assert q(b, gdr("site.#{@ds}:alan") <> ".name") == "Other tenant's Alan"
  end

  test "another dataset, another project, a bare id or a missing id is null", %{a: a} do
    assert q(a, gdr("site.gdg_other:bob")) == nil
    assert q(a, gdr("elsewhere.#{@ds}:alan")) == nil
    assert q(a, gdr("site.#{@ds}:nope")) == nil
    assert q(a, ~s|documents::get("alan")|) == nil
    assert q(a, ~s|documents::get({"_ref": "alan"})|) == nil
  end

  test "follows the query's perspective, as a deref does", %{a: a} do
    assert q(a, gdr("site.#{@ds}:alan") <> ".name", "published") == "Alan Turing"
    assert q(a, gdr("site.#{@ds}:alan") <> ".name", "drafts") == "Alan (draft)"
  end

  test "a field the caller may not read is absent, as through a deref", %{a: a} do
    doc = q(a, gdr("site.#{@ds}:alan"))
    assert doc["name"] == "Alan Turing"
    refute Map.has_key?(doc, "secret")
  end
end
