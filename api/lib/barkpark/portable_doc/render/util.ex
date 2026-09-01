defmodule Barkpark.PortableDoc.Render.Util do
  @moduledoc """
  Leaf string-safety + tone helpers for the PortableDoc render engine.

  Pure, dependency-free: HTML escaping, URL scheme allowlisting, and the
  callout tone palette. Extracted verbatim from `Barkpark.PortableDoc.Render`
  (module location only — NO logic change) so the many call sites across the
  compose / walk / forms / figures families share one owner. Output is
  byte-identical to the pre-split engine.
  """

  @allowed_scheme ~r/^(?:https?|mailto|tel):/i

  # Control bytes removed from the WHOLE href before any check — the exact set
  # `isCtrlRune` strips in the Go twin (`internal/pdrender/inline.go`:
  # `r < 0x20 || r == 0x7f`). Kept as one @-attribute so the two sets are
  # comparable by eye; see `safe_url/1` for why the strip must be global.
  @control_bytes ~r/[\x00-\x1F\x7F]/
  # Leading spaces (0x20) only. The Go twin does NOT strip these — a leading
  # space makes `urlScheme` return "" there, so the value passes through as
  # schemeless. Elixir has always trimmed them, and continuing to is a NO-OP
  # for every allowed form, so this line preserves shipped behaviour rather
  # than importing a divergence in the name of parity.
  @leading_spaces ~r/^\x20+/

  @doc """
  Escape the five HTML-significant characters in the EXACT order `& < > " '`.

  The ampersand must go first so we never double-escape the entities the later
  replacements introduce.
  """
  def escape_html(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  # Fail-soft: a non-binary leaf (JSON null → nil, or a number/list/map off
  # stored JSON) escapes to nothing rather than raising and 500-ing the reader.
  def escape_html(_), do: ""

  @doc "Stricter escape for attribute values — same as `escape_html/1`."
  def escape_attr(s) when is_binary(s), do: escape_html(s)

  # Fail-soft twin of `escape_html/1` for non-binary leaves.
  def escape_attr(_), do: ""

  @doc """
  Return the URL attribute-escaped if it is safe to emit, else `#`.

  Permitted forms: an allowlisted scheme (`http | https | mailto | tel`,
  case-insensitive), a root-relative path (`/…`, but NOT protocol-relative
  `//host`), or a scheme-less in-document / relative / query form
  (`#anchor`, `?query`, `./rel`, `../up`). Bare relative words (`other-page`)
  are rejected, mirroring the stricter JS sibling.

  Parity twins — keep the permitted set in lockstep:
  `web/lib/safe-href.ts` and `internal/pdrender/inline.go` (`sanitizeURL`).

  ASCII control bytes (0x00-0x1F and 0x7F) are removed from the WHOLE string
  before matching, not just from its head, and the CLEANED string is what gets
  emitted — so the value that was CHECKED is the value that RESOLVES.

  This is the parity point, and a leading-only strip is what made it a defect:
  the WHATWG URL parser deletes ASCII tab / LF / CR from ANYWHERE in a URL
  before it parses. Strip only the head and then test position 1 for the
  protocol-relative `//` or `/\\` form, and `/<TAB>/evil.example/phish` reads as
  an ordinary root-relative path here while a browser resolves it to
  `https://evil.example/phish` — an off-site navigation out of a CMS-authored
  link, straight past the scheme allowlist. Measured against the Go twin before
  the fix: `sanitizeURL` dropped all seven embedded-control protocol-relative
  forms; `safe_url/1` returned every one of them unchanged.

  The strip set is `internal/pdrender/inline.go`'s `isCtrlRune`
  (`r < 0x20 || r == 0x7f`) exactly — wider than the JS twins' `[\\t\\n\\r]`,
  because the Go renderer is the reference implementation for this function and
  a third behaviour would be a new divergence, not a fix.
  """
  def safe_url(href) when is_binary(href) do
    trimmed =
      href
      |> String.replace(@control_bytes, "")
      |> String.replace(@leading_spaces, "")

    cond do
      String.starts_with?(trimmed, "/") ->
        # Reject protocol-relative `//host` (and browser-normalized `/\host`),
        # which would escape the scheme allowlist into an off-site navigation.
        if protocol_relative?(trimmed), do: "#", else: escape_attr(trimmed)

      Regex.match?(@allowed_scheme, trimmed) ->
        escape_attr(trimmed)

      # Scheme-less in-document / relative / query forms. A string starting
      # with #, ?, or . cannot be protocol-relative, so no extra guard needed.
      Regex.match?(~r/^(#|\?|\.\/|\.\.\/)/, trimmed) ->
        escape_attr(trimmed)

      true ->
        "#"
    end
  end

  # Fail-soft: a non-binary href (JSON null → nil, or a number/list/map off
  # stored JSON) degrades to `#` rather than raising and 500-ing the reader.
  def safe_url(_), do: "#"

  defp protocol_relative?(s), do: Regex.match?(~r|^/[/\\]|, s)

  @doc "Background / foreground palette for a callout tone."
  # Light tone tints, harmonized to the evergreen paper ground — semantic hues
  # kept (info blue / success green / warning amber / danger red), saturation
  # pulled toward the profile so a toned callout sits IN the page instead of on
  # it. Success is evergreen-kin by design. The {bg,fg} pairs are sourced
  # VERBATIM from design/tokens.json paperCallout via TokensGen (theme-system
  # Wave 1 CAPTURE). Mirrored by the `--bp-tone-*` light block in
  # paper-surface.css — change both (the token) together.
  alias Barkpark.PortableDoc.Render.TokensGen

  def tone_palette("success"), do: TokensGen.callout(:success)
  def tone_palette("warning"), do: TokensGen.callout(:warning)
  def tone_palette("danger"), do: TokensGen.callout(:danger)
  def tone_palette("info"), do: TokensGen.callout(:info)
  def tone_palette("neutral"), do: TokensGen.callout(:neutral)
  # Unknown/`nil` tone degrades to the info tint (same value set).
  def tone_palette(_), do: TokensGen.callout(:info)
end
