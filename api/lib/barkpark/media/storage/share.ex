defmodule Barkpark.Media.Storage.Share do
  @moduledoc """
  Public share links for media collections (WoodWing-style gallery URLs).
  """

  import Ecto.Query
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.Collections
  alias Barkpark.Repo

  @collection_type "mediaCollection"
  @default_ttl 60 * 60 * 24 * 7

  @doc """
  Enable or rotate a collection share link.

  `opts` carries the caller's tenancy scope (`[workspace_id: ..., project_id:
  ...]`) plus `:ttl`. The scope is threaded into `Collections.get/3` so the
  collection is resolved within the caller's workspace — without it a
  workspace-B writer could mint/rotate the share token on workspace-A's
  collection sharing the same dataset string + collection id (barkpark-ukzs).
  """
  @spec create(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(collection_id, dataset, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    expires_at = DateTime.utc_now() |> DateTime.add(ttl, :second) |> DateTime.to_iso8601()
    token = generate_token()

    with {:ok, doc} <- Collections.get(collection_id, dataset, opts) do
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

      case Content.upsert_document(@collection_type, attrs, dataset, write_opts(opts)) do
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

  @doc """
  Disable a collection share link.

  `opts` carries the caller's tenancy scope (`[workspace_id: ..., project_id:
  ...]`), threaded into `Collections.get/3` so the collection is resolved
  within the caller's workspace (barkpark-ukzs).
  """
  @spec revoke(String.t(), String.t(), keyword()) :: {:ok, Document.t()} | {:error, term()}
  def revoke(collection_id, dataset, opts \\ []) do
    with {:ok, doc} <- Collections.get(collection_id, dataset, opts) do
      content = doc.content || %{}
      share_link = Map.get(content, "shareLink", %{})

      attrs = %{
        "doc_id" => doc.doc_id,
        "title" => doc.title,
        "status" => doc.status,
        "content" => Map.put(content, "shareLink", Map.merge(share_link, %{"enabled" => false}))
      }

      Content.upsert_document(@collection_type, attrs, dataset, write_opts(opts))
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

  # Carry the caller's tenancy scope into the follow-on `upsert_document` write
  # so the share-link mutation lands on the SAME row the scoped
  # `Collections.get/3` read resolved — never a Default-scoped duplicate
  # (barkpark-ukzs). Without the scope keys the write would resolve to the
  # seeded Default workspace and either overwrite the wrong tenant's row or
  # insert a fresh one, leaving the resolved collection's shareLink untouched.
  # `:ttl` (create's own opt) is dropped — only the tenancy keys + `source`
  # belong on the write.
  defp write_opts(opts) do
    opts
    |> Keyword.take([:workspace_id, :project_id])
    |> Keyword.put(:source, :api)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  end
end
