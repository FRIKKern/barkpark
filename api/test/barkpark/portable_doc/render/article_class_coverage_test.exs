defmodule Barkpark.PortableDoc.Render.ArticleClassCoverageTest do
  # Pure, in-process render — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.ParityFixture
  alias Barkpark.PortableDoc.Render.Stylesheet

  # ── the Stage-2 article CLASS-COVERAGE tripwire (Wave 2) ─────────────────────
  #
  # Wave 2 moves `:article` THEME styling (text roles, callout tones, chrome)
  # out of inline `style=` attributes and onto `bp-*` CSS CLASSES driven by the
  # single canonical paper-surface stylesheet (charter Decisions 2/3/4). That is
  # what makes View and Edit "identical by construction": both render the same
  # selectors resolving the same tokens.
  #
  # The failure mode THIS test guards is the one no other test catches: a class
  # emitted with NO rule behind it — a typo'd selector, or a walk.ex change that
  # forgot the matching addition to `paper-surface.css`. The inline-allowlist
  # ratchet only sees `style=` attributes; a class token that resolves to
  # nothing renders as UNSTYLED text and slips past every existing guard.
  #
  # Contract: every class token in the `:article` render of the all-kinds
  # ParityFixture must EITHER
  #
  #   • appear as a class selector (`.<token>`) in `Stylesheet.css()` — the class
  #     "moved to a class" actually resolves to a canonical rule; OR
  #   • sit on the @layout_hooks allowlist below — a class that is DELIBERATELY
  #     not in the canonical stylesheet (styled by a hosting layout, or a pure
  #     JS/content hook), each with a one-line justification.
  #
  # CRITICAL — this is MEMBERSHIP-ONLY (emitted ⊆ styled ∪ hooks), NOT exact-set.
  # The sibling walk.ex slice in this wave adds MANY new class+rule pairs; every
  # one of them lands in `styled` and stays green here WITHOUT editing this file.
  # There is deliberately NO "dead-hook" / exact-equality check — that belongs to
  # `article_inline_allowlist_test.exs` (whose ratchet IS shrink-only); adding it
  # here would fight the walk.ex slice. A @layout_hooks entry that later gains a
  # real rule simply becomes redundant-but-harmless (it is in the union either
  # way); dedup it opportunistically, never on a red build here.
  #
  # SCOPE (stated honestly): the scan sees what the ParityFixture's WALK clauses
  # emit. Classes minted at COMPOSE time inside `_raw` HTML (figures.ex
  # `bp-asciicast`, forms.ex `bp-form`/`bp-form-question`) are NOT covered — the
  # fixture cannot grow them without breaking the email golden's byte-lock. They
  # are content-layer markup like `mermaid`, not walk.ex theme emission, so the
  # wave-2 class migration this test guards never touches them.

  # Class tokens the `:article` render emits that are, BY DESIGN, absent from the
  # canonical stylesheet. Seeded from TODAY'S real `:article` inventory of the
  # fixture (only what actually appears is listed). The value is the one-line
  # justification — machine-checked non-empty by a test below.
  @layout_hooks %{
    # Derived sheet default-alignment classes. NOT inline on purpose: the
    # sheets-parity suite pins the inline b/i/bg/al styles identical across
    # surfaces, so the DERIVED default must never reach the style attribute. The
    # `td.sheet-al-*` rules live in the hosting layouts (root.html.heex for the
    # Studio paper view, bulldocs.html.heex for /papers); stylesheet-less
    # surfaces degrade to the table's left. See walk.ex sheet_default_align_attr.
    "sheet-al-center" =>
      "styled by hosting layout td.sheet-al-* rules (walk.ex sheet_default_align_attr)",
    "sheet-al-right" =>
      "styled by hosting layout td.sheet-al-* rules (walk.ex sheet_default_align_attr)",

    # The embed frame is an inline-styled <section> (walk.ex embed clause): the
    # embedded body renders on export/email/Studio alike and can't rely on an
    # external `.paper-embed` stylesheet, so the frame carries its own inline
    # styles; the class is a JS/styling hook, not a canonical theme rule.
    "paper-embed" =>
      "inline-styled embed frame; class is a JS/styling hook (walk.ex embed clause)",
    "paper-embed--unresolved" =>
      "inline-styled unresolved-embed frame; JS/styling hook (walk.ex embed clause)",

    # Verbatim `_raw` passthrough — the Mermaid engine selects on `pre.mermaid`,
    # so the class must reach the DOM byte-exact from author/compose HTML. It is
    # content/JS-engine markup, never a paper-surface theme class (walk.ex _raw).
    "mermaid" =>
      "verbatim _raw passthrough; Mermaid engine selects pre.mermaid (walk.ex _raw clause)",

    # Graceful-degrade wrapper for an unknown/forward-compat PdNode kind (walk.ex
    # degrade clause). It is a fallback marker rendered as plain text, not themed
    # chrome; no canonical rule is wanted.
    "bp-unknown-block" =>
      "degrade wrapper for unknown PdNode kinds; plain-text fallback marker (walk.ex degrade clause)",

    # Studio-only accept-baseline button on a DRIFTED valueref, emitted ONLY when
    # the palette opts in via `:valueref_accept` (Studio's per-request paper view;
    # never the body_html cache, delta frames, or the public reader — walk.ex
    # valueref_accept_control). Styled by the Studio hosting layout
    # (root.html.heex `.bp-paper-surface button.bp-valueref-accept`), so it is a
    # layout hook by construction, not a canonical theme class.
    "bp-valueref-accept" =>
      "Studio-only drift accept control (palette-gated :valueref_accept); styled by root.html.heex (walk.ex valueref_accept_control)"
  }

  describe ":article class-coverage tripwire" do
    test "every emitted class token resolves to a canonical rule or a documented layout hook" do
      emitted = emitted_class_tokens()

      # Non-vacuous scan: a render that emitted no class at all would make the
      # membership check pass trivially. Fail loud instead.
      assert MapSet.size(emitted) > 0, """
      No class="…" attribute found in the :article render — the coverage scan is
      vacuous. Either the fixture no longer exercises class-bearing nodes or the
      render regressed. Investigate before trusting a green here.
      """

      css = stripped_css()

      unresolved =
        emitted
        |> Enum.reject(fn token -> Map.has_key?(@layout_hooks, token) or styled?(css, token) end)
        |> Enum.sort()

      assert unresolved == [], """
      :article emitted #{length(unresolved)} class token(s) with NO canonical
      rule and NO layout-hook justification:

        #{Enum.join(unresolved, ", ")}

      A class that resolves to nothing renders as unstyled text. Fix one of:
        • add the rule to api/assets/paper-surface/paper-surface.css (so View and
          Edit resolve the same selector by construction), or
        • if this class is styled by a hosting layout or is a pure JS/content
          hook, add it to @layout_hooks with a one-line justification.
      """
    end

    test "the fixture actually exercises the article palette (guards a mis-wired render)" do
      html = render()

      # Article-only signals in the FRAGMENT: the 680px article width budget
      # (email uses 600) and a `bp-role-*` class (email inlines these roles, only
      # :article emits the class). Wave 2 moved the serif font to the canonical
      # stylesheet, so it no longer rides the fragment — width + role class are
      # the fragment-level article signals now. If the render silently fell back
      # to :email both vanish — a mis-wired palette must not vacuously pass.
      assert html =~ "max-width:680px"
      assert html =~ "bp-role-eyebrow"
      assert MapSet.size(emitted_class_tokens()) > 0
    end

    test "every @layout_hooks entry carries a non-empty justification" do
      for {class, why} <- @layout_hooks do
        assert is_binary(why) and String.trim(why) != "",
               "@layout_hooks entry #{inspect(class)} needs a one-line justification comment/value"
      end
    end
  end

  # The scan renders the SUPERSET :article emission: `valueref_accept: true`
  # additionally lights up the palette-gated Studio drift-accept button (the
  # fixture carries a drifted valueref, fallback "40" vs canonical "42"), which
  # the plain fixture opts would silently leave unscanned. Sibling rails render
  # WITHOUT the opt, so this widening cannot perturb their inventories.
  defp render do
    opts = ParityFixture.render_opts(:article) |> Map.put(:valueref_accept, true)
    Render.render_html(ParityFixture.tree(), opts)
  end

  # Every class token appearing in a `class="…"` attribute of the :article
  # render. Attribute values are escaped (`"` → `&quot;`), so `[^"]*` captures
  # the whole attribute body exactly; whitespace splits multi-class attributes.
  # The lookbehind keeps a future `data-class="…"`-style attribute from leaking
  # foreign tokens into the scan (a false alarm, since only real class attrs
  # carry the membership contract).
  defp emitted_class_tokens do
    ~r/(?<![\w-])class="([^"]*)"/
    |> Regex.scan(render())
    |> Enum.flat_map(fn [_, body] -> String.split(body, ~r/\s+/, trim: true) end)
    |> MapSet.new()
  end

  # The canonical stylesheet with CSS comments removed, so a token mentioned only
  # inside a `/* … */` comment is not mistaken for a real rule.
  defp stripped_css do
    Regex.replace(~r|/\*.*?\*/|s, Stylesheet.css(), "")
  end

  # True when `token` appears as its own class selector `.token` in the CSS. The
  # trailing lookahead stops a prefix match: token `bp-callout` is NOT satisfied
  # by a `.bp-callout--info` rule (the `-` after it is an identifier char).
  defp styled?(css, token) do
    Regex.match?(~r/\.#{Regex.escape(token)}(?![\w-])/, css)
  end
end
