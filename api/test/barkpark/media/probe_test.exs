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
        <<13::32-little>> <>
        "WEBP" <> "VP8L" <> <<5::32-little>> <> <<0x2F>> <> <<bits::32-little>>

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

  # ── sniff_mime/2 — the magic-byte table (task-57ee9fff4aae9217 #4) ─────────
  #
  # The invariant that matters is the FALLBACK CHAIN, not the size of the
  # table: `sniff_mime/2` may only ever return the caller's fallback or a type
  # it POSITIVELY recognised. Every "no match" case below is really a test that
  # a pre-existing upload's persisted mime is unchanged by this feature.
  describe "sniff_mime/2 — content sniffing" do
    test "recognises the raster formats regardless of the filename" do
      for {bytes, expected} <- [
            {Base.decode64!(@png_b64), "image/png"},
            {<<0xFF, 0xD8, 0xFF, 0xE0, "junk">>, "image/jpeg"},
            {<<"GIF89a", 1::16, 1::16>>, "image/gif"},
            {<<"GIF87a", 1::16, 1::16>>, "image/gif"},
            {<<"RIFF", 0::32, "WEBPVP8 ">>, "image/webp"},
            {<<0x49, 0x49, 0x2A, 0x00, "tiff">>, "image/tiff"},
            {<<0x4D, 0x4D, 0x00, 0x2A, "tiff">>, "image/tiff"},
            {<<"BM", 0::size(12)-unit(8), "bmp">>, "image/bmp"}
          ] do
        # `remote.axd` is Gyldendal's real filename: MIME.from_path gives
        # application/octet-stream, so a returned image type can ONLY have
        # come from the bytes.
        path = write_temp!(bytes, "remote.axd")

        assert Probe.sniff_mime(path, MIME.from_path("remote.axd")) == expected
      end
    end

    test "recognises documents, containers and audio" do
      for {bytes, expected} <- [
            {"%PDF-1.7\ntrailer", "application/pdf"},
            {<<0::32, "ftypavif", 0::32>>, "image/avif"},
            {<<0::32, "ftypheic", 0::32>>, "image/heic"},
            {<<0::32, "ftypisom", 0::32>>, "video/mp4"},
            {<<0::32, "ftypqt  ", 0::32>>, "video/quicktime"},
            {<<0x1A, 0x45, 0xDF, 0xA3, "matroska">>, "video/webm"},
            {<<"OggS", 0, 2, 0::48>>, "audio/ogg"},
            {<<"fLaC", 0::32>>, "audio/flac"},
            {<<"ID3", 3, 0, 0, 0::32>>, "audio/mpeg"},
            {<<0xFF, 0xFB, 0x90, 0x00>>, "audio/mpeg"},
            {<<"RIFF", 0::32, "WAVEfmt ">>, "audio/wav"}
          ] do
        path = write_temp!(bytes, "remote.axd")

        assert Probe.sniff_mime(path, "application/octet-stream") == expected
      end
    end

    test "returns the FALLBACK for unrecognised bytes — the no-regression arm" do
      path = write_temp!("plain prose with no magic number", "notes.txt")

      assert Probe.sniff_mime(path, "text/plain") == "text/plain"
      assert Probe.sniff_mime(path, "application/octet-stream") == "application/octet-stream"
      assert Probe.sniff_mime(path, nil) == nil
    end

    test "a ZIP-family container is deliberately NOT sniffed" do
      # `PK\x03\x04` is docx/xlsx/epub/jar/apk alike — the extension is the
      # better evidence, so the table stays out of it and the fallback stands.
      path = write_temp!(<<"PK", 3, 4, 0::64>>, "report.docx")

      assert Probe.sniff_mime(path, MIME.from_path("report.docx")) ==
               MIME.from_path("report.docx")
    end

    test "a missing or unreadable file yields the fallback, never a raise" do
      missing = Path.join(System.tmp_dir!(), "probe-absent-#{:rand.uniform(999_999)}")
      refute File.exists?(missing)

      assert Probe.sniff_mime(missing, "image/png") == "image/png"
    end

    test "an empty file yields the fallback" do
      path = write_temp!("", "empty.bin")

      assert Probe.sniff_mime(path, "application/octet-stream") == "application/octet-stream"
    end
  end

  describe "sniff_bytes/1 — the dangerous family is sniffed, and only downgrades" do
    test "SVG is recognised through a leading XML prologue, whitespace and a BOM" do
      svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"/>"

      assert Probe.sniff_bytes(svg) == "image/svg+xml"
      assert Probe.sniff_bytes("<?xml version=\"1.0\"?>\n" <> svg) == "image/svg+xml"
      assert Probe.sniff_bytes("\n\n  " <> svg) == "image/svg+xml"
      assert Probe.sniff_bytes(<<0xEF, 0xBB, 0xBF>> <> svg) == "image/svg+xml"
      assert Probe.sniff_bytes("<SVG WIDTH=\"1\"/>") == "image/svg+xml"
    end

    test "HTML is recognised" do
      assert Probe.sniff_bytes("<!DOCTYPE html><html><body>hi") == "text/html"
      assert Probe.sniff_bytes("<html lang=\"en\">") == "text/html"
    end

    test "binary magic wins over the text scan" do
      # Real PNG bytes that happen to contain the string `<svg` later on must
      # still sniff as PNG — the binary table is consulted first.
      png = Base.decode64!(@png_b64) <> "<svg onload=alert(1)>"

      assert Probe.sniff_bytes(png) == "image/png"
    end

    test "prose that merely mentions svg is not markup" do
      assert Probe.sniff_bytes("a note about svg files in general") == nil
    end
  end

  defp write_temp!(bytes, name) do
    path = Path.join(System.tmp_dir!(), "probe-#{:rand.uniform(999_999)}-#{name}")
    File.write!(path, bytes)
    path
  end
end
