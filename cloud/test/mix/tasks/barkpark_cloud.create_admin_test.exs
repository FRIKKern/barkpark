defmodule Mix.Tasks.BarkparkCloud.CreateAdminTest do
  @moduledoc """
  Drives the create_admin Mix task's testable core (`create_admin/3`) against
  the sandbox repo — no Mix process, no `app.start`, so the Ecto sandbox owns
  the connection and every change reverts at test end.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias Mix.Tasks.BarkparkCloud.CreateAdmin

  @password "correct-horse-battery"

  test "creates user + team + owner membership directly via Accounts" do
    email = "admin-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, %{user: user, team: team, membership: membership}} =
             CreateAdmin.create_admin(email, @password)

    assert user.email == email
    assert is_binary(user.hashed_password)
    refute user.hashed_password == @password

    # Team name + slug derive from the email local-part when no TEAM_NAME given.
    local = email |> String.split("@") |> List.first()
    assert team.name == local
    assert team.slug == local

    assert membership.role == "owner"
    assert Accounts.get_membership(team, user).id == membership.id
  end

  test "explicit team name is honoured and slugified" do
    email = "admin-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, %{team: team}} = CreateAdmin.create_admin(email, @password, "Control Plane")
    assert team.name == "Control Plane"
    assert team.slug == "control-plane"
  end

  test "existing email → {:error, :email_taken}, no second user" do
    email = "dup-admin-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.register_user(%{email: email, password: @password})

    assert {:error, :email_taken} = CreateAdmin.create_admin(email, @password)
  end

  test "rollback: a reserved team slug leaves no orphan user" do
    email = "rb-admin-#{System.unique_integer([:positive])}@example.com"

    # "admin" is a reserved slug → create_team fails → transaction rolls back.
    assert {:error, %Ecto.Changeset{}} = CreateAdmin.create_admin(email, @password, "admin")
    assert Accounts.get_user_by_email(email) == nil
  end

  test "weak password → changeset error, no user" do
    email = "weak-admin-#{System.unique_integer([:positive])}@example.com"

    assert {:error, %Ecto.Changeset{}} = CreateAdmin.create_admin(email, "short")
    assert Accounts.get_user_by_email(email) == nil
  end

  test "team name with a NUL/control byte → changeset error, not a Postgrex crash" do
    # Symmetric with the HTTP register guard: a NUL byte in TEAM_NAME would
    # otherwise reach the teams INSERT and raise Postgrex 22021. The Team
    # changeset control-char validation must surface a clean changeset error
    # (which the task prints + exits non-zero on) instead of crashing.
    email = "nul-admin-#{System.unique_integer([:positive])}@example.com"

    assert {:error, %Ecto.Changeset{}} =
             CreateAdmin.create_admin(email, @password, "evil" <> <<0>> <> "name")

    # The transaction rolled back — no orphan user committed.
    assert Accounts.get_user_by_email(email) == nil
  end
end
