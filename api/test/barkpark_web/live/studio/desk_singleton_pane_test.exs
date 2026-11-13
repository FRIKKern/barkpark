defmodule BarkparkWeb.Studio.DeskSingletonPaneTest do
  @moduledoc """
  singleton.spec:64 (B13): a document the desk opens from a document node of
  its own (an `S.document()` child, which is what a singleton is) shows the
  form only, as Sanity's: no view tabs, so no "Split pane right", and no type
  line ("<Type> · N fields") over the title (the document's id is its type).
  A document opened from a list keeps all three.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @pane "[data-pane-editing]"
  @views %{
    "views" => [
      %{"id" => "linked", "title" => "Linked", "type" => "dsp_post", "by" => "content.x"}
    ]
  }

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    single = "dsp_prefs_#{n}"
    post = "dsp_post"

    for {name, extra} <- [{single, %{"singleton" => true}}, {post, %{}}] do
      {:ok, _} =
        Content.upsert_schema(
          Map.merge(
            %{
              "name" => name,
              "title" => "Title of #{name}",
              "visibility" => "public",
              "desk" => @views,
              "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
            },
            extra
          ),
          @dataset
        )
    end

    {:ok, _} =
      Content.create_document(single, %{"doc_id" => single, "title" => "The shop"}, @dataset)

    {:ok, _} =
      Content.create_document(post, %{"doc_id" => "dsp-post-#{n}", "title" => "A post"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "dsp-token-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "dsp", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     single: single,
     post: "#{post};dsp-post-#{n}",
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"}
  end

  defp editor(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)

    assert Enum.any?(1..200, fn _ ->
             has_element?(view, "#{@pane} #editor-form") or (Process.sleep(10) && false)
           end)

    view
  end

  test "a singleton's pane: the form only, no view tabs, no Split, no type line", ctx do
    view = editor(ctx.conn, "#{ctx.base}/#{ctx.single}")

    assert has_element?(view, "#{@pane}[data-desk-document]")
    refute has_element?(view, "#{@pane} [role=tab]")
    refute has_element?(view, ~s(#{@pane} [aria-label="Split pane right"]))
    # TanStack's singleton: the title over the form, no type line above it.
    assert has_element?(view, "#{@pane} .dk-big-title")
    assert render(view) =~ ".dk .dk-edit[data-desk-document] .dk-kind { display: none; }"
  end

  test "control: a document from a list keeps its view tabs, Split and type line", ctx do
    view = editor(ctx.conn, "#{ctx.base}/#{ctx.post}")

    refute has_element?(view, "#{@pane}[data-desk-document]")
    assert has_element?(view, "#{@pane} [role=tab]", "Linked")
    assert has_element?(view, ~s(#{@pane} [aria-label="Split pane right"]))
    assert has_element?(view, "#{@pane} .editor-meta .dk-kind", "Title of dsp_post")
  end
end
