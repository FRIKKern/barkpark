defmodule BarkparkWeb.RelatedRouteTest do
  @moduledoc """
  GET /v1/data/related/:dataset/:id — route parity with backlinks (D70/D71):
  token/preview only (anon 404, existence-hiding), envelope
  `{result: {related, count}, syncTags}`, scoped mount byte-equivalent, and
  the `doc.related` manifest entry at auth_tier "read" — NEVER "none" (the
  proven doc.query silent-404 bug class).

  Docs are inserted directly, stamped with the seeded Default workspace +
  project so the flat (Default-scoped) and `/w/default/p/default` mounts see
  the same rows.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "related_route_test"
  @token "related-route-token"

  setup do
    Barkpark.Auth.create_token(@token, "dev", @dataset, ["read", "write", "admin"])

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    insert_doc!("rel-src", "Source Doc", weighted([{"elixir", 80}, {"search", 40}]), ws, proj)

    insert_doc!(
      "rel-cand",
      "Strong Candidate",
      weighted([{"elixir", 60}]) |> Map.put("main_tag", "elixir"),
      ws,
      proj
    )

    insert_doc!("rel-weak", "Weak Candidate", weighted([{"search", 10}]), ws, proj)

    :ok
  end

  defp weighted(pairs) do
    %{
      "tags" =>
        Enum.map(pairs, fn {tag, strength} ->
          %{"tag" => tag, "strength" => strength, "rationale" => "r"}
        end)
    }
  end

  defp insert_doc!(doc_id, title, content, ws, proj) do
    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "post",
      dataset: @dataset,
      title: title,
      status: "published",
      content: content,
      rev: Barkpark.Content.Writer.generate_rev(),
      workspace_id: ws.id,
      project_id: proj.id
    })
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  test "authed: 200 with the {result: {related, count}, syncTags} envelope, best first", %{
    conn: conn
  } do
    resp = conn |> authed() |> get("/v1/data/related/#{@dataset}/rel-src")
    assert resp.status == 200

    body = Jason.decode!(resp.resp_body)
    assert %{"result" => %{"related" => related, "count" => count}} = body
    assert count == length(related)
    assert body["syncTags"] == ["bp:ds:#{@dataset}:related:rel-src"]

    # main_tag-bonused strong match first: 0.6 + 0.5 vs 0.1.
    assert [first, second] = related
    assert first["doc_id"] == "rel-cand"
    assert first["type"] == "post"
    # The title COLUMN projection (content carries no usable title).
    assert first["title"] == "Strong Candidate"
    assert first["sources"] == ["tags"]
    assert_in_delta first["score"], 1.1, 0.0001

    assert [
             %{"tag" => "elixir", "src_strength" => 80, "cand_strength" => 60}
           ] = first["shared_tags"]

    assert second["doc_id"] == "rel-weak"
    assert_in_delta second["score"], 0.1, 0.0001
  end

  test "without a token, related 404s (existence-hiding, like backlinks)", %{conn: conn} do
    resp = get(conn, "/v1/data/related/#{@dataset}/rel-src")
    assert resp.status == 404
  end

  test "scoped mount /w/default/p/default mirrors the flat read", %{conn: conn} do
    resp =
      conn
      |> authed()
      |> get("/w/default/p/default/v1/data/related/#{@dataset}/rel-src")

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    ids = Enum.map(body["result"]["related"], & &1["doc_id"])
    assert ids == ["rel-cand", "rel-weak"]
  end

  test "?limit narrows the ask", %{conn: conn} do
    resp = conn |> authed() |> get("/v1/data/related/#{@dataset}/rel-src?limit=1")
    assert resp.status == 200

    body = Jason.decode!(resp.resp_body)
    assert body["result"]["count"] == 1
    assert [%{"doc_id" => "rel-cand"}] = body["result"]["related"]
  end

  test "an unknown source id is an empty related list, not an error", %{conn: conn} do
    resp = conn |> authed() |> get("/v1/data/related/#{@dataset}/no-such-doc")
    assert resp.status == 200

    body = Jason.decode!(resp.resp_body)
    assert body["result"]["related"] == []
    assert body["result"]["count"] == 0
  end

  test "manifest: doc.related is GET /v1/data/related/:dataset/:id at auth_tier read — NEVER none (D71)",
       %{conn: conn} do
    manifest =
      conn
      |> authed()
      |> get("/v1/capabilities")
      |> json_response(200)

    cmd = Enum.find(manifest["commands"], &(&1["id"] == "doc.related"))

    assert cmd != nil, "doc.related not found in manifest"
    assert cmd["http"]["method"] == "GET"
    assert cmd["http"]["path_template"] == "/v1/data/related/:dataset/:id"
    # The endpoint 404s anon, so it is read-tier; "none" would drop the bearer
    # and silently 404 private-schema reads (the doc.query bug class).
    assert cmd["auth_tier"] == "read"
    assert "id" in Enum.map(cmd["args"], & &1["name"])
    assert cmd["scoped_prefix"] == "/w/:workspace_slug/p/:project_slug"
  end
end
