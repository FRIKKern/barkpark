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
  alias BarkparkWeb.BulldocsEmailHTML

  # @sobelow_skip — XSS.SendResp (send_resp/3) is a false-positive: the body is
  # `Render.render_document/2` output or sanitizer-filtered legacy HTML inside
  # `Render.render_html_document/2`. `slug` selects the record; it is never
  # interpolated into the response.
  # sobelow_skip ["XSS.SendResp"]
  def show(conn, %{"slug" => slug} = params) do
    dataset = requested_dataset(params)
    scope = paper_scope(conn, params)

    case fetch_paper(slug, dataset, scope) do
      nil ->
        send_resp(conn, 404, "not found")

      paper ->
        opts = %{style: :email, theme: email_theme(paper)}
        title = email_title(paper, slug)
        trusted_paper_uri = trusted_paper_uri(conn)

        case Content.Papers.reader_source(paper, dataset, scope) do
          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{"error" => %{"code" => to_string(reason)}})

          source ->
            html =
              case source do
                {:blocks, blocks} ->
                  resolved_blocks =
                    Content.Papers.resolve_tasks_in_blocks(
                      blocks,
                      email_task_scope(paper),
                      dataset
                    )
                    |> BulldocsEmailHTML.prepare_blocks(trusted_paper_uri)

                  blocks_with_name =
                    if BulldocsEmailHTML.authored_heading?(resolved_blocks) do
                      resolved_blocks
                    else
                      [%{"type" => "heading", "level" => 1, "text" => title} | resolved_blocks]
                    end

                  Render.render_document(blocks_with_name, opts)

                {:html, sanitized_html} ->
                  named_html =
                    if BulldocsEmailHTML.legacy_heading?(sanitized_html) do
                      sanitized_html
                    else
                      BulldocsEmailHTML.fallback_heading(title, opts) <> sanitized_html
                    end

                  Render.render_html_document(named_html, opts)
              end

            html = BulldocsEmailHTML.finalize(html, title, trusted_paper_uri)

            conn
            |> put_resp_content_type("text/html")
            |> send_resp(200, html)
        end
    end
  end

  # `dataset` is QUERY-STRING sourced on the flat and scoped `/papers/:slug/email`
  # routes (only `/d/:dataset/...` carries it as a path segment), so Plug hands
  # us whatever `?dataset[]=x` / `?dataset[a]=b` decodes to — a list or a map.
  # A non-binary lands on `x.dataset == ^dataset` against a :string column and
  # raises Ecto.Query.CastError, which has no Plug.Exception impl → a raw 500.
  # A dataset is a SCOPE SELECTOR with a documented default, so a malformed one
  # fails soft to that default (same guard shape as MetaController.show/2).
  #
  # The share gate is ALIGNED to this: `RequireShareScope.request_dataset/1`
  # resolves the dataset the same way (path segment, else query string, else
  # the default, same `is_binary` soft-fail), so the value compared against the
  # share / item link is the value this function returns. Until
  # task-4f26838232b5ece0 the guard read the PATH only and always compared
  # `"production"` here, and `?dataset=other` read a dataset that was never
  # shared. Changing the precedence below without changing that function
  # reopens the escape.
  defp requested_dataset(params) do
    case Map.get(params, "dataset") do
      ds when is_binary(ds) -> ds
      _ -> Content.paper_default_dataset()
    end
  end

  defp paper_scope(conn, %{"workspace_slug" => _}),
    do: BarkparkWeb.ScopeHelpers.scope_opts(conn)

  defp paper_scope(_conn, _params), do: []

  defp fetch_paper(slug, dataset, []), do: Content.get_public_paper(slug, dataset)
  defp fetch_paper(slug, dataset, scope), do: Content.get_paper(slug, dataset, scope)

  defp email_title(%{title: title}, slug) when is_binary(title) do
    case String.trim(title) do
      "" -> slug
      title -> title
    end
  end

  defp email_title(_paper, slug), do: slug

  # Resolve relative links against the canonical reader location while taking
  # the origin only from Endpoint configuration, never the request Host header.
  # Keeping the scoped request path preserves /w/:ws/p/:project isolation.
  defp trusted_paper_uri(conn) do
    reader_path = String.replace_suffix(conn.request_path, "/email", "")
    URI.parse(BarkparkWeb.Endpoint.url() <> reader_path)
  end

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
