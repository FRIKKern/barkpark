defmodule Barkpark.Plugins.Media.ApiTests do
  @moduledoc """
  Declarative smoke specs for the Media plugin — surfaced in Studio
  `/studio/:dataset/api-tester` under the Plugins category.

  Probe ids are stable so operators can re-run specs; every mutating spec
  carries `:cleanup` that deletes the probe document or revokes share state.
  """

  @probe_collection "api-test-media-collection"
  @probe_book_id "api-test-media-probe-asset"

  @doc "All Media plugin api_test specs for `Registry.collect_api_tests/1`."
  @spec specs() :: [map()]
  def specs do
    [
      search_envelope(),
      collections_list(),
      media_schemas_registered(),
      studio_media_tab(),
      collection_mutate_round_trip(),
      share_link_invalid_token(),
      checkout_requires_auth(),
      relations_unknown_asset(),
      media_index_list(),
      processing_callback_requires_auth()
    ]
  end

  defp search_envelope do
    %{
      name: "Media search returns result envelope with facets",
      method: :get,
      path: "/v1/media/production/search?limit=5&facets=kind,visibility,processing",
      auth: :none,
      asserts: [
        {:status, 200},
        {:body_contains, ~s|"hits"|},
        {:body_contains, ~s|"facets"|},
        {:body_contains, ~s|"total"|},
        {:duration_under_ms, 3_000}
      ]
    }
  end

  defp collections_list do
    %{
      name: "Media collections list is reachable",
      method: :get,
      path: "/v1/media/production/collections?limit=20",
      auth: :none,
      asserts: [
        {:status, 200},
        {:body_contains, ~s|"collections"|}
      ]
    }
  end

  defp media_schemas_registered do
    %{
      name: "mediaAsset + mediaCollection schemas are registered",
      method: :get,
      path: "/v1/schemas/production",
      auth: :admin,
      asserts: [
        {:status, 200},
        {:body_contains, ~s|"name":"mediaAsset"|},
        {:body_contains, ~s|"name":"mediaCollection"|}
      ]
    }
  end

  defp studio_media_tab do
    %{
      name: "Studio Media tab renders bp-asset-explorer",
      method: :get,
      path: "/studio/production/media",
      auth: :none,
      asserts: [
        {:status, 200},
        {:body_contains, "bp-asset-explorer"},
        {:body_contains, "bp-ae-root"}
      ]
    }
  end

  defp collection_mutate_round_trip do
    %{
      name: "mediaCollection mutate: create + publish probe folder",
      method: :post,
      path: "/v1/data/mutate/production",
      auth: :admin,
      headers: %{"content-type" => "application/json"},
      body: %{
        "mutations" => [
          %{
            "create" => %{
              "_type" => "mediaCollection",
              "_id" => @probe_collection,
              "title" => "API Test Folder",
              "kind" => "folder",
              "slug" => @probe_collection
            }
          },
          %{"publish" => %{"id" => @probe_collection, "type" => "mediaCollection"}}
        ]
      },
      asserts: [
        {:status, 200},
        {:body_contains, @probe_collection}
      ],
      cleanup: [
        %{
          method: :post,
          path: "/v1/data/mutate/production",
          auth: :admin,
          headers: %{"content-type" => "application/json"},
          body: %{
            "mutations" => [
              %{"delete" => %{"id" => @probe_collection, "type" => "mediaCollection"}}
            ]
          }
        }
      ]
    }
  end

  defp share_link_invalid_token do
    %{
      name: "Public share token returns 404 for unknown token",
      method: :get,
      path: "/v1/media/production/share/not-a-real-share-token",
      auth: :none,
      asserts: [{:status, 404}]
    }
  end

  defp checkout_requires_auth do
    %{
      name: "Media checkout requires Bearer token",
      method: :post,
      path: "/v1/media/production/#{@probe_book_id}/checkout",
      auth: :none,
      asserts: [{:status, 401}]
    }
  end

  defp relations_unknown_asset do
    %{
      name: "Media relations returns 404 for unknown blob id",
      method: :get,
      path: "/v1/media/production/00000000-0000-0000-0000-000000000099/relations",
      auth: :none,
      asserts: [{:status, 404}]
    }
  end

  defp media_index_list do
    %{
      name: "Media index lists assets envelope",
      method: :get,
      path: "/v1/media/production?limit=5",
      auth: :none,
      asserts: [
        {:status, 200},
        {:body_contains, ~s|"assets"|}
      ]
    }
  end

  defp processing_callback_requires_auth do
    %{
      name: "Processing callback rejects missing Bearer token",
      method: :post,
      path: "/v1/media/production/processing/#{@probe_book_id}/callback",
      auth: :none,
      headers: %{"content-type" => "application/json"},
      body: %{"status" => "ready"},
      asserts: [{:status, 401}]
    }
  end
end
