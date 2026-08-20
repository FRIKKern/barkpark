defmodule BarkparkWeb.StatusController do
  @moduledoc """
  Public status page + machine-readable status API, plus admin incident
  management.

    * `GET /status`        — a self-contained public HTML status page
    * `GET /status.json`   — the same data as JSON (for uptime monitors)
    * `POST /v1/status/incidents`         — open an incident (admin)
    * `POST /v1/status/incidents/:id/resolve` — resolve one (admin)

  All health is real (`Barkpark.Status` probes the database, migrations, and
  plugin registry); incidents come from the `status_incidents` table; the SLA is
  config-driven.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Status
  alias BarkparkWeb.Studio.TokensGen

  # Severity LABEL text only. The per-status health tone is DATA, looked up from
  # BarkparkWeb.Studio.TokensGen.status_health/0 (design/tokens.json
  # color.statusHealth) at render time — see page_html/0 + component_row/1.
  @labels %{
    operational: "All systems operational",
    degraded: "Degraded performance",
    partial_outage: "Partial outage",
    major_outage: "Major outage"
  }

  # ── Public ────────────────────────────────────────────────────────────────────

  # @sobelow_skip — XSS.SendResp (send_resp/3) is a false-positive: `page_html/0`
  # is a server-generated status page. Its only user-influenced values are the
  # admin-authored incident fields (title/component/body), each run through
  # `esc/1` (`Phoenix.HTML.html_escape`) before interpolation; health/status
  # tones come from server probes + `TokensGen`. No unescaped request data.
  # sobelow_skip ["XSS.SendResp"]
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page_html())
  end

  def show_json(conn, _params) do
    health = Status.health()

    json(conn, %{
      status: health.status,
      components: Enum.map(health.components, &%{name: &1.component, status: &1.status}),
      version: health.version,
      # The sha is the identity; `version`'s trailing segment is only a
      # commits-since-tag distance. Public + unauthenticated on purpose.
      commit: health.commit,
      uptime_seconds: health.uptime_seconds,
      sla: Status.sla(),
      incidents:
        Status.recent_incidents(20)
        |> Enum.map(&incident_json/1),
      checked_at: health.checked_at
    })
  end

  # ── Admin ─────────────────────────────────────────────────────────────────────

  def create_incident(conn, params) do
    case Status.create_incident(
           Map.take(params, ~w(title component impact status body started_at))
         ) do
      {:ok, incident} ->
        conn |> put_status(:created) |> json(%{incident: incident_json(incident)})

      {:error, cs} ->
        conn
        |> put_status(422)
        |> json(%{error: %{code: "invalid_incident", message: errors(cs)}})
    end
  end

  def resolve_incident(conn, %{"id" => id}) do
    case Status.get_incident(id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: %{code: "not_found", message: "no such incident"}})

      incident ->
        {:ok, resolved} = Status.resolve_incident(incident)
        json(conn, %{incident: incident_json(resolved)})
    end
  end

  # ── rendering ─────────────────────────────────────────────────────────────────

  defp incident_json(i) do
    %{
      id: i.id,
      title: i.title,
      component: i.component,
      impact: i.impact,
      status: i.status,
      body: i.body,
      started_at: i.started_at,
      resolved_at: i.resolved_at
    }
  end

  defp page_html do
    health = Status.health()
    label = Map.get(@labels, health.status, "Unknown")
    color = Map.get(TokensGen.status_health(), health.status, TokensGen.status_health_unknown())
    sla = Status.sla()
    incidents = Status.recent_incidents(20)

    """
    <!doctype html>
    <html lang="en"><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Barkpark — Status</title>
    <style>
      :root { color-scheme: light dark; }
      /* Self-contained page chrome — this page renders WITHOUT the Studio layout,
         so the root tokens never cascade in. De-literalized onto design/tokens.json
         (color.statusChrome) via the page-scoped block below; regenerate with
         `node design/emit.mjs --write`, never hand-edit. The health-severity DATA
         tones (inline style, below) are DATA from BarkparkWeb.Studio.TokensGen. */
      /* BEGIN GENERATED: tokens (design/tokens.json — regenerate: node design/emit.mjs --write; do not hand-edit) */
      :root { --bg:#ffffff; --fg:#111827; --muted:#6b7280; --card:#f9fafb; --line:#e5e7eb; }
      @media (prefers-color-scheme: dark){ :root{ --bg:#0b0f17; --fg:#e5e7eb; --muted:#9ca3af; --card:#111827; --line:#1f2937; } }
      /* ── theme identity (data-bp-theme) — orthogonal to light/dark mode; the bare declarations above are the evergreen fallback (no attribute → renders exactly as today) ── */
      html[data-bp-theme="evergreen"] { --bg:#ffffff; --fg:#111827; --muted:#6b7280; --card:#f9fafb; --line:#e5e7eb; }
      @media (prefers-color-scheme: dark){ html[data-bp-theme="evergreen"]{ --bg:#0b0f17; --fg:#e5e7eb; --muted:#9ca3af; --card:#111827; --line:#1f2937; } }
      html[data-bp-theme="charple"] { --bg:#ffffff; --fg:#111827; --muted:#6b7280; --card:#f9fafb; --line:#e5e7eb; }
      @media (prefers-color-scheme: dark){ html[data-bp-theme="charple"]{ --bg:#0b0f17; --fg:#e5e7eb; --muted:#9ca3af; --card:#111827; --line:#1f2937; } }
      html[data-bp-theme="ember"] { --bg:#ffffff; --fg:#111827; --muted:#6b7280; --card:#f9fafb; --line:#e5e7eb; }
      @media (prefers-color-scheme: dark){ html[data-bp-theme="ember"]{ --bg:#0b0f17; --fg:#e5e7eb; --muted:#9ca3af; --card:#111827; --line:#1f2937; } }
      html[data-bp-theme="fjord"] { --bg:#ffffff; --fg:#111827; --muted:#6b7280; --card:#f9fafb; --line:#e5e7eb; }
      @media (prefers-color-scheme: dark){ html[data-bp-theme="fjord"]{ --bg:#0b0f17; --fg:#e5e7eb; --muted:#9ca3af; --card:#111827; --line:#1f2937; } }
      html[data-bp-theme="iris"] { --bg:#ffffff; --fg:#111827; --muted:#6b7280; --card:#f9fafb; --line:#e5e7eb; }
      @media (prefers-color-scheme: dark){ html[data-bp-theme="iris"]{ --bg:#0b0f17; --fg:#e5e7eb; --muted:#9ca3af; --card:#111827; --line:#1f2937; } }
      /* END GENERATED: tokens */
      body{ margin:0; font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background:var(--bg); color:var(--fg); }
      .wrap{ max-width:760px; margin:0 auto; padding:2.5rem 1.25rem; }
      h1{ font-size:1.25rem; margin:0 0 1.5rem; }
      .banner{ display:flex; align-items:center; gap:.75rem; padding:1rem 1.25rem; border-radius:12px; background:var(--card); border:1px solid var(--line); margin-bottom:2rem; }
      .dot{ width:12px; height:12px; border-radius:50%; flex:0 0 auto; }
      .banner b{ font-size:1.05rem; }
      h2{ font-size:.85rem; text-transform:uppercase; letter-spacing:.05em; color:var(--muted); margin:2rem 0 .75rem; }
      .row{ display:flex; justify-content:space-between; align-items:center; padding:.7rem 0; border-bottom:1px solid var(--line); }
      .pill{ font-size:.8rem; color:var(--muted); }
      .sla{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:1rem 1.25rem; }
      .sla .t{ font-size:1.75rem; font-weight:700; }
      .inc{ padding:.85rem 0; border-bottom:1px solid var(--line); }
      .inc .m{ font-size:.8rem; color:var(--muted); }
      .none{ color:var(--muted); padding:.7rem 0; }
      footer{ margin-top:2.5rem; color:var(--muted); font-size:.8rem; }
    </style></head>
    <body><div class="wrap">
      <h1>Barkpark Status</h1>
      <div class="banner"><span class="dot" style="background:#{color}"></span><b>#{label}</b></div>

      <h2>Components</h2>
      #{Enum.map_join(health.components, "", &component_row/1)}

      <h2>Service level</h2>
      <div class="sla">
        <div class="t">#{sla[:uptime_target] || sla["uptime_target"]}</div>
        <div class="pill">uptime target, measured #{sla[:measurement_window] || sla["measurement_window"]} · service credits apply below target</div>
      </div>

      <h2>Incident history</h2>
      #{incidents_html(incidents)}

      <footer>Version #{esc(health.version)} · commit #{esc(health.commit)} · checked #{health.checked_at} · <a href="/status.json">JSON</a></footer>
    </div></body></html>
    """
  end

  defp component_row(%{component: name, status: status}) do
    color = Map.get(TokensGen.status_health(), status, TokensGen.status_health_unknown())

    """
    <div class="row"><span>#{name |> to_string() |> String.capitalize()}</span>
    <span class="pill"><span class="dot" style="background:#{color};display:inline-block;margin-right:.4rem"></span>#{status}</span></div>
    """
  end

  defp incidents_html([]), do: ~s(<div class="none">No incidents reported.</div>)

  defp incidents_html(incidents) do
    Enum.map_join(incidents, "", fn i ->
      state = if i.resolved_at, do: "Resolved", else: String.capitalize(i.status)

      """
      <div class="inc"><div><b>#{esc(i.title)}</b> — #{state}</div>
      <div class="m">#{esc(i.component)} · #{i.impact} · #{i.started_at}#{if i.resolved_at, do: " → resolved #{i.resolved_at}", else: ""}</div>
      #{if i.body && i.body != "", do: "<div class=\"m\">#{esc(i.body)}</div>", else: ""}</div>
      """
    end)
  end

  defp esc(nil), do: ""
  defp esc(v), do: v |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
  end
end
