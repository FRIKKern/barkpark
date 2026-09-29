defmodule BarkparkWeb.Integration.StudioSessionScopedReadsTest do
  @moduledoc """
  Gyldendal E1.9 (task-f355110d81401e8b) — a Studio browser session reads the
  scoped REST surface of its own workspace.

  Measured live on gyl 0.2.26.2579 (2026-09-10): signed into the Studio with a
  member token (the LiveView opens every document of workspace
  `gyldendal-agency-twin`), a same-origin `fetch` from the Studio page to
  `/w/gyldendal-agency-twin/p/default/v1/data/doc/production/author/author-34878`
  answered `403 not_a_member`, while `/v1/media/production` and
  `/v1/data/search/production` next door — same cookie — answered 200, and the
  same doc URL with the token as a Bearer header answered 200.

  The doc/query reads ride `:shared_docs_api`, which ran plain `OptionalToken`
  and so never looked at the session cookie; the media and search reads ride
  `:scoped_api`, which admits the cookie on GET/HEAD. `bp-reference-picker`
  resolves a pill's title through exactly that doc read, so every reference
  pill in a non-default workspace showed the target's id.

  Contract pinned here, on the routed pipelines:

    1. SESSION READS — a conn carrying only `session["api_token"]` of a member
       token reads the scoped doc AND the scoped query route (200), like the
       scoped media list and search it could already read.
    2. THE BEARER ARM IS UNCHANGED — the same token as a Bearer header reads
       all four.
    3. FAIL-CLOSED IS UNCHANGED — an anonymous conn is refused `not_a_member`
       on the doc route; a session whose token belongs to a SIBLING workspace
       is refused `not_a_member` too (membership, not merely authentication).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}

  @dataset "production"

  setup do
    ws = create_workspace!("e19-ws")
    project = create_project!(ws, "e19-proj")
    scope = [workspace_id: ws.id, project_id: project.id]

    sibling_ws = create_workspace!("e19-sibling")
    _sibling_project = create_project!(sibling_ws, "e19-sibling-proj")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Forfatter",
          "visibility" => "public",
          "fields" => [%{"name" => "name", "title" => "Navn", "type" => "string"}],
          "list_preview" => %{"title" => "name"}
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "author",
        %{"_id" => "author-1", "title" => "Sverre Graff", "name" => "Sverre Graff"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("author-1", "author", @dataset, scope)

    suffix = System.unique_integer([:positive])
    member_raw = "e19-member-#{suffix}"
    sibling_raw = "e19-sibling-#{suffix}"

    {:ok, _} = Auth.create_token(member_raw, "e19-member", @dataset, ["read", "write"], ws.id)

    {:ok, _} =
      Auth.create_token(sibling_raw, "e19-sibling", @dataset, ["read", "write"], sibling_ws.id)

    %{ws: ws, project: project, member: member_raw, sibling: sibling_raw}
  end

  defp scoped(ws, project, suffix), do: "/w/#{ws.slug}/p/#{project.slug}/v1/#{suffix}"

  defp session_conn(raw), do: Plug.Test.init_test_session(scoped_conn(), %{"api_token" => raw})

  defp bearer_conn(raw), do: put_req_header(scoped_conn(), "authorization", "Bearer " <> raw)

  defp doc_path(ws, project), do: scoped(ws, project, "data/doc/#{@dataset}/author/author-1")
  defp query_path(ws, project), do: scoped(ws, project, "data/query/#{@dataset}/author")
  defp search_path(ws, project), do: scoped(ws, project, "data/search/#{@dataset}?q=Sverre")
  defp media_path(ws, project), do: scoped(ws, project, "media/#{@dataset}?limit=1")

  describe "a Studio session (cookie only, no Bearer header)" do
    test "reads the scoped doc route — the read bp-reference-picker resolves a pill title through",
         %{ws: ws, project: project, member: member} do
      conn = get(session_conn(member), doc_path(ws, project))

      assert conn.status == 200,
             "session doc read answered #{conn.status}: #{conn.resp_body}"

      assert %{"result" => %{"_id" => "author-1", "title" => "Sverre Graff"}} =
               json_response(conn, 200)
    end

    test "reads the scoped query route", %{ws: ws, project: project, member: member} do
      conn = get(session_conn(member), query_path(ws, project))

      assert conn.status == 200,
             "session query read answered #{conn.status}: #{conn.resp_body}"
    end

    test "control: the scoped search and media reads it could already do stay 200",
         %{ws: ws, project: project, member: member} do
      for path <- [search_path(ws, project), media_path(ws, project)] do
        conn = get(session_conn(member), path)
        assert conn.status == 200, "#{path} answered #{conn.status}: #{conn.resp_body}"
      end
    end
  end

  describe "the Bearer arm is unchanged" do
    test "the same token as a header reads doc, query, search and media",
         %{ws: ws, project: project, member: member} do
      for path <- [
            doc_path(ws, project),
            query_path(ws, project),
            search_path(ws, project),
            media_path(ws, project)
          ] do
        conn = get(bearer_conn(member), path)
        assert conn.status == 200, "#{path} answered #{conn.status}: #{conn.resp_body}"
      end
    end
  end

  describe "fail-closed is unchanged" do
    test "an anonymous conn is refused not_a_member on the doc route", %{
      ws: ws,
      project: project
    } do
      conn = get(scoped_conn(), doc_path(ws, project))
      assert conn.status == 403
      assert %{"error" => %{"reason" => "not_a_member"}} = json_response(conn, 403)
    end

    test "a session whose token belongs to a sibling workspace is refused not_a_member",
         %{ws: ws, project: project, sibling: sibling} do
      conn = get(session_conn(sibling), doc_path(ws, project))
      assert conn.status == 403
      assert %{"error" => %{"reason" => "not_a_member"}} = json_response(conn, 403)
    end
  end
end
