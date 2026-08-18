defmodule Barkpark.Media.ProbeAdversarialTest do
  @moduledoc """
  Fail-closed regression coverage for `Barkpark.Media.Probe`.

  `probe_test.exs` covered only happy-path decodes plus one unsupported type.
  This suite banks the verify-round proof that a malformed, truncated, zero-byte,
  hostile-sized or mime-lying upload NEVER raises — `Probe.probe/2` always
  returns an `{:error, reason}` or an `{:ok, %{width, height}}` tuple. Each case
  runs inside `probe/3`, which `flunk`s if the call raises.

  Notes on the real contract (code is ground truth, not the brief):
    * `Probe.probe/2` takes a FILE PATH + mime, not raw bytes — so each case
      writes its bytes to a temp file first (same shape as `probe_test.exs`).
    * `read_prefix/1` caps the parsed window at 512_000 bytes; the final case
      proves an IHDR pushed past that cap is unreachable (`:invalid_png`) while
      the identical IHDR at offset 0 decodes.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.Probe

  @png_sig <<137, 80, 78, 71, 13, 10, 26, 10>>

  # Minimal valid PNG (8-byte sig + IHDR chunk). png_dimensions only needs the
  # sig, a 4-byte length, the "IHDR" literal, then width::32 height::32.
  defp png_with(w, h) do
    @png_sig <> <<13::32>> <> "IHDR" <> <<w::32, h::32>> <> <<8, 6, 0, 0, 0>> <> <<0::32>>
  end

  # Minimal GIF89a header: "GIF" + "89a" (24 bits) then width/height little-endian.
  defp gif_with(w, h), do: "GIF89a" <> <<w::16-little, h::16-little>>

  # Minimal JPEG: SOI then a SOF0 marker carrying height::16 width::16.
  defp jpeg_with(w, h) do
    <<0xFF, 0xD8>> <> <<0xFF, 0xC0, 17::16, 8, h::16, w::16, 3, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1>>
  end

  test "truncated JPEG cut mid-SOF -> {:error, :invalid_jpeg}, no raise" do
    assert {:error, :invalid_jpeg} =
             probe(<<0xFF, 0xD8, 0xFF, 0xC0, 0, 3>>, "image/jpeg", "trunc-sof.jpg")
  end

  test "50000-byte 0xFF storm after SOI terminates with {:error, :invalid_jpeg}" do
    storm = <<0xFF, 0xD8>> <> :binary.copy(<<0xFF>>, 50_000)
    assert {:error, :invalid_jpeg} = probe(storm, "image/jpeg", "storm.jpg")
  end

  test "zero-byte input -> {:error, :empty}, no raise" do
    assert {:error, :empty} = probe("", "image/png", "empty.png")
  end

  test "0x0 PNG / GIF / JPEG decode to {:ok, %{width: 0, height: 0}}" do
    assert {:ok, %{width: 0, height: 0}} = probe(png_with(0, 0), "image/png", "zero.png")
    assert {:ok, %{width: 0, height: 0}} = probe(gif_with(0, 0), "image/gif", "zero.gif")
    assert {:ok, %{width: 0, height: 0}} = probe(jpeg_with(0, 0), "image/jpeg", "zero.jpg")
  end

  test "valid 1x1 PNG with a lying .txt name and text/plain mime decodes via magic bytes" do
    # Magic-byte sniff must override the client-declared mime.
    assert {:ok, %{width: 1, height: 1}} = probe(png_with(1, 1), "text/plain", "not-really.txt")
  end

  test "truncated PNG (partial IHDR) -> {:error, :invalid_png}, no raise" do
    partial = @png_sig <> <<13::32>> <> "IHD"
    assert {:error, :invalid_png} = probe(partial, "image/png", "trunc.png")
  end

  test "truncated GIF (partial header) -> {:error, :invalid_gif}, no raise" do
    partial = "GIF89a" <> <<0>>
    assert {:error, :invalid_gif} = probe(partial, "image/gif", "trunc.gif")
  end

  test "oversized non-image (600KB) -> {:error, :unsupported}, no raise" do
    blob = :binary.copy(<<0>>, 600_000)
    assert {:error, :unsupported} = probe(blob, "application/octet-stream", "big.bin")
  end

  test "512K read cap: an IHDR past 512_000 is unreachable while the same IHDR at offset 0 decodes" do
    # Distinct dims so a false decode can't masquerade as a coincidence.
    valid = png_with(7, 9)
    assert {:ok, %{width: 7, height: 9}} = probe(valid, "image/png", "at-zero.png")

    # Keep the PNG signature at offset 0, then push the IHDR chunk just past the
    # 512_000-byte read cap. read_prefix truncates the parsed window before the
    # IHDR is ever seen -> {:error, :invalid_png}.
    past_cap =
      binary_part(valid, 0, 8) <>
        :binary.copy(<<0>>, 512_000) <>
        binary_part(valid, 8, byte_size(valid) - 8)

    assert byte_size(past_cap) > 512_000
    assert {:error, :invalid_png} = probe(past_cap, "image/png", "past-cap.png")
  end

  # Write the bytes, probe, and fail the test loudly if the call raises/throws —
  # the whole point of this suite is that it never does.
  defp probe(bytes, mime, name) do
    path = Path.join(System.tmp_dir!(), "probe-adv-#{:rand.uniform(9_999_999)}-#{name}")
    File.write!(path, bytes)

    try do
      Probe.probe(path, mime)
    rescue
      e -> flunk("Probe.probe/2 RAISED on #{name}: #{inspect(e)}")
    catch
      kind, reason -> flunk("Probe.probe/2 THREW #{kind} on #{name}: #{inspect(reason)}")
    after
      File.rm(path)
    end
  end
end
