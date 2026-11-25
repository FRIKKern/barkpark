defmodule Barkpark.Content.NulByte do
  @moduledoc """
  A NUL (U+0000) in a written string is a 422, not a 500
  (task-0d3af3362c4702d8).

  Postgres stores no NUL: a `text`/`varchar` column raises 22021 on one and
  `jsonb` raises 22P05 on a `\\u0000` escape, so a write holding one used to
  raise in the insert and the API answered 500, which tells the caller to
  retry a write that fails the same way forever.

  It is checked in `Barkpark.Content.Document.changeset/2`, the one changeset
  every write door goes through (as `Content.DocumentSize` is), and only on a
  changed field. The error names the field and, inside `content`, the JSON
  pointer to the first string holding a NUL; a NUL in an object key names the
  object holding that key, so the message never carries the NUL itself.
  Other control characters are stored as they are.
  """

  import Ecto.Changeset, only: [add_error: 4]

  # The caller-supplied string columns, and the content.
  @fields [:doc_id, :type, :dataset, :title, :content]

  @doc "Adds a `validation: :nul_byte` error to each changed field holding a NUL."
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(%Ecto.Changeset{changes: changes} = cs) do
    Enum.reduce(@fields, cs, fn field, cs ->
      case changes |> Map.get(field) |> find("") do
        nil -> cs
        {:value, ""} -> add_error(cs, field, "holds a NUL byte", validation: :nul_byte)
        {:value, at} -> error(cs, field, "holds a NUL byte at %{path}", at)
        {:key, ""} -> add_error(cs, field, "holds a NUL byte in a key", validation: :nul_byte)
        {:key, at} -> error(cs, field, "holds a NUL byte in a key at %{path}", at)
      end
    end)
  end

  defp error(cs, field, message, at),
    do: add_error(cs, field, message, validation: :nul_byte, path: at)

  @doc """
  `{:value, pointer}` for the first string holding a NUL, `{:key, pointer}`
  for the first object with a NUL in a key, or nil. The pointer is from
  `value`'s root, `""` for the value itself.
  """
  @spec find(term(), String.t()) :: {:value | :key, String.t()} | nil
  def find(value, at) when is_binary(value), do: if(nul?(value), do: {:value, at})

  def find(%{} = map, at) when not is_struct(map) do
    Enum.find_value(map, fn {k, v} ->
      key = key(k)
      if nul?(key), do: {:key, at}, else: find(v, at <> "/" <> escape(key))
    end)
  end

  def find(list, at) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {v, i} -> find(v, "#{at}/#{i}") end)
  end

  def find(_value, _at), do: nil

  defp nul?(string), do: :binary.match(string, <<0>>) != :nomatch

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: to_string(k)

  defp escape(key), do: key |> String.replace("~", "~0") |> String.replace("/", "~1")
end
