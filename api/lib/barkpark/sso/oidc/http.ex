defmodule Barkpark.Sso.Oidc.HTTP do
  @moduledoc """
  The two outbound calls the OIDC relying-party makes — the token-endpoint POST
  and the JWKS GET — behind a swappable behaviour so tests can stand in a mock
  IdP (config key `:oidc_http`). The default is a `Req`-backed client.
  """
  @callback post_form(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback get_json(String.t()) :: {:ok, map()} | {:error, term()}

  def impl, do: Application.get_env(:barkpark, :oidc_http, __MODULE__.ReqClient)
  def post_form(url, params), do: impl().post_form(url, params)
  def get_json(url), do: impl().get_json(url)

  defmodule ReqClient do
    @moduledoc false
    @behaviour Barkpark.Sso.Oidc.HTTP

    @impl true
    def post_form(url, params) do
      case Req.post(url, form: params) do
        {:ok, %{status: s, body: body}} when s in 200..299 and is_map(body) -> {:ok, body}
        {:ok, %{status: s}} -> {:error, {:http_status, s}}
        {:error, e} -> {:error, e}
      end
    end

    @impl true
    def get_json(url) do
      case Req.get(url) do
        {:ok, %{status: s, body: body}} when s in 200..299 and is_map(body) -> {:ok, body}
        {:ok, %{status: s}} -> {:error, {:http_status, s}}
        {:error, e} -> {:error, e}
      end
    end
  end
end
