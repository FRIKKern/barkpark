defmodule Barkpark.Plugin do
  @moduledoc """
  Behaviour + `use` macro for first-party Barkpark plugins.

  Compile-time discovery only. NO `Code.eval_*`, `Code.compile_string`, or any
  runtime macro evaluation (decision D7 from
  `.doey/plans/masterplan-20260425-085425.md`). Plugins are first-party trusted
  Elixir modules — the manifest JSON is read at compile time of the plugin
  module via `__using__/1`, validated, and frozen as a literal in
  `manifest/0`.

  ## Usage

      defmodule MyApp.Plugins.Hello do
        use Barkpark.Plugin
      end

  By default the macro reads `plugin.json` from the parent directory of the
  using module's source file (e.g. `priv/plugins/hello/plugin.json` when the
  module lives at `priv/plugins/hello/lib/hello.ex`). Pass
  `manifest_path: "..."` to override.
  """

  @callback manifest() :: map()
  @callback register_routes(any()) :: any()
  @callback register_workers(any()) :: [Supervisor.child_spec()]
  @callback register_schemas(keyword()) :: [Barkpark.Content.SchemaDefinition.t()]
  @callback validate_settings(map()) :: :ok | {:error, [{atom(), String.t()}]}

  @optional_callbacks register_routes: 1,
                      register_workers: 1,
                      register_schemas: 1,
                      validate_settings: 1

  defmacro __using__(opts) do
    caller_dir = Path.dirname(__CALLER__.file)

    manifest_path =
      case Keyword.fetch(opts, :manifest_path) do
        {:ok, p} -> Path.expand(p, caller_dir)
        :error -> Path.expand("../plugin.json", caller_dir)
      end

    manifest =
      manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> Barkpark.Plugins.Manifest.validate!()

    quote do
      @behaviour Barkpark.Plugin
      @external_resource unquote(manifest_path)
      @barkpark_plugin_manifest unquote(Macro.escape(manifest))
      @barkpark_plugin_manifest_path unquote(manifest_path)

      @impl Barkpark.Plugin
      def manifest, do: @barkpark_plugin_manifest

      @impl Barkpark.Plugin
      def register_routes(_router), do: :ok

      @impl Barkpark.Plugin
      def register_workers(_supervisor), do: []

      @impl Barkpark.Plugin
      def register_schemas(_opts), do: []

      @impl Barkpark.Plugin
      def validate_settings(_settings), do: :ok

      defoverridable manifest: 0,
                     register_routes: 1,
                     register_workers: 1,
                     register_schemas: 1,
                     validate_settings: 1
    end
  end
end
