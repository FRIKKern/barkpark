defmodule BarkparkWeb.Studio.ZzReview28096ProbeTest do
  # Reviewer probe (a6c895ed, #28096). Prints facts as "PROBE ..." lines; asserts only fixtures.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @history ",changesInspectorTab=history,inspect=sanity%2Fstructure%2Fhistory"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "rprobe_#{n}"
    id = "rprobe-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Probe #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "note", "title" => "Note", "type" => "string"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Words A", "content" => %{"note" => "N0"}},
        @dataset
      )

    write(type, id, "Words B", "N0")

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "rprobe-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "rprobe", @dataset, ~w(read write admin), ws_id)
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     studio: "#{base}/#{type}/#{id}",
     desk: "#{base}/_desk/#{type};#{id}"}
  end

  # A probe prints; it never fails a row.
  defp probe(name, fun) do
    fun.()
  rescue
    e -> IO.puts("PROBE #{name} ERROR #{Exception.message(e)}")
  catch
    kind, value -> IO.puts("PROBE #{name} ERROR #{inspect(kind)} #{inspect(value)}")
  end

  defp write(type, id, title, note) do
    {:ok, doc} =
      Content.upsert_document(
        type,
        %{"doc_id" => Content.draft_id(id), "title" => title, "content" => %{"note" => note}},
        @dataset
      )

    doc
  end

  defp open(c, url) do
    {:ok, view, _html} = live(c.conn, url)
    render_async(view, 5_000)
    view
  end

  defp current(c) do
    {doc, _d, _p} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc
  end

  defp revision(c, title) do
    c.id
    |> Content.list_revisions(c.type, @dataset, limit: 200)
    |> Enum.find(&(&1.title == title and &1.action != "delete"))
    |> Map.fetch!(:id)
    |> to_string()
  end

  defp a(view), do: :sys.get_state(view.pid).socket.assigns
  defp flash(view), do: a(view).flash

  defp values(view, selector) do
    [el] =
      view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.to_list()

    for key <- ~w(id if_rev if_absent),
        [value] <- [LazyHTML.attribute(el, "phx-value-#{key}")],
        into: %{},
        do: {key, value}
  end

  defp dialog_values(view, rev_id) do
    render_click(view, "show-history", %{})
    values(view, ~s(#history-list button[phx-value-id="#{rev_id}"]))
  end

  defp hold_frames(view) do
    render(view)

    topics =
      Barkpark.PubSub |> Registry.keys(view.pid) |> Enum.filter(&String.starts_with?(&1, "doc"))

    :sys.replace_state(view.pid, fn state ->
      Enum.each(topics, &Phoenix.PubSub.unsubscribe(Barkpark.PubSub, &1))
      state
    end)

    Enum.each(topics, &Phoenix.PubSub.subscribe(Barkpark.PubSub, &1))
    topics
  end

  defp drain(acc \\ []) do
    receive do
      {tag, _} = m when tag in [:doc_updated, :document_changed] -> drain([m | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  test "T3 own save while another's frames are still on the way", c do
    probe("T3", fn ->
      view = open(c, c.studio)
      hold_frames(view)
      other = write(c.type, c.id, "Words C", "N0")
      EditorPost.change(view, %{"title" => "Words B", "note" => "mine"})
      s = a(view)
      stored = current(c)

      IO.puts(
        "PROBE T3 after own save: stored title=#{inspect(stored.title)} note=#{inspect(stored.content["note"])} " <>
          "form title=#{inspect(s.editor_form["title"])} note=#{inspect(s.editor_form["note"])} " <>
          "editor_doc.rev==stored.rev:#{s.editor_doc.rev == stored.rev} other.rev==stored.rev:#{other.rev == stored.rev} dirty=#{inspect(s.editor_dirty)}"
      )

      held = drain()
      IO.puts("PROBE T3 held frames: #{inspect(Enum.map(held, &elem(&1, 0)))}")
      Enum.each(held, &send(view.pid, &1))
      render(view)
      s2 = a(view)

      IO.puts(
        "PROBE T3 after the held frames: form title=#{inspect(s2.editor_form["title"])} editor_doc.rev==stored:#{s2.editor_doc.rev == current(c).rev}"
      )
    end)
  end

  test "T3b the same press, made before the frames arrive", c do
    probe("T3b", fn ->
      view = open(c, c.studio)
      hold_frames(view)
      write(c.type, c.id, "Words C", "N0")
      EditorPost.change(view, %{"title" => "Words B", "note" => "mine"})
      before = current(c)
      pressed = dialog_values(view, revision(c, "Words A"))
      EditorPost.press(view, "restore-revision", pressed)
      after_press = current(c)

      IO.puts(
        "PROBE T3b form title shown=#{inspect(a(view).editor_form["title"])} stored before=#{inspect(before.title)} " <>
          "press if_rev==stored:#{pressed["if_rev"] == before.rev} after press title=#{inspect(after_press.title)} flash=#{inspect(flash(view))}"
      )
    end)
  end

  test "T4 a refused Revert: does the revision view close?", c do
    probe("T4", fn ->
      view = open(c, c.desk <> @history <> ",rev=#{revision(c, "Words A")}")

      [el] =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("[data-pane-editing] [data-desk-revert-confirm]")
        |> Enum.to_list()

      [js] = LazyHTML.attribute(el, "phx-click")

      pressed =
        js
        |> Jason.decode!()
        |> Enum.find_value(fn
          ["push", %{"event" => "restore-revision", "value" => v}] -> v
          _ -> nil
        end)

      write(c.type, c.id, "Words C", "N0")
      render(view)
      before_rev = a(view)[:desk_revision]
      mark = %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.id)}
      EditorPost.press(view, "restore-revision", pressed, mark)

      patched =
        try do
          assert_patch(view, 500)
        rescue
          _ -> :none
        end

      render(view)

      IO.puts(
        "PROBE T4 before press desk_revision set:#{not is_nil(before_rev)} after press desk_revision=#{inspect(a(view)[:desk_revision] && a(view)[:desk_revision][:id])} " <>
          "patched=#{inspect(patched)} flash=#{inspect(flash(view))} stored title=#{inspect(current(c).title)}"
      )
    end)
  end

  test "T5 non-string values from a hand-built event", c do
    probe("T5", fn ->
      view = open(c, c.studio)
      id = revision(c, "Words A")

      for extra <- [
            %{"if_rev" => 5},
            %{"if_absent" => true},
            %{"if_rev" => %{"a" => 1}},
            %{"if_rev" => ["x"]},
            %{"if_absent" => "true", "if_rev" => nil},
            %{"if_rev" => current(c).rev, "if_absent" => false}
          ] do
        before = current(c).rev
        EditorPost.press(view, "restore-revision", Map.put(extra, "id", id))
        after_rev = current(c).rev

        IO.puts(
          "PROBE T5 #{inspect(extra)} written:#{before != after_rev} flash=#{inspect(flash(view)["error"])}"
        )
      end

      before = current(c).rev
      EditorPost.press(view, "restore-revision", %{"id" => 7, "if_rev" => before})

      IO.puts(
        "PROBE T5 id=7 written:#{before != current(c).rev} flash=#{inspect(flash(view)["error"])}"
      )
    end)
  end

  describe "sheet" do
    setup do
      stop_all_sessions()

      on_exit(fn ->
        stop_all_sessions()
        Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
      end)

      Application.put_env(:barkpark, Barkpark.Plugins.Sheets.Session,
        debounce_ms: 60_000,
        idle_stop_ms: 60_000
      )

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "sheet",
            "title" => "Sheets",
            "visibility" => "private",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          @dataset
        )

      :ok
    end

    defp stop_all_sessions do
      for {_, pid, _, _} <-
            DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
          is_pid(pid) do
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
      end

      :ok
    end

    defp type_cell!(target, ref, value) do
      render_hook(target, "cell-click", %{"ref" => ref, "shift" => false})
      render_hook(target, "edit-commit", %{"value" => value, "move" => "down"})
    end

    defp cells(slug) do
      {:ok, doc} = Content.get_document(Content.draft_id(slug), "sheet", @dataset)
      {doc.rev, get_in(doc.content, ["tabs", Access.at(0), "cells"]) || %{}}
    end

    test "T2 own cell edits, flushed and shown, then Restore", %{conn: conn} do
      probe("T2", fn ->
        slug = "rprobe-sheet-#{System.unique_integer([:positive])}"

        {:ok, _} =
          Content.create_document(
            "sheet",
            %{
              "doc_id" => slug,
              "title" => "Untitled sheet",
              "content" => %{"tabs" => [%{"name" => "Sheet 1", "cells" => %{}}]}
            },
            @dataset
          )

        {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
        target = with_target(view, "#sheet-grid-#{slug}")
        type_cell!(target, "A1", "old")
        assert :ok = Session.flush(slug, @dataset, nil)
        type_cell!(target, "A1", "new")
        assert :ok = Session.flush(slug, @dataset, nil)
        render(view)
        Process.sleep(200)
        render(view)
        {stored_rev, _} = cells(slug)

        old =
          Content.list_revisions(slug, "sheet", @dataset, limit: 30)
          |> Enum.find(
            &(get_in(&1.content || %{}, ["tabs", Access.at(0), "cells", "A1", "v"]) == "old")
          )

        assert old

        render_click(view, "show-history", %{})

        [button] =
          view
          |> render()
          |> LazyHTML.from_document()
          |> LazyHTML.query(~s(#history-list button[phx-value-id="#{old.id}"]))
          |> Enum.to_list()

        pressed =
          for key <- ~w(id if_rev),
              [value] <- [LazyHTML.attribute(button, "phx-value-#{key}")],
              into: %{},
              do: {key, value}

        EditorPost.press(view, "restore-revision", pressed)
        {_, after_cells} = cells(slug)

        IO.puts(
          "PROBE T2 if_rev==stored rev:#{pressed["if_rev"] == stored_rev} editor_doc.rev==stored:#{a(view).editor_doc.rev == stored_rev} " <>
            "A1 after press=#{inspect(get_in(after_cells, ["A1", "v"]))} flash=#{inspect(flash(view))}"
        )
      end)
    end
  end

  describe "paper" do
    setup do
      previous = System.get_env("BARKPARK_PAPER_CANVAS")
      System.put_env("BARKPARK_PAPER_CANVAS", "1")

      on_exit(fn ->
        if previous,
          do: System.put_env("BARKPARK_PAPER_CANVAS", previous),
          else: System.delete_env("BARKPARK_PAPER_CANVAS")
      end)

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "paper",
            "title" => "Papers",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "type" => "string"}]
          },
          @dataset
        )

      :ok
    end

    defp paper!(slug, text) do
      {:ok, p} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => slug,
            "title" => "Probe paper",
            "blocks" => [
              %{"id" => "b-head", "type" => "heading", "text" => "Probe paper", "level" => 1},
              %{
                "id" => "b-body",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => text}]
              }
            ]
          })
        )

      p
    end

    defp paper_row_rev(slug) do
      {doc, _d, _p} = Content.fetch_doc_with_draft("paper", slug, @dataset)
      doc && doc.rev
    end

    test "T1 a paper write the page painted, then Restore", c do
      probe("T1", fn ->
        slug = "rprobe-paper-#{System.unique_integer([:positive])}"
        paper!(slug, "Body one")
        paper!(slug, "Body two")
        {:ok, view, _} = live(c.conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
        render_async(view, 5_000)
        s0 = a(view)

        IO.puts(
          "PROBE T1 open: editor_view=#{inspect(s0[:editor_view])} editor_doc.rev==row:#{s0.editor_doc && s0.editor_doc.rev == paper_row_rev(slug)}"
        )

        paper!(slug, "Body three")
        render(view)
        Process.sleep(200)
        html = render(view)
        s1 = a(view)
        revs = Content.list_revisions(slug, "paper", @dataset, limit: 30)
        first = Enum.at(revs, -1)

        IO.puts(
          "PROBE T1 after another's write: page shows three:#{html =~ "Body three"} editor_doc.rev==row:#{s1.editor_doc && s1.editor_doc.rev == paper_row_rev(slug)} revisions=#{length(revs)}"
        )

        render_click(view, "show-history", %{})

        buttons =
          view
          |> render()
          |> LazyHTML.from_document()
          |> LazyHTML.query(~s(#history-list button[phx-value-id="#{first.id}"]))
          |> Enum.to_list()

        IO.puts("PROBE T1 dialog Restore buttons for the first revision: #{length(buttons)}")

        case buttons do
          [button] ->
            pressed =
              for key <- ~w(id if_rev),
                  [value] <- [LazyHTML.attribute(button, "phx-value-#{key}")],
                  into: %{},
                  do: {key, value}

            before = paper_row_rev(slug)
            EditorPost.press(view, "restore-revision", pressed)

            IO.puts(
              "PROBE T1 press if_rev==row:#{pressed["if_rev"] == before} written:#{before != paper_row_rev(slug)} flash=#{inspect(flash(view))}"
            )

          _ ->
            :ok
        end
      end)
    end
  end
end
