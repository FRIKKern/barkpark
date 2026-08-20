defmodule BarkparkWeb.Studio.SwatchLive do
  @moduledoc """
  One cell of the styleguide THEME SHOWROOM (ts-w5d) — a minimal, admin-gated
  preview surface loaded in an IFRAME by `StyleguideLive`'s theme matrix, one per
  `Tenancy.known_themes()` × `[light, dark]`.

  Why an iframe (not a scoped `<div>`): the studio-chrome / status / reader
  skins are anchored on `html[data-bp-theme="…"]` and
  `html[data-bp-theme="…"][data-theme="dark"]` (emit.mjs studioBlock / paperBlock
  / bulldocsBlock). Those selectors only fire off the DOCUMENT root, so a preview
  cell must own its own `<html>`. Here the root layout stamps `data-bp-theme` from
  `@bp_theme` (this LV forces it to the requested theme; evergreen → no attribute
  → the bare `:root` fallback, which IS evergreen) and a tiny pre-content script
  forces `data-theme` to the requested mode. The result: ONE shipped stylesheet
  paints every theme × mode cell — the showroom parses the real artifact, it does
  not hand-rebuild a palette.

  Everything on the cell is painted with `var(--…)` off the shipped CSS — reader
  surface (`.bp-paper-surface`: paper / ink / reading-accent / callout tones /
  rule), Studio chrome (bg / text / primary / primary-fg / border / muted), and
  the four status roles + their on-fill foregrounds. The ONE exception is the
  mail-chrome row: those hues are the EMAIL skin (a client renders bytes, not
  CSS vars), so their hex is read from `Palettes.email_skin(theme)` (generated,
  theme-keyed) and applied inline — never hand-copied, the same documented
  exception `StyleguideLive` uses for persisted categorical data.

  Admin-gated via its own `live_session :admin_swatch` (`on_mount LiveAuth :admin`),
  and rendered through the bare `:swatch` layout so the cell carries no nav chrome.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Tenancy
  alias Barkpark.PortableDoc.Render.Palettes

  # Studio chrome roles — NAMES + emitted var names only; the values arrive live
  # from the GENERATED token block via var(--…).
  @chrome [
    {"bg", "--bg"},
    {"surface", "--surface"},
    {"text", "--text"},
    {"muted-text", "--muted-text"},
    {"primary", "--primary"},
    {"primary-fg", "--primary-fg"},
    {"border", "--border"}
  ]

  # Status roles — {name, solid var, on-fill fg var}.
  @status [
    {"ok", "--ok", "--ok-fg"},
    {"warn", "--warn", "--warn-fg"},
    {"danger", "--danger", "--danger-fg"},
    {"info", "--info", "--info-fg"}
  ]

  # Reader surface roles (scoped to .bp-paper-surface). paper/ink/reading-accent/rule.
  @reader [
    {"paper-bg", "--paper-bg"},
    {"paper-ink", "--paper-ink"},
    {"reading-accent", "--paper-accent"},
    {"paper-rule", "--paper-rule"}
  ]

  # Reader callout tones — {name, bg var, fg var}.
  @callouts [
    {"success", "--bp-tone-success-bg", "--bp-tone-success-fg"},
    {"warning", "--bp-tone-warning-bg", "--bp-tone-warning-fg"},
    {"danger", "--bp-tone-danger-bg", "--bp-tone-danger-fg"},
    {"info", "--bp-tone-info-bg", "--bp-tone-info-fg"},
    {"neutral", "--bp-tone-neutral-bg", "--bp-tone-neutral-fg"}
  ]

  # Mail-chrome skin slots surfaced in the email row — {label, skin key}. Read as
  # generated hex from Palettes.email_skin/1 (the email skin is bytes, not vars).
  @mail [
    {"page_bg", :page_bg},
    {"paper", :paper},
    {"brand", :brand},
    {"brand_text", :brand_text},
    {"text", :text},
    {"muted", :muted},
    {"rule", :rule}
  ]

  @modes ~w(light dark)

  @impl true
  def mount(params, _session, socket) do
    theme = normalize_theme(params["theme"])
    mode = normalize_mode(params["mode"])

    {:ok,
     socket
     # Force the theme identity so the root layout stamps data-bp-theme (nil for
     # the default → the bare :root evergreen fallback). Overrides the workspace
     # theme StudioChrome resolved — this cell previews the REQUESTED theme.
     |> assign(:bp_theme, theme)
     |> assign(
       page_title: "swatch",
       theme: theme,
       mode: mode,
       chrome: @chrome,
       status: @status,
       reader: @reader,
       callouts: @callouts,
       mail: mail_row(theme)
     )}
  end

  # The email skin resolved to hex, theme-keyed and generated — never hand-copied.
  defp mail_row(theme) do
    skin = Palettes.email_skin(theme)
    for {label, key} <- @mail, do: {label, Map.fetch!(skin, key)}
  end

  defp normalize_theme(theme) when is_binary(theme) do
    if theme in Tenancy.known_themes(), do: theme, else: Tenancy.default_theme()
  end

  defp normalize_theme(_), do: Tenancy.default_theme()

  defp normalize_mode(mode) when mode in @modes, do: mode
  defp normalize_mode(_), do: "light"

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Force the light/dark mode for THIS cell before its content paints, so the
          matrix shows both modes regardless of the viewer's OS/localStorage
          preference (data-theme is otherwise client-owned). Runs on the initial
          static (SSR) render the iframe loads. --%>
    <%!-- Single-line + no surrounding whitespace ON PURPOSE: this renders in the
          LiveView body (not a conn-rendered layout) so it cannot carry a nonce.
          Its exact textContent (mode is only "light"/"dark") is allow-listed by
          sha256 in BarkparkWeb.CSP so the :browser script-src does not block it
          — keep it byte-identical to CSP.swatch_theme_script/1 (task-0fc9d55c). --%>
    <script>document.documentElement.dataset.theme="<%= @mode %>";</script>

    <div
      id="swatch-root"
      data-test-id="swatch"
      data-swatch-theme={@theme}
      data-swatch-mode={@mode}
      style="font-family: var(--font, sans-serif); background: var(--bg); color: var(--text); padding: 14px; min-height: 100vh;"
    >
      <div style="font-family: var(--font-mono, monospace); font-size: 11px; color: var(--muted-text); margin: 0 0 10px;">
        {@theme} · {@mode}
      </div>

      <%!-- Studio chrome roles --%>
      <div style="display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 12px;">
        <div :for={{label, cssvar} <- @chrome} title={label} style="display: flex; flex-direction: column; align-items: center; gap: 2px;">
          <span style={"width: 30px; height: 30px; border-radius: 6px; border: 1px solid var(--border); background: var(#{cssvar});"}></span>
          <span style="font-family: var(--font-mono, monospace); font-size: 8px; color: var(--muted-text);">{label}</span>
        </div>
      </div>

      <%!-- Status roles — solid fill + on-fill foreground chip --%>
      <div style="display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 12px;">
        <span
          :for={{label, solid, fg} <- @status}
          data-test-id="swatch-status"
          style={"font-family: var(--font-mono, monospace); font-size: 10px; padding: 4px 9px; border-radius: 6px; background: var(#{solid}); color: var(#{fg});"}
        >
          {label}
        </span>
      </div>

      <%!-- Reader surface — scoped to .bp-paper-surface so the --paper-* / --bp-tone-* skin applies --%>
      <div class="bp-paper-surface" style="border: 1px solid var(--paper-rule); border-radius: 8px; padding: 12px; background: var(--paper-bg); color: var(--paper-ink);">
        <div style="display: flex; flex-wrap: wrap; gap: 6px; margin: 0 0 8px;">
          <div :for={{label, cssvar} <- @reader} title={label} style="display: flex; flex-direction: column; align-items: center; gap: 2px;">
            <span style={"width: 28px; height: 28px; border-radius: 6px; border: 1px solid var(--paper-rule); background: var(#{cssvar});"}></span>
            <span style="font-family: var(--paper-font-mono, monospace); font-size: 8px; color: var(--paper-ink-soft, var(--paper-ink));">{label}</span>
          </div>
        </div>
        <div style="display: flex; flex-wrap: wrap; gap: 5px;">
          <span
            :for={{label, bg, fg} <- @callouts}
            data-test-id="swatch-callout"
            style={"font-family: var(--paper-font-mono, monospace); font-size: 9px; padding: 3px 7px; border-radius: 5px; background: var(#{bg}); color: var(#{fg});"}
          >
            {label}
          </span>
        </div>
      </div>

      <%!-- Mail-chrome row — email skin hex, generated + theme-keyed (Palettes.email_skin) --%>
      <div style="margin: 12px 0 0;">
        <div style="font-family: var(--font-mono, monospace); font-size: 8px; color: var(--muted-text); margin: 0 0 4px;">
          mail-chrome (email_skin — generated hex)
        </div>
        <div style="display: flex; flex-wrap: wrap; gap: 6px;">
          <div :for={{label, hex} <- @mail} data-test-id="swatch-mail" title={label} style="display: flex; flex-direction: column; align-items: center; gap: 2px;">
            <span style={"width: 26px; height: 26px; border-radius: 6px; border: 1px solid var(--border); background: #{hex};"}></span>
            <span style="font-family: var(--font-mono, monospace); font-size: 8px; color: var(--muted-text);">{label}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
