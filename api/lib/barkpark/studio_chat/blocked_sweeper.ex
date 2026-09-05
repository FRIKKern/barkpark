defmodule Barkpark.StudioChat.BlockedSweeper do
  @moduledoc """
  Walk-away safety for the herd: a Studio chat session blocked on a pending ask
  longer than a per-workspace threshold fires EXACTLY ONE debounced webhook
  notification (chat-tui charter D57h–D59h). Off by default — a workspace enables
  it purely by inserting a workspace-scoped `webhooks` row with a
  `blocked_threshold_s` (the subscription flag AND the threshold in one column).

  ## What it scans — and pointedly does NOT

  The scan keys on the PENDING ASK ROWS themselves — `chat_messages` with a
  needs-you role (`approval`/`question`/`plan`) whose `metadata.approval_status`
  is `"pending"` and whose `inserted_at` is older than the workspace threshold,
  joined to `chat_sessions` for `owner_workspace_id`/`title`. It NEVER keys on
  `agent_state`/`agent_state_at`:

    * the 60s heartbeat bumps `agent_state_at` WHILE blocked (charter D41h), so a
      staleness scan would never fire on a genuinely-blocked session;
    * the D56h recorder bug leaves `agent_state='blocked'` unobservable to any
      scan (herd-s3f fixes that separately — this slice must not depend on it).

  `blocked_since` is the ask row's `inserted_at`. A session with a NULL
  `owner_workspace_id` NEVER fires (`s.owner_workspace_id == ^ws` — a NULL never
  matches the equality; fail-closed by construction, charter D43h).

  ## Exactly-once, and unblock

  Each fire claims a `webhook_deliveries` row keyed on
  `(endpoint_id, dedupe_key=<ask id>)` under a partial UNIQUE index
  (`Webhooks.claim_chat_blocked_delivery/3`), so a re-sweep of the same
  still-blocked ask no-ops. Answering the ask flips `approval_status` off
  `"pending"`, so the row leaves the scan — no second fire, no explicit "clear"
  event. A NEW ask is a fresh `chat_messages` row with a fresh id, so it is
  legitimately a new fire after its OWN threshold elapses.

  ## Shape (AgentStateSweeper twin)

  GenServer child of `StudioChat.Supervisor` beside `AgentStateSweeper`: a
  synchronous boot sweep in `init/1`, a `Process.send_after` 60s re-arm, a
  `safe_sweep` that rescues (a DB hiccup logs and waits for the next tick — the
  convergence machinery must never crash-loop the chat supervision tree), and a
  pure `sweep(now)` with an injectable clock so tests drive it directly.

  ## NOT boot-started under MIX_ENV=test — and why

  The 60s tick is a `Repo.all` from THIS process, which under test owns no
  ExUnit SQL-sandbox connection: every tick raised ownership and logged a
  warning on an exact 60s period for the whole `mix test` run (CI run
  33720395852 — 05:51:06.88, 05:52:06.88, 05:53:06.88, 05:58:06.89,
  06:03:06.90). That is noise in every CI log AND a foreign statement inside
  the window of every test that counts telemetry/queries. So
  `config :barkpark, Barkpark.StudioChat.BlockedSweeper, enabled: false` in
  `config/test.exs` keeps the boot-started singleton out of
  `StudioChat.Supervisor.children/0` under test only. It defaults to `true`, so
  dev and prod are unchanged — asserted directly in
  `Barkpark.StudioChat.SupervisorChildrenTest`. Tests exercise the PURE
  `sweep(now)`; a test that wants the running GenServer starts its own instance
  with `start_supervised/1` after `Sandbox.allow/3` (or in `:shared` mode), so
  the tick runs against the test's own sandbox owner.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Barkpark.Repo
  alias Barkpark.StudioChat.{Message, Session}
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Dispatcher

  @sweep_every_ms 60_000
  @ask_roles ~w(approval question plan)

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
  One sweep pass (public so tests drive it directly with an injected clock):
  for every workspace that owns a pending ask, fire the workspace's chat_blocked
  webhook(s) once per ask that has been pending longer than that webhook's
  threshold. Returns the number of NEW deliveries fired (a dedupe no-op does not
  count). Rows with no chat_blocked webhook, asks within threshold, answered
  asks, and NULL-owner sessions are all skipped.
  """
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(now \\ DateTime.utc_now()) do
    now
    |> workspaces_with_pending_asks()
    |> Enum.reduce(0, fn workspace_id, acc ->
      acc + sweep_workspace(workspace_id, now)
    end)
  end

  # Distinct owner_workspace_ids of sessions that currently hold a pending ask.
  # NULL owners are excluded here (fail-closed, D43h) so they can never enter the
  # per-workspace fire path.
  defp workspaces_with_pending_asks(_now) do
    Message
    |> join(:inner, [m], s in Session, on: s.id == m.session_id)
    |> where([m], m.role in @ask_roles)
    |> where([m], fragment("?->>'approval_status' = 'pending'", m.metadata))
    |> where([_m, s], not is_nil(s.owner_workspace_id))
    |> distinct(true)
    |> select([_m, s], s.owner_workspace_id)
    |> Repo.all()
  end

  defp sweep_workspace(workspace_id, now) do
    case Webhooks.chat_blocked_webhooks_for(workspace_id) do
      [] ->
        0

      webhooks ->
        Enum.reduce(webhooks, 0, fn webhook, acc ->
          acc + fire_for_webhook(webhook, workspace_id, now)
        end)
    end
  end

  defp fire_for_webhook(webhook, workspace_id, now) do
    cutoff = DateTime.add(now, -webhook.blocked_threshold_s, :second)

    workspace_id
    |> pending_asks_before(cutoff)
    |> Enum.reduce(0, fn ask, acc ->
      payload = %{
        session_id: ask.session_id,
        title: ask.title,
        workspace_id: workspace_id,
        blocked_since: DateTime.to_iso8601(ask.inserted_at),
        ask_role: ask.role
      }

      case Dispatcher.deliver_chat_blocked(webhook, payload, Integer.to_string(ask.id)) do
        {:skipped, :already_delivered} -> acc
        _ -> acc + 1
      end
    end)
  end

  # Pending asks in a workspace whose ask row is older than `cutoff` — the exact
  # rows a stall-notification is owed for. Carries only what the payload needs
  # (never message content or tool input).
  defp pending_asks_before(workspace_id, cutoff) do
    Message
    |> join(:inner, [m], s in Session, on: s.id == m.session_id)
    |> where([m], m.role in @ask_roles)
    |> where([m], fragment("?->>'approval_status' = 'pending'", m.metadata))
    |> where([m], m.inserted_at < ^cutoff)
    |> where([_m, s], s.owner_workspace_id == ^workspace_id)
    |> select([m, s], %{
      id: m.id,
      session_id: m.session_id,
      role: m.role,
      inserted_at: m.inserted_at,
      title: s.title
    })
    |> Repo.all()
  end

  defp safe_sweep do
    sweep()
  rescue
    error ->
      Logger.warning(
        "studio chat blocked-notification sweeper: sweep failed: #{Exception.message(error)}"
      )

      0
  end
end
