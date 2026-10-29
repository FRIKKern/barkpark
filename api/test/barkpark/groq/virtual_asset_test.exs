defmodule Barkpark.Groq.VirtualAssetTest do
  use ExUnit.Case, async: true

  alias Barkpark.Groq.VirtualAsset

  defp file(attrs) do
    Map.merge(
      %{
        id: "0b0e1d4e-1c4f-4b8e-9d5a-2f7c3a1b2c3d",
        sha1: nil,
        source_id: nil,
        mime_type: "application/pdf",
        original_name: "Report.PDF",
        filename: "report-abc123.pdf",
        path: "uploads/2026/10/report-abc123.pdf",
        size: 45
      },
      attrs
    )
  end

  # Rows stored before sha1 have no Sanity id, but Sanity gives every asset
  # an extension (task-ee1196ce908b12cf).
  test "a file with no sha1 still has an extension, from its type or its name" do
    pdf = VirtualAsset.build(file(%{}), %{}, "production", nil)
    assert pdf["_id"] == "asset-0b0e1d4e-1c4f-4b8e-9d5a-2f7c3a1b2c3d"
    assert pdf["extension"] == "pdf"
    refute Map.has_key?(pdf, "assetId")

    jpeg = file(%{mime_type: "image/jpeg", original_name: "photo.jpeg"})
    assert VirtualAsset.build(jpeg, %{}, "production", nil)["extension"] == "jpg"

    nameless = file(%{original_name: nil, filename: "notes"})
    refute Map.has_key?(VirtualAsset.build(nameless, %{}, "production", nil), "extension")
  end
end
