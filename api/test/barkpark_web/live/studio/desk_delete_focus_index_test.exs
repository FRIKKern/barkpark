defmodule BarkparkWeb.Studio.DeskDeleteFocusIndexTest do
  @moduledoc """
  task-3904bae587276669: after a desk delete the page is told where the
  document sat in its list (`bp:focus-after-delete`), so the desk's script
  can focus the row that takes its place when it never saw the row drawn
  (#28243, `bp-desk.js` `_focusAfterDelete`). `Handlers.Delete` read the
  old Studio's `:items` panes, which the desk has not got, and always sent
  index 0. The desk list holds its own rows (`PaneComponent`); the index
  comes from them.

  The index only steers the focus. The delete is of the open document
  (`editor_doc`), whatever the index says.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @pane "[data-pane-editing]"
  @delete ~s(#{@pane} [role="dialog"][aria-modal="true"][data-desk-dialog="delete"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "del_index_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Delete index",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    ids =
      for i <- 1..4 do
        id = "del-index-#{n}-#{i}"

        {:ok, _} =
          Content.create_document(type, %{"doc_id" => id, "title" => "Row #{i}"}, @dataset)

        id
      end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-delete-index-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-delete-index", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     type: type,
     ids: ids}
  end

  defp poll(view, fun, tries \\ 50) do
    render_async(view, 5_000)

    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(view, fun, tries - 1)
    end
  end

  # The list's document rows as drawn, in order: the ids their links open.
  defp drawn_rows(view, type) do
    html = view |> element(~s([data-pane-index="1"])) |> render()

    for [_, href] <- Regex.scan(~r/<a href="([^"]+)"[^>]*data-desk-row/, html),
        id = href |> URI.decode() |> String.split(";") |> List.last() |> String.split(",") |> hd(),
        String.starts_with?(id, "del-index-"),
        do: {type, id}
  end

  # The draft or the published row: a fixture made by `create_document/3`
  # is a draft.
  defp exists?(c, id) do
    published = Content.published_id(id)

    Enum.any?(
      [published, "drafts." <> published],
      &match?({:ok, _}, Content.get_document(&1, c.type, @dataset))
    )
  end

  test "a desk delete of the third row says the row sat at index 2", c do
    {:ok, list, _} = live(c.conn, "#{c.base}/#{c.type}")
    assert poll(list, fn -> length(drawn_rows(list, c.type)) == 4 end)
    rows = for {_type, id} <- drawn_rows(list, c.type), do: id
    third = Enum.at(rows, 2)

    {:ok, view, _} = live(c.conn, "#{c.base}/#{c.type};#{third}")
    assert poll(view, fn -> has_element?(view, "#{@pane} #editor-form") end)
    assert poll(view, fn -> length(drawn_rows(view, c.type)) == 4 end)
    assert for({_t, id} <- drawn_rows(view, c.type), do: id) == rows

    BarkparkWeb.EditorPost.press(view, "delete-doc", %{})

    BarkparkWeb.EditorPost.press_on(
      view,
      element(view, ~s(#{@delete} button.danger), "Delete document")
    )

    assert_push_event(view, "bp:focus-after-delete", %{id: ^third, index: index})
    assert index == 2

    refute exists?(c, third)
    assert Enum.all?(rows -- [third], &exists?(c, &1))
  end

  test "the first row says index 0", c do
    {:ok, list, _} = live(c.conn, "#{c.base}/#{c.type}")
    assert poll(list, fn -> length(drawn_rows(list, c.type)) == 4 end)
    [first | rest] = for {_type, id} <- drawn_rows(list, c.type), do: id

    {:ok, view, _} = live(c.conn, "#{c.base}/#{c.type};#{first}")
    assert poll(view, fn -> has_element?(view, "#{@pane} #editor-form") end)
    assert poll(view, fn -> length(drawn_rows(view, c.type)) == 4 end)

    BarkparkWeb.EditorPost.press(view, "delete-doc", %{})

    BarkparkWeb.EditorPost.press_on(
      view,
      element(view, ~s(#{@delete} button.danger), "Delete document")
    )

    assert_push_event(view, "bp:focus-after-delete", %{id: ^first, index: 0})
    refute exists?(c, first)
    assert Enum.all?(rest, &exists?(c, &1))
  end

  # The index steers only the focus: a hand-sent confirm naming another row
  # and another index still deletes the open document, and only it.
  test "a hand-sent confirm-delete naming another row deletes only the open one", c do
    [id | _] = c.ids
    {:ok, view, _} = live(c.conn, "#{c.base}/#{c.type};#{id}")
    assert poll(view, fn -> has_element?(view, "#{@pane} #editor-form") end)
    assert poll(view, fn -> length(drawn_rows(view, c.type)) == 4 end)

    other = List.last(c.ids)

    BarkparkWeb.EditorPost.press(view, "confirm-delete", %{"id" => other, "index" => "3"})
    assert_push_event(view, "bp:focus-after-delete", %{id: ^id})
    refute exists?(c, id)
    assert exists?(c, other)
  end
end
