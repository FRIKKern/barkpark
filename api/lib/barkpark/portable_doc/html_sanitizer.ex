defmodule Barkpark.PortableDoc.HtmlSanitizer do
  @moduledoc """
  Strict HTML scrubber for the ONE untrusted sink in the Papers pipeline:
  legacy `body_html` supplied verbatim by an external producer.

  ## Why this exists (named failure mode)

  A paper written with an HTML-only `body_html` (no `blocks` list) had its
  markup persisted VERBATIM (`Content.Papers.BlockOps.write_encrypted_paper/6`
  and the raw `Content.Writer` mutate path) and emitted through `raw/1` to the
  anonymous public reader (`BulldocsLive` `/papers/:slug`, the scoped
  `/w/:ws/p/:project/papers/:slug` reader, and the `/s/:token` share reader).
  With no Content-Security-Policy on those browser pipelines, a `<script>` tag
  or an `onerror=` handler in `body_html` executed in every reader's browser
  (session/token theft, defacement). Both the `:ingest` shared-secret API and —
  as this audit confirmed — any ordinary write-token via `/v1/data/mutate`
  could plant it.

  ## Trust model

  `body_html` is a DERIVED cache of the paper's `blocks`. When blocks are
  present it is re-rendered server-side by `PortableDoc.Render` (trusted,
  auto-escaping) and never needs scrubbing. This module hardens only the
  LEGACY leg where an opaque `body_html` is the sole source: it is scrubbed at
  STORE time so poisoned markup never reaches the database, complementing the
  reader's Content-Security-Policy backstop.

  ## Strategy — conservative denylist over producer HTML

  Legacy `body_html` is producer-rendered (Markdown/pdrender → HTML): headings,
  paragraphs, lists, code, tables, images, links. None of the executable
  constructs below appear in legitimate producer output, so removing them
  cannot damage real content:

    * script-bearing / sandbox-escaping ELEMENTS removed with their content
      (`script`, `style`, `iframe`, `object`, `embed`, `applet`, `noscript`,
      `template`, `svg`, `math`, `form`, `frame`, `frameset`, `link`, `meta`,
      `base`, `title`) — iterated to a fixpoint so split/nested tags
      (`<scr<script>ipt>`) cannot survive a single pass;
    * inline event-handler attributes (`on\*=`);
    * dangerous URL schemes (`javascript:`, `vbscript:`, non-image `data:`,
      `blob:`) in URL-bearing attributes, neutralised to `#` (`data:image/…`
      inline images are preserved);
    * HTML comments (IE conditional-comment script vector).

  This is the first layer; the reader's `script-src 'self' 'nonce-…'` CSP is
  the allowlist backstop that blocks any inline script/handler a denylist pass
  might miss. Defense in depth — neither layer is trusted alone.
  """

  # Elements removed WITH their inner content. script/style would leak raw
  # text; the rest can host or become a script/handler execution context.
  @dangerous_elements ~w(
    script style iframe object embed applet noscript template
    svg math form frame frameset link meta base title
  )

  @max_passes 8

  @doc """
  Scrub untrusted HTML. Non-binary input is returned unchanged (a nil/absent
  `body_html` is a no-op).
  """
  @spec sanitize(term()) :: term()
  def sanitize(html) when is_binary(html) do
    html
    |> strip_comments()
    |> strip_dangerous_elements(@max_passes)
    |> strip_event_handlers()
    |> neutralize_dangerous_uris()
  end

  def sanitize(other), do: other

  # ── HTML comments (removes <!--[if IE]><script>…<![endif]--> vectors) ──────
  defp strip_comments(html), do: Regex.replace(~r/<!--.*?-->/s, html, "")

  # ── Dangerous elements — iterate to a fixpoint ────────────────────────────
  # A single regex pass over `<scr<script>ipt>alert(1)</script>` leaves a
  # reconstituted `<script>` behind; re-running until the string stops changing
  # (bounded by @max_passes) collapses these tag-splitting evasions.
  defp strip_dangerous_elements(html, 0), do: html

  defp strip_dangerous_elements(html, passes) do
    scrubbed = Enum.reduce(@dangerous_elements, html, &strip_element/2)

    if scrubbed == html do
      html
    else
      strip_dangerous_elements(scrubbed, passes - 1)
    end
  end

  defp strip_element(tag, html) do
    # 1) paired `<tag …>…</tag>` (case-insensitive, dot-matches-newline);
    # 2) any orphan open `<tag …>` / `<tag …/>`;
    # 3) any orphan close `</tag>`.
    paired = ~r/<#{tag}\b[^>]*>.*?<\/#{tag}\s*>/is
    open = ~r/<#{tag}\b[^>]*\/?>/is
    close = ~r/<\/#{tag}\s*>/is

    html
    |> then(&Regex.replace(paired, &1, ""))
    |> then(&Regex.replace(open, &1, ""))
    |> then(&Regex.replace(close, &1, ""))
  end

  # ── Inline event handlers: on*="…" / on*='…' / on*=bare ───────────────────
  defp strip_event_handlers(html) do
    Regex.replace(~r/\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i, html, "")
  end

  # ── Dangerous URL schemes in URL-bearing attributes ───────────────────────
  # Matches attr = (optional quote) scheme: … and rewrites the value to "#".
  @url_attrs ~w(href src xlink:href action formaction poster background)

  defp neutralize_dangerous_uris(html) do
    attr_alt = @url_attrs |> Enum.map(&Regex.escape/1) |> Enum.join("|")

    # Capture attr, opening quote, scheme, and the immediate value tail (so a
    # `data:image/…` inline image can be distinguished from `data:text/html`).
    Regex.replace(
      ~r/\b(#{attr_alt})\s*=\s*(["']?)\s*([a-z][a-z0-9\-.+]*)\s*:([^"'>\s]*)/i,
      html,
      fn full, attr, quote, scheme, rest ->
        if dangerous_scheme?(scheme, rest) do
          "#{attr}=#{quote}#"
        else
          full
        end
      end
    )
  end

  # `data:image/…` is the one preserved `data:` form (inline images from real
  # producers); every other data:/blob:/javascript:/vbscript: is neutralised.
  defp dangerous_scheme?(scheme, rest) do
    case String.downcase(scheme) do
      "data" -> not String.starts_with?(String.downcase(rest), "image/")
      s -> s in ~w(javascript vbscript blob)
    end
  end
end
