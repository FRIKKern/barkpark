defmodule Barkpark.Content.Papers.WritePathNormalizerTest do
  @moduledoc """
  Write-chokepoint normalization of item shapes and the inline-leaf dialect
  (`BlockOps.normalize_render_shapes/1` + `validate_render_shapes/1`) —
  pe-w1-write-path-normalizer.

  Fixtures are LIFTED FROM THE LIVE CORPUS, not invented:

    * `notes` items as bare strings — the exact shape live paper
      `heggemsnes-act` stores (block id `hga-remedies`, 5 string items), which
      renders five EMPTY note rows on prod today (`components.ex` reads item
      fields through `get/2`, nil on a binary).
    * text-KEYED inline leaves (`%{"type" => "text", "text" => …}`, the TipTap
      dialect) — the exact shape live paper `deploy-reliability-wave-4-2026-08-06`
      stores (block id `block-0`); the renderer reads ONLY `value`
      (render/inline.ex `Map.get(n, "value", "")`, no `text` fallback), so
      the whole paper answers 200 while every heading/paragraph renders hollow.
      Corpus repair is owned by the OPEN task
      `cch-w57-bl-eleven-papers-render-200-with-prose-the-reader-drops`
      (re-publish after this deploys) — deliberately NOT re-filed here.

  RED-BEFORE EVIDENCE (this exact file against the pre-fix write path,
  commit 20dd241ad9): 14 of the 19 tests below FAILED —
  every normalization test in the "notes/cards items + pipeline nodes",
  "inline-leaf dialect", and "bare-string table cells" describes red
  (e.g. `notes string items … normalize to the text-map shape` asserted
  `%{"text" => …}` maps and got the raw strings back; `a bare-string table
  cell … passes the gate` got `{:error, {:invalid_paper_structure, …}}` with
  "has no renderable inline content") — while the 5 passthrough/refusal
  pins (byline byte-identity, canonical map items, both-keys leaf,
  unrescuable-cell refusals, idempotency-of-identity) were green, proving
  the arm is type-keyed and additive, never a behavior rewrite of canonical
  shapes.

  The "wave-11 header-row dialect" describe was added later, for
  `task-9b3778f52ca05984`. That row reported the defect on 2026-07-31 against
  a shape none of the three pins above reach — a `rows` entry that is a
  cells-map carrying `header: true`, which `normalize_array_table/2` promotes
  to `head` through its OWN arm. #11616 fixed it on 2026-08-12 as a side
  effect; nothing pinned it, so the rescue could have decayed silently.

  MUTATION EVIDENCE for that describe (delete the two-line
  `normalize_wrapped_table_cell(cell) when is_binary(cell)` arm from
  block_ops.ex and rerun): 24 tests, 6 failures — the three string-cell pins
  above plus three of the four new ones, each naming string table cells
  specifically ("blocks[0].head.cells[0] has no renderable inline content"),
  never a generic structure failure. The render-preserving and idempotency
  pins stay green under the mutation, as they must: both compare the
  normalizer against ITSELF.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.Render

  # ── notes / cards items + pipeline nodes ────────────────────────────────────

  describe "notes/cards items + pipeline nodes" do
    test "notes string items (heggemsnes-act corpus shape) normalize to the text-map shape" do
      # Two of the five live hga-remedies items, verbatim.
      block = %{
        "id" => "hga-remedies",
        "type" => "notes",
        "items" => [
          "PR #11556: his original description restored verbatim from the edit history; the after-the-fact edits disclosed in a clearly separated maintainer note.",
          "PR #11556: his deleted testing disclosure stands again, word for word."
        ]
      }

      assert [%{"items" => [item_a, item_b]}] = BlockOps.normalize_render_shapes([block])

      assert item_a == %{
               "text" =>
                 "PR #11556: his original description restored verbatim from the edit history; the after-the-fact edits disclosed in a clearly separated maintainer note."
             }

      assert item_b == %{
               "text" => "PR #11556: his deleted testing disclosure stands again, word for word."
             }
    end

    test "cards string items normalize to the text-map shape" do
      block = %{"type" => "cards", "items" => ["Rule one, stated plainly.", "Rule two."]}

      assert [%{"items" => [%{"text" => "Rule one, stated plainly."}, %{"text" => "Rule two."}]}] =
               BlockOps.normalize_render_shapes([block])
    end

    test "pipeline string nodes normalize to a shape pipeline_html actually renders" do
      block = %{"type" => "pipeline", "nodes" => ["source", "emit", "gate"]}

      assert [
               %{
                 "nodes" =>
                   [%{"title" => "source"}, %{"title" => "emit"}, %{"title" => "gate"}] = nodes
               } = normalized
             ] =
               BlockOps.normalize_render_shapes([block])

      # The shape assertion above is necessary but not sufficient — the first
      # version of this arm emitted %{"text" => s}, which no pipeline reader
      # renders, and a shape-only test stayed green (independent review of
      # #11616). The rendered output is the oracle: every node's label must
      # appear in the HTML, where the raw-string input renders empty nodes.
      html = Barkpark.PortableDoc.Render.Components.pipeline_html(normalized)
      for %{"title" => title} <- nodes, do: assert(html =~ title)

      raw_html = Barkpark.PortableDoc.Render.Components.pipeline_html(block)
      refute raw_html =~ "source"
    end

    test "an inline-array item normalizes to a text map carrying the flattened inline text" do
      block = %{
        "type" => "notes",
        "items" => [
          [
            %{"type" => "text", "value" => "lead "},
            %{"type" => "strong", "children" => [%{"type" => "text", "value" => "bold"}]},
            %{"type" => "text", "text" => "tail"}
          ]
        ]
      }

      assert [%{"items" => [%{"text" => "lead boldtail"}]}] =
               BlockOps.normalize_render_shapes([block])
    end

    test "canonical map items pass byte-identical (notes, cards, pipeline)" do
      note = %{"label" => "L", "lead" => "Lead", "text" => "Body."}
      card = %{"title" => "T", "text" => "Body.", "tone" => "info"}
      node = %{"kind" => "k", "title" => "t", "detail" => "d", "source" => true}

      blocks = [
        %{"type" => "notes", "items" => [note]},
        %{"type" => "cards", "items" => [card]},
        %{"type" => "pipeline", "nodes" => [node]}
      ]

      assert BlockOps.normalize_render_shapes(blocks) == blocks
    end

    test "notes string items inside a section's nested blocks normalize too" do
      blocks = [
        %{
          "type" => "section",
          "blocks" => [%{"type" => "notes", "items" => ["nested string item"]}]
        }
      ]

      assert [%{"blocks" => [%{"items" => [%{"text" => "nested string item"}]}]}] =
               BlockOps.normalize_render_shapes(blocks)
    end

    test "the arm is TYPE-KEYED: byline string items pass through byte-unchanged" do
      # The CANONICAL designed shape (compose.ex joins stringish items),
      # carried by 215 live papers — a generic items-must-be-maps arm is
      # forbidden. Pin passthrough at the byte level.
      byline = %{"type" => "byline", "items" => ["Fable", "2026-08-12", "Wave 1"]}

      assert BlockOps.normalize_render_shapes([byline]) == [byline]
    end
  end

  # ── text-keyed inline leaves → value-keyed ──────────────────────────────────

  describe "inline-leaf dialect" do
    test "a text-keyed leaf (deploy-reliability corpus shape) normalizes to value-keyed" do
      # Verbatim from live paper deploy-reliability-wave-4-2026-08-06, block-0.
      block = %{
        "attrs" => %{"level" => 1},
        "content" => [
          %{
            "text" =>
              "Deploy Reliability — Wave 4: Three answers down one pipe, and a door that says no",
            "type" => "text"
          }
        ],
        "id" => "block-0",
        "type" => "heading"
      }

      assert [%{"content" => [leaf]}] = BlockOps.normalize_render_shapes([block])

      assert leaf == %{
               "type" => "text",
               "value" =>
                 "Deploy Reliability — Wave 4: Three answers down one pipe, and a door that says no"
             }

      refute Map.has_key?(leaf, "text")
    end

    test "a value-keyed leaf stays byte-identical; marks are preserved on a rewritten leaf" do
      canonical = %{
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "already canonical"}]
      }

      assert BlockOps.normalize_render_shapes([canonical]) == [canonical]

      marked = %{
        "type" => "paragraph",
        "content" => [
          %{"type" => "text", "text" => "emphatic", "marks" => [%{"type" => "bold"}]}
        ]
      }

      assert [%{"content" => [leaf]}] = BlockOps.normalize_render_shapes([marked])
      assert leaf == %{"type" => "text", "value" => "emphatic", "marks" => [%{"type" => "bold"}]}
    end

    test "a leaf carrying BOTH text and value is left untouched (value already wins at render)" do
      block = %{
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "rendered", "text" => "stale"}]
      }

      assert BlockOps.normalize_render_shapes([block]) == [block]
    end

    test "text-keyed leaves nested in mark-node children normalize" do
      block = %{
        "type" => "paragraph",
        "content" => [
          %{"type" => "strong", "children" => [%{"type" => "text", "text" => "bold prose"}]}
        ]
      }

      assert [%{"content" => [%{"children" => [leaf]}]}] =
               BlockOps.normalize_render_shapes([block])

      assert leaf == %{"type" => "text", "value" => "bold prose"}
    end

    test "text-keyed leaves inside list items normalize" do
      block = %{
        "type" => "list",
        "items" => [[%{"type" => "text", "text" => "list prose"}]]
      }

      assert [%{"items" => [[leaf]]}] = BlockOps.normalize_render_shapes([block])
      assert leaf == %{"type" => "text", "value" => "list prose"}
    end

    test "text-keyed leaves inside table cells (rows and head) normalize" do
      block = %{
        "type" => "table",
        "head" => [[%{"type" => "text", "text" => "Header"}]],
        "rows" => [[[%{"type" => "text", "text" => "Cell"}]]]
      }

      assert [%{"head" => [[head_leaf]], "rows" => [[[row_leaf]]]}] =
               BlockOps.normalize_render_shapes([block])

      assert head_leaf == %{"type" => "text", "value" => "Header"}
      assert row_leaf == %{"type" => "text", "value" => "Cell"}
    end

    test "text-keyed leaves inside an expandable's nested blocks normalize" do
      block = %{
        "type" => "expandable",
        "summary" => "Appendix",
        "blocks" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "hidden prose"}]}
        ]
      }

      assert [%{"blocks" => [%{"content" => [leaf]}]}] =
               BlockOps.normalize_render_shapes([block])

      assert leaf == %{"type" => "text", "value" => "hidden prose"}
    end
  end

  # ── bare-string table cells ─────────────────────────────────────────────────

  describe "bare-string table cells" do
    test "a bare-string cell normalizes to a canonical inline array and passes the gate" do
      block = %{
        "type" => "table",
        "rows" => [["plain cell", "second cell"]]
      }

      assert [%{"rows" => [[cell_a, cell_b]]}] =
               normalized = BlockOps.normalize_render_shapes([block])

      assert cell_a == [%{"type" => "text", "value" => "plain cell"}]
      assert cell_b == [%{"type" => "text", "value" => "second cell"}]
      assert BlockOps.validate_render_shapes(normalized) == :ok
    end

    test "a bare-string HEAD cell normalizes and passes the gate" do
      block = %{
        "type" => "table",
        "head" => ["Name", "Age"],
        "rows" => [[[%{"type" => "text", "value" => "x"}], [%{"type" => "text", "value" => "1"}]]]
      }

      assert [%{"head" => [head_a, head_b]}] =
               normalized = BlockOps.normalize_render_shapes([block])

      assert head_a == [%{"type" => "text", "value" => "Name"}]
      assert head_b == [%{"type" => "text", "value" => "Age"}]
      assert BlockOps.validate_render_shapes(normalized) == :ok
    end

    test "a bare-string cell inside a cells-map row that carries extra keys normalizes" do
      block = %{
        "type" => "table",
        "rows" => [%{"cells" => ["kept-wrapper cell"], "id" => "r1", "header" => false}]
      }

      assert [%{"rows" => [%{"cells" => [cell], "id" => "r1"}]}] =
               normalized = BlockOps.normalize_render_shapes([block])

      assert cell == [%{"type" => "text", "value" => "kept-wrapper cell"}]
      assert BlockOps.validate_render_shapes(normalized) == :ok
    end

    test "unrescuable cells (textless map, number, nil) still refuse with the existing copy" do
      for bad <- [%{"tone" => "info"}, 42, nil] do
        block = %{"type" => "table", "rows" => [[bad]]}
        normalized = BlockOps.normalize_render_shapes([block])

        assert {:error, {:invalid_paper_structure, %{"blocks" => errors}}} =
                 BlockOps.validate_render_shapes(normalized)

        assert Enum.any?(errors, &(&1 =~ "has no renderable inline content")),
               "expected the existing refusal copy for #{inspect(bad)}, got: #{inspect(errors)}"
      end
    end
  end

  # ── the wave-11 reported shape (regression pin) ───────────────────────

  describe "the wave-11 header-row dialect (task-9b3778f52ca05984)" do
    # The shape the row reported VERBATIM: a `rows` entry that is a cells-map
    # carrying `header: true`, whose cells are bare strings. It reaches a
    # DIFFERENT arm of normalize_array_table than the three cases pinned above
    # (the head-promotion arm, not normalize_wrapped_table_row), so none of them
    # would have caught a regression in it. It writes-accepts today; before
    # #11616 added the bare-string arm to normalize_wrapped_table_cell/1 it also
    # write-accepted and then REFUSED at publish with invalid_paper_structure.
    @wave11_table %{
      "type" => "table",
      "rows" => [%{"cells" => ["a", "b"], "header" => true}]
    }

    test "the header row is promoted to `head` with its bare strings rescued" do
      assert [normalized_block] = normalized = BlockOps.normalize_render_shapes([@wave11_table])

      assert normalized_block["head"] == [
               [%{"type" => "text", "value" => "a"}],
               [%{"type" => "text", "value" => "b"}]
             ]

      assert normalized_block["rows"] == []
      refute Map.has_key?(normalized_block, "header")

      assert BlockOps.validate_render_shapes(normalized) == :ok
    end

    test "a header row followed by bare-string body rows all pass the publish gate" do
      block = %{
        "type" => "table",
        "rows" => [
          %{"cells" => ["Metric", "Value"], "header" => true},
          %{"cells" => ["publish round-trips", "25"]},
          ["bisected block index", "22 of 74"]
        ]
      }

      normalized = BlockOps.normalize_render_shapes([block])

      assert BlockOps.validate_render_shapes(normalized) == :ok

      assert [%{"rows" => [row_a, row_b]}] = normalized

      # A map_size-1 cells wrapper is unwrapped to the canonical bare list.
      assert row_a == [
               [%{"type" => "text", "value" => "publish round-trips"}],
               [%{"type" => "text", "value" => "25"}]
             ]

      assert row_b == [
               [%{"type" => "text", "value" => "bisected block index"}],
               [%{"type" => "text", "value" => "22 of 74"}]
             ]
    end

    test "the rescue is render-PRESERVING: normalized HTML equals the raw shape's" do
      # The asymmetry that makes normalization (not refusal) the right fix:
      # render/inline.ex `compose_inline_children(s) when is_binary(s)` already
      # tolerates a scalar cell, so the WRITER-then-PUBLISHER refused what the
      # READER renders fine. Rescuing the cell must therefore change zero bytes
      # of output.
      raw_html = Render.render_blocks([@wave11_table])
      normalized_html = Render.render_blocks(BlockOps.normalize_render_shapes([@wave11_table]))

      assert normalized_html == raw_html
      assert normalized_html =~ "a"
      assert normalized_html =~ "b"
    end

    test "the gate refuses the RAW shape and names the offending cell paths" do
      # Both halves of the row's report, in one runnable assertion:
      #
      #   * FAIL-FIRST — the raw authored shape is exactly what the publish gate
      #     refuses, which is why the write landed (a rev printed) and the
      #     publish did not. This also keeps the pins above non-vacuous: their
      #     `:ok` is earned by the normalizer, not by a gate that accepts
      #     everything.
      #   * the refusal is NOT pathless. It carries a per-cell block path, so an
      #     O(log n) publish bisect is not required to locate the offender —
      #     the row's "names NO block path" complaint was a CLI-side loss
      #     (fixed by #8809 / #13314), never a missing server-side path.
      assert {:error, {:invalid_paper_structure, %{"blocks" => errors}}} =
               BlockOps.validate_render_shapes([@wave11_table])

      assert errors == [
               "blocks[0].rows[0].cells[0] has no renderable inline content",
               "blocks[0].rows[0].cells[1] has no renderable inline content"
             ]

      assert BlockOps.validate_render_shapes(BlockOps.normalize_render_shapes([@wave11_table])) ==
               :ok
    end

    test "the wave-11 shape is idempotent under re-normalization" do
      once = BlockOps.normalize_render_shapes([@wave11_table])
      assert BlockOps.normalize_render_shapes(once) == once
    end
  end

  # ── the two table-head dialects the gate and the normalizer disagreed on ────

  describe "the `header` spelling is normalized, not just validated (task-7abe292dbfe567a6)" do
    # `header` is a FIRST-CLASS head dialect at both the gate
    # (`render_block_errors/2` reads `Map.get(block, "head") || Map.get(block,
    # "header")`) and the renderer (compose.ex `declared_head` falls back to
    # `header`) — but `normalize_table_leaves/1` only ever reached `rows` and
    # `head`. So a TipTap text-keyed leaf (`%{"type" => "text", "text" => …}`)
    # inside a `header` cell got NO inline-leaf dialect rescue: the block
    # published (the gate accepts the shape) and then rendered the header cell
    # as the empty string, forever — exactly the failure #11616 fixed for
    # every other inline-bearing surface.
    @header_dialect_table %{
      "type" => "table",
      "header" => [[%{"type" => "text", "text" => "Quantity"}]],
      "rows" => [[[%{"type" => "text", "text" => "51"}]]]
    }

    test "a text-keyed leaf in a `header` cell is rescued to the canonical `value` key" do
      assert [block] = BlockOps.normalize_render_shapes([@header_dialect_table])

      assert block["header"] == [[%{"type" => "text", "value" => "Quantity"}]]

      # the `rows` twin was already rescued — that asymmetry IS the defect
      assert block["rows"] == [[[%{"type" => "text", "value" => "51"}]]]
    end

    test "the rescue is render-PRESERVING — the row's stated blocker has expired" do
      # THE ROW DEFERRED THIS FIX ON A PREMISE THAT IS NO LONGER TRUE. It said
      # widening the rescue to `header` "changes rendered BYTES for papers that
      # publish today", because a text-keyed leaf "renders as the empty string
      # forever" — which is what #14561's negative-arm criterion forbade.
      #
      # `Render.Inline.compose_inline/2` has dual-read `value || text` since
      # 2026-08-23 (inline.ex: `case coerce_text_value(Map.get(n, "value", ""))
      # do "" -> coerce_text_value(Map.get(n, "text", ""))`), and its Go twin
      # does the same through `attrStrFirst(n, "value", "text")`. The leaf
      # already renders. What was missing is CANONICALIZATION of the stored
      # bytes — the single job this write chokepoint exists to do — so the fix
      # is byte-identical at the reader and #14561's criterion is satisfied,
      # not traded away.
      raw_html = Render.render_blocks([@header_dialect_table])
      normalized_html = Render.render_blocks(BlockOps.normalize_render_shapes([@header_dialect_table]))

      # non-vacuity: both halves of the block actually render.
      assert raw_html =~ "Quantity"
      assert raw_html =~ "51"

      assert normalized_html == raw_html
    end

    test "a `header` already carrying canonical leaves is byte-identical" do
      canonical = %{
        "type" => "table",
        "header" => [[%{"type" => "text", "value" => "Quantity"}]],
        "rows" => [[[%{"type" => "text", "value" => "51"}]]]
      }

      assert BlockOps.normalize_render_shapes([canonical]) == [canonical]
    end

    test "the `header` rescue is idempotent" do
      once = BlockOps.normalize_render_shapes([@header_dialect_table])
      assert BlockOps.normalize_render_shapes(once) == once
    end
  end

  describe "`head: true` is the promote-row-0 dialect, not a refusal (task-7abe292dbfe567a6)" do
    # compose.ex renders `{true, [first | rest]}` by promoting row 0 to the
    # head row, and `{true, []}` by rendering a headless table. The gate did
    # neither: with the head equal to `true` the case fell through to
    # `render_table_row_errors(true, path)`, whose catch-all emitted
    # "blocks[N].head has no renderable cells". `normalize_array_table/2`
    # rescues the shape ONLY when there is a row 0 that
    # `normalize_legacy_table_row/1` can normalize — an EMPTY `rows` list has
    # no row 0 to promote, so the flag survives normalization and the block
    # that the reader renders fine could never publish.
    test "`head: true` with no rows survives normalization and now passes the gate" do
      block = %{"type" => "table", "head" => true, "rows" => []}

      assert [normalized] = blocks = BlockOps.normalize_render_shapes([block])

      # non-vacuity: the flag is STILL there — the gate fix is what changed,
      # not a normalizer that quietly deleted the dialect.
      assert normalized["head"] == true

      assert BlockOps.validate_render_shapes(blocks) == :ok
    end

    test "`header: true` with no rows is accepted through the same fallback" do
      block = %{"type" => "table", "header" => true, "rows" => []}

      assert [normalized] = blocks = BlockOps.normalize_render_shapes([block])
      assert normalized["header"] == true
      assert BlockOps.validate_render_shapes(blocks) == :ok
    end

    test "the reader promotes row 0 — the gate refused a block compose renders whole" do
      raw = %{
        "type" => "table",
        "head" => true,
        "rows" => [
          [[%{"type" => "text", "value" => "Metric"}]],
          [[%{"type" => "text", "value" => "a"}]]
        ]
      }

      # The reader: row 0 becomes the head row, row 1 the body.
      html = Render.render_blocks([raw])
      assert html =~ "Metric"
      assert html =~ "a"

      # The gate, on the RAW shape: every row is renderable, and the ONLY
      # complaint is the head flag the renderer understands.
      assert BlockOps.validate_render_shapes([raw]) == :ok
    end

    test "`head: true` WITH a row 0 still normalizes to promoted cells (unchanged)" do
      # The gate's new `true` arm must not mask the normalizer: where a row 0
      # exists, the flag is still resolved into real head cells and dropped.
      block = %{"type" => "table", "head" => true, "rows" => [["Metric", "Value"], ["a", "b"]]}

      assert [normalized] = blocks = BlockOps.normalize_render_shapes([block])

      assert normalized["head"] == [
               [%{"type" => "text", "value" => "Metric"}],
               [%{"type" => "text", "value" => "Value"}]
             ]

      assert BlockOps.validate_render_shapes(blocks) == :ok
    end

    test "a head that is neither `true` nor a row of cells is STILL refused" do
      # The `true` arm is a named dialect, not a hole: any other unrenderable
      # head keeps its refusal, path and all.
      for bad <- [42, "Metric", %{"no" => "cells"}] do
        block = %{"type" => "table", "head" => bad, "rows" => [[["a"]]]}
        blocks = BlockOps.normalize_render_shapes([block])

        assert {:error, {:invalid_paper_structure, %{"blocks" => errors}}} =
                 BlockOps.validate_render_shapes(blocks),
               "expected a refusal for head #{inspect(bad)}"

        assert "blocks[0].head has no renderable cells" in errors
      end
    end
  end

  # ── idempotency ─────────────────────────────────────────────────────────────

  test "the whole normalization pass is idempotent" do
    blocks = [
      %{"type" => "notes", "items" => ["string item"]},
      %{"type" => "pipeline", "nodes" => ["node"]},
      %{
        "type" => "paragraph",
        "content" => [%{"type" => "text", "text" => "dialect prose"}]
      },
      %{"type" => "table", "head" => ["H"], "rows" => [["cell"]]},
      %{"type" => "byline", "items" => ["Fable", "2026-08-12"]}
    ]

    once = BlockOps.normalize_render_shapes(blocks)
    assert BlockOps.normalize_render_shapes(once) == once
  end
end
