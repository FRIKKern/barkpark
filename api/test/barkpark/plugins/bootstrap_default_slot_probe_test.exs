defmodule Barkpark.Plugins.BootstrapDefaultSlotProbeTest do
  @moduledoc """
  THE 7-SCENARIO PROBE — the re-runnable artifact behind PDS-D21/D22/D23.

  Wave 2 settled "what does `Plugins.Bootstrap.register_all_schemas/0` actually
  clobber?" by RUNNING a 7-scenario probe, but the probe was never committed —
  the whole reasoning chain survived only as prose in two Barkpark documents.
  That is a direct violation of this wave's "the proof is the program" doctrine:
  the provenance guard's scope depends on the answer, and a guard for an inert
  hazard is dead weight while a missing guard for a real one silently corrupts
  pulled schemas on the next reboot.

  This file IS the probe. It asserts the observed mechanism, not either
  surveyor's prose:

    * `Content.Scope.scope_to_workspace_global/1` (scope.ex:140) genuinely is
      `do: query` — the workspace filter IS absent.
    * BUT `Content.Schema.scope_schema_to_dataset/3` (schema.ex:440-448)
      narrows the bootstrap read to the DEFAULT project's `production`
      dataset_id (or a NULL-dataset_id legacy row matching the dataset STRING),
      because `resolve_read_dataset_id/2` falls through to
      `read_default_project_id([])` when opts carry no `:workspace_id` key.

  The effective narrowing is therefore **DEFAULT-DATASET-SLOT MATCHING** —
  neither "Default-project-scoped by an explicit filter" nor "fully unscoped,
  matches any workspace's row".

  Scenario map:

    S1  a properly-backfilled FOREIGN-workspace row is never touched
    S2  two NULL-dataset_id rows of the same (name, dataset) cannot coexist
    S3  a NULL-dataset_id row in a NON-default workspace SURVIVES with content
        and ownership intact (the theft this scenario ORIGINALLY pinned is
        closed by the ownership guard in `upsert_schema/3` —
        pds-bl-bootstrap-cross-tenant-theft; S3b/S3c prove no overfire)
    S4  re-running bootstrap inserts the Default duplicate ONCE, not per boot
    S5  `put_scope_attrs/2` RE-STAMPS the scope keys; it never NILs them
    S6  with only a foreign row present the insert happens once and converges
    S7  a pulled row sitting IN the Default slot is UPDATED in place, and the
        clobber hits all EIGHT columns

  Re-run: `cd api && CC=/usr/bin/clang MIX_ENV=test mix test \
    test/barkpark/plugins/bootstrap_default_slot_probe_test.exs`
  """

  use Barkpark.DataCase, async: false

  @moduletag :plugin_bootstrap

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "production"

  # ── The stub plugin ────────────────────────────────────────────────────
  #
  # Emits ONE schema whose eight clobber-relevant columns are all at bare
  # PLUGIN-STRUCT DEFAULTS except title/icon/visibility/owner_scoped/fields,
  # exactly mirroring a real plugin that "says nothing" about cors_origins,
  # desk_groups and list_preview.

  defmodule SlotStub do
    @moduledoc false
    alias Barkpark.Content.SchemaDefinition

    def schema_name, do: "pds_probe_slot_schema"

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
          # cors_origins / desk_groups / list_preview deliberately UNSET →
          # they carry the struct defaults [] / [] / %{}.
        }
      ]
    end
  end

  defp plugin_entry, do: %{name: "pds_probe_slot_plugin", module: SlotStub}

  defp run_bootstrap, do: Bootstrap.install_for_plugin(plugin_entry(), default_scope())

  defp default_scope do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    {ws.id, project.id}
  end

  defp rows do
    from(s in SchemaDefinition, where: s.name == ^SlotStub.schema_name())
    |> Repo.all()
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

  # A row inserted RAW (Repo.insert! on a bare struct) so the probe controls
  # the tenancy columns exactly — the changeset path would re-resolve them.
  defp insert_row!(attrs) do
    %SchemaDefinition{
      name: SlotStub.schema_name(),
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

  # ── S0 — the mechanism itself ──────────────────────────────────────────

  test "S0 the bootstrap read lands on the DEFAULT dataset slot", ctx do
    # scope_to_workspace_global/1 is a pass-through: no workspace filter.
    q = from(s in SchemaDefinition)
    assert Barkpark.Content.Scope.scope_to_workspace_global(q) == q

    # ...but resolve_read_dataset_id with EMPTY opts resolves the DEFAULT
    # project's production dataset_id, which is what narrows the read.
    resolved = Content.resolve_read_dataset_id(@dataset, [])

    assert resolved == ctx.default_ds.id,
           "expected the empty-opts read to resolve Default's dataset_id"

    refute resolved == ctx.foreign_ds.id
  end

  # ── S1 — foreign backfilled row is never touched ───────────────────────

  test "S1 a properly-backfilled FOREIGN workspace row is NOT clobbered", ctx do
    foreign =
      insert_row!(%{
        workspace_id: ctx.foreign_ws.id,
        project_id: ctx.foreign_project.id,
        dataset_id: ctx.foreign_ds.id
      })

    assert {:ok, 1} = run_bootstrap()

    reloaded = Repo.get!(SchemaDefinition, foreign.id)
    assert reloaded.title == "Pulled Title"
    assert reloaded.icon == "pulled-icon"
    assert reloaded.visibility == "private"
    assert reloaded.owner_scoped == true
    assert reloaded.fields == [%{"name" => "pulled_field", "type" => "text"}]
    assert reloaded.cors_origins == ["https://pulled.example"]
    assert reloaded.desk_groups == [%{"name" => "Pulled Group"}]
    assert reloaded.list_preview == %{"title" => "pulled"}
    assert reloaded.workspace_id == ctx.foreign_ws.id

    # ...and a SEPARATE Default-scoped row was inserted alongside it.
    all = rows()
    assert length(all) == 2
    assert Enum.any?(all, &(&1.workspace_id == ctx.default_ws.id))
  end

  # ── S2 — two NULL-dataset_id rows cannot coexist ───────────────────────

  test "S2 the partial unique index forbids two NULL-dataset_id rows of the same (name, dataset)" do
    insert_row!(%{workspace_id: nil, project_id: nil, dataset_id: nil})

    assert_raise Ecto.ConstraintError, fn ->
      insert_row!(%{workspace_id: nil, project_id: nil, dataset_id: nil})
    end
  end

  # ── S3 — the cross-tenant theft is CLOSED (pds-bl-bootstrap-cross-tenant-theft) ──
  #
  # This scenario USED to pin the theft as observed behaviour: the nil-arm of
  # `scope_schema_to_dataset/3` matched the foreign orphan, and the update
  # clobbered its content AND rewrote workspace_id/project_id into Default.
  # The ownership guard in `Content.Schema.upsert_schema/3` now refuses to
  # update a row owned by a DIFFERENT workspace than the resolved write scope
  # and inserts a fresh Default-scoped row instead.

  test "S3 a NULL-dataset_id row in a NON-default workspace SURVIVES bootstrap with content and ownership intact",
       ctx do
    orphan =
      insert_row!(%{
        workspace_id: ctx.foreign_ws.id,
        project_id: ctx.foreign_project.id,
        dataset_id: nil
      })

    assert {:ok, 1} = run_bootstrap()

    reloaded = Repo.get!(SchemaDefinition, orphan.id)
    # content survives...
    assert reloaded.title == "Pulled Title"
    assert reloaded.fields == [%{"name" => "pulled_field", "type" => "text"}]
    # ...and ownership is NEVER rewritten outside the target scope.
    assert reloaded.workspace_id == ctx.foreign_ws.id
    assert reloaded.project_id == ctx.foreign_project.id
    assert is_nil(reloaded.dataset_id)

    # The plugin's schema landed as its OWN Default-scoped row instead.
    all = rows()
    assert length(all) == 2
    default_row = Enum.find(all, &(&1.id != orphan.id))
    assert default_row.workspace_id == ctx.default_ws.id
    assert default_row.title == "Plugin Title"
    assert default_row.dataset_id == ctx.default_ds.id

    # Re-running converges on the Default row (dataset_id-first ordering):
    # no third row, and the orphan is still untouched.
    assert {:ok, 1} = run_bootstrap()
    assert length(rows()) == 2
    assert Repo.get!(SchemaDefinition, orphan.id).workspace_id == ctx.foreign_ws.id
  end

  # Positive controls: the guard must not OVERFIRE — the two legitimate
  # update-in-place shapes keep their pre-guard behaviour byte-identical.

  test "S3b a NULL-dataset_id row IN the Default workspace is still updated in place", ctx do
    row =
      insert_row!(%{
        workspace_id: ctx.default_ws.id,
        project_id: ctx.default_project.id,
        dataset_id: nil
      })

    assert {:ok, 1} = run_bootstrap()

    reloaded = Repo.get!(SchemaDefinition, row.id)
    assert reloaded.title == "Plugin Title"
    assert reloaded.workspace_id == ctx.default_ws.id
    assert length(rows()) == 1
  end

  test "S3c a legacy GLOBAL row (nil workspace) is still adopted into Default", ctx do
    row = insert_row!(%{workspace_id: nil, project_id: nil, dataset_id: nil})

    assert {:ok, 1} = run_bootstrap()

    reloaded = Repo.get!(SchemaDefinition, row.id)
    assert reloaded.title == "Plugin Title"
    assert reloaded.workspace_id == ctx.default_ws.id
    assert length(rows()) == 1
  end

  # ── S4 / S6 — convergence, insert-once ─────────────────────────────────

  test "S4/S6 with only a foreign row present the Default duplicate is inserted ONCE", ctx do
    insert_row!(%{
      workspace_id: ctx.foreign_ws.id,
      project_id: ctx.foreign_project.id,
      dataset_id: ctx.foreign_ds.id
    })

    assert {:ok, 1} = run_bootstrap()
    assert length(rows()) == 2

    assert {:ok, 1} = run_bootstrap()
    assert {:ok, 1} = run_bootstrap()
    assert length(rows()) == 2, "re-boot must UPDATE the Default row, never insert a third"
  end

  # ── S5 — put_scope_attrs RE-STAMPS, never NILs ─────────────────────────

  test "S5 put_scope_attrs re-stamps the scope keys rather than nilling them", ctx do
    # put_scope_attrs is {:ok, attrs} | {:error, reason} since the felix-w26
    # fail-closed contract — a valid dataset string always lands the ok arm.
    {:ok, attrs} =
      %{
        "name" => SlotStub.schema_name(),
        "title" => "x",
        "dataset" => @dataset,
        # a client-supplied FOREIGN scope, which must be dropped + re-resolved
        "workspace_id" => ctx.foreign_ws.id,
        "project_id" => ctx.foreign_project.id,
        "dataset_id" => ctx.foreign_ds.id
      }
      |> Content.put_scope_attrs([])

    refute is_nil(attrs["workspace_id"]), "workspace_id nilled? must be false"
    refute is_nil(attrs["project_id"]), "project_id nilled? must be false"
    refute is_nil(attrs["dataset_id"]), "dataset_id nilled? must be false"

    assert attrs["workspace_id"] == ctx.default_ws.id
    assert attrs["project_id"] == ctx.default_project.id
    assert attrs["dataset_id"] == ctx.default_ds.id

    # ...and the round-trip through the real upsert leaves a non-nil scope.
    default_row =
      insert_row!(%{
        workspace_id: ctx.default_ws.id,
        project_id: ctx.default_project.id,
        dataset_id: ctx.default_ds.id
      })

    assert {:ok, 1} = run_bootstrap()
    reloaded = Repo.get!(SchemaDefinition, default_row.id)
    refute is_nil(reloaded.workspace_id)
    refute is_nil(reloaded.project_id)
    refute is_nil(reloaded.dataset_id)
  end

  # ── S7 — the 8-column in-place clobber ─────────────────────────────────

  test "S7 a pulled row in the DEFAULT slot is updated in place and loses all EIGHT columns",
       ctx do
    pulled =
      insert_row!(%{
        workspace_id: ctx.default_ws.id,
        project_id: ctx.default_project.id,
        dataset_id: ctx.default_ds.id
      })

    assert {:ok, 1} = run_bootstrap()

    all = rows()
    assert length(all) == 1, "must be an in-place UPDATE on the same row id, not an insert"
    reloaded = Repo.get!(SchemaDefinition, pulled.id)

    # 1-5: overwritten with the plugin's declared values.
    assert reloaded.title == "Plugin Title"
    assert reloaded.icon == "plugin-icon"
    assert reloaded.visibility == "public"
    assert reloaded.owner_scoped == false
    assert reloaded.fields == [%{"name" => "plugin_field", "type" => "string"}]

    # 6-8: reverted to bare PLUGIN-STRUCT DEFAULTS — the plugin said NOTHING
    # about these three and still wiped them.
    assert reloaded.cors_origins == []
    assert reloaded.desk_groups == []
    assert reloaded.list_preview == %{}
  end
end
