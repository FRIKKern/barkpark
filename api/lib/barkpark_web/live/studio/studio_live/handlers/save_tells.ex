defmodule BarkparkWeb.Studio.StudioLive.Handlers.SaveTells do
  @moduledoc """
  After an explicit Save, the page is told of every value that landed
  during it (task-ac7531b991f6bae1).

  The Save reloads the editor from the row it wrote. A save of another
  editor's that landed under it is in that row, so the socket took it in,
  but the page was never sent it: a LiveView patch leaves the focused input
  and every rich text editor as they are. A's form kept the old text, and
  A's next Save wrote it over B's words with no banner (#28832 review, S1).

  So each field the reload changed from what the page showed is pushed to
  it, as another editor's save is (`RemoteValues.push/3`,
  `RichTextRemote.push/3`), and logged, so a post from a page that never
  drew it is read as any other. A field the Save holds or merged is left
  out: its act tells the page (`TextUnderLock.hold/3`,
  `RichTextRemote.hold/2`), and B's value must not be drawn over A's words.
  """

  alias Barkpark.Content.PortableText
  alias Barkpark.Content.PortableTextMerge
  alias BarkparkWeb.Studio.StudioLive.Handlers.RemoteValues
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote
  alias BarkparkWeb.Studio.StudioLive.Handlers.RichTextRemote.FormPath

  @doc """
  `saved` after the reload; `before` the form before the Save; `posted` the
  Save's doc (its free-text values are what the page showed); `acts` the
  rich text acts and `text_held` the held text fields, left out.
  """
  def tell(saved, false, _forms, _left_out), do: saved

  def tell(saved, true, {before, posted}, {acts, text_held}) when is_map(before) do
    schema = saved.assigns[:editor_schema]

    shown =
      schema
      |> RemoteValues.text_units(posted)
      |> Enum.reduce(before, fn key, form ->
        put(form, key, RemoteValues.value_at(posted, key))
      end)

    shown = drawn(schema, shown, saved.assigns[:editor_form] || %{}, posted)

    now =
      Enum.reduce(left_out(acts, text_held), saved.assigns[:editor_form] || %{}, fn path, form ->
        FormPath.put(form, path, FormPath.get(shown, path))
      end)

    saved
    |> RemoteValues.push(shown, now)
    |> RichTextRemote.push(shown, now)
  end

  def tell(saved, _told?, _forms, _left_out), do: saved

  # A rich text the Save posted as the reload holds it is what the page
  # shows: A's own text, not another editor's to draw.
  defp drawn(schema, shown, now, posted) do
    Enum.reduce(RichTextRemote.changes(schema, shown, now), shown, fn {path, _was, value}, form ->
      html = FormPath.get(posted, path)

      if is_binary(html) and
           PortableTextMerge.same_drawn?(PortableText.from_html(html, list(value)), list(value)),
         do: FormPath.put(form, path, value),
         else: form
    end)
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  # A held, still-held or merged rich text (`RichTextRemote` acts), and each
  # held text field.
  defp left_out(acts, text_held) do
    rich = for act <- acts, path = act_path(act), do: path
    rich ++ Enum.map(text_held, &List.wrap/1)
  end

  defp act_path({:held, _name, path, _hold}), do: path
  defp act_path({:merged, _name, path, _mine}), do: path
  defp act_path({:still, _name, path}), do: path
  defp act_path(_act), do: nil

  defp put(form, key, value) when is_binary(value), do: RemoteValues.put_at(form, key, value)
  defp put(form, _key, _value), do: form
end
