defmodule Barkpark.Media.SanityAssetTest do
  @moduledoc """
  Parsing Sanity CDN file names and moving a `rect` between pixel spaces
  (task-0bc9247eca1bd741). Pure; the lookup is covered by
  `BarkparkWeb.Integration.SanityImageUrlsTest`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.SanityAsset

  @sha "3f786850e387550fdab836ed7e6dc881de23001b"

  describe "parse_image/1" do
    test "reads sha1, size and extension, and rebuilds the Sanity asset id" do
      assert {:ok, ref} = SanityAsset.parse_image("#{@sha}-700x400.jpg")
      assert ref.kind == :image
      assert ref.sha1 == @sha
      assert ref.size == {700, 400}
      assert ref.ext == "jpg"
      assert ref.source_id == "image-#{@sha}-700x400-jpg"
    end

    test "lower-cases the hash and extension" do
      assert {:ok, ref} = SanityAsset.parse_image("#{String.upcase(@sha)}-10x20.PNG")
      assert ref.source_id == "image-#{@sha}-10x20-png"
    end

    test "refuses names that are not a Sanity image" do
      for name <- [
            "#{@sha}.jpg",
            "#{@sha}-700x400",
            "#{@sha}-0x400.jpg",
            "abc-700x400.jpg",
            "#{@sha}-700x400.jpg.exe/..",
            "../#{@sha}-700x400.jpg",
            ""
          ] do
        assert SanityAsset.parse_image(name) == :error, "accepted #{inspect(name)}"
      end
    end
  end

  describe "parse_file/1" do
    test "reads sha1 and extension, and rebuilds the Sanity asset id" do
      assert {:ok, ref} = SanityAsset.parse_file("#{@sha}.pdf")
      assert ref.kind == :file
      assert ref.size == nil
      assert ref.source_id == "file-#{@sha}-pdf"
    end

    test "refuses an image-shaped or malformed name" do
      assert SanityAsset.parse_file("#{@sha}-700x400.jpg") == :error
      assert SanityAsset.parse_file("#{@sha}") == :error
      assert SanityAsset.parse_file("nope.pdf") == :error
    end
  end

  describe "rescale_rect/3" do
    test "moves a rect from the declared size into the stored size" do
      plan = %{rect: {600, 0, 600, 400}}

      assert SanityAsset.rescale_rect(plan, {1200, 800}, {600, 400}).rect == {300, 0, 300, 200}
    end

    test "keeps the rect inside the stored image" do
      plan = %{rect: {9000, 6000, 921, 165}}

      assert {l, t, w, h} = SanityAsset.rescale_rect(plan, {9921, 6165}, {8192, 5091}).rect
      assert l + w <= 8192
      assert t + h <= 5091
      assert w >= 1 and h >= 1
    end

    test "leaves the plan alone without a rect, with equal sizes or an unknown size" do
      assert SanityAsset.rescale_rect(%{rect: nil}, {1200, 800}, {600, 400}) == %{rect: nil}

      assert SanityAsset.rescale_rect(%{rect: {1, 2, 3, 4}}, {600, 400}, {600, 400}) ==
               %{rect: {1, 2, 3, 4}}

      assert SanityAsset.rescale_rect(%{rect: {1, 2, 3, 4}}, nil, {600, 400}) ==
               %{rect: {1, 2, 3, 4}}

      assert SanityAsset.rescale_rect(%{rect: {1, 2, 3, 4}}, {600, 400}, nil) ==
               %{rect: {1, 2, 3, 4}}
    end
  end
end
