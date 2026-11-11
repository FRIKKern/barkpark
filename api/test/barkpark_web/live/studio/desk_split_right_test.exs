defmodule BarkparkWeb.Studio.DeskSplitRightTest do
  @moduledoc """
  J57: Sanity's document header has icon buttons the specs count
  (`.pane-header .icon-btn` with a tip, more than 3). "Split pane right" is
  one the desk can do for real: `Panes.split_right/3` opens the same
  document again beside it. The desk still edits only the last pane.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @split ~s([data-pane-editing] .pane-header a.icon-btn[aria-label="Split pane right"][data-tip])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "split_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Split #{type}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "split-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Twice"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-split-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-split", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: base, type: type, id: id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};#{c.id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  test "the edit pane's header has a Split pane right icon button", c do
    view = open(c)
    assert has_element?(view, @split)

    # J57 counts the header's tipped icon buttons: split, actions, close.
    html = view |> element("[data-pane-editing] > .pane-header") |> render()
    assert length(Regex.scan(~r/class="[^"]*\bicon-btn\b[^"]*"[^>]*data-tip=/s, html)) >= 3
  end

  test "Split pane right opens the same document beside it, and one pane edits", c do
    view = open(c)
    view |> element(@split) |> render_click()
    render_async(view, 5_000)

    assert_patch(view)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)

    # The same document twice: the first pane reads it, the last edits it.
    docs = view |> render() |> then(&Regex.scan(~r/data-pane-kind="doc"/, &1)) |> length()
    assert docs == 2
    assert view |> render() |> then(&Regex.scan(~r/data-pane-editing/, &1)) |> length() == 1
  end
end
