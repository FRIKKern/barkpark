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
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)
    {:ok, assign(socket, :health, Health.snapshot())}
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
        </small>
      </p>

      <div :if={not @health.active} data-role="github-health-inactive"
           style="border:1px solid #b45309; background:rgba(180,83,9,0.10); border-radius:8px; padding:0.8rem 1rem; margin:1rem 0;">
        <strong>Plugin not provisioned.</strong>
        <span style="opacity:0.85;">
          The GitHub App credentials are missing or blank — the bridge is dark.
          The health below reflects local ledger state only.
        </span>
      </div>

      <section style="margin:1.6rem 0;">
        <h2 style="font-size:0.95rem; letter-spacing:0.03em; text-transform:uppercase; opacity:0.6;">Datasets</h2>
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
                  style="border-top:1px solid var(--muted-border-color, #ccc);">
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
                      style="border-top:1px solid var(--muted-border-color, #ccc);">
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
  # Render helpers
  # ---------------------------------------------------------------------------

  defp conflict_kinds, do: @conflict_kinds

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
