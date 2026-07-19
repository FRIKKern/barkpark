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

  This slice READS `root.html.heex`; it never edits it (file-disjoint from spd-s4).
  """
  use ExUnit.Case, async: true

  @moduletag :studio_containment

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)
  @lib Path.expand("../../../lib/barkpark_web", __DIR__)
  @static_js Path.expand("../../../priv/static/assets", __DIR__)

  # The SIX `.editor-panel` roots (charter D42 — D29 listed only five).
  # A seventh root means the inventory below has to be re-audited, so the set is
  # pinned rather than merely counted.
  @panel_roots [
    {"live/studio/studio_live/components.ex", 98, "paper editor"},
    {"live/studio/studio_live/components.ex", 797, "media explorer"},
    {"live/studio/studio_live/components.ex", 861, "beta doc editor"},
    {"components/studio_components/editor.ex", 367, "classic field editor"},
    {"live/studio/graph_view.ex", 113, "graph view"},
    {"live/studio/sheet_grid.ex", 2478, "sheet grid"}
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
    ".profile-modal" => :layout_sibling
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
    "components/confirm_modal.ex" => 1
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

  defp root_css, do: File.read!(@root)

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
            do: {Path.relative_to(path, @lib), idx}

      assert MapSet.new(rendered) ==
               MapSet.new(for {f, l, _} <- @panel_roots, do: {f, l}),
             """
             The set of `.editor-panel` roots moved.

             If a root was ADDED, re-audit its `position: fixed` descendants and
             extend @fixed_css_inventory. If one merely MOVED, update
             @panel_roots. Found:

             #{inspect(Enum.sort(rendered), pretty: true)}
             """
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

  describe "the cross-engine carve-out" do
    test ".editor-panel.sheet-editor keeps container-type: normal" do
      assert root_css() =~ ~r/\.editor-panel\.sheet-editor\s*\{\s*container-type:\s*normal;?\s*\}/,
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
