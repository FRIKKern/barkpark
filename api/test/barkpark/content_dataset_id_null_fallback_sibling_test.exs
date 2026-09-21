defmodule Barkpark.ContentDatasetIdNullFallbackSiblingTest do
  @moduledoc """
  task-5c1a72db61078040 — the RED fixture for the `is_nil(x.dataset_id) and`
  sibling in every `scope_to_dataset/3` copy.

  Six modules carry the same two-armed dataset filter:

      x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset)

  The `is_nil(x.dataset_id) and` conjunct is what keeps the legacy-STRING arm
  from re-admitting rows that DO carry a dataset_id — a different one. Delete
  it and the predicate widens to `dataset_id == ^id or dataset == ^dataset`,
  which admits every row whose dataset STRING matches, whatever project owns it.

  ## Why the existing cross-project fixture cannot red it

  `content_cross_project_dataset_scope_test.exs` reads with the FULL scope
  `[workspace_id: …, project_id: …]`. That scope reaches
  `Scope.scope_to_workspace/3`'s two-binary clause, which ANDs
  `workspace_id == ^ws and project_id == ^proj` — a strictly narrower filter
  than the dataset_id one. The foreign rows are already gone before the dataset
  predicate is consulted, so widening it changes nothing and the suite stays
  green under mutation (api-w3, m4..m9).

  Putting both projects in ONE workspace does not lift the shadow either: the
  `project_id` conjunct alone still drops the sibling's rows.

  ## The scope that DOES reach the sibling

  `project_id` WITHOUT `workspace_id`. That opts shape is not exotic — it is
  what every caller that resolved a project but no workspace passes, and it is
  the shape the resolver itself is written for (`resolve_read_dataset_id/2`
  keys on `:project_id` alone). Under it:

    * `resolve_read_dataset_id("production", project_id: A)` → A's dataset_id,
      so the two-armed predicate is live; and
    * `scope_to_workspace_or_global(nil, A)` matches the `(query, nil, _)`
      clause → `scope_to_workspace_global/1` → the query is UNTOUCHED.

  With the tenancy filter absent, the dataset_id conjunct is the SOLE
  discriminator, and deleting `is_nil(x.dataset_id) and` makes each of the six
  reads return project B's rows. Each test below reds when its site's conjunct
  is deleted.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Labels, TagDistribution}
  alias Barkpark.Repo

  # The dataset STRING is unique PER TEST, not the literal "production".
  #
  # The property under test is that TWO PROJECTS SHARE ONE STRING, not what the
  # string says. A literal made these tests read other suites' rows: the second
  # arm of the very predicate being measured — `is_nil(x.dataset_id) and
  # x.dataset == ^dataset` — matches ANY legacy NULL-dataset_id row carrying
  # that string, and because these reads deliberately carry no workspace filter
  # there is nothing left to exclude them. Measured: `total_documents` returned
  # 16 against an expected 1 in the full `test/barkpark/content` run while
  # passing in isolation.
  defp unique_ds, do: "sibling-ds-#{System.unique_integer([:positive])}"

  # ONE workspace, TWO projects, each owning a dataset named "production".
  # Writes go through the real write path with the FULL scope so both projects'
  # rows are stamped with their own dataset_id/workspace_id/project_id.
  #
  # Reads use `read_a` — project_id ONLY — which is the scope shape that leaves
  # the dataset_id predicate unshadowed (see @moduledoc).
  defp two_projects_one_workspace do
    ds = unique_ds()
    ws = create_workspace!()
    proj_a = create_project!(ws)
    proj_b = create_project!(ws)

    full_a = [workspace_id: ws.id, project_id: proj_a.id]
    full_b = [workspace_id: ws.id, project_id: proj_b.id]

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "a-one", "title" => "A1"}, ds, full_a)

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "b-one", "title" => "B1"}, ds, full_b)

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "b-two", "title" => "B2"}, ds, full_b)

    %{
      ds: ds,
      ws: ws,
      proj_a: proj_a,
      proj_b: proj_b,
      full_a: full_a,
      full_b: full_b,
      read_a: [project_id: proj_a.id]
    }
  end

  # Insert a PUBLISHED row stamped with `project`'s "production" dataset_id.
  # `TagDistribution.per_type/3` only counts `status == "published"`, which the
  # draft-producing write path never yields.
  defp seed_published!(ws, project, dataset, doc_id, tags) do
    ds = Barkpark.Tenancy.get_dataset(project.id, dataset)
    refute is_nil(ds), "fixture precondition: #{dataset} must exist under the project"

    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(Document, [
        %{
          doc_id: doc_id,
          type: "post",
          dataset: dataset,
          dataset_id: ds.id,
          workspace_id: ws.id,
          project_id: project.id,
          title: doc_id,
          status: "published",
          content: %{"tags" => tags},
          rev: Barkpark.Content.Writer.generate_rev(),
          inserted_at: now,
          updated_at: now
        }
      ])

    :ok
  end

  # ── Precondition: the fixture really does build two same-named datasets ─────

  test "the two projects own DISTINCT datasets that share the STRING" do
    ctx = two_projects_one_workspace()

    ds_a = Barkpark.Tenancy.get_dataset(ctx.proj_a.id, ctx.ds)
    ds_b = Barkpark.Tenancy.get_dataset(ctx.proj_b.id, ctx.ds)

    refute is_nil(ds_a)
    refute is_nil(ds_b)
    assert ds_a.id != ds_b.id
    assert ctx.proj_a.workspace_id == ctx.proj_b.workspace_id

    # And the read scope really does resolve to A's dataset_id, so the
    # two-armed predicate (not the STRING fallback) is the live branch.
    assert Content.resolve_read_dataset_id(ctx.ds, ctx.read_a) == ds_a.id
  end

  # ── Site 1 — query.ex scope_to_dataset/3 ────────────────────────────────────

  test "query.ex: list_documents under a project-only scope excludes the sibling project's rows" do
    ctx = two_projects_one_workspace()

    ids =
      Content.list_documents("post", ctx.ds, ctx.read_a ++ [perspective: :raw])
      |> Enum.map(& &1.doc_id)
      |> MapSet.new()

    assert MapSet.member?(ids, "drafts.a-one")
    refute MapSet.member?(ids, "drafts.b-one")
    refute MapSet.member?(ids, "drafts.b-two")
  end

  # ── Site 2 — analytics.ex ───────────────────────────────────────────────────

  test "analytics.ex: total_documents/document_stats under a project-only scope count only A" do
    ctx = two_projects_one_workspace()

    assert Content.total_documents(ctx.ds, ctx.read_a) == 1

    totals = Content.document_stats(ctx.ds, ctx.read_a) |> Enum.map(& &1.total) |> Enum.sum()
    assert totals == 1
  end

  # ── Site 3 — export.ex ──────────────────────────────────────────────────────

  test "export.ex: export_stream under a project-only scope yields only A's documents" do
    ctx = two_projects_one_workspace()

    ids =
      Repo.transaction(fn ->
        Content.export_stream(ctx.ds, ctx.read_a) |> Enum.map(& &1["_id"])
      end)
      |> elem(1)
      |> MapSet.new()

    assert MapSet.member?(ids, "drafts.a-one")
    refute MapSet.member?(ids, "drafts.b-one")
    refute MapSet.member?(ids, "drafts.b-two")
  end

  # ── Site 4 — revisions.ex ───────────────────────────────────────────────────

  test "revisions.ex: list_revisions under a project-only scope returns no sibling revisions" do
    ctx = two_projects_one_workspace()

    # Only B ever writes "shared-rev". A's read must therefore be EMPTY; the
    # widened predicate hands it B's revision.
    {:ok, _} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "shared-rev", "title" => "B-rev"},
        ctx.ds,
        ctx.full_b
      )

    assert Content.list_revisions("shared-rev", "post", ctx.ds, ctx.read_a) == []

    # Control: B's own full-scope read DOES see it, so the emptiness above is
    # the dataset filter and not a fixture that wrote nothing.
    assert Content.list_revisions("shared-rev", "post", ctx.ds, ctx.full_b) != []
  end

  # ── Site 5 — labels.ex ──────────────────────────────────────────────────────

  test "labels.ex: reference_title under a project-only scope does not resolve the sibling's doc" do
    ctx = two_projects_one_workspace()

    # Only B holds "sibling-ref". A's resolution must fall back to the raw
    # value; the widened predicate resolves it to B's title instead.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "sibling-ref", "title" => "B-SIBLING-TITLE"},
        ctx.ds,
        ctx.full_b
      )

    assert Labels.reference_title("sibling-ref", "post", ctx.ds, ctx.read_a) == "sibling-ref"

    # Control: with B's own scope the very same call DOES resolve the title.
    assert Labels.reference_title("sibling-ref", "post", ctx.ds, ctx.full_b) == "B-SIBLING-TITLE"
  end

  # ── Site 6 — tag_distribution.ex ────────────────────────────────────────────

  test "tag_distribution.ex: per_type under a project-only scope excludes the sibling's tags" do
    ctx = two_projects_one_workspace()

    :ok = seed_published!(ctx.ws, ctx.proj_a, ctx.ds, "pub-a", ["kept"])
    :ok = seed_published!(ctx.ws, ctx.proj_b, ctx.ds, "pub-b", ["leaked"])

    tags =
      TagDistribution.per_type("post", ctx.ds, ctx.read_a)
      |> Enum.map(& &1.tag)
      |> MapSet.new()

    assert MapSet.member?(tags, "kept")
    refute MapSet.member?(tags, "leaked")
  end

  # ── Criterion 1 — sheets.ex cond arms 2 and 3 (lines 104 / 107) ─────────────
  #
  # `Content.Sheets.sheet_embed_targets/2` picks its scope with a three-armed
  # cond: arm 1 `sheet.dataset_id` (authoritative), arm 2 `sheet.workspace_id`
  # (dataset STRING + workspace), arm 3 the nil-workspace global layer. Every
  # sheet a fixture writes through the write path carries a dataset_id, so arm 1
  # always wins and arms 2/3 never execute.
  #
  # MEASURED (before these two tests): replacing BOTH arm bodies with the
  # unscoped `base` left `content_sheets_writethrough_test.exs` +
  # `sheets_test.exs` + `bulldocs_sheet_embed_test.exs` at
  # `5 doctests, 54 tests, 0 failures` — identical to the unmutated baseline.
  # So they were NOT a clear: they were uncovered. The two tests below drive a
  # dataset_id-LESS sheet, which is the only input that reaches them.

  defp seed_doc!(attrs) do
    now = DateTime.utc_now()

    base = %{
      type: "paper",
      status: "published",
      rev: Barkpark.Content.Writer.generate_rev(),
      inserted_at: now,
      updated_at: now
    }

    {1, _} = Repo.insert_all(Document, [Map.merge(base, attrs)])
    :ok
  end

  defp embed_block(ref), do: %{"blocks" => [%{"type" => "sheet", "ref" => ref}]}

  test "sheets.ex arm 2: a workspace-stamped, dataset_id-LESS sheet refreshes only its own workspace" do
    ds = unique_ds()
    ws_a = create_workspace!()
    ws_b = create_workspace!()

    # The sheet itself is legacy: dataset STRING only, no dataset_id, so arm 1
    # falls through and arm 2 (line 104) is the live scope.
    sheet = %Document{
      doc_id: "legacy-sheet",
      type: "sheet",
      dataset: ds,
      dataset_id: nil,
      workspace_id: ws_a.id
    }

    :ok =
      seed_doc!(%{
        doc_id: "embedder-a",
        dataset: ds,
        workspace_id: ws_a.id,
        content: embed_block("legacy-sheet")
      })

    :ok =
      seed_doc!(%{
        doc_id: "embedder-b",
        dataset: ds,
        workspace_id: ws_b.id,
        content: embed_block("legacy-sheet")
      })

    :ok =
      seed_doc!(%{
        doc_id: "embedder-global",
        dataset: ds,
        workspace_id: nil,
        content: embed_block("legacy-sheet")
      })

    ids =
      Content.Sheets.sheet_embed_targets(sheet, ["legacy-sheet", "drafts.legacy-sheet"])
      |> Enum.map(& &1.doc_id)
      |> MapSet.new()

    assert MapSet.member?(ids, "embedder-a")
    refute MapSet.member?(ids, "embedder-b")
    refute MapSet.member?(ids, "embedder-global")
  end

  test "sheets.ex arm 3: a fully unstamped sheet refreshes only nil-workspace embedders" do
    ds = unique_ds()
    ws_a = create_workspace!()

    # Neither dataset_id nor workspace_id — arms 1 and 2 both fall through and
    # arm 3 (line 107) is the live scope.
    sheet = %Document{
      doc_id: "global-sheet",
      type: "sheet",
      dataset: ds,
      dataset_id: nil,
      workspace_id: nil
    }

    :ok =
      seed_doc!(%{
        doc_id: "g-embedder-global",
        dataset: ds,
        workspace_id: nil,
        content: embed_block("global-sheet")
      })

    :ok =
      seed_doc!(%{
        doc_id: "g-embedder-a",
        dataset: ds,
        workspace_id: ws_a.id,
        content: embed_block("global-sheet")
      })

    ids =
      Content.Sheets.sheet_embed_targets(sheet, ["global-sheet", "drafts.global-sheet"])
      |> Enum.map(& &1.doc_id)
      |> MapSet.new()

    assert MapSet.member?(ids, "g-embedder-global")
    refute MapSet.member?(ids, "g-embedder-a")
  end
end
