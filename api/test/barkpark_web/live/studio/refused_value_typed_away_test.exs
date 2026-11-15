defmodule BarkparkWeb.Studio.RefusedValueTypedAway.Refuse do
  @moduledoc false
  # Refuses an excerpt holding "FAIL"; an excerpt holding "NEEDS" or the
  # stage "done" while `summary` is empty.
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(%{doc: doc}) do
    c = Map.get(doc, "content") || %{}
    excerpt = if is_binary(c["excerpt"]), do: c["excerpt"], else: ""
    no_summary? = c["summary"] in [nil, ""]

    cond do
      String.contains?(excerpt, "FAIL") -> {:halt, "excerpt FAIL"}
      String.contains?(excerpt, "NEEDS") and no_summary? -> {:halt, "needs summary"}
      c["stage"] == "done" and no_summary? -> {:halt, "needs summary"}
      true -> :ok
    end
  end

  def halt(_), do: :ok
end

defmodule BarkparkWeb.Studio.RefusedValueTypedAwayTest do
  @moduledoc """
  #26396 review: one editor, a value the store refused, typed back.

  The refused value stays in the form buffer so the person can correct it.
  Typing it back to the stored value writes nothing, and the buffer kept the
  refused value. When the buffer stopped taking every posted value
  (`StudioLive.PostedEdits`), nothing replaced it: the next patch drew the
  refused value into the input again under "Saved", and the next change
  posted it as an edit.

  After a save settles, the buffer holds for every field what the page just
  posted for it or a newer value from another editor.

  A LiveView patch sets an input to what the server draws for it
  and never touches the input being typed in. So each test keeps the values
  the person has in the page (`dom`), posts those, and after each post gives
  every other text input what the server draws. Old Studio and desk.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.RefusedValueTypedAway.Refuse

  @dataset "production"

  @fields [
    %{"name" => "title", "title" => "Title", "type" => "string"},
    %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"},
    %{"name" => "stage", "title" => "Stage", "type" => "select", "options" => ["open", "done"]},
    %{"name" => "summary", "title" => "Summary", "type" => "string"},
    %{"name" => "tags", "title" => "Tags", "type" => "arrayOf", "of" => %{"type" => "string"}},
    %{"name" => "g", "title" => "G", "type" => "string"}
  ]

  @content %{"excerpt" => "First", "stage" => "open", "tags" => ["t1"], "g" => "g0"}

  # What the page shows when it opens.
  @dom %{
    "title" => "Old title",
    "excerpt" => "First",
    "stage" => "open",
    "summary" => "",
    "tags" => %{"0" => "t1"},
    "g" => "g0"
  }

  setup %{conn: conn} do
    prior = Barkpark.PluginEnv.capture()
    Barkpark.PluginEnv.put!([Refuse])
    on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)

    n = System.unique_integer([:positive])
    type = "refused_back_#{n}"
    doc_id = "refused-back-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => type, "title" => "Refused", "visibility" => "public", "fields" => @fields},
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => "Old title", "content" => @content},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "refused-back-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "refused-back", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     type: type,
     doc_id: doc_id,
     studio: {"#{base}/#{type}/#{doc_id}", "#editor-form"},
     desk: {"#{base}/_desk/#{type};#{doc_id}", "[data-pane-editing] #editor-form"}}
  end

  defp open(c, surface) do
    {url, sel} = Map.fetch!(c, surface)
    {:ok, view, _html} = live(c.conn, url)
    render_async(view, 5_000)
    assert Enum.any?(1..200, fn _ -> has_element?(view, sel) or (Process.sleep(10) && false) end)
    {view, sel}
  end

  @text_inputs ~w(title excerpt summary g)

  # The person sets `name` to `value`; the page posts everything it shows.
  # Then the patch: every text input but the one being typed in shows what the
  # server draws for it, as in a browser.
  defp types({view, sel} = a, dom, name, value) do
    dom = Map.put(dom, name, value)
    view |> element(sel) |> render_change(%{"_target" => ["doc", name], "doc" => dom})
    Enum.reduce(@text_inputs -- [name], dom, &Map.put(&2, &1, drawn(a, &1)))
  end

  defp add_tag_row({view, sel}) do
    BarkparkWeb.EditorPost.press_on(
      view,
      element(view, ~s(#{sel} [phx-value-action="add_row"][phx-value-field="tags"]))
    )
  end

  # What the server draws for the field now: a patch puts it in the input
  # when it differs from what the server drew before.
  defp drawn({view, sel}, name) do
    html = view |> element(~s(#{sel} input[name="doc[#{name}]"])) |> render()
    [_, value] = Regex.run(~r/\svalue="([^"]*)"/, html)
    value
  end

  defp buffer({view, _sel}, name),
    do: :sys.get_state(view.pid).socket.assigns.editor_form[name]

  defp stored(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    Map.put(doc.content || %{}, "title", doc.title)
  end

  for surface <- [:studio, :desk] do
    @surface surface

    test "#{surface}: a refused excerpt typed back, then two other changes: it is not saved", c do
      a = open(c, @surface)

      dom = types(a, @dom, "excerpt", "First NEEDS")
      assert stored(c)["excerpt"] == "First"
      assert buffer(a, "excerpt") == "First NEEDS"

      dom = types(a, dom, "excerpt", "First")

      # With a summary the hook would take "First NEEDS".
      dom = types(a, dom, "summary", "s")
      drawn_after_summary = drawn(a, "excerpt")

      types(a, dom, "g", "g1")

      assert Map.take(stored(c), ~w(excerpt summary g)) ==
               %{"excerpt" => "First", "summary" => "s", "g" => "g1"}

      assert drawn_after_summary == "First"
    end

    # Main kept the refused value in the buffer until the next change
    # elsewhere, and a select was drawn back to the refused option meanwhile.
    test "#{surface}: a refused value typed back leaves the buffer at once", c do
      a = open(c, @surface)

      dom = types(a, @dom, "excerpt", "FAIL here")
      dom = types(a, dom, "excerpt", "First")
      assert buffer(a, "excerpt") == "First"

      dom = types(a, dom, "stage", "done")
      assert buffer(a, "stage") == "done"
      types(a, dom, "stage", "open")
      assert buffer(a, "stage") == "open"

      assert Map.take(stored(c), ~w(excerpt stage)) == %{"excerpt" => "First", "stage" => "open"}
      refute render(elem(a, 0)) =~ "Not saved"
    end

    test "#{surface}: a still-refused excerpt typed back is not drawn again, and an array op does not post it",
         c do
      a = open(c, @surface)

      dom = types(a, @dom, "excerpt", "FAIL here")
      assert stored(c)["excerpt"] == "First"

      dom = types(a, dom, "excerpt", "First")
      types(a, dom, "g", "g1")

      assert drawn(a, "excerpt") == "First"
      assert buffer(a, "excerpt") == "First"
      refute render(elem(a, 0)) =~ "Not saved"

      # An array op posts the form buffer.
      add_tag_row(a)
      assert buffer(a, "excerpt") == "First"
      assert Map.take(stored(c), ~w(excerpt g)) == %{"excerpt" => "First", "g" => "g1"}
    end

    test "#{surface}: a refused select option set back, a summary, then an array op: it is not saved",
         c do
      a = open(c, @surface)

      dom = types(a, @dom, "stage", "done")
      assert stored(c)["stage"] == "open"

      dom = types(a, dom, "stage", "open")

      # With a summary the hook would take "done".
      types(a, dom, "summary", "s")
      add_tag_row(a)

      assert Map.take(stored(c), ~w(stage summary)) == %{"stage" => "open", "summary" => "s"}
    end

    test "#{surface}: a refused value corrected to a new one is saved, with the change made meanwhile",
         c do
      a = open(c, @surface)

      dom = types(a, @dom, "excerpt", "FAIL here")
      dom = types(a, dom, "g", "g1")
      assert buffer(a, "excerpt") == "FAIL here"
      assert stored(c)["g"] == "g1"

      types(a, dom, "excerpt", "Fixed")
      assert Map.take(stored(c), ~w(excerpt g)) == %{"excerpt" => "Fixed", "g" => "g1"}
      refute render(elem(a, 0)) =~ "Not saved"
    end
  end
end
