defmodule BarkparkWeb.Studio.ObjectRichTextKeys.HaltOnFail do
  @moduledoc false
  # Refuses any write whose `meta.label` holds "FAIL": the label typing is
  # held unsaved in the form, and with it the object.
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(%{doc: doc}) do
    label = get_in(doc, ["content", "meta", "label"])
    if is_binary(label) and String.contains?(label, "FAIL"), do: {:halt, "test"}, else: :ok
  end

  def halt(_), do: :ok
end

defmodule BarkparkWeb.Studio.ObjectRichTextKeysTest do
  @moduledoc """
  task-d74a36f11381b523: rich text inside an object (`meta.rt`). The form
  takes a post's rich text rebuilt from the page's HTML, with new block keys
  (`b0` for the stored `k1`); the save rebuilds it against the stored blocks
  and keeps `k1`. So while A held the object (its label typing refused), an
  rt A never changed read as changed by A, and B's later rt edit raised a
  "meta" banner on A, whose form kept the old rt. TanStack merges an
  untouched path: it takes theirs. Rich text that draws the same as the
  stored blocks is the stored blocks.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.ObjectRichTextKeys.HaltOnFail

  @dataset "production"
  @banner ~s([data-test-id="doc-conflict-banner"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "obj_rt_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Object rich text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [
                %{"name" => "label", "title" => "Label", "type" => "string"},
                %{"name" => "rt", "title" => "Body", "type" => "richText"}
              ]
            }
          ]
        },
        @dataset
      )

    id = "obj-rt-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T0",
          "content" => %{"meta" => %{"label" => "l0", "rt" => [block("k1", "one two")]}}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "obj-rt-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "obj-rt", @dataset, ~w(read write admin), ws_id)

    prior = Barkpark.PluginEnv.capture()
    Barkpark.PluginEnv.put!([HaltOnFail])
    on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     paths: %{
       desk: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{type};#{id}",
       studio: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{type}/#{id}"
     },
     type: type,
     id: id}
  end

  defp block(key, text) do
    %{
      "_type" => "block",
      "_key" => key,
      "style" => "normal",
      "markDefs" => [],
      "children" => [%{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}]
    }
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.paths[c.surface])
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content["meta"]
  end

  # The rich text's words, block by block: keys left out.
  defp words(blocks) when is_list(blocks),
    do: for(%{"children" => spans} <- blocks, do: Enum.map_join(spans, & &1["text"]))

  defp words(_), do: nil

  # A post as the page sends it: the object's subfields under their dotted
  # names, the rich text as the editor's HTML.
  defp posts(view, target, label, html) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => %{"title" => "T0"},
      "doc[meta].label" => label,
      "doc[meta].rt" => html
    })
  end

  defp held_label(a, html) do
    posts(a, "doc[meta].label", "l0 FAIL", html)

    assert eventually(fn ->
             MapSet.member?(assigns(a).editor_unsaved_keys || MapSet.new(), "meta")
           end)
  end

  defp b_adds_a_paragraph(c, html) do
    b = open(c)
    posts(b, "doc[meta].rt", stored(c)["label"], html <> "<p>B para</p>")
    assert eventually(fn -> List.last(words(stored(c)["rt"])) == "B para" end)
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: A holds its label, B edits the rich text A did not change: A takes it, no banner",
         c do
      c = Map.put(c, :surface, @surface)
      a = open(c)
      held_label(a, "<p>one two</p>")
      b_adds_a_paragraph(c, "<p>one two</p>")

      assert eventually(fn ->
               words(assigns(a).editor_form["meta"]["rt"]) == ["one two", "B para"]
             end),
             inspect(assigns(a).editor_form["meta"])

      assert assigns(a).editor_form["meta"]["label"] == "l0 FAIL"
      assert assigns(a).doc_conflict == false
      refute has_element?(a, @banner)
    end

    test "#{surface}: A edits the rich text, then holds its label; B edits the rich text: A takes it, no banner",
         c do
      c = Map.put(c, :surface, @surface)
      a = open(c)
      posts(a, "doc[meta].rt", "l0", "<p>one two A</p>")
      assert eventually(fn -> words(stored(c)["rt"]) == ["one two A"] end)

      held_label(a, "<p>one two A</p>")
      b_adds_a_paragraph(c, "<p>one two A</p>")

      assert eventually(fn ->
               words(assigns(a).editor_form["meta"]["rt"]) == ["one two A", "B para"]
             end),
             inspect(assigns(a).editor_form["meta"])

      assert assigns(a).doc_conflict == false
      refute has_element?(a, @banner)
    end

    # Control (also on main): both changed the rich text, which cannot be
    # merged as blocks: the banner shows and A keeps its own.
    test "#{surface}: A holds its own rich text change, B edits the rich text: banner, A's kept",
         c do
      c = Map.put(c, :surface, @surface)
      a = open(c)
      held_label(a, "<p>one two A</p>")
      b_adds_a_paragraph(c, "<p>one two</p>")

      assert eventually(fn -> assigns(a).doc_conflict == true end)
      assert words(assigns(a).editor_form["meta"]["rt"]) == ["one two A"]
      assert has_element?(a, @banner)
    end
  end
end
