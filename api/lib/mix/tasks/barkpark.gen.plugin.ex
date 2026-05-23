defmodule Mix.Tasks.Barkpark.Gen.Plugin do
  @moduledoc """
  DEPRECATED. Use `mix barkpark.plugin.new` instead.

  This task used to scaffold a host-side plugin module under
  `lib/barkpark/plugins/<name>/`, but that shape never registered:
  discovery is manifest-driven from `priv/plugins/<name>/plugin.json`
  (see `Barkpark.Plugins.Registry.default_paths/0`), and the old template
  emitted a module with no `use Barkpark.Plugin`, no manifest, and stale
  "wire it into application.ex" instructions that no longer apply. To avoid
  generating dead code, this task now prints a deprecation notice and
  delegates straight to `mix barkpark.plugin.new`, forwarding all arguments.
  """
  @shortdoc "DEPRECATED — use barkpark.plugin.new"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.shell().info("""
    ==> mix barkpark.gen.plugin is DEPRECATED.
        It scaffolded a host-side module that never registered (discovery is
        manifest-driven from priv/plugins/<name>/plugin.json). Delegating to
        `mix barkpark.plugin.new`, which emits a valid manifest-based plugin.
    """)

    # Re-enable so repeated invocations (e.g. across test cases in one VM)
    # actually delegate each time rather than no-op after the first run.
    Mix.Task.reenable("barkpark.plugin.new")
    Mix.Task.run("barkpark.plugin.new", args)
  end
end
