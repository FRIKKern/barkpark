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

  @doc """
  Look up one plugin's full `%{enabled, placement}` entry in an already-
  resolved `effective/1` map, falling back to the unknown-plugin default
  (`enabled: true, placement: :plugins`) when the map does not carry it.

  Convenience over `enabled?/2` + `placement/2` for callers that need both
  (the tiered-tree builder resolves each plugin's tier from this entry).
  """
  @spec for_plugin(%{optional(String.t()) => entry()}, String.t()) :: entry()
  def for_plugin(effective, plugin_name) when is_map(effective) and is_binary(plugin_name) do
    case Map.get(effective, plugin_name) do
      %{enabled: e, placement: p} when is_boolean(e) and p in @placements ->
        %{enabled: e, placement: p}

      _ ->
        @unknown
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
    if Process.get({__MODULE__, :memoized, workspace_id}) do
      case Process.get({__MODULE__, :memo, workspace_id}) do
        {:ok, overrides} ->
          overrides

        nil ->
          overrides = read_overrides!(workspace_id)
          Process.put({__MODULE__, :memo, workspace_id}, {:ok, overrides})
          overrides
      end
    else
      read_overrides!(workspace_id)
    end
  rescue
    # A failed read is answered with the declaration defaults and is NOT
    # memoized: the next call reads again.
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp workspace_overrides(_), do: %{}

  defp read_overrides!(workspace_id) do
    case Tenancy.get_workspace_by_id(workspace_id) do
      nil -> %{}
      workspace -> Tenancy.workspace_plugin_settings(workspace)
    end
  end

  # ── The per-session memo (task-c8a87043cb286a2f) ───────────────────────────
  #
  # WHY. A Studio socket resolves enablement INSIDE render — the shell's doc
  # actions, the top-menu tabs and their disabled twins each call `effective/1`
  # — so every render read the workspace row, three times per leg, and every
  # `presence_diff` re-renders every open Studio socket on the workspace. One
  # join therefore cost one workspace read per OPEN SESSION (measured: a desk
  # mount at 59 statements climbed 59, 60, 61 … with each prior live session).
  #
  # WHAT. A process that calls `memoize!/1` (the connected Studio LiveView, and
  # nothing else) keeps the workspace's override map in its process dictionary
  # after the first read. It is subscribed to `topic/1`, and every workspace
  # write in `Barkpark.Tenancy` funnels through `bust_default_scope/1`, which
  # calls `workspace_changed/1` and broadcasts there — a rename, an archive, a
  # delete, a plugin toggle. The LiveView answers with `forget/1`, so the next
  # render reads the row again. The ANSWER is never different from an unmemoized
  # read of the same row; only the number of reads changes. Opt-in per process,
  # because a request process (the dead render) is reused across keep-alive
  # requests and receives no broadcast, so it must never memoize.

  @doc "Memoize this workspace's overrides in the CALLING process and subscribe to its changes."
  @spec memoize!(binary()) :: :ok
  def memoize!(workspace_id) when is_binary(workspace_id) do
    unless Process.get({__MODULE__, :memoized, workspace_id}) do
      :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, topic(workspace_id))
      Process.put({__MODULE__, :memoized, workspace_id}, true)
    end

    :ok
  end

  @doc "Drop the calling process's memo for `workspace_id`; the next `effective/1` reads the row."
  @spec forget(binary()) :: :ok
  def forget(workspace_id) do
    Process.delete({__MODULE__, :memo, workspace_id})
    :ok
  end

  @doc "The PubSub topic a workspace write is announced on."
  @spec topic(binary()) :: String.t()
  def topic(workspace_id), do: "workspace_plugins:" <> workspace_id

  @doc """
  Announce a workspace write to every process memoizing it. Takes the write's
  RESULT and passes any other shape through untouched, so it can sit in a pipe.
  """
  def workspace_changed({:ok, %Barkpark.Tenancy.Workspace{id: id}} = result) when is_binary(id) do
    announce(id)
    result
  end

  def workspace_changed(result), do: result

  @doc "Tell every process memoizing `workspace_id` that its row changed."
  @spec announce(binary()) :: :ok
  def announce(workspace_id) when is_binary(workspace_id) do
    _ =
      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        topic(workspace_id),
        {:plugin_enablement_changed, workspace_id}
      )

    :ok
  end

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
