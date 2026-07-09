defmodule BarkparkWeb.Studio.StyleguideLive do
  @moduledoc """
  Living style guide for the Studio surface (unified-aesthetic W2).

  Every swatch, chip, glyph and type step on this page renders from a GENERATED
  source — nothing hand-copies a token value:

    * Base palette / status roles / on-status foregrounds / zinc-chrome ladder —
      painted with `background: var(--…)` / `color: var(--…)`, resolving live from
      the `/* BEGIN GENERATED: tokens */` block in `layouts/root.html.heex`
      (emitted by `design/emit.mjs` from `design/tokens.json`).
    * Type ladder — sized with `var(--text-<step>)` (the chrome scale the emitter
      now emits, closing the W2.7 gap). No px literal lives here.
    * Lifecycle row — glyph / ascii / braille frames + hue label from
      `BarkparkWeb.Studio.TokensGen.lifecycle/0` (the Studio mirror of the ONE
      lifecycle source); the applied glyph COLOUR is `var(--life-<state>)`, so no
      hex is ever painted inline. `design/check.mjs` §6 gates that mirror against
      the Go board + paper-surface CSS + `tokens.json`.
    * Categorical presence + Sheets-CF swatches — the ONE place hex is applied
      inline (via `background: <hex>`), because those hues are PERSISTED DATA, not
      theme roles. The hex comes straight from `TokensGen` (generated), never a
      source literal, so `scripts/studio-literal-check.sh` stays green.

  Retint a token in `tokens.json`, `node design/emit.mjs --write`, and this page
  moves with it — that is the drift-visibility it buys.

  A light/dark toggle mirrors its theme onto `<html>` (the `SgTheme` hook), so
  both themes are provable from one page. Admin-gated: mounted inside
  `live_session :admin_studio` (`on_mount BarkparkWeb.LiveAuth :admin`), same as
  the /studio/tmux console; the "Style" top-menu tab is admin-only too.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Tenancy
  alias Barkpark.PortableDoc.Render.Palettes
  alias BarkparkWeb.Studio.TokensGen

  # Vocabulary only — role NAMES + emitted VAR names, never colour values. The
  # values arrive live from the GENERATED CSS block via var(--…).
  # 11 base roles + the derived primary-soft tint.
  @palette [
    {"primary", "--primary"},
    {"primary-hover", "--primary-hover"},
    {"primary-soft", "--primary-soft"},
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

  # {name, solid, soft, fg} — the four semantic voices + their on-fill foreground.
  @status [
    {"ok", "--ok", "--ok-soft", "--ok-fg"},
    {"warn", "--warn", "--warn-soft", "--warn-fg"},
    {"danger", "--danger", "--danger-soft", "--danger-fg"},
    {"info", "--info", "--info-soft", "--info-fg"}
  ]

  # Studio zinc/chrome ladder aliases (emitted by studioBlock only).
  @chrome [
    {"bg-accent", "--bg-accent"},
    {"border-muted", "--border-muted"},
    {"fg-dim", "--fg-dim"},
    {"fg-accent", "--fg-accent"}
  ]

  # Chrome type steps, largest → smallest. Names only; each renders via the
  # emitted var(--text-<step>) / var(--text-<step>-lh) (Decision D2).
  @type_steps ~w(2xl xl lg base sm xs)

  # The two orthogonal light/dark modes each theme cell is previewed in. The
  # SHOWROOM matrix is known_themes() × these (ts-w5d) — it GROWS to N×2 with no
  # edit here when ts-w5c registers ember + fjord (the "theme N+1 = one file"
  # invariant made observable on one screen).
  @theme_modes ~w(light dark)

  # Mail-chrome skin slots shown per theme — {label, skin key}. The email skin is
  # BYTES a mail client renders (not CSS vars a browser resolves), so its hex is
  # read from Palettes.email_skin/1 (generated, theme-keyed) and applied inline —
  # never hand-copied, the same documented exception the categorical swatches use.
  @mail_slots [
    {"page_bg", :page_bg},
    {"paper", :paper},
    {"brand", :brand},
    {"brand_text", :brand_text},
    {"text", :text},
    {"muted", :muted},
    {"rule", :rule}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Style guide",
       theme: "light",
       palette: @palette,
       status: @status,
       chrome: @chrome,
       type_steps: @type_steps,
       presence: TokensGen.presence_palette(),
       sheet_cf: TokensGen.sheet_cf_backgrounds(),
       sheet_tabs: TokensGen.sheet_tab_colors(),
       lifecycle: TokensGen.lifecycle(),
       frames: TokensGen.lifecycle_frames(),
       themes: Tenancy.known_themes(),
       theme_modes: @theme_modes,
       mail_skins: mail_skins()
     )}
  end

  # Resolve every known theme's email skin to labelled hex — generated +
  # theme-keyed (never hand-copied), so registering a theme grows this list with
  # no edit here. Shaped {theme, [{label, hex}]} for the showroom mail rows.
  defp mail_skins do
    for theme <- Tenancy.known_themes() do
      skin = Palettes.email_skin(theme)
      {theme, for({label, key} <- @mail_slots, do: {label, Map.fetch!(skin, key)})}
    end
  end

  @impl true
  def handle_event("sg-toggle-theme", _params, socket) do
    {:noreply,
     assign(socket, :theme, if(socket.assigns.theme == "light", do: "dark", else: "light"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="sg-root"
      phx-hook="SgTheme"
      data-theme={@theme}
      style="max-width: 1080px; margin: 2rem auto; padding: 0 1.5rem 4rem; font-family: var(--font); background: var(--bg); color: var(--text);"
    >
      <div style="display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; margin: 0 0 .25rem;">
        <h1 style="margin: 0;">Studio style guide</h1>
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="sg-toggle-theme"
          data-test-id="sg-theme-toggle"
          aria-label="Toggle light / dark preview"
          style="border: 1px solid var(--border); border-radius: var(--radius-sm); padding: 4px 10px; background: var(--muted-surface); color: var(--text);"
        >
          Theme: <strong data-test-id="sg-theme-name">{@theme}</strong> · toggle
        </button>
      </div>
      <p style="color: var(--muted-text); max-width: 68ch; margin: 0 0 1.75rem;">
        The living token spec for Studio. Palette, status, chrome, type and lifecycle all
        render from the GENERATED sources —
        <code style="font-family: var(--font-mono);">var(--…)</code>
        from the root-layout token block, the emitted
        <code style="font-family: var(--font-mono);">--text-*</code> scale, and
        <code style="font-family: var(--font-mono);">Studio.TokensGen</code> — emitted by
        <code style="font-family: var(--font-mono);">design/emit.mjs</code> from
        <code style="font-family: var(--font-mono);">design/tokens.json</code>. Flip the theme
        above to prove both light and dark from one page.
      </p>

      <section data-test-id="sg-showroom" style="margin: 0 0 2.5rem;">
        <h2 style="margin: 0 0 .25rem;">Theme showroom</h2>
        <p style="color: var(--muted-text); font-size: 13px; margin: 0 0 1rem;">
          Every registered theme (<code style="font-family: var(--font-mono);">Tenancy.known_themes/0</code>)
          × light / dark, each cell an
          <code style="font-family: var(--font-mono);">&lt;iframe&gt;</code> owning its own
          <code style="font-family: var(--font-mono);">&lt;html data-bp-theme … data-theme …&gt;</code>
          so the html-anchored studio-chrome / status / reader skins actually fire — the
          showroom parses the SHIPPED stylesheet, it never hand-rebuilds a palette. Drop one
          file in <code style="font-family: var(--font-mono);">design/themes/</code>, and this
          grid grows a row with no edit here.
        </p>

        <div :for={theme <- @themes} data-test-id="sg-theme-row" data-theme-id={theme} style="margin: 0 0 1.75rem;">
          <div style="display: flex; align-items: baseline; gap: 10px; margin: 0 0 .5rem;">
            <strong style="font-family: var(--font-mono); font-size: 13px;">{theme}</strong>
            <span style="color: var(--muted-text); font-size: 11px;">theme identity · light + dark</span>
          </div>

          <%!-- Mail-chrome row — email skin hex, generated + theme-keyed (Palettes.email_skin);
                applied inline (the documented exception for byte-rendered skins, not CSS vars). --%>
          <div style="margin: 0 0 .6rem;">
            <div style="font-family: var(--font-mono); font-size: 10px; color: var(--muted-text); margin: 0 0 4px;">
              mail-chrome — email_skin (generated hex, not a CSS var)
            </div>
            <div style="display: flex; flex-wrap: wrap; gap: 8px;">
              <div
                :for={{label, hex} <- Map.get(Map.new(@mail_skins), theme, [])}
                data-test-id="sg-mail-chip"
                style="display: flex; flex-direction: column; align-items: center; gap: 3px;"
              >
                <span style={"width: 26px; height: 26px; border-radius: var(--radius-sm); border: 1px solid var(--border); background: #{hex};"}></span>
                <span style="font-family: var(--font-mono); font-size: 9px; color: var(--muted-text);">{label}</span>
              </div>
            </div>
          </div>

          <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px;">
            <div :for={mode <- @theme_modes} data-test-id="sg-theme-cell" data-cell-theme={theme} data-cell-mode={mode}>
              <div style="font-family: var(--font-mono); font-size: 10px; color: var(--muted-text); margin: 0 0 4px;">
                {theme} · {mode}
              </div>
              <iframe
                id={"sg-swatch-#{theme}-#{mode}"}
                phx-hook="SgFit"
                phx-update="ignore"
                src={"/studio/styleguide/swatch?theme=#{theme}&mode=#{mode}"}
                title={"#{theme} #{mode} preview"}
                loading="lazy"
                scrolling="no"
                style="width: 100%; min-height: 320px; overflow: hidden; border: 1px solid var(--border); border-radius: var(--radius-sm); background: var(--surface);"
              >
              </iframe>
            </div>
          </div>
        </div>
      </section>

      <section style="margin: 0 0 2.5rem;">
        <h2 style="margin: 0 0 .75rem;">Palette</h2>
        <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 10px;">
          <div
            :for={{label, cssvar} <- @palette}
            style="border: 1px solid var(--border); border-radius: var(--radius-sm); overflow: hidden;"
          >
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
          The four semantic voices — solid hue over its soft tint, with the on-fill
          foreground chip (<code style="font-family: var(--font-mono);">--…-fg</code> text on
          <code style="font-family: var(--font-mono);">--…</code> fill).
        </p>
        <div style="display: flex; flex-wrap: wrap; gap: 12px;">
          <div
            :for={{label, solid, soft, fg} <- @status}
            style={"display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-radius: var(--radius-sm); background: var(#{soft}); border: 1px solid var(--border);"}
          >
            <span style={"width: 18px; height: 18px; border-radius: 999px; background: var(#{solid});"}></span>
            <span
              style={"font-family: var(--font-mono); font-size: 11px; padding: 3px 8px; border-radius: var(--radius-sm); background: var(#{solid}); color: var(#{fg});"}
            >
              {label}
            </span>
            <span style="font-family: var(--font-mono); font-size: 11px; color: var(--text);">
              var({solid}) · var({soft}) · var({fg})
            </span>
          </div>
        </div>
      </section>

      <section style="margin: 0 0 2.5rem;">
        <h2 style="margin: 0 0 .25rem;">Zinc / chrome ladder</h2>
        <p style="color: var(--muted-text); font-size: 13px; margin: 0 0 .75rem;">
          The Studio-only alias shades with no exact base-role token.
        </p>
        <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 10px;">
          <div
            :for={{label, cssvar} <- @chrome}
            style="border: 1px solid var(--border); border-radius: var(--radius-sm); overflow: hidden;"
          >
            <div style={"height: 44px; background: var(#{cssvar});"}></div>
            <div style="padding: 6px 8px; background: var(--surface);">
              <div style="font-family: var(--font-mono); font-size: 11px; color: var(--text);">{label}</div>
              <div style="font-family: var(--font-mono); font-size: 10px; color: var(--muted-text);">var({cssvar})</div>
            </div>
          </div>
        </div>
      </section>

      <section style="margin: 0 0 2.5rem;">
        <h2 style="margin: 0 0 .25rem;">Categorical palettes</h2>
        <p style="color: var(--muted-text); font-size: 13px; margin: 0 0 .75rem;">
          Presence avatars + Sheets conditional-format fills. These are PERSISTED DATA
          (stored on the row/cell, compared for selection), not theme roles — so the hex
          is applied inline straight from
          <code style="font-family: var(--font-mono);">Studio.TokensGen</code> (generated),
          the one documented exception to the var-only rule.
        </p>
        <div style="margin: 0 0 .75rem;">
          <div style="font-family: var(--font-mono); font-size: 11px; color: var(--muted-text); margin: 0 0 4px;">presence_palette</div>
          <div style="display: flex; flex-wrap: wrap; gap: 8px;">
            <div :for={hex <- @presence} data-test-id="sg-categorical" style="display: flex; flex-direction: column; align-items: center; gap: 3px;">
              <span style={"width: 26px; height: 26px; border-radius: 999px; border: 1px solid var(--border); background: #{hex};"}></span>
              <span style="font-family: var(--font-mono); font-size: 9px; color: var(--muted-text);">{hex}</span>
            </div>
          </div>
        </div>
        <div style="margin: 0 0 .75rem;">
          <div style="font-family: var(--font-mono); font-size: 11px; color: var(--muted-text); margin: 0 0 4px;">sheet_cf_backgrounds</div>
          <div style="display: flex; flex-wrap: wrap; gap: 8px;">
            <div :for={hex <- @sheet_cf} data-test-id="sg-categorical" style="display: flex; flex-direction: column; align-items: center; gap: 3px;">
              <span style={"width: 26px; height: 26px; border-radius: var(--radius-sm); border: 1px solid var(--border); background: #{hex};"}></span>
              <span style="font-family: var(--font-mono); font-size: 9px; color: var(--muted-text);">{hex}</span>
            </div>
          </div>
        </div>
        <div>
          <div style="font-family: var(--font-mono); font-size: 11px; color: var(--muted-text); margin: 0 0 4px;">sheet_tab_colors</div>
          <div style="display: flex; flex-wrap: wrap; gap: 8px;">
            <div :for={hex <- @sheet_tabs} data-test-id="sg-categorical" style="display: flex; flex-direction: column; align-items: center; gap: 3px;">
              <span style={"width: 26px; height: 26px; border-radius: 999px; border: 1px solid var(--border); background: #{hex};"}></span>
              <span style="font-family: var(--font-mono); font-size: 9px; color: var(--muted-text);">{hex}</span>
            </div>
          </div>
        </div>
      </section>

      <section style="margin: 0 0 2.5rem;">
        <h2 style="margin: 0 0 .25rem;">Task lifecycle</h2>
        <p style="color: var(--muted-text); font-size: 13px; margin: 0 0 .75rem;">
          Glyph + ascii fallback + adaptive hue per state, the Studio mirror of the ONE
          lifecycle source — done/closed stay TEAL, distinct from status ok-green. The glyph
          colour is <code style="font-family: var(--font-mono);">var(--life-&lt;state&gt;)</code>;
          the hex labels come from
          <code style="font-family: var(--font-mono);">TokensGen.lifecycle/0</code>.
        </p>
        <div style="margin: 0 0 1rem; font-family: var(--font-mono); font-size: 13px; color: var(--info);">
          <span style="color: var(--muted-text);">in_progress braille frames:</span>
          <span :for={f <- @frames} style="padding: 0 2px;">{f}</span>
        </div>
        <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 10px;">
          <div
            :for={life <- @lifecycle}
            data-test-id="sg-lifecycle"
            style="display: flex; align-items: center; gap: 10px; padding: 10px 12px; border: 1px solid var(--border); border-radius: var(--radius-sm); background: var(--surface);"
          >
            <span style={"font-size: 22px; line-height: 1; color: var(--life-#{life.state});"}>{life.glyph}</span>
            <div>
              <div style="font-family: var(--font-mono); font-size: 12px; color: var(--text);">{life.state}</div>
              <div style="font-family: var(--font-mono); font-size: 10px; color: var(--muted-text);">
                ascii "{life.ascii}" · {life.light} / {life.dark}
              </div>
            </div>
          </div>
        </div>
      </section>

      <section style="margin: 0 0 1rem;">
        <h2 style="margin: 0 0 .25rem;">Type ladder — UI chrome (Inter)</h2>
        <p style="color: var(--muted-text); font-size: 13px; margin: 0 0 .75rem;">
          Rendered straight off the emitted
          <code style="font-family: var(--font-mono);">--text-*</code> scale
          (<code style="font-family: var(--font-mono);">tokens.json type.chrome</code>) — no
          px literal lives on this page (Decision D2).
        </p>
        <div :for={step <- @type_steps} style="display: flex; align-items: baseline; gap: 16px; margin-bottom: 8px;">
          <span style="font-family: var(--font-mono); font-size: 11px; color: var(--muted-text); flex: 0 0 190px;">
            {step} · var(--text-{step})
          </span>
          <span style={"font-size: var(--text-#{step}); line-height: var(--text-#{step}-lh); color: var(--text);"}>
            Fleet at a glance
          </span>
        </div>
      </section>
    </div>
    """
  end
end
