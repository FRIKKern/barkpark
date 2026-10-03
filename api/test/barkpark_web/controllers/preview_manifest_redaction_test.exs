defmodule BarkparkWeb.PreviewManifestRedactionTest do
  @moduledoc """
  task-84c95acb380f41e4 (item 1 of task-11acb383532d6169) — the write-time `content["preview"]` manifest
  copied private fields past the redaction boundary.

  `PortableDoc.Projection` stamps `Barkpark.Preview.project/3` over the FULL
  content on every write: `preview.description` is the first of
  `excerpt` / `description` / `summary`, and `preview.extensions` carries
  `authors`, `tags`, `section`, `published_time` (papers), `assignee`,
  `priority` … (tasks). `Envelope.render/3` drops a private field's own key but
  knew nothing about this derived copy, so an anonymous `GET /v1/data/doc` on a
  paper whose schema declares `description` private returned the description
  anyway — inside `preview`.

  Envelope now drops every manifest entry derived from a field the caller may
  not read (`Barkpark.Preview.derived_from/0` names the sources). No query.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @ds "production"
  @slug "pmr-paper"
  @secret "Embargoed acquisition summary for pmr"

  setup do
    scope = [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "description", "type" => "text", "private" => true}
          ]
        },
        @ds,
        scope
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          description: @secret,
          blocks: [
            %{"id" => "title", "type" => "heading", "level" => 1, "text" => "PMR"},
            %{
              "id" => "p",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Public lead paragraph."}]
            }
          ]
        })
      )

    admin = "pmr-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "pmr admin", @ds, ["read", "write", "admin"])
    %{admin: admin}
  end

  defp doc(conn) do
    conn
    |> get("/v1/data/doc/#{@ds}/paper/#{@slug}")
    |> json_response(200)
    |> Map.fetch!("result")
  end

  test "ANONYMOUS: neither the field nor its preview copy carries the private value", %{
    conn: conn
  } do
    result = doc(conn)

    # CONTROL: the manifest itself is served (its title is not private).
    assert is_map(result["preview"]), "expected a preview manifest, got #{inspect(result)}"
    refute Map.has_key?(result, "description")
    refute Jason.encode!(result["preview"]) =~ @secret
  end

  test "CONTROL: an admin still gets the preview description", %{conn: conn, admin: admin} do
    result = conn |> put_req_header("authorization", "Bearer " <> admin) |> doc()
    assert result["preview"]["description"] =~ "Embargoed acquisition summary"
  end
end
