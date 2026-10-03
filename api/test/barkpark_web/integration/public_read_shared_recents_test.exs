defmodule BarkparkWeb.Integration.PublicReadSharedRecentsTest do
  @moduledoc """
  task-e736ea8596e1dede — a `public-read` site token is ONE credential shipped in a
  site's JavaScript to every visitor. `SearchIntel.actor_key/1` filed its
  searches under `token:<id>` and read `recent` suggestions back by the same
  key, so every visitor of the site shared one recent-search bucket: visitor B
  opening the search box was shown visitor A's queries verbatim.

  The flat search routes refuse `public-read` (`PublicRead`), but the scoped
  `/w/:ws/p/:proj` mirror does not mount that plug, so the token reaches both
  the search and the suggestions doors there.

  A tokenless caller already gets this right: no `x-bp-search-client` header
  means the shared `"anon"` bucket, which `recent_queries/6` answers with `[]`.
  A public-read token is the same public audience (`SearchIntel.audience/1`)
  and now gets the same answer. With the per-browser header a visitor still
  gets their OWN recents, namespaced under the token.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}

  @dataset "production"

  setup do
    ws = create_workspace!("prsr-ws")
    proj = create_project!(ws, "prsr-proj")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document("post", %{"_id" => "rs-1", "title" => "Gazebo"}, @dataset, scope)

    {:ok, _} = Content.publish_document("rs-1", "post", @dataset, scope)

    raw = "prsr-site-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "site token", @dataset, ["public-read"], ws.id)

    %{base: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/search/#{@dataset}", token: raw}
  end

  defp site(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
  defp browser(conn, id), do: put_req_header(conn, "x-bp-search-client", id)

  defp recent(conn, base) do
    conn
    |> get(base <> "/suggestions")
    |> json_response(200)
    |> get_in(["result", "recent"])
    |> Kernel.||([])
    |> Enum.map(& &1["query"])
  end

  test "visitor B does not see visitor A's searches through the shared site token",
       %{base: base, token: token} do
    # Visitor A searches with the site token and no per-browser id.
    scoped_conn()
    |> site(token)
    |> get(base <> "?q=gazebo%20divorce%20lawyer")
    |> json_response(200)

    # Visitor B opens the search box with the same site token.
    refute "gazebo divorce lawyer" in recent(scoped_conn() |> site(token), base)
  end

  test "CONTROL: one browser still gets its own recents under its per-browser id",
       %{base: base, token: token} do
    scoped_conn()
    |> site(token)
    |> browser("browser-a-uuid")
    # A client-tracked browser records only a COMMITTED search (not keystrokes).
    |> put_req_header("x-bp-search-record", "1")
    |> get(base <> "?q=gazebo")
    |> json_response(200)

    assert "gazebo" in recent(scoped_conn() |> site(token) |> browser("browser-a-uuid"), base)
    refute "gazebo" in recent(scoped_conn() |> site(token) |> browser("browser-b-uuid"), base)
  end
end
