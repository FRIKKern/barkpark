defmodule BarkparkWeb.SavePathUntouchedFieldMatrixTest do
  @moduledoc """
  THE UNTOUCHED-FIELD PROPERTY, as a matrix (Run-4 Lane B).

  Runs 1–3 fixed the same defect five separate times, one cell at a time: the
  Classic save turned `42` into `"42"`, `true` into `"true"`, erased ISO
  datetimes, stored `arrayOf` rows as index-keyed maps, and rewrote untouched
  `{"_ref": …}` objects to bare strings. Each fix pinned ONE cell. This suite
  pins the whole table so the class cannot come back through a cell nobody
  thought of:

      for every (field type × stored shape) cell
        for every save path
          edit an UNRELATED field (`probe`)
          ⇒ the cell's stored value is byte-identical (`===`, so 1 ≠ 1.0)
            and an absent cell stays absent.

  THE SHAPES are the ones that reach the store without the Classic form: what
  `bp seed`, `/v1/data/mutate`, the JS SDK and Sanity-style imports write —
  numbers in string fields, objects in scalar fields, offset datetimes,
  `{_ref}` objects, Portable Text lists, string-typed numbers and booleans.
  This suite never decides a value contract (reference / richText / slug shape
  are owner rulings); it only demands that what is stored survives an edit of
  something else.

  THE PATHS:

    * `classic_form` — the Studio Classic editor, driven through the RENDERED
      form: `form("#editor-form") |> render_change/2` serialises every input the
      editor actually rendered (hidden pickers, checkbox pairs, array rows), so
      the post is what a browser would send, not a hand-written guess.
    * `classic_form_blocks` — the same, on a document whose block list has
      already been materialised by a Beta edit (the bound-block branch of
      `Forms.classic_save_content`).
    * `beta_editor` — `Content.apply_document_block_op/5` patching the probe's
      bound block on a legacy doc (synthesis on first edit, then projection
      write-back), and a second op on the now-materialised blocks.
    * `rest_patch_set` — `POST /v1/data/mutate` `patch.set` (also what
      `bp doc patch --set` sends: one key, nothing else).
    * `rest_patch_ops` — the compound patch clause (`setIfMissing` + `set`).

  A failure lists EVERY failing cell, not the first, so one red names the
  whole regression.

  `async: false` — the LiveView mounts share the seeded Default workspace.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.DraftId

  @dataset "production"

  @iso_z "2026-01-01T12:00:00Z"

  # {cell name, field declaration (minus name), stored value | :absent}
  @cells [
    # ── string-ish scalars ────────────────────────────────────────────────
    {"string_plain", %{"type" => "string"}, "plain"},
    {"string_int", %{"type" => "string"}, 42},
    {"string_float", %{"type" => "string"}, 4.5},
    {"string_bool", %{"type" => "string"}, true},
    {"string_obj", %{"type" => "string"}, %{"_type" => "slug", "current" => "x"}},
    {"string_list", %{"type" => "string"}, ["a", "b"]},
    {"string_padded", %{"type" => "string"}, "  padded  "},
    {"string_unicode", %{"type" => "string"}, "Ærlig talt — «æøå» 🐕 <b>&amp;</b>"},
    {"string_absent", %{"type" => "string"}, :absent},
    {"text_multiline", %{"type" => "text"}, "line one\nline two\n"},
    {"text_int", %{"type" => "text"}, 7},
    {"url_plain", %{"type" => "url"}, "https://example.com/a?b=c&d=e"},
    {"email_plain", %{"type" => "email"}, "a@b.no"},
    {"date_plain", %{"type" => "date"}, "2026-01-01"},
    # ── number ─────────────────────────────────────────────────────────────
    {"number_int", %{"type" => "number"}, 42},
    {"number_float", %{"type" => "number"}, 4.5},
    {"number_whole_float", %{"type" => "number"}, 2.0},
    {"number_zero", %{"type" => "number"}, 0},
    {"number_negative", %{"type" => "number"}, -3},
    {"number_string", %{"type" => "number"}, "42"},
    {"number_absent", %{"type" => "number"}, :absent},
    # ── boolean ────────────────────────────────────────────────────────────
    {"boolean_true", %{"type" => "boolean"}, true},
    {"boolean_false", %{"type" => "boolean"}, false},
    {"boolean_string", %{"type" => "boolean"}, "true"},
    {"boolean_absent", %{"type" => "boolean"}, :absent},
    # ── datetime ───────────────────────────────────────────────────────────
    {"datetime_z", %{"type" => "datetime"}, @iso_z},
    {"datetime_offset_ms", %{"type" => "datetime"}, "2026-01-01T12:00:00.123+02:00"},
    {"datetime_local", %{"type" => "datetime"}, "2026-01-01T12:00"},
    {"datetime_date_only", %{"type" => "datetime"}, "2026-01-01"},
    {"datetime_garbage", %{"type" => "datetime"}, "soon"},
    # ── slug ───────────────────────────────────────────────────────────────
    {"slug_string", %{"type" => "slug"}, "my-slug"},
    {"slug_object", %{"type" => "slug"}, %{"_type" => "slug", "current" => "my-slug"}},
    # ── reference ──────────────────────────────────────────────────────────
    {"ref_string", %{"type" => "reference", "refType" => "author"}, "author-1"},
    {"ref_object", %{"type" => "reference", "refType" => "author"}, %{"_ref" => "author-1"}},
    {"ref_object_full", %{"type" => "reference", "refType" => "author"},
     %{"_ref" => "author-1", "_type" => "reference", "_weak" => true}},
    {"ref_media", %{"type" => "reference", "refType" => "mediaAsset"}, %{"_ref" => "media-1"}},
    # ── image / file ───────────────────────────────────────────────────────
    {"image_object", %{"type" => "image"},
     %{"url" => "https://cdn.test/a.jpg", "assetId" => "a1", "alt" => "A", "focalX" => 0.5}},
    {"image_url", %{"type" => "image"}, "https://cdn.test/a.jpg"},
    {"image_sanity", %{"type" => "image"},
     %{"_type" => "image", "asset" => %{"_ref" => "image-abc"}}},
    {"file_object", %{"type" => "file"}, %{"url" => "https://cdn.test/f.pdf"}},
    # ── richText ───────────────────────────────────────────────────────────
    {"rich_html", %{"type" => "richText"}, "<p>Hi <strong>there</strong></p>"},
    {"rich_portable_text", %{"type" => "richText"},
     [%{"_type" => "block", "children" => [%{"_type" => "span", "text" => "hi"}]}]},
    # ── select ─────────────────────────────────────────────────────────────
    {"select_valid", %{"type" => "select", "options" => ["a", "b"]}, "b"},
    {"select_invalid", %{"type" => "select", "options" => ["a", "b"]}, "zzz"},
    {"select_numeric", %{"type" => "select", "options" => [1, 2, 3]}, 2},
    {"select_titled", %{"type" => "select", "options" => [%{"value" => "x", "title" => "X"}]},
     "x"},
    {"select_radio", %{"type" => "select", "options" => ["a", "b"], "layout" => "radio"}, "b"},
    {"select_absent", %{"type" => "select", "options" => ["a", "b"]}, :absent},
    # ── color / geopoint ───────────────────────────────────────────────────
    {"color_hex", %{"type" => "color"}, "#ff0000"},
    {"color_object", %{"type" => "color"}, %{"hex" => "#ff0000", "alpha" => 1}},
    {"geopoint", %{"type" => "geopoint"}, %{"lat" => 59.9, "lng" => 10.7}},
    # ── v1 containers ──────────────────────────────────────────────────────
    {"array_v1", %{"type" => "array", "of" => [%{"type" => "string"}]}, ["a", "b"]},
    {"object_v1", %{"type" => "object", "fields" => [%{"name" => "k", "type" => "string"}]},
     %{"k" => "v"}},
    # ── arrayOf of each element type ───────────────────────────────────────
    {"arr_string", %{"type" => "arrayOf", "of" => %{"type" => "string"}}, ["a", "b"]},
    {"arr_empty", %{"type" => "arrayOf", "of" => %{"type" => "string"}}, []},
    {"arr_number", %{"type" => "arrayOf", "of" => %{"type" => "number"}}, [1, 2.5]},
    {"arr_boolean", %{"type" => "arrayOf", "of" => %{"type" => "boolean"}}, [true, false]},
    {"arr_ref_string", %{"type" => "arrayOf", "of" => %{"type" => "reference"}}, ["a1", "a2"]},
    {"arr_ref_object", %{"type" => "arrayOf", "of" => %{"type" => "reference"}},
     [%{"_ref" => "a1", "_key" => "k1"}]},
    {"arr_datetime", %{"type" => "arrayOf", "of" => %{"type" => "datetime"}}, [@iso_z]},
    {"arr_image", %{"type" => "arrayOf", "of" => %{"type" => "image"}},
     [%{"url" => "https://cdn.test/a.jpg", "assetId" => "a1"}]},
    {"arr_composite",
     %{
       "type" => "arrayOf",
       "of" => %{
         "type" => "composite",
         "fields" => [
           %{"name" => "title", "type" => "string"},
           %{"name" => "n", "type" => "number"},
           %{"name" => "flag", "type" => "boolean"}
         ]
       }
     }, [%{"title" => "t", "n" => 3, "flag" => true}]},
    # ── composite ──────────────────────────────────────────────────────────
    {"composite",
     %{
       "type" => "composite",
       "fields" => [
         %{"name" => "s", "type" => "string"},
         %{"name" => "n", "type" => "number"},
         %{"name" => "b", "type" => "boolean"},
         %{"name" => "dt", "type" => "datetime"},
         %{"name" => "img", "type" => "image"},
         %{"name" => "ref", "type" => "reference"}
       ]
     },
     %{
       "s" => "x",
       "n" => 3,
       "b" => true,
       "dt" => @iso_z,
       "img" => %{"url" => "https://cdn.test/a.jpg", "assetId" => "a1"},
       "ref" => %{"_ref" => "author-1"}
     }},
    {"composite_extra_key",
     %{"type" => "composite", "fields" => [%{"name" => "s", "type" => "string"}]},
     %{"s" => "x", "unknown" => "keep me"}},
    # ── localizedText ──────────────────────────────────────────────────────
    {"localized", %{"type" => "localizedText", "languages" => ["nob", "eng"]},
     %{"nob" => "Hei", "eng" => "Hi"}},
    # ── nested shapes ──────────────────────────────────────────────────────
    {"arr_comp_ref",
     %{
       "type" => "arrayOf",
       "of" => %{
         "type" => "composite",
         "fields" => [
           %{"name" => "title", "type" => "string"},
           %{"name" => "ref", "type" => "reference"},
           %{"name" => "n", "type" => "number"}
         ]
       }
     },
     [
       %{"title" => "one", "ref" => %{"_ref" => "a1"}, "n" => 1},
       %{"title" => "two", "ref" => %{"_ref" => "a2", "_key" => "k2"}, "n" => 2.5}
     ]},
    {"comp_nested",
     %{
       "type" => "composite",
       "fields" => [
         %{"name" => "s", "type" => "string"},
         %{
           "name" => "inner",
           "type" => "composite",
           "fields" => [
             %{"name" => "k", "type" => "string"},
             %{"name" => "n", "type" => "number"}
           ]
         }
       ]
     }, %{"s" => "x", "inner" => %{"k" => "v", "n" => 1}}},
    {"comp_number_string",
     %{"type" => "composite", "fields" => [%{"name" => "n", "type" => "number"}]}, %{"n" => "3"}},
    # ── a richText field edited by the block canvas (`editor: blocks`) ──────
    {"rich_canvas", %{"type" => "richText", "editor" => "blocks"},
     %{
       "blocks" => [
         %{
           "id" => "rc-1",
           "type" => "paragraph",
           "content" => [%{"type" => "text", "value" => "canvas"}]
         }
       ],
       "html" => "<p>canvas</p>"
     }}
  ]

  @probe_before "probe before"
  @probe_after "probe after"

  @canvas_before %{
    "blocks" => [
      %{
        "id" => "pc-1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "before"}]
      }
    ],
    "html" => "<p>before</p>"
  }

  defp schema_fields do
    [
      %{"name" => "title", "title" => "Title", "type" => "string"},
      %{"name" => "probe", "title" => "Probe", "type" => "string"},
      %{
        "name" => "probe_canvas",
        "title" => "Probe canvas",
        "type" => "richText",
        "editor" => "blocks"
      }
      | Enum.map(@cells, fn {name, decl, _} ->
          Map.merge(decl, %{"name" => name, "title" => name})
        end)
    ]
  end

  defp seed_content do
    Enum.reduce(@cells, %{"probe" => @probe_before, "probe_canvas" => @canvas_before}, fn
      {_name, _decl, :absent}, acc -> acc
      {name, _decl, value}, acc -> Map.put(acc, name, value)
    end)
  end

  setup do
    type = "matrix#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Matrix",
          "visibility" => "public",
          "fields" => schema_fields()
        },
        @dataset
      )

    raw = "matrix-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(
        raw,
        "matrix",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    %{type: type, token: raw}
  end

  # A legacy (never Beta-edited) draft, written the way the API writes it.
  defp seed_draft!(type) do
    doc_id = "matrix-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_document(
        type,
        %{"doc_id" => DraftId.draft_id(doc_id), "title" => "Matrix", "content" => seed_content()},
        @dataset,
        source: :api
      )

    doc_id
  end

  defp stored(type, doc_id) do
    {:ok, doc} = Content.get_document(DraftId.draft_id(doc_id), type, @dataset)
    doc
  end

  # Every cell whose stored value moved. `===`: 1 and 1.0 are different JSON.
  defp failing_cells(content) do
    for {name, _decl, expected} <- @cells,
        actual = Map.fetch(content, name),
        not same?(expected, actual) do
      {name, expected, actual}
    end
  end

  defp same?(:absent, :error), do: true
  defp same?(:absent, {:ok, nil}), do: false
  defp same?(expected, {:ok, actual}), do: expected === actual
  defp same?(_expected, _actual), do: false

  defp assert_matrix!(path, doc) do
    # POSITIVE CONTROL: the unrelated edit actually landed, so "nothing moved"
    # cannot come from a save that never happened.
    assert doc.content["probe"] == @probe_after, "#{path}: the probe edit did not land"
    assert_cells!(path, doc)
  end

  defp assert_cells!(path, doc) do
    case failing_cells(doc.content) do
      [] ->
        :ok

      fails ->
        lines =
          Enum.map_join(fails, "\n", fn {name, expected, actual} ->
            "  #{name}: stored #{inspect(expected)} → #{inspect(actual)}"
          end)

        flunk(
          "#{path}: editing ONLY `probe` changed #{length(fails)} untouched cell(s):\n#{lines}"
        )
    end
  end

  defp editor_conn(token),
    do: scoped_conn() |> Plug.Test.init_test_session(%{"api_token" => token})

  defp classic_edit_probe!(token, type, doc_id) do
    {:ok, view, _html} =
      live(editor_conn(token), scoped_studio("/d/#{@dataset}/studio/#{type}/#{doc_id}"))

    overrides =
      deep_merge(browser_sanitised(render(view)), %{"doc" => %{"probe" => @probe_after}})

    view
    |> form("#editor-form")
    |> render_change(overrides)

    view
  end

  # THE BROWSER'S VALUE SANITISATION. `LiveViewTest.form/2` posts each input's
  # `value` ATTRIBUTE verbatim; a browser first runs the HTML value
  # sanitisation algorithm on it. A `datetime-local` whose value is not a
  # valid local datetime posts "" (that is how an offset ISO datetime was
  # erased in Run 2), a `color` posts `#000000` unless the value is a valid
  # simple colour, and a single-line text input strips newlines. Every input
  # whose posted value a browser would CHANGE is returned as an override, so
  # this suite tests what a browser sends, not what the test driver sends.
  defp browser_sanitised(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#editor-form input[name]")
    |> Enum.reject(fn el -> LazyHTML.attribute(el, "disabled") != [] end)
    |> Enum.flat_map(fn el ->
      name = attr(el, "name")
      value = attr(el, "value") || ""
      type = attr(el, "type") || "text"

      case sanitise(type, value) do
        ^value -> []
        posted -> [{name, posted}]
      end
    end)
    |> Enum.reduce(%{}, fn {name, posted}, acc ->
      deep_merge(acc, Plug.Conn.Query.decode(URI.encode_query([{name, posted}])))
    end)
  end

  defp attr(el, name), do: el |> LazyHTML.attribute(name) |> List.first()

  defp sanitise("datetime-local", v) do
    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?$/, v),
      do: v,
      else: ""
  end

  defp sanitise("color", v) do
    if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, v), do: String.downcase(v), else: "#000000"
  end

  defp sanitise(t, v) when t in ["text", "search", "url", "tel", "email", "password"],
    do: String.replace(v, ["\r", "\n"], "")

  defp sanitise(_type, v), do: v

  defp deep_merge(%{} = a, %{} = b), do: Map.merge(a, b, fn _k, x, y -> deep_merge(x, y) end)
  defp deep_merge(_a, b), do: b

  describe "Studio Classic form — rendered form, edit only `probe`" do
    test "every untouched cell is byte-identical", %{type: type, token: token} do
      doc_id = seed_draft!(type)
      classic_edit_probe!(token, type, doc_id)
      assert_matrix!("classic_form", stored(type, doc_id))
    end

    test "on a doc whose blocks a Beta edit materialised", %{type: type, token: token} do
      doc_id = seed_draft!(type)
      materialise_blocks!(type, doc_id)
      assert is_list(stored(type, doc_id).content["blocks"])

      classic_edit_probe!(token, type, doc_id)
      assert_matrix!("classic_form_blocks", stored(type, doc_id))
    end
  end

  describe "Studio Classic form — the rule is not a freeze (edits still land)" do
    # The other arm. A preservation rule that answered "untouched" for
    # everything would pass the matrix and silently drop every real edit.
    test "an edited field is written; an untouched sibling inside the same composite keeps its shape",
         %{type: type, token: token} do
      doc_id = seed_draft!(type)

      {:ok, view, _html} =
        live(editor_conn(token), scoped_studio("/d/#{@dataset}/studio/#{type}/#{doc_id}"))

      overrides =
        deep_merge(browser_sanitised(render(view)), %{
          "doc" => %{
            "probe" => @probe_after,
            "boolean_true" => "false",
            "number_string" => "43",
            "string_plain" => "edited"
          },
          # Composite subfields render as `doc[composite].s` — a dot segment
          # Plug leaves as a flat key; `Fields.autosave` folds it back in.
          "doc[composite].s" => "y"
        })

      view |> form("#editor-form") |> render_change(overrides)

      content = stored(type, doc_id).content
      assert content["boolean_true"] === false
      assert content["number_string"] === 43
      assert content["string_plain"] == "edited"

      # The composite WAS edited (s) — its untouched subfields keep their stored
      # shapes: the `{_ref}` object, the number, the image map.
      assert content["composite"]["s"] == "y"
      assert content["composite"]["ref"] === %{"_ref" => "author-1"}
      assert content["composite"]["n"] === 3
      assert content["composite"]["b"] === true
      # The datetime subfield's input is a `datetime-local`: a browser posts ""
      # for an ISO value with an offset unless the input was handed a value it
      # can show. Untouched, it must survive with its offset and seconds.
      assert content["composite"]["dt"] === @iso_z

      assert content["composite"]["img"] === %{
               "url" => "https://cdn.test/a.jpg",
               "assetId" => "a1"
             }
    end

    test "an explicit Save (phx-submit) of the untouched form keeps every cell",
         %{type: type, token: token} do
      doc_id = seed_draft!(type)

      {:ok, view, _html} =
        live(editor_conn(token), scoped_studio("/d/#{@dataset}/studio/#{type}/#{doc_id}"))

      overrides =
        deep_merge(browser_sanitised(render(view)), %{"doc" => %{"probe" => @probe_after}})

      view |> form("#editor-form") |> render_submit(overrides)

      assert_matrix!("classic_submit", stored(type, doc_id))
    end
  end

  # A Beta op that rewrites the probe's bound block to its own value — the
  # first Beta edit materialises the synthesized block list.
  defp materialise_blocks!(type, doc_id) do
    beta_patch_probe!(type, doc_id, @probe_before)
  end

  defp beta_patch_probe!(type, doc_id, value) do
    doc = stored(type, doc_id)
    {blocks, _synth?} = Content.resolve_blocks_for_edit(doc, type, @dataset)
    probe = Enum.find(blocks, &(&1["fieldName"] == "probe"))
    assert probe, "the probe has no bound block"

    op = %{"op" => "patch-block", "id" => probe["id"], "patch" => %{"value" => value}}
    {:ok, _} = Content.apply_document_block_op(DraftId.draft_id(doc_id), type, op, @dataset)
  end

  describe "Beta editor — block op on the probe's bound block" do
    test "first edit (synthesis → projection write-back)", %{type: type} do
      doc_id = seed_draft!(type)
      beta_patch_probe!(type, doc_id, @probe_after)
      assert_matrix!("beta_editor_first", stored(type, doc_id))
    end

    test "a later edit on materialised blocks", %{type: type} do
      doc_id = seed_draft!(type)
      materialise_blocks!(type, doc_id)
      beta_patch_probe!(type, doc_id, @probe_after)
      assert_matrix!("beta_editor_second", stored(type, doc_id))
    end
  end

  defp mutate!(token, mutation) do
    conn =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => [mutation]}))

    assert conn.status == 200, "mutate refused: #{conn.status} #{conn.resp_body}"
  end

  describe "Field canvas — a block op on a richText `editor: blocks` field" do
    # `apply_field_block_ops/6` is the save path of the per-field canvas: it
    # rewrites `content[field]` and must touch nothing else.
    test "editing `probe_canvas` leaves every cell byte-identical", %{type: type} do
      doc_id = seed_draft!(type)

      op = %{
        "op" => "patch-block",
        "id" => "pc-1",
        "patch" => %{"content" => [%{"type" => "text", "value" => "after"}]}
      }

      {:ok, _} =
        Content.apply_field_block_ops(
          DraftId.draft_id(doc_id),
          type,
          "probe_canvas",
          [op],
          @dataset
        )

      doc = stored(type, doc_id)
      assert doc.content["probe_canvas"]["html"] =~ "after", "the canvas edit did not land"
      assert doc.content["probe"] == @probe_before
      assert_cells!("field_canvas", doc)
    end
  end

  describe "Studio Classic form — one row of an arrayOf-of-composite edited" do
    test "the edited row's untouched subfields and the untouched row keep their shapes",
         %{type: type, token: token} do
      doc_id = seed_draft!(type)

      {:ok, view, _html} =
        live(editor_conn(token), scoped_studio("/d/#{@dataset}/studio/#{type}/#{doc_id}"))

      overrides =
        deep_merge(browser_sanitised(render(view)), %{
          "doc" => %{"probe" => @probe_after},
          "doc[arr_comp_ref][0].title" => "one — edited"
        })

      view |> form("#editor-form") |> render_change(overrides)

      rows = stored(type, doc_id).content["arr_comp_ref"]

      assert [
               %{"title" => "one — edited", "ref" => %{"_ref" => "a1"}, "n" => 1},
               %{"title" => "two", "ref" => %{"_ref" => "a2", "_key" => "k2"}, "n" => 2.5}
             ] === rows
    end
  end

  describe "REST /v1/data/mutate patch (also `bp doc patch --set`)" do
    test "patch.set of only `probe`", %{type: type, token: token} do
      doc_id = seed_draft!(type)

      mutate!(token, %{
        "patch" => %{
          "id" => DraftId.draft_id(doc_id),
          "type" => type,
          "set" => %{"probe" => @probe_after}
        }
      })

      assert_matrix!("rest_patch_set", stored(type, doc_id))
    end

    test "compound patch (setIfMissing + set)", %{type: type, token: token} do
      doc_id = seed_draft!(type)

      mutate!(token, %{
        "patch" => %{
          "id" => DraftId.draft_id(doc_id),
          "type" => type,
          "setIfMissing" => %{"probe" => "ignored — present"},
          "set" => %{"probe" => @probe_after}
        }
      })

      assert_matrix!("rest_patch_ops", stored(type, doc_id))
    end

    test "patch.set on a doc whose blocks a Beta edit materialised", %{type: type, token: token} do
      doc_id = seed_draft!(type)
      materialise_blocks!(type, doc_id)

      mutate!(token, %{
        "patch" => %{
          "id" => DraftId.draft_id(doc_id),
          "type" => type,
          "set" => %{"probe" => @probe_after}
        }
      })

      assert_matrix!("rest_patch_set_blocks", stored(type, doc_id))
    end
  end
end
