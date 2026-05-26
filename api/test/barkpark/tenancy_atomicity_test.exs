defmodule Barkpark.TenancyAtomicityTest do
  @moduledoc """
  Pins the "atomically (single `Repo.transaction`)" claim in the
  `Barkpark.Tenancy` moduledoc for the two bootstrap helpers:

    * `create_workspace_with_owner/2` — 4 inserts (workspace, membership,
      Default project, production dataset), and
    * `create_project_with_dataset/2` — 2 inserts (project, production dataset).

  The pre-existing happy-path + duplicate-slug-422 tests only ever fail at the
  FIRST insert, so they never prove that PARTIAL work mid-transaction rolls
  back. These tests force a LATER step to fail and assert that NOTHING the
  helper inserted survives — no orphan workspace / membership / project /
  dataset.

  Two complementary levers force a mid-transaction failure:

    1. A CHECK constraint added inside the per-test sandbox transaction rejects
       the production dataset slug, so the FINAL insert of each helper fails
       AFTER every earlier insert in the same transaction has written a row.
       The whole transaction must roll back. (Sandbox discards the DDL at test
       end.) This is the strongest proof — it forces the LAST step to fail.

    2. An empty-string `principal_id` (which still satisfies the `is_binary/1`
       guard) lets the workspace insert succeed and then makes the membership
       changeset invalid — exercising the `with/else -> Repo.rollback(changeset)`
       branch the moduledoc names, returning a clean `{:error, changeset}`.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Workspace, Project, Dataset, Membership}

  # Reject any dataset row whose slug is "production". NOT VALID skips the rows
  # the seed migration already inserted, so only the bootstrap's freshly-built
  # production dataset trips it. Added inside the sandbox transaction; rolled
  # back with everything else when the test owner stops.
  defp reject_production_datasets! do
    Barkpark.Repo.query!(
      "ALTER TABLE datasets ADD CONSTRAINT atomicity_no_production_chk " <>
        "CHECK (slug <> 'production') NOT VALID"
    )
  end

  defp ws_count(slug), do: Repo.aggregate(from(w in Workspace, where: w.slug == ^slug), :count)

  defp membership_count(principal_id),
    do: Repo.aggregate(from(m in Membership, where: m.principal_id == ^principal_id), :count)

  defp project_count(ws_id), do: Repo.aggregate(from(p in Project, where: p.workspace_id == ^ws_id), :count)

  defp dataset_count(project_id),
    do: Repo.aggregate(from(d in Dataset, where: d.project_id == ^project_id), :count)

  # Count projects/datasets reachable from a workspace slug — catches orphans
  # left behind even after the workspace row itself is gone.
  defp projects_under_slug(slug) do
    Repo.aggregate(
      from(p in Project, join: w in Workspace, on: p.workspace_id == w.id, where: w.slug == ^slug),
      :count
    )
  end

  describe "create_workspace_with_owner/2 mid-transaction rollback" do
    test "DATASET (last of 4) step fails -> workspace + membership + project ALL roll back" do
      reject_production_datasets!()

      slug = "atomic-ws-#{System.unique_integer([:positive])}"
      principal_id = Ecto.UUID.generate()

      # The transaction inserts workspace (1), membership (2), project (3), then
      # the production dataset insert (4) violates the CHECK and raises inside
      # the transaction. Repo.transaction rolls the whole chain back.
      assert_raise Ecto.ConstraintError, fn ->
        Tenancy.create_workspace_with_owner(%{name: "Atomic WS", slug: slug}, principal_id)
      end

      # FULL ROLLBACK — every one of the four inserts is gone:
      assert Tenancy.get_workspace_by_slug(slug) == nil
      assert ws_count(slug) == 0
      assert membership_count(principal_id) == 0
      assert projects_under_slug(slug) == 0
    end

    test "MEMBERSHIP step fails after the workspace insert -> {:error, changeset}, full rollback" do
      slug = "atomic-ws2-#{System.unique_integer([:positive])}"

      # Lever: an empty-string principal_id passes the `is_binary/1` guard, so
      # the helper runs. The WORKSPACE inserts cleanly (step 1); then
      # `TenancyAuth.create_membership/3` builds a membership changeset that
      # fails `validate_required(:principal_id)`, returning {:error, changeset},
      # which the `with/else` routes to `Repo.rollback(changeset)`. The project
      # + dataset steps never run, and the already-inserted workspace row must
      # be discarded.
      assert {:error, %Ecto.Changeset{} = cs} =
               Tenancy.create_workspace_with_owner(%{name: "Atomic WS2", slug: slug}, "")

      refute cs.valid?
      assert errors_on(cs)[:principal_id] not in [nil, []]

      assert Tenancy.get_workspace_by_slug(slug) == nil
      assert ws_count(slug) == 0
      assert projects_under_slug(slug) == 0
    end

    test "the failed-attempt slug is immediately reusable (no row holds it)" do
      slug = "atomic-ws3-#{System.unique_integer([:positive])}"

      assert {:error, _cs} =
               Tenancy.create_workspace_with_owner(%{name: "Atomic WS3", slug: slug}, "")

      # A clean bootstrap with the SAME slug succeeds — proving the failed
      # attempt left NO row occupying the unique workspace slug — and lands
      # exactly one of each child, no leftovers.
      principal_id = Ecto.UUID.generate()

      assert {:ok, %Workspace{} = ws} =
               Tenancy.create_workspace_with_owner(%{name: "Atomic WS3", slug: slug}, principal_id)

      assert ws.slug == slug
      assert ws_count(slug) == 1
      assert membership_count(principal_id) == 1
      assert project_count(ws.id) == 1
      [project] = ws.projects
      assert dataset_count(project.id) == 1
      assert Tenancy.get_dataset(project, "production")
    end
  end

  describe "create_project_with_dataset/2 mid-transaction rollback" do
    setup do
      slug = "atomic-host-#{System.unique_integer([:positive])}"
      {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: "Atomic Host"})
      %{ws: ws}
    end

    test "DATASET (last of 2) step fails -> the inserted project rolls back", %{ws: ws} do
      reject_production_datasets!()

      proj_slug = "atomic-proj-#{System.unique_integer([:positive])}"
      before = project_count(ws.id)

      # The transaction inserts the PROJECT (step 1) then the production DATASET
      # (step 2), which violates the CHECK and raises inside the transaction.
      # Repo.transaction rolls the project back.
      assert_raise Ecto.ConstraintError, fn ->
        Tenancy.create_project_with_dataset(ws, %{name: "Atomic Proj", slug: proj_slug})
      end

      # NO orphan project, NO orphan dataset.
      assert Tenancy.get_project(ws.slug, proj_slug) == nil
      assert project_count(ws.id) == before

      # And the slug is reusable once the constraint is gone — a clean bootstrap
      # lands exactly one project + one production dataset.
      Barkpark.Repo.query!("ALTER TABLE datasets DROP CONSTRAINT atomicity_no_production_chk")

      assert {:ok, %Project{} = p} =
               Tenancy.create_project_with_dataset(ws, %{name: "Atomic Proj", slug: proj_slug})

      assert project_count(ws.id) == before + 1
      assert dataset_count(p.id) == 1
      assert Tenancy.get_dataset(p, "production")
    end

    test "duplicate project slug fails at the FIRST step -> nothing partial survives", %{ws: ws} do
      proj_slug = "dup-proj-#{System.unique_integer([:positive])}"

      assert {:ok, %Project{} = p1} =
               Tenancy.create_project_with_dataset(ws, %{name: "First", slug: proj_slug})

      assert dataset_count(p1.id) == 1
      one_project = project_count(ws.id)

      # Second bootstrap on the SAME slug: the project insert collides; the
      # transaction returns {:error} and inserts NOTHING — no second project,
      # no extra production dataset.
      assert {:error, _cs} =
               Tenancy.create_project_with_dataset(ws, %{name: "Second", slug: proj_slug})

      assert project_count(ws.id) == one_project
      assert dataset_count(p1.id) == 1
    end
  end
end
