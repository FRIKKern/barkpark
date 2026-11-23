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

    test "Back (or a row, a breadcrumb, a pane's ×): a patch to another document asks", c do
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

      render_hook(a, "desk-leave", %{"href" => "https://evil.example/x", "live" => true})
      render_hook(a, "desk-leave", %{"href" => "//evil.example/x", "live" => true})
      refute has_element?(a, @dialog)

      render_hook(a, "desk-leave", %{"href" => "#{c.root}/structure", "live" => true})
      asks!(a)

      assert has_element?(
               a,
               ~s|#{@dialog} a[data-desk-leave-go][data-phx-link="redirect"][href="#{c.root}/structure"]|
             )

      render_hook(a, "desk-leave", %{"href" => "/papers", "live" => false})

      assert has_element?(
               a,
               ~s|#{@dialog} a[data-desk-leave-go][href="/papers"]:not([data-phx-link])|
             )
    end

    test "control: nothing held, nothing asked", c do
      a = open(c)
      render_patch(a, to_doc(c, c.id <> "-link"))
      refute has_element?(a, @dialog)
      render_hook(a, "desk-leave", %{"href" => "/papers", "live" => false})
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
               "Ikke lagret: Tittel. Vil du forlate dokumentet likevel? Det du skrev der, går tapt."

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
