defmodule BarkparkCloud.Templates.AppFilesDriftTest do
  @moduledoc """
  The DRIFT TRIPWIRE for the vendored deployable app trees (gh-3). Every file
  under `cloud/priv/templates/<slug>/` must be byte-identical to its canonical
  source, BOTH directions — so a repo the deploy button pushes is exactly what
  `create-barkpark-app` scaffolds locally, and neither side can be edited alone.
  Re-sync with `make cloud-templates-sync`. Mirrors the provisioner's
  `TestEmbeddedCatalogMatchesRepoRoot`.

  THE CANONICAL SOURCE IS COMPOSED, NOT A SINGLE DIRECTORY. `create-barkpark-app`
  lays `templates/_shared/` down first and copies `templates/<slug>/` over it
  (scaffold.ts), so the 16 framework-boilerplate files both starters used to
  double-author are authored once and appear in every generated app. This test
  resolves each mirrored file the SAME way — starter dir first, `_shared` as the
  fallback — and walks the composed source set in the reverse direction. A file
  present in NEITHER is still a hard failure, so the tripwire keeps both edges:
  the mirror can hold nothing the composer would not write, and the composer can
  write nothing the mirror lacks. `_shared` is not a slug and must never be
  vendored as one.
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

  # Mirrors SHARED_TEMPLATE_DIR in js/packages/create-barkpark-app/src/constants.ts.
  @shared "_shared"

  defp source_path(slug, rel) do
    starter = Path.join([@source, slug, rel])
    if File.exists?(starter), do: starter, else: Path.join([@source, @shared, rel])
  end

  # Every relative path `scaffold()` would write for `slug`: the shared tree
  # unioned with the starter tree, the starter winning on collision (a union of
  # relative paths — identical strings collapse — so `Enum.uniq` IS the override).
  defp composed_rels(slug) do
    (files_rel(Path.join(@source, @shared)) ++ files_rel(Path.join(@source, slug)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp slug_dirs(root) do
    root
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(root, &1)))
    |> Enum.sort()
  end

  test "the shared template source exists and is never vendored as a slug" do
    # If _shared ever vanishes, composed_rels/1 silently narrows to the starter
    # tree and the whole file-set half of this tripwire goes vacuous.
    assert File.dir?(Path.join(@source, @shared)),
           "templates/#{@shared} is missing — scaffold() composes it under every starter"

    refute File.dir?(Path.join(@vendored, @shared)),
           "#{@shared} is a composition source, not a deployable slug — it must not be vendored"
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
      source_path = source_path(slug, rel)

      assert File.exists?(source_path),
             "vendored #{slug}/#{rel} has no source counterpart in templates/#{slug}/ or " <>
               "templates/#{@shared}/ — run `make cloud-templates-sync`"

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
        rel <- composed_rels(slug) do
      vendored_path = Path.join([@vendored, slug, rel])

      assert File.exists?(vendored_path),
             "create-barkpark-app #{slug}/#{rel} is not vendored — run `make cloud-templates-sync`"

      assert File.read!(vendored_path) == File.read!(source_path(slug, rel)),
             "create-barkpark-app #{slug}/#{rel} drifted from the vendored copy — run `make cloud-templates-sync`"
    end
  end
end
