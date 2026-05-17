defmodule Barkpark.ExternalSync do
  @moduledoc """
  Plugin-agnostic registry of external-system sync integrations.

  Each entry describes how a system's raw state strings map to a UI pill
  (color + human-readable label) and what to show as the system label
  ("Bokbasen", "Onyx", "Stripe", whatever). The registry is the single
  source of truth `BarkparkWeb.Components.ExternalSyncPill` reads from.

  Plugins do NOT register at runtime — entries live here as a compile-time
  map so the BEAM-resident `@entries` constant is purged at code load and
  unknown systems are fast to detect (`get/1 → nil`). When a new external
  system needs UI sync semantics, add an entry here.

  ## Topic convention

      external_sync:<system_name>:<doc_id>

  Publishers broadcast `{:external_sync_status, %{system, doc_id, state,
  payload}}` on the topic above. Subscribers (typically a LiveView that
  owns the open document) call `subscribe/2` and pattern-match on the
  shape.

  ## Host-owned vs. plugin-owned entries

  The compile-time `@entries` map below is the **host-owned** slice — UI
  pill contracts that ship with Barkpark itself, independent of any
  plugin. Plugins contribute their own slice via the
  `Barkpark.Plugin.external_sync_entries/0` callback, which the
  `Barkpark.Plugins.Registry` exposes as
  `collect_external_sync_entries/0`. `all/0` merges both on every call —
  no cache, no boot-time snapshot — so a plugin coming online late still
  shows up. Plugin entries take precedence on key collision.

  Bokbasen (the original sole entry) now lives in
  `Barkpark.Plugins.OnixEdit.external_sync_entries/0` since it is
  plugin-owned territory.
  """

  @entries %{}

  @doc """
  Return the registry entry for `system_name`, or `nil` if not registered.
  """
  @spec get(String.t() | atom() | nil) :: map() | nil
  def get(system_name) when is_atom(system_name) and not is_nil(system_name),
    do: get(Atom.to_string(system_name))

  def get(system_name) when is_binary(system_name), do: Map.get(all(), system_name)
  def get(_), do: nil

  @doc """
  Return the full registry map, merging host-owned (`@entries`) and
  plugin-owned (`Plugins.Registry.collect_external_sync_entries/0`)
  contributions. Plugin entries win on key collision.

  This is a runtime GenServer call into `Plugins.Registry` — every
  invocation re-merges. For v1 the call volume is low enough that the
  simplicity wins over caching; revisit if the pill renderer hot path
  shows up in a flamegraph.
  """
  @spec all() :: map()
  def all do
    plugin_entries =
      try do
        Barkpark.Plugins.Registry.collect_external_sync_entries()
      rescue
        _ -> %{}
      catch
        _, _ -> %{}
      end

    Map.merge(@entries, plugin_entries)
  end

  @doc """
  Resolve the per-state pill metadata (`%{color, label}`) for a system+state
  pair. Unknown states fall back to the `nil` row of the system's table; an
  unknown system falls back to a gray "not synced" placeholder so the
  caller never crashes on a stray broadcast.
  """
  @spec state_meta(String.t() | atom() | nil, String.t() | atom() | nil) :: map()
  def state_meta(system_name, state) do
    entry = get(system_name) || %{label: to_label(system_name), states: %{}}
    key = normalize_state(state)
    Map.get(entry.states, key) || Map.get(entry.states, nil) ||
      %{color: "gray", label: "Not synced"}
  end

  @doc """
  Resolve the system-level label ("Bokbasen", "Stripe", …). Falls back to
  the system name unchanged so unregistered systems still render.
  """
  @spec system_label(String.t() | atom() | nil) :: String.t()
  def system_label(system_name) do
    case get(system_name) do
      %{label: label} when is_binary(label) -> label
      _ -> to_label(system_name)
    end
  end

  @doc """
  Canonical PubSub topic name for one (system, document) pair.
  """
  @spec topic(String.t() | atom(), String.t()) :: String.t()
  def topic(system_name, doc_id)
      when (is_binary(system_name) or is_atom(system_name)) and is_binary(doc_id) do
    "external_sync:#{system_name}:#{doc_id}"
  end

  @doc """
  Subscribe the calling process to `topic(system_name, doc_id)` on
  `Barkpark.PubSub`. Returns whatever `Phoenix.PubSub.subscribe/2` returns.
  """
  @spec subscribe(String.t() | atom(), String.t()) :: :ok | {:error, term()}
  def subscribe(system_name, doc_id) do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, topic(system_name, doc_id))
  end

  @doc """
  Broadcast a state transition for one (system, document) pair. Payload is
  merged into the message body so subscribers can opt-in to extra context
  (timestamps, error envelopes, submission ids) without forcing every
  publisher to populate them.
  """
  @spec broadcast(String.t() | atom(), String.t(), String.t() | atom() | nil, map()) :: :ok
  def broadcast(system_name, doc_id, state, payload \\ %{})
      when (is_binary(system_name) or is_atom(system_name)) and is_binary(doc_id) and
             is_map(payload) do
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      topic(system_name, doc_id),
      {:external_sync_status,
       %{
         system: to_string_or_nil(system_name),
         doc_id: doc_id,
         state: normalize_state(state),
         payload: payload
       }}
    )
  end

  # ── private ──────────────────────────────────────────────────────────────

  defp normalize_state(nil), do: nil
  defp normalize_state(""), do: nil
  defp normalize_state(state) when is_binary(state), do: state
  defp normalize_state(state) when is_atom(state), do: Atom.to_string(state)
  defp normalize_state(_), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v) when is_binary(v), do: v
  defp to_string_or_nil(v) when is_atom(v), do: Atom.to_string(v)
  defp to_string_or_nil(_), do: nil

  defp to_label(nil), do: ""
  defp to_label(v) when is_binary(v), do: v
  defp to_label(v) when is_atom(v), do: Atom.to_string(v)
  defp to_label(_), do: ""
end
