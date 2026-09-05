defmodule Barkpark.ContentMutateScopeLeakTest do
  @moduledoc """
  Negative cross-workspace LEAK guards for the mutate + reference + media-delete
  read paths (barkpark-s6t1 root-cause fail-closed + barkpark-af50 threaded
  scope).

  The shared root: a tenant-scoped read that drops its `:workspace_id` used to
  resolve over EVERY tenant's rows (fail-OPEN). Now `scope_to_workspace/3` fails
  CLOSED on nil, and the mutate inner reads (publish / unpublish / delete /
  block-op), `reference_title`, and the flat media DELETE all THREAD the
  caller's scope into the read. These tests prove a member of workspace B
  cannot publish / unpublish / delete / reference-resolve / media-delete a
  same-id artifact owned by workspace A.

  Same `dataset` + same `doc_id`/`slug` in BOTH workspaces — isolation must come
  from workspace_id, never from the dataset string or the id alone.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @type_name "post"
  @shared_dataset "test"
  @doc_id "shared-id"

  defp make_scope(ws_slug, project_slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: ws_slug, name: ws_slug})
    {:ok, project} = Tenancy.create_project(ws, %{slug: project_slug, name: project_slug})
    {ws, project}
  end

  # Create a DRAFT doc with the given doc_id in the given workspace.
  defp create_draft(doc_id, title, ws, proj) do
    {:ok, doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => doc_id, "title" => title, "status" => "draft"},
        @shared_dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    doc
  end

  describe "publish_document cross-workspace leak guard" do
    setup do
      {ws_a, proj_a} = make_scope("pub-a", "pp-a")
      {ws_b, proj_b} = make_scope("pub-b", "pp-b")
      # A's draft and B's draft share the SAME doc_id.
      _draft_a = create_draft(@doc_id, "A's draft", ws_a, proj_a)
      _draft_b = create_draft(@doc_id, "B's draft", ws_b, proj_b)
      %{ws_a: ws_a, ws_b: ws_b}
    end

    test "B publishing the shared id only consumes B's draft; A's draft is untouched", %{
      ws_a: ws_a,
      ws_b: ws_b
    } do
      # B publishing the shared id, scoped to B, only touches B's draft — and
      # critically NEVER resolves A's draft.
      assert {:ok, pub_b} =
               Content.publish_document(@doc_id, @type_name, @shared_dataset,
                 workspace_id: ws_b.id
               )

      assert pub_b.workspace_id == ws_b.id
      assert pub_b.title == "B's draft"

      # A's draft must still exist (was never published/consumed by B's op).
      assert {:ok, %{status: "draft", title: "A's draft"}} =
               Content.get_document("drafts.#{@doc_id}", @type_name, @shared_dataset,
                 workspace_id: ws_a.id
               )
    end

    test "publishing scoped to A only resolves A's draft, not B's", %{ws_a: ws_a, ws_b: ws_b} do
      assert {:ok, pub_a} =
               Content.publish_document(@doc_id, @type_name, @shared_dataset,
                 workspace_id: ws_a.id
               )

      assert pub_a.workspace_id == ws_a.id
      assert pub_a.title == "A's draft"

      # B's draft is untouched — still a draft in B.
      assert {:ok, %{status: "draft", title: "B's draft"}} =
               Content.get_document("drafts.#{@doc_id}", @type_name, @shared_dataset,
                 workspace_id: ws_b.id
               )
    end
  end

  describe "delete_document cross-workspace leak guard" do
    setup do
      {ws_a, proj_a} = make_scope("del-a", "dp-a")
      {ws_b, proj_b} = make_scope("del-b", "dp-b")
      _a = create_draft(@doc_id, "A's doc", ws_a, proj_a)
      _b = create_draft(@doc_id, "B's doc", ws_b, proj_b)
      %{ws_a: ws_a, ws_b: ws_b}
    end

    test "delete scoped to B returns not_found for A-only id and never deletes A's doc", %{
      ws_a: ws_a,
      ws_b: ws_b
    } do
      # First delete B's own copy (legit).
      assert {:ok, _} =
               Content.delete_document(@doc_id, @type_name, @shared_dataset,
                 workspace_id: ws_b.id
               )

      # Now the id exists ONLY in A. A delete scoped to B must NOT find or
      # delete A's doc — fail-closed-on-foreign-id.
      assert {:error, :not_found} =
               Content.delete_document(@doc_id, @type_name, @shared_dataset,
                 workspace_id: ws_b.id
               )

      # A's doc is still present.
      assert {:ok, %{title: "A's doc"}} =
               Content.get_document("drafts.#{@doc_id}", @type_name, @shared_dataset,
                 workspace_id: ws_a.id
               )
    end

    test "delete scoped to A removes A's doc only", %{ws_a: ws_a, ws_b: ws_b} do
      assert {:ok, _} =
               Content.delete_document(@doc_id, @type_name, @shared_dataset,
                 workspace_id: ws_a.id
               )

      assert {:error, :not_found} =
               Content.get_document("drafts.#{@doc_id}", @type_name, @shared_dataset,
                 workspace_id: ws_a.id
               )

      # B's same-id doc survives.
      assert {:ok, %{title: "B's doc"}} =
               Content.get_document("drafts.#{@doc_id}", @type_name, @shared_dataset,
                 workspace_id: ws_b.id
               )
    end
  end

  describe "unpublish_document cross-workspace leak guard" do
    setup do
      {ws_a, proj_a} = make_scope("unp-a", "up-a")
      {ws_b, _proj_b} = make_scope("unp-b", "up-b")
      _a = create_draft(@doc_id, "A's draft", ws_a, proj_a)

      {:ok, _} =
        Content.publish_document(@doc_id, @type_name, @shared_dataset, workspace_id: ws_a.id)

      %{ws_a: ws_a, ws_b: ws_b}
    end

    test "unpublish scoped to B cannot touch A's published doc", %{ws_a: ws_a, ws_b: ws_b} do
      # B has no published doc with this id → not_found, A untouched.
      assert {:error, :not_found} =
               Content.unpublish_document(@doc_id, @type_name, @shared_dataset,
                 workspace_id: ws_b.id
               )

      # A's published doc still published.
      assert {:ok, %{status: "published"}} =
               Content.get_document(@doc_id, @type_name, @shared_dataset, workspace_id: ws_a.id)
    end

    test "unpublish scoped to A moves A's doc back to draft", %{ws_a: ws_a} do
      assert {:ok, draft} =
               Content.unpublish_document(@doc_id, @type_name, @shared_dataset,
                 workspace_id: ws_a.id
               )

      assert draft.status == "draft"
      assert draft.workspace_id == ws_a.id
    end
  end

  describe "reference_title cross-workspace leak guard" do
    setup do
      {ws_a, proj_a} = make_scope("ref-a", "rp-a")
      {ws_b, proj_b} = make_scope("ref-b", "rp-b")

      # Same doc_id, DIFFERENT titles, in each workspace.
      {:ok, _} =
        Content.create_document(
          @type_name,
          %{"doc_id" => @doc_id, "title" => "Title in A", "status" => "published"},
          @shared_dataset,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      {:ok, _} =
        Content.create_document(
          @type_name,
          %{"doc_id" => @doc_id, "title" => "Title in B", "status" => "published"},
          @shared_dataset,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      %{ws_a: ws_a, ws_b: ws_b}
    end

    test "reference_title scoped to A resolves A's title, never B's", %{ws_a: ws_a} do
      assert Content.reference_title(@doc_id, @type_name, @shared_dataset, workspace_id: ws_a.id) ==
               "Title in A"
    end

    test "reference_title scoped to B resolves B's title", %{ws_b: ws_b} do
      assert Content.reference_title(@doc_id, @type_name, @shared_dataset, workspace_id: ws_b.id) ==
               "Title in B"
    end
  end

  describe "flat media delete cross-workspace leak guard" do
    defp insert_media(name, ws, proj) do
      %MediaFile{}
      |> MediaFile.changeset(%{
        filename: name,
        original_name: name,
        path: "uploads/#{@shared_dataset}/#{name}",
        mime_type: "image/png",
        size: 7,
        dataset: @shared_dataset,
        workspace_id: ws.id,
        project_id: proj.id
      })
      |> Repo.insert!()
    end

    setup do
      {ws_a, proj_a} = make_scope("mdel-a", "mdp-a")
      {ws_b, _proj_b} = make_scope("mdel-b", "mdp-b")
      file_a = insert_media("a-only.png", ws_a, proj_a)
      %{ws_a: ws_a, ws_b: ws_b, file_a: file_a}
    end

    test "delete_file scoped to B cannot delete A's blob", %{
      ws_a: ws_a,
      ws_b: ws_b,
      file_a: file_a
    } do
      assert {:error, :not_found} =
               Media.delete_file(file_a.id, workspace_id: ws_b.id, where_used: :cascade)

      # A's blob row survives.
      assert {:ok, _} = Media.get_file(file_a.id, workspace_id: ws_a.id)
    end

    test "delete_file scoped to A deletes A's own blob", %{ws_a: ws_a, file_a: file_a} do
      assert {:ok, _} = Media.delete_file(file_a.id, workspace_id: ws_a.id, where_used: :cascade)
      assert {:error, :not_found} = Media.get_file(file_a.id, workspace_id: ws_a.id)
    end
  end

  describe "scope_to_workspace fails CLOSED on nil (s6t1 root cause)" do
    test "a deliberately nil-scoped scope_to_workspace yields ZERO rows, not all rows" do
      import Ecto.Query
      alias Barkpark.Content.Scope
      alias Barkpark.Content.Document

      {ws, proj} = make_scope("closed-a", "cp-a")

      {:ok, _} =
        Content.create_document(
          @type_name,
          %{"doc_id" => "closed-doc", "title" => "Closed"},
          @shared_dataset,
          workspace_id: ws.id,
          project_id: proj.id
        )

      # nil → where(false) → empty result even though a matching row exists.
      closed =
        Document
        |> where([d], d.dataset == ^@shared_dataset)
        |> Scope.scope_to_workspace(nil, nil)
        |> Repo.all()

      assert closed == []

      # The EXPLICIT global opt-in returns rows (proves the data was there).
      globalled =
        Document
        |> where([d], d.dataset == ^@shared_dataset)
        |> Scope.scope_to_workspace_global()
        |> Repo.all()

      assert Enum.any?(globalled, &(&1.doc_id == "drafts.closed-doc"))
    end
  end
end
