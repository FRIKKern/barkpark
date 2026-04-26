defmodule Mix.Tasks.Barkpark.Plugin.New do
  @moduledoc """
  Scaffold a new Barkpark plugin skeleton.

  ## Usage

      mix barkpark.plugin.new <name> [options]

  ## Options

    * `--out PATH`           — output directory (default `priv/plugins/<name>`)
    * `--module ModuleName`  — module name (default derived from `<name>`)
    * `--description "..."`  — manifest description (default boilerplate)
    * `--capabilities r,w,s` — CSV list of capability names (default empty).
      Single-letter shortcuts: `r`→`routes`, `w`→`workers`, `s`→`schemas`,
      `n`→`node`, `c`→`codelists`, `t`→`settings`. Full names also accepted.
    * `--force`              — overwrite an existing output directory

  The generated skeleton uses the `Barkpark.Plugin` behaviour at compile
  time (D7 — no runtime eval) and produces a `plugin.json` that validates
  against `Barkpark.Plugins.Manifest` (D20 — `plugin_name` discriminator).
  """
  @shortdoc "Scaffold a new Barkpark plugin skeleton."

  use Mix.Task

  @switches [
    out: :string,
    module: :string,
    description: :string,
    capabilities: :string,
    force: :boolean
  ]

  @slug_regex ~r/^[a-z][a-z0-9_-]*$/

  @templates [
    {"plugin.json.eex", "plugin.json"},
    {"lib/plugin.ex.eex", :lib_module},
    {"README.md.eex", "README.md"},
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

    assigns = build_assigns(name, opts)
    out_dir = Keyword.get(opts, :out, default_out(name))
    force? = Keyword.get(opts, :force, false)

    ensure_writable!(out_dir, force?)
    generate(out_dir, assigns)
    print_next_steps(out_dir, assigns)

    :ok
  end

  defp default_out(name), do: Path.join(["priv", "plugins", name])

  defp build_assigns(name, opts) do
    unless Regex.match?(@slug_regex, name) do
      Mix.raise("""
      Invalid plugin name: #{inspect(name)}

      Names must match #{inspect(@slug_regex.source)} — start with a lowercase
      letter, then lowercase letters, digits, hyphens or underscores.
      """)
    end

    description =
      Keyword.get(opts, :description, "A Barkpark plugin named " <> name <> ".")

    capabilities = parse_capabilities(Keyword.get(opts, :capabilities))
    module = Keyword.get(opts, :module, default_module(name))

    %{
      plugin_name: name,
      module: module,
      description: description,
      capabilities: capabilities
    }
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

  defp default_module(name) do
    name
    |> String.split(["-", "_"], trim: true)
    |> Enum.map_join("", &String.capitalize/1)
  end

  defp ensure_writable!(out_dir, force?) do
    if File.exists?(out_dir) and not force? do
      Mix.raise("""
      Output directory already exists: #{out_dir}

      Pass `--force` to overwrite.
      """)
    end

    if force? and File.exists?(out_dir) do
      File.rm_rf!(out_dir)
    end

    File.mkdir_p!(out_dir)
  end

  defp generate(out_dir, assigns) do
    template_root = template_root()

    for {src, dest} <- @templates do
      target = resolve_target(dest, assigns, out_dir)
      File.mkdir_p!(Path.dirname(target))

      content =
        if String.ends_with?(src, ".eex") do
          render_eex(Path.join(template_root, src), assigns)
        else
          File.read!(Path.join(template_root, src))
        end

      File.write!(target, content)
      Mix.shell().info("* creating #{Path.relative_to_cwd(target)}")
    end

    schemas_keep = Path.join([out_dir, "schemas", ".gitkeep"])
    File.mkdir_p!(Path.dirname(schemas_keep))
    File.write!(schemas_keep, "")
    Mix.shell().info("* creating #{Path.relative_to_cwd(schemas_keep)}")
  end

  defp resolve_target(:lib_module, %{plugin_name: name}, out_dir),
    do: Path.join([out_dir, "lib", name <> ".ex"])

  defp resolve_target(:test_module, %{plugin_name: name}, out_dir),
    do: Path.join([out_dir, "test", name <> "_test.exs"])

  defp resolve_target(rel, _assigns, out_dir) when is_binary(rel),
    do: Path.join(out_dir, rel)

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

  defp print_next_steps(out_dir, %{plugin_name: name}) do
    Mix.shell().info("""

    Plugin scaffold created at #{Path.relative_to_cwd(out_dir)}.

    Next steps:

      1. Run `mix compile` to verify the skeleton compiles.
      2. Add the module to your plugin registry (see
         `Barkpark.Plugins.Registry.discover_and_register/0`).
      3. Drop schemas into `#{Path.join(out_dir, "schemas")}`.
      4. Run `mix test test/#{name}_test.exs` once tests are wired up.
    """)
  end
end
