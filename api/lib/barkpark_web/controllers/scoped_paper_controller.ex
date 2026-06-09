defmodule BarkparkWeb.ScopedPaperController do
  @moduledoc """
  Read-only, workspace/project-SCOPED paper reader at
  `GET /w/:workspace_slug/p/:project_slug/papers/:slug` (P1b).

  Unlike the public `/papers/:slug` LiveView (`BarkparkWeb.BulldocsLive`, pinned
  to the seeded Default workspace), this controller renders a paper scoped to
  the workspace/project the routing layer resolved into `conn.assigns`
  (`current_workspace` / `current_project`) — fetched via
  `Barkpark.Content.get_paper/3` threaded with `ScopeHelpers.scope_opts/1`, so a
  same-slug paper in another tenant is never reachable here.

  Whether this scope is reachable AT ALL by an anonymous caller is decided
  UPSTREAM by `BarkparkWeb.Plugs.RequireShareScope`: only a scope explicitly
  shared for the `:papers` surface (via `Barkpark.Sharing`) reaches this action
  without workspace membership. With no share, `ResolveWorkspace`'s membership
  gate runs first and a non-member never gets here.

  Static, server-rendered HTML — no LiveView, no streaming. The cached
  `content["body_html"]` (rendered at ingest time) is wrapped in the
  full-document `:bulldocs` root layout's `.bp-paper-shell` shell. A missing
  slug 404s; it never leaks the existence of a paper in another scope.
  """

  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content

  # The route carries no `:dataset` segment, so reads target the canonical
  # public dataset — the same one `Barkpark.Sharing` defaults a share scope to.
  @dataset "production"

  def show(conn, %{"slug" => slug}) do
    case Content.get_paper(slug, @dataset, scope_opts(conn)) do
      %Content.Document{} = paper ->
        conn
        |> put_root_layout(html: {BarkparkWeb.Layouts, :bulldocs})
        |> put_layout(false)
        |> render(:show,
          article?: paper_article?(paper),
          body_html: paper_body_html(paper),
          slug: slug
        )

      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(BarkparkWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  # Cached, ingest-time-rendered HTML fragment (no <html>/<body> wrapper). The
  # template wraps it in the paper shell.
  defp paper_body_html(%{content: content}), do: Map.get(content || %{}, "body_html") || ""

  # Article papers get the `.bp-paper-article` chrome class (parchment + serif),
  # mirroring BulldocsLive's `@article?` toggle.
  defp paper_article?(%{content: content}), do: Map.get(content || %{}, "style") == "article"
end
