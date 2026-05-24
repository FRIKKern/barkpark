defmodule Barkpark.Media.Share do
  @moduledoc """
  Public share links for media collections (WoodWing-style gallery URLs).
  """

  import Ecto.Query
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media.Collections
  alias Barkpark.Repo

  @collection_type "mediaCollection"
  @default_ttl 60 * 60 * 24 * 7

  @doc "Enable or rotate a collection share link."
  @spec create(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(collection_id, dataset, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    expires_at = DateTime.utc_now() |> DateTime.add(ttl, :second) |> DateTime.to_iso8601()
    token = generate_token()

    with {:ok, doc} <- Collections.get(collection_id, dataset) do
      content = doc.content || %{}

      share_link = %{
        "enabled" => true,
        "token" => token,
        "expiresAt" => expires_at
      }

      attrs = %{
        "doc_id" => doc.doc_id,
        "title" => doc.title,
        "status" => doc.status,
        "content" => Map.put(content, "shareLink", share_link)
      }

      case Content.upsert_document(@collection_type, attrs, dataset, source: :api) do
        {:ok, _updated} ->
          {:ok,
           %{
             token: token,
             shareUrl: share_path(dataset, token),
             expiresAt: expires_at
           }}

        error ->
          error
      end
    end
  end

  @doc "Disable a collection share link."
  @spec revoke(String.t(), String.t()) :: {:ok, Document.t()} | {:error, term()}
  def revoke(collection_id, dataset) do
    with {:ok, doc} <- Collections.get(collection_id, dataset) do
      content = doc.content || %{}
      share_link = Map.get(content, "shareLink", %{})

      attrs = %{
        "doc_id" => doc.doc_id,
        "title" => doc.title,
        "status" => doc.status,
        "content" =>
          Map.put(content, "shareLink", Map.merge(share_link, %{"enabled" => false}))
      }

      Content.upsert_document(@collection_type, attrs, dataset, source: :api)
    end
  end

  @doc "Resolve a share token to a collection document."
  @spec resolve(String.t(), String.t()) :: {:ok, Document.t()} | {:error, term()}
  def resolve(token, dataset) when is_binary(token) and is_binary(dataset) do
    doc =
      Document
      |> where([d], d.type == ^@collection_type and d.dataset == ^dataset)
      |> where([d], fragment("?->'shareLink'->>'token' = ?", d.content, ^token))
      |> Repo.one()

    cond do
      is_nil(doc) ->
        {:error, :not_found}

      not share_active?(doc) ->
        {:error, :expired}

      true ->
        {:ok, doc}
    end
  end

  @doc "Public share URL path (relative)."
  @spec share_path(String.t(), String.t()) :: String.t()
  def share_path(dataset, token) do
    "/v1/media/#{dataset}/share/#{token}"
  end

  defp share_active?(%Document{content: content}) when is_map(content) do
    link = Map.get(content, "shareLink", %{})

    with true <- Map.get(link, "enabled") in [true, "true"],
         exp when is_binary(exp) <- Map.get(link, "expiresAt"),
         {:ok, expires_at, _} <- DateTime.from_iso8601(exp) do
      DateTime.compare(DateTime.utc_now(), expires_at) == :lt
    else
      _ -> false
    end
  end

  defp share_active?(_), do: false

  defp generate_token do
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  end
end
