defmodule BarkparkWeb.Studio.StudioLive.WidgetValues do
  @moduledoc """
  [server-replaced-widget-values] task-c7b0565a482b9d21. Rich text,
  reference and image inputs render inside `phx-update="ignore"` wrappers
  that LiveView never re-renders, so when the SERVER replaces one of their
  values in the open document's form (another tab's save, Reload after a
  conflict, a revision restore) the widget kept the old value, and this
  tab's next autosave wrote it back over the other edit. `editor_form_gen`
  is part of those wrapper ids (`FieldInputs.doc_wrap_id/4`): moving it
  remounts them with the new value. It moves ONLY when a widget-owned value
  actually changed, so a reload that leaves them alone (and the tab's own
  autosave, which never comes through here) keeps the caret where it is.

  Rich text inside an object is such a widget too (task-47be2cdf59d0acd5):
  its editor kept the old text, and the next typing in it posted that text
  over the other editor's. It is read by what it draws: this tab's own post
  rebuilds its blocks with new keys (`Forms.coerce_params/2`), and a save of
  another subfield must not remount it under the caret.
  """

  alias Barkpark.Content.PortableText

  @widget_field_types ~w(richText reference image)

  @doc "Whether a widget-drawn value differs between the two forms."
  def changed?(schema, old_form, new_form) do
    {old_form, new_form} = {old_form || %{}, new_form || %{}}
    fields = fields(schema)
    names = for %{"type" => t, "name" => n} <- fields, t in @widget_field_types, do: n

    Map.take(old_form, names) != Map.take(new_form, names) or
      Enum.any?(fields, &object_changed?(&1, old_form, new_form))
  end

  defp object_changed?(%{"type" => "composite", "name" => name, "fields" => subs}, old, new)
       when is_list(subs),
       do: drawn(subs, Map.get(old, name)) != drawn(subs, Map.get(new, name))

  defp object_changed?(_field, _old, _new), do: false

  # The rich text an object draws in its editors, by path, as HTML.
  defp drawn(subs, %{} = value) when not is_struct(value) do
    for %{"name" => sub} = field <- subs, is_map(field), into: %{} do
      case {field["type"], Map.get(value, sub), field["fields"]} do
        {"richText", v, _} -> {sub, html(v)}
        {"composite", %{} = inner, [_ | _] = inner_subs} -> {sub, drawn(inner_subs, inner)}
        _ -> {sub, nil}
      end
    end
  end

  defp drawn(_subs, _value), do: nil

  defp html(value) do
    if PortableText.value?(value), do: PortableText.to_html(value), else: value
  end

  defp fields(%{fields: fields}) when is_list(fields), do: fields
  defp fields(_schema), do: []
end
