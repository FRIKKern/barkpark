defmodule BarkparkWeb.Studio.DeskSelectDatetimeTest do
  @moduledoc """
  J31: a select list and a date-time in the desk, as the TanStack Studio
  draws them (`DeskSelect`, `DeskDatetime`).

    * A radio list declared Sanity's way (`options: {list, direction}`) is a
      group of radios named by the field, its bare values titled ("Idea"),
      with Clear on the chosen value. A pick stores the value; Clear removes
      the field; a stored value that is not an option survives other edits.
    * A date-time is a text box with an "Open calendar" button; the form posts
      the hidden ISO instant, stored as posted.
    * Edits in the published view are refused. The old Studio keeps its own.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @form "[data-pane-editing] #editor-form"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "sd_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Post #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "stage",
              "title" => "Stage",
              "type" => "select",
              "layout" => "radio",
              "options" => %{
                "list" => ["idea", "writing", "review", "done"],
                "direction" => "horizontal"
              }
            },
            %{
              "name" => "format",
              "title" => "Format",
              "type" => "select",
              "options" => [
                %{"value" => "essay", "title" => "Essay"},
                %{"value" => "note", "title" => "Short note"}
              ]
            },
            %{"name" => "publishedAt", "title" => "Published at", "type" => "datetime"},
            %{"name" => "notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-sd-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-sd", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, root: root, type: type}
  end

  defp doc!(c, content) do
    id = "sd-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Post", "content" => Map.put(content, "notes", "0")},
        @dataset
      )

    id
  end

  defp desk(c, id, query \\ "") do
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}#{query}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  defp change(view, name, value) do
    view
    |> form(@form, %{"doc" => %{name => value}})
    |> render_change(%{"_target" => ["doc", name]})
  end

  # The hidden input the hook writes (a form helper refuses a hidden change).
  defp hook_post(view, name, value) do
    view
    |> form(@form)
    |> render_change(%{"doc" => %{name => value}, "_target" => ["doc", name]})
  end

  @group ~s(#{@form} .radio-box[data-direction="horizontal"] [role="group"]#stage[aria-label="Stage"])

  test "a radio list from options.list: a group named by the field, values titled, Clear on the pick",
       c do
    view = desk(c, doc!(c, %{"stage" => "writing"}))

    assert has_element?(
             view,
             ~s(#{@group} label.radio input[type="radio"][name="doc[stage]"][value="idea"])
           )

    assert has_element?(view, ~s(#{@group} label.radio), "Idea")
    assert has_element?(view, ~s(#{@group} input[value="writing"][checked]))
    refute has_element?(view, ~s(#{@group} input[value="idea"][checked]))

    assert has_element?(
             view,
             ~s(#{@form} .radio-box > button[data-radio-clear][aria-label="Clear"])
           )

    assert has_element?(
             view,
             ~s(#{@form} .radio-box > input[type="hidden"][name="doc[stage]"][value=""][disabled])
           )

    refute has_element?(view, ~s(#{@form} select[name="doc[stage]"]))

    # A dropdown keeps a select, its titles the declared ones.
    assert has_element?(
             view,
             ~s(#{@form} select#format[name="doc[format]"] option[value="note"]),
             "Short note"
           )
  end

  test "a pick stores the value, Clear removes the field, and nothing chosen shows no Clear", c do
    id = doc!(c, %{})
    view = desk(c, id)

    refute has_element?(view, ~s(#{@form} [data-radio-clear]))

    change(view, "stage", "review")
    assert stored(c, id)["stage"] == "review"
    assert has_element?(view, ~s(#{@group} input[value="review"][checked]))
    assert has_element?(view, ~s(#{@form} [data-radio-clear]))

    # Clear: the hidden input posts "" for the field.
    EditorPost.change(view, %{"doc[stage]" => "", "_target" => ["doc", "stage"]})
    refute Map.has_key?(stored(c, id), "stage")
    assert stored(c, id)["notes"] == "0"
    refute has_element?(view, ~s(#{@group} input[checked]))
  end

  test "a stored value that is not an option survives an edit elsewhere", c do
    id = doc!(c, %{"stage" => "archived"})
    view = desk(c, id)

    refute has_element?(view, ~s(#{@group} input[checked]))
    refute has_element?(view, ~s(#{@form} [data-radio-clear]))

    change(view, "notes", "typed")
    assert stored(c, id)["notes"] == "typed"
    assert stored(c, id)["stage"] == "archived"
  end

  test "a date-time is a text box with a calendar button; the posted instant is stored", c do
    id = doc!(c, %{"publishedAt" => "2026-09-06T09:00:00.000Z"})
    view = desk(c, id)
    wrap = ~s(#{@form} .datetime[phx-hook="BarkparkDatetimeField"])

    assert has_element?(
             view,
             ~s(#{wrap} input[type="hidden"][name="doc[publishedAt]"][value="2026-09-06T09:00:00Z"])
           )

    assert has_element?(
             view,
             ~s(#{wrap} [phx-update="ignore"] input[type="text"]#publishedAt[data-datetime-text])
           )

    assert has_element?(
             view,
             ~s(#{wrap} button[data-datetime-open][aria-label="Open calendar"][aria-expanded="false"])
           )

    assert has_element?(view, ~s(#{wrap} p.field-error[role="alert"][hidden]))
    refute has_element?(view, ~s(#{wrap} input[type="datetime-local"]))
    assert has_element?(view, ~s(#{@form} label[for="publishedAt"]))

    hook_post(view, "publishedAt", "2026-09-07T09:00:00.000Z")
    assert stored(c, id)["publishedAt"] == "2026-09-07T09:00:00.000Z"

    change(view, "notes", "typed")
    assert stored(c, id)["publishedAt"] == "2026-09-07T09:00:00.000Z"

    hook_post(view, "publishedAt", "")
    refute Map.has_key?(stored(c, id), "publishedAt")
  end

  test "an edit sent while the published version is shown is refused", c do
    id = doc!(c, %{"stage" => "idea", "publishedAt" => "2026-09-06T09:00:00.000Z"})
    {:ok, _} = Content.publish_document(id, c.type, @dataset)
    published = Content.get_document(id, c.type, @dataset)
    view = desk(c, id, "?perspective=published")

    EditorPost.change(view, %{"doc[stage]" => ""})
    EditorPost.change(view, %{"doc[publishedAt]" => "2027-01-01T00:00:00.000Z"})

    assert Content.get_document(id, c.type, @dataset) == published
    assert stored(c, id)["stage"] == "idea"
  end

  test "the old Studio keeps its radio group and date-time-local", c do
    id = doc!(c, %{"stage" => "writing", "publishedAt" => "2026-09-06T09:00:00.000Z"})
    {:ok, view, _html} = live(c.conn, "#{c.root}/#{c.type}/#{id}")

    assert has_element?(
             view,
             ~s([role="radiogroup"] input[type="radio"][name="doc[stage]"][value="writing"][checked])
           )

    refute has_element?(view, ~s([data-radio-clear]))
    assert has_element?(view, ~s(input[type="datetime-local"]))
    refute has_element?(view, ~s([data-datetime-text]))
  end
end
