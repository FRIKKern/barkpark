defmodule BarkparkWeb.Studio.DeskRemoteSaveValuesTest do
  @moduledoc """
  task-6b336810643b1a70 (round 4 review of #27622): how the desk footer
  judges another editor's save (`Desk.RemoteSave`).

  - A value that is not free text (a select, a date, a datetime, a slug) is
    written by the last post, with no merge. When another editor replaces
    the value this tab saved, it is gone, even when the two share
    characters: "Updated by another user".
  - Only free text is merged, so only free text is read for this tab's
    words (`TextUndo.revert/3`), and only in a field the frame moved. A
    frame that moves another field reads none of it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.RemoteSave

  @dataset "production"
  @status ~s([data-pane-editing] .dk-edit-footer [data-desk-footer-status] .save-state-text)
  @revert [:barkpark, :desk, :remote_save, :revert]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "rsv_#{n}"
    doc_id = "rsv-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Remote save values #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"},
            %{"name" => "big", "title" => "Big", "type" => "text"},
            %{"name" => "day", "title" => "Day", "type" => "date"},
            %{"name" => "at", "title" => "At", "type" => "datetime"},
            %{
              "name" => "slug",
              "title" => "Slug",
              "type" => "slug",
              "options" => %{"source" => "title"}
            },
            %{
              "name" => "size",
              "title" => "Size",
              "type" => "string",
              "options" => %{"list" => ["s", "m", "l", "xl"]}
            }
          ]
        },
        @dataset
      )

    content = %{
      "excerpt" => "First",
      "big" => "small",
      "day" => "2026-05-05",
      "at" => "2026-05-05T10:00:00Z",
      "slug" => %{"current" => "my-post"},
      "size" => "m"
    }

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => "Hello world", "content" => content},
        @dataset
      )

    Application.put_env(:barkpark, :desk_saved_ms, 100)
    on_exit(fn -> Application.delete_env(:barkpark, :desk_saved_ms) end)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-remote-save-values-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-rsv", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, desk: "#{base}/_desk/#{type};#{doc_id}", type: type, doc_id: doc_id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..300, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp status(view), do: view |> element(@status) |> render() |> strip()
  defp strip(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()

  defp settled(view) do
    Process.sleep(250)
    render(view)
    status(view)
  end

  defp form_of(view), do: :sys.get_state(view.pid).socket.assigns.editor_form

  # A post from `form` (default: the form the view holds now).
  defp send_post(view, target, changes, form \\ nil) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", target],
      "doc" => Map.merge(form || form_of(view), changes),
      "_bp_seen" => Jason.encode!(%{})
    })
  end

  defp told(view) do
    render(view)
    assert_push_event(view, "bp:form-remote-values", %{values: _} = payload, 2_000)
    Map.get(payload, :seqs, %{})
  end

  defp stored(c, key) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    Map.put(doc.content || %{}, "title", doc.title)[key]
  end

  describe "a value that is not free text, replaced by another editor, is named" do
    test "a select: l, then xl", c do
      a = open(c)
      b = open(c)
      send_post(a, "size", %{"size" => "l"})
      told(b)
      send_post(b, "size", %{"size" => "xl"})
      assert stored(c, "size") == "xl"

      assert settled(a) == "Updated by another user"
    end

    test "a select: l, then xl from a tab that never saw l", c do
      a = open(c)
      b = open(c)
      b_form = form_of(b)
      send_post(a, "size", %{"size" => "l"})
      send_post(b, "size", %{"size" => "xl"}, b_form)
      assert stored(c, "size") == "xl"

      assert settled(a) == "Updated by another user"
    end

    test "a date: 05-17, then 06-17 from a tab that never saw it", c do
      a = open(c)
      b = open(c)
      b_form = form_of(b)
      send_post(a, "day", %{"day" => "2026-05-17"})
      send_post(b, "day", %{"day" => "2026-06-17"}, b_form)
      assert stored(c, "day") == "2026-06-17"

      assert settled(a) == "Updated by another user"
    end

    test "a datetime: the time, then the day", c do
      a = open(c)
      b = open(c)
      from = form_of(a)["at"]
      mine = String.replace(from, "10:00", "11:30")
      send_post(a, "at", %{"at" => mine})
      told(b)
      send_post(b, "at", %{"at" => String.replace(mine, "2026-05-05", "2026-06-05")})
      assert stored(c, "at") =~ "2026-06-05"

      assert settled(a) == "Updated by another user"
    end

    test "a slug: my-post-2, then your-post-2", c do
      a = open(c)
      b = open(c)
      send_post(a, "slug", %{"slug" => "my-post-2"})
      told(b)
      send_post(b, "slug", %{"slug" => "your-post-2"})
      assert stored(c, "slug") == %{"current" => "your-post-2"}

      assert settled(a) == "Updated by another user"
    end
  end

  describe "free text is read for this tab's words only where the frame moved it, and near them" do
    setup do
      me = self()
      id = "remote-save-revert-#{System.unique_integer([:positive])}"
      :ok = :telemetry.attach(id, @revert, fn _e, m, _md, _c -> send(me, {:revert, m}) end, nil)
      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "a 60 KB text this tab saved, and a frame that moves another field", c do
      # Words that do not repeat, under the merge's 64 KB cap.
      big = Enum.map_join(1..10_200, " ", &"w#{&1}")
      assert byte_size(big) in 60_000..64_000

      {:ok, _} =
        Content.upsert_document(
          c.type,
          %{
            "doc_id" => "drafts." <> c.doc_id,
            "title" => "Hello world",
            "content" => %{"big" => big}
          },
          @dataset
        )

      a = open(c)
      b = open(c)
      send_post(a, "big", %{"big" => big <> " A"})
      [was, _] = told(b)["doc[big]"]

      # A frame that moves the text far from this tab's words keeps them
      # (both ends merged, J06), judged without the merge.
      send_post(b, "big", %{"big" => "B " <> big}, nil, was)
      assert stored(c, "big") == "B " <> big <> " A"
      assert settled(a) == "Edited just now"
      refute_received {:revert, _}

      # A frame that moves another field reads none of it.
      send_post(b, "excerpt", %{"excerpt" => "Second"})
      assert settled(a) == "Edited just now"
      refute_received {:revert, _}
    end
  end

  describe "the cost of a frame from another editor (frame/2 alone)" do
    setup do
      me = self()
      id = "remote-save-revert-cost-#{System.unique_integer([:positive])}"
      :ok = :telemetry.attach(id, @revert, fn _e, m, _md, _c -> send(me, {:revert, m}) end, nil)
      on_exit(fn -> :telemetry.detach(id) end)
    end

    # A tab whose kept step on a 60 KB text is not the text the form holds:
    # its post was merged with another editor's words ("B " ... " A").
    test "a frame that moves another field reads no text and takes no time" do
      {big, socket, msg} = costly(fn merged -> merged end, "Second")

      {median, runs} = timed(socket, msg)
      assert median < 15_000, "frame/2 took #{median} us (median of 5)"
      refute_received {:revert, _}

      for {:noreply, s} <- runs,
          do: assert(s.assigns[:desk_own_values] == {"cost", %{"big" => [{big, big <> " A"}]}})
    end

    test "a frame that moves the text far from this tab's words: no merge, the step follows" do
      {big, socket, msg} = costly(&("C " <> &1), "First")

      {median, runs} = timed(socket, msg)
      assert median < 15_000, "frame/2 took #{median} us (median of 5)"
      refute_received {:revert, _}

      for {:noreply, s} <- runs do
        assert s.assigns[:desk_own_values] ==
                 {"cost", %{"big" => [{"C B " <> big, "C B " <> big <> " A"}]}}

        refute s.assigns[:desk_overwritten]
      end
    end

    test "a frame that moves the text next to this tab's words: the full merge judges it" do
      {_big, socket, msg} = costly(&String.replace_suffix(&1, " A", " AB"), "First")

      {_median, runs} = timed(socket, msg)
      assert_received {:revert, %{bytes: bytes}} when bytes > 60_000

      for {:noreply, s} <- runs, do: assert(s.assigns[:desk_overwritten] == "cost")
    end
  end

  # A desk socket whose kept step on a 60 KB text was merged with another
  # editor's "B " at the start, and a frame from a third editor whose text is
  # `text.(merged)` and whose excerpt is `excerpt`.
  defp costly(text, excerpt) do
    big = Enum.map_join(1..10_200, " ", &"w#{&1}")
    merged = "B " <> big <> " A"

    schema = %{
      fields: [
        %{"name" => "title", "type" => "string"},
        %{"name" => "big", "type" => "text"},
        %{"name" => "excerpt", "type" => "string"}
      ]
    }

    at = ~U[2026-11-20 10:00:00.000000Z]

    doc = %{
      doc_id: "drafts.cost",
      title: "T",
      status: "draft",
      content: %{"big" => merged, "excerpt" => "First"},
      updated_at: at,
      rev: "r1"
    }

    form = Content.doc_to_form(doc, schema)

    frame = %{
      doc
      | content: %{"big" => text.(merged), "excerpt" => excerpt},
        updated_at: DateTime.add(at, 1)
    }

    socket =
      Phoenix.Component.assign(%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}},
        editor_doc: doc,
        editor_schema: schema,
        # The Studio's clean path put the frame in the form.
        editor_form: Content.doc_to_form(frame, schema),
        doc_conflict: false,
        desk_own_values: {"cost", %{"big" => [{big, big <> " A"}]}},
        desk_remote_seen: {"cost", form}
      )

    {big, socket, %{doc: frame, sender: spawn(fn -> :ok end), mutation: "update"}}
  end

  defp timed(socket, msg) do
    runs = for _ <- 1..5, do: :timer.tc(fn -> RemoteSave.frame({:noreply, socket}, msg) end)
    {runs |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.at(2), Enum.map(runs, &elem(&1, 1))}
  end

  # A post typed from the value whose number is `was` (the page's `_bp_seen`).
  defp send_post(view, target, changes, form, was) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", target],
      "doc" => Map.merge(form || form_of(view), changes),
      "_bp_seen" => Jason.encode!(%{"doc[#{target}]" => was, "v" => 2})
    })
  end
end
