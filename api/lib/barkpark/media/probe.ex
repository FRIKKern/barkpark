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
         <<"RIFF", _::32, "WEBP", "VP8 ", _::32, _tag::24, 0x9D, 0x01, 0x2A,
           w::16-little, h::16-little, _::binary>>
       ) do
    {:ok, {Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF)}}
  end

  defp webp_dimensions(
         <<"RIFF", _::32, "WEBP", "VP8L", _::32, 0x2F, bits::32-little, _::binary>>
       ) do
    {:ok,
     {Bitwise.band(bits, 0x3FFF) + 1, Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1}}
  end

  defp webp_dimensions(_), do: {:error, :invalid_webp}
end
