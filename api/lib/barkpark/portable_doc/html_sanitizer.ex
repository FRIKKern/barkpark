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
  @url_attrs ~w(href src xlink:href action formaction poster background)

  # Named HTML entities a browser decodes inside an attribute value that can
  # forge or hide a dangerous URL scheme. The colon is the payload; tab/newline
  # obfuscate the scheme token (a browser strips them before URL parsing).
  @scheme_entities %{
    "colon" => ":",
    "tab" => "\t",
    "newline" => "\n",
    "sol" => "/",
    "newl" => "\n"
  }

  # Capture the FULL attribute value (quoted or bare) and judge it the way a
  # browser will: decode HTML entities and drop ASCII control/space from the
  # scheme, THEN test the scheme. A raw-byte scheme test (the naive version)
  # was defeated by an entity-encoded colon — `href="javascript&#58;alert(1)"`
  # has no literal `:` after the scheme token, so it slipped through while the
  # browser decoded `&#58;`→`:` and executed it. See the entity-bypass cases in
  # html_sanitizer_test.exs.
  defp neutralize_dangerous_uris(html) do
    attr_alt = @url_attrs |> Enum.map(&Regex.escape/1) |> Enum.join("|")

    Regex.replace(
      ~r/\b(#{attr_alt})\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i,
      html,
      fn full, attr, dq, sq, bare ->
        # Exactly one of the three value groups is populated; the others are "".
        value = dq <> sq <> bare

        if dangerous_url?(value) do
          ~s(#{attr}="#")
        else
          full
        end
      end
    )
  end

  defp dangerous_url?(value) do
    normalized =
      value
      |> decode_entities()
      # A browser removes ASCII whitespace/control (incl. tab/newline/CR) while
      # parsing the URL scheme; strip them so `jav\tascript:` reads as
      # `javascript:`.
      |> String.replace(~r/[\x00-\x20]/, "")

    case Regex.run(~r/^([a-z][a-z0-9\-.+]*):(.*)$/is, normalized) do
      [_, scheme, rest] -> dangerous_scheme?(scheme, rest)
      _ -> false
    end
  end

  # `data:image/…` is the one preserved `data:` form (inline images from real
  # producers); every other data:/blob:/javascript:/vbscript: is neutralised.
  defp dangerous_scheme?(scheme, rest) do
    case String.downcase(scheme) do
      "data" -> not String.starts_with?(String.downcase(rest), "image/")
      s -> s in ~w(javascript vbscript blob)
    end
  end

  # Decode the HTML entities a browser resolves in an attribute value: numeric
  # decimal (`&#58;`), numeric hex (`&#x3a;`), and the scheme-relevant named
  # set — with an OPTIONAL trailing `;` (browsers accept numeric refs without
  # it). Over-decoding only risks neutralising a rare legit URL, never a false
  # negative, so it fails safe for a denylist.
  defp decode_entities(value) do
    value
    |> decode_numeric_entities()
    |> decode_named_entities()
  end

  defp decode_numeric_entities(value) do
    value = Regex.replace(~r/&#x([0-9a-f]+);?/i, value, fn _m, hex -> codepoint(hex, 16) end)
    Regex.replace(~r/&#([0-9]+);?/, value, fn _m, dec -> codepoint(dec, 10) end)
  end

  defp decode_named_entities(value) do
    Regex.replace(~r/&([a-z]+);/i, value, fn full, name ->
      Map.get(@scheme_entities, String.downcase(name), full)
    end)
  end

  defp codepoint(digits, base) do
    case Integer.parse(digits, base) do
      # Valid scalar values only — skip surrogates (invalid UTF-8) and
      # out-of-range; a dropped char still can't reconstruct a live scheme.
      {cp, ""} when cp in 0..0xD7FF or cp in 0xE000..0x10FFFF -> <<cp::utf8>>
      _ -> ""
    end
  end
end
