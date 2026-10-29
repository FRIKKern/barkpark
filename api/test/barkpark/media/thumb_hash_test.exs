defmodule Barkpark.Media.ThumbHashTest do
  @moduledoc """
  task-dbfa49e99510e0f1: upload processing stores Sanity's `metadata.thumbHash`.
  The fixture is the e2e-local 640x400 png; Sanity's asset for the same pixels
  (image-0437f83b…-640x400-png, read 29 Oct) carries 5ZYJNIiGh3d/eHiCh3l0YBr3ZQ==.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.ImageBackend.Vix
  alias Barkpark.Media.ThumbHash

  @fixture "test/fixtures/media/sanity-e2e-640x400.png"
  @sanity "5ZYJNIiGh3d/eHiCh3l0YBr3ZQ=="

  setup do
    if Vix.available?(), do: :ok, else: {:skip, "no libvips on this host"}
  end

  test "analyze/2 gives the thumbHash Sanity stores for the same image" do
    assert {:ok, %{thumb_hash: @sanity}} = Vix.analyze(@fixture, [])
  end

  test "an image with alpha sets the alpha flag and adds the alpha byte" do
    # 2x2: opaque red, half-transparent green, transparent, opaque blue.
    rgba = <<255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 0, 0, 0, 0, 255, 255>>
    <<alpha_flag::1, _::23, _::binary>> = reverse3(ThumbHash.encode(2, 2, rgba))
    assert alpha_flag == 1

    assert byte_size(ThumbHash.encode(2, 2, rgba)) >
             byte_size(ThumbHash.encode(2, 2, opaque(rgba)))
  end

  # The 24-bit header is little-endian; bit 23 is the alpha flag.
  defp reverse3(<<a, b, c, rest::binary>>), do: <<c, b, a, rest::binary>>
  defp opaque(rgba), do: for(<<r, g, b, _a <- rgba>>, into: <<>>, do: <<r, g, b, 255>>)
end
