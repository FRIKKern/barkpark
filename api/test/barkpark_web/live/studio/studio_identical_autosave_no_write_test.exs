defmodule BarkparkWeb.Studio.StudioIdenticalAutosaveNoWriteTest do
  @moduledoc """
  task-512fec7116c519e5 — THE PHANTOM IDENTICAL DRAFT.

  THE SHAPE. On the Gyldendal twin a `drafts.<id>` row appears whose content is
  byte-identical to the published document — lists stay lists, images stay
  objects, zero field diffs — with the published row untouched. Observed twice
  on Forside in September, and a later sweep found two survivors
  (`drafts.pub-10039465`, `drafts.pub-10040418`), both publications. So the
  shape is NOT confined to frontpage, and no keystroke is known to have caused
  any of them.

  WHY IT MATTERS EVEN THOUGH IT IS IDENTICAL. It puts the document in "draft"
  state in every desk and every editor's eye, and it would carry a future
  serialisation regression into the store the moment one lands.

  WHAT THIS SUITE PINS. `Shared.do_autosave/2` — the ONE chokepoint every
  Classic-editor write funnels through (`Fields.autosave/2` from
  `phx-change="autosave"`, `Fields.save/2`, the slug-derive and array-op arms,
  and `Lifecycle.autosave_form/2` from the `{:autosave_form, …}` handle_info) —
  must write NOTHING when the posted form carries nothing the stored document
  does not already hold.

  THE COMPARISON, AND WHY THIS ONE. The check normalises BOTH sides through
  `Forms.coerce_params/2`, the same function the write path already applies to
  the posted params before persisting, and derives the stored side with
  `Forms.doc_to_form/2` — the very function that produced the form the browser
  is now posting back. Comparing raw params against `doc.content` would be
  wrong in both directions: an `image` value rides to the browser as a JSON
  STRING and comes back as one, while the stored value is a MAP, and a
  `richText` body projects to a map in content but to an HTML string in the
  form. Normalising both sides with the writer's own pair removes exactly those
  differences and no others.

  ONE-SIDED ON PURPOSE. Only keys the form actually posted are compared, and a
  key the stored projection does not carry counts as a DIFFERENCE. A partial
  post (the slug-derive arm posts a single field) is therefore judged on what
  it posts, and anything unrecognised falls through to the write.

  `async: false` — these mounts share the seeded Default workspace.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.DraftId

  @dataset "production"

  # A document shaped like the twin's Forside: an array of maps that must stay
  # a LIST, an image that must stay an OBJECT, and plain scalars.
  @seed_content %{
    "body" => "Velkommen til forsiden",
    "cover" => %{
      "url" => "https://cdn.example.test/forside.jpg",
      "assetId" => "image-abc123",
      "alt" => "Forsidebilde"
    },
    "featuredPublications" => ["pub-10039465", "pub-10040418"]
  }

  setup do
    seed_schema!()
    :ok
  end

  defp seed_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "frontpage",
          "title" => "Forside",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "text"},
            %{"name" => "cover", "title" => "Cover", "type" => "image"},
            %{
              "name" => "featuredPublications",
              "title" => "Featured",
              # `arrayOf` with a MAP `of` — the shape `coerce_field_value/2`
              # actually dispatches on. A `"type" => "array"` declaration is
              # invisible to it and the index-keyed post is stored as a map.
              "type" => "arrayOf",
              "of" => %{"type" => "reference"}
            }
          ]
        },
        @dataset
      )
  end

  # Seed the doc as a DRAFT, then publish it, so the store is in the state the
  # twin was in when a phantom appeared: a published row and NO draft row.
  defp seed_published!(doc_id) do
    {:ok, _} =
      Content.upsert_document(
        "frontpage",
        %{
          "doc_id" => DraftId.draft_id(doc_id),
          "title" => "Forside",
          "content" => @seed_content
        },
        @dataset,
        source: :api
      )

    {:ok, _} = Content.publish_document(doc_id, "frontpage", @dataset, source: :api)
    :ok
  end

  defp draft_row(doc_id) do
    case Content.get_document(DraftId.draft_id(doc_id), "frontpage", @dataset) do
      {:ok, doc} -> doc
      _ -> :no_draft
    end
  end

  defp published_content(doc_id) do
    case Content.get_document(DraftId.published_id(doc_id), "frontpage", @dataset) do
      {:ok, doc} -> doc.content
      _ -> :absent
    end
  end

  defp editor_conn! do
    raw = "identical-autosave-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(
        raw,
        "identical-autosave",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    build_conn() |> Plug.Test.init_test_session(%{"api_token" => raw})
  end

  defp open!(doc_id) do
    {:ok, view, _html} =
      live(editor_conn!(), scoped_studio("/d/#{@dataset}/studio/frontpage/#{doc_id}"))

    view
  end

  # THE FORM THE BROWSER HOLDS. Read off the live socket rather than
  # hand-written, because the whole defect is "the browser posted back exactly
  # what the editor handed it". A hand-written map would be a guess at that
  # shape and could pass while the real one still writes.
  defp editor_form(view), do: :sys.get_state(view.pid).socket.assigns.editor_form

  # THE BROWSER'S SERIALISATION. `Plug.Conn.Query`'s bracket encoding has no
  # representation for a list of multi-key maps: an array field renders its rows
  # as `doc[featuredPublications][0][_ref]`, so what arrives server-side is an
  # INDEX-KEYED MAP (Gyldendal friction 65/66 — the same shape
  # `Forms.coerce_params/2` exists to coerce back). Posting the socket's own
  # list verbatim would test a payload production never sends.
  defp wire(%{} = map), do: Map.new(map, fn {k, v} -> {k, wire(v)} end)

  defp wire(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Map.new(fn {v, i} -> {Integer.to_string(i), wire(v)} end)
  end

  defp wire(other), do: other

  describe "an autosave that posts the form UNCHANGED" do
    test "writes no draft row" do
      doc_id = "phantom-forside-#{System.unique_integer([:positive])}"
      seed_published!(doc_id)

      # PRECONDITION, ASSERTED — not assumed. If a draft already existed the
      # run below could not tell a phantom from the fixture.
      assert draft_row(doc_id) == :no_draft

      view = open!(doc_id)
      form = editor_form(view)

      # POSITIVE CONTROL ON THE READ: the form is non-empty and carries the
      # shapes the row is about, so "no write" below cannot come from an empty
      # post that never had anything to compare.
      assert map_size(form) > 0
      assert Map.has_key?(form, "cover")
      assert Map.has_key?(form, "featuredPublications")

      render_change(view, "autosave", %{"doc" => wire(form)})

      assert draft_row(doc_id) == :no_draft,
             "an autosave identical to the published document created a draft row"

      assert published_content(doc_id) == @seed_content
    end

    test "writes no draft row on a SECOND identical autosave either" do
      doc_id = "phantom-forside-twice-#{System.unique_integer([:positive])}"
      seed_published!(doc_id)
      view = open!(doc_id)
      form = editor_form(view)

      render_change(view, "autosave", %{"doc" => wire(form)})
      render_change(view, "autosave", %{"doc" => wire(form)})

      assert draft_row(doc_id) == :no_draft
    end
  end

  describe "the flight recorder (crit 0)" do
    test "one line per autosave naming socket, trigger, param count and changed" do
      # `config/test.exs` pins the primary level at `:warning`, which filters an
      # `:info` line before any capture device sees it. Prod runs at `:info`,
      # which is the level this line is FOR, so the test raises the primary
      # level for its own duration rather than lowering the line to `:debug` and
      # pinning a severity production would never emit.
      prev_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      doc_id = "logged-#{System.unique_integer([:positive])}"
      seed_published!(doc_id)
      view = open!(doc_id)
      form = editor_form(view)

      unchanged =
        ExUnit.CaptureLog.capture_log(fn ->
          render_change(view, "autosave", %{"doc" => wire(form)})
        end)

      changed =
        ExUnit.CaptureLog.capture_log(fn ->
          render_change(view, "autosave", %{
            "doc" => wire(Map.put(form, "body", "endret"))
          })
        end)

      # Both arms, in ONE read. A single-arm assertion cannot tell a correct
      # `changed=false` from a line that says `false` unconditionally — the
      # uniform-verdict trap. These two posts differ in exactly one field.
      assert unchanged =~ "studio.autosave "
      assert unchanged =~ "trigger=change"
      assert unchanged =~ "type=\"frontpage\""
      assert unchanged =~ "doc_id=\"#{doc_id}\""
      assert unchanged =~ "changed=false"

      assert changed =~ "trigger=change"
      assert changed =~ "changed=true"

      # The socket id is the field that lets an operator tie a phantom to a
      # tab; assert it is a real id, not the literal "nil".
      assert Regex.match?(~r/socket="phx-[^"]+"/, unchanged)

      # The param count moves with the post, so it is not a constant.
      assert unchanged =~ "params=#{map_size(form)}"
    end
  end

  describe "the control — a REAL edit still writes" do
    test "a changed field creates the draft" do
      doc_id = "real-edit-#{System.unique_integer([:positive])}"
      seed_published!(doc_id)
      view = open!(doc_id)
      form = editor_form(view)

      render_change(view, "autosave", %{
        "doc" => wire(Map.put(form, "body", "Velkommen til forsiden — REDIGERT"))
      })

      doc = draft_row(doc_id)

      refute doc == :no_draft,
             "a real edit did not reach the store — the no-write check is over-firing"

      assert doc.content["body"] == "Velkommen til forsiden — REDIGERT"

      # The shapes survive the write that DID happen: lists stay lists, images
      # stay objects. Without this the control could pass while the very
      # serialisation the row worries about had already regressed.
      assert is_list(doc.content["featuredPublications"])
      assert is_map(doc.content["cover"])
    end

    test "a changed TITLE creates the draft" do
      doc_id = "real-title-#{System.unique_integer([:positive])}"
      seed_published!(doc_id)
      view = open!(doc_id)
      form = editor_form(view)

      render_change(view, "autosave", %{"doc" => wire(Map.put(form, "title", "Forsiden 2"))})

      doc = draft_row(doc_id)
      refute doc == :no_draft
      assert doc.title == "Forsiden 2"
    end
  end
end
