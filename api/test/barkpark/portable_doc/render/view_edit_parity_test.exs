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

  Intentional, documented divergences (View-only list bottom-margin) are
  encoded as guarded invariants below, so ADDING them to Edit trips the wire and
  forces a conscious decision rather than silent double-spacing.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Stylesheet

  # The block elements that both surfaces style and that must stay in lock-step.
  # (`ul`/`ol` are handled separately — they carry an intentional divergence.)
  @parity_elements ~w(h1 h2 h3 p li code img)

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
      html = Render.render_block(%{"type" => "heading", "level" => level, "text" => "X"}, %{style: :article})
      assert html =~ ~r/^<h#{level}>/, "heading level #{level} must open a bare <h#{level}>, got: #{html}"
      refute html =~ ~r/<h#{level}[^>]*\sstyle=/, "heading level #{level} must carry NO inline style, got: #{html}"
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

  # ── 2. Cross-surface CSS parity — the drift tripwire ───────────────────────

  test "every shared (element, property) has byte-identical values across View and Edit" do
    edit = edit_css()
    view = view_css()

    mismatches =
      for element <- @parity_elements,
          view_decls = declarations_for(view, "bp-paper-surface", element),
          edit_decls = declarations_for(edit, "bp-paper-editor-body", element),
          prop <- Map.keys(view_decls),
          Map.has_key?(edit_decls, prop),
          view_decls[prop] != edit_decls[prop] do
        "#{element}.#{prop}: View=#{inspect(view_decls[prop])} Edit=#{inspect(edit_decls[prop])}"
      end

    assert mismatches == [],
           """
           View↔Edit typography drift detected — a property was changed on one
           surface but not the other. Align the EDIT rule (root.html.heex
           .bp-paper-editor-body) to the published VIEW value (paper-surface.css
           .bp-paper-surface), per charter D6, OR route both through the same
           --bp-* token. Divergences:

           #{Enum.join(mismatches, "\n")}
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
      shared = MapSet.intersection(MapSet.new(Map.keys(view_decls)), MapSet.new(Map.keys(edit_decls)))

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
  # those two hand-kept copies. Same contract as §2: every shared
  # (element, property) pair must be byte-identical. Properties one side
  # declares and the other doesn't are allowed — the bundle base rule carries
  # standalone-host extras (background/font on the wrapper, a plain `pre` rule)
  # that Studio inherits from `.bp-paper-surface` instead.
  @mirror_elements ~w(h1 h2 h3 p li ul ol code img blockquote hr pre.bp-canvas-code)

  test "Studio inline editor rules and the bundle stylesheet stay byte-aligned" do
    studio = edit_css()
    bundle = bundle_css()

    mismatches =
      for element <- @mirror_elements,
          studio_decls = declarations_for(studio, "bp-paper-editor-body", element),
          bundle_decls = declarations_for(bundle, "bp-paper-editor-body", element),
          prop <- Map.keys(studio_decls),
          Map.has_key?(bundle_decls, prop),
          studio_decls[prop] != bundle_decls[prop] do
        "#{element}.#{prop}: Studio=#{inspect(studio_decls[prop])} Bundle=#{inspect(bundle_decls[prop])}"
      end

    assert mismatches == [],
           """
           Studio↔bundle editor-typography drift — the root.html.heex inline
           mirror and assets/paper-editor/src/styles.css disagree, so the
           embedded editor no longer looks like the Studio canvas. Align the
           copies (and rebuild the bundle if styles.css changed — see the
           wave-1 mechanics note in the pd-doctrine charter). Divergences:

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
        MapSet.intersection(MapSet.new(Map.keys(studio_decls)), MapSet.new(Map.keys(bundle_decls)))

      assert MapSet.size(shared) > 0,
             "no shared property found for <#{element}> — a selector rename likely broke the mirror parser"
    end
  end
end
