defmodule Barkpark.Media.ProbeTest do
  use ExUnit.Case, async: true

  alias Barkpark.Media.Probe

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  test "reads PNG dimensions from IHDR" do
    path = write_temp!(Base.decode64!(@png_b64), "probe.png")

    assert {:ok, %{width: 1, height: 1, exif: %{}}} = Probe.probe(path, "image/png")
  end

  test "reads JPEG dimensions from a baseline JFIF SOF0" do
    app0 = <<0xFF, 0xE0, 0x00, 0x10, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>>
    sof0 = <<0xFF, 0xC0, 0x00, 0x11, 8, 2::16, 3::16, 3, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1>>
    jpeg = <<0xFF, 0xD8>> <> app0 <> sof0

    path = write_temp!(jpeg, "probe.jpg")

    assert {:ok, %{width: 3, height: 2, exif: %{}}} = Probe.probe(path, "image/jpeg")
  end

  test "reads WebP dimensions from a simple-lossy VP8 chunk" do
    webp =
      "RIFF" <>
        <<20::32-little>> <>
        "WEBP" <>
        "VP8 " <>
        <<12::32-little>> <> <<0, 0, 0>> <> <<0x9D, 0x01, 0x2A>> <> <<3::16-little, 2::16-little>>

    path = write_temp!(webp, "probe-lossy.webp")

    assert {:ok, %{width: 3, height: 2, exif: %{}}} = Probe.probe(path, "image/webp")
  end

  test "reads WebP dimensions from a lossless VP8L chunk" do
    bits = 3 - 1 + Bitwise.bsl(2 - 1, 14)

    webp =
      "RIFF" <>
        <<13::32-little>> <> "WEBP" <> "VP8L" <> <<5::32-little>> <> <<0x2F>> <> <<bits::32-little>>

    path = write_temp!(webp, "probe-lossless.webp")

    assert {:ok, %{width: 3, height: 2, exif: %{}}} = Probe.probe(path, "image/webp")
  end

  test "reads WebP dimensions from an extended VP8X chunk" do
    webp =
      "RIFF" <>
        <<22::32-little>> <>
        "WEBP" <>
        "VP8X" <>
        <<10::32-little>> <> <<0x00>> <> <<0::24>> <> <<2::24-little>> <> <<1::24-little>>

    path = write_temp!(webp, "probe-extended.webp")

    assert {:ok, %{width: 3, height: 2, exif: %{}}} = Probe.probe(path, "image/webp")
  end

  test "returns unsupported for non-image bytes" do
    path = write_temp!("hello", "probe.txt")
    assert {:error, :unsupported} = Probe.probe(path, "text/plain")
  end

  defp write_temp!(bytes, name) do
    path = Path.join(System.tmp_dir!(), "probe-#{:rand.uniform(999_999)}-#{name}")
    File.write!(path, bytes)
    path
  end
end
