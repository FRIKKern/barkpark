defmodule Barkpark.Media.Relations do
  @moduledoc """
  Asset relation graph — outbound refs on the asset doc plus inbound back-links.
  """

  import Ecto.Query
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.{AssetResponse, MediaFile}
  alias Barkpark.Repo

  @asset_type "mediaAsset"

  @doc "Relation graph for a blob id."
  @spec graph(struct(), String.t(), keyword()) :: map()
  def graph(%MediaFile{} = file, dataset, opts \\ []) do
    doc = Media.asset_doc_for_file(file, dataset)
    render_opts = Keyword.take(opts, [:conn, :sign_urls, :dataset])

    %{
      outbound: outbound(doc, dataset, render_opts),
      inbound: inbound(doc, dataset, render_opts)
    }
  end

  defp outbound(nil, _dataset, _opts), do: []

  defp outbound(%Document{content: content}, dataset, render_opts) do
    content
    |> Map.get("relatedAssets", [])
    |> List.wrap()
    |> Enum.map(&normalize_edge/1)
    |> Enum.reject(&is_nil(&1.target))
    |> Enum.map(fn edge ->
      case resolve_target(edge.target, dataset) do
        {file, target_doc} ->
          %{
            relation: edge.relation,
            assetDocId: edge.target,
            asset: AssetResponse.render(file, target_doc, Keyword.put(render_opts, :dataset, dataset))
          }

        nil ->
          %{relation: edge.relation, assetDocId: edge.target, asset: nil}
      end
    end)
  end

  defp inbound(nil, _dataset, _opts), do: []

  defp inbound(%Document{doc_id: doc_id}, dataset, render_opts) do
    Document
    |> where([d], d.type == ^@asset_type and d.dataset == ^dataset)
    |> where(
      [d],
      fragment(
        "EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(?->'relatedAssets', '[]'::jsonb)) elem WHERE elem->>'target' = ?)",
        d.content,
        ^doc_id
      )
    )
    |> Repo.all()
    |> Enum.flat_map(fn source_doc ->
      source_doc.content
      |> Map.get("relatedAssets", [])
      |> List.wrap()
      |> Enum.filter(fn edge ->
        normalize_edge(edge).target == doc_id
      end)
      |> Enum.map(fn edge ->
        file = file_for_doc(source_doc, dataset)

        %{
          relation: normalize_edge(edge).relation,
          assetDocId: source_doc.doc_id,
          asset:
            if file do
              AssetResponse.render(file, source_doc, Keyword.put(render_opts, :dataset, dataset))
            end
        }
      end)
    end)
  end

  defp resolve_target(asset_doc_id, dataset) do
    case Content.get_document(asset_doc_id, @asset_type, dataset) do
      {:ok, doc} ->
        case file_for_doc(doc, dataset) do
          nil -> nil
          file -> {file, doc}
        end

      _ ->
        nil
    end
  end

  defp file_for_doc(%Document{content: content}, dataset) do
    case Map.get(content || %{}, "mediaFileId") do
      id when is_binary(id) ->
        case Media.get_file(id) do
          {:ok, file} when file.dataset == dataset -> file
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp normalize_edge(edge) when is_map(edge) do
    target =
      case Map.get(edge, "target") do
        %{"_ref" => ref} -> ref
        ref when is_binary(ref) -> ref
        _ -> nil
      end

    relation =
      case Map.get(edge, "relation") do
        %{"code" => code} -> code
        code when is_binary(code) -> code
        _ -> "related"
      end

    %{relation: relation, target: target}
  end

  defp normalize_edge(_), do: %{relation: "related", target: nil}
end
