defmodule Barkpark.Plugins.Github.Web.OpsLive do
  @moduledoc """
  Read-only `:ops` console for the GitHub bridge, mounted at `/admin/github`.

  Four waves of the bridge accumulate sync state that nothing renders — open
  `github_sync_conflicts`, the outbound cursor + its drain backlog, and the
  `github_mirror` Oban queue. This LiveView gives an operator EYES on it:
  `Github.Health.snapshot/1` (a pure local read — NO GitHub call) painted as a
  per-dataset cursor/lag/pending panel, the mirror queue depth, and the open
  conflicts grouped by kind.

  Purely observational with ONE exception: each open-conflict row carries a
  "Resolve" button wired to the already-built `Github.Conflicts.resolve/1` — a
  maintainer clearing a quarantine row. That touches only the side table (never
  `Content.*` / `mutation_events`), so there is no loop surface (epic D5/D7).
  Everything else is read-only text.

  Health is a POLL, not a subscription: `mount/3` schedules a slow 5s
  `:refresh` re-read (the pulse dashboard precedent — no PubSub). Mounted via
  `Github.register_routes/1`'s `{:live, "/github", …, auth: :ops}` under the
  router's `plugin_routes(scope: :ops)` block, so the `:ops` on_mount admin gate
  always guards it (NEVER public_demo, NEVER anonymous). Off-by-default is
  unaffected — the route only resolves a live handler when `github` is
  whitelisted, and the gate still admin-gates it regardless.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Plugins.Github.{Conflicts, Health}

  @refresh_ms 5_000

  @conflict_kinds ~w(out_of_band_edit detached dedup_refused)

  @impl true
  def mount(_params, _session, socket) do
    connected = connected?(socket)

    if connected, do: Process.send_after(self(), :refresh, @refresh_ms)

    # NAMED COST (doctrine lever #2, query-count): `Health.snapshot/0` is 5+ DB
    # round-trips — a `SELECT 1` liveness ping, the open-conflict GROUP-BY count
    # + a capped row read, one per-dataset cursor/lag/pending read, and the Oban
    # `github_mirror` queue-depth read. The disconnected (dead) mount render is
    # DISCARDED the instant the WebSocket connects and `mount/3` re-runs — and
    # this console is admin-gated (`:ops`), so no crawler/unfurler ever consumes
    # that HTML. Running the snapshot there was pure waste (2× per page open).
    # Guard it behind `connected?/1` (the board_live.ex/#2402 precedent): paint a
    # DB-free loading skeleton on the dead render (`blank_health/0`), and read the
    # real snapshot ONCE, on connect. The 5s `:refresh` poll is untouched.
    health = if connected, do: Health.snapshot(), else: blank_health()

    {:ok,
     socket
     |> assign(:loading, not connected)
     |> assign(:health, health)}
  end

  # Slow periodic re-read — keeps cursor/lag/pending/queue honest; conflicts too.
  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, :health, Health.snapshot())}
  end

  # The ONLY control on the page: clear one open quarantine row, then re-read so
  # the resolved row drops out of `open`. `Conflicts.resolve/1` is idempotent and
  # side-table only — a missing/already-resolved id is a harmless no-op. The id
  # is parsed defensively: our own buttons always render an integer, but a
  # malformed/stale phx-value must never crash the LV process (parse failure is a
  # silent no-op re-read, not a raise).
  @impl true
  def handle_event("resolve", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, n} -> _ = Conflicts.resolve(n)
      :error -> :noop
    end

    {:noreply, assign(socket, :health, Health.snapshot())}
  end

  # Dead-render skeleton: the disconnected mount no longer runs
  # `Health.snapshot/0`, so it has no readings to paint. Rather than flash an
  # all-zeros board (which would falsely read as "DB down / everything caught up,
  # zero conflicts" — a genuinely-quiet snapshot is indistinguishable from an
  # unloaded one), paint a light, self-contained loading state; the connected
  # mount (~one RTT later) replaces it with the real health. CSP-safe, no JS, no
  # external assets — mirrors the board_live.ex precedent.
  @impl true
  def render(%{loading: true} = assigns) do
    ~H"""
    <main class="container" style="max-width: 66rem;" data-role="github-ops-loading">
      <h1>🔗 GitHub Sync</h1>
      <p style="display:flex; align-items:center; gap:0.6rem; opacity:0.7;">
        <span aria-hidden="true"
              style="width:8px; height:8px; border-radius:999px; background:var(--primary); display:inline-block;">
        </span>
        Loading sync health…
      </p>
    </main>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="container" style="max-width: 66rem;">
      <h1>🔗 GitHub Sync</h1>
      <p>
        <small>
          Read-only sync health for the outbound GitHub mirror. Local state only —
          this page never calls GitHub. Refreshes every 5&nbsp;s.
          <span :if={@health.repo} data-role="github-repo">
            Mirror target: <strong><%= @health.repo %></strong>.
          </span>
          <%!-- DB reachability is a distinct signal from provisioning: it tells a
                genuinely-quiet all-zero snapshot (db reachable) from a BLIND one
                (db unreachable → every section degraded to zeros by Health.safe/2). --%>
          <span data-role="github-db-status" data-db-ok={to_string(@health.db_ok)}>
            Database: <strong><%= db_status_label(@health) %></strong>.
          </span>
        </small>
      </p>

      <%!-- One banner-state decision, made once by the pure health_banner/1 helper
            and consumed by both banners below — no branch logic duplicated in HEEx.
            A DB outage degrades Settings.active?() to false through the same safe/2
            wrapper as db_ok, so keying "not provisioned" on active alone MISREADS an
            outage as missing credentials. :db_down wins over :inactive for that reason. --%>
      <% banner = health_banner(@health) %>

      <div :if={banner == :db_down} data-role="github-health-db-down"
           style="border:1px solid var(--danger); background:hsl(var(--danger-hsl) / 0.10); border-radius:8px; padding:0.8rem 1rem; margin:1rem 0;">
        <strong>Cannot reach the database — readings are blind, not necessarily zero.</strong>
        <span style="opacity:0.85;">
          A trivial <code>SELECT 1</code> liveness probe failed, so every count below
          degraded to zero. This is NOT a healthy quiet state — the true sync backlog
          is unknown until the database is reachable again.
        </span>
      </div>

      <div :if={banner == :inactive} data-role="github-health-inactive"
           style="border:1px solid var(--warn); background:hsl(var(--warn-hsl) / 0.10); border-radius:8px; padding:0.8rem 1rem; margin:1rem 0;">
        <strong>Plugin not provisioned.</strong>
        <span style="opacity:0.85;">
          The GitHub App credentials are missing or blank — the bridge is dark.
          The database is reachable, so the health below reflects real local ledger state.
        </span>
      </div>

      <section style="margin:1.6rem 0;">
        <h2 style="font-size:0.95rem; letter-spacing:0.03em; text-transform:uppercase; opacity:0.6;">
          Reporters waiting
        </h2>
        <p style="margin:0 0 0.6rem;">
          <small style="opacity:0.6;">
            <code>gh-&lt;num&gt;</code> tasks born from an OUTSIDER's issue whose acknowledgement
            criterion is not stamped met. They can see nothing but their issue, where the
            bridge already promised them updates. This reads the ledger only — it cannot
            see a comment nobody recorded, so post the outcome <em>and</em> stamp the criterion.
          </small>
        </p>

        <div :if={@health.unacknowledged.total == 0} data-role="github-unacked-empty">
          <p><em>Every intaken issue has been answered.</em></p>
        </div>

        <div :if={@health.unacknowledged.total > 0}>
          <div data-role="github-unacked-counts"
               style="display:flex; flex-wrap:wrap; gap:1.6rem; margin-bottom:1rem; font-variant-numeric:tabular-nums;">
            <span data-role="github-unacked-closed">
              closed with no answer: <strong><%= @health.unacknowledged.closed %></strong>
            </span>
            <span>still open: <strong><%= @health.unacknowledged.open %></strong></span>
            <span style="opacity:0.7;">
              no criterion at all: <strong><%= @health.unacknowledged.no_criterion %></strong>
            </span>
            <span style="opacity:0.7;">total: <strong><%= @health.unacknowledged.total %></strong></span>
          </div>

          <div style="overflow-x:auto;">
            <table style="width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums;">
              <thead>
                <tr style="text-align:left; opacity:0.6; font-size:0.85rem;">
                  <th style="padding:0.35rem 0.7rem;">issue</th>
                  <th style="padding:0.35rem 0.7rem;">task</th>
                  <th style="padding:0.35rem 0.7rem;">bridge state</th>
                  <th style="padding:0.35rem 0.7rem;">lifecycle</th>
                  <th style="padding:0.35rem 0.7rem;">waiting since</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @health.unacknowledged.rows}
                    data-role="github-unacked-row" data-doc-id={row.doc_id}
                    style="border-top:1px solid var(--border);">
                  <td style="padding:0.35rem 0.7rem;"><%= unacked_issue_ref(row) %></td>
                  <td style="padding:0.35rem 0.7rem;"><%= row.doc_id %></td>
                  <td style="padding:0.35rem 0.7rem;"><%= row.state || "—" %></td>
                  <td style="padding:0.35rem 0.7rem;"><%= row.lifecycle_status || "—" %></td>
                  <td style="padding:0.35rem 0.7rem;"><%= fmt(row.created_at) %></td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section style="margin:1.6rem 0;">
        <h2 style="font-size:0.95rem; letter-spacing:0.03em; text-transform:uppercase; opacity:0.6;">Datasets</h2>
        <p data-role="github-lag-caption" style="margin:0 0 0.6rem;">
          <small style="opacity:0.6;">
            <strong>lag</strong> = every <code>mutation_events</code> row since the cursor;
            <strong>pending</strong> = only the mirrorable task subset the drain actually consumes.
            High lag with zero pending is caught-up, not a stall.
          </small>
        </p>
        <div style="overflow-x:auto;">
          <table style="width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums;">
            <thead>
              <tr style="text-align:left; opacity:0.6; font-size:0.85rem;">
                <th style="padding:0.35rem 0.7rem;">dataset</th>
                <th style="padding:0.35rem 0.7rem;">cursor</th>
                <th style="padding:0.35rem 0.7rem;">head</th>
                <th style="padding:0.35rem 0.7rem;">lag</th>
                <th style="padding:0.35rem 0.7rem;">pending</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={ds <- @health.datasets} data-role="github-dataset" data-dataset={ds.dataset}
                  style="border-top:1px solid var(--border);">
                <td style="padding:0.35rem 0.7rem;"><strong><%= ds.dataset %></strong></td>
                <td style="padding:0.35rem 0.7rem;"><%= ds.cursor %></td>
                <td style="padding:0.35rem 0.7rem;"><%= ds.head %></td>
                <td style="padding:0.35rem 0.7rem;" data-role="github-lag"><%= ds.lag %></td>
                <td style="padding:0.35rem 0.7rem;" data-role="github-pending"><%= pending_display(ds) %></td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section style="margin:1.6rem 0;">
        <h2 style="font-size:0.95rem; letter-spacing:0.03em; text-transform:uppercase; opacity:0.6;">
          Mirror queue <span style="opacity:0.7; text-transform:none; letter-spacing:0;">(github_mirror)</span>
        </h2>
        <div data-role="github-queue"
             style="display:flex; flex-wrap:wrap; gap:1.6rem; font-variant-numeric:tabular-nums;">
          <span>available: <strong><%= @health.queue.available %></strong></span>
          <span>scheduled: <strong><%= @health.queue.scheduled %></strong></span>
          <span>executing: <strong><%= @health.queue.executing %></strong></span>
          <span>retryable: <strong><%= @health.queue.retryable %></strong></span>
          <span style="opacity:0.7;">total: <strong><%= @health.queue.total %></strong></span>
        </div>
      </section>

      <section style="margin:1.6rem 0;">
        <h2 style="font-size:0.95rem; letter-spacing:0.03em; text-transform:uppercase; opacity:0.6;">Open conflicts</h2>

        <div :if={@health.conflicts.total == 0} data-role="github-health-empty">
          <p><em>No open sync conflicts. The ledger and the repo agree.</em></p>
        </div>

        <div :if={@health.conflicts.total > 0}>
          <div data-role="github-conflict-counts"
               style="display:flex; flex-wrap:wrap; gap:1.6rem; margin-bottom:1rem; font-variant-numeric:tabular-nums;">
            <span :for={kind <- conflict_kinds()} data-role="github-conflict-count" data-kind={kind}>
              <%= kind %>: <strong><%= count_for(@health.conflicts, kind) %></strong>
            </span>
            <span style="opacity:0.7;">total: <strong><%= @health.conflicts.total %></strong></span>
          </div>

          <div :for={{kind, rows} <- grouped(@health.conflicts.open)}
               data-role="github-conflict-group" data-kind={kind}
               style="margin:1rem 0;">
            <h3 style="font-size:0.9rem; margin-bottom:0.3rem;"><%= kind %></h3>
            <div style="overflow-x:auto;">
              <table style="width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums;">
                <thead>
                  <tr style="text-align:left; opacity:0.6; font-size:0.85rem;">
                    <th style="padding:0.35rem 0.7rem;">issue</th>
                    <th style="padding:0.35rem 0.7rem;">task</th>
                    <th style="padding:0.35rem 0.7rem;">recorded</th>
                    <th style="padding:0.35rem 0.7rem;"></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- rows} data-role="github-conflict-row" data-conflict-id={row.id}
                      style="border-top:1px solid var(--border);">
                    <td style="padding:0.35rem 0.7rem;"><%= issue_ref(row) %></td>
                    <td style="padding:0.35rem 0.7rem;"><%= row.doc_id || "—" %></td>
                    <td style="padding:0.35rem 0.7rem;"><%= fmt(row.inserted_at) %></td>
                    <td style="padding:0.35rem 0.7rem;">
                      <button type="button" data-role="github-resolve"
                              phx-click="resolve" phx-value-id={row.id}
                              style="cursor:pointer;">
                        Resolve
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </section>
    </main>
    """
  end

  # ---------------------------------------------------------------------------
  # Banner state (pure) — public so it is unit-testable without a full mount
  # ---------------------------------------------------------------------------

  @doc """
  Decide the single top-of-console banner state from the health snapshot.

  A DB outage degrades BOTH `Settings.active?()` and `db_ok` to `false` through
  the same `Health.safe/2` wrapper, so keying "not provisioned" on `active`
  alone misreports an outage as missing credentials. `db_ok` is the tiebreaker:

    * `:db_down`  — `db_ok == false` (regardless of `active`): the DB is
      unreachable, so every count is blind zeros, not a healthy quiet state.
    * `:inactive` — `db_ok == true` AND `active == false`: the DB is fine but the
      plugin is genuinely un-provisioned (credentials missing/blank).
    * `:ok`       — otherwise: DB reachable and the plugin is provisioned.

  `render/1` calls this once and drives both banners off the result, so the
  precedence lives here (unit-testable) rather than duplicated in HEEx.
  """
  @spec health_banner(map()) :: :db_down | :inactive | :ok
  def health_banner(%{db_ok: false}), do: :db_down
  def health_banner(%{active: false}), do: :inactive
  def health_banner(_), do: :ok

  @doc """
  Human label for the DB-reachability indicator, distinct from provisioning.
  Pure so both the reachable and unreachable copy are unit-testable without a
  full mount (the in-process test Repo is always up, so `db_ok` is always true
  under a real mount).
  """
  @spec db_status_label(map()) :: String.t()
  def db_status_label(%{db_ok: true}), do: "reachable"
  def db_status_label(_), do: "unreachable"

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  defp conflict_kinds, do: @conflict_kinds

  # DB-free placeholder assigned on the disconnected (dead) mount render so
  # `mount/3` issues ZERO `Health.snapshot/0` probes on the discarded first
  # paint. Fully shaped (mirrors `Health.t()`) so any accidental field reference
  # stays crash-safe; the `loading: true` render clause paints a skeleton and
  # never reads these values. `db_ok`/`active` default false — a placeholder
  # never claims a healthy DB it has not probed.
  # `repo#num` when both are known, `#num` when the row predates a repo stamp,
  # and an em dash when there is nothing honest to print. Same shape as
  # `issue_ref/1` for conflict rows; kept separate because a census row and a
  # conflict row are different structs and a shared helper would have to guess.
  defp unacked_issue_ref(%{repo: repo, issue: issue}) when is_binary(repo) and not is_nil(issue),
    do: "#{repo}##{issue}"

  defp unacked_issue_ref(%{issue: issue}) when not is_nil(issue), do: "##{issue}"
  defp unacked_issue_ref(_row), do: "—"

  defp blank_health do
    %{
      active: false,
      db_ok: false,
      repo: nil,
      conflicts: %{out_of_band_edit: 0, detached: 0, dedup_refused: 0, total: 0, open: []},
      datasets: [],
      queue: %{available: 0, scheduled: 0, executing: 0, retryable: 0, total: 0},
      unacknowledged: %{total: 0, closed: 0, open: 0, no_criterion: 0, rows: []}
    }
  end

  # phx-value ids arrive as strings. Accept only a clean integer; anything else
  # (garbage, empty, a float, trailing junk) is rejected so the handler no-ops
  # instead of raising.
  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}
  defp parse_id(_), do: :error

  # Group the (already newest-first, capped) open rows by kind for display, in a
  # stable kind order.
  defp grouped(open) do
    open
    |> Enum.group_by(& &1.kind)
    |> Enum.sort_by(fn {kind, _rows} -> kind end)
  end

  # Per-kind count off the Health conflicts map (atom keys); 0 for an absent kind.
  defp count_for(conflicts, kind) when is_binary(kind) do
    Map.get(conflicts, String.to_existing_atom(kind), 0)
  end

  defp issue_ref(%{repo: repo, issue: issue}) when is_binary(repo) and is_integer(issue),
    do: "#{repo}##{issue}"

  defp issue_ref(%{issue: issue}) when is_integer(issue), do: "##{issue}"
  defp issue_ref(_), do: "—"

  defp pending_display(%{pending: p, pending_capped: true}), do: "#{p}+"
  defp pending_display(%{pending: p}), do: Integer.to_string(p)

  defp fmt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp fmt(_), do: "—"
end
