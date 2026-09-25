defmodule BarkparkWeb.ScopedPaperControllerReaderHtmlTest do
  @moduledoc """
  `ScopedPaperController.show/2` serves the reader HTML, not the stored
  `body_html` cache (pt-backlog-kill-the-body-html-cache).

  The controller is retired from routing (router.ex mounts `BulldocsLive` at
  the scoped `/papers/:slug`), so it is called directly here with a conn that
  carries the scope `ResolveWorkspace` would have assigned. It used to read
  `content["body_html"]` with a bare `Map.get/2`: no render, no sanitizer, no
  visibility redaction. If it is ever routed again, it must answer what the
  live reader answers.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, Repo}
  alias BarkparkWeb.ScopedPaperController

  @dataset "production"

  setup %{conn: conn} do
    ws = Barkpark.TenancyFixtures.create_workspace!("scoped-reader-html-ws")
    project = Barkpark.TenancyFixtures.create_project!(ws, "scoped-reader-html-proj")

    conn =
      conn
      |> bypass_through(BarkparkWeb.Router, [:browser])
      |> get("/")
      |> assign(:current_workspace, ws)
      |> assign(:current_project, project)

    {:ok, conn: conn, ws: ws, project: project}
  end

  defp upsert!(ws, project, slug, attrs) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(
          Map.merge(
            %{
              "slug" => slug,
              "dataset" => @dataset,
              "workspace_id" => ws.id,
              "project_id" => project.id
            },
            attrs
          )
        )
      )

    paper
  end

  # Through the controller's own plug pipeline (`call/2`), so the view and
  # format `use BarkparkWeb, :controller` sets up are in place.
  defp show(conn, slug) do
    conn
    |> Map.put(:params, %{"slug" => slug})
    |> Map.put(:path_params, %{"slug" => slug})
    |> ScopedPaperController.call(ScopedPaperController.init(:show))
  end

  defp plant_cache!(paper, html) do
    paper
    |> Ecto.Changeset.change(
      content: paper.content |> Map.put("body_html", html) |> Map.delete("body_html_sv")
    )
    |> Repo.update!()
  end

  test "a blocks paper renders from its blocks, not from a planted cache", %{
    conn: conn,
    ws: ws,
    project: project
  } do
    slug = "scoped-reader-blocks-#{System.unique_integer([:positive])}"

    paper =
      upsert!(ws, project, slug, %{
        "blocks" => [
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Prose from the blocks"}]
          }
        ]
      })

    _ = plant_cache!(paper, "<p>CACHE-ONLY-MARKER</p>")

    body = conn |> show(slug) |> html_response(200)

    assert body =~ "Prose from the blocks"
    refute body =~ "CACHE-ONLY-MARKER"
  end

  test "a legacy HTML-only paper serves its sanitized body_html", %{
    conn: conn,
    ws: ws,
    project: project
  } do
    slug = "scoped-reader-legacy-#{System.unique_integer([:positive])}"
    paper = upsert!(ws, project, slug, %{"body_html" => "<p>Legacy prose</p>"})
    _ = plant_cache!(paper, ~s|<p>Legacy prose</p><script>alert("x")</script>|)

    body = conn |> show(slug) |> html_response(200)

    assert body =~ "Legacy prose"
    refute body =~ ~s|alert("x")|
  end

  test "a paper the reader refuses answers 422 instead of the cache", %{
    conn: conn,
    ws: ws,
    project: project
  } do
    slug = "scoped-reader-empty-#{System.unique_integer([:positive])}"
    paper = upsert!(ws, project, slug, %{"body_html" => "<p>Legacy prose</p>"})
    _ = plant_cache!(paper, "<script>steal()</script>")

    conn = show(conn, slug)
    assert conn.status == 422
    refute conn.resp_body =~ "steal()"
  end

  test "a missing slug is 404", %{conn: conn} do
    conn = show(conn, "scoped-reader-absent")
    assert conn.status == 404
  end
end
