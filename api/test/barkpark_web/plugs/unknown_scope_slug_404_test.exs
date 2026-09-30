defmodule BarkparkWeb.Plugs.UnknownScopeSlug404Test do
  @moduledoc """
  task-69cd78907b82abf6: an unknown workspace or project slug on a scoped route
  answers a 404 that names the SLUG as the missing thing.

  On main, `GET /w/nosuchws/p/default/v1/data/query/production/post` answered
  `{code: not_found, message: "document not found", hint: "Check the document
  _id, type, and dataset in the URL"}`. No document was named, so a typo in
  `bp -w` sent the user hunting for a document id.

  The 404 status and the `not_found` code are unchanged, so clients keying on
  either are unaffected. The distinctions are kept:

    * a workspace that does not exist answers 404;
    * a workspace that exists but the caller may not enter still answers 403.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth

  setup %{conn: conn} do
    ws = create_workspace!("slug404-#{System.unique_integer([:positive])}")
    _proj = create_project!(ws, "real")
    raw = "slug404-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "slug404", "production", ["read"], ws.id)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> raw), ws: ws}
  end

  test "an unknown workspace slug names the workspace, not a document", %{conn: conn} do
    body =
      conn |> get("/w/nosuchws/p/default/v1/data/query/production/post") |> json_response(404)

    assert body["error"]["code"] == "not_found"
    assert body["error"]["message"] == ~s(workspace "nosuchws" not found)
    assert body["error"]["hint"] =~ "workspace slug"
    refute body["error"]["message"] =~ "document"
    refute body["error"]["hint"] =~ "document"
  end

  test "an unknown project slug names the project and its workspace", %{conn: conn, ws: ws} do
    body =
      conn
      |> get("/w/#{ws.slug}/p/nosuchproj/v1/data/query/production/post")
      |> json_response(404)

    assert body["error"]["code"] == "not_found"

    assert body["error"]["message"] ==
             ~s(project "nosuchproj" not found in workspace "#{ws.slug}")

    assert body["error"]["hint"] =~ "project slug"
    refute body["error"]["hint"] =~ "document"
  end

  test "CONTROL: a real document miss under a real scope still says document", %{
    conn: conn,
    ws: ws
  } do
    Barkpark.Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "production",
      workspace_id: ws.id
    )

    conn = get(conn, "/w/#{ws.slug}/p/real/v1/data/doc/production/post/nope")
    assert conn.status == 404
    error = Jason.decode!(conn.resp_body)["error"]
    assert error["code"] == "not_found"
    # The scope resolved, so the miss is the document's, and says so.
    assert error["message"] =~ "document"
    refute error["message"] =~ "workspace"
  end
end
