defmodule BarkparkWeb.Studio.StyleguideLive do
  @moduledoc """
  Living style guide for the Studio surface (unified-aesthetic W1.4 scaffold).

  Renders the design tokens the console already loads — it does NOT hand-copy
  hex. Every swatch is painted with `background: var(--…)`, resolving live from
  the GENERATED token block inlined into `layouts/root.html.heex`
  (`/* BEGIN GENERATED: tokens */`, emitted by `design/emit.mjs` from
  `design/tokens.json`). Change a hue in `tokens.json`, re-emit, and the
  swatches on this page re-tint — that is the drift-visibility this page buys.

  Scaffold only (W1.4): palette + status roles + the UI type ladder. Full
  content adoption (chrome, components, wiring `--text-*` emitted vars into the
  type ladder) is W2.7's job.

  Admin-gated: mounted inside `live_session :admin_studio`
  (`on_mount BarkparkWeb.LiveAuth :admin`), same as the /studio/tmux console.
  """

  use BarkparkWeb, :live_view

  # Palette + status roles are the emitted CSS custom properties from the
  # root-layout GENERATED block. {label, css-var}. Rendered, never inlined.
  @palette [
    {"primary", "--primary"},
    {"primary-fg", "--primary-fg"},
    {"bg", "--bg"},
    {"surface", "--surface"},
    {"muted-surface", "--muted-surface"},
    {"text", "--text"},
    {"muted-text", "--muted-text"},
    {"border", "--border"},
    {"ring", "--ring"},
    {"accent", "--accent"}
  ]

  @status [
    {"ok", "--ok", "--ok-soft"},
    {"warn", "--warn", "--warn-soft"},
    {"danger", "--danger", "--danger-soft"},
    {"info", "--info", "--info-soft"}
  ]

  # UI type ladder — mirrors tokens.json `type.ui`. NOTE: Studio does not yet
  # emit `--text-*` CSS vars, so these sizes are a preview, not var-driven;
  # W2.7 wires the emitted scale in and makes this section fully living too.
  @type_scale [
    {"2xl", 26, 1.2, 700},
    {"xl", 20, 1.3, 700},
    {"lg", 16, 1.4, 600},
    {"base", 14, 1.5, 400},
    {"sm", 13, 1.45, 400},
    {"xs", 12, 1.4, 400}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Style guide",
       palette: @palette,
       status: @status,
       type_scale: @type_scale
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="max-width: 1080px; margin: 2rem auto; padding: 0 1.5rem 4rem; font-family: var(--font);">
      <h1 style="margin: 0 0 .25rem;">Studio style guide</h1>
      <p style="color: var(--muted-text); max-width: 66ch; margin: 0 0 1.75rem;">
        The living token spec for Studio. Every swatch is painted with
        <code style="font-family: var(--font-mono);">var(--…)</code> straight from the
        GENERATED block in the root layout — emitted by
        <code style="font-family: var(--font-mono);">design/emit.mjs</code> from
        <code style="font-family: var(--font-mono);">design/tokens.json</code>. Retint a token,
        re-emit, and this page moves with it (W1.4 scaffold).
      </p>

      <section style="margin: 0 0 2.5rem;">
        <h2 style="margin: 0 0 .75rem;">Palette</h2>
        <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 10px;">
          <div :for={{label, cssvar} <- @palette}
               style="border: 1px solid var(--border); border-radius: var(--radius-sm); overflow: hidden;">
            <div style={"height: 44px; background: var(#{cssvar});"}></div>
            <div style="padding: 6px 8px; background: var(--surface);">
              <div style="font-family: var(--font-mono); font-size: 11px; color: var(--text);">{label}</div>
              <div style="font-family: var(--font-mono); font-size: 10px; color: var(--muted-text);">var({cssvar})</div>
            </div>
          </div>
        </div>
      </section>

      <section style="margin: 0 0 2.5rem;">
        <h2 style="margin: 0 0 .25rem;">Status roles</h2>
        <p style="color: var(--muted-text); font-size: 13px; margin: 0 0 .75rem;">
          The four semantic voices — ok / warn / danger / info — solid hue over its soft tint.
        </p>
        <div style="display: flex; flex-wrap: wrap; gap: 12px;">
          <div :for={{label, solid, soft} <- @status}
               style={"display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-radius: var(--radius-sm); background: var(#{soft}); border: 1px solid var(--border);"}>
            <span style={"width: 18px; height: 18px; border-radius: 999px; background: var(#{solid});"}></span>
            <span style="font-family: var(--font-mono); font-size: 12px; color: var(--text);">
              {label} · var({solid})
            </span>
          </div>
        </div>
      </section>

      <section style="margin: 0 0 1rem;">
        <h2 style="margin: 0 0 .25rem;">Type ladder — UI chrome (Inter)</h2>
        <p style="color: var(--muted-text); font-size: 13px; margin: 0 0 .75rem;">
          Mirrors <code style="font-family: var(--font-mono);">tokens.json type.ui</code>. Studio
          does not yet emit <code style="font-family: var(--font-mono);">--text-*</code> vars, so
          sizes here are a preview — W2.7 wires the emitted scale in.
        </p>
        <div :for={{label, size, lh, weight} <- @type_scale} style="display: flex; align-items: baseline; gap: 16px; margin-bottom: 8px;">
          <span style="font-family: var(--font-mono); font-size: 11px; color: var(--muted-text); flex: 0 0 140px;">
            {label} · {size}px / {lh}
          </span>
          <span style={"font-size: #{size}px; line-height: #{lh}; font-weight: #{weight}; color: var(--text);"}>
            Fleet at a glance
          </span>
        </div>
      </section>
    </div>
    """
  end
end
