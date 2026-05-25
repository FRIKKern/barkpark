defmodule Barkpark.TenancyAuthTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Auth, Membership}

  # `Auth` is Barkpark.Tenancy.Auth (the primitives under test); the token
  # context is reached via the `TokenAuth` alias.
  alias Barkpark.Auth, as: TokenAuth

  defp workspace(slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: "Auth WS"})
    ws
  end

  # Insert a raw token (no membership) so we can test authorize/3 against an
  # explicitly-controlled membership state.
  defp raw_token(permissions, dataset \\ "test") do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("t-" <> Ecto.UUID.generate()),
        label: "l",
        dataset: dataset,
        permissions: permissions
      })
      |> Repo.insert()

    token
  end

  describe "authorize/3 matrix" do
    test "member with read perm → :ok for :read; forbidden for :write/:admin" do
      ws = workspace("ws-read")
      token = raw_token(["read"])
      {:ok, _} = Auth.create_membership(ws.id, token.id, "member")

      assert Auth.authorize(token, ws.id, :read) == :ok
      assert Auth.authorize(token, ws.id, :write) == {:error, :forbidden}
      assert Auth.authorize(token, ws.id, :admin) == {:error, :forbidden}
    end

    test "member needing write but read-only → forbidden" do
      ws = workspace("ws-ro")
      token = raw_token(["read"])
      {:ok, _} = Auth.create_membership(ws.id, token.id, "member")

      assert Auth.authorize(token, ws.id, :write) == {:error, :forbidden}
    end

    test "member with write perm → :ok for :read and :write; forbidden for :admin" do
      ws = workspace("ws-write")
      token = raw_token(["read", "write"])
      {:ok, _} = Auth.create_membership(ws.id, token.id, "member")

      assert Auth.authorize(token, ws.id, :read) == :ok
      assert Auth.authorize(token, ws.id, :write) == :ok
      assert Auth.authorize(token, ws.id, :admin) == {:error, :forbidden}
    end

    test "admin perm → :ok for every action" do
      ws = workspace("ws-admin")
      token = raw_token(["admin"])
      {:ok, _} = Auth.create_membership(ws.id, token.id, "admin")

      assert Auth.authorize(token, ws.id, :read) == :ok
      assert Auth.authorize(token, ws.id, :write) == :ok
      assert Auth.authorize(token, ws.id, :admin) == :ok
    end

    test "public-read perm satisfies :read only" do
      ws = workspace("ws-pub")
      token = raw_token(["public-read"])
      {:ok, _} = Auth.create_membership(ws.id, token.id, "member")

      assert Auth.authorize(token, ws.id, :read) == :ok
      assert Auth.authorize(token, ws.id, :write) == {:error, :forbidden}
    end

    test "non-member is forbidden for every action even with admin perm" do
      ws = workspace("ws-nomem")
      token = raw_token(["admin"])

      refute Auth.member?(token, ws.id)
      assert Auth.authorize(token, ws.id, :read) == {:error, :forbidden}
      assert Auth.authorize(token, ws.id, :write) == {:error, :forbidden}
      assert Auth.authorize(token, ws.id, :admin) == {:error, :forbidden}
    end

    test "authorize/3 with a non-token principal is forbidden" do
      ws = workspace("ws-bad")
      assert Auth.authorize(nil, ws.id, :read) == {:error, :forbidden}
    end
  end

  describe "member?/2 and membership/2" do
    test "membership/2 accepts a token struct or a raw principal id" do
      ws = workspace("ws-mem")
      token = raw_token(["read"])
      {:ok, m} = Auth.create_membership(ws.id, token.id, "member")

      assert Auth.membership(token, ws.id).id == m.id
      assert Auth.membership(token.id, ws.id).id == m.id
      assert Auth.member?(token, ws.id)
      assert Auth.member?(token.id, ws.id)
    end

    test "non-member returns nil/false" do
      ws = workspace("ws-mem2")
      token = raw_token(["read"])
      assert Auth.membership(token, ws.id) == nil
      refute Auth.member?(token, ws.id)
    end
  end

  describe "create_token/5 binds a membership" do
    test "explicit workspace_id attaches a membership with role from permissions" do
      ws = workspace("ws-mint")

      {:ok, token} = TokenAuth.create_token("mint-raw-1", "l", "test", ["read", "write"], ws.id)

      assert token.workspace_id == ws.id
      m = Auth.membership(token, ws.id)
      assert %Membership{} = m
      assert m.role == "member"
      assert m.principal_type == "api_token"
      assert m.principal_id == token.id
    end

    test "an admin-permission token gets the admin role on its membership" do
      ws = workspace("ws-mint-admin")
      {:ok, token} = TokenAuth.create_token("mint-raw-2", "l", "test", ["admin"], ws.id)

      assert Auth.membership(token, ws.id).role == "admin"
      # And authorize/3 immediately works end-to-end off the minted membership.
      assert Auth.authorize(token, ws.id, :admin) == :ok
    end

    test "role_for_permissions/1 maps admin→admin else member" do
      assert Auth.role_for_permissions(["admin"]) == "admin"
      assert Auth.role_for_permissions(["read", "write"]) == "member"
      assert Auth.role_for_permissions([]) == "member"
    end
  end

  describe "token-membership backfill idempotency (data-level)" do
    # Re-run the migration's exact guarded INSERT twice against a token row
    # and assert exactly one membership lands — proving NOT EXISTS guards it.
    @insert """
    INSERT INTO workspace_memberships
      (id, workspace_id, principal_type, principal_id, role, inserted_at, updated_at)
    SELECT gen_random_uuid(), t.workspace_id, 'api_token', t.id,
      CASE WHEN 'admin' = ANY(t.permissions) THEN 'admin' ELSE 'member' END,
      now(), now()
    FROM api_tokens t
    WHERE t.workspace_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM workspace_memberships m
        WHERE m.workspace_id = t.workspace_id
          AND m.principal_type = 'api_token'
          AND m.principal_id = t.id
      )
    """

    test "running the guarded INSERT twice yields exactly one membership" do
      ws = workspace("ws-backfill")
      # Raw token bound to the workspace but WITHOUT a membership yet.
      {:ok, token} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token("backfill-raw"),
          label: "l",
          dataset: "test",
          permissions: ["admin"],
          workspace_id: ws.id
        })
        |> Repo.insert()

      Repo.query!(@insert, [])
      Repo.query!(@insert, [])

      memberships =
        Repo.all(
          from m in Membership,
            where: m.principal_id == ^token.id and m.workspace_id == ^ws.id
        )

      assert length(memberships) == 1
      assert hd(memberships).role == "admin"
    end
  end
end
