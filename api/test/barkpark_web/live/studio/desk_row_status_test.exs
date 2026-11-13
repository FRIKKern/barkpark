defmodule BarkparkWeb.Studio.DeskRowStatusTest do
  @moduledoc """
  A desk list row's tile and status marks, as the TanStack Studio's preview
  (LOOKS A2, 2026-11-13): the type's icon in a tile at the left, and at the
  right a ring for a draft, a dot for published, and both for a published
  document with unpublished edits (`Preview.tsx` `RowStatus`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "dsr_post"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Status posts",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    create = fn id, title ->
      {:ok, _} =
        Content.create_document(@type_name, %{"doc_id" => id, "title" => title}, @dataset)
    end

    # Only a draft; only published; published with a draft over it.
    create.("dsr-draft", "Only draft")
    create.("dsr-pub", "Only published")
    {:ok, _} = Content.publish_document("dsr-pub", @type_name, @dataset)
    create.("dsr-both", "Both")
    {:ok, _} = Content.publish_document("dsr-both", @type_name, @dataset)

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => "dsr-both", "title" => "Both, edited"},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "dsr-token-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "dsr",
        @dataset,
        ["read", "write", "admin"],
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"}
  end

  defp row(view, title) do
    view
    |> element(~s([data-pane-index="1"] a[data-desk-row]), title)
    |> render()
  end

  test "a row's tile is the type's icon; its marks say draft, published or both", %{
    conn: conn,
    base: base
  } do
    {:ok, view, _html} = live(conn, "#{base}/#{@type_name}")
    render_async(view, 5_000)

    draft = row(view, "Only draft")
    assert draft =~ ~s(class="dk-media")
    assert draft =~ "dk-ring"
    refute draft =~ "dk-dot"

    published = row(view, "Only published")
    assert published =~ "dk-dot"
    refute published =~ "dk-ring"

    both = row(view, "Both, edited")
    assert both =~ "dk-ring"
    assert both =~ "dk-dot"
    # The ring first, then the dot, as TanStack's.
    assert both =~ ~r/dk-ring.*dk-dot/s
  end
end
