defmodule BarkparkWeb.CSP do
  @moduledoc """
  Tailored, script-blocking Content-Security-Policy for the root-layout browser
  surfaces (public root / Studio / admin) and the SSO/SAML SLO response.

  ## Why this exists (named failure mode + measured cost)

  Sobelow flagged `Config.CSP: Missing Content-Security-Policy` on five browser
  pipelines. Its check (`deps/sobelow/.../csp.ex`) is a **purely syntactic** AST
  match: it credits a pipeline ONLY when a CSP map is passed *inside* the
  `:put_secure_browser_headers` plug call (a downstream plug is invisible to it)
  and it checks the map KEY only, never the value. So the pre-existing
  `.sobelow-skips` line-anchored baseline entries were the only suppression —
  and because `Finding.fingerprint` hashes the LINE NUMBER, any edit anywhere in
  `router.ex` re-fingerprinted every `Config.*` finding and RED-ed the gate,
  forcing a manual rebaseline. That toil was paid five times
  (efc02d635/d5db09e57/aefba0809/ada18782e/3d7e0ebe2). Clearing the findings at
  source (a real CSP map in the plug) removes that recurring cost permanently.

  The policy is also a genuine defense-in-depth backstop, NOT vacuous green: it
  blocks any INJECTED inline `<script>` (`refute policy =~ "'unsafe-inline'"` is
  the load-bearing test lock). Studio/admin are operator-authenticated (weak XSS
  axis), so toil-removal is the spine and script-src hardening the bonus.

  ## Why nonce + hashes (the completeness constraint)

  A nonce-only `script-src` (no `'unsafe-inline'`) blocks BOTH un-nonced inline
  `<script>` blocks AND inline event-handler attributes (`onclick=`, `onchange=`
  …). The root-layout surfaces legitimately use both:

    * **Inline `<script>` blocks** — nonced per request. Every such block on
      these surfaces (root.html.heex theme-boot / editor-no-inject / self-update
      poll / liveSocket boot; the login + reset password-eye toggles; the
      /sheets and /quiz reader liveSocket boots) carries `nonce={@csp_nonce}`.
      An injected inline script cannot guess the per-request nonce, so it is
      blocked — this is what makes the policy an XSS backstop.

    * **Inline event handlers** — a nonce does NOT cover `on*=` attributes; only
      `'unsafe-hashes' 'sha256-…'` does. The exact, static handler strings that
      legitimately run in Studio are enumerated below and allow-listed by hash.
      An injected handler (different bytes → different hash) stays blocked. Two
      previously-dynamic handlers (the dataset-switcher nav + a link-copy
      button) were made static — their per-render value moved into a `data-*`
      attribute — so their handler string is stable and hashable.

  SINGLE SOURCE OF TRUTH: the two rewritten handlers and the swatch theme-boot
  read their string from the accessor functions here, so the template and the
  hashed policy can never drift. The remaining handlers are dead-stable literals
  documented with their `file:line`.

  Deliberately NO `default-src`: styles (multi-KB inline `<style>` + `style=`
  attrs), `data:` images, self-hosted fonts, the `/live` websocket
  (`connect-src`) and iframes stay unrestricted so pages render byte-identically
  — only `script-src` is tightened. `style-src` is intentionally left untouched
  (the paper reader's own CSP omits it for the same reason).
  """

  # ── Inline event-handler source strings (allow-listed via 'unsafe-hashes') ──

  # Rewritten to STATIC form (per-render value now in a data-* attribute) so the
  # string is stable and hashable — see dataset_switcher.ex / modals.ex.
  @handler_dataset_switch "window.location = '/studio/' + encodeURIComponent(this.value) + this.dataset.sectionSuffix"
  @handler_copy_data_url "if(navigator.clipboard){var u=this.dataset.url;navigator.clipboard.writeText(/^https?:/.test(u)?u:location.origin+u);this.textContent='Copied'}"

  # Dead-stable static handlers (kept as literals in their templates):
  #   modals.ex          — img onerror (thumbnail fallback)
  #   modals.ex          — onclick="this.select()" (two share-url inputs)
  #   modals.ex          — onclick copy (airdrop link, reads previous sibling)
  #   api_tester_live/components.ex — onclick copy-curl
  #
  # RETIRED — `event.stopPropagation()`. Its sole consumer was
  # `editor_fields.ex`'s secondary-picker card, where the inline handler killed
  # every window-delegated `phx-click` inside the modal (charter D96); that
  # attribute was removed by spd-w5-secondary-pane-reachability, leaving the
  # hash allow-listing a string no template emits. The constant and its
  # `'unsafe-hashes'` sha256 are gone (spd-csp-stop-propagation-allowlist-dead);
  # `browser_csp_test.exs` asserts the hash's ABSENCE from the emitted policy so
  # it cannot creep back. Do NOT re-add a consumer: reintroducing the attribute
  # reintroduces the bug, and `studio_live_secondary_pane_dom_test.exs` reds.
  # (The `e.stopPropagation();` inside the nonced `<script>` block in
  # `bulldocs.html.heex` is NOT an inline handler — nonced script blocks are
  # covered by `'nonce-…'`, never by these `'unsafe-hashes'` entries.)
  @handler_img_error "this.onerror=null;this.classList.add('image-picker-thumb-broken');this.removeAttribute('src');"
  @handler_select "this.select()"
  @handler_copy_prev "var u=this.previousElementSibling.value; if(navigator.clipboard){navigator.clipboard.writeText(/^https?:/.test(u)?u:location.origin+u);this.textContent='Copied'}"
  @handler_copy_curl ~s|navigator.clipboard.writeText(document.getElementById('tester-curl').textContent); this.textContent='Copied ✓'; setTimeout(() => this.textContent='Copy curl', 1500)|

  @inline_handlers [
    @handler_dataset_switch,
    @handler_copy_data_url,
    @handler_img_error,
    @handler_select,
    @handler_copy_prev,
    @handler_copy_curl
  ]

  # The swatch styleguide cell (admin-only iframe) sets data-theme via a
  # single-line inline body script it cannot nonce (it renders in the LiveView
  # body, not a conn-rendered layout). @mode is only ever "light" or "dark", so
  # both exact variants are hashed.
  @swatch_scripts for m <- ~w(light dark),
                      do: ~s|document.documentElement.dataset.theme="#{m}";|

  @script_hashes (@inline_handlers ++ @swatch_scripts)
                 |> Enum.map(&("'sha256-" <> Base.encode64(:crypto.hash(:sha256, &1)) <> "'"))
                 |> Enum.uniq()

  @doc "Handler string for the dataset-switcher `<select onchange=…>` (static)."
  def dataset_switch_onchange, do: @handler_dataset_switch

  @doc "Handler string for the data-url copy button (static)."
  def copy_data_url_onclick, do: @handler_copy_data_url

  @doc "The swatch theme-boot script body for a given mode (`\"light\"`/`\"dark\"`)."
  def swatch_theme_script(mode) when mode in ~w(light dark),
    do: ~s|document.documentElement.dataset.theme="#{mode}";|

  @doc "The `'sha256-…'` sources this policy allow-lists (handlers + swatch)."
  def script_hashes, do: @script_hashes

  @doc """
  A fresh, cryptographically-random per-request nonce (24-char base64, no pad).
  An attacker cannot predict it to smuggle an inline script past the policy.
  """
  @spec nonce() :: String.t()
  def nonce, do: 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

  @doc """
  The script-blocking CSP for the root-layout surfaces (public root / Studio /
  admin). `nonce` runs the enumerated inline `<script>` blocks; `'unsafe-hashes'`
  + the static handler hashes keep the inline event handlers alive;
  `https://cdn.jsdelivr.net` keeps mermaid; `'wasm-unsafe-eval'`/`'unsafe-eval'`
  keep the wasm reader + mermaid engine. NO `'unsafe-inline'`.
  """
  @spec studio_policy(String.t()) :: String.t()
  def studio_policy(nonce) when is_binary(nonce) do
    "script-src 'self' 'nonce-#{nonce}' 'unsafe-hashes' " <>
      Enum.join(@script_hashes, " ") <>
      " 'wasm-unsafe-eval' 'unsafe-eval' https://cdn.jsdelivr.net; " <>
      "object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
  end

  @doc """
  The CSP for the SAML SLO auto-submit response (`:sso_browser`). That page's
  ONLY script is the esaml auto-submit `<script nonce=…>` — a strict nonce-only
  `script-src` blocks anything else. No hashes, no CDN (the form is self-hosted).
  """
  @spec sso_policy(String.t()) :: String.t()
  def sso_policy(nonce) when is_binary(nonce) do
    "script-src 'self' 'nonce-#{nonce}'; object-src 'none'; " <>
      "base-uri 'self'; frame-ancestors 'self'"
  end
end
