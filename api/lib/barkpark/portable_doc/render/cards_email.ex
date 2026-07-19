defmodule Barkpark.PortableDoc.Render.CardsEmail do
  @moduledoc """
  Email-safe `_raw` HTML emitters for the CARDS / NOTES / PIPELINE fleet
  (`cards`, `card`, `notes`, `note`, `pipeline`, `stage`) — the inline-styled
  siblings of the classed `Render.Components` emitters, the same relationship
  `Render.DataViz`'s `*_email_html/2` variants have to the classed data-viz
  emitters. Email clients strip `<style>`/`class`, so the reader's `bp-*`
  markup arrives as unstyled text runs; every emitter here bakes the theme skin
  into `style=""` attributes and lays layout out with real tables where the
  clients demand it (Outlook is the contract).

  Same family contract as `Render.DataViz`: pure, snapshot-driven leaf emitters
  — a block carries literal data in its attrs, each `*_email_html(block, theme)`
  returns a byte string that `Compose.compose_block/3` wraps as
  `%{"kind" => "_raw", "html" => …}`. No DB, no plugin, deterministic output.

  ## Shared helpers (byte-shared by construction)

    * `card_cell/3` renders ONE bordered card box — used for both a `cards`
      grid item AND the singular `card` block (same tone allowlist
      `info|ok|warn|danger`).
    * `note_row/2` renders ONE annotated note ROW — used for both a `notes`
      item AND the singular `note`.
    * `pnode_cell/6` renders ONE pipeline-node box — used for both a `pipeline`
      node AND the singular `stage`; a `stage` carrying the same scalars a
      pipeline node carries renders the byte-IDENTICAL cell (the documented
      twin invariant, held in email too — see `cards_email_test.exs`).

  ## Colours (charter D2)

  Skin hexes come from `Palettes.email_skin(theme)` (the theme-resolved
  captured `paperEmail` hand hex — the SAME source the email palette and
  article var() fallbacks draw on). Card tones come from `StatusVocab.tones()`
  light values (`info #2563eb`, `ok #0d9488`, `warn #d97706`, `danger #dc2626`
  — matching the reader `--st-*`). NEVER `TokensGen.tone_*`, never a hand-typed
  hex.

  ## Theme threading (charter D1)

  `card`'s slot children recurse through the existing
  `Compose.render_children/2` at `:email` — nested blocks pick their OWN email
  variants through their `/2 _style` clauses at the evergreen default (theme is
  NOT threaded through recursion, matching the nested-email data-viz rule).
  """

  import Barkpark.PortableDoc.Render.Util, only: [escape_html: 1]

  alias Barkpark.PortableDoc.Render.{Compose, Palettes, StatusVocab}
  alias Barkpark.PortableDoc.Slots

  # ── cards / card (shared card-cell) ─────────────────────────────────────────

  @doc "Email-safe `cards` grid: a fixed 2-column table of tone-topped card boxes."
  def cards_email_html(block, theme \\ :evergreen)

  def cards_email_html(block, theme) when is_map(block) do
    items = block |> get("items") |> as_list() |> Enum.filter(&is_map/1)

    case items do
      [] ->
        empty_email("cards", theme)

      _ ->
        sk = skin(theme)

        cells =
          Enum.map(items, fn it ->
            title = it |> get("title") |> stringish()
            text = it |> get("text") |> stringish()
            tone = it |> get("tone") |> stringish()
            card_cell(card_scalars_inner(title, text, sk), tone, sk)
          end)

        rows =
          cells
          |> Enum.chunk_every(2)
          |> Enum.map_join("", fn row ->
            tds =
              Enum.map_join(row, "", fn c ->
                ~s|<td style="width:50%;vertical-align:top;padding:0 6px 12px 6px">#{c}</td>|
              end)

            pad =
              if length(row) == 1,
                do: ~s|<td style="width:50%;padding:0 6px 12px 6px"></td>|,
                else: ""

            "<tr>#{tds}#{pad}</tr>"
          end)

        ~s|<table role="presentation" cellspacing="0" cellpadding="0" style="width:100%;border-collapse:collapse;margin:12px 0">#{rows}</table>|
    end
  end

  def cards_email_html(_, theme), do: empty_email("cards", theme)

  @doc """
  Email-safe singular `card`: ONE tone-topped card box whose media/title/body/
  action slots recurse through `Compose.render_children/2` (at `:email`,
  evergreen-nested — theme not threaded, charter D1).
  """
  def card_email_html(block, theme \\ :evergreen)

  def card_email_html(block, theme) when is_map(block) do
    sk = skin(theme)
    tone = block |> get("tone") |> stringish()

    inner =
      card_slot_html(block, "media") <>
        card_slot_html(block, "title") <>
        card_slot_html(block, "body") <>
        card_slot_html(block, "action")

    card_cell(inner, tone, sk)
  end

  def card_email_html(_, theme), do: empty_email("card", theme)

  # ONE bordered card box — the shared chrome for a `cards` item AND a `card`.
  # A recognised tone paints the top border its `StatusVocab.tones()` light hex;
  # an absent/unknown tone stays on the neutral rule (a card without a status
  # never wears a status colour).
  defp card_cell(inner, tone, sk) do
    top = tone_hex(tone) || sk.border

    ~s|<div style="background:#{sk.paper};border:1px solid #{sk.border};border-top:3px solid #{top};border-radius:10px;padding:14px 16px">#{inner}</div>|
  end

  # A legacy `cards` item's scalar title/text → the card box inner (bold title +
  # muted prose). The `card` block feeds recursed slot HTML through card_cell/3
  # instead, so this scalar path is the `cards`-only leg.
  defp card_scalars_inner(title, text, sk) do
    t =
      if title == "",
        do: "",
        else:
          ~s|<div style="font-weight:700;font-size:15px;line-height:1.3;color:#{sk.ink};margin-bottom:4px">#{escape_html(title)}</div>|

    d =
      if text == "",
        do: "",
        else:
          ~s|<div style="font-size:14px;line-height:1.55;color:#{sk.muted}">#{escape_html(text)}</div>|

    t <> d
  end

  # Recurse ONE named card slot's element children through the shared compose→
  # walk bridge at :email (mirrors Components.card_slot_html/3). The `media` slot
  # defensively normalises a typeless `{src,alt}` element to `type:"image"`.
  defp card_slot_html(block, "media") do
    block
    |> Slots.slot_elements("media")
    |> Enum.map(&normalize_media_element/1)
    |> Compose.render_children(:email)
  end

  defp card_slot_html(block, name) do
    block
    |> Slots.slot_elements(name)
    |> Compose.render_children(:email)
  end

  defp normalize_media_element(%{"type" => _} = el), do: el
  defp normalize_media_element(el) when is_map(el), do: Map.put(el, "type", "image")
  defp normalize_media_element(el), do: el

  # ── notes / note (shared note-row) ──────────────────────────────────────────

  @doc "Email-safe `notes` block: a table of annotated label-chip + prose rows."
  def notes_email_html(block, theme \\ :evergreen)

  def notes_email_html(block, theme) when is_map(block) do
    items = block |> get("items") |> as_list()

    case items do
      [] ->
        empty_email("notes", theme)

      _ ->
        sk = skin(theme)
        notes_table(Enum.map_join(items, "", &note_row(&1, sk)))
    end
  end

  def notes_email_html(_, theme), do: empty_email("notes", theme)

  @doc "Email-safe singular `note`: ONE note row in the shared notes table shell."
  def note_email_html(block, theme \\ :evergreen)

  def note_email_html(block, theme) when is_map(block) do
    notes_table(note_row(block, skin(theme)))
  end

  def note_email_html(_, theme), do: empty_email("note", theme)

  defp notes_table(rows) do
    ~s|<table role="presentation" cellspacing="0" cellpadding="0" style="width:100%;border-collapse:collapse;margin:12px 0">#{rows}</table>|
  end

  # ONE annotated note ROW — the shared row for a `notes` item AND a `note`. The
  # three fields read through the `Slots.note_{label,lead,body}_text/1`
  # byte-identity accessors, so a bare legacy `notes` item and a `note` widget
  # (flat or slot-materialized) yield the SAME bytes. Chip cell = accent-tinted
  # mono label; prose cell = a bold `lead` (single trailing space) + body text.
  defp note_row(item, sk) do
    label = item |> Slots.note_label_text() |> escape_html()
    text = item |> Slots.note_body_text() |> escape_html()
    lead = item |> Slots.note_lead_text() |> String.trim()
    lead_html = if lead == "", do: "", else: ~s|<b>#{escape_html(lead)}</b> |
    chip_bg = mix_hex(0.12, sk.accent, sk.paper)

    ~s|<tr>| <>
      ~s|<td style="width:132px;vertical-align:top;padding:6px 12px 6px 0"><span style="display:inline-block;background:#{chip_bg};color:#{sk.accent};font-family:#{Palettes.font_mono()};font-size:11px;font-weight:600;line-height:1.3;padding:3px 8px;border-radius:6px">#{label}</span></td>| <>
      ~s|<td style="vertical-align:top;padding:6px 0;font-size:14px;line-height:1.55;color:#{sk.ink}">#{lead_html}#{text}</td>| <>
      "</tr>"
  end

  # ── pipeline / stage (shared pnode-cell) ────────────────────────────────────

  @doc "Email-safe `pipeline`: one horizontal table of node cells joined by arrows."
  def pipeline_email_html(block, theme \\ :evergreen)

  def pipeline_email_html(block, theme) when is_map(block) do
    nodes = block |> get("nodes") |> as_list() |> Enum.filter(&is_map/1)

    case nodes do
      [] ->
        empty_email("pipeline", theme)

      _ ->
        sk = skin(theme)

        cells =
          Enum.map(nodes, fn n ->
            kind = n |> get("kind") |> stringish()
            title = n |> get("title") |> stringish()
            detail = n |> get("detail") |> stringish()
            files = n |> get("files") |> stringish()
            source = get(n, "source")
            pnode_cell(kind, title, detail, files, source, sk)
          end)

        arrow =
          ~s|<td style="vertical-align:middle;padding:0 8px;font-size:18px;color:#{sk.muted}">→</td>|

        tds =
          cells
          |> Enum.map(fn c -> ~s|<td style="vertical-align:top;padding:0">#{c}</td>| end)
          |> Enum.intersperse(arrow)
          |> Enum.join("")

        ~s|<table role="presentation" cellspacing="0" cellpadding="0" style="border-collapse:collapse;margin:12px 0"><tr>#{tds}</tr></table>|
    end
  end

  def pipeline_email_html(_, theme), do: empty_email("pipeline", theme)

  @doc """
  Email-safe singular `stage`: ONE pipeline-node cell (no flow wrapper). Reads
  `kind`/`title`/`detail` through `Slots.stage_field_text/2` (slots OR scalar —
  both yield the same string), so a stage carrying the same scalars a pipeline
  node carries emits the byte-IDENTICAL `pnode_cell/6` — the documented twin.
  """
  def stage_email_html(block, theme \\ :evergreen)

  def stage_email_html(block, theme) when is_map(block) do
    sk = skin(theme)
    kind = Slots.stage_field_text(block, "kind")
    title = Slots.stage_field_text(block, "title")
    detail = Slots.stage_field_text(block, "detail")
    files = block |> get("files") |> stringish()
    source = get(block, "source")
    pnode_cell(kind, title, detail, files, source, sk)
  end

  def stage_email_html(_, theme), do: empty_email("stage", theme)

  # ONE pipeline-node box — the shared cell for a `pipeline` node AND a `stage`.
  # `kind` sits uppercase in the accent, `files` in mono, `source` coerced by
  # type the SAME way `Components.pnode_source/1` does: boolean `true` → the
  # accent border (an origin node), a non-empty string → a provenance line
  # (neutral border), else nothing.
  defp pnode_cell(kind, title, detail, files, source, sk) do
    {border, prov} = pnode_source(source, sk)

    k =
      if kind == "",
        do: "",
        else:
          ~s|<div style="font-family:#{Palettes.font_mono()};font-size:11px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;color:#{sk.accent};margin-bottom:4px">#{escape_html(kind)}</div>|

    t =
      if title == "",
        do: "",
        else:
          ~s|<div style="font-size:14px;font-weight:600;line-height:1.3;color:#{sk.ink};margin-bottom:2px">#{escape_html(title)}</div>|

    d =
      if detail == "",
        do: "",
        else:
          ~s|<div style="font-size:13px;line-height:1.45;color:#{sk.muted}">#{escape_html(detail)}</div>|

    f =
      if files == "",
        do: "",
        else:
          ~s|<div style="font-family:#{Palettes.font_mono()};font-size:11px;color:#{sk.muted};margin-top:4px">#{escape_html(files)}</div>|

    ~s|<div style="display:inline-block;min-width:120px;vertical-align:top;background:#{sk.paper};border:1px solid #{border};border-radius:10px;padding:10px 12px">#{k}#{t}#{d}#{f}#{prov}</div>|
  end

  # `source` coerced by type (the pipeline/stage twin's chrome). Returns the
  # {border colour, provenance HTML}: `true` → accent border, no line; a
  # non-empty string → neutral border + a mono provenance line; else neutral.
  defp pnode_source(true, sk), do: {sk.accent, ""}

  defp pnode_source(s, sk) when is_binary(s) and s != "" do
    {sk.border,
     ~s|<div style="font-family:#{Palettes.font_mono()};font-size:11px;color:#{sk.muted};margin-top:6px">#{escape_html(s)}</div>|}
  end

  defp pnode_source(_, sk), do: {sk.border, ""}

  # ── skin + colour helpers ───────────────────────────────────────────────────

  # Theme-resolved email skin (charter D2/D28) — the SAME captured paperEmail hex
  # DataViz.email_skin/1 reads. Evergreen output is byte-stable.
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

  # The card tone → its light hex, from the StatusVocab manifest (never hand-typed
  # and never TokensGen.tone_*). Allowlist info|ok|warn|danger|violet (violet is the
  # thought-state hue — considering/researching, charter D9/D12); anything else nil.
  defp tone_hex(tone) when is_binary(tone) do
    case StatusVocab.tones() do
      %{^tone => %{"light" => hex}} when tone in ~w(info ok warn danger violet) -> hex
      _ -> nil
    end
  end

  defp tone_hex(_), do: nil

  # A hex mixed over a hex at intensity t (email has no color-mix()), the general
  # twin of DataViz.mix_hex/2 — used for the note chip's accent tint.
  defp mix_hex(t, fg_hex, bg_hex) do
    {fr, fg, fb} = hex_to_rgb(fg_hex)
    {br, bg, bb} = hex_to_rgb(bg_hex)
    mix = fn a, b -> round(a * t + b * (1 - t)) end

    "#" <>
      Enum.map_join([mix.(fr, br), mix.(fg, bg), mix.(fb, bb)], "", fn c ->
        c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
      end)
  end

  defp hex_to_rgb("#" <> <<r::binary-2, g::binary-2, b::binary-2>>),
    do: {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}

  defp empty_email(kind, theme) do
    sk = skin(theme)

    ~s|<div style="border:1px dashed #{sk.border};border-radius:10px;padding:10px 13px;color:#{sk.muted};font-family:#{Palettes.font_mono()};font-size:12px;margin:12px 0">#{escape_html(kind)} — no data</div>|
  end

  # ── small helpers (Components/DataViz conventions) ──────────────────────────

  defp get(m, k) when is_map(m), do: Map.get(m, k)
  defp get(_, _), do: nil

  defp as_list(l) when is_list(l), do: l
  defp as_list(_), do: []

  defp stringish(s) when is_binary(s), do: s
  defp stringish(n) when is_integer(n), do: Integer.to_string(n)
  defp stringish(_), do: ""
end
