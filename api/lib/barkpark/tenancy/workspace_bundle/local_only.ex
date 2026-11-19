defmodule Barkpark.Tenancy.WorkspaceBundle.LocalOnly do
  @moduledoc """
  Tables a workspace import never writes, in any mode (clean or merge; an
  operator's import or a confined one, observed or enforced).

  `workspace_access_requests` is the one table. An access request is an ask a
  person makes in this workspace, decided by its admins, so it does not
  travel: an import does not carry access requests, and people ask again. The
  target's own requests stay exactly as they were.

  The export still writes the table into the bundle, so the bundle format is
  unchanged; the import leaves those rows out and says how many in its result,
  `access_requests_left_out` (0 when the bundle held none).

  The engine calls two hooks: `import!/5` per member, in place of
  `ImportConfinement.import!/5`, and `settle!/3` after the members land.
  """

  alias Barkpark.Tenancy.WorkspaceBundle.ImportConfinement

  @access_requests "workspace_access_requests"
  @tables [@access_requests]

  @doc "Tables an import never writes."
  @spec tables() :: [String.t()]
  def tables, do: @tables

  @doc """
  Hook per member: a local-only table is left out (its extracted member file is
  released, 0 rows written); every other member goes on to
  `ImportConfinement.import!/5` unchanged.
  """
  def import!(confined, %{"name" => table} = entry, dumps, mode, import_member) do
    if table in @tables do
      release!(Map.get(dumps, table, ""))
    else
      ImportConfinement.import!(confined, entry, dumps, mode, import_member)
    end
  end

  @doc """
  Hook after the members land: `ImportConfinement.settle!/2`, then the count of
  access requests the bundle carried and the import left out.
  """
  def settle!(stats, confined, manifest) do
    stats
    |> ImportConfinement.settle!(confined)
    |> Map.put(:access_requests_left_out, row_count(manifest, @access_requests))
  end

  defp row_count(manifest, table) do
    Enum.find_value(manifest["tables"] || [], 0, fn
      %{"name" => ^table, "row_count" => n} when is_integer(n) -> n
      _ -> nil
    end)
  end

  # As the engine's `release_member/1`: the member file is the engine's own
  # extraction path, deleted once read.
  # sobelow_skip ["Traversal.FileModule"]
  defp release!(dump) do
    with {:file, path} <- dump, do: File.rm(path)
    0
  end
end
