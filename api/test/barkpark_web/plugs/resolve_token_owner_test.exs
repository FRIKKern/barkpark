defmodule BarkparkWeb.Plugs.ResolveTokenOwnerTest do
  @moduledoc """
  ResolveTokenOwner — the token→owner seam. Non-halting; assigns `:current_user`
  ONLY for an OWNED token, never overriding an existing session user, and fails
  closed (assigns nothing) for a NULL-owner or absent token.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts
  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias BarkparkWeb.Plugs.ResolveTokenOwner

  @password "correct-horse-battery"

  defp user(prefix) do
    {:ok, u} =
      Accounts.register_user(%{
        email: "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    u
  end

  defp token(attrs) do
    {:ok, t} =
      %ApiToken{}
      |> ApiToken.changeset(
        Map.merge(
          %{token_hash: ApiToken.hash_token("r-" <> Ecto.UUID.generate()), permissions: ["read"]},
          attrs
        )
      )
      |> Repo.insert()

    t
  end

  test "an OWNED token assigns :current_user = its owner", %{conn: conn} do
    u = user("owner")
    tok = token(%{owner_user_id: u.id})

    conn = conn |> assign(:api_token, tok) |> ResolveTokenOwner.call([])

    assert %User{id: id} = conn.assigns[:current_user]
    assert id == u.id
    refute conn.halted
  end

  test "a NULL-owner token assigns NOTHING (fail closed)", %{conn: conn} do
    tok = token(%{})
    conn = conn |> assign(:api_token, tok) |> ResolveTokenOwner.call([])
    assert is_nil(conn.assigns[:current_user])
    refute conn.halted
  end

  test "no token assigns nothing", %{conn: conn} do
    conn = ResolveTokenOwner.call(conn, [])
    assert is_nil(conn.assigns[:current_user])
  end

  test "an existing :current_user is NEVER overridden by a token owner", %{conn: conn} do
    session_user = user("session")
    other = user("other")
    tok = token(%{owner_user_id: other.id})

    conn =
      conn
      |> assign(:current_user, session_user)
      |> assign(:api_token, tok)
      |> ResolveTokenOwner.call([])

    assert conn.assigns[:current_user].id == session_user.id
  end
end
