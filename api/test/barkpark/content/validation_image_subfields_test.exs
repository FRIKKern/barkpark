defmodule Barkpark.Content.ValidationImageSubfieldsTest do
  @moduledoc """
  task-f0f51946d2de672d — an `image` field can declare subfields (Sanity's
  `alt` on `post.mainImage`) and they are validated like a composite's;
  `hotspot` and `crop` have a checked shape. A plain image is unchanged.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.{SchemaDefinition, Validation}

  @schema %{
    "name" => "post",
    "fields" => [
      %{"name" => "title", "type" => "string"},
      %{
        "name" => "mainImage",
        "type" => "image",
        "options" => %{"hotspot" => true},
        "fields" => [
          %{"name" => "alt", "type" => "string", "validation" => %{"required" => true}},
          %{"name" => "caption", "type" => "string", "validation" => %{"max" => 10}}
        ]
      },
      %{"name" => "thumb", "type" => "image"}
    ]
  }

  defp image(extra) do
    Map.merge(
      %{"_type" => "image", "asset" => %{"_type" => "reference", "_ref" => "image-abc"}},
      extra
    )
  end

  test "an image with declared fields parses as a v2 shape with its subfields" do
    {:ok, parsed} = SchemaDefinition.parse(@schema)
    main = Enum.find(parsed.fields, &(&1.name == "mainImage"))
    assert Enum.map(main.fields, & &1.name) == ["alt", "caption"]
    refute SchemaDefinition.flat?(parsed)
  end

  test "a schema whose only image is plain stays flat" do
    assert SchemaDefinition.flat?(%{
             "name" => "x",
             "fields" => [%{"name" => "cover", "type" => "image"}]
           })
  end

  test "image fields must be a list" do
    assert {:error, _} =
             SchemaDefinition.parse(%{
               "name" => "x",
               "fields" => [%{"name" => "cover", "type" => "image", "fields" => "alt"}]
             })
  end

  test "a valid image with alt, hotspot and crop passes" do
    value =
      image(%{
        "alt" => "A dog",
        "hotspot" => %{"x" => 0.5, "y" => 0.4, "height" => 0.3, "width" => 0.3},
        "crop" => %{"top" => 0, "bottom" => 0.1, "left" => 0, "right" => 0}
      })

    assert {:ok, _} = Validation.validate(%{"mainImage" => value}, "t", @schema)
  end

  test "a missing required alt is reported at the subfield" do
    assert {:error, %{"mainImage" => msgs}} =
             Validation.validate(%{"mainImage" => image(%{})}, "t", @schema)

    assert Enum.any?(msgs, &(&1 =~ "/mainImage/alt" and &1 =~ "Required"))
  end

  test "subfield rules apply like a composite's" do
    value = image(%{"alt" => "ok", "caption" => "far too long caption"})

    assert {:error, %{"mainImage" => msgs}} =
             Validation.validate(%{"mainImage" => value}, "t", @schema)

    assert Enum.any?(msgs, &(&1 =~ "/mainImage/caption"))
  end

  test "a URL string has no alt, so a required alt is reported on it" do
    assert {:error, %{"mainImage" => msgs}} =
             Validation.validate(%{"mainImage" => "https://x/y.jpg"}, "t", @schema)

    assert Enum.any?(msgs, &(&1 =~ "/mainImage/alt"))
  end

  test "hotspot and crop values out of range or missing a side are reported" do
    value =
      image(%{
        "alt" => "ok",
        "hotspot" => %{"x" => 1.5, "y" => 0.4, "height" => 0.3},
        "crop" => "all"
      })

    assert {:error, %{"mainImage" => msgs}} =
             Validation.validate(%{"mainImage" => value}, "t", @schema)

    assert Enum.any?(msgs, &(&1 =~ "/mainImage/hotspot/x"))
    assert Enum.any?(msgs, &(&1 =~ "/mainImage/hotspot/width"))
    assert Enum.any?(msgs, &(&1 =~ "/mainImage/crop" and &1 =~ "top, bottom, left, right"))
  end

  test "a plain image field is not checked for shape" do
    assert {:ok, _} =
             Validation.validate(
               %{"mainImage" => image(%{"alt" => "ok"}), "thumb" => %{"hotspot" => "whatever"}},
               "t",
               @schema
             )
  end
end
