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

  Public-root bucket, published papers only — the same visibility contract as
  the reader route; a missing/unpublished slug is a plain 404.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Render

  def show(conn, %{"slug" => slug}) do
    case Content.get_public_paper(slug) do
      nil ->
        send_resp(conn, 404, "not found")

      paper ->
        blocks =
          paper
          |> paper_blocks()
          |> Content.Papers.resolve_tasks_in_blocks(email_task_scope(paper))

        html = Render.render_document(blocks, %{style: :email})

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)
    end
  end

  defp paper_blocks(%{content: %{"blocks" => blocks}}) when is_list(blocks), do: blocks
  defp paper_blocks(_), do: []

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
end
