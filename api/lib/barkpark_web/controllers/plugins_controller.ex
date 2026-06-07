defmodule BarkparkWeb.PluginsController do
  @moduledoc """
  `GET /v1/plugins` — admin-only roster of the installed plugins.

  Mounted under the `:api` + `:require_admin` pipeline (see the `scope
  "/v1/plugins"` admin-tier block in `BarkparkWeb.Router`), so an
  unauthenticated caller gets 401 and a non-admin token gets 403. This is the
  real route behind the capabilities manifest's `plugin.ls` core command.

  The roster is sourced from `Barkpark.Plugins.Registry.all/0`, which returns a
  list of `%{module:, manifest:, name:}` entries — `manifest` being the parsed
  `plugin.json`. We project each entry down to the publicly meaningful triple:
  `name` / `version` / `capabilities`.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Plugins.Registry

  def index(conn, _params) do
    plugins =
      Registry.all()
      |> Enum.map(&project_entry/1)
      |> Enum.sort_by(& &1.name)

    json(conn, %{plugins: plugins})
  end

  # Registry.all/0 entry shape: %{module: module(), manifest: map(), name: String.t()}
  # where `manifest` is the decoded plugin.json (string keys: "version",
  # "capabilities", "description", …). Fall back to the entry name when the
  # manifest is missing the name, and to sane empties for optional fields.
  defp project_entry(%{name: name, manifest: manifest}) when is_map(manifest) do
    %{
      name: Map.get(manifest, "plugin_name", name),
      version: Map.get(manifest, "version"),
      capabilities: Map.get(manifest, "capabilities", [])
    }
  end

  defp project_entry(%{name: name}) do
    %{name: name, version: nil, capabilities: []}
  end
end
