defmodule BarkparkWeb.PaperFleetBlocksController do
  @moduledoc """
  `GET /w/:workspace_slug/p/:project_slug/v1/papers/:slug/fleet-blocks` —
  the server-rendered HTML for a paper's fleet blocks (task list/board/
  detail, roadmap, notes, cards, pipeline, status-legend, asciicast, form,
  questionnaire, and the data-viz blocks), by block id, over HTTP
  (task-4feb8efa46a0ed33).

  D14 (task blocks inside a paper show live previews) needs the HTML the
  canvas's read-only fleet atoms paint. The canvas never renders a fleet
  block itself (embed-node.js one-producer contract): it leaves a
  `[data-bp-fleet-body]` hole keyed by the block id, and LiveView fills it by
  pushing `bp:block-html` from `StudioLive.Shared.Paper.push_block_renders/1`.
  An external (non-LiveView) host has no socket to receive that push, so this
  controller is the SAME render, called directly: `fleet_block?/1` filters
  the paper's top-level blocks to the fleet-channel set, and `fleet_render/2`
  renders each one exactly as the Studio canvas would — the live-task query
  resolved through `task_previews/2` and the SAME `PaperTaskSeam.resolver/1`
  seam (never naming the Tasks plugin's substrate directly), merged onto a
  COPY so the source blocks are untouched (D5/D3). `fleet_block?/1` was
  private; made public (with `@doc`) for this call site only — its body is
  unchanged.

  ## Learning when it changes

  A fleet block's HTML depends on the TASK rows its query names, not on the
  paper document's own `rev` — editing a referenced task changes this
  response without the paper itself being written. There is no new push
  channel for that: `GET /v1/data/listen/:dataset?types=task` (optionally
  narrowed with `?ids=<the task ids a block's query names>`, task-66d495ccd
  23e7f16) already streams `document_changed` for exactly that population.
  A host re-fetches this endpoint on any such event; every render here is
  computed fresh from the current task store, never cached.

  ## Why a synthetic socket

  `task_previews/2` is a Studio LiveView helper and takes a
  `Phoenix.LiveView.Socket` because `ScopeHelpers.scope_opts/1` and the
  session's `dataset` assign are read off it. Called from here, behaviour
  must be byte-identical to the Studio canvas's own call — not a parallel
  re-implementation — so this controller builds the minimal socket shape
  `task_previews/2` actually reads (`assigns.dataset`, `assigns.
  current_workspace`, `assigns.current_project`) rather than copying its
  body. Everything downstream (the task resolver seam, the tenant fail-closed
  rule on a nil workspace) runs exactly as it does for a connected Studio
  session.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper, as: StudioPaper

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  def show(conn, %{"slug" => slug} = params) do
    dataset = requested_dataset(params)
    scope = scope_opts(conn)

    case Content.get_paper(slug, dataset, scope) do
      %Document{} = paper ->
        json(conn, render_fleet_blocks(paper, dataset))

      nil ->
        ErrorResponse.emit_custom(conn, 404, "not_found", "no paper found as #{inspect(slug)}")
    end
  end

  defp render_fleet_blocks(%Document{} = paper, dataset) do
    blocks = Content.ensure_block_ids(get_in(paper.content || %{}, ["blocks"]) || [])
    render_blocks = StudioPaper.expandable_render_blocks(blocks)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        dataset: dataset,
        current_workspace: wrap_scope_id(paper.workspace_id),
        current_project: wrap_scope_id(paper.project_id)
      }
    }

    previews = Map.new(StudioPaper.task_previews(render_blocks, socket), &{&1["block_id"], &1})

    renders =
      render_blocks
      |> Enum.filter(&StudioPaper.fleet_block?/1)
      |> Enum.map(&StudioPaper.fleet_render(&1, previews))
      |> Enum.reject(&(&1["block_id"] in [nil, ""]))

    %{
      slug: paper.doc_id,
      rev: paper.rev,
      blocks: Map.new(renders, &{&1["block_id"], &1["html"]})
    }
  end

  defp wrap_scope_id(nil), do: nil
  defp wrap_scope_id(id) when is_binary(id), do: %{id: id}

  defp requested_dataset(params) do
    case Map.get(params, "dataset") do
      ds when is_binary(ds) -> ds
      _ -> Content.paper_default_dataset()
    end
  end
end
