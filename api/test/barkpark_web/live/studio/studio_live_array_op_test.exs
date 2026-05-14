defmodule BarkparkWeb.Studio.StudioLiveArrayOpTest do
  @moduledoc """
  Coverage for the path-based array_op machinery in StudioLive
  (commit `0901066` — nested-arrayOf fix). Two layers:

    1. Pure unit tests for the path helpers — `parse_path/1`,
       `find_field_by_path/2`, `put_value_at/3`, `list_value_at/2`,
       `empty_for_of/1`. The helpers were exposed as `@doc false def`
       specifically so this file can call them without spinning up a
       full LiveView for each parse case.

    2. Integration tests against the live `array_op` handler — set up
       a real `post`-style schema (extended with an arrayOf and a
       composite > arrayOf) plus a draft document in the sandbox DB,
       hand-build a socket with the matching editor assigns, and call
       `StudioLive.handle_event/3` directly. The returned socket's
       `editor_form` is the source of truth.

  The handler-direct call sidesteps the Structure-tree walk needed by a
  full `live/2` mount — Structure only surfaces the seeded schema
  names (`post`, `page`, etc.), so an arbitrary `tagdoc` type would
  fail to route. Calling the handler directly keeps the test focused
  on `array_op` itself, not the pane builder.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive

  @dataset "production"

  # ── Pure unit tests: parse_path/1 ───────────────────────────────────────

  describe "parse_path/1" do
    test "single bracket → [key]" do
      assert StudioLive.parse_path("doc[a]") == ["a"]
    end

    test "two brackets → [a, b]" do
      assert StudioLive.parse_path("doc[a][b]") == ["a", "b"]
    end

    test "mixed bracket + dot → [a, b]" do
      assert StudioLive.parse_path("doc[a].b") == ["a", "b"]
    end

    test "numeric row index is dropped" do
      assert StudioLive.parse_path("doc[a][0].b") == ["a", "b"]
    end

    test "deeper dot chain → [a, b, c]" do
      assert StudioLive.parse_path("doc[a].b.c") == ["a", "b", "c"]
    end

    test "empty string → []" do
      assert StudioLive.parse_path("") == []
    end

    test "non-doc-prefixed garbage → []" do
      assert StudioLive.parse_path("garbage") == []
    end

    test "malformed `doc[]` (empty key) → []" do
      assert StudioLive.parse_path("doc[]") == []
    end

    test "nil → []" do
      assert StudioLive.parse_path(nil) == []
    end
  end

  # ── Pure unit tests: find_field_by_path/2 ──────────────────────────────

  describe "find_field_by_path/2" do
    setup do
      schema = %{
        fields: [
          %{"name" => "tags", "type" => "arrayOf", "of" => %{"type" => "string"}},
          %{
            "name" => "publisher",
            "type" => "composite",
            "fields" => [
              %{"name" => "name", "type" => "string"},
              %{
                "name" => "imprints",
                "type" => "arrayOf",
                "of" => %{"type" => "string"}
              }
            ]
          }
        ]
      }

      socket = %Phoenix.LiveView.Socket{assigns: %{editor_schema: schema, __changed__: %{}}}
      {:ok, socket: socket}
    end

    test "finds top-level arrayOf", %{socket: socket} do
      assert %{"name" => "tags", "type" => "arrayOf"} =
               StudioLive.find_field_by_path(socket, ["tags"])
    end

    test "descends composite → arrayOf transparently", %{socket: socket} do
      assert %{"name" => "imprints", "type" => "arrayOf"} =
               StudioLive.find_field_by_path(socket, ["publisher", "imprints"])
    end

    test "unknown top-level field → nil", %{socket: socket} do
      assert StudioLive.find_field_by_path(socket, ["nope"]) == nil
    end

    test "empty path → nil", %{socket: socket} do
      assert StudioLive.find_field_by_path(socket, []) == nil
    end

    test "missing editor_schema → nil" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assert StudioLive.find_field_by_path(socket, ["tags"]) == nil
    end
  end

  # ── Pure unit tests: put_value_at/3 and list_value_at/2 ────────────────

  describe "put_value_at/3" do
    test "single-key write into empty map" do
      assert StudioLive.put_value_at(%{}, ["tags"], ["a"]) == %{"tags" => ["a"]}
    end

    test "single-key write into nil form (defensive default)" do
      assert StudioLive.put_value_at(nil, ["tags"], ["a"]) == %{"tags" => ["a"]}
    end

    test "deep first-time write initializes intermediate maps" do
      assert StudioLive.put_value_at(%{}, ["publisher", "imprints"], [nil]) ==
               %{"publisher" => %{"imprints" => [nil]}}
    end

    test "deep write preserves existing siblings" do
      form = %{"publisher" => %{"name" => "Acme"}}

      assert StudioLive.put_value_at(form, ["publisher", "imprints"], ["a"]) ==
               %{"publisher" => %{"name" => "Acme", "imprints" => ["a"]}}
    end

    test "empty path → form unchanged" do
      form = %{"tags" => ["x"]}
      assert StudioLive.put_value_at(form, [], :anything) == form
    end

    test "non-map intermediate is replaced (not appended-to)" do
      # publisher used to be a stringly thing — now we want a map under it.
      form = %{"publisher" => "Acme"}

      assert StudioLive.put_value_at(form, ["publisher", "imprints"], ["a"]) ==
               %{"publisher" => %{"imprints" => ["a"]}}
    end
  end

  describe "list_value_at/2" do
    test "reads list at top-level path" do
      assert StudioLive.list_value_at(%{"tags" => ["a", "b"]}, ["tags"]) == ["a", "b"]
    end

    test "reads list at nested path" do
      form = %{"publisher" => %{"imprints" => ["x"]}}
      assert StudioLive.list_value_at(form, ["publisher", "imprints"]) == ["x"]
    end

    test "missing key → []" do
      assert StudioLive.list_value_at(%{}, ["tags"]) == []
    end

    test "missing intermediate → []" do
      assert StudioLive.list_value_at(%{}, ["publisher", "imprints"]) == []
    end

    test "non-list value at path → []" do
      assert StudioLive.list_value_at(%{"tags" => "scalar"}, ["tags"]) == []
    end
  end

  # ── Pure unit tests: empty_for_of/1 ─────────────────────────────────────

  describe "empty_for_of/1" do
    test "string element → nil" do
      assert StudioLive.empty_for_of(%{"of" => %{"type" => "string"}}) == nil
    end

    test "composite element → empty map with subfield slots" do
      field = %{
        "of" => %{
          "type" => "composite",
          "fields" => [
            %{"name" => "key", "type" => "string"},
            %{"name" => "value", "type" => "string"}
          ]
        }
      }

      assert StudioLive.empty_for_of(field) == %{"key" => nil, "value" => nil}
    end

    test "nested arrayOf element → empty list" do
      assert StudioLive.empty_for_of(%{"of" => %{"type" => "arrayOf"}}) == []
    end

    test "localizedText element → empty map" do
      assert StudioLive.empty_for_of(%{"of" => %{"type" => "localizedText"}}) == %{}
    end

    test "codelist element → nil" do
      assert StudioLive.empty_for_of(%{"of" => %{"type" => "codelist"}}) == nil
    end

    test "missing `of` → nil" do
      assert StudioLive.empty_for_of(%{}) == nil
    end
  end

  # ── Integration tests against handle_event/3 directly ─────────────────

  describe "handle_event(\"array_op\", ...) — top-level arrayOf" do
    setup do
      schema = %{
        "name" => "page",
        "title" => "Page",
        "icon" => "file",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "title" => "Title", "type" => "string"},
          %{
            "name" => "tags",
            "title" => "Tags",
            "type" => "arrayOf",
            "of" => %{"type" => "string"},
            "ordered" => true
          }
        ]
      }

      {:ok, _} = Content.upsert_schema(schema, @dataset)
      {:ok, schema_def} = Content.get_schema("page", @dataset)

      {:ok, doc} =
        Content.create_document(
          "page",
          %{
            "doc_id" => "td1",
            "title" => "T",
            "content" => %{"tags" => ["a", "b", "c"]}
          },
          @dataset
        )

      form = %{"title" => "T", "tags" => ["a", "b", "c"]}

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            editor_doc: doc,
            editor_schema: schema_def,
            editor_type: "page",
            editor_form: form,
            editor_is_draft: true,
            dataset: @dataset,
            panes: [],
            save_status: ""
          }
        }

      {:ok, socket: socket}
    end

    test "add_row appends a row via path", %{socket: socket} do
      {:noreply, new_socket} =
        StudioLive.handle_event("array_op", %{"action" => "add_row", "path" => "doc[tags]"}, socket)

      assert new_socket.assigns.editor_form["tags"] == ["a", "b", "c", nil]
    end

    test "remove_row drops the indexed row", %{socket: socket} do
      {:noreply, new_socket} =
        StudioLive.handle_event(
          "array_op",
          %{"action" => "remove_row", "path" => "doc[tags]", "index" => "1"},
          socket
        )

      assert new_socket.assigns.editor_form["tags"] == ["a", "c"]
    end

    test "move_up swaps with the row above", %{socket: socket} do
      {:noreply, new_socket} =
        StudioLive.handle_event(
          "array_op",
          %{"action" => "move_up", "path" => "doc[tags]", "index" => "1"},
          socket
        )

      assert new_socket.assigns.editor_form["tags"] == ["b", "a", "c"]
    end

    test "move_down swaps with the row below", %{socket: socket} do
      {:noreply, new_socket} =
        StudioLive.handle_event(
          "array_op",
          %{"action" => "move_down", "path" => "doc[tags]", "index" => "0"},
          socket
        )

      assert new_socket.assigns.editor_form["tags"] == ["b", "a", "c"]
    end

    test "back-compat: `field`-only payload (no path) still works", %{socket: socket} do
      {:noreply, new_socket} =
        StudioLive.handle_event("array_op", %{"action" => "add_row", "field" => "tags"}, socket)

      assert new_socket.assigns.editor_form["tags"] == ["a", "b", "c", nil]
    end

    test "out-of-bounds remove → list unchanged", %{socket: socket} do
      {:noreply, new_socket} =
        StudioLive.handle_event(
          "array_op",
          %{"action" => "remove_row", "path" => "doc[tags]", "index" => "42"},
          socket
        )

      assert new_socket.assigns.editor_form["tags"] == ["a", "b", "c"]
    end

    test "out-of-bounds move_up at idx 0 → list unchanged", %{socket: socket} do
      {:noreply, new_socket} =
        StudioLive.handle_event(
          "array_op",
          %{"action" => "move_up", "path" => "doc[tags]", "index" => "0"},
          socket
        )

      assert new_socket.assigns.editor_form["tags"] == ["a", "b", "c"]
    end

    test "unknown field in path → no-op, no crash", %{socket: socket} do
      {:noreply, new_socket} =
        StudioLive.handle_event(
          "array_op",
          %{"action" => "add_row", "path" => "doc[bogus]"},
          socket
        )

      # Form completely unchanged; the handler bailed before do_autosave.
      assert new_socket.assigns.editor_form == socket.assigns.editor_form
    end

    test "malformed path → no-op", %{socket: socket} do
      {:noreply, new_socket} =
        StudioLive.handle_event(
          "array_op",
          %{"action" => "add_row", "path" => "garbage"},
          socket
        )

      assert new_socket.assigns.editor_form == socket.assigns.editor_form
    end

    test "back-compat: unknown action → list unchanged (passes through ArrayField fall-through)",
         %{socket: socket} do
      {:noreply, new_socket} =
        StudioLive.handle_event(
          "array_op",
          %{"action" => "rotate_left", "path" => "doc[tags]"},
          socket
        )

      assert new_socket.assigns.editor_form["tags"] == ["a", "b", "c"]
    end
  end

  # ── Nested composite > arrayOf (the actual 0901066 fix) ────────────────

  describe "handle_event(\"array_op\", ...) — nested composite > arrayOf" do
    setup do
      schema = %{
        "name" => "page",
        "title" => "Page",
        "icon" => "file",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "title" => "Title", "type" => "string"},
          %{
            "name" => "publisher",
            "title" => "Publisher",
            "type" => "composite",
            "fields" => [
              %{"name" => "name", "title" => "Name", "type" => "string"},
              %{
                "name" => "imprints",
                "title" => "Imprints",
                "type" => "arrayOf",
                "of" => %{"type" => "string"},
                "ordered" => true
              }
            ]
          }
        ]
      }

      {:ok, _} = Content.upsert_schema(schema, @dataset)
      {:ok, schema_def} = Content.get_schema("page", @dataset)

      {:ok, doc} =
        Content.create_document(
          "page",
          %{
            "doc_id" => "n1",
            "title" => "N",
            "content" => %{}
          },
          @dataset
        )

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            editor_doc: doc,
            editor_schema: schema_def,
            editor_type: "page",
            editor_form: %{"title" => "N"},
            editor_is_draft: true,
            dataset: @dataset,
            panes: [],
            save_status: ""
          }
        }

      {:ok, socket: socket}
    end

    test "add_row into a yet-unset nested arrayOf works on first click", %{socket: socket} do
      {:noreply, new_socket} =
        StudioLive.handle_event(
          "array_op",
          %{"action" => "add_row", "path" => "doc[publisher].imprints"},
          socket
        )

      # The deep path initializes the intermediate `publisher` map and lands
      # one nil row in `imprints`. This is the exact regression 0901066 fixed.
      assert new_socket.assigns.editor_form["publisher"] == %{"imprints" => [nil]}
    end

    test "add_row twice appends two rows under the same nested path", %{socket: socket} do
      {:noreply, after1} =
        StudioLive.handle_event(
          "array_op",
          %{"action" => "add_row", "path" => "doc[publisher].imprints"},
          socket
        )

      {:noreply, after2} =
        StudioLive.handle_event(
          "array_op",
          %{"action" => "add_row", "path" => "doc[publisher].imprints"},
          after1
        )

      assert after2.assigns.editor_form["publisher"]["imprints"] == [nil, nil]
    end
  end
end
