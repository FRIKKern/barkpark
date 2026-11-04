defmodule BarkparkCloud.Registry.MediaSha1Backfill do
  @moduledoc """
  Run the media SHA-1 backfill on a box nobody has a shell on
  (`POST /v1/operator/barkparks/:id/media-sha1-backfill`,
  `bp barkparks backfill-media-sha1`). Operator only.

  Media files born before `media_files.sha1` have no hash, so upload dedupe,
  `GET /v1/media/:ds?sha1=` and `bp export --media` cannot match them by
  bytes. The box hashes them with `bin/barkpark eval
  'Barkpark.Release.backfill_media_sha1()'`, which needs a shell. This module
  asks the box instead, with the admin token Cloud holds:

      POST <url>/v1/admin/media/sha1-backfill {"apply": bool, "after": id, "limit": n}

  Without `apply` the box writes nothing and answers its count of files with
  no hash. With `apply` it hashes one page, small enough to answer inside the
  HTTP client's timeout, and answers the cursor for the next page. The caller
  pages; Cloud forwards one page per request. The box writes only
  `media_files.sha1`, computed from bytes it already stores.

  Transport is the `:studio_link_http_client` seam every instance call uses.
  The reply names media file ids, workspace slugs, dataset names and counts,
  never a secret.
  """

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Barkpark

  @route "POST /v1/admin/media/sha1-backfill"

  @typedoc "Why a request stopped. Nothing was written on the box for any of these."
  @type refusal ::
          :not_live
          | :no_admin_token
          | :decrypt_failed
          | :unreachable
          | {:held_token_refused, non_neg_integer()}
          | {:box_too_old, String.t()}
          | {:backfill_refused, non_neg_integer(), String.t() | nil}

  @doc """
  Ask the box for a dry run (`apply?` false) or one applied page. `after_id`
  is the cursor from the previous page or `nil`; `limit` is `nil` for the
  box's default. Returns `{:ok, reply}` with the box's reply verbatim.
  """
  @spec run(Barkpark.t(), boolean(), String.t() | nil, pos_integer() | nil) ::
          {:ok, map()} | {:error, refusal()}
  def run(%Barkpark{} = bp, apply?, after_id, limit) when is_boolean(apply?) do
    with {:ok, base} <- base_url(bp),
         {:ok, held} <- held_token(bp) do
      body =
        %{apply: apply?}
        |> put_present(:after, after_id)
        |> put_present(:limit, limit)

      case request(base, "/v1/admin/media/sha1-backfill", held, body) do
        {:ok, 200, %{"applied" => applied} = reply} when is_boolean(applied) ->
          {:ok, reply}

        {:ok, 404, _} ->
          {:error, {:box_too_old, @route}}

        {:ok, status, _} when status in [401, 403] ->
          {:error, {:held_token_refused, status}}

        {:ok, status, body} ->
          {:error, {:backfill_refused, status, reason(body)}}

        {:error, :unreachable} ->
          {:error, :unreachable}
      end
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp base_url(%Barkpark{url: url}) when is_binary(url) and url != "",
    do: {:ok, String.trim_trailing(url, "/")}

  defp base_url(_), do: {:error, :not_live}

  defp held_token(bp) do
    case Registry.reveal_admin_token(bp) do
      {:ok, nil} -> {:error, :no_admin_token}
      {:ok, token} -> {:ok, token}
      :error -> {:error, :decrypt_failed}
    end
  end

  # The box's envelope is `{"error": {"code", "reason", "message"}}`.
  defp reason(%{"error" => %{} = err}), do: err["reason"] || err["message"] || err["code"]
  defp reason(_), do: nil

  defp request(base, path, bearer, body) do
    req = %{
      method: :post,
      url: base <> path,
      headers: [
        {"Authorization", "Bearer " <> bearer},
        {"Accept", "application/json"},
        {"Content-Type", "application/json"}
      ],
      body: Jason.encode!(body)
    }

    case http_client().request(req) do
      {:ok, %{status: status, body: resp}} when is_integer(status) ->
        case Jason.decode(resp || "") do
          {:ok, %{} = decoded} -> {:ok, status, decoded}
          _ -> {:ok, status, %{}}
        end

      _ ->
        {:error, :unreachable}
    end
  end

  defp http_client do
    Application.get_env(
      :barkpark_cloud,
      :studio_link_http_client,
      BarkparkCloud.Billing.HttpClient
    )
  end
end
