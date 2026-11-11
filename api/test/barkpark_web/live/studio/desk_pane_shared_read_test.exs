defmodule BarkparkWeb.Studio.DeskPaneSharedReadTest do
  @moduledoc """
  Split siblings of one document share one read: the first pane reads, the
  panes after it show what it read. None of them may be left behind when that
  read fails first, or when the first pane was drawn on hold for the editor.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.LiveRefresh
  alias BarkparkWeb.Studio.Desk.PaneComponent

  @dataset "production"
  @type_name "desk_shared_read_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Shared notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    a = "dsr-a-#{System.unique_integer([:positive])}"

    {:ok, _doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => a, "title" => "Alpha note", "content" => %{"summary" => "About Alpha"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-shared-read-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-shared-read", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, a: a}
  end

  test "after Retry on the first pane of a split, the panes that follow it show the document too",
       %{conn: conn, base: base, a: a} do
    # No automatic second read: Retry is the only way back.
    Application.put_env(:barkpark, LiveRefresh, retry_waits_ms: [])
    on_exit(fn -> Application.delete_env(:barkpark, LiveRefresh) end)

    Application.put_env(:barkpark, PaneComponent,
      reader: fn
        %{kind: :doc}, _node, _dataset, _scope, _title -> raise "the document read failed"
        pane, node, dataset, scope, title -> PaneComponent.read(pane, node, dataset, scope, title)
      end
    )

    on_exit(fn -> Application.delete_env(:barkpark, PaneComponent) end)

    # Panes 2 and 3 show the document read-only; pane 4, the last, is the editor.
    {:ok, view, _html} = live(conn, "#{base}/#{@type_name};#{a}|,view=json|,view=json")
    render_async(view, 5_000)
    assert has_element?(view, ~s([data-pane-index="2"] [role="alert"]))
    assert has_element?(view, ~s([data-pane-index="3"] [role="alert"]))

    # One more split: pane 4 is read-only now, and asks the failed pane too.
    split = "#{base}/#{@type_name};#{a}|,view=json|,view=json|,view=json"
    render_patch(view, split)
    render_async(view, 5_000)
    assert has_element?(view, ~s([data-pane-index="4"] [role="alert"]))

    # The fault is gone; Retry on the pane that read.
    Application.delete_env(:barkpark, PaneComponent)
    view |> element(~s([data-pane-index="2"] button[phx-click="retry"])) |> render_click()
    render_async(view, 5_000)

    for index <- 2..4 do
      assert has_element?(view, ~s([data-pane-index="#{index}"] dd), "About Alpha")
      refute has_element?(view, ~s([data-pane-index="#{index}"] [role="alert"]))
    end
  end
end
