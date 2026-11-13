defmodule BarkparkWeb.Studio.RefusedSave.HaltOnFail do
  @moduledoc false
  # A before_save hook that refuses any write whose excerpt holds "FAIL": a
  # real `{:error, {:halted, _}}` from the writer ("Save cancelled").
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(%{doc: doc}) do
    excerpt = (Map.get(doc, "content") || %{})["excerpt"]

    if is_binary(excerpt) and String.contains?(excerpt, "FAIL"),
      do: {:halt, "forced by the test"},
      else: :ok
  end

  def halt(_), do: :ok
end

defmodule BarkparkWeb.Studio.RefusedSaveTest do
  @moduledoc """
  One refused autosave must not make every later save fail
  (task-a0debf39daa6137d).

  The browser posts the whole form on every change, so a value the store
  refused rode along with every later edit: each was refused too, the footer
  said only "Save failed", and a reload lost them all.

  The refusals are real: a title over the column's 255 characters is a
  `{:error, %Ecto.Changeset{}}` from the writer ("Save failed"), and a
  `before_save` hook halts any write whose excerpt holds "FAIL" ("Save
  cancelled"). Every post below carries the whole form, as the browser's does.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.RefusedSave.HaltOnFail

  @dataset "production"
  @long String.duplicate("x", 300)

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "rs_post_#{n}"
    doc_id = "rs-post-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "RS posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"},
            %{"name" => "note", "title" => "Note", "type" => "string"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => doc_id,
          "title" => "Fixture post",
          "content" => %{"excerpt" => "First", "note" => "N"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "rs-editors-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "rs-editors", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    prior = Barkpark.PluginEnv.capture()
    Barkpark.PluginEnv.put!([HaltOnFail])
    on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)

    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    {:ok, conn: conn, base: base, type: type, doc_id: doc_id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type}/#{c.doc_id}")
    view
  end

  defp open_desk(c) do
    {:ok, view, _html} = live(c.conn, "#{c.base}/_desk/#{c.type};#{c.doc_id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp shown(view, name) do
    html = view |> element(~s(#editor-form input[name="doc[#{name}]"])) |> render()
    [_, value] = Regex.run(~r/value="([^"]*)"/, html)
    value
  end

  # The whole form as the page shows it, with one field changed.
  defp change(view, name, value) do
    form = Map.new(~w(title excerpt note), &{&1, shown(view, &1)})

    view
    |> element("#editor-form")
    |> render_change(%{"_target" => ["doc", name], "doc" => Map.put(form, name, value)})
  end

  defp stored(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    content = doc.content || %{}
    {doc.title, content["excerpt"], content["note"]}
  end

  defp strip(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()
  defp status(view), do: view |> element("#editor-form .save-status") |> render() |> strip()

  # The words under the field that holds the input `doc[name]`.
  defp mark(view, name) do
    field = ~s|#editor-form .editor-field:has(input[name="doc[#{name}]"])|

    if has_element?(view, "#{field} .field-errors"),
      do: view |> element("#{field} .field-errors") |> render() |> strip(),
      else: nil
  end

  test "a refused title does not block the excerpt typed after it", c do
    view = open(c)

    change(view, "title", @long)
    assert stored(c) == {"Fixture post", "First", "N"}

    change(view, "excerpt", "Second")
    assert stored(c) == {"Fixture post", "Second", "N"}

    change(view, "note", "N2")
    assert stored(c) == {"Fixture post", "Second", "N2"}
  end

  test "the refused field says why, and the save region names it", c do
    view = open(c)

    change(view, "title", @long)

    assert mark(view, "title") =~ "should be at most 255 character(s)"
    assert status(view) == "Not saved: Title"
    assert mark(view, "excerpt") == nil

    # Still marked after another field's save landed.
    change(view, "excerpt", "Second")

    assert mark(view, "title") =~ "should be at most 255 character(s)"
    assert status(view) == "Not saved: Title"
    assert mark(view, "excerpt") == nil
  end

  test "the refused value stays in the form, and a fixed one saves and clears the mark", c do
    view = open(c)

    change(view, "title", @long)
    change(view, "excerpt", "Second")
    assert shown(view, "title") == @long

    change(view, "title", "Short enough")

    assert stored(c) == {"Short enough", "Second", "N"}
    assert mark(view, "title") == nil
    assert status(view) == "Saved"
  end

  test "a save a hook cancelled holds its field too, with the hook's words", c do
    view = open(c)

    change(view, "excerpt", "First FAIL")
    assert mark(view, "excerpt") =~ "forced by the test"
    assert status(view) == "Not saved: Excerpt"

    change(view, "title", "Typed after")

    assert stored(c) == {"Typed after", "First", "N"}
    assert shown(view, "excerpt") == "First FAIL"
    assert mark(view, "excerpt") =~ "forced by the test"
  end

  test "two refused fields are both held; the third field still saves", c do
    view = open(c)

    change(view, "title", @long)
    change(view, "excerpt", "First FAIL")
    assert status(view) == "Not saved: Excerpt, Title"

    change(view, "note", "N2")

    assert stored(c) == {"Fixture post", "First", "N2"}
    assert mark(view, "title") =~ "255"
    assert mark(view, "excerpt") =~ "forced by the test"
  end

  test "the Save button's refusal says why: nothing is cut out of an explicit save", c do
    view = open(c)

    view
    |> element("#editor-form")
    |> render_submit(%{"doc" => %{"title" => @long, "excerpt" => "Second", "note" => "N"}})

    assert stored(c) == {"Fixture post", "First", "N"}
    assert status(view) =~ "Save failed: title: should be at most 255 character(s)"
  end

  test "another editor's save does not replace the held field", c do
    a = open(c)
    b = open(c)

    change(b, "title", @long)
    change(b, "excerpt", "From B")
    render(a)

    change(a, "note", "From A")
    render(b)

    assert shown(b, "title") == @long
    assert shown(b, "note") == "From A"
    assert mark(b, "title") =~ "255"
    assert stored(c) == {"Fixture post", "From B", "From A"}
  end

  test "the desk: the footer names the held field and the tab-close guard still asks", c do
    view = open_desk(c)

    change(view, "title", @long)
    change(view, "excerpt", "Second")
    render_async(view, 5_000)

    assert stored(c) == {"Fixture post", "Second", "N"}

    footer = ~s([data-pane-editing] .dk-edit-footer [data-desk-footer-status])

    assert eventually(fn ->
             view |> element(footer) |> render() |> strip() == "Not saved: Title"
           end)

    assert has_element?(view, ~s([data-pane-editing][data-desk-save="Save failed"]))
    assert mark(view, "title") =~ "should be at most 255 character(s)"
  end

  describe "a dataset that enforces its schema's rules" do
    setup c do
      type = c.type <> "_rules"

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "RS rules",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{
                "name" => "code",
                "title" => "Code",
                "type" => "string",
                "validation" => %{"max" => 5}
              },
              %{
                "name" => "must",
                "title" => "Must",
                "type" => "string",
                "validation" => %{"required" => true}
              }
            ]
          },
          @dataset
        )

      # Stored before the dataset enforces: `rules-old` has no `must`.
      for {id, content} <- [{"-ok", %{"code" => "abc", "must" => "here"}}, {"-old", %{}}] do
        {:ok, _} =
          Content.create_document(
            type,
            %{"doc_id" => c.doc_id <> id, "title" => "Rules", "content" => content},
            @dataset
          )
      end

      previous = Application.get_env(:barkpark, Barkpark.Content.Validation)
      Application.put_env(:barkpark, Barkpark.Content.Validation, enforce_datasets: [@dataset])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:barkpark, Barkpark.Content.Validation, previous),
          else: Application.delete_env(:barkpark, Barkpark.Content.Validation)
      end)

      {:ok, type: type}
    end

    defp open_rules(c, id) do
      {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type}/#{c.doc_id}#{id}")
      view
    end

    defp post_form(view, name, form) do
      view
      |> element("#editor-form")
      |> render_change(%{"_target" => ["doc", name], "doc" => form})
    end

    defp rules(c, id) do
      {doc, _draft?, _published?} =
        Content.fetch_doc_with_draft(c.type, c.doc_id <> id, @dataset)

      content = doc.content || %{}
      {doc.title, content["code"], content["must"]}
    end

    test "a value over its rule is held with the rule's words; the next field saves", c do
      view = open_rules(c, "-ok")

      post_form(view, "code", %{"title" => "Rules", "code" => "toolong", "must" => "here"})

      assert mark(view, "code") =~ "Not saved: "
      assert mark(view, "code") =~ "5"
      assert status(view) == "Not saved: Code"

      post_form(view, "title", %{"title" => "Typed", "code" => "toolong", "must" => "here"})

      assert rules(c, "-ok") == {"Typed", "abc", "here"}
      assert mark(view, "code") =~ "5"
    end

    test "a stored document that breaks a rule: the typed field is not blamed", c do
      view = open_rules(c, "-old")

      post_form(view, "title", %{"title" => "Typed", "code" => "", "must" => ""})

      assert rules(c, "-old") == {"Rules", nil, nil}
      assert mark(view, "title") == nil
      assert status(view) =~ "Save failed: must: "
      assert shown(view, "title") == "Typed"

      post_form(view, "must", %{"title" => "Typed", "code" => "", "must" => "now"})

      assert {"Typed", _code, "now"} = rules(c, "-old")
      assert status(view) == "Saved"
    end
  end
end
