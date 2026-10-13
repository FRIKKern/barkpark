defmodule Barkpark.Content.ValidationFileSubfieldsTest do
  @moduledoc """
  task-681df8da723386b8 — Sanity's `file` type (post.attachment) had no
  Barkpark equivalent: the schema accepted `type: "file"` only via the
  permissive v1 leaf fallback, with no way to declare its own subfields and
  no documented stored-value shape. Mirrors `image`'s own subfields support
  exactly (same split: declared `fields` -> v2 composite walk, else a plain
  leaf), minus the hotspot/crop concept that has no file equivalent.

  Canonical stored shape, same as `image`:
  `{"_type": "file", "asset": {"_type": "reference", "_ref": "<media-id>"}}`,
  plus any declared sibling subfields — or a bare URL string (legacy/simple).
  Barkpark.Media's upload pipeline already accepts any mime type by default
  (media.ex's `allowed_mime_types` config, `[]` = allow-all) — no server
  change was needed there for a non-image asset to upload successfully.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.{SchemaDefinition, Validation}

  @schema %{
    "name" => "post",
    "fields" => [
      %{"name" => "title", "type" => "string"},
      %{
        "name" => "attachment",
        "type" => "file",
        "fields" => [
          %{"name" => "label", "type" => "string", "validation" => %{"required" => true}}
        ]
      },
      %{"name" => "resume", "type" => "file"}
    ]
  }

  defp file(extra) do
    Map.merge(
      %{"_type" => "file", "asset" => %{"_type" => "reference", "_ref" => "file-abc"}},
      extra
    )
  end

  test "a file with declared fields parses as a v2 shape with its subfields" do
    {:ok, parsed} = SchemaDefinition.parse(@schema)
    att = Enum.find(parsed.fields, &(&1.name == "attachment"))
    assert Enum.map(att.fields, & &1.name) == ["label"]
    refute SchemaDefinition.flat?(parsed)
  end

  test "a schema whose only file is plain stays flat" do
    assert SchemaDefinition.flat?(%{
             "name" => "x",
             "fields" => [%{"name" => "resume", "type" => "file"}]
           })
  end

  test "file fields must be a list" do
    assert {:error, _} =
             SchemaDefinition.parse(%{
               "name" => "x",
               "fields" => [%{"name" => "resume", "type" => "file", "fields" => "label"}]
             })
  end

  test "a valid file with its required label passes" do
    value = file(%{"label" => "Q3 report"})
    assert {:ok, _} = Validation.validate(%{"attachment" => value}, "t", @schema)
  end

  test "a missing required label is reported at the subfield" do
    assert {:error, %{"attachment" => msgs}} =
             Validation.validate(%{"attachment" => file(%{})}, "t", @schema)

    assert Enum.any?(msgs, &(&1 =~ "/attachment/label" and &1 =~ "Required"))
  end

  test "a URL string has no label, so a required label is reported on it" do
    assert {:error, %{"attachment" => msgs}} =
             Validation.validate(%{"attachment" => "https://x/report.pdf"}, "t", @schema)

    assert Enum.any?(msgs, &(&1 =~ "/attachment/label"))
  end

  test "a non-string, non-map value is refused with a clear message" do
    assert {:error, %{"attachment" => msgs}} =
             Validation.validate(%{"attachment" => 42}, "t", @schema)

    assert Enum.any?(msgs, &(&1 =~ "expected a file URL or a file object"))
  end

  test "a plain file field is not checked for subfield shape" do
    assert {:ok, _} =
             Validation.validate(
               %{"attachment" => file(%{"label" => "ok"}), "resume" => %{"whatever" => "key"}},
               "t",
               @schema
             )
  end
end
