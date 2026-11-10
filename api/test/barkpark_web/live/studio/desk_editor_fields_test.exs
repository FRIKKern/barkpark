defmodule BarkparkWeb.Studio.DeskEditorFieldsTest do
  @moduledoc """
  Plain field kinds in the desk's editor pane (`DeskLive`, the last document
  of the chain): J13 validation, J14 field groups and a list's checkboxes,
  J30 conditional fields, J31 select / radio / date / datetime, B04 every
  plain field type renders sanely.

  Measured in a browser first (editing-w1 probe, port 4131): each of these
  behaves in the desk exactly as in the plain Studio, so these tests pin
  that behaviour for the split refactor; none is known-broken. What is
  missing or broken in the Studio itself (no validation panel, no tab
  badge, nested objects re-open on every save, slug maxLength ignored,
  integer without a numeric keyboard) is not the desk's and is not tested
  here.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "w1_kinds_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "W1 kinds #{n}",
          "visibility" => "public",
          "groups" => [
            %{"name" => "main", "title" => "Main"},
            %{"name" => "more", "title" => "More"}
          ],
          "fields" => [
            %{
              "name" => "title",
              "title" => "Title",
              "type" => "string",
              "group" => "main",
              "validation" => [
                %{"required" => true},
                %{"max" => 40, "level" => "warning", "message" => "Over 40 chars warns."}
              ]
            },
            %{"name" => "slug", "title" => "Slug", "type" => "slug", "group" => "main"},
            %{
              "name" => "email",
              "title" => "Email",
              "type" => "email",
              "group" => "main",
              "validation" => [
                %{"pattern" => "^[^@\\s]+@[^@\\s]+$", "message" => "Not an email."}
              ]
            },
            %{
              "name" => "count",
              "title" => "Count",
              "type" => "integer",
              "group" => "main",
              "validation" => [%{"min" => 1}, %{"max" => 10}]
            },
            %{"name" => "price", "title" => "Price", "type" => "number", "group" => "main"},
            %{"name" => "isEvent", "title" => "Is event", "type" => "boolean", "group" => "main"},
            %{
              "name" => "eventDay",
              "title" => "Event day",
              "type" => "date",
              "group" => "main",
              "visibleWhen" => %{"field" => "isEvent", "operator" => "eq", "value" => true}
            },
            %{
              "name" => "startsAt",
              "title" => "Starts at",
              "type" => "datetime",
              "group" => "main"
            },
            %{
              "name" => "category",
              "title" => "Category",
              "type" => "select",
              "group" => "main",
              "options" => [
                %{"value" => "news", "title" => "News"},
                %{"value" => "feature", "title" => "Feature"}
              ]
            },
            %{
              "name" => "tone",
              "title" => "Tone",
              "type" => "select",
              "group" => "main",
              "layout" => "radio",
              "options" => [
                %{"value" => "calm", "title" => "Calm"},
                %{"value" => "loud", "title" => "Loud"}
              ]
            },
            %{"name" => "tint", "title" => "Tint", "type" => "color", "group" => "more"},
            %{"name" => "where", "title" => "Where", "type" => "geopoint", "group" => "more"},
            %{"name" => "raw", "title" => "Raw JSON", "type" => "object", "group" => "more"},
            %{"name" => "code", "title" => "Code", "type" => "source", "group" => "more"},
            %{
              "name" => "labels",
              "title" => "Labels",
              "type" => "arrayOf",
              "group" => "more",
              "of" => %{
                "type" => "select",
                "options" => [
                  %{"value" => "a", "title" => "Label A"},
                  %{"value" => "b", "title" => "Label B"}
                ]
              }
            },
            %{
              "name" => "seo",
              "title" => "SEO",
              "type" => "composite",
              "group" => "more",
              "fields" => [%{"name" => "metaTitle", "title" => "Meta title", "type" => "string"}]
            }
          ]
        },
        @dataset
      )

    id = "w1k-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "Kinds one",
          "content" => %{
            "email" => "a@b.no",
            "count" => 3,
            "price" => 9.5,
            "isEvent" => false,
            "startsAt" => "2026-11-10T09:30:00Z",
            "category" => "news",
            "tone" => "calm",
            "tint" => "#ff8800",
            "where" => %{"_type" => "geopoint", "lat" => 59.9, "lng" => 10.7},
            "raw" => %{"a" => 1, "b" => [1, 2]},
            "code" => "line one\nline two",
            "labels" => ["a"],
            "seo" => %{"metaTitle" => "Meta"}
          }
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: sign_in(conn), base: base, type: type, id: id}
  end

  defp sign_in(conn) do
    raw = "desk-w1-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-w1", @dataset, ["read", "write", "admin"], ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp settle(view), do: render_async(view, 5_000)

  defp open(ctx) do
    {:ok, view, _html} = live(ctx.conn, "#{ctx.base}/#{ctx.type};#{ctx.id}")
    settle(view)
    assert has_element?(view, "[data-pane-editing] #editor-form")
    view
  end

  @form "[data-pane-editing] #editor-form"

  defp field?(view, name), do: has_element?(view, ~s(#{@form} [name="doc[#{name}]"]))

  defp tab(view, name),
    do:
      view
      |> element(~s([data-pane-editing] [role="tab"][phx-value-group="#{name}"]))
      |> render_click()

  defp content(ctx) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(ctx.type, ctx.id, @dataset)
    doc.content
  end

  describe "J13 validation" do
    test "publish is refused with the reason, and each rule's error shows under its field", ctx do
      view = open(ctx)

      view
      |> form("#editor-form")
      |> render_change(%{"doc" => %{"email" => "not-an-email", "count" => "42"}})

      view
      |> element(~s([data-pane-editing] .pane-header button[aria-label="Publish"]))
      |> render_click()

      assert has_element?(
               view,
               "#studio-flash .flash-error",
               "Fix validation errors before publishing"
             )

      assert has_element?(view, "#{@form} .editor-field.has-error .field-errors", "Not an email.")

      assert has_element?(
               view,
               "#{@form} .editor-field.has-error .field-errors",
               "Must be at most 10"
             )

      {_doc, _draft?, published?} = Content.fetch_doc_with_draft(ctx.type, ctx.id, @dataset)
      refute published?
    end

    test "a warning-level rule nags under the field and does not block", ctx do
      view = open(ctx)

      view
      |> form("#editor-form")
      |> render_change(%{"doc" => %{"title" => "A title that is clearly over forty characters"}})

      assert has_element?(view, "#{@form} .field-warnings", "Over 40 chars warns.")
      assert has_element?(view, ~s([data-pane-editing] [data-test-id="validation-warnings"]))
    end
  end

  describe "J14 groups and lists" do
    test "group tabs switch the fields shown, in the pane, without a patch", ctx do
      view = open(ctx)
      assert field?(view, "email")
      refute field?(view, "tint")

      tab(view, "more")

      assert has_element?(
               view,
               ~s([data-pane-editing] [role="tab"][aria-selected="true"]),
               "More"
             )

      assert field?(view, "tint")
      refute field?(view, "email")
      assert has_element?(view, ~s(#{@form} input[name="doc[seo].metaTitle"][value="Meta"]))
    end

    test "a list of options draws checkboxes, and ticking one saves the list", ctx do
      view = open(ctx)
      tab(view, "more")

      assert has_element?(
               view,
               ~s(#{@form} input[type="checkbox"][name="doc[labels][]"][value="a"][checked])
             )

      assert has_element?(
               view,
               ~s(#{@form} input[type="checkbox"][name="doc[labels][]"][value="b"])
             )

      view |> form("#editor-form") |> render_change(%{"doc" => %{"labels" => ["", "a", "b"]}})
      assert content(ctx)["labels"] == ["a", "b"]
    end
  end

  describe "J30 conditional fields" do
    test "a visibleWhen field appears when the switch it reads is turned on", ctx do
      view = open(ctx)
      refute field?(view, "eventDay")

      view |> form("#editor-form") |> render_change(%{"doc" => %{"isEvent" => "true"}})

      assert field?(view, "eventDay")
      assert content(ctx)["isEvent"] == true
    end
  end

  describe "J31 select, radio, date and datetime" do
    test "each control is drawn and its edit is saved", ctx do
      view = open(ctx)

      assert has_element?(
               view,
               ~s(#{@form} select[name="doc[category]"] option[value="news"][selected])
             )

      assert has_element?(
               view,
               ~s(#{@form} input[type="radio"][name="doc[tone]"][value="calm"][checked])
             )

      assert has_element?(view, ~s(#{@form} input[type="hidden"][name="doc[startsAt]"]))
      assert has_element?(view, ~s(#{@form} input[type="datetime-local"]))

      view
      |> form("#editor-form")
      |> render_change(%{
        "doc" => %{
          "isEvent" => "true",
          "category" => "feature",
          "tone" => "loud",
          "startsAt" => "2026-12-01T07:15:00Z"
        }
      })

      assert has_element?(view, ~s(#{@form} input[type="date"][name="doc[eventDay]"]))
      view |> form("#editor-form") |> render_change(%{"doc" => %{"eventDay" => "2026-12-24"}})

      saved = content(ctx)
      assert saved["category"] == "feature"
      assert saved["tone"] == "loud"
      assert saved["startsAt"] == "2026-12-01T07:15:00Z"
      assert saved["eventDay"] == "2026-12-24"
    end
  end

  describe "B04 every plain type renders sanely" do
    test "colour, slug, number, read-only JSON and source; never [object Object]", ctx do
      view = open(ctx)

      assert has_element?(view, ~s(#{@form} input[name="doc[price]"][inputmode="numeric"]))

      assert has_element?(
               view,
               ~s(#{@form} button[phx-click="slug-generate"][phx-value-field="slug"]),
               "Generate"
             )

      view |> element(~s(#{@form} button[phx-click="slug-generate"])) |> render_click()
      assert has_element?(view, ~s(#{@form} input[name="doc[slug]"][value="kinds-one"]))

      tab(view, "more")

      assert has_element?(
               view,
               ~s(#{@form} input[type="hidden"][name="doc[tint]"][value="#ff8800"])
             )

      assert has_element?(view, ~s(#{@form} input[type="color"]))
      assert has_element?(view, ~s(#{@form} [data-readonly-field="raw"]), ~s("a": 1))
      assert has_element?(view, ~s(#{@form} [data-source-field]), "line two")
      assert has_element?(view, ~s(#{@form} [data-readonly-field="where"]), "geopoint")

      refute render(view) =~ "[object Object]"
    end
  end
end
