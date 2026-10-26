defmodule Barkpark.Accounts.BootstrapOwnerTest do
  @moduledoc "BARKPARK_BOOTSTRAP_OWNER_EMAIL seats the first owner once (task-2f87e451273f55cc)."
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Accounts, Repo, Sso, Tenancy}
  alias Barkpark.Accounts.{BootstrapOwner, User}
  alias Barkpark.Audit.Event

  setup do
    Repo.delete_all(User)
    %{ws: Tenancy.establish_default_workspace!()}
  end

  test "unset does nothing" do
    assert BootstrapOwner.run(nil) == :skipped
    assert BootstrapOwner.run("") == :skipped
    refute Repo.exists?(User)
  end

  test "a fresh instance gets the owner once; a second boot changes nothing", %{ws: ws} do
    assert {:ok, user} = BootstrapOwner.run(" Owner@Example.com ")
    assert user.email == "owner@example.com"
    assert user.confirmed_at
    assert Tenancy.Auth.authorize(user, ws.id, :admin) == :ok

    assert [%{metadata: %{"workspace_slug" => slug}}] =
             Repo.all(from e in Event, where: e.action == "bootstrap_owner_created")

    assert slug == ws.slug

    # The SSO gate admits the owner once the default workspace is in the org.
    {:ok, org} = Tenancy.create_organization(%{slug: "gyl", name: "Gyl"})
    {:ok, _} = Tenancy.assign_workspace_to_organization(ws, org.id)
    assert {:ok, %User{id: id}} = Sso.org_adopt(org.id, user, user.email)
    assert id == user.id

    assert BootstrapOwner.run("owner@example.com") == :skipped
    assert BootstrapOwner.run("someone-else@example.com") == :skipped
    assert Repo.aggregate(User, :count) == 1

    assert Repo.aggregate(from(e in Event, where: e.action == "bootstrap_owner_created"), :count) ==
             1
  end

  test "an instance that already has a user is left alone" do
    {:ok, _} =
      Accounts.register_user(%{email: "existing@example.com", password: "a-long-password-1"})

    assert BootstrapOwner.run("owner@example.com") == :skipped
    assert Accounts.get_user_by_email("owner@example.com") == nil
  end
end
