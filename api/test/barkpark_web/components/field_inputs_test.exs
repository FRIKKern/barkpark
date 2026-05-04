defmodule BarkparkWeb.Components.FieldInputsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.FieldInputs

  defp render_input(assigns), do: render_component(&FieldInputs.input/1, assigns)

  describe "select clause" do
    test "renders select with options and selected flag on matched value" do
      html =
        render_input(%{
          field: %{"type" => "select", "name" => "status", "options" => ["draft", "published"]},
          editor_form: %{"status" => "published"}
        })

      assert html =~ ~s(<select)
      assert html =~ ~s(class="form-input")
      assert html =~ ~s(name="doc[status]")
      assert html =~ ~s(phx-debounce="300")
      assert html =~ ~s(<option value="draft">draft</option>)
      assert html =~ ~s(<option value="published" selected>published</option>)
    end

    test "no id attribute by default" do
      html =
        render_input(%{
          field: %{"type" => "select", "name" => "status", "options" => ["a"]},
          editor_form: %{}
        })

      refute html =~ ~s( id=)
    end

    test "id_prefix renders id=<prefix><name>" do
      html =
        render_input(%{
          field: %{"type" => "select", "name" => "status", "options" => ["a"]},
          editor_form: %{},
          id_prefix: "f-book-"
        })

      assert html =~ ~s(id="f-book-status")
    end
  end

  describe "text / richText clause" do
    test "text defaults to rows=3, phx-debounce=500, form-input class" do
      html =
        render_input(%{
          field: %{"type" => "text", "name" => "summary"},
          editor_form: %{"summary" => "hello"}
        })

      assert html =~ ~s(<textarea)
      assert html =~ ~s(name="doc[summary]")
      assert html =~ ~s(class="form-input")
      assert html =~ ~s(rows="3")
      assert html =~ ~s(phx-debounce="500")
      assert html =~ ">hello</textarea>"
    end

    test "richText renders bp-rich-text-editor Web Component bridged via hidden input (Task #11 WI4)" do
      html =
        render_input(%{
          field: %{"type" => "richText", "name" => "body"},
          editor_form: %{"body" => "hello"}
        })

      # Wrapper carries the hook + phx-update=ignore + stable id
      assert html =~
               ~r{<div[^>]*id="bp-rt-wrap-body"[^>]*phx-update="ignore"[^>]*phx-hook="BarkparkFieldBridge"}

      # Hidden input holds the form payload value + debounce
      assert html =~
               ~r{<input type="hidden"[^>]*id="bp-rt-hidden-body"[^>]*name="doc\[body\]"[^>]*phx-debounce="500"}

      # Custom element points at the hidden input via data-bridge-target
      assert html =~
               ~r{<bp-rich-text-editor[^>]*value="[^"]*"[^>]*data-bridge-target="bp-rt-hidden-body"}
    end

    test "explicit rows override wins" do
      html =
        render_input(%{
          field: %{"type" => "text", "name" => "body", "rows" => 10},
          editor_form: %{}
        })

      assert html =~ ~s(rows="10")
    end

    test "id_prefix on textarea" do
      html =
        render_input(%{
          field: %{"type" => "text", "name" => "body"},
          editor_form: %{},
          id_prefix: "f-"
        })

      assert html =~ ~s(id="f-body")
    end
  end

  describe "boolean clause" do
    test "unchecked: hidden 'false' first, checkbox 'true' second, no checked attr" do
      html =
        render_input(%{
          field: %{"type" => "boolean", "name" => "featured"},
          editor_form: %{}
        })

      assert html =~ ~s(class="form-checkbox")

      hidden_idx =
        :binary.match(html, ~s(<input type="hidden" name="doc[featured]" value="false"))
        |> elem(0)

      checkbox_idx =
        :binary.match(html, ~s(type="checkbox" name="doc[featured]" value="true")) |> elem(0)

      assert hidden_idx < checkbox_idx
      assert html =~ ~s(phx-debounce="100")
      refute html =~ "checked"
    end

    test "checked when form value is the literal string \"true\"" do
      html =
        render_input(%{
          field: %{"type" => "boolean", "name" => "featured"},
          editor_form: %{"featured" => "true"}
        })

      assert html =~ ~s(value="true" checked phx-debounce="100")
    end

    test "id_prefix lands on the checkbox only" do
      html =
        render_input(%{
          field: %{"type" => "boolean", "name" => "featured"},
          editor_form: %{},
          id_prefix: "f-"
        })

      # checkbox carries the id; the hidden input does not
      assert html =~ ~s(id="f-featured" type="checkbox")
      refute html =~ ~s(id="f-featured" type="hidden")
    end
  end

  describe "color clause" do
    test "default value is #3b82f6 when form key missing" do
      html =
        render_input(%{
          field: %{"type" => "color", "name" => "brand"},
          editor_form: %{}
        })

      assert html =~ ~s(type="color")
      assert html =~ ~s(name="doc[brand]")
      assert html =~ ~s(value="#3b82f6")
      assert html =~ ~s(phx-debounce="300")
      # mono hex display
      assert html =~ "font-family:var(--font-mono)"
      assert html =~ "#3b82f6</span>"
    end

    test "form value overrides default" do
      html =
        render_input(%{
          field: %{"type" => "color", "name" => "brand"},
          editor_form: %{"brand" => "#ff0000"}
        })

      assert html =~ ~s(value="#ff0000")
      assert html =~ "#ff0000</span>"
    end
  end

  describe "reference clause (empty value)" do
    test "renders Select trigger button with phx-click + ref-type" do
      html =
        render_input(%{
          field: %{"type" => "reference", "name" => "author", "refType" => "author"},
          editor_form: %{}
        })

      assert html =~ ~s(type="hidden")
      assert html =~ ~s(name="doc[author]")
      assert html =~ ~s(class="ref-field")
      assert html =~ ~s(phx-click="open-ref-picker")
      assert html =~ ~s(phx-value-field="author")
      assert html =~ ~s(phx-value-ref-type="author")
      assert html =~ "Select author..."
    end
  end

  # TODO(S7): exercise reference clause with a populated value via the editor
  # smoke test (requires Repo + seeded doc; render_component cannot stub the
  # in-render Content.get_document/3 call). The Change/Remove + ref-selected
  # branch is byte-identical to legacy, deferred to integration coverage.

  describe "image clause" do
    test "empty value renders upload zone with phx-click on outer div" do
      html =
        render_input(%{
          field: %{"type" => "image", "name" => "cover"},
          editor_form: %{}
        })

      assert html =~ ~s(class="image-field")

      assert html =~
               ~s(class="image-upload-zone" phx-click="open-image-picker" phx-value-field="cover")

      assert html =~ ">+</div>"
      assert html =~ "Select or upload image"
    end

    test "populated value renders preview img with empty alt + Change/Remove" do
      html =
        render_input(%{
          field: %{"type" => "image", "name" => "cover"},
          editor_form: %{"cover" => "/uploads/x.jpg"}
        })

      assert html =~ ~s(class="image-preview")

      assert html =~ ~s(<img src="/uploads/x.jpg" alt="">) or
               html =~ ~s(<img src="/uploads/x.jpg" alt=""/>)

      assert html =~ ~s(phx-click="open-image-picker" phx-value-field="cover">Change</button>)
      assert html =~ ~s(phx-click="clear-image" phx-value-field="cover">Remove</button>)
    end
  end

  describe "default fallback (string / slug / datetime / unknown)" do
    test "string falls through to text input with form-input class + 500ms debounce" do
      html =
        render_input(%{
          field: %{"type" => "string", "name" => "title"},
          editor_form: %{"title" => "Hello"}
        })

      assert html =~ ~s(<input)
      assert html =~ ~s(type="text")
      assert html =~ ~s(name="doc[title]")
      assert html =~ ~s(value="Hello")
      assert html =~ ~s(class="form-input")
      assert html =~ ~s(phx-debounce="500")
    end

    test "slug, datetime, and unknown all hit the same fallback" do
      for type <- ["slug", "datetime", "weirdo"] do
        html =
          render_input(%{
            field: %{"type" => type, "name" => "f"},
            editor_form: %{}
          })

        assert html =~ ~s(<input)
        assert html =~ ~s(type="text")
        assert html =~ ~s(class="form-input")
        assert html =~ ~s(phx-debounce="500")
      end
    end

    test "no id by default; id_prefix lands when set" do
      no_prefix =
        render_input(%{
          field: %{"type" => "string", "name" => "title"},
          editor_form: %{}
        })

      refute no_prefix =~ ~s( id=)

      with_prefix =
        render_input(%{
          field: %{"type" => "string", "name" => "title"},
          editor_form: %{},
          id_prefix: "f-"
        })

      assert with_prefix =~ ~s(id="f-title")
    end
  end
end
