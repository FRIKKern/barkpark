defmodule BarkparkWeb.Studio.StudioLiveInspectorLadderTest do
  @moduledoc """
  spd-b39 — the Tier-2 ladder where it actually renders (charter D148/D151/D152).

  `pane_builder_inspector_test.exs` pins the pure table. This file pins the
  two things a pure table structurally cannot:

  1. THE WIRING HOLE (D152). `sidebar_user_opened` used to be seeded ONLY by
     `sidebar_assigns/1` in `shared/paper.ex`, reached only from
     `setup_paper_view`. `mount.ex` seeded `width_bucket` and no sidebar
     assign, so the key was measurably ABSENT on a fresh mount for the desk
     root, a type list, the field form, the sheet grid and the graph pane —
     PRESENT for paper alone. Reading it as `@sidebar_user_opened` in the
     pane comprehension therefore did not degrade, it DIED:
     `** (KeyError) key :sidebar_user_opened not found` raised through
     `Phoenix.LiveView.Diff.process_keyed/5`. These mounts are that crash's
     regression lock. They assert on rendered panes, not on the assign, so
     they stay honest if the seeding moves house later.

     The tempting alternative — `Map.get(assigns, :sidebar_user_opened, false)`
     at the read site — compiles, goes green, and silently pins every
     non-paper desk to false. That is the same hole wearing a passing test,
     which is why the seed lives in `mount.ex` and the read stays `@`.

  2. THE LADDER END TO END. That a summoned inspector at `standard` really
     does make the nav rail yield in the rendered DOM, and that `wide` moves
     nothing — including the detail that at `wide` the panel is seeded OPEN,
     so the FIRST click CLOSES it and it takes TWO clicks to raise
     `user_opened` there, versus ONE at `standard`. A Tier-1 test that clicks
     once at wide and expects "opened" is measuring the wrong state.

  Also pinned: the toggle stays a PURE assign flip. It must never call
  `rebuild_panes/1` — LiveView change-tracking already reaches the pane
  comprehension, and rebuilding would re-run the whole structure walk on
  every click.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @slug "2026-07-20-spd-b39-ladder"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Posts",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "icon" => "grid",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _post} =
      Content.create_document(
        "post",
        %{"doc_id" => "spd-b39-post", "title" => "Ladder Post", "status" => "published"},
        @dataset
      )

    {:ok, _sheet} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => "spd-b39-sheet",
          "title" => "Ladder Sheet",
          "content" => %{"locale" => "nb-NO", "tabs" => [%{"name" => "Data", "cells" => %{}}]}
        },
        @dataset
      )

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          dataset: @dataset,
          blocks: [
            %{"id" => "h-1", "type" => "heading", "text" => "Tier Two"},
            %{
              "id" => "p-1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "The visible measure."}]
            }
          ]
        })
      )

    :ok
  end

  defp open_paper(conn), do: live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

  defp toggle(view),
    do: element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()

  # Every rendered pane column's id, in row order. The ladder is exactly a
  # change in THIS list: `:hidden` panes are skipped server-side, so a pane
  # that yields disappears from the DOM rather than merely restyling.
  #
  # Tag-agnostic on purpose. `pane_column/1` renders a `:strip` as a
  # `<button class="pane-column pane-column--collapsed">` and a `:full` as a
  # `<section>`, so a tag whitelist would silently under-count the 44px back
  # affordance — which is the exact pane this slice is about keeping.
  defp pane_ids(html) do
    Regex.scan(~r/<[a-z]+[^>]*\bid="(pane-[a-z0-9-]+)"/, html)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
  end

  describe "D152 — every desk view mounts and renders with the fifth input wired" do
    # Each of these used to raise KeyError through Diff.process_keyed/5 the
    # moment the pane comprehension read `@sidebar_user_opened`. `live/2`
    # propagates that crash, so a bare successful mount IS the assertion —
    # but each case also asserts the pane row actually rendered, so a future
    # regression that swallows the panes cannot pass by merely not crashing.

    test "the desk root", %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))
      assert pane_ids(html) != [], "the desk root rendered zero panes"
    end

    test "a type list pane", %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post"))
      assert pane_ids(html) != [], "the type list rendered zero panes"
    end

    test "the field form (a plain document editor)", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/post/spd-b39-post"))

      assert pane_ids(html) != [], "the field form rendered zero panes"
    end

    test "the sheet grid", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/spd-b39-sheet"))

      assert pane_ids(html) != [], "the sheet grid rendered zero panes"
    end

    test "the graph pane", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/graph/spd-b39-post"))

      assert pane_ids(html) != [], "the graph pane rendered zero panes"
    end

    test "the paper view, which already had the assign, is unchanged", %{conn: conn} do
      {:ok, _view, html} = open_paper(conn)
      assert pane_ids(html) != [], "the paper view rendered zero panes"
    end
  end

  describe "the ladder at standard" do
    test "summoning the inspector makes the nav rail yield to a single back strip",
         %{conn: conn} do
      {:ok, view, html} = open_paper(conn)
      render_hook(view, "width-bucket", %{"bucket" => "standard"})

      before_ids = pane_ids(html)

      # Non-vacuity: the ladder can only REMOVE panes, so a desk that starts
      # with one pane proves nothing. Guard the premise, do not assume it.
      assert length(before_ids) >= 2, """
      the desk rendered #{length(before_ids)} pane(s) before the summon, so \
      "the rail yielded" is unfalsifiable here. Deepen the nav path.
      """

      opened = toggle(view)
      assert opened =~ "data-user-opened", "one click at standard must SUMMON the inspector"

      after_ids = pane_ids(opened)

      assert length(after_ids) == 1, """
      the rail did not yield. Panes before: #{inspect(before_ids)} \
      after: #{inspect(after_ids)} — the Tier-2 ladder must leave exactly one \
      44px back strip so the inspector docks in flow instead of overlaying \
      the prose.
      """

      assert List.last(before_ids) in after_ids, """
      the surviving pane is not the LAST one. The back affordance must be the \
      pane the user drilled from, not an arbitrary ancestor.
      """
    end

    test "dismissing the inspector restores the rail exactly", %{conn: conn} do
      {:ok, view, html} = open_paper(conn)
      render_hook(view, "width-bucket", %{"bucket" => "standard"})
      before_ids = pane_ids(html)

      toggle(view)
      restored = toggle(view)

      refute restored =~ "data-user-opened"

      assert pane_ids(restored) == before_ids, """
      the rail did not come back the way it left. The ladder must be exactly \
      reversible — `/5` with the inspector closed is `/4` verbatim.
      """
    end
  end

  describe "TIER 1 — wide is unmoved" do
    test "raising user_opened at wide takes TWO clicks and moves zero panes", %{conn: conn} do
      {:ok, view, html} = open_paper(conn)
      render_hook(view, "width-bucket", %{"bucket" => "wide"})

      before_ids = pane_ids(html)
      assert length(before_ids) >= 2, "premise: wide must start with a real rail to lose"

      # At wide the panel is seeded OPEN, so click one CLOSES it. A Tier-1
      # test that stops here and expects "opened" is measuring the wrong
      # state — this is the trap D151 names explicitly.
      first = toggle(view)
      refute first =~ "data-user-opened", "at wide the first click must CLOSE, not summon"
      assert pane_ids(first) == before_ids

      second = toggle(view)
      assert second =~ "data-user-opened", "the second click at wide raises user_opened"

      assert pane_ids(second) == before_ids, """
      TIER 1 MOVED. At wide, a summoned inspector changed the pane row from \
      #{inspect(before_ids)} to #{inspect(pane_ids(second))}. Viewport 1280 \
      and 1440 must move zero cells: there is no shortfall there to spend \
      navigation on.
      """
    end
  end

  # ── TIER 3 — the return grammar (spd-b39, D164/D165/D167/D168/D169) ────────
  #
  # Wave 10 shipped the Tier-3 GEOMETRY: at narrow and phone a user-summoned
  # inspector paints `position:absolute; inset:0` over an opaque surface. It
  # shipped with no exit: the sole control rendered `chevron-down` on an action
  # that goes BACK, the header said the literal "Document", the covered prose
  # stayed in the tab order, and the deployed run's instrument SKIPPED its third
  # state by name because no destination marker existed. This block pins the
  # visible half of that exit.
  #
  # D165 VACUITY TRAP, stated so it is not re-walked: `isContentEditable` stays
  # TRUE under an `inert` ancestor. A test that asserts non-editability that way
  # is vacuous green. These assert the RENDERED ATTRIBUTE, and the gate is
  # proven by MUTATION — each predicate assertion comes in an inversion-
  # sensitive triple (on at narrow+summoned, off at narrow+dismissed, off at
  # standard+summoned), so flipping the predicate's sense in components.ex reds
  # them rather than merely shifting which one passes.

  @t3_source "lib/barkpark_web/live/studio/studio_live/components.ex"

  defp source do
    File.read!(Path.join(File.cwd!(), @t3_source))
  end

  # The `.icon` component renders raw SVG path bytes and NO name attribute, so
  # the glyph's identity is only assertable by comparing against the component's
  # own output for that name. Rendering it here is the only honest way to say
  # "this button shows arrow-left" — a data-icon attribute on the shared icon
  # would have moved every golden snapshot in the tree.
  # Compare on the `d="…"` path data, not on raw markup: `render_component/2`
  # emits self-closing `<path …/>` while the LiveView's rendered page emits
  # `<path …></path>`, so a byte comparison would be a false red.
  defp icon_body(name) do
    render_component(&BarkparkWeb.Icons.icon/1, name: name, size: 16)
    |> then(&Regex.scan(~r/\sd="([^"]+)"/, &1))
    |> Enum.map(fn [_, d] -> d end)
    |> tap(fn ds -> assert ds != [], "icon #{inspect(name)} rendered no path data" end)
  end

  # `head` shows EVERY path of `name` (and, for a refutation, none of them).
  defp shows_icon?(html, name), do: Enum.all?(icon_body(name), &String.contains?(html, &1))

  # THE VACUITY THIS SLICE ACTUALLY HIT. `icon/1` answers an UNKNOWN name with
  # the "file" glyph instead of raising, so `shows_icon?(head, "arrow-left")`
  # went green while the button painted a document — both sides of the
  # comparison were the same fallback. Every glyph-identity assertion below is
  # guarded by this first.
  defp assert_icon_is_real(name) do
    refute icon_body(name) == icon_body("file"),
           """
           `#{name}` is not in the icon map — `icon/1` fell back to "file", so any \
           assertion about this glyph compares the fallback against itself and \
           passes no matter what the button renders.
           """
  end

  defp dismiss(view),
    do: element(view, ~s([data-test-id="sidebar-dismiss"])) |> render_click()

  # The sidebar's head — the collapse/dismiss button plus the title span. Scoped
  # so an `arrow-left` in the surrounding layout chrome cannot make a Tier-3
  # assertion pass by accident.
  defp sidebar_head(html) do
    case String.split(html, ~s(class="bp-doc-sidebar__head"), parts: 2) do
      [_, tail] -> String.split(tail, "</div>", parts: 2) |> hd()
      _ -> ""
    end
  end

  # The <aside> OPEN TAG only. `aria-modal` lives elsewhere in this module (the
  # delete/confirm modals, which are real dialogs), so a whole-file refutation
  # would be a lie; the refusal is about THIS element.
  defp sidebar_tag(html) do
    case Regex.run(~r|<aside[^>]*class="bp-doc-sidebar[^>]*>|s, html) do
      [tag] -> tag
      _ -> ""
    end
  end

  defp editor_body_tag(html) do
    case Regex.run(~r|<div[^>]*class="editor-body[^>]*>|s, html) do
      [tag] -> tag
      _ -> ""
    end
  end

  defp bucket(view, b), do: render_hook(view, "width-bucket", %{"bucket" => b})

  # At narrow and phone the desk PAINTS the inspector closed while `sidebar_open`
  # still says true, so `sidebar_toggle_panel/1`'s painted-closed branch makes
  # ONE click summon — same as standard, unlike wide where it takes two.
  defp summon(view, b) do
    bucket(view, b)
    toggle(view)
  end

  # What `studio_paper_view/1` computes for the title, read from the DB rather
  # than hardcoded: `paper_doc.title || slug || "Paper"`. Mirroring the source
  # expression keeps this honest if the fixture's title changes.
  defp expected_title do
    paper = Content.get_paper(@slug, @dataset)
    (paper && Map.get(paper, :title)) || @slug || "Paper"
  end

  describe "TIER 3 — the header tells the truth (D167)" do
    test "at narrow the control is arrow-left and the header names the document",
         %{conn: conn} do
      assert_icon_is_real("arrow-left")

      {:ok, view, _html} = open_paper(conn)
      html = summon(view, "narrow")
      head = sidebar_head(html)

      assert head != "", "the inspector head did not render at narrow"

      assert shows_icon?(head, "arrow-left"), """
      the Tier-3 collapse control is not rendering `arrow-left`. At narrow this \
      button is the ONLY way out of a full-screen destination, so the glyph must \
      point the way the action goes (D46/D167) — `chevron-down` describes a \
      motion the click does not perform.
      """

      refute shows_icon?(head, "chevron-down"), "chevron-down survived at Tier 3"

      title = expected_title()

      assert head =~ title, """
      the Tier-3 header does not name the document. Expected #{inspect(title)} \
      (paper_doc.title || slug || "Paper", mirroring studio_paper_view/1).
      """

      refute head =~ ">\n          Document\n", "the hardcoded literal survived at Tier 3"
    end

    test "at wide the glyph and the literal label are UNCHANGED", %{conn: conn} do
      assert_icon_is_real("arrow-left")
      assert_icon_is_real("chevron-down")

      {:ok, view, _html} = open_paper(conn)
      html = bucket(view, "wide")
      head = sidebar_head(html)

      assert shows_icon?(head, "chevron-down"), "wide lost its chevron-down"
      refute shows_icon?(head, "arrow-left"), "wide grew a back arrow it has no use for"
      assert head =~ "Document", "wide lost the literal label"
    end
  end

  describe "TIER 3 — the gate is an ENUMERATION, not a negation (D169)" do
    test "standard + user_opened is DOCKED and gets no destination semantics",
         %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      html = summon(view, "standard")

      assert html =~ "data-user-opened", "premise: one click at standard must summon"

      refute html =~ "data-inspector-destination", """
      a DOCKED inspector was marked as a destination. The wave-10 ladder made \
      standard + user-opened a real docked state — the rail yields to one 44px \
      strip and the panel sits IN FLOW beside prose the reader can still see and \
      edit. `!= "wide"` would produce exactly this bug.
      """

      refute html =~ ~s(data-test-id="sidebar-dismiss")
      refute editor_body_tag(html) =~ "inert", "docked standard inerted visible prose"
      assert shows_icon?(sidebar_head(html), "chevron-down")
    end

    test "the predicate is never written as `!= \"wide\"` in code", %{conn: _conn} do
      code =
        source()
        |> String.split("\n")
        # `!= "wide"` appears in the PROSE of three comments that explain why it
        # is forbidden. Strip comment lines so the refutation is about code.
        |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
        |> Enum.join("\n")

      refute code =~ ~s(!= "wide"), """
      a `!= "wide"` tier predicate is in the code. Enumerate the covered buckets \
      — `in ["narrow","phone"]` — because standard is a docked state, not an \
      uncovered one.
      """
    end
  end

  describe "TIER 3 — crumbs reach narrow and learn the inspector (D168)" do
    test "the trail renders at narrow as well as phone", %{conn: conn} do
      for b <- ["narrow", "phone"] do
        {:ok, view, _html} = open_paper(conn)
        html = bucket(view, b)

        assert html =~ ~s(data-test-id="desk-crumbs"), """
        no breadcrumb trail at #{b}. Before this slice the <nav> was never \
        emitted at narrow at all (live-confirmed null at 800px) — which left a \
        full-screen Tier-3 destination with no rendered way out.
        """
      end
    end

    test "at wide the trail is still absent", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      refute bucket(view, "wide") =~ ~s(data-test-id="desk-crumbs")
    end

    test "the trail grows an inspector segment and the document crumb dismisses",
         %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      before_summon = bucket(view, "narrow")

      refute before_summon =~ ~s(data-test-id="desk-crumb-inspector"), """
      premise: with the inspector dismissed the document is where you ARE, so \
      there must be no inspector segment to leave.
      """

      opened = toggle(view)

      assert opened =~ ~s(data-test-id="desk-crumb-inspector"), """
      the trail did not grow an inspector segment. Once the inspector covers the \
      screen it — not the document — is where the reader is.
      """

      assert opened =~ ~s(data-test-id="desk-crumb-document"), """
      the document crumb is still dead text. It must become a real control: at \
      Tier 3 it is the way back to the prose.
      """

      # Drive the event through the crumb itself, not the aside's button — the
      # point is that the crumb is WIRED, not merely that something can dismiss.
      dismissed =
        element(view, ~s([data-test-id="desk-crumb-document"])) |> render_click()

      refute dismissed =~ "data-user-opened", """
      clicking the document crumb did not dismiss the inspector.
      """

      refute dismissed =~ ~s(data-test-id="desk-crumb-inspector")
    end
  end

  describe "TIER 3 — the covered content leaves the tree (D164/D165)" do
    test "inert is SERVER-RENDERED on .editor-body, and the gate survives inversion",
         %{conn: conn} do
      # (a) ON at narrow + summoned.
      {:ok, view, _html} = open_paper(conn)
      on = summon(view, "narrow")

      assert editor_body_tag(on) =~ "inert", """
      `.editor-body` is not inert while an opaque inset:0 panel covers it. The \
      prose underneath stays fully reachable by Tab and by AT.

      It MUST be the server-rendered `inert={<predicate>}` attribute, never a \
      JS-set `el.inert = true`: morphdom strips a JS-set inert on the next \
      LiveView diff, and toggling the inspector IS that diff, so an imperative \
      hook self-disables on first use with no error to show for it.
      """

      # (b) OFF at narrow + dismissed — same bucket, only user_opened moved.
      # The control's test id is `sidebar-dismiss` at Tier 3 — that rename IS
      # part of the shipped grammar, so the dismissal drives THAT selector.
      off = dismiss(view)
      refute off =~ "data-user-opened", "premise: the second click must dismiss"

      refute editor_body_tag(off) =~ "inert", """
      a DISMISSED inspector left the prose inert — the document is unusable and \
      nothing on screen explains why.
      """

      # (c) OFF at standard + summoned — same user_opened, only the bucket moved.
      {:ok, view2, _} = open_paper(conn)
      docked = summon(view2, "standard")
      assert docked =~ "data-user-opened"
      refute editor_body_tag(docked) =~ "inert"
    end

    test "no aria-modal on the destination; a named landmark and a truthful aria-expanded",
         %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      html = summon(view, "narrow")
      tag = sidebar_tag(html)

      assert tag != "", "the inspector aside did not render"

      refute tag =~ "aria-modal", """
      `aria-modal` is REFUSED (D164): at Tier 3 there is no outside content to \
      mark as outside — at phone `display_state/4` returns :hidden for every \
      pane — and a scrim beneath an opaque inset:0 panel can never be \
      hit-tested. Announcing a modal boundary that does not exist is the same \
      class of lie the wave-10 aria-expanded fix removed.
      """

      refute tag =~ ~s(role="dialog")

      assert tag =~ "aria-label=", "the destination landmark has no accessible name"
      assert tag =~ expected_title(), "the landmark name does not identify the document"

      assert sidebar_head(html) =~ ~s(aria-expanded="true"), """
      the control must announce the state the reader can SEE — at Tier 3 a \
      summoned inspector is open.
      """
    end

    test "the aria-modal refusal is recorded in the source, citing D164", %{conn: _conn} do
      code = source()

      assert code =~ ~r/aria-modal.{0,80}REFUSED \(D164\)/s, """
      the refusal must be written down where the next reader of this component \
      will find it — otherwise "add aria-modal" is re-proposed every wave.
      """
    end
  end

  describe "TIER 3 — the destination marks itself for the deployed instrument" do
    test "data-inspector-destination and sidebar-dismiss are present at Tier 3 only",
         %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      closed = bucket(view, "narrow")
      refute closed =~ "data-inspector-destination"
      refute closed =~ ~s(data-test-id="sidebar-dismiss")

      opened = toggle(view)

      assert opened =~ "data-inspector-destination", """
      the deployed run's instrument looks for this marker by name and SKIPS its \
      third state without it — which is how a whole tier went unmeasured.
      """

      assert opened =~ ~s(data-test-id="sidebar-dismiss"), """
      the back control carries no dismiss test id, so the deployed probe cannot \
      find the exit it is supposed to exercise.
      """

      # And phone, the other covered bucket.
      {:ok, view2, _} = open_paper(conn)
      assert summon(view2, "phone") =~ "data-inspector-destination"
    end
  end

  # ── spd-w12 — the keyboard exit, the focus round trip, and the trail ────────
  #
  # HONEST SCOPE, stated once for the whole block below. Everything here proves
  # the SERVER handler and the RENDERED WIRING: that the hook element and its
  # data contract render at Tier 3 and nowhere else, that the dismissal command
  # carries a focus return, and that the trail reaches the ladder tier. It
  # proves NOTHING about the key in a browser — ExUnit renders markup, models no
  # capture phase, no `inert`, no `document.activeElement` and no listener
  # ordering. The live browser proof of Escape belongs to
  # `inspector-shape-bracketed-deployed-run`, by name (D166/D173).
  #
  # WHY THE BINDING NEEDS ITS OWN TEST (D181). An ungated binding ships SILENTLY
  # GREEN: with the tier gate mutated to a bare `true` the behavioural suite is
  # untroubled — Escape simply becomes a global open-the-inspector key at every
  # bucket including wide — because a socket-driven round trip cannot see a
  # binding it never reads. And `render_keydown` does not enforce `phx-key`
  # either (a binding declared with `phx-key="Banana"` keeps a behavioural test
  # green), so the key itself is only assertable as a RENDERED ATTRIBUTE.
  # Hence: literal attribute assertions, in an inversion-sensitive quadruple
  # (present at Tier 3; absent at narrow-dismissed, at standard and at wide).
  describe "spd-w12 — the Escape binding is RENDERED, and gated to Tier 3" do
    test "the hook and its full data contract render at Tier 3", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      html = summon(view, "narrow")

      assert html =~ ~s(phx-hook="InspectorEscape"), """
      no Escape hook at Tier 3. The keyboard exit does not exist: a keyboard \
      reader enters a full-screen destination and has no key that leaves it.
      """

      assert html =~ ~s(id="bp-inspector-escape")

      assert html =~ ~s(data-escape-key="Escape"), """
      the key is not rendered. It can ONLY be pinned as an attribute — \
      `render_keydown` does not enforce `phx-key`, so a behavioural round trip \
      stays green with a binding declared on any key at all.
      """

      assert html =~ ~s(data-escape-event="sidebar-toggle-panel"), """
      the Escape binding does not name the already-classified event. A new \
      event here would cost a `caps.ex` entry and a `handle_event` head for a \
      dismissal the sidebar button already performs.
      """

      assert html =~ ~s(data-escape-veto=".bp-paper-format"), """
      the activeElement veto is missing or unscoped. The format bubble's link \
      input handles Escape with preventDefault ONLY (format-bubble.js:115-118) \
      and portals to document.body (:146), so its Escape reaches a bubble-phase \
      window listener — typing a link URL and pressing Escape would throw the \
      reader out of the inspector. The scope must be `.bp-paper-format` and \
      never a bare `input`, which would veto Escape from every input on the desk.
      """

      assert html =~ ~s(data-escape-return="#bp-doc-sidebar-toggle"), """
      the Escape path drops focus. Leaving by key must land where leaving by \
      pointer lands.
      """
    end

    test "the binding is ABSENT at narrow-dismissed, standard and wide", %{conn: conn} do
      # (a) same bucket, only user_opened moved.
      {:ok, view, _html} = open_paper(conn)
      summon(view, "narrow")
      off = dismiss(view)
      refute off =~ "data-user-opened", "premise: the second click must dismiss"

      refute off =~ ~s(phx-hook="InspectorEscape"), """
      a dismissed inspector still binds Escape. There is no destination to \
      leave, so the key would fire a summon-toggle out of nowhere.
      """

      # (b) same user_opened, only the bucket moved — the DOCKED ladder tier.
      {:ok, view2, _} = open_paper(conn)
      docked = summon(view2, "standard")
      assert docked =~ "data-user-opened", "premise: one click at standard must summon"

      refute docked =~ ~s(phx-hook="InspectorEscape"), """
      Escape was bound on the DOCKED inspector. At standard the panel sits in \
      flow beside prose the reader can still see and edit — there is no \
      full-screen destination to escape from, and stealing Escape there takes \
      it away from whatever the reader is actually typing into.
      """

      # (c) wide — the panel is seeded open, so the FIRST click closes it and it
      # takes TWO to raise user_opened. Assert on the raised state.
      {:ok, view3, _} = open_paper(conn)
      bucket(view3, "wide")
      toggle(view3)
      wide = toggle(view3)
      assert wide =~ "data-user-opened", "premise: two clicks at wide must summon"
      refute wide =~ ~s(phx-hook="InspectorEscape")
    end
  end

  describe "spd-w12 — focus moves IN and RETURNS (D163/D165)" do
    test "the destination takes focus on open and the dismissals hand it back",
         %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      html = summon(view, "narrow")

      assert html =~ ~s(id="bp-doc-sidebar"), "the landmark has no id to focus"

      assert sidebar_tag(html) =~ ~s(tabindex="-1"), """
      the destination landmark is not programmatically focusable, so focus-in \
      has nowhere to land.
      """

      assert html =~ ~s(phx-mounted=), """
      nothing moves focus INTO the destination. The hook element renders only \
      at Tier 3, so its mount IS the transition into the destination — that is \
      where focus-in belongs.
      """

      # The dismissal command carries the focus return. JS commands render as
      # a JSON-encoded array on the attribute, so assert on the encoded
      # operation rather than on Elixir structs.
      head = sidebar_head(html)

      assert head =~ "focus", """
      the Tier-3 dismissal drops focus on <body>. Focus RETURN has no precedent \
      anywhere in api/lib — the one APG-cited focus-trapping primitive in this \
      repo lives in cloud/priv/static/app.js and is OUT OF FENCE (D163) — so \
      this wiring is the whole of it and an absent test is an absent feature.
      """

      assert head =~ "bp-doc-sidebar-toggle", "the focus return names no target"

      assert html =~ ~s(data-test-id="desk-crumb-document"), "premise: the crumb dismisses"

      crumb =
        Regex.run(~r|<button[^>]*data-test-id="desk-crumb-document"[^>]*>|s, html)
        |> case do
          [tag] -> tag
          _ -> ""
        end

      assert crumb =~ "focus" and crumb =~ "bp-doc-sidebar-toggle", """
      the crumb dismissal drops focus. It is the path where focus genuinely \
      TRAVELS — from the trail back to the control that owns the panel — so it \
      is the one that must not be left to morphdom luck.
      """
    end

    test "below Tier 3 the toggle keeps its plain event string", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      head = sidebar_head(bucket(view, "wide"))

      assert head =~ ~s(phx-click="sidebar-toggle-panel"), """
      the docked/collapsed toggle grew a JS command. Below Tier 3 there is no \
      destination and nothing to return focus from — this attribute must stay \
      byte-identical to what shipped.
      """
    end
  end

  describe "spd-w12 — the crumb trail reaches the ladder tier (D180)" do
    test "standard with the ladder engaged gets the trail", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      before_ladder = bucket(view, "standard")

      refute before_ladder =~ ~s(data-test-id="desk-crumbs"), """
      an untouched standard desk grew a trail. It still has its full nav rail, \
      so the trail would be redundant chrome and the first render would move.
      """

      engaged = toggle(view)
      assert engaged =~ "data-user-opened", "premise: one click at standard must summon"

      assert engaged =~ ~s(data-test-id="desk-crumbs"), """
      the ladder tier has no trail. With the ladder engaged the rail YIELDS to a \
      44px strip, leaving exactly two affordances on the screen — so standard \
      was the one bucket that hid the whole rail without offering the trail \
      that replaces it.
      """
    end

    test "the ladder tier's trail does NOT claim you left the document", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      engaged = summon(view, "standard")

      refute engaged =~ ~s(data-test-id="desk-crumb-inspector"), """
      the docked ladder tier grew an inspector leaf. At standard the panel sits \
      in flow BESIDE prose the reader can still see — the document is still \
      where you are, and the trail must not say otherwise.
      """

      refute engaged =~ ~s(data-test-id="desk-crumb-document"), """
      the document crumb became a dismiss control on a DOCKED panel. It is the \
      way back to prose you cannot see; at standard you can see it.
      """
    end

    test "wide still has no trail at all", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      bucket(view, "wide")
      toggle(view)
      wide = toggle(view)
      assert wide =~ "data-user-opened", "premise: two clicks at wide must summon"
      refute wide =~ ~s(data-test-id="desk-crumbs")
    end
  end

  describe "spd-w12 — the keyboard exit costs no new capability" do
    test "no phx-keydown is added inside the destination subtree", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      html = summon(view, "narrow")

      aside =
        case String.split(html, ~s(<aside id="bp-doc-sidebar"), parts: 2) do
          [_, tail] -> String.split(tail, "</aside>", parts: 2) |> hd()
          _ -> ""
        end

      assert aside != "", "the destination aside did not render"

      refute aside =~ "phx-keydown", """
      a `phx-keydown` was added inside the destination. Standing law: a focused \
      element carrying `phx-keydown` suppresses EVERY `phx-window-keydown` on \
      the page — live_socket.js matches the RAW event target with no ancestor \
      walk — so this one attribute would silently kill the desk's other window \
      bindings with no error to show for it.
      """
    end

    test "the tier predicate has exactly ONE definition", %{conn: _conn} do
      code = source()

      defs = Regex.scan(~r/^\s*defp inspector_destination\?\(/m, code)

      assert length(defs) == 1, """
      the tier predicate has #{length(defs)} definitions. It is read by the \
      `inert` gate, the destination clothes, the Escape binding and the crumb \
      leaf — four readers of a hand-copied enumeration is four places to drift.
      """
    end
  end

  describe "the toggle stays a pure assign flip" do
    test "summoning does not rebuild the pane tree", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      render_hook(view, "width-bucket", %{"bucket" => "wide"})

      panes_before = :sys.get_state(view.pid).socket.assigns.panes
      toggle(view)
      panes_after = :sys.get_state(view.pid).socket.assigns.panes

      # TERM-identical, not merely equal-looking: `rebuild_panes/1` re-runs
      # the structure walk and would hand back freshly built maps. The pane
      # comprehension re-renders anyway on a pure flip — LiveView change
      # tracking already reaches it — so rebuilding buys nothing and costs a
      # full desk walk on every click.
      assert panes_after === panes_before, """
      the sidebar toggle rebuilt the pane tree. It must stay a pure assign \
      flip (D151): change-tracking already re-renders the comprehension.
      """
    end
  end
end
