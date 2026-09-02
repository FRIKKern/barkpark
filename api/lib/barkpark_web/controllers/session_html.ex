defmodule BarkparkWeb.SessionHTML do
  use BarkparkWeb, :html

  embed_templates "session_html/*"

  @doc """
  Brand mark + wordmark shared by the auth pages (login, MFA, reset). The
  evergreen tree path is the same asset the Barkpark Cloud dashboard wordmark
  uses (cloud/priv/static/index.html) — one mark across both front doors.
  """
  def auth_brand(assigns) do
    ~H"""
    <div class="bp-auth-brand">
      <svg class="bp-auth-mark" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
        <path d="M12 2 6.5 10H9l-4.5 7h6v3.5h3V17h6L15 10h2.5Z" />
      </svg>
      <span class="bp-auth-wordmark">Barkpark <b>Studio</b></span>
    </div>
    """
  end

  attr(:flash, :map, required: true)

  def auth_flash(assigns) do
    ~H"""
    <%= if Phoenix.Flash.get(@flash, :error) do %>
      <div class="flash flash-error" role="alert">
        {Phoenix.Flash.get(@flash, :error)}
      </div>
    <% end %>
    <%= if Phoenix.Flash.get(@flash, :info) do %>
      <div class="flash flash-info">
        {Phoenix.Flash.get(@flash, :info)}
      </div>
    <% end %>
    """
  end

  @doc """
  Auth-page styles, scoped under `.bp-auth`. The brand overrides (evergreen
  primary + matching focus ring, per-theme button fills) are emitted from
  design/tokens.json (color.primary/ring/authButton) into the page-scoped
  BEGIN/END GENERATED block below — regenerate with `node design/emit.mjs
  --write`, never hand-edit. Everything else rides the root-layout tokens
  (--bg-card, --border, --fg…) so both themes keep working.
  """
  def auth_styles(assigns) do
    ~H"""
    <style>
      /* Auth-page brand override: evergreen --primary/--ring (the exact emitted
         primary/ring tokens) + the decoupled auth button fills (color.authButton
         — deep-green fill, light text, per the Cloud dashboard). De-literalized
         onto design/tokens.json via the page-scoped block below; light on
         .bp-auth, dark keyed on html[data-theme="dark"] .bp-auth. The layout +
         component rules that follow stay hand-authored. */
      /* BEGIN GENERATED: tokens (design/tokens.json — regenerate: node design/emit.mjs --write; do not hand-edit) */
      .bp-auth {
        --primary: hsl(151.96 71.81% 29.22%);
        --primary-fg: hsl(0 0% 100%);
        --ring: hsl(163 42% 30%);
        --ring-soft: hsl(163 42% 30% / 0.15);
        --btn-bg: var(--primary);
        --btn-fg: var(--primary-fg);
        --btn-bg-hover: hsl(163 46% 17%);
        --dur-1: 0.15s;
        --dur-2: 0.18s;
        --dur-3: 0.28s;
      }
      html[data-theme="dark"] .bp-auth {
        --primary: hsl(152.92 60% 52.94%);
        --primary-fg: hsl(163 45% 8%);
        --ring: hsl(152.92 60% 52.94%);
        --ring-soft: hsl(152.92 60% 52.94% / 0.2);
        --btn-bg: hsl(163 45% 30%);
        --btn-fg: hsl(0 0% 100%);
        --btn-bg-hover: hsl(163 45% 26%);
      }
      /* ── theme identity (data-bp-theme) — orthogonal to light/dark mode; the bare declarations above are the evergreen fallback (no attribute → renders exactly as today) ── */
      html[data-bp-theme="evergreen"] .bp-auth {
        --primary: hsl(151.96 71.81% 29.22%);
        --primary-fg: hsl(0 0% 100%);
        --ring: hsl(163 42% 30%);
        --ring-soft: hsl(163 42% 30% / 0.15);
        --btn-bg: var(--primary);
        --btn-fg: var(--primary-fg);
        --btn-bg-hover: hsl(163 46% 17%);
      }
      html[data-bp-theme="evergreen"][data-theme="dark"] .bp-auth {
        --primary: hsl(152.92 60% 52.94%);
        --primary-fg: hsl(163 45% 8%);
        --ring: hsl(152.92 60% 52.94%);
        --ring-soft: hsl(152.92 60% 52.94% / 0.2);
        --btn-bg: hsl(163 45% 30%);
        --btn-fg: hsl(0 0% 100%);
        --btn-bg-hover: hsl(163 45% 26%);
      }
      html[data-bp-theme="charple"] .bp-auth {
        --primary: hsl(282.39 44.23% 40.78%);
        --primary-fg: hsl(0 0% 100%);
        --ring: hsl(282.39 44.23% 48.78%);
        --ring-soft: hsl(282.39 44.23% 48.78% / 0.15);
        --btn-bg: var(--primary);
        --btn-fg: var(--primary-fg);
        --btn-bg-hover: hsl(163 46% 17%);
      }
      html[data-bp-theme="charple"][data-theme="dark"] .bp-auth {
        --primary: hsl(282.56 58.11% 70.98%);
        --primary-fg: hsl(282.56 45% 8%);
        --ring: hsl(282.56 58.11% 70.98%);
        --ring-soft: hsl(282.56 58.11% 70.98% / 0.2);
        --btn-bg: hsl(163 45% 30%);
        --btn-fg: hsl(0 0% 100%);
        --btn-bg-hover: hsl(163 45% 26%);
      }
      html[data-bp-theme="ember"] .bp-auth {
        --primary: hsl(19.33 71.29% 40.98%);
        --primary-fg: hsl(0 0% 100%);
        --ring: hsl(19.33 71.29% 48.98%);
        --ring-soft: hsl(19.33 71.29% 48.98% / 0.15);
        --btn-bg: var(--primary);
        --btn-fg: var(--primary-fg);
        --btn-bg-hover: hsl(163 46% 17%);
      }
      html[data-bp-theme="ember"][data-theme="dark"] .bp-auth {
        --primary: hsl(19.01 75.53% 63.14%);
        --primary-fg: hsl(19.01 45% 8%);
        --ring: hsl(19.01 75.53% 63.14%);
        --ring-soft: hsl(19.01 75.53% 63.14% / 0.2);
        --btn-bg: hsl(163 45% 30%);
        --btn-fg: hsl(0 0% 100%);
        --btn-bg-hover: hsl(163 45% 26%);
      }
      html[data-bp-theme="fjord"] .bp-auth {
        --primary: hsl(191.6 80.95% 28.82%);
        --primary-fg: hsl(0 0% 100%);
        --ring: hsl(191.6 80.95% 36.82%);
        --ring-soft: hsl(191.6 80.95% 36.82% / 0.15);
        --btn-bg: var(--primary);
        --btn-fg: var(--primary-fg);
        --btn-bg-hover: hsl(163 46% 17%);
      }
      html[data-bp-theme="fjord"][data-theme="dark"] .bp-auth {
        --primary: hsl(193.27 62.43% 64.51%);
        --primary-fg: hsl(193.27 45% 8%);
        --ring: hsl(193.27 62.43% 64.51%);
        --ring-soft: hsl(193.27 62.43% 64.51% / 0.2);
        --btn-bg: hsl(163 45% 30%);
        --btn-fg: hsl(0 0% 100%);
        --btn-bg-hover: hsl(163 45% 26%);
      }
      html[data-bp-theme="iris"] .bp-auth {
        --primary: hsl(248.75 63.72% 55.69%);
        --primary-fg: hsl(0 0% 100%);
        --ring: hsl(248.75 63.72% 62%);
        --ring-soft: hsl(248.75 63.72% 62% / 0.15);
        --btn-bg: var(--primary);
        --btn-fg: var(--primary-fg);
        --btn-bg-hover: hsl(163 46% 17%);
      }
      html[data-bp-theme="iris"][data-theme="dark"] .bp-auth {
        --primary: hsl(248.87 100% 77.45%);
        --primary-fg: hsl(248.87 45% 8%);
        --ring: hsl(248.87 100% 77.45%);
        --ring-soft: hsl(248.87 100% 77.45% / 0.2);
        --btn-bg: hsl(163 45% 30%);
        --btn-fg: hsl(0 0% 100%);
        --btn-bg-hover: hsl(163 45% 26%);
      }
      /* END GENERATED: tokens */
      .bp-auth {
        min-height: 100vh;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        gap: 16px;
        padding: 24px;
      }

      .bp-auth-card {
        width: 100%;
        max-width: 400px;
        background: var(--bg-card);
        border: 1px solid var(--border);
        border-radius: var(--radius-lg);
        padding: 32px;
        box-shadow: 0 4px 16px rgba(0, 0, 0, 0.08);
      }
      .bp-auth-brand {
        display: flex;
        align-items: center;
        gap: 9px;
        margin-bottom: 20px;
        color: var(--fg);
      }
      .bp-auth-mark { width: 22px; height: 22px; color: var(--primary); flex: none; }
      .bp-auth-wordmark { font-size: 15px; font-weight: 500; letter-spacing: -0.01em; }
      .bp-auth-wordmark b { font-weight: 700; }

      .bp-auth-title { font-size: 20px; font-weight: 600; color: var(--fg); margin: 0 0 4px; }
      .bp-auth-sub { font-size: 13px; color: var(--fg-muted); margin: 0 0 20px; line-height: 1.45; }
      .bp-auth-sub code { font-size: 12px; }

      /* Forms: root-layout .form-input/.form-label do the heavy lifting; only
         the focus ring (hardcoded blue upstream) and spacing are re-tuned. */
      .bp-auth .form-group { margin-bottom: 16px; }
      .bp-auth .form-input:focus {
        border-color: var(--ring);
        box-shadow: 0 0 0 2px var(--ring-soft);
      }
      .bp-auth-label-row {
        display: flex;
        align-items: baseline;
        justify-content: space-between;
      }
      .bp-auth-label-row .form-label { margin-bottom: 6px; }
      .bp-auth-label-row a { font-size: 12px; font-weight: 500; color: var(--primary); text-decoration: none; }
      .bp-auth-label-row a:hover { text-decoration: underline; }

      .bp-auth-input-affix { position: relative; }
      .bp-auth-input-affix .form-input { padding-right: 40px; }
      .bp-auth-eye {
        position: absolute;
        top: 0;
        right: 4px;
        height: 100%;
        width: 32px;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        background: none;
        border: none;
        color: var(--fg-dim);
        cursor: pointer;
      }
      .bp-auth-eye:hover { color: var(--fg-muted); }

      .bp-auth-btn {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        gap: 8px;
        width: 100%;
        height: 38px;
        border-radius: var(--radius);
        border: 1px solid transparent;
        background: var(--btn-bg);
        color: var(--btn-fg);
        font-size: 14px;
        font-weight: 600;
        font-family: var(--font);
        cursor: pointer;
        text-decoration: none;
        transition: background 0.15s;
      }
      .bp-auth-btn:hover { background: var(--btn-bg-hover); color: var(--btn-fg); text-decoration: none; }
      .bp-auth-btn:focus-visible { outline: none; box-shadow: 0 0 0 2px var(--ring-soft), 0 0 0 1px var(--ring); }
      .bp-auth-btn svg { width: 16px; height: 16px; flex: none; }

      .bp-auth-btn-quiet {
        background: transparent;
        border-color: var(--border);
        color: var(--fg);
      }
      .bp-auth-btn-quiet:hover { background: var(--bg-accent); color: var(--fg); }

      .bp-auth-divider {
        display: flex;
        align-items: center;
        gap: 12px;
        margin: 20px 0;
        color: var(--fg-dim);
        font-size: 12px;
      }
      .bp-auth-divider::before,
      .bp-auth-divider::after { content: ""; flex: 1; height: 1px; background: var(--border); }

      .bp-auth-foot { margin-top: 20px; font-size: 13px; color: var(--fg-muted); line-height: 1.5; }
      .bp-auth-foot a { color: var(--primary); text-decoration: none; font-weight: 500; }
      .bp-auth-foot a:hover { text-decoration: underline; }

      .bp-auth-alt { margin: 14px 0 0; text-align: center; font-size: 13px; color: var(--fg-muted); }
      .bp-auth-alt a { color: var(--primary); text-decoration: none; font-weight: 500; }
      .bp-auth-alt a:hover { text-decoration: underline; }

      .bp-auth details { margin-top: 16px; }
      .bp-auth details summary {
        cursor: pointer;
        font-size: 13px;
        color: var(--fg-muted);
      }
      .bp-auth details summary:hover { color: var(--fg); }
      .bp-auth details[open] summary { margin-bottom: 12px; }

      .bp-auth-pagefoot { font-size: 12px; color: var(--fg-dim); }

      .bp-auth .flash { margin-bottom: 16px; }
      /* The root .flash-info is hardcoded preview-blue; on-brand here. */
      .bp-auth .flash-info {
        background: var(--ring-soft);
        border-color: var(--ring-soft);
        color: var(--primary);
      }

      /* MFA: the one-time code reads as a code. */
      .bp-auth input.bp-auth-code {
        font-family: var(--font-mono);
        font-size: 18px;
        letter-spacing: 6px;
        text-align: center;
        height: 44px;
      }
    </style>
    """
  end
end
