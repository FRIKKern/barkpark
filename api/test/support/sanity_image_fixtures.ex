defmodule Barkpark.SanityImageFixtures do
  @moduledoc """
  Image uploads for the Sanity asset document tests (task-b3e57f301bd502d8).
  A PNG of a given size, built in memory, stored through the real
  `Barkpark.Media.upload/3` so the row carries scope, sha1 and its
  `mediaAsset` document.
  """

  alias Barkpark.Media

  @doc "An RGB PNG of `w` by `h` pixels."
  def png(w \\ 3, h \\ 2) do
    row = <<0>> <> :binary.copy(<<200, 30, 90>>, w)
    idat = :zlib.compress(:binary.copy(row, h))
    ihdr = <<w::32, h::32, 8, 2, 0, 0, 0>>

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", ihdr) <> chunk("IDAT", idat) <> chunk("IEND", "")
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>

  @doc "Upload `bytes` as `name` into `dataset` under `scope`."
  def upload!(scope, bytes \\ png(), name \\ "omslag.png", dataset \\ "production") do
    path = Barkpark.TestTmp.path(name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    {:ok, file} =
      Media.upload(
        %Plug.Upload{path: path, filename: name, content_type: "image/png"},
        dataset,
        scope
      )

    file
  end
end
