defmodule Barkpark.Media.Probe do
  @moduledoc """
  Extracts dimensions from uploaded raster images via binary parsing.

  Works without libvips so probe + API metadata stay available everywhere;
  renditions use `Image` separately.
  """

  @type result :: %{
          width: pos_integer(),
          height: pos_integer(),
          exif: map()
        }

  # ── content sniffing (task-57ee9fff4aae9217, finding #4) ───────────────────
  #
  # WHY THIS LIVES HERE AND NOT IN A DEPENDENCY. `api/mix.lock` carries no
  # sniffing library (`file_info`, `mimetype`, `gen_magic` — none are present),
  # and `gen_magic` would pull a libmagic NIF onto every build host to answer a
  # question a 40-line table already answers. This module was ALREADY the magic
  # byte reader for the four raster formats; the table below is the same
  # technique widened to the container formats media actually ingests.
  #
  # DELIBERATELY CONSERVATIVE — it is a FALLBACK CHAIN, not a replacement.
  # `sniff_mime/2` returns the caller's `fallback` (in practice
  # `MIME.from_path/1`) for every byte pattern it does not positively
  # recognise, so an unrecognised upload keeps exactly the type it got before
  # this existed. ZIP-family containers (`PK\x03\x04` — docx/xlsx/epub/jar)
  # are deliberately NOT sniffed: the magic is shared by a dozen types the
  # extension distinguishes better.
  #
  # THE CLIENT'S HEADER IS STILL NEVER READ. Sniffing reads the BYTES the
  # client uploaded, so the stored-XSS defence documented in
  # `Barkpark.Media.upload/3` is untouched — a lying multipart `content_type`
  # still cannot set the persisted mime. It gets STRICTLY STRONGER: a hostile
  # SVG named `pixel.png` used to be persisted as `image/png`; the bytes now
  # give it away, `image/svg+xml` is returned, and
  # `MediaFile.neutralize_dangerous_mime/1` collapses it at write exactly as it
  # collapses an honestly-named `.svg`.
  @sniff_bytes 1024

  @doc """
  Sniff a file's real MIME from its leading bytes, falling back to `fallback`
  when the content is not positively recognised.

  `fallback` is what the caller would have used on its own — normally
  `MIME.from_path/1` on the client filename. Passing `nil` yields `nil` for
  unrecognised content.

  This exists because a filename is not evidence: Gyldendal's 816 source
  assets were all named `remote.axd` by an old .NET image handler, so the
  extension-derived type was `application/octet-stream` for real PNGs and JPEGs
  and 515 uploads were unrenderable.
  """
  @spec sniff_mime(String.t(), String.t() | nil) :: String.t() | nil
  def sniff_mime(path, fallback \\ nil) when is_binary(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @sniff_bytes)) do
      {:ok, bin} when is_binary(bin) -> sniff_bytes(bin) || fallback
      _ -> fallback
    end
  end

  @doc """
  The pure half of `sniff_mime/2`: a MIME for a leading-bytes binary, or `nil`
  when nothing in the table matches. Public so the table can be tested without
  touching disk.
  """
  @spec sniff_bytes(binary()) :: String.t() | nil
  def sniff_bytes(bin) when is_binary(bin) do
    binary_magic(bin) || text_magic(bin)
  end

  def sniff_bytes(_), do: nil

  # Images
  defp binary_magic(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>), do: "image/png"
  defp binary_magic(<<255, 216, 255, _::binary>>), do: "image/jpeg"
  defp binary_magic(<<"GIF87a", _::binary>>), do: "image/gif"
  defp binary_magic(<<"GIF89a", _::binary>>), do: "image/gif"
  defp binary_magic(<<"RIFF", _::32, "WEBP", _::binary>>), do: "image/webp"
  defp binary_magic(<<"RIFF", _::32, "WAVE", _::binary>>), do: "audio/wav"
  defp binary_magic(<<"BM", _::binary-size(12), _::binary>>), do: "image/bmp"
  defp binary_magic(<<0x49, 0x49, 0x2A, 0x00, _::binary>>), do: "image/tiff"
  defp binary_magic(<<0x4D, 0x4D, 0x00, 0x2A, _::binary>>), do: "image/tiff"
  defp binary_magic(<<"%PDF-", _::binary>>), do: "application/pdf"

  # ISO-BMFF containers: the brand lives in the `ftyp` box at offset 4.
  defp binary_magic(<<_::32, "ftyp", brand::binary-size(4), _::binary>>), do: ftyp_mime(brand)

  # Other containers
  defp binary_magic(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: "video/webm"
  defp binary_magic(<<"OggS", _::binary>>), do: "audio/ogg"
  defp binary_magic(<<"fLaC", _::binary>>), do: "audio/flac"
  defp binary_magic(<<"ID3", _::binary>>), do: "audio/mpeg"
  defp binary_magic(<<255, second, _::binary>>) when second in [0xFB, 0xF3, 0xF2, 0xE3],
    do: "audio/mpeg"

  defp binary_magic(_), do: nil

  defp ftyp_mime("avif"), do: "image/avif"
  defp ftyp_mime("avis"), do: "image/avif"
  defp ftyp_mime("heic"), do: "image/heic"
  defp ftyp_mime("heix"), do: "image/heic"
  defp ftyp_mime("heif"), do: "image/heif"
  defp ftyp_mime("mif1"), do: "image/heif"
  defp ftyp_mime("qt  "), do: "video/quicktime"
  defp ftyp_mime(_), do: "video/mp4"

  # TEXT-SHAPED MARKUP, sniffed LAST and on purpose: these are the types
  # `MediaFile.dangerous_mime?/1` neutralizes, so recognising them can only
  # DOWNGRADE what gets persisted, never upgrade it. Leading whitespace and a
  # UTF-8 BOM are skipped, and an XML prologue is looked THROUGH — an SVG's
  # root element is what decides, not the `<?xml` that may precede it.
  defp text_magic(bin) do
    head = bin |> strip_bom() |> String.slice(0, @sniff_bytes) |> String.downcase()

    cond do
      not String.printable?(head, 16) -> nil
      String.contains?(head, "<svg") -> "image/svg+xml"
      String.starts_with?(String.trim_leading(head), "<!doctype html") -> "text/html"
      String.starts_with?(String.trim_leading(head), "<html") -> "text/html"
      true -> nil
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(bin), do: bin

  @doc "Probe a file on disk. Returns `{:error, :unsupported}` for unknown types."
  @spec probe(String.t(), String.t() | nil) :: {:ok, result()} | {:error, term()}
  def probe(path, mime_type \\ nil) when is_binary(path) do
    mime = mime_type || MIME.from_path(path)

    with {:ok, bin} <- read_prefix(path),
         {:ok, {w, h}} <- dimensions(bin, mime) do
      {:ok, %{width: w, height: h, exif: %{}}}
    end
  end

  defp read_prefix(path) do
    case File.read(path) do
      {:ok, bin} when byte_size(bin) > 0 ->
        {:ok, binary_part(bin, 0, min(byte_size(bin), 512_000))}

      {:ok, _} ->
        {:error, :empty}

      error ->
        error
    end
  end

  defp dimensions(bin, mime) do
    cond do
      String.starts_with?(mime, "image/png") or match_png?(bin) ->
        png_dimensions(bin)

      String.starts_with?(mime, "image/jpeg") or match_jpeg?(bin) ->
        jpeg_dimensions(bin)

      String.starts_with?(mime, "image/gif") or match_gif?(bin) ->
        gif_dimensions(bin)

      String.starts_with?(mime, "image/webp") or match_webp?(bin) ->
        webp_dimensions(bin)

      true ->
        {:error, :unsupported}
    end
  end

  defp match_png?(<<137, 80, 78, 71, _::binary>>), do: true
  defp match_png?(_), do: false

  defp match_jpeg?(<<255, 216, _::binary>>), do: true
  defp match_jpeg?(_), do: false

  defp match_gif?(<<"GIF", _::binary>>), do: true
  defp match_gif?(_), do: false

  defp match_webp?(<<"RIFF", _::32, "WEBP", _::binary>>), do: true
  defp match_webp?(_), do: false

  defp png_dimensions(<<137, 80, 78, 71, 13, 10, 26, 10, _::32, "IHDR", w::32, h::32, _::binary>>) do
    {:ok, {w, h}}
  end

  defp png_dimensions(_), do: {:error, :invalid_png}

  defp gif_dimensions(<<"GIF", _::24, w::16-little, h::16-little, _::binary>>) do
    {:ok, {w, h}}
  end

  defp gif_dimensions(_), do: {:error, :invalid_gif}

  defp jpeg_dimensions(bin) do
    case jpeg_find_sof(bin) do
      {w, h} -> {:ok, {w, h}}
      nil -> {:error, :invalid_jpeg}
    end
  end

  defp jpeg_find_sof(<<255, marker, rest::binary>>)
       when marker in [192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207] do
    case rest do
      <<_len::16, _precision::8, h::16, w::16, _::binary>> -> {w, h}
      _ -> jpeg_find_sof(rest)
    end
  end

  defp jpeg_find_sof(<<255, marker, rest::binary>>)
       when marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9) do
    # Standalone markers (SOI/EOI/RST0-7/TEM) carry no length segment.
    jpeg_find_sof(rest)
  end

  defp jpeg_find_sof(<<255, _marker, len::16, payload::binary>>) do
    skip = min(max(len - 2, 0), byte_size(payload))
    jpeg_find_sof(binary_part(payload, skip, byte_size(payload) - skip))
  end

  defp jpeg_find_sof(<<_, rest::binary>>), do: jpeg_find_sof(rest)
  defp jpeg_find_sof(<<>>), do: nil

  defp webp_dimensions(
         <<"RIFF", _::32, "WEBP", "VP8X", _::32, _flags::8, _reserved::24, w24::24-little,
           h24::24-little, _::binary>>
       ) do
    {:ok, {w24 + 1, h24 + 1}}
  end

  defp webp_dimensions(
         <<"RIFF", _::32, "WEBP", "VP8 ", _::32, _tag::24, 0x9D, 0x01, 0x2A, w::16-little,
           h::16-little, _::binary>>
       ) do
    {:ok, {Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF)}}
  end

  defp webp_dimensions(<<"RIFF", _::32, "WEBP", "VP8L", _::32, 0x2F, bits::32-little, _::binary>>) do
    {:ok, {Bitwise.band(bits, 0x3FFF) + 1, Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1}}
  end

  defp webp_dimensions(_), do: {:error, :invalid_webp}
end
