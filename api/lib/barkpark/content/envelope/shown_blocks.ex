defmodule Barkpark.Content.Envelope.ShownBlocks do
  @moduledoc """
  The copies of a document's blocks, for a caller shown only some of them.

  A write stores more than the block list: the free blocks and their HTML
  under `body`, the rendered `body_html`, each bound block's value under its
  `fieldName`, the preview card and, for a Paper, a title taken from its first
  heading. `Envelope` redacts the block list by the `blocks` field's rules for
  the caller; this module gives the copies the same view, so no copy carries
  what the blocks hide:

    * `body.blocks` is redacted by the same rules;
    * no HTML is given (`body.html` and `body_html` are absent), as HTML
      rendered from the stored blocks carries what the view hides; the
      reader page renders the view itself;
    * a bound field carries the value of its block as shown;
    * the preview card drops its description and image, and carries the
      title as shown;
    * a Paper's title is the one `Papers.ReaderTitle` gives.

  When the caller is shown every block as stored, the envelope is returned
  unchanged. Pure: no statement.
  """

  alias Barkpark.Content
  alias Barkpark.Content.Papers.ReaderTitle
  alias Barkpark.PortableDoc.Projection

  @doc """
  `shown` is the envelope after field redaction, `stored` the envelope before
  it, and `redact` redacts a block list by the `blocks` field's rules for the
  caller (`nil` when the caller may see no block).
  """
  @spec apply(map(), map(), ([map()] -> [map()] | nil)) :: map()
  def apply(shown, stored, redact) do
    case all_blocks(stored) do
      nil ->
        shown

      blocks ->
        case redact.(blocks) do
          ^blocks -> shown
          view -> hide(shown, stored, blocks, view, redact)
        end
    end
  end

  defp all_blocks(%{"blocks" => blocks}) when is_list(blocks), do: blocks
  defp all_blocks(%{"body" => %{"blocks" => blocks}}) when is_list(blocks), do: blocks
  defp all_blocks(_stored), do: nil

  defp hide(shown, stored, blocks, view, redact) do
    title = shown_title(stored, blocks, view)

    shown
    |> Map.delete("body_html")
    |> body(redact)
    |> bound_fields(blocks, view)
    |> preview(title)
    |> put_title(title)
  end

  defp body(%{"body" => %{} = body} = shown, redact) do
    body =
      case Map.get(body, "blocks") do
        blocks when is_list(blocks) -> put_or_delete(body, "blocks", redact.(blocks))
        _ -> body
      end

    Map.put(shown, "body", Map.delete(body, "html"))
  end

  defp body(shown, _redact), do: shown

  # A field the caller may not see was dropped by its own rule and stays out.
  defp bound_fields(shown, blocks, view) do
    view = view || []

    blocks
    |> Enum.with_index()
    |> Enum.reduce(shown, fn {block, i}, acc ->
      name = is_map(block) && block["fieldName"]

      if is_binary(name) and Map.has_key?(acc, name) and Enum.at(view, i) != block,
        do: put_or_delete(acc, name, view_value(Enum.at(view, i))),
        else: acc
    end)
  end

  defp view_value(block) when is_map(block), do: Projection.projected_value(block)
  defp view_value(_block), do: nil

  defp preview(%{"preview" => %{} = card} = shown, title) do
    card = Map.drop(card, ["description", "image"])
    card = if Map.has_key?(card, "title"), do: Map.put(card, "title", title), else: card
    Map.put(shown, "preview", card)
  end

  defp preview(shown, _title), do: shown

  defp put_title(%{"title" => _} = shown, title), do: Map.put(shown, "title", title)
  defp put_title(shown, _title), do: shown

  defp shown_title(%{"_type" => "paper", "title" => title} = stored, blocks, view),
    do: ReaderTitle.of(title, blocks, view, Content.published_id(stored["_id"] || ""))

  defp shown_title(stored, _blocks, _view), do: stored["title"]

  defp put_or_delete(map, key, nil), do: Map.delete(map, key)
  defp put_or_delete(map, key, value), do: Map.put(map, key, value)
end
