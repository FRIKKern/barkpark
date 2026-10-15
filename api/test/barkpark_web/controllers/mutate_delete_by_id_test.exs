defmodule BarkparkWeb.MutateDeleteByIdTest do
  @moduledoc """
  task-645fcbef64fac473: Sanity's mutate API deletes by id alone, as in
  `{"delete": {"id": "drafts.<id>"}}`. Barkpark answered 422
  `validation_failed` "missing: type", so delete code copied from a Sanity app
  broke. A delete without a type now finds the type from the stored row and
  runs the typed delete.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "mdbi-ws-#{suffix}", name: "Delete by id"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "note",
          "title" => "Note",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    raw = "mdbi-token-#{suffix}"
    {:ok, token} = Auth.create_token(raw, "mdbi writer", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id)

    {:ok, slug: ws.slug, raw: raw, scope: scope}
  end

  defp mutate(conn, slug, raw, mutations) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/w/#{slug}/p/default/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{"mutations" => mutations})
    )
  end

  defp ok!(conn, slug, raw, mutations) do
    resp = mutate(conn, slug, raw, mutations)
    assert resp.status == 200, "#{resp.status} #{resp.resp_body}"
    resp
  end

  defp put_draft(id), do: %{"createOrReplace" => %{"_type" => "note", "_id" => id, "title" => id}}

  defp exists?(id, scope), do: match?({:ok, _}, Content.get_document(id, "note", @dataset, scope))

  test "a draft deletes by its drafts. id alone, and the published row stays", %{
    conn: conn,
    slug: slug,
    raw: raw,
    scope: scope
  } do
    ok!(conn, slug, raw, [put_draft("n1"), %{"publish" => %{"id" => "n1", "type" => "note"}}])
    ok!(conn, slug, raw, [put_draft("n1")])
    assert exists?("drafts.n1", scope)

    resp = ok!(conn, slug, raw, [%{"delete" => %{"id" => "drafts.n1"}}])

    assert [%{"operation" => "delete"}] = Jason.decode!(resp.resp_body)["results"]
    refute exists?("drafts.n1", scope)
    assert exists?("n1", scope)
  end

  test "a bare id alone deletes the document", %{conn: conn, slug: slug, raw: raw, scope: scope} do
    ok!(conn, slug, raw, [put_draft("n2"), %{"publish" => %{"id" => "n2", "type" => "note"}}])

    ok!(conn, slug, raw, [%{"delete" => %{"id" => "n2"}}])

    refute exists?("n2", scope)
    refute exists?("drafts.n2", scope)
  end

  test "a draft-only document deletes by its bare id alone", %{
    conn: conn,
    slug: slug,
    raw: raw,
    scope: scope
  } do
    ok!(conn, slug, raw, [put_draft("n3")])

    ok!(conn, slug, raw, [%{"delete" => %{"id" => "n3"}}])

    refute exists?("drafts.n3", scope)
  end

  test "an id that matches no document answers 404", %{conn: conn, slug: slug, raw: raw} do
    resp = mutate(conn, slug, raw, [%{"delete" => %{"id" => "drafts.missing"}}])
    assert resp.status == 404, "#{resp.status} #{resp.resp_body}"
  end

  test "a document in another workspace is not found", %{conn: conn, slug: slug, raw: raw} do
    suffix = System.unique_integer([:positive])
    {:ok, other} = Tenancy.create_workspace(%{slug: "mdbi-other-#{suffix}", name: "Other"})
    {:ok, other_proj} = Tenancy.create_project(other, %{slug: "default", name: "Default"})
    other_scope = [workspace_id: other.id, project_id: other_proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "note",
          "title" => "Note",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        other_scope
      )

    {:ok, _} =
      Content.create_document(
        "note",
        %{"doc_id" => "foreign", "title" => "x"},
        @dataset,
        other_scope
      )

    assert exists?("drafts.foreign", other_scope)

    resp = mutate(conn, slug, raw, [%{"delete" => %{"id" => "drafts.foreign"}}])

    assert resp.status == 404, "#{resp.status} #{resp.resp_body}"
    assert exists?("drafts.foreign", other_scope)
  end

  test "a delete with neither id nor type still names both missing keys", %{
    conn: conn,
    slug: slug,
    raw: raw
  } do
    resp = mutate(conn, slug, raw, [%{"delete" => %{}}])
    assert resp.status == 422
    assert Jason.decode!(resp.resp_body)["error"]["details"]["missing"] == ["id", "type"]
  end
end
