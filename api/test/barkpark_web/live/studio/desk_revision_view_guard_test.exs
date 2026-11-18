defmodule BarkparkWeb.Studio.DeskRevisionViewGuardTest do
  @moduledoc """
  The desk's read-only revision view (`RevisionView`, J16) writes nothing:
  no widget of the revision's form carries its value into the live form,
  no event pressed while it is shown writes the open document, and the
  header menu offers no write. History names a signed-in author.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @history ",changesInspectorTab=history,inspect=sanity%2Fstructure%2Fhistory"

  setup %{conn: conn} do
    raw = "rev-guard-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "rev-guard", @dataset, ~w(read write admin), ws.id)
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"}
  end

  # A type with `fields`, one document published with `published` and a
  # draft over it with `draft`; its publish revision.
  defp doc!(fields, published, draft) do
    n = System.unique_integer([:positive])
    type = "rvg_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Guard #{n}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"} | fields]
        },
        @dataset
      )

    id = "rvg-#{n}"
    {:ok, _} = Content.create_document(type, Map.put(published, "doc_id", id), @dataset)
    {:ok, _} = Content.publish_document(id, type, @dataset)

    {:ok, _} =
      Content.upsert_document(type, Map.put(draft, "doc_id", Content.draft_id(id)), @dataset)

    rev =
      id
      |> Content.list_revisions(type, @dataset, limit: 10)
      |> Enum.find(&(&1.action == "publish"))

    %{type: type, id: id, rev: rev.id}
  end

  defp at(c, d, params \\ @history), do: "#{c.base}/#{d.type};#{d.id}#{params}"

  defp open(c, d, params \\ @history) do
    {:ok, view, _} = live(c.conn, at(c, d, params))
    render_async(view, 5_000)
    view
  end

  defp draft(d) do
    {:ok, doc} = Content.get_document(Content.draft_id(d.id), d.type, @dataset)
    doc
  end

  defp published(d) do
    {:ok, doc} = Content.get_document(d.id, d.type, @dataset)
    doc
  end

  defp count(d) do
    case Content.list_documents(d.type, @dataset) do
      {:ok, docs} -> length(docs)
      docs when is_list(docs) -> length(docs)
    end
  end

  defp own_mark(d), do: %{PostIdentity.key() => PostIdentity.value(@dataset, d.type, d.id)}

  defp rich_text!,
    do:
      doc!(
        [%{"name" => "body", "title" => "Body", "type" => "richText"}],
        %{"title" => "RT v1", "body" => "<p>OLD PUBLISHED BODY</p>"},
        %{"title" => "RT draft", "body" => "<p>CURRENT DRAFT BODY</p>"}
      )

  defp hidden_body(view) do
    case Regex.run(~r/<input[^>]*id="bp-rt-hidden-body"[^>]*>/, render(view)) do
      [input] -> input |> then(&Regex.run(~r/value="([^"]*)"/, &1)) |> List.last()
      _ -> nil
    end
  end

  describe "no widget of the revision's form reaches the live form" do
    test "the revision draws its rich text with no editor widget, and the live one comes back fresh",
         c do
      d = rich_text!()
      view = open(c, d, "")
      assert hidden_body(view) =~ "CURRENT DRAFT BODY"

      # Picked from the live form: the revision's value, in no ignored widget.
      render_patch(view, at(c, d, @history <> ",rev=#{d.rev}"))
      render_async(view, 5_000)

      revision =
        view |> element("[data-pane-editing] fieldset[data-desk-revision-form]") |> render()

      refute revision =~ "bp-rt-wrap-"
      # Its one ignored element is the form's `_bp_seen` buffer, which the
      # disabled form never writes.
      assert [[seen]] = Regex.scan(~r/<[^>]*phx-update="ignore"[^>]*>/, revision)
      assert seen =~ ~s(name="_bp_seen")
      assert revision =~ "OLD PUBLISHED BODY"
      refute revision =~ "CURRENT DRAFT BODY"

      # Left again: the live form's own value.
      render_patch(view, at(c, d))
      render_async(view, 5_000)
      assert hidden_body(view) =~ "CURRENT DRAFT BODY"
    end

    test "a deep revision URL left for the live form: a title edit keeps the draft's rich text",
         c do
      d = rich_text!()
      view = open(c, d, @history <> ",rev=#{d.rev}")
      assert has_element?(view, "[data-pane-editing] [data-desk-revision-form]")

      render_patch(view, at(c, d))
      render_async(view, 5_000)
      refute has_element?(view, "[data-pane-editing] [data-desk-revision-form]")
      assert hidden_body(view) =~ "CURRENT DRAFT BODY"

      view
      |> form("[data-pane-editing] #editor-form", %{"doc" => %{"title" => "RT draft edited"}})
      |> render_change()

      render_async(view, 5_000)
      stored = draft(d)
      assert stored.title == "RT draft edited"
      assert stored.content["body"] =~ "CURRENT DRAFT BODY"
    end
  end

  describe "nothing pressed while a revision is shown writes the open document" do
    test "a block canvas is not drawn, and its ops write nothing", c do
      blocks = fn text ->
        %{
          "blocks" => [
            %{
              "id" => "p1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => text}]
            }
          ],
          "html" => "<p>#{text}</p>"
        }
      end

      d =
        doc!(
          [
            %{"name" => "description", "title" => "D", "type" => "richText", "editor" => "blocks"}
          ],
          %{"title" => "Pub v1", "description" => blocks.("Seed published")},
          %{"title" => "Pub draft", "description" => blocks.("Draft text")}
        )

      view = open(c, d, @history <> ",rev=#{d.rev}")

      # The canvas's ops, sent by hand: the server refuses them.
      rev = :sys.get_state(view.pid).socket.assigns.editor_doc.rev

      render_hook(view, "field-block-ops", %{
        "field" => "description",
        "request_id" => "x",
        "if_rev" => rev,
        "ops" => [
          %{
            "op" => "append-block",
            "block" => %{"id" => "h9", "type" => "heading", "level" => 2, "text" => "TYPED"}
          }
        ]
      })

      render_async(view, 5_000)
      refute draft(d).content["description"]["html"] =~ "TYPED"

      # And none is drawn: the revision's value shows, with nothing to type in.
      revision =
        view |> element("[data-pane-editing] fieldset[data-desk-revision-form]") |> render()

      refute revision =~ "bp-fc-wrap-"
      refute revision =~ "bp-paper-canvas"
      assert revision =~ "Seed published"
    end

    test "Paste field, a label, the editor mode and Duplicate write nothing", c do
      d =
        doc!(
          [%{"name" => "summary", "title" => "Summary", "type" => "text"}],
          %{"title" => "Post published", "summary" => "Published sum"},
          %{"title" => "Post draft", "summary" => "Draft sum"}
        )

      view = open(c, d, @history <> ",rev=#{d.rev}")
      before = count(d)
      clip = %{"name" => "from", "sig" => "string", "value" => "PASTED"}

      clip =
        Jason.encode!(%{
          "type" => "sanityClipboardItem",
          "isDocument" => false,
          "schemaTypeName" => "x",
          "value" => "PASTED",
          "barkpark" => %{"kind" => "field", "field" => clip}
        })

      render_hook(
        view,
        "desk-field-paste",
        Map.merge(own_mark(d), %{"field" => "title", "clip" => clip})
      )

      for {event, params} <- [
            {"sidebar-label-add", %{"value" => "x"}},
            {"duplicate-doc", %{}},
            {"autosave", %{"doc" => %{"title" => "Typed in the revision"}}}
          ] do
        render_click(view, event, Map.merge(own_mark(d), params))
      end

      render_async(view, 5_000)
      stored = draft(d)
      assert stored.title == "Post draft"
      assert stored.content["summary"] == "Draft sum"
      assert count(d) == before
    end
  end

  describe "the header menu while a revision is shown" do
    test "offers no write, and Publish or Discard pressed anyway does nothing", c do
      d =
        doc!(
          [],
          %{"title" => "Post published"},
          %{"title" => "Post draft"}
        )

      view = open(c, d, @history <> ",rev=#{d.rev}")
      menu = ~s([data-pane-editing] [role="menu"][id$="-editor-actions"])
      actions = view |> element(menu) |> render()

      for write <- ~w(publish discard-draft duplicate-doc delete-doc) do
        refute actions =~ ~s(data-desk-doc-action="#{write}"), write
      end

      assert actions =~ ~s(data-desk-doc-action="show-history")
      # Ctrl+Alt+P and Ctrl+Alt+D press these in the pane: there are none.
      refute has_element?(view, ~s([data-pane-editing] [data-desk-doc-action="publish"]))
      refute has_element?(view, ~s([data-pane-editing] [data-desk-doc-action="delete-doc"]))

      EditorPost.press(view, "publish", %{})
      EditorPost.press(view, "discard-draft", %{})
      EditorPost.press(view, "confirm-discard", %{})
      render_async(view, 5_000)

      assert published(d).title == "Post published"
      assert draft(d).title == "Post draft"
    end

    test "Confirm gives the focus to the header's menu button", c do
      d = doc!([], %{"title" => "Post published"}, %{"title" => "Post draft"})
      view = open(c, d, @history <> ",rev=#{d.rev}")
      confirm = view |> element("[data-desk-revert-confirm]") |> render()
      # An attribute selector: the id has a colon, which a `#id` selector refuses.
      assert confirm =~ ~r/restore-revision.*focus.*\[id=.*-editor-actions-button/
    end
  end

  test "History names a signed-in author as the REST history does", c do
    d = doc!([], %{"title" => "Post published"}, %{"title" => "Post draft"})
    email = "hist-#{System.unique_integer([:positive])}@example.com"
    user = Barkpark.AccountsFixtures.register_user(email)
    {:ok, user} = Barkpark.Accounts.update_display_name(user, %{display_name: "Grace Hopper"})

    Barkpark.Content.Broadcast.save_revision(
      draft(d),
      d.type,
      @dataset,
      "update",
      to_string(user.id),
      %{actor_kind: "user", actor_id: to_string(user.id), actor_label: nil}
    )

    view = open(c, d)

    list =
      view |> element(~s([data-pane-editing] ul[aria-label="Document revisions"])) |> render()

    assert list =~ ~s(aria-label="Grace Hopper Edited)
  end
end
