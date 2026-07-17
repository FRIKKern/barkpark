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

    case fetch_paper(slug, dataset, scope) do
      nil ->
        send_resp(conn, 404, "not found")

      paper ->
        source =
          case Content.Papers.reader_source(paper, dataset, scope) do
            {:blocks, blocks} ->
              resolved = Content.Papers.resolve_tasks_in_blocks(blocks, task_scope(paper))
              %{"kind" => "blocks", "blocks" => resolved}

            {:html, html} ->
              %{"kind" => "html", "html" => html}

            :empty ->
              %{"kind" => "empty"}
          end

        json(conn, %{"title" => paper.title, "source" => source})
    end
  end

  defp paper_scope(conn, %{"workspace_slug" => _}),
    do: BarkparkWeb.ScopeHelpers.scope_opts(conn)

  defp paper_scope(_conn, _params), do: []

  defp fetch_paper(slug, dataset, []), do: Content.get_public_paper(slug, dataset)
  defp fetch_paper(slug, dataset, scope), do: Content.get_paper(slug, dataset, scope)

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
