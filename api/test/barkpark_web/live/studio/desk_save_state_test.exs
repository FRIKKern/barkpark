defmodule BarkparkWeb.Studio.DeskSaveStateTest do
  @moduledoc """
  B11 (unload-guard:35, :113): the edit pane carries the editor's save token
  as `data-desk-save`, which `bp-desk.js` reads to ask before the tab closes
  over a failed save (`__desk_slice_unload.test.mjs`). The token, not its
  words, so the check reads the same in every Studio language.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @pane "section[data-pane-editing]"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "save_state_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Save state #{n}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "save-state-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Here"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-save-state-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-save-state", @dataset, ~w(read write admin), ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, view, _html} = live(conn, "#{base}/#{type};#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    {:ok, view: view}
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  test "the edit pane carries the save token: none yet, then the save's", %{view: view} do
    assert has_element?(view, ~s(#{@pane}[data-desk-save=""]))

    render_hook(view, "autosave", %{"doc" => %{"title" => "Here, typed"}})
    assert eventually(fn -> has_element?(view, ~s(#{@pane}[data-desk-save="Saved"])) end)
  end
end
