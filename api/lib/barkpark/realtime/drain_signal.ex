defmodule Barkpark.Realtime.DrainSignal do
  @moduledoc """
  The retire broadcast every long-lived SSE loop (`ListenController`,
  `ChatController`'s `stream_loop/1` and `fleet_stream_loop/4`,
  `PresenceController.loop/2`) subscribes
  to, so a blue/green deploy's Caddy flip can end every stream on the
  RETIRING slot at once (task-2bcada0faa01ebb2).

  Without this, a `/v1/data/listen` (or chat) stream opened before the flip
  stays on the OLD slot: writes now land on the NEW slot's PubSub, which the
  old slot's connection never sees, so the stream sits alive-but-deaf
  sending keepalives for the ~20-30s the old slot takes to drain and stop.
  Measured live (barkpark-studio, deploy run 37998355608): nothing is LOST
  (the client replays via `Last-Event-ID` on reconnect), but every open
  listener misses frames on every deploy.

  Triggered by `POST /v1/internal/retire-sse`
  (`BarkparkWeb.DeployController.retire_sse/2`), which `deploy/instance-
  deploy.sh` calls on the OLD slot's OWN port right after the Caddy flip
  lands — a plain same-node PubSub broadcast, no OS-signal trapping, no
  dependency on `systemctl disable --now`'s SIGTERM/SIGKILL timing.
  """

  @topic "system:retire"

  @doc "The topic every retiring-slot-aware SSE loop subscribes to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Call once, at stream start, from the SSE loop's own process."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Barkpark.PubSub, @topic)

  @doc "Broadcast to every subscriber on THIS node — called by the retire endpoint."
  @spec broadcast_retire() :: :ok | {:error, term()}
  def broadcast_retire, do: Phoenix.PubSub.broadcast(Barkpark.PubSub, @topic, :retire)

  @doc "The final SSE frame a retiring stream sends before closing — a distinct event so the client can tell a deploy-retire from a network drop and reconnect immediately instead of backing off."
  @spec retire_frame() :: String.t()
  def retire_frame,
    do: "event: retire\ndata: {\"type\":\"retire\",\"reason\":\"slot_retiring\"}\n\n"
end
