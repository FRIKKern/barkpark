defmodule BarkparkWeb.Studio.LinkDialogHrefTest do
  @moduledoc """
  task-8c1ce08bb99e4d89: the rich text annotation dialog saved any address
  and pushed it to the editor (`bp:pt-def-update` → `ptDefUpdate`), so a
  `javascript:` link reached the editor DOM. It now takes only what a link
  may draw (`Barkpark.Content.LinkHref.allowed?/1`, the reader's allowlist):
  anything else stays in the open dialog with TanStack's words under the
  field (`app/src/components/BodyToolbar.tsx`, `lib/link-href.ts`), and
  nothing is saved or pushed.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.PortableText
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.StudioLive.Handlers.ObjectBlocks

  @dataset "production"
  @refused "Use a web, mail or phone address (https:, mailto:, tel:) or a path."

  defp annotation(name, fields), do: %{"name" => name, "type" => "object", "fields" => fields}

  defp body_field(name, annotations) do
    %{
      "name" => name,
      "type" => "array",
      "of" => [
        %{
          "type" => "block",
          "styles" => [%{"title" => "normal", "value" => "normal"}],
          "lists" => [],
          "marks" => %{"decorators" => [], "annotations" => annotations}
        }
      ]
    }
  end

  defp block(key) do
    %{
      "_key" => key,
      "_type" => "block",
      "style" => "normal",
      "markDefs" => [],
      "children" => [
        %{
          "_key" => key <> "s",
          "_type" => "span",
          "text" => "an editable sentence",
          "marks" => []
        }
      ]
    }
  end

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "lkdlg-#{n}", name: "Link dialog"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    raw = "lkdlg-token-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "lkdlg", @dataset, ~w(read write admin), default_ws.id)
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "lkdlg",
          "title" => "Link dialog",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            body_field("plain", [annotation("link", [%{"name" => "href", "type" => "url"}])]),
            body_field("rich", [
              annotation("linkAnnotation", [
                %{"name" => "linkType", "type" => "string"},
                %{"name" => "url", "type" => "string"}
              ])
            ])
          ]
        },
        @dataset,
        scope
      )

    content = %{"plain" => [block("pl01")], "rich" => [block("ri01")]}

    {:ok, _} =
      Content.upsert_document(
        "lkdlg",
        %{"doc_id" => "lk-1", "title" => "Links", "status" => "published", "content" => content},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, _} = Content.publish_document("lk-1", "lkdlg", @dataset, scope)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     path: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/lkdlg/lk-1",
     scope: scope}
  end

  defp draft_defs(scope, field) do
    {:ok, doc} = Content.get_document("drafts.lk-1", "lkdlg", @dataset, scope)
    Enum.flat_map(doc.content[field], &(&1["markDefs"] || []))
  end

  # The editor marks the selection under a new key and posts its HTML; the
  # server opens the annotation's dialog.
  defp add_link(c, field, type, key) do
    {:ok, view, _html} = live(c.conn, c.path)
    {:ok, doc} = Content.get_document("lk-1", "lkdlg", @dataset, c.scope)

    html =
      doc.content[field]
      |> PortableText.to_html()
      |> String.replace(
        "editable sentence",
        ~s(<span data-pt-def="#{key}">editable sentence</span>)
      )

    render_hook(view, "pt-def-insert", %{
      "field" => field,
      "type" => type,
      "key" => key,
      "html" => html
    })

    assert_push_event(view, "bp:pt-def-ready", %{key: ^key, accepted: true})
    assert has_element?(view, ~s(#bp-object-dialog[data-object-key="#{key}"]))
    view
  end

  defp save(view, key, name, href) do
    view
    |> form("#bp-object-dialog-form-#{key}", %{"doc[__object].#{name}" => href})
    |> render_submit()
  end

  for href <- [
        "javascript:alert(1)",
        "JaVaScRiPt:alert(1)",
        "  javascript:alert(1)",
        "jav\tascript:alert(1)",
        "&#106;avascript:alert(1)",
        "data:text/html,<script>alert(1)</script>",
        "vbscript:msgbox(1)",
        "//evil.example/x"
      ] do
    @href href
    test "a link's #{inspect(href)} stays in the dialog with the reason, and reaches no editor",
         c do
      view = add_link(c, "plain", "link", "lk00new1")
      save(view, "lk00new1", "href", @href)

      refute_push_event(view, "bp:pt-def-update", %{key: "lk00new1"})
      assert has_element?(view, ~s(#bp-object-dialog[data-object-key="lk00new1"]))
      assert has_element?(view, ~s(#bp-object-dialog [data-error-for="href"]), @refused)
      refute Enum.any?(draft_defs(c.scope, "plain"), &(&1["href"] == @href))
    end
  end

  test "a linkAnnotation's javascript: url stays in the dialog with the reason", c do
    view = add_link(c, "rich", "linkAnnotation", "la00new1")
    save(view, "la00new1", "url", "javascript:alert(1)")

    refute_push_event(view, "bp:pt-def-update", %{key: "la00new1"})
    assert has_element?(view, ~s(#bp-object-dialog [data-error-for="url"]), @refused)
    refute Enum.any?(draft_defs(c.scope, "rich"), &(&1["url"] == "javascript:alert(1)"))
  end

  test "a refused address put right saves, and the reason goes", c do
    view = add_link(c, "plain", "link", "lk00new1")
    save(view, "lk00new1", "href", "javascript:alert(1)")
    assert has_element?(view, ~s(#bp-object-dialog [data-error-for="href"]))

    save(view, "lk00new1", "href", "https://example.org/c")

    assert_push_event(view, "bp:pt-def-update", %{key: "lk00new1", href: "https://example.org/c"})
    refute has_element?(view, "#bp-object-dialog")
  end

  for href <- [
        "https://example.org/c",
        "http://example.org/c",
        "mailto:someone@example.test",
        "tel:+4712345678",
        "/about",
        "./next",
        "../up",
        "?page=2",
        "#top"
      ] do
    @href href
    test "control: #{inspect(href)} saves and reaches the editor", c do
      view = add_link(c, "plain", "link", "lk00new1")
      save(view, "lk00new1", "href", @href)

      href = @href
      assert_push_event(view, "bp:pt-def-update", %{key: "lk00new1", href: ^href})
      refute has_element?(view, "#bp-object-dialog")
      assert Enum.any?(draft_defs(c.scope, "plain"), &(&1["href"] == @href))
    end
  end

  test "the reason in Norwegian, as TanStack's nb words it" do
    Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
      assert ObjectBlocks.refused_href_message() ==
               "Bruk en nett-, e-post- eller telefonadresse (https:, mailto:, tel:) eller en sti."
    end)
  end
end
