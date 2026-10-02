defmodule Barkpark.FieldShapeCorpus do
  @moduledoc """
  The field-type x stored-shape corpus (Run-4 Lane B).

  One cell per (schema field type, stored shape) that seeds, the API, the SDK
  and Sanity-style imports can put in the store: numbers in string fields,
  objects in scalar fields, offset datetimes, `{_ref}` objects, Portable Text
  lists, nested arrayOf/composite rows, a richText `editor: blocks` field.
  Shared by the save-path matrix
  (`test/barkpark_web/save_path_untouched_field_matrix_test.exs`) and the
  round-trip matrix (`test/barkpark/round_trip_integrity_matrix_test.exs`).

  `cells/0` returns `{name, field declaration (minus name), stored value |
  :absent}`.
  """

  @iso_z "2026-01-01T12:00:00Z"

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
    {"localized_extra_lang", %{"type" => "localizedText", "languages" => ["nob", "eng"]},
     %{"nob" => "Hei", "eng" => "Hi", "deu" => "Hallo"}},
    {"codelist_code", %{"type" => "codelist", "codelistId" => "matrix:none", "version" => "1"},
     "eng"},
    {"comp_select_image",
     %{
       "type" => "composite",
       "fields" => [
         %{"name" => "kind", "type" => "select", "options" => [1, 2]},
         %{"name" => "img", "type" => "image"},
         %{"name" => "flag", "type" => "boolean"}
       ]
     },
     %{
       "kind" => 2,
       "img" => %{
         "_type" => "image",
         "asset" => %{"_ref" => "image-x"},
         "hotspot" => %{"x" => 0.5, "y" => 0.5}
       },
       "flag" => "true"
     }},
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

  @doc "Every corpus cell."
  def cells, do: @cells

  @doc "The schema field list for the corpus (each cell becomes a field)."
  def schema_fields do
    Enum.map(@cells, fn {name, decl, _} -> Map.merge(decl, %{"name" => name, "title" => name}) end)
  end

  @doc "The stored content for the corpus (absent cells left out)."
  def content do
    for {name, _decl, value} <- @cells, value != :absent, into: %{}, do: {name, value}
  end
end
