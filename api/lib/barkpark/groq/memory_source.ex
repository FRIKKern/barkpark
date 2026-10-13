defmodule Barkpark.Groq.MemorySource do
  @moduledoc """
  A `Barkpark.Groq.Source` over a list of documents held in memory. Used by the
  conformance suite and by unit tests; documents are sorted by `_id`, as the
  GROQ test suite expects.
  """

  @behaviour Barkpark.Groq.Source

  @spec new([map()]) :: Barkpark.Groq.Source.t()
  def new(documents) when is_list(documents) do
    docs = Enum.sort_by(documents, &id_key/1)
    by_id = for %{"_id" => id} = d <- Enum.reverse(docs), is_binary(id), into: %{}, do: {id, d}
    {__MODULE__, %{docs: docs, by_id: by_id}}
  end

  @impl true
  def fetch(%{docs: docs}, %{types: types}) when is_list(types) do
    Enum.filter(docs, &(is_map(&1) and &1["_type"] in types))
  end

  def fetch(%{docs: docs}, _constraints), do: docs

  @impl true
  def get(%{by_id: by_id}, id), do: Map.get(by_id, id)

  defp id_key(%{"_id" => id}) when is_binary(id), do: {0, id}
  defp id_key(_), do: {1, ""}
end
