defmodule BarkparkWeb.PaperAccessController do
  @moduledoc """
  `GET /v1/papers/:slug/access` — who has viewed and edited one paper.

  Edit-on-the-link slice 4 (task-e99a8e946f80f52c). The read side of
  `Barkpark.Content.PaperAccess`: rows NEWEST FIRST, bounded by `?limit=`
  (default 100, hard cap 500), optionally narrowed by `?dataset=`.

  ## Why `:flat_admin_api`

  Because it is a flat admin surface, and that is the pipeline flat admin
  surfaces ride (router.ex, D45/D49). It matters more here than usual: this is
  a log of who read a link, so it must be workspace-attributed to the CALLER's
  own workspace rather than collapsed to the seeded Default. `:flat_admin_api`
  runs `DeriveWorkspaceFromToken` BEFORE `AssignDefaultScope`, so a
  workspace-bound admin token reads ITS workspace's trail; the naive
  `[:api, :require_admin]` pairing would have served every caller the Default
  workspace's rows.

  The pipeline also supplies the two refusals the criterion names: no token is
  a 401 (`RequireToken`), a non-admin token is a 403 (`RequireAdmin`). Neither
  is re-implemented here.

  ## What a row says

  The actor triple, verbatim. An anonymous row carries `actor_kind:
  "anonymous"` with a null id and label — the table never stored more, so this
  surface cannot leak more.
  """

  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content.PaperAccess

  @default_limit 100
  @max_limit 500

  def index(conn, %{"slug" => slug} = params) do
    opts = scope_opts(conn)

    rows =
      PaperAccess.list(slug,
        workspace_id: Keyword.get(opts, :workspace_id),
        dataset: dataset_param(params),
        limit: parse_limit(params["limit"])
      )

    json(conn, %{
      slug: slug,
      access: Enum.map(rows, &render_row/1),
      count: length(rows)
    })
  end

  defp render_row(row) do
    %{
      id: row.id,
      action: row.action,
      dataset: row.dataset,
      actor_kind: row.actor_kind,
      actor_id: row.actor_id,
      actor_label: row.actor_label,
      at: row.inserted_at
    }
  end

  defp dataset_param(%{"dataset" => ds}) when is_binary(ds) and ds != "", do: ds
  defp dataset_param(_params), do: nil

  defp parse_limit(nil), do: @default_limit

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _} -> clamp(n)
      :error -> @default_limit
    end
  end

  defp parse_limit(raw) when is_integer(raw), do: clamp(raw)

  # A list param (`?limit[]=1`) or any other non-scalar falls back rather than
  # raising FunctionClauseError into a 500 — the same guard HistoryController
  # carries for the same reason.
  defp parse_limit(_raw), do: @default_limit

  defp clamp(n), do: n |> max(1) |> min(@max_limit)
end
