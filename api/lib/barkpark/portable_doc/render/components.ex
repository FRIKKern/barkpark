defmodule Barkpark.PortableDoc.Render.Components do
  @moduledoc """
  Task-tracking PortableDoc components — the `_raw` HTML emitters for the
  Barkpark task design language (see `.claude/workflows/bp-task-design-language-spec.md`).

  Pure, snapshot-driven leaf emitters in the `Figures` family: a block carries a
  resolved `snapshot` (a list of row maps) and this module renders it to a byte
  string that `compose_block` wraps as `%{"kind" => "_raw", "html" => …}` and
  `Walk` passes through verbatim. No DB, no plugin — works offline / plugin-off.

  ## The shared status vocabulary (identical to the `bp tasks` TUI)

      state          glyph   role      colour
      open           ○       neutral   foreground @ 50% opacity (backlog)
      ready          ○       ok        foreground / full (unchecked, claim it)
      in_progress    ⠋…⠏     info      blue, CSS Braille spinner (worked now)
      blocked        !       warn      amber (something is required)
      done           ✓       done      teal (blinks ×3 on complete, live only)
      cancelled      ✕       neutral   dim

  Every author string is `escape_html`'d; there is no inline colour from author
  data, so no `safe_color` is needed here — status drives the CSS class only.
  """

  import Barkpark.PortableDoc.Render.Util, only: [escape_html: 1]

  @doc """
  Render a `tasks` block's snapshot as the upgraded task list: an optional
  momentum header, phase groups with rollups, and rows carrying the status
  glyph, title, priority, criteria, worker and blocker.
  """
  def tasks_html(block) when is_map(block) do
    rows = block |> get("snapshot") |> as_list()

    case rows do
      [] ->
        ~s|<div class="bp-tasks bp-tasks--empty">No tasks yet.</div>|

      _ ->
        title = block |> get("title") |> stringish() |> String.trim()

        title_html =
          if title == "",
            do: "",
            else: ~s|<div class="bp-tasks__title">#{escape_html(title)}</div>|

        body =
          rows
          |> group_rows()
          |> Enum.map(fn {phase, rs} -> phase_html(phase, rs) end)
          |> Enum.join("")

        ~s|<div class="bp-tasks">| <>
          title_html <>
          momentum_html(rows) <>
          ~s|<div class="bp-tasks__list">#{body}</div></div>|
    end
  end

  def tasks_html(_), do: ""

  @doc """
  Render a `task-detail` block: the "open a task and SEE it" card — a vertical
  stack of CONDITIONAL sections (a thin task stays thin), matching the design
  spec §15: title · meta line · timestamps · status timeline · criteria
  checklist with evidence · dependencies in words · children rail · papers rail
  · labels. The task map is at `block["task"]` (or the block itself).
  """
  def task_detail_html(block) when is_map(block) do
    t = case get(block, "task") do m when is_map(m) -> m; _ -> block end
    title = t |> get("title") |> stringish() |> String.trim()

    case title do
      "" ->
        ""

      _ ->
        role = t |> get("status") |> stringish() |> role_of()

        sections =
          [
            detail_meta(t, role),
            detail_stamp(t),
            detail_timeline(t),
            detail_desc(t),
            detail_criteria(t),
            detail_deps(t),
            detail_rail(t, "children", "Children"),
            detail_papers(t),
            detail_labels(t)
          ]
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("")

        ~s|<div class="bp-tdetail"><div class="bp-tdetail__title">#{escape_html(title)}</div>#{sections}</div>|
    end
  end

  def task_detail_html(_), do: ""

  defp detail_meta(t, role) do
    parts =
      [
        t |> get("status") |> stringish() |> nil_if_empty(),
        priority_label(get(t, "priority")),
        t |> get("kind") |> stringish() |> nil_if_empty(),
        t |> get("worker") |> stringish() |> nil_if_empty()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&escape_html/1)
      |> Enum.join(" · ")

    ~s|<div class="bp-tdetail__meta">#{glyph_html(role)}<span>#{parts}</span></div>|
  end

  defp detail_stamp(t) do
    c = t |> get("created") |> stringish() |> String.trim()
    u = t |> get("updated") |> stringish() |> String.trim()

    line =
      [c != "" && "created #{escape_html(c)}", u != "" && "updated #{escape_html(u)}"]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    if line == "", do: "", else: ~s|<div class="bp-tdetail__stamp">#{line}</div>|
  end

  defp detail_timeline(t) do
    segs = t |> get("timeline") |> as_list()

    case segs do
      [] ->
        ""

      _ ->
        cells =
          segs
          |> Enum.map(fn s ->
            r = s |> get("status") |> stringish() |> role_of()
            lbl = s |> get("label") |> stringish() |> escape_html()
            ~s|<span class="bp-tl__seg">#{glyph_html(r)}<span>#{lbl}</span></span>|
          end)
          |> Enum.join(~s|<span class="bp-tl__arr">→</span>|)

        ~s|<div class="bp-tdetail__timeline">#{cells}</div>|
    end
  end

  defp detail_desc(t) do
    d = t |> get("description") |> stringish() |> String.trim()
    if d == "", do: "", else: ~s|<div class="bp-tdetail__desc">#{escape_html(d)}</div>|
  end

  defp detail_criteria(t) do
    items = t |> get("criteria") |> as_list()

    case items do
      [] ->
        ""

      _ ->
        met = Enum.count(items, fn c -> truthy(get(c, "met")) end)
        total = length(items)

        rows =
          items
          |> Enum.map(fn c ->
            done = truthy(get(c, "met"))
            g = if done, do: ~s|<span class="bp-g bp-g--done">✓</span>|, else: ~s|<span class="bp-g bp-g--ready">○</span>|
            txt = c |> get("text") |> stringish() |> then(fn s -> if s == "", do: stringish(get(c, "criterion")), else: s end) |> escape_html()
            ev = c |> get("evidence") |> stringish() |> String.trim()
            ev_html = if ev == "", do: "", else: ~s|<div class="bp-crit__ev">↳ #{escape_html(ev)}</div>|
            cls = if done, do: " bp-crit--met", else: ""
            ~s|<div class="bp-crit#{cls}">#{g}<span class="bp-crit__t">#{txt}</span></div>#{ev_html}|
          end)
          |> Enum.join("")

        ~s|<div class="bp-tdetail__lbl">Criteria · #{met}/#{total}</div><div class="bp-tdetail__crit">#{rows}</div>|
    end
  end

  defp detail_deps(t) do
    blocks = int_or(get(t, "blocks"), 0)
    blocked = int_or(get(t, "blocked_by"), 0)

    words =
      [
        blocks > 0 && "blocks #{blocks} #{plural(blocks, "task")}",
        blocked > 0 && "blocked by #{blocked}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    if words == "", do: "", else: ~s|<div class="bp-tdetail__lbl">Dependencies</div><div class="bp-tdetail__deps">#{words}</div>|
  end

  defp detail_rail(t, key, label) do
    rows = t |> get(key) |> as_list()

    case rows do
      [] ->
        ""

      _ ->
        {shown, extra} = Enum.split(rows, 20)
        done = Enum.count(rows, fn r -> r |> get("status") |> stringish() |> role_of() == "done" end)

        body =
          shown
          |> Enum.map(fn r ->
            role = r |> get("status") |> stringish() |> role_of()
            title = r |> get("title") |> stringish() |> escape_html()
            ~s|<div class="bp-rail__r">#{glyph_html(role)}<span>#{title}</span></div>|
          end)
          |> Enum.join("")

        more = if extra == [], do: "", else: ~s|<div class="bp-rail__more">… and #{length(extra)} more</div>|
        ~s|<div class="bp-tdetail__lbl">#{label} · #{done}/#{length(rows)} done</div><div class="bp-tdetail__rail">#{body}#{more}</div>|
    end
  end

  defp detail_papers(t) do
    rows = t |> get("papers") |> as_list()

    case rows do
      [] ->
        ""

      _ ->
        {shown, extra} = Enum.split(rows, 10)

        body =
          shown
          |> Enum.map(fn p -> ~s|<div class="bp-rail__r bp-rail__paper">▸ #{escape_html(stringish(p))}</div>| end)
          |> Enum.join("")

        more = if extra == [], do: "", else: ~s|<div class="bp-rail__more">… and #{length(extra)} more</div>|
        ~s|<div class="bp-tdetail__lbl">Papers</div><div class="bp-tdetail__rail">#{body}#{more}</div>|
    end
  end

  defp detail_labels(t) do
    labels = t |> get("labels") |> as_list() |> Enum.map(&stringish/1) |> Enum.reject(&(&1 == ""))

    case labels do
      [] -> ""
      _ -> ~s|<div class="bp-tdetail__labels">#{labels |> Enum.map(&escape_html/1) |> Enum.join(" · ")}</div>|
    end
  end

  @doc """
  Render a `task-board` block: a kanban of the snapshot, one column per
  lifecycle bucket (ready · in_progress · blocked · done), each card carrying
  title · priority · criteria. Empty columns are omitted.
  """
  def task_board_html(block) when is_map(block) do
    rows = block |> get("snapshot") |> as_list()

    case rows do
      [] ->
        ~s|<div class="bp-tasks bp-tasks--empty">No tasks yet.</div>|

      _ ->
        by_role = Enum.group_by(rows, fn r -> r |> get("status") |> stringish() |> role_of() end)

        cols =
          [{"ready", "Ready"}, {"progress", "In progress"}, {"blocked", "Blocked"}, {"done", "Done"}]
          |> Enum.map(fn {role, label} -> board_col(role, label, Map.get(by_role, role, [])) end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("")

        ~s|<div class="bp-board">#{cols}</div>|
    end
  end

  def task_board_html(_), do: ""

  defp board_col(_role, _label, []), do: ""

  defp board_col(role, label, rows) do
    cards =
      rows
      |> Enum.map(fn r ->
        title = r |> get("title") |> stringish() |> escape_html()
        meta = [priority_html(get(r, "priority")), criteria_html(get(r, "criteria"))] |> Enum.join("")
        meta_html = if meta == "", do: "", else: ~s|<div class="bp-bcard__m">#{meta}</div>|
        ~s|<div class="bp-bcard">#{glyph_html(role)}<span class="bp-bcard__t">#{title}</span>#{meta_html}</div>|
      end)
      |> Enum.join("")

    ~s|<div class="bp-board__col bp-board__col--#{role}"><div class="bp-board__head"><span class="bp-board__label">#{label}</span><span class="bp-board__count">#{length(rows)}</span></div><div class="bp-board__cards">#{cards}</div></div>|
  end

  @doc """
  Render a `roadmap` block: phase/task bars on a timeline. Author-driven —
  the task domain has no due dates, so each row carries an explicit
  `left`/`width` percentage (0–100). Bars are coloured by status; an optional
  `today` percentage draws the now-marker; `scale` labels the axis.
  """
  def roadmap_html(block) when is_map(block) do
    rows = block |> get("snapshot") |> as_list()

    case rows do
      [] ->
        ~s|<div class="bp-tasks bp-tasks--empty">No roadmap items.</div>|

      _ ->
        today =
          case get(block, "today") do
            n when is_number(n) -> ~s|<span class="bp-rm__today" style="left:#{clampf(n)}%"></span>|
            _ -> ""
          end

        scale =
          case block |> get("scale") |> as_list() do
            [] -> ""
            cells -> ~s|<div class="bp-rm__scale">#{cells |> Enum.map(fn c -> ~s|<span>#{escape_html(stringish(c))}</span>| end) |> Enum.join("")}</div>|
          end

        lanes =
          rows
          |> Enum.map(fn r ->
            role = r |> get("status") |> stringish() |> role_of()
            title = r |> get("title") |> stringish() |> escape_html()
            phase = truthy(get(r, "phase_row"))
            left = r |> get("left") |> clampf()
            width = r |> get("width") |> clampf_width(left)
            cls = if phase, do: "bp-rm__lane bp-rm__lane--phase", else: "bp-rm__lane"
            ~s|<div class="#{cls}"><span class="bp-rm__lbl">#{title}</span><div class="bp-rm__track"><span class="bp-rm__bar bp-rm__bar--#{role}" style="left:#{left}%;width:#{width}%"></span>#{today}</div></div>|
          end)
          |> Enum.join("")

        ~s|<div class="bp-roadmap">#{scale}<div class="bp-rm__lanes">#{lanes}</div></div>|
    end
  end

  def roadmap_html(_), do: ""

  defp clampf(n) when is_number(n), do: n |> max(0) |> min(100)
  defp clampf(_), do: 0

  defp clampf_width(n, left) when is_number(n), do: n |> max(1) |> min(100 - left)
  defp clampf_width(_, left), do: max(1, 100 - left)

  # ── momentum header — the "always feel progress" read ───────────────────────

  defp momentum_html(rows) do
    total = length(rows)

    if total == 0 do
      ""
    else
      prog = count_role(rows, "progress")
      ready = count_role(rows, "ready")
      done = count_role(rows, "done")
      pct = round(done / total * 100)

      ~s|<div class="bp-momentum"><div class="bp-momentum__row">| <>
        ~s|<span class="bp-momentum__i">#{glyph_html("progress")}<b>#{prog}</b> in flight</span>| <>
        ~s|<span class="bp-momentum__i bp-g--ready">○ <b>#{ready}</b> ready</span>| <>
        ~s|<span class="bp-momentum__i bp-g--done">✓ <b>#{done}</b> done</span>| <>
        ~s|<span class="bp-momentum__grow"></span>| <>
        ~s|<span class="bp-momentum__pct">#{pct}%</span></div>| <>
        ~s|<div class="bp-momentum__track"><span class="bp-momentum__fill" style="width:#{pct}%"></span></div></div>|
    end
  end

  # ── phase grouping + rollup ─────────────────────────────────────────────────

  # Group rows by their "phase" label, preserving first-seen order; a nil phase
  # (rows with no phase) renders as a flat run with no header.
  defp group_rows(rows) do
    {order, acc} =
      Enum.reduce(rows, {[], %{}}, fn r, {order, acc} ->
        key = r |> get("phase") |> stringish() |> String.trim() |> nil_if_empty()
        order = if Map.has_key?(acc, key), do: order, else: order ++ [key]
        {order, Map.update(acc, key, [r], fn xs -> xs ++ [r] end)}
      end)

    Enum.map(order, fn k -> {k, Map.fetch!(acc, k)} end)
  end

  defp phase_html(nil, rows), do: rows |> Enum.map(&row_html/1) |> Enum.join("")

  defp phase_html(name, rows) do
    done = count_role(rows, "done")
    total = length(rows)

    hdr =
      ~s|<div class="bp-phase"><span class="bp-phase__nm">#{escape_html(name)}</span>| <>
        ~s|<span class="bp-phase__rule"></span>| <>
        ~s|<span class="bp-phase__n">#{done}/#{total}</span></div>|

    hdr <> (rows |> Enum.map(&row_html/1) |> Enum.join(""))
  end

  # ── a single row ────────────────────────────────────────────────────────────

  defp row_html(r) do
    role = r |> get("status") |> stringish() |> role_of()
    title = r |> get("title") |> stringish() |> escape_html()

    depth =
      case get(r, "depth") do
        d when is_integer(d) and d > 0 and d < 6 -> d
        _ -> 0
      end

    pad = 14 + depth * 18
    arrow = if depth > 0, do: ~s|<span class="bp-trow__arr">↳</span>|, else: ""

    meta =
      [
        priority_html(get(r, "priority")),
        criteria_html(get(r, "criteria")),
        blocked_html(get(r, "blocked_by")),
        worker_html(get(r, "worker"))
      ]
      |> Enum.join("")

    meta_html = if meta == "", do: "", else: ~s|<span class="bp-trow__m">#{meta}</span>|

    ~s|<div class="bp-trow bp-trow--#{role}" style="padding-left:#{pad}px">| <>
      arrow <>
      glyph_html(role) <>
      ~s|<span class="bp-trow__t">#{title}</span>| <>
      meta_html <>
      ~s|</div>|
  end

  # ── the shared vocabulary ───────────────────────────────────────────────────

  defp role_of("in_progress"), do: "progress"
  defp role_of("blocked"), do: "blocked"
  defp role_of("done"), do: "done"
  defp role_of("closed"), do: "done"
  defp role_of("cancelled"), do: "cancel"
  defp role_of("ready"), do: "ready"
  defp role_of(_), do: "open"

  # in_progress is an empty span whose ::before CSS-animates the Braille spinner
  defp glyph_html("progress"),
    do: ~s|<span class="bp-g bp-g--progress" aria-label="in progress"></span>|

  defp glyph_html(role),
    do: ~s|<span class="bp-g bp-g--#{role}">#{glyph_char(role)}</span>|

  defp glyph_char("ready"), do: "○"
  defp glyph_char("blocked"), do: "!"
  defp glyph_char("done"), do: "✓"
  defp glyph_char("cancel"), do: "✕"
  defp glyph_char(_), do: "○"

  # ── meta cells ──────────────────────────────────────────────────────────────

  defp priority_html(p) do
    s = p |> stringish() |> String.trim()

    if s == "" do
      ""
    else
      digits = String.replace(s, ~r/[^0-9]/, "")
      label = if digits == "", do: "P?", else: "P" <> digits
      ~s|<span class="bp-trow__p" data-p="#{digits}">#{label}</span>|
    end
  end

  defp criteria_html(%{"met" => m, "total" => t})
       when is_integer(m) and is_integer(t) and t > 0,
       do: ~s|<span class="bp-trow__cn">#{m}/#{t}</span>|

  defp criteria_html(_), do: ""

  defp worker_html(w) do
    s = w |> stringish() |> String.trim()
    if s == "", do: "", else: ~s|<span class="bp-trow__w">#{escape_html(s)}</span>|
  end

  defp blocked_html(b) do
    s = b |> stringish() |> String.trim()
    if s == "", do: "", else: ~s|<span class="bp-trow__blk">! #{escape_html(s)}</span>|
  end

  # ── tiny helpers ────────────────────────────────────────────────────────────

  defp count_role(rows, role),
    do: Enum.count(rows, fn r -> r |> get("status") |> stringish() |> role_of() == role end)

  defp get(m, k) when is_map(m), do: Map.get(m, k)
  defp get(_, _), do: nil

  defp as_list(l) when is_list(l), do: l
  defp as_list(_), do: []

  defp stringish(s) when is_binary(s), do: s
  defp stringish(n) when is_integer(n), do: Integer.to_string(n)
  defp stringish(_), do: ""

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s

  # "1"/"p1"/1 -> "P1"; blank -> nil (so it drops from a " · "-joined meta line)
  defp priority_label(p) do
    s = p |> stringish() |> String.trim()

    case String.replace(s, ~r/[^0-9]/, "") do
      "" -> nil
      digits -> "P" <> digits
    end
  end

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(1), do: true
  defp truthy(_), do: false

  defp int_or(n, _) when is_integer(n), do: n
  defp int_or(_, d), do: d

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
