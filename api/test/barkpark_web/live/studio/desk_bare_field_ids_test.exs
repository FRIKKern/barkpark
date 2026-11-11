defmodule BarkparkWeb.Studio.DeskBareFieldIdsTest do
  @moduledoc """
  R19b: Sanity's specs find a field by `.field` around an input whose id is
  the bare field path (`.field:has([id="excerpt"])`). In the desk the
  Studio's editor now names its inputs that way, the label's `for` follows,
  and an image field is a `<fieldset class="field">`. The old Studio keeps
  `doc-field-<doc>-<path>` and its `<div>` wrappers.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "ids_#{n}"
    field = fn name, t -> %{"name" => name, "title" => String.capitalize(name), "type" => t} end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Ids #{type}",
          "visibility" => "public",
          "fields" => [
            field.("title", "string"),
            field.("excerpt", "text"),
            field.("year", "number"),
            field.("done", "boolean"),
            field.("day", "date"),
            field.("cover", "image")
          ]
        },
        @dataset
      )

    id = "ids-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Here", "excerpt" => "Short"},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-ids-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-ids", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn, desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}", id: id}
  end

  defp desk(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp ids(html), do: for([_, id] <- Regex.scan(~r/\sid="([^"]+)"/, html), do: id)

  test "in the desk a field's input is named by its bare path, and its label follows", c do
    view = desk(c)
    form = "[data-pane-editing] #editor-form"

    for path <- ~w(title excerpt year done day) do
      assert has_element?(view, ~s(#{form} .editor-field.field [id="#{path}"])),
             "no .field wraps an input with id=#{path}"

      assert has_element?(view, ~s(#{form} .field label[for="#{path}"]))
    end

    assert has_element?(view, ~s(#{form} textarea[id="excerpt"][name="doc[excerpt]"]))
    refute has_element?(view, ~s(#{form} [id^="doc-field-"]))
  end

  test "in the desk an image field is a fieldset.field with a legend", c do
    view = desk(c)
    assert has_element?(view, ~s([data-pane-editing] fieldset.editor-field.field > legend))
    refute has_element?(view, ~s([data-pane-editing] fieldset > label))
  end

  test "the desk page has no id twice", c do
    html = c |> desk() |> render()
    dupes = html |> ids() |> Enum.frequencies() |> Enum.filter(fn {_id, n} -> n > 1 end)
    assert dupes == []
  end

  # Control: outside the desk nothing moved (the PR diffs the old Studio's
  # whole form, before and after, byte for byte).
  test "the old Studio keeps doc-field-<doc>-<path> ids and no fieldset", c do
    {:ok, view, _html} = live(c.conn, c.studio)
    form = view |> element("#editor-form") |> render()

    for path <- ~w(title excerpt year done day) do
      assert form =~ ~s(id="doc-field-#{c.id}-#{path}"), "no doc-field id for #{path}"
      assert form =~ ~s(for="doc-field-#{c.id}-#{path}")
    end

    refute form =~ ~r/\sid="(title|excerpt|year|done|day)"/
    refute form =~ "<fieldset"
  end
end
