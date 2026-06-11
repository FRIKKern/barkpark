defmodule Barkpark.ContentExpectedFieldsTest do
  @moduledoc """
  EX1 (barkpark-q39y) — the Expectation-aware slash menu. Cardinality
  (`max`/`enforce`) rides inside the layout `field` entries.
  `Content.available_expected_fields/2,3` returns the expected fields still
  recommendable (count < max, hide-at-cap). `Content.expected_field_blocked?/3`
  is the HARD-cap insert gate. Both are pure — no Repo access.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition

  # A post-style schema + explicit Expectation: title/slug/featuredImage are
  # once-and-hard (max: 1, enforce: true); a soft "tag" field is once-and-soft.
  defp post_schema do
    %SchemaDefinition{
      name: "post",
      title: "Post",
      fields: [
        %{"name" => "title", "title" => "Title", "type" => "string"},
        %{"name" => "slug", "title" => "Slug", "type" => "slug"},
        %{"name" => "featuredImage", "title" => "Featured Image", "type" => "image"},
        %{"name" => "tag", "title" => "Tag", "type" => "string"}
      ]
    }
  end

  defp post_expectation do
    %{
      layout: [
        %{"kind" => "field", "name" => "title", "max" => 1, "enforce" => true},
        %{"kind" => "field", "name" => "slug", "max" => 1, "enforce" => true},
        %{"kind" => "field", "name" => "featuredImage", "max" => 1, "enforce" => true},
        %{"kind" => "field", "name" => "tag", "max" => 1, "enforce" => false},
        %{"kind" => "region", "name" => "body"}
      ],
      prefill: %{}
    }
  end

  defp bound(field_name) do
    %{
      "id" => "b-#{field_name}",
      "type" => "field-string",
      "fieldName" => field_name,
      "value" => "x"
    }
  end

  describe "available_expected_fields/3" do
    test "INCLUDES title when the post has NO title block (count 0 < max 1)" do
      avail = Content.available_expected_fields([], post_expectation(), post_schema())

      title = Enum.find(avail, &(&1.name == "title"))

      assert title == %{
               name: "title",
               type: "field-string",
               label: "Title",
               count: 0,
               max: 1,
               enforce: true
             }

      # featuredImage maps to field-image; its human label comes from the schema.
      featured = Enum.find(avail, &(&1.name == "featuredImage"))
      assert featured.type == "field-image"
      assert featured.label == "Featured Image"
      assert featured.count == 0
    end

    test "EXCLUDES title when the post has 1 title block (1/1, hidden at cap)" do
      blocks = [bound("title")]
      avail = Content.available_expected_fields(blocks, post_expectation(), post_schema())

      refute Enum.any?(avail, &(&1.name == "title"))
      # slug/featuredImage/tag are still recommendable (count 0 < max 1).
      assert Enum.any?(avail, &(&1.name == "slug"))
      assert Enum.any?(avail, &(&1.name == "featuredImage"))
      assert Enum.any?(avail, &(&1.name == "tag"))
    end

    test "a SOFT field (enforce: false) at cap is EXCLUDED from available (hide-at-cap)" do
      blocks = [bound("tag")]
      avail = Content.available_expected_fields(blocks, post_expectation(), post_schema())

      refute Enum.any?(avail, &(&1.name == "tag"))
    end

    test "an unlimited field (max nil) is ALWAYS available, even at count > 1" do
      exp = %{
        layout: [
          %{"kind" => "field", "name" => "tag", "enforce" => false},
          %{"kind" => "region", "name" => "body"}
        ],
        prefill: %{}
      }

      blocks = [bound("tag"), bound("tag"), bound("tag")]
      avail = Content.available_expected_fields(blocks, exp, post_schema())

      tag = Enum.find(avail, &(&1.name == "tag"))
      assert tag.count == 3
      assert tag.max == nil
    end

    test "region entries are ignored and a nameless field entry is skipped" do
      exp = %{
        layout: [
          %{"kind" => "field", "name" => "title", "max" => 1, "enforce" => true},
          %{"kind" => "field"},
          %{"kind" => "region", "name" => "body"}
        ],
        prefill: %{}
      }

      avail = Content.available_expected_fields([], exp, post_schema())
      assert Enum.map(avail, & &1.name) == ["title"]
    end
  end

  describe "expected_field_blocked?/3" do
    test "a SOFT field at cap is NOT blocked (slash hides it, insert still allowed)" do
      blocks = [bound("tag")]
      refute Content.expected_field_blocked?(blocks, post_expectation(), "tag")
    end

    test "an ENFORCED field at cap IS blocked (2nd insert rejected)" do
      blocks = [bound("title")]
      assert Content.expected_field_blocked?(blocks, post_expectation(), "title")
    end

    test "an ENFORCED field BELOW cap is NOT blocked" do
      refute Content.expected_field_blocked?([], post_expectation(), "title")
    end

    test "an unknown field name is never blocked" do
      blocks = [bound("title")]
      refute Content.expected_field_blocked?(blocks, post_expectation(), "nope")
    end
  end
end
