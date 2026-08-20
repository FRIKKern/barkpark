defmodule Barkpark.PortableDoc.Render.PanelsEmail do
  @moduledoc """
  Email-safe `_raw` HTML emitters for the FLEET *panel* blocks — `terminal`,
  `columns`, and `status-legend` — the inline-styled twins of the classed
  article emitters (`Compose.compose_block/2` `:article` clauses +
  `Render.Components.status_legend_html/1`).

  Same family contract as `Render.DataViz`: pure, snapshot-driven leaf emitters
  that render a byte string `compose_block` wraps as `%{"kind" => "_raw", "html"
  => …}`. No DB, no plugin, deterministic (testable byte-for-byte). In a
  stylesheet-less email client the classed `bp-term` / `bp-cols` / `bp-legend`
  markup arrives as unstyled text runs; these variants carry every rule inline
  and lay layout out as `<table>` (Outlook's only reliable grid).

  ## Colour (charter D2)

  Chrome (border / bar tint / ink / muted / paper / ground) resolves through
  `Palettes.email_skin/1` at render time — the SAME captured `paperEmail` hex the
  DataViz email variants and the article `var()` fallbacks draw on, never a
  hand-typed literal. Status glyph colour comes from `StatusVocab.tones()` (the
  status-manifest, which the reader's `--st-*` tokens also derive from), so the
  legend never drifts from the reader:

    * `done` → `tones["ok"]`, `progress` → `tones["info"]`, `blocked` →
      `tones["warn"]` (light rung — email renders light, the mail client's
      dark-mode is its own transform of these bytes);
    * `ready` → `skin.ink`, `open` / `cancel` → `skin.muted`.

  ## Nesting (charter D1/D8)

  `terminal` and `columns` are CONTAINERS: their child blocks are composed at the
  `compose.ex` call site through `render_children/2` (style-only, no theme) and
  handed here as ready HTML — so a fleet or data-viz block nested inside a panel
  gets its OWN email variant at evergreen, the same accepted tradeoff DataViz
  documented. There is no follow-on task for nested panel theming (explorer-
  verified); the compose.ex SCOPE comment states this by design.
  """

  import Barkpark.PortableDoc.Render.Util, only: [escape_html: 1]

  alias Barkpark.PortableDoc.Render.{Palettes, StatusVocab}

  # ── terminal ─────────────────────────────────────────────────────────────────

  @doc """
  Email-safe terminal chrome: a bordered `<table>` whose title-bar row carries
  three traffic-dot cells + a mono title (+ an optional static `live` dot), a
  body row of the already-composed child blocks, and an optional mono muted
  footer. LIGHT-chromed to match the reader (paper-surface.css:661 — an ink-tint
  bar over a paper body); the direction's "dark panel" is overruled by reader
  parity.

  `body_html` is the children fragment composed at the compose.ex call site
  (evergreen-nested, D1). `theme` themes only the chrome.
  """
  def terminal_email_html(block, body_html, theme \\ :evergreen)

  def terminal_email_html(block, body_html, theme) when is_map(block) do
    sk = skin(theme)
    title = block |> get("title") |> stringish() |> escape_html()
    footer = block |> get("footer") |> stringish()
    mono = Palettes.font_mono()

    live =
      if get(block, "live") in [true, "true", "live"] do
        # Static live dot in the "ok" tone (StatusVocab.tones()["ok"]) — the
        # reader animates a glow; email degrades to a solid dot + label.
        ok = tone_hex("ok")

        ~s|<td align="right" style="font-family:#{mono};font-size:11px;color:#{ok};white-space:nowrap"><span style="display:inline-block;width:7px;height:7px;border-radius:50%;background:#{ok};vertical-align:middle;margin-right:5px"></span>live</td>|
      else
        ""
      end

    foot =
      if footer == "",
        do: "",
        else:
          ~s|<tr><td style="padding:8px 12px;border-top:1px solid #{sk.border};font-family:#{mono};font-size:11px;color:#{sk.muted};background:#{sk.ground}">#{escape_html(footer)}</td></tr>|

    ~s|<table role="presentation" cellspacing="0" cellpadding="0" style="width:100%;border-collapse:separate;border:1px solid #{sk.border};border-radius:10px;background:#{sk.paper};margin:12px 0">| <>
      ~s|<tr><td style="padding:8px 12px;border-bottom:1px solid #{sk.border};background:#{sk.ground}">| <>
      ~s|<table role="presentation" cellspacing="0" cellpadding="0" style="width:100%"><tr>| <>
      ~s|<td style="padding-right:10px;white-space:nowrap;vertical-align:middle">#{traffic_dots()}</td>| <>
      ~s|<td style="width:100%;font-family:#{mono};font-size:12px;color:#{sk.muted};vertical-align:middle">#{title}</td>| <>
      live <>
      "</tr></table></td></tr>" <>
      ~s|<tr><td style="padding:8px 8px">#{body_html}</td></tr>| <>
      foot <>
      "</table>"
  end

  def terminal_email_html(_block, _body_html, _theme), do: ""

  # The three traffic dots — a tight nested table, one <td> cell per dot.
  #
  # The hexes #ef4444 / #f59e0b / #22c55e are HARD-CODED LITERALS: the reader
  # hard-codes the exact same untokenized values (paper-surface.css:668-670
  # `.bp-term__dots i:nth-child(n)`). This is the ONE documented literal-hex
  # exception in the email fleet — the traffic-light palette is a fixed brand
  # convention, not a theme token, so email and reader must agree byte-for-byte.
  defp traffic_dots do
    ~s|<table role="presentation" cellspacing="0" cellpadding="0"><tr>| <>
      dot_cell("#ef4444", true) <>
      dot_cell("#f59e0b", true) <>
      dot_cell("#22c55e", false) <>
      "</tr></table>"
  end

  defp dot_cell(hex, gap) do
    pad = if gap, do: "padding-right:6px", else: ""

    ~s|<td style="#{pad}"><div style="width:11px;height:11px;border-radius:50%;background:#{hex};font-size:0;line-height:0">&nbsp;</div></td>|
  end

  # ── columns ──────────────────────────────────────────────────────────────────

  @doc """
  Email-safe columns: a fixed single-row `<table>`, one `vertical-align:top`
  `<td>` per column at equal width. NO reflow on narrow (accepted, charter D5) —
  Outlook has no reliable media-query column collapse.

  `cols_html` is the list of already-composed column fragments (each column's
  children rendered at the compose.ex call site, evergreen-nested).
  """
  def columns_email_html(cols_html, theme \\ :evergreen)

  def columns_email_html(cols_html, _theme) when is_list(cols_html) and cols_html != [] do
    n = length(cols_html)
    pct = Float.round(100.0 / n, 2)
    last = n - 1

    cells =
      cols_html
      |> Enum.with_index()
      |> Enum.map_join("", fn {col, i} ->
        pad = if i == last, do: "0", else: "0 16px 0 0"
        ~s|<td style="vertical-align:top;width:#{pct}%;padding:#{pad}">#{col}</td>|
      end)

    ~s|<table role="presentation" cellspacing="0" cellpadding="0" style="width:100%;border-collapse:separate;margin:12px 0"><tr>#{cells}</tr></table>|
  end

  def columns_email_html(_cols_html, _theme), do: ""

  # ── status-legend ────────────────────────────────────────────────────────────

  @doc """
  Email-safe status-legend: one `<tr>` per ladder role — a colour-tinted glyph
  cell + a mono name + the one-line meaning. Self-contained (the vocabulary IS
  the vocabulary): rows, order, glyph, name and meaning all derive from the ONE
  manifest source via `StatusVocab`; glyph colour from `StatusVocab.tones()` /
  the email skin (charter D2).
  """
  def status_legend_email_html(block, theme \\ :evergreen)

  def status_legend_email_html(_block, theme) do
    sk = skin(theme)
    mono = Palettes.font_mono()

    rows =
      StatusVocab.roles()
      |> Enum.map_join("", fn role ->
        name = role |> StatusVocab.label_for_role() |> escape_html()
        meaning = role |> StatusVocab.meaning_for_role() |> escape_html()

        ~s|<tr>| <>
          ~s|<td style="font-family:#{mono};font-weight:700;font-size:14px;color:#{role_glyph_hex(role, sk)};padding:6px 10px;text-align:center;width:1.4em">#{legend_glyph(role)}</td>| <>
          ~s|<td style="font-family:#{mono};font-size:12px;font-weight:600;color:#{sk.ink};padding:6px 10px;white-space:nowrap">#{name}</td>| <>
          ~s|<td style="font-size:13px;color:#{sk.muted};padding:6px 10px">#{meaning}</td>| <>
          "</tr>"
      end)

    ~s|<table role="presentation" cellspacing="0" cellpadding="0" style="border-collapse:separate;border:1px solid #{sk.border};border-radius:10px;background:#{sk.paper};margin:12px 0">#{rows}</table>|
  end

  # The spinner role ("progress") has no static manifest glyph (the reader
  # CSS-animates a Braille frame); email degrades to a static ⠿ (charter D5,
  # the same static-Braille degrade the task family uses).
  defp legend_glyph(role) do
    case StatusVocab.glyph_for_role(role) do
      "" -> "⠿"
      g -> escape_html(g)
    end
  end

  # role → glyph colour, matching the reader's `.bp-g--*` tone map: done/progress/
  # blocked take a status TONE, ready takes the ink, open/cancel take the muted ink
  # (charter D2). The thought states (charter D9/D12): researching carries the violet
  # tone (its one new hue), considering is dim so it reads as the muted ink.
  defp role_glyph_hex("done", _sk), do: tone_hex("ok")
  defp role_glyph_hex("progress", _sk), do: tone_hex("info")
  defp role_glyph_hex("blocked", _sk), do: tone_hex("warn")
  defp role_glyph_hex("researching", _sk), do: tone_hex("violet")
  defp role_glyph_hex("ready", sk), do: sk.ink
  defp role_glyph_hex("open", sk), do: sk.muted
  defp role_glyph_hex("cancel", sk), do: sk.muted
  defp role_glyph_hex("considering", sk), do: sk.muted
  defp role_glyph_hex(_role, sk), do: sk.ink

  # ── skin + tones ─────────────────────────────────────────────────────────────

  # Email-safe skin resolved PER THEME at render time (mirrors DataViz.email_skin/1).
  # Sourced from the same captured paperEmail hex via Palettes.email_skin/1 —
  # single source, zero re-typing. Evergreen (default) is byte-stable.
  defp skin(theme) do
    s = Palettes.email_skin(theme)

    %{
      ink: s.text,
      muted: s.muted,
      accent: s.brand,
      ground: s.page_bg,
      border: s.rule,
      paper: s.paper
    }
  end

  # Status tone → its LIGHT hex (email renders light; the mail client owns dark
  # mode). Sourced from StatusVocab.tones() (status-manifest) so the legend/live
  # dot never drift from the reader's `--st-*` tokens.
  defp tone_hex(tone) do
    StatusVocab.tones()
    |> Map.get(tone, %{})
    |> Map.get("light", "#000000")
  end

  # ── small helpers ────────────────────────────────────────────────────────────

  defp get(m, k) when is_map(m), do: Map.get(m, k)
  defp get(_, _), do: nil

  defp stringish(v) when is_binary(v), do: v
  defp stringish(nil), do: ""
  defp stringish(v) when is_number(v) or is_atom(v), do: to_string(v)
  defp stringish(_), do: ""
end
