defmodule Barkpark.Content.OwnerRuleTokensTest do
  @moduledoc """
  OWNER RULING 2026-10-03 #9 (task-84f7e11095ee859c, task-f462de9e4c1c4621
  item 3): on owner-scoped types the owner rule applies everywhere.

    1. A token tied to a user (`owner_user_id`: PATs) acts as that user: it
       sees its owner's rows and the unowned base, and its writes are stamped
       with its owner. Service tokens with no user keep see-all.
    2. Updates keep the STORED owner — editing the shared unowned base no
       longer makes the row the editor's (no claim-on-edit).
    3. A caller that carries a signed-in user and no context (Studio account
       sockets) acts as that user, never as anonymous.
    4. History (list / get / restore) follows the owner rule of the document.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, Revisions}

  @dataset "test"
  @owned_type "secret_note"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @owned_type,
          "title" => "Secret Note",
          "owner_scoped" => true,
          "fields" => [%{"name" => "body", "type" => "text"}]
        },
        @dataset
      )

    %{user_a: Ecto.UUID.generate(), user_b: Ecto.UUID.generate()}
  end

  defp user_opts(uid), do: [caller_context: CallerContext.from_user(uid, load_grants: false)]

  defp service_opts,
    do: [
      caller_context:
        CallerContext.from_token(%ApiToken{
          id: Ecto.UUID.generate(),
          permissions: ["read", "write"]
        })
    ]

  defp pat_opts(uid),
    do: [
      caller_context:
        CallerContext.from_token(%ApiToken{
          id: Ecto.UUID.generate(),
          permissions: ["read", "write"],
          owner_user_id: uid
        })
    ]

  defp admin_opts,
    do: [
      caller_context: %CallerContext{
        principal_type: :user,
        user_id: Ecto.UUID.generate(),
        is_admin: true
      }
    ]

  defp create!(attrs, opts) do
    {:ok, doc} =
      Content.create_document(@owned_type, attrs, @dataset, [instance_wide: true] ++ opts)

    doc
  end

  defp upsert!(attrs, opts) do
    {:ok, doc} =
      Content.upsert_document(@owned_type, attrs, @dataset, [instance_wide: true] ++ opts)

    doc
  end

  defp get(doc, opts), do: Content.get_document(doc.doc_id, @owned_type, @dataset, opts)

  describe "1. a user-owned token acts as its user" do
    test "a PAT reads its owner's rows and the shared base, never another member's",
         %{user_a: a, user_b: b} do
      b_doc = create!(%{"title" => "b-secret"}, user_opts(b))
      a_doc = create!(%{"title" => "a-secret"}, user_opts(a))
      shared = create!(%{"title" => "shared"}, service_opts())

      assert {:error, :not_found} = get(b_doc, pat_opts(a))
      assert {:ok, _} = get(a_doc, pat_opts(a))
      assert {:ok, _} = get(shared, pat_opts(a))
    end

    test "a PAT's write is stamped with its owner; a spoofed owner_id is ignored",
         %{user_a: a, user_b: b} do
      doc = create!(%{"title" => "pat-write", "owner_id" => b}, pat_opts(a))
      assert Repo.get!(Document, doc.id).owner_id == a
    end

    test "a service token (no user) still sees every member's rows", %{user_b: b} do
      b_doc = create!(%{"title" => "b-only"}, user_opts(b))
      assert {:ok, _} = get(b_doc, service_opts())
    end
  end

  describe "2. updates keep the stored owner (no claim-on-edit)" do
    test "a member editing the shared unowned base leaves it unowned and visible to all",
         %{user_a: a, user_b: b} do
      shared = create!(%{"title" => "base"}, service_opts())

      upsert!(%{"doc_id" => shared.doc_id, "title" => "edited by a"}, user_opts(a))

      assert Repo.get!(Document, shared.id).owner_id == nil
      assert {:ok, %{title: "edited by a"}} = get(shared, user_opts(b))
    end

    test "an owner editing its own row keeps it", %{user_a: a} do
      mine = create!(%{"title" => "mine"}, user_opts(a))
      upsert!(%{"doc_id" => mine.doc_id, "title" => "mine, edited"}, user_opts(a))
      assert Repo.get!(Document, mine.id).owner_id == a
    end
  end

  describe "3. a signed-in user with no context is that user, not anonymous" do
    test "from_conn on assigns carrying current_user builds a user context", %{user_a: a} do
      ctx = CallerContext.from_conn(%{assigns: %{current_user: %Barkpark.Accounts.User{id: a}}})
      assert ctx.principal_type == :user
      assert ctx.user_id == a
    end
  end

  describe "4. history follows the owner rule" do
    setup %{user_a: a} do
      doc = create!(%{"title" => "v1"}, user_opts(a))
      upsert!(%{"doc_id" => doc.doc_id, "title" => "v2"}, user_opts(a))
      [rev | _] = Revisions.list_revisions(doc.doc_id, @owned_type, @dataset, user_opts(a))
      %{doc: doc, rev: rev}
    end

    test "another member cannot list, read or restore the owner's revisions",
         %{doc: doc, rev: rev, user_b: b} do
      assert Revisions.list_revisions(doc.doc_id, @owned_type, @dataset, user_opts(b)) == []
      assert {:error, :not_found} = Revisions.get_revision(rev.id, @dataset, user_opts(b))

      assert {:error, :not_found} =
               Revisions.restore_revision(
                 rev.id,
                 @owned_type,
                 @dataset,
                 [instance_wide: true] ++ user_opts(b)
               )
    end

    test "the owner and an admin still can", %{doc: doc, rev: rev, user_a: a} do
      assert [_ | _] = Revisions.list_revisions(doc.doc_id, @owned_type, @dataset, user_opts(a))
      assert {:ok, _} = Revisions.get_revision(rev.id, @dataset, user_opts(a))
      assert {:ok, _} = Revisions.get_revision(rev.id, @dataset, admin_opts())
    end
  end
end
