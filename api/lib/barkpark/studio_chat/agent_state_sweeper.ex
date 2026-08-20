defmodule Barkpark.StudioChat.AgentStateSweeper do
  @moduledoc """
  Staleness-scoped convergence sweep for the herd-layer `agent_state` column
  (chat-tui charter D42h).

  A Recorder that dies LOUD writes its own offline truth (`unknown`/`idle` via
  the uniform D39 rule) — but a `kill -9`, an OOM, or a whole-BEAM crash writes
  nothing, leaving `working`/`blocked` rows that lie forever. This GenServer
  sweeps EXACTLY those rows: `agent_state IN ('working','blocked')` whose
  `agent_state_at` is NULL or older than 150s (2.5× the 60s heartbeat — a
  live session is always fresher) → `unknown`. Synchronously in `init/1` (the
  boot sweep beats the Endpoint's first request — this supervisor tree starts
  before the Endpoint) and every 300s thereafter.

  NEVER a blanket boot reset: guerrilla's blue/green deploy overlaps TWO live
  BEAMs on ONE Postgres (instance-deploy.sh boots the idle slot while the old
  slot keeps serving), so "reset everything at boot" would mislabel the old
  slot's genuinely-working sessions on every deploy. The staleness scope is
  what makes the sweep deploy-safe. Accepted residual: a crashed runner can
  read `working` for ≤150s — bounded, and the view-side stall badge covers the
  window.

  A sweep failure (a DB hiccup) logs and waits for the next tick — convergence
  machinery must never crash-loop the chat supervision tree.
  """

  use GenServer

  require Logger

  alias Barkpark.StudioChat

  @sweep_every_ms 300_000
  @stale_after_s 150

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    safe_sweep()
    Process.send_after(self(), :sweep, @sweep_every_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    safe_sweep()
    Process.send_after(self(), :sweep, @sweep_every_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  One staleness-scoped sweep (public so tests drive it directly): flips every
  `working`/`blocked` row whose `agent_state_at` is NULL or older than 150s to
  `unknown`. Rows in any other state — and FRESH working/blocked rows — are
  never touched. Fence-aware since herd-s6 (charter D79h): a row covered by a
  LIVE report fence (a live execution lease) is skipped — the lease's own 60s
  TTL is the reporter's liveness clock, so a dead reporter's row becomes
  sweepable within a minute, never sweep-proof. The `update_all` itself lives
  in `StudioChat.sweep_stale_agent_states/2` (the D80h census: every
  `agent_state` write funnels through `studio_chat.ex`). Returns the number of
  rows swept.
  """
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@stale_after_s, :second)
    {count, _} = StudioChat.sweep_stale_agent_states(cutoff, now)
    count
  end

  defp safe_sweep do
    sweep()
  rescue
    error ->
      Logger.warning("studio chat agent-state sweeper: sweep failed: #{Exception.message(error)}")

      0
  end
end
