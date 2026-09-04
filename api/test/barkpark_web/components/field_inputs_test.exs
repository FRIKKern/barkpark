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

    test "optional select, no stored value: leading empty placeholder is selected (empty serializes → dropped, no phantom first option)" do
      html =
        render_input(%{
          field: %{
            "type" => "select",
            "name" => "role",
            "options" => ["editor", "writer", "admin"]
          },
          editor_form: %{}
        })

      # The leading placeholder is the SELECTED option → the browser serializes
      # "" → Content.Forms.build_content/2 drops it. No phantom default persists.
      assert html =~ ~s(<option value="" selected>)
      # The first real option must NOT be force-selected (the phantom-default bug).
      assert html =~ ~s(<option value="editor">editor</option>)
      refute html =~ ~s(<option value="editor" selected>)
      # Optional placeholder is user-selectable (not disabled).
      refute html =~ ~s(value="" selected disabled)
    end

    test "optional select WITH a stored value: matching option selected, no placeholder" do
      html =
        render_input(%{
          field: %{
            "type" => "select",
            "name" => "role",
            "options" => ["editor", "writer", "admin"]
          },
          editor_form: %{"role" => "writer"}
        })

      refute html =~ ~s(<option value="" selected)
      assert html =~ ~s(<option value="writer" selected>writer</option>)
    end

    test "required select, no stored value: placeholder present but DISABLED (still forces a choice, never persists empty)" do
      html =
        render_input(%{
          field: %{
            "type" => "select",
            "name" => "role",
            "options" => ["editor", "writer"],
            "validation" => %{"required" => true}
          },
          editor_form: %{}
        })

      # Empty-valued placeholder (never a phantom) but disabled → the user must
      # pick a real option; required-field validation flags the empty meanwhile.
      assert html =~ ~r{<option value="" selected disabled}
      refute html =~ ~s(<option value="editor" selected>)
    end
  end

  describe "select persistence via Content.Forms.build_content/2 (phantom-default guard)" do
    alias Barkpark.Content.Forms

    @select_schema %{
      fields: [
        %{"name" => "role", "type" => "select", "options" => ["editor", "writer", "admin"]}
      ]
    }

    test "unset optional select (empty param) is NOT persisted" do
      assert Forms.build_content(%{"role" => ""}, @select_schema) == %{}
    end

    test "chosen optional select IS persisted" do
      assert Forms.build_content(%{"role" => "writer"}, @select_schema) == %{"role" => "writer"}
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

    test "richText with editor: blocks renders the FIELD CANVAS — no hidden input, no bridge (Gyldendal E1)" do
      html =
        render_input(%{
          field: %{
            "type" => "richText",
            "name" => "description",
            "editor" => "blocks",
            "blocks" => %{"styles" => ["normal", "h2"], "marks" => ["strong"]}
          },
          editor_form: %{
            "description" => %{
              "blocks" => [
                %{
                  "id" => "p1",
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "hi"}]
                }
              ],
              "html" => "<p>hi</p>"
            }
          },
          doc_key: "pub-1"
        })

      assert html =~
               ~r{<div[^>]*id="bp-fc-wrap-pub-1-description"[^>]*phx-update="ignore"[^>]*phx-hook="BarkparkFieldCanvas"}

      assert html =~ ~s(data-field="description")
      assert html =~ ~s(data-doc-key="pub-1")
      assert html =~ ~r{data-canvas-blocks="[^"]*p1[^"]*"}
      assert html =~ ~r{data-canvas-vocabulary="[^"]*h2[^"]*"}
      assert html =~ "<bp-paper-canvas></bp-paper-canvas>"
      refute html =~ "bp-rich-text-editor"
      refute html =~ ~s(type="hidden")
      refute html =~ "BarkparkFieldBridge"
    end

    test "richText with editor: blocks seeds a legacy plain-string value as one paragraph" do
      html =
        render_input(%{
          field: %{
            "type" => "richText",
            "name" => "description",
            "editor" => "blocks",
            "blocks" => %{}
          },
          editor_form: %{"description" => "Old prose"}
        })

      assert html =~ ~r{data-canvas-blocks="[^"]*paragraph[^"]*"}
      assert html =~ ~r{data-canvas-blocks="[^"]*Old prose[^"]*"}
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

      # Renders as the labeled switch — the real checkbox stays in the DOM
      # (hidden-false + checkbox-true ordering is the form contract below).
      assert html =~ ~s(class="form-switch")
      assert html =~ ~s(class="form-switch-track")
      assert html =~ ">Off<"

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
      assert html =~ ">On<"
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
    test "unset optional field: hidden name carries \"\" (autosave drops it, no phantom blue)" do
      html =
        render_input(%{
          field: %{"type" => "color", "name" => "brand"},
          editor_form: %{}
        })

      # The ONLY named (form-serialized) control is the hidden input, and it
      # holds "" so Content.Forms.build_content/2 drops the field — nothing
      # phantom is ever persisted for an untouched optional color field.
      assert html =~ ~s(type="hidden")
      assert html =~ ~s(data-color-value)
      assert html =~ ~s(name="doc[brand]" value="")
      # No phantom blue anywhere.
      refute html =~ "#3b82f6"
      # The picker itself is nameless (never autosaves on its own).
      refute html =~ ~s(type="color" name=)
      # Neutral "No color" state + dimmed swatch + bridge hook + no Clear.
      assert html =~ "No color</span>"
      assert html =~ ~s(phx-hook="BarkparkColorField")
      assert html =~ "opacity:0.4;"
      assert html =~ ~s(data-color-unset="true")
      refute html =~ "data-color-clear"
    end

    test "stored value renders swatch + hex + Clear, no dimming" do
      html =
        render_input(%{
          field: %{"type" => "color", "name" => "brand"},
          editor_form: %{"brand" => "#ff0000"}
        })

      # Hidden input persists the real hex; picker shows it.
      assert html =~ ~s(name="doc[brand]" value="#ff0000")
      assert html =~ ~s(type="color")
      assert html =~ ~s(value="#ff0000")
      assert html =~ "#ff0000</span>"
      # Clear affordance present, no unset dimming.
      assert html =~ "data-color-clear"
      assert html =~ ~s(data-color-unset="false")
      refute html =~ "opacity:0.4;"
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

    test "hotspot + alt opt-ins reach the picker as attributes; absent → no attribute at all (Gyldendal E1)" do
      html =
        render_input(%{
          field: %{"type" => "image", "name" => "cover", "hotspot" => true, "alt" => true},
          editor_form: %{"cover" => ""}
        })

      assert html =~ ~r{<bp-media-picker[^>]*\shotspot[^>]*>}
      assert html =~ ~r{<bp-media-picker[^>]*\salt[^>]*>}

      nested =
        render_input(%{
          field: %{"type" => "image", "name" => "cover", "options" => %{"hotspot" => true}},
          editor_form: %{"cover" => ""}
        })

      assert nested =~ ~r{<bp-media-picker[^>]*\shotspot[^>]*>}

      plain =
        render_input(%{
          field: %{"type" => "image", "name" => "cover"},
          editor_form: %{"cover" => ""}
        })

      refute plain =~ ~r{<bp-media-picker[^>]*\shotspot}
      refute plain =~ ~r{<bp-media-picker[^>]*\salt}
    end

    test "a decoded image map is handed to the picker as its JSON wire string" do
      html =
        render_input(%{
          field: %{"type" => "image", "name" => "cover"},
          editor_form: %{"cover" => %{"url" => "/x.png", "assetId" => "a1", "focalX" => 0.5}}
        })

      assert html =~ ~r{<bp-media-picker[^>]*value="\{[^"]*focalX[^"]*\}"}

      assert html =~
               ~r{<input type="hidden"[^>]*name="doc\[cover\]"[^>]*value="\{[^"]*focalX[^"]*\}"}
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

    test "a DECLARED number type gets the numeric input regardless of name" do
      html =
        render_input(%{
          field: %{"type" => "number", "name" => "priority"},
          editor_form: %{"priority" => "2"}
        })

      assert html =~ ~s(inputmode="numeric")
      assert html =~ ~s(class="form-input bp-input-numeric")
      assert html =~ ~s(value="2")
    end

    test "unknown types hit the text fallback" do
      html =
        render_input(%{
          field: %{"type" => "weirdo", "name" => "f"},
          editor_form: %{}
        })

      assert html =~ ~s(<input)
      assert html =~ ~s(type="text")
      assert html =~ ~s(class="form-input")
      assert html =~ ~s(phx-debounce="500")
    end

    test "slug renders a text input PLUS the Generate-from-title button" do
      html =
        render_input(%{
          field: %{"type" => "slug", "name" => "slug"},
          editor_form: %{"slug" => "my-post"}
        })

      assert html =~ ~s(name="doc[slug]")
      assert html =~ ~s(value="my-post")
      assert html =~ ~s(phx-debounce="500")
      assert html =~ ~s(phx-click="slug-generate")
      assert html =~ ~s(phx-value-field="slug")
      assert html =~ ">Generate</button>"
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

  describe "source clause (scaffy command source, W4 D45)" do
    test "renders the raw multi-line value in a read-only monospace <pre> with NO form input" do
      source = "COMMAND \"add-note\"\n\nVARIABLE 1 \"NoteName\"\n  <tag> & {{.note-name}}"

      html =
        render_input(%{
          field: %{"type" => "source", "name" => "source"},
          editor_form: %{"source" => source}
        })

      # The multi-line bytes survive verbatim (HTML-escaped, never collapsed to
      # a one-line JSON blob) inside the monospace <pre>.
      assert html =~
               "COMMAND &quot;add-note&quot;\n\nVARIABLE 1 &quot;NoteName&quot;\n  &lt;tag&gt; &amp; {{.note-name}}"

      assert html =~ ~s(data-readonly-field="source")
      assert html =~ ~s(data-source-field)
      assert html =~ "font-family:var(--font-mono)"
      # NO form input — the field stays absent from the submitted doc[...]
      # params, so Content.classic_save_content/4 preserves the stored bytes.
      refute html =~ ~s(name="doc[)
      assert html =~ "read-only"
    end

    test "missing value renders an empty read-only pre without crashing" do
      html =
        render_input(%{field: %{"type" => "source", "name" => "source"}, editor_form: %{}})

      assert html =~ ~s(data-source-field)
      refute html =~ ~s(name="doc[)
    end
  end
end
