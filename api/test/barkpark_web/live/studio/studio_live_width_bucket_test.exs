defmodule BarkparkWeb.Studio.StudioLiveWidthBucketTest do
  @moduledoc """
  studio-space-priority-desk spd-s4 — the bucket RECONCILIATION.

  spd-s2 proved the seam (the `width-bucket` event lands an assign);
  spd-s3 proved the table (`PaneBuilder.display_state/4`). This file proves
  they are actually WIRED to the rendered desk:

    * `#studio-panes` carries `phx-hook="WidthBucket"` — without it the hook
      registered in root.html.heex never mounts and the whole slice is inert.
    * The event, pushed at the hooked ELEMENT on a NON-admin socket, moves the
      assign (the `Caps.@safe_events` classification is non-vacuous here: an
      unclassified event is halted before the handler for a non-admin socket).
    * `"wide"` renders the pre-spd-s4 pane DOM for the default open-document
      state — the zero-desktop-change law (D7).
    * `"narrow"` with a document open collapses the whole nav row to ONE 44px
      back strip (charter D35 — the rule that actually closes the 640–1023
      overflow band; the briefed "keep the last pane full" rule was measured
      bit-identical to `collapse?/3` and removed zero pixels).
    * `"phone"` with a document open renders NO pane column at all.
    * Every `.editor-panel` root carries `data-role="content"` (D42) with its
      class attribute untouched (`studio_live_editor_test.exs:277` asserts the
      exact substring `class="editor-panel"`).
    * The pane DOM id stays derived purely from the pane title at every bucket
      (D45 — it is what lets spd-s5's collapse animation morph the node instead
      of replacing it).

  Assertions run on the rendered HTML string (there is no Floki in this app's
  deps) plus `has_element?/2`, which uses LiveViewTest's own DOM engine.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.TenancyFixtures

  @dataset "production"
  # A READ-ONLY token → a clearly NON-admin socket. If `width-bucket` were
  # unclassified it would require admin and be halted, so a moved assign is a
  # non-vacuous classification proof (spd-s2's law, re-pinned at the call site).
  @readonly "spd-s4-readonly"

  setup %{conn: conn} do
    {_ws, _proj} = TenancyFixtures.ensure_default_scope!()
    {:ok, _} = Auth.create_token(@readonly, "spd-s4 readonly", @dataset, ["read"])

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

  # The desk with a document OPEN — the state the whole epic is about: the
  # content pane is on the row, so the nav columns compete with its 560px
  # protected floor. (Root desk pane + the post type list = 2 panes.)
  defp open_doc(conn), do: live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))

  defp readonly_desk(conn) do
    conn
    |> Plug.Test.init_test_session(%{"api_token" => @readonly})
    |> live(scoped_studio("/d/#{@dataset}/studio"))
  end

  defp bucket_assign(view), do: :sys.get_state(view.pid).socket.assigns.width_bucket

  # Push the bucket THROUGH the hooked element, not at the view — this is what
  # proves the hook target actually exists in the rendered DOM.
  defp set_bucket(view, bucket) do
    view
    |> element("#studio-panes")
    |> render_hook("width-bucket", %{"bucket" => bucket})
  end

  defp count(html, pattern), do: html |> then(&Regex.scan(pattern, &1)) |> length()

  # Both column shapes open with `class="pane-column`, so this counts every
  # rendered nav pane (full + collapsed strip). The lookahead is load-bearing:
  # a collapsed strip also contains `class="pane-column-collapsed-label"`,
  # which would double-count every strip.
  defp pane_count(html), do: count(html, ~r/class="pane-column(?=[ "])/)
  defp strip_count(html), do: count(html, ~r/class="pane-column pane-column--collapsed"/)

  defp pane_ids(html) do
    ~r/id="(pane-[^"]*)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> id end)
  end

  describe "the hook is live on the pane row" do
    test "#studio-panes carries phx-hook=\"WidthBucket\"", %{conn: conn} do
      {:ok, view, _html} = open_doc(conn)

      assert has_element?(view, ~s(#studio-panes[phx-hook="WidthBucket"])),
             "the WidthBucket hook must be mounted on #studio-panes, or the whole " <>
               "reconciliation is inert"
    end

    test "the Studio desk mounts exactly ONE WidthBucket hook", %{conn: conn} do
      # The hook is a Studio-desk affordance (the API tester's pane_layout stays
      # hook-less). A second element wearing the same hook would push a
      # competing bucket at every resize.
      {:ok, _view, html} = open_doc(conn)
      assert count(html, ~r/phx-hook="WidthBucket"/) == 1
    end

    test "the event pushed at the element moves the assign on a NON-admin socket", %{conn: conn} do
      {:ok, view, _html} = readonly_desk(conn)
      assert bucket_assign(view) == "wide"

      set_bucket(view, "narrow")
      assert bucket_assign(view) == "narrow"

      for band <- ~w(phone standard narrow wide) do
        set_bucket(view, band)
        assert bucket_assign(view) == band
      end
    end
  end

  describe "the pane row reconciles with the bucket" do
    test "wide is the zero-change default (D7)", %{conn: conn} do
      {:ok, view, html} = open_doc(conn)

      # Mount seeds "wide", so the STATIC first render is already the desktop
      # DOM — no flash, no round-trip, nothing for the hook to correct on a
      # desktop viewport.
      assert bucket_assign(view) == "wide"

      # collapse?/3 verbatim for 2 panes + an editor: [:strip, :full].
      assert pane_count(html) == 2
      assert strip_count(html) == 1
    end

    test "narrow + open document leaves exactly ONE 44px back strip (D35)", %{conn: conn} do
      {:ok, view, wide_html} = open_doc(conn)
      wide_panes = pane_count(wide_html)

      narrow_html = set_bucket(view, "narrow")

      assert pane_count(narrow_html) == 1,
             "narrow with a document open must render exactly one pane (the back strip), " <>
               "got #{pane_count(narrow_html)} — the wide desk had #{wide_panes}"

      assert strip_count(narrow_html) == 1,
             "the surviving pane must be the 44px strip, not a full column"

      # It is a real back affordance, not decoration.
      assert has_element?(view, ~s(.pane-column--collapsed[phx-click="expand-pane"]))
    end

    test "the narrow back strip actually navigates BACK when clicked (D35/D46)", %{conn: conn} do
      # spd-s4 PROMOTES this strip to the ONLY navigation affordance on the
      # narrow desk, so "it carries phx-click" is not enough — the click has to
      # land somewhere useful. `expand_pane` truncates nav_path to the clicked
      # index, which for the last pane means "the same list, no document", so
      # the editor closes and the full nav row comes back. If a future edit
      # changed phx-value-idx (or expand_pane's take/2 arithmetic) the strip
      # would silently become a no-op and this is the only test that notices.
      {:ok, view, wide_html} = open_doc(conn)
      assert wide_html =~ ~s(class="editor-panel")
      wide_panes = pane_count(wide_html)

      set_bucket(view, "narrow")

      after_click = view |> element(".pane-column--collapsed") |> render_click()

      refute after_click =~ ~s(class="editor-panel"),
             "clicking the narrow back strip must close the document — it is the only " <>
               "way out of the drilled state at that width"

      assert pane_count(after_click) == wide_panes,
             "with the document closed the narrow row must restore its nav columns, " <>
               "got #{pane_count(after_click)} of #{wide_panes}"
    end

    test "narrow WITHOUT a document keeps its full drill column", %{conn: conn} do
      # The editor-closed row has no 560px floor and never overflowed, so it
      # must NOT lose its content — this is what stops D35 from over-reaching.
      {:ok, view, _html} = readonly_desk(conn)
      narrow_html = set_bucket(view, "narrow")

      assert pane_count(narrow_html) >= 1
      assert pane_count(narrow_html) > strip_count(narrow_html)
    end

    test "phone + open document renders no pane column at all", %{conn: conn} do
      {:ok, view, _html} = open_doc(conn)

      phone_html = set_bucket(view, "phone")
      assert pane_count(phone_html) == 0

      # The document itself is still there — the panes yielded, nothing broke.
      assert phone_html =~ ~s(class="editor-panel")
    end

    test "the desk survives a full bucket round-trip back to wide", %{conn: conn} do
      {:ok, view, wide_html} = open_doc(conn)
      before = pane_count(wide_html)

      set_bucket(view, "phone")
      set_bucket(view, "narrow")
      after_html = set_bucket(view, "wide")

      assert pane_count(after_html) == before,
             "returning to wide must restore the desktop pane set exactly"

      assert strip_count(after_html) == strip_count(wide_html)
    end

    test "the pane DOM id derives purely from the title at EVERY bucket (D45)", %{conn: conn} do
      {:ok, view, wide_html} = open_doc(conn)
      wide_ids = pane_ids(wide_html)

      narrow_ids = pane_ids(set_bucket(view, "narrow"))

      # The narrow row is a SUBSET of the wide row's ids — never a renamed
      # node. A display-derived id would make LiveView REPLACE the node rather
      # than morph it, which forecloses spd-s5's collapse animation.
      assert wide_ids != []
      assert narrow_ids != []

      assert Enum.all?(narrow_ids, &(&1 in wide_ids)),
             "#{inspect(narrow_ids)} is not a subset of #{inspect(wide_ids)} — the pane id " <>
               "moved with display state"
    end
  end

  describe "anatomy stamps" do
    test "the content root carries data-role=\"content\" with class untouched (D42)", %{
      conn: conn
    } do
      {:ok, view, html} = open_doc(conn)

      assert has_element?(view, ~s(.editor-panel[data-role="content"])),
             ~s(the open document's .editor-panel must be stamped data-role="content")

      # The stamp is a SEPARATE attribute — studio_live_editor_test.exs:277
      # asserts the exact substring `class="editor-panel"` and a second class
      # token would break it.
      assert html =~ ~s(class="editor-panel")
    end

    test "every rendered .editor-panel is stamped (no silent split, D29/D42)", %{conn: conn} do
      {:ok, _view, html} = open_doc(conn)

      panels = count(html, ~r/class="editor-panel/)
      stamped = count(html, ~r/data-role="content"/)

      assert panels > 0

      assert panels == stamped,
             "#{panels - stamped} .editor-panel root(s) render without data-role=\"content\" " <>
               "— a subset stamp is exactly the silent split D29 forbids"
    end

    test "pane columns carry role + priority stamps", %{conn: conn} do
      {:ok, view, html} = open_doc(conn)

      assert has_element?(view, ~s(.pane-column[data-role="nav"])) or
               has_element?(view, ~s(.pane-column[data-role="list"]))

      assert count(html, ~r/data-priority="/) > 0
    end

    test "every .bp-doc-sidebar render site is stamped data-role=\"inspector\"" do
      # The inspector sidebar renders only on the PAPER editor path, which this
      # file's `post` fixture never reaches — a `if has_element?(…)` guard here
      # would pass vacuously forever. So the stamp is pinned at SOURCE instead:
      # every place that emits a `bp-doc-sidebar` class must carry the role, or
      # the D12 inspector-overlay rules (which key on `[data-role="inspector"]`)
      # would skip a real sidebar. Text-based on purpose — there is no rendered
      # fixture for this surface in this suite.
      source = File.read!("lib/barkpark_web/live/studio/studio_live/components.ex")

      sites =
        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> line =~ ~s(class={"bp-doc-sidebar) end)

      assert sites != [],
             "no bp-doc-sidebar render site found — this guard has drifted off its subject"

      for {_line, lineno} <- sites do
        window =
          source
          |> String.split("\n")
          |> Enum.slice(max(lineno - 1, 0), 8)
          |> Enum.join("\n")

        assert window =~ ~s(data-role="inspector"),
               "the bp-doc-sidebar at components.ex:#{lineno} is not stamped " <>
                 ~s(data-role="inspector" — D12's overlay rules would skip it)
      end
    end
  end
end
