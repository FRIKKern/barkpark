defmodule BarkparkCloud.Web.RouterStudioSigninContestedHostTest do
  @moduledoc """
  task-7ebf8c0480297e7d: a host two rows hold resolves to the row
  `hostname_claims` names, not to the older one.

  The live shape (dr-w24-bl-gyldendal-live-cross-tenant-escalation): a ghost
  row (older, team A) carries the host as its `url` with no claim, and the
  customer's row (newer, team B) attached it as `custom_host` and holds the
  claim. The resolver used to order by age, so the ghost won: B's members got
  a 404 at studio-signin.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  # The contested host: the customer claims it as custom_host FIRST; the ghost
  # row then carries it as its url with no claim, and is made OLDER.
  defp contested do
    host = "contested-#{System.unique_integer([:positive])}.barkpark.cloud"

    {customer_user, customer_team} = user_with_team()
    customer = barkpark(customer_team)
    {:ok, customer} = Registry.set_custom_host(customer, host)

    customer =
      customer
      |> Ecto.Changeset.change(
        url: "https://customer-#{System.unique_integer([:positive])}.barkpark.cloud",
        host: "203.0.113.20",
        admin_token_encrypted: Vault.encrypt("customer-admin-token")
      )
      |> Repo.update!()

    {ghost_user, ghost_team} = user_with_team()

    ghost =
      ghost_team
      |> barkpark()
      |> Ecto.Changeset.change(
        url: "https://" <> host,
        host: "203.0.113.30",
        admin_token_encrypted: Vault.encrypt("ghost-admin-token"),
        inserted_at: DateTime.add(customer.inserted_at, -7 * 86_400, :second)
      )
      |> Repo.update!()

    %{
      host: host,
      customer: customer,
      customer_user: customer_user,
      ghost: ghost,
      ghost_user: ghost_user
    }
  end

  defp signin(host, user) do
    {:ok, token} = Accounts.create_user_session_token(user)

    conn(:post, "/v1/auth/studio-signin", Jason.encode!(%{host: host}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  test "the resolver returns the CLAIMANT, not the older ghost row" do
    c = contested()
    # DateTime.compare, never `<`: structural term order compares `day` before
    # `month` and went red at the 2026-10-01 month boundary (task-0284692b2db7f02e).
    assert DateTime.compare(c.ghost.inserted_at, c.customer.inserted_at) == :lt
    assert Registry.get_barkpark_by_public_host(c.host).id == c.customer.id
  end

  test "studio-signin by the contested host serves the claimant's members and 404s the ghost's" do
    c = contested()

    StudioLinkFakeHttpClient.program([
      {:ok, %{status: 201, body: ~s({"ticket":"bplt_contested","expires_in":60})}}
    ])

    assert signin(c.host, c.customer_user).status == 200
    assert signin(c.host, c.ghost_user).status == 404
  end

  test "CONTROL: an unclaimed host still resolves through the column match" do
    {_user, team} = user_with_team()
    host = "plain-#{System.unique_integer([:positive])}.barkpark.cloud"

    bp =
      team
      |> barkpark()
      |> Ecto.Changeset.change(url: "https://" <> host)
      |> Repo.update!()

    assert Registry.get_barkpark_by_public_host(host).id == bp.id
  end
end
