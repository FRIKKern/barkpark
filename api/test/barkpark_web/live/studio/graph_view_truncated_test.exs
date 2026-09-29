defmodule BarkparkWeb.Studio.GraphViewTruncatedTest do
  @moduledoc """
  THE STUDIO GRAPH PANE MUST NOT PRESENT ITS OWN TRUNCATION AS PHANTOM EDGES.

  `Content.Graph.build_drafts_index/1` reads each type's drafts corpus behind a
  document ceiling. A corpus larger than that yields a PARTIAL graph: the unread
  documents are absent as nodes, so every edge pointing at one resolves as
  `phantom` — and `bp-graph.js` draws a phantom node dashed/muted, the exact
  styling reserved for a reference whose target does not exist. So the reader is
  shown a WRONG diagnosis (broken references) for a RIGHT condition (we stopped
  reading at the ceiling).

  This pins the view half: when the graph payload carries a CORPUS truncation,
  `BarkparkWeb.Studio.GraphView` renders a NAMED notice
  (`data-test-id="studio-graph-truncated"`) that says the graph is partial, how
  much of the corpus was read, and that the dangling edges may be truncation
  rather than phantoms — and otherwise it renders NOTHING, because a banner
  accusing a complete graph of being partial is the same class of lie in the
  other direction.

  ## The field, and the two fields that are NOT it

  `Content.Graph.traverse/2` (#17359) returns three truncation fields:

    * `truncated` — a boolean ALSO set by BFS node-budget/fan-out/depth clamps.
    * `truncation_reason` — `:node_budget | :fan_out | :depth | :corpus_cap |
      nil`, where a BFS bound WINS the tie, so it can mask a real corpus cap.
    * `corpus_truncation` — `nil | %{truncated: true, limit: _, read: _}`, true
      only for the corpus cap.

  Only the third can carry this banner. `the depth-clamp control` below is the
  test that holds that line: it sets `truncated: true` and
  `truncation_reason: :depth` with `corpus_truncation: nil` — a NORMAL, complete,
  correctly-drawn graph — and asserts NO banner. Keying on either of the first
  two fields reds it.

  Uses `render_component/2` — no DB, no socket: the component is a pure function
  of the payload it is handed, which is precisely the property under test.
  """

  use BarkparkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.GraphView

  @caveat "may be truncation, not phantom references"

  # A graph with one edge onto a node that is NOT in the node list — exactly the
  # shape a truncated read produces. The payload's topology alone cannot tell you
  # whether that edge is a phantom or a casualty of the ceiling; only
  # `corpus_truncation` can.
  defp graph(extra) do
    Map.merge(
      %{
        root: "doc-a",
        nodes: [%{id: "doc-a", type: "article"}, %{id: "doc-b", type: "article"}],
        edges: [%{from: "doc-a", to: "doc-unread", kind: "reference"}]
      },
      extra
    )
  end

  defp render_graph(extra) do
    render_component(GraphView, id: "studio-graph", doc: %{id: "doc-a"}, graph: graph(extra))
  end

  describe "a corpus truncation" do
    test "renders a named notice carrying both numbers and the dangling-edge caveat" do
      html =
        render_graph(%{
          truncated: true,
          truncation_reason: :corpus_cap,
          corpus_truncation: %{truncated: true, limit: 20_000, read: 20_000}
        })

      assert html =~ ~s(data-test-id="studio-graph-truncated")
      assert html =~ "Partial graph — read 20000 of a drafts corpus larger than 20000 documents"
      assert html =~ "so some documents were never read"
      assert html =~ @caveat
      # role=status, so a screen reader is told too — visibly rendered means
      # rendered for every reader, not only the sighted one.
      assert html =~ ~s(role="status")
      # The canvas still renders: the notice EXPLAINS the graph, never replaces it.
      assert html =~ ~s(data-test-id="studio-graph-canvas")
    end

    test "reads a string-keyed payload too — the wire-decoded delta path" do
      html =
        render_graph(%{
          "corpus_truncation" => %{"truncated" => true, "limit" => 20_000, "read" => 18_412}
        })

      assert html =~ ~s(data-test-id="studio-graph-truncated")
      assert html =~ "read 18412 of a drafts corpus larger than 20000 documents"
    end

    test "falls back to the number-free wording when limit/read are absent" do
      html = render_graph(%{corpus_truncation: %{truncated: true}})

      assert html =~ ~s(data-test-id="studio-graph-truncated")
      assert html =~ "Partial graph — the drafts corpus exceeded the read ceiling"
      assert html =~ @caveat
      # The degraded wording must not leak an empty slot where a number goes.
      refute html =~ "read  of"
      refute html =~ "larger than  documents"
    end
  end

  describe "the depth-clamp control — `truncated` is NOT this banner's field" do
    test "renders NOTHING when the BFS clamped but the corpus did not" do
      html =
        render_graph(%{
          truncated: true,
          truncation_reason: :depth,
          corpus_truncation: nil
        })

      refute html =~ "studio-graph-truncated"
      refute html =~ "Partial graph"
      # Control on the control: the pane really did render, so the refutes above
      # are a measurement and not an empty string.
      assert html =~ ~s(data-test-id="studio-graph-canvas")
    end

    test "renders NOTHING for a node-budget or fan-out clamp either" do
      for reason <- [:node_budget, :fan_out] do
        html = render_graph(%{truncated: true, truncation_reason: reason})

        refute html =~ "studio-graph-truncated"
        assert html =~ ~s(data-test-id="studio-graph-canvas")
      end
    end
  end

  describe "the untruncated control" do
    test "renders NOTHING when the field is absent" do
      html = render_graph(%{})

      refute html =~ "studio-graph-truncated"
      refute html =~ "Partial graph"
      assert html =~ ~s(data-test-id="studio-graph-canvas")
    end

    test "renders NOTHING for a malformed corpus_truncation" do
      # Not a map, a map without `truncated: true`, or an explicit false — none
      # of these may light the banner.
      refute render_graph(%{corpus_truncation: true}) =~ "studio-graph-truncated"
      refute render_graph(%{corpus_truncation: "yes"}) =~ "studio-graph-truncated"
      refute render_graph(%{corpus_truncation: %{}}) =~ "studio-graph-truncated"
      refute render_graph(%{corpus_truncation: %{truncated: false}}) =~ "studio-graph-truncated"
      assert render_graph(%{corpus_truncation: true}) =~ ~s(data-test-id="studio-graph-canvas")
    end
  end
end
