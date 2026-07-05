defmodule Barkpark.Sso.Social.HTTP do
  @moduledoc """
  The two social-login outbound calls — the token-endpoint POST and the
  userinfo GET (Bearer) — behind a swappable behaviour so tests stand in a mock
  provider (config `:social_http`). Default is a `Req`-backed client.
  """
  @callback post_form(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback get_bearer(String.t(), String.t()) :: {:ok, map()} | {:error, term()}

  def impl, do: Application.get_env(:barkpark, :social_http, __MODULE__.ReqClient)
  def post_form(url, params), do: impl().post_form(url, params)
  def get_bearer(url, token), do: impl().get_bearer(url, token)

  defmodule ReqClient do
    @moduledoc false
    @behaviour Barkpark.Sso.Social.HTTP

    @impl true
    def post_form(url, params) do
      # Accept: json so GitHub returns JSON (not form-encoded) for the token.
      case Req.post(url, form: params, headers: [{"accept", "application/json"}]) do
        {:ok, %{status: s, body: b}} when s in 200..299 and is_map(b) -> {:ok, b}
        {:ok, %{status: s}} -> {:error, {:http_status, s}}
        {:error, e} -> {:error, e}
      end
    end

    @impl true
    def get_bearer(url, token) do
      headers = [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/json"},
        {"user-agent", "barkpark"}
      ]

      case Req.get(url, headers: headers) do
        {:ok, %{status: s, body: b}} when s in 200..299 and is_map(b) -> {:ok, b}
        {:ok, %{status: s}} -> {:error, {:http_status, s}}
        {:error, e} -> {:error, e}
      end
    end
  end
end
