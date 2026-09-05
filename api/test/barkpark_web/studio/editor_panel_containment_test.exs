defmodule BarkparkWeb.Studio.EditorPanelContainmentTest do
  @moduledoc """
  studio-space-priority-desk spd-b10 — the `.editor-panel` containment tripwire.

  ## Why this file is a TRIPWIRE and not a regression guard (charter D41)

  spd-s1 made `.editor-panel` a query container (`container-type: inline-size`).
  The review feared a classic CSS trap (charter D33): `container-type` computes
  to `contain: layout style inline-size`, and LAYOUT containment makes an element
  a containing block for its `position: fixed` descendants — they would stop
  resolving against the viewport and start being clipped by the panel's
  `overflow: hidden` box.

  **That mechanism was MEASURED FALSE in Blink.** A browser A/B of the pre-s1
  rule against the merged rule, on a faithful reproduction of the real DOM chain,
  found a fixed modal byte-identical in both (rect x0 w1440 h900 in each; the
  backdrop still hit-testable 180px outside the panel; the card still centred on
  the VIEWPORT, not the panel). The harness provably *can* see the effect: two
  positive controls on the same element in the same run — `contain: layout` and
  `transform: translateZ(0)` — both promoted the modal to the panel box
  (x240 w1200). Sweeping `container-type` across inline-size / size / normal left
  the fixed modal at x0 w1440 in all three while an injected `@container` rule DID
  apply, proving the query container was live. Chrome deliberately does not treat
  `container-type`'s layout containment as establishing a containing block for
  fixed descendants.

  So the panic was unfounded — but the measurement named the REAL hazard, which
  is what this file pins:

    1. **Inventory tripwire.** The set of `position: fixed` surfaces that
       genuinely render *inside* an `.editor-panel` root is small and known.
       Everything else either portals to `document.body` or is a SIBLING of the
       panel inside `.pane-layout`. If a future slice adds a fourth one, the
       verdict "containment is harmless here" silently stops being audited —
       so a new one fails this test until it is classified.

    2. **Containing-block trigger ban.** `contain:`, `transform:`, `filter:`,
       `will-change:`, `backdrop-filter:` and `perspective:` DO establish a
       containing block for fixed descendants in *every* engine — `transform`
       was one of the two positive controls above. This is not hypothetical:
       spd-s5 adds collapse/expand motion in this same wave, and a transform
       landed on `.editor-panel` instead of an inner wrapper would recreate the
       exact bug this task proved absent.

  ## Why the checks are TEXT-based

  ExUnit has no layout engine. CI can never *observe* a containing block; it can
  only observe the source facts that would create one. So this file reads the
  layout + component SOURCE and asserts over it. What would change the verdict is
  a real browser measurement (the one above), not a bigger ExUnit assertion.

  ## Why the sheet carve-out stays

  `.editor-panel.sheet-editor { container-type: normal; }` is retained even
  though D33's mechanism is measured-false in Blink: CSS Contain 2
  §layout-containment reads the other way, so WebKit/Gecko may yet do what D33
  assumed, and the Sheets right-click menu is the one surface that is
  server-rendered *inside* the panel with viewport coordinates. It is cheap
  cross-engine insurance. Do not "clean it up" — and do not "fix" it either.

  ## What the census reads (spd-b10f)

  A census that skips a source certifies safety it never checked, so the four
  places a `position: fixed` can enter the Studio are all read here:
  `root.html.heex`, inline `style=` in the studio `.ex`/`.heex` sources, shipped
  `priv/static/assets/*.js`, and `assets/paper-editor/src/styles.css` — the last
  of which spd-b10 named as its own gap in #4471 and this slice closed.

  This slice READS `root.html.heex`; it never edits it (file-disjoint from spd-s4).
  """
  use ExUnit.Case, async: true

  @moduletag :studio_containment

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  # The editor SHELL stylesheet the root layout links. edit-on-the-link lifted it
  # out of that layout's inline <style> so the public paper reader can link the
  # same bytes; for this census it is still root-layout CSS, so `root_css/0`
  # reads the two together and the inventory below is unchanged.
  @root_shell_css Path.expand(
                    "../../../priv/static/assets/bp-paper-editor-shell.css",
                    __DIR__
                  )
  @lib Path.expand("../../../lib/barkpark_web", __DIR__)
  @static_js Path.expand("../../../priv/static/assets", __DIR__)

  # The paper editor's own stylesheet — spd-b10 shipped the census WITHOUT it and
  # said so (spd-b10f closes that gap). It is a fourth source of `position: fixed`
  # and the most dangerous one: the `<bp-paper-editor>` custom element mounts
  # INSIDE the `studio-paper-editor` `.editor-panel` root, so anything this sheet
  # positions that does not portal renders under a panel. esbuild emits it to
  # `priv/static/assets/bp-paper-editor.css` (index.js `ensureStyles/0` links it),
  # which the `*.js` glob below never sees — the SOURCE is the honest census input.
  @paper_editor_css Path.expand("../../../assets/paper-editor/src/styles.css", __DIR__)

  # The BUILT sheet (spd-census-built-paper-editor-css). `assets/paper-editor`'s
  # `npm run build` runs `esbuild src/styles.css --bundle --outfile=
  # ../../priv/static/assets/bp-paper-editor.css --minify`, and that artifact is
  # COMMITTED — it, not the source above, is the byte stream `ensureStyles/0`
  # links into the page. It escaped every census this file runs: the source
  # census reads `src/styles.css`, and the artifact census globs
  # `priv/static/assets/*.js` only. So a hand-edit here, or a build that no
  # longer matches its source, could add a `position: fixed` surface under the
  # paper `.editor-panel` root with every guard green.
  #
  # One equality assertion closes both holes: built-only selector (hand-edit /
  # rebuilt-from-edited-source-without-committing-the-source) AND source-only
  # selector (stale build), because a set equality fails in either direction.
  @paper_editor_built_css Path.expand("../../../priv/static/assets/bp-paper-editor.css", __DIR__)

  # The SIX `.editor-panel` roots (charter D42 — D29 listed only five).
  # A seventh root means the inventory below has to be re-audited, so the set is
  # pinned rather than merely counted.
  #
  # Each root is pinned by {file, ANCHOR, description} — a distinguishing token
  # on the root's own source line — deliberately NOT by line number. Line
  # numbers were the first draft and they are a false tripwire: spd-s4 is a
  # file-disjoint sibling of this slice that nonetheless shifts every root in
  # `components.ex` by ~12 lines (it inserts a comment block above the pane
  # loop), which reddened this test on merge while nothing about the containment
  # audit had actually changed. An anchor moves only when the root itself is
  # rewritten — which IS the event worth failing on.
  @panel_roots [
    {"live/studio/studio_live/components.ex", ~s(data-test-id="studio-paper-editor"),
     "paper editor"},
    {"live/studio/studio_live/components.ex", "media-explorer-panel", "media explorer"},
    {"live/studio/studio_live/components.ex", ~s(data-test-id="studio-doc-beta-editor"),
     "beta doc editor"},
    {"components/studio_components/editor.ex", ~s(<div class="editor-panel"),
     "classic field editor"},
    {"live/studio/graph_view.ex", "graph-editor", "graph view"},
    {"live/studio/sheet_grid.ex", "sheet-editor", "sheet grid"}
  ]

  # Every selector in root.html.heex whose rule block declares `position: fixed`,
  # with its placement relative to the panel roots above.
  #
  #   :under_panel     — renders as a DESCENDANT of an `.editor-panel` root.
  #                      This is the set containment would affect. Keep it at 3.
  #   :body_portal     — JS moves the node to `document.body` before showing it.
  #   :layout_sibling  — server-rendered inside `.pane-layout` but AFTER
  #                      `</.studio_editor_shell>` (components.ex:913), so it is
  #                      a sibling of the panel, never a descendant.
  @fixed_css_inventory %{
    # bp-asset-explorer.js:184 / :241-247 build these INSIDE the custom element,
    # which mounts at components.ex:797 (media-explorer-panel) — under a panel.
    ".bp-ae-toast" => :under_panel,
    ".bp-ae-modal" => :under_panel,
    # sheet_grid.ex:3030, a sibling of the grid-wrap inside the sheet panel
    # (sheet_grid.ex:2478) — the one surface the carve-out insures.
    ".sheet-context-menu" => :under_panel,
    ".bp-slash-menu" => :body_portal,
    ".bp-paper-format" => :body_portal,
    ".bp-paper-context-menu" => :body_portal,
    ".bp-ab-overlay" => :body_portal,
    ".bp-bulk-action-bar" => :layout_sibling,
    ".image-picker-overlay" => :layout_sibling,
    ".image-picker" => :layout_sibling,
    ".history-modal" => :layout_sibling,
    ".delete-modal" => :layout_sibling,
    ".profile-modal" => :layout_sibling,
    # spd-w19 — `#bp-press-answer`, the press-answer live region. Rendered in
    # root.html.heex as a DIRECT SIBLING of `{@inner_content}`, i.e. outside the
    # LiveView root entirely (that placement is the point: inside the root
    # morphdom can patch the node mid-announce and the announcement is dropped).
    # It can therefore never sit under an `.editor-panel`, and it carries
    # `pointer-events: none` so it never eats a press either.
    ".bp-press-answer" => :layout_sibling
  }

  # Every selector in the paper-editor stylesheet whose rule block declares
  # `position: fixed`, with the same placement vocabulary as above. The default
  # placement for anything added here is :under_panel — the element mounts inside
  # the paper `.editor-panel` root — so a new surface earns :body_portal only when
  # its builder is shown to append to `document.body`.
  @paper_editor_fixed_inventory %{
    # wikilink-menu.js:117-120 names the node `.bp-wikilink-menu` and immediately
    # `document.body.appendChild(el)`s it — portalled out of the panel before it
    # is ever shown, so no containing block the panel grows can reach it.
    ".bp-wikilink-menu" => :body_portal
  }

  # Server-rendered INLINE `position: fixed` (style="…"), by file, with the
  # occurrence count. A new inline fixed surface bumps a count and fails here.
  @inline_fixed_inventory %{
    # cell_menu_style/1 — viewport coords from clientX/clientY, re-clamped by the
    # JS hook. UNDER a panel root; the carve-out exists for exactly this.
    "live/studio/sheet_grid.ex" => 1,
    # ConnectorsLive is its own full-page route (router.ex:1259) — it renders no
    # `.pane-layout` and no `.editor-panel`, so containment cannot reach it.
    "live/studio/connectors_live.ex" => 2,
    # ConfirmModal is invoked at components.ex:940 — after the editor shell
    # closes (:913) and before `</.pane_layout>` (:1143): a layout sibling.
    "components/confirm_modal.ex" => 1,
    # The Cmd/Ctrl+K session palette overlay. ChatLive is its own full-page
    # route (router.ex "/chat" and "/chat/:session_id") and renders NEITHER
    # `.pane-layout` NOR `.editor-panel` — grep both in chat_live.ex for zero
    # hits — so, exactly like connectors_live.ex above, no panel containing
    # block can reach it and the D33 carve-out does not apply. The overlay is a
    # full-viewport scrim (inset: 0) that must cover the whole page, which is
    # why it is fixed rather than absolute.
    "live/studio/chat_live.ex" => 1
  }

  # Shipped studio JS that emits `position: fixed` from script. Each MUST portal
  # to document.body — that is what makes its floating surface immune to any
  # containing block the panel might grow.
  @portaling_js ~w(
    bp-paper-editor.bundle.js
    bp-overflow-menu.js
    bp-media-picker.js
  )

  # Properties that establish a containing block for `position: fixed`
  # descendants in EVERY engine (unlike container-type — see @moduledoc).
  @containing_block_triggers ~w(contain transform filter will-change backdrop-filter perspective)

  # ── The INVERSE census (spd-w5, charter D80) ─────────────────────────────
  #
  # Everything above this line inventories `position: fixed` PRESENT. That is
  # one direction only, and D80 is the bug it structurally cannot see: a
  # backdrop-shaped class that has LOST its positioning entirely. `.modal-backdrop`
  # was emitted by `studio_components/editor_fields.ex` with NO rule anywhere in
  # `api/` — it computed `position: static; display: block`, and since
  # `components.ex` renders it as a SIBLING of the editor shell inside
  # `.pane-layout` (`display: flex`) it became an in-flow flex ITEM of the pane
  # row. Measured live at viewport 1280: the row went from
  # [strip 44, list 260, editor-panel 976] to
  # [strip 44, list 230.4, editor-panel 560, modal-backdrop 445.6] — the panel
  # crushed onto its own 560px floor, `rowOverflow: 0`, no console error, two
  # clicks from a normal document. No gate in this repo could have caught it.
  #
  # So: every backdrop-shaped class a Studio component emits must resolve to a
  # NON-STATIC position — by a `root.html.heex` rule, or by an inline `style=`
  # on the emitting element itself. Which of the two is a classification, not a
  # free choice: an unclassified backdrop fails until someone looks at it.
  #
  #   :css_rule     — a `root.html.heex` rule declares its position.
  #   :inline_style — the emitting element carries `position:` in `style="…"`.
  #                   (That is also why `@inline_fixed_inventory` counts it.)
  @backdrop_class_inventory %{
    # editor_fields.ex secondary_picker_modal/1 — the D80 subject. Absolute, not
    # fixed, per D52: `.pane-layout`/`.studio-shell`/`body` are all unpositioned,
    # so it resolves against the initial containing block and stays out of
    # @fixed_css_inventory, which this slice does not own.
    "modal-backdrop" => :css_rule,
    # modals.ex image picker — `position: fixed; inset: 0`, :layout_sibling above.
    "image-picker-overlay" => :css_rule,
    # confirm_modal.ex renders its own `style="position: fixed; inset: 0; …"`;
    # there is no `.bp-modal-overlay` rule and none is needed.
    "bp-modal-overlay" => :inline_style
  }

  # What counts as "backdrop-shaped": a class token whose name says it exists to
  # cover something. Deliberately name-based — a scrim is named like a scrim, and
  # ExUnit has no layout engine to recognise one any other way (see @moduledoc).
  @backdrop_name_shapes ~w(backdrop overlay scrim)

  # The Studio root layout's CSS is two files since edit-on-the-link: the
  # remaining inline <style> plus the editor shell stylesheet it links
  # (/assets/bp-paper-editor-shell.css, which the public paper reader links
  # too). The census is over what the Studio page LOADS, so it reads both.
  defp root_css, do: File.read!(@root) <> "\n" <> File.read!(@root_shell_css)

  # Strip CSS comments so prose about `position: fixed` is never censused.
  defp decommented(css), do: Regex.replace(~r|/\*.*?\*/|s, css, "")

  # The declarations of the bare `.editor-panel { … }` rule (not `.editor-panel.x`,
  # not a descendant selector) — brace-matched from the source.
  defp editor_panel_block(css) do
    [_, block] = Regex.run(~r/\n\s*\.editor-panel\s*\{(.*?)\}/s, css)
    block
  end

  # Every selector whose rule block declares `position: fixed`. Walks the sheet
  # keeping a brace stack, so a declaration inside `@media`/`@container` is
  # attributed to its own selector and not to the at-rule.
  defp fixed_position_selectors(css) do
    css
    |> decommented()
    |> String.split("\n")
    |> Enum.reduce({[], []}, fn line, {stack, found} ->
      found =
        if Regex.match?(~r/position:\s*fixed/, line) do
          selector =
            case String.split(line, "{", parts: 2) do
              [sel, _] -> String.trim(sel)
              [_] -> List.first(stack, "<unattributed>")
            end

          [selector | found]
        else
          found
        end

      {push_pop_braces(line, stack), found}
    end)
    |> elem(1)
    |> MapSet.new()
  end

  # ── The MINIFIED-SAFE census (spd-census-built-paper-editor-css) ─────────
  #
  # `fixed_position_selectors/1` above is LINE-based: it decides the selector by
  # splitting the line that carries the declaration. That is exact on authored
  # CSS and useless on the built sheet, which esbuild emits as ONE line — every
  # declaration in the file would be attributed to the first selector in it.
  #
  # This walks characters instead, keeping the same brace stack, so it reads
  # authored and minified CSS identically. `built_and_source_agree_on_the_source`
  # (below) pins that equivalence rather than assuming it.
  #
  # It also normalises the two forms esbuild legitimately rewrites:
  #
  #   * whitespace — `position: fixed` (source) vs `position:fixed` (built), and
  #     a selector broken across lines vs joined;
  #   * comma lists — `.a,\n.b { … }` vs `.a,.b{…}`. The list is SPLIT, so the
  #     census is a set of individual selectors and a re-grouped rule is not a
  #     spurious diff.
  #
  # Quoted strings are tracked so a `content: "}"` cannot unbalance the stack.
  defp minified_safe_fixed_selectors(css) do
    css
    |> decommented()
    |> String.graphemes()
    |> Enum.reduce({[], "", nil, []}, &css_scan_step/2)
    |> then(fn {_stack, _buf, _quote, found} -> found end)
    |> Enum.flat_map(&split_selector_list/1)
    |> MapSet.new()
  end

  # Inside a string literal: copy through until the matching quote.
  defp css_scan_step(ch, {stack, buf, quote_ch, found}) when not is_nil(quote_ch) do
    {stack, buf <> ch, if(ch == quote_ch, do: nil, else: quote_ch), found}
  end

  defp css_scan_step(ch, {stack, buf, nil, found}) when ch in ["\"", "'"],
    do: {stack, buf <> ch, ch, found}

  defp css_scan_step("{", {stack, buf, nil, found}),
    do: {[collapse_ws(buf) | stack], "", nil, found}

  # A `}` also terminates the last declaration, which minifiers emit without a
  # trailing `;` — so the buffer is censused before the stack pops.
  defp css_scan_step("}", {stack, buf, nil, found}),
    do: {Enum.drop(stack, 1), "", nil, census_declaration(buf, stack, found)}

  defp css_scan_step(";", {stack, buf, nil, found}),
    do: {stack, "", nil, census_declaration(buf, stack, found)}

  defp css_scan_step(ch, {stack, buf, nil, found}), do: {stack, buf <> ch, nil, found}

  defp census_declaration(buf, stack, found) do
    if Regex.match?(~r/(^|[\s;])position\s*:\s*fixed$/i, collapse_ws(buf)) do
      [List.first(stack, "<unattributed>") | found]
    else
      found
    end
  end

  defp collapse_ws(str), do: str |> String.replace(~r/\s+/, " ") |> String.trim()

  defp split_selector_list(selector),
    do: selector |> String.split(",") |> Enum.map(&collapse_ws/1) |> Enum.reject(&(&1 == ""))

  defp push_pop_braces(line, stack) do
    line
    |> String.graphemes()
    |> Enum.reduce({stack, ""}, fn
      "{", {stack, buf} -> {[String.trim(buf) | stack], ""}
      "}", {stack, _buf} -> {Enum.drop(stack, 1), ""}
      ch, {stack, buf} -> {stack, buf <> ch}
    end)
    |> elem(0)
  end

  # Inline `position: fixed` occurrences in an Elixir/HEEx source, with Elixir
  # comments and HEEx comments removed so prose never counts.
  defp inline_fixed_count(path) do
    (@lib <> "/" <> path)
    |> File.read!()
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, ""))
    |> then(&Regex.replace(~r/<!--.*?-->/s, &1, ""))
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.join("\n")
    |> then(&Regex.scan(~r/position:\s*fixed/, &1))
    |> length()
  end

  # Every backdrop-shaped class token emitted from a `class=` attribute in the
  # Studio sources, as %{class => [relative source path]}. Handles both the
  # literal `class="…"` and the interpolated `class={…}` forms.
  defp emitted_backdrop_classes do
    for path <- studio_sources(), reduce: %{} do
      acc ->
        rel = Path.relative_to(path, @lib)

        path
        |> File.read!()
        |> backdrop_tokens()
        |> Enum.reduce(acc, fn token, acc ->
          Map.update(acc, token, [rel], &Enum.uniq([rel | &1]))
        end)
    end
  end

  # The backdrop-shaped class tokens inside every `class=` attribute of a source.
  defp backdrop_tokens(src) do
    shape = Enum.join(@backdrop_name_shapes, "|")

    ~r/class=(?:"([^"]*)"|\{([^}]*)\})/s
    |> Regex.scan(src)
    |> Enum.flat_map(fn match -> Enum.drop(match, 1) end)
    |> Enum.flat_map(fn attr ->
      ~r/[a-z0-9_-]*(?:#{shape})[a-z0-9_-]*/
      |> Regex.scan(attr)
      |> Enum.map(&List.first/1)
    end)
    |> Enum.uniq()
  end

  # Every selector in a stylesheet that declares `position:`, mapped to the set
  # of values it declares. Same brace-stack walk as `fixed_position_selectors/1`,
  # so a declaration inside `@media`/`@container` is attributed to its own
  # selector — but it keeps the VALUE, which is the whole point of the inverse
  # census: `static` is the failure this reads for.
  defp declared_positions(css) do
    css
    |> decommented()
    |> String.split("\n")
    |> Enum.reduce({[], %{}}, fn line, {stack, found} ->
      found =
        case Regex.run(~r/(^|[\s;{])position:\s*([a-z-]+)/, line) do
          [_, _, value] ->
            selector =
              case String.split(line, "{", parts: 2) do
                [sel, _] -> String.trim(sel)
                [_] -> List.first(stack, "<unattributed>")
              end

            Map.update(found, selector, MapSet.new([value]), &MapSet.put(&1, value))

          nil ->
            found
        end

      {push_pop_braces(line, stack), found}
    end)
    |> elem(1)
  end

  # The `position` values a bare `.class` selector declares anywhere in a sheet
  # (a comma-list counts, `.a .class` deliberately does NOT — a descendant rule
  # positions something else).
  defp positions_for_class(css, class) do
    css
    |> declared_positions()
    |> Enum.flat_map(fn {selector, values} ->
      selector
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.any?(&(&1 == "." <> class))
      |> if(do: MapSet.to_list(values), else: [])
    end)
    |> MapSet.new()
  end

  # The `position` values declared in an inline `style="…"` on an element that
  # also carries `class="<class>"`, across the Studio sources.
  defp inline_positions_for_class(class) do
    for path <- studio_sources(),
        src = File.read!(path),
        # The attributes of one element: from the class attr to the tag close.
        [element] <- Regex.scan(~r/class="[^"]*\b#{Regex.escape(class)}\b[^"]*".*?>/s, src),
        [_, value] <- Regex.scan(~r/position:\s*([a-z-]+)/, element),
        into: MapSet.new(),
        do: value
  end

  defp studio_sources do
    for dir <- ~w(live/studio components), ext <- ~w(ex heex), reduce: [] do
      acc -> acc ++ Path.wildcard(@lib <> "/" <> dir <> "/**/*." <> ext)
    end
  end

  describe "the containing-block trigger ban (the REAL hazard)" do
    test "the .editor-panel rule declares none of contain/transform/filter/will-change/backdrop-filter/perspective" do
      block = editor_panel_block(root_css())

      # Non-vacuity: prove we grabbed the RIGHT block before asserting absence.
      assert block =~ "container-type: inline-size",
             "the matched .editor-panel block is not the spd-s1 container rule"

      assert block =~ "min-width: 560px", "the matched block is missing the D4 content floor"
      assert block =~ "position: relative", "the matched block is missing the positioning context"

      for prop <- @containing_block_triggers do
        refute Regex.match?(~r/(^|[\s;])#{Regex.escape(prop)}\s*:/, block),
               """
               `.editor-panel` declares `#{prop}:`.

               Unlike `container-type` (measured harmless in Blink — see the
               moduledoc), `#{prop}` establishes a containing block for every
               `position: fixed` descendant in EVERY engine. The Sheets
               right-click menu (sheet_grid.ex cell_menu_style/1) and the asset
               explorer's toast + New-folder modal would then resolve against the
               panel box and clip inside its `overflow: hidden`.

               Put the animation/effect on an INNER wrapper instead.
               """
      end
    end

    test "the ban is real: the same matcher fires on a planted transform" do
      planted = "flex: 1; position: relative; transform: translateZ(0);"

      assert Enum.any?(@containing_block_triggers, fn prop ->
               Regex.match?(~r/(^|[\s;])#{Regex.escape(prop)}\s*:/, planted)
             end),
             "the trigger matcher cannot see a transform — the ban above is vacuous"
    end
  end

  describe "the fixed-position inventory under the panel roots" do
    test "the six .editor-panel roots are exactly the audited set" do
      rendered =
        for path <- studio_sources(),
            {line, idx} <- Enum.with_index(File.read!(path) |> String.split("\n"), 1),
            Regex.match?(~r/class=(\{|")[^\n]*\beditor-panel\b(?!-)/, line),
            do: {Path.relative_to(path, @lib), idx, String.trim(line)}

      found_desc =
        Enum.map_join(Enum.sort(rendered), "\n  ", fn {f, l, t} -> "#{f}:#{l}  #{t}" end)

      assert length(rendered) == length(@panel_roots),
             """
             The number of `.editor-panel` roots moved: #{length(rendered)} rendered,
             #{length(@panel_roots)} audited.

             If a root was ADDED, re-audit its `position: fixed` descendants and
             extend @fixed_css_inventory before adding it to @panel_roots. Found:

               #{found_desc}
             """

      for {file, anchor, description} <- @panel_roots do
        matches =
          Enum.filter(rendered, fn {f, _l, text} ->
            f == file and String.contains?(text, anchor)
          end)

        assert length(matches) == 1,
               """
               The `#{description}` `.editor-panel` root is no longer identifiable.

               Expected exactly one line in #{file} carrying both `editor-panel`
               and the anchor `#{anchor}`; found #{length(matches)}.

               If the root was rewritten, re-audit its `position: fixed`
               descendants (that is what this file exists for) and then update
               the anchor. Found roots:

                 #{found_desc}
               """
      end
    end

    test "exactly three fixed-position selectors render under a panel root" do
      under_panel =
        @fixed_css_inventory
        |> Enum.filter(fn {_sel, placement} -> placement == :under_panel end)
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()

      assert under_panel == MapSet.new([".bp-ae-toast", ".bp-ae-modal", ".sheet-context-menu"])
    end

    test "root.html.heex declares position:fixed for exactly the inventoried selectors" do
      found = fixed_position_selectors(root_css())
      known = MapSet.new(Map.keys(@fixed_css_inventory))

      assert MapSet.difference(found, known) == MapSet.new([]),
             """
             A NEW `position: fixed` selector appeared in root.html.heex:

               #{found |> MapSet.difference(known) |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n  ")}

             Classify it in @fixed_css_inventory. If it renders UNDER an
             `.editor-panel` root, say so — that set is the one the containment
             audit reasons about, and it must stay small enough to hand-verify.
             """

      assert MapSet.difference(known, found) == MapSet.new([]),
             "inventoried selectors no longer declare position: fixed: " <>
               inspect(MapSet.to_list(MapSet.difference(known, found)))
    end

    test "the paper-editor stylesheet declares position:fixed for exactly the inventoried selectors" do
      found = fixed_position_selectors(File.read!(@paper_editor_css))
      known = MapSet.new(Map.keys(@paper_editor_fixed_inventory))

      assert MapSet.difference(found, known) == MapSet.new([]),
             """
             A NEW `position: fixed` selector appeared in
             assets/paper-editor/src/styles.css:

               #{found |> MapSet.difference(known) |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n  ")}

             Classify it in @paper_editor_fixed_inventory. This sheet styles the
             `<bp-paper-editor>` custom element, which mounts INSIDE the
             `studio-paper-editor` `.editor-panel` root — so the answer is
             :under_panel unless you can point at the `document.body.appendChild`
             that portals it out. If it is :under_panel, it also belongs in the
             hand-verified three-set above.
             """

      assert MapSet.difference(known, found) == MapSet.new([]),
             "inventoried paper-editor selectors no longer declare position: fixed: " <>
               inspect(MapSet.to_list(MapSet.difference(known, found)))
    end

    test "the paper-editor census is non-vacuous: a planted selector fails it" do
      css = File.read!(@paper_editor_css)
      known = MapSet.new(Map.keys(@paper_editor_fixed_inventory))

      # Guard 1 — a path typo or an emptied sheet must not read as "all clear".
      # (File.read! already raises on a bad path; this catches a live-but-empty
      # extraction, which is the failure mode that looks green.)
      refute MapSet.size(fixed_position_selectors(css)) == 0,
             "the paper-editor census found zero `position: fixed` selectors in " <>
               "#{@paper_editor_css} — the census above is vacuous"

      # Guard 2 — the same extractor, on the same source plus one synthetic rule,
      # must SEE it. This is the assertion the census makes; if it cannot fire
      # here, it cannot fire on a real new surface either.
      planted = css <> "\n.bp-planted-census-probe {\n  position: fixed;\n  inset: 0;\n}\n"
      found = fixed_position_selectors(planted)

      assert MapSet.member?(found, ".bp-planted-census-probe"),
             "the extractor cannot see a planted `position: fixed` rule in the " <>
               "paper-editor stylesheet — its census certifies nothing"

      assert MapSet.difference(found, known) == MapSet.new([".bp-planted-census-probe"]),
             "the planted rule is the ONLY thing the census should flag as new; got: " <>
               inspect(found |> MapSet.difference(known) |> MapSet.to_list() |> Enum.sort())
    end

    test "the BUILT paper-editor stylesheet censuses to the same fixed set as its source" do
      source = minified_safe_fixed_selectors(File.read!(@paper_editor_css))
      built = minified_safe_fixed_selectors(File.read!(@paper_editor_built_css))

      built_only = MapSet.difference(built, source)
      source_only = MapSet.difference(source, built)

      assert built_only == MapSet.new([]),
             """
             `priv/static/assets/bp-paper-editor.css` declares `position: fixed`
             for a selector its SOURCE does not:

               #{built_only |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n  ")}

             The built sheet is what the page actually links (index.js
             `ensureStyles/0`), and the paper editor mounts INSIDE the
             `studio-paper-editor` `.editor-panel` root — so this is an
             unaudited fixed surface under a panel.

             Either the artifact was hand-edited (it is generated: `cd
             api/assets/paper-editor && npm run build`), or it was built from a
             `styles.css` that was never committed. Fix the SOURCE, rebuild, and
             classify the selector in @paper_editor_fixed_inventory.
             """

      assert source_only == MapSet.new([]),
             """
             The committed build is STALE: `assets/paper-editor/src/styles.css`
             declares `position: fixed` for selectors the built sheet is missing:

               #{source_only |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n  ")}

             Every other guard in this file reads the source, so a stale artifact
             makes them certify a stylesheet nobody is served. Rebuild and commit:
             `cd api/assets/paper-editor && npm run build`.
             """

      # Belt and braces: the built set is the SAME set the source census
      # classifies, so the built sheet is inventoried, not merely self-consistent.
      assert built == MapSet.new(Map.keys(@paper_editor_fixed_inventory))
    end

    test "the built-sheet census is non-vacuous in both directions" do
      source_css = File.read!(@paper_editor_css)
      built_css = File.read!(@paper_editor_built_css)

      # Guard 0 — the minified walker is not a second POLICY. On the authored
      # source it must agree exactly with the line-based census the rest of this
      # file uses; otherwise the equality above compares two different questions.
      assert minified_safe_fixed_selectors(source_css) == fixed_position_selectors(source_css),
             "the minified-safe walker disagrees with the line-based census on " <>
               "the authored source — the built/source equality is comparing " <>
               "two different policies"

      # Guard 1 — the walker actually parses the MINIFIED sheet. A one-line file
      # is exactly where a line-based reader silently returns garbage or nothing.
      refute MapSet.size(minified_safe_fixed_selectors(built_css)) == 0,
             "the built-sheet census found zero `position: fixed` selectors in " <>
               "#{@paper_editor_built_css} — it certifies nothing"

      assert length(String.split(built_css, "\n")) <= 2,
             "the built sheet is no longer minified; the walker still works, but " <>
               "the minification premise in the comments above is now wrong"

      source = minified_safe_fixed_selectors(source_css)
      built = minified_safe_fixed_selectors(built_css)

      # Guard 2 — a built-ONLY selector fails. This is the hand-edit / bad-build
      # direction, and it is the hole the task named. Stated as "the difference
      # grows by exactly the probe" so this control stays exact even while the
      # real artifact is broken (the test above owns that verdict, not this one).
      built_only = MapSet.difference(built, source)
      refute MapSet.member?(built_only, ".bp-planted-built-only")

      planted_built =
        minified_safe_fixed_selectors(
          built_css <> ".bp-planted-built-only{position:fixed;inset:0}"
        )

      assert MapSet.difference(planted_built, source) ==
               MapSet.put(built_only, ".bp-planted-built-only"),
             "a `position: fixed` selector planted in the BUILT sheet alone is " <>
               "not flagged — the equality assertion above is vacuous"

      # Guard 3 — a STALE build fails. Same assertion, other direction: the
      # source grows a selector the artifact was never rebuilt to carry.
      source_only = MapSet.difference(source, built)
      refute MapSet.member?(source_only, ".bp-planted-stale-probe")

      planted_source =
        minified_safe_fixed_selectors(
          source_css <> "\n.bp-planted-stale-probe {\n  position: fixed;\n}\n"
        )

      assert MapSet.difference(planted_source, built) ==
               MapSet.put(source_only, ".bp-planted-stale-probe"),
             "a selector present in the SOURCE but missing from the built sheet " <>
               "is not flagged — a stale build would pass"
    end

    test "the paper-editor stylesheet contributes no unaudited under-panel surface" do
      under_panel =
        @paper_editor_fixed_inventory
        |> Enum.filter(fn {_sel, placement} -> placement == :under_panel end)
        |> Enum.map(&elem(&1, 0))

      assert under_panel == [],
             """
             A paper-editor selector is classified :under_panel: #{inspect(under_panel)}

             That is a real finding, not a test bug — the paper editor mounts
             inside an `.editor-panel` root, so this surface is now subject to any
             containing block the panel grows. Add it to the hand-verified
             under-panel set (the "exactly three" test above) with a rationale,
             then update this expectation. Do not just delete the classification.
             """
    end

    test "server-rendered inline position:fixed appears only in the inventoried files" do
      found =
        for path <- studio_sources(),
            rel = Path.relative_to(path, @lib),
            inline_fixed_count(rel) > 0,
            into: %{},
            do: {rel, inline_fixed_count(rel)}

      assert found == @inline_fixed_inventory,
             """
             The inline `style="position: fixed"` census moved.

             Found:    #{inspect(found, pretty: true)}
             Expected: #{inspect(@inline_fixed_inventory, pretty: true)}

             A new one under an `.editor-panel` root (sheet_grid.ex is the only
             such file today) has to be checked against the carve-out; one
             outside a panel just needs the count updated with a rationale.
             """
    end

    test "every studio JS that emits position:fixed portals to document.body" do
      emitting =
        (@static_js <> "/*.js")
        |> Path.wildcard()
        |> Enum.filter(&Regex.match?(~r/position:\s?fixed/, File.read!(&1)))
        |> Enum.map(&Path.basename/1)
        |> Enum.sort()

      assert emitting == Enum.sort(@portaling_js),
             """
             The set of studio JS files emitting `position: fixed` changed:
             #{inspect(emitting)}

             A script-built floating surface is only safe from ANY containing
             block if it is appended to document.body. Add the file here once
             you have confirmed it portals.
             """

      for name <- @portaling_js do
        src = File.read!(Path.join(@static_js, name))

        assert src =~ "document.body.appendChild" or src =~ "document.body.append(",
               "#{name} emits position: fixed but never portals to document.body"
      end
    end
  end

  describe "the inverse census: no backdrop may be in flow (charter D80)" do
    test "the backdrop-shaped classes emitted by Studio components are exactly the audited set" do
      emitted = emitted_backdrop_classes()
      known = MapSet.new(Map.keys(@backdrop_class_inventory))

      assert MapSet.difference(MapSet.new(Map.keys(emitted)), known) == MapSet.new([]),
             """
             A NEW backdrop-shaped class is emitted by a Studio component:

               #{emitted |> Map.drop(Map.keys(@backdrop_class_inventory)) |> inspect(pretty: true)}

             Classify it in @backdrop_class_inventory — :css_rule if
             root.html.heex positions it, :inline_style if the element carries
             its own `style="position: …"`. An unclassified backdrop is exactly
             the D80 bug: `.modal-backdrop` shipped with NO rule at all and
             became an in-flow flex item of the pane row.
             """

      assert MapSet.difference(known, MapSet.new(Map.keys(emitted))) == MapSet.new([]),
             "inventoried backdrop classes are no longer emitted anywhere: " <>
               inspect(MapSet.to_list(MapSet.difference(known, MapSet.new(Map.keys(emitted)))))
    end

    test "every backdrop-shaped class resolves to a NON-STATIC position" do
      css = root_css()

      for {class, source} <- @backdrop_class_inventory do
        positions =
          case source do
            :css_rule -> positions_for_class(css, class)
            :inline_style -> inline_positions_for_class(class)
          end

        where =
          case source do
            :css_rule -> "a `.#{class} { … }` rule in root.html.heex"
            :inline_style -> ~s(an inline `style="position: …"` on its own element)
          end

        refute MapSet.size(positions) == 0,
               """
               `.#{class}` is classified #{inspect(source)} but declares NO
               `position` in #{where}.

               That is the D80 defect verbatim: an unpositioned backdrop computes
               `position: static; display: block`, and its parent `.pane-layout`
               is a flex container — so the scrim becomes an in-flow COLUMN of
               the pane row and crushes `.editor-panel` onto its 560px floor.
               Give it `position: absolute; inset: 0;` (D52 — absolute, not
               fixed, unless you also inventory it in @fixed_css_inventory).
               """

        refute MapSet.member?(positions, "static"),
               """
               `.#{class}` declares `position: static` in #{where}
               (declared: #{inspect(MapSet.to_list(positions))}).

               A static backdrop is laid out IN FLOW. Inside `.pane-layout`
               that means it competes with `.editor-panel` for row width.
               """
      end
    end

    test "the inverse census is non-vacuous in BOTH directions" do
      css = root_css()

      # Direction 1 — the extractor SEES the real rule. If this cannot fire,
      # the "no static" assertion above certifies nothing.
      assert positions_for_class(css, "modal-backdrop") == MapSet.new(["absolute"]),
             "the extractor cannot read `.modal-backdrop`'s own position out of " <>
               "root.html.heex — the census above is vacuous"

      # Direction 2a — a backdrop whose rule VANISHES is caught. This is the
      # exact shape of the D80 regression: the class stays, the rule does not.
      without_rule =
        Regex.replace(~r/\n\s*\.modal-backdrop\s*\{.*?\n\s*\}/s, css, "\n")

      refute without_rule =~ ".modal-backdrop {",
             "the deliberate break did not actually remove the rule"

      assert positions_for_class(without_rule, "modal-backdrop") == MapSet.new([]),
             "the census reads a position for `.modal-backdrop` even with its " <>
               "rule deleted — it would never catch the D80 regression"

      # Direction 2b — a backdrop that is present but STATIC is caught too. The
      # rule existing is not the invariant; being out of flow is.
      made_static = css <> "\n.modal-backdrop { position: static; }\n"

      assert MapSet.member?(positions_for_class(made_static, "modal-backdrop"), "static"),
             "the census cannot see a `position: static` backdrop — the wrong " <>
               "direction is exactly what @fixed_css_inventory already missed"

      # And the inline path has its own non-vacuity: confirm_modal really does
      # carry a non-static inline position, read from the source, not assumed.
      inline = inline_positions_for_class("bp-modal-overlay")

      assert MapSet.member?(inline, "fixed"),
             "the inline reader cannot see confirm_modal's `position: fixed` — " <>
               "the :inline_style classification is unaudited"

      refute MapSet.member?(inline_positions_for_class("bp-planted-absent-overlay"), "fixed"),
             "the inline reader reports a position for a class that does not exist"
    end
  end

  describe "the cross-engine carve-out" do
    test ".editor-panel.sheet-editor keeps container-type: normal" do
      assert root_css() =~
               ~r/\.editor-panel\.sheet-editor\s*\{\s*container-type:\s*normal;?\s*\}/,
             """
             The Sheets containment carve-out is gone.

             D33's mechanism is measured-FALSE in Blink (see moduledoc), but the
             spec reads the other way and CI has no layout engine, so this rule
             is retained as cross-engine insurance for the ONE server-rendered
             `position: fixed` surface inside a panel. Removing it needs a real
             WebKit + Gecko measurement, not an argument.
             """
    end
  end
end
