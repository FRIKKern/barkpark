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

  # The three bytes the WHATWG URL parser deletes from ANYWHERE in a URL before
  # parsing it. Measured against `new URL(raw, base)` across `\x00`-`\x20`:
  # exactly `\x09` / `\x0A` / `\x0D` collapse `/<c>/host` into the
  # protocol-relative `//host`; every other C0 byte percent-encodes and stays an
  # ordinary path segment. Twin of `URL_STRIPPED` in
  # `js/packages/react/src/inline.tsx` and `web/lib/safe-href.ts`.
  @url_stripped ["\t", "\n", "\r"]

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

  ASCII tab / LF / CR are removed from ANYWHERE in the string FIRST, not just
  at the head: the WHATWG URL parser deletes those three bytes before parsing,
  so `/<TAB>/host` is not a path segment named TAB — it is the protocol-relative
  `//host`, and a leading-only strip plus a position-1 test never sees it. Any
  remaining leading ASCII control / whitespace bytes are stripped after that,
  mirroring browser tolerance for `\\tjavascript:…`. The cleaned string is what
  gets emitted, so what was CHECKED is what RESOLVES.

  Parity twins — keep the permitted set in lockstep:
  `web/lib/safe-href.ts`, `js/packages/react/src/inline.tsx` (`safeUrl`) and
  `internal/pdrender/inline.go` (`sanitizeURL`). The JS pair strips the same
  three bytes. `sanitizeURL` deletes the whole C0 set plus DEL because its
  output is an OSC 8 terminal sequence, where any control byte can hijack the
  reader's terminal — a hazard this HTML lane does not have, since attribute
  quotes are already entity-escaped. The divergence is consumer-driven.
  """
  def safe_url(href) when is_binary(href) do
    trimmed =
      href
      |> String.replace(@url_stripped, "")
      |> String.replace(~r/^[\x00-\x20]+/, "")

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
