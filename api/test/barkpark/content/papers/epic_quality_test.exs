defmodule Barkpark.Content.Papers.EpicQualityTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.EpicQuality

  @epic_tag %{
    "tag" => "epic-cycle-wave-paper",
    "strength" => 90,
    "rationale" => "canonical Epic Cycle Paper"
  }

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp paragraph(value), do: %{"type" => "paragraph", "content" => text(value)}
  defp h1(value \\ "A decisive title"), do: %{"type" => "heading", "level" => 1, "text" => value}

  defp ingress(value \\ "Why this wave exists and what it changes."),
    do: %{"type" => "ingress", "content" => text(value)}

  defp stats do
    %{
      "type" => "stats",
      "items" => [%{"label" => "verified criteria", "value" => "7"}]
    }
  end

  defp valid_content do
    %{
      "tags" => [@epic_tag],
      "blocks" => [
        h1(),
        ingress(),
        stats(),
        paragraph("The evidence explains the result and its consequence.")
      ]
    }
  end

  test "unrelated Papers are outside the canonical Epic gate" do
    assert :ok = EpicQuality.validate(%{"tags" => [], "blocks" => []})
  end

  test "the reference-shaped opening passes without rewarding ornament or volume" do
    assert :ok = EpicQuality.validate(valid_content())
  end

  test "hollow, micro-only, gap-heavy and unframed candidates report stable hard failures" do
    content = %{
      "tags" => [@epic_tag],
      "blocks" => [
        h1(),
        %{"type" => "paragraph", "content" => []}
      ]
    }

    assert {:error, {:invalid_epic_paper_quality, details}} = EpicQuality.validate(content)

    assert details["failures"] == [
             "empty_paragraph_spacer",
             "micro_only",
             "opening_missing_ingress",
             "opening_missing_orientation"
           ]
  end

  test "a missing H1 and heading jump fail the outline and opening contracts" do
    content = %{
      valid_content()
      | "blocks" => [
          ingress(),
          stats(),
          %{"type" => "heading", "level" => 2, "text" => "Starts too deep"},
          %{"type" => "heading", "level" => 4, "text" => "Skips a level"}
        ]
    }

    assert {:error, {:invalid_epic_paper_quality, details}} = EpicQuality.validate(content)

    assert "opening_missing_h1" in details["failures"]
    assert "outline_requires_one_h1" in details["failures"]
    assert "outline_heading_level_jump" in details["failures"]
  end

  test "the outline arms read headings inside containers, not only the top level" do
    nested_jump =
      update_in(valid_content(), ["blocks"], fn blocks ->
        blocks ++
          [
            %{
              "type" => "expandable",
              "summary" => "Appendix",
              "children" => [
                %{"type" => "heading", "level" => 4, "text" => "Skips a level while nested"},
                paragraph("The nested body still reads as part of one outline.")
              ]
            }
          ]
      end)

    assert {:error, {:invalid_epic_paper_quality, jump_details}} =
             EpicQuality.validate(nested_jump)

    assert "outline_heading_level_jump" in jump_details["failures"]

    nested_second_h1 =
      update_in(valid_content(), ["blocks"], fn blocks ->
        blocks ++
          [
            %{
              "type" => "expandable",
              "summary" => "Appendix",
              "children" => [
                h1("A second title hidden one level down"),
                paragraph("Two H1s are two outlines, wherever the second one hides.")
              ]
            }
          ]
      end)

    assert {:error, {:invalid_epic_paper_quality, h1_details}} =
             EpicQuality.validate(nested_second_h1)

    assert "outline_requires_one_h1" in h1_details["failures"]
  end

  test "numeric-string heading levels are read the way the renderer reads them" do
    string_h1 = %{
      valid_content()
      | "blocks" => [
          %{"type" => "heading", "level" => "1", "text" => "A decisive title"},
          ingress(),
          stats(),
          paragraph("The evidence explains the result and its consequence.")
        ]
    }

    assert :ok = EpicQuality.validate(string_h1)

    string_jump =
      update_in(valid_content(), ["blocks"], fn blocks ->
        blocks ++ [%{"type" => "heading", "level" => "4", "text" => "Skips a level"}]
      end)

    assert {:error, {:invalid_epic_paper_quality, jump_details}} =
             EpicQuality.validate(string_jump)

    assert "outline_heading_level_jump" in jump_details["failures"]
    refute "outline_requires_one_h1" in jump_details["failures"]

    non_numeric =
      update_in(valid_content(), ["blocks"], fn blocks ->
        blocks ++ [%{"type" => "heading", "level" => "h2", "text" => "Not a level at all"}]
      end)

    assert :ok = EpicQuality.validate(non_numeric)
  end

  test "an explicitly declared reader suite must name five passing readers" do
    checks = %{
      "public" => "pass",
      "studio" => true,
      "tui80" => "fail",
      "email" => "pass"
    }

    assert {:error, {:invalid_epic_paper_quality, details}} =
             valid_content()
             |> Map.put("reader_checks", checks)
             |> EpicQuality.validate()

    assert "reader_tui80_failed" in details["failures"]
    assert "reader_cli_api_failed" in details["failures"]
  end

  test "a complete declared five-reader suite passes" do
    checks = Map.new(EpicQuality.required_readers(), &{&1, "pass"})

    assert :ok =
             valid_content()
             |> Map.put("reader_checks", checks)
             |> EpicQuality.validate()
  end

  test "reference-style procedures require short action titles and real bodies" do
    content =
      update_in(valid_content(), ["blocks"], fn blocks ->
        blocks ++
          [
            %{
              "type" => "steps",
              "steps" => [
                %{
                  "title" => "State the governing constraint",
                  "blocks" => [
                    paragraph("Explain why it matters and what changes next.")
                  ]
                }
              ]
            }
          ]
      end)

    assert :ok = EpicQuality.validate(content)
  end

  test "title-only procedures and headerless tables fail semantic composition" do
    content =
      update_in(valid_content(), ["blocks"], fn blocks ->
        blocks ++
          [
            %{
              "type" => "steps",
              "steps" => [
                %{
                  "title" =>
                    "This entire paragraph was stuffed into a title even though a step needs a concise action and a real body that explains its purpose and evidence",
                  "blocks" => []
                }
              ]
            },
            %{"type" => "table", "rows" => [[text("column"), text("meaning")]]}
          ]
      end)

    assert {:error, {:invalid_epic_paper_quality, details}} = EpicQuality.validate(content)

    assert "empty_step_body" in details["failures"]
    assert "overloaded_step_title" in details["failures"]
    assert "table_missing_header" in details["failures"]
  end

  test "collapsed appendices preserve evidence without bloating the first pass" do
    appendix =
      "evidence"
      |> List.duplicate(5_100)
      |> Enum.join(" ")

    content =
      update_in(valid_content(), ["blocks"], fn blocks ->
        blocks ++
          [
            %{
              "type" => "expandable",
              "summary" => "Full evidence appendix",
              "children" => [paragraph(appendix)]
            }
          ]
      end)

    assert :ok = EpicQuality.validate(content)
  end

  test "an unstructured primary reading wall fails the editorial floor" do
    wall =
      "primary"
      |> List.duplicate(5_100)
      |> Enum.join(" ")

    content =
      update_in(valid_content(), ["blocks"], fn blocks ->
        blocks ++ [paragraph(wall)]
      end)

    assert {:error, {:invalid_epic_paper_quality, details}} = EpicQuality.validate(content)
    assert "primary_reading_load_exceeded" in details["failures"]
  end

  # ── the spacer predicate reads TEXT, not key shape ─────────────────────────
  #
  # `empty_paragraph?/1` used to test `content in [nil, []]` plus a blank
  # `text` key. That contradicted `meaningful?/1` in this same module (whose
  # `@text_keys` already include `value`) and misfired in BOTH directions.
  # Both pins below FAIL against that predicate.

  test "value-keyed prose is NOT a spacer - the three live leaves of felix-pristine-wave-14" do
    # Shapes read off the published paper on 2026-08-24: blocks[47]/[48]/[54]
    # are paragraphs whose content[0] is a paragraph carrying 633-841
    # characters of prose under `value`, with no `content` and no `text`.
    leaves =
      for value <- [
            "A1 (xlsx zip-bomb) CONFIRMED offline: a 1.45 MiB archive materialised 400 MiB via :zip.extract(binary, [:memory]) with no cap.",
            "A4 (media /meta) CONFIRMED LIVE: anonymous GET /media/:id/meta returned a private asset's filename, path and size.",
            "Backlog (published epic children): task-felix-w14-media-meta-fieldvis-leak (P1, out-of-fence), task-felix-w14-xlsx-zip-bomb-cap (P1)."
          ],
          do: %{"type" => "paragraph", "content" => [%{"type" => "paragraph", "value" => value}]}

    # Asserted through the PUBLIC gate, so this pin fails on the BEHAVIOUR
    # (the paper 422s on prose) rather than on the predicate's visibility.
    content = update_in(valid_content(), ["blocks"], &(&1 ++ leaves))

    refute :empty_paragraph_spacer in EpicQuality.failures(content),
           "value-keyed prose is real content, not an authored spacer"

    assert :ok = EpicQuality.validate(content)
  end

  test "a paragraph that renders blank is STILL a spacer, however its emptiness is spelled" do
    # The old predicate caught only the literal `content: []`; every other
    # spelling of "renders nothing" sailed through, because a content list
    # holding an inline leaf is merely non-EMPTY, never proof of prose.
    for {label, block} <- [
          # akerbrygge-gjennomgang-2026-08-07 blocks[253], verbatim: one of the
          # authored spacers the flipped spacing doctrine removed. `id` is inert
          # to the predicate and is kept so the pin names a REAL block.
          {"content: [] (akerbrygge blocks[253])",
           %{"type" => "paragraph", "content" => [], "id" => "i200"}},
          {"an empty inline leaf",
           %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => ""}]}},
          {"a whitespace inline leaf",
           %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "   "}]}},
          {"an inline leaf with no value at all",
           %{"type" => "paragraph", "content" => [%{"type" => "text"}]}},
          {"a blank text key", %{"type" => "paragraph", "text" => "  "}},
          {"an empty value key", %{"type" => "paragraph", "value" => ""}}
        ] do
      content = update_in(valid_content(), ["blocks"], &(&1 ++ [block]))

      assert {:error, {:invalid_epic_paper_quality, details}} = EpicQuality.validate(content)

      assert "empty_paragraph_spacer" in details["failures"],
             "the wall stopped biting for: #{label}"
    end
  end

  test "empty_paragraph?/1 is the public one-owner predicate the advisory mirror shares" do
    # AuthoringWall.count_spacer_paragraphs/1 calls THIS, so the advisory can no
    # longer drift from the hard gate by re-deriving its own key list.
    refute EpicQuality.empty_paragraph?(%{
             "type" => "paragraph",
             "value" => "Prose carried under the documented value key."
           })

    assert EpicQuality.empty_paragraph?(%{
             "type" => "paragraph",
             "content" => [%{"type" => "text", "value" => ""}]
           })

    refute EpicQuality.empty_paragraph?(%{"type" => "heading", "level" => 1, "text" => "Heading"})
  end
end
