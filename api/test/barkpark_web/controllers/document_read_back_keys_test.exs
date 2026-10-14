defmodule BarkparkWeb.DocumentReadBackKeysTest do
  @moduledoc """
  task-76ea5c8f370a271e: an imported gyl article read back with a key,
  `article_audit_suggestions`, that the importer said it never wrote. The
  document's first revision shows the import's own `create` carried that key
  and `_system`: both are fields of the source Sanity document, written there
  by the gyldendal.no Studio's article-audit plugin and by Sanity. Barkpark
  added neither.

  This pins the read-back contract in docs/api-v1.md §3: a document reads back
  with the envelope keys, `title`, and exactly the content keys the client
  wrote. Barkpark adds no content key of its own on create, publish or patch.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  # docs/api-v1.md §3, "Document envelope keys".
  @envelope ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt)

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "drbk-ws-#{suffix}", name: "Read back"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "article",
          "title" => "Article",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "preamble", "type" => "text"},
            %{"name" => "mainTag", "type" => "reference", "refType" => "tag"}
          ]
        },
        @dataset,
        scope
      )

    raw = "drbk-token-#{suffix}"
    {:ok, token} = Auth.create_token(raw, "drbk writer", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id)

    {:ok, slug: ws.slug, raw: raw}
  end

  defp authed(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp mutate(conn, slug, raw, mutations) do
    resp =
      conn
      |> authed(raw)
      |> post(
        "/w/#{slug}/p/default/v1/data/mutate/#{@dataset}",
        Jason.encode!(%{"mutations" => mutations})
      )

    assert resp.status == 200, "#{resp.status} #{resp.resp_body}"
    resp
  end

  defp read(conn, slug, raw, id) do
    resp =
      conn
      |> authed(raw)
      |> get("/w/#{slug}/p/default/v1/data/doc/#{@dataset}/article/#{id}?perspective=raw")

    assert resp.status == 200, "#{resp.status} #{resp.resp_body}"
    Jason.decode!(resp.resp_body)["result"]
  end

  defp added_keys(doc, written) do
    doc
    |> Map.keys()
    |> Kernel.--(@envelope ++ ["title" | Map.keys(written)])
  end

  # The shape of the gyl article's first revision, trimmed: content fields, a
  # field nobody shows in the source Studio, and Sanity's own `_system`.
  @written %{
    "preamble" => "Ingress",
    "mainTag" => %{"_type" => "reference", "_ref" => "tag-1", "_weak" => true},
    "article_audit_suggestions" => ~s({"_type":"article_audit_suggestions","suggestions":[]}),
    "_system" => %{"base" => %{"id" => "drbk-1", "rev" => "XM3QO0aQ3DaWpIA9vI2iop"}}
  }

  test "a created, published and patched document reads back with only the keys the client wrote",
       %{conn: conn, slug: slug, raw: raw} do
    doc = Map.merge(@written, %{"_id" => "drbk-1", "_type" => "article", "title" => "Taco"})

    mutate(conn, slug, raw, [%{"createOrReplace" => doc}])
    draft = read(conn, slug, raw, "drafts.drbk-1")
    assert added_keys(draft, @written) == []
    assert draft["article_audit_suggestions"] == @written["article_audit_suggestions"]
    assert draft["_system"] == @written["_system"]

    mutate(conn, slug, raw, [%{"publish" => %{"id" => "drbk-1", "type" => "article"}}])
    published = read(conn, slug, raw, "drbk-1")
    assert added_keys(published, @written) == []

    mutate(conn, slug, raw, [
      %{"patch" => %{"id" => "drbk-1", "type" => "article", "set" => %{"preamble" => "Ny"}}}
    ])

    patched = read(conn, slug, raw, "drafts.drbk-1")
    assert added_keys(patched, @written) == []
    assert patched["preamble"] == "Ny"
  end

  test "a document written without the gyl keys does not gain them", %{
    conn: conn,
    slug: slug,
    raw: raw
  } do
    written = %{"preamble" => "Ingress"}
    doc = Map.merge(written, %{"_id" => "drbk-2", "_type" => "article", "title" => "Plain"})

    mutate(conn, slug, raw, [%{"createOrReplace" => doc}])
    mutate(conn, slug, raw, [%{"publish" => %{"id" => "drbk-2", "type" => "article"}}])

    published = read(conn, slug, raw, "drbk-2")
    assert added_keys(published, written) == []
    refute Map.has_key?(published, "article_audit_suggestions")
    refute Map.has_key?(published, "_system")
  end
end
