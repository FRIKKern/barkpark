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

  `:pg` auto-removes a member pid when its process dies, so a closed SSE
  connection unsubscribes itself with no bookkeeping here. In the test
  environment the scope is started the same way (it is in the main supervision
  tree, not the web-only subtree), so `broadcast/2` is a safe no-op when no tab
  is connected.
  """

  @scope :barkpark_cloud_events

  @typedoc "A coarse invalidation channel the dashboard knows how to refetch."
  @type event_type :: String.t()

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
  """
  @spec broadcast(binary() | nil, event_type(), map()) :: :ok
  def broadcast(team_id, type, payload \\ %{})

  def broadcast(team_id, type, payload)
      when is_binary(team_id) and team_id != "" and is_binary(type) do
    msg = {:bpcloud_event, %{type: type, payload: payload}}

    for pid <- :pg.get_members(@scope, {:team, team_id}) do
      send(pid, msg)
    end

    :ok
  end

  def broadcast(_team_id, _type, _payload), do: :ok
end
