defmodule BarkparkWeb.Studio.DeskLeaveGuard.HaltOnFail do
  @moduledoc false
  # Refuses any write whose title holds "FAIL": the title typing is held
  # unsaved in the form.
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(%{doc: doc}) do
    title = get_in(doc, ["title"]) || get_in(doc, ["content", "title"])
    if is_binary(title) and String.contains?(title, "FAIL"), do: {:halt, "test"}, else: :ok
  end

  def halt(_), do: :ok
end

defmodule BarkparkWeb.Studio.DeskLeaveGuardTest do
  @moduledoc """
  task-33cbb6269c8823ad: a desk pane navigation from a document with a held
  field (typing a save refused, or rich text held over another editor's
  rewrite) dropped what was held with no word: the next document's form
  replaced it. A tab close or reload asked only over "Save failed".

  The edit pane now carries `data-desk-held`, the question `bp-desk.js` asks
  before a link leaves the document and before the tab closes or reloads
  (TanStack's `hasUnsaved()` beforeunload, `lib/edits.ts`), and
  `data-desk-held-doc`, the document a link may keep. Neither is drawn while
  nothing is held.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias BarkparkWeb.Studio.Desk.LeaveGuard
  alias BarkparkWeb.Studio.DeskLeaveGuard.HaltOnFail

  @pane "[data-pane-editing]"
  @held ~s([data-pane-editing][data-desk-held])

  setup %{conn: conn} do
    prior = Barkpark.PluginEnv.capture()
    Barkpark.PluginEnv.put!([HaltOnFail])
    on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)
    setup_doc(conn)
  end

  # The page's own post: every value the form holds, with the title typed.
  defp post_title(view, title) do
    view
    |> form("#editor-form", %{"doc" => %{"title" => title}})
    |> render_change(%{"_target" => ["doc", "title"]})
  end

  defp held_attr(view, name) do
    [value] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(@pane)
      |> LazyHTML.attribute(name)

    value
  end

  test "a held title: the pane asks before leaving, naming the field", c do
    a = open(c)
    refute has_element?(a, @held)

    post_title(a, "T0 FAIL")

    assert eventually(fn -> has_element?(a, @held) end)
    assert held_attr(a, "data-desk-held") =~ "Not saved: Title"
    assert held_attr(a, "data-desk-held-doc") == c.id
  end

  test "held rich text: the pane asks before leaving, naming the field", c do
    a = open(c)
    b = open(c)
    refute has_element?(a, @held)

    held_by_clash(a, b, c)

    assert has_element?(a, @held)
    assert held_attr(a, "data-desk-held") =~ "Not saved: Meta"
  end

  test "control: a save that lands holds nothing, and the pane does not ask", c do
    a = open(c)
    post_title(a, "T0 FAIL")
    assert eventually(fn -> has_element?(a, @held) end)

    post_title(a, "T0 fixed")

    assert eventually(fn -> not has_element?(a, @held) end)
  end

  describe "the desk's own dialog before leaving a held field" do
    @dialog ~s([data-desk-dialog="leave"])

    defp held(c) do
      a = open(c)
      post_title(a, "T0 FAIL")
      assert eventually(fn -> has_element?(a, @held) end)
      a
    end

    defp to_doc(c, id), do: "#{c.root}/_desk/#{c.type};#{id}"

    # What the form holds for the title, and the document it is for.
    defp title(view),
      do: view |> element(~s(#editor-form input[name="doc[title]"])) |> render() |> attr("value")

    defp attr(html, name),
      do: html |> LazyHTML.from_fragment() |> LazyHTML.attribute(name) |> hd()

    defp asks!(view) do
      assert has_element?(view, @dialog)
      assert view |> element(@dialog) |> render() =~ "Not saved: Title"
      # Nothing was put away: the held text and its hold are where they were.
      assert title(view) == "T0 FAIL"
      assert has_element?(view, @held)
    end

    test "a row, a breadcrumb, a pane's ×: the link is held back and asks; Leave follows it", c do
      a = held(c)
      to = to_doc(c, c.id <> "-link")

      render_hook(a, "desk-leave", %{"href" => to, "kind" => "patch"})
      asks!(a)

      a |> element(~s(#{@dialog} button[phx-click="desk-leave-go"])) |> render_click()
      assert_patch(a, to)
      assert eventually(fn -> title(a) == "T0" end)
    end

    test "a restore that lands ends the hold: a row click goes on at once", c do
      a = open(c)
      post_title(a, "T1")
      # The landed save made a revision; the next typing is held.
      post_title(a, "T1 FAIL")
      assert eventually(fn -> has_element?(a, @held) end)

      [rev | _] =
        Barkpark.Content.list_revisions(c.id, c.type, "production", limit: 30) |> Enum.reverse()

      a
      |> element(~s{[data-pane-editing] button[phx-click="show-history"]:not([role="menuitem"])})
      |> render_click()

      BarkparkWeb.EditorPost.press_on(
        a,
        element(
          a,
          ~s(#history-modal-dialog button[phx-click="restore-revision"][phx-value-id="#{rev.id}"])
        )
      )

      assert render(a) =~ "Restored from history"
      refute has_element?(a, @held)

      to = to_doc(c, c.id <> "-link")
      render_hook(a, "desk-leave", %{"href" => to, "kind" => "patch"})
      assert_patch(a, to)
      refute has_element?(a, @dialog)
    end

    test "control: a held-back desk link that keeps the document goes on at once", c do
      a = held(c)
      to = to_doc(c, c.id) <> ",inspect=on"

      render_hook(a, "desk-leave", %{"href" => to, "kind" => "patch"})
      assert_patch(a, to)
      refute has_element?(a, @dialog)
      assert title(a) == "T0 FAIL"
    end

    test "Back (any patch the page did not hold back) to another document asks", c do
      a = held(c)
      render_patch(a, to_doc(c, c.id <> "-link"))
      asks!(a)
    end

    test "Enter on a search hit asks", c do
      a = held(c)
      render_change(a |> element("#desk-search-form"), %{"value" => "T0"})

      assert eventually(fn ->
               a
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("a[data-desk-hit]")
               |> Enum.count() == 2
             end)

      lit =
        a
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("a[data-desk-hit]")
        |> LazyHTML.attribute("href")
        |> Enum.find_index(&String.ends_with?(&1, ";" <> c.id <> "-link"))

      render_submit(a |> element("#desk-search-form"), %{"value" => "T0", "lit" => "#{lit}"})
      asks!(a)
    end

    test "Create new asks before anything is made", c do
      a = held(c)
      count = fn -> length(Barkpark.Content.list_documents(c.type, "production")) end
      before = count.()

      render_hook(a, "new-document", %{"type" => c.type})

      asks!(a)
      assert count.() == before
    end

    test "Stay keeps everything and puts the URL back", c do
      a = held(c)
      render_patch(a, to_doc(c, c.id <> "-link"))
      asks!(a)

      a
      |> element(~s(#{@dialog} button[phx-click="desk-leave-stay"][data-modal-focus]))
      |> render_click()

      assert_patch(a, to_doc(c, c.id))
      assert_push_event(a, "bp:desk-leave-stayed", %{})
      refute has_element?(a, @dialog)
      assert title(a) == "T0 FAIL"
      assert has_element?(a, @held)
      assert held_attr(a, "data-desk-held-doc") == c.id
    end

    test "Leave opens what was asked for", c do
      a = held(c)
      render_patch(a, to_doc(c, c.id <> "-link"))
      a |> element(~s(#{@dialog} button[phx-click="desk-leave-go"])) |> render_click()

      refute has_element?(a, @dialog)
      assert eventually(fn -> has_element?(a, "#editor-form") and title(a) == "T0" end)
      refute has_element?(a, @held)
      # The next navigation asks again only if something is held again.
      render_patch(a, to_doc(c, c.id))
      refute has_element?(a, @dialog)
    end

    test "Leave on Create new makes the new document", c do
      a = held(c)
      render_hook(a, "new-document", %{"type" => c.type})
      a |> element(~s(#{@dialog} button[phx-click="desk-leave-go"])) |> render_click()

      refute has_element?(a, @dialog)
      assert_patch(a)
    end

    test "a link that leaves the page: Leave is that link, and only a path on this site", c do
      a = held(c)

      render_hook(a, "desk-leave", %{"href" => "https://evil.example/x", "kind" => "redirect"})
      render_hook(a, "desk-leave", %{"href" => "//evil.example/x", "kind" => "redirect"})
      refute has_element?(a, @dialog)

      render_hook(a, "desk-leave", %{"href" => "#{c.root}/structure", "kind" => "redirect"})
      asks!(a)

      assert has_element?(
               a,
               ~s|#{@dialog} a[data-desk-leave-go][data-phx-link="redirect"][href="#{c.root}/structure"]|
             )

      render_hook(a, "desk-leave", %{"href" => "/papers", "kind" => ""})

      assert has_element?(
               a,
               ~s|#{@dialog} a[data-desk-leave-go][href="/papers"]:not([data-phx-link])|
             )
    end

    # task-5455fd7fe69eb386: `push_patch/2` raises on a path that is not a
    # route of the desk's LiveView, and the socket died with it. Such a
    # "patch" goes as a page load.
    test "a patch to a path the desk does not route is a page load; the LiveView lives", c do
      for href <- ["/no-such-route-5455", "/%2F%2Fevil.example", "/papers"] do
        a = held(c)
        render_hook(a, "desk-leave", %{"href" => href, "kind" => "patch"})
        asks!(a)

        assert has_element?(
                 a,
                 ~s|#{@dialog} a[data-desk-leave-go][href="#{href}"]:not([data-phx-link])|
               )

        assert Process.alive?(a.pid)

        a = open(c)

        assert {:error, {:redirect, %{to: ^href}}} =
                 render_hook(a, "desk-leave", %{"href" => href, "kind" => "patch"})
      end
    end

    test "control: nothing held, nothing asked", c do
      a = open(c)
      render_patch(a, to_doc(c, c.id <> "-link"))
      refute has_element?(a, @dialog)
      # A link held back as the hold ended goes, as it would have.
      assert {:error, {:redirect, %{to: "/papers"}}} =
               render_hook(a, "desk-leave", %{"href" => "/papers", "kind" => ""})
    end

    # #28408 review r2, 3: drawn among the desk's own children, the question
    # moved `#desk-panes` in the DOM, and the pane lost its scroll.
    test "the question is drawn in a box of its own, so the panes do not move", c do
      a = held(c)
      assert has_element?(a, "#dk-leave-host")
      refute has_element?(a, "#dk-leave-host > *")

      render_patch(a, to_doc(c, c.id <> "-link"))
      asks!(a)
      assert has_element?(a, "#dk-leave-host > #{@dialog}")
    end

    # #28408 review r2, note: the question stood empty once the hold ended.
    test "the question closes when the hold ends, as Stay", c do
      a = held(c)
      render_patch(a, to_doc(c, c.id <> "-link"))
      asks!(a)

      post_title(a, "T0 saved")

      assert eventually(fn -> not has_element?(a, @dialog) end)
      assert_patch(a, to_doc(c, c.id))
      assert_push_event(a, "bp:desk-leave-stayed", %{})
    end

    # #28408 review r2, note: Delete and Duplicate patch away once done.
    test "Delete does not ask after the fact", c do
      a = held(c)
      BarkparkWeb.EditorPost.press(a, "delete-doc", %{})

      BarkparkWeb.EditorPost.press_on(
        a,
        element(a, ~s([data-desk-dialog="delete"] button.danger), "Delete document")
      )

      assert_patch(a)
      refute has_element?(a, @dialog)
    end

    test "Duplicate does not ask after the fact", c do
      a = held(c)
      BarkparkWeb.EditorPost.press(a, "duplicate-doc", %{})
      landed = assert_patch(a, 2_000)
      refute landed == to_doc(c, c.id)
      refute has_element?(a, @dialog)
    end

    test "control: a patch that keeps the document does not ask", c do
      a = held(c)
      render_patch(a, to_doc(c, c.id) <> ",inspect=on")
      refute has_element?(a, @dialog)
      assert title(a) == "T0 FAIL"
    end
  end

  test "the question in Norwegian" do
    assigns = %{
      editor_unsaved_keys: MapSet.new(["title"]),
      editor_schema: %{fields: [%{"name" => "title", "title" => "Tittel"}]}
    }

    Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
      assert LeaveGuard.message(assigns) ==
               "Ikke lagret: Tittel. Det du skrev der, går tapt."

      html =
        render_component(&LeaveGuard.dialog/1,
          id: "x",
          leave: %{to: {:patch, %{}, "/"}, back: "/"},
          message: LeaveGuard.message(assigns)
        )

      assert html =~ "Forlate dokumentet?"
      assert html =~ "Bli her"
      assert html =~ "Forlat"
    end)
  end
end
