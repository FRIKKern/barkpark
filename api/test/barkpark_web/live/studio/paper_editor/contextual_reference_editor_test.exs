defmodule BarkparkWeb.Studio.PaperEditor.ContextualReferenceEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "inline summaries patch only text while settings explicitly control default-open" do
    for open <- [nil, false, true] do
      block = %{"type" => "expandable", "open" => open}

      assert Blocks.build_block_patch(block, %{"summary" => "Updated"}) == %{
               "summary" => "Updated"
             }

      assert Blocks.build_block_patch(block, %{"open" => "false"}) == %{"open" => false}
      assert Blocks.build_block_patch(block, %{"open" => "true"}) == %{"open" => true}
    end
  end

  test "paper-links keeps canonical cards and exposes one direct scalar editor per header field" do
    block = %{
      "id" => "related",
      "type" => "paper-links",
      "title" => "Related reading",
      "description" => "Follow the release story.",
      "refs" => [
        %{
          "slug" => "release-week",
          "title" => "Release week",
          "description" => "The full account"
        }
      ]
    }

    live_details = %{
      "release-week" => %{
        title: "Release week, live",
        description: "The published account",
        event_type: "release"
      }
    }

    html =
      render_component(&PaperEditor.paper_block_fields/1, %{
        block: block,
        paper_links: live_details
      })

    assert html =~ "Release week, live"
    refute html =~ ">Release week</a>"
    assert html =~ ~s(data-test-id="paper-links-preview")
    assert html =~ ~s(class="bp-paper-links-header-editor")
    assert html =~ ~s(class="bp-paper-links-title-heading")
    assert html =~ ~s(data-paper-links-title-paint)
    assert html =~ ~s(class="bp-paper-links-description-paragraph")
    assert html =~ ~s(data-paper-links-description-paint)
    assert html =~ ~s(id="paper-links-title-cmVsYXRlZA")
    assert html =~ ~s(id="paper-links-description-cmVsYXRlZA")
    assert html =~ ~s(data-test-id="paper-links-title-editor")
    assert html =~ ~s(data-test-id="paper-links-description-editor")
    assert html =~ ~s(phx-hook="BarkparkPaperAutoSize")
    assert html =~ ~s(class="bp-paper-contextual-controls")
    assert html =~ "ignore_attrs"
    assert html =~ ~s(id="paper-links-form-related")
    assert html =~ ~s(phx-submit="paper-edit-block")
    assert html =~ ~s(phx-change="paper-block-autosave")
    assert html =~ ~s(type="hidden" name="ref-0-featured" value="false")
    assert html =~ ~s(type="checkbox" name="ref-0-featured" value="true")

    fragment = LazyHTML.from_fragment(html)

    assert fragment |> LazyHTML.query(~s(textarea[name="title"])) |> Enum.count() == 1
    assert fragment |> LazyHTML.query(~s(textarea[name="description"])) |> Enum.count() == 1
    assert fragment |> LazyHTML.query("h2 form, p form, form form") |> Enum.empty?()

    assert fragment
           |> LazyHTML.query(~s(#paper-links-form-related [name="title"]))
           |> Enum.empty?()

    assert fragment
           |> LazyHTML.query(~s(#paper-links-form-related [name="description"]))
           |> Enum.empty?()
  end

  test "paper-links default heading stays paint-only and hostile ids get safe focus targets" do
    block = %{
      "id" => "related: with punctuation!?",
      "type" => "paper-links",
      "title" => "   ",
      "refs" => []
    }

    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block, paper_links: %{}})
    encoded = Base.url_encode64(block["id"], padding: false)
    fragment = LazyHTML.from_fragment(html)

    assert html =~ "Explore the work"
    refute html =~ ~s(<section data-paper-links)
    refute html =~ ~s(data-paper-links-title-paint)
    refute html =~ ~s(class="bp-paper-links-title-heading")
    refute html =~ ~s(class="bp-paper-links-description-paragraph")

    assert fragment
           |> LazyHTML.query(~s(textarea#paper-links-title-#{encoded}[name="title"]))
           |> LazyHTML.text() == "   "

    assert fragment
           |> LazyHTML.query(~s(textarea#paper-links-title-#{encoded}[tabindex="-1"]))
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(~s(textarea#paper-links-description-#{encoded}[tabindex="-1"]))
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(~s(input[name="block_id"][value="related: with punctuation!?"]))
           |> Enum.count() == 3

    assert fragment
           |> LazyHTML.query(
             ~s([data-paper-links-title-panel-trigger][aria-controls="paper-links-title-#{encoded}"])
           )
           |> Enum.count() == 1
  end

  test "paper-links numeric header fields use edit fallback labels without changing source" do
    block = %{
      "id" => "numeric-related",
      "type" => "paper-links",
      "title" => 42,
      "description" => 7,
      "refs" => ["next"]
    }

    original = block
    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block, paper_links: %{}})
    fragment = LazyHTML.from_fragment(html)

    assert fragment
           |> LazyHTML.query(~s([data-paper-links-title-panel-trigger]))
           |> LazyHTML.text() == "Edit heading"

    assert fragment
           |> LazyHTML.query(~s([data-paper-links-description-panel-trigger]))
           |> LazyHTML.text() == "Edit description"

    assert fragment |> LazyHTML.query(~s(textarea[name="title"])) |> LazyHTML.text() == "42"

    assert fragment
           |> LazyHTML.query(~s(textarea[name="description"]))
           |> LazyHTML.text() == "7"

    assert block === original
  end

  test "admitted reference copy edits in place while duplicate and live copy stay reader links" do
    hostile_id = "related: copy/[inline]!?"

    block = %{
      "id" => hostile_id,
      "type" => "paper-links",
      "layout" => "timeline",
      "refs" => [
        %{
          "slug" => " authored ",
          "title" => "Authored title",
          "description" => "Authored description",
          "prefer_authored_copy" => true,
          "unknown" => %{"keep" => true}
        },
        %{"slug" => "missing", "prefer_authored_copy" => true},
        %{"slug" => "duplicate", "title" => "First", "prefer_authored_copy" => true},
        %{"slug" => " duplicate ", "title" => "Second", "prefer_authored_copy" => true},
        %{"slug" => "live", "title" => "Local ignored", "prefer_authored_copy" => false}
      ]
    }

    live_details = %{
      "authored" => %{title: "Live ignored", description: "Live ignored"},
      "missing" => %{title: "Live fallback title", description: "Live fallback description"},
      "duplicate" => %{title: "Duplicate live"},
      "live" => %{title: "Live owned elsewhere", description: "Read only live copy"}
    }

    html =
      render_component(&PaperEditor.paper_block_fields/1, %{
        block: block,
        paper_links: live_details
      })

    fragment = LazyHTML.from_fragment(html)
    encoded = Base.url_encode64(hostile_id, padding: false)

    assert fragment
           |> LazyHTML.query(~s(div[data-paper-link-card-editable]))
           |> Enum.count() == 2

    assert fragment
           |> LazyHTML.query(~S|a[data-paper-link-card]:not([data-paper-link-open])|)
           |> Enum.count() == 3

    assert fragment
           |> LazyHTML.query(~s([data-paper-link-ref-title-paint]))
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(~s([data-paper-link-ref-description-paint]))
           |> Enum.count() == 1

    assert html =~ "Live fallback title"
    assert html =~ "Live fallback description"
    refute html =~ "Live ignored"

    {:ok, first_admission} = Blocks.paper_link_reference_copy_admission(block, 0)
    {:ok, missing_admission} = Blocks.paper_link_reference_copy_admission(block, 1)

    first_digest =
      :crypto.hash(:sha256, first_admission.guard)
      |> Base.url_encode64(padding: false)

    missing_digest =
      :crypto.hash(:sha256, missing_admission.guard)
      |> Base.url_encode64(padding: false)

    assert byte_size(first_digest) == 43
    first_title_id = "paper-link-ref-title-#{encoded}-0-#{first_digest}"
    first_description_id = "paper-link-ref-description-#{encoded}-0-#{first_digest}"
    missing_title_id = "paper-link-ref-title-#{encoded}-1-#{missing_digest}"

    first_title_form =
      fragment
      |> LazyHTML.query(~s(form[data-test-id="paper-link-ref-title-editor"]))
      |> Enum.at(0)

    assert first_title_form
           |> LazyHTML.query(~s([name="paper-link-ref-index"]))
           |> LazyHTML.attribute("value") == ["0"]

    assert first_title_form
           |> LazyHTML.query(~s([name="paper-link-ref-slug"]))
           |> LazyHTML.attribute("value") == [" authored "]

    assert first_title_form
           |> LazyHTML.query(~s([name="paper-link-ref-field"]))
           |> LazyHTML.attribute("value") == ["title"]

    assert first_title_form
           |> LazyHTML.query(~s([name="paper-link-ref-guard"]))
           |> LazyHTML.attribute("value") == [first_admission.guard]

    assert first_title_form
           |> LazyHTML.query(~s(textarea[name="paper-link-ref-value"]))
           |> LazyHTML.text() == "Authored title"

    assert first_title_form
           |> LazyHTML.query(~s(textarea##{first_title_id}))
           |> Enum.count() == 1

    assert first_title_form |> LazyHTML.attribute("id") == [first_title_id <> "-form"]

    assert fragment
           |> LazyHTML.query(
             ~s(form##{first_description_id}-form textarea##{first_description_id})
           )
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(
             ~s(textarea##{missing_title_id}[name="paper-link-ref-value"][tabindex="-1"])
           )
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(~s(textarea##{missing_title_id}))
           |> LazyHTML.text() == ""

    assert fragment
           |> LazyHTML.query(~s(textarea##{missing_title_id}))
           |> LazyHTML.attribute("placeholder") == ["Live fallback title"]

    assert fragment
           |> LazyHTML.query(~s(a[data-paper-link-open]))
           |> LazyHTML.attribute("href")
           |> Enum.at(0) == "/papers/authored"

    assert fragment
           |> LazyHTML.query(
             ~s([data-paper-link-ref-title-panel-trigger][aria-controls="#{missing_title_id}"])
           )
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(
             ~s([data-paper-link-ref-description-panel-trigger][aria-controls="#{first_description_id}"])
           )
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(
             ~s(a[data-paper-link-open][aria-label="Open paper: Authored title"] form)
           )
           |> Enum.empty?()

    assert fragment
           |> LazyHTML.query("a button, a textarea, form form")
           |> Enum.empty?()

    approved_names = [
      "block_id",
      "paper-link-ref-index",
      "paper-link-ref-slug",
      "paper-link-ref-field",
      "paper-link-ref-value",
      "paper-link-ref-guard"
    ]

    for form <- LazyHTML.query(fragment, ~s(form[data-test-id^="paper-link-ref-"])) do
      names =
        form
        |> LazyHTML.query("[name]")
        |> Enum.map(&(LazyHTML.attribute(&1, "name") |> List.first()))
        |> Enum.sort()

      assert names == Enum.sort(approved_names)
    end

    configure = LazyHTML.query(fragment, ~s([data-test-id="paper-links-editor"]))
    refute configure |> LazyHTML.query(~s([name="ref-0-title"])) |> Enum.any?()
    refute configure |> LazyHTML.query(~s([name="ref-0-description"])) |> Enum.any?()
    refute configure |> LazyHTML.query(~s([name="ref-1-title"])) |> Enum.any?()
    refute configure |> LazyHTML.query(~s([name="ref-1-description"])) |> Enum.any?()
    assert configure |> LazyHTML.query(~s([name="ref-2-title"])) |> Enum.count() == 1
    assert configure |> LazyHTML.query(~s([name="ref-3-title"])) |> Enum.count() == 1
    assert configure |> LazyHTML.query(~s([name="ref-4-title"])) |> Enum.count() == 1

    copy_only_block =
      update_in(block, ["refs", Access.at(0)], fn ref ->
        ref
        |> Map.put("title", "Copy-only title change")
        |> Map.put("description", "Copy-only description change")
      end)

    {:ok, copy_only_admission} =
      Blocks.paper_link_reference_copy_admission(copy_only_block, 0)

    assert copy_only_admission.guard == first_admission.guard

    copy_only_html =
      render_component(&PaperEditor.paper_block_fields/1, %{
        block: copy_only_block,
        paper_links: live_details
      })

    assert copy_only_html =~ ~s(id="#{first_title_id}")

    identity_changed_block =
      update_in(block, ["refs", Access.at(0), "unknown"], fn _ -> %{"keep" => "changed"} end)

    {:ok, identity_changed_admission} =
      Blocks.paper_link_reference_copy_admission(identity_changed_block, 0)

    refute identity_changed_admission.guard == first_admission.guard

    changed_digest =
      :crypto.hash(:sha256, identity_changed_admission.guard)
      |> Base.url_encode64(padding: false)

    identity_changed_html =
      render_component(&PaperEditor.paper_block_fields/1, %{
        block: identity_changed_block,
        paper_links: live_details
      })

    refute identity_changed_html =~ ~s(id="#{first_title_id}")

    assert identity_changed_html =~
             ~s(id="paper-link-ref-title-#{encoded}-0-#{changed_digest}")
  end

  test "reference copy gates opaque title and description fields independently" do
    block = %{
      "id" => "partial-copy",
      "type" => "paper-links",
      "refs" => [
        %{
          "slug" => "opaque-title",
          "title" => %{"text" => "preserve"},
          "description" => "Editable description",
          "prefer_authored_copy" => true
        },
        %{
          "slug" => "opaque-description",
          "title" => "Editable title",
          "description" => ["preserve"],
          "prefer_authored_copy" => true
        }
      ]
    }

    html =
      render_component(&PaperEditor.paper_block_fields/1, %{
        block: block,
        paper_links: %{
          "opaque-title" => %{
            title: "Live title fallback",
            description: "Live description ignored"
          },
          "opaque-description" => %{
            title: "Live title ignored",
            description: "Live description fallback"
          }
        }
      })

    fragment = LazyHTML.from_fragment(html)

    assert html =~ "Live title fallback"
    assert html =~ "Live description fallback"
    assert html =~ "Editable description"
    assert html =~ "Editable title"

    title_form =
      fragment
      |> LazyHTML.query(~s(form[data-test-id="paper-link-ref-title-editor"]))
      |> Enum.at(0)

    description_form =
      fragment
      |> LazyHTML.query(~s(form[data-test-id="paper-link-ref-description-editor"]))
      |> Enum.at(0)

    assert title_form
           |> LazyHTML.query(~s([name="paper-link-ref-index"]))
           |> LazyHTML.attribute("value") == ["1"]

    assert description_form
           |> LazyHTML.query(~s([name="paper-link-ref-index"]))
           |> LazyHTML.attribute("value") == ["0"]

    assert fragment
           |> LazyHTML.query(~s([data-paper-link-ref-title-paint]))
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(~s([data-paper-link-ref-description-paint]))
           |> Enum.count() == 1

    configure = LazyHTML.query(fragment, ~s([data-test-id="paper-links-editor"]))

    first_row = configure |> LazyHTML.query(~s([data-ref-index="0"])) |> Enum.at(0)
    second_row = configure |> LazyHTML.query(~s([data-ref-index="1"])) |> Enum.at(0)

    assert first_row |> LazyHTML.query(~s([data-paper-link-ref-title-readonly])) |> Enum.count() ==
             1

    assert first_row
           |> LazyHTML.query(~s([data-paper-link-ref-description-panel-trigger]))
           |> Enum.count() == 1

    assert second_row
           |> LazyHTML.query(~s([data-paper-link-ref-title-panel-trigger]))
           |> Enum.count() == 1

    assert second_row
           |> LazyHTML.query(~s([data-paper-link-ref-description-readonly]))
           |> Enum.count() == 1

    refute configure |> LazyHTML.query(~s([name="ref-0-title"])) |> Enum.any?()
    refute configure |> LazyHTML.query(~s([name="ref-1-description"])) |> Enum.any?()
  end

  test "unadmitted reference rows keep safe legacy fields without serializing opaque siblings" do
    block = %{
      "id" => "legacy-partial-copy",
      "type" => "paper-links",
      "refs" => [
        %{
          "slug" => "duplicate",
          "title" => %{"text" => "preserve"},
          "description" => "Editable duplicate description",
          "prefer_authored_copy" => true
        },
        %{
          "slug" => " duplicate ",
          "title" => "Editable duplicate title",
          "description" => ["preserve"],
          "prefer_authored_copy" => true
        },
        %{
          "slug" => "live-owned-title",
          "title" => false,
          "description" => 7,
          "prefer_authored_copy" => false
        },
        %{
          "slug" => "live-owned-description",
          "title" => 9,
          "description" => 1.5,
          "prefer_authored_copy" => false
        }
      ]
    }

    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block, paper_links: %{}})

    configure =
      html |> LazyHTML.from_fragment() |> LazyHTML.query(~s([data-test-id="paper-links-editor"]))

    for {index, safe_field, opaque_field} <- [
          {0, "description", "title"},
          {1, "title", "description"},
          {2, "description", "title"},
          {3, "title", "description"}
        ] do
      row = configure |> LazyHTML.query(~s([data-ref-index="#{index}"])) |> Enum.at(0)

      assert row |> LazyHTML.query(~s([name="ref-#{index}-#{safe_field}"])) |> Enum.count() == 1
      refute row |> LazyHTML.query(~s([name="ref-#{index}-#{opaque_field}"])) |> Enum.any?()

      assert row
             |> LazyHTML.query(~s([data-paper-link-ref-#{opaque_field}-readonly]))
             |> Enum.count() == 1
    end
  end

  test "bar-chart keeps the canonical chart visible while row controls start closed" do
    block = %{
      "id" => "velocity",
      "type" => "bar-chart",
      "title" => "Changes by kind",
      "max" => 8,
      "values" => true,
      "bars" => [
        %{"label" => "Features", "value" => 8},
        %{"label" => "Fixes", "value" => 5}
      ]
    }

    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block})

    assert html =~ Render.render_block(block, %{style: :article})
    assert html =~ ~s(data-test-id="paper-bar-chart-preview")
    assert html =~ ~s(class="bp-paper-contextual-controls")
    assert html =~ "ignore_attrs"
    assert html =~ ~s(id="bar-chart-form-velocity")
    assert html =~ ~s(data-test-id="paper-bar-chart-row")
    assert html =~ ~s(phx-debounce="500")
  end

  test "expandable preview stays rendered and its closed controls retain nested canvas context" do
    block = %{
      "id" => "details",
      "type" => "expandable",
      "summary" => "Technical record",
      "children" => [
        %{
          "id" => "nested-copy",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "The preserved nested prose."}]
        }
      ]
    }

    html =
      render_component(&PaperEditor.paper_block_fields/1, %{
        block: block,
        canvas_enabled: true,
        root_slug: "chronicle",
        doc_key: "production:paper:chronicle",
        paper_rev: 7
      })

    assert html =~ ~s(data-test-id="paper-expandable-preview")
    assert html =~ ~s(class="bp-paper-contextual-controls")
    assert html =~ "ignore_attrs"
    assert html =~ ~s(id="expandable-form-details")
    assert html =~ ~s(phx-hook="BarkparkPaperCanvas")
    assert html =~ ~s(data-paper-container-id="details")
    assert html =~ ~s(data-paper-doc-key="production:paper:chronicle")
    assert html =~ ~s(data-paper-rev="7")

    fragment = LazyHTML.from_fragment(html)

    assert fragment
           |> LazyHTML.query(
             ~s(details.bp-expandable > summary textarea[name="summary"][form="expandable-summary-form-details"][aria-label="Expandable title"])
           )
           |> LazyHTML.text() == "Technical record"

    assert fragment |> LazyHTML.query("summary form, form form") |> Enum.empty?()

    assert fragment
           |> LazyHTML.query(~s(#expandable-form-details input[name="summary"]))
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(
             ~s(#expandable-form-details input[name="open"][type="hidden"][value="false"])
           )
           |> Enum.count() == 1

    for disclosure <- LazyHTML.query(fragment, "details") do
      assert [_id] = LazyHTML.attribute(disclosure, "id")
      assert [command] = LazyHTML.attribute(disclosure, "phx-mounted")
      assert [["ignore_attrs", %{"attrs" => ["open"]}]] = Jason.decode!(command)
    end

    assert fragment
           |> LazyHTML.query(
             ~s(details.bp-expandable > .bp-expandable__body > [phx-hook="BarkparkPaperCanvas"])
           )
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query("details.bp-paper-contextual-controls:not([open])")
           |> Enum.count() == 1

    assert fragment |> LazyHTML.query("details.bp-expandable") |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(
             ~s(details.bp-paper-contextual-controls [phx-hook="BarkparkPaperCanvas"])
           )
           |> Enum.count() == 0

    ids = Regex.scan(~r/\sid="([^"]+)"/, html, capture: :all_but_first) |> List.flatten()
    assert length(ids) == length(Enum.uniq(ids))
  end
end
