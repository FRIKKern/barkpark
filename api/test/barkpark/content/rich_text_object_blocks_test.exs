defmodule Barkpark.Content.RichTextObjectBlocksTest do
  @moduledoc """
  task-152cacba913a4724 — a richText field's block vocabulary may declare a
  custom object block (`blocks.of` entry `{name, fields}`, Sanity's
  `defineArrayMember({type: 'object', …})`), and every block of that type has
  its declared fields checked: on the v2 schema walk and on the Studio block-op
  write path.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.{SchemaDefinition, Validation}
  alias Barkpark.PortableDoc.FieldVocabulary

  @callout %{
    "name" => "callout",
    "fields" => [
      %{
        "name" => "tone",
        "type" => "string",
        "options" => %{"list" => [%{"title" => "Info", "value" => "info"}, "warning"]},
        "validation" => %{"required" => true}
      },
      %{"name" => "text", "type" => "text", "validation" => %{"required" => true}}
    ]
  }

  @field %{
    "name" => "body",
    "type" => "richText",
    "editor" => "blocks",
    "blocks" => %{"styles" => ["normal", "h2"], "of" => ["image", @callout]}
  }

  @schema %{"name" => "post", "fields" => [%{"name" => "title", "type" => "string"}, @field]}

  defp para(text),
    do: %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}

  defp callout(attrs), do: Map.merge(%{"type" => "callout"}, attrs)

  describe "schema validation" do
    test "an object entry in blocks.of makes the schema a v2 shape" do
      refute SchemaDefinition.flat?(@schema)

      assert SchemaDefinition.flat?(%{
               "name" => "x",
               "fields" => [%{@field | "blocks" => %{"of" => ["image"]}}]
             })
    end

    test "a valid callout passes, beside other blocks" do
      body = [para("hi"), callout(%{"tone" => "info", "text" => "Note"}), %{"type" => "image"}]
      assert {:ok, _} = Validation.validate(%{"body" => body}, "t", @schema)
    end

    test "a tone outside options.list and a missing text are reported at the block" do
      body = [para("hi"), callout(%{"tone" => "loud"})]
      assert {:error, %{"body" => msgs}} = Validation.validate(%{"body" => body}, "t", @schema)
      assert Enum.any?(msgs, &(&1 =~ "/body/1/tone" and &1 =~ "must be one of info, warning"))
      assert Enum.any?(msgs, &(&1 =~ "/body/1/text" and &1 =~ "Required"))
    end
  end

  # task-839f9bebf5628c03 — a block field's OWN `"level": "warning"` rule used
  # to be invisible on EVERY pass: `object_block_findings/3`'s child walk was
  # hardcoded to `:error` (so a warning-level rule never matched there
  # either), then the WHOLE block's findings were discarded by a blanket
  # `shape(level, …)` whenever the walk wasn't `:error` (so even an
  # error-shaped false positive could never surface on the warning pass). A
  # block field now obeys its own declared level exactly like an ordinary
  # composite subfield already does.
  describe "a block field's own warning-level rule" do
    @warn_callout %{
      "name" => "callout",
      "fields" => [
        %{
          "name" => "tone",
          "type" => "string",
          "validation" => %{"max" => 3, "level" => "warning"}
        }
      ]
    }

    @warn_field %{
      "name" => "body",
      "type" => "richText",
      "editor" => "blocks",
      "blocks" => %{"of" => [@warn_callout]}
    }

    @warn_schema %{"name" => "post", "fields" => [@warn_field]}

    test "surfaces on the warning pass, never the error pass" do
      body = [callout(%{"tone" => "toolong"})]

      assert %{errors: [], warnings: [finding]} =
               Validation.check_findings(%{"body" => body}, "t", @warn_schema)

      assert finding.path == "/body/0/tone"
      assert finding.code == :string_too_long

      # validate/3 is the error-level verdict ONLY — a warning-level rule
      # never blocks, so this still succeeds.
      assert {:ok, _} = Validation.validate(%{"body" => body}, "t", @warn_schema)
    end

    test "a tone within bounds raises neither", %{} do
      body = [callout(%{"tone" => "ok"})]

      assert %{errors: [], warnings: []} =
               Validation.check_findings(%{"body" => body}, "t", @warn_schema)
    end
  end

  describe "FieldVocabulary (the block-op write path)" do
    test "the object block's name joins the allowed block types" do
      vocab = FieldVocabulary.from_field(@field)
      assert MapSet.member?(FieldVocabulary.allowed_block_types(vocab), "callout")
      assert MapSet.member?(FieldVocabulary.allowed_block_types(vocab), "image")
    end

    test "a valid callout is admitted" do
      vocab = FieldVocabulary.from_field(@field)

      assert :ok =
               FieldVocabulary.validate(vocab, [callout(%{"tone" => "warning", "text" => "x"})])
    end

    test "an invalid callout is refused naming the field" do
      vocab = FieldVocabulary.from_field(@field)

      assert {:error, {:out_of_vocabulary, reason}} =
               FieldVocabulary.validate(vocab, [callout(%{"tone" => "loud", "text" => "x"})])

      assert reason =~ "callout/tone"
    end

    test "a vocabulary of plain strings is unchanged" do
      vocab = FieldVocabulary.from_field(%{@field | "blocks" => %{"of" => ["image"]}})
      refute MapSet.member?(FieldVocabulary.allowed_block_types(vocab), "callout")
      assert {:error, {:out_of_vocabulary, _}} = FieldVocabulary.validate(vocab, [callout(%{})])
    end
  end

  # task-839f9bebf5628c03 — a declared block named like a built-in
  # (`image`/`divider`/`code`/`diagram`) is not refused at schema save; the
  # DECLARED shape wins, consistently in both doors that check a block's
  # vocabulary membership.
  describe "a declared block name collides with a built-in block type" do
    @shadow_image %{
      "name" => "image",
      "fields" => [
        %{"name" => "caption", "type" => "text", "validation" => %{"required" => true}}
      ]
    }

    @shadowed_field %{@field | "blocks" => %{"of" => ["image", @shadow_image]}}

    test "the schema still parses — no refusal at save" do
      refute match?(
               {:error, _},
               SchemaDefinition.parse(%{"name" => "x", "fields" => [@shadowed_field]})
             )
    end

    test "the v2 schema walk checks the declared shape, not the bare built-in", %{} do
      body = [%{"type" => "image"}]
      schema = %{"name" => "post", "fields" => [@shadowed_field]}

      assert {:error, %{"body" => msgs}} = Validation.validate(%{"body" => body}, "t", schema)
      assert Enum.any?(msgs, &(&1 =~ "/body/0/caption" and &1 =~ "Required"))

      # And a block that DOES satisfy the declared shape passes.
      ok_body = [%{"type" => "image", "caption" => "a view"}]
      assert {:ok, _} = Validation.validate(%{"body" => ok_body}, "t", schema)
    end

    test "FieldVocabulary.validate/2 checks the SAME declared shape", %{} do
      vocab = FieldVocabulary.from_field(@shadowed_field)

      assert {:error, {:out_of_vocabulary, reason}} =
               FieldVocabulary.validate(vocab, [%{"type" => "image"}])

      assert reason =~ "image/caption"

      assert :ok = FieldVocabulary.validate(vocab, [%{"type" => "image", "caption" => "a view"}])
    end
  end
end
