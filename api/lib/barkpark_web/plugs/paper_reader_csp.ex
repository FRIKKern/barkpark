defmodule BarkparkWeb.Plugs.PaperReaderCsp do
  @moduledoc """
  Layer-2 script-blocking Content-Security-Policy for the PUBLIC paper reader.

  ## Why this exists (named failure mode)

  `Barkpark.PortableDoc.HtmlSanitizer` scrubs legacy `body_html` at STORE time
  (layer-1 denylist). This plug is the layer-2 allowlist backstop: if a future
  `raw/1` sink, a denylist miss, or a pre-sanitizer poisoned row reaches the
  reader, an enforcing `script-src` without `'unsafe-inline'` stops an injected
  `<script>` / `onerror=` from executing in the visitor's browser. Neither layer
  is trusted alone (defense in depth).

  ## Policy (paper reader only)

      script-src 'self' 'nonce-<n>' 'wasm-unsafe-eval' 'unsafe-eval' https://cdn.jsdelivr.net;
      object-src 'none';
      base-uri 'self';
      frame-ancestors 'self'

  Reasoning for each source (all required by the reader's legitimate render):

    * `'self'` — same-origin `/assets/phoenix.js`, `phoenix_live_view.js`, and the
      lazily-loaded `/assets/bp-wasm-exec.js` for the TUI view.
    * `'nonce-<n>'` — the two INLINE `<script>` blocks in
      `layouts/bulldocs.html.heex` (the view-toggle IIFE and the
      PaperHooks/liveSocket boot). A per-request nonce lets exactly those two
      run while any INJECTED inline script (which cannot know the nonce) is
      blocked. This is what makes the policy an XSS backstop.
    * `'wasm-unsafe-eval'` — the TUI view compiles `bp-pdrender.wasm` via
      `WebAssembly.instantiate`.
    * `'unsafe-eval'` — mermaid@11 may use `eval`/`new Function` internally. This
      does NOT re-open inline injection (only `'unsafe-inline'` would); it only
      permits `eval`, so the anti-XSS guarantee holds.
    * `https://cdn.jsdelivr.net` — mermaid + asciinema-player engines.

  Deliberately NO `default-src`: styles (the multi-KB inline `<style>` blob),
  `data:` images, self-hosted fonts, the `/live` websocket (`connect-src`), and
  the email-view iframe (`frame-src`) stay unrestricted so the reader renders
  byte-identically. `object-src 'none'` is cheap hardening that costs the reader
  nothing.

  This plug REPLACES the whole `content-security-policy` header (via
  `put_resp_header`), running AFTER `put_secure_browser_headers` in the pipeline.
  Phoenix's baseline sets `base-uri 'self'; frame-ancestors 'self';`, so both are
  carried forward here — dropping them would REGRESS clickjacking + base-tag
  protection on the reader while adding script-src.

  ## Path-gating (why this is a self-gating plug, not a pipeline header)

  The flat reader `/papers/:slug` (and `/d/:dataset/papers/:slug`) mounts on the
  `:public_root` route bucket, which is SHARED with the quiz (`/quiz/*`) and
  sheets (`/sheets/:slug`) readers — each with its own layout and CDN needs. A
  blanket CSP on that bucket would break them. So the plug emits the policy ONLY
  when the request path is a paper reader path: the segment before the trailing
  `:slug` is `papers`. That matches

    * `/papers/:slug`
    * `/d/:dataset/papers/:slug`
    * `/w/:ws/p/:proj/papers/:slug`

  and NOT `/papers/:slug/email` (a controller with its own email layout),
  `/sheets/:slug`, `/quiz/host/:pin`, `/quiz/play/:pin`, or `/s/:token`.

  On a matching path the plug both assigns `:csp_nonce` (read by
  `bulldocs.html.heex` as `nonce={assigns[:csp_nonce]}` on its two inline
  scripts) and sets the header, atomically — so header and nonce are always
  consistent. On a non-matching path it is a pure no-op: no header, no assign,
  and the layout omits the `nonce` attribute (nil-safe), i.e. byte-identical to
  before this plug.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if paper_reader_path?(conn.path_info) do
      nonce = generate_nonce()

      conn
      |> assign(:csp_nonce, nonce)
      |> put_resp_header("content-security-policy", policy(nonce))
    else
      conn
    end
  end

  @doc """
  The CSP header value for a given per-request `nonce`. Public so the plug test
  can assert the exact directive string without reaching through a live render.
  """
  @spec policy(String.t()) :: String.t()
  def policy(nonce) when is_binary(nonce) do
    "script-src 'self' 'nonce-#{nonce}' 'wasm-unsafe-eval' 'unsafe-eval' " <>
      "https://cdn.jsdelivr.net; object-src 'none'; base-uri 'self'; " <>
      "frame-ancestors 'self'"
  end

  # Matches when the path's trailing pair is `.../papers/:slug`. Reversing the
  # segment list lets one clause cover all three reader spellings (flat,
  # dataset-prefixed, workspace/project-scoped) while excluding the `/email`
  # sub-route and the sheets/quiz/share readers on the same shared bucket.
  defp paper_reader_path?(path_info) do
    case Enum.reverse(path_info) do
      [_slug, "papers" | _] -> true
      _ -> false
    end
  end

  # 18 raw bytes → a 24-char base64 nonce with no padding. `strong_rand_bytes`
  # is cryptographically random, so an attacker cannot predict the per-request
  # nonce to smuggle an inline script past the policy.
  defp generate_nonce do
    18 |> :crypto.strong_rand_bytes() |> Base.encode64()
  end
end
