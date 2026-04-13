defmodule Barkpark.Content.Envelope do
  @moduledoc """
  Canonical v1 document envelope. Flat map with reserved `_`-prefixed keys.

  Reserved keys: _id, _type, _rev, _draft, _publishedId, _createdAt, _updatedAt.
  All other keys come from the document's stored content plus `title`.
  User content cannot override reserved keys.
  """

  alias Barkpark.Content

  @reserved ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt)

  def render(doc) do
    user_fields =
      (doc.content || %{})
      |> Map.drop(@reserved)
      |> Map.put("title", doc.title)

    Map.merge(user_fields, %{
      "_id" => doc.doc_id,
      "_type" => doc.type,
      "_rev" => doc.rev,
      "_draft" => Content.draft?(doc.doc_id),
      "_publishedId" => Content.published_id(doc.doc_id),
      "_createdAt" => to_iso8601(doc.inserted_at),
      "_updatedAt" => to_iso8601(doc.updated_at)
    })
  end

  def render_many(docs), do: Enum.map(docs, &render/1)

  defp to_iso8601(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
    |> String.replace_suffix("+00:00", "Z")
  end

  defp to_iso8601(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_iso8601()
    |> String.replace_suffix("+00:00", "Z")
  end

  defp to_iso8601(nil), do: nil
end
