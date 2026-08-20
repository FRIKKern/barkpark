defmodule BarkparkWeb.Studio.StudioLiveNavigationalTruthTest do
  @moduledoc """
  spd-b47 — TWO NAVIGATIONAL LIES, BOTH MEASURED, BOTH RULED (charter D179/D180).

  This file ships NO behaviour. It is the pair of locks under two rulings that
  now live in code:

  1. **D180 — the surviving back strip closes the DOCUMENT.** The Tier-2 ladder
     leaves exactly one 44px `:strip` at `standard` when the inspector is
     summoned, and that strip fires `expand-pane`. spd-b47 predicted one of two
     outcomes from it: a dead control, or the inspector squeezed back under the
     reading bar. Execution refuted both. `expand-pane` reaches
     `sidebar_user_opened` TRANSITIVELY (push_patch -> handle_params ->
     rebuild_panes -> the fall-through -> `clear_paper_view/1` ->
     `sidebar_assigns(nil)`), so the click closes the whole document and the
     rail reverts to ordinary full display. The ruling is recorded on
     `PaneBuilder.display_state/5`; this file pins it.

  2. **D179 — the Tier-3 dismiss is not navigation.** `sidebar_toggle_panel/1`
     is a pure assign while the DOM it dismisses is a full-screen destination
     with an arrow-left and a crumb trail. Ruled (b): keep the affordance,
     record why, lock the non-navigation. The ruling is recorded on
     `Handlers.Paper.sidebar_toggle_panel/1`; this file pins it.

  ## Why each lock is able to fail

  A "no patch happened" assertion is worthless on its own — it passes just as
  well when the click is broken, when the selector is wrong, or when the whole
  patch plumbing is silent. So `refute_patch/2` never appears without a
  CONTRAST CONTROL in the same file: two tests assert that `expand-pane` DOES
  patch, through `assert_patch/1`, on the same view and the same transport.

  Both directions are mutation-proven (runs quoted in the task ledger):
  injecting a `push_patch` into `sidebar_toggle_panel/1` reds the no-patch
  tests and cascades through the ladder suite; deleting the `push_patch` from
  `expand_pane/2` reds exactly the two contrast controls with
  `"expected ... to patch, but got none"`.

  ## The trap this file deliberately avoids

  Do NOT substring-check a full `live/2` render for `data-user-opened`.
  `root.html.heex`'s inline `<style>` cites the literal selector
  `[data-user-opened]` seven-plus times, so a whole-page check is green
  regardless of state — it cost a verifier a false failure. Every assertion
  about that attribute here is scoped to the `<aside>` OPEN TAG, and the
  document-closed case (where no `<aside>` renders at all, making the scoped
  refutation vacuously true) is backed by the socket assign instead.

  ## Measured scope, not generalised

  Every figure is from a 2-SEGMENT paper path (`panes = [Structure, Papers]`).
  A deeper nav path would make the surviving strip an INTERMEDIATE pane, where
  `Enum.take(nav_path, idx)` lands on a list rather than closing the document.
  That case is filed as `b47-strip-behaviour-unmeasured-beyond-two-panes` and
  is NOT claimed here.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @slug "2026-07-20-spd-b47-navigational-truth"

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

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          dataset: @dataset,
          blocks: [
            %{"id" => "h-1", "type" => "heading", "text" => "Navigational Truth"},
            %{
              "id" => "p-1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "The way out."}]
            }
          ]
        })
      )

    :ok
  end

  defp open_paper(conn), do: live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

  defp bucket(view, b), do: render_hook(view, "width-bucket", %{"bucket" => b})

  # The inspector's own control. Below `wide` the desk paints the panel closed
  # while `sidebar_open` still says true, so ONE click summons at both
  # `standard` and `narrow` — and the same button is the dismiss on the way
  # back out.
  defp toggle(view),
    do: element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()

  # At Tier 3 the SAME button changes identity: the wave-10 chrome renames it
  # `sidebar-dismiss` (and swaps chevron-down for arrow-left) the moment the
  # panel becomes a full-screen destination, so `sidebar-toggle-panel` is not
  # on the page there. It is still the same `phx-click="sidebar-toggle-panel"`
  # event and the same pure-assign handler — which is exactly D179's point:
  # the DOM took on destination vocabulary while the click did not.
  defp dismiss(view),
    do: element(view, ~s([data-test-id="sidebar-dismiss"])) |> render_click()

  defp summon(view, b) do
    bucket(view, b)
    toggle(view)
  end

  # Every rendered pane column's id, in row order. `:hidden` panes are skipped
  # server-side, so the ladder is exactly a change in THIS list. Tag-agnostic
  # on purpose: a `:strip` renders as `<button>` and a `:full` as `<section>`,
  # so a tag whitelist would under-count the very affordance under test.
  defp pane_ids(html) do
    Regex.scan(~r/<[a-z]+[^>]*\bid="(pane-[a-z0-9-]+)"/, html)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
  end

  # The <aside> OPEN TAG only — see the moduledoc's trap. A whole-page check
  # for `data-user-opened` is a guaranteed false positive.
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

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # `Phoenix.LiveViewTest` ships `assert_patch/1` and `refute_redirected/1` but
  # no `refute_patch`. This is its inverse, on the same message the proxy sends
  # the test process for a `push_patch`: `{ref, {:patch, topic, %{to: path}}}`
  # (see `assert_navigation/4` in live_view_test.ex). It WAITS rather than
  # peeking with a zero timeout, because the click that must not patch has
  # already round-tripped through the LiveView by the time we are called and a
  # zero-timeout peek would pass on a race rather than on the truth.
  defp refute_patch(%{proxy: {ref, topic, _}} = view, timeout \\ 200) do
    receive do
      {^ref, {:patch, ^topic, %{to: to}}} ->
        flunk("""
        expected #{inspect(view.module)} NOT to patch, but it patched to #{inspect(to)}.

        Charter D179: the Tier-3 inspector dismiss is a PURE ASSIGN. If this \
        handler has grown history semantics, that is a real design change — it \
        must be designed against `?desk=` preservation and against \
        `expand-pane`'s own push_patch, which knows nothing about \
        `sidebar_user_opened`. Update the ruling on \
        `Handlers.Paper.sidebar_toggle_panel/1` before touching this lock.
        """)
    after
      timeout -> :ok
    end
  end

  describe "D179 — the Tier-3 dismiss is NOT navigation" do
    test "summoning and dismissing the inspector at narrow emits no patch and no navigate",
         %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      summoned = summon(view, "narrow")

      assert sidebar_tag(summoned) =~ "data-user-opened", """
      premise failed: one click at narrow must SUMMON the inspector. Without a \
      summoned inspector there is no full-screen destination and the \
      no-navigation claim is about nothing.
      """

      assert sidebar_tag(summoned) =~ "data-inspector-destination", """
      premise failed: the inspector is not marked as a full-screen destination \
      at narrow, so this is not the Tier-3 state D179 rules on.
      """

      dismissed = dismiss(view)

      refute sidebar_tag(dismissed) =~ "data-user-opened",
             "premise failed: the second click must dismiss"

      # Covers BOTH clicks — neither the summon nor the dismiss may write
      # history. The contrast controls below prove this can fail.
      refute_patch(view)
      refute_redirected(view)
    end

    test "the same is true at phone, the other full-screen bucket", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      summoned = summon(view, "phone")
      assert sidebar_tag(summoned) =~ "data-user-opened", "premise: one click at phone summons"

      dismiss(view)

      refute_patch(view)
      refute_redirected(view)
    end

    test "CONTRAST CONTROL — the sibling crumb (expand-pane) DOES patch", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      html = bucket(view, "narrow")

      assert html =~ ~s(data-test-id="desk-crumbs"), """
      premise failed: the crumb trail did not render at narrow, so the control \
      that is supposed to prove `refute_patch/2` can fail is not on the page.
      """

      element(view, ~s(nav[data-test-id="desk-crumbs"] button[phx-value-idx="0"]))
      |> render_click()

      path = assert_patch(view)

      assert is_binary(path) and path != "", """
      the crumb did not patch. This test is the falsifiability guarantee for \
      the two `refute_patch/2` assertions above — if `expand-pane` stops \
      patching, "the dismiss does not patch" becomes a claim about a transport \
      that never speaks, and the locks silently stop meaning anything.
      """
    end
  end

  describe "D180 — the surviving back strip closes the DOCUMENT" do
    test "clicking the ladder's 44px strip at standard closes the whole document",
         %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      before_ids = pane_ids(bucket(view, "standard"))

      assert length(before_ids) >= 2, """
      premise failed: the desk rendered #{length(before_ids)} pane(s) before the \
      summon, so "the rail yielded and came back" is unfalsifiable. Deepen the \
      nav path.
      """

      summoned = toggle(view)

      assert sidebar_tag(summoned) =~ "data-user-opened",
             "premise: one click at standard must summon the inspector"

      strips = pane_ids(summoned)

      assert length(strips) == 1, """
      premise failed: the Tier-2 ladder must leave exactly ONE 44px strip, but \
      the row is #{inspect(strips)}. Without the ladder engaged this test is \
      measuring an ordinary pane click.
      """

      [strip_id] = strips

      assert strip_id == List.last(before_ids), """
      the surviving strip is not the pane the user drilled FROM \
      (#{inspect(strip_id)} vs #{inspect(List.last(before_ids))}).
      """

      element(view, "##{strip_id}") |> render_click()

      # CONTRAST CONTROL (second of two): the strip's own event IS
      # history-bearing. This is the assertion that reds when `push_patch` is
      # removed from `expand_pane/2`.
      path = assert_patch(view)
      assert is_binary(path) and path != "", "the strip click did not patch"

      after_html = render(view)
      assigns = live_assigns(view)

      # 1 — the pane row came all the way back, not part-way.
      assert pane_ids(after_html) == before_ids, """
      the strip click did not restore the rail. Before: #{inspect(before_ids)} \
      after: #{inspect(pane_ids(after_html))}. D180 rules this click a \
      DOCUMENT-CLOSE: with no editor left there is nothing for the rail to \
      yield to, so every pane returns to `:full`.
      """

      # 2 — the DOCUMENT is closed. This is the half the task's own two
      # predicted outcomes both missed.
      assert editor_body_tag(after_html) == "", """
      the editor survived the strip click. Measured: `editor open AFTER: false` \
      — the strip closes the whole document, it does not merely dismiss the \
      inspector.
      """

      assert assigns[:editor_doc] == nil, "the editor doc assign survived the document close"

      # 3 — the reset chain really ran. Pinning pane ids alone is NOT enough:
      # it stays green if `clear_paper_view/1` stops calling
      # `sidebar_assigns(nil)`, which is the exact transitive step D180's
      # ruling rests on. And the scoped `<aside>` refutation cannot carry this
      # either — with the document closed there is no `<aside>` to scope to, so
      # the refutation would be vacuously true. The assign is the only honest
      # witness here.
      assert assigns[:sidebar_user_opened] == false, """
      `sidebar_user_opened` is #{inspect(assigns[:sidebar_user_opened])}, not \
      false. D180's ruling is that `expand-pane` implies dismiss TRANSITIVELY, \
      via push_patch -> handle_params -> rebuild_panes -> the fall-through -> \
      `clear_paper_view/1` -> `sidebar_assigns(nil)`. If that chain is broken \
      the strip stops implying dismiss and the collision spd-b47 was filed \
      about becomes real.
      """
    end
  end
end
