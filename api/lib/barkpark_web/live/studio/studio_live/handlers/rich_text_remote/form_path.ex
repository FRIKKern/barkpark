defmodule BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath do
  @moduledoc """
  A value at a path in a form or a post (`RichTextRemote`): object keys and
  row indexes, as `Path.parse_path/1` reads an input name.
  """

  # A post's rows can come as a list or as a map keyed "0", "1", ….
  @doc "The value at `path`, or nil."
  def get(value, []), do: value
  def get(list, [i | rest]) when is_list(list) and is_integer(i), do: get(Enum.at(list, i), rest)

  def get(%{} = map, [seg | rest]) when not is_struct(map) do
    case Map.fetch(map, seg) do
      {:ok, v} -> get(v, rest)
      :error -> if is_integer(seg), do: get(Map.get(map, Integer.to_string(seg)), rest)
    end
  end

  def get(_value, _path), do: nil

  @doc "`value` with `new` at `path`; a path that is not there changes nothing."
  def put(_value, [], new), do: new

  def put(list, [i | rest], new) when is_list(list) and is_integer(i) and i < length(list),
    do: List.update_at(list, i, &put(&1, rest, new))

  def put(%{} = map, [seg | rest], new) when not is_struct(map) do
    key =
      if is_integer(seg) and not Map.has_key?(map, seg) and
           Map.has_key?(map, Integer.to_string(seg)),
         do: Integer.to_string(seg),
         else: seg

    if Map.has_key?(map, key), do: Map.put(map, key, put(Map.get(map, key), rest, new)), else: map
  end

  def put(value, _path, _new), do: value
end
