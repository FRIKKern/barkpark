defmodule BarkparkWeb.Studio.DeskUndoHeldLandedTest do
  @moduledoc """
  task-728b054a91a0c385 (#29071 review, item 2): the desk's undo keeps a
  step for a write that landed (`DocUndo.landed?/2`), read from "Saved" or
  from `editor_built_landed`. While a field is held, the hold puts "Updated
  by another user" where the write said "Saved", so a typed post on another
  field and an array op landed and kept no step. `editor_built_landed` was
  cleared only by a typed post, so an array op after a paste kept the
  paste's flag and its step (U4), and one with no paste before it kept none
  (U4c). One signal now says a write landed: set by the write itself, and
  cleared as every write starts.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.HeldWrites
  alias BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  @dataset "production"
  @banner ~s([data-test-id="doc-conflict-banner"])
  @paused ~s([data-test-id="doc-conflict-paused"])
  @label "doc[meta].label"
  @t0 "one two three"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "built_held_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Held writes",
          "visibility" => "public",
          "fields" =>
            [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{
                "name" => "meta",
                "title" => "Meta",
                "type" => "composite",
                "fields" => [%{"name" => "label", "title" => "Label", "type" => "string"}]
              },
              %{"name" => "notes", "title" => "Notes", "type" => "string"}
            ] ++ HeldWrites.fields()
        },
        @dataset
      )

    id = "held-write-#{n}"
    content = Map.merge(%{"meta" => %{"label" => @t0}, "notes" => @t0}, HeldWrites.content())

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "T0", "content" => content},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "held-write-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "held-write",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     paths: %{desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}"}}
  end

  defp open(c, surface) do
    {:ok, view, _html} = live(c.conn, c.paths[surface])
    render_async(view, 5_000)
    assert ObjectRichText.eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp label(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    get_in(doc.content, ["meta", "label"])
  end

  defp form_label(view),
    do: get_in(:sys.get_state(view.pid).socket.assigns[:editor_form], ["meta", "label"])

  # The page's `_bp_seen` as bp-array-focus.js keeps it.
  defp page(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))
    seen = value |> String.replace("&quot;", ~s(")) |> Jason.decode!()
    assert_push_event(view, "bp:form-born", %{seqs: seqs, oks: oks}, 2_000)
    seen |> Map.merge(seqs) |> Map.put("v", 2) |> Map.put("ok", Map.merge(seen["ok"] || %{}, oks))
  end

  defp confirmed(view, seen) do
    assert_push_event(view, "bp:form-confirmed", %{oks: oks}, 2_000)
    Map.update!(seen, "ok", &Map.merge(&1, oks))
  end

  defp changes(view, label, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "doc" => %{"title" => "T0", "notes" => @t0},
      @label => label,
      "_bp_seen" => Jason.encode!(seen),
      "_target" => [@label]
    })
  end

  # A's label is held: A typed " A1" and it landed, the socket dropped, B
  # saved "B5 …", and A's rejoined page typed " A7" on the old value.
  defp held(c, surface) do
    a = open(c, surface)
    seen = page(a)
    changes(a, @t0 <> " A1", seen)
    seen = confirmed(a, seen)
    GenServer.stop(a.pid, :normal)

    b = open(c, surface)
    changes(b, "B5 " <> @t0 <> " A1", page(b))
    GenServer.stop(b.pid, :normal)

    a2 = open(c, surface)
    _ = page(a2)
    changes(a2, @t0 <> " A1 A7", seen)
    assert label(c) == "B5 " <> @t0 <> " A1"
    assert has_element?(a2, @paused)
    a2
  end

  defp notes(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content["notes"]
  end

  defp marked(view, params),
    do: Map.merge(Map.take(EditorPost.marks(view), ["_bp_doc"]), params)

  defp field_paste(view, value) do
    render_hook(view, "desk-field-copy", %{"field" => "notes"})
    assert_push_event(view, "desk:field-copied", %{json: json})
    clip = json |> Jason.decode!() |> put_in(["barkpark", "field", "value"], value)

    render_hook(
      view,
      "desk-field-paste",
      marked(view, %{"field" => "notes", "clip" => Jason.encode!(clip)})
    )

    assert notes(c_of(view)) == value
  end

  defp c_of(view), do: Process.get({:c, view.pid})

  defp still_held(c, a) do
    assert label(c) == "B5 " <> @t0 <> " A1", "the write carried A's label over B's save"
    assert form_label(a) == @t0 <> " A1 A7"
    assert has_element?(a, @banner), "the banner was cleared"
    assert has_element?(a, @paused, "Autosave is paused for Meta until you Save or Reload.")
  end

  defp held_desk(c) do
    a = held(c, :desk)
    Process.put({:c, a.pid}, c)
    a
  end

  defp undo(view), do: render_hook(view, "desk-undo", marked(view, %{"redo" => false}))

  defp items(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content["items"]
  end

  # A typed post on the notes, with the page's `_bp_seen`; the label posts
  # A's held words, as the page shows them.
  defp typed_notes(view, value, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "doc" => %{"title" => "T0", "notes" => value},
      @label => form_label(view),
      "_bp_seen" => Jason.encode!(seen),
      "_target" => ["doc", "notes"]
    })
  end

  # The label held as `held/2` holds it, and the page's `_bp_seen` from
  # before the drop.
  defp held_with_seen(c) do
    a = open(c, :desk)
    seen = page(a)
    changes(a, @t0 <> " A1", seen)
    seen = confirmed(a, seen)
    GenServer.stop(a.pid, :normal)

    b = open(c, :desk)
    changes(b, "B5 " <> @t0 <> " A1", page(b))
    GenServer.stop(b.pid, :normal)

    a2 = open(c, :desk)
    _ = page(a2)
    changes(a2, @t0 <> " A1 A7", seen)
    assert has_element?(a2, @paused)
    Process.put({:c, a2.pid}, c)
    {a2, seen}
  end

  test "hold: a typed post on another field keeps one undo step", c do
    {a, seen} = held_with_seen(c)
    typed_notes(a, @t0 <> " N1", seen)
    assert notes(c) == @t0 <> " N1"

    # On main: the post landed and kept no step; the undo did nothing.
    undo(a)
    assert notes(c) == @t0, "the typed post kept no undo step"
    still_held(c, a)

    undo(a)
    assert notes(c) == @t0
    still_held(c, a)
  end

  test "hold, no paste before it: an array op keeps one undo step", c do
    a = held_desk(c)
    HeldWrites.run(a, c, :array_op)
    assert items(c) == ["y"]

    # On main: the op landed and kept no step (U4c).
    undo(a)
    assert items(c) == ["x", "y"], "the array op kept no undo step"
    still_held(c, a)

    undo(a)
    assert items(c) == ["x", "y"]
    still_held(c, a)
  end

  test "hold, a paste before it: the array op keeps its own step, and the paste its own", c do
    a = held_desk(c)
    field_paste(a, "P1")
    HeldWrites.run(a, c, :array_op)
    assert items(c) == ["y"]

    undo(a)
    assert items(c) == ["x", "y"]
    assert notes(c) == "P1"

    undo(a)
    assert notes(c) == @t0
    still_held(c, a)
  end

  test "hold: an array op that writes nothing keeps no step after a paste", c do
    a = held_desk(c)
    field_paste(a, "P1")

    # Out of range: refused, nothing written. On main the paste's flag
    # carried into it.
    EditorPost.press(a, "array_op", %{
      "action" => "remove_row",
      "field" => "items",
      "path" => "doc[items]",
      "index" => "9"
    })

    assert items(c) == ["x", "y"]

    undo(a)
    assert notes(c) == @t0, "the paste's step was not the top one"
    assert items(c) == ["x", "y"]
  end

  test "control, no hold: a typed post and an array op each keep one step", c do
    a = open(c, :desk)
    Process.put({:c, a.pid}, c)
    seen = page(a)
    typed_notes(a, @t0 <> " N1", seen)
    HeldWrites.run(a, c, :array_op)

    undo(a)
    assert items(c) == ["x", "y"]
    assert notes(c) == @t0 <> " N1"

    undo(a)
    assert notes(c) == @t0
    refute has_element?(a, @banner)
  end
end
