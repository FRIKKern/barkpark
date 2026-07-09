defmodule Barkpark.Plugins.Enablement do
  @moduledoc """
  Per-workspace plugin enablement — the resolution layer that decides which
  installed plugins a workspace SURFACES, and where their desk items land.

  Two layers (charter Decision 2):

    * **Installed** — the boot whitelist (`:barkpark, :plugins`) plus discovery.
      Schemas, routes, and Oban workers register at boot for every installed
      plugin regardless of what any workspace surfaces. This module never
      touches that layer.
    * **Surfaced** — a per-workspace jsonb override map at
      `workspaces.settings["plugins"]` that layers on top of each plugin's
      compile-time declaration (`default_enabled?/0` + `structure_placement/0`).

  `effective/1` merges the two into the resolved view the surfacing collectors
  (desk items, top-menu tabs, doc actions) and the tiered-tree builder consume.

  ## The contract (charter Decision 4)

      Barkpark.Plugins.Enablement.effective(workspace_id | nil) ::
        %{optional(plugin_name :: String.t()) =>
            %{enabled: boolean(), placement: :main | :plugins | :top_menu}}

  Resolution rules:

    * `nil` workspace_id — or ANY lookup failure (missing workspace, bad
      settings shape, a raise) — resolves to the declaration defaults only.
      This is the invariant that keeps enablement resolution OFF the Registry
      GenServer registration path: that path carries no workspace, so it never
      reaches a Repo read (which would deadlock the registry).
    * An override map is `%{"<plugin>" => %{"enabled" => bool,
      "placement" => "main" | "plugins" | "top_menu"}}`. Each field is applied
      over the plugin's declaration default; a missing or malformed field
      leaves the declaration value untouched.
    * An **unknown** plugin (present in the override map but not registered, or
      queried by a name the resolved map doesn't carry) resolves to
      `%{enabled: true, placement: :plugins}` — enabled, under the Plugins node.
  """

  alias Barkpark.Plugins.Registry
  alias Barkpark.Tenancy

  @type placement :: :main | :plugins | :top_menu
  @type entry :: %{enabled: boolean(), placement: placement()}

  @default_placement :plugins
  @placements [:main, :plugins, :top_menu]
  @unknown %{enabled: true, placement: :plugins}

  @doc """
  Resolve the effective enablement map for a workspace (or the declaration
  defaults when `workspace_id` is `nil` or the lookup fails).

  See the module doc for the full contract.
  """
  @spec effective(binary() | nil) :: %{optional(String.t()) => entry()}
  def effective(workspace_id) do
    defaults = declaration_defaults()
    overrides = workspace_overrides(workspace_id)
    merge(defaults, overrides)
  end

  @doc """
  Whether `plugin_name` is surfaced in the already-resolved `effective` map.
  An unknown plugin (not in the map) is treated as enabled — the tree must
  never silently hide a plugin the resolution layer hasn't seen.
  """
  @spec enabled?(%{optional(String.t()) => entry()}, String.t()) :: boolean()
  def enabled?(effective, plugin_name) when is_map(effective) do
    case Map.get(effective, plugin_name) do
      %{enabled: enabled} when is_boolean(enabled) -> enabled
      _ -> @unknown.enabled
    end
  end

  @doc """
  Resolve the placement for `plugin_name` in the already-resolved `effective`
  map. An unknown plugin defaults to `:plugins`.
  """
  @spec placement(%{optional(String.t()) => entry()}, String.t()) :: placement()
  def placement(effective, plugin_name) when is_map(effective) do
    case Map.get(effective, plugin_name) do
      %{placement: p} when p in @placements -> p
      _ -> @unknown.placement
    end
  end

  # ── Declaration defaults ──────────────────────────────────────────────────

  # Build the baseline map from every REGISTERED plugin's compile-time
  # declaration. This reads `Registry.all/0` (the persistent_term snapshot —
  # no GenServer.call) and calls the two optional callbacks defensively.
  defp declaration_defaults do
    for %{name: name, module: module} <- Registry.all(), is_binary(name), into: %{} do
      {name, %{enabled: declared_enabled?(module), placement: declared_placement(module)}}
    end
  end

  defp declared_enabled?(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :default_enabled?, 0) do
      case module.default_enabled?() do
        bool when is_boolean(bool) -> bool
        _ -> true
      end
    else
      true
    end
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  defp declared_placement(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :structure_placement, 0) do
      case module.structure_placement() do
        p when p in @placements -> p
        _ -> @default_placement
      end
    else
      @default_placement
    end
  rescue
    _ -> @default_placement
  catch
    _, _ -> @default_placement
  end

  # ── Workspace overrides ────────────────────────────────────────────────────

  # `nil` and any failure resolve to `%{}` (declaration defaults only). This is
  # the guard that keeps a Repo read off the registration path — a nil
  # workspace never touches the DB.
  defp workspace_overrides(nil), do: %{}

  defp workspace_overrides(workspace_id) when is_binary(workspace_id) do
    case Tenancy.get_workspace_by_id(workspace_id) do
      nil -> %{}
      workspace -> Tenancy.workspace_plugin_settings(workspace)
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp workspace_overrides(_), do: %{}

  # ── Merge ──────────────────────────────────────────────────────────────────

  # Layer the override map over the declaration defaults. Every key present in
  # either map appears in the result; an override-only key (a plugin not
  # registered) resolves against the `@unknown` default before its override
  # fields apply.
  defp merge(defaults, overrides) when is_map(defaults) and is_map(overrides) do
    keys = Enum.uniq(Map.keys(defaults) ++ Map.keys(overrides))

    for key <- keys, is_binary(key), into: %{} do
      base = Map.get(defaults, key, @unknown)
      {key, apply_override(base, Map.get(overrides, key))}
    end
  end

  defp merge(defaults, _overrides), do: defaults

  defp apply_override(base, override) when is_map(override) do
    %{
      enabled: override_enabled(base.enabled, override),
      placement: override_placement(base.placement, override)
    }
  end

  defp apply_override(base, _override), do: base

  defp override_enabled(default, override) do
    case fetch(override, "enabled", :enabled) do
      bool when is_boolean(bool) -> bool
      _ -> default
    end
  end

  defp override_placement(default, override) do
    case parse_placement(fetch(override, "placement", :placement)) do
      nil -> default
      p -> p
    end
  end

  # Accept both string-keyed (jsonb round-trip) and atom-keyed (in-memory
  # test) override maps.
  defp fetch(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp parse_placement("main"), do: :main
  defp parse_placement("plugins"), do: :plugins
  defp parse_placement("top_menu"), do: :top_menu
  defp parse_placement(p) when p in @placements, do: p
  defp parse_placement(_), do: nil
end
