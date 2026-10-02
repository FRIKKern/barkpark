defmodule BarkparkWeb.Studio.EditorFormRoundtripTest do
  @moduledoc """
  Gyldendal friction 65 / 66 (task-cd8e10ca44ccb932, criterion 4) — the Classic
  editor form on a document shaped like the twin's Forside: an `image` field,
  an `arrayOf` of `reference`, and an `arrayOf` of `composite` whose rows carry
  an `image` subfield.

  Two contracts, pinned from the customer's side:

    1. OPENING the editor writes nothing. No `drafts.*` row exists after mount
       and render; the published row's revision is untouched.

    2. ONE change through the form's own wire shape round-trips the REST of
       the document byte-identically: reference arrays stay LISTS (not the
       index-keyed maps `Plug.Conn.Query.decode/1` produces for
       `doc[featuredPublications][0]`), an image object stays an OBJECT (not
       the JSON string the picker's hidden input carries), a composite row's
       image subfield stays an object, and no row is appended.

  The form data is built from the RENDERED form (`Phoenix.LiveViewTest.form/3`
  collects every input the HTML carries, hidden ones included) so the params
  the LiveView receives are exactly what a browser's `phx-change` sends.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @type_name "landing"

  @hero %{
    "assetId" => "hero",
    "url" => "https://cdn.example/hero.jpg",
    "alt" => "Hero",
    "focalX" => 0.4,
    "focalY" => 0.6,
    "width" => 1200,
    "height" => 800
  }

  @card_image %{
    "assetId" => "card",
    "url" => "https://cdn.example/card.jpg",
    "alt" => "",
    "focalX" => nil,
    "focalY" => nil,
    "lqip" => "data:image/jpeg;base64,AAAA",
    "width" => 1600,
    "height" => 900
  }

  @refs ["pub-10038688", "pub-10039433", "pub-10039087"]
  @news ["article-a", "article-b"]

  @banners [
    %{
      "title" => "Crime from the North",
      "buttonHref" => "/books",
      "blurBackground" => true,
      "backgroundImage" => @card_image
    },
    %{
      "title" => "Over My Dead Body",
      "buttonHref" => "/books/over-my-dead-body",
      "blurBackground" => false,
      "backgroundImage" => @card_image
    }
  ]

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "rt-twin-#{suffix}", name: "Roundtrip Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "rt-owner-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "rt-owner", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "article",
          "title" => "Nyhet",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Landing",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{
              "name" => "heroImage",
              "title" => "Hovedbilde",
              "type" => "image",
              "options" => %{"hotspot" => true, "alt" => true}
            },
            %{
              "name" => "featuredPublications",
              "title" => "Fremhevede utgivelser",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "publication"}
            },
            %{
              "name" => "featuredNews",
              "title" => "Fremhevede nyheter",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "article"}
            },
            %{
              "name" => "banners",
              "title" => "Feature-kort",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "title" => "Feature-kort",
                "fields" => [
                  %{"name" => "title", "title" => "Tittel", "type" => "string"},
                  %{"name" => "buttonHref", "title" => "Lenke", "type" => "string"},
                  %{"name" => "blurBackground", "title" => "Blur", "type" => "boolean"},
                  %{
                    "name" => "backgroundImage",
                    "title" => "Bakgrunnsbilde",
                    "type" => "image",
                    "options" => %{"hotspot" => true, "alt" => true}
                  }
                ]
              }
            }
          ]
        },
        @dataset,
        scope
      )

    for id <- @refs do
      {:ok, _} =
        Content.upsert_document(
          "publication",
          %{"doc_id" => id, "title" => id, "status" => "published", "content" => %{}},
          @dataset,
          Keyword.put(scope, :source, :api)
        )
    end

    for id <- @news do
      {:ok, _} =
        Content.upsert_document(
          "article",
          %{"doc_id" => id, "title" => id, "status" => "published", "content" => %{}},
          @dataset,
          Keyword.put(scope, :source, :api)
        )
    end

    {:ok, _draft} =
      Content.upsert_document(
        @type_name,
        %{
          "doc_id" => "landing-forside",
          "title" => "Forside",
          "status" => "published",
          "content" => %{
            "heroImage" => @hero,
            "featuredPublications" => @refs,
            "featuredNews" => @news,
            "banners" => @banners
          }
        },
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    # A PUBLISHED row with no draft twin — the shape an editor opens on the
    # twin's Forside. `upsert_document` always lands a draft first.
    {:ok, doc} = Content.publish_document("landing-forside", @type_name, @dataset, scope)
    assert doc.doc_id == "landing-forside"

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, ws: ws, proj: proj, doc: doc, scope: scope}
  end

  defp editor_url(ws, proj, doc),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{@type_name}/#{doc.doc_id}"

  defp draft(scope),
    do: Content.get_document("drafts.landing-forside", @type_name, @dataset, scope)

  defp published!(scope) do
    {:ok, d} = Content.get_document("landing-forside", @type_name, @dataset, scope)
    d
  end

  defp open!(conn, ws, proj, doc) do
    {:ok, view, html} = live(conn, editor_url(ws, proj, doc))

    refute html =~ "Studio could not open this document",
           "the editor answered with the not-found card"

    assert html =~ ~s(value="Forside")
    {view, html}
  end

  # Whichever row the editor wrote — the draft it should have created, else
  # the published row (so a test that expects a draft fails on CONTENT, with
  # the stored shape in the message, not on a nil).
  defp stored_content(scope) do
    case draft(scope) do
      {:ok, d} -> d.content
      _ -> published!(scope).content
    end
  end

  describe "opening the editor" do
    test "writes nothing — no draft appears and the published revision is untouched", %{
      conn: conn,
      ws: ws,
      proj: proj,
      doc: doc,
      scope: scope
    } do
      before = published!(scope)

      {view, _html} = open!(conn, ws, proj, doc)
      _ = render(view)

      assert match?({:error, _}, draft(scope)),
             "opening the editor created a draft with no user change: " <>
               inspect(draft(scope))

      assert published!(scope).rev == before.rev,
             "opening the editor rewrote the published row"
    end
  end

  describe "socket rejoin" do
    # LiveView 1.1 `getFormsForRecovery` re-posts every id-bearing
    # `form[phx-change]` on rejoin unless it carries phx-auto-recover="ignore".
    # The editor autosaves each change within its debounce, so recovery has
    # nothing to restore — and WITH recovery, a deploy restart or a network
    # blip posted the browser's whole form as an autosave: a draft with no
    # keystroke (the twin's drafts.frontpage on 2026-09-10, 09:22Z, minutes
    # after gyl restarted). A LiveView test cannot drive the JS client, so the
    # opt-out is pinned on the rendered form.
    test "the editor form opts out of LiveView form recovery", %{
      conn: conn,
      ws: ws,
      proj: proj,
      doc: doc
    } do
      {_view, html} = open!(conn, ws, proj, doc)

      assert html =~ ~r/<form[^>]*id="editor-form"[^>]*phx-auto-recover="ignore"/ or
               html =~ ~r/<form[^>]*phx-auto-recover="ignore"[^>]*id="editor-form"/,
             "the editor form is re-posted on every socket rejoin (no phx-auto-recover=\"ignore\")"
    end
  end

  describe "one change through the form's own wire shape" do
    # The fixture's own shape assertion: every input the editor renders for
    # the arrays and images, exactly as the browser would post them.
    test "the rendered form carries bracket-indexed rows and JSON image inputs", %{
      conn: conn,
      ws: ws,
      proj: proj,
      doc: doc
    } do
      {_view, html} = open!(conn, ws, proj, doc)

      assert html =~ ~s(name="doc[featuredPublications][0]")
      assert html =~ ~s(name="doc[featuredPublications][2]")
      assert html =~ ~s(name="doc[banners][0].backgroundImage")
      assert html =~ ~s(name="doc[heroImage]")
    end

    test "phx-change keeps reference arrays as lists, images as objects, and appends no row", %{
      conn: conn,
      ws: ws,
      proj: proj,
      doc: doc,
      scope: scope
    } do
      {view, _html} = open!(conn, ws, proj, doc)

      view
      |> form("#editor-form", %{"doc" => %{"title" => "Forside (endret)"}})
      |> render_change()

      content = stored_content(scope)

      assert content["featuredPublications"] == @refs,
             "reference array came back as: " <> inspect(content["featuredPublications"])

      assert content["featuredNews"] == @news,
             "featuredNews came back as: " <> inspect(content["featuredNews"])

      assert content["heroImage"] == @hero,
             "top-level image came back as: " <> inspect(content["heroImage"])

      assert is_list(content["banners"]) and length(content["banners"]) == 2,
             "banners came back as: " <> inspect(content["banners"])

      for {row, i} <- Enum.with_index(content["banners"]) do
        assert row["backgroundImage"] == @card_image,
               "banners[#{i}].backgroundImage came back as: " <> inspect(row["backgroundImage"])

        assert row["blurBackground"] == Enum.at(@banners, i)["blurBackground"],
               "banners[#{i}].blurBackground came back as: " <> inspect(row["blurBackground"])
      end

      {:ok, d} = draft(scope)
      assert d.title == "Forside (endret)"
    end

    test "phx-submit (Save) round-trips the same shapes", %{
      conn: conn,
      ws: ws,
      proj: proj,
      doc: doc,
      scope: scope
    } do
      {view, _html} = open!(conn, ws, proj, doc)

      view
      |> form("#editor-form", %{"doc" => %{"title" => "Forside (lagret)"}})
      |> render_submit()

      content = stored_content(scope)

      assert content["featuredPublications"] == @refs,
             "reference array came back as: " <> inspect(content["featuredPublications"])

      assert content["heroImage"] == @hero,
             "top-level image came back as: " <> inspect(content["heroImage"])

      assert is_list(content["banners"]) and
               Enum.all?(content["banners"], &(&1["backgroundImage"] == @card_image)),
             "banners came back as: " <> inspect(content["banners"])
    end
  end
end
