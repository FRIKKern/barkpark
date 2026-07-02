defmodule BarkparkCloud.Templates.AppFilesTest do
  @moduledoc """
  The deployable app-file catalog + render (gh-3): which templates back a repo,
  and that `render/2` reproduces the create-barkpark-app scaffold transform
  (name/tmpl renames, `.gitkeep` drop, `{{…}}` substitution).
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Templates.AppFiles

  describe "app_slugs?/app_template?" do
    test "exactly the deployable starters, sorted" do
      assert AppFiles.app_slugs() == ["blog-starter", "website-starter"]
    end

    test "place-directory is NOT creatable (no deployable app tree)" do
      refute AppFiles.app_template?("place-directory")
      assert AppFiles.app_template?("blog-starter")
      refute AppFiles.app_template?("nope")
      refute AppFiles.app_template?(nil)
    end
  end

  describe "render/2" do
    test "unknown template → {:error, :unknown_template}" do
      assert AppFiles.render("place-directory", "my-blog") == {:error, :unknown_template}
      assert AppFiles.render("no-such", "my-blog") == {:error, :unknown_template}
    end

    test "blog-starter renders the app, with names transformed and placeholders filled" do
      {:ok, files} = AppFiles.render("blog-starter", "My Blog")
      paths = Enum.map(files, & &1.path)

      # .tmpl stripped, _gitignore renamed, the manifest + app present.
      assert "package.json" in paths
      assert "barkpark.config.ts" in paths
      assert ".gitignore" in paths
      assert "barkpark.template.json" in paths
      assert "app/page.tsx" in paths

      # No raw template artifacts leak into the pushed repo.
      refute Enum.any?(paths, &String.ends_with?(&1, ".tmpl"))
      refute "_gitignore" in paths
      refute Enum.any?(paths, &(Path.basename(&1) == ".gitkeep"))

      pkg = Enum.find(files, &(&1.path == "package.json"))
      # {{packageName}} → slugified name; no unfilled tokens remain.
      assert pkg.content =~ ~s("name": "my-blog")
      refute pkg.content =~ "{{packageName}}"
    end

    test "package name is slugified from an arbitrary repo name" do
      assert AppFiles.to_package_name("My Cool Blog!") == "my-cool-blog"
      assert AppFiles.to_package_name("__weird--Name__") == "weird-name__"
      assert AppFiles.to_package_name("") == "barkpark-site"
      assert AppFiles.to_package_name("!!!") == "barkpark-site"
    end

    test "content is the raw (unencoded) text push_files expects" do
      {:ok, files} = AppFiles.render("website-starter", "site")
      manifest = Enum.find(files, &(&1.path == "barkpark.template.json"))
      assert is_binary(manifest.content)
      assert manifest.content =~ "\"name\""
    end
  end
end
