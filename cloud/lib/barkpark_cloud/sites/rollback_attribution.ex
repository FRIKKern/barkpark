defmodule BarkparkCloud.Sites.RollbackAttribution do
  @moduledoc """
  site-spawner rollback-latency (task-b017df2fda0fe600, criterion 0) — WHERE THE
  SERVER-SIDE SECOND WENT, measured by the control plane itself.

  Three live rollbacks on guerrilla took 1840 / 3021 / 3820 ms against a 1000 ms
  budget and an engine symlink flip the charter measured at 25 ms. Roughly
  1.4-3.4 s of that sits SERVER-SIDE, and until now nothing in the control plane
  could say which of the three seams held it:

    1. **the CP route itself** — auth, the team-scoped site lookup, the box row
       read, the site-pointer write, the audit row, the console push, the render;
    2. **the CP -> box relay** — the POST that starts the flip and the status
       reads that confirm it, each a full HTTPS round trip to the instance;
    3. **the box** — `site-deploy.sh --rollback` actually running over there.

  `BoxRelay.HTTP` (PR #18130) already attributed the INSIDE of seam 2. That log
  line answers "how much of the WAIT was wire", and it is blind to both ends: the
  route work either side of it is not in the sum at all, and the box's own
  execution is folded into an unnamed residue together with this plane's poll
  quantisation. A 3.8 s rollback whose relay legs add to 200 ms is a route
  problem or a box problem, and the old line cannot tell you which.

  This module closes both ends. It is a REQUEST-SCOPED accumulator: the whole
  rollback — route body, `Sites.Deploy.rollback/2`, `BoxRelay.HTTP.rollback/2`
  and its wait loop — runs in ONE Plug request process, so the stopwatch lives in
  that process's own dictionary. Nothing is shared, nothing is a GenServer, and a
  crashed request takes its half-written stopwatch with it.

  ## The arithmetic, and what is NOT additive

  Everything the CP *spends* is additive and totals the wall clock:

      total_ms = route_pre_ms + deploy_ms + route_post_ms
      deploy_ms = relay_ms + deploy_own_ms
      relay_ms  = accept_ms + poll_wire_ms + sleep_ms + relay_residue_ms

  The BOX's execution is NOT a term in that sum. It runs concurrently with this
  plane's wait loop — the CP is sleeping and polling *while* the box works — so
  adding it would double-count the same seconds. It is reported as a BRACKET
  instead, and the bracket is a real measurement rather than a residue:

    * `box_min_ms` — the box was still `running` when the last not-done poll
      ANSWERED, so it ran at least that long after the accept came back.
    * `box_max_ms` — the box was already `done` when the final poll was SENT, so
      it ran at most that long.

  A `box_max_ms` of 40 ms under a 3 s `total_ms` says the box is innocent and the
  time is the plane's. A `box_min_ms` of 3 s says the opposite, and no amount of
  CP optimisation will help. That is the discrimination the row asks for.

  ## Reading it

  The report goes to a SINK, `:site_rollback_attribution_sink`, defaulting to the
  `Logger` one below (same `site rollback attribution` prefix an operator already
  greps for in the CP journal). A test swaps in a sink that forwards the map, so
  the numbers can be asserted as numbers instead of parsed back out of prose.
  """

  require Logger

  @key :site_rollback_attribution

  @typedoc """
  The relay's own split, handed over by `BoxRelay.HTTP` when its wait finishes.
  """
  @type relay_split :: %{
          required(:relay_ms) => non_neg_integer(),
          required(:accept_ms) => non_neg_integer(),
          required(:polls) => non_neg_integer(),
          required(:poll_wire_ms) => non_neg_integer(),
          required(:sleep_ms) => non_neg_integer(),
          required(:box_min_ms) => non_neg_integer(),
          required(:box_max_ms) => non_neg_integer() | nil
        }

  @doc """
  Start the stopwatch at the top of the route body — BEFORE auth and the site
  lookup, because those are route work and the point is to stop excusing them.
  """
  @spec open(String.t() | nil) :: :ok
  def open(site_ref) do
    Process.put(@key, %{
      site_ref: site_ref,
      t0: now(),
      route_pre_ms: nil,
      deploy_ms: nil,
      relay: nil
    })

    :ok
  end

  @doc """
  Mark the boundary between route work and the box call: everything spent so far
  is `route_pre_ms` (auth, the team-scoped site read, the box row read).

  A no-op when no stopwatch is open, so `Sites.Deploy.rollback/2` stays callable
  from a test or a worker that never went through the route.
  """
  @spec deploy_begins() :: :ok
  def deploy_begins do
    update(fn state -> %{state | route_pre_ms: now() - state.t0} end)
  end

  @doc """
  Close the box call: `deploy_ms` is the whole `Sites.Deploy.rollback/2` span,
  relay INCLUDED, so `deploy_ms - relay_ms` is the context's own work — the
  payload build on the way out and the site-pointer write on the way back.
  """
  @spec deploy_ends() :: :ok
  def deploy_ends do
    update(fn state ->
      %{state | deploy_ms: now() - state.t0 - (state.route_pre_ms || 0)}
    end)
  end

  @doc """
  Hand the relay's own split in. Called by `BoxRelay.HTTP` from inside the box
  call, so it always lands before `deploy_ends/0`.
  """
  @spec record_relay(relay_split()) :: :ok
  def record_relay(split) when is_map(split) do
    update(fn state -> %{state | relay: split} end)
  end

  @doc """
  Stop the stopwatch, report the full attribution, and clear the slot. Returns
  the reported map (or `nil` when nothing was open) so a caller can assert on it
  without reaching into the process dictionary.
  """
  @spec close(String.t()) :: map() | nil
  def close(outcome) when is_binary(outcome) do
    case Process.delete(@key) do
      nil ->
        nil

      state ->
        report = build(state, outcome)
        sink().report(report)
        report
    end
  end

  # ── the arithmetic ─────────────────────────────────────────────────────────

  defp build(state, outcome) do
    total_ms = now() - state.t0
    route_pre_ms = state.route_pre_ms || 0
    deploy_ms = state.deploy_ms || 0
    relay = state.relay || %{}

    relay_ms = Map.get(relay, :relay_ms, 0)
    accept_ms = Map.get(relay, :accept_ms, 0)
    poll_wire_ms = Map.get(relay, :poll_wire_ms, 0)
    sleep_ms = Map.get(relay, :sleep_ms, 0)

    %{
      site_ref: state.site_ref,
      outcome: outcome,
      total_ms: total_ms,

      # SEAM 1 — the control plane's own route work, both ends of the box call.
      route_pre_ms: route_pre_ms,
      route_post_ms: max(total_ms - route_pre_ms - deploy_ms, 0),
      # `Sites.Deploy.rollback/2` minus the relay it wrapped: the payload build
      # and the site-pointer write. Route work by any other name, which is why it
      # is named and not left inside the relay's number.
      deploy_own_ms: max(deploy_ms - relay_ms, 0),
      # This plane's own 50 ms poll quantisation — waiting it CHOSE, not wire.
      wait_quantisation_ms: sleep_ms,

      # SEAM 2 — the CP -> box relay, one accept plus `polls` status reads.
      relay_ms: relay_ms,
      relay_accept_ms: accept_ms,
      relay_poll_wire_ms: poll_wire_ms,
      relay_polls: Map.get(relay, :polls, 0),

      # SEAM 3 — the box, bracketed. NOT a term in the sum: it overlaps the wait.
      box_min_ms: Map.get(relay, :box_min_ms, 0),
      box_max_ms: Map.get(relay, :box_max_ms),

      # What the three seams above do not account for. A big number here means
      # this module is measuring the wrong boundaries, and saying so is the point.
      unattributed_ms: max(relay_ms - accept_ms - poll_wire_ms - sleep_ms, 0)
    }
  end

  defp update(fun) do
    case Process.get(@key) do
      nil -> :ok
      state -> Process.put(@key, fun.(state)) && :ok
    end

    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  # PROCESS-SCOPED FIRST, then application config. The whole rollback runs in one
  # request process, so a test can redirect the report WITHOUT reaching for a
  # global — which is what lets the route-level arm live beside the other
  # `async: true` router tests instead of forcing the whole file serial.
  defp sink do
    Process.get(:site_rollback_attribution_sink) ||
      Application.get_env(:barkpark_cloud, :site_rollback_attribution_sink, __MODULE__.LogSink)
  end

  @doc """
  Redirect THIS process's attribution report to `sink` for the rest of its life.
  A test-support seam; production never calls it.
  """
  @spec redirect_reports_to(module()) :: :ok
  def redirect_reports_to(sink) when is_atom(sink) do
    Process.put(:site_rollback_attribution_sink, sink)
    :ok
  end

  defmodule LogSink do
    @moduledoc """
    The default sink: one `:info` line in the control-plane journal, keyed on the
    same `site rollback attribution` phrase the relay's own line already uses, so
    an operator greps once and gets both halves of the story.
    """

    require Logger

    @spec report(map()) :: :ok
    def report(r) do
      Logger.info(fn ->
        "site rollback attribution site=#{r.site_ref} outcome=#{r.outcome} " <>
          "total_ms=#{r.total_ms} " <>
          "route_pre_ms=#{r.route_pre_ms} route_post_ms=#{r.route_post_ms} " <>
          "deploy_own_ms=#{r.deploy_own_ms} wait_quantisation_ms=#{r.wait_quantisation_ms} " <>
          "relay_ms=#{r.relay_ms} relay_accept_ms=#{r.relay_accept_ms} " <>
          "relay_poll_wire_ms=#{r.relay_poll_wire_ms} relay_polls=#{r.relay_polls} " <>
          "box_min_ms=#{r.box_min_ms} box_max_ms=#{inspect(r.box_max_ms)} " <>
          "unattributed_ms=#{r.unattributed_ms}"
      end)

      :ok
    end
  end
end
