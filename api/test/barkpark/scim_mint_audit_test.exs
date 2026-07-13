defmodule Barkpark.ScimMintAuditTest do
  @moduledoc "Minting a SCIM token emits an audit event (era-w5-portal-mutation-audit)."
  use Barkpark.DataCase, async: true

  alias Barkpark.{Audit, Repo, Scim, Tenancy}
  alias Barkpark.Audit.Event
  import Ecto.Query

  test "mint_token emits a token/scim_token_minted audit event (org + label)" do
    {:ok, org} = Tenancy.create_organization(%{slug: "auditmint", name: "Audit Mint"})

    assert {:ok, {_plaintext, tok}} = Scim.mint_token(org.id, "portal")

    ev = Repo.one(from e in Event, where: e.action == "scim_token_minted")
    assert ev.category == "token"
    assert ev.subject == tok.id
    assert ev.metadata["organization_id"] == org.id
    assert ev.metadata["label"] == "portal"

    # the emit is in the context, so it fires regardless of caller (portal or API)
    assert :ok == Audit.verify_chain(nil)
  end

  test "create_group / delete_group emit membership lifecycle audit events" do
    {:ok, org} = Tenancy.create_organization(%{slug: "grpaudit", name: "Group Audit"})

    assert {:ok, group} =
             Scim.create_group(org, %{"displayName" => "Editors", "role" => "member"})

    created = Repo.one(from e in Event, where: e.action == "scim_group_created")
    assert created.category == "membership"
    assert created.subject == group.id
    assert created.metadata["group"] == "Editors"
    assert created.metadata["role"] == "member"

    assert {:ok, 1} = Scim.delete_group(org, group)

    deleted = Repo.one(from e in Event, where: e.action == "scim_group_deleted")
    assert deleted.category == "membership"
    assert deleted.subject == group.id

    assert :ok == Audit.verify_chain(nil)
  end
end
