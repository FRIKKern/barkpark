defmodule Barkpark.Content.TagRegistryProvenanceTest do
  @moduledoc """
  THE SECOND UNGUARDED BOOT-TIME WRITER (PDS-D125/D126).

  `bootstrap_guard_test.exs` proves the pull-provenance guard over
  `Plugins.Bootstrap` — the plugin-registry walk. It has ZERO `tag` coverage,
  and `tag` is not plugin-declared: `SchemaBootstrap.init/1` calls
  `TagRegistry.register!("production")` directly, BEFORE its defensive
  try/rescue and BEFORE `register_all_schemas/0`. That call landed on
  `Content.upsert_schema/2` with no provenance check of any kind, so a
  pull-provenance-stamped `tag` row was overwritten on every boot.

  It overwrote a SMALLER set than bootstrap does, and the asymmetry is the
  fingerprint of the mechanism rather than a curiosity: `schema_attrs/0`
  declares FIVE keys (name/title/icon/visibility/fields) and
  `Ecto.Changeset.cast/3` ignores keys ABSENT from params, so `owner_scoped`,
  `cors_origins`, `desk_groups` and `list_preview` were never in the changeset
  and survived by accident. `Plugins.Bootstrap.upsert_one/3` builds attrs via
  `Map.from_struct` and therefore carries — and reverts — all eight.

  THE DIFFERENTIAL this file pins: under the IDENTICAL stamp, in the same
  dataset, the bootstrap-owned row survived 8/8 (bootstrap_guard_test.exs:162)
  while the TagRegistry-owned row went 4/8. After the fix it is 8/8 on both.

  And the trap that shapes the fix (PDS-D126): the guard covers the UPDATE
  ONLY. D12 places `TagRegistry.register!/1` outside the boot rescue precisely
  so a missing core `tag` schema fails the boot CLOSED — a guard that also
  skipped the INSERT would trade a clobber bug for a boot-closed-guarantee bug.
  So this file asserts BOTH polarities, plus the negative control (an unstamped
  slot keeps today's behaviour, or a guard that fired everywhere would be
  indistinguishable from "tag registration stopped working").
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Content.TagRegistry
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "production"
  @tag_type "tag"

  @stamp %{
    "source_server" => "https://guerrilla.barkpark.cloud",
    "source_workspace" => "default",
    "source_dataset" => "production",
    "exported_at" => "2026-07-19T12:00:00Z",
    "profile" => "dev",
    "pulled_at" => "2026-07-19T12:05:00Z"
  }

  # The FOUR columns `schema_attrs/0` names — the ones the pre-fix path reverted.
  @pulled_declared %{
    title: "Pulled Tag",
    icon: "pulled-icon",
    visibility: "private",
    fields: [%{"name" => "pulled_field", "type" => "text"}]
  }

  # The FOUR columns `schema_attrs/0` is silent about — the ones that survived
  # by accident even pre-fix. Asserted anyway: a regression bar that only
  # checked the four that used to break would go green if a later widening of
  # `schema_attrs/0` started reverting these instead.
  @pulled_undeclared %{
    owner_scoped: true,
    cors_origins: ["https://pulled.example"],
    desk_groups: [%{"name" => "Pulled Group"}],
    list_preview: %{"title" => "pulled"}
  }

  setup do
    {default_ws, default_project} = TenancyFixtures.ensure_default_scope!()
    default_ds = ensure_dataset!(default_project, @dataset)

    # The core `tag` schema may already exist from the seeds/boot path; this
    # suite owns the row's exact tenancy columns, so start from a clean slot.
    delete_tag_rows!()

    %{default_ws: default_ws, default_project: default_project, default_ds: default_ds}
  end

  describe "a pull-provenance-stamped `tag` row" do
    test "survives ALL EIGHT columns and logs the drift — the clobber is closed", ctx do
      pulled = insert_pulled_tag_row!(ctx)
      {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)

      log = capture_log(fn -> assert %SchemaDefinition{} = TagRegistry.register!(@dataset) end)

      assert_all_eight_pulled(Repo.get!(SchemaDefinition, pulled.id))

      # Silent divergence is its own bug — the operator must be told the local
      # declaration and the pulled row have drifted, and told the way out.
      assert log =~ "PULLED workspace/dataset"
      assert log =~ "Barkpark.Tenancy.set_pull_provenance"
    end

    test "the skip RETURNS the surviving row, so `register!/1`'s contract is unbroken", ctx do
      pulled = insert_pulled_tag_row!(ctx)
      {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)

      returned = capture_log_value(fn -> TagRegistry.register!(@dataset) end)

      assert returned.id == pulled.id
      assert returned.title == @pulled_declared.title
    end

    test "the guard holds across REPEATED boots (convergence, not a one-shot)", ctx do
      pulled = insert_pulled_tag_row!(ctx)
      {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)

      capture_log(fn ->
        TagRegistry.register!(@dataset)
        TagRegistry.register!(@dataset)
        TagRegistry.register!(@dataset)
      end)

      assert_all_eight_pulled(Repo.get!(SchemaDefinition, pulled.id))
      assert length(tag_rows()) == 1
    end

    test "CLEARING the stamp is a real escape hatch — the very next boot registers again", ctx do
      pulled = insert_pulled_tag_row!(ctx)
      {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)
      capture_log(fn -> TagRegistry.register!(@dataset) end)
      assert_all_eight_pulled(Repo.get!(SchemaDefinition, pulled.id))

      {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, %{})
      TagRegistry.register!(@dataset)

      assert_declared_four_are_local(Repo.get!(SchemaDefinition, pulled.id))
    end

    test "a stamp on a SIBLING dataset does NOT cover this one", ctx do
      pulled = insert_pulled_tag_row!(ctx)
      _staging = ensure_dataset!(ctx.default_project, "staging")
      {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, "staging", @stamp)

      TagRegistry.register!(@dataset)

      # production was never pulled → the local declaration still owns it.
      assert_declared_four_are_local(Repo.get!(SchemaDefinition, pulled.id))
    end
  end

  describe "INSERT-when-absent stays unconditional (PDS-D126 / D12 fail-closed)" do
    test "a DELETED tag row inside a STAMPED slot is recreated, never silently skipped", ctx do
      {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)
      assert tag_rows() == []

      assert %SchemaDefinition{} = schema = TagRegistry.register!(@dataset)

      assert [row] = tag_rows()
      assert row.id == schema.id
      assert_declared_four_are_local(row)
    end

    test "the re-created row is itself stamp-covered, so the NEXT boot skips it", ctx do
      {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)
      TagRegistry.register!(@dataset)
      assert [row] = tag_rows()

      # Drift the row the way a pull would, then boot again.
      row |> Ecto.Changeset.change(title: "Pulled Tag") |> Repo.update!()
      capture_log(fn -> TagRegistry.register!(@dataset) end)

      assert Repo.get!(SchemaDefinition, row.id).title == "Pulled Tag"
      assert length(tag_rows()) == 1
    end
  end

  describe "negative control" do
    test "an UNSTAMPED slot keeps today's behaviour verbatim", ctx do
      pulled = insert_pulled_tag_row!(ctx)

      TagRegistry.register!(@dataset)

      row = Repo.get!(SchemaDefinition, pulled.id)

      # The four `schema_attrs/0` declares revert to the local declaration...
      assert_declared_four_are_local(row)

      # ...and the four it is silent about are STILL untouched, because
      # `cast/3` never saw them. This is the pre-fix fingerprint, and it must
      # remain true off-stamp or the guard has become a freeze.
      assert row.owner_scoped == @pulled_undeclared.owner_scoped
      assert row.cors_origins == @pulled_undeclared.cors_origins
      assert row.desk_groups == @pulled_undeclared.desk_groups
      assert row.list_preview == @pulled_undeclared.list_preview
    end
  end

  describe "the guard predicate has ONE home" do
    test "Tenancy.pulled_schema_row/2 answers for the `tag` row both writers can touch", ctx do
      insert_pulled_tag_row!(ctx)

      refute Tenancy.pulled_schema_row?(@tag_type, @dataset)
      assert Tenancy.pulled_schema_row(@tag_type, @dataset) == nil

      {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)

      assert Tenancy.pulled_schema_row?(@tag_type, @dataset)
      assert %SchemaDefinition{name: @tag_type} = Tenancy.pulled_schema_row(@tag_type, @dataset)
    end

    test "an ABSENT row is never 'pulled' — that is what keeps the insert unconditional" do
      assert Tenancy.pulled_schema_row("no_such_schema_at_all", @dataset) == nil
      refute Tenancy.pulled_schema_row?("no_such_schema_at_all", @dataset)
    end

    test "non-binary input degrades to 'not pulled' rather than raising on the boot path" do
      refute Tenancy.pulled_schema_row?(nil, @dataset)
      refute Tenancy.pulled_schema_row?(@tag_type, nil)
      assert Tenancy.pulled_schema_row(nil, nil) == nil
    end

    # The `rescue` is the branch most likely to matter in production and the
    # hardest to reach: `pull_provenance/2` guards every shape it is handed, so
    # only a fault in the READ ITSELF can get there. A NUL byte is rejected as
    # `22021 character_not_in_repertoire`, which raises out of `get_schema/3`
    # WITHOUT aborting the surrounding sandbox transaction — so the fail-open
    # can be proven without savepoint juggling or a poisoned connection.
    test "a RAISE inside the guard's own read fails OPEN — the boot proceeds unguarded", ctx do
      pulled = insert_pulled_tag_row!(ctx)
      {:ok, _} = Tenancy.set_pull_provenance(ctx.default_ws.id, @dataset, @stamp)

      log =
        capture_log(fn ->
          assert Tenancy.pulled_schema_row("tag\0injected", @dataset) == nil
          refute Tenancy.pulled_schema_row?("tag\0injected", @dataset)
        end)

      assert log =~ "proceeding unguarded"

      # And the fault is not sticky: the very next read on a healthy name still
      # answers correctly, so one bad read can never latch the guard off.
      assert %SchemaDefinition{id: id} = Tenancy.pulled_schema_row(@tag_type, @dataset)
      assert id == pulled.id
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp ensure_dataset!(project, slug) do
    case Tenancy.get_dataset(project, slug) do
      nil ->
        {:ok, ds} = Tenancy.create_dataset(project, %{slug: slug, name: slug})
        ds

      ds ->
        ds
    end
  end

  defp tag_rows do
    from(s in SchemaDefinition, where: s.name == ^@tag_type) |> Repo.all()
  end

  defp delete_tag_rows! do
    from(s in SchemaDefinition, where: s.name == ^@tag_type) |> Repo.delete_all()
  end

  # Inserted RAW so the test owns the tenancy columns exactly — this is what a
  # pulled `tag` row looks like once the bundle has landed in the Default slot.
  defp insert_pulled_tag_row!(ctx) do
    %SchemaDefinition{name: @tag_type, dataset: @dataset}
    |> struct!(@pulled_declared)
    |> struct!(@pulled_undeclared)
    |> struct!(%{
      workspace_id: ctx.default_ws.id,
      project_id: ctx.default_project.id,
      dataset_id: ctx.default_ds.id
    })
    |> Repo.insert!()
  end

  defp assert_all_eight_pulled(row) do
    assert row.title == @pulled_declared.title
    assert row.icon == @pulled_declared.icon
    assert row.visibility == @pulled_declared.visibility
    assert row.fields == @pulled_declared.fields
    assert row.owner_scoped == @pulled_undeclared.owner_scoped
    assert row.cors_origins == @pulled_undeclared.cors_origins
    assert row.desk_groups == @pulled_undeclared.desk_groups
    assert row.list_preview == @pulled_undeclared.list_preview
  end

  # The mirror: what the four DECLARED columns look like once TagRegistry has
  # written the row in place. Sourced from `schema_attrs/0` so a change to the
  # canonical declaration can never silently pass this bar.
  defp assert_declared_four_are_local(row) do
    attrs = TagRegistry.schema_attrs()

    assert row.title == attrs["title"]
    assert row.icon == attrs["icon"]
    assert row.visibility == attrs["visibility"]
    assert row.fields == attrs["fields"]
  end

  # `capture_log/1` swallows the return value; this keeps the log quiet AND
  # hands back what the call under test returned.
  #
  # `capture_log/1` runs `fun` INLINE in this process, so a raise propagates
  # before the receive is ever reached — the bounded wait is not protecting
  # against that. It is there so that if the shape above ever changes (fun
  # moved to a spawned process, a send dropped), the test fails in a second
  # with a legible message instead of hanging until the ExUnit timeout.
  defp capture_log_value(fun) do
    ref = make_ref()
    parent = self()
    capture_log(fn -> send(parent, {ref, fun.()}) end)

    receive do
      {^ref, value} -> value
    after
      1_000 -> flunk("capture_log_value/1: the call under test never sent its result")
    end
  end
end
