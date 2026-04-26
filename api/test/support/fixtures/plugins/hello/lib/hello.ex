defmodule Barkpark.Plugins.Hello do
  @moduledoc """
  WI1 test fixture plugin. Lives under `test/support/fixtures/plugins/hello/`
  and is compiled in the `:test` env via `elixirc_paths(:test)` in `mix.exs`.

  Phase 3 WI3: the fixture also exposes a tiny `checkers/0` declaration so
  `Barkpark.Validation.PluginCheckerLoader` has something to round-trip in
  tests.
  """

  use Barkpark.Plugin

  @impl Barkpark.Plugin
  def checkers do
    [{"always_ok", Barkpark.Plugins.Hello.AlwaysOk}]
  end
end

defmodule Barkpark.Plugins.Hello.AlwaysOk do
  @moduledoc false
  @behaviour Barkpark.Validation.Checker

  @impl Barkpark.Validation.Checker
  def check(_value, _params), do: :ok
end
