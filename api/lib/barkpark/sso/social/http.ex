defmodule Barkpark.Sso.Social.HTTP do
  @moduledoc """
  The two social-login outbound calls — the token-endpoint POST and the
  userinfo GET (Bearer) — behind a swappable behaviour so tests stand in a mock
  provider (config `:social_http`). Default is a `Req`-backed client.
  """
  @callback post_form(String.t(), map()) :: {:ok, map()} | {:error, term()}
  # A JSON array body is legitimate here: github's GET /user/emails — the only
  # place the per-address `verified` flag lives — answers with a list.
  @callback get_bearer(String.t(), String.t()) :: {:ok, map() | list()} | {:error, term()}

  def impl, do: Application.get_env(:barkpark, :social_http, __MODULE__.ReqClient)
  def post_form(url, params), do: impl().post_form(url, params)
  def get_bearer(url, token), do: impl().get_bearer(url, token)

  defmodule ReqClient do
    @moduledoc false
    @behaviour Barkpark.Sso.Social.HTTP

    @impl true
    def post_form(url, params) do
      # Accept: json so GitHub returns JSON (not form-encoded) for the token.
      # Login-path outbound: isolate onto Barkpark.Auth.Finch and cap the wait
      # for the provider token endpoint at an explicit, tunable 10s (a hung
      # provider must never stall social login). receive_timeout is a top-level
      # Req option — NEVER connect_options, which Req rejects alongside :finch.
      case Req.post(url,
             form: params,
             headers: [{"accept", "application/json"}],
             finch: Barkpark.Auth.Finch,
             receive_timeout: 10_000
           ) do
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

      # Same isolation + explicit 10s cap for the userinfo fetch (see post_form/2).
      case Req.get(url, headers: headers, finch: Barkpark.Auth.Finch, receive_timeout: 10_000) do
        {:ok, %{status: s, body: b}} when s in 200..299 and (is_map(b) or is_list(b)) -> {:ok, b}
        {:ok, %{status: s}} -> {:error, {:http_status, s}}
        {:error, e} -> {:error, e}
      end
    end
  end
end
