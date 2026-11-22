defmodule Barkpark.Content.Forms.ObjectRebase do
  @moduledoc """
  An object field's edit written subfield by subfield (task-04e50efa8405b956).

  A post carries every subfield of an object, so one that left the page
  before another editor's save carries that editor's subfields at their old
  values. The top-level rule of a save (`Forms.classic_save_content/7`) one
  level down: a subfield the post did not change from `base` (the row the
  form was drawn from) takes what `theirs` (the store now, or the form
  buffer) holds, and only a changed one is written. TanStack writes one path
  per change, so a sibling another editor saved is never written over.

  `mine` is the post after `Forms.edits/3`: an untouched subfield there is
  exactly the base's value (`restore_untouched`), so the test is `===`.
  """

  @doc """
  `params` with each object field rebased onto `theirs`. Only a field the
  schema calls `composite`, held as an object in all three, is touched.
  """
  @spec onto(map(), map(), map(), map() | nil) :: map()
  def onto(params, base, theirs, %{fields: fields}) when is_list(fields),
    do: rebase(fields, params, base, theirs)

  def onto(params, _base, _theirs, _schema), do: params

  @doc "Whether `key` is an object field (`composite`) of `schema`."
  @spec object?(map() | nil, String.t()) :: boolean()
  def object?(%{fields: fields}, key) when is_list(fields),
    do: Enum.any?(fields, &match?(%{"name" => ^key, "type" => "composite"}, &1))

  def object?(_schema, _key), do: false

  defp rebase(fields, mine, base, theirs) do
    Enum.reduce(fields, mine, fn
      %{"name" => key, "type" => "composite"} = field, acc when is_binary(key) ->
        case {Map.fetch(acc, key), Map.get(base, key), Map.get(theirs, key)} do
          {{:ok, %{} = m}, %{} = b, %{} = t}
          when not is_struct(m) and not is_struct(b) and not is_struct(t) ->
            Map.put(acc, key, object(field, m, b, t))

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  defp object(field, mine, base, theirs) do
    subs = if is_list(field["fields"]), do: field["fields"], else: []

    kept =
      Enum.reduce(mine, theirs, fn {key, value}, acc ->
        if Map.has_key?(base, key) and value === Map.fetch!(base, key),
          do: acc,
          else: Map.put(acc, key, value)
      end)

    # A subfield the post took off that nobody else changed goes; one
    # another editor changed or added stays theirs.
    kept =
      Enum.reduce(theirs, kept, fn {key, value}, acc ->
        if not Map.has_key?(mine, key) and Map.has_key?(base, key) and
             value === Map.fetch!(base, key),
           do: Map.delete(acc, key),
           else: acc
      end)

    # A changed object subfield is itself written subfield by subfield; an
    # untouched one is theirs already, and rebasing it changes nothing.
    rebase(subs, kept, base, theirs)
  end
end
