defmodule Barkpark.Accounts.PrivacyExportCompletenessTest do
  @moduledoc """
  Owner ruling #32 item 7 (2026-10-03, task-43179d8d03efe969): the
  personal-data export (`Privacy.export_subject/1`, `GET /v1/auth/export`)
  covers three more kinds of rows that name the subject — revisions they
  authored, access grants made to them, and their paper-access log entries.
  Each section is METADATA ONLY: what, where and when, never document content
  (a revision snapshot is the workspace's data, not the subject's).
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Access, Accounts, Content, Repo, Tenancy}
  alias Barkpark.Accounts.Privacy
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.{CallerContext, PaperAccess}

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    {ws, proj} = ensure_default_scope!()
    email = "export-gaps-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    {:ok, other} =
      Accounts.register_user(%{email: "other-#{email}", password: "correct-horse-battery"})

    %{ws: ws, proj: proj, user: user, other: other}
  end

  defp user_ctx(user),
    do:
      CallerContext.with_actor(%CallerContext{principal_type: :user, user_id: user.id}, %{
        kind: "user",
        id: user.id,
        label: user.email
      })

  defp grant_to!(ws, email) do
    {:ok, grantor} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("g-" <> Ecto.UUID.generate()),
        label: "grantor",
        permissions: ["read"]
      })
      |> Repo.insert()

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, grantor.id, "admin", "api_token")

    {:ok, %{grant: grant}} =
      Access.mint(grantor, %{grantee_email: email, workspace_id: ws.id, capabilities: ["read"]})

    grant
  end

  test "the export lists the subject's revisions, grants and paper access — metadata only", c do
    doc_id = "export-gaps-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts." <> doc_id, "title" => "Secret body"},
        "test",
        caller_context: user_ctx(c.user),
        workspace_id: c.ws.id,
        project_id: c.proj.id
      )

    # Another user's revision stays out.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.other-" <> doc_id, "title" => "Other"},
        "test",
        caller_context: user_ctx(c.other),
        workspace_id: c.ws.id,
        project_id: c.proj.id
      )

    grant = grant_to!(c.ws, c.user.email)
    _other_grant = grant_to!(c.ws, c.other.email)

    :ok =
      PaperAccess.record_now(
        PaperAccess.entry("export-gaps-paper", "production", c.ws.id, "view", %{
          kind: "user",
          id: c.user.id,
          label: c.user.email
        })
      )

    export = Privacy.export_subject(c.user)

    assert [_ | _] = revisions = export.revisions
    assert Enum.all?(revisions, &String.ends_with?(&1.doc_id, doc_id))
    refute Enum.any?(revisions, &String.contains?(&1.doc_id, "other-"))
    assert Enum.all?(revisions, &(&1.type == "post" and &1.dataset == "test"))

    refute Jason.encode!(revisions) =~ "Secret body",
           "the revisions section carried document content, not metadata"

    assert [g] = export.access_grants
    assert g.id == grant.id
    assert g.capabilities == ["read"]
    refute Map.has_key?(g, :link_token_hash)

    assert [a] = export.paper_access
    assert a.slug == "export-gaps-paper"
    assert a.action == "view"
  end

  test "a subject with none of these rows gets empty sections, not missing keys", c do
    export = Privacy.export_subject(c.other)
    assert export.revisions == []
    assert export.access_grants == []
    assert export.paper_access == []
  end
end
