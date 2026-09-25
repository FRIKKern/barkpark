defmodule BarkparkCloud.TemplatesAppDirTest do
  @moduledoc """
  The Vercel clone handoff's folder decision (task-32e385b29e75c102).

  Without a user repo, the console's `vercelCloneUrl` clones the template's
  default repo, the Barkpark monorepo, and passes Vercel's `root-directory`
  parameter set to the catalog's `app_dir`. A template with `app_dir: nil` gets
  no link and shows `no_app_dir_reason` instead. `BarkparkCloud.Templates` is the
  one place that decides this; this test checks it against two things:

    * the console's mirror, `priv/static/__fixtures__/template_app_dirs.json`,
      which the console suite reads to assert the produced URL for every
      template. Editing one side alone reds here.
    * the repository. Every `app_dir` must be a buildable app for THAT template
      (`package.json` with a real `build` script, and a manifest naming the
      slug), so moving a template's folder reds here. Every `nil` must have a
      reason, and neither place a starter can live may hold a `package.json`
      for it: when one appears, the catalog has to start pointing at it.

  Pure file reading. `templates/**` and
  `js/packages/create-barkpark-app/templates/**` are both in
  `scripts/cloud-path-escape-check.sh`'s CLOUD_PATHS, so a move there runs this.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Templates

  @repo_root Path.expand("../../..", __DIR__)
  @fixture Path.expand("../../priv/static/__fixtures__/template_app_dirs.json", __DIR__)

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  defp catalog_rows do
    Enum.map(Templates.catalog(), fn t ->
      %{
        "slug" => t.slug,
        "app_dir" => Map.fetch!(t, :app_dir),
        "no_app_dir_reason" => Map.fetch!(t, :no_app_dir_reason)
      }
    end)
  end

  test "the console fixture mirrors the catalog's app_dir and reason for every template" do
    assert fixture()["templates"] == catalog_rows(),
           """
           cloud/priv/static/__fixtures__/template_app_dirs.json has drifted from
           BarkparkCloud.Templates' catalog. The console tests assert the Vercel
           clone URL from that fixture, so it must carry the same slug, app_dir and
           no_app_dir_reason, in catalog order. Update both or neither.
           """
  end

  test "the fixture's repo is the catalog's default repo" do
    assert fixture()["repo"] == Templates.default_repo()
  end

  test "every app_dir is a buildable app for that template in this repository" do
    dirs = for %{"slug" => slug, "app_dir" => dir} <- catalog_rows(), dir != nil, do: {slug, dir}

    # Floor: an all-nil catalog would pass the loop below having checked nothing.
    assert length(dirs) >= 2,
           "expected at least two templates with an app_dir, got #{inspect(dirs)}"

    for {slug, dir} <- dirs do
      refute String.starts_with?(dir, "/") or String.contains?(dir, ".."),
             "#{slug}: app_dir must be a path relative to the repo root, got #{inspect(dir)}"

      pkg_path = Path.join([@repo_root, dir, "package.json"])

      assert File.regular?(pkg_path),
             "#{slug}: app_dir #{inspect(dir)} has no package.json. Did the template move? " <>
               "Update app_dir in BarkparkCloud.Templates and the console fixture."

      build = pkg_path |> File.read!() |> Jason.decode!() |> get_in(["scripts", "build"])

      assert is_binary(build) and build != "" and not String.starts_with?(build, "echo"),
             "#{slug}: #{dir}/package.json has no real build script (#{inspect(build)})"

      manifest = Path.join([@repo_root, dir, "barkpark.template.json"])

      assert File.regular?(manifest), "#{slug}: #{dir} has no barkpark.template.json"

      assert Jason.decode!(File.read!(manifest))["name"] == slug,
             "#{slug}: #{dir}/barkpark.template.json names a different template"
    end
  end

  test "every template without an app_dir has a reason and really has no app folder" do
    nils = for %{"slug" => slug, "app_dir" => nil} = row <- catalog_rows(), do: {slug, row}

    for {slug, row} <- nils do
      reason = row["no_app_dir_reason"]

      assert is_binary(reason) and String.length(reason) > 20,
             "#{slug}: app_dir is nil, so no_app_dir_reason must say why (got #{inspect(reason)})"

      for candidate <- [
            Path.join(["templates", slug]),
            Path.join(["js/packages/create-barkpark-app/templates", slug])
          ] do
        refute File.regular?(Path.join([@repo_root, candidate, "package.json"])),
               "#{slug}: #{candidate}/package.json exists, so the template may now have a " <>
                 "buildable folder. Set app_dir to it (and drop no_app_dir_reason) in " <>
                 "BarkparkCloud.Templates and the console fixture."
      end
    end
  end

  test "a template with an app_dir carries no withheld reason" do
    for %{"slug" => slug, "app_dir" => dir, "no_app_dir_reason" => reason} <- catalog_rows(),
        dir != nil do
      assert reason == nil, "#{slug}: has app_dir #{dir} and a withheld reason; pick one"
    end
  end
end
