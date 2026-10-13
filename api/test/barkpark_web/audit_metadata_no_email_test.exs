defmodule BarkparkWeb.AuditMetadataNoEmailTest do
  @moduledoc """
  Owner ruling #32 item 2 (2026-10-03, task-43179d8d03efe969): new audit
  events do not carry raw email addresses in `metadata`.

  `audit_events` is append-only and hash-chained over its metadata, so an email
  written there survives erasure and cannot be redacted at read without
  breaking external verification. Three emitters wrote one:
  `grant.minted` (`grantee_email`), SCIM `user_provisioned` (`email`) and
  `app_token_minted` (`email`, plus the default `app:<email>` label). They now
  record user ids. Rows written before this change are covered by the
  security-log exemption documented in `Barkpark.Accounts.Privacy`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Access, Accounts, Auth, Repo, Scim, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Auth.ApiToken

  defp events(action),
    do: Repo.all(from(e in Event, where: e.action == ^action, order_by: [desc: e.id], limit: 5))

  defp email, do: "audit-email-#{System.unique_integer([:positive])}@example.com"

  test "app_token_minted names the user by id, not by email" do
    admin = "audit-email-admin-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(
        admin,
        "admin",
        "production",
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    address = email()

    scoped_conn()
    |> put_req_header("authorization", "Bearer #{admin}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/app-tokens", Jason.encode!(%{email: address}))
    |> json_response(201)

    user = Accounts.get_user_by_email(address)
    [event | _] = events("app_token_minted")

    refute Jason.encode!(event.metadata) =~ address, "app_token_minted metadata carries the email"
    assert event.metadata["user_id"] == user.id
    assert event.actor_id == user.id
  end

  test "grant.minted names the grantee by user id when the address has an account, never by email" do
    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: "audit-email-#{System.unique_integer([:positive])}",
        name: "A"
      })

    {:ok, grantor} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("g-" <> Ecto.UUID.generate()),
        label: "grantor",
        permissions: ["read"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, grantor.id, "admin", "api_token")

    address = email()
    {:ok, user} = Accounts.register_user(%{email: address, password: "correct-horse-battery"})

    {:ok, %{grant: _grant}} =
      Access.mint(grantor, %{grantee_email: address, workspace_id: ws.id, capabilities: ["read"]})

    [event | _] = events("grant.minted")

    refute Jason.encode!(event.metadata) =~ address, "grant.minted metadata carries the email"
    assert event.metadata["grantee_user_id"] == user.id
  end

  test "SCIM user_provisioned names the user by id, not by email" do
    slug = "audit-email-scim-#{System.unique_integer([:positive])}"
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    address = email()

    {:ok, user} = Scim.provision_user(org, %{"userName" => address})

    [event | _] = events("user_provisioned")
    refute Jason.encode!(event.metadata) =~ address, "user_provisioned metadata carries the email"
    assert event.subject == user.id
    assert event.metadata["user_id"] == user.id
  end
end
