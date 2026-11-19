defmodule BarkparkWeb.Studio.DeskValidationUrlTest do
  @moduledoc """
  J13, nested (barkpark-studio `e2e/journeys/nested-validation.spec.ts`, its
  first test): a `url` field in an array item that holds no web address is a
  validation error named "Links / External link / URL", "Not a valid URL",
  as the TanStack Studio's `typeRule` finds it (`Content.TypeShape`). It
  draws the header's Validation button, is listed in the panel, and blocks
  Publish; it never refuses the save. Picking it opens the item's dialog
  and focuses the field (`bp-desk-validation.js`).

  Every type and document a test reads is made in this setup.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Validation
  alias Barkpark.Tenancy

  @dataset "production"
  @pane "[data-pane-editing]"
  @button ~s(#{@pane} .pane-header button.validation-btn[aria-label="Validation"])
  @panel ~s(#{@pane} aside.inspector.validation[aria-label="Validation"])
  @publish ~s(#{@pane} .doc-footer button[data-desk-publish])
  @inspect_param "inspect=sanity%2Fstructure%2Fvalidation"
  @problem ~s|#{@panel} button.problem[data-desk-problem='links[_key=="l1"].url']|

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "vu_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Linked #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "links",
              "title" => "Links",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "options" => %{
                  "typeField" => "kind",
                  "fieldsByType" => %{"externalLink" => ["title", "url"]}
                },
                "fields" => [
                  %{
                    "name" => "kind",
                    "title" => "Kind",
                    "type" => "select",
                    "options" => [%{"value" => "externalLink", "title" => "External link"}]
                  },
                  %{"name" => "title", "title" => "Title", "type" => "string"},
                  %{"name" => "url", "title" => "URL", "type" => "url"}
                ]
              }
            }
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-validation-url-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id

    {:ok, _} =
      Auth.create_token(raw, "desk-validation-url", @dataset, ~w(read write admin), ws_id)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: base, type: type, n: n}
  end

  defp links(url),
    do: [%{"_key" => "l1", "kind" => "externalLink", "title" => "Bad link", "url" => url}]

  defp draft(c, name, content) do
    id = "vu-#{name}-#{c.n}"

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> id, "title" => "Probe #{name}", "content" => content},
        @dataset
      )

    id
  end

  defp open(c, id, params \\ "") do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};#{id}#{params}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp text(html),
    do: html |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  test "an array item's url that is no address: the button, the entry, Publish blocked", c do
    view = open(c, draft(c, "bad", %{"links" => links("not a url")}))

    assert has_element?(view, ~s(#{@button}[data-level="error"][data-problems="1"]))
    assert has_element?(view, ~s(#{@publish}[disabled]))

    view |> element(@button) |> render_click()
    assert_patch(view)

    assert view |> element(@problem) |> render() |> text() ==
             "Links / External link / URL Not a valid URL"

    # The press names the row, for the jump to open its dialog.
    assert view |> element(@problem) |> render() =~ ~s(&quot;item&quot;:&quot;0&quot;)
  end

  test "an address that is not http or https, or carries a password, in TanStack's words", c do
    scheme =
      open(c, draft(c, "scheme", %{"links" => links("mailto:a@b.no")}), ",#{@inspect_param}")

    assert scheme |> element(@problem) |> render() |> text() ==
             "Links / External link / URL Does not match allowed protocols/schemes"

    login =
      open(c, draft(c, "login", %{"links" => links("https://u:p@x.no")}), ",#{@inspect_param}")

    assert login |> element(@problem) |> render() |> text() ==
             "Links / External link / URL Username/password not allowed"
  end

  test "a good address is no problem", c do
    view = open(c, draft(c, "good", %{"links" => links("https://example.com")}))

    refute has_element?(view, @button)
    refute has_element?(view, ~s(#{@publish}[disabled]))
  end

  test "the words are Norwegian under nb_NO", c do
    id = draft(c, "nb", %{"links" => links("not a url")})

    Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
      view = open(c, id, ",#{@inspect_param}")
      assert view |> element(@problem) |> render() |> text() =~ "Ikke en gyldig URL"
    end)
  end

  test "the save path does not refuse it: the rule is the desk's, as TanStack's browser rule" do
    content = %{"links" => links("not a url")}

    schema = %{
      "fields" => [
        %{
          "name" => "links",
          "type" => "arrayOf",
          "of" => %{"type" => "composite", "fields" => [%{"name" => "url", "type" => "url"}]}
        }
      ]
    }

    assert {:ok, ^content} = Validation.validate(content, "t", schema)
  end

  test "the jump opens a shut item dialog the way its preview does" do
    js = File.read!(Application.app_dir(:barkpark, "priv/static/assets/bp-desk-validation.js"))

    assert js =~ ~s|dialog[data-desk-item-dialog]|
    assert js =~ ~s|:scope > [data-desk-item-open]|
    # A desk row is an <li>, not the old Studio's <details>.
    assert js =~ ~s|li[data-row-index]|
  end
end
