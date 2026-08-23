defmodule BarkparkWeb.StudioLiveSelectorRatchetTest do
  @moduledoc """
  The strict-selector ratchet for `studio_live_*_test.exs` (spd-b31).

  ## The class this exists to catch

  spd-b31 classified all 43 StudioLive integration tests and found three shapes
  of markup assertion, only one of which is fragile under the change this
  epic keeps making — *inserting a presentation-only attribute* (a `data-role`
  stamp, a `data-width-bucket`, an `aria-current` move, a `div`→`button` swap):

    * (a) BARE TAG-NAME pins — `~s(<bp-paper-canvas)`. An inserted attribute
      lands AFTER the tag name, so these are insertion-proof. Not scanned.
    * (b) SINGLE-ATTRIBUTE-VALUE pins — `~s(class="editor-panel")`. An inserted
      attribute is a sibling, not an edit of this value. Insertion-proof.
      Not scanned.
    * (c) ORDERED-ADJACENCY pins — `~s(<span class="save-status" role="status")`,
      or an attribute PAIR pinned adjacent without its tag. These encode the
      author's *attribute order* into the assertion. ANY attribute appended,
      prepended, or reordered by an unrelated presentation change breaks them —
      and on a `refute`, breaks them SILENTLY, into a false green, because a
      refute that can no longer match is vacuously true.

  Shape (c) is what this file ratchets. Every existing occurrence is enumerated
  in `@allowlist` with the reason it is worth its fragility; a new one is a
  RED that names the file, the line, and the literal.

  ## Why it is a ratchet and not a ban

  Several shape-(c) pins are the *point* of their test: spd-s4's collapsed strip
  must be a `<button type="button">` and not a div (keyboard reachability),
  the save-status span must carry `role="status" aria-live="polite"` adjacent to
  its class (screen-reader announcement contract), the boolean form clause must
  emit hidden-BEFORE-checkbox (Phoenix's unchecked-value protocol). Loosening
  those would delete the accessibility contract they exist to hold. So the rule
  is not "never pin markup" — it is "pin markup **on purpose**, in writing".

  ## Why the allowlist is keyed by LITERAL, never by line

  Line numbers slide the moment anyone inserts a line above them, which would
  turn every unrelated edit into a spurious red and train people to re-baseline
  the file without reading it. The key is `{basename, literal}`; the line number
  appears only in the failure message, where it is a pointer and not a contract.

  ## The rot arm

  A one-directional allowlist rots: an entry whose assertion was deleted or
  loosened stays behind and silently pre-blesses the next author who writes that
  exact literal again. So the check runs BOTH ways — an unmatched allowlist entry
  is as red as an unallowlisted literal.

  ## The vacuity arm

  A scanner whose predicate silently stops matching reports "0 findings" and
  looks like a pass. Three guards make that failure loud instead: the parse of
  every file must succeed (a parse error is a red, never a skipped file), the
  scanned population must be non-empty, and the detector is run against fixed
  positive AND negative control strings so a broken regex reds on its own bench.
  """
  use ExUnit.Case, async: true

  # A tag name followed by whitespace and the start of an attribute: the whole
  # `<tag attr=…` prefix is pinned, so an attribute inserted before `attr` (or a
  # reordering) breaks the match.
  @tag_attr ~r/<[a-zA-Z][a-zA-Z0-9-]*\s+[a-zA-Z]/

  # Two attributes pinned adjacent, with no tag in front. Same fragility without
  # the tag: anything inserted BETWEEN them breaks the match.
  @attr_pair ~r/[a-zA-Z][a-zA-Z0-9-]*="[^"]*"\s+[a-zA-Z][a-zA-Z0-9-]*=/

  # Prose is not a selector: `@moduledoc`/`@doc` bodies quote markup constantly
  # to explain it. They are excluded from the walk, not allowlisted one by one.
  @doc_attrs [:moduledoc, :doc, :shortdoc, :typedoc]

  # Interpolations are erased to a stable placeholder so `~s(<article id="#{id}")`
  # keys identically no matter what the variable is called.
  @interp "\#{}"

  @allowlist [
    # ── studio_live_editor_test.exs — schema-v2 field-type render contract ────
    %{
      file: "studio_live_editor_test.exs",
      literal:
        ~s(<input type="hidden"[^>]*id="bp-rt-hidden-summary"[^>]*name="doc\\[summary\\]"[^>]*phx-debounce="500"),
      reason:
        "richtext field contract: the hidden mirror input must carry BOTH the id the " <>
          "web component writes into and the debounce the autosave depends on. Already " <>
          "insertion-tolerant via [^>]* between every attribute; the pinned adjacency is " <>
          "only `<input type=`."
    },
    %{
      file: "studio_live_editor_test.exs",
      literal: ~s(<input type="hidden" name="doc[featured]" value="false"),
      reason:
        "Phoenix unchecked-value protocol: the hidden false input must precede the " <>
          "checkbox in the byte stream or an unchecked box submits nothing. The test " <>
          "compares :binary.match offsets, so the ORDER is the assertion."
    },
    %{
      file: "studio_live_editor_test.exs",
      literal: ~s(type="checkbox" name="doc[featured]" value="true"),
      reason:
        "the second half of the unchecked-value order proof above — its offset is " <>
          "compared against the hidden input's."
    },
    %{
      file: "studio_live_editor_test.exs",
      literal: ~s(<option value="draft">draft</option>),
      reason:
        "select-option contract for a `string` field with a codelist: the option's value " <>
          "and its label must both be the raw term. No epic work stamps attributes on " <>
          "form <option>s."
    },
    %{
      file: "studio_live_editor_test.exs",
      literal: ~s(<option value="published"[^>]*selected[^>]*>published</option>),
      reason: "the selected-option arm of the same codelist contract; [^>]*-tolerant."
    },
    %{
      file: "studio_live_editor_test.exs",
      literal:
        ~s(<input type="hidden"[^>]*id="bp-ref-hidden-author"[^>]*name="doc\\[author\\]"[^>]*phx-debounce="500"),
      reason: "reference-picker field contract; same shape as the richtext mirror above."
    },
    %{
      file: "studio_live_editor_test.exs",
      literal:
        ~s(<input type="hidden"[^>]*id="bp-mp-hidden-cover"[^>]*name="doc\\[cover\\]"[^>]*phx-debounce="500"),
      reason: "media-picker field contract; same shape as the richtext mirror above."
    },

    # ── studio_live_inspector_ladder_test.exs — subtree slicing ───────────────
    %{
      file: "studio_live_inspector_ladder_test.exs",
      literal: ~s(<aside id="bp-doc-sidebar"),
      reason:
        "not an assertion — a SLICE point. The test splits the render on the destination " <>
          "aside's open tag to prove no phx-keydown was added INSIDE that subtree. " <>
          "A failed split is caught: the following line asserts the slice is non-empty, " <>
          "so this cannot fail open."
    },

    # ── studio_live_new_paper_journey_test.exs — streamed-article identity ────
    %{
      file: "studio_live_new_paper_journey_test.exs",
      literal: ~s|<article id="#{@interp}" data-rev="0">\\s*</article>|,
      reason:
        "the empty-stream-container refute: an <article> that opens and closes with " <>
          "nothing between it is the exact bug shape. The emptiness is the assertion, so " <>
          "the closing tag must be adjacent."
    },
    %{
      file: "studio_live_new_paper_journey_test.exs",
      literal: ~s|<article id="#{@interp}" data-rev="0">|,
      reason:
        "paper-body identity contract: ONE article carries both the streamed id and the " <>
          "revision. data-rev is content, not presentation — a bumped rev must break this."
    },
    %{
      file: "studio_live_new_paper_journey_test.exs",
      literal: ~s|<article id="paper-body-drafts.#{@interp}"|,
      reason:
        "refute that the notice arm does not reuse the streamed arm's container id. " <>
          "Paired: the positive assert of the same <article id= vocabulary stands five " <>
          "lines above, so a vacuated refute is caught by its partner."
    },
    %{
      file: "studio_live_new_paper_journey_test.exs",
      literal: ~s(<span class="badge badge-published">paper</span>),
      reason:
        "the badge must name the document's REAL type. The closing tag is pinned so a " <>
          "badge reading 'paper (draft)' cannot satisfy it — the exact text is the point."
    },
    %{
      file: "studio_live_new_paper_journey_test.exs",
      literal: ~s(<figure><img src="/media/x.png" alt="A scan"></figure>),
      reason:
        "FIXTURE INPUT, not a selector — seeded body_html for the 'visible element with " <>
          "no text' case. Nothing renders it back; it cannot go false-green."
    },
    %{
      file: "studio_live_new_paper_journey_test.exs",
      literal: ~s(<img src="/media/x.png"),
      reason:
        "the legacy-body passthrough proof: the seeded <img> must survive to the render. " <>
          "Pins only `<img src=` — the src IS the identity being traced."
    },
    %{
      file: "studio_live_new_paper_journey_test.exs",
      literal: ~s(<span class="badge badge-published">session</span>),
      reason:
        "the session arm of the same badge contract: the fixture is a `session` doc, so " <>
          "the badge must read `session`. Its sibling refute of the `paper` literal two " <>
          "lines below is what proves the badge is not hardcoded, and a refute is only " <>
          "meaningful while this positive assert stands beside it."
    },

    # ── studio_live_paper_canvas_test.exs — byte-identity slicing ─────────────
    %{
      file: "studio_live_paper_canvas_test.exs",
      literal: ~s|(<div id="paper-editor-#{@interp}".*?</footer>\\s*</div>)|,
      reason:
        "not an assertion — the SLICE that makes the flag-off byte-identity proof stable " <>
          "against unrelated chrome. Regex.run destructures to [_, slice], so a failed " <>
          "slice raises MatchError rather than passing an empty string on."
    },

    # ── studio_live_paper_way_out_test.exs ────────────────────────────────────
    %{
      file: "studio_live_paper_way_out_test.exs",
      literal: ~s|<article id="#{@interp}"[^>]*>\\s*</article>|,
      reason:
        "the empty-container refute for the way-out flow; already [^>]*-tolerant on " <>
          "attributes, and the emptiness between the tags is the whole assertion."
    },

    # ── studio_live_phone_drill_test.exs — accessibility contracts ────────────
    %{
      file: "studio_live_phone_drill_test.exs",
      literal: ~s(<button type="button" class="bp-desk-crumb"),
      reason:
        "ACCESSIBILITY PIN (spd-s4): every clickable crumb must be a real <button>, not a " <>
          "clickable div. Counted against crumb_buttons(html), so an inserted attribute " <>
          "before class= would under-count — but that under-count reds the equality, it " <>
          "does not pass silently."
    },
    %{
      file: "studio_live_phone_drill_test.exs",
      literal: ~s(<button type="button" class="pane-column pane-column--collapsed"),
      reason:
        "ACCESSIBILITY PIN (spd-s4): at narrow width the collapsed strip is the ONLY way " <>
          "back, so it must be a <button> — as a div it is keyboard-unreachable and " <>
          "silent to screen readers. The tag name is the contract."
    },

    # ── studio_live_save_status_test.exs — live-region contract ───────────────
    %{
      file: "studio_live_save_status_test.exs",
      literal: ~s(class="save-status" role="status" aria-live="polite">Saved),
      reason:
        "ACCESSIBILITY PIN: 'Saved' must be announced, so role/aria-live must sit on the " <>
          "SAME element as the text. Adjacency is what proves same-element; a selector " <>
          "that checked the three parts separately would pass on three different nodes."
    },
    %{
      file: "studio_live_save_status_test.exs",
      literal: ~s(class="save-status" role="status" aria-live="polite"><),
      reason:
        "the reset arm of the same live-region contract: after a push_patch the region " <>
          "must be EMPTY, which only an immediately-following `<` can express."
    },
    %{
      file: "studio_live_save_status_test.exs",
      literal: ~s(<span class="save-status" role="status" aria-live="polite">Saved),
      reason:
        "the same live-region contract with the tag pinned — the region must be a <span> " <>
          "inline in the header, not a block that reflows the toolbar."
    },

    # ── studio_live_sheet_grid_test.exs ───────────────────────────────────────
    %{
      file: "studio_live_sheet_grid_test.exs",
      literal: ~s(<a class="sheet-cell-v sheet-link"),
      reason:
        "KNOWN RESIDUAL RISK, recorded rather than blessed (spd-b31 criterion 1): this " <>
          "refute has NO paired positive assert of the same vocabulary anywhere in the " <>
          "tree, so an attribute inserted before class= in sheet_grid.ex would vacuate it " <>
          "into a false green. Kept because the behaviour it guards (editable mode must " <>
          "not wrap the cell in an anchor) is real; the fix is a one-line paired positive " <>
          "assert and belongs to the next builder in this file."
    },
    %{
      file: "studio_live_sheet_grid_test.exs",
      literal: ~s(<span class="sheet-cell-v" role="checkbox" aria-checked="false"),
      reason:
        "ACCESSIBILITY PIN: role and aria-checked must be on the SAME cell span as the " <>
          "value, which only adjacency proves. Paired with separate positive asserts of " <>
          "role=\"checkbox\" and aria-checked=\"false\" two lines above."
    },
    %{
      file: "studio_live_sheet_grid_test.exs",
      literal: ~s(data-ref="A2" data-r="2" data-c="1" data-v="first"),
      reason:
        "row-insert coordinate contract: the point is that ONE cell carries the shifted " <>
          "ref, row, column and value together. Split across four asserts it would pass " <>
          "on four different cells, which is the bug."
    },

    # ── studio_live_task_editor_test.exs ──────────────────────────────────────
    %{
      file: "studio_live_task_editor_test.exs",
      literal: ~s|<option value="#{@interp}"|,
      reason:
        "every lifecycle_status must render as a selectable option; pins only " <>
          "`<option value=` and no epic work stamps attributes on form <option>s."
    },
    %{
      file: "studio_live_task_editor_test.exs",
      literal: ~s(<option value="in_progress"[^>]*selected),
      reason: "the selected-option arm of the same lifecycle contract; [^>]*-tolerant."
    }
  ]

  # The detector's own bench. The two patterns are benched SEPARATELY and with
  # cases only one of them can catch, because a shared bench hides a half-dead
  # detector: neutering @tag_attr alone left every overlapping control still
  # matching through @attr_pair, and the bench stayed green while the scan had
  # lost a whole shape. Each control below is chosen so exactly one pattern
  # claims it.
  @tag_attr_only_controls [
    # one attribute after the tag — too few for an attribute PAIR to see
    ~s(<img src="/media/x.png"),
    ~s(<article id="paper-body">),
    ~s(<a class="sheet-link")
  ]
  @attr_pair_only_controls [
    # no tag in front — @tag_attr has nothing to anchor on
    ~s(class="save-status" role="status"),
    ~s(data-ref="A2" data-r="2")
  ]
  @negative_controls [
    ~s(<bp-paper-canvas),
    ~s(class="editor-panel"),
    ~s(data-test-id="studio-paper-block-editor"),
    "editor-field",
    ~s(<article>)
  ]

  defp studio_dir, do: __DIR__

  # This file matches its own glob, and its @allowlist quotes every literal it
  # blesses — scanning itself would report each one as a fresh finding in a file
  # that is not a StudioLive test at all. Excluded by name, not by heuristic.
  @self_basename "studio_live_selector_ratchet_test.exs"

  defp test_files do
    studio_dir()
    |> Path.join("studio_live_*_test.exs")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == @self_basename))
    |> Enum.sort()
  end

  defp brittle?(s), do: Regex.match?(@tag_attr, s) or Regex.match?(@attr_pair, s)

  # Every string literal in the module body, with the line it sits on, minus
  # documentation prose. Interpolated segments collapse to a stable placeholder.
  defp literals(path) do
    src = File.read!(path)

    ast =
      case Code.string_to_quoted(src) do
        {:ok, ast} ->
          ast

        {:error, err} ->
          flunk("""
          #{Path.basename(path)} did not parse, so it was NOT scanned.

          A file this ratchet cannot read is a hole in the ratchet, not a pass.
          #{inspect(err)}
          """)
      end

    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{doc, _, _}]}, acc when doc in @doc_attrs ->
          {nil, acc}

        {:<<>>, meta, parts}, acc ->
          joined =
            Enum.map_join(parts, fn
              b when is_binary(b) -> b
              _ -> @interp
            end)

          {nil, [{Keyword.get(meta, :line), joined} | acc]}

        b, acc when is_binary(b) ->
          {nil, [{nil, b} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp findings do
    for path <- test_files(),
        {line, literal} <- literals(path),
        brittle?(literal),
        do: %{file: Path.basename(path), line: line, literal: literal}
  end

  defp allowed_keys,
    do: MapSet.new(@allowlist, fn e -> {e.file, e.literal} end)

  test "the detector still detects — positive and negative controls" do
    for s <- @tag_attr_only_controls do
      assert Regex.match?(@tag_attr, s),
             "the TAG-with-attribute pattern stopped matching #{inspect(s)}, and no other " <>
               "pattern covers this shape. A ratchet that matches nothing passes everything."

      refute Regex.match?(@attr_pair, s),
             "#{inspect(s)} is no longer a @tag_attr-ONLY control — @attr_pair now claims " <>
               "it too, so it can no longer prove @tag_attr is alive. Pick a control with " <>
               "fewer attributes."
    end

    for s <- @attr_pair_only_controls do
      assert Regex.match?(@attr_pair, s),
             "the attribute-PAIR pattern stopped matching #{inspect(s)}, and no other " <>
               "pattern covers this shape (it has no tag to anchor on)."

      refute Regex.match?(@tag_attr, s),
             "#{inspect(s)} is no longer an @attr_pair-ONLY control — drop the tag from it."
    end

    for s <- @negative_controls do
      refute brittle?(s),
             "the detector widened onto #{inspect(s)}, which is an insertion-PROOF pin " <>
               "(bare tag name, or a single attribute value). Widening it here turns the " <>
               "ratchet into noise and trains people to re-baseline without reading."
    end
  end

  test "the scanned population is the whole StudioLive suite, and it is not empty" do
    files = test_files()

    assert length(files) >= 43,
           "only #{length(files)} studio_live_*_test.exs files were scanned; spd-b31 " <>
             "counted 43 on origin/main. A shrinking population means the glob, the " <>
             "directory layout, or the naming convention moved and the ratchet is " <>
             "guarding a smaller surface than it claims."

    # Parsing is where a file can silently drop out; force it for all of them.
    for path <- files, do: literals(path)
  end

  test "no studio_live test pins ordered attribute adjacency without a written reason" do
    allowed = allowed_keys()

    new =
      Enum.reject(findings(), fn f -> MapSet.member?(allowed, {f.file, f.literal}) end)

    assert new == [], """
    #{length(new)} NEW ordered-adjacency markup pin(s) in the StudioLive suite:

    #{Enum.map_join(new, "\n", fn f -> "  #{f.file}:#{f.line}\n      #{inspect(f.literal)}" end)}

    Each of these encodes attribute ORDER into an assertion. The next unrelated
    presentation-only attribute — a data-role stamp, a width bucket, an
    aria-current move — breaks it; and if it is a `refute`, it breaks it into a
    SILENT FALSE GREEN, because a refute that can no longer match is vacuously
    true.

    Two ways forward:

      1. Assert BEHAVIOUR instead. Prefer `has_element?(view, selector)` or
         `element(view, selector)` with a data-role / id / aria hook, or pin a
         single attribute value (`~s(class="editor-panel")`) or a bare tag name
         (`~s(<bp-paper-canvas)`) — both are insertion-proof and neither is
         flagged here. If the point is that two attributes sit on the SAME
         element, `[^>]*` between them keeps that meaning and survives insertion.

      2. Keep it and say why. If the adjacency IS the contract — a live region
         whose role must sit on the element carrying the text, a hidden input
         that must precede its checkbox, a strip that must be a <button> — add
         an entry to @allowlist in #{Path.relative_to_cwd(__ENV__.file)} with
         %{file:, literal:, reason:} and write the reason for a reader who has
         never seen the test. "intentional" is not a reason.
    """
  end

  test "no allowlist entry outlives the assertion it blesses" do
    present = MapSet.new(findings(), fn f -> {f.file, f.literal} end)

    stale = Enum.reject(@allowlist, fn e -> MapSet.member?(present, {e.file, e.literal}) end)

    assert stale == [], """
    #{length(stale)} allowlist entr(ies) no longer match anything in the suite:

    #{Enum.map_join(stale, "\n", fn e -> "  #{e.file}\n      #{inspect(e.literal)}" end)}

    The assertion was deleted, loosened, or edited — good. Delete the entry too.
    A stale entry is not harmless: it silently pre-blesses the next author who
    writes that exact literal again, which is precisely the review this file
    exists to force.
    """
  end

  test "every allowlist entry carries a reason a reader can act on" do
    thin =
      Enum.filter(@allowlist, fn e ->
        String.length(e.reason) < 40 or
          String.downcase(e.reason) in ["intentional", "intentional pin", "contract", "needed"]
      end)

    assert thin == [], """
    #{length(thin)} allowlist entr(ies) carry a reason that explains nothing:

    #{Enum.map_join(thin, "\n", fn e -> "  #{e.file}: #{inspect(e.reason)}" end)}

    The reason is the only thing separating this allowlist from a mute
    suppression file. Name the contract the adjacency holds and why a looser
    selector would lose it.
    """
  end
end
