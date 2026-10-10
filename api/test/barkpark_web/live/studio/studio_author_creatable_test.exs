defmodule BarkparkWeb.Studio.StudioAuthorCreatableTest do
  @moduledoc """
  Form submissions offered "+" and "Nytt dokument" in Studio, and both always
  failed with a bare "Kunne ikke opprette": only the public intake can write a
  submission. A type whose desk block declares `"authorCreatable": false` now
  gets no "New" in Studio. It hides the buttons only; the write path still
  answers a create with its own refusal.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, TenancyFixtures}
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "production"
  @admin "author-creatable-admin"

  test "a desk block with authorCreatable false says the type is not author-creatable" do
    refute PaneBuilder.author_creatable?(%{desk: %{"authorCreatable" => false}})
    assert PaneBuilder.author_creatable?(%{desk: %{}})
    assert PaneBuilder.author_creatable?(%{desk: %{"authorCreatable" => true}})
    assert PaneBuilder.author_creatable?(nil)
  end

  test "Forms declares its submissions not author-creatable" do
    [submission | _] = Barkpark.Plugins.Forms.register_schemas([])
    assert submission.name == "form_submission"
    refute PaneBuilder.author_creatable?(submission)
  end

  describe "the list pane" do
    setup %{conn: conn} do
      TenancyFixtures.ensure_default_scope!()

      {:ok, _} =
        Auth.create_token(
          @admin,
          "author creatable admin",
          @dataset,
          ["read", "write", "admin"],
          TenancyFixtures.default_workspace_id!()
        )

      for {name, desk} <- [{"intake_log", %{"authorCreatable" => false}}, {"field_log", %{}}] do
        {:ok, _} =
          Content.upsert_schema(
            %{
              "name" => name,
              "title" => name,
              "visibility" => "public",
              "desk" => desk,
              "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
            },
            @dataset
          )
      end

      {:ok, conn: Plug.Test.init_test_session(conn, %{"api_token" => @admin})}
    end

    test "offers no New for a type that is not author-creatable", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/intake_log"))
      refute has_element?(view, ~s(button[phx-click="new-document"]))
    end

    test "still offers New for an ordinary type", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/field_log"))
      assert has_element?(view, ~s(.pane-add-btn[phx-click="new-document"]))
      assert has_element?(view, ~s(.btn-primary[phx-click="new-document"]))
    end
  end
end
