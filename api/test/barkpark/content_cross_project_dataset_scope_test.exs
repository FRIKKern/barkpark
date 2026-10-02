defmodule Barkpark.ContentCrossProjectDatasetScopeTest do
  @moduledoc """
  barkpark-9y0w: datasets are PROJECT-owned, so the slug `"production"` is NOT
  globally unique — `project A`'s `production` and `project B`'s `production`
  are DIFFERENT datasets (distinct `dataset_id`) that share the STRING.

  Before the fix, the residual analytics / export / revision reads filtered by
  the bare `dataset == ^dataset` STRING with no dataset_id/project qualifier, so
  a read of A's `production` CONFLATED B's same-named dataset into the result.
  After the fix each read resolves the dataset STRING → the CURRENT project's
  `dataset_id` and filters on that, so A's read excludes B's rows.

  This proves the headline functions on a representative spread —
  `document_stats`, `total_documents`, `recent_activity`, `export_stream`,
  `list_revisions`. `reference_title`, `allowed_origins_for_dataset`,
  `schema_hash_for_dataset` are fixed the SAME way (resolve_read_dataset_id →
  `scope_to_dataset` dataset_id filter, STRING fallback when unresolved).
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.{Labels, TagDistribution}
  alias Barkpark.{Content, Repo}

  @ds "production"

  # Two projects in ONE workspace, each owning a `"production"` dataset with
  # distinct docs. Returns {scope_a, scope_b}.
  #
  # ONE workspace, deliberately (task-5c1a72db61078040). The prior shape put the
  # two projects in two WORKSPACES, which let `scope_to_workspace_or_global/3`
  # drop B's rows before the dataset filter was ever the discriminator — the
  # fixture could not tell a dataset_id-scoped read from a bare-string one.
  # Same workspace, different projects is the shape the dataset scope actually
  # has to survive.
  defp two_projects_with_production do
    ws = create_workspace!()
    proj_a = create_project!(ws)
    proj_b = create_project!(ws)

    scope_a = [workspace_id: ws.id, project_id: proj_a.id]
    scope_b = [workspace_id: ws.id, project_id: proj_b.id]

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "a-only", "title" => "A1"}, @ds, scope_a)

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "a-two", "title" => "A2"}, @ds, scope_a)

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "b-only", "title" => "B1"}, @ds, scope_b)

    {:ok, _} =
      Content.create_document("note", %{"doc_id" => "b-two", "title" => "B2"}, @ds, scope_b)

    {:ok, _} =
      Content.create_document("note", %{"doc_id" => "b-three", "title" => "B3"}, @ds, scope_b)

    {scope_a, scope_b}
  end

  test "total_documents for A's production counts ONLY A's docs, not B's same-named dataset" do
    {scope_a, scope_b} = two_projects_with_production()

    # A wrote 2 docs, B wrote 3 — all in the STRING "production". A's scoped
    # count is 2 (would be 5 under the old bare-string conflation).
    assert Content.total_documents(@ds, scope_a) == 2
    assert Content.total_documents(@ds, scope_b) == 3
  end

  test "document_stats for A's production groups ONLY A's types, not B's" do
    {scope_a, scope_b} = two_projects_with_production()

    a_types = Content.document_stats(@ds, scope_a) |> Enum.map(& &1.type) |> Enum.sort()
    b_types = Content.document_stats(@ds, scope_b) |> Enum.map(& &1.type) |> Enum.sort()

    # A only ever wrote "post"; B wrote "post" + "note". A's stats must NOT leak
    # B's "note" group (which it would under the bare-string read).
    assert a_types == ["post"]
    assert b_types == ["note", "post"]
  end

  test "recent_activity for A's production returns ONLY A's mutation events" do
    {scope_a, scope_b} = two_projects_with_production()

    a_ids = Content.recent_activity(@ds, scope_a) |> Enum.map(& &1.doc_id) |> MapSet.new()
    b_ids = Content.recent_activity(@ds, scope_b) |> Enum.map(& &1.doc_id) |> MapSet.new()

    assert MapSet.member?(a_ids, "drafts.a-only")
    assert MapSet.member?(a_ids, "drafts.a-two")
    refute MapSet.member?(a_ids, "drafts.b-only")
    refute MapSet.member?(a_ids, "drafts.b-two")

    # And the mirror: B's read excludes A's events.
    refute MapSet.member?(b_ids, "drafts.a-only")
    assert MapSet.member?(b_ids, "drafts.b-only")
  end

  test "export_stream for A's production yields ONLY A's documents" do
    {scope_a, scope_b} = two_projects_with_production()

    # export_stream uses Repo.stream — must be reduced inside a transaction.
    a_ids =
      Repo.transaction(fn ->
        Content.export_stream(@ds, scope_a) |> Enum.map(& &1["_id"])
      end)
      |> elem(1)
      |> MapSet.new()

    assert MapSet.member?(a_ids, "drafts.a-only")
    assert MapSet.member?(a_ids, "drafts.a-two")
    refute MapSet.member?(a_ids, "drafts.b-only")
    refute MapSet.member?(a_ids, "drafts.b-two")

    # B's export, scoped to B's production, has exactly its three docs and none
    # of A's — no conflation either direction.
    b_count =
      Repo.transaction(fn -> Content.export_stream(@ds, scope_b) |> Enum.to_list() end)
      |> elem(1)
      |> length()

    assert b_count == 3
  end

  test "list_revisions for A's production returns ONLY A's revisions" do
    {scope_a, scope_b} = two_projects_with_production()

    # Both projects have a `post` "shared-rev" doc in "production" — a write
    # records a revision per project, scoped by dataset_id.
    {:ok, _} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "shared-rev", "title" => "A-rev"},
        @ds,
        scope_a
      )

    {:ok, _} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "shared-rev", "title" => "B-rev"},
        @ds,
        scope_b
      )

    a_revs = Content.list_revisions("shared-rev", "post", @ds, scope_a)
    b_revs = Content.list_revisions("shared-rev", "post", @ds, scope_b)

    # Same doc_id + type + dataset STRING in both projects. The bare-string read
    # would surface BOTH revisions under either scope. Scoped by dataset_id, A
    # sees only its "A-rev" title and B only its "B-rev".
    a_titles = a_revs |> Enum.map(& &1.title) |> Enum.uniq()
    b_titles = b_revs |> Enum.map(& &1.title) |> Enum.uniq()

    assert a_titles == ["A-rev"]
    assert b_titles == ["B-rev"]
  end

  # ── The project-PINNED, workspace-unpinned read ─────────────────────────────
  #
  # The arms above pass BOTH `:workspace_id` and `:project_id`, and under that
  # shape `Scope.scope_to_workspace/3` appends `x.project_id == ^project_id` —
  # which ALREADY excludes the other project's rows on its own. So those arms
  # cannot tell whether the dataset filter discriminates: delete the whole
  # `is_nil(x.dataset_id) and` guard from `scope_to_dataset/3` and they stay
  # green, because project_id, not the dataset clause, is doing the work.
  #
  # `Scope.scope_to_workspace_or_global(query, nil, project_id)` matches its
  # FIRST clause on the nil workspace and returns the query UNTOUCHED — the
  # `project_id` argument is discarded. A read that pins a project but no
  # workspace (`BarkparkWeb.Plugs.DatasetCors` builds exactly `[project_id: id]`)
  # therefore has NOTHING but `scope_to_dataset/3` between it and every other
  # project's same-named dataset. These arms drive that shape, so the dataset
  # filter is the only discriminator left and a mutation to it REDS.
  #
  # Asserted as ABSENCE of a uniquely-suffixed foreign doc_id, never as a count:
  # a project-pinned read is globally unscoped, so the shared test database's
  # other rows are in the result set by construction and a count would flap.
  defp pinned_pair do
    n = System.unique_integer([:positive])
    ws = create_workspace!()
    proj_a = create_project!(ws)
    proj_b = create_project!(ws)

    {[workspace_id: ws.id, project_id: proj_a.id], [workspace_id: ws.id, project_id: proj_b.id],
     [project_id: proj_a.id], n}
  end

  test "query.ex scope_to_dataset/3: a project-pinned list excludes the sibling project's rows" do
    {scope_a, scope_b, pinned_a, n} = pinned_pair()

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "xp-a-#{n}", "title" => "A"}, @ds, scope_a)

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "xp-b-#{n}", "title" => "B"}, @ds, scope_b)

    ids = Content.list_documents("post", @ds, pinned_a) |> Enum.map(& &1.doc_id) |> MapSet.new()

    assert MapSet.member?(ids, "drafts.xp-a-#{n}")
    refute MapSet.member?(ids, "drafts.xp-b-#{n}")
  end

  test "analytics.ex: a project-pinned recent_activity excludes the sibling project's events" do
    {scope_a, scope_b, pinned_a, n} = pinned_pair()

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "an-a-#{n}", "title" => "A"}, @ds, scope_a)

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "an-b-#{n}", "title" => "B"}, @ds, scope_b)

    ids =
      Content.recent_activity(@ds, Keyword.put(pinned_a, :limit, 500))
      |> Enum.map(& &1.doc_id)
      |> MapSet.new()

    refute MapSet.member?(ids, "drafts.an-b-#{n}")
  end

  test "export.ex: a project-pinned export_stream excludes the sibling project's documents" do
    {scope_a, scope_b, pinned_a, n} = pinned_pair()

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "ex-a-#{n}", "title" => "A"}, @ds, scope_a)

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "ex-b-#{n}", "title" => "B"}, @ds, scope_b)

    ids =
      Repo.transaction(fn ->
        Content.export_stream(@ds, pinned_a) |> Enum.map(& &1["_id"])
      end)
      |> elem(1)
      |> MapSet.new()

    assert MapSet.member?(ids, "drafts.ex-a-#{n}")
    refute MapSet.member?(ids, "drafts.ex-b-#{n}")
  end

  test "revisions.ex: a project-pinned list_revisions excludes the sibling project's revisions" do
    {scope_a, scope_b, pinned_a, n} = pinned_pair()
    doc_id = "rev-shared-#{n}"

    {:ok, _} =
      Content.upsert_document("post", %{"doc_id" => doc_id, "title" => "A-rev"}, @ds, scope_a)

    {:ok, _} =
      Content.upsert_document("post", %{"doc_id" => doc_id, "title" => "B-rev"}, @ds, scope_b)

    titles =
      Content.list_revisions(doc_id, "post", @ds, pinned_a)
      |> Enum.map(& &1.title)
      |> Enum.uniq()

    assert titles == ["A-rev"]
  end

  test "labels.ex: a project-pinned reference_title never resolves the sibling project's title" do
    {scope_a, scope_b, pinned_a, n} = pinned_pair()
    doc_id = "lab-#{n}"

    # A must own a row in "production" first, so the dataset STRING RESOLVES to
    # A's dataset_id. Without it `resolve_read_dataset_id/2` returns nil and
    # `scope_to_dataset/3` takes its STRING-fallback arm, which is globally
    # unscoped on this pinned-without-workspace shape — and B's title comes back
    # on TODAY'S code (measured, see the PR body). That fallback is a DIFFERENT
    # defect from the guard this test covers; keeping it out of the frame is
    # what lets this arm measure the guard.
    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "lab-a-#{n}", "title" => "A"}, @ds, scope_a)

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => doc_id, "title" => "B-TITLE"}, @ds, scope_b)

    # Only B holds the referenced row. A's pinned read must degrade to the raw
    # id, never surface B's title.
    assert Labels.reference_title(doc_id, "post", @ds, pinned_a) == doc_id
  end

  test "tag_distribution.ex: a project-pinned per_type excludes the sibling project's tags" do
    {scope_a, scope_b, pinned_a, n} = pinned_pair()
    tag = "xproj-tag-#{n}"
    doc_id = "tag-b-#{n}"

    # Same reason as the labels arm: A owns a row so its "production" RESOLVES.
    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "tag-a-#{n}", "title" => "A"}, @ds, scope_a)

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => "B", "tags" => [tag]},
        @ds,
        scope_b
      )

    {:ok, _} = Content.publish_document(doc_id, "post", @ds, scope_b)

    tags = TagDistribution.per_type("post", @ds, pinned_a) |> Enum.map(& &1.tag)

    refute tag in tags
  end
end
