defmodule Barkpark.Content.Validation.Ops do
  @moduledoc """
  Built-in op evaluator. Each clause takes `(lhs_value, rhs_or_args)` and
  returns a boolean.

  Supported ops:

    * `:eq`            — strict equality (`==`).
    * `:in`            — membership in a list.
    * `:nonempty`      — value is not nil / `""` / `[]` / `%{}`.
    * `:contains_all`  — list (lhs) contains every element of rhs.
    * `:starts_with`   — string (lhs) starts with rhs.
    * `{:matches, c}`  — defers to `Barkpark.Validation.Registry.find/1`,
                         calls `c.check(lhs, args)`, returns `true` on `:ok`.

  Unknown ops return `false` rather than raising — invalid rules are inert.
  """

  alias Barkpark.Validation.Registry

  @doc """
  Evaluate `op` on `lhs`/`rhs`. Returns a boolean.
  """
  @spec eval(term(), term(), term()) :: boolean()
  def eval(:eq, lhs, rhs), do: lhs == rhs

  def eval(:in, lhs, rhs) when is_list(rhs), do: Enum.member?(rhs, lhs)
  def eval(:in, _lhs, _rhs), do: false

  def eval(:nonempty, lhs, _rhs), do: not blank?(lhs)

  def eval(:contains_all, lhs, rhs) when is_list(lhs) and is_list(rhs) do
    Enum.all?(rhs, &Enum.member?(lhs, &1))
  end

  def eval(:contains_all, _lhs, _rhs), do: false

  def eval(:starts_with, lhs, rhs) when is_binary(lhs) and is_binary(rhs) do
    String.starts_with?(lhs, rhs)
  end

  def eval(:starts_with, _lhs, _rhs), do: false

  def eval({:matches, name}, lhs, args) when is_binary(name) do
    case Registry.find(name) do
      {:ok, mod} ->
        try do
          case mod.check(lhs, args) do
            :ok -> true
            {:error, _code} -> false
            _ -> false
          end
        rescue
          _ -> false
        end

      :error ->
        false
    end
  end

  def eval(_op, _lhs, _rhs), do: false

  @doc """
  Stable string code for a violation, derived from the op. Consumed by
  WI2's error envelope serializer (`code` field).
  """
  @spec code(term()) :: String.t()
  def code({:matches, name}), do: "matches:" <> to_string(name)
  def code(op) when is_atom(op), do: Atom.to_string(op)
  def code(other), do: inspect(other)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(map) when is_map(map) and map_size(map) == 0, do: true
  defp blank?(_), do: false
end
