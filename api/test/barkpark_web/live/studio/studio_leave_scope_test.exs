defmodule BarkparkWeb.Studio.StudioLeaveScopeTest do
  @moduledoc """
  task-bc40f41b69eb4d9a: a Back into another project while a field is held.
  LiveScope's `reauthorize/3` moves `current_project` to the new place before
  the Studio or the desk asks, and the held document stays open under the
  question. On main a save from it then wrote a copy of the document in the
  other project. `LeaveScope` refuses every write-tier press while the
  question is open over that move; Stay puts the scope back, and Leave goes
  on to the other document under its own scope.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Repo}
  alias BarkparkWeb.ObjectRichText
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.{LeaveScope, Shared}

  @ds "production"
  @leave_events ~w(desk-leave desk-leave-stay desk-leave-go studio-leave)
  @heads [
    "lib/barkpark_web/live/studio/studio_live.ex",
    "lib/barkpark_web/live/studio/desk_live.ex"
  ]

  defp schema!(opts) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @ds,
        opts
      )
  end

  setup do
    ws = create_workspace!("lsc-#{System.unique_integer([:positive])}")
    p1 = create_project!(ws, "lsc-one")
    p2 = create_project!(ws, "lsc-two")

    for {p, id} <- [{p1, "kept-doc"}, {p2, "other-doc"}] do
      opts = [workspace_id: ws.id, project_id: p.id]
      schema!(opts)

      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "title" => "T0", "content" => %{"notes" => "one two three"}},
          @ds,
          opts
        )
    end

    conn = fn ->
      raw = "lsc-" <> Ecto.UUID.generate()
      {:ok, _} = Auth.create_token(raw, "lsc", @ds, ~w(read write admin), ws.id)
      Plug.Test.init_test_session(scoped_conn(), %{"api_token" => raw})
    end

    {:ok, ws: ws, p1: p1, p2: p2, conn: conn, base: "/w/#{ws.slug}/p/"}
  end

  defp at(c, :studio, :one), do: c.base <> "lsc-one/d/#{@ds}/studio/post/kept-doc"
  defp at(c, :studio, :two), do: c.base <> "lsc-two/d/#{@ds}/studio/post/other-doc"
  defp at(c, :desk, :one), do: c.base <> "lsc-one/d/#{@ds}/studio/_desk/post;kept-doc"
  defp at(c, :desk, :two), do: c.base <> "lsc-two/d/#{@ds}/studio/_desk/post;other-doc"

  defp dialog(:studio), do: "#studio-leave-dialog"
  defp dialog(:desk), do: ~s([data-desk-dialog="leave"])

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    assert ObjectRichText.eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp posts(view, title, notes, target \\ "doc[title]") do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => %{"title" => title, "notes" => notes},
      "_bp_seen" => Jason.encode!(%{"v" => 2})
    })
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # The editor still holds P1's kept-doc, with A's held words in the form.
  defp held_p1?(view, c) do
    %{editor_doc: doc, editor_form: form} = assigns(view)

    doc != nil and {doc.doc_id, doc.project_id} == {"drafts.kept-doc", c.p1.id} and
      form["notes"] == "one twA three"
  end

  # {doc_id, project_id, title} of every post row.
  defp rows do
    Repo.all(
      from(d in Content.Document,
        where: d.type == "post",
        select: {d.doc_id, d.project_id, d.title},
        order_by: [d.project_id, d.doc_id]
      )
    )
  end

  # A holds the notes of P1's kept-doc against B, then Back into P2.
  defp asked(c, surface) do
    a = open(c.conn.(), at(c, surface, :one))
    b = open(c.conn.(), at(c, surface, :one))

    ObjectRichText.inside(a, fn -> posts(b, "T0", "one twB three", "doc[notes]") end, fn ->
      posts(a, "T0", "one twA three", "doc[notes]")
    end)

    assert has_element?(a, ~s([data-test-id="doc-conflict-banner"]))
    before = rows()

    render_patch(a, at(c, surface, :two))
    assert has_element?(a, dialog(surface))
    assert assigns(a).current_project.id == c.p2.id
    assert assigns(a).editor_doc.project_id == c.p1.id
    {a, before}
  end

  defp press(a, surface, "desk-leave-stay"),
    do:
      a
      |> element(~s(#{dialog(surface)} button[phx-click="desk-leave-stay"][data-modal-focus]))
      |> render_click()

  defp press(a, surface, button),
    do: a |> element(~s(#{dialog(surface)} button[phx-click="#{button}"])) |> render_click()

  # The chrome's `:studio_chrome_nav` hook, from an `on_mount`, runs before
  # every hook the page's mount attaches. On a page that is not StudioLive
  # (the desk) it takes these events itself, as navigation or a new
  # workspace or project, and halts: they reach neither Caps nor LeaveScope,
  # and none writes the held document.
  defp chrome_events do
    {_ast, names} =
      Path.join(File.cwd!(), "lib/barkpark_web/studio_chrome.ex")
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:@, _, [{:per_view_events, _, [{:sigil_w, _, [{:<<>>, _, [raw]}, _]}]}]} = n, _acc
        when is_binary(raw) ->
          {n, String.split(raw)}

        n, acc ->
          {n, acc}
      end)

    assert "shares-open" in names
    names
  end

  # Every literal `handle_event/3` head of the Studio and the desk.
  defp heads do
    @heads
    |> Enum.flat_map(fn rel ->
      {_ast, acc} =
        Path.join(File.cwd!(), rel)
        |> File.read!()
        |> Code.string_to_quoted!()
        |> Macro.prewalk([], fn
          {:def, _, [{:when, _, [{:handle_event, _, [h, _, _]} | _]} | _]} = n, acc ->
            {n, [h | acc]}

          {:def, _, [{:handle_event, _, [h, _, _]} | _]} = n, acc ->
            {n, [h | acc]}

          n, acc ->
            {n, acc}
        end)

      Enum.filter(acc, &is_binary/1)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  for surface <- [:studio, :desk] do
    describe "#{surface}" do
      @surface surface

      test "a save under the question is refused: no copy in P2, P1 untouched, still asked", c do
        {a, before} = asked(c, @surface)

        html = posts(a, "T-open", "one twA three")
        _ = :sys.get_state(a.pid)

        assert rows() == before
        assert has_element?(a, dialog(@surface))
        assert html =~ Plug.HTML.html_escape(LeaveScope.notice())
      end

      test "every write-tier press is refused under the question; a read goes on", c do
        {a, before} = asked(c, @surface)
        notice = Plug.HTML.html_escape(LeaveScope.notice())

        # Reads fire with no press (presence, copies): they go on, with no notice.
        for event <- ["paper-selection"] ++ if(@surface == :desk, do: ["desk-doc-copy"], else: []) do
          assert Caps.classify(event) == :read
          refute render_hook(a, event, %{}) =~ notice, event
          assert has_element?(a, dialog(@surface)), event
        end

        skip = if @surface == :desk, do: chrome_events(), else: []

        writes =
          Enum.reject(
            heads(),
            &(&1 in @leave_events or &1 in skip or Caps.classify(&1) in [:none, :read])
          )

        # A control: the corpus is the pages' own presses, not an empty list.
        assert "autosave" in writes and "new-document" in writes and "publish" in writes
        assert length(writes) > 40

        for event <- writes do
          html = render_hook(a, event, %{})
          assert is_binary(html) and html =~ notice, event
          assert has_element?(a, dialog(@surface)), event
        end

        assert rows() == before
      end

      test "a door no event hook sees (do_autosave from handle_info) is refused too", c do
        {a, before} = asked(c, @surface)
        socket = :sys.get_state(a.pid).socket

        refused = Shared.do_autosave(socket, %{"title" => "T-info", "notes" => "one twA three"})

        assert Phoenix.Flash.get(refused.assigns.flash, :error) == LeaveScope.notice()
        assert rows() == before
        assert Shared.write_denied?(socket)
      end

      # task-7fbdea7ee305cbc4: these three rebuild the panes, which read the
      # open document under the socket's scope, P2's under the question.
      test "a reload under the question is held: P1's document and the held words stay", c do
        {a, before} = asked(c, @surface)

        for {event, params} <- [
              {"reload-remote-doc", %{}},
              {"desk-list-more", %{"type" => "post"}},
              {"select-sort", %{"type" => "post", "sort" => ""}}
            ] do
          assert Caps.classify(event) == :none, event
          html = render_hook(a, event, params)

          assert html =~ Plug.HTML.html_escape(LeaveScope.held_notice()), event
          assert held_p1?(a, c), event
          assert has_element?(a, dialog(@surface)), event
        end

        assert rows() == before
      end

      # task-62711814fa586a09: View graph builds its page from the socket's
      # project, P2 under the question: it went to P2's graph of kept-doc.
      test "View graph under the question is held: no page change, the question stays", c do
        {a, before} = asked(c, @surface)

        assert Caps.classify("view-graph") == :none
        html = render_hook(a, "view-graph", %{})

        assert is_binary(html), inspect(html)
        assert html =~ Plug.HTML.html_escape(LeaveScope.held_opens_notice())
        refute assigns(a)[:live_action] == :graph
        assert held_p1?(a, c)
        assert has_element?(a, dialog(@surface))
        assert rows() == before
      end

      test "control: with no question, View graph goes to P1's graph", c do
        a = open(c.conn.(), at(c, @surface, :one))

        case render_hook(a, "view-graph", %{}) do
          {:error, {:live_redirect, %{to: to}}} -> assert to =~ "lsc-one/", to
          html when is_binary(html) -> assert assert_patch(a) =~ "lsc-one/"
        end
      end

      test "P2 holds a document of the same id: a reload under the question still shows P1's",
           c do
        {a, _before} = asked(c, @surface)

        {:ok, _} =
          Content.create_document(
            "post",
            %{
              "doc_id" => "kept-doc",
              "title" => "P2-KEPT",
              "content" => %{"notes" => "p2 words"}
            },
            @ds,
            workspace_id: c.ws.id,
            project_id: c.p2.id
          )

        assert render_hook(a, "reload-remote-doc", %{}) =~
                 Plug.HTML.html_escape(LeaveScope.held_notice())

        # The editor's own title, not the list, which is P2's under the question.
        refute has_element?(a, ~s(#editor-form input[name="doc[title]"][value="P2-KEPT"]))
        assert held_p1?(a, c)
        assert has_element?(a, dialog(@surface))
      end

      # A control: the list topic's rebuild is skipped for the held (dirty)
      # form already; it passes on main as here.
      test "control: another document saved in P2 under the question rebuilds nothing", c do
        {a, _before} = asked(c, @surface)

        {:ok, _} =
          Content.create_document(
            "post",
            %{"doc_id" => "new-in-two", "title" => "T2", "content" => %{"notes" => "x"}},
            @ds,
            workspace_id: c.ws.id,
            project_id: c.p2.id
          )

        _ = render(a)
        assert held_p1?(a, c)
        assert has_element?(a, dialog(@surface))
      end

      test "an unnamed press under the question stays on the page, words held", c do
        {a, before} = asked(c, @surface)

        send(a.pid, {:tree_codelist_pick, %{name: "doc[notes]", value: "x", press: %{}}})
        html = render(a)

        assert html =~ Plug.HTML.html_escape(LeaveScope.notice())
        assert held_p1?(a, c)
        assert has_element?(a, dialog(@surface))
        assert rows() == before
      end

      test "Stay, then Reload: P1's document is read again in P1", c do
        {a, _before} = asked(c, @surface)
        press(a, @surface, "desk-leave-stay")

        html = render_hook(a, "reload-remote-doc", %{})

        refute html =~ Plug.HTML.html_escape(LeaveScope.held_notice())
        %{editor_doc: doc, editor_form: form} = assigns(a)
        assert {doc.doc_id, doc.project_id} == {"drafts.kept-doc", c.p1.id}
        assert form["notes"] == "one twB three"
      end

      test "control: with no question, an unnamed press sends the page to its own address", c do
        a = open(c.conn.(), at(c, @surface, :one))
        send(a.pid, {:tree_codelist_pick, %{name: "doc[notes]", value: "x", press: %{}}})
        assert {path, _flash} = assert_redirect(a)
        assert path == at(c, @surface, :one)
      end

      test "Stay goes through; the scope is the document's again and a save lands in P1", c do
        {a, _before} = asked(c, @surface)

        press(a, @surface, "desk-leave-stay")
        refute has_element?(a, dialog(@surface))
        assert assigns(a).current_project.id == c.p1.id

        html = posts(a, "T-stay", "one twA three")
        refute html =~ Plug.HTML.html_escape(LeaveScope.notice())

        assert ObjectRichText.eventually(fn ->
                 {"drafts.kept-doc", c.p1.id, "T-stay"} in rows()
               end)

        refute Enum.any?(rows(), &match?({"drafts.kept-doc", p, _} when p == c.p2.id, &1))
      end

      test "Leave goes through; the scope and path are P2's, and a save lands in P2's document",
           c do
        {a, _before} = asked(c, @surface)

        press(a, @surface, "desk-leave-go")
        refute has_element?(a, dialog(@surface))

        %{current_project: proj, scope_prefix: prefix, current_path: path, editor_doc: doc} =
          assigns(a)

        assert proj.id == c.p2.id
        assert prefix == "/w/#{c.ws.slug}/p/lsc-two"
        assert path == at(c, @surface, :two)
        assert doc.doc_id == "drafts.other-doc"

        posts(a, "T-left", "one two three")

        assert ObjectRichText.eventually(fn ->
                 {"drafts.other-doc", c.p2.id, "T-left"} in rows()
               end)

        refute Enum.any?(rows(), &match?({"drafts.kept-doc", p, _} when p == c.p2.id, &1))
      end
    end
  end

  test "control: a Back in the same project gates nothing; the question's scope has not moved",
       c do
    a = open(c.conn.(), at(c, :studio, :one))
    b = open(c.conn.(), at(c, :studio, :one))

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "near-doc", "title" => "T0", "content" => %{"notes" => "x"}},
        @ds,
        workspace_id: c.ws.id,
        project_id: c.p1.id
      )

    ObjectRichText.inside(a, fn -> posts(b, "T0", "one twB three", "doc[notes]") end, fn ->
      posts(a, "T0", "one twA three", "doc[notes]")
    end)

    render_patch(a, c.base <> "lsc-one/d/#{@ds}/studio/post/near-doc")
    assert has_element?(a, dialog(:studio))
    refute LeaveScope.moved?(assigns(a))

    refute render_hook(a, "select-sort", %{"type" => "post", "sort" => ""}) =~
             Plug.HTML.html_escape(LeaveScope.held_notice())

    refute posts(a, "T-near", "one twA three") =~ Plug.HTML.html_escape(LeaveScope.notice())
  end
end
