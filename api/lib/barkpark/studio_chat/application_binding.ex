defmodule Barkpark.StudioChat.ApplicationBinding do
  @moduledoc "Closed server configuration for personal application turns; absent means unavailable."

  @fields ~w(contract_version host_id version workspace_id)
  @max_config_bytes 16_384
  @max_applications 16

  @doc "Parse a closed deployment JSON map; no host provisioning or implicit default."
  def parse_env(nil), do: {:ok, %{}}

  def parse_env(raw) when is_binary(raw) and byte_size(raw) <= @max_config_bytes do
    with {:ok, %Jason.OrderedObject{values: entries}} <-
           Jason.decode(raw, objects: :ordered_objects),
         true <- length(entries) <= @max_applications and unique_keys?(entries) do
      Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, bindings} ->
        case parse_entry(entry) do
          {:ok, {id, binding}} -> {:cont, {:ok, Map.put(bindings, id, binding)}}
          :error -> {:halt, {:error, :invalid_application_config}}
        end
      end)
    else
      _ -> {:error, :invalid_application_config}
    end
  end

  def parse_env(_), do: {:error, :invalid_application_config}

  defp parse_entry({id, %Jason.OrderedObject{values: entries}}) do
    fields = Map.new(entries)

    if config_string?(id, ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/) and
         unique_keys?(entries) and Enum.sort(Map.keys(fields)) == @fields and
         canonical_uuid?(fields["workspace_id"]) and canonical_uuid?(fields["host_id"]) and
         config_string?(fields["version"]) and config_string?(fields["contract_version"]) do
      {:ok,
       {id,
        %{
          workspace_id: fields["workspace_id"],
          host_id: fields["host_id"],
          version: fields["version"],
          contract_version: fields["contract_version"]
        }}}
    else
      :error
    end
  end

  defp parse_entry(_), do: :error

  defp unique_keys?(entries) do
    keys = Enum.map(entries, &elem(&1, 0))
    length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp canonical_uuid?(value) when is_binary(value),
    do: match?({:ok, ^value}, Ecto.UUID.cast(value))

  defp canonical_uuid?(_), do: false

  defp config_string?(value, pattern \\ ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,99}\z/),
    do: is_binary(value) and Regex.match?(pattern, value)

  def resolve(id, workspace) when is_binary(id) and is_binary(workspace) do
    with bindings when is_map(bindings) <-
           Application.get_env(:barkpark, :personal_chat_applications, %{}),
         %{workspace_id: ^workspace, host_id: host, version: version, contract_version: contract} <-
           Map.get(bindings, id),
         {:ok, _} <- Ecto.UUID.cast(host),
         true <- bounded?(id) and bounded?(version) and bounded?(contract) do
      {:ok,
       %{"id" => id, "version" => version, "host_id" => host, "contract_version" => contract}}
    else
      _ -> {:error, :application_unavailable}
    end
  end

  def resolve(_, _), do: {:error, :application_unavailable}
  defp bounded?(s), do: is_binary(s) and byte_size(s) in 1..100
end
