defmodule BarkparkWeb.MutatePatchByIdTest do
  @moduledoc """
  task-c6cbf346a07ff01e: Sanity's mutate API patches by id alone, as
  @sanity/client's `patch()` sends it: `{"patch": {"id": "x", "set": {...}}}`.
  Barkpark answered 422 for a patch without `type`. It now finds the type from
  the stored row and runs the typed patch, with the same checks.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "mpbi-ws-#{suffix}", name: "Patch by id"})
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

    raw = "mpbi-token-#{suffix}"
    {:ok, token} = Auth.create_token(raw, "mpbi writer", @dataset, ["read", "write"])
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

  defp title(id, scope) do
    {:ok, doc} = Content.get_document(id, "note", @dataset, scope)
    doc.title
  end

  test "a patch by id alone sets fields, on the draft and on the published row", %{
    conn: conn,
    slug: slug,
    raw: raw,
    scope: scope
  } do
    ok!(conn, slug, raw, [put_draft("p1")])

    resp =
      ok!(conn, slug, raw, [
        %{"patch" => %{"id" => "drafts.p1", "set" => %{"title" => "Draft set"}}}
      ])

    assert [%{"operation" => "update"}] = Jason.decode!(resp.resp_body)["results"]
    assert title("drafts.p1", scope) == "Draft set"

    ok!(conn, slug, raw, [%{"publish" => %{"id" => "p1", "type" => "note"}}])
    ok!(conn, slug, raw, [%{"patch" => %{"id" => "p1", "set" => %{"title" => "Published set"}}}])
    assert title("p1", scope) == "Published set" or title("drafts.p1", scope) == "Published set"
  end

  test "the other patch ops by id alone match the typed patch", %{
    conn: conn,
    slug: slug,
    raw: raw,
    scope: scope
  } do
    ok!(conn, slug, raw, [put_draft("p2"), put_draft("p2t")])
    ops = %{"unset" => ["title"], "setIfMissing" => %{"title" => "Back"}}
    ok!(conn, slug, raw, [%{"patch" => Map.put(ops, "id", "drafts.p2")}])

    ok!(conn, slug, raw, [%{"patch" => Map.merge(ops, %{"id" => "drafts.p2t", "type" => "note"})}])

    assert title("drafts.p2", scope) == title("drafts.p2t", scope)
  end

  test "a patch by id of a missing document is a 404, as a typed one", %{
    conn: conn,
    slug: slug,
    raw: raw
  } do
    resp = mutate(conn, slug, raw, [%{"patch" => %{"id" => "nope", "set" => %{"title" => "x"}}}])
    assert resp.status == 404
  end

  test "a read-only token is refused a typeless patch, as a typed one", %{
    conn: conn,
    slug: slug,
    raw: raw
  } do
    ok!(conn, slug, raw, [put_draft("p3")])
    ro = "mpbi-ro-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(ro, "mpbi reader", @dataset, ["read"])
    ws = Barkpark.Tenancy.get_workspace_by_slug(slug)
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id)

    typed =
      mutate(conn, slug, ro, [
        %{"patch" => %{"id" => "drafts.p3", "type" => "note", "set" => %{"title" => "x"}}}
      ])

    typeless =
      mutate(build_conn(), slug, ro, [
        %{"patch" => %{"id" => "drafts.p3", "set" => %{"title" => "x"}}}
      ])

    assert typed.status == 403
    assert typeless.status == typed.status
  end
end
