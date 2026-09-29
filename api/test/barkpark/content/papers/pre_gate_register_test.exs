defmodule Barkpark.Content.Papers.PreGateRegisterTest do
  @moduledoc """
  The reader half of the 2026-09-02 grandfather ruling (task-076719e53a42102d):
  a Paper named in `tooling/pds/pre-gate-papers.json` AND still refused by the
  block gate wears ONE quiet badge under its byline; every other Paper wears
  none. Pure — no DB, no Phoenix boot — so the render is exercised through the
  same `Render.render_block/2` call both LiveViews make.

  Three rows, one per branch of the rule:

    * a REGISTER id with a still-refused block list → badge;
    * a NON-register id with the SAME refused block list → no badge
      (membership is required — the gate alone never badges);
    * a HEALED register id (blocks the gate accepts) → no badge
      (the recheck is required — the register alone never badges).

  Plus the "no second id list" proof: no source under `lib/` carries two or
  more register ids, and the loader inlines none — the JSON is the only source
  of membership.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.Content.Papers.PreGateRegister
  alias Barkpark.PortableDoc.Render

  # A register id from the `legacy_header_key_bare_string_cells` class (37 of
  # the 38) — reader_impact "none" → the neutral tone.
  @register_id "agent-flight-recorder-charter"
  # The one `double_wrapped_head_row_list` paper — reader_impact
  # "blank_header_cell" → the warning tone.
  @warning_id "studio-space-priority-desk-advance-2026-07-19"
  @outsider_id "heggemsnes-act"

  # `agent-flight-recorder-charter` block-5, verbatim shape: `header` (legacy
  # spelling) with bare-string cells — the gate refuses, the reader renders.
  @legacy_header_table %{
    "type" => "table",
    "id" => "block-5",
    "header" => ["Moment", "What is stored", "Where", "Cost (measured)"],
    "rows" => [[[%{"type" => "text", "value" => "claim"}], [%{"type" => "text", "value" => "x"}]]]
  }

  @masthead [
    %{"type" => "eyebrow", "id" => "b0", "text" => "Goal charter"},
    %{"type" => "heading", "id" => "b1", "level" => 1, "text" => "The flight recorder"},
    %{"type" => "byline", "id" => "b2", "items" => ["lead-papers", "2026-07-17"]}
  ]

  @refused @masthead ++ [@legacy_header_table]

  # The SAME table, healed the way the gate's own normaliser heals `head`.
  @healed @masthead ++
            [
              %{
                "type" => "table",
                "id" => "block-5",
                "head" => ["Moment", "What is stored"],
                "rows" => [
                  [
                    [%{"type" => "text", "value" => "claim"}],
                    [%{"type" => "text", "value" => "x"}]
                  ]
                ]
              }
            ]

  defp render_all(blocks),
    do: blocks |> Enum.map(&Render.render_block(&1, %{style: :article})) |> Enum.join()

  defp badge_blocks(blocks),
    do: Enum.filter(blocks, &(&1["type"] == PreGateRegister.badge_type()))

  setup_all do
    # The register is owned by tooling/pds (PR #15234). This suite is the
    # tripwire for its absence — a build without it compiles to an empty
    # register and would make every "no badge" row below vacuous.
    assert File.exists?(PreGateRegister.register_path()),
           "pre-gate register missing at #{PreGateRegister.register_path()} — " <>
             "this PR lands after #15234; the badge cannot be exercised without the file"

    assert PreGateRegister.loaded?()
    :ok
  end

  describe "the register" do
    test "names the ruling's ids and joins the class fields the badge needs" do
      assert MapSet.member?(PreGateRegister.ids(), @register_id)
      assert MapSet.member?(PreGateRegister.ids(), @warning_id)
      refute MapSet.member?(PreGateRegister.ids(), @outsider_id)

      entry = PreGateRegister.entry(@register_id)
      assert entry.reader_impact == "none"
      assert is_binary(entry.reader_behaviour) and entry.reader_behaviour != ""

      assert PreGateRegister.entry(@warning_id).reader_impact == "blank_header_cell"

      # A draft of a grandfathered paper resolves to the same entry.
      assert PreGateRegister.entry("drafts." <> @register_id) == entry
      assert PreGateRegister.entry(nil) == nil
    end

    test "the fixture blocks really are refused / accepted by the gate predicate" do
      # Non-vacuity: if the normaliser ever learns the legacy `header` spelling,
      # @refused stops being refused and the WITH row below would go vacuous —
      # this fires first.
      assert {:error, _} =
               @refused |> BlockOps.normalize_render_shapes() |> BlockOps.validate_render_shapes()

      assert :ok =
               @healed |> BlockOps.normalize_render_shapes() |> BlockOps.validate_render_shapes()
    end
  end

  describe "the badge rule — membership AND a still-refused recheck" do
    test "a register id with refused blocks renders the badge under the byline" do
      annotated = PreGateRegister.annotate(@refused, @register_id)

      assert [badge] = badge_blocks(annotated)
      # Directly after the byline (index 2) — the masthead anchor.
      assert Enum.find_index(annotated, &(&1 == badge)) == 3
      assert badge["anchor"] == "byline"

      html = render_all(annotated)
      assert html =~ ~s(<p class="bp-pregate bp-pregate--neutral bp-pregate--tucked")
      assert html =~ ">Published before the block gate</p>"
      # The register's reader_behaviour rides as the title attribute, escaped.
      assert html =~ ~s( title="GRANDFATHERED. The reader renders this shape CORRECTLY)
      refute html =~ "bp-pregate--warning"
    end

    test "a NON-register id with the SAME refused blocks renders no badge" do
      assert PreGateRegister.annotate(@refused, @outsider_id) == @refused
      refute render_all(@refused) =~ "bp-pregate"
    end

    test "a HEALED register id (blocks the gate accepts) renders no badge" do
      assert PreGateRegister.badge(@register_id, @healed) == nil
      assert PreGateRegister.annotate(@healed, @register_id) == @healed
      refute render_all(@healed) =~ "bp-pregate"
    end

    test "the recheck reads the STORED blocks, not the rendered list" do
      # A resolved/expanded list may differ from what the gate reads; the
      # badge decision must follow the stored list handed as the third arg.
      assert PreGateRegister.annotate(@healed, @register_id, @refused)
             |> badge_blocks()
             |> length() == 1

      assert PreGateRegister.annotate(@refused, @register_id, @healed) == @refused
    end

    test "the blank-header paper takes the warning tone and says what is missing" do
      annotated = PreGateRegister.annotate(@refused, @warning_id)
      html = render_all(annotated)
      assert html =~ "bp-pregate--warning"
      assert html =~ "one table header renders empty</p>"
    end
  end

  describe "the anchor" do
    test "a paper with no byline anchors under its title; with neither, first" do
      no_byline = [Enum.at(@masthead, 0), Enum.at(@masthead, 1), @legacy_header_table]
      annotated = PreGateRegister.annotate(no_byline, @register_id)
      assert [%{"anchor" => "heading"}] = badge_blocks(annotated)
      assert Enum.at(annotated, 2)["type"] == PreGateRegister.badge_type()
      refute render_all(annotated) =~ "bp-pregate--tucked"

      bare = [@legacy_header_table]
      annotated = PreGateRegister.annotate(bare, @register_id)
      assert [%{"anchor" => "top"}] = badge_blocks(annotated)
      assert hd(annotated)["type"] == PreGateRegister.badge_type()
    end

    test "a byline deep in the body is not the masthead byline" do
      body_byline = [
        Enum.at(@masthead, 1),
        %{"type" => "heading", "id" => "s", "level" => 2, "text" => "Section"},
        Enum.at(@masthead, 2),
        @legacy_header_table
      ]

      annotated = PreGateRegister.annotate(body_byline, @register_id)
      assert Enum.at(annotated, 1)["type"] == PreGateRegister.badge_type()
    end
  end

  describe "off the article surface" do
    test "the email palette carries the mark inline, no class" do
      [badge] = PreGateRegister.annotate(@refused, @register_id) |> badge_blocks()
      html = Render.render_block(badge, %{})
      assert html =~ "Published before the block gate"
      assert html =~ "text-transform:uppercase"
      refute html =~ "class="
    end
  end

  describe "one register, no second list" do
    @lib_dir Path.expand("../../../../lib", __DIR__)

    test "no source under lib/ carries a register LIST — the JSON is the only source" do
      ids = PreGateRegister.ids() |> MapSet.to_list()
      assert ids != []

      # A "second list" is two or more register ids in one file. One id can
      # occur legitimately as data (gen_pd_parity uses `paper:scaffy-benchmark`
      # as a sample sourceDefault); a membership list cannot stop at one. The
      # loader itself carries ZERO literals — it reads the JSON.
      offenders =
        [@lib_dir, "**", "*.{ex,exs,heex}"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          src = File.read!(path)

          case Enum.filter(ids, &String.contains?(src, &1)) do
            hits when length(hits) >= 2 -> [{Path.relative_to(path, @lib_dir), hits}]
            _ -> []
          end
        end)

      assert offenders == [],
             "a register id list is hand-kept in lib/ — membership must come from " <>
               "tooling/pds/pre-gate-papers.json only: #{inspect(offenders)}"

      loader = File.read!(Path.join(@lib_dir, "barkpark/content/papers/pre_gate_register.ex"))
      refute Enum.any?(ids, &String.contains?(loader, &1)), "the loader must not inline an id"
    end
  end
end
