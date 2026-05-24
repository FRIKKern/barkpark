defmodule Barkpark.Media.SignedUrl do
  @moduledoc """
  HMAC signatures for public media embed URLs (WoodWing `appendRequestSecret` style).

  Appends `?_=sig&exp=unix` to delivery paths. Verified on `/media/files/*`
  and `/media/renditions/*` when asset visibility is `token`.
  """

  @default_ttl 60 * 60 * 24 * 7

  @doc "Append a signature query string to a relative media path."
  @spec sign(String.t(), String.t(), keyword()) :: String.t()
  def sign(path, media_file_id, opts \\ []) when is_binary(path) and is_binary(media_file_id) do
    exp = System.system_time(:second) + Keyword.get(opts, :ttl, @default_ttl)
    sig = signature(media_file_id, path, exp)

    joiner = if String.contains?(path, "?"), do: "&", else: "?"
    "#{path}#{joiner}_=#{sig}&exp=#{exp}"
  end

  @doc "Verify `_` and `exp` query params against a media file id and path."
  @spec verify?(String.t(), String.t(), map()) :: boolean()
  def verify?(media_file_id, path, params) when is_binary(media_file_id) and is_binary(path) do
    with sig when is_binary(sig) and sig != "" <- Map.get(params, "_"),
         exp when is_binary(exp) <- Map.get(params, "exp"),
         {exp_int, ""} <- Integer.parse(exp),
         true <- System.system_time(:second) < exp_int,
         expected = signature(media_file_id, path, exp_int),
         true <- Plug.Crypto.secure_compare(sig, expected) do
      true
    else
      _ -> false
    end
  end

  def verify?(_, _, _), do: false

  @doc "Parse query string params from a Plug conn."
  @spec params_from_conn(Plug.Conn.t()) :: map()
  def params_from_conn(conn) do
    conn.query_params
  end

  defp signature(media_file_id, path, exp) do
    payload = "#{media_file_id}:#{path}:#{exp}"

    :crypto.mac(:hmac, :sha256, signing_secret(), payload)
    |> Base.url_encode64(padding: false)
  end

  defp signing_secret do
    Application.get_env(:barkpark, :media_signing_secret) ||
      raise "missing config :barkpark, :media_signing_secret"
  end
end
