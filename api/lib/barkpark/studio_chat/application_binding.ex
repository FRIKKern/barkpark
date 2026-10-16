defmodule Barkpark.StudioChat.ApplicationBinding do
  @moduledoc "Closed server configuration for personal application turns; absent means unavailable."

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
