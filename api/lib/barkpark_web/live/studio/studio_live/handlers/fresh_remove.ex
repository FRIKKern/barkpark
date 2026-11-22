defmodule BarkparkWeb.Studio.StudioLive.Handlers.FreshRemove do
  @moduledoc """
  A tree codelist's Remove, made onto what the store holds now
  (task-39426106a2913be5), in the desk and the old Studio.

  A Remove is handled from this editor's copy of the document. Another
  editor's save can land before that copy hears of it: their new code at
  the same spot, or a sibling key of the same object. Built from the copy,
  the Remove wrote the field back as the copy had it, and their code or
  their sibling key was lost with no word to anyone.

  So the field is read from the store first:
  - the value at the Remove's path is still the one this editor's page
    shows (its form buffer, which another editor's save that reached it is
    in): the Remove is built on the field as the store holds it now, so
    a sibling key someone else changed stays theirs;
  - it is not: someone else's value landed there unseen, and nothing is
    written. Theirs stays, and this editor's page draws it when their save
    reaches it, as the TanStack Studio keeps another editor's newer value.

  When the store cannot be read, the Remove is built on the copy, as before.
  """
  alias Barkpark.Content
  alias Barkpark.Content.Forms
  alias BarkparkWeb.ScopeHelpers

  @doc """
  The form a Remove of the code at `path` is built on: `form` (the editor's
  buffer) with the path's top-level field as the store holds it now, or
  `:moved` when the value at `path` is not the one the editor's page shows.
  """
  @spec base(Phoenix.LiveView.Socket.t(), map(), [String.t() | integer()]) ::
          {:ok, map()} | :moved
  def base(socket, form, [key | rest]) when is_binary(key) do
    assigns = socket.assigns

    with %{doc_id: id} when is_binary(id) <- assigns[:editor_doc],
         type when is_binary(type) <- assigns[:editor_type],
         {%{} = now, _, _} <-
           Content.fetch_doc_with_draft(
             type,
             Content.published_id(id),
             assigns.dataset,
             ScopeHelpers.scope_opts(socket)
           ) do
      # Both as the form draws them (`Forms.doc_to_form/2`, the round trip
      # the buffer was made by): the buffer is what the page shows, another
      # editor's save that reached this editor included.
      stored = Forms.doc_to_form(now, assigns[:editor_schema])

      cond do
        at(Map.get(stored, key), rest) != at(Map.get(form, key), rest) -> :moved
        Map.has_key?(stored, key) -> {:ok, Map.put(form, key, Map.get(stored, key))}
        true -> {:ok, form}
      end
    else
      _ -> {:ok, form}
    end
  end

  def base(_socket, form, _path), do: {:ok, form}

  defp at(value, []), do: value

  defp at(value, [i | rest]) when is_list(value) and is_integer(i),
    do: value |> Enum.at(i) |> at(rest)

  defp at(%{} = value, [key | rest]) when not is_struct(value) and is_binary(key),
    do: value |> Map.get(key) |> at(rest)

  defp at(_value, _path), do: nil
end
