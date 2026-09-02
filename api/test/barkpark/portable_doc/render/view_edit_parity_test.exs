defmodule Barkpark.PortableDoc.Render.ViewEditParityTest do
  @moduledoc """
  View↔Edit render-path parity — the drift TRIPWIRE (pd-doctrine rule 3,
  charter au-w5-paper-parity-w3 / D6).

  The paper editor has two rendered surfaces that MUST look identical when a
  user toggles between them on the same document:

    * VIEW  — `Barkpark.PortableDoc.Render` in `:article` mode emits BARE
      semantic HTML (`<h1>`, `<p>`, `<ul>`, `<li>`, `<code>` …). Its typography
      is owned entirely by the `.bp-paper-surface <el>` element rules that live
      in the ONE canonical stylesheet (`Render.Stylesheet.css/0`, compiled from
      `assets/paper-surface/paper-surface.css`). This surface backs both the
      public `/papers/:slug` reader AND the Studio View pane.

    * EDIT  — the Studio canvas emits the SAME semantic tags through ProseMirror
      inside `.bp-paper-editor-body`; its typography is the
      `.bp-paper-editor-body <el>` rules in `root.html.heex`.

  Parity today is "by construction": BOTH surfaces resolve the SAME `--bp-*`
  typography tokens (single-sourced in `paper-surface.css`), and the article
  renderer emits bare tags so the view side has NO competing inline style. The
  ONLY residual drift surface is *cross-file*: a property could be changed on
  `.bp-paper-surface <el>` (in the CSS source) without the matching change to
  `.bp-paper-editor-body <el>` (in `root.html.heex`), or vice-versa.

  These tests make that drift IMPOSSIBLE TO SHIP: they parse the two real
  sources and assert every shared (element, property) pair carries a
  byte-identical value. This is the machine-checkable one-producer property the
  pd-doctrine M3 spine (t8 fleet-in-canvas, t10 parity gate) is built on — a
  full canvas⇄reader diff extends the same parser.

  This file guards the PROSE typography surface (headings/paragraph/list/…). Its
  sibling `canvas_reader_parity_gate_test.exs` (t10) guards the NON-PROSE FLEET
  surface — asserting the canvas paints every fleet block (tasks/board/roadmap/
  cards/pipeline/notes/legend/detail/form/figures + sheet/embed chip-carry)
  through the ONE reader producer, `Render.render_block(block, %{style: :article})`,
  and that the canvas node-view JS hand-mirrors no fleet markup. Together they are
  the pd-doctrine rule-3 tripwire pair.

  Intentional, documented divergences (View-only list bottom-margin) are
  encoded as guarded invariants below, so ADDING them to Edit trips the wire and
  forces a conscious decision rather than silent double-spacing.

  §2/§5/§6 compare PRODUCER-EXHAUSTIVELY (`nil` included), so a ONE-SIDED ADD —
  a property added to the producer that the mirror simply lacks — reds. Before
  pe-w1-parity-gate-one-sided-adds those sections filtered on
  `Map.has_key?(mirror, prop)`, and a mutation adding
  `font-size: var(--bp-body-size)` to `.bp-paper-surface p` with no editor twin
  shipped GREEN through all 1156 portable_doc tests. Deliberate asymmetries now
  live in `@documented_divergences`, one reason each, with a rot guard that
  fails if an entry stops describing a real difference.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Stylesheet

  # The block elements that both surfaces style and that must stay in lock-step.
  # (`ul`/`ol` are handled separately — they carry an intentional divergence.)
  # The three `.bp-table*` CLASS tokens ride here too (editable-table): the canvas
  # table node-view carries the reader's own `.bp-table` / `.bp-table__th` /
  # `.bp-table__td` classes, and `declarations_for/3` accepts a class selector as the
  # `element` (targeting ".bp-paper-surface .bp-table__th" vs ".bp-paper-editor-body
  # .bp-table__th"), so a drift between the reader rule and the edit mirror trips §2.
  # `.bp-stats` / `.bp-chart` / `.bp-cols` complete the reader's EVIDENCE-BAND
  # BREAKOUT set (.bp-table is the fourth): all four step out of the prose column via
  # `margin-inline: var(--bp-evidence-pull)` + `width: var(--bp-evidence-width)`,
  # so an unmirrored change to their geometry desyncs canvas from reader.
  # Red-before (mutation-proven 2026-08-17, pe-w2-parity-widening): with the gate
  # widened, `padding: 4px` added to `.bp-paper-surface .bp-stats` with no editor
  # twin reds §2 (".bp-stats.padding: View=\"4px\" Edit=nil"); before the widening
  # the same mutation shipped GREEN through the whole portable_doc tree.
  # `a` + `a:focus-visible` (paper-links wave): the LINK AFFORDANCE. Before this
  # wave the reader rule was `text-decoration: none` + a `--paper-accent-soft`
  # border-bottom that computed to 1.14–1.35:1 over the reading ground, and the
  # editor surfaces declared NO `a` rule at all — the widest kind of View↔Edit
  # asymmetry this gate exists to catch, and it shipped green because `a` was
  # not on the wire. Red-before (mutation-proven, paper-links): changing
  # `text-underline-offset` to `0.19em` on `.bp-paper-surface a` alone reds §2
  # ("a.text-underline-offset: View=\"0.19em\" Edit=\"0.18em\"").
  @parity_elements ~w(h1 h2 h3 p li code img a a:focus-visible .bp-table .bp-table__th .bp-table__td .bp-stats .bp-chart .bp-cols)

  @root_heex Path.expand(
               "../../../../lib/barkpark_web/layouts/root.html.heex",
               __DIR__
             )

  # The bundle's standalone stylesheet — the THIRD copy of the editor
  # typography. Studio never loads it (`BP_PAPER_EDITOR_NO_INJECT`); embedders
  # load ONLY it. Its `.bp-paper-editor-body` element rules are a hand-kept
  # mirror of root.html.heex's ("keep byte-aligned" comments both sides), so
  # they are the same cross-file drift surface — §5 puts them on the wire too.
  @bundle_css Path.expand(
                "../../../../assets/paper-editor/src/styles.css",
                __DIR__
              )

  # ── CSS micro-parser ───────────────────────────────────────────────────────
  # Scans a stylesheet for every LEAF rule block (`selector { decls }` whose
  # declaration body has no nested braces — i.e. not an `@media` wrapper) and
  # accumulates declarations per element for one surface class. Comma-grouped
  # selectors (e.g. the shared `h1,h2,…,h6` heading rule) are split and folded
  # into each element, so a property declared on the group counts for every
  # heading. Later declarations win, matching CSS source-order cascade.
  defp declarations_for(css, surface_class, element) do
    target = ".#{surface_class} #{element}"

    ~r/([^{}]+)\{([^{}]*)\}/
    |> Regex.scan(css)
    |> Enum.reduce(%{}, fn [_, selectors, body], acc ->
      selectors
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.any?(&(&1 == target))
      |> if do
        Map.merge(acc, parse_decls(body))
      else
        acc
      end
    end)
  end

  defp parse_decls(body) do
    body
    |> String.split(";")
    |> Enum.reduce(%{}, fn decl, acc ->
      case String.split(decl, ":", parts: 2) do
        [prop, value] ->
          prop = prop |> String.trim() |> normalize_ws()
          value = value |> String.trim() |> normalize_ws()
          if prop == "", do: acc, else: Map.put(acc, prop, value)

        _ ->
          acc
      end
    end)
  end

  # Collapse internal runs of whitespace so `var(--x);  letter-spacing` style
  # double-spaces and single-spaces compare equal.
  defp normalize_ws(s), do: String.replace(s, ~r/\s+/, " ")

  defp view_css, do: strip_comments(Stylesheet.css())
  defp edit_css, do: strip_comments(File.read!(@root_heex))
  defp bundle_css, do: strip_comments(File.read!(@bundle_css))

  # Drop `/* … */` comments so a comment's prose (which contains commas and the
  # word ".bp-paper-surface" in explanations) can't leak into the greedy
  # selector capture and defeat the exact selector match.
  defp strip_comments(css), do: String.replace(css, ~r|/\*.*?\*/|s, "")

  # ── 1. VIEW emits bare, single-source-styled semantic HTML ─────────────────
  # If the article renderer ever re-introduced an inline `style=` on a prose
  # element, that element would stop tracking the shared `--bp-*` tokens and
  # View↔Edit could silently drift. Freeze the bare-emit contract.

  test "article headings emit bare <hN> with no inline style" do
    for level <- [1, 2, 3] do
      html =
        Render.render_block(%{"type" => "heading", "level" => level, "text" => "X"}, %{
          style: :article
        })

      assert html =~ ~r/^<h#{level}>/,
             "heading level #{level} must open a bare <h#{level}>, got: #{html}"

      refute html =~ ~r/<h#{level}[^>]*\sstyle=/,
             "heading level #{level} must carry NO inline style, got: #{html}"
    end
  end

  test "article paragraph emits a bare <p> with no inline style" do
    html = Render.render_block(%{"type" => "paragraph", "text" => "hello"}, %{style: :article})
    assert html =~ ~r/^<p>/
    refute html =~ ~r/<p[^>]*\sstyle=/
  end

  test "article list emits bare <ul>/<li> with no inline style" do
    html =
      Render.render_block(
        %{"type" => "list", "ordered" => false, "items" => ["a", "b"]},
        %{style: :article}
      )

    assert html =~ ~r/^<ul>/
    refute html =~ ~r/<ul[^>]*\sstyle=/
    refute html =~ ~r/<li[^>]*\sstyle=/
  end

  # ── Documented-divergence allowlist ────────────────────────────────────────
  # §2/§5/§6 below compare PRODUCER-EXHAUSTIVELY (§7's shape): every
  # (property, value) the producer declares must appear byte-identical on the
  # mirror, `nil` INCLUDED — so a one-sided ADD (a property the mirror simply
  # lacks) reds instead of being filtered out of the comparison. Before this,
  # those sections filtered on `Map.has_key?(mirror, prop)`, which meant adding
  # e.g. `font-size: var(--bp-body-size)` to `.bp-paper-surface p` with no
  # editor twin shipped GREEN through all 1156 portable_doc tests
  # (mutation-proven 2026-08-12, pe-w1-parity-gate-one-sided-adds).
  #
  # A DELIBERATE asymmetry therefore has to be declared here, keyed by
  # `{section, element, property}`, each with a one-line reason. The map is the
  # complete list of things this file knowingly lets diverge — anything not in
  # it must match. Sections:
  #
  #   :view_edit    — §2, `.bp-paper-surface <el>` (paper-surface.css)
  #                        ↔ `.bp-paper-editor-body <el>` (root.html.heex)
  #   :studio_bundle — §5, root.html.heex ↔ assets/paper-editor/src/styles.css
  #   :view_bundle   — §6, paper-surface.css callout tones ↔ styles.css mirror
  #
  # Mirror-ONLY properties (the mirror declares what the producer does not) stay
  # unchecked in every section — the mirrors legitimately carry standalone-host
  # extras, and this wave scopes the gate to producer-side adds.
  # Verified 2026-08-12 against paper-surface.css / root.html.heex /
  # assets/paper-editor/src/styles.css — each entry states WHY the mirror may
  # stay silent. All four §2 entries share one mechanism (§4's single-producer
  # note): the Studio canvas mounts in LIGHT DOM inside
  # `<main class="bp-paper-shell bp-paper-surface">` with `Stylesheet.css/0`
  # inlined on the same page, so the View rule itself paints the canvas and the
  # editor rule only redeclares what it must.
  @documented_divergences %{
    {:view_edit, "h1", "color"} =>
      "headings inherit the View group rule in Studio (light-DOM canvas) and the bundle's `.bp-paper-editor-body { color: var(--paper-ink) }` wrapper standalone",
    {:view_edit, "h2", "color"} =>
      "headings inherit the View group rule in Studio (light-DOM canvas) and the bundle's `.bp-paper-editor-body { color: var(--paper-ink) }` wrapper standalone",
    {:view_edit, "h3", "color"} =>
      "headings inherit the View group rule in Studio (light-DOM canvas) and the bundle's `.bp-paper-editor-body { color: var(--paper-ink) }` wrapper standalone",
    {:view_edit, "h1", "font-family"} =>
      "same inheritance as heading `color` — the bundle wrapper sets `font-family: var(--paper-font-serif)`, so no editor surface needs a per-heading copy",
    {:view_edit, "h2", "font-family"} =>
      "same inheritance as heading `color` — the bundle wrapper sets `font-family: var(--paper-font-serif)`, so no editor surface needs a per-heading copy",
    {:view_edit, "h3", "font-family"} =>
      "same inheritance as heading `color` — the bundle wrapper sets `font-family: var(--paper-font-serif)`, so no editor surface needs a per-heading copy"
    # `max-width` is GONE from the View rule as of pe-w1-evidence-breakout, so its
    # entry is gone too — the rot guard below fails an allowlist that outlives the
    # asymmetry it describes. It was `100%` beside `width: 100%` (a no-op) and
    # would have CLAMPED the evidence band the moment the table stepped out of the
    # column; the band width supersedes it on both surfaces.
    #
    # Both `.bp-table` entries (`display` / `overflow-x`, the reader's mobile
    # scroll chrome) are GONE too (pe-w2-parity-widening, closing
    # pe-w1-bundle-table-scroll-chrome-gap): the chrome now lives in BOTH editor
    # copies, so the mirrors match and the rot guard would red the entries.
  }

  defp divergence(section, element, prop),
    do: Map.get(@documented_divergences, {section, element, prop})

  # ── 2. Cross-surface CSS parity — the drift tripwire ───────────────────────

  test "every View (element, property) has a byte-identical value on the Edit surface" do
    edit = edit_css()
    view = view_css()

    mismatches =
      for element <- @parity_elements,
          view_decls = declarations_for(view, "bp-paper-surface", element),
          edit_decls = declarations_for(edit, "bp-paper-editor-body", element),
          {prop, value} <- Enum.to_list(view_decls),
          is_nil(divergence(:view_edit, element, prop)),
          Map.get(edit_decls, prop) != value do
        "#{element}.#{prop}: View=#{inspect(value)} Edit=#{inspect(Map.get(edit_decls, prop))}"
      end

    assert mismatches == [],
           """
           View↔Edit typography drift detected — a property was changed or ADDED
           on the View surface without the matching change on Edit (`Edit=nil`
           means the editor rule never declares it at all). Align the EDIT rule
           (root.html.heex .bp-paper-editor-body) to the published VIEW value
           (paper-surface.css .bp-paper-surface), per charter D6, OR route both
           through the same --bp-* token. If the asymmetry is DELIBERATE, add it
           to @documented_divergences with a one-line reason. Divergences:

           #{Enum.join(mismatches, "\n")}
           """
  end

  test "every documented divergence is still a real divergence (allowlist rot guard)" do
    # An allowlist entry whose asymmetry has since been fixed is a permanent
    # HOLE in the gate — the property would be free to drift again unnoticed.
    # Assert every entry still names a live producer↔mirror difference, and
    # carries a non-empty reason.
    surfaces = %{
      view_edit: {view_css(), "bp-paper-surface", edit_css(), "bp-paper-editor-body"},
      studio_bundle: {edit_css(), "bp-paper-editor-body", bundle_css(), "bp-paper-editor-body"},
      view_bundle: {view_css(), "bp-paper-surface", bundle_css(), "bp-paper-editor-body"}
    }

    stale =
      for {{section, element, prop}, reason} <- @documented_divergences do
        {producer_css, producer_class, mirror_css, mirror_class} = Map.fetch!(surfaces, section)
        producer = declarations_for(producer_css, producer_class, element)
        mirror = declarations_for(mirror_css, mirror_class, element)

        assert is_binary(reason) and String.trim(reason) != "",
               "documented divergence {#{section}, #{element}, #{prop}} has no reason"

        cond do
          not Map.has_key?(producer, prop) ->
            "{#{section}, #{element}, #{prop}} — the PRODUCER no longer declares it"

          Map.get(mirror, prop) == producer[prop] ->
            "{#{section}, #{element}, #{prop}} — the mirror now matches; drop the allowlist entry"

          true ->
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    assert stale == [],
           """
           @documented_divergences has stale entries — each one is a hole this
           gate can no longer close. Delete them:

           #{Enum.join(stale, "\n")}
           """
  end

  test "each parity element actually shares at least one property (parser sanity)" do
    # Guards against a selector rename silently emptying the diff above into a
    # vacuous pass (distrust-vacuous-green): if a rule stops matching, this fails
    # loudly instead of the parity test passing on an empty set.
    edit = edit_css()
    view = view_css()

    for element <- @parity_elements do
      view_decls = declarations_for(view, "bp-paper-surface", element)
      edit_decls = declarations_for(edit, "bp-paper-editor-body", element)

      shared =
        MapSet.intersection(MapSet.new(Map.keys(view_decls)), MapSet.new(Map.keys(edit_decls)))

      assert MapSet.size(shared) > 0,
             "no shared property found for <#{element}> — a selector rename likely broke the parity parser"
    end
  end

  # ── 3. No dangling tokens — Edit can only reference tokens the single source
  #       actually defines, so a token typo/rename can never leave the editor
  #       resolving to a browser default while View stays correct. ─────────────

  test "every --bp-*/--paper-* token the editor typography references is defined in the single source" do
    view = view_css()
    edit = edit_css()

    defined =
      ~r/(--(?:bp|paper)-[a-z0-9-]+)\s*:/
      |> Regex.scan(view)
      |> Enum.map(fn [_, name] -> name end)
      |> MapSet.new()

    referenced =
      for element <- @parity_elements,
          {_prop, value} <- declarations_for(edit, "bp-paper-editor-body", element),
          [_, name] <- Regex.scan(~r/var\(\s*(--(?:bp|paper)-[a-z0-9-]+)/, value),
          into: MapSet.new() do
        name
      end

    dangling = MapSet.difference(referenced, defined)

    assert MapSet.size(dangling) == 0,
           "editor typography references undefined tokens (not in paper-surface.css): #{inspect(MapSet.to_list(dangling))}"
  end

  # ── 4. The intentional declaration-level divergence, guarded ───────────────
  # View lists carry a bottom margin (`.bp-paper-surface ul,ol { margin: 0 0
  # 24px }`); the Edit rule deliberately does NOT redeclare it. That is not a
  # visual divergence in Studio: the canvas WC mounts in LIGHT DOM
  # (paper-editor/src/index.js `appendChild`, no shadow root) inside
  # `<main class="bp-paper-shell bp-paper-surface">` (studio_live/components.ex
  # doc-beta shell), and `Stylesheet.css/0` is inlined on the same page — so the
  # View rule ITSELF styles the canvas list. One producer; the margin tracks
  # View automatically, and with `.bp-paper-editor { gap: 0 }` (no inter-block
  # gap — rhythm rides element margins, root.html.heex) it IS the canvas list
  # rhythm. Redeclaring `margin` on the editor rule would sever that tracking
  # into a silent shadow copy — exactly the drift this file exists to prevent —
  # so ADDING one trips the wire and forces a conscious call.
  # (Standalone embeds have no `.bp-paper-surface` ancestor and fall to the UA
  # default list margin — an embed-only nuance flagged in the parity matrix.)

  test "View and Edit lists share the indent token" do
    view = view_css()
    edit = edit_css()

    for element <- ~w(ul ol) do
      view_decls = declarations_for(view, "bp-paper-surface", element)
      edit_decls = declarations_for(edit, "bp-paper-editor-body", element)

      assert view_decls["padding-left"] == "var(--bp-list-indent)"
      assert edit_decls["padding-left"] == "var(--bp-list-indent)"
    end
  end

  test "View list keeps its bottom margin; Edit list omits it (documented divergence)" do
    view = view_css()
    edit = edit_css()

    view_ul = declarations_for(view, "bp-paper-surface", "ul")
    edit_ul = declarations_for(edit, "bp-paper-editor-body", "ul")

    assert view_ul["margin"] == "0 0 24px",
           "View list bottom-margin changed — update the parity doc + Edit divergence note."

    refute Map.has_key?(edit_ul, "margin"),
           """
           The editor list rule now declares a `margin`. In Studio the canvas
           list already receives the View margin through the `.bp-paper-surface`
           cascade (light-DOM WC inside the surface shell) — redeclaring it here
           severs that single-producer tracking into a shadow copy that will
           silently drift from View. If this is intentional, update the
           divergence note in docs/specs/*-view-edit-parity-matrix.html and this
           guard.
           """
  end

  # ── 5. The bundle mirror — Studio inline rules ↔ standalone stylesheet ─────
  # Studio loads ONLY the root.html.heex inline rules (BP_PAPER_EDITOR_NO_INJECT);
  # embedders load ONLY assets/paper-editor/src/styles.css. Until now "keep it
  # byte-aligned with the bundle" comments were the sole enforcement between
  # those two hand-kept copies. Same contract as §2, Studio-exhaustive: every
  # (property, value) Studio declares must be byte-identical on the bundle,
  # `nil` included — so ADDING a rule to root.html.heex without the bundle twin
  # reds. Bundle-ONLY properties stay allowed — the bundle base rule carries
  # standalone-host extras (background/font on the wrapper, a plain `pre` rule)
  # that Studio inherits from `.bp-paper-surface` instead.
  # `.bp-table` rides here too (pe-w2-parity-widening): its scroll chrome
  # (`display: block; overflow-x: auto`) now lives in BOTH editor copies, so the
  # root↔bundle pair is gated the same way the prose elements are.
  # `.bp-stats` / `.bp-chart` complete the trio here as well (wave-2 review):
  # §2 gates them reader↔root only, so WITHOUT these entries a bundle-side
  # drift on either breakout class would ship green — the exact rot §5 exists
  # to catch.
  # `a` / `a:focus-visible` ride here too (paper-links wave): §2 gates the link
  # rule reader↔root only, so WITHOUT these the bundle copy could drift and the
  # embedded editor would lose the underline while Studio kept it.
  @mirror_elements ~w(h1 h2 h3 p li ul ol code img a a:focus-visible blockquote hr pre.bp-canvas-code .bp-table .bp-stats .bp-chart)

  test "every Studio inline editor (element, property) is byte-identical in the bundle stylesheet" do
    studio = edit_css()
    bundle = bundle_css()

    mismatches =
      for element <- @mirror_elements,
          studio_decls = declarations_for(studio, "bp-paper-editor-body", element),
          bundle_decls = declarations_for(bundle, "bp-paper-editor-body", element),
          {prop, value} <- Enum.to_list(studio_decls),
          is_nil(divergence(:studio_bundle, element, prop)),
          Map.get(bundle_decls, prop) != value do
        "#{element}.#{prop}: Studio=#{inspect(value)} Bundle=#{inspect(Map.get(bundle_decls, prop))}"
      end

    assert mismatches == [],
           """
           Studio↔bundle editor-typography drift — the root.html.heex inline
           mirror and assets/paper-editor/src/styles.css disagree (`Bundle=nil`
           means the bundle never declares the property Studio just added), so
           the embedded editor no longer looks like the Studio canvas. Align the
           copies (and rebuild the bundle if styles.css changed — see the
           wave-1 mechanics note in the pd-doctrine charter). If the asymmetry is
           DELIBERATE, add it to @documented_divergences with a one-line reason.
           Divergences:

           #{Enum.join(mismatches, "\n")}
           """
  end

  test "each mirror element actually shares at least one property (parser sanity)" do
    studio = edit_css()
    bundle = bundle_css()

    for element <- @mirror_elements do
      studio_decls = declarations_for(studio, "bp-paper-editor-body", element)
      bundle_decls = declarations_for(bundle, "bp-paper-editor-body", element)

      shared =
        MapSet.intersection(
          MapSet.new(Map.keys(studio_decls)),
          MapSet.new(Map.keys(bundle_decls))
        )

      assert MapSet.size(shared) > 0,
             "no shared property found for <#{element}> — a selector rename likely broke the mirror parser"
    end
  end

  # ── 6. The callout TONE mirror — reader surface ↔ embedder bundle ──────────
  # loop-epic/parity-callout. The canvas callout node-view carries the reader's
  # own `bp-callout` + `bp-callout--<tone>` classes. In Studio those are painted
  # by the inlined paper-surface.css `.bp-paper-surface .bp-callout*` cascade (the
  # canvas mounts inside `.bp-paper-surface`), so root.html.heex declares NO tone
  # rules — same single-producer reason lists omit their Edit margin (§4). But the
  # standalone embedder bundle (styles.css) has NO `.bp-paper-surface` ancestor, so
  # it carries a HAND-COPIED `.bp-paper-editor-body .bp-callout*` mirror. This test
  # locks that mirror byte-for-byte to the reader: VIEW (paper-surface.css,
  # `.bp-paper-surface`) vs BUNDLE (styles.css, `.bp-paper-editor-body`). NOT
  # root.html.heex — Studio inherits tone and won't declare it.
  @callout_tone_elements ~w(
    .bp-callout .bp-callout--info .bp-callout--success .bp-callout--warning
    .bp-callout--danger .bp-callout--neutral .bp-callout__summary .bp-callout__body
  )

  test "every callout tone (element, property) is byte-identical between the reader surface and the embedder bundle" do
    view = view_css()
    bundle = bundle_css()

    mismatches =
      for element <- @callout_tone_elements,
          view_decls = declarations_for(view, "bp-paper-surface", element),
          bundle_decls = declarations_for(bundle, "bp-paper-editor-body", element),
          {prop, value} <- Enum.to_list(view_decls),
          is_nil(divergence(:view_bundle, element, prop)),
          Map.get(bundle_decls, prop) != value do
        "#{element}.#{prop}: View=#{inspect(value)} Bundle=#{inspect(Map.get(bundle_decls, prop))}"
      end

    assert mismatches == [],
           """
           Callout tone drift — the embedder bundle's hand-copied
           `.bp-paper-editor-body .bp-callout*` mirror disagrees with the reader's
           `.bp-paper-surface .bp-callout*` rules (paper-surface.css) — `Bundle=nil`
           means the bundle never copied a property the reader declares. Standalone
           editors would paint callouts a different colour than the /papers reader.
           Re-copy the reader tone block verbatim into styles.css (and rebuild the
           bundle). If the asymmetry is DELIBERATE, add it to
           @documented_divergences with a one-line reason. Divergences:

           #{Enum.join(mismatches, "\n")}
           """
  end

  test "each callout tone element actually shares at least one property (parser sanity)" do
    # distrust-vacuous-green: a class rename on either side would silently empty
    # the diff above into a vacuous pass. Assert every tone element pairs up.
    view = view_css()
    bundle = bundle_css()

    for element <- @callout_tone_elements do
      view_decls = declarations_for(view, "bp-paper-surface", element)
      bundle_decls = declarations_for(bundle, "bp-paper-editor-body", element)

      shared =
        MapSet.intersection(MapSet.new(Map.keys(view_decls)), MapSet.new(Map.keys(bundle_decls)))

      assert MapSet.size(shared) > 0,
             "no shared property found for `#{element}` — a callout tone selector " <>
               "rename likely broke the mirror parser (reader ↔ bundle)."
    end
  end

  # ── 7. Article-chrome ROLE prose parity (eyebrow/byline/ingress/pullquote) ──
  # The canvas mounts these four blocks as `<p class="bp-role-*">` nodes matching
  # the reader (run-convert.js CANVAS_ROLE_TYPES + role-nodes.js). Their typography
  # is single-sourced in `.bp-paper-surface .bp-role-*` (paper-surface.css); the
  # Studio (root.html.heex) and bundle (styles.css) both carry a `.bp-paper-editor-
  # body .bp-role-*` mirror. Same drift tripwire as §2/§5 but on the ROLE classes:
  # every (property, value) declared on the View selector must be byte-identical on
  # BOTH edit selectors. `declarations_for/3` accepts a class selector as `element`
  # (target ".bp-paper-surface .bp-role-eyebrow" etc.). pullquote's italic is an
  # author mark the node emits INLINE (font-style:italic), NOT in the class — so it
  # is intentionally absent from every surface's rule here (parity stays clean).
  @role_classes ~w(.bp-role-eyebrow .bp-role-byline .bp-role-ingress .bp-role-pullquote)

  test "each role class shares at least one property across View/Edit/bundle (parser sanity)" do
    view = view_css()
    edit = edit_css()
    bundle = bundle_css()

    for class <- @role_classes do
      view_decls = declarations_for(view, "bp-paper-surface", class)
      edit_decls = declarations_for(edit, "bp-paper-editor-body", class)
      bundle_decls = declarations_for(bundle, "bp-paper-editor-body", class)

      assert map_size(view_decls) > 0,
             "no View declarations for #{class} — a selector rename likely broke the parser"

      assert MapSet.size(
               MapSet.intersection(
                 MapSet.new(Map.keys(view_decls)),
                 MapSet.new(Map.keys(edit_decls))
               )
             ) > 0,
             "no shared View↔Edit property for #{class} — the mirror is missing or renamed"

      assert MapSet.size(
               MapSet.intersection(
                 MapSet.new(Map.keys(view_decls)),
                 MapSet.new(Map.keys(bundle_decls))
               )
             ) > 0,
             "no shared View↔bundle property for #{class} — the mirror is missing or renamed"
    end
  end

  test "every role-class (property, value) is byte-identical across View, Edit, and bundle" do
    view = view_css()
    edit = edit_css()
    bundle = bundle_css()

    mismatches =
      for class <- @role_classes,
          view_decls = declarations_for(view, "bp-paper-surface", class),
          edit_decls = declarations_for(edit, "bp-paper-editor-body", class),
          bundle_decls = declarations_for(bundle, "bp-paper-editor-body", class),
          {prop, value} <- Enum.to_list(view_decls),
          surface <- [{"Edit", edit_decls}, {"Bundle", bundle_decls}],
          {label, decls} = surface,
          Map.get(decls, prop) != value do
        "#{class}.#{prop}: View=#{inspect(value)} #{label}=#{inspect(Map.get(decls, prop))}"
      end

    assert mismatches == [],
           """
           Article-chrome ROLE typography drift — a `.bp-role-*` property differs
           between the single source (paper-surface.css `.bp-paper-surface`) and an
           editor mirror (root.html.heex or assets/paper-editor/src/styles.css). The
           canvas role node would then render differently from the reader. Byte-align
           the mirrors to the View value (and rebuild the bundle if styles.css
           changed). Divergences:

           #{Enum.join(mismatches, "\n")}
           """
  end

  # ── 8. The section-divider VALUE lockstep — reader inline styles ↔ edit CSS ──
  # loop-epic/parity-divider-lockstep. The reader paints the § section divider as
  # INLINE styles on a `<div>`/`<span>` pair (Figures.section_divider_html/0,
  # figures.ex:33-37) with light-only hex fallbacks. The edit side re-expresses the
  # SAME values as a hand-mirrored `.bp-section-divider` / `.bp-section-divider__mark`
  # CSS pair in BOTH root.html.heex (~L3392-3400) and styles.css (~L452-460), bound
  # off the same custom props (dark-aware, no hex fallback). §5/§6 lock the two CSS
  # copies together but NOTHING locked them to the reader's inline source — and it
  # drifted once already (the figures.ex hex fallbacks changed after the mjs
  # structure test was written and nothing turned red). This section closes that
  # gap: it parses the inline `style="…"` decls out of the figures.ex sigil source,
  # strips var() fallbacks on every side, and asserts each visual property is
  # byte-identical across all THREE producers (reader inline / Studio CSS / bundle
  # CSS). Values verified matching 2026-07-09; no production code changed.
  @figures_ex Path.expand(
                "../../../../lib/barkpark/portable_doc/render/figures.ex",
                __DIR__
              )

  # The two divider sub-elements and the inline `style=` order they appear in the
  # figures.ex source: the outer `<div>` maps to `.bp-section-divider`, the inner
  # `<span>` to `.bp-section-divider__mark`.
  @divider_container_selector ".bp-section-divider"
  @divider_mark_selector ".bp-section-divider__mark"

  # Reconstruct the concatenated HTML string emitted by section_divider_html/0 and
  # pull the two inline declaration sets out of its `style="…"` attributes. The body
  # is three `~s|…| <> ~s|…|` fragments; strip the sigil delimiters + `<>` glue so a
  # `style="…"` that straddles a fragment boundary (the span's is split across L35/36)
  # reads as one attribute. Returns %{container: decls, mark: decls}, var()-fallbacks
  # stripped so `var(--paper-rule, #dde7e2)` compares equal to the CSS `var(--paper-rule)`.
  defp figures_divider_decls do
    src = File.read!(@figures_ex)

    [_, body] =
      Regex.run(~r/def section_divider_html do(.*?)\n  end/s, src)

    stitched =
      body
      # drop the `| <> ~s|` concatenation glue between adjacent sigil fragments
      |> String.replace(~r/\|\s*<>\s*~s\|/, "")
      # drop the leading `~s|` opener and the final `|` closer
      |> String.replace(~r/~s\|/, "")
      |> String.replace("|", "")

    styles =
      ~r/style="([^"]*)"/
      |> Regex.scan(stitched)
      |> Enum.map(fn [_, s] -> s end)

    [container_style, mark_style] = styles

    %{
      container: container_style |> parse_decls() |> strip_var_fallbacks(),
      mark: mark_style |> parse_decls() |> strip_var_fallbacks()
    }
  end

  # Normalise every value in a decl map so `var(--name, fallback)` -> `var(--name)`.
  # The reader carries light-only hex fallbacks; the CSS mirrors carry none. Comparing
  # fallback-stripped isolates the ACTUAL bound values (custom props + literals) and
  # lets the CSS side stay a legitimate dark-aware improvement without tripping the wire.
  defp strip_var_fallbacks(decls) when is_map(decls) do
    Map.new(decls, fn {prop, value} ->
      {prop, Regex.replace(~r/var\(\s*(--[a-z0-9-]+)\s*,[^)]*\)/, value, "var(\\1)")}
    end)
  end

  # The CSS-side decls for a divider selector, var()-fallbacks stripped, from one
  # editor stylesheet (root.html.heex inline OR the bundle styles.css).
  defp divider_css_decls(css, selector),
    do: css |> declarations_for("bp-paper-editor-body", selector) |> strip_var_fallbacks()

  test "section-divider inline decls byte-match the .bp-section-divider CSS in Studio and the bundle" do
    reader = figures_divider_decls()
    studio = edit_css()
    bundle = bundle_css()

    pairs = [
      {@divider_container_selector, reader.container},
      {@divider_mark_selector, reader.mark}
    ]

    mismatches =
      for {selector, reader_decls} <- pairs,
          css <- [
            {"Studio", divider_css_decls(studio, selector)},
            {"Bundle", divider_css_decls(bundle, selector)}
          ],
          {label, css_decls} = css,
          {prop, value} <- Enum.to_list(reader_decls),
          Map.get(css_decls, prop) != value do
        "#{selector}.#{prop}: Reader=#{inspect(value)} #{label}=#{inspect(Map.get(css_decls, prop))}"
      end

    assert mismatches == [],
           """
           Section-divider value drift — a property the reader paints INLINE
           (Figures.section_divider_html/0, figures.ex) disagrees with the edit
           CSS mirror (.bp-section-divider / .bp-section-divider__mark in
           root.html.heex or assets/paper-editor/src/styles.css). The edit canvas
           divider would then look different from the /papers reader. Re-align the
           mirror to the reader value (var() fallbacks are stripped before compare,
           so this is about the ACTUAL bound value, not the light-only hex). Divergences:

           #{Enum.join(mismatches, "\n")}
           """
  end

  test "section-divider extractors found non-empty decl sets in all three sources (parser sanity)" do
    # distrust-vacuous-green: a sigil-shape change in figures.ex, a selector rename
    # in either stylesheet, or the container/mark split collapsing would silently
    # empty the diff above into a vacuous pass. Assert every extractor pulled a
    # non-empty set AND that the reader carries the expected visual property keys.
    reader = figures_divider_decls()
    studio = edit_css()
    bundle = bundle_css()

    assert map_size(reader.container) > 0,
           "figures.ex divider container inline decls came back empty — sigil source shape changed"

    assert map_size(reader.mark) > 0,
           "figures.ex divider mark inline decls came back empty — sigil source shape changed"

    assert MapSet.subset?(
             MapSet.new(~w(position text-align margin border-top)),
             MapSet.new(Map.keys(reader.container))
           ),
           "figures.ex divider container is missing an expected property: #{inspect(Map.keys(reader.container))}"

    assert MapSet.subset?(
             MapSet.new(~w(position top display padding background color font-size)),
             MapSet.new(Map.keys(reader.mark))
           ),
           "figures.ex divider mark is missing an expected property: #{inspect(Map.keys(reader.mark))}"

    for {name, css} <- [{"Studio", studio}, {"Bundle", bundle}],
        selector <- [@divider_container_selector, @divider_mark_selector] do
      decls = divider_css_decls(css, selector)

      assert map_size(decls) > 0,
             "#{name} stylesheet has no `#{selector}` declarations — a selector rename likely broke the divider lockstep parser"
    end
  end

  # ── 9. The SECTION HEAD — one device, four hand-kept declarations ───────────
  # A top-level level-2 heading is a section boundary and draws it with air + a
  # rule + a gap (space.section → `--bp-section-*`; the reasoning lives on the
  # rule in paper-surface.css). Unlike the h1/h2/h3 margins §2 and §5 already
  # cover, this device cannot ride the shared `.bp-paper-surface h2` element
  # rule: component chrome emits bare `<h2>`s too (a `.bp-card` title inside a
  # grid cell), and only POSITION separates a section head from a card's title.
  # So it is written four times against four document shapes — and four hand-kept
  # copies of one law is precisely the drift surface §2/§5 exist for.
  #
  # The failure this catches is NOT a deleted token (design/check.mjs Part L
  # already refuses that, on both surfaces). It is one copy keeping the air while
  # another keeps the rule: every per-file census passes, the reader and the
  # canvas disagree, and the only witness is a screenshot nobody diffs.
  #
  # Exhaustive over the READER's declarations, `nil` included, in §2's shape —
  # so adding a property to the reader without the three editor twins reds here.
  @section_head_reader "> #paper-body > h2"
  @section_head_stream "> #paper-body > div:not([class]) > h2"
  @section_head_edit "> h2"

  test "the section head is byte-identical across the reader and all three editor copies" do
    view = view_css()

    reader = declarations_for(view, "bp-paper-surface", @section_head_reader)

    copies = [
      {"Studio inline (root.html.heex)",
       declarations_for(edit_css(), "bp-paper-editor-body", @section_head_edit)},
      {"embedder bundle (assets/paper-editor/src/styles.css)",
       declarations_for(bundle_css(), "bp-paper-editor-body", @section_head_edit)}
    ]

    mismatches =
      for {name, decls} <- copies,
          {prop, value} <- Enum.to_list(reader),
          Map.get(decls, prop) != value do
        "#{name} — #{prop}: reader=#{inspect(value)} copy=#{inspect(Map.get(decls, prop))}"
      end

    assert mismatches == [],
           """
           SECTION HEAD drift — the reader and an editor copy disagree about the
           section boundary. One surface is drawing a device the other is not:

           #{Enum.join(mismatches, "\n")}

           The device is air + rule + gap TOGETHER. Change all four declarations
           (paper-surface.css reader + its keyed-stream leg, root.html.heex,
           assets/paper-editor/src/styles.css) or none, then re-run the render rig
           — the rendered gap is asserted against the artifact's 92px there.
           """
  end

  test "the reader's section head covers BOTH document shapes it ships in" do
    # The block-backed reader streams every top-level block as its own class-less
    # `<div id data-block-id>` (bulldocs_live.ex, `phx-update="stream"`), while
    # the legacy whole-body path and the render rig put the heading directly in
    # the article. A rule written against only one of those is dead on the page
    # that actually ships AND green in every gate that reads declarations rather
    # than selectors — so the two legs are pinned to carry identical values.
    view = view_css()

    flat = declarations_for(view, "bp-paper-surface", @section_head_reader)
    streamed = declarations_for(view, "bp-paper-surface", @section_head_stream)

    assert flat == streamed,
           """
           the section head's two reader legs disagree:
             #{@section_head_reader} => #{inspect(flat)}
             #{@section_head_stream} => #{inspect(streamed)}
           The keyed-stream leg is the one the live reader matches; the flat leg is
           the legacy body and the render rig. Both must draw the same boundary.
           """
  end

  test "the section head declares all three halves of the device (parser sanity)" do
    # Guards the two tests above against a vacuous pass: if a selector is renamed
    # the declaration maps go empty, every comparison trivially holds, and the
    # drift tripwire silently stops tripping (distrust-vacuous-green).
    surfaces = [
      {"reader", declarations_for(view_css(), "bp-paper-surface", @section_head_reader)},
      {"reader keyed-stream leg",
       declarations_for(view_css(), "bp-paper-surface", @section_head_stream)},
      {"Studio inline", declarations_for(edit_css(), "bp-paper-editor-body", @section_head_edit)},
      {"embedder bundle",
       declarations_for(bundle_css(), "bp-paper-editor-body", @section_head_edit)}
    ]

    for {name, decls} <- surfaces do
      for {prop, token} <- [
            {"margin-top", "--bp-section-beat"},
            {"border-top", "--bp-section-rule"},
            {"padding-top", "--bp-section-gap"}
          ] do
        value = Map.get(decls, prop)

        assert value && String.contains?(value, "var(#{token})"),
               "#{name}: the section head's #{prop} is #{inspect(value)}, expected it to read var(#{token}) — " <>
                 "a selector rename or a half-written device would make the parity tests above vacuous"
      end
    end
  end

  # ── 10. THE READING SERIF, for chrome portaled OUT of the surface ───────────
  # The slash menu and the format bubble are appended to `document.body`
  # (slash-menu.js:283, format-bubble.js:203), so they are NOT descendants of
  # `.bp-paper-surface` and cannot inherit the `--paper-font-serif` declared
  # there. Each surface therefore needs its OWN document-root declaration, and
  # for a while only the bundle had one: styles.css's generated mirror puts the
  # token on `:root, :host`, while root.html.heex instead gave the two popups a
  # private `'Source Serif 4', Georgia, 'Times New Roman', serif`. That is a
  # DIFFERENT stack from the one the reader resolves, and it was live — measured
  # in headless Chromium via CDP CSS.getPlatformFontsForNode, the format
  # bubble's B and I glyphs painted in Georgia while the prose they format
  # painted in Iowan Old Style.
  #
  # It never moved a `ch` figure — `.bp-paper-surface` resolves its own token,
  # and its px-per-ch measured 10.0000 before and after — so this is a typography
  # parity bug, not a layout one (spd-b37). The guard exists because the two
  # declarations are hand-kept copies in different files with no other link.
  #
  # The stack ORDER is deliberately NOT asserted here: it is owned by
  # au-w5-reading-typography (human-gated) and lives in design/tokens.json
  # `font.reading.stack`. This pins that the two documents AGREE, whatever that
  # gate later ratifies — so the eventual Source-Serif-first cutover changes one
  # token and this test keeps holding.
  @serif_token "--paper-font-serif"

  defp root_serif_declarations(css) do
    ~r/--paper-font-serif:\s*([^;]+);/
    |> Regex.scan(css)
    |> Enum.map(fn [_, value] -> String.trim(value) end)
  end

  test "the Studio and the bundle declare ONE reading-serif stack, byte-identical" do
    studio = root_serif_declarations(edit_css())
    bundle = root_serif_declarations(bundle_css())

    # distrust-vacuous-green: a rename that empties BOTH sides would make the
    # equality below trivially true, so require each side to actually declare it.
    assert studio != [],
           "root.html.heex declares #{@serif_token} nowhere — the Studio's " <>
             "body-portaled popups (slash menu, format bubble) would inherit no " <>
             "reading serif at all. A selector or token rename likely broke this."

    assert bundle != [],
           "api/assets/paper-editor/src/styles.css declares #{@serif_token} nowhere — " <>
             "the embedder bundle's popups would inherit no reading serif."

    assert length(Enum.uniq(studio)) == 1,
           "root.html.heex declares #{@serif_token} with MORE THAN ONE value: " <>
             "#{inspect(Enum.uniq(studio))}. A second, private stack for portaled " <>
             "chrome is exactly the divergence spd-b37 removed — declare it once at :root."

    assert length(Enum.uniq(bundle)) == 1,
           "styles.css declares #{@serif_token} with more than one value: " <>
             "#{inspect(Enum.uniq(bundle))}."

    [studio_value] = Enum.uniq(studio)
    [bundle_value] = Enum.uniq(bundle)

    assert studio_value == bundle_value,
           """
           Reading-serif drift between the Studio shell and the embedder bundle.
           These are two hand-kept copies of ONE stack; nothing but this test
           links them, and when they last diverged the format bubble's B and I
           glyphs rendered in a different face from the prose they format.

             root.html.heex (:root)          #{inspect(studio_value)}
             styles.css     (:root, :host)   #{inspect(bundle_value)}

           Align them byte-for-byte. If the stack ORDER itself is what changed,
           that belongs in design/tokens.json `font.reading.stack` behind the
           au-w5-reading-typography gate, and then BOTH sides carry it.
           """
  end
end
