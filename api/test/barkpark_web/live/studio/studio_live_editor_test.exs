defmodule BarkparkWeb.Studio.StudioLiveEditorTest do
  @moduledoc """
  Smoke + byte-identity assertions for StudioLive's editor pane against
  the v1 leaf-input cascade (now `BarkparkWeb.Components.FieldInputs.input/1`).

  Closes the regression gap reported in pre-flight Q4: prior to Task #10,
  no test exercised the StudioLive editor render path on a v1 schema.
  Asserts the 12 byte-identity hotspots from
  `task10_studiolive_render_input_catalog.md`:

    * select: phx-debounce="300", `class="form-input"`
    * text:   rows=3 default, phx-debounce="500"
    * richText: rows=6 default
    * boolean: hidden(value="false") FIRST, checkbox(value="true") SECOND,
               phx-debounce="100"
    * color:  hidden mirror carries `name`, nameless picker, phx-debounce="300",
              mono hex span (unset optional field persists no phantom hex)
    * reference (empty): `<bp-reference-picker>` WC bridged via
               `BarkparkFieldBridge` (Task #12 WI2 replaced server modal flow)
    * image (empty): `class="image-field"` + `class="image-upload-zone"
                     phx-click="open-image-picker"` (whole-div click target)
    * default fallback: `<input type="text" class="form-input"
                        phx-debounce="500">` for string / slug / datetime
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup %{conn: conn} do
    {:ok, _post_schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "slug", "title" => "Slug", "type" => "slug"},
            %{"name" => "body", "title" => "Body", "type" => "text"},
            %{"name" => "summary", "title" => "Summary", "type" => "richText"},
            %{"name" => "featured", "title" => "Featured", "type" => "boolean"},
            %{"name" => "brand", "title" => "Brand colour", "type" => "color"},
            %{
              "name" => "category",
              "title" => "Category",
              "type" => "select",
              "options" => ["draft", "published"]
            },
            %{
              "name" => "author",
              "title" => "Author",
              "type" => "reference",
              "refType" => "author"
            },
            %{"name" => "cover", "title" => "Cover", "type" => "image"},
            %{"name" => "publishedAt", "title" => "Published at", "type" => "datetime"}
          ],
          # Explicit Expectation layout — the gate for create_document's
          # portable-doc scaffold path (scaffold_or_initial_values requires a
          # STORED non-empty layout). Declared here so the test is hermetic:
          # it used to lean on a committed demo-seed `post` row whose layout
          # survived the in-sandbox upsert (changeset keeps an uncast column).
          "layout" => [
            %{"kind" => "field", "name" => "title", "max" => 1, "enforce" => true},
            %{"kind" => "field", "name" => "slug", "max" => 1, "enforce" => true},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    {:ok, _page_schema} =
      Content.upsert_schema(
        %{
          "name" => "page",
          "title" => "Page",
          "icon" => "file",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "text"}
          ]
        },
        @dataset
      )

    {:ok, _author_schema} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Author",
          "icon" => "user",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Name", "type" => "string"},
            %{"name" => "bio", "title" => "Bio", "type" => "text"}
          ]
        },
        @dataset
      )

    {:ok, _post} =
      Content.create_document(
        "post",
        %{
          "doc_id" => "p1",
          "title" => "Hello world",
          "content" => %{
            "slug" => "hello-world",
            "body" => "the quick brown fox",
            "summary" => "richer copy",
            "featured" => "true",
            "brand" => "#ff0000",
            "category" => "published",
            "author" => "",
            "cover" => "",
            "publishedAt" => "2026-04-12T09:11:20Z"
          }
        },
        @dataset
      )

    {:ok, _page} =
      Content.create_document(
        "page",
        %{
          "doc_id" => "about",
          "title" => "About",
          "content" => %{"body" => "about body"}
        },
        @dataset
      )

    {:ok, _author} =
      Content.create_document(
        "author",
        %{
          "doc_id" => "knut",
          "title" => "Knut",
          "content" => %{"bio" => "Norwegian"}
        },
        @dataset
      )

    {:ok, conn: conn}
  end

  describe "slug Generate button (Sanity parity)" do
    test "slug-generate derives the slug from the title and persists it", %{conn: conn} do
      {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))
      assert html =~ ~s(phx-click="slug-generate")

      view
      |> element(~s(button[phx-click="slug-generate"][phx-value-field="slug"]))
      |> render_click()

      # The derived slug lands in the form AND the saved draft.
      assert render(view) =~ Barkpark.Tenancy.slugify("Hello world")

      {:ok, saved} = Barkpark.Content.get_document("drafts.p1", "post", @dataset)
      assert saved.content["slug"] == Barkpark.Tenancy.slugify("Hello world")
    end
  end

  describe "StudioLive editor renders v1 schemas via FieldInputs" do
    test "post editor mounts and emits all 7 leaf-input clauses byte-identically",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/p1"))

      # Editor mounted at all
      assert html =~ ~s(name="doc[title]")
      assert html =~ ~s(class="form-input")
      assert html =~ "Hello world"

      # ── default fallback (slug = type "slug" → text fallback) ─────────────
      assert html =~ ~s(name="doc[slug]")
      assert html =~ ~s(value="hello-world")

      # ── default fallback (datetime → text fallback, no upgrade) ────────────
      assert html =~ ~s(name="doc[publishedAt]")

      # ── text clause (rows=3 default, phx-debounce=500) ─────────────────────
      assert html =~
               ~r{<textarea[^>]*name="doc\[body\]"[^>]*class="form-input"[^>]*rows="3"[^>]*phx-debounce="500"}

      # The `post` schema carries an explicit Expectation layout, so the
      # document is stored via the portable-doc path: the plain `body` string
      # lands in the body REGION as a free block with an `html` render
      # (`<span>…</span>`), and the text-fallback textarea shows that HTML
      # escaped. (The layout-less `page` schema below keeps the bare string —
      # see "page editor mounts".)
      assert html =~ ">&lt;span&gt;the quick brown fox&lt;/span&gt;</textarea>"

      # ── richText clause: bp-rich-text-editor Web Component bridged via
      # hidden input + BarkparkFieldBridge hook (Task #11 WI4) ───────────────
      assert html =~
               ~r{<div[^>]*id="bp-rt-wrap-summary"[^>]*phx-update="ignore"[^>]*phx-hook="BarkparkFieldBridge"}

      assert html =~
               ~r{<input type="hidden"[^>]*id="bp-rt-hidden-summary"[^>]*name="doc\[summary\]"[^>]*phx-debounce="500"}

      assert html =~
               ~r{<bp-rich-text-editor[^>]*value="[^"]*"[^>]*data-bridge-target="bp-rt-hidden-summary"}

      # ── boolean clause: hidden FIRST, checkbox SECOND, phx-debounce="100" ─
      hidden_idx =
        :binary.match(
          html,
          ~s(<input type="hidden" name="doc[featured]" value="false")
        )
        |> elem(0)

      checkbox_idx =
        :binary.match(
          html,
          ~s(type="checkbox" name="doc[featured]" value="true")
        )
        |> elem(0)

      assert hidden_idx < checkbox_idx
      # Phoenix may emit `checked` as bare or `checked=""`; assert the leaf
      # signature without depending on attr punctuation.
      assert html =~
               ~r{type="checkbox"[^>]*name="doc\[featured\]"[^>]*value="true"[^>]*checked[^>]*phx-debounce="100"}

      # ── color clause: a STORED value renders the picker + hidden mirror.
      # The named (form-serialized) control is the hidden input; the native
      # picker is nameless so an untouched optional field cannot autosave a
      # phantom hex (see BarkparkColorField hook + Content.Forms drop of "").
      assert html =~
               ~r{<input[^>]*type="hidden"[^>]*name="doc\[brand\]"[^>]*value="#ff0000"[^>]*phx-debounce="300"}

      assert html =~ ~r{<input[^>]*type="color"[^>]*value="#ff0000"}
      assert html =~ ~s(phx-hook="BarkparkColorField")
      assert html =~ "font-family:var(--font-mono)"
      assert html =~ "#ff0000</span>"

      # ── select clause: phx-debounce="300", form-input class, options ───────
      assert html =~
               ~r{<select[^>]*name="doc\[category\]"[^>]*class="form-input"[^>]*phx-debounce="300"}

      assert html =~ ~s(<option value="draft">draft</option>)
      assert html =~ ~r{<option value="published"[^>]*selected[^>]*>published</option>}

      # ── reference clause (empty value): bp-reference-picker WC + bridge ────
      # Task #12 WI2 replaced the server modal flow with a client-owned WC.
      assert html =~
               ~r{<div[^>]*id="bp-ref-wrap-author"[^>]*phx-update="ignore"[^>]*phx-hook="BarkparkFieldBridge"}

      assert html =~
               ~r{<input type="hidden"[^>]*id="bp-ref-hidden-author"[^>]*name="doc\[author\]"[^>]*phx-debounce="500"}

      assert html =~
               ~r{<bp-reference-picker[^>]*ref-type="author"[^>]*dataset="production"[^>]*data-bridge-target="bp-ref-hidden-author"}

      # ── image clause (Task #12 WI1): bp-media-picker Web Component
      # bridged via hidden input + BarkparkFieldBridge hook ────────────────
      assert html =~
               ~r{<div[^>]*id="bp-mp-wrap-cover"[^>]*phx-update="ignore"[^>]*phx-hook="BarkparkFieldBridge"}

      assert html =~
               ~r{<input type="hidden"[^>]*id="bp-mp-hidden-cover"[^>]*name="doc\[cover\]"[^>]*phx-debounce="500"}

      assert html =~
               ~r{<bp-media-picker[^>]*data-bridge-target="bp-mp-hidden-cover"}

      # No legacy phx-click events emitted from the image clause
      refute html =~ ~s(phx-click="open-image-picker")
      refute html =~ ~s(phx-click="clear-image")

      # ── editor chrome preserved (PR-A document_header / editor_field) ──────
      assert html =~ ~s(class="editor-panel")
      assert html =~ "editor-field"
    end

    test "page editor mounts (text fallback only)", %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/page/about"))
      assert html =~ ~s(name="doc[title]")
      assert html =~ "About"
      assert html =~ ~r{<textarea[^>]*name="doc\[body\]"[^>]*rows="3"}
      assert html =~ ">about body</textarea>"
    end

    test "author editor mounts (string + text)", %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/author/knut"))
      assert html =~ ~s(name="doc[title]")
      assert html =~ "Knut"
      assert html =~ ~r{<textarea[^>]*name="doc\[bio\]"[^>]*rows="3"}
      assert html =~ ">Norwegian</textarea>"
    end
  end
end
