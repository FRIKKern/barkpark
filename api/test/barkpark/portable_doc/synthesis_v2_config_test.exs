defmodule Barkpark.PortableDoc.SynthesisV2ConfigTest do
  @moduledoc """
  Synthesized/scaffolded v2 field blocks must carry their structural config.

  `PaperFieldBlock.build_field/1` reads the element shape OFF THE BLOCK
  ("of" / "fields" / "codelistId" / "languages"). A bound block emitted
  without it degrades: an arrayOf-of-composite renders its row maps through
  ArrayField's `leaf_input`, whose `to_string/1` crashed the whole Studio
  LiveView (first hit: the task schema's `acceptance_criteria` in the Beta
  editor). These tests pin the config onto both the legacy-doc synthesis
  path and the create-time scaffold path.
  """

  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Synthesis

  @criterion_of %{
    "name" => "criterion",
    "type" => "composite",
    "fields" => [
      %{"name" => "criterion", "title" => "Criterion", "type" => "text"},
      %{"name" => "met", "title" => "Met", "type" => "boolean"}
    ]
  }

  @fields [
    %{"name" => "title", "type" => "string"},
    %{
      "name" => "acceptance_criteria",
      "title" => "Acceptance criteria",
      "type" => "arrayOf",
      "ordered" => true,
      "of" => @criterion_of
    },
    %{
      "name" => "estimate",
      "title" => "Estimate",
      "type" => "composite",
      "fields" => [%{"name" => "size", "type" => "select", "options" => ["s", "m"]}]
    }
  ]

  @layout [
    %{"kind" => "field", "name" => "title"},
    %{"kind" => "field", "name" => "acceptance_criteria"},
    %{"kind" => "field", "name" => "estimate"}
  ]

  describe "synthesize/3 carries v2 structural config" do
    test "arrayOf block keeps its of descriptor, ordered flag, and label" do
      content = %{
        "title" => "T",
        "acceptance_criteria" => [%{"criterion" => "done", "met" => false}],
        "estimate" => %{"size" => "m"}
      }

      blocks = Synthesis.synthesize(@layout, content, @fields)
      array = Enum.find(blocks, &(&1["fieldName"] == "acceptance_criteria"))

      assert array["type"] == "arrayOf"
      assert array["of"] == @criterion_of
      assert array["ordered"] == true
      assert array["label"] == "Acceptance criteria"
    end

    test "composite block keeps its subfield list" do
      blocks = Synthesis.synthesize(@layout, %{"estimate" => %{"size" => "m"}}, @fields)
      comp = Enum.find(blocks, &(&1["fieldName"] == "estimate"))

      assert comp["type"] == "composite"
      assert [%{"name" => "size"}] = comp["fields"]
    end

    test "v1 leaf blocks are untouched — no config keys leak in" do
      blocks = Synthesis.synthesize(@layout, %{"title" => "T"}, @fields)
      title = Enum.find(blocks, &(&1["fieldName"] == "title"))

      assert title["type"] == "field-string"
      refute Map.has_key?(title, "of")
      refute Map.has_key?(title, "fields")
      refute Map.has_key?(title, "label")
    end
  end

  describe "scaffold/4 carries the same config" do
    test "a scaffolded arrayOf block knows its element shape" do
      blocks = Synthesis.scaffold(@layout, %{}, %{}, @fields)
      array = Enum.find(blocks, &(&1["fieldName"] == "acceptance_criteria"))

      assert array["of"] == @criterion_of
      assert array["ordered"] == true
    end
  end
end
