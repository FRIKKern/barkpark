defmodule Mix.Tasks.Barkpark.Workspace.ImportDatasetTest do
  @moduledoc """
  `mix barkpark.workspace.import_dataset` (task-9a458d67319697b3) passes its
  target straight through to `WorkspaceBundle.import_bundle_file/2`'s
  `:into_dataset` option: a dataset bundle exported from workspace A lands as
  a new dataset in workspace B, and a refusal exits non-zero naming the
  engine's reason.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureIO

  alias Barkpark.{BootModeSandbox, Content, Repo, TenancyFixtures}
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Mix.Tasks.Barkpark.Workspace.ImportDataset

  @src "src"

  setup do
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(prev_shell) end)

    ws_a = TenancyFixtures.create_workspace!(unique("wsa"))
    proj_a = TenancyFixtures.create_project!(ws_a, unique("proja"))
    scope = [workspace_id: ws_a.id, project_id: proj_a.id]
    {:ok, _} = Content.create_document("post", %{"doc_id" => "b", "title" => "B"}, @src, scope)

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "a", "title" => "A", "next" => %{"_ref" => "b"}},
        @src,
        scope
      )

    {:ok, path} = WorkspaceBundle.export_to_file(ws_a.id, dataset: @src)
    on_exit(fn -> File.rm(path) end)

    ws_b = TenancyFixtures.create_workspace!(unique("wsb"))
    proj_b = TenancyFixtures.create_project!(ws_b, unique("projb"))

    %{path: path, ws_a: ws_a, ws_b: ws_b, proj_b: proj_b}
  end

  test "imports the bundle as a new dataset in the named workspace and project", ctx do
    argv =
      [ctx.path, "--workspace", ctx.ws_b.slug, "--project", ctx.proj_b.slug] ++
        ["--dataset", "copy"]

    out = capture_io(fn -> send(self(), {:stats, run_task(argv)}) end)
    assert_received {:stats, stats}

    assert stats.remap.dataset_slug == "copy"
    assert stats.remap.workspace_id == ctx.ws_b.id
    assert stats.remap.project_id == ctx.proj_b.id
    assert stats.remap.source.workspace_id == ctx.ws_a.id
    assert out =~ "imported dataset copy (#{stats.remap.dataset_id})"
    assert out =~ "documents: 2"

    assert Repo.query!(
             "SELECT doc_id FROM documents WHERE dataset_id = $1::text::uuid AND " <>
               "workspace_id = $2::text::uuid ORDER BY doc_id",
             [stats.remap.dataset_id, ctx.ws_b.id]
           ).rows == [["drafts.a"], ["drafts.b"]]
  end

  test "a refusal exits non-zero with the engine's reason and writes nothing", ctx do
    argv =
      [ctx.path, "--workspace", ctx.ws_b.slug, "--project", ctx.proj_b.slug] ++
        ["--dataset", "copy"]

    capture_io(fn -> run_task(argv) end)

    error =
      assert_raise Mix.Error, fn -> capture_io(fn -> run_task(argv) end) end

    assert error.message =~ "import refused (dataset_slug_conflict)"
  end

  test "missing options and an unknown project are refused before anything is read", ctx do
    assert_raise Mix.Error, ~r/missing --dataset/, fn ->
      run_task([ctx.path, "--workspace", ctx.ws_b.slug, "--project", ctx.proj_b.slug])
    end

    assert_raise Mix.Error, ~r/has no project "nope"/, fn ->
      run_task([ctx.path, "--workspace", ctx.ws_b.slug, "--project", "nope", "--dataset", "x"])
    end
  end

  # `run/1` calls `Barkpark.OneShot.boot!/0`, which sets the node-wide boot mode;
  # `BootModeSandbox.protecting/1` puts it back (see provision_schemas_test.exs).
  defp run_task(argv), do: BootModeSandbox.protecting(fn -> ImportDataset.run(argv) end)

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
