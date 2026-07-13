defmodule Barkpark.Tenancy.WorkspaceBundle.Archive do
  @moduledoc """
  The bp-export-v1 container: a tar carrying a `manifest.json` plus one
  `tables/<name>.copy` member per exported table (charter D1). The `.copy`
  members are the RAW `COPY … TO STDOUT` text bytes — the byte carrier
  (charter D2), never `Envelope.render` output (charter D9).

  `:erl_tar` has no in-memory create, so packing writes a short-lived temp tar
  and reads it back; extraction is fully in-memory from the bundle binary.
  """

  @format "bp-export-v1"
  @grain "workspace"
  @manifest_name ~c"manifest.json"

  @doc """
  Pack a manifest map + a `%{table => copy_bytes}` map into a bundle binary.
  """
  def pack(manifest, table_dumps) when is_map(manifest) and is_map(table_dumps) do
    manifest_bytes = Jason.encode!(manifest, pretty: true)

    members =
      [{@manifest_name, manifest_bytes}] ++
        Enum.map(table_dumps, fn {table, bytes} ->
          {~c"tables/" ++ String.to_charlist(table) ++ ~c".copy", bytes}
        end)

    path =
      Path.join(
        System.tmp_dir!(),
        "bp-ws-bundle-#{System.unique_integer([:positive])}.tar"
      )

    try do
      :ok = :erl_tar.create(String.to_charlist(path), members, [])
      File.read!(path)
    after
      File.rm(path)
    end
  end

  @doc """
  Extract a bundle binary into `{manifest_map, %{table => copy_bytes}}`.
  """
  def unpack(bundle) when is_binary(bundle) do
    {:ok, entries} = :erl_tar.extract({:binary, bundle}, [:memory])

    {manifest_bytes, dumps} =
      Enum.reduce(entries, {nil, %{}}, fn {name, content}, {mf, acc} ->
        name = to_string(name)

        cond do
          name == "manifest.json" ->
            {content, acc}

          String.starts_with?(name, "tables/") and String.ends_with?(name, ".copy") ->
            table =
              name |> String.replace_prefix("tables/", "") |> String.replace_suffix(".copy", "")

            {mf, Map.put(acc, table, content)}

          true ->
            {mf, acc}
        end
      end)

    if is_nil(manifest_bytes) do
      raise "WorkspaceBundle.Archive: bundle has no manifest.json"
    end

    {Jason.decode!(manifest_bytes), dumps}
  end

  def format, do: @format
  def grain, do: @grain
end
