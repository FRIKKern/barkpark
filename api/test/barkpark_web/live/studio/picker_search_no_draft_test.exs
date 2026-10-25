defmodule BarkparkWeb.Studio.PickerSearchNoDraftTest do
  @moduledoc """
  task-32d983d47299e137: on the gyldendal.no twin, typing "Åpent hus" into the
  Hovedarrangement picker search of a published event wrote a draft and eight
  draft updates, one per keystroke, though nothing was picked.

  The browser posted the whole editor form for each keystroke. The posts had
  three things the stored document does not, and each made the no-change check
  in `Shared.do_autosave/3` answer "changed":

    * `_target` "undefined", LiveView's name for an input with no name (the
      picker's search box);
    * an `_unused_<name>` key beside every untouched input;
    * the bare id of a reference the store keeps as `{_ref, _type, _weak}`.

  The payloads here are the ones the browser sent, captured from a local copy of
  the twin's event.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.DraftId

  @dataset "production"
  @type_name "pickerEvent"
  @parent "parent-event-1"

  @seed_content %{
    "location" => "Gyldendalhuset",
    "parentEvent" => %{"_ref" => @parent, "_type" => "reference", "_weak" => true}
  }

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Arrangement",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "location", "title" => "Sted", "type" => "string"},
            %{"name" => "price", "title" => "Pris", "type" => "string"},
            %{
              "name" => "parentEvent",
              "title" => "Hovedarrangement",
              "type" => "reference",
              "to" => [%{"type" => @type_name}]
            }
          ]
        },
        @dataset
      )

    :ok
  end

  defp seed_published!(doc_id) do
    {:ok, _} =
      Content.upsert_document(
        @type_name,
        %{
          "doc_id" => DraftId.draft_id(doc_id),
          "title" => "Boksignering med Emma",
          "content" => @seed_content
        },
        @dataset,
        source: :api
      )

    {:ok, _} = Content.publish_document(doc_id, @type_name, @dataset, source: :api)
    assert draft_row(doc_id) == :no_draft
    :ok
  end

  defp draft_row(doc_id) do
    case Content.get_document(DraftId.draft_id(doc_id), @type_name, @dataset) do
      {:ok, doc} -> doc
      _ -> :no_draft
    end
  end

  defp open!(doc_id) do
    raw = "picker-search-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(
        raw,
        "picker-search",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    conn = build_conn() |> Plug.Test.init_test_session(%{"api_token" => raw})

    {:ok, view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/#{@type_name}/#{doc_id}"))

    # The picker is on the page, holding the stored reference's id.
    assert html =~ "bp-reference-picker"
    assert html =~ ~s(name="doc[parentEvent]" value="#{@parent}")
    view
  end

  # The form a browser posts for the untouched editor: every input's value, the
  # reference as its bare id, and an `_unused_` key beside each untouched input.
  defp browser_form(overrides \\ %{}) do
    values =
      Map.merge(
        %{
          "title" => "Boksignering med Emma",
          "location" => "Gyldendalhuset",
          "price" => "",
          "parentEvent" => @parent
        },
        overrides
      )

    unused = for {k, _} <- values, into: %{}, do: {"_unused_" <> k, ""}
    Map.merge(unused, values)
  end

  test "typing in a reference picker search writes no draft" do
    doc_id = "picker-search-#{System.unique_integer([:positive])}"
    seed_published!(doc_id)
    view = open!(doc_id)

    # One post per keystroke of "Åpent hus", as the browser sends them.
    for _ <- String.graphemes("Åpent hus") do
      render_change(view, "autosave", %{"_target" => ["undefined"], "doc" => browser_form()})
    end

    assert draft_row(doc_id) == :no_draft,
           "typing in the picker search created a draft of the published document"
  end

  test "a post that changes no value writes no draft, even with _unused_ keys and a weak reference" do
    doc_id = "picker-unchanged-#{System.unique_integer([:positive])}"
    seed_published!(doc_id)
    view = open!(doc_id)

    render_change(view, "autosave", %{"_target" => ["doc", "price"], "doc" => browser_form()})

    assert draft_row(doc_id) == :no_draft
  end

  test "a real edit still writes the draft and keeps the reference" do
    doc_id = "picker-edit-#{System.unique_integer([:positive])}"
    seed_published!(doc_id)
    view = open!(doc_id)

    form = browser_form(%{"location" => "Litteraturhuset"}) |> Map.delete("_unused_location")
    render_change(view, "autosave", %{"_target" => ["doc", "location"], "doc" => form})

    doc = draft_row(doc_id)
    refute doc == :no_draft
    assert doc.content["location"] == "Litteraturhuset"
    assert %{"_ref" => @parent} = doc.content["parentEvent"]
  end

  test "picking another document still writes the draft" do
    doc_id = "picker-pick-#{System.unique_integer([:positive])}"
    seed_published!(doc_id)
    view = open!(doc_id)

    form = browser_form(%{"parentEvent" => "parent-event-2"}) |> Map.delete("_unused_parentEvent")
    render_change(view, "autosave", %{"_target" => ["doc", "parentEvent"], "doc" => form})

    doc = draft_row(doc_id)
    refute doc == :no_draft
    assert %{"_ref" => "parent-event-2"} = doc.content["parentEvent"]
  end
end
