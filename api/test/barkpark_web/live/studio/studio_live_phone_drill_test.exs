defmodule BarkparkWeb.Studio.StudioLivePhoneDrillTest do
  @moduledoc """
  studio-space-priority-desk spd-s6 — the phone drill has a way BACK.

  spd-s4 wired `PaneBuilder.display_state/4` to the rendered desk. At the
  phone bucket that table hides EVERY nav column when a document is open, and
  every column but the leaf when one is not — so the 44px back strip spd-s4
  promoted to the desk's primary back affordance is not on the page at all.
  Measured live on guerrilla at a 500px viewport: `strips: 0`, `crumbs: 0`.
  Opening a document on a phone was a navigational dead end.

  This file pins the two things that close it:

    * `.bp-desk-crumbs` renders as a SIBLING BEFORE `.pane-layout` (charter
      D27 — never inside the flex row, never in the topbar), built from the
      `@panes` titles, clicking through the EXISTING `expand-pane` event with
      the same `phx-value-idx` truncation the strip uses. Zero new server
      events, zero new `caps.ex` entries.
    * The collapsed strip is a real `<button>` — keyboard-reachable and
      announced — because a `phx-click` div is invisible to everyone not
      using a mouse, and spd-s4 made that strip the primary back-nav.

  Assertions run on the rendered HTML string (no Floki in this app's deps)
  plus `has_element?/2`, which uses LiveViewTest's own DOM engine.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.TenancyFixtures

  @dataset "production"

  setup %{conn: conn} do
    {_ws, _proj} = TenancyFixtures.ensure_default_scope!()

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "text"}
          ]
        },
        @dataset
      )

    {:ok, _doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "p1", "title" => "Hello world", "content" => %{"body" => "b"}},
        @dataset
      )

    {:ok, conn: conn}
  end

  # Root desk pane + the post type list = 2 panes, with the document open.
  defp open_doc(conn), do: live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))

  # The drilled list WITHOUT a document — 2 panes, no editor.
  defp open_list(conn), do: live(conn, scoped_studio("/d/#{@dataset}/studio/post"))

  defp root_desk(conn), do: live(conn, scoped_studio("/d/#{@dataset}/studio"))

  defp set_bucket(view, bucket) do
    view
    |> element("#studio-panes")
    |> render_hook("width-bucket", %{"bucket" => bucket})
  end

  defp count(html, pattern), do: html |> then(&Regex.scan(pattern, &1)) |> length()

  # Byte offset of a literal in the rendered HTML — source order IS the D27
  # sibling-placement proof.
  defp at(html, needle), do: html |> :binary.match(needle) |> elem(0)

  # Clickable crumbs only — the current crumb carries a second class token.
  defp crumb_buttons(html), do: count(html, ~r/class="bp-desk-crumb"/)

  describe "the phone bucket gets a breadcrumb trail" do
    test "phone + open document renders crumbs where the pane row renders nothing", %{conn: conn} do
      {:ok, view, _html} = open_doc(conn)

      phone_html = set_bucket(view, "phone")

      # spd-s4's phone rule: not one nav column survives.
      assert count(phone_html, ~r/class="pane-column(?=[ "])/) == 0

      assert phone_html =~ ~s(class="bp-desk-crumbs"),
             "with every pane column hidden the crumb trail is the ONLY route back — " <>
               "without it the phone desk is a dead end (D56)"

      assert has_element?(view, ~s(nav.bp-desk-crumbs[data-test-id="desk-crumbs"]))

      # Both panes stay clickable because the trail's CURRENT entry is the
      # open document, not the list it came from.
      assert crumb_buttons(phone_html) == 2
      assert phone_html =~ ~s(class="bp-desk-crumb bp-desk-crumb--current")
      assert phone_html =~ "Hello world"
    end

    test "the trail is a SIBLING placed BEFORE the pane row, never inside it (D27)", %{conn: conn} do
      {:ok, view, _html} = open_doc(conn)
      html = set_bucket(view, "phone")

      crumbs_at = at(html, ~s(class="bp-desk-crumbs"))
      layout_at = at(html, ~s(class="pane-layout"))

      assert crumbs_at < layout_at,
             "the crumb trail must render before the pane row, not after it"

      closed_at =
        crumbs_at + at(binary_part(html, crumbs_at, byte_size(html) - crumbs_at), "</nav>")

      assert closed_at < layout_at,
             "the crumb trail must CLOSE before .pane-layout opens — nested inside the " <>
               "flex row it would become a squeezed column (D27)"
    end

    test "every crumb reuses the existing expand-pane event — no new server event", %{conn: conn} do
      {:ok, view, _html} = open_doc(conn)
      html = set_bucket(view, "phone")

      # Each clickable crumb is a real <button type="button"> ...
      assert count(html, ~r/<button type="button" class="bp-desk-crumb"/) == crumb_buttons(html)

      # ... and every one of them fires `expand-pane` with an index. If a crumb
      # ever needed a new event, `caps.ex` would need a new entry and a
      # non-admin socket would be halted before the handler.
      crumbs_at = at(html, ~s(class="bp-desk-crumbs"))
      crumb_zone = binary_part(html, crumbs_at, at(html, ~s(class="pane-layout")) - crumbs_at)

      assert count(crumb_zone, ~r/phx-click="expand-pane"/) == crumb_buttons(html)
      assert count(crumb_zone, ~r/phx-click="(?!expand-pane)/) == 0
      assert crumb_zone =~ ~s(phx-value-idx="0")
    end

    test "clicking the leaf crumb closes the document — the dead end is actually open", %{
      conn: conn
    } do
      {:ok, view, wide_html} = open_doc(conn)
      assert wide_html =~ ~s(class="editor-panel")

      set_bucket(view, "phone")

      after_click =
        view
        |> element(~s(button.bp-desk-crumb[phx-value-idx="1"]))
        |> render_click()

      refute after_click =~ ~s(class="editor-panel"),
             "the crumb for the leaf LIST must close the open document — this is the tap " <>
               "that gets a phone user out of the editor"

      # And the list itself is back on screen (phone, no editor → leaf pane full).
      assert count(after_click, ~r/class="pane-column(?=[ "])/) == 1
    end

    test "clicking the root crumb walks all the way home", %{conn: conn} do
      {:ok, view, _html} = open_doc(conn)
      set_bucket(view, "phone")

      after_click =
        view
        |> element(~s(button.bp-desk-crumb[phx-value-idx="0"]))
        |> render_click()

      refute after_click =~ ~s(class="editor-panel")

      # Back at the undrilled root there is nowhere left to go, so the trail
      # retires rather than leaving a vestigial single crumb.
      refute after_click =~ ~s(class="bp-desk-crumbs")
      refute has_element?(view, "nav.bp-desk-crumbs")
    end

    test "drilled WITHOUT a document: the current pane is text, its ancestors are buttons", %{
      conn: conn
    } do
      {:ok, view, _html} = open_list(conn)
      html = set_bucket(view, "phone")

      assert html =~ ~s(class="bp-desk-crumbs")

      # 2 panes, no editor → root is clickable, the leaf is where you already are.
      assert crumb_buttons(html) == 1
      assert count(html, ~r/class="bp-desk-crumb bp-desk-crumb--current"/) == 1
      assert html =~ ~s(aria-current="page")
    end

    test "the undrilled root desk gets no vestigial trail", %{conn: conn} do
      {:ok, view, _html} = root_desk(conn)

      refute set_bucket(view, "phone") =~ ~s(class="bp-desk-crumbs")
      refute has_element?(view, "nav.bp-desk-crumbs")
    end
  end

  describe "the desktop desk is untouched" do
    # spd-b39/D168 — `narrow` LEFT this list, deliberately. It was here because
    # narrow still keeps its pane columns (or the 44px strip), so it had a way
    # back without a trail. The wave-10 geometry broke that premise: at narrow a
    # summoned inspector paints `inset:0` over everything, and the trail is the
    # rendered way out of it. Wide and standard are unchanged and stay pinned.
    test "no crumb markup at wide or standard", %{conn: conn} do
      {:ok, view, wide_html} = open_doc(conn)

      # NB: the literal must be the MARKUP (`class="bp-desk-crumb`), not the
      # bare class name — root.html.heex ships the `.bp-desk-crumb` CSS in
      # every render, so a bare-substring refute would fail vacuously.
      refute wide_html =~ ~s(class="bp-desk-crumb),
             "the static first render must stay byte-identical to the pre-spd-s6 desktop desk"

      refute has_element?(view, "nav.bp-desk-crumbs")

      for bucket <- ~w(wide standard) do
        refute set_bucket(view, bucket) =~ ~s(class="bp-desk-crumb),
               "#{bucket} keeps its pane columns (or the 44px strip) and needs no trail"
      end

      # And the other side of the move, so this test still measures a BOUNDARY
      # rather than merely having had its inconvenient case deleted.
      assert set_bucket(view, "narrow") =~ ~s(class="bp-desk-crumb),
             "narrow must now carry the trail (D168) — a Tier-3 destination needs a rendered way out"
    end

    test "the trail appears and disappears with the bucket, round-trip clean", %{conn: conn} do
      {:ok, view, _html} = open_doc(conn)

      assert set_bucket(view, "phone") =~ ~s(class="bp-desk-crumbs")
      refute set_bucket(view, "wide") =~ ~s(class="bp-desk-crumb)
      assert set_bucket(view, "phone") =~ ~s(class="bp-desk-crumbs")
    end
  end

  describe "the collapsed strip is keyboard-operable and announced" do
    test "narrow + open document renders the strip as a real button (not a div)", %{conn: conn} do
      {:ok, view, _html} = open_doc(conn)
      html = set_bucket(view, "narrow")

      assert html =~
               ~s(<button type="button" class="pane-column pane-column--collapsed"),
             "the strip must be a <button> — as a div it is unreachable by keyboard and " <>
               "silent to a screen reader, and spd-s4 made it the ONLY way back at this width"

      assert has_element?(
               view,
               ~s(button.pane-column--collapsed[phx-click="expand-pane"])
             )

      assert html =~ ~s(aria-label="Back to Post")
    end

    # spd-w5 / charter D79. `aria-expanded` shipped hardcoded to "false" and a
    # live browser reading found `[aria-expanded="true"]` returning ZERO
    # elements document-wide in every state: activating the strip destroys it,
    # so nothing survives to carry the true state. An ARIA state that can never
    # change is a lie to assistive tech; it is gone, and `aria-controls` names
    # the region the control actually replaces.
    test "the strip claims no expanded state and its aria-controls resolves to a real id",
         %{conn: conn} do
      {:ok, view, _html} = open_doc(conn)
      html = set_bucket(view, "narrow")

      # Scoped to the strip's own tag: the workspace switcher's `aria-expanded`
      # is a REAL disclosure (a persistent trigger beside a menu it toggles) and
      # is correct — the strip's was not.
      assert [[strip_tag]] = Regex.scan(~r/<button[^>]*pane-column--collapsed[^>]*>/, html)

      refute strip_tag =~ "aria-expanded",
             "the strip must claim no ARIA expanded state it cannot keep — D79"

      assert [[_, controls]] =
               Regex.scan(~r/pane-column--collapsed"[^>]*aria-controls="([^"]+)"/, html)

      assert html =~ ~s(id="#{controls}"),
             "aria-controls=\"#{controls}\" must point at an element that EXISTS in the " <>
               "same document — an unresolvable referent is the decoration it replaced"

      assert controls == "studio-panes",
             "the strip re-composes the pane row; that row is the region it controls"
    end

    # The second half of D79: after Enter, `document.activeElement` was BODY —
    # a keyboard user who tabs to the only route back out of a drilled pane is
    # thrown to the top of the tab order the moment they use it.
    test "activating the strip marks the re-opened pane to take focus on mount", %{conn: conn} do
      {:ok, view, _html} = open_doc(conn)
      before_click = set_bucket(view, "narrow")

      refute before_click =~ "phx-mounted",
             "no pane may grab focus before the user has navigated — an initial " <>
               "render that focuses a pane steals focus on every page load"

      after_click = view |> element("button.pane-column--collapsed") |> render_click()

      assert after_click =~ ~s(tabindex="-1")

      assert after_click =~ "phx-mounted",
             "the pane the strip named must take focus when it mounts, or focus " <>
               "falls to <body> exactly as it did before this fix"

      # The focus target is the EXPANDED pane, never a strip: the strip is gone.
      assert [[focused]] =
               Regex.scan(
                 ~r/<div\s+class="pane-column[^"]*"[^>]*phx-mounted="[^"]*"/,
                 after_click
               )

      refute focused =~ "pane-column--collapsed"
      assert focused =~ "focus"
    end

    test "the button strip still navigates back when clicked", %{conn: conn} do
      {:ok, view, _html} = open_doc(conn)
      set_bucket(view, "narrow")

      after_click = view |> element("button.pane-column--collapsed") |> render_click()

      refute after_click =~ ~s(class="editor-panel")
    end
  end
end
