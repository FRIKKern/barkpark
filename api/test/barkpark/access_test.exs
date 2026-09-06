defmodule Barkpark.AccessTest do
  @moduledoc """
  Access-grants lifecycle + fail-closed paths, proved NON-VACUOUSLY: a grantor
  mints only what it holds, an expired/revoked grant is refused, an out-of-scope
  or un-permitted action is refused, claim binds exactly once, and UUID-guarded
  reads never crash.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Access
  alias Barkpark.Access.Grant
  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.{CallerContext, Scope}
  alias Barkpark.Tenancy.{Auth, Membership}

  @password "correct-horse-battery"

  # An API-token grantor with a chosen permission set, made an admin member of
  # `ws` so authorize/3 combines membership AND permits?. The token's perms are
  # what cap the grant — a ["read"] token can never MINT a "write" grant.
  defp grantor_token(ws, permissions, role \\ "admin") do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("t-" <> Ecto.UUID.generate()),
        label: "grantor",
        dataset: "test",
        permissions: permissions
      })
      |> Repo.insert()

    {:ok, _} = Auth.create_membership(ws.id, token.id, role, "api_token")
    token
  end

  defp grantee_user do
    email = "grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp base_attrs(ws, overrides) do
    Map.merge(
      %{
        grantee_email: "grantee@example.com",
        workspace_id: ws.id,
        capabilities: ["read"]
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # 1. mint → validate :ok; raw token returned once, only the hash stored
  # ---------------------------------------------------------------------------

  describe "mint/2 + validate/3 happy path" do
    test "mints an in-scope grant, returns the raw token once, stores only the hash" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])

      assert {:ok, %{grant: %Grant{} = grant, token: raw}} =
               Access.mint(grantor, base_attrs(ws, %{capabilities: ["read", "write"]}))

      # raw token returned; never persisted verbatim
      assert is_binary(raw) and byte_size(raw) > 20
      refute grant.link_token_hash == raw
      assert grant.link_token_hash == :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
      assert grant.grantor_id == grantor.id

      # in-scope action validates :ok both by struct and by raw token
      assert Access.validate(grant, :read, %{workspace_id: ws.id}) == :ok
      assert Access.validate(raw, :write, %{workspace_id: ws.id}) == :ok

      # active lookup resolves the same grant
      assert %Grant{id: id} = Access.lookup_by_token(raw)
      assert id == grant.id
    end
  end

  # ---------------------------------------------------------------------------
  # 2. mint no-escalation: grantor lacking a capability → :forbidden
  # ---------------------------------------------------------------------------

  describe "mint/2 no-escalation gate" do
    test "a read-only grantor cannot mint a write grant" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["read"])

      # can confer what it holds
      assert {:ok, _} = Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"]}))

      # cannot confer write it does not hold
      assert Access.mint(grantor, base_attrs(ws, %{capabilities: ["write"]})) ==
               {:error, :forbidden}

      # cannot confer admin it does not hold
      assert Access.mint(grantor, base_attrs(ws, %{capabilities: ["read", "admin"]})) ==
               {:error, :forbidden}
    end

    # The OTHER arm of the same conjunction, pinned apart from the one above so
    # the two reasons can never collapse back into one atom. This grantor HOLDS
    # `read` — `permits?` cannot be what refused it; it is simply not a member
    # of `ws_b`. The membership-shortfall test above (`:forbidden`) and this one
    # (`:not_a_member`) fail in opposite directions if either arm is mislabelled.
    test "a non-member grantor that HOLDS the capability fails on membership, not capability" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()
      grantor = grantor_token(ws_a, ["read", "write"])

      # It really does hold the capability — in the workspace it belongs to.
      assert {:ok, _} = Access.mint(grantor, base_attrs(ws_a, %{capabilities: ["read"]}))

      assert Access.mint(grantor, base_attrs(ws_b, %{capabilities: ["read"]})) ==
               {:error, :not_a_member}
    end

    test "an unknown capability is rejected (fail-closed)" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])

      assert Access.mint(grantor, base_attrs(ws, %{capabilities: ["publish"]})) ==
               {:error, :forbidden}
    end
  end

  # ---------------------------------------------------------------------------
  # 3. validate EXPIRY
  # ---------------------------------------------------------------------------

  describe "validate/3 expiry" do
    test "an expired grant validates to {:error, :expired}" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, %{grant: grant, token: raw}} =
        Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"], expires_at: past}))

      assert Access.validate(grant, :read, %{workspace_id: ws.id}) == {:error, :expired}
      assert Access.validate(raw, :read, %{workspace_id: ws.id}) == {:error, :expired}
      # and an expired grant is not resolvable as active
      assert Access.lookup_by_token(raw) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # 4. validate SCOPE-DENIAL + action-not-in-capabilities
  # ---------------------------------------------------------------------------

  describe "validate/3 scope + capability denial" do
    test "a request outside the grant's scope ladder is forbidden" do
      ws = create_workspace!()
      proj = create_project!(ws)
      grantor = grantor_token(ws, ["admin"])

      # grant scoped down to a specific project
      {:ok, %{grant: grant}} =
        Access.mint(
          grantor,
          base_attrs(ws, %{capabilities: ["read"], project_id: proj.id})
        )

      # at-or-under the grant scope → ok
      assert Access.validate(grant, :read, %{workspace_id: ws.id, project_id: proj.id}) == :ok

      # a DIFFERENT project in the same workspace → escape → forbidden
      other_proj = create_project!(ws)

      assert Access.validate(grant, :read, %{workspace_id: ws.id, project_id: other_proj.id}) ==
               {:error, :forbidden}

      # a broader request that omits the project the grant pins → forbidden
      assert Access.validate(grant, :read, %{workspace_id: ws.id}) == {:error, :forbidden}

      # a different workspace entirely → forbidden
      assert Access.validate(grant, :read, %{workspace_id: Ecto.UUID.generate()}) ==
               {:error, :forbidden}
    end

    test "an action not in the grant's capabilities is forbidden" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])

      {:ok, %{grant: grant}} =
        Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"]}))

      # in-scope but write is not conferred → forbidden
      assert Access.validate(grant, :write, %{workspace_id: ws.id}) == {:error, :forbidden}
      assert Access.validate(grant, :admin, %{workspace_id: ws.id}) == {:error, :forbidden}
    end
  end

  describe "admits_desk?/3 — desk-granularity admission (ag-…-subscope)" do
    test "a type/doc grant ADMITS its own project/dataset desk (below-desk levels auto-satisfied)" do
      ws = create_workspace!()
      proj = create_project!(ws)
      grantor = grantor_token(ws, ["admin"])

      {:ok, %{grant: grant}} =
        Access.mint(
          grantor,
          base_attrs(ws, %{
            capabilities: ["read"],
            project_id: proj.id,
            dataset: "production",
            type: "post"
          })
        )

      desk = %{workspace_id: ws.id, project_id: proj.id, dataset: "production"}

      # The desk cannot name a type, yet the type-scoped grant admits it —
      # plain validate/3 (below) would DENY (the pinned type escapes the desk).
      assert Access.admits_desk?(grant, :read, desk) == true
      assert Access.validate(grant, :read, desk) == {:error, :forbidden}
    end

    test "NO WIDEN — a project grant does NOT admit a sibling or project-less desk" do
      ws = create_workspace!()
      proj = create_project!(ws)
      other = create_project!(ws)
      grantor = grantor_token(ws, ["admin"])

      {:ok, %{grant: grant}} =
        Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"], project_id: proj.id}))

      # own desk → admit; sibling project's desk → deny; project-less (broader)
      # desk → deny (the desk omits the project the grant pins → escape).
      assert Access.admits_desk?(grant, :read, %{workspace_id: ws.id, project_id: proj.id}) ==
               true

      assert Access.admits_desk?(grant, :read, %{workspace_id: ws.id, project_id: other.id}) ==
               false

      assert Access.admits_desk?(grant, :read, %{workspace_id: ws.id}) == false
    end

    test "fail-closed — capability + a foreign workspace are still enforced" do
      ws = create_workspace!()
      proj = create_project!(ws)
      grantor = grantor_token(ws, ["admin"])

      {:ok, %{grant: grant}} =
        Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"], project_id: proj.id}))

      desk = %{workspace_id: ws.id, project_id: proj.id, dataset: "production"}

      # read-only grant → :write desk denied; a different workspace → denied.
      assert Access.admits_desk?(grant, :write, desk) == false
      assert Access.admits_desk?(grant, :read, %{workspace_id: Ecto.UUID.generate()}) == false
    end
  end

  # ---------------------------------------------------------------------------
  # 5. revoke → subsequent validate → {:error, :revoked}; idempotent
  # ---------------------------------------------------------------------------

  describe "revoke/2" do
    test "revoking flips validate to :revoked and is idempotent" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])

      {:ok, %{grant: grant, token: raw}} =
        Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"]}))

      assert {:ok, revoked} = Access.revoke(grant.id, grantor)
      refute is_nil(revoked.revoked_at)

      # the revoked record (and the raw token, which re-fetches) both validate
      # to :revoked. (Passing the STALE pre-revoke struct trusts its own fields
      # by design — validate/3 on a %Grant{} does not re-query.)
      assert Access.validate(revoked, :read, %{workspace_id: ws.id}) == {:error, :revoked}
      assert Access.validate(raw, :read, %{workspace_id: ws.id}) == {:error, :revoked}
      assert Access.lookup_by_token(raw) == nil

      # idempotent: second revoke is a no-op {:ok, grant}
      assert {:ok, _} = Access.revoke(grant.id, grantor)
    end

    test "a stranger principal cannot revoke" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])
      stranger = grantor_token(ws, ["read"], "member")

      {:ok, %{grant: grant}} = Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"]}))

      # stranger is neither grantor nor workspace-admin → forbidden
      assert Access.revoke(grant.id, stranger) == {:error, :forbidden}
      # grant remains active
      refute is_nil(Access.get_grant(grant.id))
    end
  end

  # ---------------------------------------------------------------------------
  # 6. claim binds a user; single_use double-claim refused
  # ---------------------------------------------------------------------------

  describe "claim/2" do
    test "claim binds the grantee user and stamps claimed_at" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])
      user = grantee_user()

      {:ok, %{token: raw}} = Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"]}))

      assert {:ok, claimed} = Access.claim(raw, user)
      assert claimed.grantee_user_id == user.id
      refute is_nil(claimed.claimed_at)

      # bound grant surfaces in the grantee's active list
      ids = Access.list_active_grants_for_grantee(user.id) |> Enum.map(& &1.id)
      assert claimed.id in ids
    end

    test "a single-use grant refuses a second claim" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])
      user1 = grantee_user()
      user2 = grantee_user()

      {:ok, %{token: raw}} =
        Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"], single_use: true}))

      assert {:ok, _} = Access.claim(raw, user1)
      # second claim (even a different user) is refused atomically
      assert Access.claim(raw, user2) == {:error, :already_claimed}

      # a spent single-use grant is no longer active
      assert Access.lookup_by_token(raw) == nil
    end

    test "claiming a missing token is not_found" do
      user = grantee_user()
      assert Access.claim("no-such-token", user) == {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # 7. UUID-guarded reads never crash
  # ---------------------------------------------------------------------------

  describe "UUID guards" do
    test "get_grant / revoke with a non-UUID string do not crash" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])

      assert Access.get_grant("not-a-uuid") == nil
      assert Access.revoke("not-a-uuid", grantor) == {:error, :not_found}
      assert Access.list_active_grants_for_grantee("not-a-uuid") == []
    end

    # The three grant reads now delegate the cast to Repo.uuid_or_nil/1. Prove
    # the guard is intact after the dedup: a non-UUID string folds to the empty
    # branch (never an Ecto.CastError 500), while a well-formed-but-absent UUID
    # exercises the cast-success → no-row path (also empty, no crash).
    test "list reads fold a non-UUID and a well-formed-absent UUID to empty" do
      absent = Ecto.UUID.generate()

      assert Access.list_grants_for_workspace("not-a-uuid") == []
      assert Access.list_grants_for_workspace(absent) == []
      assert Access.list_active_grants_for_grantee(absent) == []
      assert Access.get_grant(absent) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Grantor authority re-validated LIVE at enforcement (finding ag-1). A grant
  # only confers a capability while its GRANTOR still holds that capability in
  # the workspace, RE-CHECKED per action at read time. Both directions, paired:
  # the NEGATIVE (grantor lost authority → grant no longer admits) and its
  # explicit POSITIVE control (grantor still holds → grant still admits).
  # ---------------------------------------------------------------------------
  describe "grantor authority re-validation at enforcement (ag-1)" do
    # Remove the grantor's membership row → grantor holds NOTHING in the ws.
    defp remove_membership(ws, principal_id) do
      from(m in Membership,
        where: m.workspace_id == ^ws.id and m.principal_id == ^principal_id
      )
      |> Repo.delete_all()
    end

    # POSITIVE CONTROL (no over-deny): a grantor that STILL holds the capability
    # admits normally — the re-validation gates ONLY on lost authority.
    test "grantor still holds authority → grant STILL admits (no over-deny)" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["read", "write"])

      {:ok, %{grant: grant, token: raw}} =
        Access.mint(grantor, base_attrs(ws, %{capabilities: ["read", "write"]}))

      assert Access.grantor_authorizes?(grant, :write) == true
      assert Access.validate(grant, :read, %{workspace_id: ws.id}) == :ok
      assert Access.validate(grant, :write, %{workspace_id: ws.id}) == :ok
      assert Access.validate(raw, :write, %{workspace_id: ws.id}) == :ok
    end

    # NEGATIVE (the hole): grantor's membership is REMOVED after the grant is
    # minted → the grant confers nothing thereafter.
    test "grantor membership removed → grant no longer admits (hole closed)" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["read", "write"])

      {:ok, %{grant: grant}} =
        Access.mint(grantor, base_attrs(ws, %{capabilities: ["read", "write"]}))

      # admits while the grantor still holds authority
      assert Access.validate(grant, :write, %{workspace_id: ws.id}) == :ok

      # grantor loses ALL authority in the workspace
      remove_membership(ws, grantor.id)

      # the grant now confers nothing — denied by real behavior, not a flag
      assert Access.grantor_authorizes?(grant, :read) == false
      assert Access.validate(grant, :read, %{workspace_id: ws.id}) == {:error, :forbidden}
      assert Access.validate(grant, :write, %{workspace_id: ws.id}) == {:error, :forbidden}
    end

    # PARTIAL DOWNGRADE (per-action): token grantor downgraded write→read. A
    # read grant still admits; the write action is denied — grantor authority is
    # per-action, so the grant confers only what the grantor still holds.
    test "grantor downgraded write→read → read admits, write denied (per-action)" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["read", "write"])

      {:ok, %{grant: grant}} =
        Access.mint(grantor, base_attrs(ws, %{capabilities: ["read", "write"]}))

      # downgrade the grantor's live capability: write→read
      grantor |> Ecto.Changeset.change(permissions: ["read"]) |> Repo.update!()

      assert Access.validate(grant, :read, %{workspace_id: ws.id}) == :ok
      assert Access.validate(grant, :write, %{workspace_id: ws.id}) == {:error, :forbidden}
    end

    # USER grantor path (proves User-principal resolution + per-action admin).
    # An admin USER mints an admin-bearing grant, then is downgraded admin→member
    # (member keeps read/write, loses admin): the grant loses admin, keeps read.
    test "USER grantor downgraded admin→member → admin denied, read kept" do
      ws = create_workspace!()
      user = grantee_user()
      {:ok, _} = Auth.create_membership(ws.id, user.id, "admin", "user")

      {:ok, %{grant: grant}} =
        Access.mint(user, base_attrs(ws, %{capabilities: ["read", "write", "admin"]}))

      assert Access.validate(grant, :admin, %{workspace_id: ws.id}) == :ok

      from(m in Membership,
        where:
          m.workspace_id == ^ws.id and m.principal_id == ^user.id and
            m.principal_type == "user"
      )
      |> Repo.update_all(set: [role: "member"])

      assert Access.validate(grant, :admin, %{workspace_id: ws.id}) == {:error, :forbidden}
      assert Access.validate(grant, :read, %{workspace_id: ws.id}) == :ok
    end

    # FAIL-CLOSED: a grant whose grantor_id resolves to no live principal
    # (deleted / never-existed) is excluded — never fail-open.
    test "fail-closed: unresolvable grantor → grant excluded" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["read"])
      {:ok, %{grant: grant}} = Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"]}))

      orphaned =
        grant |> Ecto.Changeset.change(grantor_id: Ecto.UUID.generate()) |> Repo.update!()

      assert Access.grantor_authorizes?(orphaned, :read) == false
      assert Access.validate(orphaned, :read, %{workspace_id: ws.id}) == {:error, :forbidden}
    end

    # FAIL-CLOSED: a REVOKED grantor token can no longer authenticate to mint, so
    # enforcement excludes its grants too (consistent with the mint gate).
    test "fail-closed: revoked grantor token → grant excluded" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["read", "write"])
      {:ok, %{grant: grant}} = Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"]}))

      assert Access.validate(grant, :read, %{workspace_id: ws.id}) == :ok

      {:ok, _} = Barkpark.Auth.revoke_token(grantor)

      assert Access.validate(grant, :read, %{workspace_id: ws.id}) == {:error, :forbidden}
    end

    # SECOND CHOKEPOINT (no bypass): the row-narrowing path scope_to_grants/3
    # honors the SAME grantor gate — a grant whose grantor lost read authority
    # drops out of the read-union → fail-closed zero rows, so the SQL path can't
    # admit what the per-action path denies.
    test "scope_to_grants excludes a grant whose grantor lost read authority" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["read"])
      {:ok, %{grant: grant}} = Access.mint(grantor, base_attrs(ws, %{capabilities: ["read"]}))

      ctx = %CallerContext{grants: [grant]}
      base = from(d in "documents")

      # grantor holds read → grant contributes a real union (not fail-closed)
      q_ok = Scope.scope_to_grants(base, ctx, ws.id)
      refute Enum.any?(q_ok.wheres, &(&1.expr == false))

      # grantor loses authority → read-union excludes the grant → zero rows
      remove_membership(ws, grantor.id)
      q_denied = Scope.scope_to_grants(base, ctx, ws.id)
      assert [%{expr: false}] = q_denied.wheres
    end
  end
end
