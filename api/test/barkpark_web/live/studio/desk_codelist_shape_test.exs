defmodule BarkparkWeb.Studio.DeskCodelistShapeTest do
  @moduledoc """
  task-6617a482448ddb3d (review of #27107): an autosave of a codelist field
  stored whatever it carried. A post made by hand of `doc[subject]`, a
  single-value codelist, stored a list, a map or a 200 KB string, and an
  edit of another field in the same post was stored with it.

  An unknown code is still stored on purpose (task-400a66c6ebd31026): a
  stored document may hold such codes, and Validation shows a warning under
  the field. But a code is one short string. A post from the page of
  anything else for a codelist field now writes nothing for that field, and
  the store keeps what it held; the rest of the post is saved as before.

  The page says so (#27955 review, B2): the field draws the stored value and
  reads "Not saved", in the desk and the old Studio, also after Save. A
  write the server built from a stored value is not read for shape (B1):
  Review changes' Revert puts a stored list back, and a paste never writes a
  codelist at all.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @form "[data-pane-editing] #editor-form"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list_id = "onixedit:desk-shape-#{n}"
    type = "dcs_#{n}"

    {:ok, _} =
      Codelists.register("onixedit", list_id, %{
        issue: "1",
        name: "Subjects",
        values: [
          %{code: "FBA", translations: [%{language: "eng", label: "Modern fiction"}]},
          %{code: "YFB", translations: [%{language: "eng", label: "Children's fiction"}]}
        ]
      })

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Codelist shape #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "subject",
              "title" => "Subject",
              "type" => "codelist",
              "codelistId" => list_id
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "dcs-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Book", "content" => %{"subject" => "FBA", "notes" => "n0"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-shape-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-shape", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     root: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type,
     id: id,
     n: n}
  end

  defp desk(c, extra \\ "") do
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{c.id}#{extra}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content || %{}
  end

  defp send_post(view, subject, notes),
    do: EditorPost.change(view, %{"doc" => %{"subject" => subject, "notes" => notes}})

  for {label, subject} <- [
        {"a list", ["FBA", "YFB"]},
        {"a map", %{"x" => "FBA"}},
        {"a 200 KB string", String.duplicate("F", 200_000)},
        {"a string one past the limit", String.duplicate("F", 65)}
      ] do
    test "a post of #{label} for a codelist writes nothing for it; the rest is saved", c do
      view = desk(c)

      send_post(view, unquote(Macro.escape(subject)), "n1")

      assert eventually(fn -> stored(c)["notes"] == "n1" end)
      assert stored(c)["subject"] == "FBA"
    end
  end

  test "an unknown short code is still stored, and so is one at the limit", c do
    view = desk(c)

    send_post(view, "ZZZ", "n1")
    assert eventually(fn -> stored(c)["subject"] == "ZZZ" end)

    at_limit = String.duplicate("F", 64)
    send_post(view, at_limit, "n2")
    assert eventually(fn -> stored(c)["subject"] == at_limit end)
    assert stored(c)["notes"] == "n2"
  end

  test "a known code is stored, and an empty post still takes the code off", c do
    view = desk(c)

    send_post(view, "YFB", "n1")
    assert eventually(fn -> stored(c)["subject"] == "YFB" end)

    send_post(view, "", "n2")
    assert eventually(fn -> stored(c)["notes"] == "n2" end)
    refute Map.has_key?(stored(c), "subject")
  end

  # ── What the page shows for a post it did not write (B2) ────────────────

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
  defp strip(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()
  defp status(view), do: view |> element("#editor-form .save-status") |> render() |> strip()

  # The words under the subject field, or nil.
  defp mark(view) do
    field = ~s|#editor-form .editor-field:has([name="doc[subject]"])|

    if has_element?(view, "#{field} .field-errors"),
      do: view |> element("#{field} .field-errors") |> render() |> strip(),
      else: nil
  end

  defp input_value(view) do
    html = view |> element(~s|#editor-form input[name="doc[subject]"]|) |> render()

    case Regex.run(~r/\svalue="([^"]*)"/, html) do
      [_, value] -> value
      _ -> nil
    end
  end

  # A flat list of more than 100 codes draws a free-text combobox, in the
  # desk and the old Studio.
  defp long_list(c) do
    list_id = "onixedit:desk-shape-long-#{c.n}"
    type = "dcsl_#{c.n}"

    {:ok, _} =
      Codelists.register("onixedit", list_id, %{
        issue: "1",
        name: "Long",
        values:
          for(
            i <- 1..120,
            do: %{code: "L#{i}", translations: [%{language: "eng", label: "L #{i}"}]}
          )
      })

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Codelist long #{c.n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "subject",
              "title" => "Subject",
              "type" => "codelist",
              "codelistId" => list_id
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "dcsl-#{c.n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Book", "content" => %{"subject" => "L1", "notes" => "n0"}},
        @dataset
      )

    %{c | type: type, id: id}
  end

  defp open(c, :desk), do: desk(c)

  defp open(c, :studio) do
    {:ok, view, _html} = live(c.conn, "#{c.root}/#{c.type}/#{c.id}")
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp type_in(view, doc, target) do
    view
    |> form("#editor-form", %{"doc" => doc})
    |> render_change(%{"_target" => ["doc", target]})
  end

  @typed String.duplicate("x", 70)
  @not_code "Not saved: Not a code (kept as stored)"

  for surface <- [:desk, :studio] do
    test "#{surface}: long text typed into the combobox is not saved, and the page says so", c do
      c = long_list(c)
      view = open(c, unquote(surface))
      assert render(view) =~ ~s(data-codelist-combobox="true")

      type_in(view, %{"subject" => @typed, "notes" => "n1"}, "subject")

      assert eventually(fn -> stored(c)["notes"] == "n1" end)
      assert stored(c)["subject"] == "L1"
      assert assigns(view)[:editor_form]["subject"] == "L1"
      assert input_value(view) == "L1"
      assert mark(view) =~ @not_code
      assert status(view) == "Not saved: Subject"

      # Save, with the typed text still in the browser's input.
      view
      |> form("#editor-form", %{"doc" => %{"subject" => @typed}})
      |> render_submit(EditorPost.marks(view))

      assert stored(c)["subject"] == "L1"
      assert status(view) == "Not saved: Subject"
      assert mark(view) =~ @not_code
      refute Phoenix.Flash.get(assigns(view).flash, :info) == "Saved"

      # A code typed over it is saved, and the words go.
      type_in(view, %{"subject" => "L2"}, "subject")
      assert eventually(fn -> stored(c)["subject"] == "L2" end)
      refute (mark(view) || "") =~ "Not saved"
      refute status(view) =~ "Not saved"
    end
  end

  test "a hand-made list post: the field draws the stored code and reads Not saved", c do
    view = desk(c)

    send_post(view, ["FBA", "YFB"], "n1")

    assert eventually(fn -> stored(c)["notes"] == "n1" end)
    assert stored(c)["subject"] == "FBA"
    assert assigns(view)[:editor_form]["subject"] == "FBA"
    assert mark(view) =~ @not_code
    assert has_element?(view, ~s([data-pane-editing][data-desk-save="Save failed"]))
  end

  # ── Writes the server builds from a stored value (B1) ───────────────────

  # A published document whose subject is a list, and its draft.
  defp published_list(c, draft) do
    id = "dcs-pub-#{c.n}"
    content = %{"subject" => ["A1", "B2"], "notes" => "n0"}

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => content},
        @dataset
      )

    {:ok, _} = Content.publish_document(id, c.type, @dataset)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => Content.draft_id(id), "title" => "Book", "content" => draft},
        @dataset
      )

    %{c | id: id}
  end

  test "Review changes' Revert puts back a published value that is not a code", c do
    c = published_list(c, %{"notes" => "n0"})
    view = desk(c, ",changesInspectorTab=review,inspect=sanity%2Fstructure%2Fhistory")

    mark = Map.take(EditorPost.marks(view), [PostIdentity.key()])
    render_hook(view, "desk-field-revert", Map.merge(mark, %{"field" => "subject"}))

    assert eventually(fn -> stored(c)["subject"] == ["A1", "B2"] end)
    assert stored(c)["notes"] == "n0"
    assert assigns(view)[:save_status] == "Saved"
    refute status(view) =~ "Not saved"
  end

  @toast "desk:field-toast"

  defp pressed(view, params),
    do: Map.merge(Map.take(EditorPost.marks(view), ["_bp_doc"]), params)

  test "Paste field never writes a codelist: a copied list is refused in words", c do
    view = desk(c)
    copied = %{"name" => "subject", "sig" => "codelist", "value" => ["A1", "B2"]}

    clip =
      Jason.encode!(%{
        "type" => "sanityClipboardItem",
        "isDocument" => false,
        "schemaTypeName" => "codelist",
        "value" => ["A1", "B2"],
        "barkpark" => %{"kind" => "field", "field" => copied}
      })

    render_hook(view, "desk-field-paste", pressed(view, %{"field" => "subject", "clip" => clip}))

    assert_push_event(view, @toast, %{
      tone: "critical",
      title: "Invalid clipboard item",
      description: ~s(A field of type "codelist" cannot be pasted into)
    })

    assert stored(c)["subject"] == "FBA"
  end

  test "Paste document writes the fields that fit and leaves a codelist as stored", c do
    view = desk(c)

    clip =
      Jason.encode!(%{
        "type" => "sanityClipboardItem",
        "isDocument" => true,
        "value" => %{},
        "barkpark" => %{
          "kind" => "document",
          "docType" => c.type,
          "fields" => [
            %{"name" => "subject", "sig" => "codelist", "value" => ["A1", "B2"]},
            %{"name" => "notes", "sig" => "string", "value" => "pasted"}
          ]
        }
      })

    render_hook(view, "desk-doc-paste", pressed(view, %{"clip" => clip}))

    assert eventually(fn -> stored(c)["notes"] == "pasted" end)
    assert stored(c)["subject"] == "FBA"
  end
end
