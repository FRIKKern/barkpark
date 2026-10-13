defmodule BarkparkWeb.Studio.StudioPaperLabelsRegistryTest do
  @moduledoc """
  task-3a5b9cda74564d1c (ruling: option b + copy). A paper publishes only with
  a registered label, and a workspace with none had no way in from Studio.

    * The Labels editor suggests the registered labels (a `<datalist>`).
    * A workspace admin registers a new label inline; a member cannot, and is
      told to ask an admin.
    * The publish refusal speaks the sidebar's word, "label", and says what to
      do; it never shows `{tag, strength, rationale}`.

  Seeding a starter vocabulary (a) and relaxing the minimum (c) stay with the
  owner question task-8edd8e147c648a36.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, TenancyFixtures}
  alias Barkpark.Content.TagRegistry

  @dataset "production"
  @admin "labels-admin"
  @member "labels-member"

  setup %{conn: conn} do
    {_ws, _proj} = TenancyFixtures.ensure_default_scope!()
    ws_id = TenancyFixtures.default_workspace_id!()

    {:ok, _} =
      Auth.create_token(@admin, "labels admin", @dataset, ["read", "write", "admin"], ws_id)

    {:ok, _} = Auth.create_token(@member, "labels member", @dataset, ["read", "write"], ws_id)
    TagRegistry.register!(@dataset)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, conn: conn}
  end

  defp draft_paper!(slug) do
    {:ok, _} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => slug,
          "title" => "Untitled",
          "content" => %{
            "description" => "A paper walking the label registry from Studio.",
            "blocks" => [
              %{
                "id" => "b0",
                "type" => "heading",
                "level" => 1,
                "content" => [%{"type" => "text", "value" => "A Title"}]
              },
              %{
                "id" => "b1",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Real prose."}]
              }
            ]
          }
        },
        @dataset
      )
  end

  defp register_tag!(name) do
    {:ok, _} = Content.create_document("tag", %{"doc_id" => name, "title" => name}, @dataset)
    {:ok, _} = Content.publish_document(name, "tag", @dataset)
  end

  defp open_as(conn, token, slug) do
    {:ok, view, html} =
      conn
      |> Plug.Test.init_test_session(%{"api_token" => token})
      |> live(scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))

    {view, html}
  end

  defp add_label(view, tag) do
    view
    |> element(~s(form[data-test-id="sidebar-label-add"]))
    |> render_submit(%{
      "tag" => tag,
      "strength" => "70",
      "rationale" => "This label names the subject well."
    })
  end

  defp publish(view),
    do: view |> element(~s(button[data-test-id="paper-publish"])) |> render_click()

  defp flash(view, kind), do: :sys.get_state(view.pid).socket.assigns.flash[kind]

  defp tags_of(slug),
    do: elem(Content.get_document("drafts." <> slug, "paper", @dataset), 1).content["tags"] || []

  test "the publish refusal for a paper with no label speaks the Labels section's words", %{
    conn: conn
  } do
    draft_paper!("labels-none")
    {view, _} = open_as(conn, @member, "labels-none")
    publish(view)
    msg = flash(view, "error")
    assert msg =~ "Publish blocked:"
    assert msg =~ "label"
    assert msg =~ "Labels section"
    refute msg =~ "{tag, strength, rationale}"
    refute msg =~ "`tags`"
  end

  test "an admin registers a new label inline, uses it, and publishes", %{conn: conn} do
    draft_paper!("labels-admin-walk")
    {view, _html} = open_as(conn, @admin, "labels-admin-walk")
    assert render(view) =~ "to register it"
    refute TagRegistry.registered?("field-notes", @dataset)

    add_label(view, "field-notes")
    assert TagRegistry.registered?("field-notes", @dataset), "the admin's add registers the label"
    assert [%{"tag" => "field-notes"}] = tags_of("labels-admin-walk")
    assert has_element?(view, ~s(#bp-label-suggestions option[value="field-notes"]))

    publish(view)
    assert flash(view, "info") =~ "Published", "error: #{inspect(flash(view, "error"))}"

    assert {:ok, %{status: "published"}} =
             Content.get_document("labels-admin-walk", "paper", @dataset)
  end

  test "a member sees the registered labels and publishes with one", %{conn: conn} do
    register_tag!("how-to")
    draft_paper!("labels-member-walk")
    {view, _html} = open_as(conn, @member, "labels-member-walk")

    assert has_element?(view, ~s(#bp-label-suggestions option[value="how-to"]))
    assert render(view) =~ "Ask an admin to add a label"

    add_label(view, "how-to")
    assert [%{"tag" => "how-to"}] = tags_of("labels-member-walk")

    publish(view)
    assert flash(view, "info") =~ "Published", "error: #{inspect(flash(view, "error"))}"
  end

  test "a member cannot register a label, and is told to ask an admin", %{conn: conn} do
    draft_paper!("labels-member-new")
    {view, _} = open_as(conn, @member, "labels-member-new")

    add_label(view, "brand-new")
    refute TagRegistry.registered?("brand-new", @dataset)
    assert tags_of("labels-member-new") == []
    assert flash(view, "error") =~ "ask an admin"
  end
end
