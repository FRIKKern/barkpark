defmodule BarkparkWeb.BulldocsEmailController do
  @moduledoc """
  `GET /papers/:slug/email` — the paper as the EXACT email byte stream.

  Papers get sent as email (digests, plan shares); until now the only way to
  see that rendering was to send one. This serves the same published paper the
  `/papers/:slug` reader shows, composed with the `:email` style — every style
  inline (clients strip `<style>`; Outlook is the contract), the evergreen
  email palette, task widgets resolved live (the same
  `Papers.resolve_tasks_in_blocks` + default-workspace scope as the reader) —
  wrapped in `Render.render_document/2`'s doctype envelope. What you see IS
  what a mail backend should send.

  It is mounted beside the public, dataset, and scoped Paper readers and shares
  each route's visibility/capability contract; a missing/unpublished slug is a
  plain 404. Historical body_html is sanitized before it enters the same card
  chrome, so legacy Papers remain readable without becoming an HTML bypass.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Render

  # @sobelow_skip — XSS.SendResp (send_resp/3) is a false-positive: the body is
  # `Render.render_document/2` output or sanitizer-filtered legacy HTML inside
  # `Render.render_html_document/2`. `slug` selects the record; it is never
  # interpolated into the response.
  # sobelow_skip ["XSS.SendResp"]
  def show(conn, %{"slug" => slug} = params) do
    dataset = Map.get(params, "dataset") || Content.paper_default_dataset()
    scope = paper_scope(conn, params)

    case fetch_paper(slug, dataset, scope) do
      nil ->
        send_resp(conn, 404, "not found")

      paper ->
        opts = %{style: :email, theme: email_theme(paper)}

        html =
          case Content.Papers.reader_source(paper, dataset, scope) do
            {:blocks, blocks} ->
              blocks
              |> Content.Papers.resolve_tasks_in_blocks(email_task_scope(paper))
              |> Render.render_document(opts)

            {:html, sanitized_html} ->
              Render.render_html_document(sanitized_html, opts)

            :empty ->
              Render.render_document([], opts)
          end

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)
    end
  end

  defp paper_scope(conn, %{"workspace_slug" => _}),
    do: BarkparkWeb.ScopeHelpers.scope_opts(conn)

  defp paper_scope(_conn, _params), do: []

  defp fetch_paper(slug, dataset, []), do: Content.get_public_paper(slug, dataset)
  defp fetch_paper(slug, dataset, scope), do: Content.get_paper(slug, dataset, scope)

  # Mirrors BulldocsLive.reader_task_scope/1: the paper's own tenant, falling
  # back to the seeded Default workspace (fail-closed underneath — a nil
  # workspace resolves zero rows, never cross-tenant data).
  defp email_task_scope(paper) do
    ws_id =
      (paper && paper.workspace_id) ||
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: id} -> id
          _ -> nil
        end

    [workspace_id: ws_id, project_id: paper && paper.project_id]
  end

  # The paper's workspace theme identity, defaulting through the seeded Default
  # workspace (mirrors email_task_scope's fail-closed fallback). Absent/unknown
  # → the default theme, keeping the byte stream unchanged.
  defp email_theme(paper) do
    ws_id =
      (paper && paper.workspace_id) ||
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: id} -> id
          _ -> nil
        end

    ws_id
    |> Barkpark.Tenancy.get_workspace_by_id()
    |> Barkpark.Tenancy.workspace_theme()
  end
end
