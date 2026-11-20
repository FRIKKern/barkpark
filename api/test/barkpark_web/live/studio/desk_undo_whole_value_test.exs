defmodule BarkparkWeb.Studio.DeskUndoWholeValueTest.Halt do
  @moduledoc false
  # Refuses every write while the flag is on ("Save cancelled").
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(_doc),
    do: if(:persistent_term.get(__MODULE__, false), do: {:halt, "held"}, else: :ok)
end

defmodule BarkparkWeb.Studio.DeskUndoWholeValueTest do
  @moduledoc """
  The desk's undo and redo of a value write the field's whole stored value
  back, nulls included, as TanStack's undo `edit`s the reverted value: an
  object the clear of its last language unset comes back with its stored
  null, and the last redo unsets it again (#27533 review r4, B7).

  The unset marker (`Forms.unset/0`) never reaches the form buffer, a page
  or the store, also after a refused save (B6).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.DeskUndoWholeValueTest.Halt
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @form "[data-pane-editing] #editor-form"

  defp lt(name),
    do: %{
      "name" => name,
      "title" => name,
      "type" => "localizedText",
      "languages" => ["nob", "eng"],
      "fallbackChain" => ["nob", "eng"]
    }

  defp str(name), do: %{"name" => name, "title" => name, "type" => "string"}

  defp comp(name, fields),
    do: %{"name" => name, "title" => name, "type" => "composite", "fields" => fields}

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "undo_whole_#{n}"

    fields = [
      str("title"),
      comp("c2", [lt("cap"), str("n")]),
      comp("c4", [comp("inner", [lt("cap"), str("n")]), str("keep")]),
      comp("comp", [lt("cap"), str("note")]),
      %{
        "name" => "arr",
        "title" => "arr",
        "type" => "arrayOf",
        "of" => comp("row", [lt("cap"), str("note")])
      },
      str("notes")
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => type, "title" => "Whole #{n}", "visibility" => "public", "fields" => fields},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-uw-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-uw", @dataset, ~w(read write admin), ws_id)

    prior = Barkpark.PluginEnv.capture()
    Barkpark.PluginEnv.put!([Halt])
    :persistent_term.put(Halt, false)

    on_exit(fn ->
      Barkpark.PluginEnv.restore(prior)
      :persistent_term.put(Halt, false)
    end)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     root: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type}
  end

  defp doc!(c, content) do
    id = "uw-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => Map.put(content, "notes", "0")},
        @dataset
      )

    id
  end

  defp desk(c, id) do
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  # The draft row as the store holds it, jsonb text.
  defp row(c, id) do
    %{rows: [[text]]} =
      Barkpark.Repo.query!(
        "select content::text from documents where type = $1 and doc_id = $2 and dataset = $3",
        [c.type, "drafts." <> id, @dataset]
      )

    text
  end

  defp change(view, name, value),
    do: view |> form(@form, %{name => value}) |> render_change(%{"_target" => [name]})

  defp undo(view, c, id, redo \\ false) do
    mark = %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, id)}
    render_hook(view, "desk-undo", Map.put(mark, "redo", redo))
    render(view)
  end

  defp buffer(view), do: :sys.get_state(view.pid).socket.assigns[:editor_form]

  defp marker?(value) when is_struct(value, Barkpark.Content.Forms.Unset), do: true
  defp marker?(%{} = map), do: Enum.any?(map, fn {_k, v} -> marker?(v) end)
  defp marker?(list) when is_list(list), do: Enum.any?(list, &marker?/1)
  defp marker?(_value), do: false

  # Clear both languages, then undo twice and redo twice.
  defp clear_undo_redo(view, c, id, name) do
    change(view, name <> ".cap.nob", "")
    Process.sleep(650)
    change(view, name <> ".cap.eng", "")
    cleared = stored(c, id)
    undo1 = undo(view, c, id) && stored(c, id)
    undo2 = undo(view, c, id) && stored(c, id)
    redo1 = undo(view, c, id, true) && stored(c, id)
    redo2 = undo(view, c, id, true) && stored(c, id)
    {cleared, undo1, undo2, redo1, redo2}
  end

  test "an object unset with its stored null comes back with it, and the last redo unsets it",
       c do
    c2 = %{"cap" => %{"nob" => "cn", "eng" => "ce"}, "n" => nil}
    id = doc!(c, %{"c2" => c2})
    view = desk(c, id)

    {cleared, undo1, undo2, redo1, redo2} = clear_undo_redo(view, c, id, "doc[c2]")

    refute Map.has_key?(cleared, "c2")
    assert Map.fetch(undo1, "c2") == {:ok, %{"cap" => %{"eng" => "ce"}, "n" => nil}}
    assert Map.fetch(undo2, "c2") == {:ok, c2}
    assert Map.fetch(redo1, "c2") == {:ok, %{"cap" => %{"eng" => "ce"}, "n" => nil}}
    refute Map.has_key?(redo2, "c2")
    refute row(c, id) =~ "__bp_unset__"
  end

  test "a nested object unset with its stored null comes back with it, and the last redo unsets it",
       c do
    c4 = %{"inner" => %{"cap" => %{"nob" => "cn", "eng" => "ce"}, "n" => nil}, "keep" => "k"}
    id = doc!(c, %{"c4" => c4})
    view = desk(c, id)

    {cleared, undo1, undo2, redo1, redo2} = clear_undo_redo(view, c, id, "doc[c4].inner")

    assert cleared["c4"] == %{"keep" => "k"}

    assert undo1["c4"] == %{
             "inner" => %{"cap" => %{"eng" => "ce"}, "n" => nil},
             "keep" => "k"
           }

    assert undo2["c4"] == c4
    assert redo1["c4"] == undo1["c4"]
    assert redo2["c4"] == %{"keep" => "k"}
  end

  test "a refused undo leaves no marker in the form, the page or the store", c do
    id = doc!(c, %{"comp" => %{"cap" => %{"nob" => "cn"}}})
    view = desk(c, id)

    change(view, "doc[comp].note", "x")
    assert stored(c, id)["comp"] == %{"cap" => %{"nob" => "cn"}, "note" => "x"}

    :persistent_term.put(Halt, true)
    html = undo(view, c, id)
    assert stored(c, id)["comp"] == %{"cap" => %{"nob" => "cn"}, "note" => "x"}
    refute marker?(buffer(view))
    refute html =~ "__bp_unset__"

    :persistent_term.put(Halt, false)
    change(view, "doc[notes]", "nx")
    assert stored(c, id)["notes"] == "nx"
    refute row(c, id) =~ "__bp_unset__"
  end

  test "a refused undo in an array row leaves no marker, and the item copies clean", c do
    row = %{"_key" => "k1", "_type" => "row", "cap" => %{"nob" => "cn"}}
    id = doc!(c, %{"arr" => [row]})
    view = desk(c, id)

    change(view, "doc[arr][0].note", "x")
    assert stored(c, id)["arr"] == [Map.put(row, "note", "x")]

    :persistent_term.put(Halt, true)
    html = undo(view, c, id)
    assert stored(c, id)["arr"] == [Map.put(row, "note", "x")]
    refute marker?(buffer(view))
    refute html =~ "__bp_unset__"

    render_hook(view, "desk-item-copy", %{"field" => "arr", "path" => "arr", "index" => "0"})
    assert_push_event(view, "desk:field-copied", %{json: json})
    refute json =~ "__bp_unset__"

    :persistent_term.put(Halt, false)
    change(view, "doc[notes]", "nx")
    assert stored(c, id)["notes"] == "nx"
    refute row(c, id) =~ "__bp_unset__"
  end

  test "a refused clear of a language field keeps nil, not the marker, in the form", c do
    id = doc!(c, %{"comp" => %{"cap" => %{"nob" => "cn", "eng" => "ce"}, "note" => "nn"}})
    view = desk(c, id)

    change(view, "doc[comp].cap.nob", "")
    Process.sleep(650)
    :persistent_term.put(Halt, true)
    html = change(view, "doc[comp].cap.eng", "")
    refute marker?(buffer(view))
    refute html =~ "__bp_unset__"

    :persistent_term.put(Halt, false)
    change(view, "doc[notes]", "nx")
    refute row(c, id) =~ "__bp_unset__"
    assert stored(c, id)["notes"] == "nx"
  end
end
