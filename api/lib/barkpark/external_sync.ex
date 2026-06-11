defmodule Barkpark.ExternalSync do
  @moduledoc """
  Plugin-agnostic registry of external-system sync integrations.

  Each entry describes how an external system's raw state strings map to
  a UI pill (color + human-readable label) and what to show as the
  system label. The registry is the single source of truth
  `BarkparkWeb.Components.ExternalSyncPill` reads from.

  Host-owned entries live here as a compile-time `@entries` map; plugins
  contribute their own slice at runtime via the `external_sync_entries/0`
  callback (see `Barkpark.Plugin` for the contract). When a new external
  system needs UI sync semantics, either add a host entry below or have
  a plugin contribute it.

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
  `external_sync_entries/0` callback on `Barkpark.Plugin`, which
  `Barkpark.Plugins.Registry.collect_external_sync_entries/1` walks at
  call time. `all/0` merges host + plugin entries on every invocation —
  no cache, no boot-time snapshot — so a plugin coming online late still
  shows up. Plugin entries take precedence on key collision.
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
  Return the full registry map. Seeds the
  `resolve_external_sync_entries/2` resolver chain with the host-owned
  compile-time `@entries` map as `:baseline` and threads it through
  every registered plugin in load order. Plugins implementing the
  resolver can see / drop / amend host entries symmetric with how they
  treat sibling-plugin contributions. The default lift (plugin only
  defines the additive `external_sync_entries/0`) is `Map.merge(prev,
  result)` — plugin entries still win on key collision.

  This is a runtime GenServer call into `Plugins.Registry` — every
  invocation re-runs the chain. For v1 the call volume is low enough
  that the simplicity wins over caching; revisit if the pill renderer
  hot path shows up in a flamegraph.
  """
  @spec all() :: map()
  def all(dataset \\ nil) do
    try do
      Barkpark.Plugins.Registry.collect_external_sync_entries(
        baseline: @entries,
        ctx: %{dataset: dataset}
      )
    rescue
      _ -> @entries
    catch
      _, _ -> @entries
    end
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
  Resolve the system-level label (the human-readable name shown on the
  external-sync pill — registered via the entry's `:label` key). Falls back to
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
