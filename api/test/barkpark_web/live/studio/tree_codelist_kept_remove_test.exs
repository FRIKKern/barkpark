defmodule BarkparkWeb.Studio.TreeCodelistKeptRemoveTest.Halt do
  @moduledoc false
  # Refuses every write while the flag is on ("Save cancelled").
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(_doc),
    do: if(:persistent_term.get(__MODULE__, false), do: {:halt, "held"}, else: :ok)
end

defmodule BarkparkWeb.Studio.TreeCodelistKeptRemoveTest do
  @moduledoc """
  task-9ae4a10efeab3bc9: a tree codelist over a stored value that is no code
  (7), top-level and in an object, offers Remove, in the desk and the old
  Studio. The value is kept as stored on an edit of another field; Remove's
  own press clears that field only. A top-level Remove takes the key off the
  document. A nested one does too in the desk, and an object left empty goes
  with it (TanStack's `write()`); the old Studio stores "" there, as on main.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.TreeCodelistKeptRemoveTest.Halt

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list_id = "onixedit:tree-kept-#{n}"

    {:ok, _} =
      Codelists.register("onixedit", list_id, %{
        issue: "1",
        name: "Tree kept",
        values: [
          %{
            code: "FB",
            translations: [%{language: "eng", label: "Fiction"}],
            children:
              for(
                i <- 1..101,
                do: %{code: "FB#{i}", translations: [%{language: "eng", label: "F#{i}"}]}
              )
          }
        ]
      })

    type = "tk_book_#{n}"
    tree = %{"title" => "Subject", "type" => "codelist", "codelistId" => list_id}

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Tree kept",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            Map.put(tree, "name", "subject"),
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [
                Map.merge(tree, %{"name" => "code", "title" => "Code"}),
                %{"name" => "label", "title" => "Label", "type" => "string"}
              ]
            },
            %{
              "name" => "solo",
              "title" => "Solo",
              "type" => "composite",
              "fields" => [Map.merge(tree, %{"name" => "scode", "title" => "Solo code"})]
            },
            %{
              "name" => "items",
              "title" => "Items",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "fields" => [
                  Map.merge(tree, %{"name" => "icode", "title" => "Item code"}),
                  %{"name" => "ilabel", "title" => "Item label", "type" => "string"},
                  %{
                    "name" => "box",
                    "title" => "Box",
                    "type" => "composite",
                    "fields" => [Map.merge(tree, %{"name" => "bcode", "title" => "Box code"})]
                  }
                ]
              }
            },
            %{"name" => "notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "tree-kept-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "tree-kept", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, root: root, type: type}
  end

  defp doc!(c) do
    id = "tk-#{System.unique_integer([:positive])}"

    content = %{
      "subject" => 7,
      "meta" => %{"code" => 7, "label" => "x"},
      "solo" => %{"scode" => "FB2"},
      "items" => [
        %{"_key" => "ka", "icode" => 7},
        %{"_key" => "kb", "icode" => 7, "box" => %{"bcode" => 7}}
      ],
      "notes" => "0"
    }

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => content},
        @dataset
      )

    id
  end

  defp open(c, :desk, id) do
    {:ok, view, _} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert has_element?(view, "[data-pane-editing] #editor-form")
    {view, "[data-pane-editing] #editor-form"}
  end

  defp open(c, :studio, id) do
    {:ok, view, _} = live(c.conn, "#{c.root}/#{c.type}/#{id}")
    assert has_element?(view, "#editor-form")
    {view, "#editor-form"}
  end

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  defp edit_notes(view, form, value) do
    view
    |> form(form, %{"doc" => %{"notes" => value}})
    |> render_change(%{"_target" => ["doc", "notes"]})
  end

  # The tree's own wrapper: the top-level field's, or the object's subfield's.
  defp field(form, :top), do: ~s(#{form} [data-field-name="subject"])
  defp field(form, :nested), do: ~s(#{form} [data-field-name="code"])

  defp remove(form, where), do: field(form, where) <> ~s( [data-test-id="tree-codelist-remove"])

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: Remove is offered over a stored 7, top-level and in an object", c do
      {view, form} = open(c, @surface, doc!(c))

      assert has_element?(view, remove(form, :top))
      assert has_element?(view, remove(form, :nested))

      if @surface == :desk do
        assert has_element?(
                 view,
                 ~s(#{field(form, :top)} .codelist-current[data-codelist-kept]),
                 "Not a code (kept as stored)"
               )
      end
    end

    test "#{surface}: an edit elsewhere keeps the 7; Remove clears its own field only",
         c do
      id = doc!(c)
      {view, form} = open(c, @surface, id)

      edit_notes(view, form, "typed")
      assert stored(c, id)["subject"] === 7
      assert stored(c, id)["meta"] == %{"code" => 7, "label" => "x"}

      EditorPost.press_on(view, element(view, remove(form, :top)))
      render(view)
      # A top-level "" takes the key off, as Remove over a code does.
      refute Map.has_key?(stored(c, id), "subject")
      assert stored(c, id)["meta"] == %{"code" => 7, "label" => "x"}

      EditorPost.press_on(view, element(view, remove(form, :nested)))
      render(view)
      # The desk unsets the key, as TanStack does; the old Studio stores "".
      meta = if @surface == :desk, do: %{"label" => "x"}, else: %{"code" => "", "label" => "x"}
      assert stored(c, id)["meta"] == meta

      edit_notes(view, form, "again")
      assert stored(c, id)["notes"] == "again"
      assert stored(c, id)["meta"] == meta
    end
  end

  test "desk: a nested tree has the desk's toolbar and says a 7 is kept", c do
    {view, form} = open(c, :desk, doc!(c))

    assert has_element?(
             view,
             ~s(#{field(form, :nested)} .codelist-current[data-codelist-kept]),
             "Not a code (kept as stored)"
           )
  end

  test "desk: Remove over an object's only code takes the object off", c do
    id = doc!(c)
    {view, form} = open(c, :desk, id)
    before = stored(c, id)

    EditorPost.press_on(
      view,
      element(view, ~s(#{form} [data-field-name="scode"] [data-test-id="tree-codelist-remove"]))
    )

    render(view)

    refute Map.has_key?(stored(c, id), "solo")
    assert Map.delete(stored(c, id), "solo") == Map.delete(before, "solo")
  end

  test "desk: Remove in an array item takes the code off that row only; the row stays", c do
    id = doc!(c)
    {view, form} = open(c, :desk, id)
    row = ~s(#{form} li[data-item-path='items[_key=="kb"]'] [data-field-name="icode"])

    assert has_element?(view, ~s(#{row} .codelist-current[data-codelist-kept]))
    EditorPost.press_on(view, element(view, row <> ~s( [data-test-id="tree-codelist-remove"])))
    render(view)

    assert stored(c, id)["items"] == [
             %{"_key" => "ka", "icode" => 7},
             %{"_key" => "kb", "box" => %{"bcode" => 7}}
           ]

    edit_notes(view, form, "again")

    assert stored(c, id)["items"] == [
             %{"_key" => "ka", "icode" => 7},
             %{"_key" => "kb", "box" => %{"bcode" => 7}}
           ]
  end

  # TanStack's `write()` unsets no parent inside an array item: an object
  # in the row left empty stays `{}`.
  test "desk: Remove of an object's only code inside an array item leaves the object {}", c do
    id = doc!(c)
    {view, form} = open(c, :desk, id)
    box = ~s(#{form} li[data-item-path='items[_key=="kb"]'] [data-field-name="bcode"])

    EditorPost.press_on(view, element(view, box <> ~s( [data-test-id="tree-codelist-remove"])))
    render(view)

    assert stored(c, id)["items"] == [
             %{"_key" => "ka", "icode" => 7},
             %{"_key" => "kb", "icode" => 7, "box" => %{}}
           ]
  end

  # Review r4 of #27533, B6: no unset marker reaches the form, the page or
  # the store. #27936 review: a refused Remove is a refused clear; the page
  # draws the code as stored, says "Not saved", and the next post leaves it.
  test "desk: a refused nested Remove shows the stored code, says not saved, and leaves no marker",
       c do
    prior = Barkpark.PluginEnv.capture()
    Barkpark.PluginEnv.put!([Halt])

    on_exit(fn ->
      Barkpark.PluginEnv.restore(prior)
      :persistent_term.put(Halt, false)
    end)

    id = doc!(c)
    {view, form} = open(c, :desk, id)
    before = stored(c, id)

    :persistent_term.put(Halt, true)
    EditorPost.press_on(view, element(view, remove(form, :nested)))
    html = render(view)
    assert stored(c, id) == before

    buffer = :sys.get_state(view.pid).socket.assigns[:editor_form]
    assert buffer["meta"] == before["meta"]
    refute html =~ "__bp_unset__"
    assert html =~ "Not saved: held"
    assert has_element?(view, remove(form, :nested))

    :persistent_term.put(Halt, false)
    html = edit_notes(view, form, "after")
    assert stored(c, id)["meta"] == before["meta"]
    assert html =~ "Not saved"
    assert has_element?(view, remove(form, :nested))

    %{rows: [[text]]} =
      Barkpark.Repo.query!(
        "select content::text from documents where type = $1 and doc_id = $2 and dataset = $3",
        [c.type, "drafts." <> id, @dataset]
      )

    refute text =~ "__bp_unset__"
    assert stored(c, id)["notes"] == "after"
  end
end
