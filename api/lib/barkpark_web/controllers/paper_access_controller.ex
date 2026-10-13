defmodule BarkparkWeb.PaperAccessController do
  @moduledoc """
  `GET /v1/papers/:slug/access` — who has viewed and edited one paper.

  Edit-on-the-link slice 4 (task-e99a8e946f80f52c). The read side of
  `Barkpark.Content.PaperAccess`: rows NEWEST FIRST, bounded by `?limit=`
  (default 100, hard cap 500), optionally narrowed by `?dataset=`.

  ## Paging past the first N (task-fb4cf8323a9795e5)

  The trail is unbounded (90-day retention, `PaperAccess.ttl_days/0`), so a
  bounded top-N with no signal left a caller holding a full page unable to
  tell it from the whole log. Every page now carries `has_more` and
  `next_offset`, the same contract `SecretController.audit/2` already gives
  its own unbounded trail: `has_more` is derived by fetching ONE row past
  `limit` and dropping it (never a separate COUNT that could disagree with
  the page), and `next_offset` is `nil` exactly when `has_more` is false.
  Walk with `?offset=<next_offset>` until `has_more` is false.

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
    limit = parse_limit(params["limit"])
    offset = parse_offset(params["offset"])

    # ONE row past the page decides `has_more`; it is dropped before render —
    # the same technique SecretController.audit/2 uses for the same reason.
    fetched =
      PaperAccess.list(slug,
        workspace_id: Keyword.get(opts, :workspace_id),
        dataset: dataset_param(params),
        limit: limit + 1,
        offset: offset
      )

    has_more = length(fetched) > limit
    rows = Enum.take(fetched, limit)

    json(conn, %{
      slug: slug,
      access:
        rows
        |> Barkpark.Accounts.Privacy.redact_actor_labels()
        |> Enum.map(&render_row/1),
      count: length(rows),
      limit: limit,
      offset: offset,
      has_more: has_more,
      # Minted from the SAME `has_more` that promises it, so the signal and
      # its continuation cannot drift apart.
      next_offset: if(has_more, do: offset + length(rows))
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

  defp parse_offset(nil), do: 0

  defp parse_offset(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _} -> max(n, 0)
      :error -> 0
    end
  end

  defp parse_offset(raw) when is_integer(raw), do: max(raw, 0)
  defp parse_offset(_raw), do: 0
end
