defmodule BarkparkWeb.Studio.DeskConditionalReadOnlyTest do
  @moduledoc """
  WP2 PR 2: a field whose `readOnly` is a condition is locked in the desk
  while the condition holds, for an admin too (`Desk.FieldLock`). A text field
  keeps its input with the `readonly` attribute; any other type is drawn
  display-only with no input.

  The round trip: a document with a value in every locked field. The
  condition is flipped, one other field is edited; every other stored value is
  the same afterwards.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.FieldLock

  @dataset "production"
  @pane "[data-pane-editing]"
  @form "#{@pane} #editor-form"

  @done %{"field" => "stage", "operator" => "eq", "value" => "done"}

  @fields [
    %{"name" => "title", "title" => "Title", "type" => "string"},
    %{
      "name" => "stage",
      "title" => "Stage",
      "type" => "select",
      "options" => ["idea", "review", "done"]
    },
    %{"name" => "reviewNote", "title" => "Review note", "type" => "text", "readOnly" => @done},
    %{"name" => "byline", "title" => "Byline", "type" => "string", "readOnly" => @done},
    %{"name" => "score", "title" => "Score", "type" => "number", "readOnly" => @done},
    %{"name" => "path", "title" => "Path", "type" => "slug", "readOnly" => @done},
    %{"name" => "signed", "title" => "Signed", "type" => "boolean", "readOnly" => @done},
    %{"name" => "day", "title" => "Day", "type" => "date", "readOnly" => @done},
    %{
      "name" => "tags",
      "title" => "Tags",
      "type" => "arrayOf",
      "ordered" => true,
      "of" => %{"type" => "string"},
      "readOnly" => @done
    },
    %{
      "name" => "seo",
      "title" => "SEO",
      "type" => "composite",
      "readOnly" => @done,
      "fields" => [
        %{"name" => "metaTitle", "title" => "Meta title", "type" => "string"},
        %{"name" => "noIndex", "title" => "No index", "type" => "boolean"}
      ]
    },
    %{"name" => "fixed", "title" => "Fixed", "type" => "string", "readOnly" => true},
    %{"name" => "spare", "title" => "Spare", "type" => "string", "readOnly" => @done}
  ]

  # `spare` is left out: an absent locked field must stay absent.
  @content %{
    "reviewNote" => "Checked facts.\nTwice.",
    "byline" => "Ada",
    "score" => 0,
    "path" => %{"_type" => "slug", "current" => "a-path"},
    "signed" => false,
    "day" => "2026-09-19",
    "tags" => ["one", "two"],
    "seo" => %{"metaTitle" => "Meta", "noIndex" => false},
    "fixed" => "Set by the server"
  }

  @text ~w(reviewNote byline score path)
  @other ~w(signed day tags seo)

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    type = "lock_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Lock #{n}",
          "visibility" => "public",
          "fields" => @fields
        },
        @dataset
      )

    scope = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    {:ok, conn: conn, n: n, type: type, scope: scope}
  end

  defp sign_in(conn, perms) do
    raw = "desk-lock-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-lock", @dataset, perms, ws_id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp doc!(c, stage) do
    id = "lock-#{c.n}-#{stage}"
    attrs = Map.merge(@content, %{"doc_id" => id, "title" => "Locked", "stage" => stage})
    {:ok, _} = Content.create_document(c.type, attrs, @dataset)
    {:ok, stored} = Content.get_document("drafts." <> id, c.type, @dataset)
    {id, stored.content}
  end

  defp open(conn, path, form) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, form) end)
    view
  end

  defp desk(c, id),
    do: open(sign_in(c.conn, ~w(read write admin)), "#{c.scope}/_desk/#{c.type};#{id}", @form)

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  # What the browser posts: every input the form shows, plus `changes`.
  defp change(view, changes) do
    view |> element(@form) |> render_change(%{"doc" => changes})
    render_async(view, 5_000)
  end

  defp draft(c, id) do
    {:ok, doc} = Content.get_document("drafts." <> id, c.type, @dataset)
    doc.content
  end

  defp saved?(c, id, key, value),
    do: eventually(fn -> Map.get(draft(c, id), key) == value end)

  defp titled?(c, id, title) do
    eventually(fn ->
      match?({:ok, %{title: ^title}}, Content.get_document("drafts." <> id, c.type, @dataset))
    end)
  end

  defp input(name), do: ~s(#{@form} [name="doc[#{name}]"])

  test "while the condition holds a text field is readonly, an admin's too", c do
    {id, _stored} = doc!(c, "done")
    view = desk(c, id)

    assert has_element?(view, ~s(#{@form} textarea[id="reviewNote"][readonly]))
    assert has_element?(view, ~s(#{@form} .field label[for="reviewNote"]))
    assert has_element?(view, ~s(#{@form} input[id="byline"][readonly][value="Ada"]))
    assert has_element?(view, ~s(#{@form} input[id="score"][readonly][value="0"]))
    assert has_element?(view, ~s(#{@form} input[id="path"][readonly][value="a-path"]))
    assert has_element?(view, ~s(#{@form} button[phx-click="slug-generate"][disabled]))
  end

  test "before it holds every field is an ordinary input", c do
    {id, _stored} = doc!(c, "review")
    view = desk(c, id)

    for name <- @text ++ ~w(signed day) do
      assert has_element?(view, input(name)), "no input for #{name}"
    end

    refute has_element?(view, "#{@form} [readonly]")
    refute has_element?(view, "#{@form} [data-schema-readonly]")
    refute has_element?(view, ~s(#{@form} button[phx-click="slug-generate"][disabled]))
  end

  test "any other locked type is display-only and posts nothing", c do
    {id, _stored} = doc!(c, "done")
    view = desk(c, id)

    for name <- @other do
      assert has_element?(
               view,
               ~s(#{@form} [data-schema-readonly][data-readonly-field="#{name}"])
             ),
             "#{name} is not display-only"

      refute has_element?(view, ~s(#{@form} [name^="doc[#{name}]"])), "#{name} still posts"
    end
  end

  test "the lock follows the field the condition reads", c do
    {id, _stored} = doc!(c, "review")
    view = desk(c, id)
    refute has_element?(view, ~s(#{@form} textarea[id="reviewNote"][readonly]))

    change(view, %{"stage" => "done"})
    assert saved?(c, id, "stage", "done")
    assert has_element?(view, ~s(#{@form} textarea[id="reviewNote"][readonly]))
    refute has_element?(view, input("signed"))

    change(view, %{"stage" => "idea"})
    assert saved?(c, id, "stage", "idea")
    refute has_element?(view, ~s(#{@form} textarea[id="reviewNote"][readonly]))
    assert has_element?(view, input("signed"))
  end

  test "readOnly: true is as before: an admin keeps the input", c do
    {id, _stored} = doc!(c, "done")
    view = desk(c, id)
    assert has_element?(view, ~s|#{@form} input[id="fixed"]:not([readonly])|)
  end

  # The desk route turns a non-admin token away today, so the non-admin half
  # is read off the component.
  test "a non-admin gets the same lock; readOnly: true stays display-only" do
    render = fn field ->
      render_component(&BarkparkWeb.Components.FieldInputs.input/1,
        field: FieldLock.resolve(field, %{"stage" => "done"}, true),
        editor_form: %{"stage" => "done", field["name"] => "kept"},
        id_prefix: "",
        schema_admin: false
      )
    end

    text = render.(%{"name" => "note", "type" => "text", "readOnly" => @done})
    assert text =~ ~r/<textarea[^>]*id="note"[^>]*readonly/
    assert text =~ ~s(name="doc[note]")

    flag = render.(%{"name" => "flag", "type" => "boolean", "readOnly" => @done})
    assert flag =~ "data-schema-readonly"
    refute flag =~ "name="

    fixed = render.(%{"name" => "fixed", "type" => "string", "readOnly" => true})
    assert fixed =~ "data-schema-readonly"
    refute fixed =~ "name="
  end

  # Control: the old Studio resolves the condition as main does. An admin
  # keeps plain inputs, a text field has no `readonly`.
  test "the old Studio is as main has it", c do
    {id, _stored} = doc!(c, "done")
    conn = sign_in(c.conn, ~w(read write admin))
    view = open(conn, "#{c.scope}/#{c.type}/#{id}", "#editor-form")

    assert has_element?(view, ~s|#editor-form textarea[name="doc[reviewNote]"]:not([readonly])|)
    assert has_element?(view, ~s(#editor-form [name="doc[signed]"]))
    refute has_element?(view, "#editor-form [data-schema-readonly]")
  end

  test "FieldLock.resolve/3" do
    form = %{"stage" => "done"}
    text = %{"name" => "a", "type" => "text", "readOnly" => @done}
    flag = %{"name" => "b", "type" => "boolean", "readOnly" => @done}

    assert %{"readOnly" => false, "lockedByRule" => true} = FieldLock.resolve(text, form, true)
    assert %{"readOnly" => true, "lockedByRule" => true} = FieldLock.resolve(flag, form, true)
    assert FieldLock.resolve(text, %{"stage" => "idea"}, true) == Map.put(text, "readOnly", false)
    assert FieldLock.resolve(text, nil, true) == Map.put(text, "readOnly", false)
    assert FieldLock.resolve(text, form, false) == Map.put(text, "readOnly", true)

    fixed = %{"name" => "c", "type" => "string", "readOnly" => true}
    assert FieldLock.resolve(fixed, form, true) == fixed
    refute FieldLock.locked?(fixed)
    refute FieldLock.locked?(%{"name" => "d", "lockedByRule" => "true"})
  end

  describe "stored-row round trip" do
    test "locked, one other field edited: every other stored value is the same", c do
      {id, stored} = doc!(c, "done")
      assert stored["signed"] == false
      assert stored["score"] == 0
      refute Map.has_key?(stored, "spare")
      view = desk(c, id)

      change(view, %{"title" => "Renamed"})
      assert titled?(c, id, "Renamed")
      assert draft(c, id) |> Map.delete("title") == Map.delete(stored, "title")
    end

    test "the condition flipped on and off, an edit in between", c do
      {id, stored} = doc!(c, "review")
      view = desk(c, id)

      change(view, %{"stage" => "done"})
      assert saved?(c, id, "stage", "done")
      assert draft(c, id) == Map.put(stored, "stage", "done")

      # A crafted post into a locked field's readonly input is what any post is:
      # the browser never sends one. An unrelated edit keeps every locked value.
      change(view, %{"fixed" => "By an admin"})
      assert saved?(c, id, "fixed", "By an admin")
      assert draft(c, id) == Map.merge(stored, %{"stage" => "done", "fixed" => "By an admin"})

      change(view, %{"stage" => "review"})
      assert saved?(c, id, "stage", "review")
      assert draft(c, id) == Map.put(stored, "fixed", "By an admin")

      change(view, %{"reviewNote" => "Checked again."})
      assert saved?(c, id, "reviewNote", "Checked again.")

      assert draft(c, id) ==
               Map.merge(stored, %{"fixed" => "By an admin", "reviewNote" => "Checked again."})
    end
  end
end
