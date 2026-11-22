defmodule BarkparkWeb.Studio.StudioLive.Handlers.UnsavedBases do
  @moduledoc """
  The stored value an unsaved free-text field's words were typed on: the
  base a remote save over that field is merged against
  (`Handlers.Lifecycle.doc_updated/2`, task-65543203e7b71c80).

  A post that did not land leaves its text in the form
  (`Fields.keep_unsaved_values`). That text was typed on the value the page
  reported in `_bp_seen` (`RemoteValues.put_bases/3`), which can be older
  than the newest stored version. A typed through B's first save, so its
  text has none of B's words; B saves again, and against the newest version
  (which holds B's first words) the merge read A's text as deleting them,
  with no banner (#28176 review, round 2). TanStack rebases its local value
  onto theirs on every frame, so its base always matches its text
  (barkpark-studio edit-bases.ts). Here each field keeps `{base, text}`:
  the base holds only while the form still shows that text.

  A field with no known base (a post with no number, a page running an
  older copy of bp-array-focus.js, a value the server built) is a conflict
  wherever both changed: a banner that was not needed, never words lost
  without one.
  """

  import Phoenix.Component, only: [assign: 3]

  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues
  alias BarkparkWeb.Studio.StudioLive.RefusedSave

  @held ["Save failed", "Save cancelled"]

  @doc """
  After a post of `keys` (`saved`, from `before`): each free-text field the
  form keeps unsaved gets the base its text was typed on, from the bases
  the post was merged from (`field_bases`) or, for a field the page never
  had a number for, the value the form held before it. Any other posted
  field loses its base.
  """
  def record(saved, before, keys, field_bases, seen) do
    schema = saved.assigns[:editor_schema]
    form = saved.assigns[:editor_form] || %{}

    kept =
      if saved.assigns[:save_status] in @held, do: keys -- RefusedSave.clears(saved), else: []

    bases =
      Enum.reduce(keys, all(saved), fn key, acc ->
        with true <- key in kept and RemoteValues.free_text?(schema, key),
             {:ok, base} <- typed_on(before, key, field_bases, seen) do
          Map.put(acc, key, {base, Map.get(form, key)})
        else
          _ -> Map.delete(acc, key)
        end
      end)

    assign(saved, :editor_unsaved_bases, bases)
  end

  @doc """
  `{:ok, base}` when the form's value of `key` is the text a base was kept
  for, else `:error`.
  """
  def fetch(socket, key) do
    value = Map.get(socket.assigns[:editor_form] || %{}, key)

    case Map.fetch(all(socket), key) do
      {:ok, {base, ^value}} -> {:ok, base}
      _ -> :error
    end
  end

  @doc "Keeps `base` for `value`, the text `key` now holds."
  def put(bases, key, base, value), do: Map.put(bases, key, {base, value})

  @doc "Every kept `{base, text}`, by field."
  def all(socket), do: socket.assigns[:editor_unsaved_bases] || %{}

  # A base the post was merged from. With none and no number for the field
  # in the page's numbered `_bp_seen`, the page showed the value the form
  # held: the drawn one, or the text already kept with its own base.
  defp typed_on(before, key, field_bases, seen) do
    case Map.fetch(field_bases, key) do
      {:ok, base} when is_binary(base) or is_nil(base) ->
        {:ok, base}

      {:ok, _whole} ->
        :error

      :error ->
        cond do
          not RemoteValues.unnumbered?(before, key, seen) ->
            :error

          MapSet.member?(before.assigns[:editor_unsaved_keys] || MapSet.new(), key) ->
            fetch(before, key)

          true ->
            {:ok, Map.get(before.assigns[:editor_form] || %{}, key)}
        end
    end
  end
end
