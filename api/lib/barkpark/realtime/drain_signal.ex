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
  lands — a plain same-node PubSub broadcast, no dependency on
  `systemctl disable --now`'s SIGTERM/SIGKILL timing.

  With `BARKPARK_RETIRE_SSE_ON_SIGTERM=1`, `Barkpark.Application` also traps
  SIGTERM and calls `retire_and_await/1` before the default graceful stop, so
  a container stop ends this node's streams with the same final frame.

  The broadcast is node-local. A clustered peer keeps its streams open.
  """

  @topic "system:retire"

  @doc "The topic every retiring-slot-aware SSE loop subscribes to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Call once, at stream start, from the SSE loop's own process."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Barkpark.PubSub, @topic)

  @doc "Broadcast to every subscriber on THIS node — called by the retire endpoint."
  @spec broadcast_retire() :: :ok
  def broadcast_retire, do: Phoenix.PubSub.local_broadcast(Barkpark.PubSub, @topic, :retire)

  @doc """
  Retire this node's streams, then wait up to `timeout_ms` for every subscriber
  to close, so each stream writes its final frame before the Endpoint stops.
  The SIGTERM trap's callback. Always returns `:ok`.
  """
  @spec retire_and_await(non_neg_integer()) :: :ok
  def retire_and_await(timeout_ms \\ 5_000) do
    :ok = broadcast_retire()
    await_unsubscribed(System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await_unsubscribed(deadline) do
    if Registry.lookup(Barkpark.PubSub, @topic) == [] or
         System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      Process.sleep(50)
      await_unsubscribed(deadline)
    end
  end

  @doc "The final SSE frame a retiring stream sends before closing — a distinct event so the client can tell a deploy-retire from a network drop and reconnect immediately instead of backing off."
  @spec retire_frame() :: String.t()
  def retire_frame,
    do: "event: retire\ndata: {\"type\":\"retire\",\"reason\":\"slot_retiring\"}\n\n"
end
