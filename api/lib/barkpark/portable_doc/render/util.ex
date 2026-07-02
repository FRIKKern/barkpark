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

  Leading ASCII control characters / whitespace are stripped before matching,
  mirroring browser tolerance for `\\tjavascript:…`.
  """
  def safe_url(href) when is_binary(href) do
    trimmed = String.replace(href, ~r/^[\x00-\x20]+/, "")

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
  def tone_palette("success"), do: %{bg: "#ecfdf5", fg: "#047857"}
  def tone_palette("warning"), do: %{bg: "#fffbeb", fg: "#92400e"}
  def tone_palette("danger"), do: %{bg: "#fef2f2", fg: "#b91c1c"}
  def tone_palette("info"), do: %{bg: "#eff6ff", fg: "#1d4ed8"}
  def tone_palette("neutral"), do: %{bg: "#f3f4f6", fg: "#374151"}
  def tone_palette(_), do: %{bg: "#eff6ff", fg: "#1d4ed8"}
end
