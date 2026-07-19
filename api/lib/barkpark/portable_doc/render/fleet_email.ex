defmodule Barkpark.PortableDoc.Render.FleetEmail do
  @moduledoc """
  Email-safe (`:email` view) variants of the task-family fleet components —
  `tasks`/`task-list`, `task-detail`, `task-board`, `roadmap`. The sibling of
  `Render.DataViz`'s `*_email_html/2` family (data_viz.ex) for the fleet blocks:
  the classed markup in `Render.Components` leans on `paper-surface.css` (`.bp-*`
  rules + a CSS Braille spinner), so in a stylesheet-less mail client it arrives
  as unstyled text runs. These emitters render the SAME snapshots as real
  components using `<table>` scaffolding and INLINE styles only — Outlook is the
  contract.

  ## Contract (mirrors `Render.Components` + `Render.DataViz`)

  Pure, snapshot-driven leaf emitters: a block carries its resolved data (the
  same `snapshot` / `task` maps `Components` reads) and each function returns a
  byte string that `Compose` wraps as `%{"kind" => "_raw", "html" => …}`. No DB,
  no plugin, deterministic. Every author string flows through `escape_html`; no
  author-controlled colour reaches an inline style.

  ## Colour (charter D2)

  Skin (ink/muted/accent/ground/border/paper) resolves PER THEME through
  `Palettes.email_skin/1` — the same captured hex the email palette and the
  DataViz email variants draw on, never a hand-typed literal. Status hues come
  from `StatusVocab.tones()` (the status-manifest, light values) via a STATIC
  role→tone map — done→`ok`, in_progress→`info`, blocked→`warn` — NOT
  `TokensGen.tone_*` (whose "ok" green is deliberately distinct from the
  lifecycle done teal and would visibly diverge from the reader). `ready`→ink,
  `open`/`cancel`→muted.

  ## Honest degradations (charter D5)

    * roadmap drops the absolute `today` marker (the one genuinely undrawable
      element in a spacer-table bar);
    * the momentum bar is a static accent fill (no shimmer);
    * the `in_progress` Braille spinner degrades to a static `⠿` glyph;
    * task-board renders only NON-EMPTY lifecycle columns as equal-width cells.

  Everything else is lists and grids — email's home turf — and renders as a real
  component.
  """

  import Barkpark.PortableDoc.Render.Util, only: [escape_html: 1]
  alias Barkpark.PortableDoc.Render.{Palettes, StatusVocab}

  # ── tasks / task-list ────────────────────────────────────────────────────────

  @doc "Email-safe task list: momentum header + phase groups + glyph/title/meta rows."
  def tasks_email_html(block, theme \\ :evergreen)

  def tasks_email_html(block, theme) when is_map(block) do
    sk = email_skin(theme)
    rows = block |> get("snapshot") |> as_list()

    case rows do
      [] ->
        empty_email("tasks", "No tasks yet.", theme)

      _ ->
        title = block |> get("title") |> stringish() |> String.trim()

        title_html =
          if title == "",
            do: "",
            else:
              ~s|<div style="font-size:15px;font-weight:700;color:#{sk.ink};margin-bottom:8px">#{escape_html(title)}</div>|

        body =
          rows
          |> group_rows()
          |> Enum.map_join("", fn {phase, rs} -> phase_email(phase, rs, sk) end)

        card(
          title_html <>
            momentum_email(rows, sk) <>
            table_open() <> body <> "</table>",
          sk
        )
    end
  end

  def tasks_email_html(_, theme), do: empty_email("tasks", "No tasks yet.", theme)

  # ── task-detail ──────────────────────────────────────────────────────────────

  @doc "Email-safe task detail: a single-column stack of conditional sections."
  def task_detail_email_html(block, theme \\ :evergreen)

  def task_detail_email_html(block, theme) when is_map(block) do
    sk = email_skin(theme)

    t =
      case get(block, "task") do
        m when is_map(m) -> m
        _ -> block
      end

    title = t |> get("title") |> stringish() |> String.trim()

    case title do
      "" ->
        ""

      _ ->
        role = t |> get("status") |> stringish() |> role_of()

        sections =
          [
            detail_meta(t, role, sk),
            detail_stamp(t, sk),
            detail_timeline(t, sk),
            detail_desc(t, sk),
            detail_criteria(t, sk),
            detail_deps(t, sk),
            detail_rail(t, "children", "Children", sk),
            detail_papers(t, sk),
            detail_labels(t, sk)
          ]
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("")

        card(
          ~s|<div style="font-size:17px;font-weight:700;color:#{sk.ink};margin-bottom:6px">#{escape_html(title)}</div>| <>
            sections,
          sk
        )
    end
  end

  def task_detail_email_html(_, _theme), do: ""

  defp detail_meta(t, role, sk) do
    parts =
      [
        t |> get("status") |> stringish() |> nil_if_empty(),
        priority_label(get(t, "priority")),
        t |> get("kind") |> stringish() |> nil_if_empty(),
        t |> get("worker") |> stringish() |> nil_if_empty()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" · ", &escape_html/1)

    ~s|<div style="margin:2px 0 6px">#{glyph_span(role, sk)}<span style="font-size:12px;color:#{sk.muted};font-family:#{mono()}">#{parts}</span></div>|
  end

  defp detail_stamp(t, sk) do
    c = t |> get("created") |> stringish() |> String.trim()
    u = t |> get("updated") |> stringish() |> String.trim()

    line =
      [c != "" && "created #{escape_html(c)}", u != "" && "updated #{escape_html(u)}"]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    if line == "",
      do: "",
      else:
        ~s|<div style="font-size:11px;color:#{sk.muted};font-family:#{mono()};margin:2px 0 6px">#{line}</div>|
  end

  defp detail_timeline(t, sk) do
    segs = t |> get("timeline") |> as_list()

    case segs do
      [] ->
        ""

      _ ->
        cells =
          segs
          |> Enum.map_join(
            ~s| <span style="color:#{sk.muted}">→</span> |,
            fn s ->
              r = s |> get("status") |> stringish() |> role_of()
              lbl = s |> get("label") |> stringish() |> escape_html()

              ~s|<span style="white-space:nowrap">#{glyph_span(r, sk)}<span style="font-size:12px;color:#{sk.ink}">#{lbl}</span></span>|
            end
          )

        ~s|<div style="margin:6px 0;line-height:1.9">#{cells}</div>|
    end
  end

  defp detail_desc(t, sk) do
    d = t |> get("description") |> stringish() |> String.trim()

    if d == "",
      do: "",
      else:
        ~s|<div style="font-size:13px;color:#{sk.ink};margin:6px 0;line-height:1.5">#{escape_html(d)}</div>|
  end

  defp detail_criteria(t, sk) do
    items = t |> get("criteria") |> as_list()

    case items do
      [] ->
        ""

      _ ->
        met = Enum.count(items, fn c -> truthy(get(c, "met")) end)
        total = length(items)

        rows =
          items
          |> Enum.map_join("", fn c ->
            done = truthy(get(c, "met"))
            role = if done, do: "done", else: "ready"

            txt =
              c
              |> get("text")
              |> stringish()
              |> then(fn s -> if s == "", do: stringish(get(c, "criterion")), else: s end)
              |> escape_html()

            ev = c |> get("evidence") |> stringish() |> String.trim()

            ev_html =
              if ev == "",
                do: "",
                else:
                  ~s|<tr><td></td><td style="font-size:11px;color:#{sk.muted};padding:0 0 4px;font-family:#{mono()}">↳ #{escape_html(ev)}</td></tr>|

            ~s|<tr><td valign="top" width="18" style="color:#{role_color(role, sk)};font-family:#{mono()};font-size:13px;padding:2px 0">#{glyph_char(role)}</td><td valign="top" style="font-size:13px;color:#{sk.ink};padding:2px 0 2px 6px">#{txt}</td></tr>#{ev_html}|
          end)

        detail_label("Criteria · #{met}/#{total}", sk) <>
          table_open() <> rows <> "</table>"
    end
  end

  defp detail_deps(t, sk) do
    blocks = int_or(get(t, "blocks"), 0)
    blocked = int_or(get(t, "blocked_by_count"), int_or(get(t, "blocked_by"), 0))

    words =
      [
        blocks > 0 && "blocks #{blocks} #{plural(blocks, "task")}",
        blocked > 0 && "blocked by #{blocked}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    if words == "",
      do: "",
      else:
        detail_label("Dependencies", sk) <>
          ~s|<div style="font-size:12px;color:#{sk.ink};margin:2px 0 6px">#{words}</div>|
  end

  defp detail_rail(t, key, label, sk) do
    rows = t |> get(key) |> as_list()

    case rows do
      [] ->
        ""

      _ ->
        {shown, extra} = Enum.split(rows, 20)

        done =
          Enum.count(rows, fn r -> r |> get("status") |> stringish() |> role_of() == "done" end)

        body =
          shown
          |> Enum.map_join("", fn r ->
            role = r |> get("status") |> stringish() |> role_of()
            title = r |> get("title") |> stringish() |> escape_html()

            ~s|<tr><td valign="top" width="18" style="color:#{role_color(role, sk)};font-family:#{mono()};font-size:12px;padding:2px 0">#{glyph_char(role)}</td><td valign="top" style="font-size:12px;color:#{sk.ink};padding:2px 0 2px 6px">#{title}</td></tr>|
          end)

        more =
          if extra == [],
            do: "",
            else:
              ~s|<tr><td></td><td style="font-size:11px;color:#{sk.muted};padding:2px 0 0 6px">… and #{length(extra)} more</td></tr>|

        detail_label("#{label} · #{done}/#{length(rows)} done", sk) <>
          table_open() <> body <> more <> "</table>"
    end
  end

  defp detail_papers(t, sk) do
    rows = t |> get("papers") |> as_list()

    case rows do
      [] ->
        ""

      _ ->
        {shown, extra} = Enum.split(rows, 10)

        body =
          shown
          |> Enum.map_join("", fn p ->
            ~s|<div style="font-size:12px;color:#{sk.ink};padding:2px 0">▸ #{escape_html(stringish(p))}</div>|
          end)

        more =
          if extra == [],
            do: "",
            else:
              ~s|<div style="font-size:11px;color:#{sk.muted}">… and #{length(extra)} more</div>|

        detail_label("Papers", sk) <> body <> more
    end
  end

  defp detail_labels(t, sk) do
    labels = t |> get("labels") |> as_list() |> Enum.map(&stringish/1) |> Enum.reject(&(&1 == ""))

    case labels do
      [] ->
        ""

      _ ->
        chips =
          Enum.map_join(labels, "", fn l ->
            ~s|<span style="display:inline-block;font-size:11px;color:#{sk.muted};background:#{sk.ground};border:1px solid #{sk.border};border-radius:10px;padding:1px 8px;margin:6px 6px 0 0;font-family:#{mono()}">#{escape_html(l)}</span>|
          end)

        ~s|<div style="margin-top:2px">#{chips}</div>|
    end
  end

  defp detail_label(text, sk) do
    ~s|<div style="font-size:11px;font-weight:700;color:#{sk.muted};text-transform:uppercase;letter-spacing:.04em;font-family:#{mono()};margin:10px 0 2px">#{text}</div>|
  end

  # ── task-board ───────────────────────────────────────────────────────────────

  @doc "Email-safe kanban: one equal-width cell per NON-EMPTY lifecycle column."
  def task_board_email_html(block, theme \\ :evergreen)

  def task_board_email_html(block, theme) when is_map(block) do
    sk = email_skin(theme)
    rows = block |> get("snapshot") |> as_list()

    case rows do
      [] ->
        empty_email("task-board", "No tasks yet.", theme)

      _ ->
        by_role = Enum.group_by(rows, fn r -> r |> get("status") |> stringish() |> role_of() end)

        present =
          board_roles()
          |> Enum.filter(fn role -> Map.get(by_role, role, []) != [] end)

        case present do
          [] ->
            empty_email("task-board", "No tasks yet.", theme)

          _ ->
            width = max(div(100, length(present)), 1)

            cells =
              present
              |> Enum.map_join("", fn role ->
                board_col_email(role, Map.get(by_role, role, []), width, sk)
              end)

            ~s|<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:separate;border-spacing:6px 0;margin:12px 0"><tr>#{cells}</tr></table>|
        end
    end
  end

  def task_board_email_html(_, theme), do: empty_email("task-board", "No tasks yet.", theme)

  defp board_col_email(role, rows, width, sk) do
    label = role |> StatusVocab.label_for_role() |> String.capitalize()

    cards =
      rows
      |> Enum.map_join("", fn r ->
        title = r |> get("title") |> stringish() |> escape_html()

        meta =
          [priority_label(get(r, "priority")), criteria_frac(get(r, "criteria"))]
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join(" · ", &escape_html/1)

        meta_html =
          if meta == "",
            do: "",
            else:
              ~s|<div style="font-size:11px;color:#{sk.muted};font-family:#{mono()};margin-top:2px">#{meta}</div>|

        ~s|<div style="background:#{sk.paper};border:1px solid #{sk.border};border-radius:5px;padding:6px 8px;margin-top:6px"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse"><tr><td valign="top" width="16" style="color:#{role_color(role, sk)};font-family:#{mono()};font-size:12px">#{glyph_char(role)}</td><td valign="top" style="font-size:12px;color:#{sk.ink};padding-left:5px">#{title}#{meta_html}</td></tr></table></div>|
      end)

    ~s|<td valign="top" width="#{width}%" style="border-top:3px solid #{board_stripe(role, sk)};background:#{sk.ground};border-radius:6px;padding:8px"><div style="font-size:11px;font-family:#{mono()};color:#{sk.muted};text-transform:uppercase;letter-spacing:.03em"><b style="color:#{sk.ink}">#{escape_html(label)}</b> #{length(rows)}</div>#{cards}</td>|
  end

  # ── roadmap ──────────────────────────────────────────────────────────────────

  @doc "Email-safe roadmap: label cell + nested spacer-table percentage bars (no today marker)."
  def roadmap_email_html(block, theme \\ :evergreen)

  def roadmap_email_html(block, theme) when is_map(block) do
    sk = email_skin(theme)
    rows = block |> get("snapshot") |> as_list()

    case rows do
      [] ->
        empty_email("roadmap", "No roadmap items.", theme)

      _ ->
        scale = roadmap_scale(block, sk)

        lanes =
          rows
          |> Enum.map_join("", fn r ->
            role = r |> get("status") |> stringish() |> role_of()
            title = r |> get("title") |> stringish() |> escape_html()
            phase = truthy(get(r, "phase_row"))
            left = r |> get("left") |> clampf()
            width = r |> get("width") |> clampf_width(left)
            remaining = 100 - left - width

            weight = if phase, do: "700", else: "500"

            spacer_left =
              if left > 0,
                do: ~s|<td width="#{left}%" style="font-size:0;line-height:0"></td>|,
                else: ""

            spacer_right =
              if remaining > 0,
                do: ~s|<td width="#{remaining}%" style="font-size:0;line-height:0"></td>|,
                else: ""

            bar =
              ~s|<td width="#{width}%" style="height:8px;background:#{role_color(role, sk)};border-radius:4px;font-size:0;line-height:0">&nbsp;</td>|

            ~s|<tr><td width="34%" valign="middle" style="font-size:12px;font-weight:#{weight};color:#{sk.ink};padding:4px 8px 4px 0">#{title}</td><td valign="middle" style="padding:4px 0"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse;background:#{mix_hex(0.1, sk)};border-radius:4px"><tr>#{spacer_left}#{bar}#{spacer_right}</tr></table></td></tr>|
          end)

        card(
          scale <>
            ~s|<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse">#{lanes}</table>|,
          sk
        )
    end
  end

  def roadmap_email_html(_, theme), do: empty_email("roadmap", "No roadmap items.", theme)

  defp roadmap_scale(block, sk) do
    case block |> get("scale") |> as_list() do
      [] ->
        ""

      cells ->
        n = length(cells)
        w = max(div(100, n), 1)

        tds =
          Enum.map_join(cells, "", fn c ->
            ~s|<td width="#{w}%" style="font-size:10px;color:#{sk.muted};font-family:#{mono()};padding-bottom:4px">#{escape_html(stringish(c))}</td>|
          end)

        ~s|<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse"><tr><td width="34%"></td><td><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse"><tr>#{tds}</tr></table></td></tr></table>|
    end
  end

  # ── momentum header ──────────────────────────────────────────────────────────

  defp momentum_email(rows, sk) do
    total = length(rows)

    if total == 0 do
      ""
    else
      prog = count_role(rows, "progress")
      ready = count_role(rows, "ready")
      done = count_role(rows, "done")
      pct = round(done / total * 100)

      counts =
        ~s|<span style="color:#{role_color("progress", sk)}">#{glyph_char("progress")}</span> <b style="color:#{sk.ink}">#{prog}</b> in flight · | <>
          ~s|<span style="color:#{role_color("ready", sk)}">#{glyph_char("ready")}</span> <b style="color:#{sk.ink}">#{ready}</b> ready · | <>
          ~s|<span style="color:#{role_color("done", sk)}">#{glyph_char("done")}</span> <b style="color:#{sk.ink}">#{done}</b> done · <b style="color:#{sk.ink}">#{pct}%</b>|

      ~s|<div style="font-size:12px;color:#{sk.muted};font-family:#{mono()};margin:2px 0 4px">#{counts}</div>| <>
        momentum_bar(pct, sk)
    end
  end

  # 2-cell filled/track bar — a STATIC accent fill (charter D5: no shimmer). A
  # 0% fill / 100% fill drops the degenerate cell so Outlook never paints a
  # stray sliver.
  defp momentum_bar(pct, sk) do
    fill =
      if pct > 0,
        do:
          ~s|<td width="#{pct}%" style="height:6px;background:#{sk.accent};border-radius:3px;font-size:0;line-height:0">&nbsp;</td>|,
        else: ""

    track =
      if pct < 100,
        do:
          ~s|<td style="height:6px;background:#{sk.border};border-radius:3px;font-size:0;line-height:0">&nbsp;</td>|,
        else: ""

    ~s|<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse;margin-bottom:8px"><tr>#{fill}#{track}</tr></table>|
  end

  # ── phase grouping + rollup ──────────────────────────────────────────────────

  defp group_rows(rows) do
    {order, acc} =
      Enum.reduce(rows, {[], %{}}, fn r, {order, acc} ->
        key = r |> get("phase") |> stringish() |> String.trim() |> nil_if_empty()
        order = if Map.has_key?(acc, key), do: order, else: order ++ [key]
        {order, Map.update(acc, key, [r], fn xs -> xs ++ [r] end)}
      end)

    Enum.map(order, fn k -> {k, Map.fetch!(acc, k)} end)
  end

  defp phase_email(nil, rows, sk), do: Enum.map_join(rows, "", &row_email(&1, sk))

  defp phase_email(name, rows, sk) do
    done = count_role(rows, "done")
    total = length(rows)

    hdr =
      ~s|<tr><td colspan="3" style="padding:10px 0 4px;border-bottom:1px solid #{sk.border};font-family:#{mono()};font-size:11px;color:#{sk.muted};text-transform:uppercase;letter-spacing:.04em"><b style="color:#{sk.ink}">#{escape_html(name)}</b> · #{done}/#{total}</td></tr>|

    hdr <> Enum.map_join(rows, "", &row_email(&1, sk))
  end

  # ── a single task row: glyph-cell + title-cell + right meta-cell ─────────────

  defp row_email(r, sk) do
    role = r |> get("status") |> stringish() |> role_of()
    title = r |> get("title") |> stringish() |> escape_html()

    depth =
      case get(r, "depth") do
        d when is_integer(d) and d > 0 and d < 6 -> d
        _ -> 0
      end

    pad = depth * 16
    arrow = if depth > 0, do: ~s|<span style="color:#{sk.muted}">↳ </span>|, else: ""

    meta = row_meta(r)

    meta_html =
      if meta == "",
        do: "",
        else:
          ~s|<td valign="top" align="right" style="font-size:11px;color:#{sk.muted};font-family:#{mono()};white-space:nowrap;padding:3px 0">#{meta}</td>|

    ~s|<tr><td valign="top" width="18" style="color:#{role_color(role, sk)};font-family:#{mono()};font-size:13px;padding:3px 0">#{glyph_char(role)}</td><td valign="top" style="font-size:13px;color:#{sk.ink};padding:3px 8px 3px #{6 + pad}px">#{arrow}#{title}</td>#{meta_html}</tr>|
  end

  defp row_meta(r) do
    [
      priority_label(get(r, "priority")),
      criteria_frac(get(r, "criteria")),
      blocked_meta(get(r, "blocked_by")),
      worker_meta(get(r, "worker"))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" · ", &escape_html/1)
  end

  # ── the shared vocabulary — DERIVED from design/status-manifest.json ──────────

  defp role_of(status), do: StatusVocab.role_for_status(status)

  # The in_progress spinner degrades to a static glyph (charter D5).
  defp glyph_char(role) do
    if StatusVocab.spinner?(role), do: "⠿", else: StatusVocab.glyph_for_role(role)
  end

  defp glyph_span(role, sk),
    do:
      ~s|<span style="color:#{role_color(role, sk)};font-family:#{mono()};font-size:13px;margin-right:6px">#{glyph_char(role)}</span>|

  # Static role→colour map (charter D2). Lifecycle hues come from the
  # status-manifest tones (light), NOT TokensGen.tone_* (health greens). ready is
  # the ink; researching carries the violet thought-hue (charter D9/D12);
  # open/cancel/considering (and any unknown role) fall to muted.
  defp role_color("done", _sk), do: tone_light("ok")
  defp role_color("progress", _sk), do: tone_light("info")
  defp role_color("blocked", _sk), do: tone_light("warn")
  defp role_color("researching", _sk), do: tone_light("violet")
  defp role_color("ready", sk), do: sk.ink
  defp role_color(_role, sk), do: sk.muted

  # The board column stripe: open/ready read as ink (a full column of backlog is
  # not "muted away"), the worked/blocked/done columns carry their tone.
  defp board_stripe(role, sk) when role in ["open", "ready"], do: sk.ink
  defp board_stripe(role, sk), do: role_color(role, sk)

  defp tone_light(tone), do: StatusVocab.tones() |> Map.fetch!(tone) |> Map.fetch!("light")

  # White-ladder column order, with the two thought states as dim columns at the
  # ladder BOTTOM (charter D12 — thought states ARE visible board columns). Empty
  # columns are dropped, so a board with no considering/researching rows is byte-stable.
  defp board_roles, do: ~w(open ready progress blocked done considering researching)

  # ── meta cells ───────────────────────────────────────────────────────────────

  defp priority_label(p) do
    s = p |> stringish() |> String.trim()

    case String.replace(s, ~r/[^0-9]/, "") do
      "" -> nil
      digits -> "P" <> digits
    end
  end

  defp criteria_frac(%{"met" => m, "total" => t})
       when is_integer(m) and is_integer(t) and t > 0,
       do: "#{m}/#{t}"

  defp criteria_frac(_), do: nil

  defp worker_meta(w) do
    s = w |> stringish() |> String.trim()
    if s == "", do: nil, else: s
  end

  defp blocked_meta(b) do
    s = b |> stringish() |> String.trim()
    if s == "", do: nil, else: "! " <> s
  end

  # ── skin + tint (charter D2 / DataViz email_skin template) ────────────────────

  defp email_skin(theme) do
    s = Palettes.email_skin(theme)

    %{
      ink: s.text,
      muted: s.muted,
      accent: s.brand,
      ground: s.page_bg,
      border: s.rule,
      paper: s.paper,
      accent_rgb: hex_to_rgb(s.brand),
      ground_rgb: hex_to_rgb(s.page_bg)
    }
  end

  # accent mixed over the ground at intensity t (email has no color-mix()) — the
  # faint rail behind a roadmap bar. The RGB tuples come from the resolved skin.
  defp mix_hex(t, sk) do
    {ar, ag, ab} = sk.accent_rgb
    {gr, gg, gb} = sk.ground_rgb
    mix = fn a, g -> round(a * t + g * (1 - t)) end

    "#" <>
      Enum.map_join([mix.(ar, gr), mix.(ag, gg), mix.(ab, gb)], "", fn c ->
        c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
      end)
  end

  defp hex_to_rgb("#" <> <<r::binary-2, g::binary-2, b::binary-2>>),
    do: {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}

  # ── chrome helpers ───────────────────────────────────────────────────────────

  defp card(inner, sk) do
    ~s|<div style="background:#{sk.paper};border:1px solid #{sk.border};border-radius:10px;padding:14px 16px;margin:12px 0">#{inner}</div>|
  end

  defp table_open,
    do:
      ~s|<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse">|

  defp empty_email(kind, message, theme) do
    sk = email_skin(theme)

    ~s|<div style="border:1px dashed #{sk.border};border-radius:10px;padding:10px 13px;color:#{sk.muted};font-family:#{mono()};font-size:12px;margin:12px 0">#{escape_html(kind)} — #{escape_html(message)}</div>|
  end

  defp mono, do: Palettes.font_mono()

  # ── small helpers (Components conventions) ───────────────────────────────────

  defp get(m, k) when is_map(m), do: Map.get(m, k)
  defp get(_, _), do: nil

  defp as_list(l) when is_list(l), do: l
  defp as_list(_), do: []

  defp stringish(s) when is_binary(s), do: s
  defp stringish(n) when is_integer(n), do: Integer.to_string(n)
  defp stringish(_), do: ""

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(1), do: true
  defp truthy(_), do: false

  defp int_or(n, _) when is_integer(n), do: n
  defp int_or(_, d), do: d

  defp count_role(rows, role),
    do: Enum.count(rows, fn r -> r |> get("status") |> stringish() |> role_of() == role end)

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp clampf(n) when is_number(n), do: n |> max(0) |> min(100)
  defp clampf(_), do: 0

  defp clampf_width(n, left) when is_number(n), do: n |> max(1) |> min(100 - left)
  defp clampf_width(_, left), do: max(1, 100 - left)
end
