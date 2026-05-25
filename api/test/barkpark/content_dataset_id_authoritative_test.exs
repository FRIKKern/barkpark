defmodule Barkpark.ContentDatasetIdAuthoritativeTest do
  @moduledoc """
  W2 (barkpark-w16c): `dataset_id` is the authoritative scoping key — dual-write
  + uniqueness-flip + read-scope, with the `dataset` STRING kept as a mirror.

  Two proofs:

    1. THE LIFTED LIMIT. The old global `(doc_id, type, dataset)` unique index
       made the `dataset` STRING shared across workspaces, so two workspaces
       could NEVER each own a document with the same `doc_id` + `type`. The flip
       to `(doc_id, type, dataset_id)` — where `dataset_id` is project- (and
       thus workspace-) scoped — lets them coexist. This is the headline win.

    2. READ-SCOPE + MIRROR CONSISTENCY. A read that resolves the incoming
       dataset STRING → dataset_id returns the right rows, and every write keeps
       the `dataset` STRING mirror consistent with the stamped `dataset_id`.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Repo, Tenancy}
  alias Barkpark.Content.Document

  describe "lifted cross-workspace doc_id limit (the W2 win)" do
    test "two workspaces each own a document with the SAME doc_id + type (different dataset_id)" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      # SAME doc_id + type + dataset STRING in both workspaces. Under the old
      # global (doc_id, type, dataset) unique index the SECOND insert would have
      # fail-closed on the unique constraint. After the flip it succeeds because
      # each project resolves its OWN "test" dataset_id.
      {:ok, doc_a} =
        create_document_in!(ws_a, proj_a, "post", %{"doc_id" => "shared-id"}, "test")

      {:ok, doc_b} =
        create_document_in!(ws_b, proj_b, "post", %{"doc_id" => "shared-id"}, "test")

      # Both rows exist and are distinct.
      assert doc_a.id != doc_b.id
      assert doc_a.doc_id == doc_b.doc_id
      assert doc_a.type == doc_b.type
      assert doc_a.dataset == doc_b.dataset

      # The discriminator that lets them coexist: distinct, non-nil dataset_id,
      # one per project.
      assert is_binary(doc_a.dataset_id)
      assert is_binary(doc_b.dataset_id)
      assert doc_a.dataset_id != doc_b.dataset_id

      # And both are still in the DB (the second insert did NOT overwrite the
      # first via a shared unique-constraint upsert).
      assert Repo.aggregate(
               from(d in Document, where: d.doc_id == "drafts.shared-id" and d.type == "post"),
               :count
             ) == 2
    end

    test "two datasets in the SAME project still collide on doc_id+type (per-project isolation holds)" do
      ws = create_workspace!()
      proj = create_project!(ws)
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, _first} =
        Content.create_document("post", %{"doc_id" => "p1", "title" => "x"}, "alpha", scope)

      # Same project, same doc_id + type, DIFFERENT dataset string => different
      # dataset_id => coexists (the dataset is the leaf, just keyed by id now).
      {:ok, second} =
        Content.create_document("post", %{"doc_id" => "p1", "title" => "y"}, "beta", scope)

      assert is_binary(second.dataset_id)

      assert Repo.aggregate(
               from(d in Document, where: d.doc_id == "drafts.p1" and d.type == "post"),
               :count
             ) == 2
    end
  end

  describe "read-scope resolves dataset string -> dataset_id" do
    test "a scoped read returns only the rows for the resolved dataset_id" do
      ws = create_workspace!()
      proj = create_project!(ws)
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, _a} =
        Content.create_document("post", %{"doc_id" => "a", "title" => "A"}, "alpha", scope)

      {:ok, _b} =
        Content.create_document("post", %{"doc_id" => "b", "title" => "B"}, "beta", scope)

      alpha_ids =
        Content.list_documents("post", "alpha", [perspective: :raw] ++ scope)
        |> Enum.map(& &1.doc_id)

      beta_ids =
        Content.list_documents("post", "beta", [perspective: :raw] ++ scope)
        |> Enum.map(& &1.doc_id)

      assert "drafts.a" in alpha_ids
      refute "drafts.b" in alpha_ids
      assert "drafts.b" in beta_ids
      refute "drafts.a" in beta_ids
    end

    test "get_document under the resolved scope finds the row by dataset_id" do
      ws = create_workspace!()
      proj = create_project!(ws)
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, doc} =
        Content.create_document("post", %{"doc_id" => "g1", "title" => "G"}, "gamma", scope)

      assert {:ok, fetched} = Content.get_document("drafts.g1", "post", "gamma", scope)
      assert fetched.id == doc.id
      assert fetched.dataset_id == doc.dataset_id
    end
  end

  describe "the dataset STRING mirror stays consistent with dataset_id on writes" do
    test "create stamps a dataset_id whose dataset row's slug equals the dataset STRING" do
      ws = create_workspace!()
      proj = create_project!(ws)
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, doc} =
        Content.create_document("post", %{"doc_id" => "m1", "title" => "M"}, "mirror_ds", scope)

      # The string is kept...
      assert doc.dataset == "mirror_ds"
      # ...AND the dataset_id points at a dataset row under THIS project whose
      # slug equals the string — the mirror is consistent.
      assert is_binary(doc.dataset_id)
      ds = Tenancy.get_dataset_by_id(doc.dataset_id)
      assert ds.project_id == proj.id
      assert ds.slug == "mirror_ds"
    end

    test "an upsert keeps the string + dataset_id consistent across the update" do
      ws = create_workspace!()
      proj = create_project!(ws)
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, created} =
        Content.upsert_document("doc", %{"doc_id" => "u1", "title" => "first"}, "upd_ds", scope)

      {:ok, updated} =
        Content.upsert_document("doc", %{"doc_id" => "u1", "title" => "second"}, "upd_ds", scope)

      assert updated.id == created.id
      assert updated.title == "second"
      assert updated.dataset == "upd_ds"
      assert updated.dataset_id == created.dataset_id

      ds = Tenancy.get_dataset_by_id(updated.dataset_id)
      assert ds.slug == "upd_ds"
      assert ds.project_id == proj.id
    end
  end
end
