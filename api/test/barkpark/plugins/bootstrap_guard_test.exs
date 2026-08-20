defmodule Barkpark.Plugins.BootstrapGuardTest do
  @moduledoc """
  THE PULL-PROVENANCE GUARD (PDS-D21/D22).

  `bootstrap_default_slot_probe_test.exs` proves the HAZARD: a pulled schema row
  sitting in the Default dataset slot is UPDATED in place on every boot and
  loses EIGHT columns — title, icon, visibility, owner_scoped, fields, plus
  cors_origins, desk_groups and list_preview, which revert to bare plugin-struct
  defaults even though the plugin says nothing about them.

  This file proves the GUARD, and proves it is a guard rather than a freeze:

    * a row whose (workspace, dataset) slot carries a `pull_provenance` stamp
      survives ALL EIGHT columns, and the drift is LOGGED, not silent;
    * an UNSTAMPED row keeps today's update behaviour verbatim (the negative
      control — a guard that fired everywhere would be indistinguishable from
      "bootstrap stopped working");
    * insert-when-absent is UNCHANGED even inside a stamped workspace;
    * a stamp on a SIBLING dataset does not cover this one (the two-level
      nesting is load-bearing at the guard, not only at the accessor);
    * a FOREIGN properly-backfilled workspace is untouched either way (the read
      never reached it — the guard adds nothing there and must not remove
      anything either);
    * CLEARING the stamp (`set_pull_provenance(ws, slug, %{})` — the literal call
      the drift warning names) restores today's behaviour on the very next boot,
      so the sticky skip has a proven way out, not just a documented one.
  """

  use Barkpark.DataCase, async: false

  @moduletag :plugin_bootstrap

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "production"

  @stamp %{
    "source_server" => "https://guerrilla.barkpark.cloud",
    "source_workspace" => "default",
    "source_dataset" => "production",
    "exported_at" => "2026-07-19T12:00:00Z",
    "profile" => "dev",
    "pulled_at" => "2026-07-19T12:05:00Z"
  }

  defmodule GuardStub do
    @moduledoc false
    alias Barkpark.Content.SchemaDefinition

    def schema_name, do: "pds_guard_schema"

    def register_schemas(_opts) do
      [
        %SchemaDefinition{
          name: schema_name(),
          title: "Plugin Title",
          icon: "plugin-icon",
          visibility: "public",
          owner_scoped: false,
          fields: [%{"name" => "plugin_field", "type" => "string"}],
          dataset: "production"
          # cors_origins / desk_groups / list_preview deliberately UNSET.
        }
      ]
    end
  end

  defp plugin_entry, do: %{name: "pds_guard_plugin", module: GuardStub}

  defp run_bootstrap do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    Bootstrap.install_for_plugin(plugin_entry(), {ws.id, project.id})
  end

  defp rows do
    from(s in SchemaDefinition, where: s.name == ^GuardStub.schema_name()) |> Repo.all()
  end

  defp ensure_dataset!(project, slug) do
    case Tenancy.get_dataset(project, slug) do
      nil ->
        {:ok, ds} = Tenancy.create_dataset(project, %{slug: slug, name: slug})
        ds

      ds ->
        ds
    end
  end

  # Inserted RAW so the test controls the tenancy columns exactly — this is what
  # a pulled row looks like once the bundle has landed.
  defp insert_pulled_row!(attrs) do
    %SchemaDefinition{
      name: GuardStub.schema_name(),
      title: "Pulled Title",
      icon: "pulled-icon",
      visibility: "private",
      owner_scoped: true,
      fields: [%{"name" => "pulled_field", "type" => "text"}],
      dataset: @dataset,
      cors_origins: ["https://pulled.example"],
      desk_groups: [%{"name" => "Pulled Group"}],
      list_preview: %{"title" => "pulled"}
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  defp assert_all_eight_pulled(row) do
    assert row.title == "Pulled Title"
    assert row.icon == "pulled-icon"
    assert row.visibility == "private"
    assert row.owner_scoped == true
    assert row.fields == [%{"name" => "pulled_field", "type" => "text"}]
    assert row.cors_origins == ["https://pulled.example"]
    assert row.desk_groups == [%{"name" => "Pulled Group"}]
    assert row.list_preview == %{"title" => "pulled"}
  end

  # The mirror of `assert_all_eight_pulled/1`: what the SAME eight columns look
  # like once bootstrap has updated the row in place. The last three are the
  # silent half of the clobber — the plugin declares nothing about
  # cors_origins / desk_groups / list_preview, so they revert to bare
  # plugin-struct defaults. Both polarities of the guard assert the same eight,
  # or one of them is a spot check wearing a regression bar's name.
  defp assert_all_eight_plugin(row) do
    assert row.title == "Plugin Title"
    assert row.icon == "plugin-icon"
    assert row.visibility == "public"
    assert row.owner_scoped == false
    assert row.fields == [%{"name" => "plugin_field", "type" => "string"}]
    assert row.cors_origins == []
    assert row.desk_groups == []
    assert row.list_preview == %{}
  end

  setup do
    {default_ws, default_project} = TenancyFixtures.ensure_default_scope!()
    default_ds = ensure_dataset!(default_project, @dataset)

    foreign_ws = TenancyFixtures.create_workspace!()
    foreign_project = TenancyFixtures.create_project!(foreign_ws)
    foreign_ds = ensure_dataset!(foreign_project, @dataset)

    %{
      default_ws: default_ws,
      default_project: default_project,
      default_ds: default_ds,
      foreign_ws: foreign_ws,
      foreign_project: foreign_project,
      foreign_ds: foreign_ds
    }
  end

  test "a STAMPED slot survives all EIGHT columns and logs the drift", ctx do
    pulled =
      insert_pulled_row!(%{
        workspace_id: ctx.default_ws.id,
        project_id: ctx.default_project.id,
        dataset_id: ctx.default_ds.id
      })

    {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)

    log = capture_log(fn -> assert {:ok, 1} = run_bootstrap() end)

    assert length(rows()) == 1, "the guard must SKIP the update, never insert a duplicate"
    assert_all_eight_pulled(Repo.get!(SchemaDefinition, pulled.id))

    assert log =~ "pds_guard_schema"
    assert log =~ "PULLED"
    assert log =~ "pds_guard_plugin"
  end

  test "the guard holds across REPEATED boots (convergence, not a one-shot)", ctx do
    pulled =
      insert_pulled_row!(%{
        workspace_id: ctx.default_ws.id,
        project_id: ctx.default_project.id,
        dataset_id: ctx.default_ds.id
      })

    {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)

    capture_log(fn ->
      assert {:ok, 1} = run_bootstrap()
      assert {:ok, 1} = run_bootstrap()
      assert {:ok, 1} = run_bootstrap()
    end)

    assert length(rows()) == 1
    assert_all_eight_pulled(Repo.get!(SchemaDefinition, pulled.id))
  end

  # The skip is STICKY: every import stamps its target, so a workspace that ever
  # took a bundle never accepts a plugin schema update again. `skip_pulled/3`'s
  # warning tells the operator to clear the stamp — this pins that the documented
  # escape hatch is real, and that clearing restores today's behaviour EXACTLY
  # (a recovery path with no test is a promise, not a mechanism).
  test "CLEARING the stamp is a real escape hatch — the very next boot updates again", ctx do
    pulled =
      insert_pulled_row!(%{
        workspace_id: ctx.default_ws.id,
        project_id: ctx.default_project.id,
        dataset_id: ctx.default_ds.id
      })

    {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)
    capture_log(fn -> assert {:ok, 1} = run_bootstrap() end)
    assert_all_eight_pulled(Repo.get!(SchemaDefinition, pulled.id))

    # The literal call the drift warning names.
    {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, %{})

    assert Tenancy.pull_provenance(Tenancy.get_workspace_by_id(ctx.default_ws.id), @dataset) ==
             %{}

    assert {:ok, 1} = run_bootstrap()

    assert length(rows()) == 1, "clearing must not insert a duplicate row"
    # The SAME eight columns the negative control asserts — the escape hatch has
    # to restore today's behaviour exactly, not approximately.
    assert_all_eight_plugin(Repo.get!(SchemaDefinition, pulled.id))
  end

  test "NEGATIVE CONTROL — an UNSTAMPED slot keeps today's clobber behaviour", ctx do
    pulled =
      insert_pulled_row!(%{
        workspace_id: ctx.default_ws.id,
        project_id: ctx.default_project.id,
        dataset_id: ctx.default_ds.id
      })

    assert {:ok, 1} = run_bootstrap()

    assert length(rows()) == 1
    assert_all_eight_plugin(Repo.get!(SchemaDefinition, pulled.id))
  end

  test "a stamp on a SIBLING dataset does NOT cover this one", ctx do
    pulled =
      insert_pulled_row!(%{
        workspace_id: ctx.default_ws.id,
        project_id: ctx.default_project.id,
        dataset_id: ctx.default_ds.id
      })

    {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, "staging", @stamp)

    assert {:ok, 1} = run_bootstrap()

    # production was never pulled → the plugin still owns it.
    assert Repo.get!(SchemaDefinition, pulled.id).title == "Plugin Title"
  end

  test "INSERT-WHEN-ABSENT is unchanged inside a stamped workspace", ctx do
    {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)

    assert rows() == []
    assert {:ok, 1} = run_bootstrap()

    assert [row] = rows()
    assert row.title == "Plugin Title"
    assert row.workspace_id == ctx.default_ws.id

    # ...and the freshly inserted row is now itself stamp-covered, so the NEXT
    # boot skips it. That is the honest consequence of a slot-keyed guard, and
    # it converges rather than oscillating.
    capture_log(fn -> assert {:ok, 1} = run_bootstrap() end)
    assert length(rows()) == 1
  end

  test "a FOREIGN backfilled workspace is untouched, stamped or not", ctx do
    foreign =
      insert_pulled_row!(%{
        workspace_id: ctx.foreign_ws.id,
        project_id: ctx.foreign_project.id,
        dataset_id: ctx.foreign_ds.id
      })

    {:ok, _} = Tenancy.set_pull_provenance(ctx.foreign_ws.id, @dataset, @stamp)

    assert {:ok, 1} = run_bootstrap()

    assert_all_eight_pulled(Repo.get!(SchemaDefinition, foreign.id))
    assert Repo.get!(SchemaDefinition, foreign.id).workspace_id == ctx.foreign_ws.id

    # The Default-scoped duplicate still gets inserted — the guard changed
    # nothing on this path (the read never matched the foreign row).
    assert length(rows()) == 2
  end
end
