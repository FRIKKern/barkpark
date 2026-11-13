defmodule BarkparkWeb.Studio.DeskAllFieldsTabTest do
  @moduledoc """
  LOOKS PR 5a: the desk's group tabs as the TanStack Studio (and Sanity)
  draw them: All fields first, then one per group. A document opens on the
  group marked `default: true`, else on All fields, which shows every field,
  grouped or not. The old Studio keeps its tabs and opens on the first group.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @pane "[data-pane-editing]"
  @all "#{@pane} #bp-group-tab-all-fields"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-all-fields-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-all-fields", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, n: n, scope: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"}
  end

  # Content: title, body. Meta: slug. No group: note.
  defp doc!(c, meta_default? \\ false) do
    type = "allf_#{c.n}_#{if meta_default?, do: "m", else: "a"}"

    meta =
      if meta_default?,
        do: %{"name" => "meta", "title" => "Meta", "default" => true},
        else: %{"name" => "meta", "title" => "Meta"}

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "All fields #{c.n}",
          "visibility" => "public",
          "groups" => [%{"name" => "content", "title" => "Content"}, meta],
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string", "group" => "content"},
            %{"name" => "body", "title" => "Body", "type" => "text", "group" => "content"},
            %{"name" => "slug", "title" => "Slug", "type" => "string", "group" => "meta"},
            %{"name" => "note", "title" => "Note", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "allf-#{c.n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Grouped"}, @dataset)
    {type, id}
  end

  defp open(c, path) do
    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp tabs(view) do
    view
    |> element("#{@pane} .bp-tab-bar")
    |> render()
    |> then(&Regex.scan(~r/<span class="bp-tab-label">([^<]*)<\/span>/, &1))
    |> Enum.map(fn [_, t] -> String.trim(t) end)
  end

  defp shown(view) do
    for f <- ~w(title body slug note),
        has_element?(view, ~s(#{@pane} #editor-form [name="doc[#{f}]"])),
        do: f
  end

  test "the desk opens on All fields, first of the tabs, and shows every field", c do
    {type, id} = doc!(c)
    view = open(c, "#{c.scope}/_desk/#{type};#{id}")

    assert tabs(view) == ["All fields", "Content", "Meta"]
    assert has_element?(view, ~s(#{@all}[aria-selected="true"][tabindex="0"].is-active))
    assert has_element?(view, ~s(#{@pane} #bp-group-tab-content[tabindex="-1"]))

    assert has_element?(
             view,
             ~s(#{@pane} [role=tabpanel][aria-labelledby="bp-group-tab-all-fields"])
           )

    assert shown(view) == ~w(title body slug note)
  end

  test "a group, then All fields again; a save keeps All fields", c do
    {type, id} = doc!(c)
    view = open(c, "#{c.scope}/_desk/#{type};#{id}")

    view |> element("#{@pane} #bp-group-tab-meta") |> render_click()
    assert shown(view) == ~w(slug)
    assert has_element?(view, ~s(#{@all}[aria-selected="false"]))

    view |> element(@all) |> render_click()
    assert shown(view) == ~w(title body slug note)

    view |> element("#{@pane} #editor-form") |> render_change(%{"doc" => %{"note" => "kept"}})
    render_async(view, 5_000)

    assert eventually(fn ->
             match?(
               {:ok, %{content: %{"note" => "kept"}}},
               Content.get_document("drafts." <> id, type, @dataset)
             )
           end)

    assert has_element?(view, ~s(#{@all}[aria-selected="true"]))
    assert shown(view) == ~w(title body slug note)
  end

  test "a group marked default: true is the one the desk opens on", c do
    {type, id} = doc!(c, true)
    view = open(c, "#{c.scope}/_desk/#{type};#{id}")

    assert has_element?(view, ~s(#{@pane} #bp-group-tab-meta[aria-selected="true"]))
    assert has_element?(view, ~s(#{@all}[aria-selected="false"][tabindex="-1"]))
    assert shown(view) == ~w(slug)
  end

  # Control: the old Studio has no All fields tab and opens on the first group.
  test "the old Studio keeps its tabs and opens on the first group", c do
    {type, id} = doc!(c)
    {:ok, view, _html} = live(c.conn, "#{c.scope}/#{type}/#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)

    refute has_element?(view, "#bp-group-tab-all-fields")
    assert has_element?(view, ~s(#bp-group-tab-content[aria-selected="true"]))
    refute has_element?(view, ~s(#editor-form [name="doc[slug]"]))
  end
end
