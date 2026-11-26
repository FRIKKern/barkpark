defmodule BarkparkWeb.Studio.StudioBackLeaveDialogTest do
  # task-5b4914f1b5f21594: in Studio, browser Back with a held field left the
  # document with no question. Back is a popstate that LiveView turns into
  # handle_params, so the held form was read again from the store and A's
  # words were gone. Studio now asks with the desk's dialog
  # (`Desk.LeaveGuard.dialog/1`, `StudioLive.LeaveAsk`), naming the field;
  # Stay patches the URL back and keeps A's words.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.ObjectRichText
  alias BarkparkWeb.Studio.StudioLive.LeaveAsk

  @dataset "production"
  @dialog "#studio-leave-dialog"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "back_leave_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Back leave",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "back-leave-#{n}"

    for {doc_id, notes} <- [{id, "one two three"}, {id <> "-2", "second"}] do
      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => doc_id, "title" => "T0", "content" => %{"notes" => notes}},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "back-leave-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "back-leave", @dataset, ~w(read write admin), ws_id)
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     doc: "#{root}/#{type}/#{id}",
     other: "#{root}/#{type}/#{id}-2"}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.doc)
    render_async(view, 5_000)
    assert ObjectRichText.eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp posts(view, notes) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc[notes]"],
      "doc" => %{"title" => "T0", "notes" => notes},
      "_bp_seen" => Jason.encode!(%{"v" => 2})
    })
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
  defp open_id(view), do: Content.published_id(assigns(view).editor_doc.doc_id)

  # A held: B's save lands under A's post, rewriting the same letter.
  defp hold(c) do
    {a, b} = {open(c), open(c)}

    ObjectRichText.inside(a, fn -> posts(b, "one twB three") end, fn ->
      posts(a, "one twA three")
    end)

    assert has_element?(a, ~s([data-test-id="doc-conflict-banner"]))
    a
  end

  # Stay is the dialog's own button, not the header's close (also Stay).
  defp press(view, "desk-leave-stay"),
    do:
      view
      |> element(~s(#{@dialog} button[phx-click="desk-leave-stay"][data-modal-focus]))
      |> render_click()

  defp press(view, button),
    do: view |> element(~s(#{@dialog} button[phx-click="#{button}"])) |> render_click()

  test "Back to another document with a held field asks with the desk's dialog, naming the field; A's words kept",
       c do
    a = hold(c)

    # On main: the editor read the second document, A's words gone.
    render_patch(a, c.other)

    assert has_element?(a, @dialog, "Leave this document?")
    assert has_element?(a, @dialog, "Not saved: Notes. What you typed there will be lost.")
    assert open_id(a) == c.id
    assert assigns(a).editor_form["notes"] == "one twA three"
  end

  test "Stay patches the URL back to the document and keeps A's words", c do
    a = hold(c)
    render_patch(a, c.other)

    press(a, "desk-leave-stay")

    assert_patch(a, c.doc)
    refute has_element?(a, @dialog)
    assert open_id(a) == c.id
    assert assigns(a).editor_form["notes"] == "one twA three"
    assert has_element?(a, "form#editor-form[data-studio-held]")
  end

  test "Leave goes on with the patch: the other document opens", c do
    a = hold(c)
    render_patch(a, c.other)

    press(a, "desk-leave-go")

    assert open_id(a) == c.id <> "-2"
    assert assigns(a).editor_form["notes"] == "second"
    refute has_element?(a, @dialog)
  end

  test "Stay's mark is one patch: Back again after Stay asks again", c do
    a = hold(c)
    render_patch(a, c.other)
    press(a, "desk-leave-stay")
    assert_patch(a, c.doc)

    render_patch(a, c.other)

    assert has_element?(a, @dialog)
    assert open_id(a) == c.id
    assert assigns(a).editor_form["notes"] == "one twA three"
  end

  test "Stay's mark is one patch: a later patch to the same document reads it again, as before",
       c do
    a = hold(c)
    render_patch(a, c.other)
    press(a, "desk-leave-stay")
    assert_patch(a, c.doc)

    render_patch(a, c.doc)

    assert ObjectRichText.eventually(fn -> assigns(a).editor_form["notes"] == "one twB three" end)
    refute has_element?(a, @dialog)
  end

  test "the hold ends under the open question: it closes, and the URL goes back", c do
    a = hold(c)
    render_patch(a, c.other)
    assert has_element?(a, @dialog)

    posts(a, "one twAA three")

    assert ObjectRichText.eventually(fn -> not has_element?(a, @dialog) end)
    assert_patch(a, c.doc)
    assert open_id(a) == c.id
  end

  # task-eac6c592: Forward to the held document closed the question with no
  # word and drew the stored document over A's words.
  test "Back, then Forward to the held document: Stay, A's words still held", c do
    a = hold(c)
    render_patch(a, c.other)
    assert has_element?(a, @dialog)

    render_patch(a, c.doc)
    refute has_element?(a, @dialog)
    assert open_id(a) == c.id
    assert assigns(a).editor_form["notes"] == "one twA three"
    assert has_element?(a, ~s([data-test-id="doc-conflict-banner"]))

    # Still held: Back again asks again.
    render_patch(a, c.other)
    assert has_element?(a, @dialog, "Not saved: Notes.")
  end

  test "Back, then a patch to a third document: it still asks", c do
    a = hold(c)
    render_patch(a, c.other)
    assert has_element?(a, @dialog)

    render_patch(a, c.doc <> "-3")
    assert has_element?(a, @dialog, "Not saved: Notes.")
    assert open_id(a) == c.id
    assert assigns(a).editor_form["notes"] == "one twA three"
  end

  test "nothing held: Back goes on, nothing asked", c do
    a = open(c)
    render_patch(a, c.other)
    refute has_element?(a, @dialog)
    assert open_id(a) == c.id <> "-2"
  end

  # A link bp-studio-leave.js held back reaches the server through the
  # bridge button (`studio-leave`, PR 2): the dialog asks for it, as for Back.
  describe "a link held back" do
    test "the bridge the script clicks is on the page", c do
      a = open(c)
      assert has_element?(a, ~s(button#studio-leave-ask[phx-click="studio-leave"][hidden]))
    end

    test "held, a patch link asks; Leave makes the patch", c do
      a = hold(c)
      render_click(a, "studio-leave", %{"href" => c.other, "kind" => "patch"})

      assert has_element?(a, @dialog, "Not saved: Notes.")
      assert open_id(a) == c.id

      press(a, "desk-leave-go")
      assert_patch(a, c.other)
      assert open_id(a) == c.id <> "-2"
    end

    test "held, a page link asks; Leave is that link, marked so the unload does not ask again",
         c do
      a = hold(c)
      render_click(a, "studio-leave", %{"href" => "/papers", "kind" => ""})

      assert has_element?(
               a,
               ~s|#{@dialog} a[data-desk-leave-go][href="/papers"]:not([data-phx-link])|
             )

      render_click(a, "studio-leave", %{"href" => c.other, "kind" => "redirect"})

      assert has_element?(
               a,
               ~s|#{@dialog} a[data-desk-leave-go][data-phx-link="redirect"][href="#{c.other}"]|
             )

      assert open_id(a) == c.id
    end

    test "Stay on a link: the question closes, nothing moves", c do
      a = hold(c)
      render_click(a, "studio-leave", %{"href" => c.other, "kind" => "patch"})
      press(a, "desk-leave-stay")

      refute has_element?(a, @dialog)
      assert open_id(a) == c.id
      assert assigns(a).editor_form["notes"] == "one twA three"
    end

    test "nothing held: the link goes on at once", c do
      a = open(c)
      render_click(a, "studio-leave", %{"href" => c.other, "kind" => "patch"})
      assert_patch(a, c.other)

      assert {:error, {:redirect, %{to: "/papers"}}} =
               render_click(a, "studio-leave", %{"href" => "/papers", "kind" => ""})
    end

    test "a path with a space or control byte goes nowhere (a browser reads /<TAB>/x as //x)",
         c do
      a = hold(c)

      for href <- [
            "/\t/evil.example/x",
            "/\n/evil.example/x",
            "/\r/evil.example/x",
            "/ /evil.example/x",
            "/\0/evil.example/x",
            "/papers\t"
          ] do
        render_click(a, "studio-leave", %{"href" => href, "kind" => ""})
        refute has_element?(a, @dialog), inspect(href)
      end

      assert open_id(a) == c.id
    end

    test "a path that is not this site's goes nowhere", c do
      a = hold(c)
      render_click(a, "studio-leave", %{"href" => "//evil.example/x", "kind" => ""})
      refute has_element?(a, @dialog)
      assert open_id(a) == c.id
    end
  end

  describe "LeaveAsk.params/4" do
    # The mark is read on the very next patch and never again, and it only
    # stops a patch to the place it names.
    defp socket(held?, mark) do
      assigns = %{
        __changed__: %{},
        flash: %{},
        dataset: "production",
        nav_path: ["post", "a"],
        nav_desk: nil,
        studio_leave: nil,
        studio_leave_pass: false,
        studio_leave_return: mark,
        studio_leave_uri: "/studio/post/a",
        editor_doc: %{doc_id: "drafts.a"},
        editor_schema: %{fields: [%{"name" => "notes", "title" => "Notes"}]},
        editor_unsaved_keys: MapSet.new(if held?, do: ["notes"], else: [])
      }

      %Phoenix.LiveView.Socket{assigns: assigns}
    end

    @here {"production", ["post", "a"], nil}
    @there {"production", ["post", "b"], nil}

    test "a mark never stops a patch to another place: held, it asks; not held, it goes" do
      assert {:stop, s} = LeaveAsk.params(socket(true, @here), %{}, "/studio/post/b", @there)
      assert %{to: {:patch, _, "/studio/post/b"}, back: "/studio/post/a"} = s.assigns.studio_leave
      assert s.assigns.studio_leave_return == nil

      assert {:route, s} = LeaveAsk.params(socket(false, @here), %{}, "/studio/post/b", @there)
      assert s.assigns.studio_leave_return == nil
    end

    test "the mark stops one patch to its place, then goes" do
      assert {:stop, s} = LeaveAsk.params(socket(true, @here), %{}, "/studio/post/a", @here)
      assert s.assigns.studio_leave == nil
      assert s.assigns.studio_leave_return == nil

      assert {:route, _} = LeaveAsk.params(s, %{}, "/studio/post/a", @here)
    end
  end
end
