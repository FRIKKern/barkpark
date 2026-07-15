defmodule Barkpark.EpicFleet.CanonicalJSON do
  @moduledoc """
  Deterministic JSON encoding for portable Epic benchmark artifacts.

  Object keys are converted to strings and sorted recursively. Lists retain
  their semantic order. The resulting bytes can be hashed by non-BEAM readers
  without depending on Erlang external-term encoding.
  """

  @doc "Encode a JSON-compatible term with recursively sorted object keys."
  @spec encode(term()) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(term) do
    {:ok, term |> encode_iodata() |> IO.iodata_to_binary()}
  rescue
    error in [ArgumentError, Jason.EncodeError] -> {:error, error}
  end

  @doc "Bang variant of `encode/1`."
  @spec encode!(term()) :: binary()
  def encode!(term), do: term |> encode_iodata() |> IO.iodata_to_binary()

  @doc "Return a lowercase SHA-256 digest of the canonical JSON bytes."
  @spec digest(term()) :: String.t()
  def digest(term) do
    :sha256
    |> :crypto.hash(encode!(term))
    |> Base.encode16(case: :lower)
  end

  @doc "Convert object keys to strings recursively, rejecting key collisions."
  @spec stringify_keys(term()) :: term()
  def stringify_keys(term) when is_map(term) and not is_struct(term) do
    Enum.reduce(term, %{}, fn {key, value}, acc ->
      key = stringify_key(key)

      if Map.has_key?(acc, key) do
        raise ArgumentError, "duplicate canonical JSON key #{inspect(key)}"
      end

      Map.put(acc, key, stringify_keys(value))
    end)
  end

  def stringify_keys(term) when is_list(term), do: Enum.map(term, &stringify_keys/1)

  def stringify_keys(term) when is_atom(term) and term not in [true, false, nil],
    do: to_string(term)

  def stringify_keys(term), do: term

  defp encode_iodata(term) when is_map(term) and not is_struct(term) do
    pairs =
      term
      |> stringify_keys()
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> [Jason.encode!(key), ?:, encode_iodata(value)] end)
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  defp encode_iodata(term) when is_list(term) do
    items = term |> Enum.map(&encode_iodata/1) |> Enum.intersperse(?,)
    [?[, items, ?]]
  end

  defp encode_iodata(term) when is_binary(term), do: Jason.encode!(term)
  defp encode_iodata(term) when is_integer(term) or is_float(term), do: Jason.encode!(term)
  defp encode_iodata(term) when is_boolean(term) or is_nil(term), do: Jason.encode!(term)
  defp encode_iodata(term) when is_atom(term), do: Jason.encode!(Atom.to_string(term))

  defp encode_iodata(term) do
    raise ArgumentError, "not JSON-compatible: #{inspect(term)}"
  end

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: to_string(key)
end
