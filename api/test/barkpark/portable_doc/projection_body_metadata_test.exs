defmodule Barkpark.PortableDoc.ProjectionBodyMetadataTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Projection

  test "projection preserves body-map metadata while replacing owned blocks and html on every pass" do
    old_bound = field("subtitle", "Before")
    new_bound = field("subtitle", "After")
    old_free = paragraph("old", "Old prose")
    new_free = paragraph("new", "New prose")

    content = %{
      "blocks" => [new_bound, new_free],
      "subtitle" => "Before",
      "body" => %{
        "blocks" => [old_free],
        "html" => "<p>stale derivative</p>",
        "unknown" => %{"keep" => [1, 2, 3]}
      }
    }

    projected = Projection.project(content, [old_bound, old_free], [new_bound, new_free], %{})
    reprojected = Projection.project(projected, [new_bound, new_free], [new_bound, new_free], %{})

    for result <- [projected, reprojected] do
      assert result["subtitle"] == "After"
      assert result["body"]["unknown"] == %{"keep" => [1, 2, 3]}
      assert result["body"]["blocks"] == [new_free]
      assert result["body"]["html"] =~ "New prose"
      refute result["body"]["html"] =~ "stale derivative"
    end
  end

  test "scalar and bare-list body representations still canonicalize" do
    free = paragraph("new", "Canonical prose")

    for body <- ["legacy markdown", [paragraph("old", "Old prose")], 42] do
      projected = Projection.project(%{"body" => body}, [free], [free], %{})

      assert Map.keys(projected["body"]) |> Enum.sort() == ["blocks", "html"]
      assert projected["body"]["blocks"] == [free]
      assert projected["body"]["html"] =~ "Canonical prose"
    end
  end

  defp field(name, value) do
    %{
      "id" => "field-#{name}",
      "type" => "field-string",
      "fieldName" => name,
      "value" => value
    }
  end

  defp paragraph(id, value) do
    %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => value}]
    }
  end
end
