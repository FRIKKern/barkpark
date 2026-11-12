defmodule BarkparkWeb.Studio.DeskCodelistCurrentTest do
  @moduledoc """
  B05 (codelist.spec:6, native-fields:11): in the desk a tree codelist shows
  its current code above the search, as the TanStack Studio's
  `.codelist-tree-field .codelist-current` does: the code and its label path
  (`Fiction › Modern fiction`). Before, the tree marked the code only on its
  own row, which a collapsed branch or a search hid. The old Studio is
  unchanged.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy

  @dataset "production"
  @plugin "onixedit"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list_id = "#{@plugin}:desk-current-#{n}"
    type = "cl_#{n}"

    # Over the tree threshold (100 raw values): the TreeCodelistField variant.
    fillers =
      for i <- 1..105,
          do: %{code: "FBZ#{i}", translations: [%{language: "eng", label: "Filler #{i}"}]}

    {:ok, _} =
      Codelists.register(@plugin, list_id, %{
        issue: "1",
        name: "Desk current",
        values: [
          %{
            code: "FB",
            translations: [%{language: "eng", label: "Fiction"}],
            children: [
              %{code: "FBA", translations: [%{language: "eng", label: "Modern fiction"}]}
              | fillers
            ]
          }
        ]
      })

    field = %{
      "name" => "subject",
      "title" => "Subject",
      "type" => "codelist",
      "codelistId" => list_id
    }

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Codelist #{type}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}, field]
        },
        @dataset
      )

    for {id, subject} <- [{"cl-#{n}", "FBA"}, {"cl-none-#{n}", nil}, {"cl-gone-#{n}", "ZZZ"}] do
      content = if subject, do: %{"subject" => subject}, else: %{}

      {:ok, _} =
        Content.create_document(
          type,
          Map.merge(%{"doc_id" => id, "title" => id}, content),
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-codelist-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-codelist", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, root: root, type: type, n: n}
  end

  @form "[data-pane-editing] #editor-form"

  defp desk(c, id) do
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  test "the desk's tree codelist shows its current code and label path", c do
    view = desk(c, "cl-#{c.n}")
    current = ~s(#{@form} .codelist-tree-field .codelist-current)
    assert has_element?(view, current, "FBA")
    assert has_element?(view, current, "Fiction › Modern fiction")
  end

  test "no code, no current-code line; a code not in the list shows the code alone", c do
    view = desk(c, "cl-none-#{c.n}")
    assert has_element?(view, ~s(#{@form} .codelist-tree-field))
    refute has_element?(view, ~s(#{@form} .codelist-current))

    view = desk(c, "cl-gone-#{c.n}")
    assert has_element?(view, ~s(#{@form} .codelist-current[data-unknown]), "ZZZ")
  end

  test "the old Studio's tree codelist has neither mark", c do
    {:ok, view, _html} = live(c.conn, "#{c.root}/#{c.type}/cl-#{c.n}")
    html = render(view)
    assert html =~ "bp-tree-codelist"
    refute html =~ "codelist-tree-field"
    refute html =~ "codelist-current"
  end
end
