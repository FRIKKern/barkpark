defmodule BarkparkCloud.Events do
  @moduledoc """
  Team-scoped pub/sub for the live dashboard, built on OTP's `:pg` process
  groups — no new dependency, no Phoenix.PubSub.

  The dashboard opens one Server-Sent-Events stream per browser tab
  (`GET /v1/events`); that request process `subscribe/1`s to its team's group.
  When a mutation completes anywhere in the control plane (a provision job
  succeeds, a webhook activates a subscription, an agent reports health), the
  router calls `broadcast/2` with the owning team id and a coarse event TYPE.
  Every subscribed tab for that team receives `{:bpcloud_event, %{type:,
  payload:}}` and the SSE loop forwards it; the dashboard JS maps the type back
  to "refetch this collection" (it does NOT trust a pushed payload as state —
  the event is an invalidation signal, the authoritative read is the GET).

  Coarse-by-design: the event carries a short `type` ("fleet", "subscription",
  "sites", "deployments") and an optional small `payload` (e.g. a site id), not
  a serialized row. That keeps this module free of every schema's JSON shape and
  makes a missed/duplicated event harmless — the client just refetches.

  The type vocabulary is CLOSED. `@event_types` below is the registry; the same
  list is committed to `priv/static/__fixtures__/event_types.json`, which the
  dashboard's node harness asserts against its `TYPE_ACTIONS` dispatch table and
  `events_contract_test.exs` asserts against `types/0` — so adding a type on one
  side without the other reds a gate instead of silently going stale. To add a
  type: give it a handler in `app.js` `TYPE_ACTIONS`, add it to the fixture, add
  it here — in the same PR. `broadcast/3` raises `ArgumentError` on an
  unregistered type in EVERY environment (a typo'd type is a bug at the call
  site, never a runtime condition to tolerate).

  `:pg` auto-removes a member pid when its process dies, so a closed SSE
  connection unsubscribes itself with no bookkeeping here. In the test
  environment the scope is started the same way (it is in the main supervision
  tree, not the web-only subtree), so `broadcast/2` is a safe no-op when no tab
  is connected.
  """

  @scope :barkpark_cloud_events

  # The closed set of invalidation channels, sorted. Mirrored byte-for-byte
  # (as a sorted JSON array) in priv/static/__fixtures__/event_types.json.
  @event_types ~w(audit barkpark.restored barkpark.suspended deployments fleet
                  github members notifications onboarding sites subscription)

  @typedoc "A coarse invalidation channel the dashboard knows how to refetch."
  @type event_type :: String.t()

  @doc """
  The registered event-type vocabulary (sorted). The contract test asserts this
  equals the shared JSON fixture the dashboard harness also checks.
  """
  @spec types() :: [event_type()]
  def types, do: @event_types

  @doc """
  Child spec that starts the `:pg` scope this module broadcasts over. Added to
  `BarkparkCloud.Application`'s supervision tree so the scope is up before the
  web listener accepts the first SSE connection.
  """
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {:pg, :start_link, [@scope]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Subscribe the CALLING process to `team_id`'s event group. Called by the SSE
  request process; when that process exits (the browser closed the stream) `:pg`
  drops it automatically. Returns `:ok`.
  """
  @spec subscribe(binary()) :: :ok
  def subscribe(team_id) when is_binary(team_id) do
    :pg.join(@scope, {:team, team_id}, self())
  end

  @doc """
  Broadcast a coarse `type` event (optionally with a small `payload`) to every
  subscriber of `team_id`. Fire-and-forget — returns `:ok` even when no tab is
  connected. A nil/blank team id is a no-op (a mutation whose team can't be
  resolved simply pushes nothing rather than crashing the request).

  Raises `ArgumentError` when `type` is not in `types/0` — in every env, nil
  team or not. An unregistered type is a call-site bug (the dashboard would
  have no handler for it), so it fails fast instead of degrading into a
  silently-stale panel.
  """
  @spec broadcast(binary() | nil, event_type(), map()) :: :ok
  def broadcast(team_id, type, payload \\ %{})

  def broadcast(team_id, type, payload)
      when is_binary(team_id) and team_id != "" and type in @event_types do
    msg = {:bpcloud_event, %{type: type, payload: payload}}

    for pid <- :pg.get_members(@scope, {:team, team_id}) do
      send(pid, msg)
    end

    :ok
  end

  # nil/blank team stays a no-op — but only for a REGISTERED type.
  def broadcast(_team_id, type, _payload) when type in @event_types, do: :ok

  def broadcast(_team_id, type, _payload) do
    raise ArgumentError,
          "unregistered SSE event type #{inspect(type)} — the vocabulary is closed. " <>
            "Register it in BarkparkCloud.Events (@event_types), " <>
            "priv/static/__fixtures__/event_types.json, and app.js TYPE_ACTIONS (same PR)."
  end
end
