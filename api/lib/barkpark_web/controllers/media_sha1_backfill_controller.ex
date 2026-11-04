defmodule BarkparkWeb.MediaSha1BackfillController do
  @moduledoc """
  `POST /v1/admin/media/sha1-backfill`. Hashes the media files born before
  `media_files.sha1`, so a box nobody has a shell on can run the backfill that
  `bin/barkpark eval 'Barkpark.Release.backfill_media_sha1()'` runs. Barkpark
  Cloud calls it with the admin token it holds, for
  `bp barkparks backfill-media-sha1`. `Barkpark.Media.Sha1Backfill` owns the
  walk.

  Pipeline `[:api, :require_admin, :require_platform_operator]`, the
  instance-operator tier of `/v1/admin/*`.

  Body: `{"apply": bool, "after": id, "limit": n}`. All are optional. Without
  `"apply": true` nothing is written and the box answers
  `{"applied": false, "unhashed": n, "datasets": [{"workspace", "dataset",
  "unhashed"}]}`. With it the box hashes one page and answers
  `{"applied": true, "hashed": n, "failed": [{"id", "workspace", "dataset",
  "reason"}], "next_after": id | null, "unhashed": n}`. The caller sends
  `next_after` back as `after` until it is null.

  Refusal: 422 `unprocessable` for a bad body.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Media.Sha1Backfill
  alias BarkparkWeb.ErrorResponse

  def create(conn, params) do
    with {:ok, apply?} <- fetch_apply(params),
         {:ok, after_id} <- fetch_after(params),
         {:ok, limit} <- fetch_limit(params) do
      if apply? do
        page = Sha1Backfill.run(after: after_id, limit: limit)
        json(conn, Map.put(page, :applied, true))
      else
        json(conn, Map.put(Sha1Backfill.plan(), :applied, false))
      end
    else
      {:error, message} ->
        ErrorResponse.emit_fields(conn, :unprocessable_entity, %{
          code: "unprocessable",
          message: message
        })
    end
  end

  defp fetch_apply(%{"apply" => value}) when is_boolean(value), do: {:ok, value}
  defp fetch_apply(%{"apply" => nil}), do: {:ok, false}
  defp fetch_apply(%{"apply" => _}), do: {:error, "apply must be true or false"}
  defp fetch_apply(_), do: {:ok, false}

  defp fetch_after(%{"after" => nil}), do: {:ok, nil}

  defp fetch_after(%{"after" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "after must be a media file id"}
    end
  end

  defp fetch_after(%{"after" => _}), do: {:error, "after must be a media file id"}
  defp fetch_after(_), do: {:ok, nil}

  defp fetch_limit(%{"limit" => nil}), do: {:ok, nil}

  defp fetch_limit(%{"limit" => n}) when is_integer(n) and n >= 1 do
    if n <= Sha1Backfill.max_limit(),
      do: {:ok, n},
      else: {:error, "limit must be between 1 and #{Sha1Backfill.max_limit()}"}
  end

  defp fetch_limit(%{"limit" => _}),
    do: {:error, "limit must be between 1 and #{Sha1Backfill.max_limit()}"}

  defp fetch_limit(_), do: {:ok, nil}
end
