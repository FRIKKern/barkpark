defmodule Barkpark.ContentProjectPinnedNilWorkspaceScopeTest do
  @moduledoc """
  task-ab5da5c4faf1a04c: the PROJECT-PINNED, WORKSPACE-UNPINNED scope.

  `BarkparkWeb.Plugs.DatasetCors.cors_scope/1` builds `[project_id: id]` with
  NO `:workspace_id` — a real, routed request shape, not a synthetic one. Two
  things went wrong for that shape and this file reds both:

    1. `Scope.scope_to_workspace_or_global(q, nil, project_id)` matched its
       nil-workspace clause and returned the query UNTOUCHED, DISCARDING the
       project_id. Every tenancy-scoped read reached through that helper with
       a project and no workspace therefore carried NO tenancy clause at all.

    2. `Schema.allowed_origins_for_dataset/2` — the read
       `DatasetCors` actually performs — applied `scope_to_dataset/3` and no
       workspace/project scope WHATSOEVER. Its sibling
       `schema_hash_for_dataset/2` in the same module already applied both.

  With no tenancy clause left, the dataset STRING is the only discriminator,
  and `scope_to_dataset/3` falls back to a bare `x.dataset == ^dataset` match
  whenever the string resolves to no `dataset_id` in the caller's project —
  which is exactly the case when the caller's project owns no dataset row of
  that name. A sibling project's same-named dataset then answers the read.

  Counts are useless here: the test database is shared with other suites. Every
  assertion below is the ABSENCE of a uniquely-suffixed foreign id/origin.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Related, WriteScope}
  alias Barkpark.{Repo, Tenancy}

  # A dataset name owned by project B alone. Unique per run so no other suite's
  # rows can satisfy or defeat the assertions.
  defp b_only_dataset, do: "bonly-#{System.unique_integer([:positive])}"

  defp two_projects do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)
    {proj_a, proj_b, ws_b}
  end

  test "a project-pinned, workspace-unpinned document read does not return a sibling project's rows" do
    {proj_a, proj_b, ws_b} = two_projects()
    ds = b_only_dataset()
    foreign_id = "bdoc-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => foreign_id, "title" => "B-TITLE"},
        ds,
        workspace_id: ws_b.id,
        project_id: proj_b.id
      )

    # THE SHAPE UNDER TEST: project_id present, workspace_id absent. Project A
    # owns no dataset row named `ds`, so scope_to_dataset/3 takes its bare
    # STRING fallback and B's row is the only string match in the corpus.
    a_scope = [project_id: proj_a.id]

    a_ids =
      Content.list_documents("post", ds, a_scope)
      |> Enum.map(& &1.doc_id)
      |> MapSet.new()

    refute Enum.any?(a_ids, &String.contains?(&1, foreign_id)),
           "project A's project-pinned read returned project B's document #{foreign_id}"

    # CONTROL: B's own fully-pinned read DOES see it — proving the row exists
    # and the assertion above is not vacuous.
    b_ids =
      Content.list_documents("post", ds, workspace_id: ws_b.id, project_id: proj_b.id)
      |> Enum.map(& &1.doc_id)
      |> MapSet.new()

    assert Enum.any?(b_ids, &String.contains?(&1, foreign_id)),
           "control failed: project B cannot see its own document #{foreign_id}"
  end

  test "allowed_origins_for_dataset/2 with a project-pinned, workspace-unpinned scope does not return a sibling project's origins" do
    {proj_a, proj_b, ws_b} = two_projects()
    ds = b_only_dataset()
    foreign_origin = "https://borigin-#{System.unique_integer([:positive])}.example"

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "cors_origins" => [foreign_origin]},
        ds,
        workspace_id: ws_b.id,
        project_id: proj_b.id
      )

    # The exact call DatasetCors makes: Content.allowed_origins_for_dataset(ds,
    # [project_id: <caller project>]).
    a_origins = Content.allowed_origins_for_dataset(ds, project_id: proj_a.id)

    refute foreign_origin in a_origins,
           "project A's CORS allowlist for #{ds} leaked project B's origin #{foreign_origin}"

    # CONTROL: B's own scope DOES see it.
    b_origins =
      Content.allowed_origins_for_dataset(ds, workspace_id: ws_b.id, project_id: proj_b.id)

    assert foreign_origin in b_origins,
           "control failed: project B cannot see its own CORS origin"
  end

  test "an opts-less (fully unscoped) internal read still reads globally" do
    # The nil/nil arm is the DELIBERATE global read named in Scope's docs. The
    # project clause must not be applied when there is no project either — this
    # test reds if the fix narrows the wrong arm.
    ds = b_only_dataset()
    origin = "https://global-#{System.unique_integer([:positive])}.example"
    ws = create_workspace!()
    proj = create_project!(ws)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "cors_origins" => [origin]},
        ds,
        workspace_id: ws.id,
        project_id: proj.id
      )

    assert origin in Content.allowed_origins_for_dataset(ds)
  end

  # ── The `is_nil(dataset_id) and` guard (criterion 2) ────────────────────────
  #
  # `scope_to_dataset/3` matches `dataset_id == ^id OR (is_nil(dataset_id) AND
  # dataset == ^dataset)`. The `is_nil(dataset_id) and` conjunct is the whole
  # fence on the second disjunct: without it a row STAMPED with a DIFFERENT
  # project's dataset_id matches by STRING alone.
  #
  # It is observable exactly where no tenancy clause survives to cover for it —
  # the FLAT, opts-less back-compat read, which resolves the dataset through
  # the seeded Default project and applies `scope_to_workspace_or_global(q,
  # nil, nil)` = untouched. Both arms below drop the conjunct if mutated and go
  # red; neither is a synthetic shape (the flat read is every pre-tenancy
  # route and every internal caller that passes no opts).
  defp default_and_foreign_dataset do
    {def_ws, def_proj} = ensure_default_scope!()
    ds = b_only_dataset()

    # Minting a document through the facade is what CREATES the project's
    # dataset row, so each project ends up owning its own `ds` with a distinct
    # dataset_id — the 1:1 string↔id pair the guard depends on.
    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "seed-#{ds}"}, ds,
        workspace_id: def_ws.id,
        project_id: def_proj.id
      )

    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "seed-b-#{ds}"}, ds,
        workspace_id: ws_b.id,
        project_id: proj_b.id
      )

    %Tenancy.Dataset{id: default_ds_id} = Tenancy.get_dataset(def_proj.id, ds)
    %Tenancy.Dataset{id: foreign_ds_id} = Tenancy.get_dataset(proj_b.id, ds)
    assert default_ds_id != foreign_ds_id

    %{
      ds: ds,
      def_ws: def_ws,
      def_proj: def_proj,
      default_ds_id: default_ds_id,
      ws_b: ws_b,
      proj_b: proj_b,
      foreign_ds_id: foreign_ds_id
    }
  end

  test "write_scope.ex scope_to_dataset/3: a flat read never string-matches a FOREIGN project's stamped row" do
    f = default_and_foreign_dataset()
    foreign_id = "wsfar-#{System.unique_integer([:positive])}"

    Repo.insert!(%Document{
      doc_id: foreign_id,
      type: "post",
      dataset: f.ds,
      title: "foreign",
      status: "published",
      content: %{},
      rev: Barkpark.Content.Writer.generate_rev(),
      workspace_id: f.ws_b.id,
      project_id: f.proj_b.id,
      dataset_id: f.foreign_ds_id
    })

    mine_id = "wsmine-#{System.unique_integer([:positive])}"

    Repo.insert!(%Document{
      doc_id: mine_id,
      type: "post",
      dataset: f.ds,
      title: "mine",
      status: "published",
      content: %{},
      rev: Barkpark.Content.Writer.generate_rev(),
      workspace_id: f.def_ws.id,
      project_id: f.def_proj.id,
      dataset_id: f.default_ds_id
    })

    ids =
      Document
      |> WriteScope.scope_to_dataset(f.ds, [])
      |> Repo.all()
      |> Enum.map(& &1.doc_id)
      |> MapSet.new()

    # CONTROL: the Default project's own stamped row IS returned, so the
    # absence below is a fence, not an empty query.
    assert MapSet.member?(ids, mine_id)

    refute MapSet.member?(ids, foreign_id),
           "WriteScope.scope_to_dataset/3 string-matched a foreign project's stamped row #{foreign_id}"
  end

  test "related.ex scope_to_dataset/3: a flat related read never string-matches a FOREIGN project's stamped row" do
    f = default_and_foreign_dataset()

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "fields" => []},
        f.ds,
        workspace_id: f.def_ws.id,
        project_id: f.def_proj.id
      )

    tagged = fn tag, strength ->
      %{"tags" => [%{"tag" => tag, "strength" => strength, "rationale" => "r"}]}
    end

    src_id = "relsrc-#{System.unique_integer([:positive])}"
    mine_id = "relmine-#{System.unique_integer([:positive])}"
    foreign_id = "relfar-#{System.unique_integer([:positive])}"

    Repo.insert!(%Document{
      doc_id: src_id,
      type: "post",
      dataset: f.ds,
      title: "Source",
      status: "published",
      content: tagged.("elixir", 80),
      rev: Barkpark.Content.Writer.generate_rev(),
      workspace_id: f.def_ws.id,
      project_id: f.def_proj.id,
      dataset_id: f.default_ds_id
    })

    Repo.insert!(%Document{
      doc_id: mine_id,
      type: "post",
      dataset: f.ds,
      title: "Mine",
      status: "published",
      content: tagged.("elixir", 50),
      rev: Barkpark.Content.Writer.generate_rev(),
      workspace_id: f.def_ws.id,
      project_id: f.def_proj.id,
      dataset_id: f.default_ds_id
    })

    Repo.insert!(%Document{
      doc_id: foreign_id,
      type: "post",
      dataset: f.ds,
      title: "Foreign",
      status: "published",
      content: tagged.("elixir", 90),
      rev: Barkpark.Content.Writer.generate_rev(),
      workspace_id: f.ws_b.id,
      project_id: f.proj_b.id,
      dataset_id: f.foreign_ds_id
    })

    ids = Related.related_documents(src_id, f.ds, []) |> Enum.map(& &1.doc_id) |> MapSet.new()

    # CONTROL: the same-dataset sibling IS related, so the absence below is a
    # fence and not an empty result.
    assert MapSet.member?(ids, mine_id)

    refute MapSet.member?(ids, foreign_id),
           "Related's scope_to_dataset/3 string-matched a foreign project's stamped row #{foreign_id}"
  end
end
