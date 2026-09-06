defmodule BarkparkWeb.Studio.InspectorPaintRulePredicatePinTest do
  @moduledoc """
  spd-b41 — the inspector's painted-closed CSS rule and the control's
  announcement, coupled by an executable pin instead of a comment.

  ## The gap this closes

  Three places encode the same predicate, "is the inspector PAINTED open right
  now?":

    1. `root.html.heex` — `html:not([data-width-bucket="wide"])
       .bp-doc-sidebar.is-open:not([data-user-opened])` — what actually PAINTS
       the open-but-never-asked-for panel as the collapsed strip.
    2. `components.ex` — `visually_open? = panel_open && (width_bucket ==
       "wide" || user_opened)` — what the collapse control ANNOUNCES via
       `aria-expanded`.
    3. `handlers/paper.ex` — `painted_closed?` — what a press DOES.

  2↔3 is already pinned across all sixteen (bucket × panel_open × user_opened)
  states by `paper_canvas_test.exs` (spd-b29f review). 1↔2 was pinned by
  NOTHING: both Elixir copies treat every non-`wide` bucket as painted-closed
  only because the cascade says so. If a future bucket ever DOCKS the inspector
  instead of overlaying it, the CSS moves, both predicates keep announcing
  "closed" over a panel the reader can plainly see — and the a11y lie that
  \#4633 and spd-b29f each landed to fix returns a third time.

  ## The idiom: BOTH sides derived, NEITHER retyped

  This file hardcodes no bucket set. It reads the painted-closed selector out
  of the shipped stylesheet at RUN time (not compile time — a mutation to
  `root.html.heex` alone must be able to red it), evaluates that selector
  against the bucket universe read out of the head script that stamps it, and
  compares the result with the set the Elixir predicate announces — obtained by
  RENDERING the real component once per bucket and reading `aria-expanded` off
  the real control. Neither expectation is a constant copied beside its
  subject, so the two can only agree by actually agreeing.

  ## A guard that cannot see is theatre

  Every derivation step flunks loudly rather than degrading to a vacuous pass:
  a missing/duplicated selector, an unreadable bucket universe, an empty
  derived CSS set, and a control whose `aria-expanded` is neither `"true"` nor
  `"false"` each fail with the reason named.

  On divergence the failure is a bucket-set diff (`only-in-CSS` /
  `only-in-Elixir`), never a generic source-text mismatch: the message names
  the bucket that moved and which side moved it.

  ## Mutation-proven, both directions (spd-b41 criterion 2)

    * CSS side — `html:not([data-width-bucket="wide"])` →
      `...:not([data-width-bucket="standard"])` (one more bucket excluded):
      RED, naming `standard` as only-in-Elixir. Reverted: GREEN.
    * Elixir side — `visually_open?` extended to treat `"standard"` as open:
      RED, naming `standard` as only-in-CSS. Reverted: GREEN.
  """
  use Barkpark.DataCase, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Components

  @root_heex Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  # The one rule that paints an open-but-never-asked-for inspector as the
  # collapsed strip: anchored at `html`, and terminating at the panel itself
  # (the title/body suppressors and the scrim guard carry a further descendant
  # or a `::after`, so they cannot match this shape).
  @paint_rule ~r/(?m)^\s*(html[^{};]*\.bp-doc-sidebar\.is-open:not\(\[data-user-opened\]\))\s*\{/

  # spd-s1's pre-paint stamp is the authority on WHICH buckets exist:
  #   var NAMES = ["phone", "narrow", "standard", "wide"];
  @bucket_universe ~r/var NAMES = \[([^\]]*)\];/

  defp stylesheet, do: File.read!(@root_heex)

  # ── the CSS side ─────────────────────────────────────────────────────────

  defp bucket_universe(css) do
    names =
      case Regex.run(@bucket_universe, css) do
        [_, list] -> Regex.scan(~r/"([a-z-]+)"/, list) |> Enum.map(fn [_, n] -> n end)
        nil -> flunk("width-bucket universe not found in #{@root_heex} (`var NAMES = [...]`)")
      end

    if length(names) < 2 do
      flunk("width-bucket universe degenerate (#{inspect(names)}) — this pin cannot see")
    end

    names
  end

  defp paint_selector(css) do
    case Regex.scan(@paint_rule, css) do
      [[_, selector]] ->
        String.trim(selector)

      [] ->
        flunk("""
        the inspector's painted-closed rule was not found in #{@root_heex}.

        Expected exactly one rule of the shape
          html<…> .bp-doc-sidebar.is-open:not([data-user-opened]) { … }

        If the rule was deliberately reshaped, this pin must be reshaped with
        it — do not delete it: it is the only executable link between what
        paints and what the control announces.
        """)

      many ->
        flunk("""
        #{length(many)} candidate painted-closed rules in #{@root_heex}; this pin
        needs exactly one authority:

        #{many |> Enum.map(fn [_, s] -> "  " <> String.trim(s) end) |> Enum.join("\n")}
        """)
    end
  end

  # The `html` compound of the selector — everything before the descendant
  # combinator that introduces `.bp-doc-sidebar`.
  defp html_compound(selector), do: selector |> String.split(~r/\s+/, parts: 2) |> hd()

  # Which buckets does this compound MATCH, given `<html data-width-bucket=…>`?
  # `:not([data-width-bucket="x"])` excludes x; a bare `[data-width-bucket="x"]`
  # requires x. Anything else in the compound is bucket-agnostic.
  defp buckets_matched(compound, universe) do
    negatives =
      ~r/:not\(\[data-width-bucket="([^"]+)"\]\)/
      |> Regex.scan(compound)
      |> Enum.map(fn [_, b] -> b end)

    positives =
      compound
      |> String.replace(~r/:not\([^)]*\)/, "")
      |> then(&Regex.scan(~r/\[data-width-bucket="([^"]+)"\]/, &1))
      |> Enum.map(fn [_, b] -> b end)
      |> Enum.uniq()

    Enum.filter(universe, fn bucket ->
      bucket not in negatives and (positives == [] or positives == [bucket])
    end)
  end

  defp css_paints_closed_for(css) do
    universe = bucket_universe(css)
    selector = paint_selector(css)
    matched = buckets_matched(html_compound(selector), universe)

    if matched == [] do
      flunk("""
      the painted-closed rule matches NO width bucket — this pin would compare
      an empty set against the Elixir predicate and pass vacuously.

        selector: #{selector}
        universe: #{inspect(universe)}
      """)
    end

    {universe, selector, matched}
  end

  # ── the Elixir side ──────────────────────────────────────────────────────

  @paper %{
    content: %{"blocks" => []},
    status: "published",
    doc_id: "b41-paint-rule-pin",
    title: "b41 paint-rule pin"
  }

  # What the SHIPPED control announces for this bucket, read off the rendered
  # `aria-expanded` — never a re-typed copy of `visually_open?`. `panel_open:
  # true, user_opened: false` is precisely the state the CSS rule selects: the
  # server opened the panel and the user never asked.
  defp announces_closed?(bucket) do
    html =
      render_component(&Components.paper_metadata_sidebar/1,
        paper_doc: @paper,
        dataset: "production",
        panel_open: true,
        user_opened: false,
        width_bucket: bucket
      )

    announced =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(button#bp-doc-sidebar-toggle))
      |> LazyHTML.attribute("aria-expanded")

    case announced do
      ["true"] ->
        false

      ["false"] ->
        true

      other ->
        flunk("""
        the inspector collapse control did not announce a readable state for
        bucket #{inspect(bucket)} — aria-expanded was #{inspect(other)}.

        This pin reads the announcement off `button#bp-doc-sidebar-toggle`; if
        the control moved, move the reader with it rather than deleting it.
        """)
    end
  end

  defp elixir_announces_closed_for(universe), do: Enum.filter(universe, &announces_closed?/1)

  # ── the pin ──────────────────────────────────────────────────────────────

  describe "the painted-closed CSS predicate and the announced one are the same set" do
    test "every bucket the cascade paints closed is a bucket the control announces closed" do
      css = stylesheet()
      {universe, selector, painted} = css_paints_closed_for(css)
      announced = elixir_announces_closed_for(universe)

      assert painted == announced, """
      THE CASCADE AND THE ANNOUNCEMENT DISAGREE ABOUT WHICH BUCKETS PAINT THE
      INSPECTOR CLOSED. One of them is now lying to a reader who can see the
      panel (or cannot).

        width-bucket universe:       #{inspect(universe)}
        CSS paints closed for:       #{inspect(painted)}
        Elixir announces closed for: #{inspect(announced)}

        only-in-CSS   (painted closed, announced OPEN):   #{inspect(painted -- announced)}
        only-in-Elixir (announced closed, painted OPEN):  #{inspect(announced -- painted)}

      CSS rule read from #{@root_heex}:
        #{selector}

      Elixir side: `visually_open?` in
      lib/barkpark_web/live/studio/studio_live/components.ex, read through the
      rendered `aria-expanded` on `#bp-doc-sidebar-toggle` with
      panel_open: true, user_opened: false.

      A bucket in only-in-CSS is the \#4633 / spd-b29f accessibility lie
      returning: the panel paints as a 41px strip while its control announces
      expanded. A bucket in only-in-Elixir is the mirror lie: a visibly open
      panel whose control announces collapsed. Move BOTH sides, or neither.
      """
    end

    test "the suppressor and scrim rules keep the SAME bucket predicate as the paint rule" do
      css = stylesheet()
      {universe, _selector, painted} = css_paints_closed_for(css)

      # Every other rule keyed on the same open-but-never-asked state must
      # select the same buckets; a partial move (geometry rule updated, scrim
      # guard forgotten) is the drift this catches.
      siblings =
        ~r/(?m)^\s*(html[^{};]*\.bp-doc-sidebar\.is-open:not\(\[data-user-opened\]\)[^{};]*)\{/
        |> Regex.scan(css)
        |> Enum.map(fn [_, s] -> s |> String.replace(~r/\s+/, " ") |> String.trim() end)

      assert length(siblings) >= 1,
             "no rules keyed on `.bp-doc-sidebar.is-open:not([data-user-opened])` found — this pin cannot see"

      # A selector list may carry several comma-separated selectors; each one
      # anchored at `html` is checked on its own compound.
      anchored =
        siblings
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "html"))

      assert anchored != [],
             "no `html`-anchored open-but-never-asked rules found — this pin cannot see"

      for one <- anchored do
        assert buckets_matched(html_compound(one), universe) == painted, """
          a rule for the open-but-never-asked-for inspector selects a DIFFERENT
          bucket set than the paint rule — the cascade now disagrees with itself.

            paint rule selects: #{inspect(painted)}
            this rule selects:  #{inspect(buckets_matched(html_compound(one), universe))}
            only in paint rule: #{inspect(painted -- buckets_matched(html_compound(one), universe))}
            only in this rule:  #{inspect(buckets_matched(html_compound(one), universe) -- painted)}

            #{one}
        """
      end
    end
  end
end
