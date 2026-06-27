defmodule Barkpark.PortableDoc.SynthesisTest do
  @moduledoc """
  Core behaviour of Synthesis: field_block_type/1, synthesize/3, scaffold/4,
  and patch_bound_values/2.

  All pure — no DB, no Repo.
  """

  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Synthesis

  # ── field_block_type/1 ────────────────────────────────────────────────────

  describe "field_block_type/1" do
    test "maps known v1 leaf types to their field-* counterparts" do
      assert Synthesis.field_block_type("string") == "field-string"
      assert Synthesis.field_block_type("richText") == "field-text"
      assert Synthesis.field_block_type("image") == "field-image"
      assert Synthesis.field_block_type("boolean") == "field-boolean"
    end

    test "maps v2 nested types to the identity (no field- prefix)" do
      assert Synthesis.field_block_type("composite") == "composite"
      assert Synthesis.field_block_type("arrayOf") == "arrayOf"
      assert Synthesis.field_block_type("codelist") == "codelist"
      assert Synthesis.field_block_type("localizedText") == "localizedText"
    end

    test "unknown or nil type falls back to field-string" do
      assert Synthesis.field_block_type(nil) == "field-string"
      assert Synthesis.field_block_type("nonsense") == "field-string"
    end
  end

  # ── synthesize/3 ──────────────────────────────────────────────────────────

  @fields [
    %{"name" => "title", "type" => "string"},
    %{"name" => "published", "type" => "boolean"}
  ]

  @layout [
    %{"kind" => "field", "name" => "title"},
    %{"kind" => "field", "name" => "published"},
    %{"kind" => "region", "name" => "body"}
  ]

  describe "synthesize/3 — field blocks" do
    test "emits one bound block per content key that is present in layout" do
      content = %{"title" => "Hello", "published" => true}
      blocks = Synthesis.synthesize(@layout, content, @fields)

      title_block = Enum.find(blocks, &(&1["fieldName"] == "title"))
      assert title_block["type"] == "field-string"
      assert title_block["value"] == "Hello"

      pub_block = Enum.find(blocks, &(&1["fieldName"] == "published"))
      assert pub_block["type"] == "field-boolean"
      assert pub_block["value"] == true
    end

    test "skips fields absent from content — no empty bound block emitted" do
      blocks = Synthesis.synthesize(@layout, %{"title" => "T"}, @fields)
      assert Enum.all?(blocks, fn b -> b["fieldName"] != "published" end)
    end

    test "synthetic ids are deterministic and unique across field/region blocks" do
      content = %{"title" => "T"}
      blocks = Synthesis.synthesize(@layout, content, @fields)
      ids = Enum.map(blocks, & &1["id"])
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "synthesize/3 — body region" do
    test "a plain string body becomes one paragraph free block" do
      content = %{"body" => "Some prose"}
      blocks = Synthesis.synthesize(@layout, content, @fields)

      [para] = Enum.filter(blocks, &(&1["type"] == "paragraph"))
      assert para["content"] == [%{"type" => "text", "value" => "Some prose"}]
    end

    test "an already-projected body map has its blocks reused verbatim" do
      inner = [%{"id" => "p1", "type" => "paragraph", "content" => []}]
      content = %{"body" => %{"blocks" => inner}}
      blocks = Synthesis.synthesize(@layout, content, @fields)

      assert Enum.find(blocks, &(&1["id"] == "p1"))
    end

    test "empty/absent body produces no free blocks" do
      blocks_nil = Synthesis.synthesize(@layout, %{}, @fields)
      blocks_empty = Synthesis.synthesize(@layout, %{"body" => ""}, @fields)

      refute Enum.any?(blocks_nil, &(&1["type"] == "paragraph"))
      refute Enum.any?(blocks_empty, &(&1["type"] == "paragraph"))
    end
  end

  # ── scaffold/4 ────────────────────────────────────────────────────────────

  describe "scaffold/4" do
    test "always emits all layout fields, even with no values" do
      blocks = Synthesis.scaffold(@layout, %{}, %{}, @fields)
      names = blocks |> Enum.filter(& &1["fieldName"]) |> Enum.map(& &1["fieldName"])

      assert "title" in names
      assert "published" in names
    end

    test "values wins over prefill for the same field" do
      blocks =
        Synthesis.scaffold(@layout, %{"title" => "override"}, %{"title" => "prefill"}, @fields)

      title = Enum.find(blocks, &(&1["fieldName"] == "title"))
      assert title["value"] == "override"
    end

    test "falls back to prefill when values lacks the key" do
      blocks = Synthesis.scaffold(@layout, %{}, %{"title" => "from-prefill"}, @fields)
      title = Enum.find(blocks, &(&1["fieldName"] == "title"))
      assert title["value"] == "from-prefill"
    end

    test "field-boolean defaults to false when both maps are empty" do
      blocks = Synthesis.scaffold(@layout, %{}, %{}, @fields)
      pub = Enum.find(blocks, &(&1["fieldName"] == "published"))
      assert pub["value"] == false
    end

    test "empty body region produces one empty paragraph placeholder" do
      blocks = Synthesis.scaffold(@layout, %{}, %{}, @fields)
      paras = Enum.filter(blocks, &(&1["type"] == "paragraph"))

      assert length(paras) == 1
      assert hd(paras)["content"] == []
    end
  end

  # ── patch_bound_values/2 ──────────────────────────────────────────────────

  describe "patch_bound_values/2" do
    @bound_blocks [
      %{"id" => "t", "type" => "field-string", "fieldName" => "title", "value" => "Old"},
      %{"id" => "s", "type" => "field-slug", "fieldName" => "slug", "value" => "old-slug"},
      %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "prose"}]
      }
    ]

    test "patches only bound blocks whose fieldName appears in values" do
      patched = Synthesis.patch_bound_values(@bound_blocks, %{"title" => "New"})
      title = Enum.find(patched, &(&1["fieldName"] == "title"))
      slug = Enum.find(patched, &(&1["fieldName"] == "slug"))

      assert title["value"] == "New"
      assert slug["value"] == "old-slug"
    end

    test "free blocks are passed through byte-identical" do
      patched = Synthesis.patch_bound_values(@bound_blocks, %{"title" => "X"})
      para = Enum.find(patched, &(&1["type"] == "paragraph"))

      assert para == Enum.find(@bound_blocks, &(&1["type"] == "paragraph"))
    end

    test "returns same length list in same order" do
      patched = Synthesis.patch_bound_values(@bound_blocks, %{"title" => "X", "slug" => "new"})
      assert length(patched) == length(@bound_blocks)
      assert Enum.map(patched, & &1["id"]) == Enum.map(@bound_blocks, & &1["id"])
    end
  end
end
