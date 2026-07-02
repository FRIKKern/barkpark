defmodule BarkparkCloud.Templates.AppFiles do
  @moduledoc """
  The DEPLOYABLE app-file catalog the gh-3 "Create GitHub repo" flow pushes into
  a user's repo. Each known template's Next.js app tree (`package.json`,
  `next.config`, `app/`, `.env.example`, `vercel`-ready config,
  `barkpark.template.json`) is vendored under `cloud/priv/templates/<slug>/` —
  the cloud image (`cloud/Dockerfile`) COPYs only `lib/ priv/ config/`, so the
  monorepo `js/` source is NOT reachable at run time and a vendored copy is the
  only way the control plane can hand these bytes to GitHub.

  ## Source of truth + drift

  The canonical trees are the `create-barkpark-app` starters
  (`js/packages/create-barkpark-app/templates/<slug>/`) — the SAME files the CLI
  scaffolds locally — so a repo created from the deploy button is byte-for-byte
  the repo `npx create-barkpark-app` would produce. `make cloud-templates-sync`
  re-vendors them and `BarkparkCloud.Templates.AppFilesDriftTest` fails the build
  on any drift (both directions), mirroring the provisioner's
  `provisioner-catalog-sync` + `TestEmbeddedCatalogMatchesRepoRoot` precedent.

  Only templates that ship a DEPLOYABLE app are here: `create-barkpark-app`'s
  `AVAILABLE_TEMPLATES` = `website-starter`, `blog-starter`. `place-directory`
  exists in the public catalog (`BarkparkCloud.Templates`) as a launchable
  managed instance but has no standalone app tree, so it is NOT creatable as a
  repo (the endpoint 422s `unknown_template`) — honest, not a silent empty push.

  ## Rendering = the CLI scaffold, reproduced

  `render/2` reproduces `create-barkpark-app`'s `scaffold.ts` transform so the
  pushed files are what a local scaffold would write:

    * `_gitignore` → `.gitignore`, `_npmrc` → `.npmrc`
    * a trailing `.tmpl` is stripped
    * `.gitkeep` placeholders are dropped
    * `{{projectName}}` / `{{packageName}}` / `{{pmCommand}}` are substituted
      (unknown `{{…}}` tokens are left verbatim, exactly like the CLI)

  `pmCommand` is fixed to `"npm run"` — the pushed repo deploys to Vercel, whose
  default install/build uses npm.
  """

  @pm_command "npm run"

  @doc "The vendored template slugs (sorted) — the ones a repo can be created from."
  @spec app_slugs() :: [String.t()]
  def app_slugs do
    case File.ls(templates_root()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(templates_root(), &1)))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc "Whether `slug` ships a deployable app tree (and so can back a repo)."
  @spec app_template?(term()) :: boolean()
  def app_template?(slug) when is_binary(slug), do: slug in app_slugs()
  def app_template?(_), do: false

  @doc """
  Render a template's app tree into a `[%{path: rel_path, content: text}]` batch
  ready for `GitHub.Client.push_files/4`, with the CLI scaffold transform applied
  and `name` woven into the `{{…}}` placeholders. Returns
  `{:error, :unknown_template}` for a slug with no vendored app tree.
  """
  @spec render(String.t(), String.t()) ::
          {:ok, [%{path: String.t(), content: String.t()}]} | {:error, :unknown_template}
  def render(slug, name) when is_binary(slug) and is_binary(name) do
    dir = Path.join(templates_root(), slug)

    if app_template?(slug) and File.dir?(dir) do
      vars = %{
        "projectName" => name,
        "packageName" => to_package_name(name),
        "pmCommand" => @pm_command
      }

      files =
        dir
        |> list_files()
        |> Enum.reject(&(Path.basename(&1) == ".gitkeep"))
        |> Enum.map(fn abs ->
          rel = Path.relative_to(abs, dir)
          %{path: render_path(rel), content: render_template(File.read!(abs), vars)}
        end)
        |> Enum.sort_by(& &1.path)

      {:ok, files}
    else
      {:error, :unknown_template}
    end
  end

  def render(_, _), do: {:error, :unknown_template}

  @doc """
  Turn a repo name into a valid npm package name — mirror of
  `create-barkpark-app`'s `toPackageName`: lowercase, non-URL-safe runs collapsed
  to `-`, no leading `.`/`_`, never empty.
  """
  @spec to_package_name(String.t()) :: String.t()
  def to_package_name(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\-_.]+/, "-")
      |> String.replace(~r/^[._]+/, "")
      |> String.replace(~r/-+/, "-")
      |> String.replace(~r/^-+|-+$/, "")

    if slug == "", do: "barkpark-site", else: slug
  end

  ## Internals ───────────────────────────────────────────────────────────────

  # Rename the file's BASENAME the way scaffold.ts does; the directory path is
  # left intact.
  defp render_path(rel) do
    dir = Path.dirname(rel)
    base = rel |> Path.basename() |> rename_base()
    if dir in [".", ""], do: base, else: Path.join(dir, base)
  end

  defp rename_base("_gitignore"), do: ".gitignore"
  defp rename_base("_npmrc"), do: ".npmrc"

  defp rename_base(base) do
    if String.ends_with?(base, ".tmpl"),
      do: String.replace_suffix(base, ".tmpl", ""),
      else: base
  end

  # Substitute `{{ key }}` tokens; an unknown key is left verbatim (parity with
  # the CLI's renderTemplate).
  defp render_template(input, vars) do
    Regex.replace(~r/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/, input, fn whole, key ->
      Map.get(vars, key, whole)
    end)
  end

  defp list_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)
      if File.dir?(path), do: list_files(path), else: [path]
    end)
  end

  defp templates_root, do: Application.app_dir(:barkpark_cloud, "priv/templates")
end
