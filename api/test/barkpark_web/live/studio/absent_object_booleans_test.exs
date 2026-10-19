defmodule BarkparkWeb.Studio.AbsentObjectBooleansTest do
  @moduledoc """
  task-d89926b8afd3dcb9: a Studio edit of one field wrote `false` for every
  boolean of a named object field the stored document did not have. The
  schema default of each boolean was `true`, so publishing that draft would
  have turned the three switches off.

  The fixture is synthetic. A named object type `shareToggles` holds a
  composite `channels` of three booleans that default to `true`. A published
  `note` has no `share` field. The editor opens it, edits `probe` only, and
  the draft must not gain `share`. The switches show their default while the
  field is absent. A switch the editor turns off is the only value written.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.DraftId

  @dataset "production"

  setup do
    suffix = System.unique_integer([:positive])
    object_type = "shareToggles#{suffix}"
    type = "note#{suffix}"
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => object_type,
          "kind" => "object",
          "title" => "Share toggles",
          "fields" => [
            %{
              "name" => "channels",
              "title" => "Channels",
              "type" => "composite",
              "fields" => [
                %{"name" => "alpha", "title" => "Alpha", "type" => "boolean", "default" => true},
                %{"name" => "beta", "title" => "Beta", "type" => "boolean", "default" => true},
                %{"name" => "gamma", "title" => "Gamma", "type" => "boolean", "default" => true}
              ]
            }
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Note",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "probe", "title" => "Probe", "type" => "string"},
            %{"name" => "share", "title" => "Share", "type" => object_type},
            %{"name" => "pinned", "title" => "Pinned", "type" => "boolean", "default" => true}
          ]
        },
        @dataset,
        scope
      )

    doc_id = "note-#{suffix}"

    {:ok, _} =
      Content.upsert_document(
        type,
        %{"doc_id" => doc_id, "title" => "Note", "content" => %{"probe" => "before"}},
        @dataset,
        source: :api
      )

    {:ok, _} = Content.publish_document(doc_id, type, @dataset)

    raw = "absent-booleans-#{suffix}"

    {:ok, _} =
      Barkpark.Auth.create_token(
        raw,
        "absent-booleans",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    %{type: type, doc_id: doc_id, token: raw}
  end

  defp open!(token, type, doc_id) do
    conn = scoped_conn() |> Plug.Test.init_test_session(%{"api_token" => token})
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/#{type}/#{doc_id}"))
    {view, html}
  end

  defp draft_content(type, doc_id) do
    {:ok, doc} = Content.get_document(DraftId.draft_id(doc_id), type, @dataset)
    doc.content
  end

  defp checked?(html, name) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(input[type="checkbox"][name="#{name}"]))
    |> Enum.any?(fn el -> LazyHTML.attribute(el, "checked") != [] end)
  end

  defp checkbox_names(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(#editor-form input[type="checkbox"]))
    |> Enum.flat_map(&LazyHTML.attribute(&1, "name"))
  end

  test "an absent boolean shows its declared default", %{type: type, doc_id: doc_id, token: t} do
    {_view, html} = open!(t, type, doc_id)
    names = checkbox_names(html)

    channel_names = Enum.filter(names, &String.contains?(&1, "channels"))
    assert length(channel_names) == 3, "expected three channel switches, got #{inspect(names)}"
    assert Enum.all?(channel_names, &checked?(html, &1))
    assert checked?(html, "doc[pinned]")
  end

  test "editing another field leaves an absent object of booleans absent",
       %{type: type, doc_id: doc_id, token: t} do
    {view, _html} = open!(t, type, doc_id)

    view |> form("#editor-form") |> render_change(%{"doc" => %{"probe" => "after"}})

    content = draft_content(type, doc_id)
    assert content["probe"] == "after"
    refute Map.has_key?(content, "share")
    refute Map.has_key?(content, "pinned")
  end

  test "a switch the editor turns off is the only value written",
       %{type: type, doc_id: doc_id, token: t} do
    {view, html} = open!(t, type, doc_id)
    alpha = Enum.find(checkbox_names(html), &String.ends_with?(&1, "alpha"))
    assert alpha

    view
    |> form("#editor-form")
    |> render_change(%{alpha => "false", "doc" => %{"probe" => "after", "pinned" => "false"}})

    content = draft_content(type, doc_id)
    assert content["share"] == %{"channels" => %{"alpha" => false}}
    assert content["pinned"] === false
  end
end
