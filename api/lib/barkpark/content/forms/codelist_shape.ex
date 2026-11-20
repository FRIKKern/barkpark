defmodule Barkpark.Content.Forms.CodelistShape do
  @moduledoc """
  What a form save takes for a codelist field: one code, a short string.

  An unknown code is stored on purpose (task-400a66c6ebd31026): stored
  documents may hold codes a list does not, and `Validation` shows a
  warning under the field. Anything else posted for a single-value
  codelist (a list, a map, a number, or a string longer than any code)
  was stored as posted by a hand-made autosave (task-6617a482448ddb3d).
  The save now drops such a post for that field, so the store keeps what
  it holds; the rest of the post is saved as before.

  The longest code in the bundled lists is 14 characters (Thema), ONIX's
  are shorter; `max_length/0` leaves room for codes we do not ship.
  A blank post (`""` or nil) still clears the field, and the desk's unset
  marker still unsets it.
  """

  alias Barkpark.Content.Forms.Unset

  @max_length 64

  @doc "The longest string a codelist field takes from a form, in characters."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  `params` without the top-level codelist fields whose post is not a code.
  `schema` is the canonical schema (`%{fields: [...]}`); any other schema
  leaves `params` as they are.
  """
  @spec drop_misshapen(map(), term()) :: map()
  def drop_misshapen(params, %{fields: fields}) when is_map(params) and is_list(fields) do
    Enum.reduce(fields, params, fn
      %{"name" => key, "type" => "codelist"}, acc when is_binary(key) ->
        case Map.fetch(acc, key) do
          {:ok, posted} -> if code?(posted), do: acc, else: Map.delete(acc, key)
          :error -> acc
        end

      _field, acc ->
        acc
    end)
  end

  def drop_misshapen(params, _schema), do: params

  defp code?(nil), do: true
  defp code?(%Unset{}), do: true

  # A code's characters can take up to 4 bytes each; the byte check keeps a
  # huge post from being walked.
  defp code?(code) when is_binary(code),
    do: byte_size(code) <= 4 * @max_length and String.length(code) <= @max_length

  defp code?(_posted), do: false
end
