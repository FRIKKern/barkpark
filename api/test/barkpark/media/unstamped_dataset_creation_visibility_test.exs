defmodule Barkpark.Media.UnstampedDatasetCreationVisibilityTest do
  @moduledoc """
  DOES CREATING A `Dataset` ROW MAKE THE UNSTAMPED ROWS THAT NAME IT VANISH?
  The answer is NO, and this file is the regression lock — task-fa5ccc714ad4a939,
  criterion 0.

  ## The disagreement this settles

  A builder reported a residual hole in the recommended `dataset_id` backfill:
  "a NULL row for slug X becomes invisible the moment a later upload creates
  dataset X under the same project." The row's filer disagreed from reading the
  predicate #16677 actually shipped:

      m.dataset_id == ^dataset_id or (is_nil(m.dataset_id) and m.dataset == ^dataset)

  Once dataset X resolves, an unstamped row carrying `dataset == "X"` is still
  matched by the SECOND disjunct. The claim and the code cannot both be right,
  and a backfill written to close a hole that does not exist is a data migration
  run for no reason.

  ## The property, stated

  For a workspace-scoped media search: creating a `Tenancy.Dataset` slugged X in
  the workspace's default project — and inserting a freshly-stamped blob under
  it — is MONOTONE on the returned id set. Rows are added; no previously-visible
  unstamped row is removed. The filer's reading holds; the builder's hole does
  not exist on the shipped read.

  ## Why the SQL probe is here and not decoration

  `scope_media_to_dataset/3` has TWO arms, and phase 1 exercises the UNRESOLVED
  one (`m.dataset == ^dataset AND m.dataset_id IS NULL`). If creating the
  Dataset row failed to make `resolve_dataset_id/2` resolve, phase 2 would run
  the SAME unresolved arm — the rows would still be there, the test would still
  be green, and it would have proved NOTHING. The probe asserts the emitted SQL
  goes from carrying no `m0."dataset_id" = $n` leaf to carrying one. That is
  what makes the "after" state real rather than assumed.

  ## The scoping clamp that DOES drop a row, and why it is not this hole

  A truly legacy blob is unstamped on `dataset_id` AND on `project_id` — the
  same `resolve_write_scope/1` nil that skipped the dataset stamp skipped the
  project stamp. `Content.Scope.scope_to_workspace/3` filters
  `x.project_id == ^project_id` with NO null tolerance, so an EXPLICITLY
  project-scoped read never returns that row. The last test pins that this is
  true BEFORE the dataset exists as well: it is a property of the project
  clamp, invariant under dataset creation, and therefore not the transition the
  builder described.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Media.Delivery.Search
  alias Barkpark.Tenancy

  # Deliberately NOT "production"/"test": this slug must have no Dataset row in
  # any project until phase 2 creates one, and sibling suites seed those two.
  @dataset "legacyunstamped"
  @event [:barkpark, :repo, :query]
  @handler_id :unstamped_dataset_creation_sql_probe

  defp search_ids(opts) do
    {files, _total, _facets, _meta} = Search.search(@dataset, opts)
    MapSet.new(files, & &1.id)
  end

  # Same probe shape as cursor_sql_shape_test.exs / dataset_project_scope_test.exs.
  defp capture_sql(fun) do
    test = self()

    :telemetry.attach(
      {@handler_id, make_ref()},
      @event,
      fn _event, _measure, meta, _cfg -> send(test, {:sql, meta.query}) end,
      nil
    )

    try do
      fun.()
    after
      for {id, _, _, _} <- :telemetry.list_handlers(@event),
          match?({@handler_id, _}, id),
          do: :telemetry.detach(id)
    end

    drain_sql([])
  end

  defp drain_sql(acc) do
    receive do
      {:sql, sql} -> drain_sql([sql | acc])
    after
      0 -> acc
    end
  end

  defp page_sql(statements) do
    Enum.find(statements, fn sql ->
      String.contains?(sql, ~s(FROM "media_files")) and
        String.contains?(sql, ~s(m0."inserted_at")) and
        String.contains?(sql, "LIMIT")
    end)
  end

  # A workspace with a `default`-slugged project and NO Dataset row for
  # @dataset, holding two UNSTAMPED blobs that name it:
  #
  #   * `legacy` — project_id NULL too. The TRUE legacy shape: the nil project
  #     that skipped the dataset stamp skipped the project stamp with it.
  #   * `legacy_attributed` — project_id set, dataset_id still NULL. The other
  #     half of the corpus, and the row the project clamp cannot explain away.
  defp workspace_before_the_dataset_exists! do
    ws = create_workspace!()
    project = create_project!(ws, "default")

    refute Tenancy.get_dataset(project, @dataset),
           "fixture precondition broken: a Dataset row for #{@dataset} already exists"

    {:ok, legacy} = create_media_file_in!(ws, nil, %{dataset_id: nil}, @dataset)
    {:ok, legacy_attributed} = create_media_file_in!(ws, project, %{dataset_id: nil}, @dataset)

    assert is_nil(legacy.dataset_id) and is_nil(legacy.project_id)
    assert is_nil(legacy_attributed.dataset_id)

    %{ws: ws, project: project, legacy: legacy, legacy_attributed: legacy_attributed}
  end

  # Phase 2: the event the builder said destroys visibility — the dataset comes
  # into existence and a later upload lands STAMPED under it.
  defp create_the_dataset_and_a_stamped_upload!(ws, project) do
    {:ok, _} = Tenancy.create_dataset(project, %{slug: @dataset, name: @dataset})

    # create_dataset/2 is on_conflict: :nothing; reload for the persisted id.
    ds = Tenancy.get_dataset(project, @dataset)
    assert %Tenancy.Dataset{} = ds

    {:ok, stamped} = create_media_file_in!(ws, project, %{dataset_id: ds.id}, @dataset)
    assert stamped.dataset_id == ds.id

    {ds, stamped}
  end

  describe "an unstamped row, after the Dataset it names is created" do
    test "stays visible — the second disjunct still matches it" do
      %{ws: ws, project: project, legacy: legacy, legacy_attributed: legacy_attributed} =
        workspace_before_the_dataset_exists!()

      before_ids = search_ids(workspace_id: ws.id)

      assert MapSet.equal?(before_ids, MapSet.new([legacy.id, legacy_attributed.id])),
             """
             BASELINE failed before the interesting state was even built. Expected
             both unstamped rows from the UNRESOLVED arm
             (`m.dataset = $n AND m.dataset_id IS NULL`); got
             #{inspect(MapSet.to_list(before_ids))}.
             """

      {_ds, stamped} = create_the_dataset_and_a_stamped_upload!(ws, project)

      after_ids = search_ids(workspace_id: ws.id)

      # POSITIVE CONTROL. Without this, "the unstamped rows are gone" and "the
      # search returned nothing at all / the fixture never reached the query"
      # are the same empty set. The stamped row is reachable ONLY through the
      # first disjunct, so its presence proves the read ran AND the resolved arm
      # fired.
      assert MapSet.member?(after_ids, stamped.id),
             """
             POSITIVE CONTROL FAILED: the freshly-stamped row #{stamped.id} did not
             come back. Nothing below this line is a measurement — the query did
             not reach the rows it is being asked about.
             Got: #{inspect(MapSet.to_list(after_ids))}
             """

      assert MapSet.equal?(
               after_ids,
               MapSet.new([legacy.id, legacy_attributed.id, stamped.id])
             ),
             """
             THE RESIDUAL HOLE WOULD BE REAL. Creating Dataset "#{@dataset}" removed
             a previously-visible unstamped row from a workspace-scoped media
             search.

             Before: #{inspect(Enum.sort(MapSet.to_list(before_ids)))}
             After:  #{inspect(Enum.sort(MapSet.to_list(after_ids)))}
             Lost:   #{inspect(Enum.sort(MapSet.to_list(MapSet.difference(before_ids, after_ids))))}

             That is the shape a STRICT `m.dataset_id == ^dataset_id` produces: the
             moment the dataset resolves, the whole unstamped corpus becomes a
             zero-row 200. The shipped predicate's second disjunct
             (`is_nil(m.dataset_id) and m.dataset == ^dataset`) is what prevents
             it, and it is load-bearing, not decoration.
             """

      assert MapSet.subset?(before_ids, after_ids),
             "the transition must be MONOTONE on the id set — rows added, none removed"
    end

    test "and the read really did switch arms — the SQL grows a dataset_id leaf" do
      # Guards the test above against going vacuous. If creating the Dataset row
      # did NOT make resolve_dataset_id/2 resolve, phase 2 re-runs the UNRESOLVED
      # arm, the rows are trivially still there, and the assertion above proves
      # nothing about the disjunction it claims to be testing.
      %{ws: ws, project: project} = workspace_before_the_dataset_exists!()

      sql_before =
        capture_sql(fn -> Search.search(@dataset, workspace_id: ws.id, limit: 5) end)
        |> page_sql()

      assert sql_before, "no page query reached the Repo in phase 1"

      refute sql_before =~ ~r/m0\."dataset_id" = \$\d+/,
             """
             Phase 1 already emitted a resolved `dataset_id` leaf, so the fixture
             never established the "before the dataset exists" state.
             Rendered: #{sql_before}
             """

      create_the_dataset_and_a_stamped_upload!(ws, project)

      sql_after =
        capture_sql(fn -> Search.search(@dataset, workspace_id: ws.id, limit: 5) end)
        |> page_sql()

      assert sql_after, "no page query reached the Repo in phase 2"

      assert sql_after =~ ~r/m0\."dataset_id" = \$\d+/,
             """
             Creating the Dataset row did NOT change the emitted predicate — the
             read is still on the unresolved arm. The visibility test is then
             vacuous: it never exercised the resolved disjunction at all.
             Rendered: #{sql_after}
             """

      naked = String.replace(sql_after, ["(", ")"], "")

      assert naked =~ ~r/m0\."dataset_id" IS NULL AND m0\."dataset" = \$\d+/,
             """
             The NULL-tolerant second disjunct is GONE from the resolved arm. That
             disjunct is the only thing keeping the unstamped corpus visible once
             a dataset resolves.
             Rendered: #{sql_after}
             """
    end
  end

  describe "the project clamp, which is a different thing and predates the dataset" do
    test "drops the project_id-NULL legacy row from an EXPLICIT project scope, before AND after" do
      %{ws: ws, project: project, legacy: legacy, legacy_attributed: legacy_attributed} =
        workspace_before_the_dataset_exists!()

      before_scoped = search_ids(workspace_id: ws.id, project_id: project.id)

      # `Content.Scope.scope_to_workspace/3` filters `x.project_id == ^project_id`
      # with no null tolerance. The truly-legacy row carries project_id NULL, so
      # it is already absent here — WITH NO DATASET ROW IN EXISTENCE. Whatever
      # this is, it is not "creating dataset X hid the row".
      assert MapSet.equal?(before_scoped, MapSet.new([legacy_attributed.id])),
             """
             Expected only the project-attributed unstamped row under an explicit
             project scope; got #{inspect(MapSet.to_list(before_scoped))}.
             """

      {_ds, stamped} = create_the_dataset_and_a_stamped_upload!(ws, project)

      after_scoped = search_ids(workspace_id: ws.id, project_id: project.id)

      assert MapSet.member?(after_scoped, stamped.id),
             "positive control: the freshly-stamped row is missing from its OWN project scope"

      assert MapSet.equal?(after_scoped, MapSet.new([legacy_attributed.id, stamped.id])),
             """
             The project-scoped read is not monotone either. Expected the
             project-attributed unstamped row plus the new stamped one; got
             #{inspect(MapSet.to_list(after_scoped))}.
             """

      refute MapSet.member?(after_scoped, legacy.id),
             "documented: the project_id-NULL row stays out, exactly as it was before"

      # And the workspace read — the one the corpus is actually served by —
      # still holds every row.
      assert MapSet.equal?(
               search_ids(workspace_id: ws.id),
               MapSet.new([legacy.id, legacy_attributed.id, stamped.id])
             )
    end
  end
end
