defmodule Mix.Tasks.Barkpark.Workspace.ProvisionSchemasTest do
  @moduledoc """
  THE THIRD `upsert_schema` WRITER (pds-bl-provision-schemas-pulled-warning).

  `bootstrap_guard_test.exs` and `tag_registry_provenance_test.exs` close the
  two BOOT-TIME writers over a pull-provenance-stamped row. This is the third,
  and it is a different animal: `mix barkpark.workspace.provision_schemas` is
  OPERATOR-INVOKED with a dry-run default, so nothing fires it on a restart and
  the boot-path remedy (silently skip the stamped row) would be wrong — it would
  convert a deliberate command into a no-op that reports success.

  The remedy is a REFUSAL with an escape hatch:

    * both modes MARK every target row sitting in a stamped slot
      (`— TARGET IS PULLED DATA`) and print a summary naming them;
    * `--apply` alone REFUSES when any target row is stamped, writes nothing and
      exits non-zero naming `--force`;
    * `--force` proceeds, marks the rows it overwrote, and — the load-bearing
      guard of this file — the write STAYS UNCONDITIONAL: the target row's
      columns really change. A patch that "guards" this task by skipping stamped
      rows reds `the --force write is unconditional …` below.

  The provenance read is the SCOPED face of the canonical predicate,
  `Tenancy.pulled_schema_row?/2` handed the TARGET-scope row. The negative
  control that pins why: `a stamp on the SOURCE workspace marks nothing`, and
  `a stamp on a SIBLING dataset marks nothing` — a by-NAME read would answer
  about the Default dataset slot instead of the workspace being written into.
  """

  use Barkpark.DataCase, async: false

  import ExUnit.CaptureIO

  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures
  alias Mix.Tasks.Barkpark.Workspace.ProvisionSchemas

  @dataset "production"

  @stamp %{
    "source_server" => "https://guerrilla.barkpark.cloud",
    "source_workspace" => "default",
    "source_dataset" => "production",
    "exported_at" => "2026-07-19T12:00:00Z",
    "profile" => "dev",
    "pulled_at" => "2026-07-19T12:05:00Z"
  }

  setup do
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(prev_shell) end)

    source_ws = TenancyFixtures.create_workspace!(unique("src"))
    source_project = TenancyFixtures.create_project!(source_ws, "default")
    ensure_dataset!(source_project, @dataset)

    target_ws = TenancyFixtures.create_workspace!(unique("tgt"))
    target_project = TenancyFixtures.create_project!(target_ws, "default")
    ensure_dataset!(target_project, @dataset)

    %{
      source_ws: source_ws,
      source_scope: scope(source_project),
      source_slug: source_ws.slug,
      target_ws: target_ws,
      target_scope: scope(target_project),
      target_slug: target_ws.slug
    }
  end

  # ── dry run marks, and writes nothing ───────────────────────────────────────

  describe "dry run (the default)" do
    # The stamp's granularity is the (workspace, dataset) SLOT, not the row, so
    # EVERY existing target row in a stamped slot is pulled data and every one
    # of them must be marked. The unmarked controls live in the tests below
    # (a create, a source-only stamp, a sibling-dataset stamp).
    test "marks EVERY existing target row in the stamped slot, and writes nothing", ctx do
      seed_source!(ctx, "paper", "Source Paper")
      seed_source!(ctx, "sheet", "Source Sheet")
      seed_target!(ctx, "paper", "Pulled Paper")
      seed_target!(ctx, "sheet", "Pulled Sheet")
      stamp_target!(ctx)

      out = capture_io(fn -> ProvisionSchemas.run(argv(ctx, ["--schemas", "paper,sheet"])) end)

      assert out =~ "• paper (would update — TARGET IS PULLED DATA)"
      assert out =~ "• sheet (would update — TARGET IS PULLED DATA)"
      assert out =~ "2 target row(s) sit in a pull-provenance-stamped slot: paper, sheet"
      assert out =~ "writing over them requires --apply --force"
      assert out =~ "(dry run — re-run with --apply to write)"

      # The dry run is still a dry run.
      assert title_of(ctx.target_scope, "paper") == "Pulled Paper"
      assert title_of(ctx.target_scope, "sheet") == "Pulled Sheet"
    end

    test "a row that does not exist in the target is a plain create, never marked", ctx do
      seed_source!(ctx, "paper", "Source Paper")
      stamp_target!(ctx)

      out = capture_io(fn -> ProvisionSchemas.run(argv(ctx, ["--schemas", "paper"])) end)

      assert out =~ "• paper (would create)"
      refute out =~ "TARGET IS PULLED DATA"
      refute out =~ "pull-provenance-stamped slot"
    end
  end

  # ── --apply alone refuses over a stamped target ─────────────────────────────

  describe "--apply over a stamped target row" do
    test "refuses, names --force, exits non-zero and writes nothing", ctx do
      seed_source!(ctx, "paper", "Source Paper")
      seed_target!(ctx, "paper", "Pulled Paper")
      stamp_target!(ctx)

      out =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/re-run with --force/, fn ->
            ProvisionSchemas.run(argv(ctx, ["--schemas", "paper", "--apply"]))
          end
        end)

      # The refusal still LISTS the stamped rows, plainly marked.
      assert out =~ "• paper (would update — TARGET IS PULLED DATA)"
      assert out =~ "1 target row(s) sit in a pull-provenance-stamped slot: paper"

      # Nothing was written.
      assert title_of(ctx.target_scope, "paper") == "Pulled Paper"
    end

    test "a stamp on the SOURCE workspace marks nothing — the read is TARGET-scoped", ctx do
      seed_source!(ctx, "paper", "Source Paper")
      seed_target!(ctx, "paper", "Local Paper")
      {:ok, _} = Tenancy.set_pull_provenance(ctx.source_ws.id, @dataset, @stamp)

      out =
        capture_io(fn -> ProvisionSchemas.run(argv(ctx, ["--schemas", "paper", "--apply"])) end)

      assert out =~ "✓ paper (update)"
      refute out =~ "TARGET IS PULLED DATA"
      assert title_of(ctx.target_scope, "paper") == "Source Paper"
    end

    test "a stamp on a SIBLING dataset of the target marks nothing", ctx do
      seed_source!(ctx, "paper", "Source Paper")
      seed_target!(ctx, "paper", "Local Paper")
      {:ok, _} = Tenancy.set_pull_provenance(ctx.target_ws.id, "staging", @stamp)

      out =
        capture_io(fn -> ProvisionSchemas.run(argv(ctx, ["--schemas", "paper", "--apply"])) end)

      assert out =~ "✓ paper (update)"
      refute out =~ "TARGET IS PULLED DATA"
      assert title_of(ctx.target_scope, "paper") == "Source Paper"
    end
  end

  # ── --force proceeds, and the write stays unconditional ─────────────────────

  describe "--force" do
    test "the --force write is unconditional — the stamped target row really changes", ctx do
      seed_source!(ctx, "paper", "Source Paper")
      seed_target!(ctx, "paper", "Pulled Paper")
      stamp_target!(ctx)

      out =
        capture_io(fn ->
          ProvisionSchemas.run(argv(ctx, ["--schemas", "paper", "--apply", "--force"]))
        end)

      assert out =~ "✓ paper (update — TARGET IS PULLED DATA)"
      assert out =~ "--force: overwrote 1 pull-provenance-stamped target row(s)"

      # THE GUARD: a patch that turns the stamped row into a silent skip reds here.
      assert title_of(ctx.target_scope, "paper") == "Source Paper"
    end

    test "with no stamped rows the write is unconditional and nothing is marked", ctx do
      seed_source!(ctx, "paper", "Source Paper")
      seed_target!(ctx, "paper", "Local Paper")

      out =
        capture_io(fn -> ProvisionSchemas.run(argv(ctx, ["--schemas", "paper", "--apply"])) end)

      assert out =~ "✓ paper (update)"
      refute out =~ "TARGET IS PULLED DATA"
      refute out =~ "pull-provenance-stamped slot"
      assert title_of(ctx.target_scope, "paper") == "Source Paper"
    end
  end

  # ── the predicate's scoped face ─────────────────────────────────────────────

  describe "Tenancy.pulled_schema_row?/2 on a SCOPED row" do
    test "answers about THAT row's workspace, not about the Default slot", ctx do
      seed_target!(ctx, "paper", "Pulled Paper")
      {:ok, row} = Content.get_schema("paper", @dataset, ctx.target_scope)

      refute Tenancy.pulled_schema_row?(row, @dataset)

      {:ok, _} = Tenancy.set_pull_provenance(ctx.target_ws.id, @dataset, @stamp)
      assert Tenancy.pulled_schema_row?(row, @dataset)

      # Clearing the stamp is the documented escape hatch, and it un-marks.
      {:ok, _} = Tenancy.set_pull_provenance(ctx.target_ws.id, @dataset, %{})
      refute Tenancy.pulled_schema_row?(row, @dataset)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp scope(project), do: [workspace_id: project.workspace_id, project_id: project.id]

  defp argv(ctx, rest),
    do: [ctx.target_slug, "--project", "default", "--from", ctx.source_slug] ++ rest

  defp ensure_dataset!(project, slug) do
    case Tenancy.get_dataset(project, slug) do
      nil ->
        {:ok, ds} = Tenancy.create_dataset(project, %{slug: slug, name: slug})
        ds

      ds ->
        ds
    end
  end

  defp seed_source!(ctx, name, title), do: seed!(ctx.source_scope, name, title)
  defp seed_target!(ctx, name, title), do: seed!(ctx.target_scope, name, title)

  defp seed!(scope, name, title) do
    {:ok, row} =
      Content.upsert_schema(
        %{
          "name" => name,
          "title" => title,
          "icon" => "icon-#{title}",
          "visibility" => "public",
          "fields" => [%{"name" => "body", "type" => "text"}]
        },
        @dataset,
        scope
      )

    row
  end

  defp stamp_target!(ctx) do
    {:ok, ws} = Tenancy.set_pull_provenance(ctx.target_ws.id, @dataset, @stamp)
    ws
  end

  defp title_of(scope, name) do
    {:ok, row} = Content.get_schema(name, @dataset, scope)
    row.title
  end
end
