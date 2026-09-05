defmodule BarkparkWeb.Studio.StudioLive.Shared.PaperReadOnlyPaneTest do
  @moduledoc """
  Session-handoff final review, F4. `PaneBuilder` now opens EVERY blocks-doc
  type in the paper pane (`Content.blocks_type?/1`), but the pane's write path
  is paper-hardcoded — `Content.apply_paper_block_op/4` /
  `apply_paper_block_ops/4`, and `sync_paper_edit_doc/1`'s `get_paper/2`.
  Pointing those at a session either fails opaquely or resolves a SAME-SLUG
  PAPER and edits the wrong document.

  v1 ruling: the session pane is READ-ONLY. These tests pin the guard at both
  pane op entry points, and — the part that matters — pin that it is SCOPED:
  a paper still takes the unchanged write path.

  No `DataCase` here on purpose. Without a checked-out sandbox connection any
  `Content.*` call raises, so "did not touch the DB" is directly observable:
  the session cases return a socket, the paper control raises.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @notice "Sessions are read-only in Studio (v1) — edit via bp session publish"

  defp socket(assigns) do
    base = %{__changed__: %{}, flash: %{}, dataset: "production"}
    %Phoenix.LiveView.Socket{assigns: Map.merge(base, assigns)}
  end

  defp session_socket do
    socket(%{
      editor_type: "session",
      paper_doc: %{doc_id: "session-2026-07-25-x", content: %{"blocks" => []}}
    })
  end

  defp paper_socket do
    socket(%{
      editor_type: "paper",
      paper_doc: %{doc_id: "some-paper", content: %{"blocks" => []}}
    })
  end

  @op %{"op" => "append-block", "block" => %{"id" => "b1", "type" => "paragraph"}}

  test "a single op on a session pane is refused with the honest notice, no write attempted" do
    socket = Paper.paper_pane_op(session_socket(), @op)

    assert socket.assigns.flash["error"] == @notice
    assert socket.assigns.save_status == "Read-only"
  end

  test "a canvas BATCH on a session pane is refused too (its own entry point)" do
    socket = Paper.paper_ops(session_socket(), [@op])

    assert socket.assigns.flash["error"] == @notice
    assert socket.assigns.save_status == "Read-only"
  end

  test "the guard is SCOPED — a paper pane still reaches the unchanged write path" do
    # Reaching the write path means calling Content, which needs a DB
    # connection this async, sandbox-less test never checked out. The raise IS
    # the evidence that the paper leg was not swallowed by the new guard.
    assert_raise DBConnection.OwnershipError, fn -> Paper.paper_pane_op(paper_socket(), @op) end
    assert_raise DBConnection.OwnershipError, fn -> Paper.paper_ops(paper_socket(), [@op]) end
  end

  test "a pane with no editor_type (paper-only legacy assigns) is NOT treated as read-only" do
    s = socket(%{paper_doc: nil})

    # nil editor_type must reach the missing-document save failure, never the
    # read-only refusal: an assign-order change must not make papers read-only.
    result = Paper.paper_pane_op(s, @op)

    refute result.assigns.flash["error"] == @notice
    assert result.assigns.save_status == "Save failed"
    assert result.assigns.last_paper_save_ok? == false
    assert result.assigns.last_paper_save_result == %{saved: false, request_id: nil}
  end
end
