defmodule BarkparkWeb.Studio.DeskLiveUpdatesJ49ReadOnlyTest do
  @moduledoc """
  J49 (barkpark-studio JOURNEYS.md, reference `e2e/journeys/read-only.spec.ts`):
  a read-only role. The desk is workspace-admin-only while it is a slice
  (`shares_admin?` in `DeskLive.mount/3`; campaign rule 1: do not widen it),
  so today a viewer or a non-admin editor never reaches it. This file pins
  that, for a deep link to a document as well as the bare desk, and pins that
  the first (dead) render already leaves without drawing the document.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_readonly_note"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk read-only notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "dro-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{
          "doc_id" => id,
          "title" => "Read-only note",
          "content" => %{"summary" => "Only an admin's desk shows this"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    studio = String.replace_suffix(base, "/_desk", "")

    {:ok, conn: conn, base: base, studio: studio, url: "#{base}/#{@type_name};#{id}"}
  end

  defp sign_in(conn, permissions) do
    raw = "desk-readonly-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-readonly", @dataset, permissions, ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  for {who, permissions} <- [
        {"a viewer", ~w(read)},
        {"an editor who is not an admin", ~w(read write)}
      ] do
    @permissions permissions

    test "#{who}'s deep link to a document lands on the Studio root", %{
      conn: conn,
      url: url,
      studio: studio
    } do
      assert {:error, {:live_redirect, %{to: ^studio}}} = live(sign_in(conn, @permissions), url)
    end

    test "#{who}'s first render sends them on without drawing the document", %{
      conn: conn,
      url: url,
      studio: studio
    } do
      conn = get(sign_in(conn, @permissions), url)

      assert redirected_to(conn, 302) == studio
      refute conn.resp_body =~ "Only an admin's desk shows this"
      refute conn.resp_body =~ "Read-only note"
    end
  end

  test "control: a workspace admin's deep link draws the document in the desk", %{
    conn: conn,
    url: url
  } do
    {:ok, view, _html} = live(sign_in(conn, ~w(read write admin)), url)
    render_async(view, 5_000)

    assert has_element?(view, ~s([data-pane-index="2"][data-pane-editing] #editor-form))
  end
end
