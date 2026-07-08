defmodule Barkpark.AccessAuditTest do
  @moduledoc """
  Grant lifecycle audit trail (finding #11): mint / claim / revoke each land an
  `access`/`grant.*` event on the append-only, tamper-evident `Barkpark.Audit`
  bus — with the right actor/subject/metadata, the hash chain intact, and NO
  raw token or `link_token_hash` ever recorded (field hygiene).
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{Access, Audit, Repo}
  alias Barkpark.Access.Grant
  alias Barkpark.Audit.Event
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Accounts
  alias Barkpark.Tenancy.Auth

  @password "correct-horse-battery"

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
      %{grantee_email: "grantee@example.com", workspace_id: ws.id, capabilities: ["read"]},
      overrides
    )
  end

  defp event(action), do: Repo.one(from e in Event, where: e.action == ^action)

  # Every scalar value that ended up in a jsonb metadata map, flattened to
  # strings — so a secret hiding in a nested list/value is still caught.
  defp metadata_values(%{} = metadata) do
    metadata
    |> Map.values()
    |> Enum.flat_map(fn
      v when is_list(v) -> Enum.map(v, &to_string/1)
      nil -> []
      v -> [to_string(v)]
    end)
  end

  defp refute_secret(%Event{} = ev, raw, grant) do
    values = metadata_values(ev.metadata)
    refute Enum.member?(values, raw), "raw token leaked into #{ev.action} metadata"
    refute Enum.member?(values, grant.link_token_hash), "token hash leaked into #{ev.action}"
    refute Map.has_key?(ev.metadata, "link_token_hash")
    refute Map.has_key?(ev.metadata, "token")
  end

  # ---------------------------------------------------------------------------
  # mint → access/grant.minted
  # ---------------------------------------------------------------------------

  describe "mint/2 audit" do
    test "emits access/grant.minted — grantor actor, grant subject, non-secret scope" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])

      assert {:ok, %{grant: grant, token: raw}} =
               Access.mint(
                 grantor,
                 base_attrs(ws, %{
                   capabilities: ["read", "write"],
                   grantee_email: "alice@example.com",
                   single_use: true
                 })
               )

      ev = event("grant.minted")
      assert ev.category == "access"
      assert ev.subject == grant.id
      assert ev.actor_type == "token"
      assert ev.actor_id == grantor.id
      assert ev.workspace_id == ws.id

      # non-secret descriptors present
      assert ev.metadata["workspace_id"] == ws.id
      assert ev.metadata["grantee_email"] == "alice@example.com"
      assert ev.metadata["capabilities"] == ["read", "write"]
      assert ev.metadata["single_use"] == true

      refute_secret(ev, raw, grant)
      assert :ok == Audit.verify_chain(ws.id)
    end
  end

  # ---------------------------------------------------------------------------
  # claim → access/grant.claimed
  # ---------------------------------------------------------------------------

  describe "claim/2 audit" do
    test "emits access/grant.claimed — grantee user actor, grant subject" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])
      user = grantee_user()

      {:ok, %{grant: grant, token: raw}} = Access.mint(grantor, base_attrs(ws, %{}))
      assert {:ok, claimed} = Access.claim(raw, user)

      ev = event("grant.claimed")
      assert ev.category == "access"
      assert ev.subject == grant.id
      assert ev.actor_type == "user"
      assert ev.actor_id == user.id
      assert ev.workspace_id == ws.id
      assert ev.metadata["grantee_user_id"] == user.id
      assert claimed.grantee_user_id == user.id

      refute_secret(ev, raw, grant)
      assert :ok == Audit.verify_chain(ws.id)
    end
  end

  # ---------------------------------------------------------------------------
  # revoke → access/grant.revoked
  # ---------------------------------------------------------------------------

  describe "revoke/2 audit" do
    test "emits access/grant.revoked on the real state transition, once" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])

      {:ok, %{grant: grant, token: raw}} = Access.mint(grantor, base_attrs(ws, %{}))
      assert {:ok, _} = Access.revoke(grant.id, grantor)

      ev = event("grant.revoked")
      assert ev.category == "access"
      assert ev.subject == grant.id
      assert ev.actor_type == "token"
      assert ev.actor_id == grantor.id
      assert ev.workspace_id == ws.id
      refute is_nil(ev.metadata["revoked_at"])

      refute_secret(ev, raw, grant)

      # idempotent re-revoke is a no-op → still exactly one revoke event
      assert {:ok, _} = Access.revoke(grant.id, grantor)
      assert Repo.aggregate(from(e in Event, where: e.action == "grant.revoked"), :count) == 1

      assert :ok == Audit.verify_chain(ws.id)
    end
  end

  # ---------------------------------------------------------------------------
  # additive guarantee on the RAISE path: a raising emit can't break the op
  # ---------------------------------------------------------------------------

  describe "a RAISING Audit.emit is fully isolated (additive guarantee)" do
    test "mint/claim/revoke still return success and the grant persists" do
      ws = create_workspace!()
      grantor = grantor_token(ws, ["admin"])
      user = grantee_user()

      # Force EVERY Audit.emit to RAISE at the infra layer: with the audit table
      # gone, emit's per-workspace chain read raises a Postgrex.Error mid-emit
      # (an advisory-lock / DB-blip stand-in). The DDL runs inside the test
      # sandbox transaction and rolls back at test end.
      Repo.query!("ALTER TABLE audit_events RENAME TO audit_events_hidden")

      # mint: emit raises internally, yet mint returns {:ok, ...} and persists.
      assert {:ok, %{grant: grant, token: raw}} = Access.mint(grantor, base_attrs(ws, %{}))
      assert %Grant{} = Repo.get(Grant, grant.id)

      # claim: same isolation — normal success value, binding persisted.
      assert {:ok, claimed} = Access.claim(raw, user)
      assert claimed.grantee_user_id == user.id

      # revoke: same isolation — normal success value, revocation persisted.
      assert {:ok, revoked} = Access.revoke(grant.id, grantor)
      refute is_nil(revoked.revoked_at)

      # sanity: emit really WAS raising — no events were recorded.
      Repo.query!("ALTER TABLE audit_events_hidden RENAME TO audit_events")
      assert Repo.aggregate(from(e in Event, where: e.category == "access"), :count) == 0
    end
  end
end
