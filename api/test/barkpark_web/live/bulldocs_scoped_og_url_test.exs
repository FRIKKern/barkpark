defmodule BarkparkWeb.BulldocsScopedOgUrlTest do
  @moduledoc """
  task-01a69b46651f43fc — a paper's share card names the reader that serves it.

  `/papers/:slug` serves only the Default workspace's papers. A paper in any
  other workspace is read at `/w/:ws/p/:proj/papers/:slug`, yet its card
  (og:url, JSON-LD url) said `/papers/<slug>`, a 404. The write-time card
  stamps `/papers/<slug>`; the reader now supplies its own path, and
  `ShareMeta.manifest/4` lets it win over the stamped one.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, TenancyFixtures}
  alias BarkparkWeb.ShareMeta

  @dataset "production"

  setup do
    {ws_a, project_a} = TenancyFixtures.ensure_default_scope!()
    ws_b = TenancyFixtures.create_workspace!()
    project_b = TenancyFixtures.create_project!(ws_b)
    Barkpark.LabelFixtures.register_tags!(@dataset)
    Barkpark.SharingFixtures.snapshot_shares!()

    Barkpark.SharingFixtures.plant_shares!(
      "#{ws_b.slug}/#{project_b.slug}/#{@dataset}:papers:read"
    )

    %{ws_a: ws_a, project_a: project_a, ws_b: ws_b, project_b: project_b}
  end

  defp paper!(ws, project) do
    slug = "og-scope-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => @dataset,
          "workspace_id" => ws.id,
          "project_id" => project.id,
          "blocks" => [
            %{
              "id" => "p1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Body."}]
            }
          ]
        })
      )

    slug
  end

  defp og_url(html) do
    [url] = Regex.run(~r/property="og:url" content="([^"]+)"/, html, capture: :all_but_first)
    URI.parse(url).path
  end

  test "paper_reader_path/3: /papers for Default (or no scope), scoped for any other workspace",
       ctx do
    assert ShareMeta.paper_reader_path(ctx.ws_a, ctx.project_a, "x") == "/papers/x"

    assert ShareMeta.paper_reader_path(ctx.ws_b, ctx.project_b, "x") ==
             "/w/#{ctx.ws_b.slug}/p/#{ctx.project_b.slug}/papers/x"

    assert ShareMeta.paper_reader_path(nil, nil, "x") == "/papers/x"
  end

  test "manifest/4 lets the reader's path win over a stamped card url" do
    content = %{"preview" => %{"url" => "/papers/x", "title" => "X", "type" => "paper"}}
    assert ShareMeta.manifest(content, "/w/a/p/b/papers/x", "paper")["url"] == "/w/a/p/b/papers/x"
  end

  test "a non-Default workspace's paper unfurls to its scoped reader path", %{conn: conn} = ctx do
    slug = paper!(ctx.ws_b, ctx.project_b)
    path = "/w/#{ctx.ws_b.slug}/p/#{ctx.project_b.slug}/papers/#{slug}"
    html = conn |> get(path) |> html_response(200)
    assert og_url(html) == path
  end

  test "a Default paper still unfurls to /papers/<slug>", %{conn: conn} = ctx do
    slug = paper!(ctx.ws_a, ctx.project_a)
    html = conn |> get("/papers/#{slug}") |> html_response(200)
    assert og_url(html) == "/papers/#{slug}"
  end
end
