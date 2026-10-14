defmodule Barkpark.Media.DatasetIdBackfillTest do
  @moduledoc """
  task-fa5ccc714ad4a939 — the prepared `media_files.dataset_id` backfill.

  Criterion 2, NO ROW CHANGES VISIBILITY: the id SET every workspace-scoped and
  project-scoped media search returns is equal before and after the backfill,
  for a workspace holding only unstamped rows and one holding a mix (stamped,
  unstamped with no project, unstamped in its default project, unstamped in a
  second project). Compared as sets, never counts. The same equality holds
  again after `undo/1`.

  Criterion 3, REVERSIBLE: `undo/1` restores the NULL stamps from the journal
  and deletes only the Datasets it created that nothing references.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Media.DatasetIdBackfill
  alias Barkpark.Media.Delivery.Search
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @ds_a "legacybfa"
  @ds_b "legacybfb"
  @ds_c "legacybfc"

  setup do
    journal = Path.join(System.tmp_dir!(), "media-ds-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal) end)

    # Workspace ONE: only unstamped rows; Dataset @ds_a does not exist anywhere.
    one = create_workspace!()
    one_default = create_project!(one, "default")
    {:ok, u1} = create_media_file_in!(one, nil, %{dataset_id: nil}, @ds_a)
    {:ok, u2} = create_media_file_in!(one, one_default, %{dataset_id: nil}, @ds_a)
    {:ok, u6} = create_media_file_in!(one, nil, %{dataset_id: nil}, @ds_c)

    # Workspace TWO: a mix, across its default project and a second project.
    two = create_workspace!()
    two_default = create_project!(two, "default")
    two_other = create_project!(two, "other")
    {:ok, stamped_ds} = Tenancy.get_or_create_dataset(two_default.id, @ds_b)
    {:ok, s1} = create_media_file_in!(two, two_default, %{dataset_id: stamped_ds.id}, @ds_b)
    {:ok, u3} = create_media_file_in!(two, nil, %{dataset_id: nil}, @ds_b)
    {:ok, u4} = create_media_file_in!(two, two_default, %{dataset_id: nil}, @ds_b)
    {:ok, u5} = create_media_file_in!(two, two_other, %{dataset_id: nil}, @ds_b)

    %{
      journal: journal,
      scopes: [
        {@ds_a, [workspace_id: one.id]},
        {@ds_a, [workspace_id: one.id, project_id: one_default.id]},
        {@ds_c, [workspace_id: one.id]},
        {@ds_b, [workspace_id: two.id]},
        {@ds_b, [workspace_id: two.id, project_id: two_default.id]},
        {@ds_b, [workspace_id: two.id, project_id: two_other.id]}
      ],
      unstamped: [u1, u2, u3, u4, u5],
      extra: u6,
      one: one,
      stamped: s1,
      one_default: one_default,
      two_default: two_default,
      two_other: two_other,
      stamped_ds: stamped_ds
    }
  end

  defp visible(scopes) do
    Map.new(scopes, fn {ds, opts} = key ->
      {files, _total, _facets, _meta} = Search.search(ds, opts)
      {key, MapSet.new(files, & &1.id)}
    end)
  end

  defp dataset_id(%MediaFile{id: id}), do: Repo.get!(MediaFile, id).dataset_id

  test "the census measures the population, with a positive control, and writes nothing", ctx do
    report = DatasetIdBackfill.run()

    assert report.null_rows >= 5
    assert %{id: control_id} = report.control
    assert Repo.get(MediaFile, control_id), "the positive control must be a real row"

    ours = Enum.filter(report.groups, &(&1.dataset in [@ds_a, @ds_b]))
    assert Enum.sum(Enum.map(ours, & &1.rows)) == 5
    assert Enum.any?(report.groups, &(&1.dataset == @ds_c and &1.rows == 1))
    # @ds_a needs a Dataset in workspace ONE's default project; @ds_b exists in
    # TWO's default project but not in "other".
    assert Enum.any?(report.to_create, &(&1.dataset == @ds_a))
    # The row filed under "other" is read by two scopes resolving two dataset
    # ids; it is reported, never planned for creation.
    assert [%{rows: 1}] = Enum.filter(report.split_readers, &(&1.project_id == ctx.two_other.id))
    refute Enum.any?(report.to_create, &(&1.target_project_id == ctx.two_other.id))

    assert report.stamped == 0
    assert Enum.all?(ctx.unstamped, &is_nil(dataset_id(&1)))
    refute Tenancy.get_dataset(ctx.one_default, @ds_a)
  end

  test "apply: every unstamped row is stamped and no search's id set changes", ctx do
    before = visible(ctx.scopes)

    # The fixture must actually exercise something: each scope sees rows.
    assert Enum.all?(before, fn {_k, ids} -> MapSet.size(ids) > 0 end), inspect(before)

    report = DatasetIdBackfill.run(apply: true, journal: ctx.journal)
    [u1, u2, u3, u4, u5] = ctx.unstamped
    # The stamp is the dataset every reader of the row resolves: the
    # workspace's default project, for a row with no project or in that project.
    assert Enum.all?([u1, u2, u3, u4], &is_binary(dataset_id(&1)))
    assert dataset_id(u3) == ctx.stamped_ds.id
    assert dataset_id(u4) == ctx.stamped_ds.id
    # The split-readers row stays NULL and is reported as skipped.
    assert is_nil(dataset_id(u5))

    assert Enum.any?(
             report.skipped,
             &(&1.reason == :split_readers and &1.project_id == ctx.two_other.id)
           )

    assert visible(ctx.scopes) == before
  end

  test "undo restores the NULL stamps and removes only unreferenced created Datasets", ctx do
    before = visible(ctx.scopes)
    report = DatasetIdBackfill.run(apply: true, journal: ctx.journal)

    created_a = Tenancy.get_dataset(ctx.one_default, @ds_a)
    created_c = Tenancy.get_dataset(ctx.one_default, @ds_c)
    assert created_a && created_c
    # The census is global, so other unstamped rows in the test database may add
    # their own; assert on this fixture's two.
    journal = ctx.journal |> File.read!() |> Jason.decode!()
    assert created_a.id in journal["created_datasets"]
    assert created_c.id in journal["created_datasets"]

    # A NEW upload starts using created_c after the backfill.
    {:ok, later} =
      create_media_file_in!(ctx.one, ctx.one_default, %{dataset_id: created_c.id}, @ds_c)

    result = DatasetIdBackfill.undo(ctx.journal)

    assert result.unstamped == report.stamped
    assert Enum.all?([ctx.extra | ctx.unstamped], &is_nil(dataset_id(&1)))

    assert dataset_id(ctx.stamped) == ctx.stamped_ds.id,
           "a row the backfill did not stamp is untouched"

    assert dataset_id(later) == created_c.id, "a row stamped after the backfill is untouched"

    assert created_a.id in result.deleted_datasets
    refute Tenancy.get_dataset(ctx.one_default, @ds_a)
    assert created_c.id in result.kept_datasets, "a Dataset the later upload uses is kept"
    refute created_c.id in result.deleted_datasets
    assert Tenancy.get_dataset(ctx.one_default, @ds_c)

    # Visibility for the original rows is back to before (the later upload is
    # new, so compare on the original ids only).
    original = MapSet.new([ctx.stamped, ctx.extra | ctx.unstamped], & &1.id)

    assert Map.new(visible(ctx.scopes), fn {k, ids} -> {k, MapSet.intersection(ids, original)} end) ==
             before
  end

  test "apply refuses to overwrite an existing journal", ctx do
    File.write!(ctx.journal, "{}")

    assert_raise ArgumentError, ~r/exists/, fn ->
      DatasetIdBackfill.run(apply: true, journal: ctx.journal)
    end

    assert Enum.all?(ctx.unstamped, &is_nil(dataset_id(&1)))
  end
end
