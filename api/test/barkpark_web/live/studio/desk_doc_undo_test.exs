defmodule BarkparkWeb.Studio.DeskDocUndoTest do
  @moduledoc """
  task-c25c112913859b11 (F7, the tail of live-edit.spec.ts:17): on the desk,
  Mod+Z takes back this editor's own typing only, and another editor's words
  stay, in the store and in both pages (`Desk.DocUndo`).

  The posts are the page's, as in `two_editors_in_flight_test.exs`: the whole
  form, `_target` naming the field, and `_bp_seen` as bp-array-focus.js keeps
  it. `desk-undo` is what bp-desk-undo.js pushes for the key.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @history ",changesInspectorTab=history,inspect=sanity%2Fstructure%2Fhistory"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "undo_post_#{n}"
    doc_id = "undo-post-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Undo posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "text"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => doc_id,
          "title" => "Fixture post 14",
          "content" => %{"excerpt" => "Short."}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "doc-undo-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "doc-undo", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, desk: "#{base}/_desk/#{type};#{doc_id}", type: type, doc_id: doc_id}
  end

  defp open(c, url \\ nil) do
    {:ok, view, _html} = live(c.conn, url || c.desk)
    render(view)
    view
  end

  defp form_of(view),
    do: Map.take(:sys.get_state(view.pid).socket.assigns.editor_form, ["title", "excerpt"])

  defp send_post(view, target, changes, seen \\ %{}) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", target],
      "doc" => Map.merge(form_of(view), changes),
      "_bp_seen" => Jason.encode!(Map.put(seen, "v", 2))
    })
  end

  defp mark(c), do: %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.doc_id)}

  defp undo(view, c, redo \\ false) do
    render_hook(view, "desk-undo", Map.put(mark(c), "redo", redo))
    render(view)
  end

  # The stored row, read back from the store.
  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    %{"title" => doc.title, "excerpt" => (doc.content || %{})["excerpt"]}
  end

  defp told(view) do
    render(view)
    assert_push_event(view, "bp:form-remote-values", %{values: values} = payload)
    {values, Map.get(payload, :seqs, %{})}
  end

  # A pause longer than one undo step's (600 ms): the next typing is a step of its own.
  defp pause, do: Process.sleep(650)

  # J05 then J06, as live-edit.spec.ts's two-browser test types them: A's " A", B's " B" in
  # the excerpt, then A's " aaa" crossing B's "bbb " in the title.
  defp j05_j06(c, a, b) do
    send_post(a, "title", %{"title" => "Fixture post 14 A"})
    {_values, b_seqs} = told(b)
    b_seen = %{"doc[title]" => List.last(b_seqs["doc[title]"])}
    send_post(b, "excerpt", %{"excerpt" => "Short. B"}, b_seen)
    told(a)
    pause()

    send_post(b, "title", %{"title" => "bbb Fixture post 14 A"}, b_seen)
    send_post(a, "title", %{"title" => "Fixture post 14 A aaa"})
    assert stored(c)["title"] == "bbb Fixture post 14 A aaa"
    told(a)
    told(a)
    told(b)
  end

  describe "F7: A's undo after J05 and J06" do
    test "takes back A's typing only; B's words stay, stored and in both pages", c do
      a = open(c)
      b = open(c)
      j05_j06(c, a, b)

      undo(a, c)
      assert stored(c) == %{"title" => "bbb Fixture post 14 A", "excerpt" => "Short. B"}

      assert_push_event(a, "desk:undone", %{
        field: "doc[title]",
        value: "bbb Fixture post 14 A",
        was: "bbb Fixture post 14 A aaa"
      })

      undo(a, c)
      assert stored(c) == %{"title" => "bbb Fixture post 14", "excerpt" => "Short. B"}

      assert_push_event(a, "desk:undone", %{
        field: "doc[title]",
        value: "bbb Fixture post 14",
        was: "bbb Fixture post 14 A"
      })

      assert form_of(a)["title"] == "bbb Fixture post 14"

      # B's page is told each, over the title it shows, and takes it.
      {values, _} = told(b)

      assert values["doc[title]"] == %{
               value: "bbb Fixture post 14 A",
               was: "bbb Fixture post 14 A aaa"
             }

      {values, _} = told(b)
      assert values["doc[title]"] == %{value: "bbb Fixture post 14", was: "bbb Fixture post 14 A"}

      # Nothing more of A's: a third Mod+Z writes nothing, B's excerpt stays.
      undo(a, c)
      assert stored(c) == %{"title" => "bbb Fixture post 14", "excerpt" => "Short. B"}
    end

    test "redo puts A's typing back, B's words kept", c do
      a = open(c)
      b = open(c)
      j05_j06(c, a, b)

      undo(a, c)
      undo(a, c)
      assert stored(c)["title"] == "bbb Fixture post 14"

      undo(a, c, true)
      assert stored(c)["title"] == "bbb Fixture post 14 A"
      undo(a, c, "true")
      assert stored(c)["title"] == "bbb Fixture post 14 A aaa"
      assert stored(c)["excerpt"] == "Short. B"
    end

    test "a new edit after an undo ends what could be redone", c do
      a = open(c)
      send_post(a, "title", %{"title" => "Fixture post 14 A"})
      undo(a, c)
      assert stored(c)["title"] == "Fixture post 14"

      send_post(a, "excerpt", %{"excerpt" => "Short. typed"})
      undo(a, c, true)
      assert stored(c)["title"] == "Fixture post 14"
    end
  end

  describe "steps" do
    test "typing in one field without a pause is one undo", c do
      a = open(c)
      send_post(a, "title", %{"title" => "Fixture post 14 A"})
      send_post(a, "title", %{"title" => "Fixture post 14 A aaa"})

      undo(a, c)
      assert stored(c)["title"] == "Fixture post 14"
    end

    test "undo walks back across fields, the last first", c do
      a = open(c)
      send_post(a, "title", %{"title" => "Fixture post 14 A"})
      send_post(a, "excerpt", %{"excerpt" => "Short. B"})

      undo(a, c)
      assert stored(c) == %{"title" => "Fixture post 14 A", "excerpt" => "Short."}
      assert_push_event(a, "desk:undone", %{field: "doc[excerpt]", value: "Short."})

      undo(a, c)
      assert stored(c) == %{"title" => "Fixture post 14", "excerpt" => "Short."}
    end

    test "a change another editor wrote over stays theirs, and the step is gone", c do
      a = open(c)
      b = open(c)
      send_post(a, "title", %{"title" => "Fixture post 14 A"})
      {_values, seqs} = told(b)
      # B rewrites A's word.
      send_post(b, "title", %{"title" => "Fixture post 14 B"}, %{
        "doc[title]" => List.last(seqs["doc[title]"])
      })

      render(a)
      undo(a, c)
      assert stored(c)["title"] == "Fixture post 14 B"
    end
  end

  describe "what is refused" do
    test "an undo named for another document writes nothing", c do
      a = open(c)
      send_post(a, "title", %{"title" => "Fixture post 14 A"})

      other = %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, "someone-else")}
      render_hook(a, "desk-undo", other)
      assert stored(c)["title"] == "Fixture post 14 A"
    end

    test "nothing is undone over an old revision or in the published perspective", c do
      {:ok, _} = Content.publish_document(c.doc_id, c.type, @dataset)

      rev =
        c.doc_id
        |> Content.list_revisions(c.type, @dataset, limit: 10)
        |> Enum.find(&(&1.action == "publish"))

      a = open(c)
      send_post(a, "title", %{"title" => "Fixture post 14 A"})
      assert stored(c)["title"] == "Fixture post 14 A"

      render_patch(a, c.desk <> @history <> ",rev=#{rev.id}")
      render_async(a, 5_000)
      undo(a, c)
      assert stored(c)["title"] == "Fixture post 14 A"

      render_patch(a, c.desk <> "?perspective=published")
      undo(a, c)
      assert stored(c)["title"] == "Fixture post 14 A"

      # The change was kept: back in the draft, it is undone.
      render_patch(a, c.desk)
      undo(a, c)
      assert stored(c)["title"] == "Fixture post 14"
    end
  end
end
