defmodule Barkpark.BpmlStoredDocuments do
  @moduledoc """
  The stored documents the test suite carries, for the BPML checks: the block
  goldens, the limit goldens and the BPML fixtures.
  Each entry is `{path relative to the repo root, top-level blocks}`.
  """

  @root Path.expand("../../..", __DIR__)

  @sources [
    {"api/priv/portable_doc/goldens/blocks/*.golden.json", :golden},
    {"api/priv/portable_doc/goldens/limits/*.golden.json", :golden},
    {"api/test/support/fixtures/bpml/*.json", :blocks}
  ]

  @spec all() :: [{String.t(), [map()]}]
  def all do
    for {pattern, kind} <- @sources,
        file <- @root |> Path.join(pattern) |> Path.wildcard() |> Enum.sort() do
      json = file |> File.read!() |> Jason.decode!()

      blocks =
        case {kind, json} do
          {:golden, %{"input" => input}} -> [input]
          {:blocks, list} when is_list(list) -> list
          {:blocks, %{"blocks" => blocks}} when is_list(blocks) -> blocks
          _ -> []
        end

      {Path.relative_to(file, @root), blocks}
    end
  end

  @doc "The input block of `api/priv/portable_doc/goldens/blocks/<name>.golden.json`."
  @spec golden(String.t()) :: map()
  def golden(name) do
    @root
    |> Path.join("api/priv/portable_doc/goldens/blocks/#{name}.golden.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("input")
  end
end
