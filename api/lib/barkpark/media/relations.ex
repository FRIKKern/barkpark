defmodule Barkpark.Media.Relations do
  @moduledoc """
  Asset relation graph — outbound refs on the asset doc plus inbound back-links.
  """

  import Ecto.Query
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Delivery.AssetResponse
  alias Barkpark.Media.MediaFile
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo

  @asset_type "mediaAsset"

  @doc """
  Relation graph for a blob id.

  `opts` carries the render keys (`:conn`, `:sign_urls`, `:dataset`) AND the
  tenancy scope (`:workspace_id` / `:project_id`). The scope is what closes the
  cross-workspace relations leak (barkpark-m21z): every back-link query and
  every related-asset/file resolution is bounded to the caller's tenant, so the
  graph resolved to workspace B never surfaces workspace A's related asset docs,
  titles, or signed URLs even when both share the `dataset` STRING. Scope keys
  are threaded into the reads but stripped from the render opts so AssetResponse
  is unaffected. NULL-tolerant — legacy NULL-workspace asset docs still resolve
  in their own tenant's graph (never-worse).
  """
  @spec graph(struct(), String.t(), keyword()) :: map()
  def graph(%MediaFile{} = file, dataset, opts \\ []) do
    scope_opts = Keyword.take(opts, [:workspace_id, :project_id])
    render_opts = Keyword.take(opts, [:conn, :sign_urls, :dataset])
    doc = Media.asset_doc_for_file(file, dataset, scope_opts)

    %{
      outbound: outbound(doc, dataset, render_opts, scope_opts),
      inbound: inbound(doc, dataset, render_opts, scope_opts)
    }
  end

  defp outbound(nil, _dataset, _render_opts, _scope_opts), do: []

  defp outbound(%Document{content: content}, dataset, render_opts, scope_opts) do
    content
    |> Map.get("relatedAssets", [])
    |> List.wrap()
    |> Enum.map(&normalize_edge/1)
    |> Enum.reject(&is_nil(&1.target))
    |> Enum.map(fn edge ->
      case resolve_target(edge.target, dataset, scope_opts) do
        {file, target_doc} ->
          %{
            relation: edge.relation,
            assetDocId: edge.target,
            asset:
              AssetResponse.render(file, target_doc, Keyword.put(render_opts, :dataset, dataset))
          }

        nil ->
          %{relation: edge.relation, assetDocId: edge.target, asset: nil}
      end
    end)
  end

  defp inbound(nil, _dataset, _render_opts, _scope_opts), do: []

  defp inbound(%Document{doc_id: doc_id}, dataset, render_opts, scope_opts) do
    workspace_id = Keyword.get(scope_opts, :workspace_id)
    project_id = Keyword.get(scope_opts, :project_id)

    Document
    |> where([d], d.type == ^@asset_type)
    # Mirror the asset-doc read envelope exactly (NULL-tolerant dataset_id +
    # workspace) so a back-link query resolved to workspace B never picks up
    # workspace A's source asset doc that targets this blob's doc, even though
    # both share the `dataset` STRING (barkpark-m21z). The bare
    # `d.dataset == ^dataset` filter had no workspace/dataset_id envelope, so
    # any tenant sharing the dataset string leaked into the inbound list.
    |> Assets.scope_asset_dataset(dataset, scope_opts)
    |> Assets.scope_asset_workspace(workspace_id, project_id)
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
        file = file_for_doc(source_doc, dataset, scope_opts)

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

  defp resolve_target(asset_doc_id, dataset, scope_opts) do
    case Content.get_document(asset_doc_id, @asset_type, dataset, scope_opts) do
      {:ok, doc} ->
        case file_for_doc(doc, dataset, scope_opts) do
          nil -> nil
          file -> {file, doc}
        end

      _ ->
        nil
    end
  end

  defp file_for_doc(%Document{content: content}, dataset, scope_opts) do
    case Map.get(content || %{}, "mediaFileId") do
      id when is_binary(id) ->
        case Media.get_file(id, scope_opts) do
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
