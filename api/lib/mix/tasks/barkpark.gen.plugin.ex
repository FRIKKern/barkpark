defmodule Mix.Tasks.Barkpark.Gen.Plugin do
  @moduledoc """
  Scaffolds the file structure for a new Barkpark plugin.

      mix barkpark.gen.plugin Vlie

  Creates:
    lib/barkpark/plugins/vlie.ex          (entry module + register_schemas/1)
    lib/barkpark/plugins/vlie/actions.ex  (schema-action handlers)
    lib/barkpark/plugins/vlie/client.ex   (HTTP client skeleton)
    test/barkpark/plugins/vlie/actions_test.exs
    test/barkpark/plugins/vlie/client_test.exs

  All templates are minimal but compile clean. Edit them to implement
  the plugin's real behavior. See `docs/plugins/RECIPE.md` for a worked
  walkthrough; `docs/plugins/INTEGRATION_LESSONS.md` for the formal
  contract — plugins own schemas + business logic, the host owns UI.

  ## Options

    * `--no-test` — skip the two test files
    * `--force`   — overwrite existing files without prompting

  The plugin name accepts PascalCase ("Vlie") or snake_case ("vlie");
  the task derives both forms via `Macro.camelize/1` and
  `Macro.underscore/1`.

  Note: this task scaffolds the host-side plugin module (i.e. plugins
  that ship inside the Barkpark application tree). For external,
  manifest-based plugins in `priv/plugins/<name>/`, use
  `mix barkpark.plugin.new` instead.
  """
  @shortdoc "Scaffold a new Barkpark plugin"

  use Mix.Task

  @switches [no_test: :boolean, force: :boolean]

  @templates [
    {"plugin.ex.eex", &__MODULE__.entry_module_path/1},
    {"actions.ex.eex", &__MODULE__.actions_module_path/1},
    {"client.ex.eex", &__MODULE__.client_module_path/1}
  ]

  @test_templates [
    {"actions_test.exs.eex", &__MODULE__.actions_test_path/1},
    {"client_test.exs.eex", &__MODULE__.client_test_path/1}
  ]

  @impl Mix.Task
  def run([]) do
    Mix.shell().error("Usage: mix barkpark.gen.plugin <Name>")
    exit({:shutdown, 1})
  end

  def run([name | rest]) do
    {opts, _positional, _invalid} = OptionParser.parse(rest, strict: @switches)
    {module_name, snake_name} = normalize_name(name)

    bindings = [
      module_name: module_name,
      module_path: "Barkpark.Plugins." <> module_name,
      snake_name: snake_name,
      external_label: module_name
    ]

    Mix.shell().info(~s|==> Creating plugin scaffold for "#{module_name}" (#{snake_name})|)

    files =
      @templates
      |> Enum.map(fn {tmpl, path_fn} -> {tmpl, path_fn.(snake_name)} end)

    files =
      if opts[:no_test] do
        files
      else
        files ++
          Enum.map(@test_templates, fn {tmpl, path_fn} -> {tmpl, path_fn.(snake_name)} end)
      end

    Enum.each(files, fn {tmpl, target} ->
      render(tmpl, target, bindings, !!opts[:force])
    end)

    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  1. Add Barkpark.Plugins.#{module_name} to your plugin list")
    Mix.shell().info("     (currently hardcoded in application.ex's plugin bootstrap)")
    Mix.shell().info("  2. If you need an ExternalSync pill, add an entry in")
    Mix.shell().info("     lib/barkpark/external_sync.ex's @entries map")
    Mix.shell().info("  3. Wire schema_action dispatch in studio_live.ex if your")
    Mix.shell().info(~s|     actions are kind: "modal" or kind: "event"|)
    Mix.shell().info("  4. See docs/plugins/RECIPE.md for a worked example.")
  end

  ## ── path helpers (public so the @templates capture can reference them) ──

  @doc false
  def entry_module_path(snake), do: "lib/barkpark/plugins/#{snake}.ex"
  @doc false
  def actions_module_path(snake), do: "lib/barkpark/plugins/#{snake}/actions.ex"
  @doc false
  def client_module_path(snake), do: "lib/barkpark/plugins/#{snake}/client.ex"
  @doc false
  def actions_test_path(snake), do: "test/barkpark/plugins/#{snake}/actions_test.exs"
  @doc false
  def client_test_path(snake), do: "test/barkpark/plugins/#{snake}/client_test.exs"

  ## ── internals ──

  @doc false
  def normalize_name(raw) do
    cleaned = String.trim(raw)

    if cleaned == "" do
      Mix.shell().error("Plugin name must not be empty")
      exit({:shutdown, 1})
    end

    snake = Macro.underscore(cleaned)
    module = Macro.camelize(snake)

    unless Regex.match?(~r/^[a-z][a-z0-9_]*$/, snake) do
      Mix.shell().error(
        "Invalid plugin name: #{inspect(raw)}. Use PascalCase (Vlie) or snake_case (vlie)."
      )

      exit({:shutdown, 1})
    end

    {module, snake}
  end

  defp render(template_name, target, bindings, force?) do
    contents = EEx.eval_file(template_path(template_name), assigns: bindings)
    Mix.Generator.create_file(target, contents, force: force?)
  end

  defp template_path(template_name) do
    Path.join([
      Application.app_dir(:barkpark, "priv"),
      "templates",
      "barkpark.gen.plugin",
      template_name
    ])
  end
end
