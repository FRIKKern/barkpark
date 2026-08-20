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
end
