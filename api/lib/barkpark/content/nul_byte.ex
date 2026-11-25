defmodule Barkpark.Content.NulByte do
  @moduledoc """
  A NUL (U+0000) in a written string is a 422, not a 500
  (task-0d3af3362c4702d8, task-b456c48d916f7cbc).

  Postgres stores no NUL: a `text`/`varchar` column raises 22021 on one and
  `jsonb` raises 22P05 on a `\\u0000` escape, so a write holding one used to
  raise in the insert and the API answered 500, which tells the caller to
  retry a write that fails the same way forever.

  It is checked in `Barkpark.Content.Document.changeset/2` (as
  `Content.DocumentSize` is), on a changed field. Writes that skip that
  changeset and put caller words into `content` call `refuse!/2` instead: the
  task verbs' `Tasks.Internal.fenced_content_write/4` and the session trail's
  `Content.Sessions.append_event/5` and `touch_conversation/5`. Writers that
  store only server values (the envelope reseal, a title restored from a
  stored revision, scope moves) are not checked.

  The error names the field and, inside `content`, the JSON pointer to the
  first string holding a NUL; a NUL in an object key names the object holding
  that key, so the message never carries the NUL itself. Other control
  characters are stored as they are.
  """

  import Ecto.Changeset, only: [add_error: 4]

  alias Barkpark.Content.NulByteError

  # The caller-supplied string columns, and the content.
  @fields [:doc_id, :type, :dataset, :title, :content]

  @doc "Adds a `validation: :nul_byte` error to each changed field holding a NUL."
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(%Ecto.Changeset{changes: changes} = cs) do
    Enum.reduce(@fields, cs, fn field, cs ->
      case changes |> Map.get(field) |> check() do
        nil -> cs
        message -> add_error(cs, field, message, validation: :nul_byte)
      end
    end)
  end

  @doc """
  Raises `Barkpark.Content.NulByteError` (422 `validation_failed`, the
  changeset's shape) when `value`, written to `field`, holds a NUL.
  """
  @spec refuse!(atom(), term()) :: :ok
  def refuse!(field, value) do
    case check(value) do
      nil -> :ok
      message -> raise NulByteError, field: field, message: message
    end
  end

  @doc "The refusal message for a value holding a NUL, or nil."
  @spec check(term()) :: String.t() | nil
  def check(value) do
    case find(value, []) do
      nil -> nil
      {:value, []} -> "holds a NUL byte"
      {:value, at} -> "holds a NUL byte at " <> pointer(at)
      {:key, []} -> "holds a NUL byte in a key"
      {:key, at} -> "holds a NUL byte in a key at " <> pointer(at)
    end
  end

  # The walk carries the path as a reversed list of keys and indexes; the
  # pointer string is built only on a hit (#28712 review).
  defp find(value, at) when is_binary(value), do: if(nul?(value), do: {:value, at})

  defp find(%{} = map, at) when not is_struct(map) do
    Enum.find_value(map, fn {k, v} ->
      key = key(k)
      if nul?(key), do: {:key, at}, else: find(v, [key | at])
    end)
  end

  defp find(list, at) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {v, i} -> find(v, [i | at]) end)
  end

  defp find(_value, _at), do: nil

  defp pointer(at), do: at |> Enum.reverse() |> Enum.map_join(&("/" <> escape(&1)))

  defp nul?(string), do: :binary.match(string, <<0>>) != :nomatch

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: to_string(k)

  defp escape(i) when is_integer(i), do: Integer.to_string(i)
  defp escape(key), do: key |> String.replace("~", "~0") |> String.replace("/", "~1")
end
