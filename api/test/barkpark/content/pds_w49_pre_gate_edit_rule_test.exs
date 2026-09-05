defmodule Barkpark.Content.PdsW49PreGateEditRuleTest do
  @moduledoc """
  THE 2026-09-02 GRANDFATHER RULING, AS A MECHANISM.

  38 of 1050 published Papers (measured at origin/main
  `02c3b735421eae54f66bc58c49da74228a9736ba`, register at
  `tooling/pds/pre-gate-papers.json`) carry stored blocks the Paper publish gate
  refuses today. They published before the gate existed. The ruling:

    * already-published rows STAY READABLE and are NEVER retroactively refused;
    * the gate binds new publishes AND EDITS — the next edit of such a Paper
      must satisfy the gate;
    * the registered set may shrink, never grow (the ratchet lives in
      `scripts/pds-pre-gate-papers-check.sh`).

  "The next edit must satisfy the gate" is the half that is easy to write down
  and easy to leave as prose. This file makes it a mechanism: the two
  grandfathered shapes, VERBATIM from the live corpus, are planted in a draft
  and re-published, and the gate refuses — at every location a reader reads.

  It also PINS THE READER BEHAVIOUR the ruling was made on, because that is the
  fact the ruling rests on and the fact a future normaliser change would
  silently invalidate:

    * class `legacy_header_key_bare_string_cells` (37 papers, 440 refusals) —
      the reader renders the header text CORRECTLY. The refusal is a
      normaliser/validator key asymmetry: `validate_render_shapes/1` reads
      `head || header`, `normalize_table_leaves/1` rescues bare-string cells
      under `head` ONLY. Nothing is lost to a reader; the ruling's cost is that
      an author editing one of these 37 is refused on a header that renders.

    * class `double_wrapped_head_row_list` (1 paper, 5 refusals) — `head` holds
      a list containing a ROW object instead of the cells. The reader emits ONE
      EMPTY `<th>` where two labels were authored. This is the only Paper of the
      38 whose readers actually lose content.

  If either reader assertion flips, this file reds and the register's recorded
  reader behaviour — and therefore the ruling — is stale.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.Projection
  alias Barkpark.PortableDoc.Render
  alias Barkpark.Repo

  @dataset "pds_w49_pre_gate_edit_rule_test"

  # The three STORED locations `Projection.read_blocks/1` accepts. The corpus
  # measurement found all 38 refusals at `:top`, but the gate's scope descends
  # from the reader, so the EDIT rule must hold wherever a writer put the list —
  # otherwise "the next edit must satisfy the gate" is defeatable by switching
  # keys, which is exactly the hole #14977 closed.
  @locations [:top, :body_blocks, :body_list]

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)
    :ok
  end

  # ── the two grandfathered shapes, VERBATIM from the live corpus ────────────

  # `agent-flight-recorder-charter`, block `block-5`, published 2026-07-12.
  # Note the key: `header`, not `head`.
  defp legacy_header_block do
    %{
      "type" => "table",
      "id" => "block-5",
      "header" => ["Moment", "What is stored", "Where", "Cost (measured)"],
      "rows" => [
        [
          [%{"type" => "text", "value" => "claim"}],
          [%{"type" => "text", "value" => "priming manifest"}]
        ]
      ]
    }
  end

  # `studio-space-priority-desk-advance-2026-07-19`, block `dg-cov-t`,
  # published 2026-07-19. `head` is a list holding a ROW object.
  defp double_wrapped_head_block do
    %{
      "type" => "table",
      "id" => "dg-cov-t",
      "head" => [
        %{
          "cells" => [
            %{"content" => [%{"type" => "text", "value" => "Corner"}]},
            %{"content" => [%{"type" => "text", "value" => "Verdict"}]}
          ]
        }
      ],
      "rows" => [
        [
          [%{"type" => "text", "value" => "origin/main PR state"}],
          [%{"type" => "text", "value" => "FOUND"}]
        ]
      ]
    }
  end

  @shapes [
    {:legacy_header_key_bare_string_cells,
     "blocks[0].head.cells[0] has no renderable inline content"},
    {:double_wrapped_head_row_list, "blocks[0].head.cells[0] has no renderable inline content"}
  ]

  defp block_for(:legacy_header_key_bare_string_cells), do: legacy_header_block()
  defp block_for(:double_wrapped_head_row_list), do: double_wrapped_head_block()

  defp place(:top, blocks), do: %{"blocks" => blocks}
  defp place(:body_blocks, blocks), do: %{"body" => %{"blocks" => blocks}}
  defp place(:body_list, blocks), do: %{"body" => blocks}

  defp insert_paper!(id, location, blocks, status) do
    content = Barkpark.LabelFixtures.with_registered_labels(place(location, blocks), @dataset)

    # NON-VACUITY: the whole ruling is about what READERS see, so every fixture
    # first proves the readers' own locator finds the planted list here. If
    # `read_blocks/1` stops reading a location, this fires instead of the
    # refusal assertions quietly passing on a location nobody renders.
    assert Projection.read_blocks(content) == blocks

    doc_id = if status == "draft", do: "drafts." <> id, else: id

    %Document{}
    |> Document.changeset(%{
      "doc_id" => doc_id,
      "type" => "paper",
      "dataset" => @dataset,
      "title" => "Pre-gate #{id}",
      "status" => status,
      "content" => content,
      "rev" => "source-rev-" <> id
    })
    |> Repo.insert!()

    id
  end

  describe "the recorded reader behaviour — the fact the ruling rests on" do
    test "the legacy `header` bare-string class renders its header text CORRECTLY" do
      block = legacy_header_block()

      # The gate refuses it …
      assert {:error, {:invalid_paper_structure, %{"blocks" => errors}}} =
               [block] |> BlockOps.normalize_render_shapes() |> BlockOps.validate_render_shapes()

      assert "blocks[0].head.cells[0] has no renderable inline content" in errors

      # … and normalisation does not even TOUCH it: `normalize_table_leaves/1`
      # rescues bare-string cells under `head`, never under the legacy `header`
      # spelling the validator reads. That asymmetry IS the refusal.
      assert BlockOps.normalize_render_shapes([block]) == [block],
             "normalisation now rewrites the legacy `header` key — the register's class " <>
               "`legacy_header_key_bare_string_cells` is stale and the ruling needs re-deriving"

      # … but the reader loses NOTHING. Every authored label reaches the page.
      html = Render.render_blocks([block], %{})

      for label <- ["Moment", "What is stored", "Where", "Cost (measured)"] do
        assert html =~ "<span>#{label}</span>",
               "the reader stopped rendering the header label #{inspect(label)} — the register " <>
                 "records reader_impact \"none\" for this class and would now be WRONG"
      end
    end

    test "the double-wrapped `head` class renders an EMPTY header cell — real reader loss" do
      block = double_wrapped_head_block()

      assert {:error, {:invalid_paper_structure, %{"blocks" => errors}}} =
               [block] |> BlockOps.normalize_render_shapes() |> BlockOps.validate_render_shapes()

      assert "blocks[0].head.cells[0] has no renderable inline content" in errors

      html = Render.render_blocks([block], %{})

      # The authored labels are GONE from the header …
      [head_html] = Regex.run(~r{<thead>.*?</thead>}s, html)
      refute head_html =~ "Corner"
      refute head_html =~ "Verdict"

      # … replaced by exactly one empty `<th>`: the page answers, the labels do
      # not. This is the register's `reader_impact: "blank_header_cell"`.
      assert length(Regex.scan(~r{<th\b}, head_html)) == 1
      assert head_html =~ ~r{<th\b[^>]*></th>}

      # The BODY still renders — the loss is confined to the head, which is why
      # this is grandfathered debt and not an outage.
      assert html =~ "origin/main PR state"
    end
  end

  describe "the ruling is NOT retroactive" do
    test "an already-published pre-gate Paper stays readable at every location" do
      for {shape, _} <- @shapes, location <- @locations do
        id = insert_paper!("live-#{shape}-#{location}", location, [block_for(shape)], "published")

        assert {:ok, doc} = Content.get_document(id, "paper", @dataset)

        # The read path never runs the gate. A published pre-gate row is served,
        # not refused — the half of the ruling that protects 38 live Papers.
        assert Projection.read_blocks(doc.content) == [block_for(shape)]
        assert is_binary(Render.render_blocks(Projection.read_blocks(doc.content), %{}))
      end
    end
  end

  describe "the EDIT-time rule — what makes \"the next edit must satisfy the gate\" a mechanism" do
    test "publishing an edit of a grandfathered shape is REFUSED at every reader-rendered location" do
      for {shape, expected_error} <- @shapes do
        verdicts =
          Map.new(@locations, fn location ->
            id = insert_paper!("edit-#{shape}-#{location}", location, [block_for(shape)], "draft")
            {location, Content.publish_document(id, "paper", @dataset)}
          end)

        for {location, verdict} <- verdicts do
          # `match?/2` keeps the message LIVE: a bare `assert pattern = verdict`
          # raises MatchError before assert/2 reads its message, so the shape and
          # location that failed would never be named.
          assert match?({:error, {:invalid_paper_structure, %{"blocks" => _}}}, verdict),
                 "#{shape} at #{inspect(location)} published UNGATED: #{inspect(verdict)}"

          {:error, {:invalid_paper_structure, %{"blocks" => errors}}} = verdict

          assert expected_error in errors,
                 "#{shape} at #{inspect(location)} refused for the wrong reason: #{inspect(errors)}"
        end

        # One verdict, three writers: the edit rule is a property of the CONTENT,
        # not of the key the author's tool happened to use.
        assert verdicts |> Map.values() |> Enum.uniq() |> length() == 1

        # A refused edit leaves the draft where it was — the gate is
        # side-effect-free, so a grandfathered Paper is never half-migrated.
        for location <- @locations do
          id = "edit-#{shape}-#{location}"
          assert {:ok, _} = Content.get_document("drafts." <> id, "paper", @dataset)
          assert {:error, :not_found} = Content.get_document(id, "paper", @dataset)
        end
      end
    end

    test "the gate is a DOOR, not a wall: the mechanical repair of each shape publishes clean" do
      # The ruling says the next edit must SATISFY the gate. That is only a fair
      # burden if satisfying it is reachable, so both repairs are pinned here —
      # they are the exact patches `tooling/pds/pre-gate-papers.json` names.

      # class `legacy_header_key_bare_string_cells`: rename the legacy `header`
      # spelling to `head`, which normalisation already rescues.
      repaired_legacy =
        legacy_header_block()
        |> Map.put("head", legacy_header_block()["header"])
        |> Map.delete("header")

      id = insert_paper!("repair-legacy", :top, [repaired_legacy], "draft")
      assert {:ok, published} = Content.publish_document(id, "paper", @dataset)

      assert [table] = published.content["blocks"]

      assert table["head"] == [
               [%{"type" => "text", "value" => "Moment"}],
               [%{"type" => "text", "value" => "What is stored"}],
               [%{"type" => "text", "value" => "Where"}],
               [%{"type" => "text", "value" => "Cost (measured)"}]
             ]

      # class `double_wrapped_head_row_list`: unwrap TWICE — to the CELLS, not to
      # the row object. The one-level unwrap is the obvious repair and it is a
      # TRAP: see the next test.
      [%{"cells" => cells}] = double_wrapped_head_block()["head"]
      repaired_wrapped = Map.put(double_wrapped_head_block(), "head", cells)

      id2 = insert_paper!("repair-wrapped", :top, [repaired_wrapped], "draft")
      assert {:ok, published2} = Content.publish_document(id2, "paper", @dataset)

      # And the repair is not cosmetic: the labels the reader was dropping now
      # reach the page.
      html = Render.render_blocks(published2.content["blocks"], %{})
      [head_html] = Regex.run(~r{<thead>.*?</thead>}s, html)
      assert head_html =~ "Corner"
      assert head_html =~ "Verdict"
    end

    test "the OBVIOUS repair of the double-wrapped head satisfies the gate and STILL loses the header" do
      # `head: [%{"cells" => cs}]` -> `head: %{"cells" => cs}` is the repair a
      # reader of the refusal message would reach for first, and the gate ACCEPTS
      # it: `validate_render_shapes/1` routes a `%{"cells" => list}` head through
      # `render_table_row_errors/2` and finds every cell renderable.
      #
      # The RENDERER does not agree. `Render.Compose` only promotes `head` to a
      # header row when `is_list(declared_head)`, so a MAP head falls through to
      # `legacy_head || column_head` — both nil — and the table renders with NO
      # `<thead>` at all. Gate-green, header gone.
      #
      # This is pinned because it is the failure mode the ruling invites: 38
      # Papers are told "your next edit must satisfy the gate", and the repair
      # that satisfies it is not the repair that fixes the reader. Anyone
      # backfilling `double_wrapped_head_row_list` must unwrap to the CELLS.
      [row] = double_wrapped_head_block()["head"]
      naive = Map.put(double_wrapped_head_block(), "head", row)

      assert :ok ==
               [naive] |> BlockOps.normalize_render_shapes() |> BlockOps.validate_render_shapes(),
             "the gate now refuses the map-head repair — the trap this test documents is closed " <>
               "and tooling/pds/pre-gate-papers.json can drop its warning"

      id = insert_paper!("repair-naive", :top, [naive], "draft")
      assert {:ok, published} = Content.publish_document(id, "paper", @dataset)

      html = Render.render_blocks(published.content["blocks"], %{})
      refute html =~ "<thead>"
      refute html =~ "Corner"
      refute html =~ "Verdict"

      # The body survives — the loss is the header, exactly as before the repair.
      assert html =~ "origin/main PR state"
    end
  end

  describe "the register itself" do
    test "names every paper it rules on, with a reason and a reader impact" do
      register =
        Path.join([__DIR__, "..", "..", "..", "..", "tooling", "pds", "pre-gate-papers.json"])
        |> Path.expand()

      assert File.exists?(register), "the grandfather register is missing: #{register}"

      decoded = register |> File.read!() |> Jason.decode!()

      # A ruling that names no rows rules on nothing. This also catches the
      # failure mode where a future edit empties the register to make the
      # ratchet in scripts/pds-pre-gate-papers-check.sh trivially pass.
      assert length(decoded["papers"]) == 38
      assert decoded["ruling"]["verdict"] == "grandfather"

      for paper <- decoded["papers"] do
        assert is_binary(paper["id"]) and paper["id"] != ""
        assert paper["ruling"] == "grandfathered"
        assert is_list(paper["reasons"]) and paper["reasons"] != []
        assert paper["reader_impact"] in ["none", "blank_header_cell"]
      end

      # The classes the reader-behaviour tests above pin must be the classes the
      # register rules on — otherwise those tests vouch for a document that no
      # longer says what they proved.
      assert decoded["classes"] |> Enum.map(& &1["class"]) |> Enum.sort() ==
               ["double_wrapped_head_row_list", "legacy_header_key_bare_string_cells"]

      assert decoded["measurement"]["repo_sha"] ==
               "02c3b735421eae54f66bc58c49da74228a9736ba"
    end
  end
end
