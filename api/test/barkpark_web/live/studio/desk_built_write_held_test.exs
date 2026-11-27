defmodule BarkparkWeb.Studio.DeskBuiltWriteHeldTest do
  @moduledoc """
  task-25de1fd76bf1f6d8 (#29050 review N1): while a text field is held (B's
  save is stored, A's words wait in the form under the banner, and autosave
  of that field is paused), a write the desk builds itself on another field
  kept B's save but cleared the banner and the paused line, so A lost the
  notice that their words are not saved. The writes go through
  `Fields.autosave_built/2`: a field paste, an undo, Review changes'
  Revert and a document paste. Each now keeps the banner, the paused line
  and A's words, and B's label stays stored.
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

  test "desk field paste into another field while the label is held", c do
    a = held_desk(c)
    field_paste(a, "PASTED")
    still_held(c, a)
  end

  test "desk undo of another field while the label is held", c do
    a = held_desk(c)
    field_paste(a, "PASTED")
    render_hook(a, "desk-undo", marked(a, %{"redo" => false}))
    assert notes(c) == @t0
    still_held(c, a)
  end

  test "desk Review changes' Revert of another field while the label is held", c do
    # Revert writes the published value back.
    {:ok, _} = Content.publish_document(c.id, c.type, @dataset)
    a = held_desk(c)
    field_paste(a, "PASTED")
    render_hook(a, "desk-field-revert", marked(a, %{"field" => "notes"}))
    assert notes(c) == @t0
    still_held(c, a)
  end

  test "desk document paste into another field while the label is held", c do
    a = held_desk(c)

    clip =
      Jason.encode!(%{
        "type" => "sanityClipboardItem",
        "isDocument" => true,
        "value" => %{},
        "barkpark" => %{
          "kind" => "document",
          "docType" => c.type,
          "fields" => [%{"name" => "notes", "sig" => "string", "value" => "DOC PASTED"}]
        }
      })

    render_hook(a, "desk-doc-paste", marked(a, %{"clip" => clip}))
    assert notes(c) == "DOC PASTED"
    still_held(c, a)
  end

  test "desk control: a field paste with nothing held raises no banner", c do
    a = open(c, :desk)
    Process.put({:c, a.pid}, c)
    _ = page(a)
    field_paste(a, "PASTED")
    refute has_element?(a, @banner)
    refute has_element?(a, @paused)
  end
end
