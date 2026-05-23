defmodule Mix.Tasks.Barkpark.Plugin.New do
  @moduledoc """
  Scaffold a new Barkpark plugin skeleton.

  ## Usage

      mix barkpark.plugin.new <name> [options]

  ## Options

    * `--root PATH`          — base directory the layout is rooted at
      (default `.`, the `api/` cwd). The manifest, entry module, and test
      destinations are all derived from this.
    * `--out PATH`           — override for the manifest (priv) directory only
      (default `<root>/priv/plugins/<name>`)
    * `--module ModuleName`  — module name (default `Barkpark.Plugins.<Pascal>`)
    * `--description "..."`  — manifest description (default boilerplate)
    * `--capabilities r,w,s` — CSV list of capability names (default empty).
      Single-letter shortcuts: `r`→`routes`, `w`→`workers`, `s`→`schemas`,
      `n`→`node`, `c`→`codelists`, `t`→`settings`. Full names also accepted.
    * `--force`              — overwrite existing output files

  The generated skeleton mirrors the working OnixEdit layout so the plugin
  actually registers: the entry module lands in the COMPILED tree at
  `<root>/lib/barkpark/plugins/<name>.ex` (where `elixirc_paths` can see it),
  the manifest at `<root>/priv/plugins/<name>/plugin.json` carries an explicit
  `"module"` key so `Barkpark.Plugins.Registry.resolve_module/1` agrees with
  what the module defines, and the test lands on the `mix test` path at
  `<root>/test/barkpark/plugins/<name>_test.exs`.

  The generated skeleton uses the `Barkpark.Plugin` behaviour at compile
  time (D7 — no runtime eval) and produces a `plugin.json` that validates
  against `Barkpark.Plugins.Manifest` (D20 — `plugin_name` discriminator).
  """
  @shortdoc "Scaffold a new Barkpark plugin skeleton."

  use Mix.Task

  @switches [
    root: :string,
    out: :string,
    module: :string,
    description: :string,
    capabilities: :string,
    force: :boolean
  ]

  @slug_regex ~r/^[a-z][a-z0-9_-]*$/

  # Each template renders to a destination resolved against the assigns.
  # The manifest + README + schemas live under the priv dir; the entry
  # module and test live in the compiled `lib/` and `test/` trees so the
  # plugin actually registers and is exercised by `mix test`.
  @templates [
    {"plugin.json.eex", :manifest},
    {"lib/plugin.ex.eex", :lib_module},
    {"README.md.eex", :readme},
    {"test/plugin_test.exs.eex", :test_module}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, positional, _invalid} = OptionParser.parse(argv, strict: @switches)

    name =
      case positional do
        [n | _] ->
          n

        [] ->
          Mix.raise("""
          Plugin name is required.

              mix barkpark.plugin.new <name>
          """)
      end

    root = Keyword.get(opts, :root, ".")
    priv_dir = Keyword.get(opts, :out, default_priv_dir(root, name))
    paths = build_paths(root, name, priv_dir)

    assigns = build_assigns(name, opts)
    force? = Keyword.get(opts, :force, false)

    ensure_writable!(paths, force?)
    generate(paths, assigns)
    print_next_steps(paths, assigns)

    :ok
  end

  defp default_priv_dir(root, name), do: Path.join([root, "priv", "plugins", name])

  # Resolves the three destinations. The manifest, README and schemas/
  # dir live under `priv_dir`; the entry module and test live in the
  # compiled trees rooted at `root`.
  defp build_paths(root, name, priv_dir) do
    %{
      priv_dir: priv_dir,
      manifest: Path.join(priv_dir, "plugin.json"),
      readme: Path.join(priv_dir, "README.md"),
      schemas_keep: Path.join([priv_dir, "schemas", ".gitkeep"]),
      lib_module: Path.join([root, "lib", "barkpark", "plugins", name <> ".ex"]),
      test_module: Path.join([root, "test", "barkpark", "plugins", name <> "_test.exs"])
    }
  end

  defp build_assigns(name, opts) do
    unless Regex.match?(@slug_regex, name) do
      Mix.raise("""
      Invalid plugin name: #{inspect(name)}

      Names must match #{inspect(@slug_regex.source)} — start with a lowercase
      letter, then lowercase letters, digits, hyphens or underscores.
      """)
    end

    description = Keyword.get(opts, :description, "A Barkpark plugin named " <> name <> ".")

    capabilities = parse_capabilities(Keyword.get(opts, :capabilities))
    module = Keyword.get(opts, :module, default_module(name))

    %{
      plugin_name: name,
      module: module,
      manifest_rel: manifest_rel(name),
      description: description,
      capabilities: capabilities
    }
  end

  # Relative path from the entry module's dir (`lib/barkpark/plugins/`)
  # to its manifest under `priv/plugins/<name>/`. Three `..` climbs reach
  # the app root, same as the OnixEdit reference module.
  defp manifest_rel(name) do
    Path.join(["../../../priv/plugins", name, "plugin.json"])
  end

  defp parse_capabilities(nil), do: []

  defp parse_capabilities(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&expand_capability/1)
    |> Enum.uniq()
  end

  defp expand_capability("r"), do: "routes"
  defp expand_capability("w"), do: "workers"
  defp expand_capability("s"), do: "schemas"
  defp expand_capability("n"), do: "node"
  defp expand_capability("c"), do: "codelists"
  defp expand_capability("t"), do: "settings"
  defp expand_capability(other), do: other

  # Namespaced default so it matches what `Registry.resolve_module/1`
  # derives from `plugin_name` (same `Macro.camelize` per-segment, same
  # `Barkpark.Plugins.` prefix). An explicit `--module` overrides this.
  defp default_module(name) do
    pascal =
      name
      |> String.split(~r/[_\-\s]+/, trim: true)
      |> Enum.map_join("", &Macro.camelize/1)

    "Barkpark.Plugins." <> pascal
  end

  # Files are scattered across the priv dir and the shared lib/+test/
  # trees, so we guard each generated file individually rather than
  # wiping a single output directory (which would destroy unrelated code
  # under `lib/barkpark/plugins/`). The priv dir is treated as the plugin's
  # own — `--force` clears it wholesale.
  defp ensure_writable!(paths, force?) do
    targets = [paths.manifest, paths.readme, paths.lib_module, paths.test_module]
    existing = Enum.filter(targets, &File.exists?/1)

    if existing != [] and not force? do
      Mix.raise("""
      Refusing to overwrite existing files:

      #{Enum.map_join(existing, "\n", &("  - " <> &1))}

      Pass `--force` to overwrite.
      """)
    end

    if force? and File.exists?(paths.priv_dir) do
      File.rm_rf!(paths.priv_dir)
    end
  end

  defp generate(paths, assigns) do
    template_root = template_root()

    for {src, key} <- @templates do
      target = Map.fetch!(paths, key)
      File.mkdir_p!(Path.dirname(target))
      content = render_eex(Path.join(template_root, src), assigns)
      File.write!(target, content)
      Mix.shell().info("* creating #{Path.relative_to_cwd(target)}")
    end

    File.mkdir_p!(Path.dirname(paths.schemas_keep))
    File.write!(paths.schemas_keep, "")
    Mix.shell().info("* creating #{Path.relative_to_cwd(paths.schemas_keep)}")
  end

  defp render_eex(path, assigns) do
    EEx.eval_file(path, assigns: Map.to_list(assigns))
  end

  defp template_root do
    Path.join([
      Application.app_dir(:barkpark, "priv"),
      "templates",
      "plugin_new"
    ])
  end

  defp print_next_steps(paths, %{module: module}) do
    schemas_dir = Path.join(paths.priv_dir, "schemas")

    Mix.shell().info("""

    Plugin scaffold created.

      module:   #{Path.relative_to_cwd(paths.lib_module)}  (#{module})
      manifest: #{Path.relative_to_cwd(paths.manifest)}
      test:     #{Path.relative_to_cwd(paths.test_module)}

    Next steps:

      1. Run `mix compile` to compile the entry module.
      2. Restart the server. `Barkpark.Plugins.Registry` auto-discovers
         the plugin from its manifest in `priv/plugins/` — no manual
         registry edit. (When the `:plugins` config is unset, discovery is
         automatic; when set, it acts as a whitelist of `plugin_name`s.)
      3. Drop schemas into `#{schemas_dir}`.
      4. Run `mix test #{Path.relative_to_cwd(paths.test_module)}`.
    """)
  end
end
