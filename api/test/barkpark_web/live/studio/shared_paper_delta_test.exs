defmodule BarkparkWeb.Studio.StudioLive.Shared.PaperDeltaTest do
  @moduledoc """
  Unit tests for `Paper.apply_paper_delta/2`'s op_kind dispatch — in particular the
  `op_kind: :batch` no-op clause (Phase-6 audit Bug #3): a canvas batch broadcasts ONE
  frame with op_kind: :batch + fragment_html: nil, and the editing LV is subscribed to
  its own doc topic, so it receives its own batch frame. Without the dedicated clause it
  fell through to the catch-all and stream_insert'd a {id, html: nil} :paper_blocks row.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  test "op_kind: :batch is a NO-OP for the per-block stream — tracks rev, no stream_insert" do
    frame = %{
      op_kind: :batch,
      block_id: "b-3",
      block_ids: ["b-1", "b-2", "b-3"],
      fragment_html: nil,
      position: nil,
      rev: 7
    }

    # The catch-all clause calls stream_insert/3, which raises on a bare socket with no
    # registered stream. If the :batch frame reached it (the bug), this would crash; the
    # dedicated no-op clause only assigns, so it succeeds on a bare socket.
    socket = Paper.apply_paper_delta(socket(), frame)

    assert socket.assigns.paper_rev == 7
    # :batch is NOT a per-block edit, so it must not flip paper_block_mode like the
    # per-block clauses do.
    refute Map.get(socket.assigns, :paper_block_mode)
  end

  test "a per-block frame still reaches the stream-touching clause (the :batch clause is scoped)" do
    # A non-:batch frame must NOT match the new no-op clause — it falls to the per-block
    # clauses, which call stream functions that raise on a bare socket with no registered
    # stream. The raise itself proves the dispatch did NOT swallow it as a no-op.
    frame = %{op_kind: "remove-block", block_id: "b-1", rev: 4}

    # stream_delete_by_dom_id reaches for socket.assigns.streams, absent on a bare socket.
    assert_raise KeyError, fn ->
      Paper.apply_paper_delta(socket(), frame)
    end
  end
end
