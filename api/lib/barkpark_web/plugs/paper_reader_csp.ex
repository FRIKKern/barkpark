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

      default-src 'self';
      script-src 'self' 'nonce-<n>' 'wasm-unsafe-eval' 'unsafe-eval' https://cdn.jsdelivr.net;
      style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net;
      img-src 'self' data: blob: https: http:;
      media-src 'self' data: blob: https: http:;
      font-src 'self' data:;
      connect-src 'self' https: ws: wss:;
      frame-src 'self';
      object-src 'none';
      base-uri 'self';
      form-action 'self';
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

  ## Non-script directives: what each one buys, and what it CANNOT buy

  An enforcing `script-src` alone downgrades a markup-injection defect to
  defacement, dangling-markup exfiltration, `form-action` hijack and iframe
  phishing rather than blocking it. The directives below close the three of
  those that CAN be closed without changing a single rendered byte. Each was
  chosen by enumerating what `layouts/bulldocs.html.heex` and
  `Barkpark.PortableDoc.Render.*` actually emit — not by copying a hardening
  checklist.

    * `default-src 'self'` — a FLOOR for the fetch directives nobody named
      (`worker-src`, `manifest-src`, `prefetch-src`, `child-src`). The reader
      uses none of them, so the floor costs nothing today and stops a future
      injected `<link rel=manifest>` / worker. Every directive the reader DOES
      use is spelled out below, so the floor never governs a live load. Note
      `default-src` does NOT cover `form-action`, `frame-ancestors` or
      `base-uri` — those are set explicitly.

    * `form-action 'self'` — a REAL win, and the row's headline vector. The
      reader emits ZERO `<form>`: none in `bulldocs.html.heex`, none anywhere
      under `portable_doc/render/`. So an injected `<form action="https://evil">`
      (the classic CSP-bypass exfiltration for a policy that only pins
      `script-src`) now fails to submit, and nothing legitimate is affected.

    * `frame-src 'self'` — also a real win. The reader has exactly ONE frame,
      `#bp-mail-frame`, whose src the layout computes as
      `location.pathname + "/email" + location.search` — same origin, always.
      The renderer emits no `<iframe>`/`<object>`/`<embed>` for ANY block type
      (there is no embed block), so an injected off-site iframe (phishing
      overlay, ad-fraud frame) is blocked while the email view keeps working.

    * `font-src 'self' data:` — a genuine tightening. The only faces are
      `/fonts/SourceSerif4Variable-{Roman,Italic}.woff2`, self-hosted and
      declared in the head's `@font-face` blob. `data:` is kept so an inline
      face in that blob (or a future token-generated one) cannot regress the
      render.

    * `style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net` — CANNOT be
      tightened, and it is important to say why rather than to pretend. The
      head carries a multi-KB inline `<style>` blob, and the renderer stamps
      `style="…"` ATTRIBUTES on nearly every emitted node (e.g. `walk.ex`'s
      `<img … style="max-width:100%;height:auto">`, `figures.ex`'s
      `<video … style="max-width:100%;border-radius:6px">`), while the mail-frame
      script writes `frame.style.height`. A nonce does not cover style
      attributes — that needs `'unsafe-hashes'` plus a hash per distinct
      attribute value, which is impossible for attribute values derived from
      user content. Dropping `'unsafe-inline'` here would strip the paper's
      entire appearance, which violates the byte-identical-render constraint.
      So this directive is a no-op for security; it exists only so
      `default-src 'self'` does not break styling. The residual risk it leaves
      open is CSS-based defacement and CSS exfiltration of attribute values.
      jsdelivr is here for the `asciinema-player@3.8.0` stylesheet in the head.

    * `img-src` / `media-src` `'self' data: blob: https: http:` — deliberately
      permissive, for the same "keep the floor from breaking the render" reason.
      `Render.Util.safe_url/1` allows `https?|mailto|tel` plus root-relative
      paths, so a paper block may legitimately point an `<img>`/`<video>` at ANY
      remote host, and the lightbox re-reads `image.currentSrc`. Pinning these
      to `'self'` would silently blank third-party images in existing papers.
      Both schemes are listed because the reader is served over plain HTTP in
      dev. What this still buys: `javascript:`/`filesystem:` image sources stay
      blocked, and there is no `*` wildcard to inherit later.

    * `connect-src 'self' https: ws: wss:` — likewise permissive, and likewise
      NOT an exfiltration control. Same-origin traffic would be enough for the
      LiveSocket (`/live`), `fetch("/assets/bp-pdrender.wasm.gz")` and
      `fetch(pathname + "/source")` — but `AsciinemaPlayer.create(src, …)`
      fetches an asciicast URL taken straight from the paper's own block data,
      which may be any remote host. Narrowing to `'self'` would break every
      paper with a remotely-hosted `asciicast` block. Read this directive as
      "no non-HTTP(S) transports", not as "no exfiltration" — with
      `script-src` enforcing, there is no attacker script to exfiltrate WITH,
      which is where the actual guarantee lives.

  `object-src 'none'` is cheap hardening that costs the reader nothing.

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
    "default-src 'self'; " <>
      "script-src 'self' 'nonce-#{nonce}' 'wasm-unsafe-eval' 'unsafe-eval' " <>
      "https://cdn.jsdelivr.net; " <>
      "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; " <>
      "img-src 'self' data: blob: https: http:; " <>
      "media-src 'self' data: blob: https: http:; " <>
      "font-src 'self' data:; " <>
      "connect-src 'self' https: ws: wss:; " <>
      "frame-src 'self'; object-src 'none'; base-uri 'self'; " <>
      "form-action 'self'; frame-ancestors 'self'"
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
