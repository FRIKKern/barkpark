defmodule SanityApi.Auth do
  @moduledoc "Context for API token authentication."

  import Ecto.Query
  alias SanityApi.Repo
  alias SanityApi.Auth.ApiToken

  def verify_token(raw_token) do
    hash = ApiToken.hash_token(raw_token)

    ApiToken
    |> where([t], t.token_hash == ^hash)
    |> Repo.one()
    |> case do
      nil -> {:error, :unauthorized}
      token -> {:ok, token}
    end
  end

  def create_token(raw_token, label, dataset, permissions) do
    %ApiToken{}
    |> ApiToken.changeset(%{
      token_hash: ApiToken.hash_token(raw_token),
      label: label,
      dataset: dataset,
      permissions: permissions
    })
    |> Repo.insert()
  end

  def list_tokens(dataset) do
    ApiToken
    |> where([t], t.dataset == ^dataset)
    |> Repo.all()
  end

  def has_permission?(token, permission) do
    permission in token.permissions
  end
end
