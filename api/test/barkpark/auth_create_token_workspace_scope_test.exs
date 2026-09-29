defmodule Barkpark.AuthCreateTokenWorkspaceScopeTest do
  @moduledoc """
  task-e0e6454b8b2045ae — `Auth.create_token/5` was the LAST of the three api
  token mints still carrying `ws_id = workspace_id || default_workspace_id()`.

  THE INVARIANT THIS FILE IS THE DETECTOR FOR: a token minted through
  `create_token/5` with no workspace is NEVER given a `Tenancy.Membership` in a
  workspace the caller did not name. Restore the `|| default_workspace_id()`
  fallback at the mint and "mints workspace-less …" below goes RED.

  THE PRECONDITION IS THE WHOLE TEST. With the instance-default seat VACANT,
  `default_workspace_id()` resolved to `nil` anyway and the fallback was
  invisible — a suite that forgot to seat a default would pass identically
  before and after the fix and prove nothing. Every arm that claims something
  about the fallback therefore ASSERTS the seat is held first, by reading it
  back rather than trusting `establish_default_workspace!/0`'s return.

  `async: false`: the instance-default seat (`workspaces.is_default`, partial
  unique) and `Tenancy.DefaultScopeCache` are process-wide singletons.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Auth.PublicRead
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Membership

  import Barkpark.TenancyFixtures
  import Ecto.Query

  defp memberships_of(%ApiToken{id: token_id}) do
    Repo.all(from(m in Membership, where: m.principal_id == ^token_id))
  end

  defp raw, do: "ctws-" <> Ecto.UUID.generate()

  describe "create_token/5 with workspace_id nil (the removed Default fallback)" do
    setup do
      {default_ws, _project} = ensure_default_scope!()

      # PRECONDITION, not decoration: read the seat back. If this is nil the
      # arms below are vacuous — the fallback would have produced nil too.
      seated = Tenancy.get_default_workspace()

      assert seated != nil,
             "PRECONDITION FAILED: the instance-default seat is vacant, so " <>
               "default_workspace_id() would answer nil and this suite could " <>
               "not tell the fallback's presence from its absence"

      assert seated.id == default_ws.id

      %{default_ws: seated}
    end

    test "mints workspace-less and grants NO membership, while a Default workspace is seated",
         %{default_ws: default_ws} do
      {:ok, token} = Auth.create_token(raw(), "no-ws mint", "production", ["read"])

      assert token.workspace_id == nil,
             "create_token/5 bound a nil-workspace mint to #{inspect(token.workspace_id)} " <>
               "(the seated default is #{default_ws.id}) — the " <>
               "`|| default_workspace_id()` fallback is back at auth.ex"

      assert memberships_of(token) == [],
             "a token nobody scoped was handed a membership row — the caller " <>
               "named no workspace, so no workspace may name it"
    end

    test "the seated Default workspace gains no new api_token member from an unscoped mint",
         %{default_ws: default_ws} do
      before =
        Repo.aggregate(
          from(m in Membership, where: m.workspace_id == ^default_ws.id),
          :count
        )

      {:ok, _token} = Auth.create_token(raw(), "no-ws mint 2", "production", ["read", "write"])

      after_count =
        Repo.aggregate(
          from(m in Membership, where: m.workspace_id == ^default_ws.id),
          :count
        )

      assert after_count == before,
             "an unscoped create_token/5 added #{after_count - before} membership row(s) to " <>
               "the seated Default workspace"
    end

    test "an unscoped ADMIN-permission mint gets no admin seat in the Default workspace" do
      # The sharpest edge of the old fallback: role_for_permissions(["admin"])
      # is "admin", so the forgetful caller's token became an ADMIN of whatever
      # tenant held the default seat.
      {:ok, token} =
        Auth.create_token(raw(), "no-ws admin mint", "production", ["read", "write", "admin"])

      assert token.workspace_id == nil
      assert memberships_of(token) == []
    end
  end

  describe "CONTROL — an explicitly named workspace still mints token + membership atomically" do
    test "quiet under the arm mutation: restoring the fallback does not change this" do
      ws = create_workspace!("ct-explicit-ws")

      {:ok, token} =
        Auth.create_token(raw(), "scoped mint", "production", ["read", "write"], ws.id)

      assert token.workspace_id == ws.id

      assert [%Membership{} = membership] = memberships_of(token)
      assert membership.workspace_id == ws.id
      assert membership.principal_type == "api_token"
      assert membership.role == "member"
    end

    test "an admin-permission scoped mint derives the admin role" do
      ws = create_workspace!("ct-explicit-admin-ws")

      {:ok, token} =
        Auth.create_token(raw(), "scoped admin", "production", ["read", "write", "admin"], ws.id)

      assert [%Membership{role: "admin", workspace_id: ws_id}] = memberships_of(token)
      assert ws_id == ws.id
    end
  end

  describe "PublicRead — the one caller that MEANT the instance default now names it" do
    test "binds to the seated Default workspace explicitly" do
      {default_ws, _project} = ensure_default_scope!()
      assert Tenancy.get_default_workspace() != nil

      {:ok, _raw, row} = PublicRead.create_public_read_token("public-read-explicit")

      assert row.workspace_id == default_ws.id,
             "PublicRead.create_public_read_token/2 must resolve the instance-default " <>
               "seat itself now that create_token/5 has no fallback to lean on"

      assert [%Membership{workspace_id: ws_id}] = memberships_of(row)
      assert ws_id == default_ws.id
    end

    test "a VACANT seat stays vacant — no workspace, no membership, no crash" do
      ensure_default_scope!()
      vacate_default_seat!()

      {:ok, _raw, row} = PublicRead.create_public_read_token("public-read-vacant")

      assert row.workspace_id == nil
      assert memberships_of(row) == []
    end
  end
end
