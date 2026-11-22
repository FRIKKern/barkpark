defmodule BarkparkWeb.Studio.DeskDocUndoRemoteSelectTest do
  @moduledoc """
  task-165052f4fad43c1e (review-27770): editor A undoes their pick of a
  select on the desk, then editor B saves the same select. A's page is told
  B's value (`bp:form-remote-values`) from the value A's page shows, the one
  the undo put back, and draws it, with no action of A's in between.
  bp-array-focus.js sets a field from that push only while it still shows the
  value the push says it showed.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "undo_remote_#{n}"
    doc_id = "undo-remote-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Undo remote",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "choice",
              "title" => "Choice",
              "type" => "select",
              "options" => [
                %{"value" => "a", "title" => "Alpha"},
                %{"value" => "b", "title" => "Beta"},
                %{"value" => "c", "title" => "Gamma"}
              ]
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => "drafts." <> doc_id,
          "title" => "Undo remote probe",
          "content" => %{"choice" => "b"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "undo-remote-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "undo-remote", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, desk: "#{base}/_desk/#{type};#{doc_id}", type: type, doc_id: doc_id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    render(view)
    view
  end

  defp mark(c), do: %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.doc_id)}

  # A post of the select, as the page's: the form's title too.
  defp pick(view, c, value) do
    view
    |> element("#editor-form")
    |> render_change(
      Map.merge(mark(c), %{
        "_target" => ["doc", "choice"],
        "doc" => %{"title" => "Undo remote probe", "choice" => value}
      })
    )
  end

  defp undo(view, c) do
    render_hook(view, "desk-undo", Map.put(mark(c), "redo", false))
    render(view)
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    (doc.content || %{})["choice"]
  end

  defp selected(view) do
    html = view |> element(~s(#editor-form select[name="doc[choice]"])) |> render()

    case Regex.run(
           ~r/<option[^>]*\bselected\b[^>]*value="([^"]*)"|<option[^>]*value="([^"]*)"[^>]*\bselected\b/,
           html
         ) do
      [_, v] -> v
      [_, "", v] -> v
      _ -> nil
    end
  end

  test "after A's undo of a select, B's later save of it is drawn on A's page and told from the undone value",
       c do
    a = open(c)
    b = open(c)

    pick(a, c, "c")
    assert stored(c) == "c"

    undo(a, c)
    assert stored(c) == "b"
    assert_push_event(a, "desk:undone", %{field: "doc[choice]", value: "b", was: "c"})

    pick(b, c, "a")
    assert stored(c) == "a"

    render(a)
    assert selected(a) == "a", "A's page draws B's value"

    assert_push_event(a, "bp:form-remote-values", %{values: %{"doc[choice]" => told}})
    assert told == %{value: "a", was: "b"}, "told from the value A's page shows"
  end
end
