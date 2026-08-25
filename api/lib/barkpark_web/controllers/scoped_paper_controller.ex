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
        # Social-share head (preview-contract pc-w2): the `:bulldocs` root layout
        # reads `:preview` + `:page_title` (kept in sync with BulldocsLive even
        # though this dead-render controller is currently retired from routing —
        # see the backlinks note below).
        preview =
          BarkparkWeb.ShareMeta.manifest(
            paper.content || %{},
            "/papers/#{slug}",
            "paper",
            paper.title
          )

        conn
        |> put_root_layout(html: {BarkparkWeb.Layouts, :bulldocs})
        |> put_layout(false)
        |> render(:show,
          article?: paper_article?(paper),
          body_html: paper_body_html(paper),
          preview: preview,
          page_title: preview["title"],
          # Related Paper cards — papers that link TO this one, rendered as a
          # server-side section AFTER the body. Powered by the INDEXED engine
          # `Content.Graph.reverse_referencers/2` (over `content_edges`), scoped
          # exactly like the read so it only sees papers the caller may read.
          # Empty string when nothing links → the template omits the section.
          #
          # NOTE: this dead-render controller is currently RETIRED from routing
          # (router.ex mounts BulldocsLive at the scoped
          # `live("/papers/:slug", BulldocsLive, :index)` reader too); the
          # live section is wired in `BarkparkWeb.BulldocsLive`. The assign is
          # kept here so the controller + its template stay self-consistent if it
          # is ever re-routed.
          backlinks_html:
            BarkparkWeb.PaperBacklinks.section_html(
              Content.Graph.reverse_referencers(
                Content.published_id(paper.doc_id),
                [dataset: @dataset] ++ scope_opts(conn)
              )
            ),
          # "Driven tasks" (lvw-t8) — same parity note as backlinks_html above.
          driven_tasks_html:
            BarkparkWeb.PaperTasks.section_html(
              Barkpark.Tasks.driven_tasks(
                paper.doc_id,
                [dataset: @dataset] ++ scope_opts(conn)
              )
            ),
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
