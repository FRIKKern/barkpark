defmodule BarkparkWeb.GraphPrivateReferenceEdgeTest do
  @moduledoc """
  task-855e091e60d5c008 — the corpus graph built edges from reference fields the caller
  may not read.

  `Content.Edges.extract_edges/2` walks every `reference` /
  `arrayOf<reference>` field of a document's schema and emits an edge whose
  `kind` IS the field name, with the referenced id as its target (a target
  outside the node set becomes a phantom node titled with that id). It never
  consulted field visibility, so a field declared `private` — redacted from
  the same document on `/v1/data/doc` — still told a `public-read` caller on
  `GET /v1/graph` (and the anonymous `/finder`) that the field exists, that it
  is set, and what it points at.

  The two public corpus doors now pass the caller (`:visible_to`), and a
  reference field `Envelope.field_readable?/3` refuses yields no edge. The
  EdgeProjector, which stores the full graph for internal use, passes no
  caller and is unchanged.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"
  @type_name "gpre-post"

  setup do
    {ws, proj} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => @type_name,
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "related", "type" => "reference", "refType" => @type_name},
            %{
              "name" => "secret_source",
              "type" => "reference",
              "refType" => @type_name,
              "private" => true
            }
          ]
        },
        @dataset,
        scope
      )

    publish!("gpre-target", %{}, scope)
    publish!("gpre-informant", %{}, scope)

    publish!(
      "gpre-source",
      %{
        "related" => %{"_ref" => "gpre-target"},
        "secret_source" => %{"_ref" => "gpre-informant"}
      },
      scope
    )

    pr = "gpre-public-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(pr, "gpre public", @dataset, ["public-read"], ws.id)
    admin = "gpre-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "gpre admin", @dataset, ["read", "write", "admin"], ws.id)

    %{public: pr, admin: admin}
  end

  defp publish!(id, content, scope) do
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => "drafts." <> id, "title" => id, "content" => content},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(id, @type_name, @dataset, scope)
  end

  defp edge_kinds(token) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/v1/graph?dataset=#{@dataset}&types=#{@type_name}")
    |> json_response(200)
    |> Map.fetch!("edges")
    |> Enum.filter(&(&1["from_id"] == "gpre-source"))
    |> Enum.map(& &1["kind"])
    |> Enum.sort()
  end

  test "PUBLIC-READ /v1/graph carries no edge for a private reference field", %{public: token} do
    # CONTROL: the public reference still draws its edge.
    assert edge_kinds(token) == ["related"]
  end

  test "CONTROL: an admin still sees both edges", %{admin: token} do
    assert edge_kinds(token) == ["related", "secret_source"]
  end
end
