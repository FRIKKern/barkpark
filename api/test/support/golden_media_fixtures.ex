defmodule Barkpark.GoldenMediaFixtures do
  @moduledoc """
  Seeds the media corpus the `media` golden surface is scored against.

  THE CORPUS IS DERIVED FROM THE FIXTURE, NOT RETYPED BESIDE IT. The ids this
  inserts are read out of `test/search_golden/media/test.jsonl`'s `expect_ids`,
  and each blob's filename carries the `q` that is supposed to retrieve it. So
  a fixture entry added, removed or re-worded on disk changes what gets seeded
  with no edit here, and an `expect_ids` that no seeded blob can satisfy is a
  contradiction the fixture cannot express: every declared id IS a row.

  `media_files.id` is a `:binary_id` with `autogenerate: true`, which Ecto only
  applies when the struct's id is nil — so the fixture's literal UUIDs survive
  the insert and `GoldenEval`'s `Enum.map(files, & &1.id)` can be compared
  against them.
  """

  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @doc "Path of the media golden fixture, relative to the app's cwd."
  @spec fixture_path() :: String.t()
  def fixture_path, do: Path.join([File.cwd!(), "test", "search_golden", "media", "test.jsonl"])

  @doc "The fixture entries, decoded, in file order."
  @spec entries() :: [map()]
  def entries do
    fixture_path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Insert one `media_files` row per declared `expect_id`, in `dataset`.

  Blobs are left NULL-workspace and NULL-`dataset_id` on purpose: that is the
  shape `GoldenEval.run("media", scope)` reads, which passes no tenancy opts
  (`scope_to_workspace_or_global(q, nil, _)` leaves the query untouched, and
  the unresolved-dataset arm filters `m.dataset == scope and is_nil(m.dataset_id)`).

  Returns the list of seeded ids.
  """
  @spec seed!(String.t()) :: [String.t()]
  def seed!(dataset) when is_binary(dataset) do
    entries()
    |> Enum.flat_map(fn entry -> Enum.map(entry["expect_ids"] || [], &{entry["q"], &1}) end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{q, id}, i} ->
      slug = q |> String.replace(~r/[^a-zA-Z0-9]+/, "-") |> String.trim("-")
      name = "#{slug}-#{i}.png"

      {:ok, file} =
        %MediaFile{id: id}
        |> MediaFile.changeset(%{
          filename: name,
          original_name: name,
          path: "golden/#{dataset}/#{name}",
          mime_type: "image/png",
          size: 1,
          dataset: dataset
        })
        |> Repo.insert()

      file.id
    end)
  end
end
