defmodule BarkparkWeb.BulldocsSourceController do
  @moduledoc """
  Capability-bound canonical source for the embedded Paper readers.

  The endpoint is mounted beside each public/scoped Paper route and therefore
  inherits that route's membership/share boundary. It never exposes the broad
  document API to browser code and returns only the visibility-redacted source
  needed by the TUI/email mirrors.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content

  def show(conn, %{"slug" => slug} = params) do
    dataset = Map.get(params, "dataset") || Content.paper_default_dataset()
    scope = paper_scope(conn, params)
    perspective = BarkparkWeb.AnonPerspective.resolve(conn, params)

    case fetch_paper(slug, dataset, scope, perspective) do
      nil ->
        send_resp(conn, 404, "not found")

      paper ->
        source =
          case Content.Papers.reader_source(paper, dataset, scope) do
            {:blocks, blocks} ->
              resolved =
                Content.Papers.resolve_tasks_in_blocks(blocks, task_scope(paper), dataset)

              %{"kind" => "blocks", "blocks" => resolved}

            {:html, html} ->
              %{"kind" => "html", "html" => html}

            {:error, reason} ->
              {:error, reason}
          end

        case source do
          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{"error" => %{"code" => to_string(reason)}})

          source ->
            json(conn, %{
              "id" => paper.doc_id,
              "title" => paper.title,
              "_rev" => paper.rev,
              "source" => source
            })
        end
    end
  end

  defp paper_scope(conn, %{"workspace_slug" => _}),
    do: BarkparkWeb.ScopeHelpers.scope_opts(conn)

  defp paper_scope(_conn, _params), do: []

  # Flat public readers are always published-only; AnonPerspective already
  # pins them, and get_public_paper keeps the Default-workspace boundary.
  defp fetch_paper(slug, dataset, [], :published),
    do: fetch_published(slug, dataset, [])

  defp fetch_paper(slug, dataset, [], perspective) do
    case public_scope() do
      nil -> nil
      scope -> fetch_paper(slug, dataset, scope, perspective)
    end
  end

  # Drafts is an overlay: prefer drafts.<published-id>, then fall back to the
  # published row. Raw addresses the exact id the caller supplied.
  defp fetch_paper(slug, dataset, scope, :drafts) do
    published_id = Content.published_id(slug)

    fetch_exact("drafts." <> published_id, dataset, scope) ||
      fetch_exact(published_id, dataset, scope)
  end

  defp fetch_paper(slug, dataset, scope, :raw), do: fetch_exact(slug, dataset, scope)
  defp fetch_paper(slug, dataset, scope, :published), do: fetch_published(slug, dataset, scope)

  defp fetch_published("drafts." <> _slug, _dataset, _scope), do: nil
  defp fetch_published(slug, dataset, []), do: Content.get_public_paper(slug, dataset)
  defp fetch_published(slug, dataset, scope), do: fetch_exact(slug, dataset, scope)

  defp fetch_exact(slug, dataset, scope), do: Content.get_paper(slug, dataset, scope)

  defp public_scope do
    case Barkpark.Tenancy.get_default_workspace() do
      %{id: id} -> [workspace_id: id]
      _ -> nil
    end
  end

  defp task_scope(paper) do
    ws_id =
      paper.workspace_id ||
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: id} -> id
          _ -> nil
        end

    [workspace_id: ws_id, project_id: paper.project_id]
  end
end
