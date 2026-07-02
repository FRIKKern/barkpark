defmodule BarkparkCloud.Templates.AppFilesDriftTest do
  @moduledoc """
  The DRIFT TRIPWIRE for the vendored deployable app trees (gh-3). Every file
  under `cloud/priv/templates/<slug>/` must be byte-identical to its canonical
  sibling in `js/packages/create-barkpark-app/templates/<slug>/`, BOTH
  directions — so a repo the deploy button pushes is exactly what
  `create-barkpark-app` scaffolds locally, and neither side can be edited alone.
  Re-sync with `make cloud-templates-sync`. Mirrors the provisioner's
  `TestEmbeddedCatalogMatchesRepoRoot`.
  """
  use ExUnit.Case, async: true

  @vendored Path.expand("../../../priv/templates", __DIR__)
  @source Path.expand(
            "../../../../js/packages/create-barkpark-app/templates",
            __DIR__
          )

  defp files_rel(root) do
    root
    |> walk()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  defp walk(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn e ->
      p = Path.join(dir, e)
      if File.dir?(p), do: walk(p), else: [p]
    end)
  end

  defp slug_dirs(root) do
    root
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(root, &1)))
    |> Enum.sort()
  end

  test "every vendored slug exists in the create-barkpark-app source (no orphan copy)" do
    for slug <- slug_dirs(@vendored) do
      assert File.dir?(Path.join(@source, slug)),
             "vendored template #{slug} has no create-barkpark-app source — remove it or re-sync"
    end
  end

  test "every vendored file is byte-identical to its create-barkpark-app source" do
    for slug <- slug_dirs(@vendored),
        rel <- files_rel(Path.join(@vendored, slug)) do
      vendored = File.read!(Path.join([@vendored, slug, rel]))
      source_path = Path.join([@source, slug, rel])

      assert File.exists?(source_path),
             "vendored #{slug}/#{rel} has no source counterpart — run `make cloud-templates-sync`"

      assert vendored == File.read!(source_path),
             "vendored #{slug}/#{rel} has DRIFTED from create-barkpark-app — run `make cloud-templates-sync`"
    end
  end

  test "every deployable create-barkpark-app template is vendored, byte-for-byte" do
    # AVAILABLE_TEMPLATES in js/.../constants.ts — the templates that ship a
    # deployable app. place-directory (schemas+seeds only) is intentionally not
    # among them and so must NOT be vendored.
    deployable = ["blog-starter", "website-starter"]

    assert slug_dirs(@vendored) == deployable,
           "the vendored set drifted from create-barkpark-app's deployable templates"

    for slug <- deployable,
        rel <- files_rel(Path.join(@source, slug)) do
      vendored_path = Path.join([@vendored, slug, rel])

      assert File.exists?(vendored_path),
             "create-barkpark-app #{slug}/#{rel} is not vendored — run `make cloud-templates-sync`"

      assert File.read!(vendored_path) == File.read!(Path.join([@source, slug, rel])),
             "create-barkpark-app #{slug}/#{rel} drifted from the vendored copy — run `make cloud-templates-sync`"
    end
  end
end
