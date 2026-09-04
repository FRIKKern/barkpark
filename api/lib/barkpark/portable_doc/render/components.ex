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
  alias Barkpark.Chat.ToolRows
  alias Barkpark.Papers.TextDiff
  alias Barkpark.PortableDoc.Render.StatusVocab
  alias Barkpark.PortableDoc.Slots

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

            g = if done, do: glyph_html("done"), else: glyph_html("ready")

            txt =
              c
              |> get("text")
              |> stringish()
              |> then(fn s -> if s == "", do: stringish(get(c, "criterion")), else: s end)
              |> escape_html()

            ev = c |> get("evidence") |> stringish() |> String.trim()

            ev_html =
              if ev == "", do: "", else: ~s|<div class="bp-crit__ev">↳ #{escape_html(ev)}</div>|

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

    if words == "",
      do: "",
      else:
        ~s|<div class="bp-tdetail__lbl">Dependencies</div><div class="bp-tdetail__deps">#{words}</div>|
  end

  defp detail_rail(t, key, label) do
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
          |> Enum.map(fn r ->
            role = r |> get("status") |> stringish() |> role_of()
            title = r |> get("title") |> stringish() |> escape_html()
            ~s|<div class="bp-rail__r">#{glyph_html(role)}<span>#{title}</span></div>|
          end)
          |> Enum.join("")

        more =
          if extra == [],
            do: "",
            else: ~s|<div class="bp-rail__more">… and #{length(extra)} more</div>|

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
          |> Enum.map(fn p ->
            ~s|<div class="bp-rail__r bp-rail__paper">▸ #{escape_html(stringish(p))}</div>|
          end)
          |> Enum.join("")

        more =
          if extra == [],
            do: "",
            else: ~s|<div class="bp-rail__more">… and #{length(extra)} more</div>|

        ~s|<div class="bp-tdetail__lbl">Papers</div><div class="bp-tdetail__rail">#{body}#{more}</div>|
    end
  end

  defp detail_labels(t) do
    labels = t |> get("labels") |> as_list() |> Enum.map(&stringish/1) |> Enum.reject(&(&1 == ""))

    case labels do
      [] ->
        ""

      _ ->
        ~s|<div class="bp-tdetail__labels">#{labels |> Enum.map(&escape_html/1) |> Enum.join(" · ")}</div>|
    end
  end

  @doc """
  Render a `cards` block: a responsive grid of titled cards (title + body, with
  an optional `tone` accent stripe) — the rule-card / feature-card grid.
  `items: [%{title, text, tone}]` where tone ∈ info|ok|warn|danger.
  """
  def cards_html(block) when is_map(block) do
    items = block |> get("items") |> as_list()

    case items do
      [] ->
        ""

      _ ->
        cards =
          items
          |> Enum.map(fn it ->
            title = it |> get("title") |> stringish() |> escape_html()
            text = it |> get("text") |> stringish() |> escape_html()
            tone = it |> get("tone") |> stringish()
            tone_cls = if tone in ~w(info ok warn danger), do: " bp-card--#{tone}", else: ""
            title_html = if title == "", do: "", else: ~s|<div class="bp-card__t">#{title}</div>|
            text_html = if text == "", do: "", else: ~s|<div class="bp-card__d">#{text}</div>|
            ~s|<div class="bp-card#{tone_cls}">#{title_html}#{text_html}</div>|
          end)
          |> Enum.join("")

        ~s|<div class="bp-cards">#{cards}</div>|
    end
  end

  def cards_html(_), do: ""

  @doc """
  Render a `card` block (MODEL B — au-w5-card-slot-parity): ONE card from its slots,
  each slot recursed as ARBITRARY element children through the shared compose→walk
  bridge (`Compose.render_children/2`), the SAME helper terminal/columns/section use.

  Slots render in the ORDER `media, title, body, action`. An `image` media child
  fast-paths to a proper `<img>` (via `compose_block(image)` → `PdImage`); an `action`
  child fast-paths to a button link (`PdButton`); a `heading`/`paragraph` title/body
  child renders as a semantic `<h_>`/`<p>` — no card-specific `bp-card__t/__d/__media/
  __action` chrome anymore (model B drops the text-flatten wrappers). The top-level
  `tone` (legacy card vocab info|ok|warn|danger — the SAME allowlist as `cards_html/1`,
  NOT the callout tone vocab) → the `bp-card--<tone>` modifier is KEPT.

  Empty-card guard: a card whose every slot is absent/empty renders as a blank
  `<div class="bp-card">…</div>` container (no stray chrome).

  BACK-COMPAT: persisted slot children are already typed element blocks, so generic
  recursion renders them directly. DEFENSIVE: a media element persisted as a bare
  `{src, alt}` map with NO `type` key is normalized to `type: "image"` before
  recursion so it fast-paths to an `<img>` instead of the unknown-block degrade.

  `style` defaults to `:article` (the reader/paper surface) so
  `render_block(card, :article)` and a bare `card_html(card)` agree.

  The shared cross-surface PROJECTION is now the full model-B shape
  (`{container_role, slots, tone, media_fastpath}` — au-w5-card-slot-parity GRADUATED,
  all three surfaces conform): the ordered present slots, the tone accent and the
  image media fast-path are asserted by every surface's realization leg.
  """
  def card_html(block, style \\ :article)

  def card_html(block, style) when is_map(block) do
    tone = block |> get("tone") |> stringish()
    tone_cls = if tone in ~w(info ok warn danger), do: " bp-card--#{tone}", else: ""

    inner =
      card_slot_html(block, "media", style) <>
        card_slot_html(block, "title", style) <>
        card_slot_html(block, "body", style) <>
        card_slot_html(block, "action", style)

    ~s|<div class="bp-card#{tone_cls}">#{inner}</div>|
  end

  def card_html(_, _), do: ""

  # Recurse ONE named slot's element children through the shared compose→walk
  # bridge. The `media` slot defensively normalizes a typeless `{src,alt}` element
  # to `type:"image"` so it fast-paths to an <img> rather than degrading. An
  # absent/empty slot yields "".
  defp card_slot_html(block, "media", style) do
    block
    |> Slots.slot_elements("media")
    |> Enum.map(&normalize_media_element/1)
    |> Barkpark.PortableDoc.Render.Compose.render_children(style)
  end

  defp card_slot_html(block, name, style) do
    block
    |> Slots.slot_elements(name)
    |> Barkpark.PortableDoc.Render.Compose.render_children(style)
  end

  # A media element persisted WITHOUT a `type` key (a bare `{src, alt}` map from an
  # older writer) is normalized to an `image` element so generic recursion fast-paths
  # it to an <img> instead of the unknown-block degrade path. A typed element (the
  # persisted norm) and a non-map entry pass through untouched.
  defp normalize_media_element(%{"type" => _} = el), do: el
  defp normalize_media_element(el) when is_map(el), do: Map.put(el, "type", "image")
  defp normalize_media_element(el), do: el

  @doc """
  Render a `pipeline` block: a horizontal flow of labelled nodes joined by
  arrows — `source → emit → gate`. `nodes: [%{kind, title, detail, files,
  source}]`; a `source: true` node gets the accent border. Scrolls on narrow.
  """
  def pipeline_html(block) when is_map(block) do
    nodes = block |> get("nodes") |> as_list()

    case nodes do
      [] ->
        ""

      _ ->
        cells =
          nodes
          |> Enum.map(fn n ->
            k = n |> get("kind") |> stringish() |> escape_html()
            t = n |> get("title") |> stringish() |> escape_html()
            d = n |> get("detail") |> stringish() |> escape_html()
            f = n |> get("files") |> stringish() |> escape_html()
            {src_class, src_html} = pnode_source(n)
            k_html = if k == "", do: "", else: ~s|<div class="bp-pnode__k">#{k}</div>|
            t_html = if t == "", do: "", else: ~s|<div class="bp-pnode__t">#{t}</div>|
            d_html = if d == "", do: "", else: ~s|<div class="bp-pnode__d">#{d}</div>|
            f_html = if f == "", do: "", else: ~s|<div class="bp-pnode__f">#{f}</div>|

            ~s|<div class="bp-pnode#{src_class}">#{k_html}#{t_html}#{d_html}#{f_html}#{src_html}</div>|
          end)
          |> Enum.join(~s|<span class="bp-pipe__arr">→</span>|)

        ~s|<div class="bp-pipe-scroll"><div class="bp-pipe">#{cells}</div></div>|
    end
  end

  def pipeline_html(_), do: ""

  @doc """
  Render a `stage` block (the editable per-node twin of ONE legacy `pipeline` node):
  the IDENTICAL pnode cell a single `pipeline` node emits (`Components.pipeline_html/1`'s
  per-node loop), so a stage carrying the same scalars renders byte-identically. The
  three text fields `kind`/`title`/`detail` read through `Slots.stage_field_text/2`
  (slots OR scalar — both yield the same PLAIN string); `files`/`source` are chrome
  scalars — `source` is coerced through the SAME `pnode_source/1` the pipeline uses
  (boolean `true` → `bp-pnode--src` origin accent; non-empty string → a
  `bp-pnode__src` provenance line; false/absent → nothing). ADDITIVE: the legacy
  `pipeline` clause + `pipeline_html/1` are
  UNTOUCHED — this is a SEPARATE emitter. A stage is ONE cell, so there is no
  `bp-pipe-scroll`/`bp-pipe` wrapper (a `section` of stages composes the flow).
  """
  def stage_html(block) when is_map(block) do
    k = block |> Slots.stage_field_text("kind") |> escape_html()
    t = block |> Slots.stage_field_text("title") |> escape_html()
    d = block |> Slots.stage_field_text("detail") |> escape_html()
    f = block |> get("files") |> stringish() |> escape_html()
    {src_class, src_html} = pnode_source(block)
    k_html = if k == "", do: "", else: ~s|<div class="bp-pnode__k">#{k}</div>|
    t_html = if t == "", do: "", else: ~s|<div class="bp-pnode__t">#{t}</div>|
    d_html = if d == "", do: "", else: ~s|<div class="bp-pnode__d">#{d}</div>|
    f_html = if f == "", do: "", else: ~s|<div class="bp-pnode__f">#{f}</div>|
    ~s|<div class="bp-pnode#{src_class}">#{k_html}#{t_html}#{d_html}#{f_html}#{src_html}</div>|
  end

  def stage_html(_), do: ""

  @doc """
  Render a `notes` block: an annotated list — a short label chip beside a line
  of prose (an optional bold `lead` + `text`). The "what upgraded / why it
  matters" column that rides beside a demo. `items: [%{label, lead, text}]`.
  """
  def notes_html(block) when is_map(block) do
    items = block |> get("items") |> as_list()

    case items do
      [] ->
        ""

      _ ->
        rows = items |> Enum.map(&note_item_html/1) |> Enum.join("")
        ~s|<div class="bp-notes">#{rows}</div>|
    end
  end

  def notes_html(_), do: ""

  @doc """
  Render ONE annotated note ROW — the inner `<div class="bp-note">…` of a `notes`
  grid item, WITHOUT the `bp-notes` grid wrapper. This is the single per-item
  expression lifted VERBATIM from the old `notes_html/1` loop, so `notes_html/1`
  now `Enum.map`s it and stays byte-identical; the NEW singular `note` widget
  (`Compose.compose_block(%{"type" => "note"})`) composes to a lone row of these
  bytes — byte-identical to a single-item `notes` grid MINUS the wrapper.

  Reads the three fields through the `Slots.note_{label,lead,body}_text/1`
  byte-identity accessors, so BOTH a bare legacy `notes` item (`%{label,lead,text}`,
  flat) AND a `note` widget (flat OR slot-materialized) yield the SAME bytes. The
  lead is trim-then-escaped, wrapped in `<b>…</b> ` (a single trailing space) ONLY
  when non-empty; label + body are escaped directly.

  NO `is_map` guard: the `Slots.note_*_text/1` accessors are total (a non-map item
  yields `""` for every field), so a malformed non-map item emits the SAME
  empty-field row the old `notes_html/1` loop did (`get/2` → nil → `""`) — byte-fidelity.
  """
  def note_item_html(item) do
    label = item |> Slots.note_label_text() |> escape_html()
    text = item |> Slots.note_body_text() |> escape_html()
    lead = item |> Slots.note_lead_text() |> String.trim()
    lead_html = if lead == "", do: "", else: ~s|<b>#{escape_html(lead)}</b> |

    ~s|<div class="bp-note"><span class="bp-note__k">#{label}</span><div class="bp-note__d">#{lead_html}#{text}</div></div>|
  end

  @doc """
  Render a `status-legend` block: the shared glyph/colour vocabulary key — the
  six lifecycle states with their glyph and a one-line meaning. Static (the
  vocabulary is the vocabulary); useful atop a plan so a reader learns the marks.
  """
  def status_legend_html(_block) do
    # Name + meaning both derive from the ONE manifest source (StatusVocab); no
    # hand-typed second copy. Row order is the manifest's role order.
    rows =
      StatusVocab.roles()
      |> Enum.map(fn role ->
        name = role |> StatusVocab.label_for_role() |> escape_html()
        meaning = StatusVocab.meaning_for_role(role)

        ~s|<div class="bp-legend__r">#{glyph_html(role)}<span class="bp-legend__n">#{name}</span><span class="bp-legend__d">#{meaning}</span></div>|
      end)
      |> Enum.join("")

    ~s|<div class="bp-legend">#{rows}</div>|
  end

  @doc """
  Render a `task-board` block: a kanban of the snapshot, one column per
  lifecycle bucket (open · ready · in_progress · blocked · done), each card
  carrying title · priority · criteria. Empty columns are omitted.

  The `open` column mirrors the web reader's white-ladder column set
  (`web/lib/task-board-columns.ts`) so a populated `open` bucket is NEVER
  silently dropped — the omit-empty layout used to have no `open` column at all,
  so `open` tasks vanished from the Studio/View board (bug-taskboard-drops-open-tasks).
  """
  def task_board_html(block) when is_map(block) do
    rows = block |> get("snapshot") |> as_list()

    case rows do
      [] ->
        ~s|<div class="bp-tasks bp-tasks--empty">No tasks yet.</div>|

      _ ->
        by_role = Enum.group_by(rows, fn r -> r |> get("status") |> stringish() |> role_of() end)

        cols =
          board_roles()
          |> Enum.map(fn role ->
            board_col(role, board_label(role), Map.get(by_role, role, []))
          end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("")

        ~s|<div class="bp-board">#{cols}</div>|
    end
  end

  def task_board_html(_), do: ""

  # The board's column roles, in white-ladder order (cancel folds to a tally, so
  # it is NOT a column). One place defines the order; labels are DERIVED, never a
  # second hardcoded copy. The two thought states are dim columns at the ladder
  # BOTTOM (charter D12 — thought states ARE visible board columns); empty columns
  # are dropped, so a board with no considering/researching rows is byte-stable.
  defp board_roles, do: ~w(open ready progress blocked done considering researching)

  # A board column header: the canonical lowercase label sentence-cased at render
  # (the fold — "in progress" → "In progress"), NOT a hand-typed board label.
  defp board_label(role), do: role |> StatusVocab.label_for_role() |> String.capitalize()

  defp board_col(_role, _label, []), do: ""

  defp board_col(role, label, rows) do
    cards =
      rows
      |> Enum.map(fn r ->
        title = r |> get("title") |> stringish() |> escape_html()

        meta =
          [priority_html(get(r, "priority")), criteria_html(get(r, "criteria"))] |> Enum.join("")

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
            n when is_number(n) ->
              ~s|<span class="bp-rm__today" style="left:#{clampf(n)}%"></span>|

            _ ->
              ""
          end

        scale =
          case block |> get("scale") |> as_list() do
            [] ->
              ""

            cells ->
              ~s|<div class="bp-rm__scale">#{cells |> Enum.map(fn c -> ~s|<span>#{escape_html(stringish(c))}</span>| end) |> Enum.join("")}</div>|
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

  # ═══ Chat tool / todo / thinking rows (charter D25 — dual-surface Law 1) ══════
  #
  # The three highest-frequency non-text chat rows become FIRST-CLASS PortableDoc
  # block types — `chat-tool-diff`, `chat-todo`, `chat-thinking` — so they render
  # through the SAME compose_block path the assistant reply body already uses (D8)
  # on BOTH surfaces. The GUI/reader leg is these `_raw` emitters (`compose_block`
  # :article delegates here); the Go TUI leg (`internal/chat`) decodes the IDENTICAL
  # typed block map. This closes the Law-1 parallel-render fork: no more bespoke
  # inline `ChatToolRenderer.tool_diff/todo_card` HEEx in `chat_live.ex`.
  #
  # The pure derivations are REUSED verbatim — NO new diff/parse engine is invented:
  # `Barkpark.Papers.TextDiff.diff_lines/2` (the ONE line diff), `ChatToolRenderer.
  # classify/1` (shape dispatch), `ChatToolRenderer.parse_todos/1` +
  # `ChatToolRenderer.todo_glyph/1` (the living checklist), and the "thought for ~N
  # tokens" count label. Output stays byte-faithful to today's `chat_tool_renderer.ex`.
  #
  # Each block carries its DERIVED, surface-neutral render data (diff `lines`,
  # `todos`, `tokens`) so the Go half renders the same rows WITHOUT re-running the
  # diff (the "one diff engine" law holds across surfaces); the block-build/render
  # split mirrors the reply body's markdown→blocks derivation (D8).

  # Lines shown before a chat diff collapses behind a details/summary — matches
  # `ChatToolRenderer`'s @collapsed_budget so the two surfaces fold at the same row.
  @chat_diff_budget 20

  @doc """
  Build a `chat-tool-diff` block from a raw tool-call `input` map. The derived
  `lines` (string-keyed `%{"op","text"}`) come from `TextDiff.diff_lines/2` via
  the shared shape dispatch — the SAME derivation the GUI renderer re-runs, so
  the fixture freshness lock (`lines == derive(input)`) keeps both surfaces true.
  Returns `nil` for a non-diff shape (the generic tool row stands on its own).
  """
  @spec chat_tool_diff_block(map() | any()) :: map() | nil
  def chat_tool_diff_block(input) do
    case chat_diff_line_maps(input) do
      [] ->
        nil

      lines ->
        %{
          "type" => "chat-tool-diff",
          "input" => input,
          "lines" => lines,
          "added" => Enum.count(lines, &(&1["op"] == "+")),
          "removed" => Enum.count(lines, &(&1["op"] == "-"))
        }
    end
  end

  @doc """
  Build a `chat-todo` block from an ALREADY-parsed todo list
  (`ChatToolRenderer.parse_todos/1` output — `%{content, status, active_form}`).
  The `chat_live` path already parses; the controller/generator parse first via
  `chat_todo_block_from_input/1`.
  """
  @spec chat_todo_block([map()]) :: map()
  def chat_todo_block(todos) when is_list(todos) do
    %{"type" => "chat-todo", "todos" => Enum.map(todos, &todo_to_json/1)}
  end

  def chat_todo_block(_), do: %{"type" => "chat-todo", "todos" => []}

  @doc "Build a `chat-todo` block straight from a raw TodoWrite `input` map."
  @spec chat_todo_block_from_input(map() | any()) :: map()
  def chat_todo_block_from_input(input), do: chat_todo_block(ToolRows.parse_todos(input))

  @doc """
  Build a `chat-thinking` block from a cumulative thinking-token count (charter
  D41). The wire never carries thinking TEXT — only the count — so the block is a
  single integer both surfaces render as "thought for ~N tokens".
  """
  @spec chat_thinking_block(integer() | any()) :: map()
  def chat_thinking_block(tokens) when is_integer(tokens) and tokens >= 0 do
    %{"type" => "chat-thinking", "tokens" => tokens}
  end

  def chat_thinking_block(_), do: %{"type" => "chat-thinking", "tokens" => 0}

  # ═══ Chat approval / question / plan cards (charter D35 — the INTERACTIVE rows) ═
  #
  # approval/question/plan are the three INTERACTIVE chat rows. Unlike the inert
  # tool/todo/thinking blocks above, their ANSWERABILITY (the Studio answer forms,
  # the TUI focus ring + ctrl+a/ctrl+r) is driven by the message ENVELOPE
  # (role + request_id + approval_status), NEVER by the block. The block carries
  # only the read-time VISUAL, synthesized from the SAME metadata the Recorder
  # persists (`persist_approval_ask`: request_id, tool_name, input, approval_status)
  # — NO persist change, NO migration. `message_json` emits BOTH the envelope and
  # this block, so a naive inert copy that answered off the block would render a
  # DEAD card; the answer path stays on the message (D35).

  @doc """
  Build a `chat-approval` block from a persisted approval row's metadata
  (`%{"tool_name","input","approval_status"}`). Read-time synthesis: the card
  names the tool, previews the ask in one line (the Recorder's `tool_line`
  vocabulary), and carries the terminal status so a read-only replay is honest.
  """
  @spec chat_approval_block(map() | any()) :: map()
  def chat_approval_block(meta) when is_map(meta) do
    %{
      "type" => "chat-approval",
      "tool_name" => chat_tool_name(Map.get(meta, "tool_name")),
      "summary" => chat_ask_summary(Map.get(meta, "tool_name"), Map.get(meta, "input")),
      "approval_status" => chat_approval_status(Map.get(meta, "approval_status"))
    }
  end

  def chat_approval_block(_), do: chat_approval_block(%{})

  @doc """
  Build a `chat-question` block from an AskUserQuestion row's metadata. Each
  question carries its prompt + option labels — the read-time visual of the
  question card. The answer FORM stays envelope-driven (D35).
  """
  @spec chat_question_block(map() | any()) :: map()
  def chat_question_block(meta) when is_map(meta) do
    %{
      "type" => "chat-question",
      "questions" => chat_questions(Map.get(meta, "input")),
      "approval_status" => chat_approval_status(Map.get(meta, "approval_status"))
    }
  end

  def chat_question_block(_), do: chat_question_block(%{})

  @doc """
  Build a `chat-plan` block from an ExitPlanMode row's metadata. The title is the
  plan's first heading (charter D34), the preview a clamped plain-text lede — the
  read-only visual of the proposed plan. Approve / Keep planning stays on the
  envelope (D35); the full plan replays in the interactive card / published Paper.
  """
  @spec chat_plan_block(map() | any()) :: map()
  def chat_plan_block(meta) when is_map(meta) do
    plan = chat_plan_markdown(Map.get(meta, "input"))

    %{
      "type" => "chat-plan",
      "title" => chat_plan_title(plan),
      "preview" => chat_plan_preview(plan),
      "approval_status" => chat_approval_status(Map.get(meta, "approval_status"))
    }
  end

  def chat_plan_block(_), do: chat_plan_block(%{})

  @doc """
  Render a `chat-tool-diff` block: the terminal-style `+`/`−` line diff beneath a
  tool call (dispatch on input SHAPE, never tool name — `ChatToolRenderer`). A
  diff over `@chat_diff_budget` DRAWABLE lines (gaps never spend budget — D40)
  folds behind a `<details>` with an honest `+N more lines` counting drawable
  rows only. Re-derives from `block["input"]` via the ONE `TextDiff` engine,
  so it is byte-faithful to `ChatToolRenderer.tool_diff/1`. Evergreen tokens only.
  """
  def chat_tool_diff_html(block) when is_map(block) do
    case chat_diff_line_maps(Map.get(block, "input")) do
      [] ->
        ""

      lines ->
        added = Enum.count(lines, &(&1["op"] == "+"))
        removed = Enum.count(lines, &(&1["op"] == "-"))
        drawable = Enum.count(lines, &(&1["op"] != "gap"))
        {head, rest} = chat_diff_budget_split(lines)

        counts =
          ~s|<div class="text-dim" style="font-size: 11px; margin-bottom: 4px;">| <>
            ~s|<span style="color: var(--ok);">+#{added}</span> | <>
            ~s|<span style="color: var(--danger);">−#{removed}</span></div>|

        body =
          if drawable > @chat_diff_budget do
            overflow = drawable - @chat_diff_budget

            ~s|<details><summary style="cursor: pointer; list-style: none;">| <>
              chat_diff_rows_html(head) <>
              ~s|<div class="text-dim" style="font-size: 11px; padding: 1px 0;">… +#{overflow} more lines</div>| <>
              ~s|</summary>#{chat_diff_rows_html(rest)}</details>|
          else
            chat_diff_rows_html(head)
          end

        ~s|<div class="bp-chat-tool-diff text-xs" style="font-family: var(--font-mono); margin: 4px 0 0 16px; background: var(--muted-surface); border-radius: 6px; padding: 6px 8px; overflow-x: auto; line-height: 1.5;">| <>
          counts <> body <> ~s|</div>|
    end
  end

  def chat_tool_diff_html(_), do: ""

  # ═══ Code-story blocks — `diff` + `filetree` (charter W7, D75–D78/D85) ════════
  #
  # The two authored code-story blocks born in W7. Unlike chat-tool-diff (which
  # DERIVES lines from a tool-call input via TextDiff), `diff` carries ONE
  # verbatim unified-diff text field parsed at render time on every surface
  # (D75) — the front-end differs, the ROW back-end is SHARED (D76): the rows
  # render through the same private chat_diff_rows_html/chat_row_style/
  # chat_prefix vocabulary and fold at the same @chat_diff_budget. Style-invariant
  # single clauses like chat-tool-diff — the inline-token mono rendering reads
  # identically in email.

  @doc """
  Render a `diff` block: a verbatim unified diff (`diff` attr) parsed into the
  shared chat diff-row vocabulary (D76). Per D77: `@@` hunk headers render as dim
  context rows VERBATIM (their `-l,s +l,s` numbers are load-bearing); `diff
  --git`/`index`/`---` header lines never count as +/- rows; each `+++`
  transition emits a bold path sub-header (multi-file diffs get one per file
  section). Optional `file`/`lang` metadata lead the +N −M tally row. Over
  `@chat_diff_budget` rows the tail folds behind a `<details>` (same fold as
  chat-tool-diff).
  """
  def diff_html(block) when is_map(block) do
    rows = block |> Map.get("diff", "") |> stringish() |> diff_rows()
    added = Enum.count(rows, &(&1["op"] == "+"))
    removed = Enum.count(rows, &(&1["op"] == "-"))
    {head, rest} = Enum.split(rows, @chat_diff_budget)

    file = stringish(Map.get(block, "file", ""))
    lang = stringish(Map.get(block, "lang", ""))

    lead =
      [
        if(file == "",
          do: "",
          else: ~s|<span style="font-weight: 600;">#{escape_html(file)}</span>|
        ),
        if(lang == "", do: "", else: escape_html(lang))
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" · ")

    lead_html = if lead == "", do: "", else: lead <> " · "

    counts =
      ~s|<div class="text-dim" style="font-size: 12px; margin-bottom: 4px;">| <>
        lead_html <>
        ~s|<span style="color: var(--ok);">+#{added}</span> | <>
        ~s|<span style="color: var(--danger);">−#{removed}</span></div>|

    body =
      if length(rows) > @chat_diff_budget do
        overflow = length(rows) - @chat_diff_budget

        ~s|<details><summary style="cursor: pointer; list-style: none;">| <>
          diff_section_rows_html(head) <>
          ~s|<div class="text-dim" style="font-size: 12px; padding: 1px 0;">… +#{overflow} more lines</div>| <>
          ~s|</summary>#{diff_section_rows_html(rest)}</details>|
      else
        diff_section_rows_html(head)
      end

    ~s|<div class="bp-diff text-xs" style="font-family: var(--font-mono); margin: 4px var(--bp-evidence-pull, 0px); width: var(--bp-evidence-width, 100%); box-sizing: border-box; background: var(--muted-surface); border-radius: 6px; padding: 6px 8px; overflow-x: auto; line-height: 1.5;">| <>
      counts <> body <> ~s|</div>|
  end

  def diff_html(_), do: ""

  @doc """
  Render a `filetree` block: verbatim tree lines (`text` attr — box glyphs +
  indentation preserved via `white-space: pre`), each line's trailing annotation
  split on the first ` ● `/` ○ `/` ✕ ` marker into a colored annotation span
  (D78). An optional `legend` string attr renders a dim legend row beneath the
  tree — the block self-describes its glyphs. Degrades to plain preformatted
  text when no marker matches.
  """
  def filetree_html(block) when is_map(block) do
    rows =
      block
      |> Map.get("text", "")
      |> stringish()
      |> split_verbatim_lines()
      |> Enum.map_join("", &filetree_row_html/1)

    legend = stringish(Map.get(block, "legend", ""))

    legend_html =
      if legend == "",
        do: "",
        else:
          ~s|<div class="bp-filetree-legend text-dim" style="font-size: 12px; margin-top: 4px;">#{escape_html(legend)}</div>|

    ~s|<div class="bp-filetree text-xs" style="font-family: var(--font-mono); margin: 4px var(--bp-evidence-pull, 0px); width: var(--bp-evidence-width, 100%); box-sizing: border-box; background: var(--muted-surface); border-radius: 6px; padding: 6px 8px; overflow-x: auto; line-height: 1.5;">| <>
      rows <> legend_html <> ~s|</div>|
  end

  def filetree_html(_), do: ""

  # ── diff/filetree private parse helpers (the verbatim-text front-end, D76) ────

  # Verbatim text → display rows. Row maps share the chat vocabulary
  # (%{"op","text"} with op in "+"/"-"/""), plus the diff-only "file" op the
  # bold path sub-header renders (D77). Never a second diff engine — this is a
  # line CLASSIFIER over author-provided text, not a diff derivation.
  defp diff_rows(text) do
    text
    |> split_verbatim_lines()
    |> Enum.flat_map(&diff_line_row/1)
  end

  # Order matters: "+++ "/"--- " match before the bare "+"/"-" ops.
  defp diff_line_row("+++ " <> path), do: [%{"op" => "file", "text" => strip_b_prefix(path)}]
  defp diff_line_row("--- " <> _), do: []
  defp diff_line_row("diff --git " <> _), do: []
  defp diff_line_row("index " <> _), do: []
  defp diff_line_row("@@" <> _ = line), do: [%{"op" => "", "text" => line}]
  defp diff_line_row("+" <> rest), do: [%{"op" => "+", "text" => rest}]
  defp diff_line_row("-" <> rest), do: [%{"op" => "-", "text" => rest}]
  defp diff_line_row(" " <> rest), do: [%{"op" => "", "text" => rest}]
  defp diff_line_row(line), do: [%{"op" => "", "text" => line}]

  defp strip_b_prefix("b/" <> rest), do: rest
  defp strip_b_prefix(path), do: path

  # Rows render through the SHARED chat row back-end (D76); only the diff-only
  # bold path sub-header is emitted here.
  defp diff_section_rows_html(rows) do
    Enum.map_join(rows, "", fn
      %{"op" => "file", "text" => path} ->
        ~s|<div style="font-weight: 600; margin: 4px 0 1px; white-space: pre-wrap; overflow-wrap: anywhere;">#{escape_html(path)}</div>|

      row ->
        chat_diff_rows_html([row])
    end)
  end

  # split on "\n", drop a single trailing empty line; "" → [] — the same
  # semantics as chat.ts splitLines, so both surfaces see identical line lists.
  defp split_verbatim_lines(""), do: []

  defp split_verbatim_lines(text) do
    lines = String.split(text, "\n")
    if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
  end

  # The D78 annotation markers with their evergreen token colors. The glyph is
  # the semantic carrier; color is never load-bearing (the legend row
  # disambiguates locally).
  @filetree_markers [
    {" ● ", "var(--ok)"},
    {" ○ ", "var(--paper-ink-soft)"},
    {" ✕ ", "var(--danger)"}
  ]

  defp filetree_row_html(line) do
    case split_filetree_note(line) do
      {path, nil} ->
        ~s|<div style="white-space: pre;">#{escape_html(path)}</div>|

      {path, {glyph, note, color}} ->
        ~s|<div style="white-space: pre;">#{escape_html(path)}| <>
          ~s|<span class="bp-filetree-note" style="color: #{color};">#{escape_html(glyph <> note)}</span></div>|
    end
  end

  # First marker occurrence (scanning left-to-right across all three) splits the
  # line into the verbatim path part and the annotation (glyph + trailing text).
  defp split_filetree_note(line) do
    @filetree_markers
    |> Enum.flat_map(fn {glyph, color} ->
      case :binary.match(line, glyph) do
        :nomatch -> []
        {idx, _len} -> [{idx, glyph, color}]
      end
    end)
    |> Enum.sort()
    |> case do
      [] ->
        {line, nil}

      [{idx, glyph, color} | _] ->
        path = binary_part(line, 0, idx)
        rest_start = idx + byte_size(glyph)
        rest = binary_part(line, rest_start, byte_size(line) - rest_start)
        {path, {glyph, rest, color}}
    end
  end

  @doc """
  Render a `chat-todo` block: the living checklist card (charter D39) — one
  ☐/◐/☒ row per item with an honest `N/M done` progress read. An empty list
  still renders the header + a "no items" line, never a blank box. Reuses
  `ChatToolRenderer.todo_glyph/1`.
  """
  def chat_todo_html(block) when is_map(block) do
    todos = block |> Map.get("todos") |> as_list()

    progress =
      if todos == [],
        do: "",
        else: ~s| <span style="opacity: 0.6;"> · #{todo_progress(todos)}</span>|

    header =
      ~s|<div class="text-xs" style="overflow-wrap: anywhere;">| <>
        ~s|<span style="color: var(--primary);">●</span> <span>Update todos</span>#{progress}</div>|

    items =
      if todos == [] do
        ~s|<div class="text-xs text-dim" style="padding-left: 16px;">⎿ no items</div>|
      else
        rows = todos |> Enum.map(&chat_todo_item_html/1) |> Enum.join("")

        ~s|<ul style="list-style: none; margin: 4px 0 0; padding: 0 0 0 16px; display: flex; flex-direction: column; gap: 2px;">#{rows}</ul>|
      end

    ~s|<div class="bp-chat-todo" style="font-family: var(--font-mono);">#{header}#{items}</div>|
  end

  def chat_todo_html(_), do: ""

  @doc """
  Render a `chat-thinking` block: the dim mono `✻ thought for ~N tokens` row
  (charter D41) — no thinking text ever, identical live and on replay.
  """
  def chat_thinking_html(block) when is_map(block) do
    tokens = Map.get(block, "tokens")

    label =
      if is_integer(tokens), do: "thought for ~#{tokens} tokens", else: "thought"

    ~s|<div class="bp-chat-thinking text-xs text-dim" style="font-family: var(--font-mono);">| <>
      ~s|<span aria-hidden="true">✻</span> #{escape_html(label)}</div>|
  end

  def chat_thinking_html(_), do: ""

  @doc """
  Render a `chat-approval` block: the read-only VISUAL of a permission ask — the
  tool name, a one-line preview, and the status badge. The ANSWER affordance is
  NEVER here (envelope-driven, D35); this is what a replay / reader shows and the
  body the TUI card wraps with its interactive shell.
  """
  def chat_approval_html(block) when is_map(block) do
    tool = Map.get(block, "tool_name", "tool")
    summary = Map.get(block, "summary", "")
    status = chat_approval_status(Map.get(block, "approval_status", "pending"))
    title = if status == "pending", do: "Allow #{tool}?", else: tool

    ~s|<div class="bp-chat-approval text-xs" style="font-family: var(--font-mono);">| <>
      chat_card_header(title, status) <>
      chat_card_body(summary) <>
      ~s|</div>|
  end

  def chat_approval_html(_), do: ""

  @doc """
  Render a `chat-question` block: the read-only VISUAL of an AskUserQuestion —
  each prompt with its option chips. The answer FORM is envelope-driven (D35).
  An empty question set still renders an honest "no question" line, never blank.
  """
  def chat_question_html(block) when is_map(block) do
    questions = block |> Map.get("questions") |> as_list()
    status = chat_approval_status(Map.get(block, "approval_status", "pending"))

    body =
      if questions == [] do
        ~s|<div class="text-dim" style="padding-left: 12px;">⎿ no question</div>|
      else
        questions |> Enum.map(&chat_question_item_html/1) |> Enum.join("")
      end

    ~s|<div class="bp-chat-question text-xs" style="font-family: var(--font-mono);">| <>
      chat_card_header("Question", status) <>
      body <>
      ~s|</div>|
  end

  def chat_question_html(_), do: ""

  @doc """
  Render a `chat-plan` block: the read-only VISUAL of a proposed plan — the first
  heading as a title and a clamped lede. Approve / Keep planning is envelope-driven
  (D35); the full plan replays in the interactive card / the published Paper.
  """
  def chat_plan_html(block) when is_map(block) do
    title = Map.get(block, "title", "Proposed plan")
    preview = Map.get(block, "preview", "")
    status = chat_approval_status(Map.get(block, "approval_status", "pending"))

    ~s|<div class="bp-chat-plan text-xs" style="font-family: var(--font-mono);">| <>
      chat_card_header(title, status) <>
      chat_card_body(preview) <>
      ~s|</div>|
  end

  def chat_plan_html(_), do: ""

  # ── chat card internals (approval / question / plan visual — D35) ────────────

  # The shared header row: a bold title and a right-aligned status word. The
  # status is the honest read-only state a replay shows (the interactive answer
  # layer lives on the envelope, not here).
  #
  # INVARIANT: `status` arrives ALREADY folded through `chat_approval_status/1`.
  # Every caller (chat_approval_html/1, chat_question_html/1, chat_plan_html/1)
  # folds it, and that fold is the SINGLE guard — deliberately not doubled here
  # or inside `chat_status_label/1`, so removing any one caller's fold is a
  # mutation the block tests actually catch instead of one a second layer hides.
  #
  # NO INLINE `white-space: nowrap`. It used to sit on this span, and being
  # INLINE it beat every paper-surface.css rule — a long status word forced one
  # unbreakable line and gave the whole reader page horizontal scroll at a
  # 390px viewport. `overflow-wrap: anywhere` is the guard a shrink-to-fit box
  # needs (only `anywhere` reduces the intrinsic width the box is sized from);
  # `min-width: 0` lets the flex item shrink below its content size at all.
  defp chat_card_header(title, status) do
    ~s|<div style="display: flex; gap: 6px; align-items: baseline;">| <>
      ~s|<span style="font-weight: 600; min-width: 0; overflow-wrap: anywhere;">| <>
      ~s|#{escape_html(title)}</span>| <>
      ~s|<span class="text-dim" style="margin-left: auto; min-width: 0; overflow-wrap: anywhere;">| <>
      ~s|#{escape_html(chat_status_label(status))}</span></div>|
  end

  # The one-line ask/plan preview beneath the header; blank text renders nothing
  # (the header alone stands) rather than an empty box.
  defp chat_card_body(text) do
    case String.trim(to_string(text)) do
      "" ->
        ""

      trimmed ->
        ~s|<div style="opacity: 0.85; overflow-wrap: anywhere; margin-top: 2px;">| <>
          ~s|#{escape_html(trimmed)}</div>|
    end
  end

  # One question row: the prompt over its option chips (labels only — the visual,
  # not the interactive form).
  defp chat_question_item_html(q) do
    question = Map.get(q, "question", "")
    options = q |> Map.get("options") |> as_list()

    chips =
      if options == [] do
        ""
      else
        rendered =
          Enum.map_join(options, "", fn opt ->
            ~s|<span style="display: inline-block; padding: 0 6px; margin: 2px 4px 0 0; | <>
              ~s|border: 1px solid var(--border-muted); border-radius: 4px;">| <>
              ~s|#{escape_html(to_string(opt))}</span>|
          end)

        ~s|<div style="margin: 2px 0 0 12px;">#{rendered}</div>|
      end

    ~s|<div style="margin-top: 4px;"><div style="overflow-wrap: anywhere;">| <>
      ~s|#{escape_html(to_string(question))}</div>#{chips}</div>|
  end

  # The card status words — pending, or a terminal decision glyph. Reused by all
  # three interactive cards (the block's own read-only badge; the TUI footer's
  # interactive badge is a SEPARATE envelope-driven layer in internal/chat).
  defp chat_status_label("pending"), do: "pending"
  defp chat_status_label("allowed"), do: "✓ allowed"
  defp chat_status_label("denied"), do: "⊘ denied"
  defp chat_status_label("canceled"), do: "— canceled"
  defp chat_status_label(other), do: to_string(other)

  # The tool name for an ask, defaulting to a generic "tool" when the row carries
  # none (a legacy/malformed frame) so the card header never reads "Allow ?".
  defp chat_tool_name(name) when is_binary(name) and name != "", do: name
  defp chat_tool_name(_), do: "tool"

  # The approval lifecycle, folded to the known vocabulary — pending until a
  # terminal decision (allowed | denied | canceled). Anything unrecognized reads
  # pending (fail-open to "still awaiting you", never a fake resolution).
  defp chat_approval_status(s) when s in ["pending", "allowed", "denied", "canceled"], do: s
  defp chat_approval_status(_), do: "pending"

  # A one-line preview of an approval ask — the tool plus a diff-shaped file path
  # or a compact k:v preview, mirroring the Recorder's `tool_line`. Keys are
  # sorted so the preview is deterministic across a regenerate (the fixture lock).
  defp chat_ask_summary(name, input) when is_map(input) do
    tool = chat_tool_name(name)

    if is_binary(input["file_path"]) do
      "#{tool} — #{input["file_path"]}"
    else
      preview =
        input
        |> Enum.filter(fn {_k, v} -> is_binary(v) end)
        |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
        |> Enum.take(2)
        |> Enum.map_join(" · ", fn {k, v} -> "#{k}: #{String.slice(v, 0, 80)}" end)

      if preview == "", do: tool, else: "#{tool} — #{preview}"
    end
  end

  defp chat_ask_summary(name, _), do: chat_tool_name(name)

  # Normalize the AskUserQuestion input into render-ready questions (prompt +
  # option labels). Mirrors chat_live's `parse_questions`, string-keyed for JSON.
  defp chat_questions(%{"questions" => qs}) when is_list(qs) do
    Enum.map(qs, fn q ->
      %{
        "question" => to_string(Map.get(q, "question", "")),
        "options" => chat_question_options(Map.get(q, "options"))
      }
    end)
  end

  defp chat_questions(_), do: []

  defp chat_question_options(opts) when is_list(opts) do
    opts
    |> Enum.map(fn
      %{"label" => label} -> to_string(label)
      label when is_binary(label) -> label
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp chat_question_options(_), do: []

  # The ExitPlanMode plan markdown (`%{"plan" => md}`), or "" when absent.
  defp chat_plan_markdown(%{"plan" => plan}) when is_binary(plan), do: plan
  defp chat_plan_markdown(_), do: ""

  # The plan title: the first markdown heading's text, else "Proposed plan"
  # (mirrors chat_live's `plan_title` without booting the paper engine).
  defp chat_plan_title(plan) when is_binary(plan) do
    plan
    |> String.split("\n")
    |> Enum.find_value("Proposed plan", fn line ->
      case Regex.run(~r/^\s*#+\s+(\S.*?)\s*$/, line) do
        [_, heading] -> heading
        _ -> nil
      end
    end)
  end

  defp chat_plan_title(_), do: "Proposed plan"

  # A clamped plain-text lede: the plan's non-heading prose, joined and clipped so
  # the card reads compact. The clip is stored on the block so the fixture's
  # projection text and the render agree exactly (word-safe: a hard char clip).
  defp chat_plan_preview(plan) when is_binary(plan) do
    plan
    |> String.split("\n")
    |> Enum.reject(&(String.match?(&1, ~r/^\s*#/) or String.trim(&1) == ""))
    |> Enum.join(" ")
    |> String.trim()
    |> chat_clip(200)
  end

  defp chat_plan_preview(_), do: ""

  defp chat_clip(text, max) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "…"
  end

  # ── chat toolrow internals (derivations REUSED, never reinvented) ───────────

  # The flat diff-line list for a tool input, keyed the SAME way as
  # `ChatToolRenderer` but string-keyed for JSON. `TextDiff.diff_lines/2` is the
  # ONE line engine; `ChatToolRenderer.classify/1` is the ONE shape dispatch.
  defp chat_diff_line_maps(input) do
    case ToolRows.classify(input) do
      :edit ->
        input |> Map.get("old_string") |> chat_diff(Map.get(input, "new_string"))

      :write ->
        chat_diff("", Map.get(input, "content"))

      :multi_edit ->
        chat_multi_edit_lines(Map.get(input, "edits"))

      :generic ->
        []
    end
  end

  defp chat_diff(old_text, new_text) do
    old_text
    |> TextDiff.diff_lines(new_text)
    |> Enum.map(fn %{op: op, text: text} -> %{"op" => op, "text" => text} end)
  end

  # Stack each edit's hunk, separated by a faint gap row — mirrors
  # `ChatToolRenderer.multi_edit_lines/1`. Defensive: a malformed edit yields no
  # hunk rather than raising.
  defp chat_multi_edit_lines(edits) when is_list(edits) do
    edits
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn e -> chat_diff(Map.get(e, "old_string"), Map.get(e, "new_string")) end)
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([%{"op" => "gap", "text" => ""}])
    |> List.flatten()
  end

  defp chat_multi_edit_lines(_), do: []

  # Split the diff after the budget-th DRAWABLE row (charter D40): a `gap` hunk
  # separator never spends budget — it rides free in the head — and never stays
  # in the summary once the budget is spent (a gap at or past the fold belongs to
  # the `<details>` tail it separates). The overflow footnote counts undisplayed
  # DRAWABLE rows only; the web surface keeps the folded tail behind `<details>`
  # — parity with the terminal/mobile discard is the budget arithmetic, never
  # the DOM. Mirrors chat_blocks.go / mobile chat.tsx / react chat.ts.
  defp chat_diff_budget_split(lines) do
    {head, rest, _drawn} =
      Enum.reduce(lines, {[], [], 0}, fn line, {head, rest, drawn} ->
        if drawn < @chat_diff_budget do
          {[line | head], rest, drawn + if(line["op"] == "gap", do: 0, else: 1)}
        else
          {head, [line | rest], drawn}
        end
      end)

    {Enum.reverse(head), Enum.reverse(rest)}
  end

  defp chat_diff_rows_html(lines) do
    Enum.map_join(lines, "", fn %{"op" => op, "text" => text} ->
      ~s|<div style="#{chat_row_style(op)}">#{chat_prefix(op)}#{escape_html(text)}</div>|
    end)
  end

  defp chat_row_style("+"),
    do:
      "color: var(--ok); background: var(--ok-soft); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;"

  defp chat_row_style("-"),
    do:
      "color: var(--danger); background: var(--danger-soft); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;"

  defp chat_row_style("gap"),
    do: "border-top: 1px solid var(--border-muted); margin: 4px 0; height: 0;"

  defp chat_row_style(_),
    do: "color: var(--fg-dim); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;"

  defp chat_prefix("+"), do: "+ "
  defp chat_prefix("-"), do: "- "
  defp chat_prefix("gap"), do: ""
  defp chat_prefix(_), do: "&nbsp;&nbsp;"

  # A parsed todo (atom-keyed) → JSON-safe string-keyed map. `status` is one of
  # "pending" | "in_progress" | "completed"; `active_form` is null when absent.
  defp todo_to_json(%{content: content, status: status} = todo) do
    %{
      "content" => to_string(content),
      "status" => Atom.to_string(status),
      "active_form" => Map.get(todo, :active_form)
    }
  end

  defp todo_to_json(todo) when is_map(todo) do
    %{
      "content" => to_string(Map.get(todo, "content", "")),
      "status" => to_string(Map.get(todo, "status", "pending")),
      "active_form" => Map.get(todo, "active_form")
    }
  end

  defp chat_todo_item_html(todo) do
    status = Map.get(todo, "status", "pending")
    content = Map.get(todo, "content", "")
    active_form = Map.get(todo, "active_form")

    glyph = ToolRows.todo_glyph(chat_todo_status_atom(status))

    active_html =
      if status == "in_progress" and is_binary(active_form) and active_form != "" do
        ~s|<div class="text-dim" style="padding-left: 20px; opacity: 0.75;">→ #{escape_html(active_form)}</div>|
      else
        ""
      end

    ~s|<li class="text-xs"><div style="display: flex; gap: 6px; align-items: baseline;">| <>
      ~s|<span aria-hidden="true" style="#{chat_todo_glyph_style(status)}">#{glyph}</span>| <>
      ~s|<span style="#{chat_todo_text_style(status)}">#{escape_html(content)}</span></div>#{active_html}</li>|
  end

  defp chat_todo_status_atom("completed"), do: :completed
  defp chat_todo_status_atom("in_progress"), do: :in_progress
  defp chat_todo_status_atom(_), do: :pending

  defp chat_todo_glyph_style("completed"), do: "flex: none; color: var(--ok);"
  defp chat_todo_glyph_style("in_progress"), do: "flex: none; color: var(--primary);"
  defp chat_todo_glyph_style(_), do: "flex: none; opacity: 0.6;"

  defp chat_todo_text_style("completed"),
    do: "overflow-wrap: anywhere; opacity: 0.6; text-decoration: line-through;"

  defp chat_todo_text_style("in_progress"),
    do: "overflow-wrap: anywhere; color: var(--primary); font-weight: 600;"

  defp chat_todo_text_style(_), do: "overflow-wrap: anywhere;"

  # "1/3 done" — the compact honest progress read; in-progress is not "done".
  defp todo_progress(todos) do
    done = Enum.count(todos, &(Map.get(&1, "status") == "completed"))
    "#{done}/#{length(todos)} done"
  end

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
        ~s|<span class="bp-momentum__i bp-g--ready">#{glyph_char("ready")} <b>#{ready}</b> ready</span>| <>
        ~s|<span class="bp-momentum__i bp-g--done">#{glyph_char("done")} <b>#{done}</b> done</span>| <>
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

  # ── the shared vocabulary — DERIVED from design/status-manifest.json ─────────
  # via Render.StatusVocab (compile-time). There is no second copy of the
  # status→role or role→glyph map here to drift; edit the manifest, not this.

  defp role_of(status), do: StatusVocab.role_for_status(status)

  defp glyph_html(role) do
    if StatusVocab.spinner?(role) do
      # a spinner role is an empty span whose ::before CSS-animates the Braille frames
      ~s|<span class="bp-g bp-g--#{role}" aria-label="#{StatusVocab.label_for_role(role)}"></span>|
    else
      ~s|<span class="bp-g bp-g--#{role}">#{glyph_char(role)}</span>|
    end
  end

  defp glyph_char(role), do: StatusVocab.glyph_for_role(role)

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

  # A pnode's `source` coercion (RATIFIED): boolean `true` → an ORIGIN accent (the
  # `bp-pnode--src` border, existing origin signal); a non-empty STRING → a
  # provenance LINE rendering the text (`bp-pnode__src`); `false`/absent/"" →
  # nothing. accent and provenance are MUTUALLY EXCLUSIVE (one field, coerced by
  # type). The pipeline per-node loop AND stage_html BOTH read through this, so a
  # stage carrying the same scalars byte-matches one legacy pipeline node.
  # NOTE: distinct from `truthy/1` — that conflated `true` and a non-empty string
  # (both → accent, the string text SWALLOWED); this distinguishes them.
  defp pnode_source(node) do
    case get(node, "source") do
      true ->
        {" bp-pnode--src", ""}

      s when is_binary(s) and s != "" ->
        {"", ~s|<div class="bp-pnode__src">#{escape_html(s)}</div>|}

      _ ->
        {"", ""}
    end
  end

  defp int_or(n, _) when is_integer(n), do: n
  defp int_or(_, d), do: d

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
