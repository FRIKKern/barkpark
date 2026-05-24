defmodule Barkpark.Media.Checkout do
  @moduledoc "Editorial checkout lock on `mediaAsset` documents."

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media.MediaFile

  @asset_type "mediaAsset"

  @doc "Check out an asset for editing. Returns updated document."
  @spec checkout(%MediaFile{}, String.t(), String.t()) :: {:ok, Document.t()} | {:error, term()}
  def checkout(%MediaFile{} = file, actor, dataset) when is_binary(actor) do
    with %Document{} = doc <- fetch_doc(file, dataset),
         :ok <- ensure_available(doc, actor) do
      patch_checkout(doc, file, dataset, actor, DateTime.utc_now() |> DateTime.to_iso8601())
    end
  end

  @doc "Release checkout lock. Admin or lock holder only."
  @spec undo_checkout(%MediaFile{}, String.t(), String.t(), boolean()) ::
          {:ok, Document.t()} | {:error, term()}
  def undo_checkout(%MediaFile{} = file, actor, dataset, admin?) do
    with %Document{} = doc <- fetch_doc(file, dataset),
         :ok <- ensure_can_release(doc, actor, admin?) do
      patch_checkout(doc, file, dataset, nil, nil)
    end
  end

  defp fetch_doc(%MediaFile{} = file, dataset) do
    case Barkpark.Plugins.Media.Assets.find_by_media_file_id(file.id, dataset) do
      %Document{} = doc -> doc
      nil -> {:error, :not_found}
    end
  end

  defp ensure_available(%Document{content: content}, actor) do
    holder = Map.get(content || %{}, "checkedOutBy")

    cond do
      holder in [nil, ""] -> :ok
      holder == actor -> :ok
      true -> {:error, :checked_out}
    end
  end

  defp ensure_can_release(%Document{content: content}, actor, admin?) do
    holder = Map.get(content || %{}, "checkedOutBy")

    cond do
      holder in [nil, ""] -> :ok
      admin? -> :ok
      holder == actor -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp patch_checkout(doc, file, dataset, actor, at) do
    content =
      (doc.content || %{})
      |> Map.put("checkedOutBy", actor)
      |> Map.put("checkedOutAt", at)

    attrs = %{
      "doc_id" => doc.doc_id,
      "title" => doc.title,
      "status" => doc.status,
      "content" => content
    }

    case Content.upsert_document(@asset_type, attrs, dataset, source: :api) do
      {:ok, updated} ->
        if actor == nil, do: Barkpark.Media.Renditions.delete_for_file(file.id)
        {:ok, updated}

      error ->
        error
    end
  end
end
