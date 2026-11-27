defmodule BarkparkWeb.Studio.StudioLive.Handlers.HeldSeed do
  @moduledoc """
  The form the save fold seeds a posted field from (task-38e3de7fb9f10312).

  The fold writes a post's dotted leaves into the field's value as the
  form holds it (`Fields.seed_root/3`): a post carries only the leaves its
  page renders. While a rich text is held (`editor_rt_held`), A's form is
  unsaved and does not take another editor's saves of that field
  (`Lifecycle`'s kept buffer). A stale post seeded from it wrote A's old
  rows back: B's inserted row was lost, B's removed row came back, and
  A's held view, which the post did not carry, was written (#29223
  review, H1, H2, G8).

  While a hold of the open document is open, each top-level field the
  form holds as a list or an object is seeded from the newest stored row
  this socket has seen (`Lifecycle.base_doc/1`), as a form reads it; the
  post's own leaves still go over it, by their row's `_key`, except a
  held one that lands at another index (`moved_hold?/3`). With no hold,
  the form as before.
  """

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle
  alias BarkparkWeb.Studio.StudioLive.Path
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @doc """
  The form to seed the fold from: with a hold of this document open, its
  lists and objects as stored; with none, `form`.
  """
  def form(socket, form) do
    if held?(socket), do: stored(socket, form), else: form
  end

  @doc """
  Whether a leaf the post names at a held path (`posted`) goes to another
  row index now (`path`): another editor put a row in or took one out
  before it. The hold is read by its name, at the old index, so the leaf
  was written as posted over the other editor's text (#29223 review, H1).
  It is not written: the stored row stays, and A's words stay held.
  """
  def moved_hold?(socket, posted, path) do
    posted != path and held?(socket) and
      Enum.any?(
        Map.keys(socket.assigns[:editor_rt_held] || %{}),
        &(Path.parse_path(&1) == posted)
      )
  end

  defp held?(socket) do
    socket.assigns[:editor_rt_doc] == PostIdentity.of(socket) and
      map_size(socket.assigns[:editor_rt_held] || %{}) > 0
  end

  # The form's lists and objects as stored; every other field as the form
  # holds it.
  defp stored(socket, form) when is_map(form) do
    case Lifecycle.base_doc(socket) do
      %{} = doc ->
        stored = Content.doc_to_form(doc, socket.assigns[:editor_schema])

        Map.new(form, fn {key, value} ->
          if (is_list(value) or is_map(value)) and Map.has_key?(stored, key),
            do: {key, Map.fetch!(stored, key)},
            else: {key, value}
        end)

      _ ->
        form
    end
  end

  defp stored(_socket, form), do: form
end
