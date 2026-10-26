defmodule Barkpark.Groq.SyncTag do
  @moduledoc """
  Opaque sync tags for the live content events stream (task-d6566cbed9b7c33c).

  A GROQ response's readable tags (`bp:ds:<dataset>:type:<type>`,
  `bp:ds:<dataset>:doc:<id>`, `bp:ds:<dataset>:_all`) name document ids and type
  names. The live events stream must not, as Sanity's opaque `s1:…` tags do
  not, so it sends each tag's opaque twin: `"s1:"` plus 11 url-safe base64
  characters of an HMAC-SHA256 over the project and the readable tag. GROQ
  responses carry both halves, so a site keeps revalidating webhook tags as
  before while `next-sanity` matches stream tags against the twins.

  The key derives from the endpoint's `secret_key_base`, so a twin is stable
  across deploys and restarts. The project is part of the input, so two
  projects' same-named datasets never share a tag.
  """

  @doc "The opaque twin of a readable tag in `project` (nil for a flat route)."
  @spec opaque(String.t() | nil, String.t()) :: String.t()
  def opaque(project, tag) when is_binary(tag) do
    mac = :crypto.mac(:hmac, :sha256, key(), (project || "") <> "|" <> tag)
    "s1:" <> (mac |> binary_part(0, 8) |> Base.url_encode64(padding: false))
  end

  @doc """
  The readable tag every untyped scan of `dataset` carries: the canonical
  `_all` tag of docs/contracts/webhook-realtime.md, which a webhook handler
  already revalidates on every mutation of the dataset.
  """
  @spec all(String.t()) :: String.t()
  def all(dataset), do: "bp:ds:#{dataset}:_all"

  defp key do
    case :persistent_term.get({__MODULE__, :key}, nil) do
      nil ->
        base =
          :barkpark
          |> Application.get_env(BarkparkWeb.Endpoint, [])
          |> Keyword.get(:secret_key_base, "")

        key = :crypto.mac(:hmac, :sha256, base, "barkpark live sync tags v1")
        :persistent_term.put({__MODULE__, :key}, key)
        key

      key ->
        key
    end
  end
end
