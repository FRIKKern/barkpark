defmodule Barkpark.Tenancy.WorkspaceBundle.LocalOnly do
  @moduledoc """
  What belongs to this database alone and never travels in a workspace bundle,
  in any import mode (clean or merge; an operator's import or a confined one,
  observed or enforced).

  * **A table: `workspace_access_requests`.** An access request is an ask a
    person makes in this workspace, decided by its admins. An import does not
    carry access requests; people ask again. The target's own requests stay
    exactly as they were. The export still writes the table into the bundle,
    so the bundle format is unchanged; the import leaves those rows out and
    says how many in its result, `access_requests_left_out` (0 when the bundle
    held none).
  * **Columns: `seat_change`** on `workspace_memberships` and on
    `workspace_access_requests`. The seat change stamp is set by this
    database alone (task-018e79d8734a1b08). The export leaves these
    columns out; an import refuses a bundle that names one (`invalid_bundle`).
  * **A trigger: `workspace_memberships_seat_change`**, the one setter of a
    seat's stamp, `ENABLE ALWAYS` so it fires under
    `session_replication_role = replica` too. The import turns user triggers
    off on every member table (`DISABLE TRIGGER USER`);
    `disable_user_triggers!/2` turns this one back on by name in the same
    breath, so every seat row the import writes gets a new stamp from this
    database. `ENABLE TRIGGER USER` at the end would leave it plain enabled,
    so `enable_user_triggers!/2` sets it back to `ENABLE ALWAYS`.

  The engine calls `disable_user_triggers!/2` once, `import!/5` per member (in
  place of `ImportConfinement.import!/5`), `settle!/3` after the members land,
  and `enable_user_triggers!/2` once. The export asks `columns/1`.
  """

  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle.{ImportConfinement, InvalidBundleError}

  @access_requests "workspace_access_requests"
  @memberships "workspace_memberships"
  @tables [@access_requests]
  @columns %{@memberships => ["seat_change"], @access_requests => ["seat_change"]}
  @keep_seat_trigger "ALTER TABLE public.workspace_memberships ENABLE ALWAYS TRIGGER workspace_memberships_seat_change"

  @doc "Tables an import never writes."
  @spec tables() :: [String.t()]
  def tables, do: @tables

  @doc "Columns of `table` that a bundle never carries."
  @spec columns(String.t()) :: [String.t()]
  def columns(table), do: Map.get(@columns, table, [])

  @doc """
  `alter!.(live, "DISABLE")` (the engine's `DISABLE TRIGGER USER` on every
  member table), then the seat-stamp trigger back to `ENABLE ALWAYS` by name
  when `workspace_memberships` is a member.
  """
  def disable_user_triggers!(live, alter!), do: alter_then_keep!(live, alter!, "DISABLE")

  @doc "`alter!.(live, \"ENABLE\")`, then the seat-stamp trigger back to `ENABLE ALWAYS`."
  def enable_user_triggers!(live, alter!), do: alter_then_keep!(live, alter!, "ENABLE")

  defp alter_then_keep!(live, alter!, action) do
    alter!.(live, action)

    if @memberships in live, do: Repo.query!(@keep_seat_trigger, [])
    :ok
  end

  @doc """
  Hook per member: a local-only table is left out (its extracted member file is
  released, 0 rows written); a member naming a local-only column is refused;
  every other member goes on to `ImportConfinement.import!/5` unchanged.
  """
  def import!(confined, %{"name" => table} = entry, dumps, mode, import_member) do
    cond do
      table in @tables ->
        release!(Map.get(dumps, table, ""))

      (carried = local_columns_in(entry)) != [] ->
        raise InvalidBundleError,
          code: "invalid_bundle",
          message:
            "#{table} carries #{Enum.join(carried, ", ")}, which only this database " <>
              "sets; a workspace bundle never holds it"

      true ->
        ImportConfinement.import!(confined, entry, dumps, mode, import_member)
    end
  end

  defp local_columns_in(%{"name" => table} = entry) do
    case entry["columns"] do
      cols when is_list(cols) -> Enum.filter(columns(table), &(&1 in cols))
      _ -> []
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
