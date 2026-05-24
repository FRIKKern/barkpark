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

  describe "reference clause (Task #12 WI2 — bp-reference-picker)" do
    test "empty value: wrapper + hidden input + bp-reference-picker bridged via BarkparkFieldBridge" do
      html =
        render_input(%{
          field: %{"type" => "reference", "name" => "author", "refType" => "author"},
          editor_form: %{}
        })

      # Wrapper carries the hook + phx-update=ignore + stable id
      assert html =~
               ~r{<div[^>]*id="bp-ref-wrap-author"[^>]*phx-update="ignore"[^>]*phx-hook="BarkparkFieldBridge"}

      # Hidden input holds the form payload value + debounce
      assert html =~
               ~r{<input type="hidden"[^>]*id="bp-ref-hidden-author"[^>]*name="doc\[author\]"[^>]*phx-debounce="500"}

      # Custom element receives ref-type + dataset and points at the hidden input
      assert html =~
               ~r{<bp-reference-picker[^>]*ref-type="author"[^>]*dataset="production"[^>]*data-bridge-target="bp-ref-hidden-author"}

      # Legacy modal-trigger phx-click events are gone — the WC owns search/select/clear
      refute html =~ ~s(phx-click="open-ref-picker")
      refute html =~ ~s(phx-click="clear-ref")
    end

    test "populated value: hidden input carries the doc id, WC mirrors it via value attribute" do
      html =
        render_input(%{
          field: %{"type" => "reference", "name" => "author", "refType" => "author"},
          editor_form: %{"author" => "a1"}
        })

      assert html =~ ~r{<input type="hidden"[^>]*id="bp-ref-hidden-author"[^>]*value="a1"}
      assert html =~ ~r{<bp-reference-picker[^>]*value="a1"[^>]*ref-type="author"}
    end

    test "non-default dataset propagates to the WC attribute" do
      html =
        render_input(%{
          field: %{"type" => "reference", "name" => "author", "refType" => "author"},
          editor_form: %{},
          dataset: "staging"
        })

      assert html =~ ~r{<bp-reference-picker[^>]*dataset="staging"}
    end
  end

  # TODO(S7): exercise reference clause with a populated value via the editor
  # smoke test (requires Repo + seeded doc; render_component cannot stub the
  # in-render Content.get_document/3 call). The Change/Remove + ref-selected
  # branch is byte-identical to legacy, deferred to integration coverage.

  describe "mediaAsset reference clause" do
    test "renders bp-media-picker in reference mode for mediaAsset refs" do
      html =
        render_input(%{
          field: %{"type" => "reference", "name" => "featuredAsset", "refType" => "mediaAsset"},
          editor_form: %{"featuredAsset" => "drafts.asset-abc"},
          dataset: "production",
          api_token_raw: "barkpark-dev-token"
        })

      assert html =~ ~r{<bp-media-picker[^>]*value-mode="reference"}
      assert html =~ ~s(value="drafts.asset-abc")
      assert html =~ ~s(dataset="production")
      assert html =~ ~r{name="doc\[featuredAsset\]"}
    end
  end

  describe "image clause (Task #12 WI1 — bp-media-picker Web Component)" do
    test "renders bp-media-picker bridged via hidden input wrapper" do
      html =
        render_input(%{
          field: %{"type" => "image", "name" => "cover"},
          editor_form: %{"cover" => "/media/files/x.jpg"}
        })

      # Wrapper carries hook + phx-update=ignore + stable id
      assert html =~
               ~r{<div[^>]*id="bp-mp-wrap-cover"[^>]*phx-update="ignore"[^>]*phx-hook="BarkparkFieldBridge"}

      # Hidden input holds the form payload (URL string) + debounce
      assert html =~
               ~r{<input type="hidden"[^>]*id="bp-mp-hidden-cover"[^>]*name="doc\[cover\]"[^>]*value="/media/files/x.jpg"[^>]*phx-debounce="500"}

      # Custom element points at the hidden input via data-bridge-target
      assert html =~
               ~r{<bp-media-picker[^>]*value="/media/files/x.jpg"[^>]*data-bridge-target="bp-mp-hidden-cover"}

      # No legacy phx-click events emitted from the image clause
      refute html =~ ~s(phx-click="open-image-picker")
      refute html =~ ~s(phx-click="clear-image")
      refute html =~ ~s(class="image-field")
    end

    test "empty value still renders the WC wrapper (WC owns empty UX)" do
      html =
        render_input(%{
          field: %{"type" => "image", "name" => "cover"},
          editor_form: %{}
        })

      assert html =~ ~r{<bp-media-picker[^>]*value=""}
      assert html =~ ~r{<input type="hidden"[^>]*name="doc\[cover\]"[^>]*value=""}
      refute html =~ "image-upload-zone"
    end

    test "api_token_raw is passed to the WC as data-token" do
      html =
        render_input(%{
          field: %{"type" => "image", "name" => "cover"},
          editor_form: %{},
          api_token_raw: "barkpark-dev-token"
        })

      assert html =~ ~s(data-token="barkpark-dev-token")
    end

    test "missing api_token_raw defaults to empty string (uploads disabled)" do
      html =
        render_input(%{
          field: %{"type" => "image", "name" => "cover"},
          editor_form: %{}
        })

      assert html =~ ~s(data-token="")
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

    test "slug and unknown types hit the text fallback" do
      for type <- ["slug", "weirdo"] do
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

    test "datetime renders as datetime-local (Goal barkpark-mwr G1)" do
      html =
        render_input(%{
          field: %{"type" => "datetime", "name" => "publishedAt"},
          editor_form: %{}
        })

      assert html =~ ~s(<input)
      assert html =~ ~s(type="datetime-local")
      assert html =~ ~s(name="doc[publishedAt]")
      assert html =~ ~s(class="form-input")
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
