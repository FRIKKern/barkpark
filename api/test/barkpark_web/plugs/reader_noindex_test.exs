defmodule BarkparkWeb.Plugs.ReaderNoindexTest do
  @moduledoc """
  Papers are shareable, not searchable (am-hg-ai-crawler-stance): the public
  reader surfaces carry `x-robots-tag: noindex`; API surfaces must NOT — a
  blanket header on JSON endpoints would be scope creep with SEO side effects
  on any HTML a consumer proxies. Full-list pins, both directions.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.TenancyFixtures

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => "noindex-paper",
          "dataset" => @dataset,
          "body_html" => "<h1>Noindex Paper</h1>",
          "workspace_id" => ws.id,
          "project_id" => project.id
        })
      )

    %{paper: paper}
  end

  test "the flat reader 200 carries exactly noindex", %{conn: conn} do
    conn = get(conn, "/papers/noindex-paper")

    assert conn.status == 200
    assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
  end

  test "the conditional 304 carries it too (set before the halt)", %{conn: conn} do
    conn200 = get(conn, "/papers/noindex-paper")
    assert [etag] = get_resp_header(conn200, "etag")

    conn304 =
      scoped_conn()
      |> put_req_header("if-none-match", etag)
      |> get("/papers/noindex-paper")

    assert conn304.status == 304
    assert get_resp_header(conn304, "x-robots-tag") == ["noindex"]
  end

  test "API surfaces carry NO x-robots-tag", %{conn: conn} do
    for path <- ["/api/schemas", "/v1/openapi.json"] do
      conn = get(scoped_conn(), path)
      assert get_resp_header(conn, "x-robots-tag") == [], "expected no x-robots-tag on #{path}"
      refute conn.status == 404, "#{path} should exist for this pin to mean anything"
    end

    _ = conn
  end
end
