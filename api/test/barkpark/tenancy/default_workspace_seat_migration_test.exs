defmodule Barkpark.Tenancy.DefaultWorkspaceSeatMigrationTest do
  @moduledoc """
  The `20260909120000_add_is_default_to_workspaces` BACKFILL must tolerate an
  ALREADY-VACANT seat (task-566dc5be4871353b, criterion 5).

  WHY THAT IS NOT A HYPOTHETICAL. `bp cloud support add --ws default`
  (internal/cli/cloud_support_cmd.go) runs SupportResetDefaultWorkspaceStep,
  which DELETES the `default`-slugged workspace, and only then
  SupportAdminTokenStep, whose `Seeds.Shared.ensure_default_scope/0` re-mints it.
  Between those two steps the instance has NO workspace at slug `default` — on
  purpose, and the bracket is written to tolerate it so re-runs converge. A
  migration that ran in that window and assumed a row existed would crash a
  provision half-way through, and the operator's remedy would be to re-run the
  very bracket that produced the state.

  So the backfill is asserted to be a NO-OP there, not merely believed to be:
  the arms below run the migration's EXACT statement against both populations.

  WHAT THIS FILE DOES NOT CLAIM. It runs the backfill SQL, not `up/0` — the
  `alter table` and `create index` halves are exercised by `mix ecto.migrate`
  itself on every developer and CI database, and re-running DDL inside the
  sandbox transaction would measure the harness rather than the migration.
  """

  use Barkpark.DataCase, async: false


  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Repo, Tenancy}
  alias Barkpark.Tenancy.Workspace

  # Copied from the migration deliberately, and kept honest by
  # `the statement under test is the statement the migration ships` below.
  @backfill "UPDATE workspaces SET is_default = true WHERE slug = 'default'"

  @migration Path.join([
               __DIR__,
               "..",
               "..",
               "..",
               "priv",
               "repo",
               "migrations",
               "20260909120000_add_is_default_to_workspaces.exs"
             ])

  setup do
    {_n, _} =
      Repo.update_all(from(w in Workspace, where: w.is_default == true), set: [is_default: false])

    Barkpark.Tenancy.DefaultScopeCache.invalidate()
    :ok
  end

  test "the statement under test is the statement the migration ships" do
    source = File.read!(@migration)

    assert source =~ @backfill,
           "this file's @backfill drifted from the migration — it is now proving something " <>
             "the migration does not do"
  end

  test "ALREADY-VACANT seat: no `default`-slugged row at all → 0 rows, no raise" do
    {_n, _} =
      Repo.update_all(
        from(w in Workspace, where: w.slug == ^"default"),
        set: [slug: "gone-for-vacancy-arm"]
      )

    assert Repo.aggregate(from(w in Workspace, where: w.slug == ^"default"), :count) == 0

    # THE ASSERTION: no crash, and nothing claimed.
    assert %{num_rows: 0} = Repo.query!(@backfill, [])

    Barkpark.Tenancy.DefaultScopeCache.invalidate()

    refute Tenancy.get_default_workspace(),
           "the backfill invented a default workspace out of a vacant instance"
  end

  test "CONTROL — with the row present the SAME statement does claim the seat" do
    # Without this arm the vacancy arm above is vacuous: a backfill that never
    # updates anything would also pass it.
    {_n, _} =
      Repo.update_all(
        from(w in Workspace, where: w.slug == ^"default"),
        set: [slug: "gone-for-control-arm"]
      )

    {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default Workspace"})
    refute Tenancy.get_default_workspace(), "precondition: the seat starts vacant"

    assert %{num_rows: 1} = Repo.query!(@backfill, [])

    Barkpark.Tenancy.DefaultScopeCache.invalidate()
    assert Tenancy.get_default_workspace().id == ws.id
  end

  test "the backfill can never seat TWO workspaces (the slug is unique, the seat is unique)" do
    {_n, _} =
      Repo.update_all(
        from(w in Workspace, where: w.slug == ^"default"),
        set: [slug: "gone-for-uniqueness-arm"]
      )

    {:ok, _} = Tenancy.create_workspace(%{slug: "default", name: "Default Workspace"})
    {:ok, _other} = Tenancy.create_workspace(%{slug: "other-#{System.unique_integer([:positive])}", name: "Other"})

    assert %{num_rows: 1} = Repo.query!(@backfill, [])

    assert Repo.aggregate(from(w in Workspace, where: w.is_default == true), :count) == 1
  end

  describe "DEGRADES TO VACANCY, NEVER TO CAPTURE" do
    test "an unscoped write with the seat vacant lands with workspace_id nil" do
      # PR #12879's capture arm, re-pinned against the NEW identity: the seat is
      # vacant here because no row holds `is_default`, not because no row holds a
      # string. Vacancy is a bounded problem; capture is an unbounded privilege
      # transfer, and the ordering has to survive the identity change.
      refute Tenancy.get_default_workspace()

      {:ok, doc} =
        Barkpark.Content.create_document(
          "post",
          %{"title" => "unscoped, seat vacant, new identity"},
          "production",
          []
        )

      row = Repo.get_by(Barkpark.Content.Document, id: doc.id)

      assert is_nil(row.workspace_id),
             "an unscoped write was attributed to a workspace despite the seat being vacant"
    end
  end
end
